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

// MARK: VLibrarySample

/// Deterministic fixtures for the three library previews.
///
/// ⚠️ Synthesised, not captured. The frozen "now" is 2026-07-26 10:14:38 UTC — the same instant
/// `VTimelineSample` uses — so a preview never calls `Date()` and never moves between redraws.
///
/// This is the only place in the directory that fabricates a row: the file header's rule is that no
/// *shipping* view invents one, and a `#Preview` is not a shipping view.
@MainActor
private enum VLibrarySample {

    /// 2026-07-26 10:14:38 UTC.
    static let now = Date(timeIntervalSince1970: 1_785_060_878)

    static let clock = TimelineClock(timeZoneIdentifier: "UTC",
                                     now: now,
                                     locale: Locale(identifier: "en_GB"))

    /// A stable UUID per fixture, so a redraw does not re-identify every row.
    static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012ld", number)) ?? UUID()
    }

    /// `now` minus a whole number of minutes, which is how every fixture below places itself.
    static func minutesAgo(_ minutes: Int) -> Date {
        let seconds: Double = Double(minutes) * 60
        return now.addingTimeInterval(-seconds)
    }

    static let frontDoor = VLibraryCamera(id: CameraID(id(1)), name: "Front Door",
                                          identityIndex: 0)
    static let backYard = VLibraryCamera(id: CameraID(id(2)), name: "Back Yard",
                                         identityIndex: 3)

    /// Nothing recorded, nothing seen, nothing marked — the state every user is in today.
    static func emptyState() -> VLibraryState {
        VLibraryState(clock: clock, recordingsFolder: "~/Movies/Vigil")
    }

    /// Two days of rows, so the day headers and the "yesterday" boundary both appear.
    static func populatedState() -> VLibraryState {
        VLibraryState(clock: clock,
                      clips: clips,
                      events: events,
                      bookmarks: bookmarks,
                      recordingsFolder: "~/Movies/Vigil")
    }

    static var clips: [VLibraryClip] {
        [
            VLibraryClip(id: id(10), camera: frontDoor, startedAt: minutesAgo(4),
                         durationSeconds: 96, byteCount: 41_238_016,
                         fileName: "Front Door 2026-07-26 10-10-38.mp4"),
            VLibraryClip(id: id(11), camera: backYard, startedAt: minutesAgo(52),
                         durationSeconds: 1_284, byteCount: 512_884_736,
                         fileName: "Back Yard 2026-07-26 09-22-38.mp4"),
            // Still being written: the row prints a pulse rather than a duration.
            VLibraryClip(id: id(12), camera: frontDoor, startedAt: minutesAgo(1),
                         fileName: "Front Door 2026-07-26 10-13-38.mp4", isRecording: true),
            VLibraryClip(id: id(13), camera: backYard, startedAt: minutesAgo(26 * 60),
                         durationSeconds: 312, byteCount: 128_974_848,
                         fileName: "Back Yard 2026-07-25 08-14-38.mp4"),
        ]
    }

    static var events: [VLibraryEvent] {
        [
            VLibraryEvent(id: id(20), camera: frontDoor, occurredAt: minutesAgo(3),
                          kind: TimelineMarkerKind.motion, label: "Motion",
                          durationSeconds: 14, isUnread: true),
            VLibraryEvent(id: id(21), camera: backYard, occurredAt: minutesAgo(38),
                          kind: TimelineMarkerKind.lineCrossing, label: "Line crossing",
                          durationSeconds: 6, isUnread: true),
            VLibraryEvent(id: id(22), camera: frontDoor, occurredAt: minutesAgo(97),
                          kind: TimelineMarkerKind.videoLoss, label: "Video loss",
                          durationSeconds: 41),
            VLibraryEvent(id: id(23), camera: backYard, occurredAt: minutesAgo(27 * 60),
                          kind: TimelineMarkerKind.tamper, label: "Tamper"),
        ]
    }

    static var bookmarks: [VLibraryBookmark] {
        [
            VLibraryBookmark(id: id(30), camera: frontDoor, instant: minutesAgo(41),
                             title: "Delivery", note: "Parcel left by the porch."),
            VLibraryBookmark(id: id(31), camera: backYard, instant: minutesAgo(29 * 60),
                             title: "Gate left open"),
        ]
    }
}

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
