//
//  MainWindowView+Commands.swift
//  Vigil
//
//  What the window can be told to do: the command palette's catalogue, the overflow menu, the
//  layout picker, recording, and the patrol cycle.
//  macOS-only. Split from MainWindowView.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

#if os(macOS)

import Foundation
import SwiftUI

import VigilCore
import VigilProtocols
import VigilUI

// MARK: - Commands, the overflow menu and the cycle

/// ⚠️ `internal` rather than `private`, for the reason given in `MainWindowView+Library.swift`:
/// `private` reaches a type's extensions only within one file.
extension MainWindowView {

    /// Applies visual zoom and an edge-clamped drag only while zoomed in.
    func digitalViewport(_ content: some View) -> some View {
        content
            .scaleEffect(window.digitalViewport.scale)
            .offset(x: window.digitalViewport.offset.width * window.contentWidth,
                    y: window.digitalViewport.offset.height * window.contentWidth)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let width = max(1, window.contentWidth)
                        window.digitalViewport.panGesture(to: CGSize(
                            width: value.translation.width / width,
                            height: value.translation.height / width))
                    }
                    .onEnded { _ in window.digitalViewport.endPanGesture() },
                including: window.digitalViewport.scale > 1 ? .all : .none)
    }

    /// Reads the picture controls, but only when the Image tab is on screen.
    func loadImageIfShown() async {
        guard window.inspectorTab == .image, let channel = session.camera?.channel else { return }
        await deviceInfo.loadImageSettings(channel: channel)
    }

    /// Asks the camera who it is, once there is a camera to ask.
    ///
    /// Silent when the record does not exist yet — that is the window between pressing Return and
    /// the session storing the camera, and guessing an address there would send a request to the
    /// wrong host.
    func loadDeviceInfo() {
        guard let camera = selectedCamera else { return }
        deviceInfo.load(camera: camera, credentials: session.credentials)
    }

    /// Opens the palette with an empty query.
    ///
    /// Cleared on *open* rather than on close: a query that survived dismissal would silently filter
    /// the next invocation, and the first keystroke would land in the middle of stale text.
    func openPalette() {
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
    var commandCatalogue: [VCommand] {
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
        commands.append(VCommand(id: "capture.snapshot",
                                 title: Self.localized("Snapshot"),
                                 shortcut: "⇧S",
                                 category: .camera,
                                 isEnabled: session.camera != nil))
        commands.append(VCommand(id: "view.cycle",
                                 title: Self.localized("Cycle cameras"),
                                 category: .view,
                                 isEnabled: window.cycle.canCycle(
                                     cameraCount: library.cameras.count,
                                     layout: window.layout)))
        commands.append(VCommand(id: "camera.find",
                                 title: Self.localized("Find Cameras…"),
                                 category: .camera))
        return commands
    }

    /// A command title in the user's language, as a plain `String`.
    ///
    /// `VCommand.title` is a `String` and not a `LocalizedStringKey` on purpose — the ranker folds
    /// and scores individual characters, and a key is opaque to that, so a Russian build would rank
    /// against English text. The lookup therefore happens here, through the same bundle every other
    /// `VigilUI` string uses.
    static func localized(_ key: String) -> String {
        vigilUIString(key)
    }

    /// The layout's name, sharing `VChromeLayoutSwitcher`'s wording so the palette and the toolbar's
    /// tooltip cannot describe the same layout differently.
    static func layoutTitle(_ layout: VGridLayout) -> String {
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
    func run(_ command: VCommand) {
        window.isPaletteOpen = false
        switch command.id {
        case "view.sidebar":   window.isSidebarVisible.toggle()
        case "view.inspector": window.isInspectorVisible.toggle()
        case "view.cycle":     window.cycle = window.cycle.toggledRunning()
        case "record.toggle":  toggleRecording()
        case "capture.snapshot": takeSnapshot()
        case "camera.find":    onFindCameras()
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
    func toggleRecording() {
        if recording.isRecording {
            recording.stop()
            return
        }
        // ⛔ Said, not swallowed. This used to `return` on both guards, so ⌘R and the tile's Record
        // button did nothing at all before the DESCRIBE landed — which is precisely the window in
        // which an eager user presses them. The palette entry is disabled in that state; a keyboard
        // shortcut and a tile button are not, and cannot be without a per-tile enabled set.
        guard let camera = session.camera else {
            window.toast = MainWindowToast(kind: .warning,
                                           message: Self.localized("Connect a camera first"))
            return
        }
        guard let format = session.format else {
            window.toast = MainWindowToast(
                kind: .info,
                message: Self.localized("Recording starts once the stream's format is known. "
                                        + "Try again in a moment."))
            return
        }
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

    // MARK: - Keyboard

    /// Every shortcut the main window owns, as zero-sized buttons behind it.
    ///
    /// A hidden `Button` carrying a `.keyboardShortcut` is how a window-wide shortcut is declared in
    /// pure SwiftUI: it has no label, the pointer and focus cannot reach it, and only the key
    /// combination fires it. The real menu bar (UX.md §11.2, `VigilCommands`) is W6 and will
    /// eventually own these; until it does, this is where they live, and moving them will be a
    /// deletion rather than a rewrite.
    ///
    /// ⛔ Gathered here rather than inline in `body`, which had grown past the 600-line ceiling
    /// DESIGN.md §7.2 sets for a file. Twelve of these were specified in §11.1 and never bound —
    /// every one of them naming a function this window already had and only a mouse could reach.
    @ViewBuilder
    var windowShortcuts: some View {
        Group {
            Button("", action: { openPalette() })
                .keyboardShortcut("k", modifiers: .command)
            Button("", action: { toggleRecording() })
                .keyboardShortcut("r", modifiers: .command)
            Button("", action: { window.sheet = .newBookmark(markableInstant) })
                .keyboardShortcut("d", modifiers: .command)
            Button("", action: { takeSnapshot() })
                .keyboardShortcut("s", modifiers: [.command, .shift])
            // ↑/↓ walk the list. Declared here rather than on the sidebar because the panel is a
            // `ScrollView` over a `LazyVStack` — chosen so DESIGN.md §9.12's row surface could be
            // drawn at all — and that gives up the system list's own keyboard handling.
            Button("", action: { stepSidebar(-1) })
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("", action: { stepSidebar(1) })
                .keyboardShortcut(.downArrow, modifiers: [])
            Button("", action: {
                window.sidebarSelection.selectAll(in: sidebarTree.visibleCameras)
            })
                .keyboardShortcut("a", modifiers: .command)
            // UX.md §4: `/` moves the cursor to the toolbar's search field. `VToolbarView` has taken
            // a `focusSearchRequests` counter since it was written — the field's `@FocusState`
            // cannot be lifted out without making the whole view generic — and nothing ever
            // incremented it, so the `/` key cap drawn inside the field advertised a shortcut that
            // did not exist.
            Button("", action: { window.focusSearchRequests &+= 1 })
                .keyboardShortcut("/", modifiers: [])
        }
        .hidden()
        // A second `Group`: SwiftUI's `ViewBuilder` takes at most ten children, and §11.1 asks for
        // more than ten. Splitting is the documented way and costs nothing at runtime.
        Group {
            Button("", action: { window.isSidebarVisible.toggle() })
                .keyboardShortcut("l", modifiers: .command)
            Button("", action: { window.isInspectorVisible.toggle() })
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("", action: { window.cycle = window.cycle.toggledRunning() })
                .keyboardShortcut("y", modifiers: .command)
            Button("", action: { addCamera() })
                .keyboardShortcut("n", modifiers: .command)
            Button("", action: { onFindCameras() })
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("", action: { openRecordingsFolder() })
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("", action: { cycleKeyboardRegion(forward: true) })
                .keyboardShortcut(.tab, modifiers: [])
            Button("", action: { cycleKeyboardRegion(forward: false) })
                .keyboardShortcut(.tab, modifiers: .shift)
            Button("", action: { window.isCinemaMode.toggle() })
                .keyboardShortcut("f", modifiers: [.control, .command])
            Button("", action: { session.muteAllAudio() })
                .keyboardShortcut("m", modifiers: [.shift, .command])
        }
        .hidden()
        layoutShortcuts
        inspectorTabShortcuts
        Group {
            Button("", action: { window.digitalViewport.zoom(by: 1.25) })
                .keyboardShortcut("=", modifiers: .command)
            Button("", action: { window.digitalViewport.zoom(by: 0.8) })
                .keyboardShortcut("-", modifiers: .command)
            Button("", action: { window.digitalViewport.reset() })
                .keyboardShortcut("0", modifiers: .command)
            Button("", action: {
                window.mosaicEditor = VMosaicEditor(tiles: window.layout.cells)
            }).keyboardShortcut("8", modifiers: [.option, .command])
            Button("", action: {
                if let first = window.layoutPresets.presets.first { applyLayoutPreset(first) }
            }).keyboardShortcut("9", modifiers: .command)
            Button("", action: { selectNextCycleInterval() })
                .keyboardShortcut("y", modifiers: [.option, .command])
        }.hidden()
        accessibilityShortcuts
    }

    /// The four §11.1 keys that were listed as "waiting for features that do not exist" and were
    /// not: every one of them had its behaviour already built and no way to reach it.
    ///
    /// A fourth `Group` for `ViewBuilder`'s ten-child ceiling, like the three above it.
    @ViewBuilder
    private var accessibilityShortcuts: some View {
        Group {
            // ⌥⌘L — the icon rail (UX.md §2.3). `VSidebarView` has had a rail since the narrow-window
            // rule landed; nothing let the user ask for one at a comfortable width.
            Button("", action: { window.prefersSidebarRail.toggle() })
                .keyboardShortcut("l", modifiers: [.option, .command])
            // ⌘F — solo the selected tile, and ⌘F again to put the layout back (UX.md §5.8).
            Button("", action: { window.toggleSolo() })
                .keyboardShortcut("f", modifiers: .command)
            // ⌃⌘H — pin the selected tile's controls, which is the *only* way a keyboard-only user
            // reaches snapshot, record, fit/fill and close (UX.md §6.2).
            Button("", action: { window.pinsTileControls.toggle() })
                .keyboardShortcut("h", modifiers: [.control, .command])
            // ⌥⇧⌘S — capture every enabled camera (FEATURES.md §F-CAP-02 acceptance 1). The
            // sequential capture behind it has existed since the deep link `vigil://snapshot-all`
            // was wired; the key was never bound and the menu never offered it.
            Button("", action: { snapshotAllEnabledCameras() })
                .keyboardShortcut("s", modifiers: [.option, .shift, .command])
            // ⌘/ — the cheat sheet. Every other shortcut in this file is discoverable only by
            // reading UX.md §11.1, which the customer does not have.
            Button("", action: { window.sheet = .shortcuts })
                .keyboardShortcut("/", modifiers: .command)
        }
        .hidden()
        Group {
            // ⌥N ⌥S ⌥T ⌥B — View ▸ Tile Overlays. One switch per piece, because §11.1 gives each its
            // own key: the stats readout is for diagnosing a stream and noise the rest of the time,
            // while the name chip is what tells you which camera you are looking at.
            Button("", action: { window.tileOverlays.formSymmetricDifference(.name) })
                .keyboardShortcut("n", modifiers: .option)
            Button("", action: { window.tileOverlays.formSymmetricDifference(.stats) })
                .keyboardShortcut("s", modifiers: .option)
            Button("", action: { window.tileOverlays.formSymmetricDifference(.timestamp) })
                .keyboardShortcut("t", modifiers: .option)
            Button("", action: { window.tileOverlays.formSymmetricDifference(.motion) })
                .keyboardShortcut("b", modifiers: .option)
            // ⌥⌘F — the camera-list filter. `VSidebarFilter` has been complete since the sidebar
            // landed; every call site built its search with the default `.all`, so the list could be
            // narrowed by text and by nothing else.
            Button("", action: { selectNextSidebarFilter() })
                .keyboardShortcut("f", modifiers: [.option, .command])
        }
        .hidden()
        Group {
            // ⇧⌘I, ⌥⌘E, ⌥⌘D — the three File/Help commands whose machinery shipped without a door:
            // `CameraCSVImporter`, `ConfigurationArchiveCodec` and the Stream Doctor prefix behind
            // the connect form's Test button. All three were written, tested and reachable from
            // nothing.
            Button("", action: { importCamerasFromCSV() })
                .keyboardShortcut("i", modifiers: [.shift, .command])
            Button("", action: { exportConfiguration() })
                .keyboardShortcut("e", modifiers: [.option, .command])
            Button("", action: { runStreamDoctor() })
                .keyboardShortcut("d", modifiers: [.option, .command])
            Button("", action: { togglePictureInPicture() })
                .keyboardShortcut("p", modifiers: [.control, .command])
        }
        .hidden()
        // `Esc` leaves solo, per §5.8 — but only when the timeline is away, because the scrubber's
        // overlay binds the same key to dismissing itself and two `.cancelAction`s in one window is
        // a coin toss. With the timeline up, ⌘F is still the way out.
        if window.isSoloed && !window.showsTimeline {
            Button("", action: { window.exitSolo() })
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
    }

    /// ⌥⇧⌘S: every **enabled** camera, which is what F-CAP-02 acceptance 1 asks for.
    ///
    /// ⚠️ Enabled, not "all". A camera the user has switched off in its settings is one they have
    /// said they do not want Vigil talking to; a snapshot-all that dials it anyway would be the app
    /// overriding a preference on the user's behalf, and on a camera that is off because it is
    /// unreachable it would mean waiting out a connect timeout per row.
    func snapshotAllEnabledCameras() {
        snapshotCameras(library.cameras.filter(\.isEnabled))
    }

    /// ⌥⌘F walks the five filters, the way ⌥⌘Y walks the dwell intervals.
    ///
    /// ⚠️ A cycle rather than a menu, and that is a deliberate reduction of §11.1's "open the filter
    /// menu". A key that opens a menu needs the menu to exist and to be anchored to something on
    /// screen; a key that steps through five named states needs neither, works from the keyboard
    /// alone, and — crucially — is honest about what it does. The menu belongs with the sidebar's
    /// own chrome, which is where UX.md draws it; this is the binding that makes the model
    /// reachable in the meantime, and the sidebar shows which filter is on.
    func selectNextSidebarFilter() {
        let filters = VSidebarFilter.allCases
        let current = filters.firstIndex(of: window.sidebarFilter) ?? -1
        window.sidebarFilter = filters[(current + 1) % filters.count]
    }

    /// ⌥⌘Y walks the same finite dwell menu shown by the toolbar.
    func selectNextCycleInterval() {
        let intervals = VCycleModel.intervals
        let current = intervals.firstIndex(of: window.cycle.interval) ?? -1
        window.cycle = window.cycle.withInterval(intervals[(current + 1) % intervals.count])
    }

    func cycleKeyboardRegion(forward: Bool) {
        guard window.isFullKeyboardAccessEnabled else { return }
        let visible: [MainWindowState.KeyboardRegion] = [
            window.showsSidebar ? .sidebar : nil,
            .stage,
            window.showsInspector ? .inspector : nil,
        ].compactMap { $0 }
        guard let index = visible.firstIndex(of: window.keyboardRegion) else {
            window.keyboardRegion = visible[0]
            return
        }
        window.keyboardRegion = visible[(index + (forward ? 1 : visible.count - 1)) % visible.count]
    }

    /// ⌘1 … ⌘8 select a layout (UX.md §11.1).
    ///
    /// ⚠ The digit is not the tile count — `⌘2` is the four-tile grid and `⌘3` the six-tile hero —
    /// and that mapping is `VGridLayout.shortcutDigit`'s, not restated here. Deriving the shortcut
    /// from the layout rather than writing eight literals is what stops the two drifting apart.
    @ViewBuilder
    private var layoutShortcuts: some View {
        ForEach(VGridLayout.allCases, id: \.self) { layout in
            Button("", action: { selectLayout(layout) })
                .keyboardShortcut(KeyEquivalent(layout.shortcutDigit), modifiers: .command)
        }
        .hidden()
    }

    /// ⌃1 … ⌃6 select an inspector tab (UX.md §11.1).
    ///
    /// The tab is also revealed by the shortcut: a key that changed a hidden panel's tab and left it
    /// hidden would look broken, and the user pressing ⌃3 wants to see PTZ, not to arrange for it to
    /// be there later.
    @ViewBuilder
    private var inspectorTabShortcuts: some View {
        ForEach(Array(VInspectorTab.allCases.enumerated()), id: \.element) { index, tab in
            Button("", action: {
                window.inspectorTab = tab
                window.isInspectorVisible = true
            })
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
        }
        .hidden()
    }

    /// Overflow entries that cannot run for the currently selected camera.
    ///
    /// Removing them would make the menu's shape change as features land, and a user who learned
    /// where Settings sits would find it somewhere else next month.
    ///
    /// ⛔ `.discovery` left this set, and it should have left it when `VigilDiscovery` landed. The
    /// coordinator, the sockets, the sheet and the model are all written and CI-tested, and the only
    /// way into them was the connect form's *Find Cameras* button — reachable exactly when the user
    /// has no camera, and gone the moment they have one. That is the opposite of when somebody looks
    /// for a second device.
    ///
    var unavailableOverflowItems: Set<VOverflowItem> {
        []
    }

    /// Handles an overflow choice.
    func select(_ item: VOverflowItem) {
        window.isOverflowMenuOpen = false
        switch item {
        case .discovery: onFindCameras()
        case .pictureInPicture: togglePictureInPicture()
        case .videoWall: openWindow(id: SceneID.wall)
        case .streamDoctor:
            guard let camera = selectedCamera else { return }
            beginStreamDoctor(camera: camera)
        case .settings: openWindow(id: SceneID.settings)
        }
    }

    /// Floats the selected live camera in the one process-wide PiP panel.
    func togglePictureInPicture() {
        guard let camera = selectedCamera,
              let stream = session.cameras.stream(for: camera.id), stream.isActive else {
            window.toast = MainWindowToast(kind: .warning,
                                           message: Self.localized("Connect a camera first"))
            return
        }
        session.pictureInPicture.toggle(camera: camera, stream: stream, session: session)
    }

    /// Applies a layout and re-anchors the cycle, so a page index cannot survive into a layout that
    /// has fewer pages than it.
    func selectLayout(_ layout: VGridLayout) {
        // Through `chooseLayout`, so an explicit choice also ends solo — see `layoutBeforeSolo`.
        window.presetCameraOrder = nil
        window.chooseLayout(layout)
        window.cycle = window.cycle.retargeted(cameraCount: library.cameras.count, layout: layout)
    }

    func applyLayoutPreset(_ preset: VLayoutPreset) {
        window.chooseLayout(preset.layout)
        window.presetCameraOrder = preset.cameraIDs.compactMap(UUID.init(uuidString:)).map(CameraID.init)
        window.cycle = window.cycle.retargeted(cameraCount: stageOrder.count, layout: preset.layout)
    }

    /// What restarts the cycle timer: whether it is ticking, how fast, and over what.
    ///
    /// A value rather than a `Bool`, so changing the interval or the layout mid-cycle restarts the
    /// sleep instead of waiting out the old one.
    var cycleTick: CycleTick {
        CycleTick(isTicking: window.cycle.isTicking,
                  interval: window.cycle.interval,
                  layout: window.layout)
    }

    /// The cycle's clock. The model is pure and holds no timer — this is the only thing that ticks.
    func runCycle() async {
        while !Task.isCancelled, window.cycle.isTicking {
            let nanoseconds = UInt64(window.cycle.interval * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return                  // cancelled: the task id changed, or the view went away
            }
            guard !Task.isCancelled else { return }
            // ⛔ `library.cameras.count`, not the `1` that used to be hard-coded here. With one
            // camera `pageCount` is 1, `next` returns the same page every time, and the cycle
            // advanced through nothing for as long as it was switched on — which is what the
            // toolbar's spinning ring was reporting. It was right when the app held one camera and
            // wrong from the moment the library landed.
            window.cycle = window.cycle.next(cameraCount: library.cameras.count,
                                             layout: window.layout)
            await showCyclePage()
        }
    }

    /// Brings the cycle's current page onto the stage — the whole page, not its first camera.
    ///
    /// ⛔ IT USED TO TAKE `range.first` AND STOP THERE. That was the honest limit of a build with one
    /// `StreamController`: a 2 × 2 patrol advanced through four-camera pages showing one picture and
    /// three *Add camera* placeholders, and the ring in the toolbar reported progress through pages
    /// the user never saw. `F-LIV-06`'s open item is exactly this, and `AppSessionModel.showOnStage`
    /// is what F-LIV-01 made possible.
    ///
    /// ⚠️ A reconnect per step is still what an advance costs — roughly 1.2 s to a first frame on
    /// this device (docs/PLAYBACK-LATENCY.md) — and nothing here pre-warms the next page. Pre-warming
    /// means holding two pages of sessions at once, which is what the device's own session limit
    /// refuses (three on a DS-I256) and what `VCycleModel`'s 2 s floor exists to keep away from.
    ///
    /// The page can be wider than the concurrency budget — a 4 × 4 layout names sixteen cameras and
    /// `maxConcurrentStreams` is four — and `showOnStage` fills the cells in order until the budget
    /// is spent. That is a placeholder's behaviour, and it is `F-DEC-06` that replaces the number
    /// with a measured admission policy.
    private func showCyclePage() async {
        let cameras = library.cameras
        let range = window.cycle.visibleRange(cameraCount: cameras.count, layout: window.layout)
        await session.showOnStage(range.compactMap { index in
            cameras.indices.contains(index) ? cameras[index] : nil
        })
    }
}

#endif  // os(macOS)
