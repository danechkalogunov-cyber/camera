//
//  MainWindowView+Commands.swift
//  Vigil
//
//  What the window can be told to do: the command palette's catalogue, the overflow menu, the
//  layout picker, recording, and the patrol cycle.
//  macOS-only. Split from MainWindowView.swift, which docs/DESIGN.md §7.2 caps at 600 lines.
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
        guard let camera = session.camera else { return }
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
        }
        .hidden()
        layoutShortcuts
        inspectorTabShortcuts
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

    /// Overflow entries with nothing behind them yet, dimmed rather than hidden.
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
    /// The other four stay dimmed and are not given "not in this build" toasts: an item in a menu
    /// can be genuinely disabled, which says the same thing without spending a click to say it.
    var unavailableOverflowItems: Set<VOverflowItem> {
        [.videoWall, .pictureInPicture, .streamDoctor, .settings]
    }

    /// Handles an overflow choice.
    func select(_ item: VOverflowItem) {
        window.isOverflowMenuOpen = false
        guard item == .discovery else { return }
        onFindCameras()
    }

    /// Applies a layout and re-anchors the cycle, so a page index cannot survive into a layout that
    /// has fewer pages than it.
    func selectLayout(_ layout: VGridLayout) {
        window.layout = layout
        window.cycle = window.cycle.retargeted(cameraCount: library.cameras.count, layout: layout)
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

    /// Brings the camera the cycle's current page names onto the stage.
    ///
    /// ⚠️ A RECONNECT PER STEP, AND THAT IS WHAT A ONE-STREAM BUILD CAN HONESTLY DO. `switchTo`
    /// stops the current session and opens another, so each advance costs the ~1.2 s this device
    /// takes to reach a first frame (docs/PLAYBACK-LATENCY.md). At the 10 s default dwell that is a
    /// tenth of the interval; at the 2 s floor `VCycleModel` clamps to, it would be most of it,
    /// which is why that floor exists and why this does not try to pre-warm the next page. Pre-warm
    /// means holding two sessions, and holding two sessions is the multi-camera work this build has
    /// not done.
    ///
    /// `.single` is the layout this matters in — one page per camera — but nothing here assumes it:
    /// `visibleRange` is asked for the page's indices and the first is taken, so a 2 × 2 page of
    /// four cameras streams the first of the four rather than silently doing nothing.
    private func showCyclePage() async {
        let cameras = library.cameras
        let range = window.cycle.visibleRange(cameraCount: cameras.count, layout: window.layout)
        guard let index = range.first, cameras.indices.contains(index) else { return }
        let target = cameras[index]
        guard target.id != session.camera?.id else { return }
        await session.switchTo(target)
    }
}

#endif  // os(macOS)
