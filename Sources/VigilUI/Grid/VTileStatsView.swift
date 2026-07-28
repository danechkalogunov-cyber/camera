//
//  VTileStatsView.swift
//  VigilUI
//
//  The tile's statistics readout and the empty cell beside it, plus the metrics both share.
//  macOS-only. Split from GridTileView.swift, which docs/API_CONTRACT.md §7.2 caps at 600
//  lines. ⚠️ Separate top-level types, not extensions, so `private` inside each still means
//  what it did.
//

#if os(macOS)

import Foundation
import SwiftUI
import VigilProtocols

// MARK: - VTileStats

/// The negotiated facts the tile's top-trailing readout prints.
///
/// A value type rather than a live observation on purpose: the readout updates at **1 Hz, not per
/// frame** (UX.md §5.3), so whatever owns the stream samples it on a timer and hands a snapshot down.
/// Anything finer would put a SwiftUI invalidation on the frame path.
package struct VTileStats: Sendable, Hashable {

    /// Codec name, e.g. `H.265`.
    package var codec: String

    /// Pixel dimensions, or `nil` before the first frame.
    package var dimensions: FrameDimensions?

    /// Presented frame rate, or `nil` until a second of samples exists — the readout shows `—`
    /// rather than a wrong number (UX.md §15.2 step 5).
    package var framesPerSecond: Double?

    /// Whether the decode is on the hardware path, which earns the `bolt.fill` glyph.
    package var isHardwareDecode: Bool

    /// Creates a snapshot.
    package init(codec: String,
                 dimensions: FrameDimensions? = nil,
                 framesPerSecond: Double? = nil,
                 isHardwareDecode: Bool = false) {
        self.codec = codec
        self.dimensions = dimensions
        self.framesPerSecond = framesPerSecond
        self.isHardwareDecode = isHardwareDecode
    }

    /// `HH:MM:SS` for the recording elapsed readout.
    ///
    /// Written by hand rather than with a `Duration` format style because the tile needs exactly the
    /// mockup's `00:04:12` — zero-padded hours, no locale variation, monospaced — and a format style
    /// that changed with the locale would change the reserved width with it.
    package static func timecode(_ duration: Duration) -> String {
        let total = Swift.max(0, duration.components.seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02lld:%02lld:%02lld", hours, minutes, seconds)
    }
}

/// The pixel dimensions of a frame, as the readout prints them.
package struct FrameDimensions: Sendable, Hashable {

    /// Width in pixels.
    package var width: Int

    /// Height in pixels.
    package var height: Int

    /// Creates a size.
    package init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// `1920×1080`, with a true multiplication sign.
    package var label: String {
        "\(width)×\(height)"
    }
}

// MARK: - VGridTileMetrics

/// Sizes the tile decides with.
///
/// ⛔ `@MainActor` for the same reason as ``VTileActionMetrics``: the theme namespaces these read
/// are main-actor isolated, so a nonisolated static cannot touch them.
@MainActor
package enum VGridTileMetrics {

    /// Below this width the button row is dropped.
    ///
    /// The row's own width, plus room for the camera-name chip beside it and the chrome inset at
    /// both ends. Narrower than this and the two overlap in the middle.
    package static var actionBarMinimumWidth: CGFloat {
        VTileActionMetrics.width + VGridTileMetrics.nameChipReserve
            + VTheme.Metrics.tileChromeInset * 2
    }

    /// Below this height the row is dropped too: a very short tile puts the buttons over the
    /// picture's only usable band.
    package static let actionBarMinimumHeight: CGFloat = 160

    /// Room kept for the camera-name chip at the other end of the same edge.
    package static let nameChipReserve: CGFloat = 120
}

// MARK: - VTileStatsView

/// The tile's top-trailing telemetry pill.
@MainActor
package struct VTileStatsView: View {

    /// The snapshot to print.
    package let stats: VTileStats

    /// Whether to append the `REC` badge.
    package let isRecording: Bool

    @Environment(\.vPulsePhase) private var pulsePhase
    @Environment(\.vMotionEnabled) private var motionEnabled

    /// Creates the readout.
    package init(stats: VTileStats, isRecording: Bool) {
        self.stats = stats
        self.isRecording = isRecording
    }

    package var body: some View {
        HStack(spacing: VTheme.Space.xxs) {
            VChip(.onVideo) {
                HStack(spacing: VTheme.Space.xs) {
                    Text(verbatim: stats.codec)
                    if let dimensions = stats.dimensions {
                        Text(verbatim: "·")
                            .foregroundStyle(VTheme.Color.Text.onVideoDim)
                        Text(verbatim: dimensions.label)
                    }
                    Text(verbatim: "·")
                        .foregroundStyle(VTheme.Color.Text.onVideoDim)
                    Text(verbatim: frameRateLabel)
                        .vReserved(VTheme.Typography.Reserved.fps)
                    if stats.isHardwareDecode {
                        Image(systemName: VTheme.Symbol.hardwareDecode.name)
                            .foregroundStyle(VTheme.Color.Semantic.warn)
                    }
                }
                .vType(VTheme.Typography.monoSmall.numeric)
                .foregroundStyle(VTheme.Color.Text.onVideoSecondary)
            }
            if isRecording {
                recordingBadge
            }
        }
    }

    /// `25 fps`, or `—` until a second of samples exists.
    private var frameRateLabel: String {
        guard let fps = stats.framesPerSecond else { return "—" }
        return "\(Int(fps.rounded())) fps"
    }

    /// `● REC`, with the dot pulsing off the shared clock.
    private var recordingBadge: some View {
        VChip(.onVideo) {
            HStack(spacing: VTheme.Space.xxs) {
                Circle()
                    .fill(VTheme.Color.Semantic.live)
                    .frame(width: VLiveDot.dotSize, height: VLiveDot.dotSize)
                    .opacity(motionEnabled && !pulsePhase ? 0.55 : 1.0)
                    .animation(VTheme.Motion.resolvedLoop(VTheme.Motion.breathe, reduced: !motionEnabled),
                               value: pulsePhase)
                Text("REC", bundle: .vigilUI)
                    .vType(VTheme.Typography.caption2)
                    .foregroundStyle(VTheme.Color.Text.onVideo)
            }
        }
    }
}

// MARK: - VGridEmptyCell

/// The placeholder an unassigned cell shows.
///
/// Copy is UX.md §5.4's `stage.emptyCell.title` — "Add camera" — which is also what the approved
/// mockup renders; DESIGN.md §9.13's "Drop a camera" is the older wording and UX owns strings. The
/// visual is DESIGN's: a `layer.canvas` fill with a dashed `stroke.default` and a 22 pt `plus`, going
/// to an `accent` stroke over an `accent α 0.10` fill on hover.
///
/// It is a `Button`, not a tappable rectangle, so it is in the keyboard's path for free — an action a
/// mouse can reach must have a keyboard path (P6).
@MainActor
package struct VGridEmptyCell: View {

    /// Which cell this is, for the screen-reader's "position 3 of 16".
    package let position: Int

    /// How many cells there are.
    package let total: Int

    /// Whether a drag is hovering over this cell.
    package let isDropTarget: Bool

    /// Whether this cell has keyboard focus.
    package let isFocused: Bool

    /// Opens the camera picker.
    package let onChoose: () -> Void

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.vMotionEnabled) private var motionEnabled

    @State private var isHovering = false

    /// Creates a placeholder.
    package init(position: Int,
                 total: Int,
                 isDropTarget: Bool = false,
                 isFocused: Bool = false,
                 onChoose: @escaping () -> Void = {}) {
        self.position = position
        self.total = total
        self.isDropTarget = isDropTarget
        self.isFocused = isFocused
        self.onChoose = onChoose
    }

    package var body: some View {
        Button(action: onChoose) {
            VStack(spacing: VTheme.Space.sm) {
                Image(systemName: VTheme.Symbol.addCamera.name)
                    .font(VTheme.Icon.font(22, weight: VTheme.Icon.Weight.lg))
                    .foregroundStyle(VTheme.Color.Text.tertiary)
                Text("Add camera", bundle: .vigilUI)
                    .vType(VTheme.Typography.caption1)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(fill, in: VTheme.Radius.shape(VTheme.Radius.xl))
            .overlay { border }
            .contentShape(VTheme.Radius.shape(VTheme.Radius.xl))
        }
        .buttonStyle(PlainButtonStyle())
        .focusEffectDisabled()
        .onHover { hovering in
            withAnimation(VTheme.Motion.resolved(VTheme.Motion.micro, reduced: !motionEnabled)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel(Text("Empty cell", bundle: .vigilUI))
        .accessibilityValue(Text("Position \(position) of \(total)", bundle: .vigilUI))
        .accessibilityHint(Text("Drop a camera here or press Return to choose one",
                                bundle: .vigilUI))
    }

    /// `layer.canvas` at rest; the accent drop-target tint while a drag is over it.
    private var fill: SwiftUI.Color {
        if isDropTarget { return VTheme.Color.Semantic.Tint.dropTarget }
        if isHovering { return VTheme.Color.Semantic.accentTint(0.10) }
        return VTheme.Color.Layer.canvas
    }

    /// A dashed hairline, going solid accent under a drag.
    @ViewBuilder
    private var border: some View {
        let shape = VTheme.Radius.shape(VTheme.Radius.xl)
        if isDropTarget || isFocused {
            shape.stroke(isDropTarget
                            ? VTheme.Color.Semantic.accent
                            : VTheme.Color.Semantic.focusRing,
                         style: StrokeStyle(lineWidth: VTheme.Border.selected, dash: [4, 4]))
                .overlay(alignment: .center) { dropGlyph }
        } else {
            shape.stroke(isHovering
                            ? VTheme.Color.Semantic.accent
                            : VTheme.Color.Stroke.default,
                         style: StrokeStyle(lineWidth: VTheme.Border.thin, dash: [4, 4]))
        }
    }

    /// Under `differentiateWithoutColor` a drop target also carries a glyph, so the state is not
    /// carried by hue alone (DESIGN.md §10.5).
    @ViewBuilder
    private var dropGlyph: some View {
        if isDropTarget, differentiateWithoutColor {
            Image(systemName: VTheme.Symbol.dropTarget.name)
                .font(VTheme.Icon.font(VTheme.Icon.lg, weight: VTheme.Icon.Weight.lg))
                .foregroundStyle(VTheme.Color.Semantic.accent)
        }
    }
}

#endif  // os(macOS)
