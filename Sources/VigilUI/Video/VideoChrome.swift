//
//  VideoChrome.swift
//  VigilUI
//
//  The three pieces of chrome that sit on the video well: the name chip, the status line and the
//  degraded banner. All three use the solid scrim recipe, inside their own shape.
//  macOS-only. Implements docs/DESIGN.md §9.13, §2.3, §7.4 #23 and #39, and docs/UX.md §12.5.
//

#if os(macOS)

import SwiftUI

// MARK: - CameraNameChip

/// The camera's name, bottom-leading on the well.
///
/// At rest it sits at 0.70 opacity and rises to 1.0 under the pointer (§9.13): present enough to
/// answer "which camera is this?" at a glance, quiet enough that the frame stays the hero (P1).
@MainActor
package struct CameraNameChip: View {

    /// The camera being named.
    package let camera: LiveCameraIdentity

    /// Whether the pointer is over the well.
    package let isHovered: Bool

    @Environment(\.vMotionEnabled) private var motionEnabled

    /// Creates the chip.
    package init(camera: LiveCameraIdentity, isHovered: Bool) {
        self.camera = camera
        self.isHovered = isHovered
    }

    package var body: some View {
        VChip(.onVideo, restOpacity: isHovered ? 1.0 : 0.70) {
            VIdentityMark(colour: camera.colour, initial: camera.initial)
            Text(verbatim: camera.name)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .animation(VTheme.Motion.resolved(VTheme.Motion.micro, reduced: !motionEnabled),
                   value: isHovered)
        .accessibilityLabel(Text(verbatim: camera.name))
    }
}

// MARK: - ConnectionStatusChip

/// The status line: a dot and a word.
///
/// The dot is driven by the window's single pulse clock so that every indicator in the app
/// breathes in unison, and the word is there because colour alone is never allowed to carry a
/// state (DESIGN.md §7.5, §10.5).
@MainActor
package struct ConnectionStatusChip: View {

    /// The state to report.
    package let state: LiveConnectionState

    /// Creates the chip.
    package init(state: LiveConnectionState) {
        self.state = state
    }

    package var body: some View {
        // The clock wraps **only** this chip. A `TimelineView` re-evaluates its content every
        // second, and the container that owns a video layer must never be re-laid-out on a timer
        // (DESIGN.md §7.9 rule 1).
        VPulseClock {
            VChip(.onVideo) {
                VLiveDot(state.dot)
                Text(state.statusWord, bundle: .vigilUI)
                    .vType(VTheme.Typography.caption2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(state.statusWord, bundle: .vigilUI))
    }
}

// MARK: - DegradedBanner

/// The banner that names *why* a flowing stream looks bad.
///
/// It appears only after 1.5 s of sustained degradation (`Delay.degradedDebounce`), because a
/// banner that flickers on a one-second network hiccup is worse than no banner (§7.4 #39).
///
/// ⛔ The scrim is inside the banner's own shape. The only full-tile scrim Vigil allows is the
/// offline overlay's (§2.3, R-36).
@MainActor
package struct DegradedBanner: View {

    /// The entry offset from §7.4 #39: the banner drops in from 28 pt above its resting place.
    package static let entryOffset: CGFloat = -28

    /// The measured cause.
    package let cause: DegradedCause

    /// Performs the offered remedy.
    package let onRemedy: (ConnectRemedy) -> Void

    /// Creates the banner.
    package init(cause: DegradedCause, onRemedy: @escaping (ConnectRemedy) -> Void) {
        self.cause = cause
        self.onRemedy = onRemedy
    }

    package var body: some View {
        HStack(spacing: VTheme.Space.sm) {
            VTheme.Symbol.warning.image()
                .vIcon(size: VTheme.Icon.xs, weight: VTheme.Icon.Weight.xs)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            cause.message
                .vType(VTheme.Typography.caption1Numeric)
                .foregroundStyle(VTheme.Color.Text.onVideo)
                .lineLimit(1)
            Spacer(minLength: VTheme.Space.xs)
            if let remedy = cause.remedy {
                VButton(remedy.title, style: .ghost, size: .xs) {
                    onRemedy(remedy)
                }
            }
        }
        .padding(.horizontal, VTheme.Space.md)
        .frame(height: VTheme.Metrics.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vScrim(VTheme.Color.Scrim.strong, radius: VTheme.Radius.sm)
        .accessibilityElement(children: .contain)
    }

    /// Informational news takes the accent; an actual degradation takes `warn` (§3.2, P3).
    private var tint: SwiftUI.Color {
        cause.isTransient ? VTheme.Color.Semantic.accent : VTheme.Color.Semantic.warn
    }
}

// MARK: - Previews

#if DEBUG && !VIGIL_NO_PREVIEWS
#Preview("Video chrome") {
    let camera = LiveCameraIdentity(id: UUID(), name: "Front Door", host: "192.168.1.64")
    return VStack(spacing: VTheme.Space.md) {
        DegradedBanner(cause: .packetLoss(fraction: 0.031)) { _ in }
        HStack(spacing: VTheme.Space.xs) {
            CameraNameChip(camera: camera, isHovered: false)
            ConnectionStatusChip(state: .live)
            ConnectionStatusChip(state: .connecting(.authenticating))
            ConnectionStatusChip(state: .degraded(.packetLoss(fraction: 0.031)))
            ConnectionStatusChip(state: .offline(OfflineDetail()))
        }
    }
    .padding(VTheme.Space.xl)
    .background(VTheme.Color.Layer.videoWell)
    .vOnVideo()
}
#endif

#endif  // os(macOS)
