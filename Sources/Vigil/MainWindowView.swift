//
//  MainWindowView.swift
//  Vigil
//
//  The assembled main window: toolbar, camera list, tile stage, inspector, status bar. The one place
//  the single-camera session model is adapted into the shapes the `VigilUI` screens expect.
//  macOS-only. See design/mockups/01-main-window.html and docs/UX.md.
//

#if os(macOS)

import AppKit
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

    /// Fetches the Info tab's device identity over ISAPI.
    ///
    /// Owned here rather than by `AppSessionModel`, because nothing it does can affect the stream:
    /// a camera that refuses `/ISAPI/System/deviceInfo` still shows a picture, and a device-info
    /// timeout must not be able to disturb a session. Built in `init` because it needs the app's
    /// logger and clock, which arrive with the session.
    @State private var deviceInfo: DeviceInfoService

    /// Starts and stops clip recording.
    @State private var recording: RecordingCoordinator

    /// Advances once a second while recording, purely to redraw the elapsed counter.
    ///
    /// `RecordingCoordinator.elapsed()` is a function over `startedAt`, not an observable property,
    /// so nothing invalidates the body as the clock moves — the counter would render once and then
    /// sit frozen. Ticking only while recording keeps the window idle the rest of the time.
    @State private var recordingTick = Date()

    // MARK: - Initialisation

    /// Builds the window over a session.
    ///
    /// - Parameters:
    ///   - session: the streaming session.
    ///   - window: per-window view state.
    init(session: AppSessionModel, window: MainWindowState) {
        self.session = session
        self.window = window
        _deviceInfo = State(initialValue: DeviceInfoService(logger: session.dependencies.logger,
                                                            clock: session.dependencies.clock))
        _recording = State(initialValue: RecordingCoordinator(tap: session.recordingTap,
                                                              logger: session.dependencies.logger,
                                                              clock: session.dependencies.clock))
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            VToolbarView(isSidebarVisible: window.isSidebarVisible,
                         isInspectorVisible: window.isInspectorVisible,
                         layout: window.layout,
                         searchText: $window.searchText,
                         isCycling: window.cycle.isRunning,
                         showsSeparator: true,
                         onToggleSidebar: { window.isSidebarVisible.toggle() },
                         onToggleInspector: { window.isInspectorVisible.toggle() },
                         onSelectLayout: { selectLayout($0) },
                         onToggleCycle: { window.cycle = window.cycle.toggledRunning() },
                         onOpenPalette: { openPalette() },
                         onShowMore: { window.isOverflowMenuOpen = true })

            HStack(spacing: 0) {
                if window.isSidebarVisible {
                    sidebar
                        .frame(width: VTheme.Metrics.sidebarWidth)
                }

                stageRoute
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if window.isInspectorVisible {
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
            if !window.isSidebarVisible {
                VStatusBarView(status: chromeStatus)
            }
        }
        .background(VTheme.Color.Layer.canvas)
        .overlay(alignment: .bottom) { toastOverlay }
        .overlay(alignment: .topTrailing) { overflowMenu }
        .overlay { paletteOverlay }
        // A zero-sized button is how a window-wide shortcut is declared in pure SwiftUI. It carries
        // no label and cannot be reached by the pointer or by focus; only ⌘K triggers it.
        .background {
            Button("", action: { openPalette() })
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
            Button("", action: { toggleRecording() })
                .keyboardShortcut("r", modifiers: .command)
                .hidden()
        }
        .task(id: cycleTick) { await runCycle() }
        // Keyed on the camera's id, so a reconnect to the same device does not re-ask and a switch
        // to a different one does. `load` is cheap when the ISAPI session's TTL cache is warm.
        .task(id: session.camera?.id) { loadDeviceInfo() }
        // Re-read whenever a clip finishes, so a recording appears in the list the moment it closes.
        .task(id: recording.completed.count) { reloadClips() }
        .task(id: recording.isRecording) { await tickWhileRecording() }
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

    // MARK: - Palette, menu and cycle

    /// Asks the camera who it is, once there is a camera to ask.
    ///
    /// Silent when the record does not exist yet — that is the window between pressing Return and
    /// the session storing the camera, and guessing an address there would send a request to the
    /// wrong host.
    private func loadDeviceInfo() {
        guard let camera = session.camera else { return }
        deviceInfo.load(camera: camera, credentials: session.credentials)
    }

    /// Opens the palette with an empty query.
    ///
    /// Cleared on *open* rather than on close: a query that survived dismissal would silently filter
    /// the next invocation, and the first keystroke would land in the middle of stale text.
    private func openPalette() {
        window.paletteQuery = ""
        window.paletteSelection = nil
        window.isPaletteOpen = true
    }

    /// Every command the window can honour right now.
    ///
    /// Titles are plain resolved strings by design — `VCommand.title` is not a `LocalizedStringKey`,
    /// because a key is opaque to the character-level folding the ranker does and would score against
    /// English text in a Russian build.
    ///
    /// The catalogue is deliberately short. Only the layout switches and the two panel toggles do
    /// anything today; listing commands the app cannot perform would make the palette a menu of
    /// disappointments.
    private var commandCatalogue: [VCommand] {
        var commands = VGridLayout.allCases.map { layout in
            VCommand(id: "layout.\(layout.rawValue)",
                     title: Self.layoutTitle(layout),
                     shortcut: String(layout.shortcutDigit),
                     category: .layout,
                     isEnabled: layout != window.layout)
        }
        commands.append(VCommand(id: "view.sidebar",
                                 title: Self.localized("Toggle Sidebar"),
                                 category: .view))
        commands.append(VCommand(id: "view.inspector",
                                 title: Self.localized("Toggle Inspector"),
                                 category: .view))
        commands.append(VCommand(id: "record.toggle",
                                 title: recording.isRecording
                                     ? Self.localized("Stop Recording")
                                     : Self.localized("Start Recording"),
                                 shortcut: "R",
                                 category: .recording,
                                 isEnabled: session.format != nil && session.camera != nil))
        commands.append(VCommand(id: "view.cycle",
                                 title: Self.localized("Cycle cameras"),
                                 category: .view,
                                 isEnabled: window.cycle.canCycle(cameraCount: 1,
                                                                  layout: window.layout)))
        return commands
    }

    /// A command title in the user's language, as a plain `String`.
    ///
    /// `VCommand.title` is a `String` and not a `LocalizedStringKey` on purpose — the ranker folds
    /// and scores individual characters, and a key is opaque to that, so a Russian build would rank
    /// against English text. The lookup therefore happens here, through the same bundle every other
    /// `VigilUI` string uses.
    private static func localized(_ key: String) -> String {
        Bundle.vigilUI.localizedString(forKey: key, value: key, table: nil)
    }

    /// The layout's name, sharing `VChromeLayoutSwitcher`'s wording so the palette and the toolbar's
    /// tooltip cannot describe the same layout differently.
    private static func layoutTitle(_ layout: VGridLayout) -> String {
        switch layout {
        case .single:    return localized("Single view")
        case .grid2x2:   return localized("Two by two")
        case .hero1p5:   return localized("Hero and five")
        case .grid3x3:   return localized("Three by three")
        case .grid4x4:   return localized("Four by four")
        case .hero1p7:   return localized("Hero and seven")
        case .dual2p8:   return localized("Two heroes and eight")
        case .mosaic4x3: return localized("Mosaic")
        }
    }

    /// Performs a command and closes the palette.
    private func run(_ command: VCommand) {
        window.isPaletteOpen = false
        switch command.id {
        case "view.sidebar":   window.isSidebarVisible.toggle()
        case "view.inspector": window.isInspectorVisible.toggle()
        case "view.cycle":     window.cycle = window.cycle.toggledRunning()
        case "record.toggle":  toggleRecording()
        default:
            if let layout = VGridLayout(rawValue: String(command.id.dropFirst("layout.".count))) {
                selectLayout(layout)
            }
        }
    }

    /// Starts or stops a clip.
    ///
    /// Needs the negotiated format: `ClipRecorder` is a passthrough writer, so it must be told the
    /// codec before the first frame rather than inferring it. Silent before the DESCRIBE lands,
    /// which is also when the palette entry is disabled.
    private func toggleRecording() {
        if recording.isRecording {
            recording.stop()
            return
        }
        guard let camera = session.camera, let format = session.format else { return }
        recording.start(camera: camera,
                        codec: format.videoCodec,
                        parameterSets: format.parameterSets,
                        resolution: format.resolution,
                        requestKeyframe: { })
    }

    /// Overflow entries with nothing behind them yet, dimmed rather than hidden.
    ///
    /// Removing them would make the menu's shape change as features land, and a user who learned
    /// where Settings sits would find it somewhere else next month.
    private var unavailableOverflowItems: Set<VOverflowItem> {
        [.videoWall, .pictureInPicture, .discovery, .streamDoctor, .settings]
    }

    /// Handles an overflow choice. Every item is disabled today, so this only closes the menu.
    private func select(_ item: VOverflowItem) {
        window.isOverflowMenuOpen = false
    }

    /// Applies a layout and re-anchors the cycle, so a page index cannot survive into a layout that
    /// has fewer pages than it.
    private func selectLayout(_ layout: VGridLayout) {
        window.layout = layout
        window.cycle = window.cycle.retargeted(cameraCount: 1, layout: layout)
    }

    /// What restarts the cycle timer: whether it is ticking, how fast, and over what.
    ///
    /// A value rather than a `Bool`, so changing the interval or the layout mid-cycle restarts the
    /// sleep instead of waiting out the old one.
    private var cycleTick: CycleTick {
        CycleTick(isTicking: window.cycle.isTicking,
                  interval: window.cycle.interval,
                  layout: window.layout)
    }

    /// The cycle's clock. The model is pure and holds no timer — this is the only thing that ticks.
    private func runCycle() async {
        while !Task.isCancelled, window.cycle.isTicking {
            let nanoseconds = UInt64(window.cycle.interval * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return                  // cancelled: the task id changed, or the view went away
            }
            guard !Task.isCancelled else { return }
            window.cycle = window.cycle.next(cameraCount: 1, layout: window.layout)
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
                     aggregateBitsPerSecond: nil,
                     onSelect: { selection, _ in window.sidebarSelection.select(selection) },
                     onToggleCollapse: { rowID in
                         if window.collapsedRows.contains(rowID) {
                             window.collapsedRows.remove(rowID)
                         } else {
                             window.collapsedRows.insert(rowID)
                         }
                     },
                     onClearSearch: { window.searchText = "" },
                     thumbnail: { _ in Color.clear })
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

    /// What the three library screens read.
    ///
    /// Every collection is empty and `archive` is `nil`, because nothing records, no event stream is
    /// subscribed and no archive day has been loaded. That is not a placeholder standing in for real
    /// data — it is the truthful state, and each screen's empty state says what would fill it.
    private var libraryState: VLibraryState {
        VLibraryState(clock: TimelineClock(calendar: .autoupdatingCurrent, now: Date()),
                      clips: window.clips,
                      recordingsFolder: Self.recordingsFolderLabel)
    }

    /// The recordings folder as a user would recognise it, for the empty state's "where would a clip
    /// appear" answer. Abbreviated with a tilde rather than shown as a container path.
    private static var recordingsFolderLabel: String? {
        guard let folder = Self.recordingsFolder else { return nil }
        return (folder.path as NSString).abbreviatingWithTildeInPath
    }

    /// Where clips are written. `RecordingDestinationResolver` owns the real answer; this is the same
    /// default location, used only for listing and revealing.
    private static var recordingsFolder: URL? {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?
            .appending(path: "Vigil", directoryHint: .isDirectory)
    }

    /// Re-reads the clips folder into `window.clips`.
    ///
    /// Runs on appearance and every time a recording finishes, which is when the set can change. A
    /// file still being written is listed with `isRecording` true rather than hidden, because hiding
    /// it would make pressing Record look like it did nothing for as long as the clip ran.
    private func reloadClips() {
        guard let folder = Self.recordingsFolder else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let listing = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        guard let listing else {
            window.clips = []
            return
        }
        let camera = VLibraryCamera(id: cameraID, name: identity.name)
        window.clips = listing.compactMap { url -> VLibraryClip? in
            guard ["mp4", "mov"].contains(url.pathExtension.lowercased()) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isPartial = url.lastPathComponent.hasSuffix(".partial")
            return VLibraryClip(id: Self.stableID(for: url),
                                camera: camera,
                                startedAt: values?.contentModificationDate ?? Date(),
                                durationSeconds: nil,
                                byteCount: values?.fileSize.map(Int64.init),
                                fileName: url.lastPathComponent,
                                isRecording: isPartial)
        }
    }

    /// A UUID derived from the file's path, so a row keeps its identity across a refresh.
    ///
    /// Hashing the path rather than minting a fresh UUID matters: `ForEach` would otherwise rebuild
    /// every row on each reload, losing selection and restarting animations.
    private static func stableID(for url: URL) -> UUID {
        var hasher = Hasher()
        hasher.combine(url.path)
        let value = UInt64(bitPattern: Int64(hasher.finalize()))
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 { bytes[index] = UInt8((value >> (8 * UInt64(index))) & 0xFF) }
        for index in 8..<16 { bytes[index] = bytes[index - 8] }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The library gestures the app can honour today.
    ///
    /// Only the two that need no data behind them. Everything else keeps its no-op default: playing,
    /// revealing and deleting a clip need clips, and scrubbing needs a loaded day. A handler that
    /// fired against an empty list would be a button pretending to work.
    private var libraryActions: VLibraryActions {
        var actions = VLibraryActions()
        actions.onOpenRecordingsFolder = { openRecordingsFolder() }
        actions.onRevealClip = { clip in revealClip(clip) }
        actions.onOpenNotificationSettings = { window.isInspectorVisible = true }
        return actions
    }

    /// Reveals the recordings destination in the Finder, creating nothing.
    ///
    /// `RecordingDestination` owns where clips go; until the app drives it, the folder may not exist
    /// yet, and `activateFileViewerSelecting` on a missing path silently does nothing rather than
    /// failing — which is the right outcome for a button whose whole job is "show me where".
    /// Reveals one clip in the Finder.
    private func revealClip(_ clip: VLibraryClip) {
        guard let folder = Self.recordingsFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder.appending(path: clip.fileName)])
    }

    private func openRecordingsFolder() {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)
        guard let folder = movies.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// The tile stage.
    ///
    /// The video closure is where `VigilRender` enters, exactly as it did in the pre-window build:
    /// every callback and the logger are named explicitly, because each one has a default that
    /// compiles and reports nothing, which is the "no video, no error" shape this project refuses.
    private var stage: some View {
        VGridStageView(assignment: stageAssignment,
                       cameras: stageCameras,
                       selection: cameraID,
                       onRetry: { _ in session.perform(.retry) },
                       onRemedy: { _, remedy in session.perform(remedy) },
                       video: { _ in
                           VideoTile(cameraID: cameraID,
                                     frames: session.frames,
                                     logger: session.dependencies.logger,
                                     onKeyframeNeeded: { session.recoverStalledPicture() },
                                     onDecodeFailure: { session.handleDecodeFailure($0) },
                                     onFramesDropped: { session.handleFramesDropped($0, reason: $1) })
                       })
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
                       onDismiss: { window.toast = nil })
                .padding(.bottom, VTheme.Space.xl)
        }
    }

    // MARK: - Session → panel adapters

    /// The library as the sidebar sees it: one camera, no groups.
    private var sidebarTree: VSidebarTree {
        VSidebarTree(cameras: [sidebarCamera],
                     search: VSidebarSearch(query: window.searchText),
                     collapsed: window.collapsedRows,
                     now: Date())
    }

    /// The session camera as a sidebar row.
    private var sidebarCamera: VSidebarCamera {
        VSidebarCamera(id: cameraID,
                       name: identity.name,
                       host: identity.host,
                       status: Self.sidebarStatus(for: session.liveState))
    }

    /// One cell, holding the one camera.
    private var stageAssignment: VStageAssignment {
        VStageAssignment(layout: window.layout, cameras: [cameraID])
    }

    /// The session camera as a stage tile.
    private var stageCameras: [VStageCamera] {
        [VStageCamera(camera: identity,
                      state: session.liveState,
                      attemptStartedAt: session.attemptStartedAt,
                      isRecording: recording.isRecording,
                      recordingElapsed: recording.elapsed(now: recordingTick),
                      stats: tileStats)]
    }

    /// The tile's telemetry pill.
    ///
    /// Only the codec and the geometry, which the negotiated format already answers — bitrate and
    /// frame rate need `StreamStatisticsCollector`, which is written but not yet fed. `nil` before
    /// the DESCRIBE lands, which also hides the pill's REC badge, so the badge is not the only
    /// signal that a clip is running: the elapsed counter at the bottom of the tile is unconditional.
    private var tileStats: VTileStats? {
        guard let format = session.format else { return nil }
        let dimensions = format.resolution.map {
            FrameDimensions(width: $0.width, height: $0.height)
        }
        return VTileStats(codec: format.videoCodec.rawValue.uppercased(),
                          dimensions: dimensions,
                          framesPerSecond: format.declaredFPS,
                          isHardwareDecode: true)
    }

    /// Redraws once a second for as long as a clip is being written.
    private func tickWhileRecording() async {
        while !Task.isCancelled, recording.isRecording {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            recordingTick = Date()
        }
    }

    /// What the inspector shows.
    ///
    /// Only the fields the slice can actually answer are set. The rest keep their defaults, so a
    /// panel renders its own "not available" treatment rather than a fabricated number — the same
    /// reason `stats:` is left off the stage tile above.
    private var inspectorState: VInspectorState {
        VInspectorState(camera: identity,
                        connection: session.liveState,
                        now: Date(),
                        identity: deviceIdentity,
                        storage: deviceInfo.storage,
                        isDeviceLoading: deviceInfo.isLoading,
                        isDeviceUnavailable: deviceInfo.isUnavailable,
                        recording: recordingState)
    }

    /// The address half of the Info tab.
    ///
    /// Only the fields the app already holds: host, ports, channel and TLS come from the `Camera`
    /// record, or from the typed request before that record exists. Model, firmware, serial, MAC and
    /// uptime stay empty and render as `—`, because they arrive from the ISAPI device-info endpoint
    /// and the single-camera slice never calls it. An empty identity was why the Info tab showed a
    /// bare `:554` — the port with no host in front of it.
    private var deviceIdentity: InspectorDeviceIdentity {
        // Whatever the device answered. `DeviceInfoService.load` publishes the address half
        // immediately and fills in model, firmware, serial, MAC and uptime when the reply lands, so
        // this is correct before the request completes and richer after it.
        deviceInfo.identity
    }

    /// The inspector buttons the slice can actually honour.
    ///
    /// Three of the six. `onRunStreamDoctor` and `onRetryDevice` need the diagnosis sequence and the
    /// ISAPI reboot endpoint respectively, and `onCopySerial` needs a serial to copy — none of which
    /// the single-camera slice has. They keep their no-op defaults rather than being given something
    /// approximate, because a button that does *nearly* the right thing is worse than one that
    /// visibly does nothing.
    private var inspectorActions: VInspectorActions {
        var actions = VInspectorActions()
        actions.onOpenWebPage = { openDeviceWebPage() }
        actions.onRequestKeyframe = { session.recoverStalledPicture() }
        actions.onReconnect = { session.perform(.retry) }
        actions.onRetryDevice = { deviceInfo.retry() }
        actions.onToggleRecording = { toggleRecording() }
        return actions
    }

    /// Opens the camera's own web interface in the default browser.
    ///
    /// Built from the same host and HTTP port the inspector shows, so the two cannot disagree. A host
    /// that will not form a URL — empty, before a connection — simply does nothing rather than
    /// force-unwrapping into a crash.
    private func openDeviceWebPage() {
        let identity = deviceIdentity
        guard !identity.host.isEmpty else { return }
        var components = URLComponents()
        components.scheme = identity.usesTLS ? "https" : "http"
        components.host = identity.host
        components.port = identity.httpPort
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// What the Rec tab shows.
    private var recordingState: VInspectorRecordingState {
        VInspectorRecordingState(
            isRecording: recording.isRecording,
            elapsedSeconds: recording.elapsed(now: recordingTick)
                .map { Double($0.components.seconds) } ?? 0,
            destination: Self.recordingsFolderLabel,
            clipsToday: window.clips.count)
    }

    /// The status bar's counters.
    private var chromeStatus: VChromeStatus {
        VChromeStatus(liveCount: session.liveState.isShowingVideo ? 1 : 0,
                      degradedCount: Self.isDegraded(session.liveState) ? 1 : 0,
                      throughput: .unmeasured)
    }

    // MARK: - Identity

    /// Name, address and identity colour for the one camera.
    private var identity: LiveCameraIdentity {
        let camera = session.camera
        return LiveCameraIdentity(id: cameraID.rawValue,
                                  name: camera?.displayName ?? session.form.request.host,
                                  host: camera?.host ?? session.form.request.host)
    }

    /// The camera's identifier, or the stable placeholder the tile keeps before the record exists.
    private var cameraID: CameraID {
        session.camera?.id ?? RootView.pendingCameraID
    }

    // MARK: - Mapping

    /// Whether the stream is impaired but still showing a picture.
    ///
    /// `LiveConnectionState` offers `isConnecting` and `isShowingVideo` but no "degraded" question,
    /// because every screen that needed one so far pattern-matched the cause to say *what* is wrong.
    /// The status bar only needs the count, so it asks here rather than growing the shared type.
    private static func isDegraded(_ state: LiveConnectionState) -> Bool {
        if case .degraded = state { return true }
        return false
    }

    /// Restates a connection state in the sidebar's vocabulary.
    ///
    /// The two enumerations were written independently and their impairment cases line up one for
    /// one, which is not a coincidence — both come from `docs/DESIGN.md` §9. The mapping is spelled
    /// out rather than bridged automatically so that a case added to one and not the other fails to
    /// compile here, at the seam, instead of silently picking a wrong badge.
    private static func sidebarStatus(for state: LiveConnectionState) -> VSidebarStatus {
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
