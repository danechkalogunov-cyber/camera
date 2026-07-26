//
//  RTSPSessionConfig.swift
//  VigilRTSP
//
//  Everything the session machine needs to know before it sends a byte: the target URL, the
//  timeouts, and the safety caps that keep a wrong password from locking the user out of their own
//  camera. Also `RTSPCloseReason`.
//  Implements docs/spec-rtsp.md §14.2, §17 and docs/API_CONTRACT.md §4.3, §2 R-25.
//
//  `RTSPTimerID` is **not** declared here: it lives in `VigilProtocols` because `RTSPError.timeout`
//  carries one (API_CONTRACT §3.9). docs/API_CONTRACT.md §5.4 places it in this file; the type
//  already existing in the shared layer wins.
//

import Foundation
import VigilProtocols

// MARK: - RTSPCloseReason

/// Why the driver is being told to close the connection.
///
/// The distinction matters to `VigilCore`: `.normal` must not trigger a reconnect, `.error` must,
/// `.redirect` and `.ladderAdvance` mean "reconnect immediately, to the endpoint I just gave you,
/// without counting this against the backoff".
public enum RTSPCloseReason: String, Sendable, Hashable, CaseIterable {
    /// A `TEARDOWN` completed, or the peer asked us to stop.
    case normal
    /// The session failed; the driver decides whether to reconnect.
    case error
    /// A `301`/`302`/`REDIRECT` sent us elsewhere.
    case redirect
    /// This URL candidate lost the R1.2 probe ladder; try the next one.
    case ladderAdvance
}

// MARK: - RTSPSessionConfig

/// Static configuration for one RTSP session.
///
/// Defaults are the constants of docs/spec-rtsp.md §17 as amended by API_CONTRACT §2 R-25 (the
/// auth cap is **2**, not 4). Every duration is a stdlib `Duration`; the machine adds them to the
/// injected `MediaInstant` and never reads a clock.
public struct RTSPSessionConfig: Sendable {

    // MARK: Target

    /// The URI every request line carries, and the DESCRIBE target. Credentials are never part of
    /// it — `RTSPURL` strips userinfo, and the digest layer takes the credential separately.
    public var url: RTSPURL

    /// `User-Agent` on every request. Some Hikvision firmware answers `400` to an empty one.
    public var userAgent = "Vigil/1.0"

    /// The transport to negotiate. The slice supports `.tcpInterleaved` only; anything else is
    /// refused at `SETUP` time with a clear error rather than negotiated badly.
    public var transport: RTSPTransportKind = .tcpInterleaved

    /// Set by the driver once TLS is up. Informational here, except that it permits Basic auth.
    public var isTLS = false

    /// Whether Basic auth may be sent over a plaintext connection. Off by default: Basic puts the
    /// password on the wire in base64, and every Hikvision device supports Digest.
    public var allowBasicOverPlaintext = false

    // MARK: Track selection

    /// Whether to `SETUP` an audio track. **Off by default**, because the first-light slice
    /// (.vigil/SLICE.md) does not decode audio, and an unused audio track costs a round trip and a
    /// second interleaved channel pair.
    public var setupAudio = false

    /// Whether to `SETUP` an ONVIF metadata track. Off; nothing consumes it yet.
    public var setupMetadataTrack = false

    /// Hard cap on tracks to negotiate, whatever the SDP offers.
    public var maxTracks = 4

    // MARK: Timeouts

    /// How long a request may go unanswered.
    public var requestTimeout: Duration = .seconds(5)

    /// The shorter timeout used for `TEARDOWN`: we are closing anyway.
    public var teardownTimeout: Duration = .seconds(2)

    /// How long after a successful `PLAY` we wait for the first media frame.
    public var firstMediaTimeout: Duration = .seconds(5)

    /// How long a playing session may go with no media at all before it is declared stalled.
    public var dataIdleTimeout: Duration = .seconds(8)

    /// Lower clamp on the keepalive interval.
    public var keepaliveFloor: Duration = .seconds(5)

    /// Upper clamp on the keepalive interval.
    public var keepaliveCeiling: Duration = .seconds(20)

    /// Session timeout assumed when the `Session` header omits one, and the clamp applied to the
    /// value when it does not: 10…600 s. A `timeout=0` has been seen in the field.
    public var defaultSessionTimeout: Duration = .seconds(60)

    // MARK: Caps

    /// Credentialed `401`s tolerated before authentication is declared terminal.
    ///
    /// **Two, never more** (API_CONTRACT §2 R-25). Hikvision firmware locks an account for 30
    /// minutes after about five failed logins, including from the camera's own web UI, so a
    /// generous retry budget is how an app locks its user out of their own camera.
    public var maxAuthAttemptsPerRequest = 2

    /// Redirects followed before giving up.
    public var maxRedirects = 3

    /// Framing resynchronisations tolerated in a 60 s sliding window. Silent, endless resyncing is
    /// worse than a 400 ms reconnect.
    public var maxResyncsPerMinute = 3

    /// Commands that may queue behind the outstanding request.
    public var maxCommandQueueDepth = 8

    /// Media frames buffered between the first frame and the `PLAY` response, after which the
    /// oldest is dropped. Media must never be emitted before its track's timing seed.
    public var maxPreplayMediaFrames = 64

    /// Set for firmware that closes the connection on `GET_PARAMETER`; the keepalive then uses
    /// `OPTIONS` instead.
    public var closesOnGetParameter = false

    /// Limits handed to the framing decoder.
    public var decoderLimits = RTSPInterleavedDecoder.Limits()

    // MARK: Initialisation

    /// Builds a configuration targeting `url` with every default in place.
    public init(url: RTSPURL) {
        self.url = url
    }

    // MARK: Derived

    /// `clamp(sessionTimeout / 3, keepaliveFloor, keepaliveCeiling)`.
    ///
    /// A third of the timeout survives two consecutive lost keepalives; the 20 s ceiling keeps
    /// dead-link detection fast enough that the UI reconnects before a user notices.
    func keepaliveInterval(sessionTimeout: Duration) -> Duration {
        let third = Duration.nanoseconds(sessionTimeout.wholeNanoseconds / 3)
        if third < keepaliveFloor { return keepaliveFloor }
        if third > keepaliveCeiling { return keepaliveCeiling }
        return third
    }

    /// Clamps an advertised `Session` timeout into 10…600 s, mapping zero to the default.
    func clampedSessionTimeout(seconds: Int) -> Duration {
        guard seconds > 0 else { return defaultSessionTimeout }
        return .seconds(min(max(seconds, 10), 600))
    }
}
