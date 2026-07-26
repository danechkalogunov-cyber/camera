//
//  StreamState.swift
//  VigilCore
//
//  The eleven states one camera's live path can be in, and the detail the UI narrates alongside
//  them.
//  Implements docs/spec-core.md §7.3 and docs/API_CONTRACT.md §4.8 / §5.12
//  (`Streaming/StreamState.swift`).
//

#if os(macOS)

import Foundation

// MARK: - StreamState

/// Where one camera's live path is.
///
/// `Codable` because the health ring and the diagnostics bundle persist it; the raw values are
/// stable and must not be renamed.
public enum StreamState: String, Sendable, Hashable, Codable, CaseIterable {

    /// Constructed, never started.
    case idle
    /// Loading the credential and the cached capabilities, and resolving the path.
    case resolving
    /// Connecting the socket to the RTSP port.
    case connecting
    /// Answering a `401` and re-sending with credentials.
    case authenticating
    /// `DESCRIBE` is out; the SDP has not arrived.
    case describing
    /// `SETUP` per track, then `PLAY`.
    case settingUp
    /// Media is flowing and health is nominal.
    case playing
    /// Media is flowing but health is below threshold.
    case degraded
    /// Waiting out the backoff, or waiting for the network to come back.
    case reconnecting
    /// Needs the user: a wrong password, a closed port, a codec we cannot play.
    case failed
    /// Stopped by the user or by the coordinator. Reusable — `start()` runs again from here.
    case stopped

    /// True while media is flowing.
    public var isActive: Bool { self == .playing || self == .degraded }

    /// True while the connect sequence is running, which is when the UI shows the skeleton and the
    /// narration string.
    public var isTransient: Bool {
        switch self {
        case .resolving, .connecting, .authenticating, .describing, .settingUp: true
        default: false
        }
    }

    /// True when this state holds a decode lease.
    public var holdsDecodeLease: Bool { isActive }

    /// The localised narration shown under the connecting skeleton (spec-core §7.3).
    ///
    /// `playing` narrates the pre-warm wait rather than the steady state, because the only time the
    /// UI shows a narration for `playing` is before the first picture.
    public var narration: String {
        switch self {
        case .idle: "Ready."
        case .resolving: "Looking up camera…"
        case .connecting: "Connecting…"
        case .authenticating: "Signing in…"
        case .describing: "Negotiating stream…"
        case .settingUp: "Starting video…"
        case .playing: "Waiting for the first keyframe…"
        case .degraded: "The stream is struggling."
        case .reconnecting: "Reconnecting…"
        case .failed: "Cannot connect."
        case .stopped: "Stopped."
        }
    }

    /// Rough progress through the connect sequence, for the skeleton's progress hint. `nil` once
    /// the sequence is over, in either direction.
    public var connectProgress: Double? {
        switch self {
        case .resolving: 0.15
        case .connecting: 0.35
        case .authenticating: 0.55
        case .describing: 0.70
        case .settingUp: 0.85
        default: nil
        }
    }
}

// MARK: - StateDetail

/// The context that goes with a state change: what to narrate, how far along the connect is, which
/// attempt this is, when the next one starts, and what went wrong last.
public struct StateDetail: Sendable, Hashable {

    /// Localised sentence shown under the skeleton or in the status line.
    public var narration: String

    /// `0...1` through the connect sequence, or `nil` when the state is not part of it.
    public var progress: Double?

    /// Which connect attempt this is, from zero. Frozen while the network is down, so an outage
    /// does not exhaust the ladder (spec-core §7.6 rule 4).
    public var attempt: Int

    /// When the next attempt begins, so the UI can render "Retrying in 4 s" and a **Retry Now**
    /// button. `nil` unless the state is `.reconnecting` or `.failed` with a cold retry armed.
    public var nextRetryAt: Date?

    /// The failure that caused this state, when one did.
    public var underlying: StreamError?

    /// Builds a detail. `narration` defaults to the state's own sentence, which is what every
    /// transition but a failure wants.
    public init(narration: String,
                progress: Double? = nil,
                attempt: Int = 0,
                nextRetryAt: Date? = nil,
                underlying: StreamError? = nil) {
        self.narration = narration
        self.progress = progress
        self.attempt = attempt
        self.nextRetryAt = nextRetryAt
        self.underlying = underlying
    }

    /// The detail for a plain transition into `state`.
    public static func plain(_ state: StreamState, attempt: Int = 0) -> StateDetail {
        StateDetail(narration: state.narration, progress: state.connectProgress, attempt: attempt)
    }

    /// The detail for a transition caused by a failure. The error's own sentence replaces the
    /// state's, because "Cannot connect." helps nobody next to "The camera rejected the password."
    public static func failure(_ error: StreamError,
                               state: StreamState,
                               attempt: Int = 0,
                               nextRetryAt: Date? = nil) -> StateDetail {
        StateDetail(narration: error.message,
                    progress: nil,
                    attempt: attempt,
                    nextRetryAt: nextRetryAt,
                    underlying: error)
    }
}

#endif
