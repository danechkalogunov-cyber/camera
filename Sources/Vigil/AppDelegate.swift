//
//  AppDelegate.swift
//  Vigil
//
//  The few application-lifecycle behaviours SwiftUI has no modifier for: quitting with the last
//  window, and coming back from the Dock.
//  macOS-only. See docs/API_CONTRACT.md §4.12 and §5.14.
//

#if os(macOS)

import AppKit
import UserNotifications

import VigilUI

// MARK: - AppDelegate

/// The slice's application delegate.
///
/// Owns process-level application and notification behaviour. Stream sleep/wake remains with the
/// window's session lifecycle, where all active camera paths and recorders are available together.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Keep the process available from its menu-bar extra after the last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Bring the window back when the Dock icon is clicked with no visible window.
    ///
    /// Returning `true` lets AppKit restore the `WindowGroup`'s window itself; returning `false`
    /// would leave the click doing nothing at all.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        true
    }

    /// Put the window in front on launch.
    ///
    /// A bundled app is already `.regular`, but a binary run straight from `swift build` output —
    /// which is exactly how this gets tested first — launches behind the terminal without this.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `activate()`, not `activate(ignoringOtherApps:)`: the latter is deprecated on macOS 14,
        // which is this app's floor.
        NSApplication.shared.activate()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let actions = [
            UNNotificationAction(identifier: CameraNotificationCenter.viewLiveAction,
                                 title: vigilUIString("View Live")),
            UNNotificationAction(identifier: CameraNotificationCenter.playBackAction,
                                 title: vigilUIString("Play Back")),
        ]
        center.setNotificationCategories([
            UNNotificationCategory(identifier: CameraNotificationCenter.eventCategory,
                                   actions: actions, intentIdentifiers: []),
            UNNotificationCategory(identifier: CameraNotificationCenter.cameraLostCategory,
                                   actions: [actions[0]], intentIdentifiers: []),
        ])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        let info = response.notification.request.content.userInfo
        guard let cameraID = info["cameraID"] as? String else { return }
        let text: String
        if response.actionIdentifier == CameraNotificationCenter.playBackAction,
           let seconds = info["occurredAt"] as? TimeInterval {
            let instant = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
            text = "vigil://playback/\(cameraID)?t=\(instant)"
        } else {
            text = "vigil://camera/\(cameraID)?action=live"
        }
        guard let url = URL(string: text) else { return }
        Task { @MainActor in NSWorkspace.shared.open(url) }
    }
}

#endif  // os(macOS)
