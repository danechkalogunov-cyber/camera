//
//  VTimelineClusterList.swift
//  VigilUI
//
//  What a collapsed marker cluster expands into: the events hiding under one badge.
//  macOS-only. Implements docs/UX.md §7.3 ("expands on click into a popover list").
//

#if os(macOS)

import Foundation
import SwiftUI

// MARK: - VTimelineClusterList

/// The markers under one cluster badge, each seekable.
///
/// **Why the badge is not just a seek.** At the 24 h zoom a busy afternoon puts forty events inside
/// eight points, and `TimelineMarkerLayout` collapses them into one badge reading `40`. Without this
/// list that badge can only do one thing — seek to the first of the forty — and the other
/// thirty-nine are unreachable at any zoom the user is likely to be at. The badge says how many are
/// there; this is what makes the claim useful.
///
/// **Time, not label, leads each row.** The reviewer arrived here from a position on a ruler, so the
/// question in their head is "which of these is the one at 14:32" — and the labels in a cluster are
/// very often identical ("Motion detected" forty times over), which makes the timestamp the only
/// thing that distinguishes the rows.
@MainActor
package struct VTimelineClusterList: View {

    // MARK: - Stored Properties

    /// The cluster to expand. Its markers are already in time order.
    package let cluster: TimelineMarkerCluster

    /// The zone the times are shown in.
    package let clock: TimelineClock

    /// Seeks to one marker. The caller closes the popover.
    package let onSelect: (TimelineMarker) -> Void

    /// The row under the pointer.
    ///
    /// Held here rather than inside a `ButtonStyle`: a `ButtonStyle` is a value re-made on every
    /// evaluation and cannot carry `@State`, which is why ``VButtonSurface`` hands its own hover
    /// tracking to a separate view.
    @State private var hovered: UUID?

    // MARK: - Initialisation

    /// Creates the list.
    package init(cluster: TimelineMarkerCluster,
                 clock: TimelineClock,
                 onSelect: @escaping (TimelineMarker) -> Void) {
        self.cluster = cluster
        self.clock = clock
        self.onSelect = onSelect
    }

    // MARK: - View

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(cluster.count) events", bundle: .vigilUI)
                .vType(VTheme.Typography.caption2)
                .foregroundStyle(VTheme.Color.Text.tertiary)
                .padding(.horizontal, VTheme.Space.sm)
                .padding(.bottom, VTheme.Space.xxs)
            // Scrolls rather than growing without bound: a cluster of two hundred would otherwise
            // produce a popover taller than the display, which AppKit resolves by clipping it.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(cluster.markers) { marker in
                        row(marker)
                    }
                }
            }
            .frame(maxHeight: VClusterMetrics.maxListHeight)
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.vertical, VTheme.Space.sm)
        .frame(width: VClusterMetrics.width)
    }

    // MARK: - Private Helpers

    private func row(_ marker: TimelineMarker) -> some View {
        Button {
            onSelect(marker)
        } label: {
            HStack(spacing: VTheme.Space.sm) {
                dot(marker.kind)
                Text(verbatim: timeLabel(marker.instant))
                    .vType(VTheme.Typography.monoSmall.numeric)
                    .foregroundStyle(VTheme.Color.Text.primary)
                Text(verbatim: marker.label)
                    .vType(VTheme.Typography.caption1)
                    .foregroundStyle(VTheme.Color.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            // The library's own row surface, so a list of events here and a list of events on the
            // Events screen highlight identically rather than nearly so.
            .modifier(VLibraryRowSurface(isHovering: hovered == marker.id))
        }
        .buttonStyle(.plain)
        .onHover { isInside in
            if isInside { hovered = marker.id } else if hovered == marker.id { hovered = nil }
        }
        .accessibilityLabel(Text(verbatim: "\(timeLabel(marker.instant)) \(marker.label)"))
    }

    /// The kind's colour as a small dot, matching the lane's own palette so a row and the glyph it
    /// came from are recognisably the same event.
    private func dot(_ kind: TimelineMarkerKind) -> some View {
        Circle()
            .fill(Self.tint(kind))
            .frame(width: VClusterMetrics.dot, height: VClusterMetrics.dot)
    }

    /// Same mapping as ``VTimelineMarkerGlyph.tint``. Duplicated deliberately rather than hoisted:
    /// that one colours by the cluster's *dominant* kind, this one colours each row by its own, and
    /// merging them into one helper would invite passing the wrong kind at one of the two sites.
    private static func tint(_ kind: TimelineMarkerKind) -> SwiftUI.Color {
        switch kind {
        case .bookmark: VTheme.Color.Semantic.accent
        case .alarm: VTheme.Color.Semantic.live
        case .videoLoss: VTheme.Color.Semantic.danger
        case .tamper, .intrusion, .lineCrossing: VTheme.Color.Semantic.warn
        case .motion: VTheme.Color.Semantic.motion
        }
    }

    /// `14:32:07`, or `2:32:07 PM` on a 12-hour clock.
    ///
    /// Straight through ``TimelineClock``, which already caches the `Date.FormatStyle` and already
    /// carries the timeline's zone and the user's `TimelineHourPreference`. A private
    /// `DateFormatter` here would be the mistake the clock's own documentation records having
    /// already made once: it would show `14:32` under a ruler whose ticks say `2 PM`, and a row
    /// that disagrees with the ruler it sits under makes the user distrust both.
    private func timeLabel(_ instant: Date) -> String {
        clock.hourMinuteSecond(instant)
    }
}

// MARK: - VClusterMetrics

/// The list's sizes.
@MainActor
private enum VClusterMetrics {

    /// Wide enough for a timestamp and a short label without wrapping.
    static let width: CGFloat = 260

    /// About eight rows. Beyond that the list scrolls.
    static let maxListHeight: CGFloat = 240

    /// The per-row kind dot.
    static let dot: CGFloat = 6
}

#endif  // os(macOS)
