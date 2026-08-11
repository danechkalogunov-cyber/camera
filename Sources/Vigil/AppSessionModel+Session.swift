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
import VigilISAPI
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
    ///
    /// ⚠️ `sessionTask` is cancelled here and nowhere else: it is the connect the *user* started,
    /// one per application however many cameras are streaming, and stopping one camera must not
    /// cancel a connect that another one is in the middle of.
    func stopSession() {
        sessionTask?.cancel()
        sessionTask = nil
        stop(live)
    }

    /// Tears one camera's stream down, whichever camera it is.
    ///
    /// The state is cleared synchronously so the window reads the right thing on the next frame;
    /// the two `async` stops happen off this path, because a polite socket teardown takes up to
    /// 1.5 s and no click should wait for it.
    func stop(_ stream: CameraStream) {
        let audioKey = stream.camera.map { StreamKey(camera: $0.id, quality: .main) }
        let outgoing = stream.teardown()
        rebalanceDecodeBudget()
        guard outgoing.controller != nil || outgoing.pipeline != nil else { return }
        // The tile keeps its last picture on purpose — no flush, no blanking (R-36, §4.9).
        Task {
            if let audioKey { await audioPlayback.remove(audioKey) }
            await outgoing.pipeline?.stop(reason: .stopped)
            // Graceful TEARDOWN, off the caller's path: `stop` is safe to await from a cancelled
            // task, and the UI must not wait 1.5 s for a socket to close politely.
            await outgoing.controller?.stop(reason: .userRequested)
        }
    }

    /// Moves the window to the video screen and puts the live stream into its connecting state.
    ///
    /// ⚠️ `phase` is the application's, the rest is the stream's — see `CameraStream.beginConnecting`.
    func beginConnecting() {
        phase = .live
        live.beginConnecting()
    }

    /// The form path: write the password to the Keychain, then stream.
    func connect(_ request: ConnectRequest, ref: CredentialRef, rtspPath: String?) async {
        do {
            // ⚠️ The remembered name is carried in, and this is not cosmetic. Built without one,
            // `Camera.validated()` invents "Camera 192.168.1.64" from the host — and because
            // `rememberThisCamera()` runs on every first frame, that invention was then written
            // over whatever the user had renamed the camera to. A rename survived until the first
            // reconnect and no longer, which reads exactly like "renaming does not save".
            //
            // Only for the same host: a different address is a different camera and must not
            // inherit its name.
            let remembered = LastConnection.load(from: defaults)
            let rememberedName = remembered?.host == request.host ? remembered?.name : nil
            var camera = try makeCamera(host: request.host, ref: ref, rtspPath: rtspPath,
                                        name: rememberedName)
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
            if rtspPath == nil,
               let resolved = await resolveONVIFStream(for: request, camera: camera) {
                camera.rtspPort = resolved.port
                camera.rtspPathOverride = resolved.path
                self.rtspPort = resolved.port
                self.resolvedPath = resolved.path
            }
            await stream(camera: camera, ref: ref)
        } catch {
            fail(with: error, host: request.host)
        }
    }

    /// Uses authenticated ONVIF Device + Media calls only for the discovery row that supplied it.
    private func resolveONVIFStream(for request: ConnectRequest, camera: Camera) async
        -> (port: Int, path: String)? {
        guard let deviceURL = pendingONVIFServiceURL,
              deviceURL.host?.caseInsensitiveCompare(request.host) == .orderedSame else {
            pendingONVIFServiceURL = nil
            return nil
        }
        pendingONVIFServiceURL = nil
        do {
            let secret: String
            if request.password.isEmpty {
                guard let stored = try await credentials.credential(for: camera) else { return nil }
                secret = stored.secret
            } else {
                secret = request.password
            }
            var random = dependencies.random
            func freshToken() -> WSUsernameToken {
                WSUsernameToken(username: request.username, password: secret,
                                nonce: random.randomBytes(20),
                                created: ISO8601DateFormatter().string(from: Date()))
            }
            let transport = URLSessionHTTPTransport(logger: dependencies.logger)
            let device = ONVIFMediaClient(endpoint: deviceURL, transport: transport)
            let mediaURL = try await device.getMediaServiceURL(token: freshToken())
            guard mediaURL.host?.caseInsensitiveCompare(request.host) == .orderedSame else {
                dependencies.logger.warning(.app, "ONVIF returned a Media service on another host")
                return nil
            }
            let media = ONVIFMediaClient(endpoint: mediaURL, transport: transport)
            guard let profile = try await media.getProfiles(token: freshToken()).first else {
                dependencies.logger.notice(.app, "ONVIF device reported no media profiles")
                return nil
            }
            let streamURL = try await media.getStreamURI(profileToken: profile.token,
                                                         token: freshToken())
            guard streamURL.host?.caseInsensitiveCompare(request.host) == .orderedSame,
                  streamURL.scheme?.lowercased() == "rtsp" else {
                dependencies.logger.warning(.app, "ONVIF returned an unsafe stream URI")
                return nil
            }
            var path = streamURL.path.isEmpty ? "/" : streamURL.path
            if let query = streamURL.query, !query.isEmpty { path += "?\(query)" }
            return (streamURL.port ?? request.rtspPort, path)
        } catch {
            dependencies.logger.notice(.app, "ONVIF media fallback failed",
                                       ["reason": String(describing: error)])
            return nil
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
            // ⚠️ `id:` carried through, and it is the whole of the fix for "two cameras, one of
            // them permanently offline". Without it every launch minted a fresh `CameraID` for the
            // same device, so the resumed camera never matched its own row in `library.json` — the
            // sidebar drew both, and group membership, bookmarks and the clip list all detached.
            let camera = try makeCamera(host: remembered.host,
                                        ref: remembered.credentialRef,
                                        rtspPath: remembered.rtspPath,
                                        name: remembered.name,
                                        id: remembered.cameraID,
                                        transport: remembered.transport,
                                        lastWorkingTransport: remembered.lastWorkingTransport)
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
    /// - Parameter id: the identity this camera had last launch, or `nil` to mint a new one. Same
    ///   argument as `name`, and with more riding on it: `CameraID` is the key for group
    ///   membership, bookmarks, the clip list and the stage assignment, so a fresh one silently
    ///   detaches all four and leaves the library's own row for this device looking like a second,
    ///   permanently offline camera.
    func makeCamera(host: String, ref: CredentialRef, rtspPath: String? = nil,
                    name: String? = nil, id: CameraID? = nil,
                    transport: RTSPTransportKind? = nil,
                    lastWorkingTransport: RTSPTransportKind? = nil) throws -> Camera {
        try Camera(id: id ?? CameraID(),
                   name: name ?? "",
                   host: host,
                   httpPort: form.httpPort,
                   rtspPort: rtspPort,
                   useTLS: form.usesTLS,
                   channel: ChannelID(form.channel),
                   transport: transport ?? GeneralPreferenceKey.defaultTransport(in: defaults),
                   lastWorkingTransport: lastWorkingTransport,
                   credentialRef: ref,
                   rtspPathOverride: rtspPath).validated()
    }

    /// Builds the decode chain and the controller, subscribes to its events, and starts it.
    ///
    /// This is the whole column, in the order the bytes travel: socket (`CoreDependencies`
    /// `makeRTSPSession`) → `StreamController` → `EncodedFrame` → `DecodePipeline` →
    /// `TileVideoSink` → `VideoTileView`'s `AVSampleBufferDisplayLayer`.
    ///
    /// Drives ``live``, which is what every existing caller means by "the stream". The work itself
    /// is in ``start(_:camera:ref:)`` and knows nothing about which stream it is building.
    func stream(camera: Camera, ref: CredentialRef) async {
        await start(live, camera: camera, ref: ref)
    }

    /// Builds one camera's decode chain and controller, and starts it.
    ///
    /// ⛔ Every line here reads and writes the `stream` argument rather than `self`. That is the
    /// whole of F-LIV-01's step 3: the same code that has driven one camera since the first frame
    /// now drives whichever camera it is handed, so a second one is another call rather than a
    /// second implementation. The four defects the first live camera exposed were all
    /// two-implementation seams; this refactor exists to avoid adding a fifth.
    func start(_ stream: CameraStream, camera: Camera, ref: CredentialRef) async {
        stream.camera = camera
        let muteKey = "Vigil.audio.muted.\(camera.id.rawValue.uuidString)"
        stream.isAudioMuted = defaults.object(forKey: muteKey) as? Bool ?? true
        stream.hasAudio = false
        if !stream.isAudioMuted {
            // A hand-edited defaults domain or an older build can leave more than one camera
            // remembered as audible. Restore the same one-route invariant the mute button enforces
            // before any audio packet reaches the graph; the stream starting now wins.
            for other in cameras.streams.values where other !== stream {
                other.isAudioMuted = true
                if let otherID = other.camera?.id {
                    defaults.set(true, forKey: "Vigil.audio.muted.\(otherID.rawValue.uuidString)")
                }
            }
            await audioPlayback.solo(StreamKey(camera: camera.id, quality: .main))
        }
        cameras.file(stream)
        stream.activeRef = ref
        stream.attemptStartedAt = Date()
        let store = credentials
        // Called by the controller on every connect attempt, so the password is read from the
        // Keychain each time and never captured in the closure (docs/spec-core.md §2).
        let provider: @Sendable () async throws -> Credential? = {
            try await store.credential(for: ref)
        }
        let logger = dependencies.logger
        let pipeline = DecodePipeline(
            sink: stream.tileSink,
            pacing: .live,
            requestKeyframe: { [weak self, weak stream] in
                Task { @MainActor in
                    guard let self, let stream else { return }
                    self.recoverStalledPicture(on: stream)
                }
            },
            onError: { error in
                // Never swallowed: "no video, no error" is the worst failure we could ship.
                logger.error(.video, "decode: \(error)")
            })
        stream.pipeline = pipeline
        rebalanceDecodeBudget()
        // One ordered hop from the controller's isolation to the pipeline actor. A `Task` per frame
        // would preserve neither order nor allocation budget; a single-consumer stream does both,
        // and its bounded buffer drops the oldest frames rather than growing without limit (R-27).
        let (frameStream, continuation) = AsyncStream<EncodedFrame>.makeStream(
            of: EncodedFrame.self, bufferingPolicy: .bufferingNewest(64))
        stream.frameContinuation = continuation
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
        let recordingTap = stream.recordingTap
        let telemetry = stream.telemetry
        let backlog = stream.backlog
        let mediaClock = dependencies.clock
        let audioPlayback = self.audioPlayback
        let audioKey = StreamKey(camera: camera.id, quality: .main)
        backlog.reset()
        stream.decodeTask = Task.detached {
            for await frame in frameStream {
                if frame.codec.audio != nil {
                    await audioPlayback.submit(frame, for: audioKey)
                    backlog.departed()
                    continue
                }
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
                if let recorder = recordingTap.route(frame) {
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
                                              if frame.codec.audio != nil {
                                                  Task { @MainActor [weak stream] in
                                                      stream?.hasAudio = true
                                                  }
                                              }
                                          },
                                          // Normal speed sends no `Scale:` at all, so a live
                                          // stream is byte-identical to what it was before speed
                                          // existed. Only archive playback ever sets one.
                                          playbackScale: stream.playback == nil
                                              || stream.playbackRate == .normal
                                              ? nil
                                              : stream.playbackRate.scale)
        stream.controller = controller
        startTilePolicy(on: stream, controller: controller)
        // `events()` is `nonisolated` and returns a fresh bounded stream per call (R-27), so the
        // subscription is established before `start()` and cannot miss the first transition.
        stream.eventTask = Task { [weak self, weak stream] in
            for await event in controller.events() {
                guard let self, let stream else { return }
                stream.telemetry.ingest(event, at: self.dependencies.clock.now())
                self.apply(event, to: stream)
            }
        }
        await controller.start()
    }

    /// Samples the renderer's authoritative backing-pixel size and applies the policy's dwell.
    /// A quality handoff restarts only the network session; the mounted tile and its last drawable
    /// remain in place, so resize-driven promotion never inserts a synthetic black frame.
    private func startTilePolicy(on stream: CameraStream, controller: StreamController) {
        stream.tilePolicyTask?.cancel()
        stream.tilePolicyTask = Task { [weak stream] in
            var selector = TilePolicySelector()
            let clock = ContinuousClock()
            let origin = clock.now
            while !Task.isCancelled {
                guard let stream else { return }
                let context = TileContext(
                    pixelSize: stream.renderState?.pixelSize ?? Resolution(width: 0, height: 0),
                    isVisible: stream.renderState != nil,
                    isRecording: stream.recordingTap.recorder() != nil,
                    subStreamHeight: nil,
                    deviceSupportsSubStream: true,
                    qualityOverride: stream.camera?.preferredQuality)
                if case .stream(let quality)? = selector.ingest(context, at: origin.duration(to: clock.now)) {
                    await controller.setQuality(quality)
                }
                if let cameraID = stream.camera?.id {
                    let key = StreamKey(camera: cameraID, quality: .main)
                    let audio = await audioPlayback.statistics(for: key)
                    stream.audioLevel = audio.rmsLevel
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Folds one controller event into observable state.
    ///
    /// The `default` arm is deliberate: the slice reacts to seven of `StreamEvent`'s cases and must
    /// keep consuming the rest rather than leave them to fill the stream's bounded buffer. It also
    /// means a case added in W4 cannot stop this file compiling.
    ///
    /// ⛔ WHAT IS THE CAMERA'S AND WHAT IS THE APPLICATION'S. Everything that describes the stream —
    /// its state, its attempt count, its diagnosis, its format — goes on `stream`, so sixteen of
    /// them can be in sixteen different states at once. Four things do not: the connect form, the
    /// remembered connection, the failure screen and the Keychain deletion belong to the user's one
    /// connect attempt, and they are gated on `stream === live`. Without that gate, camera nine
    /// getting its first frame would clear the form under a user who is typing camera ten's
    /// password, and camera three failing would throw the window off camera one.
    func apply(_ event: StreamEvent, to stream: CameraStream) {
        let isLive = stream === live
        switch event {
        case .stateChanged(_, let to, let detail):
            stream.streamState = to
            stream.attempt = max(1, detail.attempt)
            stream.retryInSeconds = Self.seconds(until: detail.nextRetryAt)
            if let underlying = detail.underlying, let camera = stream.camera {
                stream.diagnosis = ConnectDiagnosis.from(underlying, camera: camera)
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
            resetDecodePipeline(on: stream)
        case .firstPacketReceived:
            stream.hasFirstPacket = true
        case .firstFrameAssembled(let afterStart):
            stream.isReceivingMedia = true
            stream.firstFrameLatency = afterStart
            stream.lastSeen = Date()
            stream.diagnosis = nil
            if isLive {
                form.isConnecting = false
                form.clearDiagnosis()
                // The Keychain has the password now, so the copy in memory — and in the form's
                // secure field — has no reason to exist.
                form.password = ""
                rememberThisCamera()
            }
            // The R1.7 number, in the log where the acceptance checklist can read it.
            dependencies.logger.info(.app, "first frame assembled after \(afterStart)")
            // For an archive seek, the same number split at the point Vigil hands over. `afterStart`
            // is the camera's half — handshake, opening the recording, first keyframe. The
            // difference is Vigil's own: tearing the old session down and building the new one.
            // Printed as two numbers because they have different owners and different fixes, and a
            // single "one second" tells you which to work on only by accident.
            if let startedAt = stream.seekStartedAt {
                let total = dependencies.clock.now() - startedAt
                dependencies.logger.info(.app, "seek complete: \(total) total, "
                    + "\(afterStart) of it after the socket opened")
                stream.seekStartedAt = nil
            }
        case .pathResolved(let candidate, let capabilities):
            // Remembered at the first frame, not here: a path that answers `DESCRIBE` but never
            // delivers video is not the one to start from next time.
            stream.resolvedPath = candidate.path
            stream.camera?.capabilities = capabilities
        case .statistics(let latest):
            stream.statistics = latest
            if stream.streamState.isActive { stream.lastSeen = Date() }
        case .reconnectScheduled(let attempt, let delay, let cause):
            stream.attempt = attempt
            stream.retryInSeconds = Int(delay.components.seconds)
            if let camera = stream.camera {
                stream.diagnosis = ConnectDiagnosis.from(cause, camera: camera)
            }
        case .error(let error, let isFatal):
            guard let camera = stream.camera else { return }
            let named = ConnectDiagnosis.from(error, camera: camera)
            stream.diagnosis = named
            guard !named.allowsAutomaticRetry || isFatal else { return }
            // Terminal. Back to the form with the cause and its remedies, and stop remembering a
            // password the camera rejects — retrying it at every launch is precisely how a
            // Hikvision account gets locked out (R-25, R1.5 "Account locked").
            let rejected = error.code == .authenticationFailed ? stream.activeRef : nil
            // ⚠️ Only this camera stops. `stopSession()` also cancels the application's connect
            // task, which belongs to whatever the user asked for last — a camera dying in a corner
            // of a sixteen-tile wall must not cancel the connect the user started a moment ago.
            if isLive { stopSession() } else { stop(stream) }
            // The Keychain deletion is this camera's, whichever camera it is: a password the device
            // rejects is what walks an account into a thirty-minute lockout, and it does that from a
            // background tile exactly as fast as from the one on screen.
            if let rejected { deleteRejectedCredential(rejected) }
            guard isLive else { return }
            if !named.allowsAutomaticRetry { LastConnection.clear(in: defaults) }
            present(named)
        case .formatResolved(let resolved):
            stream.format = resolved
            rebalanceDecodeBudget()
        case .transportSelected(let transport):
            guard var camera = stream.camera else { return }
            camera.lastWorkingTransport = transport
            stream.camera = camera
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
        resetDecodePipeline(on: live)
    }

    /// The same, for whichever camera reconnected.
    func resetDecodePipeline(on stream: CameraStream) {
        stream.decodeFailures = 0
        stream.droppedByReason.removeAll()
        guard let pipeline = stream.pipeline else { return }
        Task { await pipeline.reset() }
    }
}

#endif  // os(macOS)
