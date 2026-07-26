//
//  RecordingTimelineTests.swift
//  VigilVideoTests
//
//  The timestamp rebasing: the session-start value, the gaps that must survive into the file, the
//  jumps that must not, and the monotonicity clamp.
//  Covers Sources/VigilVideo/Recording/RecordingTimeline.swift.
//
//  `CMTime` is a plain struct, so this is pure arithmetic and runs identically on macOS and in the
//  Linux shadow harness under scratchpad/shadow-recording, which is where these were executed.
//
//  Equality is asserted through `CMTimeCompare` or through the `value`/`timescale` pair rather than
//  through `==`: the CoreMedia overlay's `==` compares *rational values*, so `1/2 == 2/4`, and a test
//  that means "exactly this representation" has to say so.
//

#if os(macOS)

import CoreMedia
import Testing
import VigilVideo

// MARK: - Support

/// The RTP video timescale every Hikvision profile uses.
private let recordingTimelineScale: CMTimeScale = 90_000

/// A 90 kHz time.
private func recordingTimelineTime(_ ticks: Int64) -> CMTime {
    CMTime(value: ticks, timescale: recordingTimelineScale)
}

/// One frame at 30 fps in 90 kHz ticks.
private let recordingTimelineFrame: Int64 = 3_000

/// True when the two times denote the same instant.
private func recordingTimelineSame(_ a: CMTime, _ b: CMTime) -> Bool {
    CMTimeCompare(a, b) == 0
}

/// Admits one sample and returns its timing, or `nil` for anything else.
private func recordingTimelineAdmit(_ timeline: inout RecordingTimeline, pts: Int64,
                                   duration: Int64 = recordingTimelineFrame)
    -> RecordingSampleTiming? {
    switch timeline.admit(presentation: recordingTimelineTime(pts),
                          decode: CMTime.invalid,
                          duration: recordingTimelineTime(duration)) {
    case .write(let timing, _): timing
    default: nil
    }
}

// MARK: - Session start

@Test func recordingTimelineStartsTheSessionAtTheFirstSamplesOwnTimestamp() throws {
    // An RTP stream starts at an arbitrary 32-bit value. This one is nine and a bit hours in.
    var timeline = RecordingTimeline()
    let first = try #require(recordingTimelineAdmit(&timeline, pts: 3_000_000_000))

    // Rebased, so the file starts at zero — and `sessionStart` is that value, computed from the
    // sample. Handing `AVAssetWriter.startSession` a hardcoded zero while appending unrebased
    // samples is the trap: the file would claim its media begins 9 h 15 m in.
    #expect(first.presentation.value == 0)
    #expect(first.presentation.timescale == recordingTimelineScale)
    let sessionStart = try #require(timeline.sessionStart)
    #expect(recordingTimelineSame(sessionStart, first.presentation))
    #expect(timeline.admittedCount == 1)
}

@Test func recordingTimelineWithoutRebasingStartsTheSessionAtTheRawTimestamp() throws {
    var timeline = RecordingTimeline(rebaseToZero: false)
    let first = try #require(recordingTimelineAdmit(&timeline, pts: 3_000_000_000))
    #expect(first.presentation.value == 3_000_000_000)
    let sessionStart = try #require(timeline.sessionStart)
    #expect(recordingTimelineSame(sessionStart, recordingTimelineTime(3_000_000_000)))
}

@Test func recordingTimelineReportsTheSessionEndAtTheEndOfTheLastSample() throws {
    var timeline = RecordingTimeline()
    _ = recordingTimelineAdmit(&timeline, pts: 1_000_000)
    _ = recordingTimelineAdmit(&timeline, pts: 1_000_000 + recordingTimelineFrame)
    // Two frames written: the session ends one frame duration after the second one starts, not at
    // its start — ending at the start truncates the final frame to zero length.
    let end = try #require(timeline.sessionEnd)
    #expect(recordingTimelineSame(end, recordingTimelineTime(2 * recordingTimelineFrame)))
    #expect(abs(timeline.writtenSeconds - 2.0 / 30.0) < 1e-9)
}

// MARK: - Gaps that must be preserved

@Test func recordingTimelinePreservesAFourSecondDropoutAsRealDuration() throws {
    // F-REC-01 acceptance 4: a ten-minute recording with a four-second dropout is ten minutes long.
    // Collapsing the gap would make the file shorter than the events it recorded.
    var timeline = RecordingTimeline()
    _ = recordingTimelineAdmit(&timeline, pts: 0)
    let after = try #require(recordingTimelineAdmit(&timeline, pts: 4 * 90_000))
    #expect(recordingTimelineSame(after.presentation, recordingTimelineTime(4 * 90_000)))
}

