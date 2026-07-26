//
//  PipelineProfileTests.swift
//  VigilPipelineTests
//
//  The end-to-end happy path: for every synthetic camera preset, drive the real RTSP session
//  machine and the real RTP receiver from the fixture's bytes and assert a correct sequence of
//  frames comes out. No sockets, no camera, no Mac — this is the evidence that the connection logic
//  is right rather than merely plausible.
//

import Foundation
import Testing
import VigilProtocols
import VigilRTP
import VigilTestKit

// MARK: - Shared expectations

/// Assertions every successful run must satisfy, factored out so each test states only what is
/// specific to it.
enum PipelineExpectations {

    /// The whole "a correct sequence of frames came out" claim, in one place.
    static func assertHealthy(_ report: HarnessReport, minimumFrames: Int,
                              sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(report.failure == nil, "session failed: \(report.diagnosticSummary)",
                sourceLocation: sourceLocation)
        #expect(report.setupFailure == nil, "setup failed: \(report.diagnosticSummary)",
                sourceLocation: sourceLocation)
        #expect(report.frames.count >= minimumFrames,
                "too few frames: \(report.diagnosticSummary)", sourceLocation: sourceLocation)
        #expect(report.firstFrameIsKeyframe,
                "first frame was not a keyframe: \(report.diagnosticSummary)",
                sourceLocation: sourceLocation)
        let backwards = report.nonMonotonicPTSIndices
        #expect(report.hasMonotonicPTS,
                "PTS went backwards at \(backwards): \(report.diagnosticSummary)",
                sourceLocation: sourceLocation)
        #expect(report.duplicatePTSCount == 0,
                "duplicate access units emitted: \(report.diagnosticSummary)",
                sourceLocation: sourceLocation)
        #expect(report.serverState == .playing,
                "camera never reached PLAY: \(report.diagnosticSummary)",
                sourceLocation: sourceLocation)
    }
}

// MARK: - Presets

@Suite struct PipelineProfileSuite {

