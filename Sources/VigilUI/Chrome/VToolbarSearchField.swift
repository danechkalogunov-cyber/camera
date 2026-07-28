//
//  VToolbarSearchField.swift
//  VigilUI
//
//  The toolbar's own controls: the search field and what sits beside it.
//  macOS-only. Split from VToolbarView.swift, which docs/API_CONTRACT.md §7.2 caps at 600
//  lines. ⚠️ Separate top-level types, not extensions.
//

#if os(macOS)

import Foundation
import SwiftUI
import VigilProtocols

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
            // `cells` is computed, so it is read once here rather than once per iteration.
            let cells = layout.cells
            let unit = proxy.size.width / CGFloat(VGridLayout.units)
            ForEach(cells.indices, id: \.self) { index in
                cell(cells[index], unit: unit)
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
