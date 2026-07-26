//
//  RTPSourceState.swift
//  VigilRTP
//
//  Per-SSRC reception state: the RFC 3550 A.1 sequence algorithm, the A.8 interarrival jitter
//  estimator, and the report block they produce.
//  Implements docs/spec-rtp.md §12.5 – §12.7 and docs/API_CONTRACT.md §5.5
//  (`RTCP/RTPSourceState.swift`).
//

import Foundation
import VigilProtocols

/// Reception state for one synchronisation source.
///
/// This is RFC 3550 Appendix A.1 and A.8 implemented as written, not a simplification. The Receiver
/// Report fields are only correct with this exact algorithm, and Hikvision NVRs really do restart
/// their sequence numbers when a shared session switches channel — which is precisely the case the
/// `badSeq` two-packet confirmation exists to distinguish from noise.
public struct RTPSourceState: Sendable {

    // MARK: - Constants

    /// One full sequence cycle: 2^16.
    public static let sequenceModulus: UInt32 = 1 << 16
    /// A forward jump larger than this is treated as a restart, not as loss (RFC 3550 A.1).
    public static let maxDropout: UInt32 = 3000
    /// A backward jump larger than this is treated as a restart, not as reordering.
    public static let maxMisorder: UInt32 = 100
    /// Consecutive packets required before a new source is believed.
    public static let minSequential: UInt32 = 2

    // MARK: - Stored Properties

    /// The source this state describes.
    public private(set) var ssrc: UInt32

    /// Highest sequence number seen, in wrapped form.
    public private(set) var maxSequence: UInt16 = 0

    /// Completed cycles, already multiplied by 2^16 as RFC 3550 stores it.
    public private(set) var cycles: UInt32 = 0

    /// The first sequence number counted, in extended form.
    public private(set) var baseSequence: UInt32 = 0

    /// The sequence number that, if seen again, confirms a restart. Starts "impossible".
    private var badSequence: UInt32 = sequenceModulus + 1

    /// Packets still needed before the source leaves probation.
    private var probation: UInt32 = minSequential

    /// Packets counted as validly received.
    public private(set) var received: UInt32 = 0

    /// `expected` at the previous report, for the per-interval fraction.
    private var expectedPrior: UInt32 = 0

    /// `received` at the previous report, for the per-interval fraction.
    private var receivedPrior: UInt32 = 0

    /// The previous packet's relative transit time, in RTP clock units.
    private var transit: Int32 = 0

    /// True once `transit` holds a real measurement.
    private var hasTransit = false

    /// Interarrival jitter, stored scaled by 16 so the A.8 recurrence needs no floating point.
    public private(set) var jitter: UInt32 = 0

    /// Compact NTP of the last Sender Report received, for the report block's LSR field.
    public private(set) var lastSenderReportCompactNTP: UInt32?

    /// When that Sender Report arrived, for the report block's DLSR field.
    public private(set) var lastSenderReportArrival: MediaInstant?

    /// The media clock rate, used to express arrival times in RTP units and jitter in milliseconds.
    public let clockRate: Int32

    // MARK: - Initialisation

    /// Creates state for a source that has not been seen yet.
    ///
    /// - Parameters:
    ///   - ssrc: the source. Rebind with `restart(ssrc:)` when it changes; do not reuse this value.
    ///   - clockRate: the RTP clock rate from the SDP. Must be positive; a non-positive rate leaves
    ///     the jitter estimate at zero rather than dividing by it.
    public init(ssrc: UInt32 = 0, clockRate: Int32) {
        self.ssrc = ssrc
        self.clockRate = clockRate
    }

    // MARK: - Computed Properties

    /// The extended (cycle-corrected) highest sequence number received.
    public var extendedHighestSequence: UInt32 { cycles &+ UInt32(maxSequence) }

    /// How many packets should have arrived, per RFC 3550 A.3.
    public var expected: UInt32 { extendedHighestSequence &- baseSequence &+ 1 }

