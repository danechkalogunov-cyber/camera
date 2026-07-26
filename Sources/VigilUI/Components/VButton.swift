//
//  VButton.swift
//  VigilUI
//
//  The one button in Vigil: five styles, five sizes, and the six states every component declares.
//  macOS-only. Implements docs/DESIGN.md §9.1, §5.5 (heights), §7.4 #24 (press), §9.28 (focus).
//

#if os(macOS)

import SwiftUI

// MARK: - VButton

/// A button.
///
/// Only **one** `.primary` button may be visible in any container; a second one becomes
/// `.secondary`. `.destructive` requires a confirmation unless the action is undoable (§9.1).
///
/// Over a video well every style resolves to the solid scrim ladder with a `Stroke.onVideo`
/// hairline and **no** shadow, because a material over video frosts the canvas behind the picture
/// and a shadow over live imagery is a dirty smear (§2.3, §6.3). The switch is automatic: the
/// button reads `\.vOnVideo`, which the well publishes for its subtree.
@MainActor
package struct VButton: View {

    // MARK: - Style

    /// The five button styles of §9.1.
    package enum Style: Sendable, Hashable {

        /// The single most important action in its container: `accentFill`, white label, E1.
        case primary

        /// The default: `surfaceRaised` with a `stroke.default` hairline.
        case secondary

        /// No fill and no stroke until hovered. Toolbars, cards, tile overlays.
        case ghost

        /// `dangerFill`, white label. Requires a confirmation unless the action is undoable.
        case destructive

        /// Icon-only, square at its size, no fill until hovered.
        case icon

        /// Whether the label is set in `Headline` rather than `Body`, and carries white ink on a
        /// coloured fill.
        package var isEmphasised: Bool {
            self == .primary || self == .destructive
        }
    }

    // MARK: - Size

    /// The five control heights of §5.5. There are no others.
    package enum Size: Sendable, Hashable {

        /// 20 pt — tile HUD chips, table cells.
        case xs

        /// 24 pt — inspector rows, the tile overlay's actions.
        case sm

        /// 28 pt — **the default**: toolbar, forms, menus.
        case md

        /// 32 pt — primary sheet actions, the search field.
        case lg

        /// 40 pt — the empty-state call to action and onboarding only.
        case xl

        /// The geometry that follows from the height: radius, padding, type step, icon size.
        ///
        /// `@MainActor` on the *member*, not on `Size`: a nested type does **not** inherit its
        /// enclosing type's global actor, so this accessor would otherwise be nonisolated and could
        /// not read `VTheme.Metrics`, which is `@MainActor`. Isolating the member rather than the
        /// enum keeps `Size` a plain `Sendable` value that a non-main context can still name.
        @MainActor
        package var control: VTheme.Metrics.Control {
            switch self {
            case .xs: return VTheme.Metrics.controlXS
            case .sm: return VTheme.Metrics.controlSM
            case .md: return VTheme.Metrics.controlMD
            case .lg: return VTheme.Metrics.controlLG
            case .xl: return VTheme.Metrics.controlXL
            }
        }
    }

    // MARK: - Geometry

    /// Multi-word labels never wrap; they truncate at the tail beyond this width (§9.1).
    package static let maxLabelWidth: CGFloat = 220

    // MARK: - Stored Properties

    /// The label. `nil` for an icon-only button, which then requires ``symbol``.
    package let title: LocalizedStringKey?

    /// The leading glyph, as a typed case rather than a string literal (§8.3).
    package let symbol: VTheme.Symbol?

    /// One of the five styles.
    package let style: Style

    /// One of the five heights.
    package let size: Size

    /// While `true` the label fades out and a ring fades in **at the same width**, so the button
    /// never resizes mid-action (§9.1, loading row).
    package let isLoading: Bool

    /// A speakable, distinct VoiceOver label. Required for an icon-only button, where the glyph
    /// carries the meaning: "Snapshot", never "button" (§10.7, Voice Control).
    package let accessibilityLabel: LocalizedStringKey?

    private let action: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.vOnVideo) private var onVideo

    // MARK: - Initialisation

    /// Creates a button with a label and an optional leading glyph.
    ///
    /// - Parameters:
    ///   - title: the label. Buttons are verbs naming the outcome — `Update Password`, never `OK`
    ///     where a verb exists (UX.md §14.1 rule 6).
    ///   - symbol: an optional leading glyph.
    ///   - style: one of the five styles.
    ///   - size: one of the five heights; `.md` by default.
    ///   - isLoading: replaces the label with a ring without changing the button's width.
    ///   - action: performed on click, on `Return` when the button is focused, and via any
    ///     `.keyboardShortcut` the call site attaches.
    package init(_ title: LocalizedStringKey,
                 symbol: VTheme.Symbol? = nil,
                 style: Style,
                 size: Size = .md,
                 isLoading: Bool = false,
                 action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.style = style
        self.size = size
        self.isLoading = isLoading
        self.accessibilityLabel = nil
        self.action = action
    }

    /// Creates an icon-only button, square at its size.
    ///
    /// - Parameters:
    ///   - symbol: the glyph.
    ///   - style: normally `.icon`.
    ///   - size: one of the five heights.
    ///   - isLoading: replaces the glyph with a ring.
    ///   - accessibilityLabel: **required** — the glyph is not speakable, and no two visible
    ///     controls in a window may share a label (§10.7).
    ///   - action: performed on click.
    package init(symbol: VTheme.Symbol,
                 style: Style = .icon,
                 size: Size = .md,
                 isLoading: Bool = false,
                 accessibilityLabel: LocalizedStringKey,
                 action: @escaping () -> Void) {
        self.title = nil
        self.symbol = symbol
        self.style = style
        self.size = size
        self.isLoading = isLoading
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    // MARK: - View

    package var body: some View {
        Button(action: action) {
            label
        }
        .buttonStyle(VButtonSurface(style: style, size: size, onVideo: onVideo,
                                    isLoading: isLoading))
        .focused($isFocused)
        // Ours is the only focus ring; the system's would double-draw with it (§9.28).
        .focusEffectDisabled()
        .vFocusRing(isFocused,
                    radius: size.control.radius,
                    outset: onVideo ? VFocusRing.outsetOnVideo : VFocusRing.outsetChrome)
        .accessibilityLabel(accessibilityText)
        .allowsHitTesting(!isLoading)
    }

    // MARK: - Private Helpers

    @ViewBuilder
    private var label: some View {
        HStack(spacing: size.control.iconGap) {
            if let symbol {
                symbol.image()
                    .symbolRenderingMode(symbol.rendering)
                    .vIcon(size: size.control.icon, weight: symbol.weight)
            }
            if let title {
                Text(title, bundle: .vigilUI)
                    .vType(typeStep)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: Self.maxLabelWidth)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    /// `Headline` on the two emphasised styles at the two sizes where the scale offers a semibold
    /// 13 pt partner to `Body`; the control's own step everywhere else (§9.1).
    private var typeStep: VTheme.Typography.Step {
        guard style.isEmphasised else { return size.control.type }
        switch size {
        case .md, .lg: return VTheme.Typography.headline
        case .xs, .sm, .xl: return size.control.type
        }
    }

    private var accessibilityText: Text {
        if let accessibilityLabel {
            return Text(accessibilityLabel, bundle: .vigilUI)
        }
        if let title {
            return Text(title, bundle: .vigilUI)
        }
        return Text(verbatim: "")
    }
}

// MARK: - VButtonSurface

/// Everything §9.1's state table says about a button's fill, stroke, ink, scale and shadow.
///
/// A `ButtonStyle` rather than a modifier chain because only a `ButtonStyle` is handed the real
/// pressed state; hover is tracked here too so that the two cannot disagree.
@MainActor
package struct VButtonSurface: ButtonStyle {

    /// The style whose row of §9.1 to apply.
    package let style: VButton.Style

    /// The height and the geometry that follows from it.
    package let size: VButton.Size

    /// Whether the button sits on a video well, which replaces every fill with the scrim ladder.
    package let onVideo: Bool

    /// Whether the label is currently replaced by a ring.
    package let isLoading: Bool

    package func makeBody(configuration: Configuration) -> some View {
        VButtonBody(configuration: configuration, style: style, size: size,
                    onVideo: onVideo, isLoading: isLoading)
    }
}

// MARK: - VButtonBody

/// The rendered surface. Separate from ``VButtonSurface`` because it needs `@State` for the
/// hover flag and for the minimum press dwell, which a `ButtonStyle` value cannot hold.
@MainActor
package struct VButtonBody: View {

    /// The button's pressed state and label, from the style.
    package let configuration: ButtonStyleConfiguration

    /// See ``VButtonSurface/style``.
    package let style: VButton.Style

    /// See ``VButtonSurface/size``.
    package let size: VButton.Size

    /// See ``VButtonSurface/onVideo``.
    package let onVideo: Bool

    /// See ``VButtonSurface/isLoading``.
    package let isLoading: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.vMotionEnabled) private var motionEnabled

    @State private var isHovering = false
    @State private var isHeld = false
    @State private var pressedAt: Date?

    // MARK: - View

    package var body: some View {
        let control = size.control
        return configuration.label
            .foregroundStyle(foreground)
            .opacity(isLoading ? 0 : 1)
            .overlay { loadingRing }
            .padding(.horizontal, isIconOnly ? 0 : control.horizontalPadding)
            .frame(minWidth: isIconOnly ? control.height : nil, minHeight: control.height)
            .background(fill, in: VTheme.Radius.shape(control.radius))
            .overlay { border }
            .compositingGroup()
            .shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
            .scaleEffect(pressScale)
            // A forgiving target under a moving cursor: 32 × 32 on video, 24 × 24 minimum
            // elsewhere, even when the glyph is 11 pt (§10.6). The content shape comes *after*
            // the frame so the expanded area is what actually receives the click.
            .frame(minWidth: minimumTarget, minHeight: minimumTarget)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(VTheme.Motion.resolved(VTheme.Motion.micro, reduced: !motionEnabled),
                       value: isHovering)
            .animation(VTheme.Motion.resolved(VTheme.Motion.snap, reduced: !motionEnabled),
                       value: isHeld)
            .task(id: configuration.isPressed) { await holdPress() }
    }

    // MARK: - Press dwell

    /// Holds the pressed visual for at least `pressMin` (80 ms) so that a fast click is still
    /// *seen* (§7.2, §7.4 #24). `.task(id:)` cancels the pending release when the button is
    /// pressed again, so a double-click cannot leave the surface stuck.
    private func holdPress() async {
        if configuration.isPressed {
            pressedAt = Date.now
            isHeld = true
            return
        }
        guard isHeld else { return }
        let elapsed = pressedAt.map { Date.now.timeIntervalSince($0) } ?? VTheme.Motion.Delay.pressMin
        let remaining = VTheme.Motion.Delay.pressMin - elapsed
        if remaining > 0 {
            try? await Task.sleep(for: .seconds(remaining))
        }
        isHeld = false
    }

    // MARK: - Appearance

    private var isIconOnly: Bool {
        style == .icon
    }

    private var minimumTarget: CGFloat {
        onVideo ? VTheme.Metrics.videoHitTarget : VTheme.Metrics.minHitTarget
    }

    /// White ink on a coloured fill is the specification's own value (§9.1): white on `accentFill`
    /// measures 5.86:1 and on `dangerFill` 5.12:1, and neither fill exists in a light variant that
    /// would need a different ink.
    private var foreground: SwiftUI.Color {
        guard isEnabled else {
            return style.isEmphasised
                ? SwiftUI.Color.white.opacity(0.45)
                : VTheme.Color.Text.disabled
        }
        if style.isEmphasised {
            return SwiftUI.Color.white
        }
        if onVideo {
            return VTheme.Color.Text.primary
        }
        switch style {
        case .secondary:
            return VTheme.Color.Text.primary
        case .ghost, .icon:
            return isHovering ? VTheme.Color.Text.primary : VTheme.Color.Text.secondary
        case .primary, .destructive:
            return SwiftUI.Color.white
        }
    }

    private var fill: SwiftUI.Color {
        guard isEnabled else { return disabledFill }
        if onVideo {
            // §2.3: the scrim ladder, inside the button's own shape, and never a material.
            return isHeld || isHovering ? VTheme.Color.Scrim.strong : VTheme.Color.Scrim.base
        }
        switch style {
        case .primary:
            if isHeld { return VTheme.Color.Semantic.accentPressed }
            return isHovering ? VTheme.Color.Semantic.accentHover : VTheme.Color.Semantic.accentFill
        case .destructive:
            if isHeld { return VTheme.Color.Semantic.dangerFill.opacity(0.86) }
            return isHovering
                ? VTheme.Color.Semantic.danger.opacity(0.92)
                : VTheme.Color.Semantic.dangerFill
        case .secondary:
            if isHeld { return SwiftUI.Color.white.opacity(0.10) }
            return VTheme.Color.Layer.surfaceRaised
        case .ghost, .icon:
            if isHeld { return SwiftUI.Color.white.opacity(0.10) }
            return isHovering ? SwiftUI.Color.white.opacity(0.06) : SwiftUI.Color.clear
        }
    }

    private var disabledFill: SwiftUI.Color {
        switch style {
        case .primary: return VTheme.Color.Semantic.accentFill.opacity(0.30)
        case .destructive: return VTheme.Color.Semantic.dangerFill.opacity(0.30)
        case .secondary: return VTheme.Color.Layer.surface
        case .ghost, .icon: return SwiftUI.Color.clear
        }
    }

    @ViewBuilder
    private var border: some View {
        if let stroke = strokeColour {
            VTheme.Radius.shape(size.control.radius)
                .strokeBorder(stroke, lineWidth: VTheme.Border.thin)
                .allowsHitTesting(false)
        }
    }

    private var strokeColour: SwiftUI.Color? {
        if onVideo {
            return isHovering
                ? VTheme.Color.Stroke.onVideoStrong
                : VTheme.Color.Stroke.onVideo
        }
        guard style == .secondary else { return nil }
        guard isEnabled else { return VTheme.Color.Stroke.subtle }
        return isHovering ? VTheme.Color.Stroke.strong : VTheme.Color.Stroke.default
    }

    /// E1 for the two filled styles on chrome; nothing anywhere else, and **never** over video
    /// (§6.3). The values are the `VTheme.Elevation.e1` token rather than literals.
    private var shadow: VTheme.Elevation.Shadow {
        let none = VTheme.Elevation.Shadow(alpha: 0, radius: 0, y: 0)
        guard !onVideo, isEnabled, !isHeld, style.isEmphasised else { return none }
        return VTheme.Elevation.e1.shadow(0, scheme) ?? none
    }

    /// Pressed shrinks to 0.97, and to 0.985 at `xl` where 3 % of 40 pt is too much travel (§9.1).
    private var pressScale: CGFloat {
        guard isHeld, motionEnabled else { return 1 }
        return size == .xl ? 0.985 : 0.97
    }

    @ViewBuilder
    private var loadingRing: some View {
        if isLoading {
            VProgressRing(progress: nil,
                          size: .small,
                          tint: style.isEmphasised ? SwiftUI.Color.white
                                                   : VTheme.Color.Semantic.accent,
                          onVideo: onVideo)
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("VButton") {
    VStack(alignment: .leading, spacing: VTheme.Space.sm) {
        VButton("Connect", style: .primary, size: .lg) {}
        VButton("Connect", style: .primary, size: .lg, isLoading: true) {}
        VButton("Add Manually", symbol: .addCamera, style: .secondary) {}
        VButton("Diagnose", style: .ghost, size: .sm) {}
        VButton("Delete Camera", style: .destructive) {}
        VButton(symbol: .snapshot, size: .md, accessibilityLabel: "Snapshot") {}
        VButton("Connect", style: .primary, size: .lg) {}.disabled(true)
    }
    .padding(VTheme.Space.xl)
    .background(VTheme.Color.Layer.canvas)
}
#endif

#endif  // os(macOS)
