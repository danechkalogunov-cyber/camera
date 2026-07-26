//
//  MediaTimestamp.swift
//  VigilProtocols
//
//  Rational media time — the CoreMedia-free replacement for `CMTime` — plus the 128-bit division
//  helper its exact rescale is built on.
//  Implements docs/API_CONTRACT.md §3.3 and §2 R-05 (a non-positive timescale clamps, never traps).
//
//  No `import` on purpose: fixed-width integer arithmetic needs nothing from Foundation.
//

// MARK: - MediaTimestamp

/// A rational media time: `value / timescale` seconds. Deliberately mirrors `CMTime`'s semantics
/// without importing CoreMedia, so the pure layer stays Linux-buildable.
///
/// - Important: the initialiser **clamps** a non-positive timescale to 1 rather than trapping.
///   `timescale` derives from the SDP `a=rtpmap` clock rate, which is network data; a camera (or an
///   attacker on the LAN) advertising `H264/0` must not be able to take the app down. Clock-rate
///   validation happens once, at `RTPTrackFormat` construction, which throws
///   `RTPError.invalidClockRate`. See API_CONTRACT §2 R-05.
///
/// - Note: like `CMTime`, equality is on the *raw pair*, not on the rational value: `1/2` and `2/4`
///   are ordered equally by `<` but are not `==`. Compare with `<`/`>` when you mean "the same
///   instant"; use `==` only when you mean "the same representation".
public struct MediaTimestamp: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {

    // MARK: - Stored Properties

    /// Numerator, in units of `1 / timescale` seconds.
    public var value: Int64

    /// Denominator. Always > 0 after initialisation. 90 000 for RTP video; the sample rate for
    /// audio; 1 000 000 for host-time conversions; 600 for recorded MP4 tracks.
    public private(set) var timescale: Int32

    // MARK: - Initialisation

    /// The sentinel for "no time". Distinguished from `.zero`, which is a real instant.
    public static let invalid = MediaTimestamp(value: .min, timescale: 1)

    /// The origin of a stream's own timeline.
    public static let zero = MediaTimestamp(value: 0, timescale: 1)