    /// Cumulative packets lost. Negative when duplicates outnumber losses, which is legal.
    public var cumulativeLost: Int32 {
        Int32(truncatingIfNeeded: Int64(expected) - Int64(received))
    }

    /// Interarrival jitter in milliseconds. 0 for a non-positive clock rate.
    public var jitterMilliseconds: Double {
        guard clockRate > 0 else { return 0 }
        return Double(jitter >> 4) * 1000 / Double(clockRate)
    }

    /// True while the source has not yet produced `minSequential` consecutive packets.
    public var isInProbation: Bool { probation > 0 }

    // MARK: - Sequence tracking

    /// RFC 3550 A.1 `init_seq`: adopt `sequence` as the base of a fresh counting run.
    public mutating func initialise(sequence: UInt16) {
        baseSequence = UInt32(sequence)
        maxSequence = sequence
        badSequence = Self.sequenceModulus + 1
        cycles = 0
        received = 0
        receivedPrior = 0
        expectedPrior = 0
    }

    /// RFC 3550 A.1 `update_seq`.
    ///
    /// - Returns: true when the packet counts as validly received. False while the source is still
    ///   in probation, and false for the first packet of an unconfirmed restart — in both cases the
    ///   packet is still handed to the depacketizer, it just does not yet count towards the report.
    @discardableResult
    public mutating func update(sequence: UInt16) -> Bool {
        let delta = UInt32(sequence &- maxSequence)

        if probation > 0 {
            if sequence == maxSequence &+ 1 {
                probation -= 1
                maxSequence = sequence
                if probation == 0 {
                    initialise(sequence: sequence)
                    received &+= 1
                    return true
                }
            } else {
                probation = Self.minSequential - 1
                maxSequence = sequence
            }
            return false
        } else if delta < Self.maxDropout {
            // In order, possibly with a small gap. A wrapped raw value proves a completed cycle.
            if sequence < maxSequence { cycles &+= Self.sequenceModulus }
            maxSequence = sequence
        } else if delta <= Self.sequenceModulus - Self.maxMisorder {
            // A jump too large to be loss: only believe it once a second packet confirms it.
            if UInt32(sequence) == badSequence {
                initialise(sequence: sequence)
            } else {
                badSequence = (UInt32(sequence) + 1) & (Self.sequenceModulus - 1)
                return false
            }
        } else {
            // Duplicate or reordered inside the misorder window: counted, but nothing moves.
        }
        received &+= 1
        return true
    }

    /// Starts counting a source that has just been heard for the first time.
    ///
    /// Exactly RFC 3550 A.1's new-source path: `init_seq`, then `max_seq = seq - 1` so that this
    /// very packet takes the "one more than the last" branch of probation, then `probation =
    /// minSequential`. The source therefore becomes valid on its *second* consecutive packet, and
    /// the first packet is deliberately not counted — that is what makes a random scan of the port
    /// unable to poison the loss statistics.
    public mutating func beginSource(sequence: UInt16) {
        initialise(sequence: sequence)
        maxSequence = sequence &- 1
        probation = Self.minSequential
    }

    /// Adopts a new SSRC and forgets everything about the old one.
    public mutating func restart(ssrc newSSRC: UInt32, sequence: UInt16) {
        ssrc = newSSRC
        transit = 0
        hasTransit = false
        jitter = 0
        lastSenderReportCompactNTP = nil
        lastSenderReportArrival = nil
        beginSource(sequence: sequence)
    }

    // MARK: - Jitter

