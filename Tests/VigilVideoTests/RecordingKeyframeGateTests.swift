//
//  RecordingKeyframeGateTests.swift
//  VigilVideoTests
//
//  The gate that decides whether a clip opens at all, driven by an injected instant so every case is
//  deterministic and none of them spends a real second.
//  Covers Sources/VigilVideo/Recording/RecordingKeyframeGate.swift.
//
//  Pure arithmetic over `MediaInstant`; runs identically on macOS and in the Linux shadow harness
//  under scratchpad/shadow-recording, which is where these were executed.
//

#if os(macOS)

import Testing
import VigilProtocols
import VigilVideo

// MARK: - Support

/// `t0 + seconds`, as a reading from a notional injected clock.
private func recordingGateInstant(_ seconds: Double) -> MediaInstant {
    MediaInstant(nanoseconds: Int64(seconds * 1e9))
}

// MARK: - Opening

@Test func recordingKeyframeGateOpensOnTheFirstKeyframeAndWritesIt() {
    var gate = RecordingKeyframeGate(now: recordingGateInstant(0))
    #expect(!gate.isOpen)
    #expect(gate.admit(isKeyframe: true, now: recordingGateInstant(0)) == .write)
    #expect(gate.isOpen)
    #expect(gate.heldCount == 0)
}

@Test func recordingKeyframeGateHoldsEveryFrameBeforeTheFirstKeyframe() {
    var gate = RecordingKeyframeGate(now: recordingGateInstant(0))
    for frame in 1...30 {
        #expect(gate.admit(isKeyframe: false, now: recordingGateInstant(Double(frame) / 30))
                == .holdAwaitingKeyframe)
    }
    #expect(gate.heldCount == 30)
    #expect(!gate.isOpen)
}

@Test func recordingKeyframeGateWritesEverythingOnceOpen() {
    var gate = RecordingKeyframeGate(now: recordingGateInstant(0))
    #expect(gate.admit(isKeyframe: true, now: recordingGateInstant(0)) == .write)
    // Non-keyframes are exactly what a passthrough file is mostly made of; the gate must not keep
    // filtering them once the first sync sample is in.
    #expect(gate.admit(isKeyframe: false, now: recordingGateInstant(1)) == .write)
    #expect(gate.admit(isKeyframe: false, now: recordingGateInstant(600)) == .write)
    #expect(gate.heldCount == 0)
}

// MARK: - Keyframe request

@Test func recordingKeyframeGateAsksForAKeyframeOnceAfterTheRequestDelay() {
    var gate = RecordingKeyframeGate(now: recordingGateInstant(0),
                                     requestAfter: .seconds(5),
                                     giveUpAfter: .seconds(15))
    #expect(gate.admit(isKeyframe: false, now: recordingGateInstant(4.9))
            == .holdAwaitingKeyframe)
    #expect(!gate.didRequestKeyframe)
    #expect(gate.admit(isKeyframe: false, now: recordingGateInstant(5))
            == .holdAndRequestKeyframe)
    #expect(gate.didRequestKeyframe)
    // Asking once per frame would be a denial of service against the camera dressed up as error
    // handling: an ISAPI keyframe request per frame is 30 requests a second.
    #expect(gate.admit(isKeyframe: false, now: recordingGateInstant(6))
            == .holdAwaitingKeyframe)
    #expect(gate.admit(isKeyframe: false, now: recordingGateInstant(14.9))
            == .holdAwaitingKeyframe)
}

@Test func recordingKeyframeGateDoesNotRequestWhenTheKeyframeArrivesFirst() {
    var gate = RecordingKeyframeGate(now: recordingGateInstant(0), requestAfter: .seconds(5))
    #expect(gate.admit(isKeyframe: false, now: recordingGateInstant(1)) == .holdAwaitingKeyframe)
    #expect(gate.admit(isKeyframe: true, now: recordingGateInstant(2)) == .write)
    #expect(!gate.didRequestKeyframe)
}

// MARK: - Giving up

@Test func recordingKeyframeGateGivesUpAtTheBudgetRatherThanOpeningAFileAnyway() {
    var gate = RecordingKeyframeGate(now: recordingGateInstant(0),
                                     requestAfter: .seconds(5),
                                     giveUpAfter: .seconds(15))
    // Just inside the budget, and past the request delay, so this is the one keyframe request.
    #expect(gate.admit(isKeyframe: false, now: recordingGateInstant(14.999))
            == .holdAndRequestKeyframe)
    #expect(gate.admit(isKeyframe: false, now: recordingGateInstant(15))
            == .giveUp(waitedSeconds: 15))
    #expect(!gate.isOpen)
    // And it keeps giving up rather than flipping open on a later non-keyframe.
    #expect(gate.admit(isKeyframe: false, now: recordingGateInstant(20))
            == .giveUp(waitedSeconds: 20))
}

@Test func recordingKeyframeGateGivesUpBeforeRequestingWhenTheBudgetIsShorter() {
    // A misconfiguration, not a crash: with `giveUpAfter <= requestAfter` the request simply never
    // happens, which is checked here so the ordering of the two comparisons cannot silently invert.
    var gate = RecordingKeyframeGate(now: recordingGateInstant(0),
                                     requestAfter: .seconds(10),
                                     giveUpAfter: .seconds(2))
    #expect(gate.admit(isKeyframe: false, now: recordingGateInstant(3))
            == .giveUp(waitedSeconds: 3))
    #expect(!gate.didRequestKeyframe)
}

@Test func recordingKeyframeGateNeverGivesUpOnceOpen() {
    var gate = RecordingKeyframeGate(now: recordingGateInstant(0), giveUpAfter: .seconds(15))
    #expect(gate.admit(isKeyframe: true, now: recordingGateInstant(0)) == .write)
    // Hours later, still writing. The budget applies to opening the file, not to keeping it open.
    #expect(gate.admit(isKeyframe: false, now: recordingGateInstant(3_600)) == .write)
}

// MARK: - Reset for a new segment

@Test func recordingKeyframeGateShutsAgainForANewSegment() {
    var gate = RecordingKeyframeGate(now: recordingGateInstant(0))
    #expect(gate.admit(isKeyframe: true, now: recordingGateInstant(0)) == .write)
    _ = gate.admit(isKeyframe: false, now: recordingGateInstant(1))

    gate.reset(now: recordingGateInstant(100))
    #expect(!gate.isOpen)
    #expect(gate.heldCount == 0)
    #expect(!gate.didRequestKeyframe)

    // Every segment is an independent file, so every segment's first sample must be a keyframe too.
    #expect(gate.admit(isKeyframe: false, now: recordingGateInstant(100))
            == .holdAwaitingKeyframe)
    #expect(gate.admit(isKeyframe: true, now: recordingGateInstant(101)) == .write)
}

@Test func recordingKeyframeGateRestartsItsBudgetFromTheResetInstant() {
    var gate = RecordingKeyframeGate(now: recordingGateInstant(0), giveUpAfter: .seconds(15))
    gate.reset(now: recordingGateInstant(1_000))
    // Measured from the reset, not from construction: 1 001 s absolute is 1 s into the new wait, so
    // it is well inside a budget that would have expired long ago on the original clock.
    #expect(gate.admit(isKeyframe: false, now: recordingGateInstant(1_001))
            == .holdAwaitingKeyframe)
    #expect(gate.admit(isKeyframe: false, now: recordingGateInstant(1_015))
            == .giveUp(waitedSeconds: 15))
}

#endif
