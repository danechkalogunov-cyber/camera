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

    /// The transport to negotiate. TCP interleaving and UDP unicast are supported.
    public var transport: RTSPTransportKind = .tcpInterleaved

    /// First RTP port used by UDP unicast. Each subsequent track consumes the next even/odd pair.
    public var udpClientPortBase: UInt16 = 50_000

    /// Returns the local port pair reserved for a SETUP position, or `nil` if it would overflow.
    public func udpClientPorts(forTrack position: Int) -> RTSPUDPPortPair? {
        guard position >= 0, position <= (Int(UInt16.max) - Int(udpClientPortBase) - 1) / 2 else {
            return nil
        }
        let rtp = UInt16(Int(udpClientPortBase) + position * 2)
        return RTSPUDPPortPair(rtp: rtp, rtcp: rtp + 1)
    }

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

    // MARK: Initial PLAY

    /// The `Scale:` the handshake's own `PLAY` carries, or `nil` for normal speed.
    ///
    /// ⚠️ SET HERE RATHER THAN SENT LATER, AND THAT IS A FINDING, NOT A PREFERENCE. A second `PLAY`
    /// on an established session is the textbook way to change speed, and `perform(.play(scale:))`
    /// can send one — but a DS-I256 on V5.5.6 refuses a second `PLAY` outright, which is what
    /// `docs/PLAYBACK-LATENCY.md` records after in-session seeking was tried on hardware and
    /// reverted. The handshake's `PLAY` is the one this firmware honours, so a speed change is a
    /// reconnect carrying the new scale, and that costs a seek's worth of latency by design.
    ///
    /// Negative values mean reverse playback. `RTSPScale.serialized` writes the wire form.
    public var initialScale: Double?

    /// Whether the handshake's `PLAY` asks the device to stop pacing (`Rate-Control: no`).
    ///
    /// Wanted above 2×: a camera that keeps pacing at wall-clock speed delivers an 8× request as
    /// eight seconds of video per eight seconds, which is not fast-forward. Off at normal speed,
    /// where pacing is exactly what is wanted.
    public var initialDisableRateControl = false

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

    /// Credentialed requests this connection may write **since the last one the device accepted**.
    ///
    /// This is how the shared per-device budget reaches the wire: a caller debits strikes from
    /// `LockoutGovernor.reserve` and hands the number it was granted to this field, so the pure
    /// machine stays synchronous and the allowance is just a number it was constructed with
    /// (docs/RULING-LOCKOUT.md §2.5).
    ///
    /// **Zero is a legitimate and important value.** A rung of the path ladder that has been granted
    /// nothing still answers "does this path exist" against a device that does not challenge it; a
    /// rung that meets a `401` with an allowance of zero returns terminal `.authRejected` **without
    /// writing an `Authorization` header at all**, which is the honest answer and stops the ladder.
    ///
    /// Two by default, matching `maxAuthAttemptsPerRequest` and `LockoutGovernor`'s own budget.
    public var credentialedAttemptAllowance = 2

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
    public var decoderLimits = RTSPWireDecoder.Limits()

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