    /// Every preset must connect, authenticate and deliver a correct frame sequence.
    @Test(arguments: SyntheticCameraProfile.allPresets())
    func pipelineDeliversFramesForEveryPreset(profile: SyntheticCameraProfile) {
        var harness = PipelineHarness(profile: profile)
        let report = harness.run(untilFrames: 40, virtualTimeout: .seconds(20))
        PipelineExpectations.assertHealthy(report, minimumFrames: 35)
        #expect(report.groundTruth.injectedPacketLosses.isEmpty)
        #expect(report.undeliveredFrameCount <= 2,
                "clean run should lose nothing: \(report.diagnosticSummary)")
    }

    /// H.265 with a VPS: the parameter sets must arrive complete and the geometry must survive the
    /// conformance-window arithmetic.
    @Test func pipelineH265StreamCarriesVPSAndCorrectGeometry() throws {
        var harness = PipelineHarness(profile: .hevcCamera())
        let report = harness.run(untilFrames: 30, virtualTimeout: .seconds(15))
        PipelineExpectations.assertHealthy(report, minimumFrames: 25)
        let sets = try #require(report.frames.compactMap(\.parameterSets).first,
                                "no frame carried parameter sets: \(report.diagnosticSummary)")
        #expect(sets.codec == .h265)
        #expect(sets.vps.count == 1)
        #expect(sets.sps.count == 1)
        #expect(sets.pps.count == 1)
        #expect(report.groundTruth.geometry.displayWidth == 1920)
        #expect(report.groundTruth.geometry.displayHeight == 1080)
        #expect(report.groundTruth.geometry.codedHeight == 1080)
    }

    /// H.264 at 1080-in-1088: the coded height differs from the display height, which is where
    /// cropping bugs live.
    @Test func pipelineH264StreamHandlesCroppedGeometry() {
        var profile = SyntheticCameraProfile.ds2cd2143g2()
        profile.width = 1920
        profile.height = 1080
        var harness = PipelineHarness(profile: profile)
        let report = harness.run(untilFrames: 25, virtualTimeout: .seconds(15))
        PipelineExpectations.assertHealthy(report, minimumFrames: 20)
        #expect(report.groundTruth.geometry.codedHeight == 1088)
        #expect(report.groundTruth.geometry.displayHeight == 1080)
    }

    /// The NVR path is a different URI shape, which the request-line URI and the digest URI must
    /// both use byte for byte.
    @Test func pipelineNVRChannelUsesTheChannelURI() {
        let profile = SyntheticCameraProfile.ds7608nvr(channels: 8, channel: 3)
        var harness = PipelineHarness(profile: profile)
        let report = harness.run(untilFrames: 20, virtualTimeout: .seconds(20))
        PipelineExpectations.assertHealthy(report, minimumFrames: 15)
        #expect(report.requests.allSatisfy { $0.uri.contains("/Streaming/Channels/302") },
                "a request went to the wrong channel: \(report.requests.map(\.uri))")
    }

    /// The legacy path form plus Basic auth: both are still shipped by older encoders.
    @Test func pipelineLegacyPathCameraConnects() {
        var harness = PipelineHarness(profile: .legacyPathCamera())
        let report = harness.run(untilFrames: 25, virtualTimeout: .seconds(20))
        PipelineExpectations.assertHealthy(report, minimumFrames: 20)
        #expect(report.requests.contains { $0.uri.contains("/h264/ch1/main/av_stream") })
        #expect(report.challengeCount >= 1, "Basic auth still needs one challenge")
    }

    /// Digest with and without `qop` are separate code paths in the client and separate
    /// verification paths in the camera.
    @Test(arguments: [SyntheticAuthMode.digestNoQop, .digestQopAuth, .basic, .none])
    func pipelineAuthenticatesInEveryMode(mode: SyntheticAuthMode) {
        var profile = SyntheticCameraProfile.hevcCamera()
        profile.authMode = mode
        var harness = PipelineHarness(profile: profile)
        let report = harness.run(untilFrames: 20, virtualTimeout: .seconds(20))
        PipelineExpectations.assertHealthy(report, minimumFrames: 15)
        #expect(report.credentialRejections.isEmpty,
                "camera rejected a credential in \(mode.rawValue): \(report.credentialRejections)")
        if mode.requiresCredential {
            #expect(report.authenticatedRequestCount >= 1)
        }
    }

    /// The pipeline must not sit on unbounded buffers even on a clean run.
    @Test func pipelineDoesNotBufferUnboundedly() {
        var harness = PipelineHarness(profile: .hevcCamera())
        let report = harness.run(untilFrames: 60, virtualTimeout: .seconds(20))
        PipelineExpectations.assertHealthy(report, minimumFrames: 50)
        #expect(report.peakBufferedBytes < 4 << 20,
                "peak wire buffer was \(report.peakBufferedBytes) bytes")
    }

    /// Time to first frame on the virtual clock. The whole handshake plus one GOP-opening keyframe
    /// must complete well inside the slice's ten-second budget.
    @Test func pipelineReachesFirstFrameQuicklyOnTheVirtualClock() throws {
        var harness = PipelineHarness(profile: .hevcCamera())
        let report = harness.run(untilFrames: 5, virtualTimeout: .seconds(15))
        let elapsed = try #require(report.timeToFirstFrame,
                                   "no first frame: \(report.diagnosticSummary)")
        #expect(elapsed < .seconds(10), "first frame took \(elapsed) of virtual time")
    }

    /// Two runs with the same seed must produce the same frames, or a CI failure is not replayable.
    @Test func pipelineIsReproducibleFromItsSeed() {
        func fingerprint(seed: UInt64) -> [UInt32] {
            var harness = PipelineHarness(profile: .hevcCamera(seed: seed))
            let report = harness.run(untilFrames: 20, virtualTimeout: .seconds(15))
            return report.frames.map { CRC32.checksum($0.data) }
        }
        let first = fingerprint(seed: 0xABCD)
        #expect(!first.isEmpty)
        #expect(first == fingerprint(seed: 0xABCD))
    }
}
