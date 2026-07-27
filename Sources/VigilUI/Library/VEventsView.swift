//
//  VEventsView.swift
//  VigilUI
//
//  The LIBRARY ▸ Events screen: the device's event feed, grouped by day and filtered by kind.
//  macOS-only. See docs/UX.md §9.1 (the feed) and §12.2 (the empty state).
//

#if os(macOS)

import Foundation
import SwiftUI

import VigilProtocols

// MARK: - VEventsView

/// What the cameras reported, newest first.
///
/// Filtering is local state rather than a caller's concern: it changes nothing about what has been
/// fetched, so lifting it into `VLibraryState` would make every keystroke a round trip through the
/// app target for a decision this view can hold by itself.
@MainActor
package struct VEventsView: View {

    // MARK: - Stored Properties

    /// The library snapshot.
    package let state: VLibraryState

    /// What the rows can ask for.
    package let actions: VLibraryActions

    /// Kinds currently shown. Empty means everything — the resting state, so an untouched filter
    /// never hides anything.
    @State private var selectedKinds: Set<TimelineMarkerKind> = []

    // MARK: - Initialisation

    /// Creates the Events screen.
    ///
    /// - Parameters:
    ///   - state: the library snapshot; `events` is the part this screen reads.
    ///   - actions: open, delete, and the route to notification settings.
    package init(state: VLibraryState, actions: VLibraryActions = VLibraryActions()) {
        self.state = state
        self.actions = actions
    }

    // MARK: - View

    package var body: some View {
        VStack(spacing: 0) {
            VLibraryHeader(title: VLibrarySection.events.title, count: visibleEvents.count) {
                filterControl
            }

            if visibleEvents.isEmpty {
                emptyState
            } else {
                eventList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VTheme.Color.Layer.canvas)
    }

    // MARK: - Private Helpers

    /// One toggle per kind actually present in the feed.
    ///
    /// Only kinds that occur are offered. A filter for a kind this camera never raises is a control
    /// that can only ever empty the list, which reads as a bug rather than as a filter.
    @ViewBuilder
    private var filterControl: some View {
        if presentKinds.count > 1 {
            HStack(spacing: VTheme.Space.xs) {
                ForEach(presentKinds, id: \.self) { kind in
                    // `VChip` is a presentation container, not a control, so the toggle is a button
                    // whose style carries the selected state — secondary when on, ghost when off.
                    VButton(symbol: VInspectorEventsTab.symbol(for: kind),
                            style: selectedKinds.contains(kind) ? .secondary : .ghost,
                            size: .sm,
                            accessibilityLabel: "Filter events",
                            action: { toggle(kind) })
                }
            }
        }
    }

    /// What to say when the feed is empty.
    ///
    /// Two different messages, because the two situations need different next actions: an empty feed
    /// means events are not arriving at all, while an empty *filtered* feed means the user hid them.
    private var emptyState: some View {
        VLibraryEmptyState(symbol: VLibrarySection.events.heroSymbol,
                           title: selectedKinds.isEmpty ? "No events yet" : "Nothing matches",
                           message: selectedKinds.isEmpty
                               ? "Motion and tamper alerts appear here as cameras report them."
                               : "No events of the selected kinds. Clear the filter to see the rest.",
                           actionTitle: selectedKinds.isEmpty ? "Notification settings" : "Clear filter",
                           action: { selectedKinds.isEmpty ? actions.onOpenNotificationSettings()
                                                           : selectedKinds.removeAll() })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The events, newest first, under one header per day.
    private var eventList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(dayGroups) { group in
                    Section {
                        ForEach(group.items) { event in
                            VEventsRow(event: event, clock: state.clock, actions: actions)
                        }
                    } header: {
                        VLibraryDayHeader(day: group.day, clock: state.clock)
                    }
                }
            }
            .padding(.bottom, VTheme.Space.lg)
        }
    }

    /// The events passing the current filter.
    private var visibleEvents: [VLibraryEvent] {
        guard !selectedKinds.isEmpty else { return state.events }
        return state.events.filter { selectedKinds.contains($0.kind) }
    }

    /// The kinds actually present, in the enumeration's own order so the row does not reshuffle.
    private var presentKinds: [TimelineMarkerKind] {
        let present = Set(state.events.map(\.kind))
        return VLibraryEventKind.ordered.filter(present.contains)
    }

    /// Visible events grouped into local days.
    ///
    /// Grouped on `occurredAt` — the device's own instant — through `TimelineClock`, so an event
    /// during a daylight-saving transition lands on the day the user lived through. The label breaks
    /// ties so two simultaneous events keep a stable order.
    private var dayGroups: [VLibraryDayGroup<VLibraryEvent>] {
        VLibraryGrouping.days(visibleEvents,
                              clock: state.clock,
                              instant: { $0.occurredAt },
                              tieBreak: { $0.label })
    }

    /// Adds or removes a kind from the filter.
    private func toggle(_ kind: TimelineMarkerKind) {
        if selectedKinds.contains(kind) {
            selectedKinds.remove(kind)
        } else {
            selectedKinds.insert(kind)
        }
    }
}

