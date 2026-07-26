//
//  GridAssignment.swift
//  VigilUI
//
//  Which camera is in which cell, what the stage is showing, and where cameras go when the layout
//  shrinks. Pure value semantics; the view reads a state and renders it without deciding anything.
//  macOS-only. Implements docs/UX.md §5.1 (`LayoutState`, cell order), §5.4 (empty cells) and
//  §5.1's overflow rule; docs/DESIGN.md §1.1 P1 keeps the well black in every case.
//

#if os(macOS)

import Foundation

import VigilProtocols

// MARK: - VStageMode

/// What the stage is showing.
package enum VStageMode: Sendable, Hashable {

    /// The grid of tiles.
    case grid

    /// One camera filling the stage, promoted from the grid — "tile fullscreen", `⌘F`, which is
    /// **not** macOS full screen and leaves the sidebar and inspector alone (UX.md §2.5).
    ///
    /// Keyed by ``VigilProtocols/CameraID`` and not by cell index on purpose. DESIGN.md §7.7 keys
    /// the `stage` `matchedGeometryEffect` namespace by `camera.id.uuidString` for the same reason:
    /// the promoted camera has to survive a layout change and a reorder, and a cell index survives
    /// neither. The cell the animation flies from is looked up when it is needed.
    case focus(CameraID)

    /// The promoted camera, if any.
    package var focusedCamera: CameraID? {
        switch self {
        case .grid: return nil
        case .focus(let id): return id
        }
    }

    /// Whether one camera is filling the stage.
    package var isFocused: Bool {
        focusedCamera != nil
    }

    /// The mode reached by double-clicking, or pressing `⌘F` on, a camera.
    ///
    /// Double-click promotes and double-click again returns (UX.md §5.6), so this toggles rather
    /// than always promoting.
    package func toggling(_ camera: CameraID) -> VStageMode {
        focusedCamera == camera ? .grid : .focus(camera)
    }
}

// MARK: - VStageAssignment

