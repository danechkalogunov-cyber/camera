//
//  TimelineMarkers.swift
//  VigilUI
//
//  Event and bookmark markers on the lane beneath the bar: their model, their pixel positions, and
//  the clustering that keeps a busy afternoon legible.
//  macOS-only. Implements docs/UX.md §7.3 and docs/DESIGN.md §9.14.
//
//  Clustering is not decoration. A camera on a driveway produces a few hundred motion events a day;
//  at the 24 h zoom those are 1 440 minutes across ~1 200 pt, so a dozen events inside one minute all
//  land on the same point. Drawn raw they become an indistinguishable smear that hides how many there
//  are and cannot be clicked accurately. Collapsed into a counted cluster they stay countable and
//  each one stays reachable through the popover. UX.md §7.3 sets the collapse distance at 8 pt.
//

#if os(macOS)

import Foundation

// MARK: - TimelineMarkerKind

/// What a marker stands for, which decides its shape and colour.
package enum TimelineMarkerKind: Sendable, Hashable {

    /// A detected event. `severity` orders clusters so an alarm inside a cluster of motion events
    /// still colours it — the most severe member wins, because that is the one the user is looking
    /// for.
    case motion
    case lineCrossing
    case intrusion
    case tamper
    case videoLoss
    case alarm

    /// A user's bookmark. Drawn as a pennant rather than a diamond (UX.md §7.3), so it is
    /// distinguishable from an event without relying on colour.
    case bookmark

    /// Higher wins when markers collapse into a cluster.
    package var severity: Int {
        switch self {
        case .bookmark: 6      // the user put it there by hand; never masked by an automatic event
        case .alarm: 5
        case .videoLoss: 4
        case .tamper: 3
        case .intrusion: 2
        case .lineCrossing: 1
        case .motion: 0
        }
    }

    /// Whether this kind draws as a pennant instead of a diamond.
    package var isPennant: Bool { self == .bookmark }
}

// MARK: - TimelineMarker

/// One thing worth marking on the timeline.
package struct TimelineMarker: Sendable, Hashable, Identifiable {

    /// Stable identity supplied by the caller — an event's or bookmark's own id.
    package let id: UUID

    /// When it happened.
    package let instant: Date

    package let kind: TimelineMarkerKind

    /// A short label for the popover and for VoiceOver. Not drawn on the lane, which has no room.
    package let label: String

    package init(id: UUID, instant: Date, kind: TimelineMarkerKind, label: String) {
        self.id = id
        self.instant = instant
        self.kind = kind
        self.label = label
    }

    /// Where clicking this marker should seek to.
    ///
    /// Three seconds early, per docs/FEATURES.md §13: "clicking one seeks to it minus 3 s". An event's
    /// timestamp is the moment detection *fired*, which is already after the thing that caused it
    /// entered frame; landing exactly on it shows the aftermath. Three seconds of lead-in is what
    /// makes the clip show what happened.
    ///
    /// ⚠️ The events *feed* uses −5 s for the same gesture (UX.md §6.5/§10). Both numbers are in the
    /// docs, for two different surfaces, and neither has an `R-` ruling. This is the timeline's.
    package var seekInstant: Date { instant.addingTimeInterval(-Self.seekLeadSeconds) }

    /// The lead-in applied by ``seekInstant``.
    package static let seekLeadSeconds: Double = 3
}

// MARK: - TimelineMarkerCluster

/// One drawn item on the marker lane: a single marker, or several collapsed together.
package struct TimelineMarkerCluster: Sendable, Hashable, Identifiable {

    /// Identity for `ForEach`. The first member's id, which is stable as long as the marker set and
    /// the zoom are — and when they change, a rebuild is correct anyway.
    package var id: UUID { markers[0].id }

    /// The markers in this cluster, in time order. Never empty.
    package let markers: [TimelineMarker]

    /// The cluster's position in points: the position of its *first* marker, not the mean.
    ///
    /// The first, because the mean would put the glyph somewhere no event happened, and a user
    /// clicking it would seek to a time the popover does not list.
    package let x: Double

    /// How many markers are collapsed here. 1 for a lone marker.
    package var count: Int { markers.count }

    /// Whether this is a collapsed group needing a count badge.
    package var isCluster: Bool { markers.count > 1 }

    /// The kind that colours the glyph: the most severe member.
    package var dominantKind: TimelineMarkerKind {
        markers.max { $0.kind.severity < $1.kind.severity }?.kind ?? markers[0].kind
    }

    /// The instant a click seeks to: the first marker's, less its lead-in.
    package var seekInstant: Date { markers[0].seekInstant }
}

