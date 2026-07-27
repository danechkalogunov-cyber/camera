//
//  VLibraryItems.swift
//  VigilUI
//
//  The three things the LIBRARY screens list: a written clip, a recorded event, a user bookmark.
//  View-facing value types — already resolved, already formatted where formatting is a decision.
//  macOS-only. See docs/UX.md §9.1 (events), §12.2 (empty states) and docs/DESIGN.md §3.2.
//

#if os(macOS)

import Foundation

import VigilProtocols

// MARK: - VLibraryClip

/// One clip Vigil has written to this Mac.
///
/// **Why a view type rather than `VigilCore`'s recording model.** `VigilUI` may not see `VigilCore`,
/// and the screens need a shape that is already resolved: the camera's display name and identity
/// colour rather than a `CameraID` to look up, and a byte count rather than a file handle. The app
/// target performs that resolution once, where the library actually lives.
package struct VLibraryClip: Identifiable, Sendable, Hashable {

    /// Stable identity for the list. The app target keeps it stable across a refresh, or rows lose
    /// their selection and their animation every time the folder is re-read.
    package let id: UUID

    /// Which camera it came from, resolved for display.
    package let camera: VLibraryCamera

    /// When recording started. Day grouping and the row's timestamp both read this.
    package let startedAt: Date

    /// Length in seconds, or `nil` while the clip is still being written.
    ///
    /// `nil` rather than a running value: a duration that ticks would make the row re-render every
    /// second for a number nobody is reading. `isRecording` is what the row shows instead.
    package let durationSeconds: Double?

    /// Size on disk in bytes, or `nil` for a clip still being written.
    package let byteCount: Int64?

    /// The file's name as it appears in the Finder, so "reveal in Finder" and the row agree.
    package let fileName: String

    /// Whether the recorder still holds this file open.
    ///
    /// A clip in this state is deliberately still listed. Hiding it until it closed would make
    /// pressing Record appear to do nothing for as long as the recording ran.
    package let isRecording: Bool

    /// Creates a clip row.
    ///
    /// - Parameters:
    ///   - id: stable identity across refreshes.
    ///   - camera: the resolved source camera.
    ///   - startedAt: when recording began.
    ///   - durationSeconds: length, or `nil` while still recording.
    ///   - byteCount: size on disk, or `nil` while still recording.
    ///   - fileName: the name shown and revealed in the Finder.
    ///   - isRecording: whether the file is still open.
    package init(id: UUID,
                 camera: VLibraryCamera,
                 startedAt: Date,
                 durationSeconds: Double? = nil,
                 byteCount: Int64? = nil,
                 fileName: String,
                 isRecording: Bool = false) {
        self.id = id
        self.camera = camera
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.byteCount = byteCount
        self.fileName = fileName
        self.isRecording = isRecording
    }
}

// MARK: - VLibraryEvent

/// One entry in the event feed.
///
/// `kind` is `TimelineMarkerKind` rather than a second enumeration of the same seven cases. That
/// type is already the shared vocabulary — the timeline draws markers from it and
/// `VInspectorEventsTab` maps it to a glyph and a colour — and a parallel taxonomy here would be one
/// more place for "line crossing" to acquire a different icon.
package struct VLibraryEvent: Identifiable, Sendable, Hashable {

    /// Stable identity for the list.
    package let id: UUID

    /// Which camera raised it, resolved for display.
    package let camera: VLibraryCamera

    /// When the device says it happened — not when Vigil heard about it. The two differ by the
    /// alert stream's latency, and grouping by the wrong one puts an event on the wrong day.
    package let occurredAt: Date

    /// What kind of event it is.
    package let kind: TimelineMarkerKind

    /// The device's own description, already localised where the device localises it.
    package let label: String

    /// How long the condition lasted, or `nil` for an instantaneous event.
    package let durationSeconds: Double?

    /// Whether the user has yet to look at it. Drives the unread badge in the sidebar's count.
    package let isUnread: Bool

    /// Creates an event row.
    ///
    /// - Parameters:
    ///   - id: stable identity across refreshes.
    ///   - camera: the resolved source camera.
    ///   - occurredAt: the device's own instant for the event.
    ///   - kind: the shared marker vocabulary.
    ///   - label: the device's description.
    ///   - durationSeconds: how long it lasted, or `nil` if instantaneous.
    ///   - isUnread: whether it still counts towards the unread badge.
    package init(id: UUID,
                 camera: VLibraryCamera,
                 occurredAt: Date,
                 kind: TimelineMarkerKind,
                 label: String,
                 durationSeconds: Double? = nil,
                 isUnread: Bool = false) {
        self.id = id
        self.camera = camera
        self.occurredAt = occurredAt
        self.kind = kind
        self.label = label
        self.durationSeconds = durationSeconds
        self.isUnread = isUnread
    }
}

// MARK: - VLibraryBookmark

/// An instant the user marked, so they can get back to it.
package struct VLibraryBookmark: Identifiable, Sendable, Hashable {

    /// Stable identity for the list.
    package let id: UUID

    /// Which camera's timeline it points into, resolved for display.
    package let camera: VLibraryCamera

    /// The marked instant.
    package let instant: Date

    /// What the user called it. Empty is allowed — the row falls back to the timestamp, because
    /// forcing a title at creation time is what stops people bookmarking anything.
    package let title: String

    /// A longer note, or `nil`.
    package let note: String?

    /// Creates a bookmark row.
    ///
    /// - Parameters:
    ///   - id: stable identity across refreshes.
    ///   - camera: the resolved camera.
    ///   - instant: the marked moment.
    ///   - title: the user's label; may be empty.
    ///   - note: an optional longer note.
    package init(id: UUID,
                 camera: VLibraryCamera,
                 instant: Date,
                 title: String = "",
                 note: String? = nil) {
        self.id = id
        self.camera = camera
        self.instant = instant
        self.title = title
        self.note = note
    }
}

// MARK: - VLibraryTime

/// Clock formatting shared by all three screens.
///
/// Declared here rather than as an extension on `TimelineClock`: that type belongs to `Timeline/`,
/// and adding a member to it from this directory is how two slices end up declaring the same
/// property — the same reasoning `VInspectorEventsTab` gives for its own kind vocabulary.
package enum VLibraryTime {

    /// `HH:mm:ss` in the library's own calendar and zone.
    ///
    /// Built from `TimelineClock.wallClock(_:)`, which is the DST-correct decomposition, rather than
    /// from a `DateFormatter` — a formatter would carry a second time zone that could disagree with
    /// the one the day headers and the timeline are already using.
    package static func label(_ instant: Date, clock: TimelineClock) -> String {
        let parts = clock.wallClock(instant)
        return String(format: "%02d:%02d:%02d", parts.hour, parts.minute, parts.second)
    }
}

// MARK: - VLibraryEventKind

/// The event kinds, in the order the filter row shows them.
///
/// `TimelineMarkerKind` is deliberately not `CaseIterable` — it lives in `Timeline/` and conforming
/// it from here would be declaring a member on someone else's type. The order is fixed so the filter
/// row does not reshuffle between renders, and severity ascends left to right.
package enum VLibraryEventKind {

    /// Every kind, in display order.
    package static let ordered: [TimelineMarkerKind] = [
        .motion, .lineCrossing, .intrusion, .tamper, .videoLoss, .alarm, .bookmark
    ]
}

#endif  // os(macOS)