@Test func recordingTimelinePreservesAGapExactlyAtTheTolerance() throws {
    var timeline = RecordingTimeline()
    _ = recordingTimelineAdmit(&timeline, pts: 0)
    // Ten seconds is the boundary and is still a dropout, not a discontinuity.
    switch timeline.admit(presentation: recordingTimelineTime(10 * 90_000),
                          decode: CMTime.invalid,
                          duration: recordingTimelineTime(recordingTimelineFrame)) {
    case .write(let timing, let discontinuity):
        #expect(discontinuity == nil)
        #expect(recordingTimelineSame(timing.presentation, recordingTimelineTime(10 * 90_000)))
    default:
        Issue.record("a ten-second gap must still be written")
    }
}

// MARK: - Jumps that must not be preserved

@Test func recordingTimelineCollapsesALargeForwardJumpAndReportsIt() throws {
    var timeline = RecordingTimeline()
    _ = recordingTimelineAdmit(&timeline, pts: 0)
    // The camera's clock resynchronised: a 30 s jump. Writing it verbatim gives the file a 30 s
    // frozen frame, which every player renders as a hang.
    switch timeline.admit(presentation: recordingTimelineTime(30 * 90_000),
                          decode: CMTime.invalid,
                          duration: recordingTimelineTime(recordingTimelineFrame)) {
    case .write(let timing, let discontinuity):
        #expect(discontinuity == .epochShifted(gapSeconds: 30))
        // Advanced by exactly one nominal frame instead of by thirty seconds.
        #expect(recordingTimelineSame(timing.presentation,
                                      recordingTimelineTime(recordingTimelineFrame)))
    default:
        Issue.record("a large jump must still be written, after the epoch is shifted")
    }
}

@Test func recordingTimelineKeepsTheShiftedEpochForEverySubsequentSample() throws {
    var timeline = RecordingTimeline()
    _ = recordingTimelineAdmit(&timeline, pts: 0)
    _ = recordingTimelineAdmit(&timeline, pts: 30 * 90_000)
    // The correction is an offset, not a one-off fix-up: the next sample continues from the
    // collapsed position rather than jumping back to thirty seconds.
    let third = try #require(recordingTimelineAdmit(&timeline,
                                                    pts: 30 * 90_000 + recordingTimelineFrame))
    #expect(recordingTimelineSame(third.presentation,
                                  recordingTimelineTime(2 * recordingTimelineFrame)))
}

@Test func recordingTimelineDemandsANewSegmentForAJumpOverTheSplitThreshold() {
    var timeline = RecordingTimeline()
    _ = recordingTimelineAdmit(&timeline, pts: 0)
    switch timeline.admit(presentation: recordingTimelineTime(61 * 90_000),
                          decode: CMTime.invalid,
                          duration: recordingTimelineTime(recordingTimelineFrame)) {
    case .requiresNewSegment(let gapSeconds):
        #expect(abs(gapSeconds - 61) < 1e-6)
    default:
        Issue.record("a 61 s jump is a different recording, not a dropout")
    }
    // Rejected without being recorded, so the state is unchanged and the caller can rotate.
    #expect(timeline.admittedCount == 1)
}

// MARK: - Monotonicity

@Test func recordingTimelineClampsABackwardsTimestampAndReportsIt() {
    var timeline = RecordingTimeline()
    _ = recordingTimelineAdmit(&timeline, pts: 90_000)
    switch timeline.admit(presentation: recordingTimelineTime(45_000),
                          decode: CMTime.invalid,
                          duration: recordingTimelineTime(recordingTimelineFrame)) {
    case .write(let timing, let discontinuity):
        // A file needs strictly increasing presentation times; `append` fails otherwise and the
        // failure surfaces as a truncated file rather than as an error the user sees.
        #expect(timing.presentation.value == 1)
        #expect(timing.presentation.timescale == recordingTimelineScale)
        #expect(discontinuity == .nonMonotonic(rawGapSeconds: -0.5))
    default:
        Issue.record("a backwards timestamp is clamped, not dropped")
    }
}

@Test func recordingTimelineClampsARepeatedTimestamp() {
    var timeline = RecordingTimeline()
    _ = recordingTimelineAdmit(&timeline, pts: 90_000)
    switch timeline.admit(presentation: recordingTimelineTime(90_000),
                          decode: CMTime.invalid,
                          duration: recordingTimelineTime(recordingTimelineFrame)) {
    case .write(let timing, let discontinuity):
        #expect(timing.presentation.value == 1)
        #expect(discontinuity == .nonMonotonic(rawGapSeconds: 0))
    default:
        Issue.record("a repeated timestamp is clamped, not dropped")
    }
}

// MARK: - Rejections

