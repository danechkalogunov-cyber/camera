//
//  RecordingSegmentPlannerTests.swift
//  VigilVideoTests
//
//  The rotation arithmetic, and the one rule that matters most: a segment closes on a keyframe
//  boundary, never on a limit being reached.
//  Covers Sources/VigilVideo/Recording/RecordingSegmentPlanner.swift.
//
//  Every case here is pure arithmetic with no CoreMedia object in it, so these run identically on the
//  customer's Mac and in the Linux shadow harness under scratchpad/shadow-recording — which is where
//  they were actually executed, because on Linux this whole file preprocesses to nothing.
//

#if os(macOS)

import Testing
import VigilVideo

// MARK: - Limits

@Test func recordingSegmentPlannerWritesWhileUnderEveryLimit() {
    var planner = RecordingSegmentPlanner()
    #expect(planner.evaluate(isKeyframe: false, writtenSeconds: 0, writtenBytes: 0) == .write)
    #expect(planner.evaluate(isKeyframe: true, writtenSeconds: 10, writtenBytes: 1_000) == .write)
    #expect(planner.segmentIndex == 0)
    #expect(!planner.isAwaitingKeyframeToRotate)
}

@Test func recordingSegmentPlannerArmsOnDurationButDoesNotRotateWithoutAKeyframe() {
    let limits = RecordingSegmentPlanner.Limits(maximumSeconds: 30, maximumBytes: .max)
    var planner = RecordingSegmentPlanner(limits: limits)

    // The limit is reached on a non-keyframe. The file must stay open: closing here would give the
    // next file a P-frame for its first sample, which is the unplayable-file failure.
    #expect(planner.evaluate(isKeyframe: false, writtenSeconds: 30, writtenBytes: 0) == .write)
    #expect(planner.isAwaitingKeyframeToRotate)
    #expect(planner.pendingReason == .durationLimit)
    #expect(planner.segmentIndex == 0)

    // Still no keyframe, twelve seconds over the limit: still open.
    #expect(planner.evaluate(isKeyframe: false, writtenSeconds: 42, writtenBytes: 0) == .write)
    #expect(planner.segmentIndex == 0)

    // The keyframe is what rotates.
    #expect(planner.evaluate(isKeyframe: true, writtenSeconds: 42, writtenBytes: 0)
            == .rotate(.durationLimit))
    #expect(planner.segmentIndex == 1)
    #expect(!planner.isAwaitingKeyframeToRotate)
}

@Test func recordingSegmentPlannerRotatesImmediatelyWhenTheLimitIsReachedOnAKeyframe() {
    let limits = RecordingSegmentPlanner.Limits(maximumSeconds: 30, maximumBytes: .max)
    var planner = RecordingSegmentPlanner(limits: limits)
    #expect(planner.evaluate(isKeyframe: true, writtenSeconds: 30, writtenBytes: 0)
            == .rotate(.durationLimit))
    #expect(planner.segmentIndex == 1)
}

@Test func recordingSegmentPlannerArmsOnTheByteLimit() {
    let limits = RecordingSegmentPlanner.Limits(maximumSeconds: .infinity,
                                                maximumBytes: 3_758_096_384)
    var planner = RecordingSegmentPlanner(limits: limits)
    #expect(planner.evaluate(isKeyframe: false, writtenSeconds: 5,
                             writtenBytes: 3_758_096_383) == .write)
    #expect(!planner.isAwaitingKeyframeToRotate)
    #expect(planner.evaluate(isKeyframe: false, writtenSeconds: 5,
                             writtenBytes: 3_758_096_384) == .write)
    #expect(planner.pendingReason == .sizeLimit)
}

@Test func recordingSegmentPlannerTreatsTheDurationLimitAsInclusive() {
    // The boundary itself rotates. A strictly-greater test would let every file run one GOP long.
    let limits = RecordingSegmentPlanner.Limits(maximumSeconds: 1_800, maximumBytes: .max)
    var planner = RecordingSegmentPlanner(limits: limits)
    #expect(planner.evaluate(isKeyframe: true, writtenSeconds: 1_799.999, writtenBytes: 0) == .write)
    #expect(planner.evaluate(isKeyframe: true, writtenSeconds: 1_800, writtenBytes: 0)
            == .rotate(.durationLimit))
}

@Test func recordingSegmentPlannerTreatsNonPositiveLimitsAsDisabled() {
    // A literal reading of "seconds >= limit" with limit 0 would rotate on every single sample.
    let limits = RecordingSegmentPlanner.Limits(maximumSeconds: 0, maximumBytes: 0)
    var planner = RecordingSegmentPlanner(limits: limits)
    #expect(planner.evaluate(isKeyframe: true, writtenSeconds: 9_999,
                             writtenBytes: 9_999_999_999) == .write)
    #expect(planner.segmentIndex == 0)
}

