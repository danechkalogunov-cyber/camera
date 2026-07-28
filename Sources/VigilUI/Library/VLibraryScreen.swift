//
//  VLibraryScreen.swift
//  VigilUI
//
//  The LIBRARY stage route: the container that switches between Recordings, Events and Bookmarks,
//  the header, day headers and empty-state treatment the three share, and the pure helpers they all
//  use — day grouping through `TimelineClock`, and the size formatting the rows print.
//  macOS-only. Implements docs/UX.md §4.1 (LIBRARY rows), §5.9 (stage routes), §9.1 (events feed),
//  §12.2 (empty-state catalogue), and docs/DESIGN.md §9.18 (`VEmptyState`) and §4.4 (monospaced
//  digits).
//
//  ⛔ THE EMPTY STATE IS THE PRIMARY DESIGN. Nothing in Vigil records to disk yet, so all three
//  lists are empty for every user today: the empty state is not the edge case, it is the screen.
//  Each one therefore names the fact, the reason and the next action, per UX.md §14.1 rules 1 and
//  10. No shipping view here fabricates a sample row — the populated fixtures live only in the
//  `#Preview` blocks at the foot of each file, and say so.
//
//  WHAT THIS FILE DOES NOT DO. It fetches nothing, owns no model, spawns no `Task` and reads no
//  singleton. Every collection arrives as a value in ``VLibraryState`` and every gesture leaves
//  through a closure in ``VLibraryActions``, so the app target wires it to `VigilCore` and a preview
//  wires it to literals.
//
//  ⛔ A DAY IS NOT 86 400 SECONDS. Every "group these by day" in this directory goes through
//  ``VLibraryGrouping/days(_:clock:instant:tieBreak:)``, which asks ``TimelineClock`` — see the
//  header of Timeline/TimelineClock.swift for the hour that goes missing otherwise. Nothing here
//  divides by 86 400 and nothing here reads `TimeZone.current` or calls `Date()`.
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

    /// 96 pt. The event row's thumbnail box (UX.md §9.1: "96×54 thumbnails").
    package static let thumbnailWidth: CGFloat = 96

    /// 54 pt. See ``thumbnailWidth``.
    package static let thumbnailHeight: CGFloat = 54

    /// 56 pt. An event row (UX.md §9.1: "list (☰, 56 pt rows)").
    package static let eventRow: CGFloat = 56

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

    /// The hover/scrub preview card, or `nil` to show none.
    package var preview: VTimelinePreview?

    /// Creates an archive mount.
    package init(tracks: [VTimelineTrack],
                 day: TimelineDay,
                 window: TimelineWindow,
                 zoom: TimelineZoom,
                 playhead: Date,
                 isScrubbing: Bool = false,
                 isLoading: Bool = false,
                 magnetismEnabled: Bool = true,
                 preview: VTimelinePreview? = nil) {
        self.tracks = tracks
        self.day = day
        self.window = window
        self.zoom = zoom
        self.playhead = playhead
        self.isScrubbing = isScrubbing
        self.isLoading = isLoading
        self.magnetismEnabled = magnetismEnabled
        self.preview = preview
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
    package var onHoverInstant: (Date?) -> Void = { _ in }

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

// MARK: - VLibraryScreen

/// The LIBRARY stage route: one of three screens, under one header.
///
/// The Stage is a router (UX.md §5.9) and this is one of its destinations. Selecting Recordings,
/// Events or Bookmarks replaces the stage's content **inside the main window**; it opens no window
/// and it owns no navigation of its own.
@MainActor
package struct VLibraryScreen: View {

    // MARK: - Stored Properties

    /// Which of the three to show.
    package let section: VLibrarySection

    /// Everything the three read.
    package let state: VLibraryState

    /// Everything they can do.
    package let actions: VLibraryActions

    @Environment(\.vMotionEnabled) private var motionEnabled

    // MARK: - Initialisation

    /// Creates the screen.
    ///
    /// - Parameters:
    ///   - section: which screen to show. Derive it from the sidebar with
    ///     ``VLibrarySection/init(_:)``.
    ///   - state: the collections and the clock.
    ///   - actions: the handlers. Defaults to a bag that does nothing, for previews.
    package init(section: VLibrarySection,
                 state: VLibraryState,
                 actions: VLibraryActions = VLibraryActions()) {
        self.section = section
        self.state = state
        self.actions = actions
    }

    // MARK: - View

    package var body: some View {
        Group {
            switch section {
            case .recordings:
                VRecordingsView(state: state, actions: actions)
            case .events:
                VEventsView(state: state, actions: actions)
            case .bookmarks:
                VBookmarksView(state: state, actions: actions)
            }
        }
        // UX.md §5.9: the stage cross-fades between routes. `standard` is the 340 ms spring the
        // token table gives a route change; `resolved` returns `reducedFallback` under Reduce
        // Motion rather than nothing, so the change is still perceptible without travel.
        .transition(.opacity)
        .animation(VTheme.Motion.resolved(VTheme.Motion.standard, reduced: !motionEnabled),
                   value: section)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VTheme.Color.Layer.canvas)
    }
}

