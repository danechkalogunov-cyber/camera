//
//  VLibraryModel.swift
//  VigilUI
//
//  What the three library screens read and call: the sections, the rows, the formatting, and
//  the action bag. No views — those are in VLibraryScreen.swift.
//  macOS-only. Split from VLibraryScreen.swift, which docs/API_CONTRACT.md §7.2 caps at 600
//  lines. ⚠️ These are separate top-level types, not extensions, so `private` inside each one
//  still means what it did — nothing had to open up.
//

#if os(macOS)

import Foundation
import SwiftUI

import VigilProtocols

// MARK: - VLibrarySection

/// Which of the sidebar's three LIBRARY rows is showing (UX.md §4.1 rows 4–6).
///
/// A separate enum from ``VSidebarSelection`` rather than a reuse of it: the sidebar's selection also
/// has `live`, `group` and `camera`, none of which this screen can render, and a container that had
/// to handle three impossible cases would need a fourth branch that can only be an error.
package enum VLibrarySection: Sendable, Hashable, CaseIterable {

    /// Local clips, with the archive scrubber above them.
    case recordings

    /// The event feed.
    case events

    /// The user's bookmarks.
    case bookmarks

    /// The section a sidebar selection routes to, or `nil` when the selection is not a LIBRARY row.
    ///
    /// Returning `nil` rather than a default is deliberate: the stage router (UX.md §5.9) shows the
    /// live grid for every other selection, and a silent fallback here would show an empty
    /// Recordings screen when the user clicked a camera.
    package init?(_ selection: VSidebarSelection) {
        switch selection {
        case .recordings: self = .recordings
        case .events: self = .events
        case .bookmarks: self = .bookmarks
        case .live, .group, .camera: return nil
        }
    }

    /// The heading, which is also the sidebar row's own label so the two cannot disagree.
    package var title: LocalizedStringKey {
        switch self {
        case .recordings: "Recordings"
        case .events: "Events"
        case .bookmarks: "Bookmarks"
        }
    }

    /// The 32 pt empty-state glyph (DESIGN.md §9.18, UX.md §12.2).
    ///
    /// ⚠️ UX.md §12.2 names `film.stack`, `bell.slash` and `bookmark.slash`. None of the three is in
    /// `VTheme.Symbol`, and DESIGN.md §8.3 makes that enum the only legal way to name a glyph — a
    /// string literal here would be the exact defect §8.3 exists to prevent. The nearest members of
    /// the vocabulary are used instead. Reported; adding the three cases is a change to
    /// `VTheme+Icon.swift`, which this slice does not own.
    package var heroSymbol: VTheme.Symbol {
        switch self {
        case .recordings: VTheme.Symbol.cinema
        case .events: VTheme.Symbol.events
        case .bookmarks: VTheme.Symbol.bookmark
        }
    }
}

// MARK: - VLibraryCamera

/// The camera facts a library row prints: a name, a stable identity and a colour.
///
/// Deliberately not `LiveCameraIdentity`, which requires a `host` a clip row has no use for and
/// carries no persisted identity index; and deliberately not `VSidebarCamera`, which carries live
/// status, codec and frame rate that a row about something that happened yesterday must not claim to
/// know. This is the intersection of the two, and nothing else.
package struct VLibraryCamera: Identifiable, Sendable, Hashable {

    /// The camera the row belongs to.
    package let id: CameraID

    /// The display name, shown verbatim — never localised, never possessive (UX.md §14.2).
    package let name: String

    /// The persisted identity-colour index (DESIGN.md §3.4), or `nil` to derive one from ``id``.
    package let identityIndex: Int?

    /// Creates an identity.
    ///
    /// - Parameters:
    ///   - id: the camera's library identifier.
    ///   - name: the display name.
    ///   - identityIndex: the persisted colour slot, or `nil` to derive it deterministically.
    package init(id: CameraID, name: String, identityIndex: Int? = nil) {
        self.id = id
        self.name = name
        self.identityIndex = identityIndex
    }

    /// The camera's first letter, which accompanies the colour everywhere so the colour is never the
    /// sole carrier of identity (DESIGN.md §3.4).
    package var initial: Character? { name.first }

    /// The identity colour: the persisted slot when there is one, otherwise the deterministic
    /// derivation from the identifier that `VTheme.Color.Ident` already publishes.
    @MainActor
    package var colour: SwiftUI.Color {
        if let identityIndex {
            return VTheme.Color.Ident.colour(at: identityIndex)
        }
        return VTheme.Color.Ident.colour(for: id.rawValue)
    }
}

