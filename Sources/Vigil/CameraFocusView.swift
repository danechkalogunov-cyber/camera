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

/// The playback surface: video filling the stage, chrome over it.
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
@MainActor
struct CameraFocusView<Video: View>: View {

    // MARK: - Stored Properties

    /// The camera's name, shown in the top-left over the picture.
    let name: String

    /// The archive to scrub, or `nil` when the camera has no index to show.
    let archive: VLibraryArchive?

    /// The calendar and zone the ruler and the day label are rendered in.
    let clock: TimelineClock

    /// The picture. Built by the caller so `VigilRender` stays out of this file.
    let video: () -> Video

    /// Steps the day the timeline is showing.
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

    /// Raised by any key press, so the chrome answers the keyboard as well (§6.6).
    @State private var wokenByKey = false

    @Environment(\.vMotionEnabled) private var motionEnabled

    // MARK: - View

    var body: some View {
        ZStack(alignment: .bottom) {
            video()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(VTheme.Color.Layer.videoWell)

            header
                .frame(maxHeight: .infinity, alignment: .top)

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

    // MARK: - Header

    /// The camera's name and the way out, over the picture.
    ///
    /// Always visible, unlike the bottom chrome: knowing which camera you are looking at is not an
    /// occasional need, and a full-bleed picture with no way back is a trap.
    private var header: some View {
        HStack(spacing: VTheme.Space.sm) {
            Text(verbatim: name)
                .vType(VTheme.Typography.headline)
                .foregroundStyle(VTheme.Color.Text.inverse)
            Spacer(minLength: VTheme.Space.sm)
            if let archive {
                dayStepper(archive.day)
            }
            VButton(symbol: VTheme.Symbol.close,
                    style: .icon,
                    size: .sm,
                    accessibilityLabel: "Close",
                    action: onClose)
        }
        .padding(.horizontal, VTheme.Space.lg)
        .padding(.vertical, VTheme.Space.md)
        .background {
            // A gradient rather than a bar: §7.1 puts the label over the picture, and a solid strip
            // across the top would crop the very thing being watched.
            LinearGradient(colors: [VTheme.Color.Layer.scrim.opacity(0.55), .clear],
                           startPoint: .top,
                           endPoint: .bottom)
                .allowsHitTesting(false)
        }
    }

    /// `‹ 26 Jul 2026 ›`, the day stepper UX.md §7.2 puts in the playback toolbar.
    private func dayStepper(_ day: TimelineDay) -> some View {
        HStack(spacing: VTheme.Space.xs) {
            VButton(symbol: VTheme.Symbol.back10,
                    style: .icon,
                    size: .sm,
                    accessibilityLabel: "Previous day",
                    action: { onSelectDay(clock.day(day, offsetByDays: -1)) })
            Text(verbatim: VFocusChrome.dayLabel.string(from: day.start))
                .vType(VTheme.Typography.mono.numeric)
                .foregroundStyle(VTheme.Color.Text.inverse)
                .frame(minWidth: VFocusMetrics.dayLabelWidth)
            VButton(symbol: VTheme.Symbol.forward10,
                    style: .icon,
                    size: .sm,
                    accessibilityLabel: "Next day",
                    action: { onSelectDay(clock.day(day, offsetByDays: 1)) })
                // Never past today: the camera cannot have recorded tomorrow, and a stepper that
                // walks into an empty future is a control that only produces empty screens.
                .disabled(clock.day(containing: clock.now).start <= day.start)
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
            VStack(spacing: 0) {
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

    /// Whether the bottom chrome is up.
    private var isChromeVisible: Bool {
        isNearBottom || isOverChrome || wokenByKey
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
