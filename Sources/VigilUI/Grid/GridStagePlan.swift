//
//  GridStagePlan.swift
//  VigilUI
//
//  The stage's cells resolved into slots: which camera is in each one, the identity SwiftUI keys
//  the tile by, where a promoted tile goes, and the keyboard moves between cells. Pure value work,
//  so everything the stage decides is testable without a window.
//  macOS-only. Implements docs/UX.md §5.1 (cell order), §5.4 (empty cells), §5.6 (promotion) and
//  §5.7 (keyboard movement); docs/DESIGN.md §7.7 is why identity is the camera and not the cell.
//

#if os(macOS)

import Foundation

import VigilProtocols

// MARK: - VGridStageMetrics

/// The stage's own numbers.
///
/// A namespace of its own for two reasons. Swift rejects a static stored property inside a generic
/// type outright — `static stored properties not supported in generic types` — so `VGridStageView`,
/// which is generic over its video content, cannot hold these itself; that is a hard error on macOS
/// which a Linux build cannot see, and `Scripts/lint.py` catches it instead. And a number DESIGN.md
/// states belongs somewhere a reviewer can find it, next to the citation.
package enum VGridStageMetrics {

    /// 0.96 — the entrance scale of DESIGN.md §7.8: a tile arrives at `scale 0.96 → 1` together
    /// with `opacity 0 → 1`, staggered in reading order.
    ///
    /// `scaleEffect` is one of the properties §7.9 rule 1 permits on a view that *contains* a video
    /// layer, because it is a compositor transform rather than a re-layout: the tile's frame, and so
    /// the display layer's bounds, are untouched by it.
    package static let entranceScale: CGFloat = 0.96

    /// The promoted tile is drawn above the black backdrop that hides the grid behind it.
    package static let promotedZIndex: Double = 2

    /// The backdrop sits above the grid and below the promoted tile.
    package static let backdropZIndex: Double = 1
}

// MARK: - VStageSlot

/// One cell of the stage, resolved: where it sits, what is in it, and what SwiftUI should key it by.
///
/// A slot is derived, never stored: ``VStageAssignment`` owns the assignment and ``VGridLayout``
/// owns the rectangles, and this type is the join of the two in cell order.
package struct VStageSlot: Sendable, Hashable, Identifiable {

    // MARK: - Stored Properties

    /// The cell's position in **cell order** — which is tab order, digit order, and the order
    /// cameras are assigned into (UX.md §5.1).
    package let index: Int

    /// Where the cell sits on the 12 × 12 unit grid.
    package let rect: VLayoutRect

    /// The camera in the cell, or `nil` for an empty one, which renders `VGridEmptyCell`.
    package let camera: CameraID?

    // MARK: - Initialisation

    /// Creates a slot. No validation: a slot is only ever built by ``VStagePlan`` from a layout and
    /// an assignment that have already agreed on their cell count.
    package init(index: Int, rect: VLayoutRect, camera: CameraID?) {
        self.index = index
        self.rect = rect
        self.camera = camera
    }

    // MARK: - Computed Properties

    /// Whether this cell shows the "Add camera" placeholder (UX.md §5.4).
    package var isEmpty: Bool {
        camera == nil
    }

    /// The prefix an empty cell's identity carries.
    ///
    /// Empty cells are keyed by position because position is all they have; a camera's UUID string
    /// can never collide with this because it contains no dot.
    package static let emptyIDPrefix = "stage.empty."

    /// The identity SwiftUI keys this cell's view by — the **camera**, never the cell index.
    ///
    /// ⛔ This is the single line that keeps a layout change from tearing down a decode session
    /// (UX.md §5.1, acceptance #3). `ForEach` re-uses the view whose identity is unchanged, so a
    /// camera that moves from cell 6 to cell 1 across a layout change keeps its tile, its
    /// `AVSampleBufferDisplayLayer` and its RTSP session; keying by index would instead hand cell 1
    /// a different camera and rebuild both. DESIGN.md §7.7 keys the `stage` namespace by
    /// `camera.id.uuidString` for exactly the same reason.
    package var id: String {
        guard let camera else { return "\(Self.emptyIDPrefix)\(index)" }
        return camera.rawValue.uuidString
    }
}

