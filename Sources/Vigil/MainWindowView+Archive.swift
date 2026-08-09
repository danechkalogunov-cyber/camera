//
//  MainWindowView+Archive.swift
//  Vigil
//
//  Archive playback and the stage it happens over: seeking the camera's recordings, the day the
//  scrubber shows, and what the three library screens read.
//  macOS-only. Split from MainWindowView.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

#if os(macOS)

    import AVFoundation
    import AppKit
    import CoreMedia
    import Foundation
    import SwiftUI

    import VigilCore
    import VigilProtocols
    import VigilRender
    import VigilUI

    // MARK: - The archive, the timeline and the stage

    /// ⚠️ `internal` rather than `private`, for the reason given in `MainWindowView+Library.swift`:
    /// `private` reaches a type's extensions only within one file.
    extension MainWindowView {

        /// Plays the camera's archive from an instant, or says why it cannot.
        ///
        /// Refuses a moment with no footage rather than seeking near it: spec-isapi.md §15.6 is explicit
        /// that an arbitrary time with nothing recorded yields a 404 or a stream that ends at once, and
        /// "there is nothing here" is a better answer than a picture that dies in a second.
        func playArchive(from instant: Date) {
            if session.synchronizedPlayback.isEnabled {
                Task {
                    await session.synchronizedPlayback.seek(
                        to: instant, rate: session.playbackRate, appSession: session)
                }
                return
            }
            guard let locator = archive.locator(at: instant) else {
                window.toast = MainWindowToast(
                    kind: .info,
                    message: Self.localized("Nothing was recorded at that moment"))
                return
            }
            // ⛔ THE SCRUBBER NOW SHOWS THE SELECTED CAMERA, SO THE SEEK HAS TO REACH IT. Playback
            // runs on the bound stream — one archive session, one set of transport controls — so a
            // seek on another camera's timeline first brings that camera to the front. Without this
            // the user scrubs camera nine's index and camera one jumps, which is the exact confusion
            // moving the panels onto the selection was meant to remove.
            let target = selectedCamera
            Task {
                if let target, target.id != session.camera?.id { await session.switchTo(target) }
                await session.playArchive(locator)
            }
        }

        /// Puts the picture back on the live stream.
        func returnToLive() {
            Task {
                if session.synchronizedPlayback.isEnabled {
                    await session.synchronizedPlayback.returnToLive(appSession: session)
                } else {
                    await session.returnToLive()
                }
            }
        }

        /// Cameras occupying visible cells, in cell order, capped by F-PLB-05's four-session limit.
        var synchronizedPlaybackCameras: [Camera] {
            stageAssignment.cells.prefix(SyncedPlaybackPolicy.maximumCameras)
                .compactMap { id in
                    id.flatMap { cameraID in library.cameras.first { $0.id == cameraID } }
                }
        }

        func toggleSynchronizedPlayback() {
            if session.synchronizedPlayback.isEnabled {
                Task { await session.synchronizedPlayback.returnToLive(appSession: session) }
                return
            }
            let cameras = synchronizedPlaybackCameras
            guard cameras.count > 1, let day = archive.archive?.day else { return }
            Task {
                await session.synchronizedPlayback.enable(
                    cameras: cameras, day: day, appSession: session)
                guard let instant = archive.archive?.playhead else { return }
                await session.synchronizedPlayback.seek(
                    to: instant, rate: session.playbackRate, appSession: session)
            }
        }

        /// Loads a different day into the timeline.
        func loadArchiveDay(_ day: TimelineDay) {
            if session.synchronizedPlayback.isEnabled {
                // Its four indexes belong to the outgoing day. Keeping them while the ruler moves
                // to another date would turn every valid segment into a false gap.
                Task { await session.synchronizedPlayback.returnToLive(appSession: session) }
            }
            let clock = libraryClock
            archive.load(
                day: day,
                clock: clock,
                localClips: timelineLocalClips,
                markers: timelineMarkers)
            // Keeps the calendar's selected-day ring on the day actually being shown. Cheap: this
            // rebuilds the grid from the month already in hand and never touches the device.
            archive.remarkMonth(selected: day, clock: clock)
        }

        /// ⇧⌘G — back to the live edge (UX.md §14.2).
        ///
        /// Both halves, because either alone leaves a half-truth on screen: returning the picture to
        /// live while the scrubber still shows last Tuesday says the wrong day about a live image, and
        /// moving the timeline to today while the stream still plays an archive says the wrong thing
        /// about the picture.
        func goToLiveEdge() {
            loadArchiveDay(libraryClock.day(containing: Date()))
            returnToLive()
        }

        /// What the three library screens read.
        ///
        /// Clips, events and bookmarks all have sources now. `archive` does not, and stays `nil`: it is
        /// the camera-side recording index the timeline scrubs, and nothing reads it off the device yet.
        /// `VRecordingsView` mounts `VTimelineView` only when it is non-`nil`, so the whole scrubber —
        /// ruler, playhead, marker lane — is written, tested and never seen. That is the truthful state
        /// rather than a placeholder, and the screen's empty half says what would fill it.
        var libraryState: VLibraryState {
            VLibraryState(
                clock: libraryClock,
                clips: window.clips,
                events: eventFeed.events,
                bookmarks: libraryBookmarks,
                // ⛔ Deliberately not `archive.archive`. UX.md §7 gives the timeline its own
                // surface — a video canvas with the scrubber beneath it — and putting it in
                // this *list* screen sat a scrubber on a light canvas between a row of legend
                // chips and a table of files. Recordings lists what is on this Mac; reviewing
                // footage happens over the picture, where `StageTimelineOverlay` mounts it.
                archive: nil,
                recordingsFolder: recordingsFolderLabel)
        }

        /// The calendar, zone and instant every library surface shares.
        ///
        /// One value, built once per body evaluation: a row and its day header computing `Date()`
        /// separately can land either side of midnight and disagree about which day a clip is on.
        var libraryClock: TimelineClock {
            TimelineClock(calendar: .autoupdatingCurrent, now: Date())
        }

        /// What decides the archive is worth reading: the screen being open, and for which camera.
        ///
        /// ⚠️ The **selected** camera. The scrubber is a panel like the rest of them, and a timeline
        /// drawn from camera one's index under a heading naming camera nine would send a seek to a
        /// moment that exists on neither.
        var archiveTrigger: String {
            let isOpen = window.showsTimeline
            return "\(isOpen)/\(selectedCamera?.id.rawValue.uuidString ?? "-")"
                + "/\(deviceInfo.session == nil ? 0 : 1)"
        }

        /// Reads the camera's index for the day the timeline is showing, and says why when there is
        /// nothing to read.
        ///
        /// The scrubber is absent for three different reasons and they are not interchangeable: the
        /// camera records nothing, the camera refused to say, or Vigil has not asked yet. Only the
        /// first two are worth a sentence, and only once — a toast every time the Recordings screen
        /// opens would be nagging about a fact that has not changed.
        func loadArchive() async {
            archive.follow(
                camera: selectedCamera?.id,
                session: deviceInfo.session,
                channel: selectedCamera?.channel,
                name: selectedIdentity.name)
            guard window.showsTimeline else { return }
            let clock = libraryClock
            let day = archive.archive?.day ?? clock.day(containing: clock.now)
            archive.load(
                day: day,
                clock: clock,
                localClips: timelineLocalClips,
                markers: timelineMarkers)
            await reportArchiveAvailability()
        }

        /// Waits for the index read to settle and explains an absent scrubber, at most once per camera.
        func reportArchiveAvailability() async {
            // The read is a paged search at the device; a second is generous for a LAN and short enough
            // that the explanation still feels like a response to opening the screen.
            for _ in 0..<20 {
                if archive.tracks != .unknown { break }
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            // ⛔ Checked before `hasExplainedArchive` and not gated by it. That flag suppresses the
            // once-per-camera explanation of an *absent* scrubber; this is a fact about the day just
            // loaded and changes as the user steps days, so silencing it after the first time would
            // hide an incomplete Tuesday because Monday was already explained.
            reportIncompleteDay()

            guard !window.hasExplainedArchive else { return }
            switch archive.tracks {
            case .unknown, .present:
                return
            case .none:
                window.hasExplainedArchive = true
                // ⛔ Says what was observed, not what it implies. The earlier wording claimed the camera
                // had no memory card — which was an invention: the Info tab was showing storage in use
                // at the same moment. All that is actually known is that the tracks endpoint offered
                // nothing, and firmware that simply does not implement it looks identical from here.
                window.toast = MainWindowToast(
                    kind: .info,
                    message: Self.localized(
                        "The camera did not list any recordings it can play "
                            + "back, so there is no timeline to scrub."))
            case .refused(let reason):
                window.hasExplainedArchive = true
                window.toast = MainWindowToast(
                    kind: .warning,
                    message: String(
                        format: Self.localized(
                            "The camera would not list its recordings: "
                                + "%@"),
                        reason))
            }
        }

        /// Says so when the day on screen is only part of the day.
        ///
        /// The symptom this answers is a user reporting "there is no recording after 06:30" about a
        /// camera that recorded all day. The device's search is paged and capped; past the cap it stops
        /// answering, and what comes back is the morning. A timeline that just ends looks exactly like a
        /// camera that stopped, so it has to say which it is.
        func reportIncompleteDay() {
            guard let edge = archive.incompleteAfter else { return }
            window.toast = MainWindowToast(
                kind: .warning,
                message: String(
                    format: Self.localized(
                        "This day holds more recordings than Vigil "
                            + "could read. The timeline is complete up to "
                            + "%@ and unknown after it."),
                    libraryClock.hourMinuteSecond(edge)))
        }

        /// Vigil's own clips as timeline blocks, so the scrubber shows them against the device's.
        ///
        /// A clip still being written has no duration yet and is skipped: a block of zero width draws
        /// as a hairline at the wrong instant rather than as "recording now".
        var timelineLocalClips: [VTimelineLocalClip] {
            window.clips.compactMap { clip in
                guard let seconds = clip.durationSeconds, seconds > 0 else { return nil }
                return VTimelineLocalClip(
                    id: clip.id,
                    start: clip.startedAt,
                    end: clip.startedAt.addingTimeInterval(seconds),
                    title: clip.fileName)
            }
        }

        /// The event feed as timeline markers.
        var timelineMarkers: [TimelineMarker] {
            eventFeed.events.map { event in
                TimelineMarker(
                    id: event.id,
                    instant: event.occurredAt,
                    kind: event.kind,
                    label: event.label)
            }
        }

        /// The stored bookmarks in the shape the screen reads.
        ///
        /// The camera name is resolved here rather than stored on the record: a bookmark made before the
        /// camera was renamed should show the name it has now, not the one it had then.
        var libraryBookmarks: [VLibraryBookmark] {
            let source = VLibraryCamera(id: cameraID, name: identity.name)
            return bookmarks.bookmarks.map { record in
                VLibraryBookmark(
                    id: record.id,
                    camera: source,
                    instant: record.instant,
                    title: record.title,
                    note: record.note)
            }
        }

        /// Whether the Events screen is the stage's current route.
        var isEventsScreenOpen: Bool {
            VLibrarySection(window.sidebarSelection.focus) == .events
        }

        /// Clears the unread badge once the feed has actually been looked at.
        ///
        /// Delayed rather than immediate: opening Events and leaving in the same second has not read
        /// anything, and a badge that clears on a mis-click stops being worth glancing at.
        func markEventsRead() async {
            guard isEventsScreenOpen, eventFeed.unreadCount > 0 else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, isEventsScreenOpen else { return }
            await eventFeed.markAllRead(camera: selectedCamera)
        }

        /// The recordings folder as a user would recognise it, for the empty state's "where would a clip
        /// appear" answer. Abbreviated with a tilde rather than shown as a container path.
        var recordingsFolderLabel: String? {
            guard let folder = recording.clipsDirectory() else { return nil }
            return (folder.path as NSString).abbreviatingWithTildeInPath
        }

        /// The tile stage.
        ///
        /// The video closure is where `VigilRender` enters, exactly as it did in the pre-window build:
        /// every callback and the logger are named explicitly, because each one has a default that
        /// compiles and reports nothing, which is the "no video, no error" shape this project refuses.
        var stage: some View {
            stageGrid
                // The bump of UX.md §5.7, applied to the whole grid rather than to the tile that could
                // not move — see `MainWindowState.stageBumpOffset` for why it is a translation and not a
                // frame change. The scrubber below is deliberately outside it: a control that slid 3 pt
                // sideways because focus hit the edge of the grid would read as a glitch.
                .offset(window.stageBumpOffset)
                .overlay(alignment: .bottom) { timelineOverlay }
        }

        /// The scrubber over the bottom edge, once it has been asked for.
        @ViewBuilder
        var timelineOverlay: some View {
            if window.showsTimeline {
                StageTimelineOverlay(
                    archive: archive.archive,
                    availability: archive.tracks,
                    clock: libraryClock,
                    onSelectDay: { day in loadArchiveDay(day) },
                    month: archive.month,
                    isLoadingMonth: archive.isLoadingMonth,
                    onSelectMonth: { year, month in
                        archive.showMonth(
                            year: year,
                            month: month,
                            selected: archive.archive?.day,
                            clock: libraryClock)
                    },
                    onGoToNow: { goToLiveEdge() },
                    onScrub: { phase, instant in
                        archive.movePlayhead(
                            to: instant,
                            isScrubbing: phase != .ended)
                        // Only the release seeks. `VLibraryActions.onScrub` says so,
                        // and the reason is the device: every seek is a fresh RTSP
                        // session, and issuing one per drag tick would open and tear
                        // down a hundred of them at a camera that allows a handful.
                        guard phase == .ended else { return }
                        playArchive(from: instant)
                    },
                    onZoom: { stop in archive.zoom(stop) },
                    onActivateMarker: { cluster in
                        // A cluster is one or more markers at the same x; the earliest
                        // is what the badge is anchored on.
                        guard let first = cluster.markers.first else { return }
                        archive.movePlayhead(to: first.instant, isScrubbing: false)
                    },
                    onStep: { seconds in archive.stepPlayhead(by: seconds) },
                    onStepToEdge: { forward in archive.stepToEdge(forward: forward) },
                    onStepToMarker: { forward in
                        archive.stepToMarker(forward: forward)
                    },
                    onGoToDayEdge: { start in archive.moveToDayEdge(start: start) },
                    onDismiss: {
                        window.showsTimeline = false
                        // Closing the scrubber returns to live. A window left showing
                        // yesterday with no scrubber to say so is the worst state this
                        // feature can produce: the picture looks live and is not.
                        returnToLive()
                    },
                    revealRequests: window.timelineRevealRequests,
                    rate: session.playbackRate,
                    // Only while an archive is open. A live channel has no speed —
                    // `Scale: 4` on it asks for the next four seconds.
                    isRateAdjustable: session.playback != nil
                        || session.synchronizedPlayback.isEnabled,
                    isPaused: session.synchronizedPlayback.isEnabled
                        ? (session.synchronizedPlayback.playhead?.isPaused ?? false)
                        : session.isPlaybackPaused,
                    onTogglePause: {
                        Task {
                            if session.synchronizedPlayback.isEnabled {
                                let paused = !(session.synchronizedPlayback.playhead?.isPaused ?? false)
                                await session.synchronizedPlayback.setPaused(
                                    paused, appSession: session)
                            } else {
                                await session.togglePlaybackPause()
                            }
                        }
                    },
                    // ⛔ ONE ACTION, NOT TWO. This used to seek to the stepped instant and then
                    // call `stepPlaybackFrame`, which stopped the session it had just started —
                    // the two fought and the button did nothing visible. Stepping is a seek of one
                    // frame's worth of time, and the seek is the whole of it.
                    onFrameStep: { forward in
                        let fps = session.format?.declaredFPS ?? 25
                        archive.stepPlayhead(by: (forward ? 1 : -1) / max(fps, 1))
                        guard let instant = archive.archive?.playhead else { return }
                        playArchive(from: instant)
                    },
                    syncLabel: synchronizedPlaybackCameras.count > 1
                        ? (session.synchronizedPlayback.label
                            ?? vigilUIString("Synchronize visible cameras"))
                        : nil,
                    isSyncEnabled: session.synchronizedPlayback.isEnabled,
                    onToggleSync: { toggleSynchronizedPlayback() },
                    onRate: { stop in
                        Task {
                            if session.synchronizedPlayback.isEnabled {
                                session.playbackRate = stop
                                await session.synchronizedPlayback.setRate(stop, appSession: session)
                            } else {
                                await session.setPlaybackRate(stop)
                            }
                        }
                    })
            }
        }

        var stageGrid: some View {
            VGridStageView(
                assignment: stageAssignment,
                cameras: stageCameras,
                selection: cameraID,
                focusedIndex: window.stageFocusIndex,
                // Keyboard focus moving between cells binds the sidebar and the inspector
                // to whatever it lands on, which is what makes ⌥-arrow useful rather than
                // decorative. One cell today; the mapping is the same at sixteen.
                onFocusCell: { index in
                    window.stageFocusIndex = index
                    // `cells` is one optional per cell; an empty one selects nothing rather
                    // than clearing what is selected, because arrowing across a gap should
                    // not deselect the camera you came from.
                    let cells = stageAssignment.cells
                    guard cells.indices.contains(index), let id = cells[index] else { return }
                    window.sidebarSelection.select(.camera(id))
                },
                onBump: { direction in bumpStage(direction) },
                // Selecting a tile is selecting that camera everywhere else.
                onSelectCamera: { id in window.sidebarSelection.select(.camera(id)) },
                onToggleFullscreen: { id in focusCamera(id) },
                // The empty cell's "+" is the same act as the sidebar's.
                onAddCamera: { _ in addCamera() },
                onCloseCell: { index in closeStageCell(index) },
                onRetry: { id in session.retryCamera(id) },
                onRemedy: { id, remedy in applyRemedy(remedy, to: id) },
                onShowOverflow: { showOverflowCameras() },
                // Clicking an idle cell is the same act as opening its sidebar row: connect
                // this camera. `switchTo` refuses a no-op switch, so clicking the cell that
                // is already live costs nothing.
                onConnectCamera: { id in connectStageCell(id) },
                supportsPosition3D: { id in
                    id == cameraID && ptz.capability.supportsPosition3D
                },
                onPosition3D: { id, rect, size in
                    guard id == cameraID else { return }
                    ptz.position3D(rect: rect, viewSize: size)
                },
                // One renderer per mounted tile, each attached to **its own** camera's frame
                // handle. The stage calls this once per tile and keys the view by camera, so
                // a layout change re-uses the renderer rather than rebuilding it.
                video: { id in stageVideo(for: id) })
        }

        /// Clicking an idle cell: select that camera, and start it **beside** whatever is already
        /// playing.
        ///
        /// ⛔ This used to be `switchTo`, which stopped the picture the user was watching in order
        /// to show the one they clicked — the only thing a build with one `StreamController` could
        /// do, and the thing F-LIV-01 exists to end. A second cell now becomes a second picture.
        ///
        /// The budget refusal is said out loud. A click that quietly does nothing reads as a broken
        /// app, and a limit the user can see is one they can work with.
        func connectStageCell(_ id: CameraID) {
            guard let target = library.cameras.first(where: { $0.id == id }) else { return }
            window.sidebarSelection.select(.camera(id))
            Task {
                guard await session.connectAlongside(target) == false else { return }
                // ⚠️ No number in the sentence, and that is what `F-DEC-06` changed. The limit used
                // to be four cameras and could be written out — Russian declines it, so a formatted
                // `%lld` would have needed a `.stringsdict` for a constant. It is now a decode
                // budget: what fits depends on the machine and on what these particular cameras
                // cost, so there is no number to name and naming one would be a lie on most Macs.
                window.toast = MainWindowToast(
                    kind: .warning,
                    message: MainWindowView.localized(
                        "This Mac is already decoding all it can. Close a camera to open another."))
            }
        }

        /// A remedy chosen from one tile's failure card, applied to that tile's camera.
        ///
        /// ⚠️ Only the two that mean "try again" are per camera, and the split is honest rather than
        /// lazy. Retrying is a fact about one stream. The rest — *Check the address*, *Update the
        /// password*, *Open the camera's web page* — put the user in front of the **connect form**,
        /// which the application has exactly one of, and it is the bound camera's. Routing those
        /// through a background tile would open the form for camera one while the user was looking
        /// at camera three's card. `F-LIV-01`'s remaining step is what makes the form follow the
        /// selection; until then this is where the line honestly falls.
        func applyRemedy(_ remedy: ConnectRemedy, to id: CameraID) {
            // The bound camera keeps every remedy exactly as it had it, including the log lines
            // `perform` writes for the ones that are really a reconnect.
            guard id != cameraID else { return session.perform(remedy) }
            switch remedy {
            case .retry, .switchToTCP:
                session.retryCamera(id)
            default:
                session.perform(remedy)
            }
        }

        /// The renderer for one cell, attached to that camera's own frame source.
        ///
        /// ⛔ The `?? session.live` fallback is not a shrug. The stage only calls this for a tile
        /// it decided to mount, which means `stageCamera(_:)` found an active stream a moment
        /// ago; the fallback covers the frame in which a camera is filed and the map has not been
        /// read yet, and attaching to the bound camera's handle for that frame is strictly better
        /// than mounting a renderer with no source, which would show a black rectangle and never
        /// recover.
        func stageVideo(for id: CameraID) -> VideoTile {
            let stream = session.cameras.stream(for: id) ?? session.live
            return VideoTile(
                cameraID: id,
                frames: stream.frames,
                // `updateNSView` retargets the layer's gravity in place, so toggling this
                // does not rebuild the view or interrupt the picture — it is the one tile
                // option that is free to change.
                options: TileRenderOptions(gravity: window.fillsTile ? .fill : .fit),
                logger: session.dependencies.logger,
                // Each report names the stream that made it, so a recovery restarts the camera
                // that stalled rather than whichever one the window happens to be bound to.
                onKeyframeNeeded: { session.recoverStalledPicture(on: stream) },
                onDecodeFailure: { session.handleDecodeFailure($0, on: stream) },
                onFramesDropped: { session.handleFramesDropped($0, reason: $1, on: stream) })
        }
    }

#endif  // os(macOS)
