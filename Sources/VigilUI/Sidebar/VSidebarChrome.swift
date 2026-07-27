//
//  VSidebarChrome.swift
//  VigilUI
//
//  The sidebar's non-camera furniture: the 28 pt link row every other line uses, the 22 pt section
//  eyebrow, and the 32 pt status footer.
//  macOS-only. Implements docs/DESIGN.md §9.12 and docs/UX.md §4.1 (sections and their `+`),
//  §3.3 (the footer's live count and aggregate rate).
//

#if os(macOS)

import Foundation

import SwiftUI

// MARK: - VSidebarLinkRow

/// The 28 pt row every non-camera line uses: the layout row, a group, a device header and the three
/// library links.
///
/// One type rather than four, because they differ only in which of four optional slots they fill —
/// a leading glyph, a leading identity tag, a trailing count and a selection — and four
/// near-identical row types is how two of them end up with different selection treatments.
@MainActor
package struct VSidebarLinkRow: View {

    // MARK: - Stored Properties

    /// The row's label, already localised by the caller.
    package let title: Text

    /// A leading glyph, or `nil` when the row carries an identity tag or nothing at all.
    package let symbol: VTheme.Symbol?

    /// The glyph's ink.
    package let symbolTint: SwiftUI.Color

    /// The identity colour of the leading rounded square, or `nil` for no tag.
    package let tagColour: SwiftUI.Color?

    /// The letter inside the tag, which keeps the colour from being the only cue (§3.4).
    package let tagInitial: Character?

    /// The trailing count, already formatted, or `nil` for none.
    package let badge: String?

    /// The badge's ink — `motion` for unread events, `text.tertiary` otherwise (UX.md §4.1).
    package let badgeTint: SwiftUI.Color

    /// Nesting depth.
    package let indent: Int

    /// Whether the row is the current selection.
    package let isSelected: Bool

    /// Whether the keyboard is on this row.
    package let isFocused: Bool

    /// Whether a drag is proposing to drop into this row. Only a group row ever accepts one.
    package let isDropTarget: Bool

    /// A click, carrying the modifiers that were held.
    package let onSelect: (VSidebarClick) -> Void

    /// A double-click.
    package let onActivate: () -> Void

    @Environment(\.vMotionEnabled) private var motionEnabled

    @State private var isHovering = false

    // MARK: - Initialisation

    /// Creates a link row.
    package init(title: Text,
                 symbol: VTheme.Symbol? = nil,
                 symbolTint: SwiftUI.Color = VTheme.Color.Text.secondary,
                 tagColour: SwiftUI.Color? = nil,
                 tagInitial: Character? = nil,
                 badge: String? = nil,
                 badgeTint: SwiftUI.Color = VTheme.Color.Text.tertiary,
                 indent: Int = 0,
                 isSelected: Bool = false,
                 isFocused: Bool = false,
                 isDropTarget: Bool = false,
                 onSelect: @escaping (VSidebarClick) -> Void = { _ in },
                 onActivate: @escaping () -> Void = {}) {
        self.title = title
        self.symbol = symbol
        self.symbolTint = symbolTint
        self.tagColour = tagColour
        self.tagInitial = tagInitial
        self.badge = badge
        self.badgeTint = badgeTint
        self.indent = indent
        self.isSelected = isSelected
        self.isFocused = isFocused
        self.isDropTarget = isDropTarget
        self.onSelect = onSelect
        self.onActivate = onActivate
    }

    // MARK: - View

    package var body: some View {
        HStack(spacing: VTheme.Space.sm) {
            leading
            title
                .vType(VTheme.Typography.body)
                .foregroundStyle(isSelected
                                    ? VTheme.Color.Text.primary
                                    : VTheme.Color.Text.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: VTheme.Space.xxs)
            trailingBadge
        }
        .padding(.horizontal, VTheme.Space.xs)
        .frame(height: VTheme.Metrics.Row.settings)
        .modifier(VSidebarRowSurface(isSelected: isSelected,
                                     isFocused: isFocused,
                                     isHovering: isHovering,
                                     isDropTarget: isDropTarget))
        .padding(.leading, CGFloat(indent) * VSidebarMetrics.indentStep)
        .onHover { hovering in
            withAnimation(VTheme.Motion.resolved(VTheme.Motion.micro, reduced: !motionEnabled)) {
                isHovering = hovering
            }
        }
        .onTapGesture(count: 2) { onActivate() }
        .onTapGesture { onSelect(VSidebarClick.current) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Private Helpers

    @ViewBuilder
    private var leading: some View {
        if let tagColour {
            tag(tagColour)
        } else if let symbol {
            symbol.image()
                .symbolRenderingMode(symbol.rendering)
                .vIcon(size: VTheme.Icon.sm, weight: symbol.weight)
                .foregroundStyle(symbolTint)
                .frame(width: VTheme.Icon.md, alignment: .center)
        }
    }

    @ViewBuilder
    private var trailingBadge: some View {
        if let badge {
            Text(verbatim: badge)
                .vType(VTheme.Typography.monoSmall.numeric)
                .foregroundStyle(badgeTint)
        }
    }

    /// A 14 pt rounded square in the identity colour, carrying the initial in ink.
    ///
    /// `text.inverse` is the correct ink in both appearances by construction: near-black on dark,
    /// where the identity colours are bright, and white on light, where they are dark.
    private func tag(_ colour: SwiftUI.Color) -> some View {
        VTheme.Radius.shape(VTheme.Radius.xs)
            .fill(colour)
            .frame(width: VSidebarMetrics.groupTag, height: VSidebarMetrics.groupTag)
            .overlay { tagLetter }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var tagLetter: some View {
        if let tagInitial {
            Text(String(tagInitial))
                .vType(VTheme.Typography.caption2)
                .foregroundStyle(VTheme.Color.Text.inverse)
        }
    }
}

// MARK: - VSidebarSectionHeader

/// A 22 pt uppercase eyebrow, with an optional `＋` and an optional disclosure state.
///
/// The disclosure chevron shows only while the header is hovered, or while the section is already
/// collapsed: the approved mockup has no chevron at rest, and a section the user has closed must
/// still say so when the pointer is somewhere else.
@MainActor
package struct VSidebarSectionHeader: View {

    // MARK: - Stored Properties

    /// The eyebrow's text. `Caption2` uppercases it, so pass it in sentence case.
    package let title: Text

    /// Whether the section can be collapsed. The LIVE section cannot (UX.md §4.1).
    package let isCollapsible: Bool

    /// Whether it currently is collapsed.
    package let isCollapsed: Bool

    /// The trailing `＋`'s glyph, or `nil` for a header with no add affordance.
    package let addSymbol: VTheme.Symbol?

    /// The `＋`'s VoiceOver label. Required whenever ``addSymbol`` is non-`nil`: a glyph is not
    /// speakable, and no two visible controls in a window may share a label (DESIGN.md §10.7).
    package let addLabel: LocalizedStringKey

    /// A trailing count shown before the `＋`, or `nil` for none.
    package let badge: String?

    /// Toggles the section's collapsed state.
    package let onToggle: () -> Void

    /// Runs the `＋`. Ignored when ``addSymbol`` is `nil`.
    package let onAdd: () -> Void

    @Environment(\.vMotionEnabled) private var motionEnabled

    @State private var isHovering = false

    // MARK: - Initialisation

    /// Creates a section header.
    package init(title: Text,
                 isCollapsible: Bool,
                 isCollapsed: Bool = false,
                 addSymbol: VTheme.Symbol? = nil,
                 addLabel: LocalizedStringKey = "",
                 badge: String? = nil,
                 onToggle: @escaping () -> Void = {},
                 onAdd: @escaping () -> Void = {}) {
        self.title = title
        self.isCollapsible = isCollapsible
        self.isCollapsed = isCollapsed
        self.addSymbol = addSymbol
        self.addLabel = addLabel
        self.badge = badge
        self.onToggle = onToggle
        self.onAdd = onAdd
    }

    // MARK: - View

    package var body: some View {
        HStack(spacing: VTheme.Space.xxs) {
            // The tap target stops at the title: a gesture spanning the whole row would compete
            // with the `＋`'s own `Button` for the same clicks.
            HStack(spacing: VTheme.Space.xxs) {
                chevron
                title
                    .vType(VTheme.Typography.caption2)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleIfPossible() }
            Spacer(minLength: VTheme.Space.xxs)
            trailingBadge
            addButton
        }
        .padding(.horizontal, VTheme.Space.xs)
        .frame(height: VTheme.Metrics.Row.sectionHeader)
        .onHover { hovering in
            withAnimation(VTheme.Motion.resolved(VTheme.Motion.micro, reduced: !motionEnabled)) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Private Helpers

    private func toggleIfPossible() {
        guard isCollapsible else { return }
        onToggle()
    }

    /// `chevron.down`, **rotated** rather than swapped — §8.3 makes the disclosure pair the one
    /// case that rotates instead of using `.symbolEffect(.replace)`.
    @ViewBuilder
    private var chevron: some View {
        if isCollapsible {
            VTheme.Symbol.disclosureExpanded.image()
                .vIcon(size: VTheme.Icon.xs, weight: VTheme.Symbol.disclosureExpanded.weight)
                .foregroundStyle(VTheme.Color.Text.disabled)
                .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                .opacity(isCollapsed || isHovering ? 1 : 0)
                .frame(width: VTheme.Icon.xs)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var trailingBadge: some View {
        if let badge {
            Text(verbatim: badge)
                .vType(VTheme.Typography.monoSmall.numeric)
                .foregroundStyle(VTheme.Color.Text.disabled)
        }
    }

    @ViewBuilder
    private var addButton: some View {
        if let addSymbol {
            VButton(symbol: addSymbol,
                    style: .icon,
                    size: .xs,
                    accessibilityLabel: addLabel,
                    action: onAdd)
        }
    }
}

// MARK: - VSidebarFooterView

/// The 32 pt status footer: `⚙ 6 live · 1.8 Gb/s`, and `⚙ 6 live · 1 degraded` the moment anything
/// is impaired, at which point the whole line turns `warn` (UX.md §3.3).
///
/// The count is a `Text(verbatim:)` around a `FormatStyle` result and the word beside it is a
/// separate localised run, rather than one interpolated sentence. "{n} live" is a count-bearing
/// phrase and Russian needs one/few/many for it; splitting the two keeps the pair out of the plural
/// table entirely, which is what the invariable `в эфире` translation is chosen for.
@MainActor
package struct VSidebarFooterView: View {

    /// How many cameras are showing a picture, impaired or not.
    package let liveCount: Int

    /// How many of those are impaired. Above zero the footer takes its warning form.
    package let degradedCount: Int

    /// Aggregate ingest across every camera in bits per second, sampled at 1 Hz by whatever owns
    /// the streams. `nil` omits the rate — which is the right thing to show before the first
    /// sample, rather than a confident `0 b/s`.
    package let bitsPerSecond: Double?

    /// Opens Settings.
    package let onOpenSettings: () -> Void

    /// Creates the footer.
    package init(liveCount: Int,
                 degradedCount: Int,
                 bitsPerSecond: Double? = nil,
                 onOpenSettings: @escaping () -> Void = {}) {
        self.liveCount = liveCount
        self.degradedCount = degradedCount
        self.bitsPerSecond = bitsPerSecond
        self.onOpenSettings = onOpenSettings
    }

    package var body: some View {
        HStack(spacing: VTheme.Space.xs) {
            VButton(symbol: .settings,
                    style: .icon,
                    size: .xs,
                    accessibilityLabel: "Settings",
                    action: onOpenSettings)
            Text(verbatim: liveCount.formatted(.number))
                .vType(VTheme.Typography.mono.numeric)
                .foregroundStyle(tint)
            Text("live", bundle: .vigilUI)
                .vType(VTheme.Typography.caption1)
                .foregroundStyle(tint)
            tail
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VTheme.Space.md)
        .frame(height: VSidebarMetrics.footerHeight)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var tail: some View {
        if degradedCount > 0 {
            separator
            Text(verbatim: degradedCount.formatted(.number))
                .vType(VTheme.Typography.mono.numeric)
                .foregroundStyle(VTheme.Color.Semantic.warn)
            Text("degraded", bundle: .vigilUI)
                .vType(VTheme.Typography.caption1)
                .foregroundStyle(VTheme.Color.Semantic.warn)
        } else if let bitsPerSecond {
            separator
            VSidebarBitrate.text(bitsPerSecond)
                .vType(VTheme.Typography.mono.numeric)
                .foregroundStyle(VTheme.Color.Text.secondary)
        }
    }

    private var separator: some View {
        Text(verbatim: "·")
            .vType(VTheme.Typography.caption1)
            .foregroundStyle(VTheme.Color.Text.disabled)
    }

    /// The whole footer turns `warn` the moment any camera is degraded (UX.md §3.3).
    private var tint: SwiftUI.Color {
        degradedCount > 0 ? VTheme.Color.Semantic.warn : VTheme.Color.Text.tertiary
    }
}

#endif  // os(macOS)
