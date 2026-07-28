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
        decodeFailures = 0
        droppedByReason.removeAll()
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
                // §4 of docs/RULING-LOCKOUT.md, and the reason it cannot be skipped: after §2.4 the
                // authentication counter outlives every controller, so a genuinely new password would
                // otherwise never clear it and the user would stay blocked with the *right* password.
                // The clear is explicit and it is gated on proof of difference — the fingerprint is
                // computed here, where the `CredentialRef` is known, and the governor only compares.
                // Retyping the same characters clears nothing, which matters because that is the most
                // likely route to a real thirty-minute lockout.
                //
                // It happens here rather than only in `StreamController.credentialsUpdated()` because
                // `AppSessionModel.connect(_:)` calls `stopSession()` before this runs, so there is
                // normally no controller left to tell. The controller hand-off below is kept for the
                // case where there is one: telling a live controller is strictly better than
                // rebuilding it.
                let cleared = await dependencies.governor.clear(
                    host: camera.host,
                    account: request.username,
                    secretFingerprint: SecretFingerprint.of(credential))
                dependencies.logger.info(.app, "password saved; auth counters "
                    + (cleared ? "cleared" : "kept — same password"))
                if let existing = controller, activeRef == ref, camera.id == self.camera?.id {
                    await existing.credentialsUpdated()
                    return
                }
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
                                        rtspPath: remembered.rtspPath,
                                        name: remembered.name)
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
    /// - Parameter name: the name the user gave this camera on a previous launch, or `nil` to let
    ///   `validated()` derive one from the host. Passing it back in is what makes a rename survive
    ///   a relaunch — the record itself is rebuilt from scratch every time, so nothing else could.
    func makeCamera(host: String, ref: CredentialRef, rtspPath: String? = nil,
                    name: String? = nil) throws -> Camera {
        try Camera(name: name ?? "",
                   host: host,
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
        // ⛔ `Task.detached`, and it must stay detached. `Task { }` carries
        // `@_inheritActorContext`, so a plain `Task` started from this `@MainActor` method would run
        // its `for await` loop **on the main actor** — every access unit would hop onto the UI
        // thread and back out again on its way to the pipeline actor. That is the media path
        // crossing the main thread once per frame, which DESIGN.md §7.9 forbids outright and which
        // works directly against the 250 ms glass-to-glass budget (REQUIREMENTS §R3). It is
        // invisible on one camera and ruinous on a sixteen-tile grid, so it would never be found
        // later. Detached is not an optimisation here; a plain `Task` is the bug.
        //
        // Nothing in the loop needs main-actor state: `frameStream` is `Sendable` because
        // `EncodedFrame` is, and `pipeline` is an actor.
        // `recordingTap` is a `Sendable` box, not the recorder itself: recording starts long after
        // this loop does, so the loop cannot capture a recorder that does not exist yet — and it must
        // not capture `self`, which is `@MainActor`. Reading it costs one uncontended lock per frame,
        // and answers `nil` whenever nothing is being written.
        let recordingTap = self.recordingTap
        let telemetry = self.telemetry
        let backlog = self.backlog
        let mediaClock = dependencies.clock
        backlog.reset()
        decodeTask = Task.detached {
            for await frame in frameStream {
                // Counted before the hop into the pipeline, so the measurement is of what arrived
                // rather than of what the decoder got round to. Two integer additions under one
                // uncontended lock; nothing here allocates.
                telemetry.noteFrame(byteCount: frame.byteCount,
                                    isKeyframe: frame.isKeyframe,
                                    at: mediaClock.now())
                await pipeline.submit(frame)
                // Only the departure is recorded here. Reporting the depth at this point sampled
                // the minimum of the cycle — one frame had just been drained — so it read zero even
                // under load. The window reports the peak instead, once a second.
                backlog.departed()
                if let recorder = recordingTap.recorder() {
                    await recorder.append(frame)
                }
            }
        }
        let controller = StreamController(camera: camera,
                                          credentialProvider: provider,
                                          initialQuality: .main,
                                          initialPriority: .focused,
                                          dependencies: dependencies,
                                          frameSink: { frame in
                                              backlog.arrived()
                                              continuation.yield(frame)
                                          })
        self.controller = controller
        // `events()` is `nonisolated` and returns a fresh bounded stream per call (R-27), so the
        // subscription is established before `start()` and cannot miss the first transition.
        eventTask = Task { [weak self] in
            for await event in controller.events() {
                guard let self else { return }
                self.telemetry.ingest(event, at: self.dependencies.clock.now())
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
        case .connectAttemptStarted:
            // The decode pipeline outlives the socket, so a reconnect must tell it to forget the old
            // stream — otherwise it keeps the previous parameter sets and format description, and the
            // tile keeps a queue of samples belonging to a session that no longer exists. Nothing
            // called `reset()` at all until this arm existed (docs/INTEGRATION-TODO.md item 7); it
            // was latent only because the RTP layer waits for a keyframe on start.
            //
            // ⛔ This event, and not `formatResolved`, because this is the one moment that is
            // provably a **gap**: `StreamController` emits it before `connect()`, so the new session
            // has no socket yet and cannot have produced a frame. Resetting after frames are flowing
            // would race the detached decode task and throw away the new stream's parameter sets.
            //
            // Fires on the first attempt too, where it is a no-op on an empty pipeline, and on every
            // rung of the RTSP path ladder — each of which is equally a gap.
            //
            // The attempt number is deliberately not read here: `.stateChanged` owns that property
            // and carries the same value, and two writers for one number is how they drift apart.
            resetDecodePipeline()
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
        case .formatResolved(let resolved):
            format = resolved
        default:
            break
        }
    }

    /// Tells the decode pipeline the stream is starting over, and clears the display-path counters.
    ///
    /// `reset()` also calls `streamDidReset()` on the sink, which is how the tile learns to drop the
    /// samples it is holding **without** clearing the picture — the frozen last frame stays on screen
    /// under the reconnecting overlay, which is the no-black-flash rule (API_CONTRACT §4.9, R-36).
    func resetDecodePipeline() {
        decodeFailures = 0
        droppedByReason.removeAll()
        guard let pipeline else { return }
        Task { await pipeline.reset() }
    }

    // MARK: - Display-path reports

    /// A sample the video renderer refused to decode.
    ///
    /// `VigilRender` hands over a diagnostic string rather than an error, because `any Error` is not
    /// `Sendable` and the report crosses a thread boundary from whatever queue AVFoundation posts on.
    /// The decision about what to *do* is here rather than there, which is why the tile only reports.
    ///
    /// One failure is not a fault: a truncated access unit after packet loss produces exactly this
    /// and the next keyframe fixes it. A run of them means the decoder cannot make progress from the
    /// parameter sets it has, and the only escape is a fresh keyframe — which is what
    /// ``AppSessionModel/recoverStalledPicture()`` asks for, rate-limited so a decoder that keeps
    /// failing cannot put the session into a restart loop.
    func handleDecodeFailure(_ diagnostic: String) {
        decodeFailures += 1
        dependencies.logger.error(.video, "renderer failed to decode: \(diagnostic)")
        guard decodeFailures >= Self.decodeFailuresBeforeRecovery else { return }
        decodeFailures = 0
        recoverStalledPicture()
    }

    /// Frames that never reached the screen, from either end of the display path.
    ///
    /// Two origins arrive here through one callback: `VigilVideo`'s pipeline dropping an access unit
    /// before it became a sample buffer, and the tile's own renderer refusing one it was handed. The
    /// reason string keeps them apart, and the tile's ``VigilRender/TileRenderState`` already carries
    /// the running counts for the status line, so this method's job is the part no view can do —
    /// putting the fact in the log, and acting on the one reason that never resolves by itself.
    ///
    /// **`noFormat` is the case this exists for.** It means no parameter sets have arrived, so every
    /// frame is being discarded and the tile is black with nothing wrong anywhere else. Left alone it
    /// stays that way forever. Hikvision re-sends SPS/PPS immediately before every IDR, so asking
    /// for a keyframe is precisely the right remedy — the recovery that looks like it is about a
    /// stalled picture is really about getting the format.
    ///
    /// Logging is thresholded, not per frame: at 25 fps an unresolved `noFormat` would otherwise
    /// write 1,500 lines a minute and bury the line that matters.
    func handleFramesDropped(_ count: Int, reason: String) {
        droppedByReason[reason, default: 0] += count
        let total = droppedByReason[reason] ?? count
        if total.isMultiple(of: Self.dropLogInterval) || total == count {
            dependencies.logger.notice(.video, "dropped \(total) frame(s), reason: \(reason)")
        }
        guard reason == FrameDropReason.noFormat.rawValue,
              total >= Self.noFormatDropsBeforeRecovery
        else { return }
        droppedByReason[reason] = 0
        dependencies.logger.notice(.video, "no parameter sets after \(total) frames; asking for a "
            + "keyframe so the camera re-sends them")
        recoverStalledPicture()
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
                       rtspPath: resolvedPath,
                       // The name the user gave it, not the fallback `Camera.validated()` invents
                       // from the host — storing that one would make "Camera 192.168.1.64" look
                       // like a deliberate choice on the next launch.
                       name: camera.name).save(to: defaults)
    }

    /// Stores a renamed camera, so the name outlives the window.
    ///
    /// Separate from ``rememberThisCamera()`` because it must work before a frame has arrived: that
    /// one is called once video is flowing and requires `activeRef`, while a rename can happen the
    /// moment the sidebar row exists. Everything but the name is read back from what is already
    /// stored, so renaming cannot disturb the remembered account or the learned RTSP path.
    func rememberCameraName(_ name: String) {
        guard var remembered = LastConnection.load(from: defaults) else { return }
        remembered.name = name
        remembered.save(to: defaults)
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

    /// How many renderer decode failures in a row before forcing a keyframe.
    ///
    /// Three, because one is packet loss and two can be the same GOP; three means the parameter sets
    /// the decoder is working from cannot decode what the camera is sending.
    static let decodeFailuresBeforeRecovery = 3

    /// How many frames may be dropped for want of parameter sets before asking for a keyframe.
    ///
    /// Fifty is about two seconds at 25 fps — long enough that a normal startup, where the first
    /// access units precede the first SPS by a few frames, resolves on its own without a restart.
    static let noFormatDropsBeforeRecovery = 50

    /// One log line per this many dropped frames of the same reason.
    static let dropLogInterval = 100
}

#endif  // os(macOS)
