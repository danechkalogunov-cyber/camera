//
//  VOverflowMenuView.swift
//  VigilUI
//
//  The toolbar's "…" menu: Video Wall, Picture in Picture, Discover Cameras, Stream Doctor,
//  Settings. Menu *content* on its own E2 surface, so the window can hand it to a popover, an
//  overlay or a preview without the five items being restated at each site.
//  macOS-only. Implements docs/UX.md §3.2 (the overflow contents) and docs/DESIGN.md §2.3 and §6.5
//  (a detached surface takes the glass recipe), §9.26 (key cap), §9.28 (focus), §5.4 (⛔ Divider).
//

#if os(macOS)

import SwiftUI

// MARK: - VOverflowItem

/// One entry of the "…" menu.
///
/// A typed case rather than a caller-supplied list, because UX.md §3.2 names these five and only
/// these five: a menu whose contents differ between the toolbar and the previews is a menu nobody
/// can screenshot-test. Which of them are *available* still varies, and that is the caller's
/// business — see ``VOverflowMenuView/disabledItems``.
package enum VOverflowItem: String, Sendable, Hashable, CaseIterable, Identifiable {

    /// Open the multi-window video wall.
    case videoWall

    /// Detach the selected camera into a floating Picture-in-Picture window.
    case pictureInPicture

    /// Scan the local network for cameras.
    case discovery

    /// Open the stream diagnostics panel.
    case streamDoctor

    /// Open Settings.
    case settings

    /// Stable identity for `ForEach`.
    package var id: String { rawValue }

    /// The glyph, as a typed case rather than a string literal (§8.3).
    package var symbol: VTheme.Symbol {
        switch self {
        case .videoWall: return .videoWall
        case .pictureInPicture: return .pictureInPicture
        case .discovery: return .discover
        case .streamDoctor: return .streamDoctor
        case .settings: return .settings
        }
    }

    /// The key equivalent as it is printed on a key cap, or `nil`.
    ///
    /// Only Settings has one, and only because `⌘,` is a macOS-wide convention rather than
    /// something this menu invented. ⚠️ UX.md §3.2 assigns no shortcuts to the other four, and
    /// making some up here would put a key cap on screen that no responder answers.
    package var shortcut: String? {
        self == .settings ? "⌘," : nil
    }

    /// Whether a separator is drawn **above** this item.
    ///
    /// One rule, so the grouping cannot drift: Settings is application-level and the four above it
    /// act on the current window.
    package var startsGroup: Bool {
        self == .settings
    }
}

// MARK: - VOverflowMetrics

/// The menu's own geometry — the numbers that belong to this one surface.
///
/// A separate namespace for the reason ``VToolbarMetrics`` gives: a component's internals are not
/// design tokens, and putting a menu width in `VTheme` would imply that some other view may reach
/// for a 240 pt panel. Heights, radii, spacing, colours and icon sizes all come from `VTheme` and
/// are not restated here.
@MainActor
package enum VOverflowMetrics {

    /// 240 pt — wide enough for "Picture in Picture" beside a glyph and a key cap without
    /// truncating, and narrow enough to stay a menu rather than become a panel.
    package static let width: CGFloat = 240

    /// A menu row is 28 pt — `VTheme.Metrics.Row.settings`, the height the settings list already
    /// uses, so a menu row and a settings row scan alike.
    package static var rowHeight: CGFloat { VTheme.Metrics.Row.settings }
}

// MARK: - VOverflowMenuView

