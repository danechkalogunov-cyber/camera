//
//  AppSessionModel.swift
//  Vigil
//
//  The app-level object: owns the one `StreamController` the slice runs, turns its event stream
//  into observable state, and implements the launch → live-video flow of R1.
//  macOS-only. See docs/API_CONTRACT.md §4.12, docs/spec-core.md §7 and REQUIREMENTS-CUSTOMER §R1.
//

#if os(macOS)

import Foundation
import Observation

import VigilCore
import VigilProtocols

// MARK: - AppSessionModel

/// Everything the two screens of the slice need, and nothing else.
///
/// One camera, one controller, one window. The model is the only place in the app target that
/// touches `VigilCore`; the views receive plain values and closures, which is also why they can
/// live in `VigilUI` (a module that cannot see this type).
///
/// **Isolation.** `@MainActor` throughout, because every property here is read during SwiftUI body
/// evaluation. The `StreamController` it owns is an actor, so every call into it is `await`ed from
/// a `Task` that inherits this isolation; nothing blocks the main thread.
///
/// **What it deliberately does not do:** no discovery, no channel enumeration, no Stream Doctor, no
/// library persistence. Those are named in R1 and in the manifest and land in W2–W6; the slice's
/// job is to prove the column from socket to pixel (`.vigil/SLICE.md`).
@MainActor
@Observable
final class AppSessionModel {

    // MARK: - Nested Types

    /// Which of the two screens the window is showing.
    ///
    /// The transition to `.live` happens the instant the user presses Return — not when the first
    /// frame arrives. The connecting narration belongs on the video surface (`StateDetail.narration`,
    /// docs/spec-core.md §7.3), so that the ten seconds R1 allows are spent watching the stream come
    /// up rather than watching a modal spinner over a form.
    enum Phase: Equatable {
        /// The connect form: address, account, password.
        case connect
        /// The video surface and its status line.
        case live
    }

    // MARK: - Stored Properties

    /// Camera address as typed. IPv4, IPv6 without brackets, or a DNS name (docs/spec-core.md §4.1).
    var host: String = ""

    /// Hikvision account name. Pre-filled with the factory default, per R1.1 step 3.
    var account: String = "admin"

    /// The password. Held only until the Keychain has it, then cleared (see `apply(_:)`).
    var password: String = ""

    /// Which screen is showing.
    private(set) var phase: Phase = .connect

    /// One short sentence describing what the stream is doing, shown under the video.
    ///
    /// Empty once a picture is on screen: nothing is drawn over live video at rest
    /// (docs/DESIGN.md §11.4 and R-36).
    private(set) var statusLine: String = ""

    /// The controller's last reported state, or `nil` before the first connect attempt.
    private(set) var streamState: StreamState?

    /// `true` once the first complete access unit has been assembled from RTP.
    ///
    /// This is the earliest honest "the camera is sending video" signal available at this layer:
    /// `StreamEvent.firstFrameAssembled` is named for what the controller can observe, and the
    /// decoder reports the picture separately (see the case's own documentation in
    /// `VigilCore/Streaming/StreamEvent.swift`). A view that needs the exact moment pixels appear
    /// should read `TileRenderState.isReceivingFrames` from its own tile instead of this.
    private(set) var isReceivingMedia: Bool = false

    /// Time from `start()` to the first assembled access unit, as reported by the controller. Kept
    /// for the R1.7 measurement and written to the log; the UI may show it and may ignore it.
    private(set) var firstFrameLatency: Duration?

    /// One sentence naming what went wrong, or `nil` when nothing is wrong.
    ///
    /// Always `StreamError.message` or `VigilFailure.userMessage` — never a status code, never
    /// `localizedDescription` of an `NWError`. The slice has no Stream Doctor, so this is a cause
    /// and not yet a diagnosis: R1.5's nine named diagnoses are a W4 obligation and are **not** met
    /// here.
    private(set) var failure: String?

    /// One imperative sentence saying what to do about `failure`, when there is something to do.
    private(set) var failureRemedy: String?

    /// The live controller, handed to the video view so it can attach its display layer.
    private(set) var controller: StreamController?

    /// `true` between pressing Return and the first frame (or the first failure).
    private(set) var isConnecting: Bool = false

    private let dependencies: CoreDependencies
    private let credentials: CredentialStore
    private let defaults: UserDefaults
    private var sessionTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    /// Keychain handle of the camera currently being connected. Held so that the first decoded
    /// frame can be remembered against the right item without re-reading `UserDefaults`.
    private var activeRef: CredentialRef?

    /// Whether the launch-time resume has already been attempted.
    private var hasResumed = false

