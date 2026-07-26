//
//  PipelineQuirkTests.swift
//  VigilPipelineTests
//
//  One test per `Quirk`: the pipeline either survives the fault and still produces frames, or it
//  fails with the specific diagnosable error that is the correct behaviour. Every quirk found on
//  real hardware becomes a row here, permanently.
//

import Foundation
import Testing
import VigilProtocols
import VigilRTP
import VigilTestKit

// MARK: - Transport shape

@Suite struct PipelineTransportQuirkSuite {

    /// A camera that delivers seven bytes per read must produce the same result as one that does
    /// not: the client's decoder has to accumulate rather than assume whole messages.
    @Test func quirkSlowDripProducesTheSameFramesAsACleanRun() {
        var clean = PipelineHarness(profile: .hevcCamera())
        let baseline = clean.run(untilFrames: 20, virtualTimeout: .seconds(20))
        var dripped = PipelineHarness(profile: .hevcCamera().adding(.slowDrip(bytesPerRead: 7)))
        let report = dripped.run(untilFrames: 20, virtualTimeout: .seconds(20))
        PipelineExpectations.assertHealthy(report, minimumFrames: 18)
        #expect(report.frames.map { CRC32.checksum($0.data) }
            == baseline.frames.map { CRC32.checksum($0.data) },
            "slowDrip changed the delivered frames: \(report.diagnosticSummary)")
    }

    /// Reads that land inside the status line, across the header terminator and inside the
    /// four-byte `$` header. Same result required.
    @Test func quirkHostileSplitsProduceTheSameFramesAsACleanRun() {
        var clean = PipelineHarness(profile: .hevcCamera())
        let baseline = clean.run(untilFrames: 20, virtualTimeout: .seconds(20))
        var split = PipelineHarness(profile: .hevcCamera().adding(.splitAtHostileOffsets))
        let report = split.run(untilFrames: 20, virtualTimeout: .seconds(20))
        PipelineExpectations.assertHealthy(report, minimumFrames: 18)
        #expect(report.frames.map { CRC32.checksum($0.data) }
            == baseline.frames.map { CRC32.checksum($0.data) },
            "hostile splits changed the delivered frames: \(report.diagnosticSummary)")
    }

    /// A `$` inside the SDP body must be consumed as body, not mistaken for interleaved framing.
    @Test func quirkDollarInResponseBodyDoesNotDesynchroniseTheDecoder() {
        var harness = PipelineHarness(profile: .hevcCamera().adding(.dollarInResponseBody))
        let report = harness.run(untilFrames: 20, virtualTimeout: .seconds(20))
        PipelineExpectations.assertHealthy(report, minimumFrames: 15)
    }

    @Test func quirkExtraSDPAttributesAreIgnored() {
        var harness = PipelineHarness(profile: .hevcCamera().adding(.extraSDPAttributes))
        let report = harness.run(untilFrames: 20, virtualTimeout: .seconds(20))
        PipelineExpectations.assertHealthy(report, minimumFrames: 15)
    }

    /// With no `Content-Base`, control URLs resolve against the request URI instead.
    @Test func quirkNoContentBaseStillResolvesTheTrackURL() {
        var harness = PipelineHarness(profile: .hevcCamera().adding(.noContentBase))
        let report = harness.run(untilFrames: 20, virtualTimeout: .seconds(20))
        PipelineExpectations.assertHealthy(report, minimumFrames: 15)
    }

    @Test func quirkAbsoluteControlURLIsAccepted() {
        var harness = PipelineHarness(profile: .hevcCamera().adding(.absoluteControlURL))
        let report = harness.run(untilFrames: 20, virtualTimeout: .seconds(20))
        PipelineExpectations.assertHealthy(report, minimumFrames: 15)
    }
}

// MARK: - Auth

@Suite struct PipelineAuthQuirkSuite {

    /// `stale=TRUE` mid-session: the credential is still right, only the nonce expired. The client
    /// must re-authenticate and the session must continue.
    @Test func quirkStaleNonceReAuthenticatesWithoutLosingTheSession() {
        let profile = SyntheticCameraProfile.hevcCamera().adding(.digestStaleNonce(afterRequests: 2))
        var harness = PipelineHarness(profile: profile)
        let report = harness.run(untilFrames: 25, virtualTimeout: .seconds(25))
        PipelineExpectations.assertHealthy(report, minimumFrames: 15)
        #expect(report.challengeCount >= 2, "the stale challenge should be a second 401")
        #expect(report.credentialRejections.isEmpty,
                "a stale nonce is not a credential failure: \(report.credentialRejections)")
    }

    /// A permanently wrong password is the one quirk where failing is correct. The client must stop
    /// at two authenticated attempts — never five, never a loop.
    @Test func quirkWrongPasswordStopsAtTwoAttemptsWithADiagnosableError() {
        let profile = SyntheticCameraProfile.hevcCamera().adding(.wrongPasswordAlways)
        var harness = PipelineHarness(profile: profile)
        let report = harness.run(untilFrames: 5, virtualTimeout: .seconds(20))
        #expect(report.frames.isEmpty, "no media may flow: \(report.diagnosticSummary)")
        #expect(report.failure != nil || report.transportClosed,
                "the client must give up rather than retry forever: \(report.diagnosticSummary)")
        let credentialed = report.requests.filter { $0.header("Authorization") != nil }
        #expect(credentialed.count <= 2,
                "sent \(credentialed.count) credentialed requests; the cap is 2")
        #expect(report.serverState != .playing)
    }
}

