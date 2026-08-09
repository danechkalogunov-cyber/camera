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

// MARK: - AppDelegate

/// The slice's application delegate.
///
/// The manifest's W6 delegate also handles sleep/wake, the Dock badge and a two-second termination
/// budget for finalising recordings (docs/API_CONTRACT.md §5.14). None of that applies yet: the
/// slice records nothing, and `StreamController` tears its socket down when the process exits. What
/// is here is what a one-window viewer gets wrong without it.
final class AppDelegate: NSObject, NSApplicationDelegate {

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
    }
}

#endif  // os(macOS)
