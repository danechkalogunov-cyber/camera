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
import VigilDiscovery
import VigilISAPI
import VigilProtocols
import VigilRender
import VigilUI
import VigilTransport
import VigilVideo

// MARK: - AppSessionModel

struct CachedCapabilitiesDiagnostics {
    let host: String
    let port: Int
    let useTLS: Bool
    let capturedAt: Date
    let data: Data

    func matches(_ camera: Camera, now: Date) -> Bool {
        host == camera.host && port == camera.httpPort && useTLS == camera.useTLS
            && now.timeIntervalSince(capturedAt) < 24 * 60 * 60
    }
}

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
/// Discovery, library persistence and window-owned diagnostics are injected around this model;
/// its job is the media column from socket to pixel (`.vigil/SLICE.md`).
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

    /// The one camera whose media path this model is driving.
    ///
    /// ⛔ STEP 1 OF F-LIV-01. Every property below is a forwarder onto this object, keeping the
    /// names the window already uses — `session.camera`, `session.streamState`, `session.frames` —
    /// so that moving the storage changes no behaviour and no call site. The seam is the point: the
    /// next step replaces this single stream with `[CameraID: CameraStream]`, and only the
    /// forwarders have to learn which one they mean.
    ///
    /// A `var` rather than a `let` so that step can swap it, and non-optional because a stream
    /// exists before its camera does: the connect form writes `streamState` and a diagnosis while
    /// the user is still typing an address.
    var live = CameraStream()

    /// Every camera with a media path, ``live`` among them once it has a camera. Step 2 of
    /// F-LIV-01.
    ///
    /// ⚠️ Filed, not driven. Nothing here starts or stops a stream yet, and the one-camera path is
    /// byte-for-byte what it was: ``live`` is still the stream every forwarder reads, and it is
    /// filed here whenever its camera changes so that the map is already true when step 3 asks it
    /// for a tile's frame source. A map that only becomes true at the moment it is first read is a
    /// map that is wrong in every state before that.
    let cameras = CameraStreamSet()

    let dependencies: CoreDependencies
    let credentials: CredentialStore
    let defaults: UserDefaults
    let audioPlayback = AudioPlaybackEngine()
    /// Original capabilities response bytes retained for 24 hours for diagnostics export.
    @ObservationIgnored var capabilitiesDiagnostics: [CameraID: CachedCapabilitiesDiagnostics] = [:]

    /// Device-service XAddr selected in discovery; consumed by the next matching form submit.
    var pendingONVIFServiceURL: URL?
    let pictureInPicture = PictureInPictureCoordinator()
    let twoWayAudio = TwoWayAudioCoordinator()
    let synchronizedPlayback = SynchronizedPlaybackCoordinator()
    let clipExport = ClipExportCoordinator()

    /// The launch-time resume, and the connect the form submits. Application-scoped: there is one
    /// user pressing Return, however many cameras are streaming.
    var sessionTask: Task<Void, Never>?

    /// Camera sessions that were active immediately before macOS went to sleep.
    /// Old sockets and decoder sessions are never reused after wake.
    var systemSleepStreamIDs: Set<CameraID> = []
    var isSuspendedForSystemSleep = false

    // MARK: - Forwarders onto ``live``
    //
    // Mechanical, and deliberately so. Each pair is the property `CameraStream` now stores; the
    // bodies do nothing but read and write it. `@Observable` tracks through them, because the nested
    // object is `@Observable` too and SwiftUI observes whatever is read during a body evaluation.

    var controller: StreamController? {
        get { live.controller }
        set { live.controller = newValue }
    }

    /// The camera ``live`` is pointed at.
    ///
    /// ⚠️ The setter also files the stream, which is the whole of how ``cameras`` stays true: the
    /// app reuses one `CameraStream` across a switch, so the map has to be told when the camera
    /// under it changes. `CameraStreamSet.file(_:)` removes the entry the stream was filed under
    /// before adding the new one, so a switch cannot leave a stale key behind.
    var camera: Camera? {
        get { live.camera }
        set {
            live.camera = newValue
            cameras.file(live)
        }
    }

    var firstFrameLatency: Duration? {
        get { live.firstFrameLatency }
        set { live.firstFrameLatency = newValue }
    }

    var seekGeneration: UInt64 {
        get { live.seekGeneration }
        set { live.seekGeneration = newValue }
    }

    var seekStartedAt: MediaInstant? {
        get { live.seekStartedAt }
        set { live.seekStartedAt = newValue }
    }

    var streamState: StreamState {
        get { live.streamState }
        set { live.streamState = newValue }
    }

    var hasFirstPacket: Bool {
        get { live.hasFirstPacket }
        set { live.hasFirstPacket = newValue }
    }

    var isReceivingMedia: Bool {
        get { live.isReceivingMedia }
        set { live.isReceivingMedia = newValue }
    }

    var renderState: TileRenderState? {
        get { live.renderState }
        set { live.renderState = newValue }
    }

    var format: StreamFormat? {
        get { live.format }
        set { live.format = newValue }
    }

    var statistics: StreamStatistics {
        get { live.statistics }
        set { live.statistics = newValue }
    }

    var diagnosis: ConnectDiagnosis? {
        get { live.diagnosis }
        set { live.diagnosis = newValue }
    }

    var attempt: Int {
        get { live.attempt }
        set { live.attempt = newValue }
    }

    var retryInSeconds: Int? {
        get { live.retryInSeconds }
        set { live.retryInSeconds = newValue }
    }

    var lastSeen: Date? {
        get { live.lastSeen }
        set { live.lastSeen = newValue }
    }

    var frames: FrameStreamHandle { live.frames }
    var telemetry: StreamStatisticsCollector { live.telemetry }
    var backlog: FrameBacklog { live.backlog }
    var recordingTap: RecordingTap { live.recordingTap }
    var tileSink: TileVideoSink { live.tileSink }

    var eventTask: Task<Void, Never>? {
        get { live.eventTask }
        set { live.eventTask = newValue }
    }

    var decodeTask: Task<Void, Never>? {
        get { live.decodeTask }
        set { live.decodeTask = newValue }
    }

    var frameContinuation: AsyncStream<EncodedFrame>.Continuation? {
        get { live.frameContinuation }
        set { live.frameContinuation = newValue }
    }

    var pipeline: DecodePipeline? {
        get { live.pipeline }
        set { live.pipeline = newValue }
    }

    var tilePolicyTask: Task<Void, Never>? {
        get { live.tilePolicyTask }
        set { live.tilePolicyTask = newValue }
    }

    var attemptStartedAt: Date? {
        get { live.attemptStartedAt }
        set { live.attemptStartedAt = newValue }
    }

    var lastRecoveryAt: Date? {
        get { live.lastRecoveryAt }
        set { live.lastRecoveryAt = newValue }
    }

    var decodeFailures: Int {
        get { live.decodeFailures }
        set { live.decodeFailures = newValue }
    }

    var droppedByReason: [String: Int] {
        get { live.droppedByReason }
        set { live.droppedByReason = newValue }
    }

    var activeRef: CredentialRef? {
        get { live.activeRef }
        set { live.activeRef = newValue }
    }

    var resolvedPath: String? {
        get { live.resolvedPath }
        set { live.resolvedPath = newValue }
    }

    var rtspPort: Int {
        get { live.rtspPort }
        set { live.rtspPort = newValue }
    }

    var playback: PlaybackLocator? {
        get { live.playback }
        set { live.playback = newValue }
    }

    var playbackRate: TimelinePlaybackRate {
        get { live.playbackRate }
        set { live.playbackRate = newValue }
    }

    var isPlaybackPaused: Bool {
        get { live.isPlaybackPaused }
        set { live.isPlaybackPaused = newValue }
    }

    /// Whether the launch-time resume has already been attempted.
    var hasResumed = false

    // MARK: - Computed Properties

    /// What the video screen shows for the camera it is bound to, in its own vocabulary.
    ///
    /// The rule itself is `CameraStream.liveState` — it is a fact about one camera and nothing
    /// about the application, which is why it moved. This is the forwarder the window already
    /// calls.
    var liveState: LiveConnectionState { live.liveState }

    /// Whether a picture is actually on the glass for the bound camera.
    var isDisplayingPicture: Bool { live.isDisplayingPicture }

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
        // The unsandboxed dev build (build-app.sh --sandbox off) is signed ad-hoc, so it has no
        // Team ID and cannot use the data-protection keychain — every SecItem call would fail with
        // errSecMissingEntitlement. That build stamps VigilDevBuild=true into Info.plist; when it is
        // set, CredentialStore falls back to the legacy file keychain, which needs no access group.
        // A shipping build has no such key, so it keeps the data-protection keychain.
        let isDevBuild = Bundle.main.object(forInfoDictionaryKey: "VigilDevBuild") as? Bool ?? false
        self.credentials = CredentialStore(keychain: dependencies.keychain,
                                           logger: dependencies.logger,
                                           useDataProtectionKeychain: !isDevBuild)
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
        // ⛔ A pasted URL beats the remembered path, and beats the probe ladder. The user has just
        // told us exactly where the stream is; searching for it anyway would be ignoring an answer
        // in favour of a guess, and on a camera whose sub-stream is at `/Streaming/Channels/102` the
        // ladder happily finds `/101` instead and shows the wrong picture with no error.
        //
        // `form.rtspPath` is `nil` for every address that is not a URL — `absorbPastedURL()` clears
        // it on the same change that fails to parse — so this cannot resurrect a path from a camera
        // the user has since typed away from.
        let pastedPath = form.rtspPath
        rtspPort = form.rtspPort
        resolvedPath = pastedPath ?? known.rtspPath
        sessionTask = Task { [weak self] in
            await self?.connect(request, ref: known.ref, rtspPath: pastedPath ?? known.rtspPath)
        }
    }

    /// Runs only Stream Doctor's credential-free TCP/OPTIONS prefix; it does not save or connect.
    func testConnection(_ request: ConnectRequest) {
        guard !form.isTesting, let host = IPv4Address(request.host),
              let http = UInt16(exactly: request.httpPort),
              let rtsp = UInt16(exactly: request.rtspPort) else {
            form.isTesting = false
            form.testResult = vigilUIString("Testing currently requires an IPv4 address.")
            return
        }
        form.isTesting = true
        let environment = LiveDiscoveryEnvironment.make(logger: dependencies.logger)
        Task { [weak self] in
            let result = await ManualConnectionTest(environment: environment)
                .run(host: host, httpPort: http, rtspPort: rtsp, useTLS: request.usesTLS)
            guard let self else { return }
            self.form.isTesting = false
            self.form.testResult = result.speaksRTSP
                ? vigilUIString("Test passed: RTSP OPTIONS answered.")
                : vigilUIString("Test incomplete: the RTSP endpoint did not answer OPTIONS.")
        }
    }

    /// Tears **every** session down and returns to the form. Idempotent.
    ///
    /// ⛔ Every one of them, and this is not tidiness. The window goes back to the connect form, so
    /// nothing on screen is showing the other cameras — and a stream nobody can see is a socket, a
    /// decoder and a camera session that the user has no way to stop. Leaving them running was the
    /// obvious shape of this method for as long as there could only be one.
    ///
    /// - Parameter forget: when `true`, the remembered connection is cleared so the next launch
    ///   shows the form rather than reconnecting.
    func disconnect(forget: Bool = false) {
        stopSession()
        for stream in cameras.all where stream !== live { stop(stream) }
        phase = .connect
        form.isConnecting = false
        if forget {
            LastConnection.clear(in: defaults)
        }
    }

    /// Performs one of the remedies the diagnosis card offered.
    ///
    /// `ConnectDiagnosis` promises that every failure has at least one action; this is where the
    /// promise is kept. Activation and ONVIF still require external/device machinery and say so
    /// rather than silently doing nothing.
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
            guard var camera else {
                connect(form.request)
                return
            }
            camera.transport = .tcpInterleaved
            camera.lastWorkingTransport = nil
            self.camera = camera
            if let controller {
                Task { await controller.setCamera(camera) }
            } else {
                connect(form.request)
            }
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
            // The full report is window-owned. On the connect screen, run its credential-free
            // prefix rather than presenting a dead remedy.
            testConnection(form.request)
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
        recoverStalledPicture(on: live)
    }

    /// The same, for whichever tile reported the stall.
    ///
    /// ⚠️ The rate limit is per **stream**, because it protects a session rather than the app: two
    /// cameras that both lose their keyframes are two independent problems, and a shared timer would
    /// let the first one's recovery silence the second one's for thirty seconds.
    func recoverStalledPicture(on stream: CameraStream) {
        let now = Date()
        if let lastRecoveryAt = stream.lastRecoveryAt,
           now.timeIntervalSince(lastRecoveryAt) < Self.recoveryInterval {
            return
        }
        stream.lastRecoveryAt = now
        guard let controller = stream.controller else { return }
        dependencies.logger.notice(.video, "no keyframe; restarting the session to recover")
        Task { await controller.restart() }
    }

    /// Bypasses retry timers after the network returns or the Mac wakes.
    ///
    /// ⚠️ Every stream, not the bound one. A Mac that slept with four cameras up wakes with four
    /// dead sockets, and three of them waiting out a backoff nobody can see is the same bug as one.
    func reconnectImmediately() {
        guard !isSuspendedForSystemSleep else { return }
        var reachedLive = false
        for stream in cameras.all {
            if stream === live { reachedLive = true }
            guard let controller = stream.controller else { continue }
            Task { await controller.restart() }
        }
        // `live` is filed only once it has a camera record, so a session still connecting is not in
        // the map yet and would otherwise be the one stream this misses.
        guard !reachedLive, let controller = live.controller else { return }
        Task { await controller.restart() }
    }

    /// Finalizes recordings and releases every socket/decoder before macOS sleeps.
    func suspendForSystemSleep() {
        guard !isSuspendedForSystemSleep else { return }
        isSuspendedForSystemSleep = true
        systemSleepStreamIDs = Set(cameras.all.compactMap { stream in
            guard stream.isActive else { return nil }
            stream.recordingCoordinator?.stop()
            return stream.camera?.id
        })
        for stream in cameras.all where stream.isActive { stop(stream) }
        // A connection can be resolving before it has been filed in the set.
        if let id = live.camera?.id, live.isActive, !systemSleepStreamIDs.contains(id) {
            live.recordingCoordinator?.stop()
            systemSleepStreamIDs.insert(id)
            stopSession()
        } else {
            sessionTask?.cancel()
            sessionTask = nil
        }
        dependencies.logger.info(.app, "suspended camera sessions for system sleep",
                                 ["count": "\(systemSleepStreamIDs.count)"])
    }

    /// Rebuilds exactly the sessions that were active before sleep, with fresh media paths.
    func resumeAfterSystemSleep() {
        guard isSuspendedForSystemSleep else { return }
        isSuspendedForSystemSleep = false
        let ids = systemSleepStreamIDs
        systemSleepStreamIDs.removeAll()
        dependencies.logger.info(.app, "resuming camera sessions after system wake",
                                 ["count": "\(ids.count)"])
        for id in ids {
            guard let stream = cameras.stream(for: id),
                  let camera = stream.camera,
                  stream.controller == nil else { continue }
            stream.beginConnecting()
            Task { await start(stream, camera: camera, ref: camera.credentialRef) }
        }
    }
}

#endif  // os(macOS)