// MARK: - VStagePlan

/// Everything the stage needs to lay itself out, derived once from an assignment.
///
/// Deliberately **not** `Hashable`: it is rebuilt whenever the assignment changes and is never a
/// dictionary key or an `animation(_:value:)` argument, so a conformance would be one more thing
/// that has to keep holding. ``VGridGeometry`` is not `Hashable` for the same reason.
///
/// The navigator is held rather than made per key press: `VGridNavigator.init` resolves
/// ``VGridLayout/cells``, and doing that inside a key handler would make every arrow press
/// re-derive sixteen rectangles for one comparison.
package struct VStagePlan: Sendable {

    // MARK: - Stored Properties

    /// The arrangement being shown.
    package let layout: VGridLayout

    /// Every cell, in cell order. One entry per ``VGridLayout/cells`` entry, always.
    package let slots: [VStageSlot]

    /// How many cameras did not fit — the `+3` chip's number (UX.md §5.1).
    package let overflowCount: Int

    private let navigator: VGridNavigator

    // MARK: - Initialisation

    /// Resolves an assignment into slots.
    ///
    /// A cell whose camera is out of range of the assignment — which cannot happen, because
    /// `VStageAssignment` pads and truncates its own cell array — resolves to an empty slot rather
    /// than trapping.
    package init(assignment: VStageAssignment) {
        let cells = assignment.layout.cells
        var built: [VStageSlot] = []
        built.reserveCapacity(cells.count)
        for (index, rect) in cells.enumerated() {
            built.append(VStageSlot(index: index, rect: rect, camera: assignment.camera(at: index)))
        }
        self.layout = assignment.layout
        self.slots = built
        self.overflowCount = assignment.overflowCount
        self.navigator = VGridNavigator(layout: assignment.layout)
    }

    /// Fills a layout from an ordered camera list. The convenience a preview and a test want.
    package init(layout: VGridLayout, cameras: [CameraID]) {
        self.init(assignment: VStageAssignment(layout: layout, cameras: cameras))
    }

    // MARK: - Reading

    /// How many cells there are.
    package var tileCount: Int {
        slots.count
    }

    /// The cells holding a camera, in cell order.
    package var occupiedIndices: [Int] {
        slots.filter { !$0.isEmpty }.map { $0.index }
    }

    /// The cells showing "Add camera", in cell order.
    package var emptyIndices: [Int] {
        slots.filter { $0.isEmpty }.map { $0.index }
    }

    /// The slot at a cell index, or `nil` when the index is out of range.
    package func slot(at index: Int) -> VStageSlot? {
        guard index >= 0, index < slots.count else { return nil }
        return slots[index]
    }

    /// The camera in a cell, or `nil` for an empty cell or an out-of-range index.
    package func camera(at index: Int) -> CameraID? {
        slot(at: index)?.camera
    }

    /// The cell a camera occupies, or `nil` when it is not on the stage.
    package func index(of camera: CameraID) -> Int? {
        slots.first { $0.camera == camera }?.index
    }

    // MARK: - Geometry

    /// The rectangle a slot's tile occupies, in the tile area's own coordinates.
    ///
    /// The promoted camera — the one `VStageMode.focus` names — takes the **whole** tile area, which
    /// is what "tile fullscreen" means: it fills the stage while the sidebar and inspector stay put
    /// (UX.md §2.5, §5.6). Every other slot keeps its cell, because the tiles behind the promoted
    /// one stay mounted and must not be re-laid-out while they are hidden.
    ///
    /// - Parameters:
    ///   - slot: the cell to measure.
    ///   - geometry: the measured layout, already reduced by the stage inset.
    ///   - promoted: the camera filling the stage, or `nil` in grid mode. A camera that is not on
    ///     the stage promotes nothing, so every slot keeps its cell.
    package func frame(for slot: VStageSlot,
                       in geometry: VGridGeometry,
                       promoted: CameraID? = nil) -> CGRect {
        if let promoted, slot.camera == promoted {
            return geometry.stageFrame
        }
        return geometry.frame(of: slot.rect)
    }

    // MARK: - Keyboard

    /// The first cell, for `Home` and for the first key press when nothing is focused yet.
    package var firstIndex: Int? {
        navigator.firstIndex
    }

    /// The last cell, for `End`.
    package var lastIndex: Int? {
        navigator.lastIndex
    }

    /// The cell an ⌥-arrow moves to, or `nil` when nothing lies that way.
    ///
    /// Movement is spatial and does not wrap; `nil` means the caller should play the 3 pt bump and
    /// let the key event travel onwards (UX.md §5.7). Delegated to ``VGridNavigator`` rather than
    /// reimplemented, so the stage and the navigator can never disagree about what `⌥→` does.
    package func move(from index: Int, _ direction: VGridDirection) -> Int? {
        navigator.move(from: index, direction)
    }

    /// The next cell in `⇥` order, or `nil` at the end — where focus belongs to the inspector.
    package func next(after index: Int) -> Int? {
        navigator.next(after: index)
    }

    /// The previous cell in `⇧⇥` order, or `nil` before the first — where focus belongs to the
    /// sidebar.
    package func previous(before index: Int) -> Int? {
        navigator.previous(before: index)
    }

    /// The nearest cell to an index that no longer exists, after a layout change shrank the grid.
    ///
    /// DESIGN.md §10.2 #7: focus is never lost. `nil` only when the layout has no cells at all.
    package func clamped(_ index: Int) -> Int? {
        navigator.clamped(index)
    }
}

