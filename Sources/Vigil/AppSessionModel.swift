//
//  AppSessionModel.swift
//  Vigil
//
//  The app-level object: owns the one `StreamController` the slice runs, turns its event stream
//  into the state the two screens render, and implements the launch → live-video flow of R1.
//  macOS-only. See docs/API_CONTRACT.md §4.12, docs/spec-core.md §7 and REQUIREMENTS-CUSTOMER §R1.
//

#if os(macOS)

import Foundation
import Observation

import VigilCore
import VigilProtocols
import VigilRender
import VigilUI
import VigilVideo

// MARK: - AppSessionModel

/// Everything the two screens of the slice need, and nothing else.
///
/// One camera, one controller, one window. This is the only type in the app that touches
/// `VigilCore`'s streaming API, and the only one that both screens read — `VigilUI` cannot see the
/// app target, so its views take values and closures and this is what supplies them.
///
/// **Isolation.** `@MainActor` throughout, because every property here is read during SwiftUI body
/// evaluation. `StreamController` is an actor, so every call into it is `await`ed from a task that
/// inherits this isolation; nothing blocks the main thread.
///
/// **What it deliberately does not do:** no discovery, no channel enumeration, no Stream Doctor,
/// no library persistence. Those are named in R1 and in the manifest and land in W2–W6; the slice's
/// job is to prove the column from socket to pixel (`.vigil/SLICE.md`).
@MainActor
@Observable
final class AppSessionModel {

    // MARK: - Nested Types

    /// Which of the two screens the window is showing.
    ///
    /// The move to `.live` happens the instant the user presses Return — not when the first frame
    /// arrives. The connecting narration belongs on the video surface (`LiveConnectionState`), so
    /// that the ten seconds R1 allows are spent watching the stream come up rather than watching a
    /// spinner over a form.
    enum Phase: Equatable {
        /// The connect form: address, account, password.
        case connect
        /// The video surface and its status line.
        case live
    }

    // MARK: - Stored Properties
    //
    // The type is split across `AppSessionModel.swift` and `AppSessionModel+Session.swift`, and
    // Swift's `private`/`private(set)` are file-scoped, so the members the session half writes are
    // internal here. Nothing outside this target can see the type at all: `Vigil` is the leaf
    // executable and no other module depends on it.

    /// The connect form's fields, validation and last diagnosis.
    ///
    /// Owned here rather than in the view because `ConnectFormView` takes a `Binding` and says so:
    /// "state lives in the caller so the app can prefill an address … and drive the in-flight and
    /// failure states from `VigilCore`".
    var form = ConnectFormState()

    /// Which screen is showing.
    var phase: Phase = .connect

    /// The live controller, handed to the video screen so it can attach its display layer.
    var controller: StreamController?

    /// The camera currently being connected or streamed.
    var camera: Camera?

    /// Time from `start()` to the first assembled access unit. The R1.7 measurement.
    var firstFrameLatency: Duration?

    /// The controller's last reported state.
    var streamState: StreamState = .idle

    /// Whether any RTP has arrived, which is what separates "no video is arriving" from "waiting
    /// for a keyframe" in the connecting narration.
    var hasFirstPacket: Bool = false

    /// Whether a complete access unit has been assembled. See `StreamEvent.firstFrameAssembled`.
    ///
    /// ⛔ This is **not** "the user can see the camera", and it must never be what says `Live`:
    /// an access unit that assembled can still fail to decode, and the difference on screen is a
    /// black well wearing a `Live` chip with no narration — the exact failure DESIGN.md §3.6 exists
    /// to prevent. ``renderState`` is the authority on pixels; this drives the narration ladder and
    /// the R1.7 latency number.
    var isReceivingMedia: Bool = false

    /// The mounted tile's own render state, or `nil` while no tile is mounted.
    ///
    /// Published by `TileVideoSink.follow(_:onRenderState:)` when `VideoTile.makeNSView` attaches a
    /// view. `TileRenderState` is `@Observable`, so reading ``isDisplayingPicture`` during a body
    /// evaluation subscribes to it and the overlay clears on the frame the picture actually appears.
    /// The `nil` → non-`nil` transition is itself observed, because this property is tracked.
    var renderState: TileRenderState?

    /// The latest 1 Hz telemetry, used for the degraded banner's measured cause.
    var statistics = StreamStatistics()

    /// The named cause of the current failure, in `VigilUI`'s vocabulary.
    var diagnosis: ConnectDiagnosis?

    /// Which reconnect attempt we are on. `1` until the controller says otherwise.
    var attempt: Int = 1

    /// Seconds until the next reconnect, when one is scheduled.
    var retryInSeconds: Int?

    /// When media was last flowing, for the offline card's "Last seen" line.
    var lastSeen: Date?

