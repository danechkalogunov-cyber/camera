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

    /// Overflow entries with nothing behind them yet, dimmed rather than hidden.
    ///
    /// Removing them would make the menu's shape change as features land, and a user who learned
    /// where Settings sits would find it somewhere else next month.
    var unavailableOverflowItems: Set<VOverflowItem> {
        [.videoWall, .pictureInPicture, .discovery, .streamDoctor, .settings]
    }

    /// Handles an overflow choice. Every item is disabled today, so this only closes the menu.
    func select(_ item: VOverflowItem) {
        window.isOverflowMenuOpen = false
    }

    /// Applies a layout and re-anchors the cycle, so a page index cannot survive into a layout that
    /// has fewer pages than it.
    func selectLayout(_ layout: VGridLayout) {
        window.layout = layout
        window.cycle = window.cycle.retargeted(cameraCount: 1, layout: layout)
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
            window.cycle = window.cycle.next(cameraCount: 1, layout: window.layout)
        }
    }
}

#endif  // os(macOS)