// MARK: - VEventsRow

/// One event.
@MainActor
package struct VEventsRow: View {

    // MARK: - Stored Properties

    /// The event shown.
    package let event: VLibraryEvent

    /// The clock its timestamp is rendered in.
    package let clock: TimelineClock

    /// The handlers its controls call.
    package let actions: VLibraryActions

    @State private var isHovering = false

    // MARK: - Initialisation

    /// Creates an event row.
    ///
    /// - Parameters:
    ///   - event: the event to show.
    ///   - clock: the calendar and zone its instant is formatted in.
    ///   - actions: open and delete.
    package init(event: VLibraryEvent, clock: TimelineClock, actions: VLibraryActions) {
        self.event = event
        self.clock = clock
        self.actions = actions
    }

    // MARK: - View

    package var body: some View {
        HStack(spacing: VTheme.Space.md) {
            glyph
            titleBlock
            Spacer(minLength: VTheme.Space.sm)
            timestamp
            deleteControl
        }
        .padding(.horizontal, VTheme.Space.lg)
        .frame(height: VLibraryMetrics.eventRow)
        .modifier(VLibraryRowSurface(isHovering: isHovering))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { actions.onOpenEvent(event) }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Private Helpers

    /// The kind's glyph in the kind's colour.
    ///
    /// Both come from `VInspectorEventsTab`, which already owns that mapping against DESIGN.md §8.3
    /// and §3.2. A second table here is how "line crossing" ends up with two different icons.
    private var glyph: some View {
        VInspectorEventsTab.symbol(for: event.kind).image()
            .vIcon(size: VTheme.Icon.sm)
            .foregroundStyle(VInspectorEventsTab.colour(for: event.kind))
            .frame(width: VTheme.Icon.md)
            .accessibilityHidden(true)
    }

    /// The device's label over the camera name.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: VTheme.Space.hair) {
            HStack(spacing: VTheme.Space.xs) {
                Text(verbatim: event.label)
                    .vType(VTheme.Typography.body)
                    .foregroundStyle(VTheme.Color.Text.primary)
                    .lineLimit(1)
                if event.isUnread {
                    Circle()
                        .fill(VTheme.Color.Semantic.accent)
                        .frame(width: VTheme.Space.xxs, height: VTheme.Space.xxs)
                        .accessibilityHidden(true)
                }
            }
            Text(verbatim: event.camera.name)
                .vType(VTheme.Typography.caption)
                .foregroundStyle(VTheme.Color.Text.tertiary)
                .lineLimit(1)
        }
    }

    /// Time of day, and the duration when the condition lasted.
    private var timestamp: some View {
        VStack(alignment: .trailing, spacing: VTheme.Space.hair) {
            Text(verbatim: VLibraryTime.label(event.occurredAt, clock: clock))
                .vType(VTheme.Typography.monoSmall.numeric)
                .foregroundStyle(VTheme.Color.Text.secondary)
            if let seconds = event.durationSeconds {
                Text(verbatim: VLibraryFormat.duration(seconds: seconds))
                    .vType(VTheme.Typography.monoSmall.numeric)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
            }
        }
        .frame(width: VLibraryMetrics.measureColumn, alignment: .trailing)
    }

    /// Delete, revealed on hover.
    @ViewBuilder
    private var deleteControl: some View {
        if isHovering {
            VButton(symbol: VTheme.Symbol.delete,
                    size: .sm,
                    accessibilityLabel: "Delete event",
                    action: { actions.onDeleteEvent(event) })
                .transition(.opacity)
        }
    }
}

#endif  // os(macOS)
