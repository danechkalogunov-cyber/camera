//
//  RandomSource.swift
//  VigilProtocols
//
//  Injected randomness: the protocol every jitter, nonce and probe-UUID call site takes, the system
//  implementation, and the seeded SplitMix64 generator every test and fixture uses.
//  Implements docs/API_CONTRACT.md §3.2 and §2 R-09 (`RTSPRandomSource` does not exist).
//
//  No `import Foundation`: bytes are `[UInt8]` and hex formatting reuses `Hex` from this module.
//

// MARK: - RandomSource

/// Deterministic randomness. Used for Digest `cnonce`, WS-Discovery probe UUIDs, reconnect jitter
/// and JPEG-poll jitter. `mutating` so a seeded generator advances reproducibly — that is the whole
/// point: a failing CI run prints its seed and re-running with that seed reproduces it byte for byte.
///
/// `RTSPRandomSource` does not exist (API_CONTRACT §2 R-09).
///
/// - Warning: never use a `RandomSource` for a secret. `SplitMix64RandomSource` is trivially
///   invertible and `SystemRandomSource` is the only member that is not predictable at all.
public protocol RandomSource: Sendable {

    /// The next 64 bits. Every other member of this protocol is derived from this one.
    mutating func next() -> UInt64
}

public extension RandomSource {

    /// Exactly `count` bytes.
    ///
    /// A `count` of zero or below yields an empty array. Bytes are taken least-significant-first
    /// from each 64-bit draw, so a given seed always produces the same byte string on every
    /// platform regardless of endianness.
    mutating func randomBytes(_ count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        while bytes.count < count {
            var word = next()
            for _ in 0..<8 where bytes.count < count {
                bytes.append(UInt8(truncatingIfNeeded: word))
                word >>= 8
            }
        }
        return bytes
    }

    /// `count` lowercase hex characters. `count` must be even; odd values are rounded up.
    ///
    /// A `count` of zero or below yields the empty string. Rounding up rather than down means a
    /// caller asking for 31 characters gets 32 — never a short nonce, which is the failure that
    /// would matter (RFC 7616 `cnonce` entropy).
    mutating func hexString(count: Int) -> String {
        guard count > 0 else { return "" }
        return Hex.lowercase(randomBytes((count + 1) / 2))
    }

    /// Uniform in `0..<upperBound`. `upperBound` must be > 0.
    ///
    /// Rejection-sampled so the result carries no modulo bias. An `upperBound` of 0 or 1 returns 0
    /// without drawing. The rejection loop is capped at 64 draws and then falls back to a plain
    /// remainder: an unbounded loop would let a degenerate generator (a stub that always returns the
    /// same word) hang the caller, and the residual bias after 64 rejections is under 2^-64.
    mutating func next(upperBound: UInt64) -> UInt64 {
        guard upperBound > 1 else { return 0 }
        // `(0 &- upperBound) % upperBound` is 2^64 mod upperBound: the size of the biased tail.
        let threshold = (0 &- upperBound) % upperBound
        var draw = next()
        var attempts = 0
        while draw < threshold, attempts < 64 {
            draw = next()
            attempts += 1
        }
        return draw % upperBound
    }

    /// A multiplier in `1 - fraction ... 1 + fraction`, for backoff jitter.
    ///
    /// `fraction` is clamped to `0...1`, so the multiplier is never negative and a caller cannot
    /// turn a backoff delay into a time in the past. A `fraction` of 0 returns exactly 1 and draws
    /// nothing, which keeps a "no jitter" configuration from perturbing a seeded sequence.
    mutating func jitterFactor(_ fraction: Double) -> Double {
        let bounded = Swift.min(Swift.max(fraction, 0), 1)
        guard bounded > 0 else { return 1 }
        // 53 uniform bits mapped to [0, 1): the same construction as `Double.random(in:)`.
        let unit = Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        return 1 - bounded + 2 * bounded * unit
    }
}

// MARK: - System implementation

/// The production source. Unpredictable, unseedable, and therefore never used in a test.
public struct SystemRandomSource: RandomSource {

    public init() {}

    /// - Note: `SystemRandomNumberGenerator.next()` is `mutating`, so it needs a `var` binding; it
    ///   cannot be called on the temporary returned by the initialiser.
    public mutating func next() -> UInt64 {
        var generator = SystemRandomNumberGenerator()
        return generator.next()
    }
}

// MARK: - Seeded implementation

/// Seeded, reproducible, 64-bit. The generator every test and every fixture uses.
///
/// - Note: SplitMix64, as published by Vigna. Not cryptographic; never used for a secret.
public struct SplitMix64RandomSource: RandomSource {

    /// The 64-bit state, advanced by the golden-ratio increment on every draw.
    private var state: UInt64

    /// Seeds the generator. The default seed is the one Vigna's reference code uses in its own
    /// self-test, so a fixture that omits a seed is still reproducible and still citable.
    public init(seed: UInt64 = 0x2545_F491_4F6C_DD1D) { state = seed }

    /// - Note: every `&+`, `&*` and shift here is 64-bit modular arithmetic by definition of the
    ///   algorithm, not an overflow being tolerated.
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