// MARK: - RTP shape

@Suite struct PipelineRTPQuirkSuite {

    /// The single most important quirk: the marker bit is never set, so the access-unit boundary
    /// must come from the timestamp change plus the slice-header first-slice predicate.
    @Test func quirkMarkerNeverSetStillBoundsAccessUnitsCorrectly() {
        var harness = PipelineHarness(profile: .hevcCamera().adding(.markerNeverSet))
        let report = harness.run(untilFrames: 30, virtualTimeout: .seconds(20))
        PipelineExpectations.assertHealthy(report, minimumFrames: 25)
        #expect(report.undeliveredFrameCount <= 2,
                "frames were lost with no marker bit: \(report.diagnosticSummary)")
    }

    /// Worse than never setting it: the marker lands mid-picture and is cleared on the real end.
    /// A marker-trusting depacketizer splits pictures here and the frame count doubles.
    @Test func quirkMarkerMidPictureDoesNotSplitPictures() {
        var harness = PipelineHarness(profile: .hevcCamera().adding(.markerMidPicture))
        let report = harness.run(untilFrames: 30, virtualTimeout: .seconds(20))
        PipelineExpectations.assertHealthy(report, minimumFrames: 25)
        #expect(report.frames.count <= report.groundTruth.frames.count + 1,
                "more frames came out than went in — split picture: \(report.diagnosticSummary)")
    }

    @Test func quirkMarkerNeverSetForH264StillBoundsAccessUnitsCorrectly() {
        var harness = PipelineHarness(profile: .ds2cd2143g2().adding(.markerNeverSet))
        let report = harness.run(untilFrames: 25, virtualTimeout: .seconds(25))
        PipelineExpectations.assertHealthy(report, minimumFrames: 20)
    }

    @Test func quirkUnpaddedSpropBase64IsAccepted() {
        var harness = PipelineHarness(profile: .hevcCamera().adding(.unpaddedSpropBase64))
        let report = harness.run(untilFrames: 20, virtualTimeout: .seconds(20))
        PipelineExpectations.assertHealthy(report, minimumFrames: 15)
    }

    /// No `sprop-*` at all: the geometry has to come from the in-band parameter sets.
    @Test func quirkParameterSetsOnlyInBandStillYieldsAKeyframeFirst() {
        var harness = PipelineHarness(profile: .hevcCamera().adding(.parameterSetsOnlyInBand))
        let report = harness.run(untilFrames: 20, virtualTimeout: .seconds(20))
        PipelineExpectations.assertHealthy(report, minimumFrames: 15)
    }

    /// The mirror case: the sets are in the SDP and never repeated on the wire.
    @Test func quirkParameterSetsOnlyInSDPStillDecodesConfiguration() {
        var harness = PipelineHarness(profile: .hevcCamera().adding(.parameterSetsOnlyInSDP))
        let report = harness.run(untilFrames: 20, virtualTimeout: .seconds(20))
        PipelineExpectations.assertHealthy(report, minimumFrames: 15)
    }

    /// Sequence numbers start at 65 500 and wrap a few packets in. No loss, no reset.
    @Test func quirkSequenceWrapSoonSurvivesTheRollover() {
        var harness = PipelineHarness(profile: .hevcCamera().adding(.sequenceWrapSoon))
        let report = harness.run(untilFrames: 30, virtualTimeout: .seconds(20))
        PipelineExpectations.assertHealthy(report, minimumFrames: 25)
        #expect(report.undeliveredFrameCount <= 1,
                "the 16-bit wrap cost frames: \(report.diagnosticSummary)")
    }

    /// RTP timestamps start near 2³² and wrap. PTS must stay monotonic after unwrapping.
    @Test func quirkTimestampWrapSoonKeepsPTSMonotonic() {
        var harness = PipelineHarness(profile: .hevcCamera().adding(.timestampWrapSoon))
        let report = harness.run(untilFrames: 30, virtualTimeout: .seconds(20))
        PipelineExpectations.assertHealthy(report, minimumFrames: 25)
        #expect(report.hasMonotonicPTS,
                "PTS broke across the 2^32 wrap at \(report.nonMonotonicPTSIndices)")
    }

    /// Two per cent seeded loss. Frames are allowed to go missing, but only the ones the loss
    /// actually damaged, and the stream must recover to a keyframe.
    @Test func quirkPacketLossLosesOnlyDamagedAccessUnits() {
        let profile = SyntheticCameraProfile.hevcCamera().adding(.packetLoss(rate: 0.02))
        var harness = PipelineHarness(profile: profile)
        let report = harness.run(forVirtualTime: .seconds(6))
        #expect(report.failure == nil, "loss must not fail the session: \(report.diagnosticSummary)")
        #expect(!report.frames.isEmpty, "no frames survived 2 % loss: \(report.diagnosticSummary)")
        #expect(!report.groundTruth.injectedPacketLosses.isEmpty, "the quirk dropped nothing")
        let allowed = report.groundTruth.expectedRecoverableFrameLosses
        let lost = report.undeliveredFrameCount
        #expect(lost <= allowed + 2,
                "lost \(lost) frames, budget was \(allowed): \(report.diagnosticSummary)")
        #expect(report.keyframeCount >= 1, "the stream never recovered to a keyframe")
    }

    /// Reordering within a window: the jitter buffer must put it back together with no loss.
    @Test func quirkReorderIsRepairedByTheJitterBuffer() {
        let profile = SyntheticCameraProfile.hevcCamera().adding(.reorder(windowPackets: 8))
        var harness = PipelineHarness(profile: profile)
        let report = harness.run(forVirtualTime: .seconds(6))
        #expect(report.failure == nil, "reordering must not fail: \(report.diagnosticSummary)")
        #expect(!report.frames.isEmpty, "reordering lost the whole stream")
        #expect(report.hasMonotonicPTS, "reordering broke PTS ordering")
    }

    /// Duplicates must never produce a duplicate access unit.
    @Test func quirkDuplicatePacketsProduceNoDuplicateFrames() {
        let profile = SyntheticCameraProfile.hevcCamera().adding(.duplicate(rate: 0.05))
        var harness = PipelineHarness(profile: profile)
        let report = harness.run(untilFrames: 25, virtualTimeout: .seconds(20))
        PipelineExpectations.assertHealthy(report, minimumFrames: 15)
        #expect(report.duplicatePTSCount == 0,
                "a duplicated packet produced a duplicated frame: \(report.diagnosticSummary)")
    }

    /// STAP-A / AP aggregation must be split back into separate NALs.
    @Test func quirkAggregationPacketsAreSplitIntoSeparateNALs() {
        var harness = PipelineHarness(profile: .hevcCamera().adding(.aggregationPackets))
        let report = harness.run(untilFrames: 20, virtualTimeout: .seconds(20))
        PipelineExpectations.assertHealthy(report, minimumFrames: 15)
    }

    @Test func quirkAggregationPacketsForH264AreSplitIntoSeparateNALs() {
        var harness = PipelineHarness(profile: .ds2cd2143g2().adding(.aggregationPackets))
        let report = harness.run(untilFrames: 20, virtualTimeout: .seconds(25))
        PipelineExpectations.assertHealthy(report, minimumFrames: 15)
    }

    /// The stream starts mid-GOP with no IRAP for two seconds. Everything before the first IRAP
    /// must be dropped, and the first delivered frame must be a keyframe.
    @Test func quirkStartMidGOPDropsEverythingBeforeTheFirstIRAP() {
        let profile = SyntheticCameraProfile.hevcCamera().adding(.startMidGOP(seconds: 2))
        var harness = PipelineHarness(profile: profile)
        let report = harness.run(untilFrames: 10, virtualTimeout: .seconds(25))
        #expect(report.failure == nil, "mid-GOP start must not fail: \(report.diagnosticSummary)")
        #expect(!report.frames.isEmpty, "no frame ever arrived: \(report.diagnosticSummary)")
        #expect(report.firstFrameIsKeyframe,
                "a non-IRAP frame arrived before the keyframe: \(report.diagnosticSummary)")
    }

    /// A resolution change mid-stream must attach a second parameter-set generation at the boundary
    /// and must not cost frames on either side of it.
    @Test func quirkMidStreamResolutionChangeAttachesNewParameterSets() {
        let profile = SyntheticCameraProfile.hevcCamera()
            .adding(.midStreamResolutionChange(atFrame: 30, newWidth: 1280, newHeight: 720))
        var harness = PipelineHarness(profile: profile)
        let report = harness.run(untilFrames: 45, virtualTimeout: .seconds(25))
        PipelineExpectations.assertHealthy(report, minimumFrames: 35)
        let distinctSets = Set(report.frames.compactMap(\.parameterSets).map(\.fingerprint))
        #expect(distinctSets.count >= 2,
                "resolution change made no new parameter sets: \(report.diagnosticSummary)")
    }
}