    /// The RTSP path the probe ladder settled on for the current camera, once it has reported one.
    /// Persisted only after a frame arrives, so a path that resolved but never produced video is
    /// not the one we start from next time.
    private var resolvedPath: String?

    // MARK: - Computed Properties

    /// Whether the connect form's primary button should fire.
    var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
            && !isConnecting
    }

    /// Cause and remedy as the one string a view can show without knowing which it has.
    ///
    /// Two properties, one sentence pair: R1.5's rule is that a failure never appears without a
    /// next action, and joining them here means a view cannot show the first and forget the second.
    var failureBanner: String? {
        switch (failure, failureRemedy) {
        case (nil, _): return nil
        case (let message?, nil): return message
        case (let message?, let remedy?): return "\(message) \(remedy)"
        }
    }

    // MARK: - Initialisation

    /// Creates the model over an already-bootstrapped dependency set.
    ///
    /// - Parameters:
    ///   - dependencies: the process-wide `CoreDependencies` from `AppEnvironment.bootstrap()`.
    ///   - defaults: where the remembered connection lives. Injected so a test can pass a scratch
    ///     suite instead of the real one.
    init(dependencies: CoreDependencies, defaults: UserDefaults = .standard) {
        self.dependencies = dependencies
        self.defaults = defaults
        // Verified against the landed source (Sources/VigilCore/Security/CredentialStore.swift):
        //     public init(keychain: any KeychainProtocol, logger: any LoggerProtocol = NullLogger(),
        //                 accessGroup: String? = nil)
        self.credentials = CredentialStore(keychain: dependencies.keychain,
                                           logger: dependencies.logger)
    }

    // MARK: - Public API

    /// Called once, when the window appears.
    ///
    /// If a previous run reached a picture, its host, account and Keychain handle were remembered,
    /// and this reconnects without asking for anything. That is what makes the *second* and every
    /// later launch a zero-input path to video (R1.4). When nothing is remembered, or the Keychain
    /// no longer holds that password, the form is shown with whatever we do know pre-filled.
    func resumeOrPrompt() {
        // `.task` fires again if the window is closed and reopened; resuming twice would build a
        // second controller for the same camera and leak the first.
        guard !hasResumed else { return }
        hasResumed = true
        guard let remembered = LastConnection.load(from: defaults) else { return }
        host = remembered.host
        account = remembered.account
        sessionTask = Task { [weak self] in
            await self?.resume(remembered)
        }
    }

    /// Starts a connection from the form's contents. Safe to call twice; the second call is ignored
    /// while the first is still in flight.
    func connect() {
        guard !isConnecting else { return }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            report(failure: "Vigil needs the camera's address.",
                   remedy: "Type its IP address, for example 192.168.1.64.")
            return
        }
        guard !trimmedAccount.isEmpty, !password.isEmpty else {
            report(failure: "Vigil needs the camera's password.",
                   remedy: "Type the password you set on the camera.")
            return
        }
        host = trimmedHost
        account = trimmedAccount
        let secret = password
        // Reuse the Keychain handle when this is the same camera and account as last time: `save`
        // updates an existing item in place, whereas a fresh `CredentialRef` would leave the old
        // item behind as an orphan on every retry.
        let ref = rememberedRef(host: trimmedHost, account: trimmedAccount) ?? CredentialRef()
        beginConnecting()
        sessionTask = Task { [weak self] in
            await self?.connect(host: trimmedHost, account: trimmedAccount, secret: secret,
                                ref: ref)
        }
    }

    /// Tears the session down and returns to the form. Idempotent.
    ///
    /// - Parameter forget: when `true`, the remembered connection is cleared so the next launch
    ///   shows the form. Used when the camera rejected the credential — repeating a wrong password
    ///   at every launch is how Hikvision accounts get locked out (R-25).
    func disconnect(forget: Bool = false) {
        eventTask?.cancel()
        eventTask = nil
        sessionTask?.cancel()
        sessionTask = nil
        let outgoing = controller
        controller = nil
        activeRef = nil
        phase = .connect
        isConnecting = false
        isReceivingMedia = false
        streamState = nil
        statusLine = ""
        firstFrameLatency = nil
        if forget {
            LastConnection.clear(in: defaults)
        }
        guard let outgoing else { return }
        // Graceful TEARDOWN on its own task: `stop` is documented to be safe to await from a task
        // that is being cancelled, and the UI must not wait 1.5 s to go back to the form.
        Task { await outgoing.stop(reason: .userRequested) }
    }

    // MARK: - Private Helpers

    private func beginConnecting() {
        failure = nil
        failureRemedy = nil
        isConnecting = true
        isReceivingMedia = false
        firstFrameLatency = nil
        statusLine = Self.openingNarration
        phase = .live
    }

    /// The first-connect path: write the password to the Keychain, then stream.
    private func connect(host: String, account: String, secret: String, ref: CredentialRef) async {
        do {
            let camera = try makeCamera(host: host, ref: ref)
            let credential = Credential(ref: ref, account: account, secret: secret)
            // Verified against the landed source: `CredentialDescriptor(camera:account:)` derives
            // server, port, protocol and the Keychain Access label from the record, and `save`
            // preconditions that the credential's ref matches the descriptor's — which it does,
            // because both come from `ref`.
            let descriptor = CredentialDescriptor(camera: camera, account: account)
            try await credentials.save(credential, descriptor: descriptor)
            await stream(camera: camera, ref: ref)
        } catch {
            fail(with: error)
        }
    }

    /// The remembered-camera path: no form, no Keychain write, straight to streaming.
    private func resume(_ remembered: LastConnection) async {
        // Straight to the video screen, before the Keychain is even asked. A remembered connection
        // means we already believe there is a camera, and showing the form for the few milliseconds
        // the Keychain takes would put a flash of "type your password" in front of a user who is
        // about to be shown video.
        beginConnecting()
        do {
            // A missing item is a normal outcome, not an error (`errSecItemNotFound`,
            // docs/spec-core.md §6.4) — it means the user removed it in Keychain Access, so we ask.
            // `hasCredential` answers from `kSecReturnAttributes` alone, so this launch-time check
            // does not decrypt the secret; the controller's provider does that when it connects.
            guard try await credentials.hasCredential(for: remembered.credentialRef) else {
                LastConnection.clear(in: defaults)
                phase = .connect
                isConnecting = false
                report(failure: "Vigil no longer has this camera's password.",
                       remedy: "Enter it again.")
                return
            }
            let camera = try makeCamera(host: remembered.host,
                                        ref: remembered.credentialRef,
                                        rtspPath: remembered.rtspPath)
            resolvedPath = remembered.rtspPath
            await stream(camera: camera, ref: remembered.credentialRef)
        } catch {
            // Nothing is on screen yet, so the honest result is the form plus an explanation.
            fail(with: error)
        }
    }

    /// Builds the one camera record the slice uses, with every field but the address defaulted.
    ///
    /// Verified against the landed source (`Sources/VigilCore/Model/Camera.swift`):
    ///     public init(id:name:host:httpPort:rtspPort:useTLS:channel:preferredQuality:transport:
    ///                 credentialRef:capabilities:createdAt:lastSeenAt:isEnabled:rtspPathOverride:
    ///                 latencyPreset:)   // everything but `host` defaulted
    ///     func validated() throws(CameraValidationError) -> Camera
    ///
    /// `validated()` supplies the name (`"Camera <host>"`), strips IPv6 brackets, and throws
    /// `.invalidHost` when the user pasted a URL rather than an address — which is exactly the
    /// mistake the form invites, so the message must reach them.
    private func makeCamera(host: String, ref: CredentialRef, rtspPath: String? = nil) throws
        -> Camera {
        // `rtspPathOverride` carries the ladder's winner from the last successful run, so R1.2's
        // "the probe happens exactly once per device, ever" holds across launches. In W4 this is
        // `capabilities.resolvedRTSPPath` read back from `library.json`; the slice has no library,
        // and skipping four `DESCRIBE` round-trips is worth this much borrowing of the field.
        try Camera(host: host, credentialRef: ref, rtspPathOverride: rtspPath).validated()
    }

    /// Builds the controller, subscribes to its events, and starts it. The only place a
    /// `StreamController` is created in the app.
    private func stream(camera: Camera, ref: CredentialRef) async {
        activeRef = ref
        let store = credentials
        // The provider is called by the controller on every connect attempt, so the password is
        // read from the Keychain each time and never captured in the closure (docs/spec-core.md §2).
        let provider: @Sendable () async throws -> Credential? = {
            try await store.credential(for: ref)
        }
        // ASSUMED SIGNATURE (VigilCore/Streaming/StreamController.swift, docs/API_CONTRACT.md §4.8):
        //     public init(camera: Camera,
        //                 credentialProvider: @Sendable @escaping () async throws -> Credential?,
        //                 initialQuality: StreamQuality,
        //                 initialPriority: StreamPriority,
        //                 dependencies: CoreDependencies,
        //                 recorderFactory: ...)
        // The contract's `recorderFactory` is omitted: `ClipRecorder` is W4 and recording is out of
        // scope for the slice, so the slice's initialiser cannot require it.
        let controller = StreamController(camera: camera,
                                          credentialProvider: provider,
                                          initialQuality: .main,
                                          initialPriority: .focused,
                                          dependencies: dependencies)
        self.controller = controller
        // `events()` is `nonisolated` and returns a fresh bounded stream per call (R-27), so this
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
    /// The `default` arm is deliberate: the slice reacts to four of `StreamEvent`'s cases and must
    /// keep consuming the rest — statistics, keyframes, warnings, path resolution — rather than
    /// leave them to fill the stream's bounded buffer. It also means a case added in W4 cannot stop
    /// this file compiling.
    private func apply(_ event: StreamEvent) {
        switch event {
        case .stateChanged(_, let to, let detail):
            streamState = to
            // `StateDetail` is not optional in the landed enum, and its narration already falls
            // back to `StreamState.narration` for a plain transition (`StateDetail.plain`).
            statusLine = isReceivingMedia && to.isActive ? "" : detail.narration
            if let underlying = detail.underlying {
                report(streamError: underlying)
            }
        case .firstFrameAssembled(let afterStart):
            isReceivingMedia = true
            isConnecting = false
            firstFrameLatency = afterStart
            statusLine = ""
            failure = nil
            failureRemedy = nil
            // The Keychain has the password now, so the copy in memory — and in the form's secure
            // field — has no reason to exist.
            password = ""
            if let activeRef {
                LastConnection(host: host, account: account, credentialRef: activeRef,
                               rtspPath: resolvedPath).save(to: defaults)
            }
            // The R1.7 number, in the log where the acceptance checklist can read it.
            dependencies.logger.info(.app, "first frame assembled after \(afterStart)")
        case .pathResolved(let candidate, _):
            // Remembered at the first frame, not here: a path that answers `DESCRIBE` but never
            // delivers video is not the one to start from next time.
            resolvedPath = candidate.path
        case .error(let error, let isFatal):
            report(streamError: error)
            // A rejected password is worth deleting; a locked or unauthorised account is not, since
            // the password itself may well be right and the user would have to type it again for
            // nothing.
            let rejected = error.code == .authenticationFailed ? activeRef : nil
            if error.code.forbidsColdRetry {
                // Terminal, and only the user can fix it. Back to the form, and stop remembering a
                // password the camera rejects: retrying it on every launch is precisely how a
                // Hikvision account gets locked out (R-25, R1.5 "Account locked").
                disconnect(forget: true)
                if let rejected {
                    deleteRejectedCredential(rejected)
                }
            } else if isFatal {
                isConnecting = false
                statusLine = error.message
            }
        case .ended(let reason):
            isConnecting = false
            statusLine = "The stream ended (\(reason))."
        default:
            break
        }
    }

    private func fail(with error: any Error) {
        isConnecting = false
        phase = .connect
        applyDescription(of: error)
        dependencies.logger.error(.app, "connect failed: \(error)")
    }

    private func report(streamError: StreamError) {
        report(failure: streamError.message, remedy: streamError.fix)
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
    /// Fire-and-forget, on purpose: the user is already looking at the form, and a Keychain that
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

    private func report(failure message: String, remedy: String?) {
        failure = message
        failureRemedy = remedy
    }

    /// Turns any error on the connect path into the cause/remedy pair the UI shows.
    ///
    /// Three sources, in the order they can occur: the address the user typed, the Keychain, and
    /// everything else. `localizedDescription` is the last resort and never the first, because for
    /// a `POSIXError` or an `NWError` it produces exactly the raw text R1.5 forbids.
    private func applyDescription(of error: any Error) {
        switch error {
        case let streamError as StreamError:
            report(streamError: streamError)
        case is CameraValidationError:
            // `CameraValidationError.description` is a redacted log line, not a sentence for a
            // person, so the user-facing copy is written here.
            report(failure: "That does not look like a camera address.",
                   remedy: "Type just the address — no rtsp://, no user name and no path.")
        case let failure as any VigilFailure:
            report(failure: failure.userMessage, remedy: failure.userRemedy)
        default:
            report(failure: "Vigil could not reach the camera.",
                   remedy: "Check that the address is right and the camera is powered on.")
        }
    }

    /// What the status line says between pressing Return and the controller's first transition.
    ///
    /// Every later sentence comes from `StateDetail.narration`, which is the authority
    /// (docs/spec-core.md §7.3) and is localized. This one exists only so the line is never blank
    /// while something is happening.
    private static let openingNarration = StreamState.connecting.narration
}

#endif  // os(macOS)
