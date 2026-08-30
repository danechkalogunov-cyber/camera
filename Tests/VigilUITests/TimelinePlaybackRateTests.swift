//
//  TimelinePlaybackRateTests.swift
//  VigilUITests
//
//  The speed ladder: the wire scales, the audio/keyframe policy each stop implies, the shuttle and
//  forward steppers, and the invertible slider mapping the type's own doc promises "asserted by a
//  test" — until now there was none.
//

#if os(macOS)

import Foundation
import Testing

@testable import VigilUI

@Suite("Timeline playback rate")
struct TimelinePlaybackRateTests {

    // MARK: - Wire scale

    @Test func everyStopMapsToItsWireScale() {
        #expect(TimelinePlaybackRate.reverseEight.scale == -8)
        #expect(TimelinePlaybackRate.reverseFour.scale == -4)
        #expect(TimelinePlaybackRate.reverseTwo.scale == -2)
        #expect(TimelinePlaybackRate.reverseOne.scale == -1)
        #expect(TimelinePlaybackRate.quarter.scale == 0.25)
        #expect(TimelinePlaybackRate.half.scale == 0.5)
        #expect(TimelinePlaybackRate.normal.scale == 1)
        #expect(TimelinePlaybackRate.double.scale == 2)
        #expect(TimelinePlaybackRate.quadruple.scale == 4)
        #expect(TimelinePlaybackRate.octuple.scale == 8)
    }

    @Test func reverseIsEveryNegativeScale() {
        for rate in TimelinePlaybackRate.allCases {
            #expect(rate.isReverse == (rate.scale < 0))
        }
    }

    // MARK: - Policy

    /// UX.md §7.5: audio mutes above 2×, and reverse is always muted.
    @Test func audioMutesAboveTwoTimesAndInReverse() {
        #expect(!TimelinePlaybackRate.normal.mutesAudio)
        #expect(!TimelinePlaybackRate.double.mutesAudio)  // exactly 2× still has audio
        #expect(TimelinePlaybackRate.quadruple.mutesAudio)
        #expect(TimelinePlaybackRate.octuple.mutesAudio)
        #expect(TimelinePlaybackRate.reverseOne.mutesAudio)
        #expect(TimelinePlaybackRate.reverseEight.mutesAudio)
    }

    /// FEATURES.md §13: non-reference frames drop above 2× in either direction.
    @Test func nonReferenceFramesDropAboveTwoTimesEitherWay() {
        #expect(!TimelinePlaybackRate.double.dropsNonReferenceFrames)  // |2| not > 2
        #expect(!TimelinePlaybackRate.reverseTwo.dropsNonReferenceFrames)  // |-2| not > 2
        #expect(TimelinePlaybackRate.quadruple.dropsNonReferenceFrames)
        #expect(TimelinePlaybackRate.reverseFour.dropsNonReferenceFrames)
    }

    // MARK: - Stepping

    @Test func fasterAndSlowerWalkTheForwardLadderAndClamp() {
        #expect(TimelinePlaybackRate.normal.faster == .double)
        #expect(TimelinePlaybackRate.double.faster == .quadruple)
        #expect(TimelinePlaybackRate.octuple.faster == .octuple)  // clamped at the top
        #expect(TimelinePlaybackRate.normal.slower == .half)
        #expect(TimelinePlaybackRate.quarter.slower == .quarter)  // clamped at the bottom
    }

    @Test func theShuttleWalksItsOwnLadderAndClamps() {
        #expect(TimelinePlaybackRate.normal.shuttled(by: 1) == .double)
        #expect(TimelinePlaybackRate.normal.shuttled(by: -1) == .reverseOne)
        #expect(TimelinePlaybackRate.octuple.shuttled(by: 1) == .octuple)
        #expect(TimelinePlaybackRate.reverseEight.shuttled(by: -1) == .reverseEight)
    }

    /// A rate not on the shuttle ladder (¼× or ½×) enters it at the nearest stop by scale, so a press
    /// does something rather than nothing (the type's own example: ½× + L → 2×).
    @Test func aRateOffTheShuttleLadderEntersAtTheNearestStop() {
        #expect(TimelinePlaybackRate.half.shuttled(by: 1) == .double)
        #expect(TimelinePlaybackRate.half.shuttled(by: -1) == .reverseOne)
        #expect(TimelinePlaybackRate.quarter.shuttled(by: 1) == .double)
    }

    // MARK: - Nearest

    /// Ties go to the slower stop, because overshooting a requested speed is the more surprising
    /// error.
    @Test func nearestBreaksTiesTowardTheSlowerStop() {
        // 3 is equidistant from 2 and 4; the slower (2×) wins.
        #expect(
            TimelinePlaybackRate.nearest(toScale: 3, in: TimelinePlaybackRate.forwardStops)
                == .double)
        #expect(
            TimelinePlaybackRate.nearest(toScale: 0.4, in: TimelinePlaybackRate.forwardStops)
                == .half)
    }

    // MARK: - Slider mapping

    @Test func theForwardStopsAreAtEqualSliderIntervals() {
        #expect(TimelinePlaybackRate.quarter.sliderPosition == 0)
        #expect(TimelinePlaybackRate.octuple.sliderPosition == 1)
        #expect(abs(TimelinePlaybackRate.normal.sliderPosition - 0.4) < 1e-9)
    }

    /// The knob returns to where it was put for every forward stop — the property §7.5 needs and the
    /// one this test exists to guarantee.
    @Test func theSliderMappingIsInvertibleForEveryForwardStop() {
        for stop in TimelinePlaybackRate.forwardStops {
            #expect(TimelinePlaybackRate(sliderPosition: stop.sliderPosition) == stop)
        }
    }

    @Test func aSliderPositionClampsAndAnInfiniteOneFallsBackToNormal() {
        #expect(TimelinePlaybackRate(sliderPosition: -5) == .quarter)
        #expect(TimelinePlaybackRate(sliderPosition: 5) == .octuple)
        #expect(TimelinePlaybackRate(sliderPosition: .nan) == .normal)
    }

    // MARK: - Ordering

    @Test func comparableRunsBySignedScale() {
        #expect(TimelinePlaybackRate.reverseEight < TimelinePlaybackRate.reverseOne)
        #expect(TimelinePlaybackRate.reverseOne < TimelinePlaybackRate.quarter)
        #expect(TimelinePlaybackRate.normal < TimelinePlaybackRate.octuple)
    }
}

#endif  // os(macOS)
