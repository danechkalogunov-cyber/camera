//
//  AppSessionModel+Memory.swift
//  Vigil
//
//  What survives quitting: the camera Vigil reconnects to, its name, and whether its picture
//  carries chrome. Plus the archive-playback pair that swaps the live path for a recorded one.
//  macOS-only. Split from AppSessionModel+Session.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
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
            record = LastConnection(
                host: camera.host,
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
        // The identity, so the next launch resumes *this* camera rather than a new one with the
        // same address. Written on every first frame like the rest of the record, which also
        // repairs a record saved before the field existed.
        record.cameraID = camera.id
        record.transport = camera.transport
        record.lastWorkingTransport = camera.lastWorkingTransport
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
        await playArchive(locator, on: live)
    }

    /// Opens one camera's archive without disturbing the other streams on the stage.
    ///
    /// This is the media-session half of F-PLB-05. The original one-camera entry point above still
    /// addresses ``live``; synchronized playback uses this overload for every admitted tile, so
    /// each camera keeps its own controller, decoder, credential and playback locator.
    func playArchive(_ locator: PlaybackLocator, on stream: CameraStream) async {
        // ⚠️ `activeRef` is cleared by a teardown, so a seek made while the picture is stopped —
        // after a pause, or after a terminal failure — would refuse on a camera whose password is
        // in the Keychain under the record's own handle. The record is the fallback and it is the
        // same handle in every case that matters.
        guard let camera = stream.camera else { return }
        let ref = stream.activeRef ?? camera.credentialRef
        stream.seekGeneration &+= 1
        let generation = stream.seekGeneration
        var target = camera
        let query = locator.rawQuery
        target.rtspPathOverride = query.isEmpty ? locator.path : locator.path + "?" + query
        stream.playback = locator
        stream.hasPlaybackCoverage = true
        // A seek is a picture starting to move again, whatever the button said a moment ago.
        stream.isPlaybackPaused = false
        stream.playbackStartedAt = dependencies.clock.now()
        stream.tileSink.setPresentationPaused(false)
        stream.seekStartedAt = dependencies.clock.now()
        dependencies.logger.info(.app, "seek: opening \(target.rtspPathOverride ?? "")")
        if stream === live { stopSession() } else { stop(stream) }
        guard generation == stream.seekGeneration else {
            dependencies.logger.debug(.app, "seek \(generation) superseded before it began")
            return
        }
        if stream === live { phase = .live }
        stream.beginConnecting()
        await start(stream, camera: target, ref: ref)
    }

    /// Sets one archive stream's rate, rebuilding only that camera's RTSP session.
    func setPlaybackRate(_ rate: TimelinePlaybackRate, on stream: CameraStream) async {
        guard rate != stream.playbackRate, let locator = stream.playback else { return }
        stream.playbackRate = rate
        await playArchive(locator, on: stream)
    }

    /// Pauses or resumes one archive stream while its session remains alive.
    func setPlaybackPaused(_ paused: Bool, on stream: CameraStream) async {
        guard stream.isPlaybackPaused != paused else { return }
        if paused, let locator = stream.playback, let started = stream.playbackStartedAt {
            let elapsed = max(0, dependencies.clock.now().seconds(since: started))
            let held = locator.start.addingTimeInterval(elapsed * stream.playbackRate.scale)
            stream.playback = locator.rebased(to: held)
        }
        stream.isPlaybackPaused = paused
        stream.tileSink.setPresentationPaused(paused)
        if let controller = stream.controller { await controller.setPaused(paused) }
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

    /// Streams another camera **beside** the one already playing, rather than instead of it.
    ///
    /// ⛔ THIS IS WHAT F-LIV-01 IS FOR. ``switchTo(_:)`` stops one session and starts another,
    /// which is the only thing a build with one `StreamController` could do; this starts a second
    /// controller, a second decode pipeline and a second frame handle, and the tile for that camera
    /// attaches to it. Neither call replaces the other: switching is still what selecting a camera
    /// in the sidebar means, and this is what clicking an idle cell on the stage means — "show me
    /// this one **as well**".
    ///
    /// ⚠️ The bound camera is never started this way. `live` is the stream the connect form, the
    /// remembered connection and the inspector all address, and it is driven by the connect path;
    /// asking for it here would build a second session for a camera that already has one.
    ///
    /// The credential is the stored record's, exactly as in ``switchTo(_:)``: a camera that has
    /// never been given a password fails with a named diagnosis on its own tile, which is the
    /// honest outcome and does not touch the form.
    ///
    /// - Returns: `false` when the budget is spent, so the caller can say so rather than leave a
    ///   click looking ignored.
    @discardableResult
    func connectAlongside(_ target: Camera) async -> Bool {
        guard target.id != camera?.id else { return true }
        let stream = cameras.stream(for: target)
        guard !stream.isActive else { return true }
        guard canAdmit(target) else { return false }
        dependencies.logger.info(.app, "adding a camera to the stage", ["host": target.host])
        stream.resolvedPath = target.capabilities?.resolvedRTSPPath
        stream.beginConnecting()
        await start(stream, camera: target, ref: target.credentialRef)
        return true
    }

    /// Starts or promotes a stream for the dedicated wall without replacing the bound camera.
    @discardableResult
    func connectForVideoWall(_ target: Camera) async -> Bool {
        guard target.isEnabled else { return false }
        let stream = target.id == camera?.id ? live : cameras.stream(for: target)
        stream.isVideoWall = true
        if stream.isActive {
            rebalanceDecodeBudget()
            return true
        }
        guard canAdmit(target, priority: .wall) else {
            stream.isVideoWall = false
            return false
        }
        stream.resolvedPath = target.capabilities?.resolvedRTSPPath
        stream.beginConnecting()
        await start(stream, camera: target, ref: target.credentialRef)
        rebalanceDecodeBudget()
        return true
    }

    /// Removes wall priority while leaving a stream alive for any other surface using it.
    func releaseVideoWall(_ ids: Set<CameraID>) {
        for id in ids {
            let stream = id == camera?.id ? live : cameras.stream(for: id)
            stream?.isVideoWall = false
        }
        rebalanceDecodeBudget()
    }

    /// Retries one camera now, cancelling whatever backoff it was waiting out.
    ///
    /// ⛔ The tile that asks is the tile that retries. `perform(.retry)` reconnects the *form's*
    /// request, which is the bound camera's — pressing Retry on camera three's offline card would
    /// have restarted camera one and left camera three exactly as it was, waiting out a timer with
    /// a button that appeared to do nothing.
    ///
    /// A stream that still owns a controller is restarted through it, which is what makes this
    /// immediate rather than another scheduled attempt. One that was torn down — a terminal failure
    /// — is built again from the stored record.
    func retryCamera(_ id: CameraID) {
        guard let stream = cameras.stream(for: id), stream !== live else { return perform(.retry) }
        if let controller = stream.controller {
            Task { await controller.restart() }
            return
        }
        guard let camera = stream.camera else { return }
        stream.beginConnecting()
        Task { await start(stream, camera: camera, ref: stream.activeRef ?? camera.credentialRef) }
    }

    /// Stops one camera's stream without touching the rest.
    ///
    /// The entry stays in ``cameras``, because the tile that remains is drawn from it — a stopped
    /// stream still knows its camera, when it was last seen and why it stopped.
    func disconnect(_ id: CameraID) {
        guard let stream = cameras.stream(for: id) else { return }
        guard stream !== live else { return disconnect() }
        stop(stream)
    }

    /// Puts exactly one page of cameras on the stage and takes everything else off it.
    ///
    /// ⛔ THIS IS WHAT THE PATROL COULD NOT DO BEFORE F-LIV-01. With one `StreamController` per
    /// application, "show page 2" could only mean `switchTo` the page's *first* camera, so a 2 × 2
    /// patrol advanced through four-camera pages one picture at a time and the other three cells sat
    /// on their placeholders. The cycle was honest about it — `showCyclePage` said so in its own doc
    /// — and it is what `F-LIV-06`'s open item names. A page is now a page.
    ///
    /// ⚠️ THE STOPS COME FIRST, AND THAT ORDER IS LOAD-BEARING. A page turn that started before it
    /// stopped would be asking the decode budget for the new page while the *previous* page's
    /// cameras were still holding it — every camera on the new page would be refused, and after one
    /// turn the patrol would show nothing new. Stopping first also matches what the device can take:
    /// a DS-I256 permits three concurrent sessions, and overlapping two pages would spend them on
    /// cameras the user has already been shown.
    ///
    /// The lead is the bound camera when the page contains it **and it is streaming**, because
    /// ``live`` is the stream the connect form, the inspector and the remembered connection all
    /// address, and re-pointing it at another member of the same page would cost that camera a
    /// reconnect for no visible gain. It is also the order the stage itself uses — the streaming
    /// camera leads (`stageOrder`).
    ///
    /// ⚠️ "And it is streaming" is not a detail. ``switchTo(_:)`` refuses a camera that is already
    /// bound — correct for a switch, and useless for a page that has just been asked to appear — so
    /// preferring a *stopped* bound camera as the lead would leave the page's first cell dark while
    /// the rest of it opened. Falling back to the page's own first camera keeps this no worse than
    /// the one-camera behaviour it replaces, which took `range.first` unconditionally.
    ///
    /// An empty page does nothing at all rather than tearing the stage down: a library that has just
    /// been emptied by a filter is not an instruction to stop streaming.
    func showOnStage(_ page: [Camera]) async {
        guard !page.isEmpty else { return }
        for stream in streamsToStop(forPage: page.map(\.id)) { stop(stream) }
        let lead = page.first { $0.id == camera?.id && live.isActive } ?? page[0]
        await switchTo(lead)
        for member in page where member.id != lead.id {
            // The budget's refusal ends the page rather than skipping one camera: the cells are
            // filled in order, and carrying on would leave a gap in the middle of the page while
            // starting a camera further down it.
            guard await connectAlongside(member) else { return }
        }
    }

    /// Which streams a page turn has to stop: everything being driven that the page does not name.
    ///
    /// ⚠️ ``live`` is never in this list, whichever camera it is pointed at, because the page turn
    /// re-points it: ``switchTo(_:)`` stops that session itself and opens the lead's. Stopping it
    /// here as well would tear down a session a moment before rebuilding it, and — worse — would do
    /// so for the one camera that is still on screen while the rest of the page opens.
    ///
    /// Separated from ``showOnStage(_:)`` because it is the decision, and the decision is the part
    /// that can be wrong: everything else is a loop.
    func streamsToStop(forPage page: [CameraID]) -> [CameraStream] {
        cameras.all.filter { stream in
            guard stream !== live, stream.isActive, let id = stream.camera?.id else { return false }
            return !page.contains(id)
        }
    }

    /// Makes the library and the session agree about the camera that is streaming: files it if it
    /// is new, and adopts its stored identity if it is not.
    ///
    /// Called once a picture exists, which is the only moment Vigil knows the record is good for
    /// anything. Adding at connect time would fill the list with addresses that never answered.
    func reconcileCurrentCamera(with library: AppLibraryModel) async {
        guard let camera else { return }
        guard let stored = library.cameras.first(where: { $0.host == camera.host }) else {
            await library.add(camera)
            return
        }
        await library.recordRuntimeKnowledge(from: camera, for: stored.id)
        // ⛔ THE SAME DEVICE MUST NOT HAVE TWO IDENTITIES. The library row was written by whichever
        // launch first reached a picture; every launch since built its own `Camera` from the
        // remembered host, and `Camera.id` defaults to a fresh `CameraID()`. Two ids for one
        // address is what put the same camera in the sidebar twice — live, and a second row
        // permanently marked not-running — and what detached its group, its bookmarks and its clips
        // on every launch.
        //
        // The library's id wins, because it is the one everything else is already keyed by. Adopting
        // it here rather than at connect time is deliberate: this runs on the first frame, when the
        // library is certainly loaded, whereas the resume starts before `library.load` may have
        // finished. `rememberThisCamera()` then persists the adopted id, so the next launch resumes
        // as this camera and never needs adopting again.
        guard stored.id != camera.id else { return }
        dependencies.logger.info(
            .app, "adopting the library's identity for this camera", ["host": camera.host])
        self.camera?.id = stored.id
        rememberThisCamera()
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

    /// Stops the picture where it is, or starts it again — on an archive **or on a live stream**.
    ///
    /// ⛔ IT USED TO REFUSE EVERYTHING BUT AN ARCHIVE. `guard let locator = playback` meant the
    /// button did nothing at all on a live camera, which is the state the app is in almost all of
    /// the time: the user pressed stop and the picture kept moving. Stopping a live stream is a
    /// real act — the tile holds its last frame (R-36) and the socket goes away — and it is the
    /// only meaning "pause" can have on something with no timeline.
    ///
    /// ⚠️ The credential is read from the camera record on the way back, not from `activeRef`:
    /// tearing the session down clears that field, so a pause that remembered nothing else could
    /// never resume. That was the second half of the same bug — the picture stopped and the button
    /// then did nothing.
    func togglePlaybackPause() async {
        guard camera != nil else { return }
        if isPlaybackPaused {
            guard let locator = playback else { return }
            // `StreamController.setPaused(false)` only resumes the already-running RTSP clock,
            // which means an archive picture jumps ahead by however long it was held. Reopen from
            // the exact held locator instead.
            await playArchive(locator)
            dependencies.logger.info(.app, "playback resumed")
            return
        }

        // Keep the last decoded picture on screen, stop accepting new media, and remember the
        // archive instant reached so resume can request that instant rather than the original seek.
        if let locator = playback, let started = live.playbackStartedAt {
            let elapsed = max(0, dependencies.clock.now().seconds(since: started))
            let held = locator.start.addingTimeInterval(elapsed * playbackRate.scale)
            playback = locator.rebased(to: held)
        }
        isPlaybackPaused = true
        live.tileSink.setPresentationPaused(true)
        if let controller { await controller.setPaused(true) }
        dependencies.logger.info(.app, "playback paused")
    }

    /// Returns the picture to the live stream.
    ///
    /// Restores the override the camera had before playback rather than clearing it: a user who set
    /// an explicit RTSP path in the connect form must get that path back, not the probe ladder.
    func returnToLive() async {
        await returnToLive(live)
    }

    /// Restores one synchronized lane to its own live path.
    func returnToLive(_ stream: CameraStream) async {
        guard stream.playback != nil, let camera = stream.camera else { return }
        let ref = stream.activeRef ?? camera.credentialRef
        var target = camera
        target.rtspPathOverride = stream.resolvedPath
        stream.playback = nil
        stream.playbackStartedAt = nil
        stream.hasPlaybackCoverage = true
        // Live has no speed, and leaving the rate set would make the next session ask a live
        // channel for `Scale: 4` — the next four seconds, which do not exist yet.
        stream.playbackRate = .normal
        stream.isPlaybackPaused = false
        // Bumped so a seek still opening does not finish into a session that has gone back to live,
        // and cleared so the live stream's first frame is not reported as a seek that took as long
        // as the user spent deciding to leave.
        stream.seekGeneration &+= 1
        stream.seekStartedAt = nil
        dependencies.logger.info(.app, "returning to the live stream")
        if stream === live { stopSession() } else { stop(stream) }
        if stream === live { phase = .live }
        stream.beginConnecting()
        await start(stream, camera: target, ref: ref)
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

private extension PlaybackLocator {
    /// Keeps a device-provided playback locator intact (including its opaque `name` query item)
    /// while rebasing only the point where RTSP playback resumes.
    func rebased(to start: Date) -> PlaybackLocator {
        let query = rawQuery.split(separator: "&", omittingEmptySubsequences: true).map { item in
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = pair.first, name.caseInsensitiveCompare("starttime") == .orderedSame
            else { return String(item) }
            return "starttime=\(ISAPITime.compactUTC(start))"
        }.joined(separator: "&")
        return PlaybackLocator(path: path, rawQuery: query, start: start, end: end,
                               fileName: fileName, sizeBytes: sizeBytes)
    }
}

#endif  // os(macOS)
