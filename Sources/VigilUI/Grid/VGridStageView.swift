//
//  VGridStageView.swift
//  VigilUI
//
//  The stage: the centre of the main window, where the layout's cells become tiles. It positions
//  what `GridGeometry` measured, keys every tile by its camera so a layout change cannot tear down
//  a decode session, and originates no animation that would touch a video layer's geometry.
//  macOS-only. Implements docs/UX.md §5.1 (explicit frames, overflow), §5.4 (empty cells), §5.6
//  (promotion) and §5.7 (keyboard); docs/DESIGN.md §3.6 (true black), §7.7, §7.8 and §7.9.
//
#if os(macOS)
    import Foundation
    import SwiftUI
    import VigilProtocols
    import VigilRender

    // MARK: - VGridStageView

    /// The grid of tiles.
    ///
    /// ## How the tiles are placed
    ///
    /// Explicit frames from ``VGridGeometry``, applied with `.frame` and `.position` inside one
    /// `ZStack` — never a `LazyVGrid`. UX.md §5.1 requires it and gives the reason: only explicit
    /// frames let a tile keep its identity, and therefore its decode session, while its rectangle
    /// changes. A lazy grid also mounts and unmounts its children, and an unmounted tile is a torn-down
    /// `AVSampleBufferDisplayLayer`.
    ///
    /// ## ⛔ How this view satisfies the video-frame rule (DESIGN.md §7.9)
    ///
    /// 1. **It originates no animation on a tile's geometry.** The rect a tile is given is applied
    ///    under `.animation(nil, value:)`, so neither a window resize nor an ambient `withAnimation`
    ///    from an ancestor can interpolate it. Interpolating a video well's frame without the still
    ///    proxy is exactly what rule 2 forbids: the layer's bounds change every display frame, which
    ///    forces an IOSurface re-allocation per frame and visibly stutters.
    /// 2. **The transition that *is* specified is `matchedGeometryEffect`, and it is opt-in.** §7.7
    ///    requires the namespace to be declared once at the window root and passed down — a
    ///    `@Namespace` created inside a subview is recreated on redraw and silently disables the
    ///    effect — so this view takes one and applies the effect only when it is given. The still proxy
    ///    that must accompany it (`VTileTransitionProxy`, §7.9 rule 2) belongs to `VigilRender`; until
    ///    it exists, a caller that supplies no namespace gets a single, unanimated re-layout, which is
    ///    the one geometry mutation per transition the rule budgets for.
    /// 3. **Only compositor-safe properties animate here.** A cell entering the stage fades and scales
    ///    in (§7.8), which rule 1 permits. A cell *leaving* does neither: the removal half of the
    ///    transition is `.identity`, because fading a tile out would fade a live picture, and §3.6
    ///    clause 6 forbids applying opacity to a live video layer outright.
    /// 4. **No clip, mask or corner radius is applied over the video subtree.** The tile owns its own
    ///    well and its own borders; this view only positions it.
    ///
    /// ## What it does not do
    ///
    /// No model fetching, no singletons, no `Task`. Focus, selection, the promoted camera and the drop
    /// target all arrive as values and leave as callbacks, so the object that owns the
    /// `StreamController`s stays in the app target and this view stays previewable.
    @MainActor
    package struct VGridStageView<Video: View>: View {

        // MARK: - Stored Properties

        /// Which camera is in which cell, and how many did not fit.
        package let plan: VStagePlan

        /// Whether the stage is showing the grid or one promoted camera (UX.md §5.6).
        package let mode: VStageMode

        /// The cell that has keyboard focus, or `nil` before the stage has been used. Focus is always
        /// visible once it exists — there is no "no focus" state on the stage (UX.md §5.7).
        package let focusedIndex: Int?

        /// The sidebar's and inspector's current camera, which draws the accent selection border.
        package let selection: CameraID?

        /// The cell a drag is hovering over, which lights the drop target on an empty cell.
        package let dropTargetIndex: Int?

        /// The stage inset. 0 in cinema mode and on the video wall (DESIGN.md §5.1, UX.md §5.8).
        package let inset: CGFloat

        /// The canvas seam between tiles. 0 on the video wall.
        package let gutter: CGFloat

        /// The colour of the seam and of the area behind the tiles, or `nil` for `layer.canvas`.
        ///
        /// ⛔ It is `layer.canvas` `#0B0C0F` and **not** black, so tile edges read as separate frames
        /// without a stroke, and it becomes `#000000` in cinema mode so a 16:9 stream on a 16:10
        /// display shows uninterrupted black (DESIGN.md §3.6 clauses 4 and 5).
        package let canvas: SwiftUI.Color?

        /// The `stage` namespace of DESIGN.md §7.7, or `nil` to place tiles without the effect.
        package let namespace: Namespace.ID?

        /// Moves tile focus to a cell.
        package let onFocusCell: (Int) -> Void

        /// ⌥-arrow reached the edge: play the 3 pt nudge (UX.md §5.7). The key event is **not**
        /// consumed, so focus can still travel on to the sidebar or the inspector.
        package let onBump: (VGridDirection) -> Void

        /// Binds this camera to the sidebar and the inspector.
        package let onSelectCamera: (CameraID) -> Void

        /// Promotes a camera to fill the stage, or returns it. Bound to a double-click on the tile.
        package let onToggleFullscreen: (CameraID) -> Void

        /// Opens the camera picker for an empty cell (UX.md §5.4).
        package let onAddCamera: (Int) -> Void

        /// Clears a cell. The camera keeps running if it is on the stage elsewhere (UX.md §5.3).
        package let onCloseCell: (Int) -> Void

        /// Retries a camera now, cancelling any backoff wait.
        package let onRetry: (CameraID) -> Void

        /// Performs a remedy chosen from one camera's overlay or banner.
        package let onRemedy: (CameraID, ConnectRemedy) -> Void

        /// Opens the popover listing the cameras that did not fit.
        package let onShowOverflow: () -> Void

        /// Starts streaming a camera that is on the stage but idle (``VStageCamera/isStreaming``).
        ///
        /// Separate from ``onSelectCamera`` because selecting binds the panels and this one costs a
        /// session: in a build that streams one camera at a time it stops whatever is playing, and a
        /// gesture that expensive must not be something a click on a row can trigger by accident.
        package let onConnectCamera: (CameraID) -> Void

        package let supportsPosition3D: (CameraID) -> Bool
        package let onPosition3D: (CameraID, CGRect, CGSize) -> Void

        private let cameraIndex: [CameraID: VStageCamera]
        private let video: (CameraID) -> Video

        @Environment(\.vMotionEnabled) private var motionEnabled

        @FocusState private var hasKeyboardFocus: Bool

        // MARK: - Initialisation

        /// Creates the stage.
        ///
        /// - Parameters:
        ///   - assignment: which camera is in which cell. Resolved into a ``VStagePlan`` once here
        ///     rather than per body evaluation.
        ///   - mode: grid, or one promoted camera.
        ///   - cameras: the tile payloads, in any order. A cell naming a camera that is not in this
        ///     collection renders as an empty cell rather than as a black rectangle, because a cell
        ///     with nothing behind it is empty however it came to be that way. Duplicates keep the
        ///     first entry.
        ///   - selection: the camera the sidebar and inspector are bound to.
        ///   - focusedIndex: the cell with keyboard focus.
        ///   - dropTargetIndex: the cell a drag is over.
        ///   - namespace: the window's `stage` namespace (DESIGN.md §7.7). Omit it and tiles are placed
        ///     without `matchedGeometryEffect`.
        ///   - inset: the stage inset; defaults to the design's 8 pt.
        ///   - gutter: the canvas seam; defaults to the design's 2 pt.
        ///   - canvas: the colour behind and between the tiles; defaults to `layer.canvas`.
        ///   - video: the renderer's view for one camera. Called once per **mounted** tile, and the
        ///     tile is keyed by camera, so a layout change re-uses the view rather than rebuilding it.
        package init(
            assignment: VStageAssignment,
            mode: VStageMode = .grid,
            cameras: [VStageCamera],
            selection: CameraID? = nil,
            focusedIndex: Int? = nil,
            dropTargetIndex: Int? = nil,
            namespace: Namespace.ID? = nil,
            inset: CGFloat = VGridGeometry.defaultStageInset,
            gutter: CGFloat = VGridGeometry.defaultGutter,
            canvas: SwiftUI.Color? = nil,
            onFocusCell: @escaping (Int) -> Void = { _ in },
            onBump: @escaping (VGridDirection) -> Void = { _ in },
            onSelectCamera: @escaping (CameraID) -> Void = { _ in },
            onToggleFullscreen: @escaping (CameraID) -> Void = { _ in },
            onAddCamera: @escaping (Int) -> Void = { _ in },
            onCloseCell: @escaping (Int) -> Void = { _ in },
            onRetry: @escaping (CameraID) -> Void = { _ in },
            onRemedy: @escaping (CameraID, ConnectRemedy) -> Void = { _, _ in },
            onShowOverflow: @escaping () -> Void = {},
            onConnectCamera: @escaping (CameraID) -> Void = { _ in },
            supportsPosition3D: @escaping (CameraID) -> Bool = { _ in false },
            onPosition3D: @escaping (CameraID, CGRect, CGSize) -> Void = { _, _, _ in },
            @ViewBuilder video: @escaping (CameraID) -> Video
        ) {
            self.plan = VStagePlan(assignment: assignment)
            self.mode = mode
            self.focusedIndex = focusedIndex
            self.selection = selection
            self.dropTargetIndex = dropTargetIndex
            self.inset = inset
            self.gutter = gutter
            self.canvas = canvas
            self.namespace = namespace
            self.onFocusCell = onFocusCell
            self.onBump = onBump
            self.onSelectCamera = onSelectCamera
            self.onToggleFullscreen = onToggleFullscreen
            self.onAddCamera = onAddCamera
            self.onCloseCell = onCloseCell
            self.onRetry = onRetry
            self.onRemedy = onRemedy
            self.onShowOverflow = onShowOverflow
            self.onConnectCamera = onConnectCamera
            self.supportsPosition3D = supportsPosition3D
            self.onPosition3D = onPosition3D
            // Built once, not per lookup: sixteen linear searches through sixteen cameras inside a
            // body evaluation is 256 comparisons for a job a dictionary does in sixteen.
            //     init<S>(_ keysAndValues: S, uniquingKeysWith combine: (Value, Value) throws -> Value)
            self.cameraIndex = Dictionary(
                cameras.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in
                    first
                })
            self.video = video
        }

        // MARK: - View

        package var body: some View {
            GeometryReader { proxy in
                tiles(in: VGridGeometry(layout: plan.layout, size: proxy.size, gutter: gutter))
            }
            .padding(inset)
            .background(canvas ?? VTheme.Color.Layer.canvas)
            .overlay(alignment: .bottomTrailing) { overflowChip }
            // The stage is one focusable element that owns `focusedIndex`; the tiles inside it draw
            // the ring themselves, so the system's own focus effect would double-draw (§9.28).
            .focusable()
            .focused($hasKeyboardFocus)
            .focusEffectDisabled()
            // func onKeyPress(keys: Set<KeyEquivalent>, phases: KeyPress.Phases = .down,
            //                 action: @escaping (KeyPress) -> KeyPress.Result) -> some View
            .onKeyPress(
                keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .space, .delete],
                phases: .down
            ) { press in
                respond(to: press)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Camera grid", bundle: .vigilUI))
        }

        // MARK: - Tiles

        /// The positioned cells, plus the backdrop that hides them when one camera is promoted.
        private func tiles(in geometry: VGridGeometry) -> some View {
            ZStack(alignment: .topLeading) {
                ForEach(plan.slots) { slot in
                    cell(slot, in: geometry)
                }
                promotedBackdrop
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }

        /// One cell: a tile, or the "Add camera" placeholder.
        ///
        /// The two branches apply their geometry separately on purpose — the tile's rect is pinned
        /// unanimated (§7.9), while an empty cell holds no video and may move however the caller's
        /// transaction says it should.
        @ViewBuilder
        private func cell(_ slot: VStageSlot, in geometry: VGridGeometry) -> some View {
            let rect = plan.frame(for: slot, in: geometry, promoted: promotedCamera)
            if let camera = slot.camera, let model = cameraIndex[camera], !model.isStreaming {
                // A camera the app holds but is not streaming. Not a tile — there is no picture to
                // preserve behind it — and not an empty cell, which would offer to *add* a camera that
                // is already here. See `VGridIdleCell` for why this is not a `LiveConnectionState` case.
                VGridIdleCell(
                    camera: model.camera,
                    isSelected: selection == model.id,
                    isFocused: focusedIndex == slot.index,
                    onConnect: { onConnectCamera(model.id) }
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .transition(entrance(slot))
                .simultaneousGesture(
                    TapGesture().onEnded {
                        onFocusCell(slot.index)
                        onSelectCamera(model.id)
                    })
            } else if let camera = slot.camera, let model = cameraIndex[camera] {
                tile(model, slot: slot)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    // ⛔ §7.9 rule 2, and rule 3's transaction stripping: a tile's rectangle is applied
                    // in one step, and an ambient `withAnimation` from an ancestor cannot interpolate
                    // it. See the type's discussion.
                    //     func animation<V: Equatable>(_ animation: Animation?, value: V) -> some View
                    .animation(nil, value: rect)
                    .modifier(
                        VStageGeometryMatch(
                            namespace: namespace,
                            camera: camera,
                            isSource: promotedCamera != camera)
                    )
                    .zIndex(promotedCamera == camera ? VGridStageMetrics.promotedZIndex : 0)
                    .transition(entrance(slot))
            } else {
                VGridEmptyCell(
                    position: slot.index + 1,
                    total: plan.tileCount,
                    isDropTarget: dropTargetIndex == slot.index,
                    isFocused: focusedIndex == slot.index,
                    onChoose: { onAddCamera(slot.index) }
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .transition(entrance(slot))
            }
        }

        /// One camera's tile, wired to the callbacks.
        private func tile(_ model: VStageCamera, slot: VStageSlot) -> some View {
            VGridTileView(
                camera: model.camera,
                state: model.state,
                attemptStartedAt: model.attemptStartedAt,
                isSelected: selection == model.id,
                isFocused: focusedIndex == slot.index,
                isRecording: model.isRecording,
                recordingElapsed: model.recordingElapsed,
                stats: model.stats,
                onRetry: { onRetry(model.id) },
                onRemedy: { onRemedy(model.id, $0) },
                onToggleFocus: { onToggleFullscreen(model.id) },
                onClose: { onCloseCell(slot.index) },
                supportsPosition3D: supportsPosition3D(model.id),
                onPosition3D: { rect, size in onPosition3D(model.id, rect, size) },
                video: { video(model.id) }
            )
            // Simultaneous rather than `onTapGesture`, so it cannot compete with the tile's own
            // double-click: a double-click both selects the camera and promotes it, which is what
            // the user asked for either way.
            .simultaneousGesture(
                TapGesture().onEnded {
                    hasKeyboardFocus = true
                    onFocusCell(slot.index)
                    onSelectCamera(model.id)
                })
        }

        /// True black behind the promoted tile, so the grid it flew out of is not visible around it
        /// (DESIGN.md §3.6 clause 5). The tiles behind it stay mounted and keep decoding — unmounting
        /// them to save a composite would tear down every other camera's session.
        @ViewBuilder
        private var promotedBackdrop: some View {
            if promotedCamera != nil {
                VTheme.Color.Layer.videoWell
                    .zIndex(VGridStageMetrics.backdropZIndex)
                    .accessibilityHidden(true)
            }
        }

        /// The `+3` chip at the stage's bottom-trailing corner (UX.md §5.1).
        ///
        /// The number is a numeral, not a sentence, so it needs no plural rule; the spoken label
        /// carries the meaning instead.
        @ViewBuilder
        private var overflowChip: some View {
            if plan.overflowCount > 0 {
                Button(action: onShowOverflow) {
                    VChip(.onVideo) {
                        Text(verbatim: "+" + plan.overflowCount.formatted(.number))
                            .vType(VTheme.Typography.monoSmall.numeric)
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .padding(VTheme.Metrics.tileChromeInset)
                .accessibilityLabel(Text("Cameras that don't fit this layout", bundle: .vigilUI))
                .accessibilityValue(Text(verbatim: plan.overflowCount.formatted(.number)))
                .accessibilityHint(Text("Show the cameras that don't fit", bundle: .vigilUI))
            }
        }

        // MARK: - Motion

        /// The entrance of DESIGN.md §7.8: `opacity 0 → 1` with `scale 0.96 → 1`, staggered 18 ms in
        /// reading order and capped at twelve items so no more than twelve springs ever run at once.
        ///
        /// ⛔ Asymmetric, and the removal half is `.identity`. A tile that is leaving still holds a live
        /// picture, and §3.6 clause 6 forbids fading a video layer outright — the frame is dropped, not
        /// dissolved. The insertion half is safe because a tile that is arriving has no picture yet:
        /// §7.8 lays every frame out black first and reveals the video per tile as it connects.
        private func entrance(_ slot: VStageSlot) -> AnyTransition {
            let insertion = AnyTransition.opacity
                .combined(with: .scale(scale: VGridStageMetrics.entranceScale))
            return
                AnyTransition
                .asymmetric(insertion: insertion, removal: .identity)
                .animation(entranceAnimation(slot.index))
        }

        /// The stagger, resolved against reduced motion: no delay and a 120 ms cross-fade when motion
        /// is off, because a staggered entrance is decoration and rule 2 of §7.10 replaces it.
        private func entranceAnimation(_ index: Int) -> Animation? {
            let reduced = !motionEnabled
            let delay = VTheme.Motion.stagger(index, reduced: reduced)
            return VTheme.Motion.resolved(VTheme.Motion.standard.delay(delay), reduced: reduced)
        }

        // MARK: - Keyboard

        /// ⌥-arrows move focus, `⏎`/`Space` activates, `⌫` clears.
        ///
        /// ⚠ Arrows **without** `⌥` are deliberately not consumed: they drive PTZ on the focused tile
        /// (UX.md §5.7), which is the whole reason tile navigation is modified. A move that finds
        /// nothing is also not consumed, so `⌥→` at the trailing edge can still hand focus onwards
        /// after the caller has played the bump.
        private func respond(to press: KeyPress) -> KeyPress.Result {
            guard let current = focusedIndex ?? plan.firstIndex else { return .ignored }
            if press.key == .return || press.key == .space {
                activate(current)
                return .handled
            }
            if press.key == .delete {
                guard plan.camera(at: current) != nil else { return .ignored }
                onCloseCell(current)
                return .handled
            }
            guard press.modifiers.contains(.option), let direction = arrow(for: press.key) else {
                return .ignored
            }
            guard focusedIndex != nil else {
                // The first ⌥-arrow on a stage that has never been focused lands on the first cell
                // rather than moving from it, so focus becomes visible before it starts travelling.
                onFocusCell(current)
                return .handled
            }
            guard let next = plan.move(from: current, direction) else {
                onBump(direction)
                return .ignored
            }
            onFocusCell(next)
            return .handled
        }

        /// `⏎` on a filled cell binds the inspector; on an empty one it opens the picker (UX.md §5.7).
        private func activate(_ index: Int) {
            guard let slot = plan.slot(at: index) else { return }
            guard let camera = slot.camera else {
                onAddCamera(index)
                return
            }
            // ⏎ on an idle cell means the same as clicking it: show me this camera. Binding the
            // inspector to a cell that is already selected — which arrowing onto it just did — would
            // make the key do nothing on exactly the cells where it has the most to offer.
            if cameraIndex[camera]?.isStreaming == false {
                onConnectCamera(camera)
            } else {
                onSelectCamera(camera)
            }
        }

        /// The arrow a key press names, or `nil` for any other key. Named `arrow` rather than
        /// `direction` so it cannot be shadowed by the binding at its one call site.
        private func arrow(for key: KeyEquivalent) -> VGridDirection? {
            if key == .leftArrow { return .left }
            if key == .rightArrow { return .right }
            if key == .upArrow { return .up }
            if key == .downArrow { return .down }
            return nil
        }

        // MARK: - Private Helpers

        /// The camera filling the stage, but only when it is actually on the stage: a promoted camera
        /// that has since been removed from the layout promotes nothing.
        private var promotedCamera: CameraID? {
            guard let camera = mode.focusedCamera, plan.index(of: camera) != nil else { return nil }
            return camera
        }
    }

    // MARK: - VStageGeometryMatch

    /// Applies DESIGN.md §7.7's `stage` geometry effect, when the window has given us its namespace.
    ///
    /// Written as a `ViewModifier` rather than an `if` inside the cell builder so that the branch is
    /// taken once per tile against a value that never changes — a namespace arrives with the view and
    /// lives as long as the window — instead of becoming a conditional in the view tree that could flip
    /// and re-create the tile underneath the renderer.
    ///
    ///     func matchedGeometryEffect<ID: Hashable>(id: ID, in namespace: Namespace.ID,
    ///                                              properties: MatchedGeometryProperties = .frame,
    ///                                              anchor: UnitPoint = .center,
    ///                                              isSource: Bool = true) -> some View
    @MainActor
    private struct VStageGeometryMatch: ViewModifier {

        /// The window's `stage` namespace, or `nil` to place the tile without the effect.
        let namespace: Namespace.ID?

        /// The camera, whose UUID string is the effect's id — the id has to survive a layout change and
        /// a reorder, and a cell index survives neither (DESIGN.md §7.7).
        let camera: CameraID

        /// True for the grid cell, false for the tile that is currently filling the stage.
        let isSource: Bool

        @ViewBuilder
        func body(content: Content) -> some View {
            if let namespace {
                content.overlay {
                    VTileTransitionProxy()
                        .matchedGeometryEffect(
                            id: camera.rawValue.uuidString,
                            in: namespace,
                            properties: .frame,
                            anchor: .center,
                            isSource: isSource)
                }
            } else {
                content
            }
        }
    }

#endif  // os(macOS)
