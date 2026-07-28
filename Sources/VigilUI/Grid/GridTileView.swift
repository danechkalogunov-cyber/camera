//
//  GridTileView.swift
//  VigilUI
//
//  One tile of the stage, and the "Add camera" placeholder that stands in for an empty one. The tile
//  owns the rules that protect the picture: true-black well, scrim-only chrome, no material, no
//  shadow, and no fade of the video layer itself.
//  macOS-only. Implements docs/DESIGN.md §9.13 (tile anatomy), §2.3 (scrim ladder), §3.6 (true
//  black), §6.3 (no shadows on video) and docs/UX.md §5.3, §5.4.
//

#if os(macOS)

import SwiftUI

import VigilProtocols

// MARK: - VGridTileView

/// One camera's tile.
///
/// ## What this view does not do
///
/// It does **no per-frame work**. The picture arrives on the `AVSampleBufferDisplayLayer` inside the
/// `VideoTile` that the app injects through ``video``, and nothing in this file is invoked when a
/// frame is presented. That is the whole reason the video child is a `@ViewBuilder` rather than
/// something this module constructs: sixteen tiles are sixteen decoders, and if any of them had to
/// pass through a SwiftUI update to reach the screen the stage would cost sixteen main-actor wakeups
/// per frame instead of none. `LiveVideoView` already disables animation and inherited transactions
/// on the picture subtree; this view only ever changes chrome.
///
/// ## The borders, and why they are overlays rather than a `.border`
///
/// Selection is a 2 pt `accent` stroke drawn **inside** the tile's bounds, inset by 1 pt so it is not
/// clipped by the neighbouring tile, plus a 1 pt outer glow (DESIGN.md §9.13). Keyboard focus is the
/// lighter `focusRing` tint so the two are distinguishable, and under
/// `accessibilityDifferentiateWithoutColor` focus becomes dashed — different geometry, not just a
/// different tint (§10.5). None of them is a shadow: ⛔ a shadow is never cast onto a video well
/// (§6.3).
@MainActor
package struct VGridTileView<Video: View>: View {

    // MARK: - Stored Properties

    /// Name, address and identity colour.
    package let camera: LiveCameraIdentity

    /// What the tile is showing.
    package let state: LiveConnectionState

    /// When the current connect attempt began, so the elapsed counter measures the connection.
    package let attemptStartedAt: Date?

    /// Whether this tile is the sidebar's and inspector's current camera.
    package let isSelected: Bool

    /// Whether this tile has keyboard focus. Focus is always visible on the stage — there is no
    /// "no focus" state (UX.md §5.7).
    package let isFocused: Bool

    /// Whether Vigil is recording this camera, which breathes a 3 pt `live` border.
    package let isRecording: Bool

    /// The elapsed recording time, shown bottom-leading while recording.
    package let recordingElapsed: Duration?

    /// The negotiated stream facts for the top-trailing readout, or `nil` to omit it.
    package let stats: VTileStats?

    /// Retries now, cancelling any backoff wait.
    package let onRetry: () -> Void

    /// Performs a remedy chosen from an overlay or banner.
    package let onRemedy: (ConnectRemedy) -> Void

    /// Promotes this tile to fill the stage, or returns it. Bound to a double-click.
    package let onToggleFocus: () -> Void

    /// Clears the cell. The camera keeps running if it is on the stage elsewhere.
    package let onClose: () -> Void

    private let video: () -> Video

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.vPulsePhase) private var pulsePhase
    @Environment(\.vMotionEnabled) private var motionEnabled

    @State private var isHovering = false

    // MARK: - Initialisation

    /// Creates a tile.
    ///
    /// - Parameter video: the renderer's view. Mounted in **every** state so the last frame is still
    ///   there to dim when the connection drops — the no-black-flash rule (DESIGN.md §3.6 clause 6).
    package init(camera: LiveCameraIdentity,
                 state: LiveConnectionState,
                 attemptStartedAt: Date? = nil,
                 isSelected: Bool = false,
                 isFocused: Bool = false,
                 isRecording: Bool = false,
                 recordingElapsed: Duration? = nil,
                 stats: VTileStats? = nil,
                 onRetry: @escaping () -> Void = {},
                 onRemedy: @escaping (ConnectRemedy) -> Void = { _ in },
                 onToggleFocus: @escaping () -> Void = {},
                 onClose: @escaping () -> Void = {},
                 @ViewBuilder video: @escaping () -> Video) {
        self.camera = camera
        self.state = state
        self.attemptStartedAt = attemptStartedAt
        self.isSelected = isSelected
        self.isFocused = isFocused
        self.isRecording = isRecording
        self.recordingElapsed = recordingElapsed
        self.stats = stats
        self.onRetry = onRetry
        self.onRemedy = onRemedy
        self.onToggleFocus = onToggleFocus
        self.onClose = onClose
        self.video = video
    }

    // MARK: - View

    package var body: some View {
        LiveVideoView(camera: camera,
                      state: state,
                      attemptStartedAt: attemptStartedAt,
                      onRetry: onRetry,
                      onRemedy: onRemedy,
                      video: video)
            // The picture is inset by the widest stroke this tile can draw, so the frame contains
            // it instead of sitting on top of it. Without this the video runs to the outer edge and
            // the recording border is painted over the last three points of the image — which reads
            // exactly as "the picture is slightly too big for its frame", because it is.
            .padding(VTheme.Border.recording)
            // The well is clipped on the layer, not by a SwiftUI `clipShape` over the video — a
            // clip on this subtree would force the tile offscreen and break the display layer's
            // direct composition (see the header of VigilRender/Interop/VideoTile.swift).
            .overlay(alignment: .topTrailing) { statsReadout }
            .overlay(alignment: .bottomLeading) { elapsedReadout }
            .overlay(alignment: .bottomTrailing) { actionBar }
            .background { sizeReader }
            .overlay { cornerCover }
            .overlay { borders }
            .onHover { hovering in
                withAnimation(VTheme.Motion.resolved(VTheme.Motion.micro, reduced: !motionEnabled)) {
                    isHovering = hovering
                }
            }
            .onTapGesture(count: 2, perform: onToggleFocus)
            .contentShape(VTheme.Radius.shape(VTheme.Radius.xl))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: camera.name))
            .accessibilityValue(accessibilityState)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Chrome

    /// Whether chrome over the picture is drawn at all.
    ///
    /// ⛔ Only decoration answers to this. The recording border stays: it reports that this camera
    /// is being written to disk, which is a fact about the system rather than a label on the
    /// picture, and a user who hid the chrome has not asked to stop being told that.
    @Environment(\.vShowsVideoOverlay) private var showsOverlay

    /// What the hover buttons do. Supplied by the app through the environment.
    @Environment(\.vTileActions) private var tileActions

    /// The tile's measured size. See ``sizeReader``.
    @State private var size: CGSize = .zero

    /// The top-trailing telemetry, on a `scrim.base` pill and never on a material.
    ///
    /// Hidden until hover unless the tile is focused, because P2 asks that chrome dissolve when it is
    /// not needed and the stats are the least urgent thing on a tile.
    @ViewBuilder
    private var statsReadout: some View {
        if showsOverlay, let stats, isHovering || isFocused {
            VTileStatsView(stats: stats, isRecording: isRecording)
                .padding(VTheme.Metrics.tileChromeInset)
                .transition(.opacity)
        }
    }

    /// The bottom-leading readout. At most one at a time, recording first (UX.md §5.3).
    @ViewBuilder
    private var elapsedReadout: some View {
        if showsOverlay, isRecording, let recordingElapsed {
            Text(verbatim: VTileStats.timecode(recordingElapsed))
                .vType(VTheme.Typography.monoLarge.numeric)
                .foregroundStyle(VTheme.Color.Text.onVideo)
                .vReserved(VTheme.Typography.Reserved.timecode, alignment: .leading)
                .padding(.horizontal, VTheme.Space.xs)
                .padding(.vertical, VTheme.Space.xxs)
                .background(VTheme.Color.Scrim.base,
                            in: VTheme.Radius.shape(VTheme.Radius.sm))
                .padding(VTheme.Metrics.tileChromeInset)
        }
    }

    /// The seven buttons of §5.3, bottom-trailing.
    ///
    /// On hover or focus, like the stats readout: chrome dissolves when it is not needed, and a
    /// wall of tiles each wearing seven buttons is not a wall of pictures.
    @ViewBuilder
    private var actionBar: some View {
        if showsOverlay, hasRoomForActions, isHovering || isFocused {
            VTileActionBar(isRecording: isRecording, actions: tileActions)
                .padding(VTheme.Metrics.tileChromeInset)
                .transition(.opacity)
        }
    }

    /// Whether the tile is wide enough to carry the button row.
    ///
    /// The bar and the camera-name chip share the bottom edge from opposite ends, so on a narrow
    /// tile they meet in the middle and overlap. The buttons are what goes: the name answers "which
    /// camera is this", which is the question a wall of small tiles exists to answer, and the
    /// actions are all reachable from the tile's menu and the palette.
    private var hasRoomForActions: Bool {
        size.width >= VGridTileMetrics.actionBarMinimumWidth
            && size.height >= VGridTileMetrics.actionBarMinimumHeight
    }

    /// The tile's measured size, for the responsive decisions above.
    ///
    /// Measured rather than derived from the layout: a 2 × 2 grid in a narrow window and a 4 × 4 in
    /// a wide one can produce the same tile size, so the grid's shape is not the question — the
    /// number of points actually available is.
    private var sizeReader: some View {
        GeometryReader { proxy in
            SwiftUI.Color.clear
                .onAppear { size = proxy.size }
                .onChange(of: proxy.size) { _, updated in size = updated }
        }
    }

    // MARK: - Corners

    /// Paints the canvas back over the four corners the picture would otherwise square off.
    ///
    /// ⛔ **Not** a `clipShape`, and not `masksToBounds` on the layer either. The file's own rule
    /// stands — a SwiftUI clip over this subtree breaks the display layer's direct composition —
    /// and the layer route was tried and does not work: `AVSampleBufferDisplayLayer` composites its
    /// video through a path `masksToBounds` does not reach, so setting `cornerRadius` on it rounds
    /// the layer's background and leaves the picture square. The corners stuck out of the 20 pt
    /// border exactly as before.
    ///
    /// So the corners are covered rather than cut. This is sound because the tile sits on
    /// `Layer.canvas` — the stage's own background — so the cover is the colour that would be
    /// showing anyway. It costs one masked shape and no compositor blend over the picture.
    ///
    /// ⚠️ It assumes the stage's default canvas. `VGridStageView` lets a caller substitute one
    /// (the video wall passes black), and a tile on a substituted canvas would show four corners of
    /// `Layer.canvas` against it. Nothing does that today; when the wall lands, the colour needs to
    /// reach here rather than being read from the token.
    private var cornerCover: some View {
        let shape = VTheme.Radius.shape(VTheme.Radius.xl)
        return Rectangle()
            .fill(VTheme.Color.Layer.canvas)
            .mask {
                // Everything outside the rounded rect: the full rectangle with the rounded shape
                // punched out of it.
                Rectangle()
                    .overlay { shape.blendMode(.destinationOut) }
                    .compositingGroup()
            }
            .allowsHitTesting(false)
    }

    // MARK: - Borders

    /// Recording, then focus, then selection — drawn as strokes inside the tile so a neighbouring
    /// tile can never clip them, and never as a shadow.
    @ViewBuilder
    private var borders: some View {
        let shape = VTheme.Radius.shape(VTheme.Radius.xl)
        ZStack {
            if isRecording {
                shape.strokeBorder(VTheme.Color.Semantic.live.opacity(recordingBorderAlpha),
                                   lineWidth: VTheme.Border.recording)
                    .animation(VTheme.Motion.resolvedLoop(VTheme.Motion.breathe, reduced: !motionEnabled),
                               value: pulsePhase)
            }
            if isSelected {
                shape.strokeBorder(VTheme.Color.Semantic.accent, lineWidth: VTheme.Border.selected)
                    .padding(VTheme.Border.thin)
            }
            if isFocused {
                focusStroke(shape)
            }
        }
        .allowsHitTesting(false)
    }

    /// The keyboard focus ring: `focusRing` rather than `accent` so it is distinguishable from
    /// selection, and **dashed** under `differentiateWithoutColor` so the distinction survives
    /// without colour (DESIGN.md §10.5).
    @ViewBuilder
    private func focusStroke(_ shape: RoundedRectangle) -> some View {
        if differentiateWithoutColor {
            shape.stroke(VTheme.Color.Semantic.focusRing,
                         style: StrokeStyle(lineWidth: VTheme.Border.focus, dash: [6, 3]))
                .padding(VTheme.Border.thin)
        } else {
            shape.strokeBorder(VTheme.Color.Semantic.focusRing, lineWidth: VTheme.Border.focus)
                .padding(VTheme.Border.thin)
        }
    }

    /// The recording border breathes α 0.55 ↔ 1.0 off the window-wide pulse clock (§7.4 #11).
    ///
    /// Read from `\.vPulsePhase` rather than from a `PhaseAnimator` of its own: sixteen independent
    /// animators would blow the four-driver budget and, worse, would not be in unison.
    private var recordingBorderAlpha: Double {
        guard motionEnabled else { return 1.0 }
        return pulsePhase ? 1.0 : 0.55
    }

    /// The one-sentence state a screen reader hears after the camera's name.
    private var accessibilityState: Text {
        switch state {
        case .connecting:
            return Text("Connecting", bundle: .vigilUI)
        case .live:
            return isRecording
                ? Text("Live and recording", bundle: .vigilUI)
                : Text("Live", bundle: .vigilUI)
        case .degraded:
            return Text("Live but degraded", bundle: .vigilUI)
        case .offline:
            return Text("No signal", bundle: .vigilUI)
        }
    }
}

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