    /// The attach point the video screen's tile registers with. One per window, not one per
    /// session: SwiftUI keeps the tile mounted across a reconnect, and so must its frame source.
    let frames = FrameStreamHandle()

    let dependencies: CoreDependencies
    let credentials: CredentialStore
    let defaults: UserDefaults
    let tileSink = TileVideoSink()
    var sessionTask: Task<Void, Never>?
    var eventTask: Task<Void, Never>?
    var decodeTask: Task<Void, Never>?
    var frameContinuation: AsyncStream<EncodedFrame>.Continuation?
    var pipeline: DecodePipeline?

    /// When the current connect attempt began, for the video screen's elapsed counter.
    var attemptStartedAt: Date?

    /// When a keyframe recovery was last forced, so a decoder that keeps asking cannot put the
    /// session into a restart loop.
    var lastRecoveryAt: Date?

    /// Keychain handle of the camera currently being connected, so the first frame can be
    /// remembered against the right item.
    var activeRef: CredentialRef?

    /// The RTSP path the ladder settled on, persisted only once a frame has arrived.
    var resolvedPath: String?

    /// Set by the "Try Port 8554" remedy, and only by it.
    var rtspPort: Int = 554

    /// Whether the launch-time resume has already been attempted.
    var hasResumed = false

    // MARK: - Computed Properties

    /// What the video screen shows, in its own vocabulary.
    ///
    /// The eleven `StreamState` cases collapse into four here, exactly as `LiveConnectionState`
    /// documents: five transient states become one `connecting` phase ladder, and `failed`,
    /// `reconnecting` and `stopped` become `offline` carrying the diagnosis that tells them apart.
    var liveState: LiveConnectionState {
        switch streamState {
        case .idle, .resolving:
            return .connecting(.resolving)
        case .connecting:
            return .connecting(.connecting)
        case .authenticating:
            return .connecting(.authenticating)
        case .describing:
            return .connecting(.negotiating)
        case .settingUp:
            return .connecting(.opening)
        case .playing:
            // `isDisplayingPicture`, not `isReceivingMedia`: `Live` is a claim about the screen.
            if isDisplayingPicture { return .live }
            return .connecting(hasFirstPacket ? .waitingForKeyframe : .waitingForVideo)
        case .degraded:
            return .degraded(degradedCause)
        case .reconnecting, .failed, .stopped:
            return .offline(OfflineDetail(attempt: attempt,
                                          retryInSeconds: retryInSeconds,
                                          lastSeen: lastSeen,
                                          isPersistent: attempt >= 5,
                                          diagnosis: diagnosis))
        }
    }

    /// Whether a picture is actually on the glass.
    ///
    /// `TileRenderState.isReceivingFrames` goes true when a sample buffer reaches the display layer
    /// and false again on a flush, which is exactly the fact the status line needs.
    ///
    /// The fallback is deliberate and is the safe direction: with no tile mounted there is no render
    /// state to ask, so we fall back to the assembled-access-unit fact rather than narrating
    /// "connecting" over a stream that is running. A tile that *is* mounted and is not showing
    /// anything is the case worth catching, and this reports it.
    var isDisplayingPicture: Bool {
        renderState?.isReceivingFrames ?? isReceivingMedia
    }

    /// The measured reason the stream is degraded.
    ///
    /// Every case carries a number the user can act on, so this reports whichever measurement is
    /// actually non-zero rather than guessing (UX.md §14.1 rule 4).
    private var degradedCause: DegradedCause {
        if statistics.lossFraction > 0 {
            return .packetLoss(fraction: statistics.lossFraction)
        }
        if statistics.jitterMilliseconds > 0 {
            return .jitter(milliseconds: statistics.jitterMilliseconds)
        }
        return .decodeQueue(frames: statistics.decodeQueueDepth)
    }

    // MARK: - Initialisation

    /// Creates the model over an already-bootstrapped dependency set.
    ///
    /// - Parameters:
    ///   - dependencies: the process-wide clock, logger, Keychain, randomness and RTSP session
    ///     factory from `AppEnvironment.bootstrap()`.
    ///   - defaults: where the remembered connection lives. Injected so a test can pass a scratch
    ///     suite instead of the real one.
    init(dependencies: CoreDependencies, defaults: UserDefaults = .standard) {
        self.dependencies = dependencies
        self.defaults = defaults
        self.credentials = CredentialStore(keychain: dependencies.keychain,
                                           logger: dependencies.logger)
        // The sink follows the handle for the life of the process, so a tile that SwiftUI rebuilds
        // mid-stream starts receiving again without the decode pipeline knowing anything happened.
        // The same attach notification carries the tile's render state up, so `liveState` can say
        // `Live` about pixels rather than about assembled access units.
        tileSink.follow(frames) { [weak self] state in
            // One hop, on attach only — never per frame. `onSinkChange` is checked as nonisolated,
            // so this is where the value crosses onto the main actor.
            Task { @MainActor in self?.renderState = state }
        }
    }

