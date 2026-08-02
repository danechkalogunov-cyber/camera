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
import VigilUI

// MARK: - Remembering, and playing back

extension AppSessionModel {

    /// Stores the connection that just produced a picture.
    ///
    /// ⛔ MERGES INTO THE EXISTING RECORD, IT DOES NOT REPLACE IT. This used to build a fresh
    /// `LastConnection` every time, and because it is called on **every** first frame — so after
    /// every reconnect and after every archive seek — it silently reset every field it did not
    /// mention. `showsVideoOverlay` was one such field: the user turned the chrome off, the next
    /// seek wrote a new record, the flag went back to its `true` default, and the setting looked
    /// like it had never been saved. Anything added to this record later would have been lost the
    /// same way, which is why the merge is the rule and not a patch for one flag.
    ///
    /// A different host is a different camera, so its settings do not come along: the record is
    /// rebuilt from scratch in that case, deliberately.
    func rememberThisCamera() {
        guard let activeRef, let camera else { return }
        var record: LastConnection
        if let existing = LastConnection.load(from: defaults), existing.host == camera.host {
            record = existing
        } else {
            record = LastConnection(host: camera.host,
                                    account: form.request.username,
                                    credentialRef: activeRef,
                                    rtspPath: resolvedPath)
        }
        record.host = camera.host
        // `form.request.username`, not `form.username`: the request is the trimmed form, and it is
        // what `knownHandle(for:)` compares against on the next connect. Storing the raw field
        // would make a name typed with a trailing space fail to match itself, mint a second
        // `CredentialRef`, orphan the Keychain item and lose the learned RTSP path.
        record.account = form.request.username
        record.credentialRef = activeRef
        record.rtspPath = resolvedPath
        // Safe to write unconditionally *because* `connect(_:ref:rtspPath:)` now seeds the camera
        // with the remembered name. Before that it did not, `Camera.validated()` invented "Camera
        // 192.168.1.64" from the host, and this line then replaced the user's rename with the
        // invention on the first reconnect. Fixing it here instead would have meant re-deriving
        // "is this name synthesised?", which duplicates a rule that lives in `validated()`.
        record.name = camera.name
        record.save(to: defaults)
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
        var target = camera
        target.rtspPathOverride = locator.rawQuery.isEmpty
            ? locator.path
            : locator.path + "?" + locator.rawQuery
        playback = locator
        seekStartedAt = dependencies.clock.now()
        dependencies.logger.info(.app, "seek: opening \(target.rtspPathOverride ?? "")")
        stopSession()
        guard generation == seekGeneration else {
            dependencies.logger.debug(.app, "seek \(generation) superseded before it began")
            return
        }
        beginConnecting()
        await stream(camera: target, ref: activeRef)
    }

    /// Streams a different camera from the library.
    ///
    /// **One stream at a time, and that is the honest shape of this build.** Switching stops the
    /// current session before starting the next — it does not run two. A viewer who selects another
    /// camera wants to see it, and pretending otherwise would mean two decode pipelines, two
    /// recorders and two archive scrubbers with no UI that can show either pair.
    ///
    /// The credential comes from the stored record and is never re-asked for: `Camera.credentialRef`
    /// is the Keychain handle the library carried through from wherever the camera was added. A
    /// switch that prompted for a password would make the list useless.
    ///
    /// Returns to live and to normal speed on the way, because neither the archive position nor the
    /// scale means anything on a different device.
    func switchTo(_ target: Camera) async {
        guard target.id != camera?.id else { return }
        playback = nil
        playbackRate = .normal
        seekGeneration &+= 1
        seekStartedAt = nil
        resolvedPath = target.capabilities?.resolvedRTSPPath
        dependencies.logger.info(.app, "switching camera", ["host": target.host])
        stopSession()
        beginConnecting()
        form.host = target.host
        await stream(camera: target, ref: target.credentialRef)
    }

    /// Files the camera that is streaming into the library, if it is not there already.
    ///
    /// Called once a picture exists, which is the only moment Vigil knows the record is good for
    /// anything. Adding at connect time would fill the list with addresses that never answered.
    func fileCurrentCameraIfNew(into library: AppLibraryModel) async {
        guard let camera else { return }
        guard !library.cameras.contains(where: { $0.host == camera.host }) else { return }
        await library.add(camera)
    }

    /// Changes archive playback speed, which means rebuilding the session at the current position.
    ///
    /// ⚠️ A RECONNECT, NOT A COMMAND, AND THAT IS FORCED BY THE FIRMWARE. RTSP changes speed with a
    /// second `PLAY` carrying `Scale:`, this machine can send one, and a DS-I256 on V5.5.6 refuses
    /// it — established by trying in-session seeking on hardware and reverting it
    /// (docs/PLAYBACK-LATENCY.md). The handshake's own `PLAY` is the one this firmware honours, so
    /// the scale is seeded into a fresh session and a speed change costs what a seek costs.
    ///
    /// It reuses ``playArchive(_:)`` rather than duplicating the connect: the locator has not
    /// changed, only the rate the next session will ask for, and `playArchive` already handles
    /// supersession, the decode reset and the timing log.
    func setPlaybackRate(_ rate: TimelinePlaybackRate) async {
        guard rate != playbackRate else { return }
        guard let locator = playback else {
            // Live has no speed. Recorded rather than silently ignored: a control that appears to
            // do nothing is worth a log line when someone reports exactly that.
            dependencies.logger.info(.app, "playback speed ignored: not playing an archive")
            return
        }
        playbackRate = rate
        dependencies.logger.info(.app, "playback speed \(rate.label); reopening the session")
        await playArchive(locator)
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
        // Live has no speed, and leaving the rate set would make the next session ask a live
        // channel for `Scale: 4` — the next four seconds, which do not exist yet.
        playbackRate = .normal
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
