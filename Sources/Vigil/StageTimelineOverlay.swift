//
//  StageTimelineOverlay.swift
//  Vigil
//
//  The archive scrubber, laid over the bottom edge of the stage.
//  macOS-only. Implements docs/UX.md §7.3 (the timeline itself) and §6.6 (chrome at the bottom edge).
//

#if os(macOS)

import Foundation
import SwiftUI

import VigilUI

// MARK: - StageTimelineOverlay

/// The timeline, over the stage rather than beside it.
///
/// **Why an overlay and not a route.** An earlier attempt made "open this camera" a separate
/// full-bleed surface with its own title bar, and it read as a second window opening — which is not
/// what opening a camera should feel like. The stage already knows how to show one camera: that is
/// `.single`. So opening a camera is a *layout* change, and the timeline is chrome laid over the
/// result. Nothing about the tile changes, which is the point — the picture the user was looking at
/// stays the picture they are looking at.
///
/// **It hides.** §6.6 puts the timeline back "on pointer-near-bottom". Once it has been asked for,
/// approaching the bottom edge brings it up and leaving takes it away, so the stage is a picture
/// again the moment the pointer is elsewhere.
@MainActor
struct StageTimelineOverlay: View {

    // MARK: - Stored Properties

    /// The day to scrub, or `nil` when the camera has no index to show.
    let archive: VLibraryArchive?

    /// What the device said when asked whether it records anything.
    ///
    /// ⚠️ The panel needs this to tell three states apart that look identical from `archive == nil`:
    /// the read is in flight, the camera offered nothing, and the camera refused to say. One of them
    /// resolves on its own and two never will, so "still reading" is a lie for the last two.
    let availability: ArchiveCoordinator.TrackAvailability

    /// The calendar and zone the ruler and the day label are rendered in.
    let clock: TimelineClock

    /// Steps the day the timeline is showing.
    let onSelectDay: (TimelineDay) -> Void

    /// The month behind ⌘G, or `nil` when the calendar has not been asked for yet.
    let month: TimelineMonthGrid?

    /// Whether that month is still being read from the device.
    let isLoadingMonth: Bool

    /// Asks for a month by year and 1-based month. Also called when the popover opens, to fetch the
    /// month the current day sits in.
    let onSelectMonth: (Int, Int) -> Void

    /// Jumps to the live edge — ⇧⌘G, UX.md §14.2.
    let onGoToNow: () -> Void

    /// Forwarded to `VTimelineView`.
    let onScrub: (VTimelineScrubPhase, Date) -> Void
    let onZoom: (TimelineZoom) -> Void

    /// The playback-speed stop in force, and whether one can be asked for at all.
    ///
    /// ⚠️ `let`, and passed through the initialiser above. As `var`s with defaults they compiled
    /// and silently did nothing: this type declares its initialiser by hand — the header explains
    /// why — so a default on the property is not a default on the parameter, and the call site kept
    /// building overlays whose speed was permanently `.normal`.
    let rate: TimelinePlaybackRate
    let isRateAdjustable: Bool
    let onRate: (TimelinePlaybackRate) -> Void
    let onActivateMarker: (TimelineMarkerCluster) -> Void

    /// Hold and single-frame stepping, forwarded to `VTimelineView`'s transport buttons.
    ///
    /// The same caveat as ``rate`` applies and for the same reason: the hand-written initialiser
    /// below is the only way in, so these are parameters or they are nothing.
    let isPaused: Bool
    let onTogglePause: () -> Void
    let onFrameStep: (Bool) -> Void

    /// Multi-camera UTC playback. `nil` means the current stage cannot synchronize (fewer than two
    /// cameras); a non-nil label is both the status and the toggle's accessible value.
    let syncLabel: String?
    let isSyncEnabled: Bool
    let onToggleSync: () -> Void

    /// Steps the playhead by a number of seconds, positive or negative.
    let onStep: (Double) -> Void

