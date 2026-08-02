//
//  AppSessionModel+Memory.swift
//  Vigil
//
//  What survives quitting: the camera Vigil reconnects to, its name, and whether its picture
//  carries chrome. Plus the archive-playback pair that swaps the live path for a recorded one.
//  macOS-only. Split from AppSessionModel+Session.swift, which docs/DESIGN.md §7.2 caps at 600 lines.
//

#if os(macOS)

import Foundation

import VigilCore
import VigilISAPI
import VigilProtocols

// MARK: - Remembering, and playing back

extension AppSessionModel {

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

    /// Plays the archive from one instant, through the same decode path as the live picture.
    ///
    /// **A different URL, not a different pipeline.** Hikvision serves recorded video as an
    /// ordinary RTSP stream on `/Streaming/tracks/{id}?starttime=…` (spec-isapi.md §15.6), and the
    /// bytes that come back are the same H.264 or H.265 the live path already decodes. So this
    /// restarts the session against the locator's address and everything downstream — depacketiser,
    /// pipeline, display layer, recorder tap — is untouched.
    ///
    /// The address rides in `rtspPathOverride`, which `Camera.rtspPath(for:)` honours ahead of the
    /// probe ladder. That is right on both counts: a playback URI must not be probed for, and the
    /// ladder's learned live path must not be overwritten by it — `resolvedPath` is left alone, so
    /// ``returnToLive()`` puts the session back on the path R1.2 paid for.
    /// **Superseded seeks are dropped, not queued.** Each seek is a whole new RTSP session — five
    /// round trips before a frame — so two clicks a moment apart used to build two of them, and the
    /// user waited for the first to finish opening before the second even started. `seekGeneration`
    /// makes the newest request win: an older one that is still mid-handshake stops as soon as it
    /// notices it has been overtaken, and the camera is never asked to hold two playback sessions
    /// for one viewer. On a camera that permits a handful of concurrent sessions, that mattered.
    func playArchive(_ locator: PlaybackLocator) async {
        guard let camera, let activeRef else { return }
        seekGeneration &+= 1
        let generation = seekGeneration
        let previous = playback
        var target = camera
        target.rtspPathOverride = locator.rawQuery.isEmpty
            ? locator.path
            : locator.path + "?" + locator.rawQuery
        playback = locator
        seekStartedAt = dependencies.clock.now()

        // Fast path: an archive session on this very track is already open, so move it instead of
        // rebuilding it. Measured on a DS-I256 (docs/PLAYBACK-LATENCY.md): this skips the connect,
        // OPTIONS, both DESCRIBEs and SETUP, which together are ~650 ms of a ~1 900 ms seek. What
        // it does not skip is PLAY itself (~870 ms) and the first keyframe (~350 ms) — the camera
        // seeking and then encoding, which no client-side change can avoid.
        if previous?.path == locator.path, let controller,
           await controller.seekWithinSession(toRange: locator.clockRange) {
            // ⛔ The pipeline must be told, and nothing else will tell it. On the rebuild path the
            // reset rides on `.connectAttemptStarted`; an in-session seek raises no such event, so
            // without this the decoder would carry frames from the old position across the jump.
            resetDecodePipeline()
            armSeekFallback(generation: generation, camera: target, ref: activeRef)
            return
        }
        dependencies.logger.info(.app, "seek: opening \(target.rtspPathOverride ?? "")")
        stopSession()
        guard generation == seekGeneration else {
            dependencies.logger.debug(.app, "seek \(generation) superseded before it began")
            return
        }
        beginConnecting()
        await stream(camera: target, ref: activeRef)
    }

    /// Rebuilds the session if an in-session seek produced no picture.
    ///
    /// **Why a timeout and not an error.** `perform(.play(rangeText:))` is handed to the session and
    /// answered on the event stream, so firmware that ignores `Range:` on a URL opened with
    /// `?starttime=` does not fail — it simply keeps sending the old position, or nothing. There is
    /// no error to catch, only a picture that does not arrive, and the only place that knows what
    /// was expected is here.
    ///
    /// The budget is deliberately generous against the measurement: PLAY plus the first keyframe is
    /// ~1.2 s on the device in docs/PLAYBACK-LATENCY.md, so 3 s is more than double and still far
    /// under the wait it is protecting against. Overshooting costs a slower seek on cameras that do
    /// not support this; undershooting would tear down a session that was about to deliver.
    ///
    /// ⚠️ Worst case is the old behaviour plus this timeout — never a broken seek. That is the whole
    /// design: the fast path is an attempt, not an assumption, because no camera here can be asked
    /// in advance whether it honours the header.
    private func armSeekFallback(generation: UInt64, camera: Camera, ref: CredentialRef) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, generation == seekGeneration, seekStartedAt != nil else { return }
            dependencies.logger.notice(.app, "in-session seek produced no picture; rebuilding")
            stopSession()
            guard generation == seekGeneration else { return }
            beginConnecting()
            await stream(camera: camera, ref: ref)
        }
    }

    /// Returns the picture to the live stream.
    ///
    /// Restores the override the camera had before playback rather than clearing it: a user who set
    /// an explicit RTSP path in the connect form must get that path back, not the probe ladder.
    func returnToLive() async {
        guard playback != nil, let camera, let activeRef else { return }
        var target = camera
        target.rtspPathOverride = resolvedPath
        playback = nil
        // Bumped so a seek still opening does not finish into a session that has gone back to live,
        // and cleared so the live stream's first frame is not reported as a seek that took as long
        // as the user spent deciding to leave.
        seekGeneration &+= 1
        seekStartedAt = nil
        dependencies.logger.info(.app, "returning to the live stream")
        stopSession()
        beginConnecting()
        await stream(camera: target, ref: activeRef)
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

    /// Stores whether this camera's picture carries chrome on top of it.
    func rememberVideoOverlay(_ shows: Bool) {
        guard var remembered = LastConnection.load(from: defaults) else { return }
        remembered.showsVideoOverlay = shows
        remembered.save(to: defaults)
    }

    /// What was stored last time, or `true` before anything has been.
    var remembersVideoOverlay: Bool {
        LastConnection.load(from: defaults)?.showsVideoOverlay ?? true
    }
}

#endif  // os(macOS)