    // MARK: - Public API

    /// Called once, when the window appears.
    ///
    /// If a previous run reached a picture, its host, account, Keychain handle and working RTSP
    /// path were remembered, and this reconnects without asking for anything. That is what makes
    /// the *second* and every later launch a zero-input path to video (R1.4). When nothing is
    /// remembered, the form is shown as it stands.
    func resumeOrPrompt() {
        // `.task` fires again if the window is closed and reopened; resuming twice would build a
        // second controller for the same camera and leak the first.
        guard !hasResumed else { return }
        hasResumed = true
        guard let remembered = LastConnection.load(from: defaults) else { return }
        form.host = remembered.host
        form.username = remembered.account
        sessionTask = Task { [weak self] in
            await self?.resume(remembered)
        }
    }

    /// Connects to what the form submitted.
    ///
    /// `ConnectFormView` has already validated the fields and set `form.isConnecting`; this is the
    /// app half — Keychain, camera record, controller.
    func connect(_ request: ConnectRequest) {
        stopSession()
        form.isConnecting = true
        diagnosis = nil
        beginConnecting()
        let known = knownHandle(for: request)
        resolvedPath = known.rtspPath
        sessionTask = Task { [weak self] in
            await self?.connect(request, ref: known.ref, rtspPath: known.rtspPath)
        }
    }

    /// Tears the session down and returns to the form. Idempotent.
    ///
    /// - Parameter forget: when `true`, the remembered connection is cleared so the next launch
    ///   shows the form rather than reconnecting.
    func disconnect(forget: Bool = false) {
        stopSession()
        phase = .connect
        form.isConnecting = false
        if forget {
            LastConnection.clear(in: defaults)
        }
    }

    /// Performs one of the remedies the diagnosis card offered.
    ///
    /// `ConnectDiagnosis` promises that every failure has at least one action; this is where the
    /// promise is kept. Three of the nine remedies need machinery the slice does not have —
    /// activation, ONVIF and Stream Doctor are W2–W4 — and each says so here rather than silently
    /// doing nothing, because a button that does nothing is worse than one that is not offered.
    func perform(_ remedy: ConnectRemedy) {
        switch remedy {
        case .checkAddress, .updatePassword:
            // On the form, `ConnectFormView` has already moved the cursor and forwards these only
            // so the app can log. From the video screen they mean "let me edit that", which makes
            // them the way back — and the only one the slice has, because `LiveVideoView` exposes
            // no disconnect affordance of its own.
            guard phase == .live else {
                dependencies.logger.debug(.ui, "remedy \(remedy) handled by the form")
                return
            }
            stopSession()
            if let diagnosis {
                present(diagnosis)
            } else {
                phase = .connect
                form.isConnecting = false
            }
        case .retry:
            connect(form.request)
        case .switchToTCP:
            // The slice is TCP-interleaved and nothing else (`.vigil/SLICE.md`), so this is a
            // retry — the transport it asks for is already the one in use.
            dependencies.logger.notice(.core, "already TCP-interleaved; retrying")
            connect(form.request)
        case .tryAlternateRTSPPort:
            rtspPort = Self.alternateRTSPPort
            connect(form.request)
        case .activateCamera, .openCameraWebPage:
            // Activation happens on the device's own web page, which is also where every setting
            // the other diagnoses point at lives. The in-app activation flow is W2.
            openCameraWebPage()
        case .useONVIF:
            unavailable("ONVIF is not in this build yet.")
        case .runStreamDoctor:
            unavailable("Stream Doctor is not in this build yet.")
        }
    }

    /// Recovers a frozen picture, when the display layer or the decoder says it needs a keyframe.
    ///
    /// `StreamController` in this slice has no IDR request path — `requestKeyframe(reason:)` and
    /// the ISAPI `requestKeyFrame` chain (R-24) are W4 — so the only lever available is a full
    /// session restart, which costs two or three seconds of held last frame. That is a real cost,
    /// so it is rate-limited: a decoder that asks continuously must not put the session into a
    /// restart loop, and the controller's own `noKeyframe` watchdog is already trying.
    func recoverStalledPicture() {
        let now = Date()
        if let lastRecoveryAt, now.timeIntervalSince(lastRecoveryAt) < Self.recoveryInterval {
            return
        }
        lastRecoveryAt = now
        guard let controller else { return }
        dependencies.logger.notice(.video, "no keyframe; restarting the session to recover")
        Task { await controller.restart() }
    }
}

#endif  // os(macOS)
