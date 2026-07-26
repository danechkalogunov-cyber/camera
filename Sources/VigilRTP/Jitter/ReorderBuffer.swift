//
//  ReorderBuffer.swift
//  VigilRTP
//
//  The bounded, sequence-ordered reorder/jitter buffer: `.passthrough` for TCP interleaved and an
//  adaptive ring for UDP, bounded in packets *and* in milliseconds.
//  Implements docs/spec-rtp.md §10 and docs/API_CONTRACT.md §4.4 / §5.5
//  (`Jitter/ReorderBuffer.swift`).
//

import Foundation
import VigilProtocols

/// Reorders RTP packets into sequence order, bounded by both a packet count and a hold time.
///
/// Two modes, and the transport decides which (API_CONTRACT §4.4):
///
/// * `.passthrough` — RTSP interleaved over TCP. TCP has already ordered the bytes, so buffering
///   adds pure latency for nothing, and that latency is charged directly against the under-250 ms
///   glass-to-glass target. Packets are forwarded on arrival; sequence discontinuities are still
///   counted and still reported as gaps, because there they mean the *camera* dropped packets.
/// * `.adaptive` — UDP. Starts at 128 packets / 60 ms and escalates to 512 packets / 200 ms once
///   measured loss passes 1 %. While packets arrive strictly in order the ring is bypassed
///   entirely, so the common case still costs nothing.
///
/// Every sequence comparison here is modulo-2^16 (`seqLess`, `seqDiff`). A `<` anywhere in this
/// type would stall the buffer permanently the first time the sequence crossed 65535.
public struct ReorderBuffer: Sendable {

    // MARK: - Nested Types

    /// Which of the two reordering disciplines this buffer applies.
    public enum Mode: Sendable, Equatable {
        /// Forward on arrival. For TCP interleaved, where the transport already ordered the stream.
        case passthrough
        /// Sequence-ordered ring with a fast path for in-order runs. For UDP.
        case adaptive
    }

    /// What one `push` or `drain` released.
    public struct Output: Sendable {
        /// Packets ready for depacketization, in strict sequence order.
        public var packets: [RTPPacket] = []
        /// Sequence numbers the buffer has given up waiting for. A run that straddles the 65535 → 0
        /// wrap is split into two ranges, because one `ClosedRange<UInt16>` cannot express it.
        public var gaps: [ClosedRange<UInt16>] = []
        /// Packets that arrived after their slot had already been released.
        public var late = 0
        /// Packets whose sequence number was already held or already released as itself.
        public var duplicates = 0
        /// Packets that arrived with a hole below them, i.e. genuinely out of order.
        public var reordered = 0
        /// Packets discarded because the ring had to be force-flushed to make room.
        public var overflowDropped = 0

        /// Creates an empty output.
        public init() {}

        /// Total number of missing sequence numbers across `gaps`.
        public var lostCount: Int { gaps.reduce(0) { $0 + Int($1.upperBound - $1.lowerBound) + 1 } }

        /// True when nothing was released and nothing was counted.
        public var isEmpty: Bool {
            packets.isEmpty && gaps.isEmpty && late == 0 && duplicates == 0
                && reordered == 0 && overflowDropped == 0
        }
    }

    /// The fast-path state machine of `.adaptive` (docs/spec-rtp.md §10.5).
    private enum RunState {
        /// Packets are arriving in order; release immediately, touch nothing.
        case streaming
        /// A reorder or a duplicate was seen; the ring is in use.
        case buffering
    }

    /// One occupied ring slot: the packet and when it arrived.
    private struct Slot {
        var packet: RTPPacket
        var arrival: MediaInstant
    }

    // MARK: - Stored Properties

    /// The discipline in force. Fixed for the life of the buffer; escalation changes depth, not mode.
    public let mode: Mode

    /// Ring capacity in packets, rounded up to a power of two and capped at 4096.
    public private(set) var capacity: Int

    /// Longest a packet may be held waiting for its predecessor.
    public private(set) var maxHold: Duration

    /// True once `escalate()` has widened the bounds and `relax()` has not undone it.
    public private(set) var isEscalated = false

    /// `capacity - 1`, the index mask. Valid because `capacity` is a power of two.
    private var mask: Int

