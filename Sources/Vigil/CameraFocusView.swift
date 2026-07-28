//
//  CameraFocusView.swift
//  Vigil
//
//  One camera, full bleed, with the archive timeline revealed at the bottom edge on approach.
//  macOS-only. Implements docs/UX.md §7.1–§7.3 (the Playback surface) and §6.6 (chrome that hides
//  and returns on pointer-near-bottom).
//

#if os(macOS)

import Foundation
import SwiftUI

import VigilProtocols
import VigilUI

// MARK: - CameraFocusView

/// The playback surface: the camera filling the stage, the scrubber at its bottom edge.
///
/// **Why the timeline lives here and not in Recordings.** UX.md §7 gives the timeline its own
/// surface — a canvas with the scrubber beneath it — and §1.2 lists `playback` as a scene of its
/// own. Mounting it inside the Recordings *list* put a scrubber on a light canvas between a header
/// of legend chips and a table of files, which is neither what §7.1 draws nor a place anyone would
/// look for it. Recordings is a list of files; this is the surface you review footage on.
///
/// **Why it is a stage route rather than a window.** UX.md §1.2 asks for a separate scene, and that
/// needs the multi-camera model, the day/camera-set toolbar and the transport bar — none of which
/// exist. A route inside the main window gives the *placement* the plan specifies now, and becomes
/// the body of that window when the scene lands, because everything here already takes its data as
/// arguments.
///
/// **The chrome hides.** §6.6: the transport and the timeline "return on pointer-near-bottom or any
/// key". So the stage is a picture until the pointer approaches the bottom edge, which is the
/// difference between a viewer and a control panel with a video in it.
///
/// ⛔ **No chrome of its own beyond that.** An earlier version carried a title bar with the camera's
/// name, a day stepper and a close button across the top, and it read as a second window opening —
/// which is not what "open this camera" should feel like. The tile already names the camera and
/// carries its own buttons; opening one collapses the side panel and lets the picture have the
/// width. Escape goes back.
@MainActor
struct CameraFocusView<Video: View>: View {

    // MARK: - Stored Properties

    /// The archive to scrub, or `nil` when the camera has no index to show.
    let archive: VLibraryArchive?

    /// The calendar and zone the ruler and the day label are rendered in.
    let clock: TimelineClock

    /// The picture. Built by the caller so `VigilRender` stays out of this file.
    let video: () -> Video

    /// Steps the day the timeline is showing. Called by the scrubber's own chrome.
    let onSelectDay: (TimelineDay) -> Void

    /// Forwarded to `VTimelineView`.
    let onScrub: (VTimelineScrubPhase, Date) -> Void
    let onZoom: (TimelineZoom) -> Void
    let onActivateMarker: (TimelineMarkerCluster) -> Void

    /// Leaves the focused camera and returns to the tile stage.
    let onClose: () -> Void

    /// Whether the pointer is near the bottom edge, or over the chrome itself.
    ///
    /// Two separate flags and not one: the chrome must stay up while the pointer is *on* it, and a
    /// single flag would drop it the moment the pointer left the trigger strip to reach the
    /// scrubber — which is the gesture the strip exists to enable.
    @State private var isNearBottom = false
    @State private var isOverChrome = false

    @Environment(\.vMotionEnabled) private var motionEnabled

    // MARK: - Initialisation

    /// Creates the surface.
    ///
    /// Spelled out rather than left to the memberwise initialiser. The two hover flags are
    /// `private`, and Swift lowers a synthesised memberwise initialiser to the least accessible
    /// stored property it includes — which would make it `private` to this file and unreachable
    /// from the window that presents it. An explicit `init` is not worth guessing about.
    ///
    /// - Parameters:
    ///   - archive: the day to scrub, or `nil` when the camera has no index.
    ///   - clock: the calendar the ruler and the day label are rendered in.
    ///   - video: the picture, built by the caller so `VigilRender` stays out of this file.
    ///   - onSelectDay: steps the day the timeline shows.
    ///   - onScrub: forwarded to the scrubber.
    ///   - onZoom: forwarded to the scrubber.
    ///   - onActivateMarker: forwarded to the scrubber.
    ///   - onClose: returns to the tile stage.
    init(archive: VLibraryArchive?,
         clock: TimelineClock,
         @ViewBuilder video: @escaping () -> Video,
         onSelectDay: @escaping (TimelineDay) -> Void,
         onScrub: @escaping (VTimelineScrubPhase, Date) -> Void,
         onZoom: @escaping (TimelineZoom) -> Void,
         onActivateMarker: @escaping (TimelineMarkerCluster) -> Void,
         onClose: @escaping () -> Void) {
        self.archive = archive
        self.clock = clock
        self.video = video
        self.onSelectDay = onSelectDay
        self.onScrub = onScrub
        self.onZoom = onZoom
        self.onActivateMarker = onActivateMarker
        self.onClose = onClose
    }

