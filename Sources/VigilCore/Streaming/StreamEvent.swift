//
//  StreamEvent.swift
//  VigilCore
//
//  Everything one camera's controller tells the rest of the app, on one stream.
//  Implements docs/spec-core.md §7.2 and docs/API_CONTRACT.md §4.8 / §5.12
//  (`Streaming/StreamEvent.swift`).
//
//  Slice scope: the recording, snapshot, health and quality-change cases of spec-core §7.2 are
//  absent because nothing in the first-light column produces them. The lifecycle and trouble cases
//  are complete, because those are what the connect form and the status line render.
//

#if os(macOS)

import Foundation
import VigilProtocols

// MARK: - AuthScheme

/// Which HTTP authentication scheme the device accepted.
public enum AuthScheme: String, Sendable, Hashable, Codable {
    /// RFC 7616 Digest. What every Hikvision device supports and what Vigil prefers.
    case digest
    /// RFC 7617 Basic. Only ever used over TLS, or when the user opted in explicitly.
    case basic
}

// MARK: - EndReason

/// Why a controller stopped.
public enum EndReason: String, Sendable, Hashable, Codable {
    /// The user asked.
    case userRequested
    /// The coordinator needed the decode budget elsewhere.
    case coordinatorEvicted
    /// The app is quitting.
    case appTerminating
    /// The camera was disabled in its settings.
    case cameraDisabled
    /// The camera record was deleted.
    case cameraDeleted
    /// A failure nothing can retry.
    case unrecoverableError
    /// The password was rejected. Kept separate from `unrecoverableError` because the UI's next
    /// step is a password field, not a diagnostics bundle.
    case authenticationFailed
}

// MARK: - StreamWarning

/// Non-fatal trouble, shown as a transient chip rather than a failure.
public enum StreamWarning: Sendable, Hashable {
    /// UDP was requested and TCP was used instead.
    case udpFellBackToTCP
    /// The SDP carried no `sprop-*` parameter sets, so decoding waits for in-band ones. Normal on
    /// Hikvision and not a problem — surfaced only because it explains a slower first picture.
    case parameterSetsMissingFromSDP
    /// The SDP offered more than one video track and Vigil took the first.
    case secondTrackIgnored
    /// An audio track was offered and skipped. The slice never sets up audio.
    case audioTrackIgnored(encodingName: String)
    /// RTP timestamps jumped by more than a plausible frame interval.
    case timestampDiscontinuity(seconds: Double)
    /// Packets were lost. Carries the count so the UI can decide whether to mention it.
    case packetLoss(count: Int)
}

// MARK: - StreamEvent

/// One observation from a controller. Delivered on a bounded broadcaster, newest-64, so a slow
/// observer drops its own oldest elements and never stalls the media path (API_CONTRACT §2 R-27).
public enum StreamEvent: Sendable {

    // Lifecycle

    /// The state changed, with what to narrate.
    case stateChanged(from: StreamState, to: StreamState, detail: StateDetail)

    /// A connect attempt began. `endpoint` is `host:port/path`, never a URL with userinfo.
    case connectAttemptStarted(attempt: Int, endpoint: String)

    /// The R1.2 ladder resolved a path. The camera record should be saved with the winner attached
    /// so the ladder never runs for this device again.
    case pathResolved(RTSPPathCandidate, capabilities: DeviceCapabilities)

    /// The device accepted our credentials.
    case authenticated(scheme: AuthScheme)

    /// The stream's shape is known.
    case formatResolved(StreamFormat)

    /// The first RTP packet arrived, measured from the start of the connect attempt.
    case firstPacketReceived(afterConnect: Duration)

    /// The first complete access unit was assembled, measured from `start()`.
    ///
    /// Named for what this layer can actually observe. `firstFrameDecoded` is `VigilVideo`'s to
    /// report, because only the decoder knows a picture came out (API_CONTRACT §2 R-24 chain).
    case firstFrameAssembled(afterStart: Duration)

    /// The controller stopped.
    case ended(reason: EndReason)

    // Steady state

    /// Telemetry, once per second.
    case statistics(StreamStatistics)

    /// A keyframe was assembled, with its presentation time.
    case keyframe(MediaTimestamp)

    // Trouble

    /// Non-fatal trouble.
    case warning(StreamWarning)

    /// A failure. `isFatal` is true when nothing will be retried without the user acting.
    case error(StreamError, isFatal: Bool)

    /// A reconnect is scheduled. The UI renders the countdown from `delay`.
    case reconnectScheduled(attempt: Int, delay: Duration, cause: StreamError)
}

#endif