    /// Fixed-size storage. Allocated once per depth change, never per packet.
    private var slots: [Slot?]

    /// The next sequence number to release. `nil` before the first packet.
    private var baseSequence: UInt16?

    /// Number of occupied slots.
    private var held = 0

    /// The fast-path state of `.adaptive`.
    private var runState: RunState = .streaming

    /// Consecutive in-order packets seen while `.buffering`, for the return to `.streaming`.
    private var inOrderRun = 0

    /// The most recently released sequence number, for duplicate detection in `.passthrough`.
    private var lastReleased: UInt16?

    /// Number of consecutive in-order packets required to leave `.buffering`.
    private static let streamingResumeRun = 256

    /// Hard ceiling on the ring, so a pathological policy cannot allocate without bound.
    public static let maximumCapacity = 4096

    // MARK: - Initialisation

    /// Creates a reorder buffer.
    ///
    /// - Parameters:
    ///   - mode: `.passthrough` for TCP interleaved, `.adaptive` for UDP.
    ///   - capacity: ring size in packets. Rounded **up** to a power of two and clamped to
    ///     `1...4096`; ignored entirely in `.passthrough`, which never stores a packet.
    ///   - maxHold: longest a packet waits for a missing predecessor before the hole is declared a
    ///     gap. Ignored in `.passthrough`.
    public init(mode: Mode, capacity: Int, maxHold: Duration) {
        self.mode = mode
        self.maxHold = maxHold
        let rounded = mode == .passthrough ? 1 : Self.roundedCapacity(capacity)
        self.capacity = rounded
        self.mask = rounded - 1
        self.slots = mode == .passthrough ? [] : Array(repeating: nil, count: rounded)
    }

    /// TCP interleaved: no buffering, no added latency.
    public static let tcpInterleaved = ReorderBuffer(mode: .passthrough, capacity: 0,
                                                     maxHold: .zero)

    /// UDP live: 128 packets / 60 ms, about 1.5 frame intervals at 25 fps.
    public static let udpLive = ReorderBuffer(mode: .adaptive, capacity: 128,
                                              maxHold: .milliseconds(60))

    /// UDP after loss passes 1 %: 512 packets / 200 ms.
    public static let udpLossy = ReorderBuffer(mode: .adaptive, capacity: 512,
                                               maxHold: .milliseconds(200))

    /// The buffer a `LatencyPreset` asks for on the given transport.
    ///
    /// `.passthrough` ignores the preset by design: on TCP the preset's depth would be latency spent
    /// on a problem the transport has already solved.
    public static func forPreset(_ preset: LatencyPreset, mode: Mode) -> ReorderBuffer {
        guard mode == .adaptive else { return .tcpInterleaved }
        return ReorderBuffer(mode: .adaptive,
                             capacity: Swift.max(preset.jitterBufferPackets, 128),
                             maxHold: preset.jitterBufferDepth)
    }

    // MARK: - Computed Properties

    /// Packets currently held, waiting for a predecessor. Always 0 in `.passthrough`.
    public var depth: Int { held }

    /// Arrival instant of the oldest held packet, or `nil` when nothing is held.
    public var oldestArrival: MediaInstant? {
        guard held > 0, let base = baseSequence else { return nil }
        var oldest: MediaInstant?
        for step in 0..<capacity {
            let sequence = base &+ UInt16(truncatingIfNeeded: step)
            guard let slot = slots[Int(sequence) & mask], slot.packet.sequenceNumber == sequence
            else { continue }
            if let current = oldest {
                oldest = Swift.min(current, slot.arrival)
            } else {
                oldest = slot.arrival
            }
        }
        return oldest
    }

    /// How long the oldest held packet has been waiting, in milliseconds. 0 when nothing is held.
    public func bufferedMilliseconds(at now: MediaInstant) -> Double {
        guard let oldest = oldestArrival else { return 0 }
        return Swift.max(0, now.milliseconds(since: oldest))
    }

    /// When `drain` will next have work to do, or `nil` when the buffer is empty.
    public var nextDeadline: MediaInstant? {
        guard let oldest = oldestArrival else { return nil }
        return oldest + maxHold
    }

    // MARK: - Depth policy

