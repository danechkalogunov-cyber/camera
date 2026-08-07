//
//  LiveConnectionState.swift
//  VigilUI
//
//  What the video screen is currently showing, and the words that go with it: the connecting
//  narration ladder, the measured degradation causes and the offline countdown.
//  macOS-only. Implements docs/UX.md §12.4, §12.5, §12.6, §12.7, §12.12 and §14.
//

#if os(macOS)

import Foundation

import SwiftUI

// MARK: - LiveConnectionState

/// The four states a single camera's screen can be in.
///
/// A reduction of `StreamState`'s eleven cases (spec-core.md §7.3) to what the picture actually
/// looks like: the five transient states collapse into ``connecting(_:)`` because the user reads
/// the narration rather than the state name, and `failed`/`reconnecting`/`stopped` collapse into
/// ``offline(_:)``, which carries the diagnosis that tells them apart in words.
package enum LiveConnectionState: Sendable, Hashable {

    /// Working towards a first frame. The payload is what to narrate — but **only** after 250 ms
    /// (UX.md §15.1).
    case connecting(ConnectingPhase)

    /// Media flowing, health nominal.
    case live

    /// Media flowing, health below threshold. The payload is the measured cause, because "video
    /// may stutter" without a number is a rumour (UX.md §14.1 rule 4).
    case degraded(DegradedCause)

    /// No media. The last frame is held and dimmed; the payload says whether we are counting down
    /// to a retry, and why we are here.
    case offline(OfflineDetail)

    /// Stopped by the user. The last frame is on the glass and nothing is being asked of the
    /// camera.
    ///
    /// ⛔ ITS OWN CASE, BECAUSE THE THREE IT WOULD OTHERWISE BORROW ARE ALL LIES. A stopped session
    /// has `StreamState.idle`, which mapped to `.connecting(.resolving)` — so pressing stop showed
    /// a spinner that never resolved, on a picture that was exactly where the user left it.
    /// `.offline` claims a connection was lost and offers to retry; `.live` claims new frames are
    /// arriving. Stopping is a thing the user did, and the interface has to say so.
    case paused

    /// Whether the connect choreography's timers should be running.
    package var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    /// Whether a picture is being presented. The video layer stays mounted in every state — see
    /// ``LiveVideoView`` — but only these two are showing new frames.
    package var isShowingVideo: Bool {
        switch self {
        // `paused` is included: the tile is still showing the frame it was stopped on, and the
        // failure overlays must not cover it.
        case .live, .degraded, .paused: return true
        case .connecting, .offline: return false
        }
    }

    /// The dot that belongs beside the status line (UX.md §12.12).
    package var dot: VLiveDot.Status {
        switch self {
        case .connecting: return .connecting
        case .live: return .live
        case .degraded: return .degraded
        case .paused: return .offline
        case .offline(let detail):
            // A credential failure gets its own dot — red with a slash — because it is the one
            // offline state Vigil will never retry out of on its own (UX.md §12.7).
            guard let diagnosis = detail.diagnosis else { return .offline }
            return diagnosis.fieldToFocus == .password ? .authFailed : .offline
        }
    }

    /// The one-word status, set in `Caption2` uppercase beside the dot (§4.2).
    @MainActor
    package var statusWord: LocalizedStringKey {
        switch self {
        case .connecting: return "Connecting"
        case .live: return "Live"
        case .degraded: return "Degraded"
        case .paused: return "Paused"
        case .offline: return "Offline"
        }
    }
}

// MARK: - ConnectingPhase

/// The narration ladder shown under the connecting ring.
///
/// The phases are the real `StreamController` states, not a decorative progress fiction: each line
/// appears because that stage actually started (UX.md §12.4, spec-core.md §7.3).
package enum ConnectingPhase: Sendable, Hashable, CaseIterable {

    /// Loading credentials, cached capabilities, DNS.
    case resolving

    /// TCP connect to the RTSP port.
    case connecting

    /// Handling the `401` and the Digest round trip.
    case authenticating

    /// `DESCRIBE` sent, waiting for the SDP.
    case negotiating

    /// `SETUP` per track, then `PLAY`.
    case opening

    /// Playing, but no RTP has arrived yet.
    case waitingForVideo

    /// RTP is arriving, but no keyframe has completed a picture yet.
    case waitingForKeyframe

    /// The line shown for this phase.
    ///
    /// - Parameter host: the camera's address, named in the first line so the user can see we are
    ///   talking to the right device.
    @MainActor
    package func narration(host: String) -> Text {
        switch self {
        case .resolving:
            return Text("Looking up \(host)…", bundle: .vigilUI)
        case .connecting:
            return Text("Connecting…", bundle: .vigilUI)
        case .authenticating:
            return Text("Signing in…", bundle: .vigilUI)
        case .negotiating:
            return Text("Negotiating stream…", bundle: .vigilUI)
        case .opening:
            return Text("Opening video channel…", bundle: .vigilUI)
        case .waitingForVideo:
            return Text("Waiting for video…", bundle: .vigilUI)
        case .waitingForKeyframe:
            return Text("Waiting for a keyframe…", bundle: .vigilUI)
        }
    }
}

// MARK: - DegradedCause