// MARK: - VLibraryHeader

/// The band at the top of every library screen: title, count, and whatever the screen puts trailing.
///
/// The count is a bare monospaced number rather than a sentence, deliberately. "%lld clips" needs a
/// plural variation in Russian (one / few / many / other) and therefore a `.stringsdict` entry; a
/// bare number needs none, reads identically in both locales, and is what the sidebar's own count
/// badges already show (UX.md §4.1).
@MainActor
package struct VLibraryHeader<Trailing: View>: View {

    // MARK: - Stored Properties

    /// The screen's name.
    package let title: LocalizedStringKey

    /// How many rows are behind it. Negative values are clamped to zero rather than printed.
    package let count: Int

    private let trailing: () -> Trailing

    @Environment(\.displayScale) private var displayScale

    // MARK: - Initialisation

    /// Creates a header.
    ///
    /// - Parameters:
    ///   - title: the screen's name.
    ///   - count: the row count; clamped at zero.
    ///   - trailing: the screen's own controls, laid out trailing at the 8 pt sibling gap.
    package init(title: LocalizedStringKey,
                 count: Int,
                 @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.count = count
        self.trailing = trailing
    }

    // MARK: - View

    package var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: VTheme.Space.sm) {
                Text(title, bundle: .vigilUI)
                    .vType(VTheme.Typography.title2)
                    .foregroundStyle(VTheme.Color.Text.primary)
                    .lineLimit(1)
                Text(verbatim: String(max(0, count)))
                    .vType(VTheme.Typography.title2Numeric)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
                    .accessibilityHidden(true)
                Spacer(minLength: VTheme.Space.md)
                trailing()
            }
            .padding(.horizontal, VTheme.Space.xl)
            .padding(.top, VTheme.Space.xl)
            .padding(.bottom, VTheme.Space.lg)
            // ⛔ Never `Divider()` — its colour and inset are not ours (DESIGN.md §5.4).
            Rectangle()
                .fill(VTheme.Color.Stroke.subtle)
                .frame(height: VTheme.Border.hairline(displayScale))
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - VLibraryDayHeader

