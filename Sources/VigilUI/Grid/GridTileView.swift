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

        /// Whether the camera accepts ISAPI 3D positioning drags.
        package let supportsPosition3D: Bool

        /// Delivers the drag in tile coordinates. A sub-threshold drag is collapsed to a point.
        package let onPosition3D: (CGRect, CGSize) -> Void

        private let video: () -> Video

        @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
        @Environment(\.vPulsePhase) private var pulsePhase
        @Environment(\.vMotionEnabled) private var motionEnabled

        @State private var isHovering = false
        @State private var position3DStart: CGPoint?
        @State private var position3DCurrent: CGPoint?

        // MARK: - Initialisation

        /// Creates a tile.
        ///
        /// - Parameter video: the renderer's view. Mounted in **every** state so the last frame is still
        ///   there to dim when the connection drops — the no-black-flash rule (DESIGN.md §3.6 clause 6).
        package init(
            camera: LiveCameraIdentity,
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
            supportsPosition3D: Bool = false,
            onPosition3D: @escaping (CGRect, CGSize) -> Void = { _, _ in },
            @ViewBuilder video: @escaping () -> Video
        ) {
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
            self.supportsPosition3D = supportsPosition3D
            self.onPosition3D = onPosition3D
            self.video = video
        }

        // MARK: - View

        package var body: some View {
            LiveVideoView(
                camera: camera,
                state: state,
                attemptStartedAt: attemptStartedAt,
                onRetry: onRetry,
                onRemedy: onRemedy,
                video: video
            )
            // The picture is inset by the widest stroke this tile can draw, so the frame contains
            // it instead of sitting on top of it. Without this the video runs to the outer edge and
            // the recording border is painted over the last three points of the image — which reads
            // exactly as "the picture is slightly too big for its frame", because it is.
            .padding(VTheme.Border.recording)
            // ⛔ The double-tap belongs to the **picture**, not to the assembled tile, and the
            // difference is felt rather than seen. A `count: 2` gesture on an ancestor forces
            // SwiftUI to hold every single click for the double-click interval before it can decide
            // the gesture missed — so with this applied after the overlays, every button in the
            // hover row answered about a third of a second late. Attached here the buttons are
            // siblings above the gesture rather than inside it, and they fire immediately.
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onToggleFocus)
            // The well is clipped on the layer, not by a SwiftUI `clipShape` over the video — a
            // clip on this subtree would force the tile offscreen and break the display layer's
            // direct composition (see the header of VigilRender/Interop/VideoTile.swift).
            .overlay(alignment: .topTrailing) { statsReadout }
            .overlay(alignment: .bottomLeading) { elapsedReadout }
            .overlay(alignment: .bottomTrailing) { actionBar }
            .background { sizeReader }
            .overlay { cornerCover }
            .overlay { borders }
            .overlay { position3DSelection }
            .simultaneousGesture(position3DGesture, including: supportsPosition3D ? .all : .none)
            .onHover { hovering in
                withAnimation(VTheme.Motion.resolved(VTheme.Motion.micro, reduced: !motionEnabled)) {
                    isHovering = hovering
                }
            }
            .contentShape(VTheme.Radius.shape(VTheme.Radius.xl))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: camera.name))
            .accessibilityValue(accessibilityState)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }

        @ViewBuilder
        private var position3DSelection: some View {
            if supportsPosition3D, let start = position3DStart, let current = position3DCurrent {
                let rect = CGRect(
                    x: min(start.x, current.x), y: min(start.y, current.y),
                    width: abs(current.x - start.x), height: abs(current.y - start.y))
                Rectangle()
                    .fill(VTheme.Color.Semantic.accent.opacity(0.12))
                    .overlay {
                        Rectangle().stroke(VTheme.Color.Semantic.accent, lineWidth: 2)
                    }
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
        }

        private var position3DGesture: some Gesture {
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    guard supportsPosition3D else { return }
                    position3DStart = position3DStart ?? value.startLocation
                    position3DCurrent = value.location
                }
                .onEnded { value in
                    guard supportsPosition3D else { return }
                    let start = position3DStart ?? value.startLocation
                    let dx = value.location.x - start.x
                    let dy = value.location.y - start.y
                    let isBox = hypot(dx, dy) >= 8
                    let rect =
                        isBox
                        ? CGRect(x: start.x, y: start.y, width: dx, height: dy)
                        : CGRect(x: value.location.x, y: value.location.y, width: 0, height: 0)
                    onPosition3D(rect, size)
                    position3DStart = nil
                    position3DCurrent = nil
                }
        }

        // MARK: - Chrome

        /// Whether chrome over the picture is drawn at all.
        ///
        /// ⛔ Only decoration answers to this. The recording border stays: it reports that this camera
        /// is being written to disk, which is a fact about the system rather than a label on the
        /// picture, and a user who hid the chrome has not asked to stop being told that.
        @Environment(\.vShowsVideoOverlay) private var showsOverlay

        /// Which pieces of that chrome are wanted — ⌥N, ⌥S, ⌥T, ⌥B (UX.md §11.1).
        ///
        /// Both gates apply, and they answer different questions: `showsOverlay` is the camera's own
        /// "draw chrome over this picture at all", this is the user's "which parts".
        @Environment(\.vTileOverlays) private var overlays

        /// What the hover buttons do. Supplied by the app through the environment.
        @Environment(\.vTileActions) private var tileActions

        /// ⌃⌘H: the focused tile's chrome stays up without the pointer (UX.md §6.2).
        @Environment(\.vPinsTileControls) private var pinsControls

        /// Whether this tile shows its chrome right now.
        ///
        /// Pointer, stage focus, or the ⌃⌘H pin — and the pin reaches only the **selected** tile,
        /// so §6.2's rule that chrome is never shown on a tile the pointer is not over is widened
        /// by exactly one tile, the one the rest of the window is already talking about.
        ///
        /// That third clause is the whole of the accessibility gap §6.2 names. Stage focus exists
        /// only once ⌥-arrow has been pressed, so before that a keyboard-only user has no route to
        /// snapshot, record, fit/fill or close on any tile: those live in the hover row and nothing
        /// else opens it. Named once, because three copies of `isHovering || isFocused` is how the
        /// stats readout and the action bar come to disagree about what "showing chrome" means.
        private var showsChrome: Bool {
            isHovering || isFocused || (pinsControls && isSelected)
        }

        /// The tile's measured size. See ``sizeReader``.
        @State private var size: CGSize = .zero

        /// The top-trailing telemetry, on a `scrim.base` pill and never on a material.
        ///
        /// Hidden until hover unless the tile is focused, because P2 asks that chrome dissolve when it is
        /// not needed and the stats are the least urgent thing on a tile.
        @ViewBuilder
        private var statsReadout: some View {
            if showsOverlay, overlays.contains(.stats), let stats, showsChrome {
                VTileStatsView(stats: stats, isRecording: isRecording)
                    .padding(VTheme.Metrics.tileChromeInset)
                    .transition(.opacity)
            }
        }

        /// The bottom-leading readout. At most one at a time, recording first (UX.md §5.3).
        @ViewBuilder
        private var elapsedReadout: some View {
            if showsOverlay, overlays.contains(.timestamp), isRecording, let recordingElapsed {
                Text(verbatim: VTileStats.timecode(recordingElapsed))
                    .vType(VTheme.Typography.monoLarge.numeric)
                    .foregroundStyle(VTheme.Color.Text.onVideo)
                    .vReserved(VTheme.Typography.Reserved.timecode, alignment: .leading)
                    .padding(.horizontal, VTheme.Space.xs)
                    .padding(.vertical, VTheme.Space.xxs)
                    .background(
                        VTheme.Color.Scrim.base,
                        in: VTheme.Radius.shape(VTheme.Radius.sm)
                    )
                    .padding(VTheme.Metrics.tileChromeInset)
            }
        }

        /// The seven buttons of §5.3, bottom-trailing.
        ///
        /// On hover or focus, like the stats readout: chrome dissolves when it is not needed, and a
        /// wall of tiles each wearing seven buttons is not a wall of pictures.
        @ViewBuilder
        private var actionBar: some View {
            if showsOverlay, hasRoomForActions, showsChrome {
                VTileActionBar(isRecording: isRecording, actions: barActions)
                    .padding(VTheme.Metrics.tileChromeInset)
                    .transition(.opacity)
            }
        }

        /// The environment's actions, with Close rebound to **this** tile.
        ///
        /// ⛔ Without this, ``onClose`` was a stored property nobody read. `VTileActions` is one bag
        /// published for the whole stage, so its `perform` cannot know which cell was pressed — and the
        /// cell index is the entire content of "close this one". `VGridStageView` already builds
        /// `onClose` per slot; overriding the single case here is what connects the two. Every other
        /// action stays stage-wide, because every other action is about the camera rather than the cell.
        ///
        /// The button is still drawn dimmed unless the app puts `.close` in `enabled`: rebinding what a
        /// button does is not the same as claiming it can be pressed.
        private var barActions: VTileActions {
            var actions = tileActions
            let stageWide = actions.perform
            let close = onClose
            actions.perform = { action in
                guard action == .close else {
                    stageWide(action)
                    return
                }
                close()
            }
            return actions
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
                    shape.strokeBorder(
                        VTheme.Color.Semantic.live.opacity(recordingBorderAlpha),
                        lineWidth: VTheme.Border.recording
                    )
                    .animation(
                        VTheme.Motion.resolvedLoop(VTheme.Motion.breathe, reduced: !motionEnabled),
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
                shape.stroke(
                    VTheme.Color.Semantic.focusRing,
                    style: StrokeStyle(lineWidth: VTheme.Border.focus, dash: [6, 3])
                )
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

#endif  // os(macOS)
