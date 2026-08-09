//
//  VigilCommands.swift
//  Vigil
//
//  The menu bar. Every item here is a shortcut the window already answers to.
//  macOS-only. Implements docs/UX.md §11.2 as far as this build's features reach.
//
//  ⛔ NO ITEM THAT DOES NOTHING. §11.2 lists menus for features this build has not written — Import
//  Cameras from CSV, Export Configuration, Open Playback, Cinema Mode, Picture in Picture, the
//  preset submenu, the dwell submenu. They are **absent**, not present-and-dimmed, and that is a
//  deliberate departure from the spec's own note that "items disabled by context show the reason in
//  their tooltip". A tooltip explains why an item cannot act *right now*; it cannot explain that the
//  feature does not exist. A menu of greyed rows for things that will never light up in this build
//  teaches the user the app is broken rather than unfinished.
//
//  ⚠️ The shortcuts here duplicate `MainWindowView.windowShortcuts`, and that is on purpose for now.
//  A menu item's key equivalent and a hidden `Button`'s do not conflict — AppKit routes the menu
//  first — and the hidden buttons still serve the case where the menu bar is not the first
//  responder's path. When every §11.2 menu exists, the hidden buttons go and this file is the only
//  place a shortcut is declared.
//

#if os(macOS)

import SwiftUI

import VigilUI

// MARK: - VigilCommands

/// Vigil's menu bar.
struct VigilCommands: Commands {

    @Environment(\.openWindow) private var openWindow

    /// The app's session. Owned by `VigilApp`, which is what makes it reachable from here at all.
    let session: AppSessionModel

