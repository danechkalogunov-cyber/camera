//
//  VToolbarView.swift
//  VigilUI
//
//  The main window's 52 pt unified toolbar: the traffic-light inset, the sidebar toggle, the search
//  field, the centred layout switcher, and the cycle / palette / overflow / inspector group.
//  macOS-only. Implements docs/DESIGN.md §11.2 and §11.3 (chrome and contents), §2.3 (the toolbar is
//  a `.headerView` material, never `.hudWindow`), §2.4 (`reduceTransparency`), §8.3 (symbols),
//  §9.2 (segmented control), §9.6 (search field), §9.26 (key cap), and docs/UX.md §3.2.
//

#if os(macOS)

import AppKit
import SwiftUI

// MARK: - VToolbarMetrics

/// `VToolbarView`'s own geometry — the numbers DESIGN.md gives this one bar and no other component.
///
/// A separate namespace for the reason `VTextFieldMetrics` gives: these are a component's internals,
/// not design tokens shared across the app, and putting them in `VTheme` would imply that some other
/// view may reach for a 200 pt search field. Everything that *is* a token — heights, radii, spacing,
/// colours, icon sizes — comes from `VTheme` and is not restated here.
///
/// `@MainActor` for the same reason `VTheme.Metrics` is: several of these values are **derived from**
/// main-actor tokens, and a nonisolated static cannot be initialised from one.
@MainActor
package enum VToolbarMetrics {

    // MARK: Traffic lights (§11.2)

    /// AppKit lays the three window buttons out 20 pt centre-to-centre.
    ///
    /// Not ours to choose, which is why it is not a `VTheme.Space` step: `WindowChrome` moves the
    /// *container* precisely so that AppKit's own spacing survives.
    private static let trafficLightSpacing: CGFloat = 20

    /// A standard window button is 14 pt across.
    private static let trafficLightDiameter: CGFloat = 14

    /// The leading inset that clears the traffic lights.
    ///
    /// `WindowChrome.applyTrafficLightInset(to:baseline:)` puts the close button's centre at
    /// `VTheme.Metrics.trafficLightLeading` 20 pt, and the other two follow at 20 pt intervals, so
    /// the zoom button's trailing edge is 20 + 2 × 20 + 7 = 67 pt. The first toolbar control starts
    /// one `space.md` after that.
    package static var trafficLightInset: CGFloat {
        // Past the rightmost button's trailing *edge*, plus a gap. The old formula added half a
        // diameter, which lands on that button's centre-plus-radius — its edge exactly — so the
        // sidebar toggle began where the zoom button ended and the two appeared to touch.
        VTheme.Metrics.trafficLightLeading
            + 2 * trafficLightSpacing
            + trafficLightDiameter
            + VTheme.Space.md
            + VTheme.Space.md
    }

    // MARK: Search field (§9.6, UX.md §3.2)

    /// 200 pt at rest.
    package static let searchWidth: CGFloat = 200

    /// 320 pt while it has the cursor, so a long camera name is readable while it is being typed.
    package static let searchFocusedWidth: CGFloat = 320

    // MARK: Layout switcher (§9.2)

    /// 30 pt per segment — the mockup's width, and comfortably over §9.2's 44 pt minimum once the
    /// 24 × 24 hit target expansion every icon control gets is taken into account.
    package static let segmentWidth: CGFloat = 30

    /// The `matchedGeometryEffect` identity of the selection thumb.
    package static let thumbID: String = "toolbar.layout.thumb"

    /// The seam between two cells of a layout miniature: one hairline, split across the two
    /// neighbours, so a 3 × 3 miniature still reads as nine cells at 15 pt.
    package static let glyphSeam: CGFloat = VTheme.Border.thin

    /// The corner radius of one cell in a layout miniature.
    ///
    /// A quarter of `radius.xs`, derived rather than invented — the same move `VLiveDot` makes for
    /// its 6 pt square dot. At 15 pt the smallest cell is under 4 pt across and any larger radius
    /// turns it into a circle.
    package static let glyphCellRadius: CGFloat = VTheme.Radius.xs / 4

    // MARK: Key cap (§9.26)

    /// 18 × 18 pt minimum, growing with the caption.
    package static let keyCapSide: CGFloat = 18

    /// 5 pt horizontal padding for a multi-character cap such as `⌘K`.
    package static let keyCapPadding: CGFloat = 5

    /// `white α 0.08` — §9.26's fill, the same alpha `VChip(.neutral)` uses.
    package static let keyCapFillAlpha: Double = 0.08
}

