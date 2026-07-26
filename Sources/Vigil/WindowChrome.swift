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
    /// - Returns: the traffic-light container's origin *before* it was moved, for the caller to
    ///   hand back to ``applyTrafficLightInset(to:baseline:)`` on every re-application.
    @discardableResult
    static func apply(to window: NSWindow) -> CGPoint? {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .none
        // `layer.canvas`, set on the window itself so a live resize never flashes white behind the
        // video (§11.2, "Background"). NSColor(_: SwiftUI.Color) is macOS 12+.
        window.backgroundColor = NSColor(VTheme.Color.Layer.canvas)
        // Vigil's multi-window model is Playback / Wall / Settings; tabs would hide live video.
        window.tabbingMode = .disallowed
        // `setFrameAutosaveName` returns a `Bool` and is not `@discardableResult`. It answers
        // "false" only when another window already owns the name, which for a single-window app
        // means the frame is being restored by that other window — nothing to do about it here.
        _ = window.setFrameAutosaveName(autosaveName)
        return applyTrafficLightInset(to: window)
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
    ///
    /// ⛔ The vertical delta is applied to a **fixed baseline**, never to the container's current
    /// origin. This method runs again on every key-window change and every full-screen transition;
    /// re-deriving `origin.y − 10` from where the container already is subtracts a further 10 pt
    /// each time, and the buttons walk down out of the title bar after a few activations. The
    /// horizontal position is absolute and so is idempotent on its own.
    ///
    /// - Parameters:
    ///   - window: the window to inset.
    ///   - baseline: the container origin recorded the first time this ran. Pass `nil` on the first
    ///     call to read and return AppKit's own origin.
    /// - Returns: the baseline that was used, or `nil` when the window has no traffic lights.
    @discardableResult
    static func applyTrafficLightInset(to window: NSWindow,
                                       baseline: CGPoint? = nil) -> CGPoint? {
        guard let close = window.standardWindowButton(.closeButton),
              let container = close.superview
        else {
            return nil
        }
        let origin = baseline ?? container.frame.origin
        container.setFrameOrigin(CGPoint(x: 20 - 7, y: origin.y - 10))
        container.superview?.needsLayout = true
        return origin
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

    /// The traffic-light container's origin before Vigil moved it. See
    /// ``WindowChrome/applyTrafficLightInset(to:baseline:)`` for why re-application needs it.
    private var trafficLightBaseline: CGPoint?

    /// The window we are already observing, so a view that SwiftUI re-parents does not register a
    /// second set of observers and apply the chrome twice per notification.
    private weak var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window !== observedWindow else { return }
        observedWindow = window
        trafficLightBaseline = WindowChrome.apply(to: window)
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
        WindowChrome.applyTrafficLightInset(to: window, baseline: trafficLightBaseline)
    }
}

#endif  // os(macOS)
