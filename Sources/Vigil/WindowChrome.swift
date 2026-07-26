//
//  WindowChrome.swift
//  Vigil
//
//  Applies the main window's chrome — hidden title bar, transparent titlebar, inset traffic
//  lights, no tabs — and re-applies it whenever AppKit resets it.
//  macOS-only. See docs/DESIGN.md §11.2 and docs/API_CONTRACT.md §4.12.
//

#if os(macOS)

import AppKit
import SwiftUI

import VigilUI

// MARK: - WindowChrome

/// The chrome recipe of `docs/DESIGN.md` §11.2, in one function.
///
/// Everything here is idempotent, which matters because it runs again on every key-window change
/// and after every full-screen transition: AppKit restores the standard traffic-light origin when
/// a window leaves full screen, and there is no notification that says "your inset is gone".
///
/// `VigilUI` owns `Window/WindowAccessor.swift` in the full build (docs/API_CONTRACT.md §5.13); the
/// app target carries this only because the slice's `VigilUI` has no window layer yet. When that
/// file lands, this one should be deleted rather than kept alongside it.
@MainActor
enum WindowChrome {

    /// Applies the main-window treatment.
    ///
    /// - Parameter window: the window hosting the root view. Auxiliary windows deliberately keep
    ///   the standard AppKit treatment (§11.2, last row) — the slice has none.
    static func apply(to window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .none
        // `layer.canvas`, set on the window itself so a live resize never flashes white behind the
        // video (§11.2, "Background"). NSColor(_: SwiftUI.Color) is macOS 12+.
        window.backgroundColor = NSColor(VTheme.Color.Layer.canvas)
        // Vigil's multi-window model is Playback / Wall / Settings; tabs would hide live video.
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName(autosaveName)
        applyTrafficLightInset(to: window)
    }

    /// Shifts the traffic-light container to a 20 pt leading, 26 pt centre-y position.
    ///
    /// The buttons are moved by moving *their container*, never the buttons themselves: AppKit lays
    /// the three out inside that view with a fixed 20 pt spacing, and repositioning them
    /// individually both fights the layout pass and breaks the hover-to-reveal glyphs.
    ///
    /// The `+13, −10` deltas are DESIGN.md's, measured against AppKit's default origin of about
    /// (7, y). If a future macOS changes that default the buttons will sit slightly wrong — a
    /// cosmetic defect, not a crash — which is why nothing here forces or asserts.
    static func applyTrafficLightInset(to window: NSWindow) {
        guard let close = window.standardWindowButton(.closeButton),
              let container = close.superview
        else {
            return
        }
        let target = CGPoint(x: 20 - 7, y: container.frame.origin.y - 10)
        container.setFrameOrigin(target)
        container.superview?.needsLayout = true
    }

    /// `NSWindow` frame autosave name, so the window comes back where the user left it.
    static let autosaveName = "VigilMain"
}

// MARK: - WindowChromeInstaller

/// A zero-size `NSView` whose only job is to find the window SwiftUI put it in.
///
/// SwiftUI gives no supported access to the hosting `NSWindow`, and `NSApp.windows.first` picks up
/// panels, the About window and anything AppKit opened on its own. Reaching the window through a
/// view that is *in* it is the boring, documented route.
struct WindowChromeInstaller: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        ChromeProbeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - ChromeProbeView

/// Applies the chrome when it enters a window, and again on the two events that undo it.
@MainActor
private final class ChromeProbeView: NSView {

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        WindowChrome.apply(to: window)
        let center = NotificationCenter.default
        // Selector-based observation, not the block form: these notifications are posted on the
        // main thread, and an `@objc` method on a `@MainActor` view is the shape AppKit expects.
        // The block form would need an isolation hop and could apply the inset a frame late, which
        // is visible as the buttons jumping.
        center.addObserver(self, selector: #selector(reapplyChrome(_:)),
                           name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(reapplyChrome(_:)),
                           name: NSWindow.didExitFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(reapplyChrome(_:)),
                           name: NSWindow.didEnterFullScreenNotification, object: window)
    }

    /// Re-applies only the inset: the rest of the treatment survives, and re-setting the background
    /// colour during a full-screen transition causes a visible flash.
    @objc private func reapplyChrome(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        WindowChrome.applyTrafficLightInset(to: window)
    }
}

#endif  // os(macOS)