    /// The arrival instant expressed in RTP clock units, as RFC 3550 §6.4.1 requires.
    ///
    /// Truncating to 32 bits is correct and intended: only differences matter, and `&-` handles the
    /// wrap. Returns 0 for a non-positive clock rate.
    public func arrivalInRTPUnits(_ now: MediaInstant) -> UInt32 {
        guard clockRate > 0 else { return 0 }
        // Integer math on purpose: at a day of uptime, `Double(nanoseconds) * 90_000` is past the
        // 2^53 exact-integer range and would quantise the arrival time into 10 µs steps.
        let rate = Int64(clockRate)
        let whole = now.nanoseconds / 1_000_000_000
        let fraction = now.nanoseconds % 1_000_000_000
        let ticks = whole &* rate &+ (fraction &* rate) / 1_000_000_000
        return UInt32(truncatingIfNeeded: ticks)
    }

    /// RFC 3550 §6.4.1 / A.8 interarrival jitter.
    ///
    /// `D(i-1,i) = (Rj - Sj) - (Ri - Si)` and `J(i) = J(i-1) + (|D(i-1,i)| - J(i-1)) / 16`, with the
    /// estimate held scaled by 16 so the division is a shift and no precision is lost. Applying
    /// `>> 4` here as well as on the wire — the classic way to get this wrong — would report a
    /// jitter sixteen times too small.
    ///
    /// The first packet only seeds `transit`: RFC 3550's own pseudo-code starts from `transit == 0`,
    /// which makes `D` the whole arrival time and takes ~50 packets to decay. Seeding is what every
    /// production stack does and is the only deviation from the printed listing.
    public mutating func updateJitter(rtpTimestamp: UInt32, arrivalRTP: UInt32) {
        let currentTransit = Int32(bitPattern: arrivalRTP &- rtpTimestamp)
        guard hasTransit else {
            transit = currentTransit
            hasTransit = true
            return
        }
        let difference = currentTransit &- transit
        // `abs(Int32.min)` traps; a difference that extreme is nonsense anyway, so it saturates.
        let d = difference == Int32.min ? Int32.max : abs(difference)
        transit = currentTransit
        let scaled = Int32(bitPattern: jitter)
        let updated = scaled &+ d &- ((scaled &+ 8) >> 4)
        jitter = UInt32(bitPattern: Swift.max(0, updated))
    }

    // MARK: - Sender reports

    /// Records the Sender Report needed for the LSR and DLSR fields of our next report block.
    public mutating func noteSenderReport(_ report: SenderReport, at now: MediaInstant) {
        lastSenderReportCompactNTP = report.compactNTP
        lastSenderReportArrival = now
    }

    // MARK: - Report block

    /// Builds the reception report block for our next Receiver Report and rolls the interval.
    ///
    /// `fractionLost` is the loss of the interval since the previous call, saturating at 0 when
    /// duplicates made the interval's arithmetic negative. `cumulativeLost` saturates into the
    /// 24-bit signed range the wire field allows.
    public mutating func makeReportBlock(at now: MediaInstant) -> ReceptionReportBlock {
        let expectedNow = expected
        let expectedInterval = expectedNow &- expectedPrior
        let receivedInterval = received &- receivedPrior
        expectedPrior = expectedNow
        receivedPrior = received

        let lostInterval = Int64(expectedInterval) - Int64(receivedInterval)
        let fraction: UInt8
        if expectedInterval == 0 || lostInterval <= 0 {
            fraction = 0
        } else {
            fraction = UInt8(Swift.min(255, (lostInterval << 8) / Int64(expectedInterval)))
        }

        let cumulative = Swift.max(-0x80_0000, Swift.min(0x7F_FFFF, cumulativeLost))

        var delay: UInt32 = 0
        if let arrival = lastSenderReportArrival {
            let seconds = Swift.max(0, now.seconds(since: arrival))
            delay = UInt32(Swift.min(Double(UInt32.max), (seconds * 65536).rounded()))
        }

        return ReceptionReportBlock(
            ssrc: ssrc,
            fractionLost: fraction,
            cumulativeLost: cumulative,
            extendedHighestSequence: extendedHighestSequence,
            jitter: jitter >> 4,
            lastSenderReportTimestamp: lastSenderReportCompactNTP ?? 0,
            delaySinceLastSenderReport: delay
        )
    }
}