    /// Moves to the next or previous edge of recorded footage.
    let onStepToEdge: (Bool) -> Void

    /// Moves to the next or previous event marker — `.` and `,`.
    let onStepToMarker: (Bool) -> Void

    /// Home and End: the day's first or last instant.
    let onGoToDayEdge: (Bool) -> Void

    /// Puts the timeline away.
    let onDismiss: () -> Void

    /// Bumped by the window every time the timeline is asked for.
    ///
    /// ⛔ A WAY BACK THAT DOES NOT DEPEND ON THE POINTER. `showsTimeline` is already `true` once the
    /// scrubber has been opened, so asking again — the tile's button, an event, a bookmark —
    /// changed nothing and looked like a dead control. Any change here re-pins the panel, which is
    /// what "show me the timeline" has to mean when it is technically already open.
    let revealRequests: Int

    /// Whether the pointer is near the bottom edge, and whether it is over the chrome itself.
    ///
    /// Two flags and not one: the chrome must stay up while the pointer is *on* it, and a single
    /// flag would drop it the moment the pointer left the trigger strip to reach the scrubber —
    /// which is the gesture the strip exists to enable.
    @State private var isNearBottom = false
    @State private var isOverChrome = false

    /// Whether the ⌘G calendar is up.
    ///
    /// Counts as a third reason for the chrome to stay visible. A popover is its own window and the
    /// pointer inside it is not over the chrome, so without this the calendar would take the
    /// scrubber down with it the instant the pointer entered the very control it opened.
    @State private var showsCalendar = false

    /// Whether the user has taken the scrubber up on being here yet.
    ///
    /// ⛔ THE PANEL HAS TO BE VISIBLE WHEN IT IS ASKED FOR. Visibility was `isNearBottom ||
    /// isOverChrome || showsCalendar` and nothing else, so opening the timeline — from the tile's
    /// button, from an event, from a bookmark — put a scrubber on screen that appeared only if the
    /// pointer already happened to be within a strip of the bottom edge. Anywhere else, the command
    /// did nothing visible, and the second attempt looked like a broken feature rather than a
    /// gesture the user had not discovered.
    ///
    /// So it starts pinned and unpins the first time the pointer *leaves* it. After that §6.6's
    /// rule takes over exactly as before: approach the bottom and it returns.
    @State private var hasEngaged = false

    @Environment(\.vMotionEnabled) private var motionEnabled

    // MARK: - Initialisation

    /// Creates the overlay.
    ///
    /// Spelled out rather than left to the memberwise initialiser: the two hover flags are
    /// `private`, and Swift lowers a synthesised memberwise initialiser to the least accessible
    /// stored property it includes, which would make it unreachable from the window.
    init(archive: VLibraryArchive?,
         availability: ArchiveCoordinator.TrackAvailability = .unknown,
         clock: TimelineClock,
         onSelectDay: @escaping (TimelineDay) -> Void,
         month: TimelineMonthGrid?,
         isLoadingMonth: Bool,
         onSelectMonth: @escaping (Int, Int) -> Void,
         onGoToNow: @escaping () -> Void,
         onScrub: @escaping (VTimelineScrubPhase, Date) -> Void,
         onZoom: @escaping (TimelineZoom) -> Void,
         onActivateMarker: @escaping (TimelineMarkerCluster) -> Void,
         onStep: @escaping (Double) -> Void,
         onStepToEdge: @escaping (Bool) -> Void,
         onStepToMarker: @escaping (Bool) -> Void,
         onGoToDayEdge: @escaping (Bool) -> Void,
         onDismiss: @escaping () -> Void,
         revealRequests: Int = 0,
         rate: TimelinePlaybackRate = .normal,
         isRateAdjustable: Bool = false,
         isPaused: Bool = false,
         onTogglePause: @escaping () -> Void = {},
         onFrameStep: @escaping (Bool) -> Void = { _ in },
         syncLabel: String? = nil,
         isSyncEnabled: Bool = false,
         onToggleSync: @escaping () -> Void = {},
         onRate: @escaping (TimelinePlaybackRate) -> Void = { _ in }) {
        self.archive = archive
        self.availability = availability
        self.clock = clock
        self.onSelectDay = onSelectDay
        self.month = month
        self.isLoadingMonth = isLoadingMonth
        self.onSelectMonth = onSelectMonth
        self.onGoToNow = onGoToNow
        self.onScrub = onScrub
        self.onZoom = onZoom
        self.onActivateMarker = onActivateMarker
        self.onStep = onStep
        self.onStepToEdge = onStepToEdge
        self.onStepToMarker = onStepToMarker
        self.onGoToDayEdge = onGoToDayEdge
        self.onDismiss = onDismiss
        self.revealRequests = revealRequests
        self.rate = rate
        self.isRateAdjustable = isRateAdjustable
        self.isPaused = isPaused
        self.onTogglePause = onTogglePause
        self.onFrameStep = onFrameStep
        self.syncLabel = syncLabel
        self.isSyncEnabled = isSyncEnabled
        self.onToggleSync = onToggleSync
        self.onRate = onRate
    }

