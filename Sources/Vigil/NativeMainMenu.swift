//
//  NativeMainMenu.swift
//  Vigil
//
//  AppKit menu bar. This intentionally avoids SwiftUI Commands because that surface can
//  re-enter the SwiftUI graph while macOS is opening a menu.
//

#if os(macOS)

import AppKit
import SwiftUI

import VigilUI

@MainActor
struct NativeMainMenuInstaller: NSViewRepresentable {

    private static var applicationCoordinator: Coordinator?

    let session: AppSessionModel
    @Bindable var window: MainWindowState
    let openWindow: OpenWindowAction

    func makeCoordinator() -> Coordinator {
        if let coordinator = Self.applicationCoordinator {
            coordinator.update(session: session, window: window, openWindow: openWindow)
            return coordinator
        }
        let coordinator = Coordinator(session: session, window: window, openWindow: openWindow)
        Self.applicationCoordinator = coordinator
        return coordinator
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        DispatchQueue.main.async { context.coordinator.install() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            context.coordinator.install()
        }
        return NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(session: session, window: window, openWindow: openWindow)
        context.coordinator.install()
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.refreshApplicationState()
    }

    @MainActor
    final class Coordinator: NSObject {

        private var session: AppSessionModel
        private var window: MainWindowState
        private var openWindow: OpenWindowAction
        private weak var previousMenu: NSMenu?
        private var menu: NSMenu?
        private var activationObserver: (any NSObjectProtocol)?

