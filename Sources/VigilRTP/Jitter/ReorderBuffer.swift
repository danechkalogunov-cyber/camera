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
/// * `.adaptive` — UDP. 128 packets / 60 ms, escalating to 512 packets / 200 ms once measured loss
///   passes 1 %. While packets arrive strictly in order the ring is bypassed entirely, so the
///   common case costs one array write less than nothing.
///
/// Every sequence comparison here is modulo-2^16 (`seqLess`, `seqDiff`). A `<` anywhere in this type
/// would stall the buffer permanently the first time the sequence crossed 65535 — every ~22 minutes
/// at 50 packets per second.
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
        /// Packets whose sequence number was already held, or was the one just released.
        public var duplicates = 0
        /// Packets that arrived with a hole below them, i.e. genuinely out of order.
        public var reordered = 0

        /// Creates an empty output.
        public init() {}

        /// Total number of missing sequence numbers across `gaps`.
        public var lostCount: Int {
            gaps.reduce(0) { $0 + Int($1.upperBound - $1.lowerBound) + 1 }
        }

        /// True when nothing was released and nothing was counted.
        public var isEmpty: Bool {
            packets.isEmpty && gaps.isEmpty && late == 0 && duplicates == 0 && reordered == 0
        }
    }

    /// The fast-path state machine of `.adaptive` (docs/spec-rtp.md §10.5).
    private enum RunState {
        /// Packets are arriving in order; the ring is bypassed.
        case streaming
        /// A reorder, a duplicate or a gap was seen; the ring is in use.
        case buffering
    }

    /// One occupied ring slot.
    private struct Slot {
        var packet: RTPPacket
    }

    // MARK: - Stored Properties

    /// The discipline in force. Fixed for the life of the buffer; escalation changes depth, not mode.
    public let mode: Mode

    /// Ring capacity in packets: a power of two in `1...4096`, or 0 in `.passthrough`.
    public private(set) var capacity: Int

    /// Longest the buffer waits for a missing packet before declaring it lost.
    public private(set) var maxHold: Duration

    /// True once `escalate()` has widened the bounds and `relax()` has not undone it.
    public private(set) var isEscalated = false

    /// `capacity - 1`, the index mask. Valid because `capacity` is a power of two.
    private var mask: Int

    /// Fixed-size storage, allocated once per depth change and never per packet.
    private var slots: [Slot?]

    /// The next sequence number to release. `nil` before the first packet.
    private var baseSequence: UInt16?

    /// Number of occupied slots.
    private var held = 0

    /// When the hole currently blocking `baseSequence` was first observed. The hold budget is
    /// measured from here, and it restarts for each distinct hole — an O(1) anchor, where scanning
    /// the ring for the oldest arrival would be O(capacity) on the per-packet path.
    private var holeAnchor: MediaInstant?

    /// The fast-path state of `.adaptive`.
    private var runState: RunState = .streaming

    /// Consecutive in-order packets seen while `.buffering`, for the return to `.streaming`.
    private var inOrderRun = 0

    /// The most recently released sequence number, for duplicate detection.
    private var lastReleased: UInt16?

    /// Consecutive in-order packets required to leave `.buffering` (docs/spec-rtp.md §10.5).
    private static let streamingResumeRun = 256

    /// Hard ceiling on the ring, so a pathological policy cannot allocate without bound.
    public static let maximumCapacity = 4096

    // MARK: - Initialisation

    /// Creates a reorder buffer.
    ///
    /// - Parameters:
    ///   - mode: `.passthrough` for TCP interleaved, `.adaptive` for UDP.
    ///   - capacity: ring size in packets. Rounded **up** to a power of two and clamped to
    ///     `1...4096`; forced to 0 in `.passthrough`, which never stores a packet.
    ///   - maxHold: longest a packet waits for a missing predecessor before the hole is declared a
    ///     gap. Ignored in `.passthrough`.
    public init(mode: Mode, capacity: Int, maxHold: Duration) {
        self.mode = mode
        self.maxHold = maxHold
        if mode == .passthrough {
            self.capacity = 0
            self.mask = 0
            self.slots = []
        } else {
            let rounded = Self.roundedCapacity(capacity)
            self.capacity = rounded
            self.mask = rounded - 1
            self.slots = Array(repeating: nil, count: rounded)
        }
    }

    /// TCP interleaved: no buffering, no added latency (API_CONTRACT §4.4).
    public static let tcpInterleaved = ReorderBuffer(mode: .passthrough, capacity: 0, maxHold: .zero)

    /// UDP live: 128 packets / 60 ms, about 1.5 frame intervals at 25 fps.
    public static let udpLive = ReorderBuffer(mode: .adaptive, capacity: 128,
                                              maxHold: .milliseconds(60))

    /// UDP after loss passes 1 %: 512 packets / 200 ms.
    public static let udpLossy = ReorderBuffer(mode: .adaptive, capacity: 512,
                                               maxHold: .milliseconds(200))

    // MARK: - Computed Properties

    /// Packets currently held, waiting for a predecessor. Always 0 in `.passthrough`.
    public var depth: Int { held }

    /// How long the current hole has been open, in milliseconds. 0 when nothing is held.
    public func bufferedMilliseconds(at now: MediaInstant) -> Double {
        guard let holeAnchor else { return 0 }
        return Swift.max(0, now.milliseconds(since: holeAnchor))
    }

    /// When `drain` will next have work to do, or `nil` when nothing is held.
    public var nextDeadline: MediaInstant? {
        guard let holeAnchor else { return nil }
        return holeAnchor + maxHold
    }

    // MARK: - Depth policy

    /// Widens the bounds to 512 packets / 200 ms. Returns true when this changed anything.
    ///
    /// Held packets survive: the ring is rebuilt in sequence order rather than dropped.
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
    /// In `.passthrough` the packet is returned immediately and unmodified — there the buffer is a
    /// counter, never a filter, so nothing it does can add a frame of latency. In `.adaptive` the
    /// packet is released immediately (the in-order fast path), held, or dropped as late or
    /// duplicate.
    ///
    /// - Parameter now: arrival instant, injected so the pure layer reads no clock.
    public mutating func push(_ packet: RTPPacket, at now: MediaInstant) -> Output {
        guard mode == .adaptive else { return passthrough(packet) }

        var out = Output()
        let sequence = packet.sequenceNumber

        guard let base = baseSequence else {
            releaseOne(packet, into: &out)
            baseSequence = sequence &+ 1
            return out
        }

        let distance = seqDiff(sequence, base)

        if distance < 0 {
            // Its slot was released already: a duplicate of the last release, or a straggler.
            if lastReleased == sequence { out.duplicates += 1 } else { out.late += 1 }
            noteDisorder()
            return out
        }

        if distance >= capacity {
            // The hole below this packet is wider than the ring. Give up on it now rather than drop
            // the packet that proves the stream has moved on.
            flushAll(into: &out)
            let resumed = baseSequence ?? sequence
            out.gaps += seqGapRanges(from: resumed, to: sequence)
            releaseOne(packet, into: &out)
            baseSequence = sequence &+ 1
            holeAnchor = nil
            noteDisorder()
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

        if distance == 0, held == 0 {
            // In-order fast path: nothing is waiting below it, so the ring is never touched.
            releaseOne(packet, into: &out)
            baseSequence = sequence &+ 1
            return out
        }

        slots[index] = Slot(packet: packet)
        held += 1
        releaseContiguous(into: &out)
        applyHoldBound(at: now, into: &out)
        anchorHole(at: now)
        return out
    }

    /// Time-driven release. Call from `RTPTrackReceiver.tick`.
    ///
    /// - Parameter force: release everything held and report every hole between the pieces. Used on
    ///   PAUSE, TEARDOWN and an SSRC change, where waiting for a packet that will never come only
    ///   delays the shutdown.
    public mutating func drain(at now: MediaInstant, force: Bool = false) -> Output {
        var out = Output()
        guard mode == .adaptive, held > 0 else { return out }
        if force {
            flushAll(into: &out)
            holeAnchor = nil
            return out
        }
        applyHoldBound(at: now, into: &out)
        anchorHole(at: now)
        return out
    }

    /// Forgets every held packet and all sequence state. Held packets are discarded, not released.
    public mutating func reset() {
        for index in slots.indices { slots[index] = nil }
        held = 0
        baseSequence = nil
        lastReleased = nil
        holeAnchor = nil
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
            // Advance the expectation forwards only, so one late packet cannot re-report a run.
            if seqGreater(sequence &+ 1, expected) { baseSequence = sequence &+ 1 }
        } else {
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

    /// Starts or clears the hold-budget anchor after a release.
    private mutating func anchorHole(at now: MediaInstant) {
        if held == 0 {
            holeAnchor = nil
        } else if holeAnchor == nil {
            holeAnchor = now
        }
    }

    /// Pops slots from `baseSequence` upwards for as long as they are occupied.
    private mutating func releaseContiguous(into out: inout Output) {
        guard var base = baseSequence else { return }
        var advanced = false
        while held > 0 {
            let index = Int(base) & mask
            guard let slot = slots[index], slot.packet.sequenceNumber == base else { break }
            slots[index] = nil
            held -= 1
            releaseOne(slot.packet, into: &out)
            base = base &+ 1
            advanced = true
        }
        baseSequence = base
        if advanced { holeAnchor = nil }        // this hole is resolved; the next one re-anchors
    }

    /// Declares the hole at `baseSequence` lost once it has been open longer than `maxHold`, then
    /// releases everything that thereby became contiguous.
    private mutating func applyHoldBound(at now: MediaInstant, into out: inout Output) {
        while held > 0, bufferedMilliseconds(at: now) > maxHold.milliseconds {
            guard releaseWithGap(into: &out) else { return }
        }
    }

    /// Skips forward to the lowest occupied slot above `baseSequence`, reporting the skipped run as
    /// a gap. Returns false when nothing above the base is occupied.
    @discardableResult
    private mutating func releaseWithGap(into out: inout Output) -> Bool {
        guard held > 0, let base = baseSequence, capacity > 0 else { return false }
        for step in 1...capacity {
            let sequence = base &+ UInt16(truncatingIfNeeded: step)
            let index = Int(sequence) & mask
            guard let slot = slots[index], slot.packet.sequenceNumber == sequence else { continue }
            out.gaps += seqGapRanges(from: base, to: sequence)
            baseSequence = sequence
            holeAnchor = nil
            releaseContiguous(into: &out)
            return true
        }
        return false
    }

    /// Releases every held packet in sequence order, reporting every hole between them.
    private mutating func flushAll(into out: inout Output) {
        releaseContiguous(into: &out)
        while held > 0 {
            guard releaseWithGap(into: &out) else { break }
        }
        holeAnchor = nil
    }

    /// Rebuilds the ring at a new depth, preserving held packets in sequence order.
    private mutating func resize(capacity newCapacity: Int, maxHold newHold: Duration) {
        maxHold = newHold
        let rounded = Self.roundedCapacity(newCapacity)
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