    // MARK: - View

    var body: some View {
        ZStack(alignment: .bottom) {
            approachStrip
            chrome
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // ⛔ THE ANIMATION BELONGS TO THE CONTAINER, NOT TO THE CHROME. It was attached to the
        // scrubber itself, inside the `if isVisible` that creates it — and a view that does not
        // exist yet cannot animate its own arrival. SwiftUI animates an insertion only if the
        // *parent* is animating when the condition changes, so the transition was declared,
        // ignored, and the panel snapped in and out. Here it works, and it is the one place the
        // timing lives.
        .animation(VTheme.Motion.resolved(VTheme.Motion.standard, reduced: !motionEnabled),
                   value: isVisible)
        .onChange(of: revealRequests) { _, _ in hasEngaged = false }
        .background { shortcuts }
    }

    // MARK: - Keyboard

    /// UX.md §7.3's timeline keys, as zero-sized buttons.
    ///
    /// Declared here and not on the scrubber because they must work while the pointer is anywhere
    /// over the stage — the whole point of a keyboard step is not having to aim first. They exist
    /// only while the overlay does, so ← and → still belong to whatever else wants them when the
    /// timeline is away.
    private var shortcuts: some View {
        ZStack {
            Button("", action: onDismiss)
                .keyboardShortcut(.cancelAction)
            Button("", action: { onStep(-10) }).keyboardShortcut(.leftArrow, modifiers: [])
            Button("", action: { onStep(10) }).keyboardShortcut(.rightArrow, modifiers: [])
            Button("", action: { onStep(-60) }).keyboardShortcut(.leftArrow, modifiers: .shift)
            Button("", action: { onStep(60) }).keyboardShortcut(.rightArrow, modifiers: .shift)
            // ⌘← / ⌘→ jump to the edge of the next run of footage. On a day with twenty minutes
            // recorded out of twenty-four hours, stepping ten seconds at a time is not navigation.
            Button("", action: { onStepToEdge(false) })
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("", action: { onStepToEdge(true) })
                .keyboardShortcut(.rightArrow, modifiers: .command)
            // §14.2's pair: ⌘G opens the calendar, ⇧⌘G returns to the live edge. Both are disabled
            // without an archive — there is no day to open a calendar around, and "go to now" on a
            // camera with no index would only restart the stream that is already running.
            Button("", action: { if let archive { openCalendar(around: archive.day) } })
                .keyboardShortcut("g", modifiers: .command)
                .disabled(archive == nil)
            Button("", action: onGoToNow)
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(archive == nil)
            // `,` / `.` walk the day's events. Unmodified on purpose (§7.3): the timeline has no
            // text field, so the bare punctuation keys are free, and an event-to-event key that
            // needs a modifier is one the user has to think about.
            Button("", action: { onStepToMarker(false) }).keyboardShortcut(",", modifiers: [])
            Button("", action: { onStepToMarker(true) }).keyboardShortcut(".", modifiers: [])
            Button("", action: { onGoToDayEdge(true) })
                .keyboardShortcut(KeyEquivalent.home, modifiers: [])
            Button("", action: { onGoToDayEdge(false) })
                .keyboardShortcut(KeyEquivalent.end, modifiers: [])
            zoomShortcuts
        }
        .hidden()
    }

    /// ⌘= / ⌘- step the zoom ladder, ⌘0 fits the day (§7.3).
    ///
    /// Split out rather than inlined above: `ZStack` builds at most ten children before SwiftUI
    /// needs a `Group`, and the shortcut list is already at that limit.
    @ViewBuilder
    private var zoomShortcuts: some View {
        if let archive {
            Group {
                Button("", action: { onZoom(archive.zoom.tighter) })
                    .keyboardShortcut("=", modifiers: .command)
                Button("", action: { onZoom(archive.zoom.wider) })
                    .keyboardShortcut("-", modifiers: .command)
                Button("", action: { onZoom(TimelineZoom.widest) })
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }

    // MARK: - Private Helpers

    /// The invisible strip that brings the scrubber back (§6.6).
    ///
    /// Taller than the chrome it reveals, so the pointer triggers it before it arrives — chrome that
    /// appears exactly under the pointer feels like it was hit rather than summoned.
    private var approachStrip: some View {
        SwiftUI.Color.clear
            .frame(height: StageTimelineMetrics.approachHeight)
            .contentShape(Rectangle())
            // ⛔ CONTINUOUS, AND ALWAYS HIT-TESTABLE. Two bugs lived in the four lines this
            // replaces, and together they are "it shows once and never again".
            //
            // `onHover` fires on a **boundary crossing**. `allowsHitTesting(!isVisible)` turned
            // this strip off while the panel was up — so when the panel hid, the strip switched
            // back on underneath a pointer that was already inside it, and no crossing was left to
            // report. The user had to leave the bottom of the window entirely and come back, which
            // nobody would guess. `onContinuousHover` reports *position*, so the next pixel of
            // movement re-arms it.
            //
            // And the strip no longer switches off: it sits under the panel in the `ZStack`, so
            // while the panel is up the panel gets the pointer and this sees nothing anyway.
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isNearBottom = true
                    // Approaching the bottom edge counts as having found it, so a user who never
                    // puts the pointer on the panel still gets hide-on-leave afterwards.
                    hasEngaged = true
                case .ended:
                    isNearBottom = false
                }
            }
    }

    @ViewBuilder
    private var chrome: some View {
        if isVisible {
            panel
        }
    }

    /// The scrubber, or a sentence saying why there is not one yet.
    ///
    /// ⛔ NEVER NOTHING. This used to be `if isVisible, let archive` — so a timeline opened on a
    /// camera whose index has not arrived drew no panel at all, and the command looked like it had
    /// failed. The index takes a round trip on a good day and never arrives on firmware that does
    /// not implement the endpoint; both are facts worth one line of text, and neither is worth an
    /// empty screen the user has to guess about.
    @ViewBuilder
    private var panel: some View {
        if let archive {
            scrubber(archive)
        } else {
            Text(absentReason, bundle: .vigilUI)
                .vType(VTheme.Typography.body)
                .foregroundStyle(VTheme.Color.Text.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(TimelinePanelSurface(isVisible: isVisible))
                .onHover { hovering in
                    isOverChrome = hovering
                    if !hovering { hasEngaged = true }
                }
        }
    }

    /// Which of the three "no scrubber" sentences applies.
    ///
    /// The refusal's own reason is deliberately not printed here: it is an ISAPI diagnostic, it is
    /// already in the toast and in the log, and a panel one line tall is not where a user reads a
    /// status code.
    private var absentReason: LocalizedStringKey {
        switch availability {
        case .unknown, .present:
            return "Reading this camera's recordings…"
        case .none:
            return "This camera did not list any recordings to scrub."
        case .refused:
            return "This camera would not list its recordings."
        }
    }

    private func scrubber(_ archive: VLibraryArchive) -> some View {
        Group {
            VStack(alignment: .leading, spacing: VTheme.Space.xs) {
                dayStepper(archive.day)
                VTimelineView(tracks: archive.tracks,
                              day: archive.day,
                              window: archive.window,
                              zoom: archive.zoom,
                              clock: clock,
                              playhead: archive.playhead,
                              isScrubbing: archive.isScrubbing,
                              isLoading: archive.isLoading,
                              magnetismEnabled: archive.magnetismEnabled,
                              onScrub: onScrub,
                              onZoom: onZoom,
                              onActivateMarker: onActivateMarker,
                              rate: rate,
                              isRateAdjustable: isRateAdjustable,
                              isPaused: isPaused,
                              onTogglePause: onTogglePause,
                              onFrameStep: onFrameStep,
                              onRate: onRate)
            }
            .modifier(TimelinePanelSurface(isVisible: isVisible))
            .onHover { hovering in
                isOverChrome = hovering
                // Leaving the panel is the moment it stops being pinned: the user has seen it,
                // used it or decided not to, and from here it behaves like chrome again.
                if !hovering { hasEngaged = true }
            }
        }
    }

    /// `‹ 28 Jul 2026 ›`, the day stepper UX.md §7.2 puts in the playback toolbar.
    private func dayStepper(_ day: TimelineDay) -> some View {
        HStack(spacing: VTheme.Space.xs) {
            VButton(symbol: VTheme.Symbol.stepBack,
                    style: .icon,
                    size: .sm,
                    accessibilityLabel: "Previous day",
                    action: { onSelectDay(clock.day(day, offsetByDays: -1)) })
            dayLabel(day)
            VButton(symbol: VTheme.Symbol.stepForward,
                    style: .icon,
                    size: .sm,
                    accessibilityLabel: "Next day",
                    action: { onSelectDay(clock.day(day, offsetByDays: 1)) })
                // Never past today: the camera cannot have recorded tomorrow, and a stepper that
                // walks into an empty future is a control that only produces empty screens.
                .disabled(clock.day(containing: clock.now).start <= day.start)
            Spacer(minLength: 0)
            if syncLabel != nil {
                VButton(symbol: .synchronisedPlayback,
                        style: isSyncEnabled ? .primary : .icon,
                        size: .sm,
                        accessibilityLabel: isSyncEnabled
                            ? "Stop synchronized playback"
                            : "Synchronize visible cameras",
                        action: onToggleSync)
                    .help(syncLabel ?? "Synchronize visible cameras")
            }
            VButton(symbol: VTheme.Symbol.close,
                    style: .icon,
                    size: .sm,
                    accessibilityLabel: "Close",
                    action: onDismiss)
        }
    }

    /// The date between the two steppers, which is also the calendar's button and its anchor.
    ///
    /// §7.2 puts the popover on the date itself rather than on a separate calendar glyph — the label
    /// is already the thing the eye goes to when asking "which day am I on", so it is the thing to
    /// click when the answer is "not this one".
    private func dayLabel(_ day: TimelineDay) -> some View {
        Button {
            openCalendar(around: day)
        } label: {
            Text(verbatim: StageTimelineChrome.dayLabel.string(from: day.start))
                .vType(VTheme.Typography.mono.numeric)
                .foregroundStyle(VTheme.Color.Text.primary)
                .frame(minWidth: StageTimelineMetrics.dayLabelWidth, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Go to date")
        .popover(isPresented: $showsCalendar, arrowEdge: .top) {
            calendar(around: day)
        }
    }

    @ViewBuilder
    private func calendar(around day: TimelineDay) -> some View {
        if let month {
            VTimelineMonthPicker(grid: month,
                                 clock: clock,
                                 isLoading: isLoadingMonth,
                                 onSelectMonth: onSelectMonth,
                                 onSelectDay: { chosen in
                                     showsCalendar = false
                                     onSelectDay(chosen)
                                 })
        } else {
            // Reachable only if the window has not answered `onSelectMonth` yet. Sized so the
            // popover does not open as a 1 pt sliver and then jump to full size.
            SwiftUI.Color.clear
                .frame(width: StageTimelineMetrics.calendarPlaceholder,
                       height: StageTimelineMetrics.calendarPlaceholder)
                .onAppear { openCalendar(around: day) }
        }
    }

    /// Opens the popover, asking for the month the given day sits in.
    ///
    /// Asks every time rather than only on first open: the coordinator caches months, so a repeat
    /// costs nothing, and going through it is what keeps the selected-day ring on the right cell
    /// after the day has been stepped with the calendar shut.
    private func openCalendar(around day: TimelineDay) {
        let parts = clock.calendar.dateComponents([.year, .month], from: day.start)
        guard let year = parts.year, let month = parts.month else { return }
        onSelectMonth(year, month)
        showsCalendar = true
    }

    /// Whether the scrubber is up.
    ///
    /// ⚠️ §6.6 also brings chrome back on "any key", which this does not do: SwiftUI has no
    /// key-press-anywhere hook without an AppKit responder, and a responder that swallowed keys
    /// would take ⌘R and Escape with it. Pointer approach only, and said so rather than pretended.
    private var isVisible: Bool {
        !hasEngaged || isNearBottom || isOverChrome || showsCalendar
    }
}

// MARK: - StageTimelineChrome

/// Formatting for the overlay. A namespace because a `DateFormatter` is expensive to rebuild and
/// this one is shared by every render.
private enum StageTimelineChrome {

    /// The day, in the user's own locale.
    static let dayLabel: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

// MARK: - TimelinePanelSurface

/// The floating panel both timeline states share: E2 glass, the same insets, the same transition.
///
/// A modifier rather than a copied block, because the two branches — the scrubber and the
/// "still reading" line — must be the same object as far as the eye is concerned. Two hand-copied
/// backgrounds are two things to keep in step, and the one that gets forgotten is the one the user
/// sees least often.
private struct TimelinePanelSurface: ViewModifier {

    let isVisible: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, VTheme.Space.lg)
            .padding(.vertical, VTheme.Space.md)
            .background {
                // E2 glass, with the solid fallback under Reduce Transparency — the treatment
                // DESIGN.md §2.4 gives every floating surface.
                VVisualEffect(material: .hudWindow,
                              blending: .withinWindow,
                              state: .active)
                    .overlay(VTheme.Color.Layer.scrim.opacity(0.25))
                    .allowsHitTesting(false)
            }
            // The timing is the container's: this only says *how* the panel enters and leaves.
            // Both halves used to live on the panel, which is why neither worked.
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - StageTimelineMetrics

/// Sizes for the overlay.
private enum StageTimelineMetrics {

    /// How far up from the bottom edge the pointer wakes the scrubber. Deeper than the chrome is
    /// tall, so it is summoned rather than collided with.
    static let approachHeight: CGFloat = 150

    /// Reserved width for the day label, so stepping a day does not shuffle the buttons either side.
    static let dayLabelWidth: CGFloat = 108

    /// Placeholder square for the instant between the popover opening and the first grid arriving.
    /// Roughly the calendar's own size, so the popover does not visibly resize under the pointer.
    static let calendarPlaceholder: CGFloat = 260
}

#endif  // os(macOS)
