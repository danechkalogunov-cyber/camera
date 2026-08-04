//
//  VInspectorControls.swift
//  VigilUI
//
//  The pieces every inspector tab is built from: the section eyebrow, the label/value row, the
//  monospaced value cell, the inline "Unavailable" notice and the per-tab empty state.
//  macOS-only. Implements design/mockups/01-main-window.html (the right panel), docs/DESIGN.md
//  §4.4, §9.20 and §5.4, and docs/UX.md §6.
//
//  Two rules from the mockup are structural rather than decorative and live here so no tab can
//  restate them differently:
//
//   1. **A row is a label on the left and a monospaced value on the right, and the value's number
//      has a reserved width.** DESIGN.md §4.4 exists because the inspector is the surface where
//      numbers change once a second; a proportional digit here makes the whole column breathe.
//      ``VInspectorRow`` supplies the geometry and ``VInspectorStatValue`` the reservation.
//   2. **Colour on a value comes from `InspectorHealth`, never from the view.** The tint enum in
//      `VInspectorFormat.swift` decides, this file only looks the token up. A threshold in a view
//      body is a threshold nobody can find.
//

#if os(macOS)

import SwiftUI

// MARK: - Tint → token

extension VInspectorHealthTint {

    /// The colour token this tint resolves to.
    ///
    /// `neutral` is `text.primary` rather than a hue: DESIGN.md P3 reserves colour for meaning, so
    /// a healthy reading is simply *text*. The three coloured cases are the reserved status
    /// vocabulary of §3.2 and nothing else.
    @MainActor
    package var colour: SwiftUI.Color {
        switch self {
        case .neutral: return VTheme.Color.Text.primary
        case .ok: return VTheme.Color.Semantic.ok
        case .warn: return VTheme.Color.Semantic.warn
        case .danger: return VTheme.Color.Semantic.danger
        }
    }
}

// MARK: - VInspectorMetrics

/// The panel's own geometry, in the component that owns it.
///
/// These are the numbers design/mockups/01-main-window.html fixes for the inspector and that
/// `VTheme` does not carry — exactly the arrangement `Components/FocusRing.swift` uses for its
/// 3 pt outset. Everything that *is* a token (spacing, radii, control heights, type) still comes
/// from `VTheme`; only these four measurements are local, and each cites where it came from.
@MainActor
package enum VInspectorMetrics {

    /// 24 pt. One label/value row — the `sm` control height (§5.5, ".kv{height:24px}").
    package static let rowHeight: CGFloat = VTheme.Metrics.sm

    /// 46 pt. The sparkline well (".chart{height:46px}").
    ///
    /// DESIGN.md §9.21 says "inspector 240 × 44" for the plot; the mockup's 46 is the well
    /// *including* its 1 pt hairline top and bottom. Same drawing, measured differently.
    package static let chartHeight: CGFloat = 46

    /// 6 pt. The storage bar (".storage{height:6px}"), which UX.md §6.1 also specifies as 6 pt.
    package static let meterHeight: CGFloat = 6

    /// 2 pt. The selected tab's underline (".tabs button.on::after{height:2px}") — the same weight
    /// as the selected-tile border (§5.4), which is what makes the two read as one system.
    package static let tabUnderline: CGFloat = 2
}

// MARK: - VInspectorSectionHeader

