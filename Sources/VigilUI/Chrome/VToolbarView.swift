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
package enum VToolbarMetrics {

    // MARK: Traffic lights (§11.2)

    /// AppKit lays the three window buttons out 20 pt centre-to-centre.
    ///
    /// Not ours to choose, which is why it is not a `VTheme.Space` step: `WindowChrome` moves the
    /// *container* precisely so that AppKit's own spacing survives.
    private static let trafficLightSpacing: CGFloat = 20

    /// A standard window button is 14 pt across.
    private static let trafficLightDiameter: CGFloat = 14

    /// The leading inset that clears the traffic lights, 79 pt.
    ///
    /// `WindowChrome.applyTrafficLightInset(to:baseline:)` puts the close button's centre at
    /// `VTheme.Metrics.trafficLightLeading` 20 pt, and the other two follow at 20 pt intervals, so
    /// the zoom button's trailing edge is 20 + 2 × 20 + 7 = 67 pt. The first toolbar control starts
    /// one `space.md` after that.
    package static var trafficLightInset: CGFloat {
        VTheme.Metrics.trafficLightLeading
            + 2 * trafficLightSpacing
            + trafficLightDiameter / 2
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

    /// Whether to draw the 1 px bottom hairline.
    ///
    /// §11.2: the window's own titlebar separator is `.none` and we draw our own `stroke.subtle`
    /// **only when the stage is scrolled** — over video there is no separator at all. The window
    /// decides; the toolbar draws.
    package let showsSeparator: Bool

    /// Incremented by the window to put the cursor in the search field — the `/` shortcut, or the
    /// palette handing over. Any change moves focus; the value itself means nothing.
    package let focusSearchRequests: Int

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
                 searchText: Binding<String>,
                 isCycling: Bool = false,
                 showsSeparator: Bool = false,
                 focusSearchRequests: Int = 0,
                 onToggleSidebar: @escaping () -> Void = {},
                 onToggleInspector: @escaping () -> Void = {},
                 onSelectLayout: @escaping (VGridLayout) -> Void = { _ in },
                 onToggleCycle: @escaping () -> Void = {},
                 onOpenPalette: @escaping () -> Void = {},
                 onShowMore: @escaping () -> Void = {}) {
        self.isSidebarVisible = isSidebarVisible
        self.isInspectorVisible = isInspectorVisible
        self.layout = layout
        self._searchText = searchText
        self.isCycling = isCycling
        self.showsSeparator = showsSeparator
        self.focusSearchRequests = focusSearchRequests
        self.onToggleSidebar = onToggleSidebar
        self.onToggleInspector = onToggleInspector
        self.onSelectLayout = onSelectLayout
        self.onToggleCycle = onToggleCycle
        self.onOpenPalette = onOpenPalette
        self.onShowMore = onShowMore
    }

    // MARK: - View

    package var body: some View {
        HStack(spacing: VTheme.Space.sm) {
            sidebarToggle
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
            .help(Text("Toggle Sidebar", bundle: .vigilUI))
    }

    private var inspectorToggle: some View {
        VButton(symbol: .toggleInspector,
                style: isInspectorVisible ? .secondary : .icon,
                accessibilityLabel: "Toggle Inspector",
                action: onToggleInspector)
            .help(Text("Toggle Inspector", bundle: .vigilUI))
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
            .help(Text("Cycle cameras", bundle: .vigilUI))
    }

    private var overflowButton: some View {
        VButton(symbol: .overflow,
                accessibilityLabel: "More",
                action: onShowMore)
            .help(Text("More", bundle: .vigilUI))
    }
}

// MARK: - VToolbarSearchField

/// §9.6's search field: an E0 well at the `lg` 32 pt height with `radius.md` 8.
///
/// ⚠️ The approved mockup draws this control 28 pt tall on a raised fill. DESIGN.md §5.5 and §9.6
/// both put the search field at `lg` 32 on an inset well, and the specification is normative where
/// the two disagree, so that is what this is. Reported.
///
/// `Esc` is two-stage, as §9.6 requires: it clears a non-empty field and blurs an empty one, so a
/// single key never both discards a query and loses the cursor.
@MainActor
private struct VToolbarSearchField: View {

    @Binding var text: String

    /// Owned by ``VToolbarView`` so the `/` shortcut can reach it.
    let focus: FocusState<Bool>.Binding

    @Environment(\.vMotionEnabled) private var motionEnabled
    @State private var isHovering = false

    private var isFocused: Bool {
        focus.wrappedValue
    }

    var body: some View {
        HStack(spacing: VTheme.Icon.Gap.md) {
            VTheme.Symbol.search.image()
                .vIcon(size: VTheme.Icon.md, weight: VTheme.Symbol.search.weight)
                .foregroundStyle(isFocused
                                    ? VTheme.Color.Text.secondary
                                    : VTheme.Color.Text.tertiary)
                .accessibilityHidden(true)
            field
            accessory
        }
        .padding(.horizontal, VTheme.Metrics.controlLG.horizontalPadding)
        .frame(width: isFocused ? VToolbarMetrics.searchFocusedWidth : VToolbarMetrics.searchWidth,
               height: VTheme.Metrics.lg)
        .background(VTheme.Color.Layer.inset, in: VTheme.Radius.shape(VTheme.Radius.md))
        // E0's inverted highlight: a 1 pt top inner shadow is what makes a well read as recessed
        // rather than raised (§6.1), and it is the same construction `VTextField` uses.
        .overlay {
            VInnerHighlight(radius: VTheme.Radius.md,
                            opacity: VTheme.Elevation.e0.innerShadow,
                            fadeStop: VTheme.Elevation.e0.highlightFade,
                            inverted: true)
        }
        .overlay {
            VTheme.Radius.shape(VTheme.Radius.md)
                .strokeBorder(borderColour, lineWidth: VTheme.Border.thin)
                .allowsHitTesting(false)
        }
        .onHover { isHovering = $0 }
        .onExitCommand { escape() }
        .animation(VTheme.Motion.resolved(VTheme.Motion.standard, reduced: !motionEnabled),
                   value: isFocused)
        .animation(VTheme.Motion.resolved(VTheme.Motion.micro, reduced: !motionEnabled),
                   value: isHovering)
        .animation(VTheme.Motion.resolved(VTheme.Motion.micro, reduced: !motionEnabled),
                   value: text.isEmpty)
    }

    private var field: some View {
        TextField(text: $text, prompt: prompt) {
            Text("Search cameras", bundle: .vigilUI)
        }
        // The prompt already names the field; a second visible copy beside it is what
        // `.labelsHidden()` exists to prevent. The label survives for VoiceOver.
        .labelsHidden()
        .textFieldStyle(.plain)
        .focused(focus)
        .focusEffectDisabled()
        .vType(VTheme.Typography.body)
        .foregroundStyle(VTheme.Color.Text.primary)
        // `.tint` is what colours the insertion point and the selection on macOS (§9.5).
        .tint(VTheme.Color.Semantic.accent)
        .autocorrectionDisabled()
    }

    private var prompt: Text {
        Text("Search cameras", bundle: .vigilUI)
            .foregroundStyle(VTheme.Color.Text.tertiary)
    }

    /// The trailing affordance: the `/` hint while the field is empty and unfocused, the clear
    /// button as soon as there is something to clear (§9.6).
    @ViewBuilder
    private var accessory: some View {
        if !text.isEmpty {
            Button {
                text = ""
            } label: {
                VTheme.Symbol.clear.image()
                    .vIcon(size: VTheme.Icon.md, weight: VTheme.Icon.Weight.md)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
                    .frame(width: VTheme.Metrics.minHitTarget,
                           height: VTheme.Metrics.minHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Clear search", bundle: .vigilUI))
            .transition(.opacity)
        } else if !isFocused {
            VToolbarKeyCap(label: "/")
                .transition(.opacity)
        }
    }

    private var borderColour: SwiftUI.Color {
        if isFocused { return VTheme.Color.Semantic.accent }
        return isHovering ? VTheme.Color.Stroke.strong : VTheme.Color.Stroke.default
    }

    /// Two-stage `Esc` (§9.6). Clearing first means a mistyped query costs one key, not two.
    private func escape() {
        if text.isEmpty {
            focus.wrappedValue = false
        } else {
            text = ""
        }
    }
}

// MARK: - VToolbarLayoutSwitcher

/// §9.2's segmented control, carrying the four layouts of ``VChromeLayoutSwitcher/options``.
///
/// ⚠️ §9.2 gives the thumb a `surfaceRaised` fill. The approved mockup, and the brief for this
/// window, both show the active layout **accented** — `accentFill` with a white glyph — which is
/// what this draws. Reported as a deliberate deviation, because the layout switcher is the one
/// segmented control in the app whose selection is a mode the operator needs to see across the room.
///
/// The thumb travels with `matchedGeometryEffect` in a namespace declared here rather than in the
/// shared `\.vNamespaces` of §7.7, because that environment key does not exist yet (see the header
/// of `Theme/Environment.swift`). A local namespace is correct in the meantime: nothing outside this
/// control participates in the thumb's geometry.
@MainActor
private struct VToolbarLayoutSwitcher: View {

    let current: VGridLayout
    let onSelect: (VGridLayout) -> Void

    @Namespace private var thumb
    @FocusState private var focusedOption: VGridLayout?
    @Environment(\.vMotionEnabled) private var motionEnabled

    var body: some View {
        HStack(spacing: VTheme.Space.hair) {
            ForEach(VChromeLayoutSwitcher.options) { option in
                segment(option)
            }
        }
        // §9.2: 2 pt inner padding, `layer.canvas` track, `stroke.default`, `radius.sm` 6.
        .padding(VTheme.Space.hair)
        .frame(height: VTheme.Metrics.md)
        .background(VTheme.Color.Layer.canvas, in: VTheme.Radius.shape(VTheme.Radius.sm))
        .overlay {
            VTheme.Radius.shape(VTheme.Radius.sm)
                .strokeBorder(VTheme.Color.Stroke.default, lineWidth: VTheme.Border.thin)
                .allowsHitTesting(false)
        }
        .animation(VTheme.Motion.resolved(VTheme.Motion.snap, reduced: !motionEnabled),
                   value: current)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Choose a layout", bundle: .vigilUI))
    }

    private func segment(_ option: VGridLayout) -> some View {
        let isSelected = VChromeLayoutSwitcher.isSelected(option, current: current)
        return Button {
            onSelect(option)
        } label: {
            VToolbarLayoutGlyph(layout: option)
                .foregroundStyle(isSelected ? SwiftUI.Color.white : VTheme.Color.Text.tertiary)
                .frame(width: VToolbarMetrics.segmentWidth, height: VTheme.Metrics.sm)
                .background { thumbShape(isSelected) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedOption, equals: option)
        // Ours is the only focus ring; the system's would double-draw with it (§9.28).
        .focusEffectDisabled()
        .vFocusRing(focusedOption == option, radius: VTheme.Radius.xs)
        .accessibilityLabel(Text(VChromeLayoutSwitcher.label(for: option), bundle: .vigilUI))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(Text(VChromeLayoutSwitcher.label(for: option), bundle: .vigilUI))
    }

    @ViewBuilder
    private func thumbShape(_ isSelected: Bool) -> some View {
        if isSelected {
            VTheme.Radius.shape(VTheme.Radius.xs)
                .fill(VTheme.Color.Semantic.accentFill)
                .matchedGeometryEffect(id: VToolbarMetrics.thumbID, in: thumb)
        }
    }
}

// MARK: - VToolbarLayoutGlyph

/// A live miniature of a layout, drawn from its own ``VGridLayout/cells``.
///
/// §8.3 is explicit that layout pickers use drawn miniatures rather than approximate SF Symbols —
/// there is no exact 4 × 4 grid symbol, and a picker whose glyphs half-lie about the arrangement is
/// worse than one that draws it. Because the rectangles come from the same table the stage lays
/// tiles out with, the glyph cannot drift from the layout it selects.
///
/// It is `private` on purpose. `VLayoutGlyph` is a shared component in the manifest and belongs in
/// `Components/`; claiming that name from this file would collide with whoever writes it.
@MainActor
private struct VToolbarLayoutGlyph: View {

    let layout: VGridLayout

    var body: some View {
        GeometryReader { proxy in
            let unit = proxy.size.width / CGFloat(VGridLayout.units)
            ForEach(Array(layout.cells.enumerated()), id: \.offset) { item in
                cell(item.element, unit: unit)
            }
        }
        .frame(width: VTheme.Icon.lg, height: VTheme.Icon.lg)
        .accessibilityHidden(true)
    }

    /// One tile of the miniature, filled with the inherited `foregroundStyle`.
    private func cell(_ rect: VLayoutRect, unit: CGFloat) -> some View {
        VTheme.Radius.shape(VToolbarMetrics.glyphCellRadius)
            .frame(width: Swift.max(0, CGFloat(rect.w) * unit - VToolbarMetrics.glyphSeam),
                   height: Swift.max(0, CGFloat(rect.h) * unit - VToolbarMetrics.glyphSeam))
            .position(x: (CGFloat(rect.x) + CGFloat(rect.w) / 2) * unit,
                      y: (CGFloat(rect.y) + CGFloat(rect.h) / 2) * unit)
    }
}

// MARK: - VToolbarKeyCap

/// §9.26's key cap: an 18 pt minimum square, `radius.xs` 4, `white α 0.08` with a hairline.
///
/// ⚠️ §9.26 also asks for a 1 pt **bottom** inner shadow to give the cap its physical look.
/// `VInnerHighlight` only draws a top edge, and inventing a second gradient here would put a shadow
/// construction outside the elevation appliers, which §12.4 bans. Left out and reported.
///
/// The caption is `Text(verbatim:)` — `/` and `⌘K` are key names, and a key name is not translated.
@MainActor
private struct VToolbarKeyCap: View {

    let label: String

    var body: some View {
        Text(verbatim: label)
            .vType(VTheme.Typography.caption2)
            .foregroundStyle(VTheme.Color.Text.secondary)
            .padding(.horizontal, VToolbarMetrics.keyCapPadding)
            .frame(minWidth: VToolbarMetrics.keyCapSide, minHeight: VToolbarMetrics.keyCapSide)
            .background(SwiftUI.Color.white.opacity(VToolbarMetrics.keyCapFillAlpha),
                        in: VTheme.Radius.shape(VTheme.Radius.xs))
            .overlay {
                VTheme.Radius.shape(VTheme.Radius.xs)
                    .strokeBorder(VTheme.Color.Stroke.default, lineWidth: VTheme.Border.thin)
                    .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - VToolbarPaletteButton

/// The `⌘K` command-palette control: the `command` glyph beside a key cap, on a bordered `md` pill.
///
/// Not a `VButton`, because `VButton`'s label is a title and a symbol and this one is a symbol and a
/// key cap — and the key cap is the whole point, since UX.md §3.2 specifies the shortcut as visible
/// chrome rather than as a tooltip. Everything else — the fill, the stroke, the focus ring, the
/// hit target — is the same token set `VButton(.secondary)` resolves to.
@MainActor
private struct VToolbarPaletteButton: View {

    let action: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.vMotionEnabled) private var motionEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: VTheme.Icon.Gap.md) {
                VTheme.Symbol.commandPalette.image()
                    .vIcon(size: VTheme.Icon.md, weight: VTheme.Symbol.commandPalette.weight)
                    .foregroundStyle(VTheme.Color.Text.secondary)
                VToolbarKeyCap(label: "⌘K")
            }
            .padding(.horizontal, VTheme.Space.sm)
            .frame(height: VTheme.Metrics.md)
            .background(VTheme.Color.Layer.surfaceRaised,
                        in: VTheme.Radius.shape(VTheme.Radius.md))
            .overlay {
                VTheme.Radius.shape(VTheme.Radius.md)
                    .strokeBorder(isHovering
                                    ? VTheme.Color.Stroke.strong
                                    : VTheme.Color.Stroke.default,
                                  lineWidth: VTheme.Border.thin)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .focusEffectDisabled()
        .vFocusRing(isFocused, radius: VTheme.Radius.md)
        .onHover { isHovering = $0 }
        .animation(VTheme.Motion.resolved(VTheme.Motion.micro, reduced: !motionEnabled),
                   value: isHovering)
        .accessibilityLabel(Text("Command palette", bundle: .vigilUI))
        .help(Text("Command palette", bundle: .vigilUI))
    }
}

// MARK: - Previews

#if DEBUG
#Preview("VToolbarView — sidebar shown") {
    VToolbarView(isSidebarVisible: true,
                 isInspectorVisible: true,
                 layout: .hero1p5,
                 searchText: .constant(""),
                 showsSeparator: true)
        .frame(width: 1080)
        .background(VTheme.Color.Layer.canvas)
}

#Preview("VToolbarView — sidebar hidden") {
    VToolbarView(isSidebarVisible: false,
                 isInspectorVisible: false,
                 layout: .grid3x3,
                 searchText: .constant("front"),
                 isCycling: true)
        .frame(width: 1080)
        .background(VTheme.Color.Layer.canvas)
}
#endif

#endif  // os(macOS)
