//
//  VInspectorEventsTab.swift
//  VigilUI
//
//  The Events tab: this camera's recent events, filtered by type, grouped by day, each one a jump
//  into Playback.
//  macOS-only. Implements docs/UX.md §6.5 and docs/DESIGN.md §4.4, §9.9 (filter chips).
//
//  ⚠️ Two things UX.md §6.5 asks for are absent, both for the same reason — no type in this package
//  carries them:
//
//   * **Thumbnails.** §6.5 puts a 64 × 36 image on each row. ``InspectorEvent`` carries
//     `hasThumbnail` but no image and no cache path, so the row draws the event-type glyph in the
//     same 64 × 36 box. Dropping a picture in later is a change of contents, not of layout.
//   * **Relative time** ("4 min ago", refreshed at 15 s). Rendering it correctly in Russian needs
//     plural agreement and therefore a `.stringsdict` entry, and this slice does not own those
//     files beyond appending flat keys to them. The absolute clock time is shown instead, in
//     monospaced digits, which is also what §6.5 shows on hover. Reported.
//

#if os(macOS)

import Foundation

import SwiftUI

// MARK: - VInspectorEventsTab

/// UX.md §6.5.
@MainActor
package struct VInspectorEventsTab: View {

    // MARK: - Geometry

    /// 64 × 36 pt, UX.md §6.5's thumbnail box.
    package static let thumbnailWidth: CGFloat = 64

    /// See ``thumbnailWidth``.
    package static let thumbnailHeight: CGFloat = 36

    // MARK: - Stored Properties

    /// The panel's snapshot.
    package let state: VInspectorState

    /// The panel's handlers.
    package let actions: VInspectorActions

    /// The type filter. Local view state on purpose: it is a way of looking at the list rather than
    /// a fact about the camera, so it does not belong in ``VInspectorState``.
    @State private var filter: TimelineMarkerKind?

    @Environment(\.calendar) private var calendar

    /// Creates the tab.
    package init(state: VInspectorState, actions: VInspectorActions) {
        self.state = state
        self.actions = actions
    }

    // MARK: - View

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.events.isEmpty {
                VInspectorEmptyState(symbol: .events,
                                     title: "No events yet.",
                                     message: "Motion detection may be disabled on this camera.")
            } else {
                filterChips
                list
            }
        }
    }

    // MARK: - Filter

    /// One chip per type actually present, plus `All`.
    ///
    /// Only the kinds this camera has produced are offered: a filter for a type with no rows behind
    /// it is a control that can only ever empty the list.
    @ViewBuilder
    private var filterChips: some View {
        VInspectorSectionHeader("Filters")
        ScrollView(.horizontal) {
            HStack(spacing: VTheme.Space.xxs) {
                filterChip(nil, title: "All")
                ForEach(presentKinds, id: \.self) { kind in
                    filterChip(kind, title: Self.title(for: kind))
                }
            }
            .padding(.vertical, VTheme.Space.hair)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func filterChip(_ kind: TimelineMarkerKind?,
                            title: LocalizedStringKey) -> some View {
        let isSelected = filter == kind
        return Button {
            filter = kind
        } label: {
            VChip(isSelected ? .selected : .neutral) {
                Text(title, bundle: .vigilUI)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The kinds present in the current event list, in severity order so the alarming ones lead.
    private var presentKinds: [TimelineMarkerKind] {
        var seen: [TimelineMarkerKind] = []
        for event in state.events where !seen.contains(event.kind) {
            seen.append(event.kind)
        }
        return seen.sorted { $0.severity > $1.severity }
    }

    // MARK: - List

    /// Day groups with their headers, newest first.
    @ViewBuilder
    private var list: some View {
        let groups = dayGroups
        if groups.isEmpty {
            Text("No events of this type.", bundle: .vigilUI)
                .vType(VTheme.Typography.caption1)
                .foregroundStyle(VTheme.Color.Text.tertiary)
                .padding(.top, VTheme.Space.sm)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups, id: \.day) { group in
                    Text(group.day, format: .dateTime.day().month(.wide).year())
                        .vType(VTheme.Typography.caption2)
                        .foregroundStyle(VTheme.Color.Text.tertiary)
                        .padding(.top, VTheme.Space.md)
                        .padding(.bottom, VTheme.Space.xxs)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.events) { event in
                        eventRow(event)
                    }
                }
            }
        }
    }

    /// The filtered events, bucketed by device-local day and kept in the order they arrived.
    ///
    /// Grouping walks the list once rather than sorting it: the caller hands them over newest
    /// first, and re-sorting here would silently discard a deliberate ordering.
    private var dayGroups: [VInspectorEventDay] {
        var groups: [VInspectorEventDay] = []
        for event in state.events where filter == nil || event.kind == filter {
            let day = calendar.startOfDay(for: event.instant)
            if let index = groups.lastIndex(where: { $0.day == day }) {
                groups[index].events.append(event)
            } else {
                groups.append(VInspectorEventDay(day: day, events: [event]))
            }
        }
        return groups
    }

    /// One event.
    private func eventRow(_ event: InspectorEvent) -> some View {
        Button {
            actions.onOpenEvent(event)
        } label: {
            HStack(spacing: VTheme.Space.sm) {
                thumbnail(event)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: event.label)
                        .vType(VTheme.Typography.body)
                        .foregroundStyle(VTheme.Color.Text.primary)
                        .lineLimit(1)
                    HStack(spacing: VTheme.Space.xxs) {
                        Text(event.instant, format: .dateTime.hour().minute().second())
                            .vType(VTheme.Typography.monoSmall.numeric)
                            .foregroundStyle(VTheme.Color.Text.tertiary)
                        if let duration = event.duration {
                            Text(verbatim: VInspectorFormat.duration(seconds: duration))
                                .vType(VTheme.Typography.monoSmall.numeric)
                                .foregroundStyle(VTheme.Color.Text.disabled)
                        }
                    }
                }
                Spacer(minLength: VTheme.Space.xs)
                VTheme.Symbol.play.image()
                    .vIcon(size: VTheme.Icon.xs, weight: VTheme.Icon.Weight.xs)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
            }
            .padding(.vertical, VTheme.Space.xxs)
            .frame(minHeight: VTheme.Metrics.Row.event)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Open in playback", bundle: .vigilUI))
    }

    /// The 64 × 36 box. It holds the type glyph until a real thumbnail exists to put in it.
    private func thumbnail(_ event: InspectorEvent) -> some View {
        Self.symbol(for: event.kind).image()
            .vIcon(size: VTheme.Icon.md, weight: VTheme.Icon.Weight.md)
            .foregroundStyle(Self.colour(for: event.kind))
            .frame(width: Self.thumbnailWidth, height: Self.thumbnailHeight)
            .background(VTheme.Color.Layer.inset, in: VTheme.Radius.shape(VTheme.Radius.xs))
            .overlay {
                VTheme.Radius.shape(VTheme.Radius.xs)
                    .strokeBorder(VTheme.Color.Stroke.subtle, lineWidth: VTheme.Border.thin)
                    .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }

    // MARK: - Kind vocabulary

    /// The glyph for an event type (DESIGN.md §8.3's Events group).
    ///
    /// Declared as a static here rather than as an extension on `TimelineMarkerKind`: that type
    /// belongs to `Timeline/`, and adding a member to it from this directory is how two slices end
    /// up declaring the same property.
    nonisolated static func symbol(for kind: TimelineMarkerKind) -> VTheme.Symbol {
        switch kind {
        case .motion: return .motionDetection
        case .lineCrossing: return .lineCrossing
        case .intrusion: return .intrusion
        case .tamper: return .tamper
        case .videoLoss: return .videoLoss
        case .alarm: return .warning
        case .bookmark: return .bookmark
        }
    }

    /// The reserved status colour for an event type (DESIGN.md §3.2).
    @MainActor
    static func colour(for kind: TimelineMarkerKind) -> SwiftUI.Color {
        switch kind {
        case .motion, .lineCrossing, .intrusion: return VTheme.Color.Semantic.motion
        case .tamper, .videoLoss, .alarm: return VTheme.Color.Semantic.danger
        case .bookmark: return VTheme.Color.Semantic.accent
        }
    }

    /// The filter chip's label. The row's own label is the caller's localised string; these are the
    /// type names, which this module does own.
    nonisolated static func title(for kind: TimelineMarkerKind) -> LocalizedStringKey {
        switch kind {
        case .motion: return "Motion"
        case .lineCrossing: return "Line crossing"
        case .intrusion: return "Intrusion"
        case .tamper: return "Tamper"
        case .videoLoss: return "Video loss"
        case .alarm: return "Alarm"
        case .bookmark: return "Bookmark"
        }
    }
}

// MARK: - VInspectorEventDay

/// One day's worth of events, for the sticky group headers.
package struct VInspectorEventDay: Sendable, Hashable, Identifiable {

    /// Device-local midnight; also the group's identity.
    package let day: Date

    /// The events on that day, in the order the caller supplied.
    package var events: [InspectorEvent]

    package var id: Date { day }

    /// Creates a day group.
    package init(day: Date, events: [InspectorEvent]) {
        self.day = day
        self.events = events
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Events — populated") {
    ScrollView {
        VInspectorEventsTab(state: .previewHealthy, actions: VInspectorActions())
            .padding(VTheme.Space.lg)
    }
    .frame(width: VTheme.Metrics.inspectorWidth, height: 520)
    .background(VTheme.Color.Layer.surface)
}

#Preview("Events — empty") {
    ScrollView {
        VInspectorEventsTab(
            state: VInspectorState(camera: LiveCameraIdentity(id: UUID(),
                                                              name: "Back Gate",
                                                              host: "192.168.1.71")),
            actions: VInspectorActions())
            .padding(VTheme.Space.lg)
    }
    .frame(width: VTheme.Metrics.inspectorWidth, height: 360)
    .background(VTheme.Color.Layer.surface)
}
#endif

#endif  // os(macOS)