    /// Widens the bounds to 512 packets / 200 ms. Returns true if this changed anything.
    ///
    /// Held packets are preserved: the ring is rebuilt in sequence order, not dropped.
    @discardableResult
    public mutating func escalate() -> Bool {
        guard mode == .adaptive, !isEscalated else { return false }
        isEscalated = true
        resize(capacity: 512, maxHold: .milliseconds(200))
        return true
    }

    /// Restores the 128 packet / 60 ms bounds after a sustained quiet period.
    @discardableResult
    public mutating func relax() -> Bool {
        guard mode == .adaptive, isEscalated else { return false }
        isEscalated = false
        resize(capacity: 128, maxHold: .milliseconds(60))
        return true
    }

    // MARK: - Insertion

    /// Offers one packet to the buffer.
    ///
    /// In `.passthrough` the packet is returned immediately and unmodified — the buffer is a counter
    /// there, never a filter, so nothing it does can add a frame of latency. In `.adaptive` the
    /// packet is either released immediately (in-order fast path), held, or dropped as late or
    /// duplicate.
    ///
    /// - Parameter now: arrival instant, injected so the pure layer reads no clock.
    public mutating func push(_ packet: RTPPacket, at now: MediaInstant) -> Output {
        guard mode == .adaptive else { return passthrough(packet) }

        var out = Output()
        let sequence = packet.sequenceNumber

        guard let base = baseSequence else {
            baseSequence = sequence
            release(from: sequence, into: &out, insert: packet, at: now)
            return out
        }

        let distance = seqDiff(sequence, base)

        if distance < 0 {
            // Its slot was released already: either a duplicate of a released packet or a straggler.
            if lastReleased == sequence {
                out.duplicates += 1
            } else {
                out.late += 1
            }
            noteDisorder()
            return out
        }

        if distance >= capacity {
            // The hole below this packet is wider than the ring: give up on it now rather than
            // dropping the packet that proves the stream moved on.
            flushAll(into: &out)
            out.gaps += seqGapRanges(from: base, to: sequence)
            baseSequence = sequence
            noteDisorder()
            release(from: sequence, into: &out, insert: packet, at: now)
            return out
        }

        let index = Int(sequence) & mask
        if let existing = slots[index], existing.packet.sequenceNumber == sequence {
            out.duplicates += 1
            noteDisorder()
            return out
        }

        if distance > 0 {
            out.reordered += 1
            noteDisorder()
        } else if runState == .buffering {
            inOrderRun += 1
            if inOrderRun >= Self.streamingResumeRun, held == 0 {
                runState = .streaming
                inOrderRun = 0
            }
        }

        // In-order fast path: nothing is held below it, so the ring is never touched.
        if distance == 0, held == 0 {
            releaseOne(packet, into: &out)
            baseSequence = sequence &+ 1
            return out
        }

        slots[index] = Slot(packet: packet, arrival: now)
        held += 1
        releaseContiguous(into: &out)
        applyHoldBound(at: now, into: &out)
        return out
    }

    /// Time-driven release. Call from `RTPTrackReceiver.tick`.
    ///
    /// - Parameter force: release everything held and report every hole. Used on PAUSE, TEARDOWN and
    ///   an SSRC change, where waiting for a packet that will never come is pointless.
    public mutating func drain(at now: MediaInstant, force: Bool = false) -> Output {
        var out = Output()
        guard mode == .adaptive, held > 0 else { return out }
        if force {
            flushAll(into: &out)
            return out
        }
        applyHoldBound(at: now, into: &out)
        return out
    }

    /// Forgets every held packet and all sequence state. Held packets are discarded, not released.
    public mutating func reset() {
        for index in slots.indices { slots[index] = nil }
        held = 0
        baseSequence = nil
        lastReleased = nil
        runState = .streaming
        inOrderRun = 0
    }

    // MARK: - Private

