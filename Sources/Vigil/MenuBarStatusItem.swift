//
//  MenuBarStatusItem.swift
//  Vigil
//
//  Native AppKit menu-bar integration. SwiftUI's MenuBarExtra re-enters menu graph updates on
//  macOS 26, so this surface deliberately uses NSStatusItem and NSMenu instead.
//

#if os(macOS)

import AppKit
import SwiftUI

import VigilUI

@MainActor
struct MenuBarStatusItemInstaller: NSViewRepresentable {

    private static var applicationCoordinator: Coordinator?

    let session: AppSessionModel
    @Bindable var window: MainWindowState
    let isVisible: Bool
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
        context.coordinator.setVisible(isVisible)
        return NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(session: session, window: window, openWindow: openWindow)
        context.coordinator.setVisible(isVisible)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.updateAppearanceForApplication()
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {

        private var session: AppSessionModel
        private var window: MainWindowState
        private var openWindow: OpenWindowAction
        private var statusItem: NSStatusItem?
        private weak var recordItem: NSMenuItem?
        private weak var camerasMenu: NSMenu?

        init(session: AppSessionModel, window: MainWindowState, openWindow: OpenWindowAction) {
            self.session = session
            self.window = window
            self.openWindow = openWindow
        }

        func update(
            session: AppSessionModel,
            window: MainWindowState,
            openWindow: OpenWindowAction
        ) {
            self.session = session
            self.window = window
            self.openWindow = openWindow
            updateAppearance()
        }

        func setVisible(_ visible: Bool) {
            if visible {
                installIfNeeded()
            } else if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
                recordItem = nil
                camerasMenu = nil
            }
        }

        func menuWillOpen(_ menu: NSMenu) {
            rebuildCameraMenu()
            updateAppearance()
        }

        func updateAppearanceForApplication() {
            updateAppearance()
        }

        private func installIfNeeded() {
            guard statusItem == nil else {
                updateAppearance()
                return
            }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(
                systemSymbolName: "video.badge.waveform", accessibilityDescription: "Vigil")
            item.button?.toolTip = "Vigil"
            item.menu = makeMenu()
            statusItem = item
            updateAppearance()
        }

