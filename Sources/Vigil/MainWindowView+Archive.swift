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
            guard let locator = archive.locator(at: instant) else {
                window.toast = MainWindowToast(
                    kind: .info,
                    message: Self.localized("Nothing was recorded at that moment"))
                return
            }
            Task { await session.playArchive(locator) }
        }

        /// Puts the picture back on the live stream.
        func returnToLive() {
            Task { await session.returnToLive() }
        }

        /// Loads a different day into the timeline.
        func loadArchiveDay(_ day: TimelineDay) {
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
        var archiveTrigger: String {
            let isOpen = window.showsTimeline
            return "\(isOpen)/\(session.camera?.id.rawValue.uuidString ?? "-")"
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
                session: deviceInfo.session,
                channel: session.camera?.channel,
                name: identity.name)
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
            await eventFeed.markAllRead(camera: session.camera)
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
                    onHoverInstant: { instant in archive.preview(at: instant) },
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
                    rate: session.playbackRate,
                    // Only while an archive is open. A live channel has no speed —
                    // `Scale: 4` on it asks for the next four seconds.
                    isRateAdjustable: session.playback != nil,
                    isPaused: session.isPlaybackPaused,
                    onTogglePause: {
                        Task { await session.togglePlaybackPause() }
                    },
                    onFrameStep: { forward in
                        let fps = session.format?.declaredFPS ?? 25
                        let seconds = (forward ? 1 : -1) / max(fps, 1)
                        archive.stepPlayhead(by: seconds)
                        guard let instant = archive.archive?.playhead else { return }
                        playArchive(from: instant)
                        Task {
                            await session.stepPlaybackFrame(
                                forward: forward, framesPerSecond: fps)
                        }
                    },
                    onRate: { stop in
                        Task { await session.setPlaybackRate(stop) }
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
                onCloseCell: { _ in closeStageCell() },
                onRetry: { _ in session.perform(.retry) },
                onRemedy: { _, remedy in session.perform(remedy) },
                onShowOverflow: { showOverflowCameras() },
                onConnectCamera: { id in
                    guard let target = library.cameras.first(where: { $0.id == id }) else {
                        return
                    }
                    window.sidebarSelection.select(.camera(id))
                    Task { await session.switchTo(target) }
                },
                supportsPosition3D: { id in
                    id == cameraID && ptz.capability.supportsPosition3D
                },
                onPosition3D: { id, rect, size in
                    guard id == cameraID else { return }
                    ptz.position3D(rect: rect, viewSize: size)
                },
                // Clicking an idle cell is the same act as opening its sidebar row: stop
                // what is playing and stream this one. `switchTo` refuses a no-op switch, so
                // clicking the cell that is already live costs nothing.
                video: { _ in
                    VideoTile(
                        cameraID: cameraID,
                        frames: session.frames,
                        // `updateNSView` retargets the layer's gravity in place, so
                        // toggling this does not rebuild the view or interrupt the
                        // picture — it is the one tile option that is free to change.
                        options: TileRenderOptions(
                            gravity: window.fillsTile ? .fill : .fit),
                        logger: session.dependencies.logger,
                        onKeyframeNeeded: { session.recoverStalledPicture() },
                        onDecodeFailure: { session.handleDecodeFailure($0) },
                        onFramesDropped: { session.handleFramesDropped($0, reason: $1) })
                })
        }
    }

#endif  // os(macOS)