// MARK: - TimelineMarkerLayout

/// Places markers on the lane and collapses those too close to tell apart.
package enum TimelineMarkerLayout {

    /// The collapse distance in points. UX.md §7.3: "Overlapping markers within 8 pt collapse into a
    /// numbered cluster".
    package static let clusterDistance: Double = 8

    /// Lays out the markers visible in `geometry`.
    ///
    /// - Parameters:
    ///   - markers: in any order.
    ///   - geometry: the pixel mapping. Markers outside the window are dropped.
    ///   - clusterDistance: the collapse distance in points. Pass 0 to disable clustering.
    /// - Returns: clusters ordered left to right.
    package static func lay(out markers: [TimelineMarker], in geometry: TimelineGeometry,
                            clusterDistance: Double = clusterDistance) -> [TimelineMarkerCluster] {
        let window = geometry.window
        let visible = markers
            .filter { window.contains($0.instant) }
            // Sort by instant, then by id, so the order — and therefore the clustering — does not
            // depend on the input order. Two events in the same millisecond must cluster the same way
            // every run or the lane flickers between layouts.
            .sorted { a, b in
                a.instant == b.instant ? a.id.uuidString < b.id.uuidString : a.instant < b.instant
            }
        guard !visible.isEmpty else { return [] }

        var clusters: [TimelineMarkerCluster] = []
        var pending: [TimelineMarker] = [visible[0]]
        var pendingX = geometry.x(at: visible[0].instant)

        for marker in visible.dropFirst() {
            let x = geometry.x(at: marker.instant)
            // Compared against the cluster's ANCHOR, not against the previous marker. Chaining off
            // the previous one would let a long run of markers 7 pt apart collapse into a single
            // cluster spanning the whole bar — each link is within tolerance but the ends are
            // nowhere near each other.
            if clusterDistance > 0, x - pendingX <= clusterDistance {
                pending.append(marker)
                continue
            }
            clusters.append(TimelineMarkerCluster(markers: pending, x: pendingX))
            pending = [marker]
            pendingX = x
        }
        clusters.append(TimelineMarkerCluster(markers: pending, x: pendingX))
        return clusters
    }

    /// The next marker instant strictly after `instant` — what `.` jumps to.
    package static func next(after instant: Date, in markers: [TimelineMarker]) -> TimelineMarker? {
        markers.filter { $0.instant > instant }.min { $0.instant < $1.instant }
    }

    /// The previous marker instant strictly before `instant` — what `,` jumps to.
    package static func previous(before instant: Date,
                                 in markers: [TimelineMarker]) -> TimelineMarker? {
        markers.filter { $0.instant < instant }.max { $0.instant < $1.instant }
    }

    /// The marker to land on when stepping event-to-event from `playhead`.
    ///
    /// ⛔ Compares ``TimelineMarker/seekInstant``, **not** `instant`, and that is the whole reason
    /// this exists beside ``next(after:in:)``. Landing on a marker puts the playhead three seconds
    /// *before* it — so the marker just jumped to still satisfies `instant > playhead`, and a
    /// stepper built on the raw instant returns that same marker on every subsequent press. The
    /// rotor action had exactly that bug: "Next Event" invoked twice never left the first event.
    ///
    /// - Parameters:
    ///   - playhead: where the playhead is now, which after any previous step is a seek instant.
    ///   - markers: in any order.
    ///   - forward: `.` when `true`, `,` when `false`.
    /// - Returns: the marker to seek to, or `nil` at either end of the day.
    package static func stepping(from playhead: Date, in markers: [TimelineMarker],
                                 forward: Bool) -> TimelineMarker? {
        // Ties broken by id so two events in the same millisecond step deterministically rather
        // than by whatever order the feed happened to deliver them in.
        let order: (TimelineMarker, TimelineMarker) -> Bool = { a, b in
            a.seekInstant == b.seekInstant
                ? a.id.uuidString < b.id.uuidString
                : a.seekInstant < b.seekInstant
        }
        return forward
            ? markers.filter { $0.seekInstant > playhead }.min(by: order)
            : markers.filter { $0.seekInstant < playhead }.max(by: order)
    }

    /// The marker instants inside `window`, for scrub magnetism.
    package static func magnetismCandidates(in window: TimelineWindow,
                                            markers: [TimelineMarker]) -> [Date] {
        markers.filter { window.contains($0.instant) }.map(\.instant)
    }
}

#endif  // os(macOS)
