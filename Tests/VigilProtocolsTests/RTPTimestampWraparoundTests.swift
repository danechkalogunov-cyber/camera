//
//  RTPTimestampWraparoundTests.swift
//  VigilProtocolsTests
//
//  The property `VigilRTP.TimestampUnwrapper` will have to preserve, asserted here against
//  `MediaTimestamp` itself: a 32-bit RTP timestamp sequence that crosses 2^32 must yield a
//  monotonically increasing media time, and a step backwards across the same boundary must not
//  become a forward jump of thirteen hours.
//  Covers docs/API_CONTRACT.md §3.3 and §2 R-26 (`VigilRTP` unwraps before building any timestamp).
//
//  `ReferenceUnwrapper` below is a *test* model of the RFC 3550 §5.1 wrap rule, not production code:
//  the shipping unwrapper is `Sources/VigilRTP/Packet/TimestampUnwrapper.swift` (W2). It exists so
//  the arithmetic contract can be pinned down before that file is written.
//

import Testing
import VigilProtocols

/// Minimal 32-bit-to-64-bit RTP timestamp unwrapper, used only by this file.
///
/// The rule is the standard one: interpret the difference from the previous raw value as a *signed*
/// 32-bit quantity, so a step of `+3000` across the 2^32 boundary reads as `+3000` and a step of
/// `-3000` reads as `-3000`, never as ±4.29 billion.
private struct ReferenceUnwrapper {

    private var previous: UInt32?
    private var epoch: Int64 = 0

    /// Returns the extended (unwrapped) timestamp for `raw`.
    mutating func unwrap(_ raw: UInt32) -> Int64 {
        defer { previous = raw }
        guard let last = previous else { return Int64(raw) }
        // 32-bit modular difference, reinterpreted as signed: this is where the wrap is absorbed.
        let delta = Int32(bitPattern: raw &- last)
        if delta >= 0, raw < last {
            epoch += 1
        } else if delta < 0, raw > last {
            epoch -= 1
        }
        return epoch * 4_294_967_296 + Int64(raw)
    }
}

@Suite struct RTPTimestampWraparoundTests {

    /// 90 kHz, 30 fps: one access unit every 3000 ticks.
    private static let tickStep: UInt32 = 3_000

    @Test func rtpTimestampSequenceCrossingTwoToThe32StaysMonotonic() {
        var unwrapper = ReferenceUnwrapper()
        // Start four frames before the wrap and run four frames past it.
        var raw = UInt32(0) &- Self.tickStep &* 4
        var timestamps: [MediaTimestamp] = []
        for _ in 0..<9 {
            timestamps.append(MediaTimestamp(value: unwrapper.unwrap(raw), timescale: 90_000))
            raw = raw &+ Self.tickStep
        }

        #expect(timestamps.count == 9)
        for (earlier, later) in zip(timestamps, timestamps.dropFirst()) {
            #expect(earlier < later, "\(earlier) must precede \(later) across the 2^32 boundary")
            #expect(later - earlier == MediaTimestamp(value: 3_000, timescale: 90_000))
        }
    }

    @Test func rtpTimestampSequenceCrossingTwoToThe32AdvancesByExactlyOneFrameEachStep() {
        var unwrapper = ReferenceUnwrapper()
        let beforeWrap = UInt32(0) &- Self.tickStep          // 4 294 964 296
        let afterWrap = UInt32(0)                            // the wrap itself
        let first = MediaTimestamp(value: unwrapper.unwrap(beforeWrap), timescale: 90_000)
        let second = MediaTimestamp(value: unwrapper.unwrap(afterWrap), timescale: 90_000)

        #expect(second.value == first.value + Int64(Self.tickStep))
        #expect((second - first).seconds == 1.0 / 30.0)
    }

    @Test func rtpTimestampStepBackwardsAcrossTheBoundaryIsNotAForwardJump() {
        var unwrapper = ReferenceUnwrapper()
        // A reordered or retransmitted packet arriving just after the wrap.
        let afterWrap = MediaTimestamp(value: unwrapper.unwrap(1_000), timescale: 90_000)
        let beforeWrap = MediaTimestamp(value: unwrapper.unwrap(UInt32.max - 2_000), timescale: 90_000)

        #expect(beforeWrap < afterWrap, "the earlier packet must stay earlier")
        let gap = afterWrap - beforeWrap
        #expect(gap.value == 3_001)
        #expect(gap.seconds < 1.0, "a backwards step must never read as a 13-hour forward jump")
    }

    @Test func rtpTimestampWithoutUnwrappingWouldRegressAtTheBoundary() {
        // The negative control: this is precisely what the unwrapper exists to prevent, and what
        // `VigilVideo` must never be shown (API_CONTRACT §2 R-26).
        let raw = [UInt32(0) &- 3_000, UInt32(0)]
        let naive = raw.map { MediaTimestamp(value: Int64($0), timescale: 90_000) }
        #expect(naive[1] < naive[0], "raw 32-bit values regress at the wrap; unwrapped ones must not")
    }

    @Test func rtpTimestampUnwrapsMultipleConsecutiveWraps() {
        var unwrapper = ReferenceUnwrapper()
        var previous = MediaTimestamp(value: unwrapper.unwrap(0), timescale: 90_000)
        var raw = UInt32(0)
        // Strides of 0x7000_0000 — 5.8 h of 90 kHz clock, just under the 2^31 point where a step
        // stops being resolvable at all — so eight of them cross the boundary three times.
        for _ in 0..<8 {
            raw = raw &+ 0x7000_0000
            let next = MediaTimestamp(value: unwrapper.unwrap(raw), timescale: 90_000)
            #expect(previous < next)
            #expect(next.value - previous.value == 0x7000_0000)
            previous = next
        }
        #expect(previous.value == 8 * Int64(0x7000_0000))
    }

    @Test func rtpTimestampUnwrappedValueSurvivesConversionToTheMP4Timescale() {
        var unwrapper = ReferenceUnwrapper()
        _ = unwrapper.unwrap(UInt32(0) &- 90_000)                 // one second before the wrap
        let extended = unwrapper.unwrap(0)
        let onVideoClock = MediaTimestamp(value: extended, timescale: 90_000)
        let onMP4Clock = onVideoClock.converted(to: 600)
        #expect(onVideoClock.value == 4_294_967_296)
        #expect(onMP4Clock.value == 28_633_115)                   // 4294967296 * 600 / 90000, rounded
        #expect(onMP4Clock.seconds > 47_721.0)
    }
}