// MARK: - VToolbarView

/// The main window's toolbar.
///
/// ## The material, and why it is not the glass recipe
///
/// DESIGN.md §2.3's table gives the unified toolbar strip `material: .headerView`, `.withinWindow`,
/// `.active` — and gives `.hudWindow` plus the §6.5 glass recipe to *detached* surfaces (palette,
/// popovers, toasts). The toolbar is attached chrome, not a floating card, so it takes the header
/// material and no inner highlight, no tint layer and no shadow. ``VToastView`` is the surface in
/// this directory that takes §6.5, through `vElevation(.e2, …)`.
///
/// Under `accessibilityReduceTransparency` the material is replaced by
/// ``VTheme/Color/Layer/headerFallback``, which is §2.4's table entry for `.headerView` (`#131519`
/// dark, `#F0F1F4` light). `colorSchemeContrast == .increased` resolves to the same solid, because
/// vibrancy is a contrast hazard (§10.4) — this is exactly the rule ``VGlass`` applies to its own
/// material, spelled out here rather than shared, because the two use different materials.
///
/// ## What it does not do
///
/// It owns no model. Every piece of state arrives as a `let` and every action leaves as a closure,
/// so the same view serves the app, the previews and a screenshot harness. The one exception is the
/// search field's `@FocusState`, which cannot be lifted out without making the whole view generic;
/// the window asks for the cursor by incrementing ``focusSearchRequests`` instead.
@MainActor
package struct VToolbarView: View {

    // MARK: - Stored Properties

    /// Whether the sidebar is showing, which lights the toggle.
    package let isSidebarVisible: Bool

    /// Whether the inspector is showing, which lights its toggle.
    package let isInspectorVisible: Bool

    /// The stage's current layout. A layout the switcher does not offer leaves every segment
    /// unselected rather than lighting the wrong one.
    package let layout: VGridLayout

    /// Whether the camera cycle (patrol) is running.
    package let isCycling: Bool
    package let cycleInterval: TimeInterval

    /// Whether to draw the 1 px bottom hairline.
    ///
    /// §11.2: the window's own titlebar separator is `.none` and we draw our own `stroke.subtle`
    /// **only when the stage is scrolled** — over video there is no separator at all. The window
    /// decides; the toolbar draws.
    package let showsSeparator: Bool

    /// Whether the window is wide enough to hold the camera list at all (DESIGN.md §11.2).
    ///
    /// The toggle is *disabled* rather than merely unlit when this is `false`. A button that stays
    /// pressable while the panel it names cannot appear is a button that does nothing, and the
    /// tooltip is the only place the width rule can be explained.
    package let canShowSidebar: Bool

    /// Whether the window is wide enough to hold the inspector. See ``canShowSidebar``.
    package let canShowInspector: Bool

    /// Selected camera or layout name, replacing a redundant window title.
    package let title: String?

    /// Incremented by the window to put the cursor in the search field — the `/` shortcut, or the
    /// palette handing over. Any change moves focus; the value itself means nothing.
    package let focusSearchRequests: Int

    /// The opposite, and it exists for the same reason: `@FocusState` cannot be lifted out of this
    /// view, so the window asks for the cursor to *leave* by incrementing this.
    ///
    /// ⛔ A counter and not a `Bool` binding. Focus is owned here — the user can click straight into
    /// the field — and a binding the window also wrote would fight that on every body evaluation. A
    /// request is a fact ("something asked the caret to leave") that cannot go stale the way a
    /// mirrored flag can.
    package let blurSearchRequests: Int

    /// The search query.
    @Binding package var searchText: String

    /// Shows or hides the sidebar. `⌘L`.
    package let onToggleSidebar: () -> Void

    /// Shows or hides the inspector. `⌥⌘I`.
    package let onToggleInspector: () -> Void

    /// Applies a layout from the switcher.
    package let onSelectLayout: (VGridLayout) -> Void

    /// Starts or stops cycling through cameras.
    package let onToggleCycle: () -> Void
    package let onSelectCycleInterval: (TimeInterval) -> Void

    /// Opens the command palette. `⌘K`.
    package let onOpenPalette: () -> Void

    /// Opens the overflow menu: Video Wall, PiP, Discovery, Stream Doctor, Settings (UX.md §3.2).
    package let onShowMore: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    @FocusState private var isSearchFocused: Bool

    // MARK: - Initialisation

    /// Creates the toolbar.
    ///
    /// Every action defaults to a no-op so a preview or a screenshot can construct the bar without
    /// standing up a model.
    package init(isSidebarVisible: Bool,
                 isInspectorVisible: Bool,
                 layout: VGridLayout,
                 title: String? = nil,
                 searchText: Binding<String>,
                 isCycling: Bool = false,
                 cycleInterval: TimeInterval = VCycleModel.defaultInterval,
                 showsSeparator: Bool = false,
                 canShowSidebar: Bool = true,
                 canShowInspector: Bool = true,
                 focusSearchRequests: Int = 0,
                 blurSearchRequests: Int = 0,
                 onToggleSidebar: @escaping () -> Void = {},
                 onToggleInspector: @escaping () -> Void = {},
                 onSelectLayout: @escaping (VGridLayout) -> Void = { _ in },
                 onToggleCycle: @escaping () -> Void = {},
                 onSelectCycleInterval: @escaping (TimeInterval) -> Void = { _ in },
                 onOpenPalette: @escaping () -> Void = {},
                 onShowMore: @escaping () -> Void = {}) {
        self.isSidebarVisible = isSidebarVisible
        self.isInspectorVisible = isInspectorVisible
        self.layout = layout
        self.title = title
        self._searchText = searchText
        self.isCycling = isCycling
        self.cycleInterval = cycleInterval
        self.showsSeparator = showsSeparator
        self.canShowSidebar = canShowSidebar
        self.canShowInspector = canShowInspector
        self.focusSearchRequests = focusSearchRequests
        self.blurSearchRequests = blurSearchRequests
        self.onToggleSidebar = onToggleSidebar
        self.onToggleInspector = onToggleInspector
        self.onSelectLayout = onSelectLayout
        self.onToggleCycle = onToggleCycle
        self.onSelectCycleInterval = onSelectCycleInterval
        self.onOpenPalette = onOpenPalette
        self.onShowMore = onShowMore
    }

    // MARK: - View

    package var body: some View {
        HStack(spacing: VTheme.Space.sm) {
            sidebarToggle
            if let title, !title.isEmpty {
                Text(verbatim: title)
                    .vType(VTheme.Typography.headline)
                    .foregroundStyle(VTheme.Color.Text.primary)
                    .lineLimit(1)
                    .frame(maxWidth: 180, alignment: .leading)
            }
            VToolbarSearchField(text: $searchText, focus: $isSearchFocused)
            // Two flexible gaps rather than a centred overlay: the mockup's own layout, and the one
            // arrangement in which the switcher can never end up underneath the group beside it.
            Spacer(minLength: VTheme.Space.md)
            VToolbarLayoutSwitcher(current: layout, onSelect: onSelectLayout)
            Spacer(minLength: VTheme.Space.md)
            cycleButton
            VToolbarPaletteButton(action: onOpenPalette)
            overflowButton
            inspectorToggle
        }
        .padding(.leading, VToolbarMetrics.trafficLightInset)
        .padding(.trailing, VTheme.Space.md)
        .frame(height: VTheme.Metrics.toolbarHeight)
        .frame(maxWidth: .infinity)
        .background { header }
        .overlay(alignment: .bottom) { separator }
        .onChange(of: focusSearchRequests) { _, _ in isSearchFocused = true }
        .onChange(of: blurSearchRequests) { _, _ in isSearchFocused = false }
    }

    // MARK: - Surface

    /// The header material, or §2.4's solid fallback.
    @ViewBuilder
    private var header: some View {
        if usesSolidHeader {
            VTheme.Color.Layer.headerFallback
        } else {
            // `NSVisualEffectView.Material.headerView`, `.withinWindow`, `.active` — §2.3's row for
            // the unified toolbar strip. `.active` and not `.followsWindowActiveState`: the sidebar
            // and inspector recede when the window loses key, the toolbar does not.
            VVisualEffect(material: .headerView,
                          blending: .withinWindow,
                          state: .active)
        }
    }

    /// `reduceTransparency` (§2.4) and `increaseContrast` (§10.4) both resolve to the solid.
    private var usesSolidHeader: Bool {
        reduceTransparency || contrast == .increased
    }

    /// §11.2's hairline. `stroke.subtle`, not `stroke.default`: it separates two pieces of chrome,
    /// and ⛔ never `Divider()`, whose colour and inset are not ours (§5.4).
    @ViewBuilder
    private var separator: some View {
        if showsSeparator {
            Rectangle()
                .fill(VTheme.Color.Stroke.subtle)
                .frame(height: VTheme.Border.hairline(displayScale))
                .allowsHitTesting(false)
        }
    }

    // MARK: - Items

    /// The sidebar toggle.
    ///
    /// An active toggle becomes `.secondary` — a fill **and** a stroke appear — rather than merely
    /// taking an accent tint. `VButton` sets its own foreground and this file may not change it, but
    /// the substitution is the better answer anyway: a state carried by a shape change survives
    /// `differentiateWithoutColor`, and a state carried only by hue does not (§10.5).
    private var sidebarToggle: some View {
        VButton(symbol: .toggleSidebar,
                style: isSidebarVisible ? .secondary : .icon,
                accessibilityLabel: "Toggle Sidebar",
                action: onToggleSidebar)
            .disabled(!canShowSidebar)
            .help(canShowSidebar
                ? Text("Toggle Sidebar", bundle: .vigilUI)
                : Text("The window is too narrow for the camera list", bundle: .vigilUI))
    }

    private var inspectorToggle: some View {
        VButton(symbol: .toggleInspector,
                style: isInspectorVisible ? .secondary : .icon,
                accessibilityLabel: "Toggle Inspector",
                action: onToggleInspector)
            .disabled(!canShowInspector)
            .help(canShowInspector
                ? Text("Toggle Inspector", bundle: .vigilUI)
                : Text("The window is too narrow for the inspector", bundle: .vigilUI))
    }

    /// Camera cycling.
    ///
    /// `VTheme.Symbol.patrol` — `play.square.stack` — is DESIGN.md §8.3's glyph for "Cycle / patrol
    /// view". ⚠️ UX.md §3.2 names `arrow.triangle.2.circlepath` for the same toolbar item, which
    /// §8.3 assigns to *Reconnecting*; §8.3 is the symbol map, so it wins. Reported.
    private var cycleButton: some View {
        VButton("Cycle",
                symbol: .patrol,
                style: isCycling ? .secondary : .ghost,
                action: onToggleCycle)
            .contextMenu {
                ForEach(VCycleModel.intervals, id: \.self) { interval in
                    Button("\(Int(interval)) s") { onSelectCycleInterval(interval) }
                }
            }
            .help(Text("Cycle cameras", bundle: .vigilUI))
    }

    private var overflowButton: some View {
        VButton(symbol: .overflow,
                accessibilityLabel: "More",
                action: onShowMore)
            .help(Text("More", bundle: .vigilUI))
            // ⛔ The button publishes where it *is*, because the menu it opens is drawn by the
            // window and the window was placing it by arithmetic — one padding token that happened
            // to be wrong, so the panel hung offset from the control that summoned it. A measured
            // frame cannot be wrong, and it survives every future change to this row's contents.
            .background {
                GeometryReader { proxy in
                    SwiftUI.Color.clear.preference(key: VToolbarAnchorKey.self,
                                                   value: proxy.frame(in: .named(VToolbarAnchor.space)))
                }
            }
    }
}

// MARK: - VToolbarAnchor

/// The named coordinate space the toolbar reports its anchors in.
///
/// Declared here rather than in the app so both halves cannot drift: the window marks its content
/// with ``space`` and the toolbar measures against the same name.
package enum VToolbarAnchor {

    /// The window content's coordinate space.
    package static let space = "vigil.window"
}

/// Where the "…" button sits, in ``VToolbarAnchor/space``.
package struct VToolbarAnchorKey: PreferenceKey {

    package static let defaultValue: CGRect = .zero

    /// Last writer wins: there is exactly one overflow button in a window.
    package static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Where the search field sits, in ``VToolbarAnchor/space``.
///
/// ⛔ Published for one reason: the window wants "a click anywhere takes the caret out of the
/// search field", and *anywhere* has to exclude the field itself or the click that focuses it would
/// blur it in the same breath. Geometry is the only honest way to make that exception — the window
/// cannot ask SwiftUI what a click landed on.
package struct VToolbarSearchAnchorKey: PreferenceKey {

    package static let defaultValue: CGRect = .zero

    package static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

#endif  // os(macOS)
