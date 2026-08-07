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

    @Environment(\.openWindow) var openWindow

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

    /// Restarts the live transport as soon as reachability returns or the Mac wakes.
    @State var streamLifecycle = StreamLifecycleMonitor()

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

    /// The same snapshot per camera, for the tiles' stats pills.
    ///
    /// ⚠️ Separate from ``telemetry`` rather than replacing it: the status bar and the Stream tab
    /// describe the *selected* camera and read the one above, while a tile's pill describes the
    /// camera it is drawn over. One dictionary lookup per tile per second is the whole cost.
    @State var measuredTelemetry: [CameraID: StreamTelemetrySnapshot] = [:]

    /// Balanced with `NSCursor.unhide()` when cinema mode ends.
    ///
    /// ⚠️ `internal`: the `.task` that hides and unhides it lives in
    /// `MainWindowView+Lifecycle.swift`, and Swift scopes `private` to a file rather than to a type.
    @State var cinemaCursorHidden = false

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

    /// ⛔ FIVE PIECES, DELIBERATELY. As one expression this is
    ///
    ///     error: the compiler is unable to type-check this expression in reasonable time;
    ///            try breaking up the expression into distinct sub-expressions
    ///
    /// and it is not a close call: the window is a `VStack` of three chunks under roughly forty
    /// modifiers, every `.task`/`.onChange` carries a closure whose types have to be inferred, and
    /// SwiftUI's builders make the whole thing one nested generic type. The solver's cost grows
    /// superlinearly in that chain, so it does not fail gently — it compiles for minutes and then
    /// gives up.
    ///
    /// Splitting is the whole fix, and it took two goes: a first cut into three still left a
    /// `windowChrome` the solver could not finish, because eleven modifiers with four
    /// `@ViewBuilder` overlays is already too much for one expression. The rule this settled on is
    /// four or five modifiers per function, with any overlay whose content is more than a single
    /// property lifted out too — `cinemaBar` is here for that reason and no other.
    ///
    /// Each function takes a view and returns one, so the type checker gets five small problems in
    /// place of one intractable one, and each `let` below pins an opaque type that the next call
    /// starts from rather than re-deriving. Adding a modifier back into `body` brings this back.
    var body: some View {
        let surfaced = windowSurface(windowStack)
        let overlaid = windowOverlays(surfaced)
        let presented = windowPresentations(overlaid)
        let live = windowTasks(presented)
        return windowReactions(live)
    }

    /// The window's three bands: toolbar, columns, status bar.
    ///
    /// Each band is its own property for the reason ``body`` gives: three declarations the solver
    /// can finish are worth more than one it cannot.
    private var windowStack: some View {
        VStack(spacing: 0) {
            if !window.isCinemaMode { toolbarBand }
            columnsBand
            // Only when the list is hidden. `VSidebarView` draws its own footer carrying the same
            // counters (UX.md §3.3), and the mockup puts the status inside the sidebar column rather
            // than across the window — so showing both stacked two status lines on top of each other.
            // The bar is kept for the collapsed case, where the sidebar's footer goes with it.
            if !window.showsSidebar && !window.showsSidebarRail && !window.isCinemaMode {
                statusBand
            }
        }
    }

    /// The toolbar, which is also the title bar.
    private var toolbarBand: some View {
        VToolbarView(isSidebarVisible: window.showsSidebar,
                     isInspectorVisible: window.showsInspector,
                     layout: window.layout,
                     title: identity.name.isEmpty ? Self.layoutTitle(window.layout) : identity.name,
                     searchText: $window.searchText,
                     isCycling: window.cycle.isRunning,
                     cycleInterval: window.cycle.interval,
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
                     blurSearchRequests: window.blurSearchRequests,
                     onToggleSidebar: { window.isSidebarVisible.toggle() },
                     onToggleInspector: { window.isInspectorVisible.toggle() },
                     onSelectLayout: { selectLayout($0) },
                     onToggleCycle: { window.cycle = window.cycle.toggledRunning() },
                     onSelectCycleInterval: { window.cycle = window.cycle.withInterval($0) },
                     onOpenPalette: { openPalette() },
                     onShowMore: { window.isOverflowMenuOpen = true })
    }

    /// Camera list, stage, inspector.
    private var columnsBand: some View {
        HStack(spacing: 0) {
            if window.showsSidebar {
                sidebar
                    .frame(width: VTheme.Metrics.sidebarWidth)
                    .overlay { keyboardRegionRing(.sidebar) }
            } else if window.showsSidebarRail && !window.isCinemaMode {
                sidebarRail
            }

            stageRoute
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(window.digitalViewport.scale)
                .offset(x: window.digitalViewport.offset.width * window.contentWidth,
                        y: window.digitalViewport.offset.height * window.contentWidth)
                // One place, and it reaches every tile on the stage — which is the whole
                // reason this is an environment value rather than an argument threaded through
                // three initialisers.
                .vShowsVideoOverlay(window.showsVideoOverlay)
                // ⌃⌘H, beside the overlay flag and an environment value for the same reason: it has
                // to reach `GridTileView` through `VGridStageView`, which makes no decision about it.
                .vPinsTileControls(window.pinsTileControls)
                // ⌥N ⌥S ⌥T ⌥B — which pieces of chrome, as against `vShowsVideoOverlay`'s whether.
                .vTileOverlays(window.tileOverlays)
                .onHover { hovering in
                    window.cycle = window.cycle.paused(hovering)
                }
                // ⛔ A CLICK ON THE PICTURE TAKES THE CARET OUT OF THE SEARCH FIELD. macOS keeps a
                // text field first responder until something else asks for it, and nothing on the
                // stage is focusable — so after typing in the toolbar's search box the only way out
                // was to click a sidebar row, which also *did* something. Clicking the picture is
                // the natural "never mind" gesture and it now performs it.
                //
                // ⚠️ `simultaneousGesture`, so the stage's own click handling — selecting a tile,
                // scrubbing, double-click to fill — is untouched; and on the stage only, because a
                // blanket window-wide version would resign the connect form's own field on the very
                // click that focused it.
                .simultaneousGesture(TapGesture().onEnded { resignSearchFocus() })
                .vTileActions(tileActions)
                .overlay { keyboardRegionRing(.stage) }

            if window.showsInspector {
                VInspectorView(tab: $window.inspectorTab,
                               state: inspectorState,
                               actions: inspectorActions)
                    .frame(width: VTheme.Metrics.inspectorWidth)
                    .overlay { keyboardRegionRing(.inspector) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The counters, shown only where the sidebar's own footer is not.
    private var statusBand: some View {
        VStatusBarView(status: chromeStatus,
                       onOpenSettings: { window.sheet = .cameraSettings },
                       // The degraded chip is only reachable while something *is* degraded, and the
                       // Info tab is where the reason lives.
                       onShowDegraded: { window.isInspectorVisible = true })
    }

    /// The surface the stack sits on: the canvas, the width probe, the title-bar inset.
    private func windowSurface(_ content: some View) -> some View {
        content
        .background(window.isCinemaMode ? SwiftUI.Color.black : VTheme.Color.Layer.canvas)
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
        // The space the toolbar reports the "…" button's frame in, and the frame itself. Both
        // halves name `VToolbarAnchor.space` so they cannot drift apart.
        .coordinateSpace(name: VToolbarAnchor.space)
        .onPreferenceChange(VToolbarAnchorKey.self) { frame in
            window.overflowAnchor = frame
        }
        // The toolbar *is* the title bar. `WindowChrome` sets `.fullSizeContentView` and nudges the
        // traffic lights down 10 pt so they centre in a 52 pt bar, but SwiftUI still insets content
        // by the title bar's safe area — which left the lights stranded in an empty strip above the
        // toolbar instead of sitting in it. `VToolbarView` already reserves the 79 pt they need.
        .ignoresSafeArea(.container, edges: .top)
    }

    /// What floats over the window: the toast, the cinema-mode bar, the overflow menu, the palette.
    private func windowOverlays(_ content: some View) -> some View {
        content
        .overlay(alignment: .bottom) { toastOverlay }
        .overlay(alignment: .bottom) { cinemaBar }
        .overlay(alignment: .topLeading) { overflowMenu }
        .overlay { paletteOverlay }
    }

    /// The name and the way out, while the chrome is gone.
    @ViewBuilder
    private var cinemaBar: some View {
        if window.isCinemaMode {
            HStack {
                Text(identity.name).lineLimit(1)
                Spacer()
                // ⚠️ `Text(_:bundle:)` in a label closure, not `Button(_:bundle:)`, which does not
                // exist — SwiftUI's `Button` takes `systemImage:`, `image:` or `role:` after the
                // title and nothing else. The bundle matters: every string this app shows is in
                // `VigilUI`'s table, not the app target's.
                Button {
                    window.isCinemaMode = false
                } label: {
                    Text("Exit Cinema Mode", bundle: .vigilUI)
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .background(.ultraThinMaterial)
            .padding(12)
        }
    }

    /// The sheet, and the window-wide keyboard shortcuts.
    private func windowPresentations(_ content: some View) -> some View {
        content
        // A zero-sized button is how a window-wide shortcut is declared in pure SwiftUI. It carries
        // no label and cannot be reached by the pointer or by focus; only ⌘K triggers it.
        .background { windowShortcuts }
        .sheet(item: $window.sheet) { sheet in sheetBody(sheet) }
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

    func updateCameraMetadata(isEnabled: Bool, colorTag: ColorTag) {
        guard let id = session.camera?.id else { return }
        session.camera?.isEnabled = isEnabled
        session.camera?.colorTag = colorTag
        Task {
            await library.setEnabled(isEnabled, for: id)
            await library.setColorTag(colorTag, for: id)
        }
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
    ///
    /// ⛔ TWO THINGS A MENU MUST DO THAT THIS ONE DID NOT. It must close when you click away —
    /// `Esc` and choosing an item were the only ways out, so a menu opened by accident stayed on
    /// screen over the picture and read as a hung window. And it must hang **under its button**:
    /// the trailing inset was one `lg`, while the "…" sits a whole inspector-toggle further in, so
    /// the panel appeared offset from the control that opened it.
    @ViewBuilder
    private var overflowMenu: some View {
        if window.isOverflowMenuOpen {
            ZStack(alignment: .topLeading) {
                // The click-away target. Transparent, fills the window, and swallows the click that
                // dismisses — which is what stops that click also hitting whatever is underneath.
                SwiftUI.Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { window.isOverflowMenuOpen = false }
                VOverflowMenuView(disabledItems: unavailableOverflowItems,
                                  onSelect: { select($0) },
                                  onDismiss: { window.isOverflowMenuOpen = false })
                    // Hung from the button's own measured frame: right edges aligned, `xs` below
                    // it. Arithmetic over the toolbar's padding tokens is what put it in the wrong
                    // place, and any future change to that row would have moved it again.
                    .offset(x: window.overflowAnchor.maxX - VOverflowMetrics.width,
                            y: window.overflowAnchor.maxY + VTheme.Space.xs)
            }
        }
    }

    // MARK: - Identity

    /// Name, address and identity colour for the one camera.
    var identity: LiveCameraIdentity {
        let camera = session.camera
        return LiveCameraIdentity(id: cameraID.rawValue,
                                  name: camera?.displayName ?? session.form.request.host,
                                  host: camera?.host ?? session.form.request.host,
                                  identityIndex: camera?.colorTag.paletteIndex)
    }

    /// The camera's identifier, or the stable placeholder the tile keeps before the record exists.
    var cameraID: CameraID {
        session.camera?.id ?? RootView.pendingCameraID
    }

    /// Takes the keyboard out of whatever text field holds it.
    ///
    /// `makeFirstResponder(nil)` rather than a `@FocusState` write: the search field's focus lives
    /// inside `VToolbarView`, and AppKit's first responder is the fact both it and SwiftUI's focus
    /// are derived from — so this clears the caret wherever it is, including a field this view has
    /// no binding to.
    func resignSearchFocus() {
        window.blurSearchRequests += 1
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
        case .paused:
            // The list says "not running", which is what a stopped camera is. `.offline` would put
            // a countdown and a retry on a row nothing is retrying.
            return .disabled
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