@Test func recordingSegmentPlannerKeepsTheFirstReasonWhenASecondLimitIsAlsoReached() {
    let limits = RecordingSegmentPlanner.Limits(maximumSeconds: 30, maximumBytes: 100)
    var planner = RecordingSegmentPlanner(limits: limits)
    // Duration is checked first, so a sample that trips both reports the duration.
    #expect(planner.evaluate(isKeyframe: false, writtenSeconds: 31, writtenBytes: 200) == .write)
    #expect(planner.pendingReason == .durationLimit)
    #expect(planner.evaluate(isKeyframe: true, writtenSeconds: 31, writtenBytes: 200)
            == .rotate(.durationLimit))
}

// MARK: - Externally armed rotations

@Test func recordingSegmentPlannerRotatesAtTheNextKeyframeWhenExternallyArmed() {
    var planner = RecordingSegmentPlanner()
    planner.requireRotationAtNextKeyframe(.requestedByOwner)
    #expect(planner.isAwaitingKeyframeToRotate)
    #expect(planner.evaluate(isKeyframe: false, writtenSeconds: 1, writtenBytes: 1) == .write)
    #expect(planner.evaluate(isKeyframe: true, writtenSeconds: 1, writtenBytes: 1)
            == .rotate(.requestedByOwner))
}

@Test func recordingSegmentPlannerDoesNotOverwriteAnAlreadyLatchedReason() {
    let limits = RecordingSegmentPlanner.Limits(maximumSeconds: 10, maximumBytes: .max)
    var planner = RecordingSegmentPlanner(limits: limits)
    _ = planner.evaluate(isKeyframe: false, writtenSeconds: 11, writtenBytes: 0)
    #expect(planner.pendingReason == .durationLimit)
    // The second reason is a consequence of the first, not the truth about why the file ended.
    planner.requireRotationAtNextKeyframe(.requestedByOwner)
    #expect(planner.pendingReason == .durationLimit)
}

// MARK: - Immediate closes

@Test func recordingSegmentPlannerClosesBeforeWritingOnAFormatChange() {
    var planner = RecordingSegmentPlanner()
    planner.requireImmediateClose(.formatChanged)
    // Not a keyframe, and it still closes: the sample cannot go into a file whose single
    // sourceFormatHint no longer describes it.
    #expect(planner.evaluate(isKeyframe: false, writtenSeconds: 1, writtenBytes: 1)
            == .closeBeforeWriting(.formatChanged))
    #expect(planner.segmentIndex == 1)
    #expect(!planner.isStopped)
}

@Test func recordingSegmentPlannerClosesBeforeWritingOnATimestampDiscontinuity() {
    var planner = RecordingSegmentPlanner()
    planner.requireImmediateClose(.timestampDiscontinuity)
    #expect(planner.evaluate(isKeyframe: true, writtenSeconds: 1, writtenBytes: 1)
            == .closeBeforeWriting(.timestampDiscontinuity))
    #expect(planner.segmentIndex == 1)
}

@Test func recordingSegmentPlannerStopsAndStaysStoppedOnDiskPressure() {
    var planner = RecordingSegmentPlanner()
    planner.requireImmediateClose(.diskPressure)
    #expect(planner.evaluate(isKeyframe: true, writtenSeconds: 1, writtenBytes: 1)
            == .stop(.diskPressure))
    #expect(planner.isStopped)
    // A late sample must not revive the recording, and must not reopen a file on a full disk.
    #expect(planner.evaluate(isKeyframe: true, writtenSeconds: 1, writtenBytes: 1)
            == .stop(.requestedByOwner))
    #expect(planner.segmentIndex == 0)
}

@Test func recordingSegmentPlannerImmediateCloseSupersedesALatchedLimit() {
    let limits = RecordingSegmentPlanner.Limits(maximumSeconds: 10, maximumBytes: .max)
    var planner = RecordingSegmentPlanner(limits: limits)
    _ = planner.evaluate(isKeyframe: false, writtenSeconds: 11, writtenBytes: 0)
    #expect(planner.pendingReason == .durationLimit)
    planner.requireImmediateClose(.formatChanged)
    #expect(planner.evaluate(isKeyframe: false, writtenSeconds: 11, writtenBytes: 0)
            == .closeBeforeWriting(.formatChanged))
    // The latch is cleared with it, so the new file does not inherit a pending rotation.
    #expect(planner.pendingReason == nil)
}

@Test func recordingSegmentPlannerCountsSegmentsAcrossSeveralRotations() {
    let limits = RecordingSegmentPlanner.Limits(maximumSeconds: 10, maximumBytes: .max)
    var planner = RecordingSegmentPlanner(limits: limits)
    for expected in 1...4 {
        #expect(planner.evaluate(isKeyframe: true, writtenSeconds: 10, writtenBytes: 0)
                == .rotate(.durationLimit))
        #expect(planner.segmentIndex == expected)
        // The caller resets its timeline per segment, so `writtenSeconds` starts again at zero.
        #expect(planner.evaluate(isKeyframe: false, writtenSeconds: 0, writtenBytes: 0) == .write)
    }
}

#endif
