//
//  Environment.swift
//  VigilUI
//
//  The environment keys VigilUI publishes: the window-wide pulse phase, the single shimmer
//  driver, the resolved motion switch, the interface text scale and the on-video flag.
//  macOS-only. See docs/DESIGN.md §12.3 and docs/API_CONTRACT.md §4.11.
//
//  Two of the seven keys in DESIGN.md §12.3 are deliberately absent because the types they carry
//  belong to files outside this slice: `\.vMotionTier` needs `VMotionTier` from
//  `Motion/VMotionGovernor.swift`, and `\.vNamespaces` needs `VNamespaces` from
//  `Window/MainWindowView.swift`. Adding them here with placeholder types would be worse than
//  leaving the two call sites to arrive with their owners.
//

#if os(macOS)

import SwiftUI

// MARK: - Keys

// These four are the only top-level types in VigilUI without an explicit `@MainActor` (R-40), and
// the omission is required rather than an oversight: `EnvironmentKey.defaultValue` is a
// `nonisolated` static requirement, so a `@MainActor` conformer cannot witness it. Each key holds
// one `Sendable` constant and has no state that could need isolation.

private struct VPulsePhaseKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private struct VShimmerOffsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = -1
}

private struct VMotionEnabledKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

private struct VVideoOverlayKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

private struct VTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = VTheme.Typography.Scale.standard
}

private struct VOnVideoKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

// MARK: - EnvironmentValues

extension EnvironmentValues {

    /// The window-wide pulse phase: a `Bool` that flips every 1.0 s, giving the 2 s breathe cycle.
    ///
    /// ⛔ Read by every ``VLiveDot`` and by the recording border; **never** produced by a component
    /// itself. Unison across sixteen tiles is the difference between a professional cockpit and a
    /// Christmas tree, and sixteen independent `PhaseAnimator`s would also blow the four-driver
    /// budget (DESIGN.md §7.5, §7.9). ``VPulseClock`` is the single driver.
    public var vPulsePhase: Bool {
        get { self[VPulsePhaseKey.self] }
        set { self[VPulsePhaseKey.self] = newValue }
    }

    /// The skeleton shimmer sweep position, −1 … 1, published by one driver for the whole window.
    ///
    /// A ``VSkeleton`` reads this instead of running its own `repeatForever` animation, so a
    /// sixteen-tile grid creates one animation driver rather than sixteen (DESIGN.md §7.8).
    public var vShimmerOffset: CGFloat {
        get { self[VShimmerOffsetKey.self] }
        set { self[VShimmerOffsetKey.self] = newValue }
    }

    /// Whether animation is allowed at all: `false` when `accessibilityReduceMotion` is on or when
    /// `VMotionGovernor` has reached tier T3 (DESIGN.md §7.9, §7.10).
    ///
    /// Pass `!vMotionEnabled` as the `reduced:` argument of
    /// ``VTheme/Motion/resolved(_:reduced:fallback:)`` rather than branching at the call site.
    public var vMotionEnabled: Bool {
        get { self[VMotionEnabledKey.self] }
        set { self[VMotionEnabledKey.self] = newValue }
    }

    /// Whether the chrome drawn *on top of* the picture is shown at all.
    ///
    /// The camera name chip, the connection chip, the stats readout and the recording timecode —
    /// everything that sits over the frame rather than around it. `false` leaves the picture and
    /// the tile's border, and nothing else.
    ///
    /// An environment value and not an initialiser parameter on purpose. The flag has to reach
    /// `LiveVideoView` and `GridTileView` through `VGridStageView`, and threading a `Bool` through
    /// three initialisers means three call sites whose argument order must all stay right — for a
    /// value none of them makes a decision about. The overlays that *explain* a problem are
    /// deliberately outside this: an offline card or a degraded banner is not decoration, and
    /// hiding it would leave a black rectangle with no account of itself.
    public var vShowsVideoOverlay: Bool {
        get { self[VVideoOverlayKey.self] }
        set { self[VVideoOverlayKey.self] = newValue }
    }

    /// The user's Settings ▸ General ▸ Interface text size factor: 0.92, 1.00 or 1.15 (§4.5).
    public var vTextScale: CGFloat {
        get { self[VTextScaleKey.self] }
        set { self[VTextScaleKey.self] = newValue }
    }

    /// Whether this subtree is drawn over a video well.
    ///
    /// This is what lets one `VButton(.icon)` or one ``VChip`` serve both the toolbar and the tile:
    /// the component reads the flag and swaps its rest fill from `clear` to `Scrim.base` with a
    /// `Stroke.onVideo` hairline, and drops its shadow entirely (DESIGN.md §2.3, §6.3, §12.3).
    ///
    /// The matching value for a modifier that takes one explicitly is ``VTheme/Backdrop``; see
    /// ``backdrop`` for the bridge.
    public var vOnVideo: Bool {
        get { self[VOnVideoKey.self] }
        set { self[VOnVideoKey.self] = newValue }
    }

    /// ``vOnVideo`` expressed as the type `vElevation(_:radius:over:)` takes.
    ///
    /// Read-only on purpose: `.video` must be set by the well that owns the frame — normally
    /// `VTile`, or ``LiveVideoView`` in this slice — and never claimed by a chip on its own.
    public var backdrop: VTheme.Backdrop {
        vOnVideo ? .video : .chrome
    }
}

// MARK: - View modifiers

extension View {

    /// Marks a subtree as drawn over a video well, so every piece of chrome inside it resolves to
    /// the solid scrim ladder rather than to a material (DESIGN.md §2.3).
    @MainActor
    package func vOnVideo(_ isOnVideo: Bool = true) -> some View {
        environment(\.vOnVideo, isOnVideo)
    }

    /// Publishes the resolved motion switch for a subtree.
    ///
    /// - Parameter enabled: `false` when `accessibilityReduceMotion` is on, when
    ///   `accessibilityPrefersCrossFadeTransitions` is on, or when the motion governor has reached
    ///   tier T3.
    @MainActor
    package func vMotionEnabled(_ enabled: Bool) -> some View {
        environment(\.vMotionEnabled, enabled)
    }

    /// Shows or hides the chrome drawn over the picture for a subtree.
    ///
    /// - Parameter shows: `false` hides the name chip, the status chip, the stats readout and the
    ///   recording timecode. Never hides an overlay that explains a failure.
    @MainActor
    package func vShowsVideoOverlay(_ shows: Bool) -> some View {
        environment(\.vShowsVideoOverlay, shows)
    }
}

#endif  // os(macOS)