    /// Builds a timestamp, clamping a non-positive `timescale` to 1 (API_CONTRACT §2 R-05).
    public init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale > 0 ? timescale : 1
    }

    /// Fails rather than clamps. Use at every boundary where a bad timescale is a protocol error
    /// you want to report instead of absorb.
    public init?(validating value: Int64, timescale: Int32) {
        guard timescale > 0 else { return nil }
        self.init(value: value, timescale: timescale)
    }

    // MARK: - Computed Properties

    /// The time in seconds. Display and logging only — rescaling through `Double` loses
    /// sub-microsecond precision long before `converted(to:)` does.
    @inlinable public var seconds: Double { Double(value) / Double(timescale) }

    /// False only for `.invalid`. A timestamp with a legal timescale is always valid.
    @inlinable public var isValid: Bool { self != .invalid }

    // MARK: - Public API

    /// Exact rescale using 128-bit intermediate arithmetic; rounds half away from zero and
    /// saturates rather than overflowing.
    ///
    /// `.invalid` converts to `.invalid`. A non-positive `newTimescale` is clamped to 1 exactly as
    /// the initialiser does, so this can never trap on network-derived input. A magnitude that
    /// cannot be represented at the new timescale saturates at `Int64.max` / `Int64.min + 1`,
    /// keeping the sign and staying distinguishable from `.invalid`.
    ///
    /// - Warning: never rescale through `Double`. At a 1/1_000_000 timescale, recorded playback
    ///   exceeds 2^53 within 285 years but loses sub-microsecond precision far sooner, and seek
    ///   accuracy is a user-visible feature.
    public func converted(to newTimescale: Int32) -> MediaTimestamp {
        guard isValid else { return .invalid }
        let target = newTimescale > 0 ? newTimescale : 1
        if target == timescale { return MediaTimestamp(value: value, timescale: target) }
        // 128-bit: |value| × target, then divide by the old timescale with half of it added in,
        // which is round-half-away-from-zero once the sign is restored below.
        let (hi, lo) = value.magnitude.multipliedFullWidth(by: UInt64(target))
        let half = UInt64(timescale) / 2
        let (quotient, _) = UInt64.divideWithOverflowGuard(
            hi: hi, lo: lo, by: UInt64(timescale), addend: half)
        let magnitude = Int64(clamping: quotient)
        return MediaTimestamp(value: value < 0 ? -magnitude : magnitude, timescale: target)
    }

    /// Adds `samples` in the receiver's own timescale.
    ///
    /// Uses `&+` (64-bit wrap) deliberately: the caller is stepping a sample counter that the RTP
    /// layer has already unwrapped, and a trap here would be reachable from a hostile stream.
    @inlinable public func adding(samples: Int64) -> MediaTimestamp {
        MediaTimestamp(value: value &+ samples, timescale: timescale)
    }

    /// Sum in the *receiver's* timescale. `.invalid` is absorbing.
    ///
    /// `b` is rescaled to `a`'s timescale first, so the result's timescale is always `a.timescale`.
    /// Overflow saturates toward the sign of `a`.
    public static func + (a: Self, b: Self) -> Self {
        guard a.isValid, b.isValid else { return .invalid }
        let rhs = b.converted(to: a.timescale)
        let (sum, overflow) = a.value.addingReportingOverflow(rhs.value)
        guard !overflow else { return saturated(negative: a.value < 0, timescale: a.timescale) }
        return MediaTimestamp(value: sum, timescale: a.timescale)
    }

    /// Difference in the *receiver's* timescale. `.invalid` is absorbing.
    public static func - (a: Self, b: Self) -> Self {
        guard a.isValid, b.isValid else { return .invalid }
        let rhs = b.converted(to: a.timescale)
        let (difference, overflow) = a.value.subtractingReportingOverflow(rhs.value)
        guard !overflow else { return saturated(negative: a.value < 0, timescale: a.timescale) }
        return MediaTimestamp(value: difference, timescale: a.timescale)
    }

    // MARK: - Comparable

    /// Cross-multiplied 128-bit comparison. Explicit `(high, low)` lexicographic compare —
    /// do not rely on tuple `<`, which compares element-wise on signed halves and is wrong here.
    ///
    /// `.invalid` sorts before every other timestamp, which is what a sort of mixed valid and
    /// missing times wants.
    public static func < (a: Self, b: Self) -> Bool {
        if a.timescale == b.timescale { return a.value < b.value }
        let lhs = a.value.multipliedFullWidth(by: Int64(b.timescale))
        let rhs = b.value.multipliedFullWidth(by: Int64(a.timescale))
        // `high` is signed and `low` is not: compare the signed halves first, then the raw bits.
        if lhs.high != rhs.high { return lhs.high < rhs.high }
        return lhs.low < rhs.low
    }

    // MARK: - CustomStringConvertible

    /// `"90000/90000 (1.0s)"`. Diagnostic only; not a stable format.
    public var description: String { "\(value)/\(timescale) (\(seconds)s)" }

    // MARK: - Private Helpers

    /// The largest representable magnitude with the given sign. The negative extreme is
    /// `Int64.min + 1`, not `Int64.min`, so a saturated result never collides with `.invalid`.
    private static func saturated(negative: Bool, timescale: Int32) -> MediaTimestamp {
        MediaTimestamp(value: negative ? .min + 1 : .max, timescale: timescale)
    }

    // MARK: - Codable

    /// Persisted as `{"value": …, "timescale": …}`. Keys are spelled out because recorded-clip and
    /// library fixtures depend on them (API_CONTRACT §7.3).
    private enum CodingKeys: String, CodingKey {
        case value
        case timescale
    }

    /// Decodes through the clamping initialiser, so a persisted or injected `timescale` of `0`
    /// yields a timescale of 1 rather than a value that violates the type's invariant.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(value: try container.decode(Int64.self, forKey: .value),
                  timescale: try container.decode(Int32.self, forKey: .timescale))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(timescale, forKey: .timescale)
    }
}

// MARK: - 128-bit division

public extension UInt64 {

    /// 128-by-64 division with saturation on overflow. `addend` is added to the 128-bit dividend
    /// before dividing (used to implement round-half-away-from-zero).
    ///
    /// Saturates — and never traps — in all three degenerate cases: a zero divisor, a dividend whose
    /// top half overflows while `addend` is folded in, and a quotient that does not fit in 64 bits.
    /// The last is exactly `hi >= divisor`, which is also `dividingFullWidth`'s precondition.
    ///
    /// - Returns: `(quotient, didSaturate)`. On saturation the quotient is `UInt64.max`.
    static func divideWithOverflowGuard(hi: UInt64, lo: UInt64, by divisor: UInt64,
                                        addend: UInt64) -> (quotient: UInt64, didSaturate: Bool) {
        guard divisor != 0 else { return (.max, true) }
        var high = hi
        let (low, carry) = lo.addingReportingOverflow(addend)
        if carry {
            let (raised, overflow) = high.addingReportingOverflow(1)
            guard !overflow else { return (.max, true) }
            high = raised
        }
        guard high < divisor else { return (.max, true) }
        let (quotient, _) = divisor.dividingFullWidth((high: high, low: low))
        return (quotient, false)
    }
}