        private func makeMenu() -> NSMenu {
            let menu = NSMenu(title: "Vigil")
            menu.delegate = self
            menu.addItem(item("Open Vigil", action: #selector(openVigil), key: ""))
            let cameraMenu = NSMenu(title: MainWindowView.localized("Cameras"))
            camerasMenu = cameraMenu
            let cameras = NSMenuItem(
                title: MainWindowView.localized("Cameras"), action: nil, keyEquivalent: "")
            cameras.submenu = cameraMenu
            menu.addItem(cameras)
            menu.addItem(.separator())
            menu.addItem(item("Snapshot every enabled camera", action: #selector(snapshotAll)))
            let recording = item("Start Recording", action: #selector(toggleRecording))
            menu.addItem(recording)
            recordItem = recording
            menu.addItem(.separator())
            menu.addItem(item("Discover Cameras…", action: #selector(discover)))
            menu.addItem(item("Playback", action: #selector(playback)))
            menu.addItem(item("Video Wall", action: #selector(videoWall)))
            menu.addItem(item("Mute All Audio", action: #selector(muteAll)))
            menu.addItem(item("Disconnect", action: #selector(disconnect)))
            menu.addItem(.separator())
            menu.addItem(item("Settings…", action: #selector(settings)))
            menu.addItem(item("About Vigil", action: #selector(about)))
            menu.addItem(.separator())
            menu.addItem(item("Quit Vigil", action: #selector(quit), key: "q"))
            rebuildCameraMenu()
            return menu
        }

        private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
            let item = NSMenuItem(
                title: MainWindowView.localized(title), action: action, keyEquivalent: key)
            item.target = self
            return item
        }

        private func updateAppearance() {
            recordItem?.title = MainWindowView.localized(
                window.isRecording ? "Stop Recording" : "Start Recording")
            let badge = MenuBarBadgeState.resolve(
                streams: session.cameras.all,
                isRecording: window.isRecording,
                unreadEvents: window.unreadEventCount)
            let symbol: String
            let toolTip: String
            switch badge {
            case .offline(let count):
                symbol = "video.slash.fill"
                toolTip = "Vigil — \(count) offline"
            case .degraded:
                symbol = "exclamationmark.triangle.fill"
                toolTip = "Vigil — degraded"
            case .recording(let count):
                symbol = "record.circle.fill"
                toolTip = "Vigil — \(count) recording"
            case .unread(let count):
                symbol = "bell.badge.fill"
                toolTip = "Vigil — \(count) unread"
            case .nominal:
                symbol = "video.badge.waveform"
                toolTip = "Vigil"
            }
            statusItem?.button?.image = NSImage(
                systemSymbolName: symbol, accessibilityDescription: "Vigil")
            statusItem?.button?.toolTip = toolTip
        }

        private func rebuildCameraMenu() {
            guard let camerasMenu else { return }
            camerasMenu.removeAllItems()
            let streams = session.cameras.all.sorted {
                ($0.camera?.displayName ?? "") < ($1.camera?.displayName ?? "")
            }
            guard !streams.isEmpty else {
                let empty = NSMenuItem(
                    title: MainWindowView.localized("No cameras yet"),
                    action: nil,
                    keyEquivalent: "")
                empty.isEnabled = false
                camerasMenu.addItem(empty)
                return
            }
            for stream in streams.prefix(8) {
                guard let camera = stream.camera else { continue }
                let row = NSMenuItem(
                    title: "\(statusMark(stream.liveState))  \(camera.displayName)",
                    action: #selector(selectCamera(_:)),
                    keyEquivalent: "")
                row.target = self
                row.representedObject = camera.id.rawValue.uuidString
                row.state = camera.id == session.camera?.id ? NSControl.StateValue.on : .off
                camerasMenu.addItem(row)
            }
            if streams.count > 8 {
                camerasMenu.addItem(.separator())
                let more = NSMenuItem(
                    title: MainWindowView.localized("Open Vigil"),
                    action: #selector(openVigil),
                    keyEquivalent: "")
                more.target = self
                camerasMenu.addItem(more)
            }
        }

        private func statusMark(_ state: LiveConnectionState) -> String {
            switch state {
            case .live: "●"
            case .degraded: "◐"
            case .connecting: "◌"
            case .offline: "○"
            case .paused: "Ⅱ"
            case .noRecording: "—"
            }
        }

        @objc private func openVigil() {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: SceneID.main)
            NSApp.windows.first(where: \.canBecomeMain)?.makeKeyAndOrderFront(nil)
        }

        @objc private func selectCamera(_ sender: NSMenuItem) {
            guard
                let raw = sender.representedObject as? String,
                let uuid = UUID(uuidString: raw),
                let camera = session.cameras.all.compactMap(\.camera).first(where: {
                    $0.id.rawValue == uuid
                })
            else { return }
            openVigil()
            Task { await session.switchTo(camera) }
        }

        @objc private func snapshotAll() {
            window.deferredRequest = .snapshotAll
            openVigil()
        }

        @objc private func toggleRecording() {
            window.deferredRequest = .recordToggle
            openVigil()
        }

        @objc private func discover() {
            window.deferredRequest = .discover
            openVigil()
        }

        @objc private func playback() {
            openWindow(id: SceneID.playback, value: PlaybackRequest.empty)
        }

        @objc private func videoWall() {
            openWindow(id: SceneID.wall)
        }

        @objc private func settings() {
            openWindow(id: SceneID.settings)
        }

        @objc private func about() {
            openWindow(id: SceneID.about)
        }

        @objc private func muteAll() {
            session.muteAllAudio()
        }

        @objc private func disconnect() {
            session.disconnect()
        }

        @objc private func quit() {
            NSApp.terminate(nil)
        }
    }
}

#endif  // os(macOS)
