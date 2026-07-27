//
//  VRecordingsView.swift
//  VigilUI
//
//  The LIBRARY ▸ Recordings screen: the archive scrubber over the list of clips written locally.
//  macOS-only. See docs/UX.md (Recordings) and design/mockups/03-playback.html.
//

#if os(macOS)

import Foundation
import SwiftUI

import VigilProtocols

// MARK: - VRecordingsView

/// Clips Vigil has written to this Mac, under the archive timeline.
///
/// **The timeline's first appearance.** `VTimelineView` and its six drawing files sit on ten files of
/// tested geometry, ruler, segment-index and DST-correct day maths, and until this screen existed
/// none of it had ever been on screen. `VLibraryArchive` was shaped as that view's parameter bag, so
/// mounting is a pass-through and no layout decision is taken twice.
///
/// **The empty state is the state that ships.** Nothing records yet, so an empty list is what a user
/// will actually see, and it says where clips would appear rather than showing a bare "no items".
@MainActor
package struct VRecordingsView: View {

    // MARK: - Stored Properties

    /// The library snapshot.
    package let state: VLibraryState

    /// What the rows and the scrubber can ask for.
    package let actions: VLibraryActions

    // MARK: - Initialisation

    /// Creates the Recordings screen.
    ///
    /// - Parameters:
    ///   - state: the library snapshot; `clips` and `archive` are the parts this screen reads.
    ///   - actions: the handlers for playback, reveal, delete and scrubbing.
    package init(state: VLibraryState, actions: VLibraryActions = VLibraryActions()) {
        self.state = state
        self.actions = actions
    }

    // MARK: - View

    package var body: some View {
        VStack(spacing: 0) {
            VLibraryHeader(title: VLibrarySection.recordings.title, count: state.clips.count) {
                if state.recordingsFolder != nil {
                    VButton("Open folder",
                            symbol: VTheme.Symbol.storage,
                            style: .ghost,
                            size: .sm,
                            action: actions.onOpenRecordingsFolder)
                }
            }

            archiveScrubber

            if state.clips.isEmpty {
                emptyState
            } else {
                clipList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VTheme.Color.Layer.canvas)
    }

    // MARK: - Private Helpers

    /// The archive timeline, when a camera and a day have been chosen.
    ///
    /// Absent rather than empty when `archive` is `nil`: a scrubber over no day would offer to seek
    /// into nothing, and a control that cannot act is worse than one that is not there.
    @ViewBuilder
    private var archiveScrubber: some View {
        if let archive = state.archive {
            VTimelineView(tracks: archive.tracks,
                          day: archive.day,
                          window: archive.window,
                          zoom: archive.zoom,
                          clock: state.clock,
                          playhead: archive.playhead,
                          isScrubbing: archive.isScrubbing,
                          isLoading: archive.isLoading,
                          magnetismEnabled: archive.magnetismEnabled,
                          preview: archive.preview,
                          onScrub: actions.onScrub,
                          onHoverInstant: actions.onHoverInstant,
                          onZoom: actions.onZoom,
                          onActivateMarker: actions.onActivateMarker)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(VTheme.Color.Stroke.subtle)
                        .frame(height: VTheme.Border.hairline(1))
                }
        }
    }

    /// What to say when nothing has been recorded.
    private var emptyState: some View {
        VLibraryEmptyState(symbol: VLibrarySection.recordings.heroSymbol,
                           title: "No recordings yet",
                           message: "Clips you record appear here, newest first.",
                           actionTitle: state.recordingsFolder == nil ? nil : "Open folder",
                           action: actions.onOpenRecordingsFolder)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The clips, newest first, under one header per day.
    private var clipList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(dayGroups) { group in
                    Section {
                        ForEach(group.items) { clip in
                            VRecordingsRow(clip: clip, clock: state.clock, actions: actions)
                        }
                    } header: {
                        VLibraryDayHeader(day: group.day, clock: state.clock)
                    }
                }
            }
            .padding(.bottom, VTheme.Space.lg)
        }
    }

    /// Clips grouped into local days.
    ///
    /// Grouping goes through `VLibraryGrouping.days`, which measures against `TimelineClock` — so a
    /// clip recorded during a daylight-saving transition lands on the day the user lived through,
    /// not the one a 86 400-second assumption would put it on. The file name breaks ties, so two
    /// clips that started in the same instant keep a stable order between refreshes.
    private var dayGroups: [VLibraryDayGroup<VLibraryClip>] {
        VLibraryGrouping.days(state.clips,
                              clock: state.clock,
                              instant: { $0.startedAt },
                              tieBreak: { $0.fileName })
    }
}

// MARK: - VRecordingsRow

