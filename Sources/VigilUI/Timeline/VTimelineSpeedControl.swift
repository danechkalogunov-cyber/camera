//
//  VTimelineSpeedControl.swift
//  VigilUI
//
//  The playback-speed stepper: slower, the current stop, faster.
//  macOS-only. Implements docs/UX.md §7.4 against the ladder in `TimelinePlaybackRate`.
//
//  ⚠️ A STEPPER AND NOT A SLIDER, unlike its neighbour `VTimelineZoomControl`. Zoom is a view of
//  data already on screen and costs nothing to change; a speed change costs a whole RTSP session on
//  the firmware this was built against, because a DS-I256 refuses a second `PLAY`
//  (docs/PLAYBACK-LATENCY.md). Dragging a slider across ten stops would open ten sessions. Two
//  buttons make each change deliberate, and each one is a decision the user meant.
//

#if os(macOS)

import SwiftUI

// MARK: - VTimelineSpeedControl

/// Steps through ``TimelinePlaybackRate``'s ladder, one stop per press.
@MainActor
package struct VTimelineSpeedControl: View {

    // MARK: - Stored Properties

    /// The stop currently playing.
    package let rate: TimelinePlaybackRate

    /// Whether an archive is playing at all. Live has no speed — asking a live channel for `Scale:
    /// 4` is asking for the next four seconds — so the whole control is disabled rather than
    /// hidden: a control that vanishes teaches nothing about why.
    package let isEnabled: Bool

    /// Called with the requested stop. The caller reopens the session; this control does not know
    /// that a change costs anything.
    package let onRate: (TimelinePlaybackRate) -> Void

    // MARK: - Initialisation

    /// Creates the control.
    package init(rate: TimelinePlaybackRate,
                 isEnabled: Bool,
                 onRate: @escaping (TimelinePlaybackRate) -> Void) {
        self.rate = rate
        self.isEnabled = isEnabled
        self.onRate = onRate
    }

    // MARK: - View

    package var body: some View {
        HStack(spacing: VTheme.Space.xs) {
            VButton(symbol: VTheme.Symbol.reverse,
                    style: VButton.Style.icon,
                    size: VButton.Size.xs,
                    accessibilityLabel: "Play slower") {
                onRate(rate.slower)
            }
            .disabled(!isEnabled || rate == TimelinePlaybackRate.allCases.first)

            // `verbatim` because the ladder's labels are already glyphs — "¼×", "−8×" — assembled
            // in `TimelinePlaybackRate`. Running them through localisation would ask a translator
            // to translate a multiplication sign.
            Text(verbatim: rate.label)
                .vType(VTheme.Typography.monoSmall.numeric)
                .foregroundStyle(isEnabled
                    ? VTheme.Color.Text.primary
                    : VTheme.Color.Text.tertiary)
                .frame(minWidth: 34)
                .padding(.vertical, VTheme.Space.hair)
                .overlay {
                    VTheme.Radius.shape(VTheme.Radius.sm)
                        .strokeBorder(VTheme.Color.Stroke.default,
                                      lineWidth: VTheme.Border.thin)
                }
                .accessibilityLabel(Text("Playback speed", bundle: .vigilUI))
                .accessibilityValue(Text(verbatim: rate.label))

            VButton(symbol: VTheme.Symbol.speed,
                    style: VButton.Style.icon,
                    size: VButton.Size.xs,
                    accessibilityLabel: "Play faster") {
                onRate(rate.faster)
            }
            .disabled(!isEnabled || rate == TimelinePlaybackRate.allCases.last)
        }
        .opacity(isEnabled ? 1 : 0.55)
    }
}

#endif  // os(macOS)
