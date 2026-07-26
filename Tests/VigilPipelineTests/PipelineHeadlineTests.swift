//
//  PipelineHeadlineTests.swift
//  VigilPipelineTests
//
//  The tests that justify the whole fixture: several quirks at once on one stream, and a long soak
//  that is only possible because the harness is a pure function of virtual time.
//

import Foundation
import Testing
import VigilProtocols
import VigilRTP
import VigilTestKit

// MARK: - The headline

@Suite struct PipelineHeadlineSuite {

    /// **The headline test.**
    ///
    /// An H.265 stream with the marker bit never set, sequence numbers wrapping through 65 535,
    /// two per cent seeded packet loss and unpadded base64 parameter sets still yields correctly
    /// bounded access units. That single scenario exercises most of the traps this project has been
    /// designed around: marker-independent access-unit detection, 16-bit sequence unwrapping,
    /// loss-tolerant reassembly and lenient base64.
    @Test func headlineH265SurvivesMarkerLossWrapAndUnpaddedBase64() {
        let profile = SyntheticCameraProfile.hevcCamera().adding([
            .markerNeverSet,
            .sequenceWrapSoon,
            .packetLoss(rate: 0.02),
            .unpaddedSpropBase64,
        ])
        var harness = PipelineHarness(profile: profile)
        let report = harness.run(forVirtualTime: .seconds(8))

        #expect(report.failure == nil, "session failed: \(report.diagnosticSummary)")
        #expect(report.setupFailure == nil, "setup failed: \(report.diagnosticSummary)")
        #expect(report.serverState == .playing, "camera never played: \(report.diagnosticSummary)")

        // Frames actually came out, and the first one the decoder could use is a keyframe.
        let summary = report.diagnosticSummary
        #expect(report.frames.count >= 40,
                "almost nothing survived 2 % loss: \(summary)")
        #expect(report.firstFrameIsKeyframe, "first frame was not a keyframe: \(summary)")

        // The control: the same three non-loss quirks with no loss must cost nothing at all, which
        // is what makes the frames missing above attributable to the injected loss and to nothing
        // else. Without this the budget assertion below could be satisfied by a broken pipeline.
        var control = PipelineHarness(profile: SyntheticCameraProfile.hevcCamera().adding([
            .markerNeverSet, .sequenceWrapSoon, .unpaddedSpropBase64,
        ]))
        let clean = control.run(forVirtualTime: .seconds(8))
        #expect(clean.failure == nil, "loss-free control failed: \(clean.diagnosticSummary)")
        #expect(clean.undeliveredFrameCount <= 1,
                "marker/wrap/base64 alone cost frames: \(clean.diagnosticSummary)")
        let controlSummary = clean.diagnosticSummary
        #expect(clean.frames.count >= 190,
                "control delivered \(clean.frames.count) of ~200: \(controlSummary)")

        // Correctly *bounded*: no picture split, no picture merged, no duplicate.
        #expect(report.hasMonotonicPTS,
                "PTS broke at \(report.nonMonotonicPTSIndices): \(report.diagnosticSummary)")
        #expect(report.duplicatePTSCount == 0,
                "duplicate access units: \(report.diagnosticSummary)")
        #expect(report.frames.count <= report.groundTruth.frames.count,
                "more frames came out than the camera sent — split pictures: \(summary)")
        let allowed = report.groundTruth.expectedRecoverableFrameLosses
        #expect(report.undeliveredFrameCount <= allowed + 3,
                "lost \(report.undeliveredFrameCount) frames, budget \(allowed): \(summary)")

        // The traps were genuinely sprung, not skipped.
        #expect(!report.groundTruth.injectedPacketLosses.isEmpty, "no loss was actually injected")
        #expect(report.injectedLossFraction > 0.005 && report.injectedLossFraction < 0.05,
                "loss fraction \(report.injectedLossFraction) is not near 2 %")
        #expect(report.keyframeCount >= 2, "the stream never recovered to a second keyframe")
    }

    /// The same combination on H.264, which takes a different depacketization path entirely.
    @Test func headlineH264SurvivesMarkerLossWrapAndUnpaddedBase64() {
        let profile = SyntheticCameraProfile.ds2cd2143g2().adding([
            .markerNeverSet,
            .sequenceWrapSoon,
            .packetLoss(rate: 0.02),
            .unpaddedSpropBase64,
        ])
        var harness = PipelineHarness(profile: profile)
        let report = harness.run(forVirtualTime: .seconds(8))
        #expect(report.failure == nil, "session failed: \(report.diagnosticSummary)")
        #expect(report.frames.count >= 20,
                "almost nothing survived 2 % loss: \(report.diagnosticSummary)")
        let allowed = report.groundTruth.expectedRecoverableFrameLosses
        #expect(report.undeliveredFrameCount <= allowed + 3,
                "lost more than the loss can explain: \(report.diagnosticSummary)")
        #expect(report.firstFrameIsKeyframe, "\(report.diagnosticSummary)")
        #expect(report.hasMonotonicPTS, "\(report.diagnosticSummary)")
        #expect(report.duplicatePTSCount == 0, "\(report.diagnosticSummary)")
    }

    /// Every transport-shape quirk at once, on a stream that is also losing packets.
    @Test func headlineHostileTransportAndLossTogether() {
        let profile = SyntheticCameraProfile.hevcCamera().adding([
            .slowDrip(bytesPerRead: 7),
            .dollarInResponseBody,
            .extraSDPAttributes,
            .noContentBase,
            .packetLoss(rate: 0.01),
        ])
        var harness = PipelineHarness(profile: profile)
        let report = harness.run(forVirtualTime: .seconds(6))
        #expect(report.failure == nil, "session failed: \(report.diagnosticSummary)")
        #expect(!report.frames.isEmpty, "no frames survived: \(report.diagnosticSummary)")
        #expect(report.firstFrameIsKeyframe, "\(report.diagnosticSummary)")
    }
}

// MARK: - Soak

@Suite struct PipelineSoakSuite {

    /// Ten minutes of virtual time at 25 fps on a low-bitrate profile.
    ///
    /// The point is not the frame count but the shape of the run: buffering must stay bounded and
    /// the sequence number must wrap many times without the pipeline resetting. This is only
    /// runnable in CI because the harness never touches a wall clock.
    @Test func soakTenVirtualMinutesKeepsBuffersBounded() {
        var profile = SyntheticCameraProfile.hevcCamera()
        profile.bitrateKbps = 192
        profile.gopLength = 50
        var harness = PipelineHarness(profile: profile.adding(.sequenceWrapSoon))
        let report = harness.run(forVirtualTime: .seconds(600), stepNanos: 5_000_000)

        #expect(report.failure == nil, "soak failed: \(report.diagnosticSummary)")
        #expect(report.frames.count > 10_000,
                "expected ~15 000 frames in ten virtual minutes, got \(report.frames.count)")
        #expect(report.hasMonotonicPTS, "PTS broke during the soak")
        #expect(report.peakBufferedBytes < 4 << 20,
                "wire buffer peaked at \(report.peakBufferedBytes) bytes")
        #expect(report.serverState == .playing, "the session did not survive ten virtual minutes")
    }
}