    /// The window's own state, hoisted to the app for the same reason.
    @Bindable var window: MainWindowState

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(MainWindowView.localized("Settings…")) { openWindow(id: SceneID.settings) }
                .keyboardShortcut(",", modifiers: .command)
        }

        // ⌘N would otherwise be File ▸ New Window, which in a single-window app opens a second,
        // camera-less copy of the only screen. Replacing the group both removes that and gives the
        // shortcut to the item §11.2 assigns it.
        CommandGroup(replacing: .newItem) {
            Button(MainWindowView.localized("Add Camera…")) { addCamera() }
                .keyboardShortcut("n", modifiers: .command)
            Button(MainWindowView.localized("Discover Cameras…")) { window.findCamerasRequests &+= 1 }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button(MainWindowView.localized("Open Recordings Folder")) {
                window.openRecordingsFolderRequests &+= 1
            }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button(MainWindowView.localized("Save Snapshot")) { window.snapshotRequests &+= 1 }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(selectedCameraID == nil)
            Button(MainWindowView.localized("Export Diagnostics…")) {
                window.exportDiagnosticsRequests &+= 1
            }
        }

        // A menu of our own, so `Camera` sits where §11.2 puts it rather than being folded into a
        // stock group. Its title goes through the same bundle as every other string in the app.
        CommandMenu(MainWindowView.localized("Camera")) {
            Button(MainWindowView.localized(recordTitle)) { window.recordToggleRequests &+= 1 }
                .keyboardShortcut("r", modifiers: .command)
                // The format is what the recorder needs before the first frame, so this is dimmed
                // for the moment between connecting and the DESCRIBE landing rather than failing.
                .disabled(session.format == nil)
            Divider()
            Button(MainWindowView.localized("Mute All Audio")) { session.muteAllAudio() }
                .keyboardShortcut("m", modifiers: [.shift, .command])
            Button(MainWindowView.localized(isWatching ? "Stop Watching Camera"
                                                        : "Watch Camera")) {
                window.toggleWatchRequests &+= 1
            }
                .disabled(selectedCameraID == nil)
            Divider()
            Button(MainWindowView.localized("Camera Settings…")) { window.sheet = .cameraSettings }
                .disabled(session.camera == nil)
        }

        CommandGroup(before: .toolbar) {
            Button(MainWindowView.localized("Command Palette")) { openPalette() }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
        }

        CommandGroup(after: .toolbar) {
            Menu(MainWindowView.localized("Layout")) {
                ForEach(VGridLayout.allCases, id: \.self) { layout in
                    Button(MainWindowView.layoutTitle(layout)) { selectLayout(layout) }
                        .keyboardShortcut(KeyEquivalent(layout.shortcutDigit), modifiers: .command)
                }
                Divider()
                Button(MainWindowView.localized("Apply First Layout Preset")) { applyFirstPreset() }
                    .keyboardShortcut("9", modifiers: .command)
                    .disabled(window.layoutPresets.presets.isEmpty)
                Button(MainWindowView.localized("Save as Preset…")) {
                    window.sheet = .saveLayoutPreset
                }
                Button(MainWindowView.localized("Manage Presets…")) {
                    window.sheet = .manageLayoutPresets
                }
                    .disabled(window.layoutPresets.presets.isEmpty)
                Button(MainWindowView.localized("Edit Mosaic")) {
                    window.mosaicEditor = VMosaicEditor(tiles: window.layout.cells)
                }
                    .keyboardShortcut("8", modifiers: [.option, .command])
            }
            Button(MainWindowView.localized("Cycle Cameras")) { window.cycle = window.cycle.toggledRunning() }
                .keyboardShortcut("y", modifiers: .command)
            Button(MainWindowView.localized("Next Cycle Interval")) { selectNextCycleInterval() }
                .keyboardShortcut("y", modifiers: [.option, .command])
            Button(MainWindowView.localized("Video Wall")) { openWindow(id: SceneID.wall) }
                .keyboardShortcut("w", modifiers: [.control, .command])
            Button(MainWindowView.localized("Cinema Mode")) { window.isCinemaMode.toggle() }
                .keyboardShortcut("f", modifiers: [.control, .command])
            Menu(MainWindowView.localized("Digital Zoom")) {
                Button(MainWindowView.localized("Zoom In")) { window.digitalViewport.zoom(by: 1.25) }
                    .keyboardShortcut("=", modifiers: .command)
                Button(MainWindowView.localized("Zoom Out")) { window.digitalViewport.zoom(by: 0.8) }
                    .keyboardShortcut("-", modifiers: .command)
                Button(MainWindowView.localized("Reset Zoom")) { window.digitalViewport.reset() }
                    .keyboardShortcut("0", modifiers: .command)
            }
            Divider()
            Button(MainWindowView.localized("Show Sidebar")) { window.isSidebarVisible.toggle() }
                .keyboardShortcut("l", modifiers: .command)
            Button(MainWindowView.localized("Show Inspector")) { window.isInspectorVisible.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }

        // ⛔ Replaced, not added to. SwiftUI's stock Help menu points at a help book this app does
        // not ship, and a Help item that opens an empty window is worse than no Help menu.
        CommandGroup(replacing: .help) {}
    }

    // MARK: - Private Helpers

    /// `Start Recording` or `Stop Recording`.
    ///
    /// From `MainWindowState`'s mirror, not from the coordinator: that lives in the window's
    /// `@State`, and `RecordingTap` — the one piece of it the app can reach — is a lock-guarded box
    /// rather than `@Observable`, so a title read from it would never refresh.
    private var recordTitle: String {
        window.isRecording ? "Stop Recording" : "Start Recording"
    }

    private var isWatching: Bool {
        selectedCameraID.map(window.watchedCameraIDs.contains) ?? false
    }

    private var selectedCameraID: CameraID? {
        window.sidebarSelection.focus.selectedCamera ?? session.camera?.id
    }

    /// The same act as the sidebar's `+`: back to the form, address cleared, account kept.
    private func addCamera() {
        session.disconnect()
        session.form.host = ""
        session.form.password = ""
        session.form.clearDiagnosis()
    }

    /// Opens the palette with an empty highlight, as ⌘K does in the window.
    private func openPalette() {
        window.paletteQuery = ""
        window.paletteSelection = nil
        window.isPaletteOpen = true
    }

    /// Applies a layout and re-anchors the cycle, so a page index cannot survive into a layout with
    /// fewer pages than it. The window's own `selectLayout` does the same; the camera count is not
    /// reachable from here, so the cycle is retargeted against the layout alone.
    private func selectLayout(_ layout: VGridLayout) {
        window.presetCameraOrder = nil
        window.chooseLayout(layout)
        window.cycle = window.cycle.retargeted(cameraCount: 1, layout: layout)
    }

    private func applyFirstPreset() {
        guard let preset = window.layoutPresets.presets.first else { return }
        window.chooseLayout(preset.layout)
        window.presetCameraOrder = preset.cameraIDs.compactMap(UUID.init(uuidString:)).map(CameraID.init)
        window.cycle = window.cycle.retargeted(cameraCount: 1, layout: preset.layout)
    }

    private func selectNextCycleInterval() {
        let intervals = VCycleModel.intervals
        let current = intervals.firstIndex(of: window.cycle.interval) ?? -1
        window.cycle = window.cycle.withInterval(intervals[(current + 1) % intervals.count])
    }
}

#endif  // os(macOS)