    // MARK: - View

    var body: some View {
        ZStack(alignment: .bottom) {
            video()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            approachStrip
            chrome
        }
        .background(VTheme.Color.Layer.videoWell)
        .clipped()
        // Escape leaves, exactly as it does everywhere else in the app. Declared as a zero-sized
        // button because that is how a key equivalent is expressed in pure SwiftUI.
        .background {
            Button("", action: onClose)
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
    }

    // MARK: - Bottom chrome

    /// The invisible strip that brings the chrome back (§6.6).
    ///
    /// Taller than the chrome it reveals, so the pointer triggers it before it arrives — chrome that
    /// appears exactly under the pointer feels like it was hit rather than summoned.
    private var approachStrip: some View {
        Color.clear
            .frame(height: VFocusMetrics.approachHeight)
            .contentShape(Rectangle())
            .onHover { isNearBottom = $0 }
            .allowsHitTesting(!isChromeVisible)
    }

    /// The timeline, or the reason there is not one.
    @ViewBuilder
    private var chrome: some View {
        if isChromeVisible, let archive {
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
                              onZoom: onZoom,
                              onActivateMarker: onActivateMarker)
            }
            .padding(.horizontal, VTheme.Space.lg)
            .padding(.bottom, VTheme.Space.lg)
            .background {
                // E2 glass over the picture, with the solid fallback under Reduce Transparency —
                // the same treatment DESIGN.md §2.4 gives every floating surface.
                VVisualEffect(material: .hudWindow,
                              blending: .withinWindow,
                              state: .active)
                    .overlay(VTheme.Color.Layer.scrim.opacity(0.25))
                    .allowsHitTesting(false)
            }
            .onHover { isOverChrome = $0 }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(VTheme.Motion.resolved(VTheme.Motion.standard, reduced: !motionEnabled),
                       value: isChromeVisible)
        }
    }

    /// `‹ 28 Jul 2026 ›`, the day stepper UX.md §7.2 puts in the playback toolbar.
    ///
    /// Inside the bottom chrome rather than in a bar of its own: it belongs to the timeline, it
    /// appears and leaves with it, and a strip across the top of the picture is what made this look
    /// like a separate window.
    private func dayStepper(_ day: TimelineDay) -> some View {
        HStack(spacing: VTheme.Space.xs) {
            VButton(symbol: VTheme.Symbol.back10,
                    style: .icon,
                    size: .sm,
                    accessibilityLabel: "Previous day",
                    action: { onSelectDay(clock.day(day, offsetByDays: -1)) })
            Text(verbatim: VFocusChrome.dayLabel.string(from: day.start))
                .vType(VTheme.Typography.mono.numeric)
                .foregroundStyle(VTheme.Color.Text.onVideo)
                .frame(minWidth: VFocusMetrics.dayLabelWidth, alignment: .leading)
            VButton(symbol: VTheme.Symbol.forward10,
                    style: .icon,
                    size: .sm,
                    accessibilityLabel: "Next day",
                    action: { onSelectDay(clock.day(day, offsetByDays: 1)) })
                // Never past today: the camera cannot have recorded tomorrow, and a stepper that
                // walks into an empty future is a control that only produces empty screens.
                .disabled(clock.day(containing: clock.now).start <= day.start)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VTheme.Space.sm)
    }

    /// Whether the bottom chrome is up.
    ///
    /// ⚠️ §6.6 also brings it back on "any key", which this does not do: SwiftUI has no
    /// key-press-anywhere hook without an AppKit responder, and a first responder that swallowed
    /// keys would take ⌘R and Escape with it. Pointer approach only, and reported as such.
    private var isChromeVisible: Bool {
        isNearBottom || isOverChrome
    }

}

// MARK: - VFocusChrome

/// Formatting shared by the focused surface.
///
/// A namespace and not a `static let` on the view: `CameraFocusView` is generic over its video, and
/// Swift rejects a static *stored* property inside a generic type outright. A `DateFormatter` is
/// expensive enough to build that recreating it per render is worth avoiding, so it lives here.
private enum VFocusChrome {

    /// The day, in the user's own locale.
    static let dayLabel: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

// MARK: - VFocusMetrics

/// Sizes for the focused surface.
private enum VFocusMetrics {

    /// How far up from the bottom edge the pointer wakes the chrome.
    ///
    /// Deeper than the chrome is tall, so it is summoned rather than collided with.
    static let approachHeight: CGFloat = 140

    /// Reserved width for the day label, so stepping a day does not shuffle the buttons either side
    /// of it as the string length changes.
    static let dayLabelWidth: CGFloat = 108
}

#endif  // os(macOS)