// MARK: - VLibraryDayGroup

/// One local day's worth of rows, for the day headers every list in this directory draws.
///
/// The day is a ``TimelineDay`` rather than a `Date`, so the group carries its own true length and a
/// header can say "this day was 23 hours long" without recomputing anything.
package struct VLibraryDayGroup<Item>: Identifiable {

    /// The device-local day these items fall in.
    package let day: TimelineDay

    /// The items, newest first.
    package let items: [Item]

    /// Local midnight, which is unique per group and stable across a rebuild.
    package var id: Date { day.start }

    /// Creates a group.
    package init(day: TimelineDay, items: [Item]) {
        self.day = day
        self.items = items
    }
}

// MARK: - VLibraryGrouping

/// The one "bucket these by day" in this directory.
package enum VLibraryGrouping {

    /// Sorts newest first and buckets by device-local calendar day.
    ///
    /// ⛔ The day boundary comes from ``TimelineClock/day(containing:)``, never from arithmetic on
    /// `timeIntervalSince1970`. On the autumn-back day a local day is 90 000 s long, so two rows
    /// 25 hours apart genuinely belong to the same day; a grouping that divided by 86 400 would put
    /// the evening ones under tomorrow's header and the user would conclude that Vigil had lost
    /// them. This is asserted by `libraryEventsGroupAcrossADaylightSavingDay`.
    ///
    /// - Parameters:
    ///   - items: in any order.
    ///   - clock: supplies the calendar, and therefore the time zone the days break in. Pass the
    ///     *device's* zone: a viewer in Berlin reviewing a camera in New York must see the camera's
    ///     midnight, because that is where its recording day breaks.
    ///   - instant: the moment an item happened.
    ///   - tieBreak: a stable string for two items at the same instant. Without it, two events in
    ///     the same millisecond would swap places between redraws and the list would flicker.
    /// - Returns: groups newest day first, each holding its items newest first. Empty in, empty out.
    package static func days<Item>(_ items: [Item],
                                   clock: TimelineClock,
                                   instant: (Item) -> Date,
                                   tieBreak: (Item) -> String) -> [VLibraryDayGroup<Item>] {
        let sorted = items.sorted { first, second in
            let a = instant(first)
            let b = instant(second)
            if a != b { return a > b }
            return tieBreak(first) < tieBreak(second)
        }

        var groups: [VLibraryDayGroup<Item>] = []
        var openDay: TimelineDay?
        var bucket: [Item] = []
        for item in sorted {
            let day = clock.day(containing: instant(item))
            if let openDay, openDay == day {
                bucket.append(item)
                continue
            }
            if let openDay {
                groups.append(VLibraryDayGroup(day: openDay, items: bucket))
            }
            openDay = day
            bucket = [item]
        }
        if let openDay {
            groups.append(VLibraryDayGroup(day: openDay, items: bucket))
        }
        return groups
    }
}

// MARK: - VLibraryFormat

