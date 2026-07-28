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

    /// The calendar and zone the ruler and the day label are rendered in.
    let clock: TimelineClock

    /// Steps the day the timeline is showing.
    let onSelectDay: (TimelineDay) -> Void

    /// Forwarded to `VTimelineView`.
    let onScrub: (VTimelineScrubPhase, Date) -> Void
    let onHoverInstant: (Date?) -> Void
    let onZoom: (TimelineZoom) -> Void
    let onActivateMarker: (TimelineMarkerCluster) -> Void

    /// Steps the playhead by a number of seconds, positive or negative.
    let onStep: (Double) -> Void

    /// Moves to the next or previous edge of recorded footage.
    let onStepToEdge: (Bool) -> Void

    /// Puts the timeline away.
    let onDismiss: () -> Void

    /// Whether the pointer is near the bottom edge, and whether it is over the chrome itself.
    ///
    /// Two flags and not one: the chrome must stay up while the pointer is *on* it, and a single
    /// flag would drop it the moment the pointer left the trigger strip to reach the scrubber —
    /// which is the gesture the strip exists to enable.
    @State private var isNearBottom = false
    @State private var isOverChrome = false

    @Environment(\.vMotionEnabled) private var motionEnabled

    // MARK: - Initialisation

    /// Creates the overlay.
    ///
    /// Spelled out rather than left to the memberwise initialiser: the two hover flags are
    /// `private`, and Swift lowers a synthesised memberwise initialiser to the least accessible
    /// stored property it includes, which would make it unreachable from the window.
    init(archive: VLibraryArchive?,
         clock: TimelineClock,
         onSelectDay: @escaping (TimelineDay) -> Void,
         onScrub: @escaping (VTimelineScrubPhase, Date) -> Void,
         onHoverInstant: @escaping (Date?) -> Void,
         onZoom: @escaping (TimelineZoom) -> Void,
         onActivateMarker: @escaping (TimelineMarkerCluster) -> Void,
         onStep: @escaping (Double) -> Void,
         onStepToEdge: @escaping (Bool) -> Void,
         onDismiss: @escaping () -> Void) {
        self.archive = archive
        self.clock = clock
        self.onSelectDay = onSelectDay
        self.onScrub = onScrub
        self.onHoverInstant = onHoverInstant
        self.onZoom = onZoom
        self.onActivateMarker = onActivateMarker
        self.onStep = onStep
        self.onStepToEdge = onStepToEdge
        self.onDismiss = onDismiss
    }

    // MARK: - View

    var body: some View {
        ZStack(alignment: .bottom) {
            approachStrip
            chrome
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
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
        }
        .hidden()
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
            .onHover { isNearBottom = $0 }
            .allowsHitTesting(!isVisible)
    }

    @ViewBuilder
    private var chrome: some View {
        if isVisible, let archive {
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
                              preview: archive.preview,
                              onScrub: onScrub,
                              onHoverInstant: onHoverInstant,
                              onZoom: onZoom,
                              onActivateMarker: onActivateMarker)
            }
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
            .onHover { isOverChrome = $0 }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(VTheme.Motion.resolved(VTheme.Motion.standard, reduced: !motionEnabled),
                       value: isVisible)
        }
    }

    /// `‹ 28 Jul 2026 ›`, the day stepper UX.md §7.2 puts in the playback toolbar.
    private func dayStepper(_ day: TimelineDay) -> some View {
        HStack(spacing: VTheme.Space.xs) {
            VButton(symbol: VTheme.Symbol.back10,
                    style: .icon,
                    size: .sm,
                    accessibilityLabel: "Previous day",
                    action: { onSelectDay(clock.day(day, offsetByDays: -1)) })
            Text(verbatim: StageTimelineChrome.dayLabel.string(from: day.start))
                .vType(VTheme.Typography.mono.numeric)
                .foregroundStyle(VTheme.Color.Text.primary)
                .frame(minWidth: StageTimelineMetrics.dayLabelWidth, alignment: .leading)
            VButton(symbol: VTheme.Symbol.forward10,
                    style: .icon,
                    size: .sm,
                    accessibilityLabel: "Next day",
                    action: { onSelectDay(clock.day(day, offsetByDays: 1)) })
                // Never past today: the camera cannot have recorded tomorrow, and a stepper that
                // walks into an empty future is a control that only produces empty screens.
                .disabled(clock.day(containing: clock.now).start <= day.start)
            Spacer(minLength: 0)
            VButton(symbol: VTheme.Symbol.close,
                    style: .icon,
                    size: .sm,
                    accessibilityLabel: "Close",
                    action: onDismiss)
        }
    }

    /// Whether the scrubber is up.
    ///
    /// ⚠️ §6.6 also brings chrome back on "any key", which this does not do: SwiftUI has no
    /// key-press-anywhere hook without an AppKit responder, and a responder that swallowed keys
    /// would take ⌘R and Escape with it. Pointer approach only, and said so rather than pretended.
    private var isVisible: Bool {
        isNearBottom || isOverChrome
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

// MARK: - StageTimelineMetrics

/// Sizes for the overlay.
private enum StageTimelineMetrics {

    /// How far up from the bottom edge the pointer wakes the scrubber. Deeper than the chrome is
    /// tall, so it is summoned rather than collided with.
    static let approachHeight: CGFloat = 150

    /// Reserved width for the day label, so stepping a day does not shuffle the buttons either side.
    static let dayLabelWidth: CGFloat = 108
}

#endif  // os(macOS)
