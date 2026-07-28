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

    /// Fetches the Info tab's device identity over ISAPI.
    ///
    /// Owned here rather than by `AppSessionModel`, because nothing it does can affect the stream:
    /// a camera that refuses `/ISAPI/System/deviceInfo` still shows a picture, and a device-info
    /// timeout must not be able to disturb a session. Built in `init` because it needs the app's
    /// logger and clock, which arrive with the session.
    @State private var deviceInfo: DeviceInfoService

    /// Starts and stops clip recording.
    @State private var recording: RecordingCoordinator

    /// Which files in the recordings folder Vigil actually wrote.
    @State private var manifest: ClipManifest

    /// The camera's alert stream, which fills the Events screen and the sidebar's badge.
    @State private var eventFeed: EventCoordinator

    /// Advances once a second while recording, purely to redraw the elapsed counter.
    ///
    /// `RecordingCoordinator.elapsed()` is a function over `startedAt`, not an observable property,
    /// so nothing invalidates the body as the clock moves — the counter would render once and then
    /// sit frozen. Ticking only while recording keeps the window idle the rest of the time.
    @State private var recordingTick = Date()

    /// The last telemetry snapshot, refreshed once a second while the window is up.
    ///
    /// Pulled rather than pushed: the collector is lock-guarded and lives off the main actor, and a
    /// per-frame push would put the media path on the UI thread — the exact thing DESIGN.md §7.9
    /// forbids. One read per second is what the Stream tab's `LAST 60 S` sparkline needs and no more.
    @State private var telemetry = StreamTelemetrySnapshot.unmeasured

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
        _manifest = State(initialValue: ClipManifest(logger: session.dependencies.logger))
        _eventFeed = State(initialValue: EventCoordinator(dependencies: session.dependencies,
                                                          credentials: session.credentials))
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
        // Only when the Image tab is actually looked at: these are four HTTP reads per channel.
        .task(id: window.inspectorTab) { await loadImageIfShown() }
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

    /// Reads the picture controls, but only when the Image tab is on screen.
    private func loadImageIfShown() async {
        guard window.inspectorTab == .image, let channel = session.camera?.channel else { return }
        await deviceInfo.loadImageSettings(channel: channel)
    }

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
                        requestKeyframe: {
                            // Not an empty closure. `ClipRecorder` asks for an IDR after five
                            // seconds without one and gives up at fifteen, so leaving this unwired
                            // meant a camera with a long GOP silently never started writing — the
                            // recorder waiting for a keyframe nobody had asked for.
                            Task { @MainActor in session.recoverStalledPicture() }
                        })
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
                     aggregateBitsPerSecond: telemetry.bitsPerSecond,
                     onSelect: { selection, _ in window.sidebarSelection.select(selection) },
                     onToggleCollapse: { rowID in
                         if window.collapsedRows.contains(rowID) {
                             window.collapsedRows.remove(rowID)
                         } else {
                             window.collapsedRows.insert(rowID)
                         }
                     },
                     onClearSearch: { window.searchText = "" },
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

    /// What the three library screens read.
    ///
    /// Every collection is empty and `archive` is `nil`, because nothing records, no event stream is
    /// subscribed and no archive day has been loaded. That is not a placeholder standing in for real
    /// data — it is the truthful state, and each screen's empty state says what would fill it.
    private var libraryState: VLibraryState {
        VLibraryState(clock: TimelineClock(calendar: .autoupdatingCurrent, now: Date()),
                      clips: window.clips,
                      events: eventFeed.events,
                      recordingsFolder: recordingsFolderLabel)
    }

    /// The recordings folder as a user would recognise it, for the empty state's "where would a clip
    /// appear" answer. Abbreviated with a tilde rather than shown as a container path.
    private var recordingsFolderLabel: String? {
        guard let folder = recording.clipsDirectory() else { return nil }
        return (folder.path as NSString).abbreviatingWithTildeInPath
    }

    /// Re-reads the clips folder into `window.clips`.
    ///
    /// Runs on appearance and every time a recording finishes, which is when the set can change. A
    /// file still being written is listed with `isRecording` true rather than hidden, because hiding
    /// it would make pressing Record look like it did nothing for as long as the clip ran.
    private func reloadClips() {
        // Two passes on the first run only: the first adopts whatever predates the manifest, the
        // second lists against it. Without this, introducing the manifest would hide every clip the
        // user had already recorded.
        if manifest.entries.isEmpty {
            adoptExistingClips()
        }
        let logger = session.dependencies.logger
        guard let folder = recording.clipsDirectory() else {
            logger.error(.storage, "clip listing: no usable destination")
            window.clips = []
            return
        }
        // Clips are NOT in this folder — they are under it. `RecordingNaming.defaultClipTemplate`
        // is "{camera}/{yyyy}-{MM}-{dd}/{camera}_{HHmmss}_{trigger}", so the recorder creates two
        // levels of directory per clip, and a flat `contentsOfDirectory` sees one subfolder and no
        // media at all. That is what "0 of 1 entries" was reporting.
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            logger.error(.storage, "clip listing: cannot read \(folder.path)")
            window.clips = []
            return
        }

        let camera = VLibraryCamera(id: cameraID, name: identity.name)
        var found: [VLibraryClip] = []
        var seen = 0
        var foreign = 0
        var altered = 0
        for case let url as URL in walker {
            seen += 1
            // A clip still being written is `name.mp4.partial`, whose `pathExtension` is "partial",
            // so testing the extension alone hides the file a user is watching get recorded.
            let name = url.lastPathComponent
            let isPartial = name.hasSuffix(".partial")
            let mediaName = isPartial ? String(name.dropLast(".partial".count)) : name
            guard ["mp4", "mov"].contains((mediaName as NSString).pathExtension.lowercased()) else {
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile != false else { continue }

            // Only files Vigil wrote. The recordings folder is an ordinary directory in the user's
            // Movies: anything dropped into it would otherwise be listed as a recording, complete
            // with a camera name it never came from. A clip still being written has no entry yet and
            // is allowed through, because the writer holding it open is this process.
            let relative = ClipManifest.key(for: url, under: folder, logger: logger)
            let vouched = manifest.entry(for: relative)
            if !isPartial {
                guard let vouched else {
                    if foreign == 0 {
                        logger.debug(.storage, "clip listing: no manifest entry for \(relative)")
                    }
                    foreign += 1
                    continue
                }
                // Size is reported, not enforced. `ClipRecorder` reads it at close, which can be
                // before `AVAssetWriter` has finished appending the moov atom and before the
                // `.partial` rename — so a legitimate clip can differ from its recorded size, and
                // hiding it over that would lose the user's own recording. Membership in the
                // manifest is the check that answers the question actually asked: was this file put
                // here by Vigil, or dropped in.
                if let size = values?.fileSize, Int64(size) != vouched.byteCount {
                    altered += 1
                }
            }
            found.append(VLibraryClip(id: Self.stableID(for: url),
                                      camera: camera,
                                      startedAt: values?.contentModificationDate ?? Date(),
                                      // Zero means "adopted, never measured" — the enrichment pass
                                      // reads the real length from the file rather than the row
                                      // showing a confident 0:00.
                                      durationSeconds: manifest.entry(for: relative)
                                          .map(\.mediaSeconds).flatMap { $0 > 0 ? $0 : nil },
                                      byteCount: values?.fileSize.map(Int64.init),
                                      fileName: relative,
                                      url: url,
                                      thumbnail: window.posters[url],
                                      isRecording: isPartial))
        }
        window.clips = found
        logger.info(.storage,
                    "clip listing: \(found.count) clips of \(seen) entries under \(folder.path)"
                    + (foreign > 0 ? ", \(foreign) not written by Vigil" : "")
                    + (altered > 0 ? ", \(altered) whose size differs from the record" : ""))
        Task { await enrich(found) }
    }

    /// Fills in the poster frame and the duration for clips that do not have them yet.
    ///
    /// Off the main actor and one clip at a time: `AVAssetImageGenerator` decodes a frame, and doing
    /// that for a folder's worth of clips at once would compete with the live decoder for the very
    /// hardware the picture depends on. Results are cached by URL, so scrolling the list or
    /// re-reading the folder does no work twice.
    private func enrich(_ clips: [VLibraryClip]) async {
        for clip in clips {
            guard let url = clip.url, !clip.isRecording, window.posters[url] == nil else { continue }
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 180)
            // A clip that is short, truncated, or whose moov atom never landed simply yields no
            // image; the row keeps its tinted placeholder rather than the list stalling.
            let poster = try? await generator.image(at: .zero).image
            let duration = try? await asset.load(.duration)
            await MainActor.run {
                if let poster { window.posters[url] = poster }
                if let duration, duration.isNumeric {
                    window.durations[url] = duration.seconds
                }
            }
        }
        applyEnrichment()
    }

    /// Rebuilds the rows with whatever posters and durations have been extracted.
    private func applyEnrichment() {
        window.clips = window.clips.map { clip in
            guard let url = clip.url else { return clip }
            return VLibraryClip(id: clip.id,
                                camera: clip.camera,
                                startedAt: clip.startedAt,
                                durationSeconds: clip.durationSeconds ?? window.durations[url],
                                byteCount: clip.byteCount,
                                fileName: clip.fileName,
                                url: url,
                                thumbnail: clip.thumbnail ?? window.posters[url],
                                isRecording: clip.isRecording)
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
        actions.onDeleteClip = { clip in deleteClip(clip) }
        actions.onOpenNotificationSettings = { window.isInspectorVisible = true }
        return actions
    }

    /// Reveals the recordings destination in the Finder, creating nothing.
    ///
    /// `RecordingDestination` owns where clips go; until the app drives it, the folder may not exist
    /// yet, and `activateFileViewerSelecting` on a missing path silently does nothing rather than
    /// failing — which is the right outcome for a button whose whole job is "show me where".
    /// One-time migration: takes responsibility for clips recorded before the manifest existed.
    private func adoptExistingClips() {
        guard let folder = recording.clipsDirectory() else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }

        var adoptable: [(relativePath: String, cameraID: CameraID, modifiedAt: Date, bytes: Int64)] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard !name.hasSuffix(".partial") else { continue }
            guard ["mp4", "mov"].contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile != false else { continue }
            adoptable.append((ClipManifest.key(for: url, under: folder),
                              cameraID,
                              values?.contentModificationDate ?? Date(),
                              Int64(values?.fileSize ?? 0)))
        }
        manifest.adopt(adoptable)
    }

    /// Adds the clips the last recording produced to the manifest.
    private func vouchForFinishedClips() {
        let finished = recording.lastFinished
        guard !finished.isEmpty,
              let camera = session.camera,
              let root = recording.clipsDirectory() else { return }
        manifest.record(finished, cameraID: camera.id, root: root)
    }

    /// Deletes a clip and forgets it.
    ///
    /// The manifest entry goes with the file. Leaving it behind would make a later file of the same
    /// name inherit this one's vouching, which is exactly the substitution the manifest exists to
    /// prevent.
    private func deleteClip(_ clip: VLibraryClip) {
        guard let url = clip.url else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            manifest.forget(clip.fileName)
            session.dependencies.logger.info(.storage, "clip moved to trash")
            reloadClips()
        } catch {
            session.dependencies.logger.error(.storage, "could not delete clip: \(error)")
        }
    }

    /// Reveals one clip in the Finder.
    private func revealClip(_ clip: VLibraryClip) {
        guard let folder = recording.clipsDirectory() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder.appending(path: clip.fileName)])
    }

    private func openRecordingsFolder() {
        guard let folder = recording.clipsDirectory() else { return }
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
                     eventBadge: eventFeed.unreadCount > 0 ? eventFeed.unreadCount : nil,
                     recordingCount: window.clips.isEmpty ? nil : window.clips.count,
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

    /// What the Stream tab's header describes.
    private var streamDescription: InspectorStreamDescription {
        guard let format = session.format else { return InspectorStreamDescription() }
        return InspectorStreamDescription(
            codec: format.videoCodec.rawValue.uppercased(),
            pixelWidth: format.resolution?.width ?? 0,
            pixelHeight: format.resolution?.height ?? 0,
            streamInUse: Self.qualityLabel(format.quality),
            transport: format.transport.rawValue,
            targetFramesPerSecond: format.declaredFPS ?? 0)
    }

    /// The stream's name as the panel shows it.
    ///
    /// `StreamQuality` is `Int`-backed — `main = 1` — so its raw value is a channel-arithmetic
    /// number, not a label. Spelling it out here keeps the panel from printing "1".
    private static func qualityLabel(_ quality: StreamQuality) -> String {
        switch quality {
        case .main:  return "Main"
        case .sub:   return "Sub"
        case .third: return "Third"
        }
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
        // Measured values win where they exist; the negotiated format fills the rest. A declared
        // frame rate is what the camera promised, a measured one is what arrived, and the tile
        // should show the second whenever it has been observed.
        return VTileStats(codec: format.videoCodec.rawValue.uppercased(),
                          dimensions: telemetry.resolution ?? dimensions,
                          framesPerSecond: telemetry.framesPerSecond ?? format.declaredFPS,
                          isHardwareDecode: true)
    }

    /// Reads the collector once a second for as long as the window is on screen.
    private func pollTelemetry() async {
        while !Task.isCancelled {
            let now = session.dependencies.clock.now()
            // The deepest the frame backlog got in the last second, not its depth at this instant —
            // see `FrameBacklog.takePeak()` for why the instantaneous value is always zero.
            session.telemetry.noteDecodeQueueDepth(session.backlog.takePeak())
            session.telemetry.tick(at: now)
            telemetry = session.telemetry.telemetry(at: now)
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
        }
    }

    /// Refreshes the sidebar's thumbnail from the camera every few seconds.
    ///
    /// Five seconds, not one: this is an HTTP round trip to the device for a picture 40 pt wide, and
    /// asking faster would put load on the camera in exchange for nothing a viewer would notice.
    private func pollPoster() async {
        guard let channel = session.camera?.channel else { return }
        while !Task.isCancelled {
            await deviceInfo.refreshPoster(channel: channel)
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
        }
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
                        stream: streamDescription,
                        statistics: telemetry.statistics,
                        recentStatistics: telemetry.recentStatistics,
                        image: deviceInfo.image ?? InspectorImageSettings(),
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
        actions.onCopySerial = { copySerial() }
        actions.onImageSettings = { settings in writeImage(settings) }
        actions.onResetImage = { resetImage() }
        return actions
    }

    /// Puts the device's serial on the pasteboard.
    ///
    /// The full value, not the masked one the row shows: masking exists so a serial does not end up
    /// in a screenshot, and someone who pressed Copy is asking for the number itself.
    private func copySerial() {
        let serial = deviceInfo.identity.serialNumber
        guard !serial.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(serial, forType: .string)
    }

    /// Writes the picture controls back to the camera.
    ///
    /// The panel hands over the whole set, so all three colour values go in one request rather than
    /// three — `/Image/channels/N/color` is a single node and writing it once is both fewer round
    /// trips and fewer chances for the camera to be left half-adjusted.
    ///
    /// Sharpness, WDR and the IR cut filter are separate ISAPI nodes with their own write paths and
    /// are not sent yet; the panel shows them read-only until they are.
    private func writeImage(_ settings: InspectorImageSettings) {
        guard let channel = session.camera?.channel else { return }
        Task {
            await deviceInfo.writeImage(channel: channel, settings)
        }
    }

    /// Puts the camera's picture back to its factory settings, and says what happened.
    ///
    /// The reset is a `PUT` to the camera, so it can be refused — by a firmware without the
    /// endpoint, by an account without the permission, or by a device that is simply not reachable
    /// at that moment. Every one of those used to be a log line and nothing else, which is why the
    /// button read as broken: the press produced no picture change and no explanation.
    private func resetImage() {
        guard let channel = session.camera?.channel else {
            window.toast = MainWindowToast(kind: .warning,
                                           message: Self.localized("Connect a camera first"))
            return
        }
        Task {
            switch await deviceInfo.resetImage(channel: channel) {
            case .reset:
                window.toast = MainWindowToast(
                    kind: .success,
                    message: Self.localized("Picture settings reset"))
            case .documentedDefaults:
                window.toast = MainWindowToast(
                    kind: .info,
                    message: Self.localized("This camera has no reset command, so Vigil wrote the "
                                            + "standard picture values instead."))
            case .unchanged:
                window.toast = MainWindowToast(
                    kind: .info,
                    message: Self.localized("The camera accepted the reset and reported the same "
                                            + "settings — its picture was already at the defaults."))
            case .refused(let reason):
                window.toast = MainWindowToast(
                    kind: .error,
                    message: String(format: Self.localized("The camera refused to reset its "
                                                           + "picture settings: %@"),
                                    reason))
            case .unavailable:
                window.toast = MainWindowToast(
                    kind: .warning,
                    message: Self.localized("Connect a camera first"))
            }
        }
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
            destination: recordingsFolderLabel,
            clipsToday: window.clips.count)
    }

    /// The status bar's counters.
    private var chromeStatus: VChromeStatus {
        VChromeStatus(liveCount: session.liveState.isShowingVideo ? 1 : 0,
                      degradedCount: Self.isDegraded(session.liveState) ? 1 : 0,
                      throughput: telemetry.throughput)
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