/// The value strings the library rows print that no existing formatter already produces.
///
/// Numbers are deliberately **not** localised, for the reason `VInspectorFormat` already gives: a
/// file size gets pasted into a bug report and compared with a colleague's, and a comma decimal
/// separator would make two screenshots of the same clip look like different clips. `kB`, `MB` and
/// `GB` are the symbols both shipping locales use.
package enum VLibraryFormat {

    /// A file size in **decimal** units — `"4.2 MB"`, `"1.5 GB"`, `"812 kB"`, `"96 B"`.
    ///
    /// Decimal rather than binary to agree with `VInspectorFormat.capacity(megabytes:)` and with the
    /// device's own accounting: two size figures in one app that disagree by 5 % is a support call.
    ///
    /// Each threshold promotes one step *before* the smaller unit would print four whole digits, so
    /// the string never runs `999 kB` → `1000 kB`; it runs `999 kB` → `1.0 MB`. That is what keeps
    /// the column width stable under DESIGN.md §4.4.
    ///
    /// - Parameter bytes: size on disk. A negative value — which cannot come from the file system
    ///   but can come from an uninitialised record — returns the em dash placeholder rather than a
    ///   confident `"0 B"`.
    package static func fileSize(bytes: Int64) -> String {
        guard bytes >= 0 else { return VInspectorFormat.placeholder }
        if bytes >= 999_500_000 {
            return InspectorStat.fixed(Double(bytes) / 1_000_000_000, places: 1) + " GB"
        }
        if bytes >= 999_500 {
            return InspectorStat.fixed(Double(bytes) / 1_000_000, places: 1) + " MB"
        }
        if bytes >= 1_000 {
            return InspectorStat.fixed(Double(bytes) / 1_000, places: 0) + " kB"
        }
        return "\(bytes) B"
    }

    /// A clip or event length as `m:ss`, growing to `h:mm:ss` past an hour.
    ///
    /// Delegates to ``VInspectorFormat/duration(seconds:)`` rather than restating it, so the Events
    /// tab in the inspector and the Events screen in the library cannot print the same event's
    /// length two different ways.
    package static func duration(seconds: Double) -> String {
        VInspectorFormat.duration(seconds: seconds)
    }

    /// The absolute date of a day, in the clock's own calendar, zone and locale — `"26 Jul 2026"`.
    ///
    /// Formatted through `Date.FormatStyle` with all three injected, never through the environment's
    /// calendar: a day header formatted in the viewer's zone under a group bucketed in the device's
    /// zone is a header that names the wrong date for half the rows beneath it.
    ///
    ///     init(date: Date.FormatStyle.DateStyle? = nil, time: Date.FormatStyle.TimeStyle? = nil,
    ///          locale: Locale = .autoupdatingCurrent, calendar: Calendar = .autoupdatingCurrent,
    ///          timeZone: TimeZone = .autoupdatingCurrent,
    ///          capitalizationContext: FormatStyleCapitalizationContext = .unknown)
    package static func dayLabel(_ day: TimelineDay, clock: TimelineClock) -> String {
        let style = Date.FormatStyle(date: Date.FormatStyle.DateStyle.abbreviated,
                                     locale: clock.locale,
                                     calendar: clock.calendar,
                                     timeZone: clock.timeZone)
        return day.start.formatted(style)
    }

    /// Whether `day` is the day before the clock's today, which earns the "Yesterday" header.
    ///
    /// Stepped in *calendar* days rather than by subtracting 86 400 s, so it is still right on both
    /// transition days.
    package static func isYesterday(_ day: TimelineDay, clock: TimelineClock) -> Bool {
        clock.day(clock.today, offsetByDays: -1) == day
    }
}

// MARK: - VLibraryMetrics