/// One clip.
@MainActor
package struct VRecordingsRow: View {

    // MARK: - Stored Properties

    /// The clip shown.
    package let clip: VLibraryClip

    /// The clock its timestamp is rendered in.
    package let clock: TimelineClock

    /// The handlers its controls call.
    package let actions: VLibraryActions

    @State private var isHovering = false

    // MARK: - Initialisation

    /// Creates a clip row.
    ///
    /// - Parameters:
    ///   - clip: the clip to show.
    ///   - clock: the calendar and zone its start time is formatted in.
    ///   - actions: play, reveal and delete.
    package init(clip: VLibraryClip, clock: TimelineClock, actions: VLibraryActions) {
        self.clip = clip
        self.clock = clock
        self.actions = actions
    }

    // MARK: - View

    package var body: some View {
        HStack(spacing: VTheme.Space.md) {
            thumbnail
            titleBlock
            Spacer(minLength: VTheme.Space.sm)
            measures
            controls
        }
        .padding(.horizontal, VTheme.Space.lg)
        .frame(height: VLibraryMetrics.row)
        .modifier(VLibraryRowSurface(isHovering: isHovering))
        // Without a content shape the row is hit-testable only where it is opaque, so hover would
        // fire over the text and nowhere else. The sidebar shipped exactly that bug once.
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { actions.onPlayClip(clip) }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Private Helpers

    /// A placeholder poster frame in the camera's identity colour.
    ///
    /// Not a real still: extracting one means decoding the clip, which belongs to the app target and
    /// does not exist yet. The identity colour still tells two cameras' clips apart at a glance.
    private var thumbnail: some View {
        VTheme.Radius.shape(VTheme.Radius.sm)
            .fill(clip.camera.colour.opacity(Self.thumbnailTint))
            .frame(width: VLibraryMetrics.thumbnailWidth, height: VLibraryMetrics.thumbnailHeight)
            .overlay {
                if clip.isRecording {
                    // `VLiveDot` is a pulse wrapper around arbitrary content, not a status enum, and
                    // it has no "recording" case — the recording red is a semantic colour instead.
                    Circle()
                        .fill(VTheme.Color.Semantic.live)
                        .frame(width: VTheme.Icon.xs, height: VTheme.Icon.xs)
                }
            }
            .accessibilityHidden(true)
    }

    /// Camera name over the file name.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: VTheme.Space.hair) {
            Text(verbatim: clip.camera.name)
                .vType(VTheme.Typography.body)
                .foregroundStyle(VTheme.Color.Text.primary)
                .lineLimit(1)
            Text(verbatim: clip.fileName)
                .vType(VTheme.Typography.caption1)
                .foregroundStyle(VTheme.Color.Text.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// Start time, duration and size, in reserved columns so they cannot reflow.
    private var measures: some View {
        HStack(spacing: VTheme.Space.lg) {
            Text(verbatim: VLibraryTime.label(clip.startedAt, clock: clock))
                .vType(VTheme.Typography.monoSmall.numeric)
                .foregroundStyle(VTheme.Color.Text.secondary)
                .frame(width: VLibraryMetrics.measureColumn, alignment: .trailing)

            Text(verbatim: durationText)
                .vType(VTheme.Typography.monoSmall.numeric)
                .foregroundStyle(VTheme.Color.Text.secondary)
                .frame(width: VLibraryMetrics.measureColumn, alignment: .trailing)

            Text(verbatim: sizeText)
                .vType(VTheme.Typography.monoSmall.numeric)
                .foregroundStyle(VTheme.Color.Text.tertiary)
                .frame(width: VLibraryMetrics.measureColumn, alignment: .trailing)
        }
    }

    /// Reveal and delete, revealed on hover so a resting list is only content.
    @ViewBuilder
    private var controls: some View {
        if isHovering {
            HStack(spacing: VTheme.Space.xs) {
                VButton(symbol: VTheme.Symbol.storage,
                        size: .sm,
                        accessibilityLabel: "Reveal in Finder",
                        action: { actions.onRevealClip(clip) })
                VButton(symbol: VTheme.Symbol.delete,
                        size: .sm,
                        accessibilityLabel: "Delete clip",
                        action: { actions.onDeleteClip(clip) })
            }
            .transition(.opacity)
        }
    }

    /// How much of the identity colour the poster placeholder carries.
    private static let thumbnailTint: Double = 0.24

    /// The duration, or an em dash while the clip is still being written.
    private var durationText: String {
        guard let seconds = clip.durationSeconds else { return "—" }
        return VLibraryFormat.duration(seconds: seconds)
    }

    /// The size on disk, or an em dash while the clip is still being written.
    private var sizeText: String {
        guard let bytes = clip.byteCount else { return "—" }
        return VLibraryFormat.fileSize(bytes: bytes)
    }
}

#endif  // os(macOS)