    /// The `.passthrough` path: forward on arrival, count what the sequence numbers imply.
    private mutating func passthrough(_ packet: RTPPacket) -> Output {
        var out = Output()
        out.packets = [packet]
        let sequence = packet.sequenceNumber
        if let expected = baseSequence {
            let distance = seqDiff(sequence, expected)
            if distance > 0 {
                out.gaps = seqGapRanges(from: expected, to: sequence)
            } else if distance < 0 {
                if lastReleased == sequence { out.duplicates += 1 } else { out.late += 1 }
            }
        }
        // Only advance the expectation forwards, so one late packet does not re-report the run.
        if baseSequence == nil || seqGreater(sequence &+ 1, baseSequence ?? sequence) {
            baseSequence = sequence &+ 1
        }
        lastReleased = sequence
        return out
    }

    /// Leaves the in-order fast path. Idempotent.
    private mutating func noteDisorder() {
        runState = .buffering
        inOrderRun = 0
    }

    /// Appends one packet to the output and records it as the most recent release.
    private mutating func releaseOne(_ packet: RTPPacket, into out: inout Output) {
        out.packets.append(packet)
        lastReleased = packet.sequenceNumber
    }

    /// Seeds the base sequence and releases `insert` immediately, storing it only if it cannot go
    /// straight out. Used for the very first packet and after a forced re-base.
    private mutating func release(from sequence: UInt16, into out: inout Output,
                                  insert packet: RTPPacket, at now: MediaInstant) {
        releaseOne(packet, into: &out)
        baseSequence = sequence &+ 1
        releaseContiguous(into: &out)
    }

    /// Pops slots from `baseSequence` upwards for as long as they are occupied.
    private mutating func releaseContiguous(into out: inout Output) {
        guard var base = baseSequence else { return }
        while held > 0 {
            let index = Int(base) & mask
            guard let slot = slots[index], slot.packet.sequenceNumber == base else { break }
            slots[index] = nil
            held -= 1
            releaseOne(slot.packet, into: &out)
            base = base &+ 1
        }
        baseSequence = base
    }

    /// Declares the hole at `baseSequence` lost once the oldest held packet has waited longer than
    /// `maxHold`, then releases everything that became contiguous.
    private mutating func applyHoldBound(at now: MediaInstant, into out: inout Output) {
        while held > 0, bufferedMilliseconds(at: now) > maxHold.milliseconds {
            guard releaseWithGap(into: &out) else { return }
        }
    }

    /// Skips forward to the lowest occupied slot above `baseSequence`, reporting the skipped run as
    /// a gap. Returns false when nothing is held, so the caller's loop terminates.
    @discardableResult
    private mutating func releaseWithGap(into out: inout Output) -> Bool {
        guard held > 0, let base = baseSequence else { return false }
        for step in 1...capacity {
            let sequence = base &+ UInt16(truncatingIfNeeded: step)
            let index = Int(sequence) & mask
            guard let slot = slots[index], slot.packet.sequenceNumber == sequence else { continue }
            out.gaps += seqGapRanges(from: base, to: sequence)
            baseSequence = sequence
            releaseContiguous(into: &out)
            return true
        }
        return false
    }

    /// Releases every held packet in sequence order, reporting every hole between them.
    private mutating func flushAll(into out: inout Output) {
        while held > 0 {
            releaseContiguous(into: &out)
            guard held > 0 else { break }
            guard releaseWithGap(into: &out) else { break }
        }
    }

    /// Rebuilds the ring at a new depth, preserving held packets in sequence order.
    private mutating func resize(capacity newCapacity: Int, maxHold newHold: Duration) {
        let rounded = Self.roundedCapacity(newCapacity)
        maxHold = newHold
        guard rounded != capacity else { return }
        var carried: [Slot] = []
        carried.reserveCapacity(held)
        for slot in slots { if let slot { carried.append(slot) } }
        capacity = rounded
        mask = rounded - 1
        slots = Array(repeating: nil, count: rounded)
        held = 0
        guard let base = baseSequence else { return }
        for slot in carried {
            let distance = seqDiff(slot.packet.sequenceNumber, base)
            guard distance >= 0, distance < rounded else { continue }   // no longer representable
            slots[Int(slot.packet.sequenceNumber) & mask] = slot
            held += 1
        }
    }

    /// Rounds a requested capacity up to a power of two in `1...maximumCapacity`.
    private static func roundedCapacity(_ requested: Int) -> Int {
        let bounded = Swift.min(Swift.max(requested, 1), maximumCapacity)
        var size = 1
        while size < bounded { size <<= 1 }
        return size
    }
}