/// The library screens' own dimensions.
///
/// The same arrangement `VTimelineMetrics` uses: each number lives here exactly once, derived from a
/// spacing or metric token where one is an exact match and carrying the clause it comes from where
/// it is not.
@MainActor
package enum VLibraryMetrics {

    /// 48 pt. The empty state's hero circle (DESIGN.md §9.18: "32 pt glyph in a 48 pt circle").
    /// `Space.jumbo` is the exact match.
    package static let heroCircle: CGFloat = VTheme.Space.jumbo

    /// 380 pt. The empty state's maximum width (DESIGN.md §9.18).
    package static let emptyStateWidth: CGFloat = 380

    /// 96 pt. How far below the header an empty state's hero begins, on every screen.
    ///
    /// A constant, because the three screens' empty states are different heights and centring them
    /// put their titles at three different y positions — see `VLibraryEmptyState`.
    package static let emptyStateTopInset: CGFloat = 96

    /// 96 pt. The event row's thumbnail box (UX.md §9.1: "96×54 thumbnails").
    package static let thumbnailWidth: CGFloat = 96

    /// 54 pt. See ``thumbnailWidth``.
    package static let thumbnailHeight: CGFloat = 54

    /// 56 pt. An event row (UX.md §9.1: "list (☰, 56 pt rows)").
    package static let eventRow: CGFloat = 56

    /// 28 pt. The screen title's content box, before the header's own padding.
    ///
    /// ⛔ FIXED, BECAUSE THE THREE SCREENS DO NOT CARRY THE SAME CONTROLS. Recordings has a folder
    /// button in the header, Events has a filter, Bookmarks has nothing at all — so the row was as
    /// tall as whatever it held, and the *title* sat a few points higher on Bookmarks than on the
    /// other two. Switching tabs made the heading jump. A title's baseline must not depend on what
    /// happens to be beside it, and 28 pt clears both the 22 pt title line and the small controls.
    package static let headerContent: CGFloat = 28

    /// The clip player's height inside the Recordings screen. Tall enough for a 16:9 picture at the
    /// panel's usual width without pushing the list off the bottom of a laptop display.
    package static let playerHeight: CGFloat = 360

    /// 44 pt. A clip or bookmark row. Neither has a row height in the specification; the 44 pt
    /// `Row.camera` token is the one designed to hold a two-line label beside a leading mark, which
    /// is exactly this row's anatomy (R-37 exempts row heights from the five control heights).
    package static let row: CGFloat = VTheme.Metrics.Row.camera

    /// 64 pt. The screen's own header band: a `Title2` line box with `Space.xl` above and below.
    package static let header: CGFloat = VTheme.Metrics.md + VTheme.Space.xl + VTheme.Space.lg

    /// 92 pt. The width reserved for the trailing duration-and-size column, so a `1.5 GB` row and a
    /// `96 B` row line their actions up (DESIGN.md §4.4). Matches
    /// ``VTheme/Typography/Reserved/timecode``, the widest reserved column the system publishes.
    package static let measureColumn: CGFloat = VTheme.Typography.Reserved.timecode
}

// MARK: - VLibraryArchive

/// Everything the archive scrubber at the top of the Recordings screen needs.
///
/// One value rather than ten parameters, because all ten change together when the day changes and a
/// caller that updated nine of them would draw yesterday's footage under today's ruler.
///
/// Deliberately conforms to nothing. ``VTimelinePreview`` holds a `SwiftUI.Image` and is not
/// declared `Sendable`; claiming `Sendable` here would be a claim about a type this file does not
/// own. Nothing needs it — the value is constructed on the main actor and read in a `body`.
package struct VLibraryArchive {

    /// One per camera being reviewed, in stage order. The first gets the tall lane.
    package var tracks: [VTimelineTrack]

    /// The day being reviewed, at its true length.
    package var day: TimelineDay

    /// The visible slice, already clamped into ``day`` by the caller.
    package var window: TimelineWindow

    /// The zoom stop ``window`` came from.
    package var zoom: TimelineZoom

    /// The playhead.
    package var playhead: Date

    /// Whether a scrub is in flight.
    package var isScrubbing: Bool

    /// Whether the day's search is still running. Not-yet-loaded ranges shimmer; they are never
    /// drawn as "no recording" (UX.md §7.4).
    package var isLoading: Bool

    /// Whether release-time magnetism applies. `false` while ⌥ is held (UX.md §7.3).
    package var magnetismEnabled: Bool

    /// Creates an archive mount.
    package init(tracks: [VTimelineTrack],
                 day: TimelineDay,
                 window: TimelineWindow,
                 zoom: TimelineZoom,
                 playhead: Date,
                 isScrubbing: Bool = false,
                 isLoading: Bool = false,
                 magnetismEnabled: Bool = true) {
        self.tracks = tracks
        self.day = day
        self.window = window
        self.zoom = zoom
        self.playhead = playhead
        self.isScrubbing = isScrubbing
        self.isLoading = isLoading
        self.magnetismEnabled = magnetismEnabled
    }
}

// MARK: - VLibraryState