// MARK: - VStageCamera

/// One camera's tile payload: everything ``VGridTileView`` needs, in one value.
///
/// The stage takes a collection of these rather than an observable model per camera, for the same
/// reason ``VTileStats`` is a snapshot: the tile's readouts update at 1 Hz and its state at human
/// speed, so whatever owns the `StreamController` samples them and hands a value down. Nothing in
/// this type is on the frame path, and nothing in it is read when a frame is presented.
///
/// The picture itself is **not** here — it arrives through the stage's `video` builder, keyed by
/// ``id``, so the renderer's display layer is injected at the app layer (DESIGN.md §7.9 rule 3).
package struct VStageCamera: Sendable, Hashable, Identifiable {

    // MARK: - Stored Properties

    /// Name, address and identity colour.
    package var camera: LiveCameraIdentity

    /// What the tile is showing.
    package var state: LiveConnectionState

    /// When the current connect attempt began, so the elapsed counter measures the connection and
    /// not the moment the tile happened to appear.
    package var attemptStartedAt: Date?

    /// Whether Vigil is recording this camera, which breathes a 3 pt `live` border.
    package var isRecording: Bool

    /// The elapsed recording time, shown bottom-leading while recording.
    package var recordingElapsed: Duration?

    /// The negotiated stream facts for the top-trailing readout, or `nil` to omit it.
    package var stats: VTileStats?

    // MARK: - Initialisation

    /// Creates a tile payload.
    package init(camera: LiveCameraIdentity,
                 state: LiveConnectionState,
                 attemptStartedAt: Date? = nil,
                 isRecording: Bool = false,
                 recordingElapsed: Duration? = nil,
                 stats: VTileStats? = nil) {
        self.camera = camera
        self.state = state
        self.attemptStartedAt = attemptStartedAt
        self.isRecording = isRecording
        self.recordingElapsed = recordingElapsed
        self.stats = stats
    }

    // MARK: - Computed Properties

    /// The library identifier, derived from the identity rather than stored beside it.
    ///
    /// `LiveCameraIdentity` carries a bare `UUID` because it is the video screen's own value type
    /// and predates the stage; deriving the `CameraID` here means the two can never disagree about
    /// which camera a tile is.
    package var id: CameraID {
        CameraID(camera.id)
    }
}

#endif  // os(macOS)
