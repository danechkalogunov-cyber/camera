//
//  MainWindowView.swift
//  Vigil
//
//  The assembled main window: toolbar, camera list, tile stage, inspector, status bar. The one place
//  the single-camera session model is adapted into the shapes the `VigilUI` screens expect.
//  macOS-only. See design/mockups/01-main-window.html and docs/UX.md.
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

// MARK: - MainWindowView

/// The window around the picture.
///
/// **What this file is and is not.** Every screen here was written against a multi-camera library;
/// the session model beneath it drives exactly one camera, because that is what `.vigil/SLICE.md`
/// scoped. So this view is an *adapter*: it presents the one live camera as a one-element library, and
/// the panels neither know nor care. Nothing here fakes a second camera — an empty cell is drawn as an
/// empty cell.
///
/// That shape is deliberate. When the multi-camera model lands, the change is to the four computed
/// properties below that build `VSidebarTree`, `VStageAssignment`, `VInspectorState` and
/// `VChromeStatus` — not to any of the screens, which already take collections.
struct MainWindowView: View {

    // MARK: - Stored Properties

    /// The streaming session. Owns the controller and everything that can fail.
    @Bindable var session: AppSessionModel

    /// Window furniture: what is shown, what is selected, what is being searched.
    @Bindable var window: MainWindowState

    /// Opens the network scan.
    ///
    /// A closure rather than state owned here, because the sheet and the `DiscoveryScanModel` behind
    /// it belong to `RootView`: the same run has to be presentable from the connect form *and* from
    /// this window, and two owners would mean two coordinators flooding one subnet.
    let onFindCameras: () -> Void

    /// Fetches the Info tab's device identity over ISAPI.
    ///
    /// Owned here rather than by `AppSessionModel`, because nothing it does can affect the stream:
    /// a camera that refuses `/ISAPI/System/deviceInfo` still shows a picture, and a device-info
    /// timeout must not be able to disturb a session. Built in `init` because it needs the app's
    /// logger and clock, which arrive with the session.
    @State var deviceInfo: DeviceInfoService

    /// Starts and stops clip recording.
    @State var recording: RecordingCoordinator

    /// Which files in the recordings folder Vigil actually wrote.
    @State var manifest: ClipManifest

    /// The camera's alert stream, which fills the Events screen and the sidebar's badge.
    @State var eventFeed: EventCoordinator

    /// The user's groups, and which camera is in which.
    @State var groups: CameraGroupStore

    /// The moments the user has marked.
    @State var bookmarks: BookmarkStore

    /// Pan, tilt, zoom, focus, iris, presets and patrols.
    @State var ptz: PTZCoordinator

    /// What this process costs the Mac, sampled once a second.
    ///
    /// A reference type because the sampler has to remember the previous CPU reading to difference
    /// against, and a `@State` struct mutated from an async loop would be differencing against a
    /// copy.
    @State var resources = ProcessResourceMonitor()

    /// Every camera the user has added.
    ///
    /// Separate from `session`, which owns exactly one live stream. The library is the *set*; the
    /// session is whichever member of it is on screen. Keeping them apart is what lets a second
    /// camera exist before a second stream does.
    ///
    /// ⚠️ Handed in rather than created here, and it used to be created here. The connect form and
    /// the network scan both need it — the scan so an address already in the list is offered as
    /// "Added" rather than as a find — and both are on screen precisely when this window is not.
    /// `RootView` owns it and loads it at launch.
    let library: AppLibraryModel

    /// Stills written to the user's Pictures folder.
    @State var snapshots: SnapshotCoordinator

    /// The camera's own recording index, which is what the timeline scrubs.
    @State var archive: ArchiveCoordinator

    /// Advances once a second while recording, purely to redraw the elapsed counter.
    ///
    /// `RecordingCoordinator.elapsed()` is a function over `startedAt`, not an observable property,
    /// so nothing invalidates the body as the clock moves — the counter would render once and then
    /// sit frozen. Ticking only while recording keeps the window idle the rest of the time.
    @State var recordingTick = Date()

