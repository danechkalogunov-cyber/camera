//
//  AppSessionModel.swift
//  Vigil
//
//  The app-level object: owns the one `StreamController` the slice runs, turns its event stream
//  into the state the two screens render, and implements the launch → live-video flow of R1.
//  macOS-only. See docs/API_CONTRACT.md §4.12, docs/spec-core.md §7 and REQUIREMENTS-CUSTOMER §R1.
//

#if os(macOS)

import AppKit
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

    /// The connect form's fields, validation and last diagnosis.
    ///
    /// Owned here rather than in the view because `ConnectFormView` takes a `Binding` and says so:
    /// "state lives in the caller so the app can prefill an address … and drive the in-flight and
    /// failure states from `VigilCore`".
    var form = ConnectFormState()

    /// Which screen is showing.
    private(set) var phase: Phase = .connect

    /// The live controller, handed to the video screen so it can attach its display layer.
    private(set) var controller: StreamController?

    /// The camera currently being connected or streamed.
    private(set) var camera: Camera?

    /// Time from `start()` to the first assembled access unit. The R1.7 measurement.
    private(set) var firstFrameLatency: Duration?

    /// The controller's last reported state.
    private(set) var streamState: StreamState = .idle

    /// Whether any RTP has arrived, which is what separates "no video is arriving" from "waiting
    /// for a keyframe" in the connecting narration.
    private(set) var hasFirstPacket: Bool = false

    /// Whether a complete access unit has been assembled. See `StreamEvent.firstFrameAssembled`:
    /// the decoder reports the *picture* separately, and the tile's own `TileRenderState` is the
    /// authority on when pixels appear.
    private(set) var isReceivingMedia: Bool = false

    /// The latest 1 Hz telemetry, used for the degraded banner's measured cause.
    private(set) var statistics = StreamStatistics()

    /// The named cause of the current failure, in `VigilUI`'s vocabulary.
    private(set) var diagnosis: ConnectDiagnosis?

    /// Which reconnect attempt we are on. `1` until the controller says otherwise.
    private(set) var attempt: Int = 1

    /// Seconds until the next reconnect, when one is scheduled.
    private(set) var retryInSeconds: Int?

    /// When media was last flowing, for the offline card's "Last seen" line.
    private(set) var lastSeen: Date?

    /// The attach point the video screen's tile registers with. One per window, not one per
    /// session: SwiftUI keeps the tile mounted across a reconnect, and so must its frame source.
    let frames = FrameStreamHandle()

    private let dependencies: CoreDependencies
    private let credentials: CredentialStore
    private let defaults: UserDefaults
    private let tileSink = TileVideoSink()
    private var sessionTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var decodeTask: Task<Void, Never>?
    private var frameContinuation: AsyncStream<EncodedFrame>.Continuation?
    private var pipeline: DecodePipeline?

    /// When the current connect attempt began, for the video screen's elapsed counter.
    private(set) var attemptStartedAt: Date?

    /// When a keyframe recovery was last forced, so a decoder that keeps asking cannot put the
    /// session into a restart loop.
    private var lastRecoveryAt: Date?

    /// Keychain handle of the camera currently being connected, so the first frame can be
    /// remembered against the right item.
    private var activeRef: CredentialRef?

    /// The RTSP path the ladder settled on, persisted only once a frame has arrived.
    private var resolvedPath: String?

    /// Set by the "Try Port 8554" remedy, and only by it.
    private var rtspPort: Int = 554

    /// Whether the launch-time resume has already been attempted.
    private var hasResumed = false

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
            if isReceivingMedia { return .live }
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
        tileSink.follow(frames)
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
        form.isConnecting = true
        diagnosis = nil
        beginConnecting()
        // Reuse the Keychain handle when this is the same camera and account as last time: `save`
        // updates an existing item in place, whereas a fresh `CredentialRef` would leave the old
        // item behind as an orphan on every retry.
        let ref = rememberedRef(host: request.host, account: request.username) ?? CredentialRef()
        sessionTask = Task { [weak self] in
            await self?.connect(request, ref: ref)
        }
    }

    /// Tears the session down and returns to the form. Idempotent.
    ///
    /// - Parameter forget: when `true`, the remembered connection is cleared so the next launch
    ///   shows the form rather than reconnecting.
    func disconnect(forget: Bool = false) {
        eventTask?.cancel()
        eventTask = nil
        sessionTask?.cancel()
        sessionTask = nil
        // Finishing the continuation ends the decode task's loop after the frames already queued,
        // so nothing is torn down under the pipeline mid-frame.
        frameContinuation?.finish()
        frameContinuation = nil
        decodeTask = nil
        let outgoing = controller
        let outgoingPipeline = pipeline
        controller = nil
        pipeline = nil
        activeRef = nil
        phase = .connect
        form.isConnecting = false
        isReceivingMedia = false
        hasFirstPacket = false
        streamState = .idle
        retryInSeconds = nil
        firstFrameLatency = nil
        attemptStartedAt = nil
        if forget {
            LastConnection.clear(in: defaults)
        }
        // The tile keeps its last picture on purpose — no flush, no blanking (R-36, §4.9).
        Task {
            await outgoingPipeline?.stop(reason: .stopped)
            // Graceful TEARDOWN: `stop` is safe to await from a cancelled task, and the UI must not
            // wait 1.5 s to go back to the form, so it happens here rather than inline.
            await outgoing?.stop(reason: .userRequested)
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
            // `ConnectFormView` has already moved the cursor; it forwards these so the app can log.
            dependencies.logger.debug(.ui, "remedy \(remedy) handled by the form")
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

    // MARK: - Private Helpers

    private func beginConnecting() {
        phase = .live
        streamState = .resolving
        isReceivingMedia = false
        hasFirstPacket = false
        firstFrameLatency = nil
        retryInSeconds = nil
        attempt = 1
    }

    /// The first-connect path: write the password to the Keychain, then stream.
    private func connect(_ request: ConnectRequest, ref: CredentialRef) async {
        do {
            let camera = try makeCamera(host: request.host, ref: ref)
            let credential = Credential(ref: ref, account: request.username, secret: request.password)
            // `CredentialDescriptor(camera:account:)` derives server, port, protocol and the
            // Keychain Access label from the record; `save` preconditions that the credential's ref
            // matches the descriptor's, which it does because both come from `ref`.
            let descriptor = CredentialDescriptor(camera: camera, account: request.username)
            try await credentials.save(credential, descriptor: descriptor)
            await stream(camera: camera, ref: ref)
        } catch {
            fail(with: error, host: request.host)
        }
    }

    /// The remembered-camera path: no form, no Keychain write, straight to streaming.
    private func resume(_ remembered: LastConnection) async {
        // Straight to the video screen, before the Keychain is even asked: a remembered connection
        // means we already believe there is a camera, and a flash of the form in front of a user
        // who is about to be shown video is exactly the "wizard" R1 forbids.
        form.isConnecting = true
        beginConnecting()
        do {
            // A missing item is a normal outcome, not an error (`errSecItemNotFound`) — it means
            // the user removed it in Keychain Access, so we ask again. `hasCredential` answers from
            // `kSecReturnAttributes` alone and never decrypts the secret.
            guard try await credentials.hasCredential(for: remembered.credentialRef) else {
                LastConnection.clear(in: defaults)
                phase = .connect
                form.isConnecting = false
                return
            }
            let camera = try makeCamera(host: remembered.host,
                                        ref: remembered.credentialRef,
                                        rtspPath: remembered.rtspPath)
            resolvedPath = remembered.rtspPath
            await stream(camera: camera, ref: remembered.credentialRef)
        } catch {
            fail(with: error, host: remembered.host)
        }
    }

    /// Builds the one camera record the slice uses, with every field but the address defaulted.
    ///
    /// From the landed source (`Sources/VigilCore/Model/Camera.swift`): every argument but `host`
    /// has a default, and `validated()` supplies the name, strips IPv6 brackets and throws
    /// `.invalidHost` when the user pasted a URL rather than an address.
    ///
    /// `rtspPathOverride` carries the ladder's winner from the last successful run, so R1.2's "the
    /// probe happens exactly once per device, ever" holds across launches — `StreamController`
    /// reads it as a resolved candidate and skips the ladder. In W4 this is
    /// `capabilities.resolvedRTSPPath` read back from `library.json`.
    private func makeCamera(host: String, ref: CredentialRef, rtspPath: String? = nil) throws
        -> Camera {
        try Camera(host: host,
                   rtspPort: rtspPort,
                   credentialRef: ref,
                   rtspPathOverride: rtspPath).validated()
    }

    /// Builds the decode chain and the controller, subscribes to its events, and starts it.
    ///
    /// This is the whole column, in the order the bytes travel: socket (`CoreDependencies`
    /// `makeRTSPSession`) → `StreamController` → `EncodedFrame` → `DecodePipeline` →
    /// `TileVideoSink` → `VideoTileView`'s `AVSampleBufferDisplayLayer`.
    private func stream(camera: Camera, ref: CredentialRef) async {
        self.camera = camera
        activeRef = ref
        attemptStartedAt = Date()
        let store = credentials
        // Called by the controller on every connect attempt, so the password is read from the
        // Keychain each time and never captured in the closure (docs/spec-core.md §2).
        let provider: @Sendable () async throws -> Credential? = {
            try await store.credential(for: ref)
        }
        let logger = dependencies.logger
        let pipeline = DecodePipeline(
            sink: tileSink,
            pacing: .live,
            requestKeyframe: { [weak self] in
                Task { @MainActor in self?.recoverStalledPicture() }
            },
            onError: { error in
                // Never swallowed: "no video, no error" is the worst failure we could ship.
                logger.error(.video, "decode: \(error)")
            })
        self.pipeline = pipeline
        // One ordered hop from the controller's isolation to the pipeline actor. A `Task` per frame
        // would preserve neither order nor allocation budget; a single-consumer stream does both,
        // and its bounded buffer drops the oldest frames rather than growing without limit (R-27).
        let (frameStream, continuation) = AsyncStream<EncodedFrame>.makeStream(
            of: EncodedFrame.self, bufferingPolicy: .bufferingNewest(64))
        frameContinuation = continuation
        decodeTask = Task {
            for await frame in frameStream {
                await pipeline.submit(frame)
            }
        }
        let controller = StreamController(camera: camera,
                                          credentialProvider: provider,
                                          initialQuality: .main,
                                          initialPriority: .focused,
                                          dependencies: dependencies,
                                          frameSink: { continuation.yield($0) })
        self.controller = controller
        // `events()` is `nonisolated` and returns a fresh bounded stream per call (R-27), so the
        // subscription is established before `start()` and cannot miss the first transition.
        eventTask = Task { [weak self] in
            for await event in controller.events() {
                guard let self else { return }
                self.apply(event)
            }
        }
        await controller.start()
    }

    /// Folds one controller event into observable state.
    ///
    /// The `default` arm is deliberate: the slice reacts to seven of `StreamEvent`'s cases and must
    /// keep consuming the rest rather than leave them to fill the stream's bounded buffer. It also
    /// means a case added in W4 cannot stop this file compiling.
    private func apply(_ event: StreamEvent) {
        switch event {
        case .stateChanged(_, let to, let detail):
            streamState = to
            attempt = max(1, detail.attempt)
            retryInSeconds = Self.seconds(until: detail.nextRetryAt)
            if let underlying = detail.underlying, let camera {
                diagnosis = ConnectDiagnosis.from(underlying, camera: camera)
            }
        case .firstPacketReceived:
            hasFirstPacket = true
        case .firstFrameAssembled(let afterStart):
            isReceivingMedia = true
            form.isConnecting = false
            firstFrameLatency = afterStart
            lastSeen = Date()
            diagnosis = nil
            form.clearDiagnosis()
            // The Keychain has the password now, so the copy in memory — and in the form's secure
            // field — has no reason to exist.
            form.password = ""
            rememberThisCamera()
            // The R1.7 number, in the log where the acceptance checklist can read it.
            dependencies.logger.info(.app, "first frame assembled after \(afterStart)")
        case .pathResolved(let candidate, _):
            // Remembered at the first frame, not here: a path that answers `DESCRIBE` but never
            // delivers video is not the one to start from next time.
            resolvedPath = candidate.path
        case .statistics(let latest):
            statistics = latest
            if streamState.isActive { lastSeen = Date() }
        case .reconnectScheduled(let attempt, let delay, let cause):
            self.attempt = attempt
            retryInSeconds = Int(delay.components.seconds)
            if let camera { diagnosis = ConnectDiagnosis.from(cause, camera: camera) }
        case .error(let error, let isFatal):
            guard let camera else { return }
            let named = ConnectDiagnosis.from(error, camera: camera)
            diagnosis = named
            guard !named.allowsAutomaticRetry || isFatal else { return }
            // Terminal. Back to the form with the cause and its remedies, and stop remembering a
            // password the camera rejects — retrying it at every launch is precisely how a
            // Hikvision account gets locked out (R-25, R1.5 "Account locked").
            let rejected = error.code == .authenticationFailed ? activeRef : nil
            disconnect(forget: !named.allowsAutomaticRetry)
            form.fail(named)
            if let rejected { deleteRejectedCredential(rejected) }
        default:
            break
        }
    }

    private func rememberThisCamera() {
        guard let activeRef, let camera else { return }
        LastConnection(host: camera.host,
                       account: form.username,
                       credentialRef: activeRef,
                       rtspPath: resolvedPath).save(to: defaults)
    }

    /// A failure before the controller existed: a bad address, or a Keychain that would not answer.
    private func fail(with error: any Error, host: String) {
        let named = Self.diagnosis(for: error, host: host)
        diagnosis = named
        phase = .connect
        form.fail(named)
        dependencies.logger.error(.app, "connect failed: \(error)")
    }

    /// Turns an error raised on the app's own half of the connect path into a named cause.
    ///
    /// `StreamError` never reaches here — the controller reports those through its event stream —
    /// so this covers exactly two sources: the address the user typed, and the Keychain.
    private static func diagnosis(for error: any Error, host: String) -> ConnectDiagnosis {
        switch error {
        case is CameraValidationError:
            // `CameraValidationError.description` is a redacted log line, not a sentence for a
            // person, so the user-facing copy is written here.
            return .undiagnosed(host: host,
                                detail: "That is not an address Vigil can use. Type just the "
                                    + "address — no rtsp://, no user name and no path.")
        case let failure as any VigilFailure:
            return .undiagnosed(host: host,
                                detail: [failure.userMessage, failure.userRemedy]
                                    .compactMap { $0 }.joined(separator: " "))
        default:
            return .undiagnosed(host: host, detail: "Vigil could not start the connection.")
        }
    }

    /// The Keychain handle for this host and account, when it is the one we already have.
    private func rememberedRef(host: String, account: String) -> CredentialRef? {
        guard let remembered = LastConnection.load(from: defaults),
              remembered.host.caseInsensitiveCompare(host) == .orderedSame,
              remembered.account == account
        else {
            return nil
        }
        return remembered.credentialRef
    }

    /// Removes a password the camera has rejected.
    ///
    /// Fire-and-forget on purpose: the user is already looking at the form, and a Keychain that
    /// refuses the delete changes nothing they can act on. The failure is logged, not shown.
    private func deleteRejectedCredential(_ ref: CredentialRef) {
        let store = credentials
        let logger = dependencies.logger
        Task {
            do {
                try await store.delete(ref)
            } catch {
                logger.warning(.app, "could not remove the rejected credential: \(error)")
            }
        }
    }

    /// Opens the camera's own web page, where every device-side setting the diagnoses point at
    /// lives — including activation for a factory-fresh camera.
    private func openCameraWebPage() {
        let host = camera?.host ?? form.request.host
        let port = camera?.httpPort ?? 80
        let authority = host.contains(":") ? "[\(host)]" : host   // bare IPv6 needs brackets
        guard !host.isEmpty, let url = URL(string: "http://\(authority):\(port)/") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Reports a remedy the slice cannot perform, in place of doing nothing.
    private func unavailable(_ sentence: String) {
        let host = camera?.host ?? form.request.host
        let named = ConnectDiagnosis.undiagnosed(host: host, detail: sentence)
        diagnosis = named
        form.fail(named)
        dependencies.logger.notice(.ui, sentence)
    }

    /// Whole seconds from now until `date`, or `nil` when there is no countdown.
    private static func seconds(until date: Date?) -> Int? {
        guard let date else { return nil }
        return max(0, Int(date.timeIntervalSinceNow.rounded()))
    }

    /// The port Hikvision devices use when 554 is taken or disabled (R1.5 "RTSP port closed").
    private static let alternateRTSPPort = 8554

    /// The shortest gap between two forced keyframe recoveries.
    private static let recoveryInterval: TimeInterval = 10
}

#endif  // os(macOS)