/// The cameras assigned to a layout's cells, plus the ones that did not fit.
///
/// ## Why assignments are explicit rather than derived from the camera list
///
/// It would be less code to say "cell *n* shows camera *n* of the library". The design does not
/// allow it: UX.md §5.1 persists a `[LayoutCell]` with an optional `cameraID` per cell, because a
/// user drags a specific camera into a specific cell (§4.3), clears a cell without deleting the
/// camera (§5.3, the tile's close button), and expects both to survive relaunch. A derived mapping
/// makes "clear this cell" impossible to express — the next redraw would refill it.
///
/// ## The overflow rule
///
/// Choosing a smaller layout does not delete the cameras that no longer fit. UX.md §5.1: "surplus
/// cameras are kept in `layout.overflow` (persisted) and restored when a larger mode is chosen; a
/// `+3` chip appears at the Stage's bottom-trailing corner". Displaced cameras are pushed to the
/// **front** of the overflow list in cell order, and growing the layout pulls from the front in cell
/// order, so 4 × 4 → 2 × 2 → 4 × 4 restores exactly the arrangement it started with. That
/// round-trip is the property worth testing, and `GridAssignmentTests` does.
///
/// There is deliberately **no pagination**. A scrolling or paged stage means tiles that are partly
/// or wholly off-screen, and such a tile is either decoding frames nobody can see or has been torn
/// down and will flash when it returns. Overflow keeps the rule that every mounted tile is fully
/// visible, which is also what keeps the decoder count equal to the tile count.
package struct VStageAssignment: Sendable, Hashable {

    // MARK: - Stored Properties

    /// The arrangement.
    package let layout: VGridLayout

    /// One entry per cell, aligned to ``VGridLayout/cells``. `nil` is an empty cell, which renders
    /// the "Add camera" placeholder (UX.md §5.4).
    package private(set) var cells: [CameraID?]

    /// Cameras that do not fit the current layout, in the order they will be restored.
    package private(set) var overflow: [CameraID]

    // MARK: - Initialisation

    /// Fills a layout from an ordered camera list.
    ///
    /// - Parameters:
    ///   - layout: the arrangement.
    ///   - cameras: the library's cameras in sidebar order. The first `layout.tileCount` take the
    ///     cells; the rest become ``overflow``.
    package init(layout: VGridLayout, cameras: [CameraID] = []) {
        self.layout = layout
        let count = layout.tileCount
        self.cells = (0..<count).map { $0 < cameras.count ? cameras[$0] : nil }
        self.overflow = cameras.count > count ? Array(cameras[count...]) : []
    }

    /// Builds a state from an explicit cell map, for restoring a persisted layout.
    ///
    /// `assignments` is padded with `nil` or truncated to the layout's cell count, so a persisted
    /// layout that was saved under a different build cannot produce a mismatched array.
    package init(layout: VGridLayout, assignments: [CameraID?], overflow: [CameraID] = []) {
        self.layout = layout
        let count = layout.tileCount
        self.cells = (0..<count).map { $0 < assignments.count ? assignments[$0] : nil }
        self.overflow = overflow
    }

    // MARK: - Reading

    /// The camera in a cell, or `nil` for an empty cell or an out-of-range index.
    package func camera(at index: Int) -> CameraID? {
        guard index >= 0, index < cells.count else { return nil }
        return cells[index]
    }

    /// The cell a camera occupies, or `nil` when it is not on the stage.
    package func index(of camera: CameraID) -> Int? {
        cells.firstIndex(of: camera)
    }

    /// Whether a camera is on the stage at all.
    package func contains(_ camera: CameraID) -> Bool {
        index(of: camera) != nil
    }

    /// The first empty cell, which is where a dragged or double-clicked camera lands (UX.md §4.3).
    package var firstEmptyIndex: Int? {
        cells.firstIndex { $0 == nil }
    }

    /// How many cells hold a camera.
    package var occupiedCount: Int {
        cells.reduce(into: 0) { total, cell in
            if cell != nil { total += 1 }
        }
    }

    /// How many cameras are waiting in overflow — the `+3` chip's number.
    package var overflowCount: Int {
        overflow.count
    }

    /// Every camera currently on the stage, in cell order.
    package var visibleCameras: [CameraID] {
        cells.compactMap { $0 }
    }

    // MARK: - Mutating

    /// Puts a camera in a cell.
    ///
    /// If the camera is already in another cell it is removed from there first, so one camera can
    /// never occupy two tiles — two tiles of one camera means two decode sessions for one stream,
    /// which is exactly the waste the tile-per-camera model exists to avoid. A camera taken out of
    /// overflow is removed from it.
    package mutating func assign(_ camera: CameraID, to index: Int) {
        guard index >= 0, index < cells.count else { return }
        if let existing = cells.firstIndex(of: camera), existing != index {
            cells[existing] = nil
        }
        overflow.removeAll { $0 == camera }
        if let displaced = cells[index], displaced != camera {
            overflow.insert(displaced, at: 0)
        }
        cells[index] = camera
    }

    /// Empties a cell, moving its camera to the front of overflow so it is not lost.
    ///
    /// This is the tile's close button and `⌫` on a focused cell. UX.md §5.3 is explicit that it
    /// clears the cell and does not delete the camera — deletion happens only from the sidebar.
    package mutating func clear(at index: Int) {
        guard index >= 0, index < cells.count, let camera = cells[index] else { return }
        cells[index] = nil
        overflow.insert(camera, at: 0)
    }

    /// Removes a camera from the stage and from overflow, for when it is deleted from the library.
    package mutating func remove(_ camera: CameraID) {
        if let index = cells.firstIndex(of: camera) {
            cells[index] = nil
        }
        overflow.removeAll { $0 == camera }
    }

    /// Swaps two cells, for dragging one tile onto another.
    package mutating func swap(_ first: Int, _ second: Int) {
        guard first >= 0, first < cells.count, second >= 0, second < cells.count else { return }
        cells.swapAt(first, second)
    }

    // MARK: - Layout change

    /// The same assignment expressed in a different layout.
    ///
    /// Growing pulls from the front of overflow into the new empty cells, in cell order. Shrinking
    /// pushes the displaced cameras to the front of overflow, in cell order. The two are exact
    /// inverses, so switching away from a layout and back restores it.
    ///
    /// ⛔ A layout change must never tear down a decode session for a camera that stays on screen
    /// (UX.md §5.1, acceptance #3). That is a property of how the *view* keys its tiles — by camera,
    /// not by cell — and this method is what makes it achievable: a camera that fits keeps its
    /// identity in the new state rather than being re-derived.
    package func changing(to newLayout: VGridLayout) -> VStageAssignment {
        guard newLayout != layout else { return self }
        let newCount = newLayout.tileCount
        var kept: [CameraID?] = []
        var displaced: [CameraID] = []
        for (index, cell) in cells.enumerated() {
            if index < newCount {
                kept.append(cell)
            } else if let camera = cell {
                displaced.append(camera)
            }
        }
        var pending = displaced + overflow
        while kept.count < newCount {
            kept.append(nil)
        }
        // Fill the cells that opened up, in cell order, from the front of the pending list.
        for index in 0..<newCount where kept[index] == nil {
            guard !pending.isEmpty else { break }
            kept[index] = pending.removeFirst()
        }
        return VStageAssignment(layout: newLayout, assignments: kept, overflow: pending)
    }

    /// The same assignment with cameras that no longer exist dropped, and new ones appended to the
    /// first empty cells.
    ///
    /// Called when the library changes under the stage. New cameras filling empty cells is what
    /// UX.md §8.2 asks for after a discovery import ("the first 4 are auto-assigned to empty Stage
    /// cells").
    package func reconciled(with cameras: [CameraID]) -> VStageAssignment {
        let known = Set(cameras)
        var kept = cells.map { cell -> CameraID? in
            guard let camera = cell, known.contains(camera) else { return nil }
            return camera
        }
        var remaining = overflow.filter { known.contains($0) }
        let placed = Set(kept.compactMap { $0 })
        let additions = cameras.filter { !placed.contains($0) && !remaining.contains($0) }
        var pending = remaining + additions
        for index in kept.indices where kept[index] == nil {
            guard !pending.isEmpty else { break }
            kept[index] = pending.removeFirst()
        }
        remaining = pending
        return VStageAssignment(layout: layout, assignments: kept, overflow: remaining)
    }
}

#endif  // os(macOS)