/// Why a flowing stream is unhealthy, with the number that says so.
///
/// Thresholds are `HealthMonitor`'s, on a 3 s sliding window: loss > 1.5 %, jitter > 80 ms, decode
/// queue > 8 frames, or fps below 60 % of the negotiated rate for 3 s (UX.md §12.5).
package enum DegradedCause: Sendable, Hashable {

    /// Packet loss, as a **fraction** (0.031 = 3.1 %) so the formatter can localise the percent
    /// sign and its spacing — Russian writes `3,1 %` with a space, English `3.1%` without
    /// (UX.md §14.1 rule 9).
    case packetLoss(fraction: Double)

    /// Inter-arrival jitter, in milliseconds.
    case jitter(milliseconds: Double)

    /// Frames waiting to be decoded.
    case decodeQueue(frames: Int)

    /// Presented frame rate against the rate the camera negotiated.
    case lowFrameRate(fps: Double, negotiated: Double)

    /// Informational: we already switched transport and expect this to recover. Shown for 4 s and
    /// then faded, because it is news rather than a problem (UX.md §12.5).
    case switchedToTCP

    /// The remedy chip offered beside the banner, or `nil` when there is nothing to offer.
    package var remedy: ConnectRemedy? {
        switch self {
        case .packetLoss, .jitter, .lowFrameRate: return .switchToTCP
        case .decodeQueue: return nil
        case .switchedToTCP: return nil
        }
    }

    /// Whether the banner retires itself. Only the informational case does.
    package var isTransient: Bool {
        self == .switchedToTCP
    }

    /// The measured sentence.
    ///
    /// Numbers are formatted by `FormatStyle`/`Measurement`, never by hand: the unit, the decimal
    /// separator and the spacing before `%` are all locale decisions (UX.md §14.2).
    @MainActor
    package var message: Text {
        switch self {
        case .packetLoss(let fraction):
            let value = fraction.formatted(.percent.precision(.fractionLength(1)))
            return Text("\(value) packet loss — video may stutter.", bundle: .vigilUI)
        case .jitter(let milliseconds):
            let value = Measurement(value: milliseconds, unit: UnitDuration.milliseconds)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided))
            return Text("\(value) of jitter — video may stutter.", bundle: .vigilUI)
        case .decodeQueue(let frames):
            return Text("\(frames) frames waiting to decode — video may lag.", bundle: .vigilUI)
        case .lowFrameRate(let fps, let negotiated):
            let shown = fps.formatted(.number.precision(.fractionLength(0)))
            let expected = negotiated.formatted(.number.precision(.fractionLength(0)))
            return Text("Showing \(shown) of \(expected) frames per second.", bundle: .vigilUI)
        case .switchedToTCP:
            return Text("Switched to TCP for stability.", bundle: .vigilUI)
        }
    }
}

// MARK: - OfflineDetail

/// Why there is no picture, and when we will try again.
///
/// ⛔ The countdown is a **number**, updated once a second, and never a spinner: "Reconnecting in
/// 4 s (attempt 3)" answers the question a spinner refuses to (UX.md §12.6).
package struct OfflineDetail: Sendable, Hashable {

    /// Which attempt the next retry will be. `1` for the first.
    package var attempt: Int

    /// Whole seconds until the next attempt, or `nil` when there is no countdown — because the
    /// diagnosis is terminal, because the network is down, or because we have given up counting.
    package var retryInSeconds: Int?

    /// When a frame was last presented, for the "Last seen" line.
    package var lastSeen: Date?

    /// True after five consecutive failures, when the interval pins at 30 s and the copy changes
    /// to "Still can't reach this camera." (UX.md §12.6).
    package var isPersistent: Bool

    /// The named cause, when the doctor produced one. Drives the card's title, its remedies, and
    /// whether a retry is offered at all.
    package var diagnosis: ConnectDiagnosis?

    /// Creates a detail record.
    package init(attempt: Int = 1,
                 retryInSeconds: Int? = nil,
                 lastSeen: Date? = nil,
                 isPersistent: Bool = false,
                 diagnosis: ConnectDiagnosis? = nil) {
        self.attempt = attempt
        self.retryInSeconds = retryInSeconds
        self.lastSeen = lastSeen
        self.isPersistent = isPersistent
        self.diagnosis = diagnosis
    }

    /// Whether Vigil will retry on its own.
    ///
    /// ⛔ A wrong password is never retried automatically: that is how devices lock out, and it is
    /// a deliberate, important behaviour rather than an omission (UX.md §12.7).
    package var retriesAutomatically: Bool {
        diagnosis?.allowsAutomaticRetry ?? true
    }
}

// MARK: - LiveCameraIdentity

/// What the screen needs to know about the camera in order to name it.
package struct LiveCameraIdentity: Sendable, Hashable {

    /// The camera's stable identifier, which selects its identity colour.
    package let id: UUID

    /// The display name.
    package let name: String

    /// The address, named in the first narration line and in every failure message.
    package let host: String

    /// Persisted palette slot, or `nil` for the stable identifier-derived fallback.
    package let identityIndex: Int?

    /// Creates an identity.
    package init(id: UUID, name: String, host: String, identityIndex: Int? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.identityIndex = identityIndex
    }

    /// The camera's first letter, which accompanies the identity colour everywhere so that the
    /// colour is never the sole carrier of identity (DESIGN.md §3.4).
    package var initial: Character? {
        name.first
    }

    /// The identity colour, assigned round-robin and derived deterministically from ``id`` when no
    /// explicit assignment has been persisted (DESIGN.md §3.4).
    @MainActor
    package var colour: SwiftUI.Color {
        identityIndex.map(VTheme.Color.Ident.colour(at:)) ?? VTheme.Color.Ident.colour(for: id)
    }
}

#endif  // os(macOS)
