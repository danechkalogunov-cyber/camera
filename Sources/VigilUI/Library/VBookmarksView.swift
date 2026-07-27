//
//  VBookmarksView.swift
//  VigilUI
//
//  The LIBRARY ▸ Bookmarks screen: instants the user marked, grouped by day.
//  macOS-only. See docs/UX.md (Bookmarks) and §12.2 (the empty state).
//

#if os(macOS)

import Foundation
import SwiftUI

import VigilProtocols

// MARK: - VBookmarksView

/// Moments the user marked, newest first.
///
/// The simplest of the three screens on purpose: a bookmark is a pointer into a timeline, so the row
/// carries what is needed to recognise it and get back to it, and nothing else.
@MainActor
package struct VBookmarksView: View {

    // MARK: - Stored Properties

    /// The library snapshot.
    package let state: VLibraryState

    /// What the rows can ask for.
    package let actions: VLibraryActions

    // MARK: - Initialisation

    /// Creates the Bookmarks screen.
    ///
    /// - Parameters:
    ///   - state: the library snapshot; `bookmarks` is the part this screen reads.
    ///   - actions: open and delete.
    package init(state: VLibraryState, actions: VLibraryActions = VLibraryActions()) {
        self.state = state
        self.actions = actions
    }

    // MARK: - View

    package var body: some View {
        VStack(spacing: 0) {
            VLibraryHeader(title: VLibrarySection.bookmarks.title,
                           count: state.bookmarks.count) {
                EmptyView()
            }

            if state.bookmarks.isEmpty {
                emptyState
            } else {
                bookmarkList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VTheme.Color.Layer.canvas)
    }

    // MARK: - Private Helpers

    /// What to say when nothing has been marked.
    ///
    /// No action button: the only way to create a bookmark is from the timeline, and offering a
    /// button here that navigated somewhere else would be answering a question the user has not
    /// asked. The message names the gesture instead.
    private var emptyState: some View {
        VLibraryEmptyState(symbol: VLibrarySection.bookmarks.heroSymbol,
                           title: "No bookmarks yet",
                           message: "Mark a moment while reviewing an archive and it appears here.")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The bookmarks, newest first, under one header per day.
    private var bookmarkList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(dayGroups) { group in
                    Section {
                        ForEach(group.items) { bookmark in
                            VBookmarksRow(bookmark: bookmark,
                                          clock: state.clock,
                                          actions: actions)
                        }
                    } header: {
                        VLibraryDayHeader(day: group.day, clock: state.clock)
                    }
                }
            }
            .padding(.bottom, VTheme.Space.lg)
        }
    }

    /// Bookmarks grouped into local days, newest first, titles breaking ties.
    private var dayGroups: [VLibraryDayGroup<VLibraryBookmark>] {
        VLibraryGrouping.days(state.bookmarks,
                              clock: state.clock,
                              instant: { $0.instant },
                              tieBreak: { $0.title })
    }
}

// MARK: - VBookmarksRow

/// One bookmark.
@MainActor
package struct VBookmarksRow: View {

    // MARK: - Stored Properties

    /// The bookmark shown.
    package let bookmark: VLibraryBookmark

    /// The clock its instant is rendered in.
    package let clock: TimelineClock

    /// The handlers its controls call.
    package let actions: VLibraryActions

    @State private var isHovering = false

    // MARK: - Initialisation

    /// Creates a bookmark row.
    ///
    /// - Parameters:
    ///   - bookmark: the bookmark to show.
    ///   - clock: the calendar and zone its instant is formatted in.
    ///   - actions: open and delete.
    package init(bookmark: VLibraryBookmark, clock: TimelineClock, actions: VLibraryActions) {
        self.bookmark = bookmark
        self.clock = clock
        self.actions = actions
    }

    // MARK: - View

    package var body: some View {
        HStack(spacing: VTheme.Space.md) {
            identityTag
            titleBlock
            Spacer(minLength: VTheme.Space.sm)
            Text(verbatim: VLibraryTime.label(bookmark.instant, clock: clock))
                .vType(VTheme.Typography.monoSmall.numeric)
                .foregroundStyle(VTheme.Color.Text.secondary)
                .frame(width: VLibraryMetrics.measureColumn, alignment: .trailing)
            deleteControl
        }
        .padding(.horizontal, VTheme.Space.lg)
        .frame(height: VLibraryMetrics.eventRow)
        .modifier(VLibraryRowSurface(isHovering: isHovering))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { actions.onOpenBookmark(bookmark) }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Private Helpers

    /// The camera's identity square, so two cameras' bookmarks are told apart without reading.
    private var identityTag: some View {
        VTheme.Radius.shape(VTheme.Radius.xs)
            .fill(bookmark.camera.colour)
            .frame(width: VTheme.Icon.md, height: VTheme.Icon.md)
            .accessibilityHidden(true)
    }

    /// The user's title over the camera name, falling back to the timestamp.
    ///
    /// An untitled bookmark is normal — requiring a title at the moment of marking is what stops
    /// people marking anything — so the row shows the instant in its place rather than a blank line.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: VTheme.Space.hair) {
            Text(verbatim: bookmark.title.isEmpty
                    ? VLibraryTime.label(bookmark.instant, clock: clock)
                    : bookmark.title)
                .vType(VTheme.Typography.body)
                .foregroundStyle(VTheme.Color.Text.primary)
                .lineLimit(1)
            Text(verbatim: subtitle)
                .vType(VTheme.Typography.caption1)
                .foregroundStyle(VTheme.Color.Text.tertiary)
                .lineLimit(1)
        }
    }

    /// The camera name, with the note appended when there is one.
    private var subtitle: String {
        guard let note = bookmark.note, !note.isEmpty else { return bookmark.camera.name }
        return "\(bookmark.camera.name) · \(note)"
    }

    /// Delete, revealed on hover.
    @ViewBuilder
    private var deleteControl: some View {
        if isHovering {
            VButton(symbol: VTheme.Symbol.delete,
                    size: .sm,
                    accessibilityLabel: "Delete bookmark",
                    action: { actions.onDeleteBookmark(bookmark) })
                .transition(.opacity)
        }
    }
}

#endif  // os(macOS)