/// A section eyebrow: `BITRATE — LAST 60 S`, `TRANSPORT HEALTH`, `DEVICE`.
///
/// `Caption2` supplies the uppercase and the +0.5 pt tracking through ``SwiftUI/View/vType(_:)``,
/// so the key stays sentence-case and stays translatable — Russian has no equivalent of English's
/// "small caps as a heading" convention and the type step is where that decision belongs.
///
/// ⚠️ The mockup paints these `--text-dis`. `text.tertiary` is used instead: `text.disabled` is
/// 2.61:1 and DESIGN.md §3.2 reserves it for disabled controls that carry a second, non-colour
/// cue. A permanent heading is neither disabled nor exempt from AA. Reported.
@MainActor
package struct VInspectorSectionHeader: View {

    /// The heading, in sentence case; the type step uppercases it.
    package let title: LocalizedStringKey

    /// Creates a section eyebrow.
    package init(_ title: LocalizedStringKey) {
        self.title = title
    }

    package var body: some View {
        Text(title, bundle: .vigilUI)
            .vType(VTheme.Typography.caption2)
            .foregroundStyle(VTheme.Color.Text.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, VTheme.Space.md)
            .padding(.bottom, VTheme.Space.xxs)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - VInspectorHairline

/// A one-pixel rule.
///
/// ⛔ Never `Divider()` — its colour and its inset belong to AppKit rather than to us (§5.4). The
/// height is `1 / displayScale`, so it is one physical pixel on every display.
@MainActor
package struct VInspectorHairline: View {

    @Environment(\.displayScale) private var displayScale

    /// Creates a rule.
    package init() {}

    package var body: some View {
        Rectangle()
            .fill(VTheme.Color.Stroke.subtle)
            .frame(height: VTheme.Border.hairline(displayScale))
            .accessibilityHidden(true)
    }
}

// MARK: - VInspectorRow

/// One `label ………… value` row.
///
/// The label is `Callout` `text.tertiary` and the value is pushed to the trailing edge by a
/// `Spacer`, which is the mockup's `margin-left:auto`. The whole row is one accessibility element
/// so VoiceOver reads "Packet loss, 0.02 %" rather than two unrelated fragments.
@MainActor
package struct VInspectorRow<Value: View>: View {

    /// The row's label.
    package let label: LocalizedStringKey

    private let value: () -> Value

    /// Creates a row.
    ///
    /// - Parameters:
    ///   - label: the localised key for the leading label.
    ///   - value: the trailing content, normally a ``VInspectorStatValue`` or
    ///     ``VInspectorMonoValue``.
    package init(_ label: LocalizedStringKey, @ViewBuilder value: @escaping () -> Value) {
        self.label = label
        self.value = value
    }

    package var body: some View {
        HStack(spacing: VTheme.Space.sm) {
            Text(label, bundle: .vigilUI)
                .vType(VTheme.Typography.callout)
                .foregroundStyle(VTheme.Color.Text.tertiary)
                .lineLimit(1)
            Spacer(minLength: VTheme.Space.xs)
            value()
        }
        .frame(minHeight: VInspectorMetrics.rowHeight)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - VInspectorMonoValue

/// A value cell for a string the device gave us: a model number, an address, a MAC.
///
/// Monospaced because DESIGN.md §4.1 puts IP and MAC addresses, serials and device identifiers on
/// the Mono track — they are read character by character, not as words. `Text(verbatim:)` because
/// none of it is ours to translate.
@MainActor
package struct VInspectorMonoValue: View {

    /// The device's string, or `nil` for the em dash.
    package let text: String?

    /// Whether the value's digits change while it is on screen (uptime does; a MAC does not).
    package let isLive: Bool

    /// Creates a value cell.
    package init(_ text: String?, isLive: Bool = false) {
        self.text = text
        self.isLive = isLive
    }

    package var body: some View {
        let given = text ?? ""
        let resolved = given.isEmpty ? VInspectorFormat.placeholder : given
        return Text(verbatim: resolved)
            .vType(isLive ? VTheme.Typography.mono.numeric : VTheme.Typography.mono)
            .foregroundStyle(VTheme.Color.Text.primary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

// MARK: - VInspectorStatValue

/// A telemetry cell: a reserved-width number, its unit, and its health.
///
/// The value and the unit are separate `Text`s because §4.4 styles them differently and because
/// **only the value gets the reserved width** — reserving the unit too would right-align `Mb/s`
/// against `%` and make the column look broken.
///
/// Under `accessibilityDifferentiateWithoutColor` a warning or failure also grows its glyph, so the
/// level survives without hue (§10.5). VoiceOver hears the number and, when it matters, the level.
@MainActor
package struct VInspectorStatValue: View {

    /// The formatted reading, from `InspectorStat`'s own factories.
    package let stat: InspectorStat

    /// Whether a healthy reading earns the `ok` colour. See ``VInspectorHealthTint``.
    package let emphasisesHealth: Bool

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    /// Creates a telemetry cell.
    package init(_ stat: InspectorStat, emphasisesHealth: Bool = false) {
        self.stat = stat
        self.emphasisesHealth = emphasisesHealth
    }

    package var body: some View {
        let tint = VInspectorHealthTint(stat.level, emphasisesHealth: emphasisesHealth)
        return HStack(spacing: VTheme.Space.xxs) {
            if differentiate, let symbol = tint.symbol {
                symbol.image()
                    .vIcon(size: VTheme.Icon.xs, weight: VTheme.Icon.Weight.xs)
                    .foregroundStyle(tint.colour)
            }
            Text(verbatim: stat.value)
                .vType(VTheme.Typography.mono.numeric)
                .foregroundStyle(tint.colour)
                .vReserved(CGFloat(stat.reservedWidth))
            if !stat.unit.isEmpty {
                Text(verbatim: stat.unit)
                    .vType(VTheme.Typography.caption1)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue(Text(verbatim: stat.spoken))
    }
}

// MARK: - VInspectorNotice

/// The inline "Unavailable" badge with a retry glyph.
///
/// ⛔ A failed ISAPI fetch is **never** an alert (UX.md §6.1). It is this, sitting where the value
/// would have been, so the rest of the panel keeps working and the user keeps their place.
@MainActor
package struct VInspectorNotice: View {

    /// What could not be read.
    package let title: LocalizedStringKey

    /// Runs the fetch again.
    package let onRetry: () -> Void

    /// Creates a notice.
    package init(_ title: LocalizedStringKey, onRetry: @escaping () -> Void) {
        self.title = title
        self.onRetry = onRetry
    }

    package var body: some View {
        HStack(spacing: VTheme.Space.xs) {
            VTheme.Symbol.warning.image()
                .vIcon(size: VTheme.Icon.xs, weight: VTheme.Icon.Weight.xs)
                .foregroundStyle(VTheme.Color.Semantic.warn)
            Text(title, bundle: .vigilUI)
                .vType(VTheme.Typography.caption1)
                .foregroundStyle(VTheme.Color.Text.secondary)
            Spacer(minLength: VTheme.Space.xs)
            VButton(symbol: .reconnecting,
                    size: .xs,
                    accessibilityLabel: "Retry Now",
                    action: onRetry)
        }
        .padding(.horizontal, VTheme.Space.sm)
        .padding(.vertical, VTheme.Space.xxs)
        .background(VTheme.Color.Semantic.warn.opacity(0.12),
                    in: VTheme.Radius.shape(VTheme.Radius.sm))
    }
}

// MARK: - VInspectorEmptyState

/// A whole tab with nothing in it: no PTZ, no events, no camera selected.
///
/// UX.md §6 is explicit that the inspector is never blank, and §6.3 that the PTZ tab stays
/// selectable on a fixed camera — "predictable IA beats disappearing tabs". So an empty tab is a
/// sentence, not an absence.
@MainActor
package struct VInspectorEmptyState: View {

    /// The hero glyph.
    package let symbol: VTheme.Symbol

    /// One sentence, ending in a full stop (UX.md §14.1).
    package let title: LocalizedStringKey

    /// The line beneath, or `nil`.
    package let message: LocalizedStringKey?

    /// Creates an empty state.
    package init(symbol: VTheme.Symbol, title: LocalizedStringKey,
                 message: LocalizedStringKey? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
    }

    package var body: some View {
        VStack(spacing: VTheme.Space.sm) {
            symbol.image()
                .vIcon(size: VTheme.Icon.hero, weight: VTheme.Icon.Weight.hero)
                .foregroundStyle(VTheme.Color.Text.tertiary)
            Text(title, bundle: .vigilUI)
                .vType(VTheme.Typography.headline)
                .foregroundStyle(VTheme.Color.Text.primary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message, bundle: .vigilUI)
                    .vType(VTheme.Typography.caption1)
                    .foregroundStyle(VTheme.Color.Text.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, VTheme.Space.md)
        .padding(.vertical, VTheme.Space.huge)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - VInspectorSkeletonValue

/// The 80 pt bar that stands in for a device row while ISAPI is answering (UX.md §6.1, §9.19).
///
/// The size is the **real** content's box rather than a generic bar, which is what stops the panel
/// from moving when the value lands — the entire reason a skeleton beats a spinner.
@MainActor
package struct VInspectorSkeletonValue: View {

    /// The width to stand in for. 80 pt is UX.md §6.1's figure for a device row.
    package static let defaultWidth: CGFloat = 80

    /// How wide the absent value is.
    package let width: CGFloat

    /// Creates a placeholder.
    package init(width: CGFloat = VInspectorSkeletonValue.defaultWidth) {
        self.width = width
    }

    package var body: some View {
        VSkeleton(radius: VTheme.Radius.xs)
            .frame(width: width, height: VTheme.Typography.mono.size)
    }
}

// MARK: - Previews

#if DEBUG && !VIGIL_NO_PREVIEWS
#Preview("Inspector controls") {
    VStack(alignment: .leading, spacing: 0) {
        VInspectorSectionHeader("Transport health")
        VInspectorRow("Packet loss") {
            VInspectorStatValue(.loss(fraction: 0.0002), emphasisesHealth: true)
        }
        VInspectorRow("Jitter") { VInspectorStatValue(.jitter(milliseconds: 74)) }
        VInspectorRow("Latency") { VInspectorStatValue(.latency(milliseconds: 812)) }
        VInspectorRow("Model") { VInspectorMonoValue("DS-2CD2385G1") }
        VInspectorRow("Firmware") { VInspectorSkeletonValue() }
        VInspectorHairline()
        VInspectorNotice("Unavailable") {}
        VInspectorEmptyState(symbol: .events,
                             title: "No events yet.",
                             message: "Motion detection may be disabled on this camera.")
    }
    .padding(VTheme.Space.lg)
    .frame(width: VTheme.Metrics.inspectorWidth)
    .background(VTheme.Color.Layer.surface)
}
#endif

#endif  // os(macOS)