        init(session: AppSessionModel, window: MainWindowState, openWindow: OpenWindowAction) {
            self.session = session
            self.window = window
            self.openWindow = openWindow
            super.init()
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.install()
                    try? await Task.sleep(for: .milliseconds(300))
                    self?.install()
                }
            }
        }

        func update(session: AppSessionModel, window: MainWindowState, openWindow: OpenWindowAction) {
            self.session = session
            self.window = window
            self.openWindow = openWindow
            refresh()
        }

        func install() {
            if let menu {
                if NSApp.mainMenu !== menu { NSApp.mainMenu = menu }
                refresh()
                return
            }
            previousMenu = NSApp.mainMenu
            let newMenu = buildMenu()
            menu = newMenu
            NSApp.mainMenu = newMenu
            refresh()
        }

        func refreshApplicationState() {
            refresh()
        }

        func uninstall() {
            guard let menu, NSApp.mainMenu === menu else { return }
            NSApp.mainMenu = previousMenu
            self.menu = nil
        }

        private func buildMenu() -> NSMenu {
            let root = NSMenu(title: "Vigil")

            let app = NSMenu(title: "Vigil")
            app.addItem(item("About Vigil", #selector(showAbout)))
            app.addItem(.separator())
            app.addItem(item("Settings…", #selector(showSettings), key: ",", modifiers: .command))
            app.addItem(.separator())
            app.addItem(item("Quit Vigil", #selector(quit), key: "q", modifiers: .command))
            root.addItem(submenu("Vigil", app))

            let file = NSMenu(title: "File")
            file.addItem(item("Add Camera…", #selector(addCamera), key: "n", modifiers: .command))
            file.addItem(
                item("Discover Cameras…", #selector(discover), key: "n", modifiers: [.command, .shift]))
            file.addItem(.separator())
            file.addItem(
                item(
                    "Open Recordings Folder", #selector(openRecordings), key: "o",
                    modifiers: [.command, .shift]))
            file.addItem(item("Save Snapshot", #selector(snapshot), key: "s", modifiers: [.command, .shift]))
            file.addItem(
                item(
                    "Snapshot every enabled camera", #selector(snapshotAll), key: "s",
                    modifiers: [.command, .option, .shift]))
            file.addItem(.separator())
            file.addItem(
                item(
                    "Import Cameras from CSV…", #selector(importCameras), key: "i",
                    modifiers: [.command, .shift]))
            file.addItem(
                item(
                    "Export Configuration…", #selector(exportConfiguration), key: "e",
                    modifiers: [.command, .option]))
            file.addItem(item("Export Diagnostics…", #selector(exportDiagnostics)))
            root.addItem(submenu("File", file))

            let camera = NSMenu(title: "Camera")
            camera.addItem(item("Start Recording", #selector(toggleRecording), key: "r", modifiers: .command))
            camera.addItem(
                item("Mute All Audio", #selector(muteAll), key: "m", modifiers: [.command, .shift]))
            camera.addItem(item("Watch Camera", #selector(toggleWatch)))
            camera.addItem(
                item("Stream Doctor…", #selector(streamDoctor), key: "d", modifiers: [.command, .option]))
            camera.addItem(.separator())
            camera.addItem(item("Camera Settings…", #selector(cameraSettings)))
            root.addItem(submenu("Camera", camera))

            let viewMenu = NSMenu(title: "View")
            viewMenu.addItem(
                item("Command Palette", #selector(commandPalette), key: "k", modifiers: .command))
            viewMenu.addItem(.separator())
            let layouts = NSMenu(title: "Layout")
            for layout in VGridLayout.allCases {
                layouts.addItem(
                    item(
                        MainWindowView.layoutTitle(layout),
                        #selector(selectLayout(_:)),
                        key: String(layout.shortcutDigit),
                        modifiers: .command,
                        represented: layout.rawValue))
            }
            layouts.addItem(.separator())
            layouts.addItem(item("Save as Preset…", #selector(savePreset)))
            layouts.addItem(item("Manage Presets…", #selector(managePresets)))
            layouts.addItem(
                item("Edit Mosaic", #selector(editMosaic), key: "8", modifiers: [.command, .option]))
            viewMenu.addItem(submenu("Layout", layouts))
            viewMenu.addItem(item("Cycle Cameras", #selector(toggleCycle), key: "y", modifiers: .command))
            viewMenu.addItem(
                item("Next Cycle Interval", #selector(nextCycle), key: "y", modifiers: [.command, .option]))
            viewMenu.addItem(
                item("Video Wall", #selector(showWall), key: "w", modifiers: [.command, .control]))
            viewMenu.addItem(
                item(
                    "Picture in Picture", #selector(togglePictureInPicture), key: "p",
                    modifiers: [.command, .control]))
            viewMenu.addItem(
                item("Cinema Mode", #selector(toggleCinema), key: "f", modifiers: [.command, .control]))
            let zoom = NSMenu(title: "Digital Zoom")
            zoom.addItem(item("Zoom In", #selector(zoomIn), key: "=", modifiers: .command))
            zoom.addItem(item("Zoom Out", #selector(zoomOut), key: "-", modifiers: .command))
            zoom.addItem(item("Reset Zoom", #selector(resetZoom), key: "0", modifiers: .command))
            viewMenu.addItem(submenu("Digital Zoom", zoom))
            viewMenu.addItem(.separator())
            viewMenu.addItem(item("Show Sidebar", #selector(toggleSidebar), key: "l", modifiers: .command))
            viewMenu.addItem(
                item(
                    "Use Sidebar Rail", #selector(toggleSidebarRail), key: "l",
                    modifiers: [.command, .option]))
            viewMenu.addItem(
                item("Show Inspector", #selector(toggleInspector), key: "i", modifiers: [.command, .option]))
            viewMenu.addItem(
                item("Solo Selected Camera", #selector(toggleSolo), key: "f", modifiers: .command))
            viewMenu.addItem(
                item(
                    "Pin Tile Controls", #selector(togglePinnedControls), key: "h",
                    modifiers: [.command, .control]))
            let overlays = NSMenu(title: "Tile Overlays")
            overlays.addItem(item("Camera Name", #selector(toggleNameOverlay), key: "n", modifiers: .option))
            overlays.addItem(
                item("Stream Statistics", #selector(toggleStatsOverlay), key: "s", modifiers: .option))
            overlays.addItem(
                item("Timestamp", #selector(toggleTimestampOverlay), key: "t", modifiers: .option))
            overlays.addItem(item("Motion", #selector(toggleMotionOverlay), key: "b", modifiers: .option))
            viewMenu.addItem(submenu("Tile Overlays", overlays))
            viewMenu.addItem(
                item("Keyboard Shortcuts", #selector(showShortcuts), key: "/", modifiers: .command))
            root.addItem(submenu("View", viewMenu))

            let windowMenu = NSMenu(title: "Window")
            windowMenu.addItem(item("Open Vigil", #selector(openMain), key: "0", modifiers: .command))
            windowMenu.addItem(item("Playback", #selector(showPlayback)))
            windowMenu.addItem(item("Discovery", #selector(showDiscovery)))
            windowMenu.addItem(item("Video Wall", #selector(showWall)))
            windowMenu.addItem(item("About Vigil", #selector(showAbout)))
            windowMenu.addItem(item("Settings…", #selector(showSettings)))
            root.addItem(submenu("Window", windowMenu))

            let help = NSMenu(title: "Help")
            help.addItem(item("Vigil Help", #selector(showAbout)))
            root.addItem(submenu("Help", help))
            return root
        }

        private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
            let item = NSMenuItem(title: MainWindowView.localized(title), action: nil, keyEquivalent: "")
            item.submenu = menu
            return item
        }

        private func item(
            _ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = [],
            represented: String? = nil
        ) -> NSMenuItem {
            let item = NSMenuItem(title: MainWindowView.localized(title), action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            item.representedObject = represented
            return item
        }

        private func refresh() {
            guard let menu else { return }
            find(menu, action: #selector(toggleRecording))?.title = MainWindowView.localized(
                window.isRecording ? "Stop Recording" : "Start Recording")
            find(menu, action: #selector(toggleWatch))?.title = MainWindowView.localized(
                window.watchedCameraIDs.isEmpty ? "Watch Camera" : "Stop Watching Camera")
            find(menu, action: #selector(toggleSidebar))?.title = MainWindowView.localized(
                window.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
            find(menu, action: #selector(toggleInspector))?.title = MainWindowView.localized(
                window.isInspectorVisible ? "Hide Inspector" : "Show Inspector")
            find(menu, action: #selector(toggleCinema))?.title = MainWindowView.localized(
                window.isCinemaMode ? "Exit Cinema Mode" : "Cinema Mode")
            find(menu, action: #selector(toggleSidebarRail))?.state = window.prefersSidebarRail ? .on : .off
            find(menu, action: #selector(toggleSolo))?.state = window.isSoloed ? .on : .off
            find(menu, action: #selector(togglePinnedControls))?.state = window.pinsTileControls ? .on : .off
            find(menu, action: #selector(toggleNameOverlay))?.state =
                window.tileOverlays.contains(.name) ? .on : .off
            find(menu, action: #selector(toggleStatsOverlay))?.state =
                window.tileOverlays.contains(.stats) ? .on : .off
            find(menu, action: #selector(toggleTimestampOverlay))?.state =
                window.tileOverlays.contains(.timestamp) ? .on : .off
            find(menu, action: #selector(toggleMotionOverlay))?.state =
                window.tileOverlays.contains(.motion) ? .on : .off
            find(menu, action: #selector(snapshot))?.isEnabled =
                window.sidebarSelection.focus.selectedCamera != nil || session.camera != nil
            find(menu, action: #selector(toggleRecording))?.isEnabled = session.format != nil
        }

        private func find(_ menu: NSMenu, action: Selector) -> NSMenuItem? {
            for item in menu.items {
                if item.action == action { return item }
                if let submenu = item.submenu, let found = find(submenu, action: action) { return found }
            }
            return nil
        }

        @objc private func addCamera() {
            session.disconnect()
            session.form.host = ""
            session.form.password = ""
            session.form.clearDiagnosis()
            openMain()
        }
        @objc private func discover() {
            window.findCamerasRequests &+= 1
            openMain()
        }
        @objc private func openRecordings() { window.openRecordingsFolderRequests &+= 1 }
        @objc private func snapshot() {
            window.snapshotRequests &+= 1
            openMain()
        }
        @objc private func snapshotAll() {
            window.deferredRequest = .snapshotAll
            openMain()
        }
        @objc private func importCameras() {
            window.importCamerasRequests &+= 1
            openMain()
        }
        @objc private func exportConfiguration() {
            window.exportConfigurationRequests &+= 1
            openMain()
        }
        @objc private func exportDiagnostics() {
            window.exportDiagnosticsRequests &+= 1
            openMain()
        }
        @objc private func toggleRecording() {
            window.recordToggleRequests &+= 1
            openMain()
        }
        @objc private func muteAll() { session.muteAllAudio() }
        @objc private func toggleWatch() {
            window.toggleWatchRequests &+= 1
            openMain()
        }
        @objc private func cameraSettings() {
            window.sheet = .cameraSettings
            openMain()
        }
        @objc private func streamDoctor() {
            window.streamDoctorRequests &+= 1
            openMain()
        }
        @objc private func commandPalette() {
            window.paletteQuery = ""
            window.paletteSelection = nil
            window.isPaletteOpen = true
            openMain()
        }
        @objc private func selectLayout(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String, let layout = VGridLayout(rawValue: raw)
            else { return }
            window.presetCameraOrder = nil
            window.chooseLayout(layout)
            window.cycle = window.cycle.retargeted(cameraCount: 1, layout: layout)
            openMain()
        }
        @objc private func savePreset() {
            window.sheet = .saveLayoutPreset
            openMain()
        }
        @objc private func managePresets() {
            window.sheet = .manageLayoutPresets
            openMain()
        }
        @objc private func editMosaic() {
            window.mosaicEditor = VMosaicEditor(tiles: window.layout.cells)
            openMain()
        }
        @objc private func toggleCycle() {
            window.cycle = window.cycle.toggledRunning()
            openMain()
        }
        @objc private func nextCycle() {
            let intervals = VCycleModel.intervals
            let current = intervals.firstIndex(of: window.cycle.interval) ?? -1
            window.cycle = window.cycle.withInterval(intervals[(current + 1) % intervals.count])
            openMain()
        }
        @objc private func toggleCinema() {
            window.isCinemaMode.toggle()
            openMain()
        }
        @objc private func togglePictureInPicture() {
            window.pictureInPictureRequests &+= 1
            openMain()
        }
        @objc private func zoomIn() {
            window.digitalViewport.zoom(by: 1.25)
            openMain()
        }
        @objc private func zoomOut() {
            window.digitalViewport.zoom(by: 0.8)
            openMain()
        }
        @objc private func resetZoom() {
            window.digitalViewport.reset()
            openMain()
        }
        @objc private func toggleSidebar() {
            window.isSidebarVisible.toggle()
            openMain()
        }
        @objc private func toggleSidebarRail() {
            window.prefersSidebarRail.toggle()
            openMain()
        }
        @objc private func toggleInspector() {
            window.isInspectorVisible.toggle()
            openMain()
        }
        @objc private func toggleSolo() {
            window.toggleSolo()
            openMain()
        }
        @objc private func togglePinnedControls() {
            window.pinsTileControls.toggle()
            openMain()
        }
        @objc private func toggleNameOverlay() {
            window.tileOverlays.formSymmetricDifference(.name)
            openMain()
        }
        @objc private func toggleStatsOverlay() {
            window.tileOverlays.formSymmetricDifference(.stats)
            openMain()
        }
        @objc private func toggleTimestampOverlay() {
            window.tileOverlays.formSymmetricDifference(.timestamp)
            openMain()
        }
        @objc private func toggleMotionOverlay() {
            window.tileOverlays.formSymmetricDifference(.motion)
            openMain()
        }
        @objc private func showShortcuts() {
            window.sheet = .shortcuts
            openMain()
        }
        @objc private func openMain() {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: SceneID.main)
        }
        @objc private func showMain() { openMain() }
        @objc private func showPlayback() { openWindow(id: SceneID.playback, value: PlaybackRequest.empty) }
        @objc private func showDiscovery() { openWindow(id: SceneID.discovery) }
        @objc private func showWall() { openWindow(id: SceneID.wall) }
        @objc private func showAbout() { openWindow(id: SceneID.about) }
        @objc private func showSettings() { openWindow(id: SceneID.settings) }
        @objc private func quit() { NSApp.terminate(nil) }
    }
}

#endif
