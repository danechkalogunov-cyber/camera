//
//  TimestampUnwrapper.swift
//  VigilRTP
//
//  Lifts the wrapping 32-bit RTP timestamp into a monotone `Int64` before any `MediaTimestamp` is
//  built, and separates a wrap from a genuine discontinuity.
//  Implements docs/spec-rtp.md §11.2 and docs/API_CONTRACT.md §5.5
//  (`Packet/TimestampUnwrapper.swift`).
//
//  No `import` on purpose: this is integer arithmetic.
//

/// Unwraps the 32-bit RTP timestamp into a monotone `Int64`, rebased so the first packet is 0.
///
/// A 90 kHz clock wraps every `2^32 / 90000 ≈ 13 h 15 m 22 s`, so a camera left running overnight
/// *will* wrap. Comparing raw timestamps with `<` across that boundary throws presentation times by
/// thirteen hours.
///
/// Reordering is handled by advancing the high water mark only forwards: a single late packet that
/// straddles the wrap is extended correctly *and* leaves the cycle count alone. Without that guard
/// one reordered packet flips the cycle counter twice.
///
/// Rebasing to the first value seen keeps presentation timestamps small and readable. `Int64` at
/// 90 kHz has room for three million years either way, so the rebasing is for legibility and for
/// exact rescaling, not for overflow.
public struct TimestampUnwrapper: Sendable {

    // MARK: - Stored Properties

    /// Signed count of completed 2^32 cycles. Negative after a backward wrap.
    private var cycles: Int64 = 0

    /// The most recent timestamp that moved forward, in wrapped form.
    private var last: UInt32?

    /// The extended value of the first timestamp seen, subtracted from every result.
    private var origin: Int64?

    /// One RTP cycle in ticks. Written out rather than shifted so a negative `cycles` is safe.
    private static let cycle: Int64 = 4_294_967_296

    // MARK: - Initialisation

    /// Creates an unwrapper that has seen nothing.
    public init() {}

    /// Creates an unwrapper already anchored to a known RTP timestamp, so the first emitted
    /// presentation time is relative to the RTSP `RTP-Info` seed rather than to the first packet
    /// that happened to arrive.
    public init(origin timestamp: UInt32) {
        last = timestamp
        origin = Int64(timestamp)
    }

    // MARK: - Computed Properties

    /// True once a first timestamp has been observed.
    public var hasOrigin: Bool { origin != nil }

    // MARK: - Public API

    /// The signed tick distance from the current high water mark to `timestamp`.
    ///
    /// Correct for distances up to ±2^31 ticks (±6.6 h at 90 kHz), far beyond any real reorder.
    /// Returns 0 before the first packet.
    public func delta(to timestamp: UInt32) -> Int32 {
        guard let last else { return 0 }
        return Int32(bitPattern: timestamp &- last)
    }

    /// True when `timestamp` is further than `thresholdTicks` from the high water mark in either
    /// direction — a stream discontinuity (a seek, an encoder restart, a channel switch), not a
    /// wrap. The caller emits `.timestampDiscontinuity` and hard-resets the presentation clock.
    public func isDiscontinuity(_ timestamp: UInt32, thresholdTicks: Int64) -> Bool {
        guard last != nil else { return false }
        return abs(Int64(delta(to: timestamp))) > thresholdTicks
    }

    /// Extends one timestamp and returns it rebased on the first value seen.
    ///
    /// Monotone for in-order input. A reordered packet returns a value below the previous one — that
    /// is the point — but never moves the cycle counter backwards.
    public mutating func extend(_ timestamp: UInt32) -> Int64 {
        let extended: Int64
        if let previous = last {
            // The extended value is always the high water mark's extended value plus the signed
            // step, so a late packet is placed correctly without any cycle bookkeeping of its own.
            let step = Int64(Int32(bitPattern: timestamp &- previous))
            extended = cycles * Self.cycle + Int64(previous) + step
            if step > 0 {
                if timestamp < previous { cycles += 1 }              // forward across the wrap
                last = timestamp                                      // advance forwards only
            }
        } else {
            extended = Int64(timestamp)
            last = timestamp
        }
        guard let origin else {
            self.origin = extended
            return 0
        }
        return extended - origin
    }

    /// Forgets all history. Called on an SSRC change, a seek or a reconnect.
    public mutating func reset() {
        cycles = 0
        last = nil
        origin = nil
    }

    /// Re-anchors the origin without forgetting the cycle count, for an `RTP-Info` seed that arrives
    /// after the first packet.
    public mutating func rebase(origin timestamp: UInt32) {
        origin = cycles * Self.cycle + Int64(timestamp)
    }
}
