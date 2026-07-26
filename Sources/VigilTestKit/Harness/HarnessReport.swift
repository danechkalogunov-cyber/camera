//
//  HarnessReport.swift
//  VigilTestKit
//
//  What came out of one end-to-end pipeline run: the frames, the RTSP conversation, the
//  depacketizer events, the ground truth to compare against, and the convenience predicates every
//  pipeline test asserts on.
//  Implements docs/ARCHITECTURE.md §10.2 (`HarnessReport`).
//

import Foundation
import VigilProtocols
import VigilRTP

// MARK: - Report

/// The result of driving the synthetic camera through the real client stack.
public struct HarnessReport: Sendable {

    /// Access units the pipeline delivered, in emission order.
    public var frames: [EncodedFrame] = []

    /// What the camera intended to send.
    public var groundTruth = GroundTruth()

    /// Requests the camera received, in order.
    public var requests: [SyntheticRTSPRequest] = []

    /// Depacketizer and receiver events, in order.
    public var events: [DepacketizerEvent] = []

    /// Rendered names of the actions the session machine produced, in order. Rendered rather than
    /// stored as values so the report stays comparable even as the action enumeration grows.
    public var actionTrace: [String] = []

    /// Log events the harness's ``RecordingLogger`` captured.
    public var logEvents: [LogEvent] = []

    /// The terminal error the session machine reported, if any.
    public var failure: RTSPError?

    /// A textual description of any error raised while building the RTP receiver.
    public var setupFailure: String?

    /// Largest number of bytes ever waiting to be handed to the client at once. A pipeline that
    /// buffers unboundedly shows up here and nowhere else.
    public var peakBufferedBytes: Int = 0

    /// Virtual time the run consumed.
    public var virtualElapsed: Duration = .zero

    /// Virtual time from the start of the run to the first delivered frame, or `nil`.
    public var timeToFirstFrame: Duration?

    /// The camera's session state when the run ended.
    public var serverState: SyntheticSessionState = .initial

    /// `401` responses the camera issued.
    public var challengeCount: Int = 0

    /// Requests the camera accepted an `Authorization` header on.
    public var authenticatedRequestCount: Int = 0

    /// Reasons the camera rejected a credential, in order.
    public var credentialRejections: [String] = []

    /// `true` when the session machine reported the transport closed.
    public var transportClosed = false

    public init() {}

    // MARK: Convenience predicates

    /// `true` when at least one frame was delivered and the first is a keyframe.
    ///
    /// The pipeline is required to open closed and stay closed until an IRAP, so a first frame that
    /// is not a keyframe is a real defect, not a tolerance.
    public var firstFrameIsKeyframe: Bool {
        frames.first?.isKeyframe ?? false
    }

    /// Number of delivered keyframes.
    public var keyframeCount: Int {
        frames.reduce(0) { $0 + ($1.isKeyframe ? 1 : 0) }
    }

    /// Indices in ``frames`` where the presentation timestamp failed to increase.
    ///
    /// Compared in seconds so two timestamps on different timescales still order correctly, which
    /// matters across a mid-stream format change.
    public var nonMonotonicPTSIndices: [Int] {
        var out: [Int] = []
        for index in 1..<Swift.max(frames.count, 1) where index < frames.count {
            if frames[index].pts.seconds <= frames[index - 1].pts.seconds { out.append(index) }
        }
        return out
    }

    /// `true` when every frame's presentation timestamp is strictly greater than its predecessor's.
    public var hasMonotonicPTS: Bool { nonMonotonicPTSIndices.isEmpty }

    /// Distinct presentation timestamps, in seconds, in delivery order. A duplicate here means the
    /// pipeline emitted the same access unit twice.
    public var duplicatePTSCount: Int {
        var seen = Set<Double>()
        var duplicates = 0
        for frame in frames {
            if !seen.insert(frame.pts.seconds).inserted { duplicates += 1 }
        }
        return duplicates
    }

    /// Access units the camera generated but the pipeline did not deliver.
    public var undeliveredFrameCount: Int {
        Swift.max(0, groundTruth.frames.count - frames.count)
    }

    /// Observed packet-loss fraction, from the injected losses against the emitted packet count.
    public var injectedLossFraction: Double {
        let emitted = groundTruth.emittedPacketCount + groundTruth.injectedPacketLosses.count
        guard emitted > 0 else { return 0 }
        return Double(groundTruth.injectedPacketLosses.count) / Double(emitted)
    }

    /// Events matching `predicate`.
    public func events(where predicate: (DepacketizerEvent) -> Bool) -> [DepacketizerEvent] {
        events.filter(predicate)
    }

    /// `true` when any recorded action trace entry contains `fragment`.
    public func tracedAction(containing fragment: String) -> Bool {
        actionTrace.contains { $0.contains(fragment) }
    }

    /// A one-line summary for a test failure message. Always includes the seed, because the seed is
    /// what makes the failure reproducible.
    public var diagnosticSummary: String {
        let seed = String(groundTruth.seed, radix: 16, uppercase: true)
        let failureText = failure.map { "\($0)" } ?? setupFailure ?? "none"
        return "seed=0x\(seed) frames=\(frames.count)/\(groundTruth.frames.count) "
            + "keyframes=\(keyframeCount) state=\(serverState.rawValue) "
            + "challenges=\(challengeCount) authed=\(authenticatedRequestCount) "
            + "losses=\(groundTruth.injectedPacketLosses.count) failure=\(failureText)"
    }
}
