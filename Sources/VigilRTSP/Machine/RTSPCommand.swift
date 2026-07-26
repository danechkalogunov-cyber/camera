//
//  RTSPCommand.swift
//  VigilRTSP
//
//  The inputs of the session machine: what `VigilCore` asks it to do, and the thirteen states it
//  reports back.
//  Implements docs/spec-rtsp.md §14.4 and docs/API_CONTRACT.md §4.3.
//

import Foundation
import VigilProtocols

// MARK: - RTSPSessionState

/// Where the session is. Reported through `.stateChanged` before any action the new state causes,
/// so a driver can drive its UI from the action stream alone.
public enum RTSPSessionState: Sendable, Hashable {
    /// Constructed, nothing sent.
    case idle
    /// `OPTIONS` is outstanding.
    case awaitingOptions
    /// `DESCRIBE` is outstanding.
    case awaitingDescribe
    /// A request is being re-sent with credentials after a `401`.
    case authenticating(retryOf: RTSPMethod)
    /// `SETUP` is outstanding for track `trackIndex` of `of` tracks.
    case settingUp(trackIndex: Int, of: Int)
    /// `PLAY` is outstanding.
    case awaitingPlay
    /// Playing. Media is flowing, or the first-media timer is waiting for it.
    case playing
    /// `PAUSE` is outstanding.
    case awaitingPause
    /// Paused; the session is alive and keepalives continue.
    case paused
    /// A seek is outstanding (recorded playback; lands with the playback extension).
    case seeking
    /// `TEARDOWN` is outstanding.
    case tearingDown
    /// The connection is finished with, cleanly.
    case closed
    /// Terminal failure. No further action will be produced.
    case failed(RTSPError)
}

// MARK: - FrameStepDirection

/// Direction of a single-frame step during recorded playback.
public enum FrameStepDirection: String, Sendable, Hashable, CaseIterable {
    case forward, backward
}

// MARK: - RTSPCommand

/// A control instruction from `VigilCore`.
///
/// At most one request is outstanding at a time — RTSP pipelining is unreliable across Hikvision
/// firmware — so a command arriving while a request is in flight queues, bounded by
/// `RTSPSessionConfig.maxCommandQueueDepth`.
///
/// The seek, frame-step and downstream-pressure commands of docs/spec-rtsp.md §14.4 belong to the
/// recorded-playback extension (`RTSPSessionMachine+Playback.swift`), which is outside the
/// first-light slice; they are deliberately absent rather than present and unimplemented.
public enum RTSPCommand: Sendable, Hashable {
    /// The normal entry point: `OPTIONS` → `DESCRIBE` → `SETUP`* → `PLAY`.
    case start
    /// `DESCRIBE` only, with no `OPTIONS` and no `SETUP`.
    ///
    /// This is the R1.2 probe ladder's primitive: the user must never be asked for a stream URL,
    /// so `VigilCore` drives one machine per candidate path and keeps the first that answers `200`
    /// with an SDP containing a supported video codec. A `401` never advances the ladder — it
    /// means the path is right and the credentials must be applied — and `404`/`451`/`455`/`460`
    /// close with `.ladderAdvance` so the driver moves on without counting a failure.
    case describeOnly
    /// `PLAY`. `rangeText` goes on the wire verbatim (`npt=0.000-`, `clock=…`); `nil` means the
    /// machine picks `npt=0.000-`, which is what every Hikvision device expects for live.
    case play(rangeText: String? = nil, scale: Double? = nil, disableRateControl: Bool? = nil)
    /// `PAUSE`.
    case pause
    /// Send a keepalive immediately, whatever the timer says.
    case keepaliveNow
    /// `GET_PARAMETER` with the named parameters, or no body when the list is empty.
    case getParameter(names: [String])
    /// `SET_PARAMETER` with one `name: value` line.
    case setParameter(name: String, value: String)
    /// `TEARDOWN`, then close.
    case teardown
    /// Frame and write an RTCP packet built by `VigilRTP` on an interleaved channel.
    case sendRTCP(channel: UInt8, payload: Data)
    /// Ask the transport to pause or resume reading. Used by `Rate-Control: no` playback, where
    /// TCP backpressure is the flow-control mechanism.
    case setReadBackpressure(Bool)
}
