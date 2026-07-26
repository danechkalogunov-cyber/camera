//
//  SequenceNumber.swift
//  VigilRTP
//
//  Modulo-2^16 RTP sequence-number arithmetic, and the unwrapper that lifts a wrapping 16-bit
//  sequence into a monotone 32-bit extended sequence.
//  Implements docs/spec-rtp.md §10.1 and docs/API_CONTRACT.md §5.5 (`Packet/SequenceNumber.swift`).
//
//  No `import` on purpose: this is integer arithmetic and needs no Foundation.
//

// MARK: - Modular comparison

/// True when `a` precedes `b` in modulo-2^16 sequence space.
///
/// This is the only correct way to order RTP sequence numbers. `a < b` is wrong: it stalls a
/// reorder buffer permanently the first time the sequence crosses 65535, which at 50 packets per
/// second happens every ~22 minutes. `Int(a) - Int(b)` is equally wrong for the same reason.
///
/// The half-space at distance exactly 32768 is ambiguous by definition — `seqLess(0, 0x8000)` is
/// `true` and `seqLess(0x8000, 0)` is `false`. No real stream reorders that far, and the reorder
/// buffer's capacity bound (≤ 4096) keeps the ambiguity unreachable in practice.
@inlinable public func seqLess(_ a: UInt16, _ b: UInt16) -> Bool {
    Int16(bitPattern: a &- b) < 0
}

/// True when `a` precedes or equals `b` in modulo-2^16 sequence space.
@inlinable public func seqLessOrEqual(_ a: UInt16, _ b: UInt16) -> Bool {
    Int16(bitPattern: a &- b) <= 0
}

/// True when `a` follows `b` in modulo-2^16 sequence space.
@inlinable public func seqGreater(_ a: UInt16, _ b: UInt16) -> Bool {
    Int16(bitPattern: a &- b) > 0
}

/// The signed distance `a - b` across the wrap, in `-32768...32767`.
///
/// Positive when `a` follows `b`. Correct across 65535 → 0: `seqDiff(1, 65535) == 2`.
@inlinable public func seqDiff(_ a: UInt16, _ b: UInt16) -> Int32 {
    Int32(Int16(bitPattern: a &- b))
}

/// The number of sequence numbers in the half-open interval `first ..< end`, counted forward across
/// the wrap. Returns 0 when `end` does not follow `first`.
@inlinable public func seqSpan(from first: UInt16, to end: UInt16) -> Int {
    let d = seqDiff(end, first)
    return d > 0 ? Int(d) : 0
}

// MARK: - Gap ranges

/// The lost sequence numbers between `first` and `end`, expressed as `ClosedRange<UInt16>` values.
///
/// A gap that straddles the wrap cannot be one `ClosedRange` — `65534...0` is not constructible and
/// would trap — so it is returned as two ranges, `65534...65535` and `0...0`. Callers that only need
/// the count should use `seqSpan(from:to:)`; the ranges exist so a log line can name the packets.
///
/// Returns an empty array when nothing is missing.
public func seqGapRanges(from first: UInt16, to end: UInt16) -> [ClosedRange<UInt16>] {
    let span = seqSpan(from: first, to: end)
    guard span > 0 else { return [] }
    let last = end &- 1
    if first <= last {
        return [first...last]
    }
    // The run wrapped: split at the 65535 → 0 boundary so both halves are valid ranges.
    return [first...UInt16.max, 0...last]
}

// MARK: - Extended sequence

/// Lifts a wrapping 16-bit sequence number into a monotone 32-bit extended sequence.
///
/// Used for `EncodedFrame.sequenceRange`, which must stay ordered across the wrap so a caller can
/// subtract two frames' ranges. `RTPSourceState` keeps its own RFC 3550 A.1 cycle counter for the
/// Receiver Report's *extended highest sequence number* field; the two are deliberately separate,
/// because A.1 also implements probation and restart detection that this type must not.
///
/// A packet older than the first one ever seen extends to a value that wrapped below zero (a very
/// large `UInt32`). That is unavoidable without a bias, is harmless for range arithmetic, and is
/// documented rather than clamped so the value stays consistent under subtraction.
public struct SequenceUnwrapper: Sendable {

    /// Completed 65536-wide cycles observed so far.
    private var cycles: UInt32 = 0

    /// The highest sequence number seen, in wrapped form. `nil` before the first packet.
    private var highest: UInt16?

    /// Creates an unwrapper that has seen nothing.
    public init() {}

    /// The extended form of the highest sequence number seen, or `nil` before the first packet.
    public var extendedHighest: UInt32? {
        guard let highest else { return nil }
        return (cycles << 16) | UInt32(highest)
    }

    /// Extends one sequence number and advances the cycle counter when it moves forward past a wrap.
    ///
    /// Reordered packets (those preceding `highest`) are extended relative to the current high
    /// water mark and do **not** move it, so a single late packet cannot rewind the cycle count.
    public mutating func extend(_ sequence: UInt16) -> UInt32 {
        guard let previous = highest else {
            highest = sequence
            return UInt32(sequence)
        }
        let base = Int32(bitPattern: (cycles << 16) | UInt32(previous))
        let extended = UInt32(bitPattern: base &+ seqDiff(sequence, previous))
        if seqGreater(sequence, previous) {
            if sequence < previous { cycles &+= 1 }     // plain `<` is right: forward motion is proven
            highest = sequence
        }
        return extended
    }

    /// Forgets all history. Called on an SSRC change, a seek or a reconnect.
    public mutating func reset() {
        cycles = 0
        highest = nil
    }
}