/// The "…" menu's contents.
///
/// ## What it owns
///
/// Nothing but its hover and focus. Which items to show, which are unavailable and what to do about
/// a click all arrive as a `let`, so the same view serves the app, the previews and a screenshot
/// harness.
///
/// ## The surface
///
/// It carries its own E2 glass through `vElevation(.e2, over: .chrome)` — DESIGN.md §2.3 gives a
/// *detached* surface the `.hudWindow` recipe of §6.5, and §12.4 bans building one by hand. A host
/// that puts this inside a `.popover` should therefore clear the popover's own background rather
/// than let two surfaces stack up; hosting it in an anchored overlay avoids the question entirely.
@MainActor
package struct VOverflowMenuView: View {

    // MARK: - Stored Properties

    /// The items to draw, in order. All five by default.
    package let items: [VOverflowItem]

    /// The items that cannot run right now.
    ///
    /// They are drawn dimmed rather than removed, because a menu that changes length between two
    /// presses is a menu whose muscle memory is worthless — and because "why can I not open the
    /// video wall" is a question a greyed row answers and a missing row does not.
    package let disabledItems: Set<VOverflowItem>

    /// Runs an item. The caller dismisses the menu; this view does not assume it should.
    package let onSelect: (VOverflowItem) -> Void

    /// Closes the menu — `⎋`.
    package let onDismiss: () -> Void

    @Environment(\.vMotionEnabled) private var motionEnabled
    @State private var hovered: VOverflowItem?
    @FocusState private var focused: VOverflowItem?

    // MARK: - Initialisation

    /// Creates the menu content.
    ///
    /// - Parameters:
    ///   - items: the entries to draw; all five by default.
    ///   - disabledItems: the entries that cannot run now.
    ///   - onSelect: performed on a click or on `Return` with a row focused.
    ///   - onDismiss: performed on `⎋`.
    package init(items: [VOverflowItem] = VOverflowItem.allCases,
                 disabledItems: Set<VOverflowItem> = [],
                 onSelect: @escaping (VOverflowItem) -> Void = { _ in },
                 onDismiss: @escaping () -> Void = {}) {
        self.items = items
        self.disabledItems = disabledItems
        self.onSelect = onSelect
        self.onDismiss = onDismiss
    }

    // MARK: - View

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                if item.startsGroup, item != items.first {
                    separator
                }
                row(item)
            }
        }
        .padding(.vertical, VTheme.Space.xs)
        .frame(width: VOverflowMetrics.width)
        .vElevation(VTheme.Elevation.e2, radius: VTheme.Radius.md, over: .chrome)
        .onExitCommand(perform: onDismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("More", bundle: .vigilUI))
    }

    // MARK: - Rows

    /// One menu row: a leading glyph, the title, and a trailing key cap when there is a shortcut.
    ///
    /// Hover is drawn as a **filled** row rather than as a tinted title, so the state survives
    /// `differentiateWithoutColor` (§10.5) — the same substitution ``VToolbarView`` makes for its
    /// active toggles.
    private func row(_ item: VOverflowItem) -> some View {
        let isEnabled = !disabledItems.contains(item)
        let isHighlighted = isEnabled && (hovered == item || focused == item)
        return Button {
            onSelect(item)
        } label: {
            HStack(spacing: VTheme.Icon.Gap.lg) {
                item.symbol.image()
                    .symbolRenderingMode(item.symbol.rendering)
                    .vIcon(size: VTheme.Icon.md, weight: item.symbol.weight)
                    .frame(width: VTheme.Icon.lg, alignment: .center)
                title(item)
                    .vType(VTheme.Typography.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: VTheme.Space.sm)
                if let shortcut = item.shortcut {
                    VPaletteKeyCap(label: shortcut)
                }
            }
            .foregroundStyle(isEnabled ? VTheme.Color.Text.primary : VTheme.Color.Text.disabled)
            .padding(.horizontal, VTheme.Space.sm)
            .frame(height: VOverflowMetrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHighlighted ? VTheme.Color.Semantic.Tint.selected : SwiftUI.Color.clear,
                        in: VTheme.Radius.shape(VTheme.Radius.sm))
            .padding(.horizontal, VTheme.Space.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .focused($focused, equals: item)
        // Ours is the only focus ring; the system's would double-draw with it (§9.28).
        .focusEffectDisabled()
        .vFocusRing(focused == item, radius: VTheme.Radius.sm)
        .onHover { hovering in
            hovered = hovering ? item : (hovered == item ? nil : hovered)
        }
        .animation(VTheme.Motion.resolved(VTheme.Motion.micro, reduced: !motionEnabled),
                   value: isHighlighted)
    }

    /// The title, a literal per case rather than a stored key: a `LocalizedStringKey` built from a
    /// variable is invisible to the localisation checker and would ship untranslated.
    @ViewBuilder
    private func title(_ item: VOverflowItem) -> some View {
        switch item {
        case .videoWall: Text("Video Wall", bundle: .vigilUI)
        case .pictureInPicture: Text("Picture in Picture", bundle: .vigilUI)
        case .discovery: Text("Discover Cameras", bundle: .vigilUI)
        case .streamDoctor: Text("Stream Doctor", bundle: .vigilUI)
        case .settings: Text("Settings", bundle: .vigilUI)
        }
    }

    /// ⛔ Never `Divider()`, whose colour and inset are not ours (§5.4).
    private var separator: some View {
        Rectangle()
            .fill(VTheme.Color.Stroke.subtle)
            .frame(height: VTheme.Border.thin)
            .padding(.horizontal, VTheme.Space.sm)
            .padding(.vertical, VTheme.Space.xs)
            .allowsHitTesting(false)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("VOverflowMenuView") {
    VOverflowMenuView()
        .padding(VTheme.Space.xl)
        .background(VTheme.Color.Layer.canvas)
}

#Preview("VOverflowMenuView — some unavailable") {
    VOverflowMenuView(disabledItems: [.pictureInPicture, .streamDoctor])
        .padding(VTheme.Space.xl)
        .background(VTheme.Color.Layer.canvas)
}
#endif

#endif  // os(macOS)