/// The `Today` / `Yesterday` / `26 Jul 2026` rule above each day's rows (UX.md §9.1).
///
/// Relative for the two days a reviewer thinks of by name, absolute after that — the same rule
/// UX.md §14.1 clause 12 applies to timestamps, one magnitude up.
@MainActor
package struct VLibraryDayHeader: View {

    /// The day this rule introduces.
    package let day: TimelineDay

    /// The clock the label is resolved in. The same one the grouping used.
    package let clock: TimelineClock

    /// Creates a day header.
    package init(day: TimelineDay, clock: TimelineClock) {
        self.day = day
        self.clock = clock
    }

    package var body: some View {
        label
            .vType(VTheme.Typography.caption2)
            .foregroundStyle(VTheme.Color.Text.tertiary)
            .padding(.top, VTheme.Space.lg)
            .padding(.bottom, VTheme.Space.xxs)
            // Matches the rows' own inset. Without it the header sat flush against the panel edge
            // while every row below it was indented, which read as a layout fault rather than as a
            // heading.
            .padding(.horizontal, VTheme.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Pinned section headers scroll content underneath themselves; without an opaque
            // background the rows show through the label.
            .background(VTheme.Color.Layer.canvas)
            .accessibilityAddTraits(.isHeader)
    }

    /// Today, Yesterday, or the formatted date.
    ///
    /// Not `@ViewBuilder`: that attribute builds a `_ConditionalContent`, which is not a `Text`, and
    /// the declared return type here has to stay `Text` so the caller can apply `.vType`. Explicit
    /// returns keep the concrete type.
    private var label: Text {
        if clock.isToday(day) {
            return Text("Today", bundle: .vigilUI)
        }
        if VLibraryFormat.isYesterday(day, clock: clock) {
            return Text("Yesterday", bundle: .vigilUI)
        }
        return Text(verbatim: VLibraryFormat.dayLabel(day, clock: clock))
    }
}

// MARK: - VLibraryEmptyState

/// The empty state DESIGN.md §9.18 specifies, and the one screen every user sees today.
///
/// Layout: a 48 pt circle holding the 32 pt hero glyph → 20 pt → `Title2` title → 8 pt → `Body`
/// `text.secondary` message → 24 pt → one `xl` primary action. Centred, at most 380 pt wide, and it
/// does not scroll.
///
/// The message says why the list is empty and what would fill it. It is never an apology and never a
/// dead end (UX.md §14.1 rules 5 and 10) — every instance here carries an action.
@MainActor
package struct VLibraryEmptyState: View {

    // MARK: - Stored Properties

    /// The hero glyph.
    package let symbol: VTheme.Symbol

    /// The fact, in at most six words.
    package let title: LocalizedStringKey

    /// The cause and the next step, in at most two sentences.
    package let message: LocalizedStringKey

    /// The primary action's label, or `nil` when the screen genuinely offers none.
    package let actionTitle: LocalizedStringKey?

    private let action: () -> Void

    // MARK: - Initialisation

    /// Creates an empty state.
    ///
    /// - Parameters:
    ///   - symbol: the hero glyph.
    ///   - title: the fact.
    ///   - message: the cause and the next step.
    ///   - actionTitle: the primary button's verb, or `nil` for no button.
    ///   - action: performed by that button.
    package init(symbol: VTheme.Symbol,
                 title: LocalizedStringKey,
                 message: LocalizedStringKey,
                 actionTitle: LocalizedStringKey? = nil,
                 action: @escaping () -> Void = {}) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    // MARK: - View

    package var body: some View {
        VStack(spacing: 0) {
            hero
            Spacer().frame(height: VTheme.Space.xl)
            Text(title, bundle: .vigilUI)
                .vType(VTheme.Typography.title2)
                .foregroundStyle(VTheme.Color.Text.primary)
                .multilineTextAlignment(.center)
            Spacer().frame(height: VTheme.Space.sm)
            Text(message, bundle: .vigilUI)
                .vType(VTheme.Typography.body)
                .foregroundStyle(VTheme.Color.Text.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle {
                Spacer().frame(height: VTheme.Space.xxl)
                VButton(actionTitle, style: .primary, size: .xl, action: action)
            }
        }
        .frame(maxWidth: VLibraryMetrics.emptyStateWidth)
        .padding(VTheme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    /// The 32 pt glyph in a 48 pt circle of `white α 0.05` with a 1 pt `stroke.default`
    /// (DESIGN.md §9.18). The alpha is the specification's own number, restated here for the same
    /// reason `VChip` restates its `α 0.08`: §3 publishes no token for a one-off surface tint.
    private var hero: some View {
        symbol.image()
            .symbolRenderingMode(symbol.rendering)
            .vIcon(size: VTheme.Icon.hero, weight: VTheme.Icon.Weight.hero)
            .foregroundStyle(VTheme.Color.Text.tertiary)
            .frame(width: VLibraryMetrics.heroCircle, height: VLibraryMetrics.heroCircle)
            .background(SwiftUI.Color.white.opacity(0.05), in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(VTheme.Color.Stroke.default, lineWidth: VTheme.Border.thin)
                    .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - VLibraryEyebrow

/// The `Caption2` uppercase rule above a group of rows inside a screen — `ARCHIVE`, `LOCAL CLIPS`.
@MainActor
package struct VLibraryEyebrow: View {

    /// The label. Set uppercase by the type step, not by the string, so translators write ordinary
    /// prose (DESIGN.md §4.1).
    package let title: LocalizedStringKey

    /// Creates an eyebrow.
    package init(_ title: LocalizedStringKey) {
        self.title = title
    }

    package var body: some View {
        Text(title, bundle: .vigilUI)
            .vType(VTheme.Typography.caption2)
            .foregroundStyle(VTheme.Color.Text.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - VLibraryRowSurface

/// The hover and selection surface every library row shares.
///
/// A modifier rather than a wrapper view so the rows stay flat in the `LazyVStack` — an extra
/// container per row is an extra layout pass per row, and these lists are unbounded.
@MainActor
package struct VLibraryRowSurface: ViewModifier {

    /// Whether the pointer is over the row.
    package let isHovering: Bool

    /// Creates the surface.
    package init(isHovering: Bool) {
        self.isHovering = isHovering
    }

    package func body(content: Content) -> some View {
        content
            .padding(.horizontal, VTheme.Space.md)
            .padding(.vertical, VTheme.Space.xs)
            .background(isHovering ? VTheme.Color.Layer.surfaceRaised : SwiftUI.Color.clear,
                        in: VTheme.Radius.shape(VTheme.Radius.md))
            .contentShape(VTheme.Radius.shape(VTheme.Radius.md))
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Library — recordings, empty") {
    VLibraryScreen(section: VLibrarySection.recordings,
                   state: VLibrarySample.emptyState())
        .frame(width: 900, height: 620)
}

#Preview("Library — events, populated") {
    VLibraryScreen(section: VLibrarySection.events,
                   state: VLibrarySample.populatedState())
        .frame(width: 900, height: 620)
}

#Preview("Library — bookmarks, populated") {
    VLibraryScreen(section: VLibrarySection.bookmarks,
                   state: VLibrarySample.populatedState())
        .frame(width: 900, height: 620)
}

#Preview("Library — empty state") {
    VLibraryEmptyState(symbol: VTheme.Symbol.cinema,
                       title: "No recordings yet.",
                       message: "Press ⌘R on any camera to start one. Clips are saved on this Mac.",
                       actionTitle: "Open Recordings Folder") {}
        .frame(width: 640, height: 420)
        .background(VTheme.Color.Layer.canvas)
}
#endif

#endif  // os(macOS)