    /// Whether decorative motion is allowed, which is `!reduceMotion` resolved by `VigilUI`.
    ///
    /// Read here rather than inside the stage because the one thing the window animates on its own
    /// — the ⌥-arrow bump of §5.7 — is decided in `MainWindowView+Sidebar.swift`, outside any view
    /// body that could read it for itself.
    @Environment(\.vMotionEnabled) var motionEnabled

    /// The last telemetry snapshot, refreshed once a second while the window is up.
    ///
    /// Pulled rather than pushed: the collector is lock-guarded and lives off the main actor, and a
    /// per-frame push would put the media path on the UI thread — the exact thing DESIGN.md §7.9
    /// forbids. One read per second is what the Stream tab's `LAST 60 S` sparkline needs and no more.
    @State var telemetry = StreamTelemetrySnapshot.unmeasured

    // MARK: - Initialisation

    /// Builds the window over a session.
    ///
    /// - Parameters:
    ///   - session: the streaming session.
    ///   - window: per-window view state.
    ///   - library: every camera the user has added; owned and loaded by `RootView`.
    ///   - onFindCameras: opens the scan sheet, which `RootView` owns.
    init(session: AppSessionModel,
         window: MainWindowState,
         library: AppLibraryModel,
         onFindCameras: @escaping () -> Void) {
        self.session = session
        self.window = window
        self.library = library
        self.onFindCameras = onFindCameras
        _deviceInfo = State(initialValue: DeviceInfoService(logger: session.dependencies.logger,
                                                            clock: session.dependencies.clock))
        _recording = State(initialValue: RecordingCoordinator(tap: session.recordingTap,
                                                              logger: session.dependencies.logger,
                                                              clock: session.dependencies.clock))
        _manifest = State(initialValue: ClipManifest(logger: session.dependencies.logger))
        _eventFeed = State(initialValue: EventCoordinator(dependencies: session.dependencies,
                                                          credentials: session.credentials))
        _groups = State(initialValue: CameraGroupStore(logger: session.dependencies.logger))
        _bookmarks = State(initialValue: BookmarkStore(logger: session.dependencies.logger))
        _ptz = State(initialValue: PTZCoordinator(logger: session.dependencies.logger))
        _snapshots = State(initialValue: SnapshotCoordinator(logger: session.dependencies.logger,
                                                             clock: session.dependencies.clock))
        _archive = State(initialValue: ArchiveCoordinator(logger: session.dependencies.logger))
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            VToolbarView(isSidebarVisible: window.showsSidebar,
                         isInspectorVisible: window.showsInspector,
                         layout: window.layout,
                         searchText: $window.searchText,
                         isCycling: window.cycle.isRunning,
                         // ⛔ DESIGN.md §11.2: the hairline is drawn "only when the stage is
                         // scrolled — over video there is no separator at all". This was `true`
                         // unconditionally, so a 1 px line sat across the top of every live picture.
                         // The library screens scroll; the tiles do not.
                         showsSeparator: stageScrolls,
                         canShowSidebar: window.contentWidth == 0
                             || window.contentWidth >= MainWindowState.sidebarMinimumWidth,
                         canShowInspector: window.contentWidth == 0
                             || window.contentWidth >= MainWindowState.inspectorMinimumWidth,
                         focusSearchRequests: window.focusSearchRequests,
                         onToggleSidebar: { window.isSidebarVisible.toggle() },
                         onToggleInspector: { window.isInspectorVisible.toggle() },
                         onSelectLayout: { selectLayout($0) },
                         onToggleCycle: { window.cycle = window.cycle.toggledRunning() },
                         onOpenPalette: { openPalette() },
                         onShowMore: { window.isOverflowMenuOpen = true })

            HStack(spacing: 0) {
                if window.showsSidebar {
                    sidebar
                        .frame(width: VTheme.Metrics.sidebarWidth)
                }

                stageRoute
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // One place, and it reaches every tile on the stage — which is the whole
                    // reason this is an environment value rather than an argument threaded through
                    // three initialisers.
                    .vShowsVideoOverlay(window.showsVideoOverlay)
                    .vTileActions(tileActions)

                if window.showsInspector {
                    VInspectorView(tab: $window.inspectorTab,
                                   state: inspectorState,
                                   actions: inspectorActions)
                        .frame(width: VTheme.Metrics.inspectorWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Only when the list is hidden. `VSidebarView` draws its own footer carrying the same
            // counters (UX.md §3.3), and the mockup puts the status inside the sidebar column rather
            // than across the window — so showing both stacked two status lines on top of each other.
            // The bar is kept for the collapsed case, where the sidebar's footer goes with it.
            if !window.showsSidebar {
                VStatusBarView(status: chromeStatus,
                               onOpenSettings: { window.sheet = .cameraSettings },
                               // The degraded chip is only reachable while something *is*
                               // degraded, and the Info tab is where the reason lives.
                               onShowDegraded: { window.isInspectorVisible = true })
            }
        }
        .background(VTheme.Color.Layer.canvas)
        // What decides whether the two side panels fit (DESIGN.md §11.2). Measured rather than read
        // from the `NSWindow`, because it is the *content* width the panels have to divide up and
        // the window's frame includes chrome this view does not own.
        //
        //     func onChange<V: Equatable>(of: V, initial: Bool = false,
        //                                 _ action: @escaping (V, V) -> Void) -> some View
        .background {
            GeometryReader { proxy in
                SwiftUI.Color.clear
                    .onChange(of: proxy.size.width, initial: true) { _, width in
                        window.contentWidth = width
                    }
            }
        }
        // The toolbar *is* the title bar. `WindowChrome` sets `.fullSizeContentView` and nudges the
        // traffic lights down 10 pt so they centre in a 52 pt bar, but SwiftUI still insets content
        // by the title bar's safe area — which left the lights stranded in an empty strip above the
        // toolbar instead of sitting in it. `VToolbarView` already reserves the 79 pt they need.
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .bottom) { toastOverlay }
        .overlay(alignment: .topTrailing) { overflowMenu }
        .overlay { paletteOverlay }
        // A zero-sized button is how a window-wide shortcut is declared in pure SwiftUI. It carries
        // no label and cannot be reached by the pointer or by focus; only ⌘K triggers it.
        .background { windowShortcuts }
        .sheet(item: $window.sheet) { sheet in sheetBody(sheet) }
        .task { window.showsVideoOverlay = session.remembersVideoOverlay }
        // ⚠️ The library is *not* loaded here any more — `RootView` does it at launch, so the
        // connect form and the scan see it too. Loading it again on this view's appearance would
        // re-run the legacy import against a library that may have just been populated by it.
        // Filed once a picture exists, which is the only moment Vigil knows the record is good for
        // anything. Adding at connect time would fill the list with addresses that never answered.
        .onChange(of: session.isReceivingMedia) { _, isReceiving in
            guard isReceiving else { return }
            Task { await session.fileCurrentCameraIfNew(into: library) }
        }
        .task(id: cycleTick) { await runCycle() }
        // Keyed on the camera's id, so a reconnect to the same device does not re-ask and a switch
        // to a different one does. `load` is cheap when the ISAPI session's TTL cache is warm.
        .task(id: session.camera?.id) { loadDeviceInfo() }
        // Re-read whenever a clip finishes, so a recording appears in the list the moment it closes.
        .task(id: recording.completed.count) {
            vouchForFinishedClips()
            reloadClips()
        }
        .task(id: recording.isRecording) {
            // Also re-read on start, so the `.partial` file appears while it is being written
            // rather than only once the clip closes.
            reloadClips()
            await tickWhileRecording()
        }
        .task { await pollTelemetry() }
        .task(id: session.camera?.id) { await pollPoster() }
        .task(id: session.camera?.id) { await eventFeed.follow(camera: session.camera) }
        // Looking at the feed is what marks it read. Anything else — a button, a per-row gesture —
        // leaves a badge that counts events the user has already seen, which is a badge nobody
        // believes after the first time.
        .task(id: isEventsScreenOpen) { await markEventsRead() }
        // Only when the Image tab is actually looked at: these are four HTTP reads per channel.
        .task(id: window.inspectorTab) { await loadImageIfShown() }
        // The capability read is cached for 24 h by the session, so re-running this on a tab change
        // costs nothing after the first time — and the coordinator ignores a repeat for the same
        // channel anyway.
        .task(id: deviceInfoReady) { followPTZ() }
        // The index is only worth reading when the Recordings screen is actually on the stage:
        // it is a paged search at the device and a camera with a full card answers slowly.
        .task(id: archiveTrigger) { await loadArchive() }
        // Fires on every day the user steps to, not just the first load. Stepping a day goes
        // through `loadArchiveDay` rather than `loadArchive`, and an incomplete Tuesday must be
        // announced even though Monday was already announced.
        .onChange(of: archive.incompleteAfter) { _, _ in reportIncompleteDay() }
        // ⛔ `AppLibraryModel` has been writing this on three paths — a list recovered from a backup,
        // a list written by a newer Vigil and therefore read-only, and an add the store refused —
        // and nothing has ever read it. That file's own header says why it matters: "a silent
        // recovery is how a user discovers weeks later that half their cameras are gone and nothing
        // ever mentioned it." That is precisely what has been happening.
        //
        // ⚠️ A toast is the right shape for a recovery and the wrong one for read-only, which is a
        // condition rather than an event and outlasts any banner. Saying it once is still better
        // than never, and a persistent read-only indicator belongs with the sidebar's own chrome
        // rather than being faked with a toast that refuses to dismiss.
        // The menu bar's half of the bargain. `VigilCommands` is built above this window and cannot
        // reach the coordinators these four need, so it bumps a counter and this is where the work
        // happens. See `MainWindowState.snapshotRequests` for why it is a counter and not a closure.
        // `initial: true` so a link that arrived during launch — before this window existed — is
        // performed the moment it does. That is §F-AUT-03 acceptance 5.
        .onChange(of: window.pendingDeepLink, initial: true) { _, _ in performPendingDeepLink() }
        .onChange(of: window.snapshotRequests) { _, _ in takeSnapshot() }
        .onChange(of: window.recordToggleRequests) { _, _ in toggleRecording() }
        .onChange(of: window.findCamerasRequests) { _, _ in onFindCameras() }
        .onChange(of: window.openRecordingsFolderRequests) { _, _ in openRecordingsFolder() }
        // The mirror the menu reads to say Start or Stop. One writer, here.
        .onChange(of: recording.isRecording, initial: true) { _, isRecording in
            window.isRecording = isRecording
        }
        .onChange(of: library.notice) { _, notice in
            guard let notice else { return }
            // The *Reveal in Finder* action FEATURES.md §F-INV-01 acceptance 3 names. Every notice
            // this model raises is about `library.json`, so the folder is always the right
            // destination; it is omitted only when the directory could not be resolved at all,
            // which is the one case where there is nothing to reveal.
            let folder = library.storeDirectory
            window.toast = MainWindowToast(
                kind: .warning,
                message: notice,
                actionTitle: folder == nil ? nil : "Reveal in Finder",
                action: folder.map { url in
                    { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                })
        }
        // ⛔ `RecordingCoordinator`'s own header says it: "Every failure becomes a logged, named
        // outcome in `lastFailure`. A Record button that does nothing and says nothing is the exact
        // shape this project refuses." It has been exactly that shape, because nothing read the
        // property. A destination the sandbox will not write to, a disk with no room, a clip that
        // closes without producing a file — all of them logged, none of them said.
        .onChange(of: recording.lastFailure) { _, failure in
            guard let failure else { return }
            window.toast = MainWindowToast(
                kind: .error,
                message: String(format: Self.localized("Recording failed: %@"), failure))
        }
        // The same omission, one coordinator over. A PTZ command that the camera refuses left the
        // pad looking like it had worked.
        .onChange(of: ptz.lastFailure) { _, failure in
            guard let failure else { return }
            window.toast = MainWindowToast(
                kind: .warning,
                message: String(format: Self.localized("The camera refused that move: %@"), failure))
        }
    }


    /// Renames the camera and remembers the new name for the next launch.
    ///
    /// Two writes, and both are needed. `session.camera` is what every panel reads right now;
    /// `LastConnection` is what the next launch rebuilds the camera from, and without it the rename
    /// would survive exactly until the window closed.
    /// Renames the camera everywhere it is stored.
    ///
    /// ⛔ THREE WRITES, AND THE THIRD WAS MISSING. `session.camera` is what every panel reads right
    /// now; `LastConnection` is what the next launch rebuilds the camera from; and `library.json` is
    /// what every *other* surface reads — `sidebarCameras` takes the name from the library for any
    /// row that is not the live one, and so does the stage's idle cell.
    ///
    /// Without the third the rename was visibly half-applied: the live tile and its sidebar row
    /// showed the new name while the same camera's idle cell showed the old one, and switching away
    /// and back brought the old name onto the live row too. That is the tail of the "renamed camera
    /// does not stick" report — `rememberThisCamera`'s merge fixed the half that `UserDefaults`
    /// owned, and this is the half the library owns.
    /// ⚠️ `internal`, not `private`, because `sheetBody` calls it from `WindowSheets.swift`. Swift
    /// scopes `private` to a *file*, not to a type, so a member a sibling extension needs cannot be
    /// private however local it looks. That is the same rule every `MainWindowView+…` file's header
    /// states — and moving this function's one caller out of this file is exactly what turned the
    /// rule from documentation into a build error.
    func renameCamera(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let id = session.camera?.id else { return }
        session.camera?.name = trimmed
        session.rememberCameraName(trimmed)
        Task { await library.rename(id, to: trimmed) }
    }

    // MARK: - Overlays

    /// The ⌘K palette, over everything.
    @ViewBuilder
    private var paletteOverlay: some View {
        if window.isPaletteOpen {
            VCommandPaletteView(commands: commandCatalogue,
                                query: $window.paletteQuery,
                                selection: $window.paletteSelection,
                                onRun: { run($0) },
                                onDismiss: { window.isPaletteOpen = false })
        }
    }

    /// The overflow menu, hung under the toolbar's "…" button.
    ///
    /// An anchored overlay rather than a `.popover`: `VOverflowMenuView` carries its own E2 glass,
    /// and a popover would draw a second system chrome around it.
    @ViewBuilder
    private var overflowMenu: some View {
        if window.isOverflowMenuOpen {
            VOverflowMenuView(disabledItems: unavailableOverflowItems,
                              onSelect: { select($0) },
                              onDismiss: { window.isOverflowMenuOpen = false })
                .padding(.top, VTheme.Metrics.toolbarHeight)
                .padding(.trailing, VTheme.Space.lg)
        }
    }

    // MARK: - Panels

    /// The camera list, presenting the single session camera as a one-element library.
    private var sidebar: some View {
        VSidebarView(tree: sidebarTree,
                     selection: window.sidebarSelection,
                     search: VSidebarSearch(query: window.searchText),
                     collapsed: window.collapsedRows,
                     layout: window.layout,
                     aggregateBitsPerSecond: telemetry.bitsPerSecond,
                     onSelect: { selection, click in selectInSidebar(selection, click) },
                     onActivate: { selection in activateInSidebar(selection) },
                     onToggleCollapse: { rowID in
                         if window.collapsedRows.contains(rowID) {
                             window.collapsedRows.remove(rowID)
                         } else {
                             window.collapsedRows.insert(rowID)
                         }
                     },
                     onAddGroup: { window.sheet = .newGroup },
                     onAddCamera: { addCamera() },
                     // The gear in the sidebar footer drew itself and answered to nothing.
                     onOpenSettings: { window.sheet = .cameraSettings },
                     onClearSearch: { window.searchText = "" },
                     cameraMenu: { camera in cameraMenu(camera) },
                     groupMenu: { group in groupMenu(group) },
                     thumbnail: { _ in cameraThumbnail })
    }

    /// The sidebar row's miniature of what the camera sees.
    ///
    /// The camera's own JPEG, not a scaled-down video frame: this app's decode path is passthrough
    /// and never produces a pixel buffer to scale — see `DeviceInfoService.poster`. Falls back to
    /// the video-well colour before the first snapshot lands and while a camera is offline.
    @ViewBuilder
    private var cameraThumbnail: some View {
        if let poster = deviceInfo.poster {
            Image(decorative: poster, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            VTheme.Color.Layer.videoWell
        }
    }

    /// What the centre of the window shows.
    ///
    /// The stage is a router (UX.md §5.9): selecting Recordings, Events or Bookmarks in the sidebar
    /// replaces the tiles *inside this window* rather than opening anything. `VLibrarySection`'s
    /// failable initialiser is the whole decision — it answers `nil` for the live selections, which
    /// is exactly the "stay on the tiles" case.
    ///
    /// Without this, the three LIBRARY rows changed the selection and nothing else, which is what
    /// made the screens behind them look absent.
    @ViewBuilder
    private var stageRoute: some View {
        if let section = VLibrarySection(window.sidebarSelection.focus) {
            VLibraryScreen(section: section, state: libraryState, actions: libraryActions)
        } else {
            stage
        }
    }

    /// Whether what is under the toolbar scrolls, which is the only case DESIGN.md §11.2 draws the
    /// toolbar's hairline in. The three library screens scroll; the tile stage does not.
    var stageScrolls: Bool {
        VLibrarySection(window.sidebarSelection.focus) != nil
    }

    /// The advisory banner, when there is one.
    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = window.toast {
            VToastView(kind: toast.kind,
                       message: Text(verbatim: toast.message),
                       actionTitle: toast.actionTitle,
                       width: nil,
                       onAction: { toast.action?() },
                       // The library's notice is cleared with the toast, not left behind: it is
                       // `Equatable` state on an `@Observable`, so an identical message arriving
                       // later would not read as a change and the second recovery would be silent.
                       onDismiss: {
                           window.toast = nil
                           library.dismissNotice()
                       })
                .padding(.bottom, VTheme.Space.xl)
        }
    }

    // MARK: - Identity

    /// Name, address and identity colour for the one camera.
    var identity: LiveCameraIdentity {
        let camera = session.camera
        return LiveCameraIdentity(id: cameraID.rawValue,
                                  name: camera?.displayName ?? session.form.request.host,
                                  host: camera?.host ?? session.form.request.host)
    }

    /// The camera's identifier, or the stable placeholder the tile keeps before the record exists.
    var cameraID: CameraID {
        session.camera?.id ?? RootView.pendingCameraID
    }

    // MARK: - Mapping

    /// Whether the stream is impaired but still showing a picture.
    ///
    /// `LiveConnectionState` offers `isConnecting` and `isShowingVideo` but no "degraded" question,
    /// because every screen that needed one so far pattern-matched the cause to say *what* is wrong.
    /// The status bar only needs the count, so it asks here rather than growing the shared type.
    static func isDegraded(_ state: LiveConnectionState) -> Bool {
        if case .degraded = state { return true }
        return false
    }

    /// Restates a connection state in the sidebar's vocabulary.
    ///
    /// The two enumerations were written independently and their impairment cases line up one for
    /// one, which is not a coincidence — both come from `docs/DESIGN.md` §9. The mapping is spelled
    /// out rather than bridged automatically so that a case added to one and not the other fails to
    /// compile here, at the seam, instead of silently picking a wrong badge.
    static func sidebarStatus(for state: LiveConnectionState) -> VSidebarStatus {
        switch state {
        case .connecting:
            return .connecting(progress: nil)
        case .live:
            return .live
        case .degraded(let cause):
            switch cause {
            case .packetLoss(let fraction):
                return .degraded(.packetLoss(fraction: fraction))
            case .jitter(let milliseconds):
                return .degraded(.jitter(milliseconds: milliseconds))
            case .decodeQueue(let frames):
                return .degraded(.decodeQueue(frames: frames))
            case .lowFrameRate(let fps, _):
                return .degraded(.lowFrameRate(fps: fps))
            case .switchedToTCP:
                return .degraded(.switchedToTCP)
            }
        case .offline:
            return .offline(retryInSeconds: nil)
        }
    }
}

// MARK: - CycleTick

/// What a change to restarts the cycle timer.
///
/// A value rather than a `Bool` so `.task(id:)` re-runs when the interval or the layout changes, not
/// only when the cycle is switched on and off — otherwise a new interval would not take effect until
/// the old sleep had finished.
struct CycleTick: Equatable {

    /// Whether the cycle should be advancing at all.
    let isTicking: Bool

    /// Seconds between advances.
    let interval: TimeInterval

    /// The layout, which decides how many pages there are to advance through.
    let layout: VGridLayout
}

#endif  // os(macOS)