@Test func recordingTimelineRejectsAnInvalidTimestamp() {
    var timeline = RecordingTimeline()
    let outcome = timeline.admit(presentation: CMTime.invalid, decode: CMTime.invalid,
                                 duration: recordingTimelineTime(recordingTimelineFrame))
    #expect(outcome == .rejectInvalidTimestamp)
    #expect(timeline.sessionStart == nil)
}

@Test func recordingTimelineRejectsAnIndefiniteTimestamp() {
    var timeline = RecordingTimeline()
    let outcome = timeline.admit(presentation: CMTime.indefinite, decode: CMTime.invalid,
                                 duration: recordingTimelineTime(recordingTimelineFrame))
    #expect(outcome == .rejectInvalidTimestamp)
}

// MARK: - Durations

@Test func recordingTimelineSubstitutesTheNominalDurationForANonPositiveOne() throws {
    var timeline = RecordingTimeline()
    switch timeline.admit(presentation: recordingTimelineTime(0), decode: CMTime.invalid,
                          duration: CMTime.zero) {
    case .write(let timing, _):
        // A zero duration makes the last sample of the file zero-length, which `AVAssetReader`
        // reports as a truncated track.
        #expect(recordingTimelineSame(timing.duration,
                                      recordingTimelineTime(recordingTimelineFrame)))
    default:
        Issue.record("a zero duration is substituted, not rejected")
    }
    let end = try #require(timeline.sessionEnd)
    #expect(recordingTimelineSame(end, recordingTimelineTime(recordingTimelineFrame)))
}

@Test func recordingTimelineSubstitutesTheNominalDurationForAnInvalidOne() {
    var timeline = RecordingTimeline()
    switch timeline.admit(presentation: recordingTimelineTime(0), decode: CMTime.invalid,
                          duration: CMTime.invalid) {
    case .write(let timing, _):
        #expect(recordingTimelineSame(timing.duration,
                                      recordingTimelineTime(recordingTimelineFrame)))
    default:
        Issue.record("an invalid duration is substituted, not rejected")
    }
}

// MARK: - Decode timestamps

@Test func recordingTimelineRebasesAValidDecodeTimestamp() {
    var timeline = RecordingTimeline()
    _ = timeline.admit(presentation: recordingTimelineTime(90_000),
                       decode: recordingTimelineTime(90_000),
                       duration: recordingTimelineTime(recordingTimelineFrame))
    switch timeline.admit(presentation: recordingTimelineTime(90_000 + recordingTimelineFrame),
                          decode: recordingTimelineTime(90_000 + 1_000),
                          duration: recordingTimelineTime(recordingTimelineFrame)) {
    case .write(let timing, _):
        #expect(recordingTimelineSame(timing.decode, recordingTimelineTime(1_000)))
    default:
        Issue.record("a valid DTS is rebased alongside the PTS")
    }
}

@Test func recordingTimelineDropsADecodeTimestampThatFollowsItsPresentationTime() {
    var timeline = RecordingTimeline()
    // A DTS after its own PTS is nonsense that AVAssetWriter rejects. The right answer is to drop
    // the claim — `.invalid` means "decode order equals presentation order" — not to invent one.
    switch timeline.admit(presentation: recordingTimelineTime(0),
                          decode: recordingTimelineTime(90_000),
                          duration: recordingTimelineTime(recordingTimelineFrame)) {
    case .write(let timing, _):
        #expect(!timing.decode.isNumeric)
    default:
        Issue.record("an impossible DTS is dropped, not rejected")
    }
}

@Test func recordingTimelinePassesAnInvalidDecodeTimestampThrough() {
    var timeline = RecordingTimeline()
    // Every Hikvision live profile has no B-frames and therefore no DTS at all.
    switch timeline.admit(presentation: recordingTimelineTime(0), decode: CMTime.invalid,
                          duration: recordingTimelineTime(recordingTimelineFrame)) {
    case .write(let timing, _):
        #expect(!timing.decode.isNumeric)
    default:
        Issue.record("a missing DTS is normal")
    }
}

// MARK: - Reset

@Test func recordingTimelineResetMakesTheNextSegmentStartAtItsOwnZero() throws {
    var timeline = RecordingTimeline()
    _ = recordingTimelineAdmit(&timeline, pts: 1_000_000)
    _ = recordingTimelineAdmit(&timeline, pts: 1_000_000 + recordingTimelineFrame)
    timeline.reset()

    #expect(timeline.sessionStart == nil)
    #expect(timeline.sessionEnd == nil)
    #expect(timeline.admittedCount == 0)
    #expect(timeline.writtenSeconds == 0)

    let first = try #require(recordingTimelineAdmit(&timeline, pts: 5_000_000))
    #expect(first.presentation.value == 0)
}

#endif
