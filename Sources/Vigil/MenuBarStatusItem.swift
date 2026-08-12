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

@MainActor
struct MenuBarStatusItemInstaller: NSViewRepresentable {

    let session: AppSessionModel
    @Bindable var window: MainWindowState
    let isVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, window: window)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.setVisible(isVisible)
        return NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(session: session, window: window)
        context.coordinator.setVisible(isVisible)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.setVisible(false)
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {

        private var session: AppSessionModel
        private var window: MainWindowState
        private var statusItem: NSStatusItem?
        private weak var recordItem: NSMenuItem?

        init(session: AppSessionModel, window: MainWindowState) {
            self.session = session
            self.window = window
        }

        func update(session: AppSessionModel, window: MainWindowState) {
            self.session = session
            self.window = window
            updateAppearance()
        }

        func setVisible(_ visible: Bool) {
            if visible {
                installIfNeeded()
            } else if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
                recordItem = nil
            }
        }

        func menuWillOpen(_ menu: NSMenu) {
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
            menu.addItem(.separator())
            menu.addItem(item("Snapshot every enabled camera", action: #selector(snapshotAll)))
            let recording = item("Start Recording", action: #selector(toggleRecording))
            menu.addItem(recording)
            recordItem = recording
            menu.addItem(.separator())
            menu.addItem(item("Discover Cameras…", action: #selector(discover)))
            menu.addItem(item("Mute All Audio", action: #selector(muteAll)))
            menu.addItem(item("Disconnect", action: #selector(disconnect)))
            menu.addItem(.separator())
            menu.addItem(item("Quit Vigil", action: #selector(quit), key: "q"))
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
            let offline = session.cameras.all.filter {
                if case .offline = $0.liveState { return true }
                return false
            }.count
            statusItem?.button?.appearsDisabled = offline > 0
            statusItem?.button?.toolTip =
                offline > 0
                ? "Vigil — \(offline) offline"
                : "Vigil"
        }

        @objc private func openVigil() {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            NSApp.windows.first(where: \.canBecomeMain)?.makeKeyAndOrderFront(nil)
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