/// Everything the three library screens read.
///
/// A snapshot, not an observation: the app target rebuilds it when its stores change and hands it
/// down. Nothing here is fetched, and no screen in this directory knows that `EventStore` or
/// `ClipRecorder` exist.
package struct VLibraryState {

    /// The calendar, zone and locale every day boundary and every timestamp is computed in. One
    /// clock for all three screens, so a row and its day header cannot disagree.
    package var clock: TimelineClock

    /// The clips Vigil has written to this Mac, in any order.
    package var clips: [VLibraryClip]

    /// The event feed, in any order.
    package var events: [VLibraryEvent]

    /// The user's bookmarks, in any order.
    package var bookmarks: [VLibraryBookmark]

    /// The archive scrubber's mount, or `nil` when no camera and day have been chosen yet.
    package var archive: VLibraryArchive?

    /// The recordings folder as the user would recognise it — `"~/Movies/Vigil"`. Shown in the
    /// Recordings empty state so "where would a clip appear" has an answer before one exists.
    package var recordingsFolder: String?

    /// Creates a snapshot.
    ///
    /// - Parameters:
    ///   - clock: the device's calendar, zone and locale.
    ///   - clips: local clips.
    ///   - events: the event feed.
    ///   - bookmarks: the user's bookmarks.
    ///   - archive: the scrubber's mount, or `nil` before a day has been loaded.
    ///   - recordingsFolder: the destination folder, for display only.
    package init(clock: TimelineClock,
                 clips: [VLibraryClip] = [],
                 events: [VLibraryEvent] = [],
                 bookmarks: [VLibraryBookmark] = [],
                 archive: VLibraryArchive? = nil,
                 recordingsFolder: String? = nil) {
        self.clock = clock
        self.clips = clips
        self.events = events
        self.bookmarks = bookmarks
        self.archive = archive
        self.recordingsFolder = recordingsFolder
    }
}

// MARK: - VLibraryActions

/// Every gesture the three screens can produce, as a bag of closures the app target fills in.
///
/// The same arrangement as `VInspectorActions`: defaults that do nothing, so a preview assigns the
/// two handlers it wants to demonstrate and a test constructs one with none.
package struct VLibraryActions {

    // MARK: Recordings

    /// Opens this clip in Playback.
    package var onPlayClip: (VLibraryClip) -> Void = { _ in }

    /// Shows the file in the Finder.
    package var onRevealClip: (VLibraryClip) -> Void = { _ in }

    /// Deletes the file, after the caller's own confirmation. UX.md §14.1 rule 7: a destructive
    /// confirmation names the object, and only the caller knows how to present one.
    package var onDeleteClip: (VLibraryClip) -> Void = { _ in }

    /// Opens the recordings destination folder in the Finder.
    package var onOpenRecordingsFolder: () -> Void = {}

    // MARK: Archive scrubber

    /// Called as a scrub progresses. Only ``VTimelineScrubPhase/ended`` should issue a seek.
    package var onScrub: (VTimelineScrubPhase, Date) -> Void = { _, _ in }

    /// The instant under the pointer, and `nil` when it leaves.

    /// A requested zoom stop. The caller re-anchors and clamps the window.
    package var onZoom: (TimelineZoom) -> Void = { _ in }

    /// A marker or cluster badge was activated on the scrubber.
    package var onActivateMarker: (TimelineMarkerCluster) -> Void = { _ in }

    // MARK: Events

    /// Opens Playback at this event. UX.md §9.1 puts the feed's lead-in at 5 s — the caller applies
    /// it, because the timeline's own lead-in is 3 s and the two surfaces are allowed to differ.
    package var onOpenEvent: (VLibraryEvent) -> Void = { _ in }

    /// Deletes the record. Local only — it never touches the device (UX.md §9.1).
    package var onDeleteEvent: (VLibraryEvent) -> Void = { _ in }

    /// Opens Settings ▸ Notifications, the action UX.md §12.2 gives the events empty state.
    package var onOpenNotificationSettings: () -> Void = {}

    // MARK: Bookmarks

    /// Opens Playback at the bookmark's instant.
    package var onOpenBookmark: (VLibraryBookmark) -> Void = { _ in }

    /// Deletes the bookmark, after the caller's own confirmation.
    package var onDeleteBookmark: (VLibraryBookmark) -> Void = { _ in }

    /// Creates a bag in which nothing is wired. Assign the handlers you need.
    package init() {}
}

#endif  // os(macOS)
