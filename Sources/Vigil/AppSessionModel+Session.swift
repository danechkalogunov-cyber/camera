//
//  AppSessionModel+Session.swift
//  Vigil
//
//  The other half of `AppSessionModel`: the connect path, the decode chain, and the fold from
//  `StreamEvent` into what the two screens show.
//  macOS-only. See docs/API_CONTRACT.md §4.12, docs/spec-core.md §7 and REQUIREMENTS-CUSTOMER §R1.
//

#if os(macOS)

import AppKit
import Foundation

import VigilCore
import VigilProtocols
import VigilRender
import VigilUI
import VigilVideo

// MARK: - Session lifecycle

extension AppSessionModel {

    /// Tears the current session down: tasks, decode chain, controller.
    ///
    /// Leaves `phase` and the form alone, because both callers want something different afterwards
    /// — `disconnect` goes back to the form, `connect` starts another session immediately.
    func stopSession() {
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
        isReceivingMedia = false
        hasFirstPacket = false
        streamState = .idle
        retryInSeconds = nil
        firstFrameLatency = nil
        attemptStartedAt = nil
        guard outgoing != nil || outgoingPipeline != nil else { return }
        // The tile keeps its last picture on purpose — no flush, no blanking (R-36, §4.9).
        Task {
            await outgoingPipeline?.stop(reason: .stopped)
            // Graceful TEARDOWN, off the caller's path: `stop` is safe to await from a cancelled
            // task, and the UI must not wait 1.5 s for a socket to close politely.
            await outgoing?.stop(reason: .userRequested)
        }
    }

    func beginConnecting() {
        phase = .live
        streamState = .resolving
        isReceivingMedia = false
        hasFirstPacket = false
        firstFrameLatency = nil
        retryInSeconds = nil
        attempt = 1
    }

    /// The form path: write the password to the Keychain, then stream.
    func connect(_ request: ConnectRequest, ref: CredentialRef, rtspPath: String?) async {
        do {
            let camera = try makeCamera(host: request.host, ref: ref, rtspPath: rtspPath)
            if request.password.isEmpty {
                // A retry after the password already reached the Keychain: the form clears its
                // secure field once a frame arrives, so the empty string it now holds must never be
                // written over a credential that works.
                guard try await credentials.hasCredential(for: ref) else {
                    // No stored password and none typed. `wrongPassword` is the closest named cause
                    // — its remedy puts the cursor in the password field, which is the action that
                    // matters — and `ConnectDiagnosis` has no "never had one" case to be exact with.
                    present(.wrongPassword(host: request.host))
                    return
                }
            } else {
                let credential = Credential(ref: ref,
                                            account: request.username,
                                            secret: request.password)
                // `CredentialDescriptor(camera:account:)` derives server, port, protocol and the
                // Keychain Access label from the record; `save` preconditions that the credential's
                // ref matches the descriptor's, which it does because both come from `ref`.
                let descriptor = CredentialDescriptor(camera: camera, account: request.username)
                try await credentials.save(credential, descriptor: descriptor)
            }
            await stream(camera: camera, ref: ref)
        } catch {
            fail(with: error, host: request.host)
        }
    }

    /// The remembered-camera path: no form, no Keychain write, straight to streaming.
    func resume(_ remembered: LastConnection) async {
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
    func makeCamera(host: String, ref: CredentialRef, rtspPath: String? = nil) throws
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
    func stream(camera: Camera, ref: CredentialRef) async {
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
    func apply(_ event: StreamEvent) {
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
            stopSession()
            if !named.allowsAutomaticRetry { LastConnection.clear(in: defaults) }
            present(named)
            if let rejected { deleteRejectedCredential(rejected) }
        default:
            break
        }
    }

    func rememberThisCamera() {
        guard let activeRef, let camera else { return }
        // `form.request.username`, not `form.username`: the request is the trimmed form, and it is
        // what `knownHandle(for:)` compares against on the next connect. Storing the raw field
        // would make a name typed with a trailing space fail to match itself, mint a second
        // `CredentialRef`, orphan the Keychain item and lose the learned RTSP path.
        LastConnection(host: camera.host,
                       account: form.request.username,
                       credentialRef: activeRef,
                       rtspPath: resolvedPath).save(to: defaults)
    }

    /// A failure before the controller existed: a bad address, or a Keychain that would not answer.
    func fail(with error: any Error, host: String) {
        present(Self.diagnosis(for: error, host: host))
        dependencies.logger.error(.app, "connect failed: \(error)")
    }

    /// Shows a named cause on the connect form.
    ///
    /// `ConnectFormState.fail` also clears the in-flight flag and bumps the failure counter that
    /// drives the form's one-per-failure shake, so this is the only way a diagnosis reaches it.
    func present(_ named: ConnectDiagnosis) {
        diagnosis = named
        phase = .connect
        form.fail(named)
    }

    /// Turns an error raised on the app's own half of the connect path into a named cause.
    ///
    /// `StreamError` never reaches here — the controller reports those through its event stream —
    /// so this covers exactly two sources: the address the user typed, and the Keychain.
    static func diagnosis(for error: any Error, host: String) -> ConnectDiagnosis {
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

    /// What we already know about this host and account: its Keychain handle, and the RTSP path
    /// that worked last time.
    ///
    /// Reusing the handle matters because `save` updates an item in place, whereas a fresh
    /// `CredentialRef` would leave the old item behind as an orphan on every retry. Reusing the
    /// path is R1.2's "the probe happens exactly once per device, ever".
    func knownHandle(for request: ConnectRequest) -> (ref: CredentialRef, rtspPath: String?) {
        guard let remembered = LastConnection.load(from: defaults),
              remembered.host.caseInsensitiveCompare(request.host) == .orderedSame,
              remembered.account == request.username
        else {
            return (CredentialRef(), nil)
        }
        return (remembered.credentialRef, remembered.rtspPath)
    }

    /// Removes a password the camera has rejected.
    ///
    /// Fire-and-forget on purpose: the user is already looking at the form, and a Keychain that
    /// refuses the delete changes nothing they can act on. The failure is logged, not shown.
    func deleteRejectedCredential(_ ref: CredentialRef) {
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
    func openCameraWebPage() {
        let host = camera?.host ?? form.request.host
        let port = camera?.httpPort ?? 80
        let authority = host.contains(":") ? "[\(host)]" : host   // bare IPv6 needs brackets
        guard !host.isEmpty, let url = URL(string: "http://\(authority):\(port)/") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Reports a remedy the slice cannot perform, in place of doing nothing.
    func unavailable(_ sentence: String) {
        let host = camera?.host ?? form.request.host
        present(.undiagnosed(host: host, detail: sentence))
        dependencies.logger.notice(.ui, sentence)
    }

    /// Whole seconds from now until `date`, or `nil` when there is no countdown.
    static func seconds(until date: Date?) -> Int? {
        guard let date else { return nil }
        return max(0, Int(date.timeIntervalSinceNow.rounded()))
    }

    /// The port Hikvision devices use when 554 is taken or disabled (R1.5 "RTSP port closed").
    static let alternateRTSPPort = 8554

    /// The shortest gap between two forced keyframe recoveries.
    static let recoveryInterval: TimeInterval = 10
}

#endif  // os(macOS)
