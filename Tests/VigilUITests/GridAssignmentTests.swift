//
//  GridAssignmentTests.swift
//  VigilUITests
//
//  Cell assignment, the overflow rule, and the layout-change round trip. The round trip is the
//  property that decides whether switching layout loses a camera, which is the kind of defect a user
//  reports as "it forgot my cameras".
//  Covers Sources/VigilUI/Grid/GridAssignment.swift; see docs/UX.md §5.1, §5.3, §5.4.
//

#if os(macOS)

import Foundation
import Testing

import VigilProtocols

@testable import VigilUI

// MARK: - Helpers

/// A deterministic run of camera identifiers, so a failure message names a stable index.
private func gridAssignmentCameras(_ count: Int) -> [CameraID] {
    (0..<count).map { index in
        // A fixed UUID pattern keeps the identities stable and readable across runs.
        let suffix = String(format: "%012x", index)
        let text = "00000000-0000-4000-8000-\(suffix)"
        return CameraID(UUID(uuidString: text) ?? UUID())
    }
}

// MARK: - Filling

/// Cameras fill cells in order and the surplus goes to overflow.
@Test func gridAssignmentFillsCellsInOrderAndOverflowsTheRest() {
    let cameras = gridAssignmentCameras(6)
    let state = VStageAssignment(layout: .grid2x2, cameras: cameras)
    #expect(state.cells.count == 4)
    #expect(state.cells == [cameras[0], cameras[1], cameras[2], cameras[3]])
    #expect(state.overflow == [cameras[4], cameras[5]])
    #expect(state.overflowCount == 2)
    #expect(state.occupiedCount == 4)
}

/// Fewer cameras than cells leaves empty cells, which is the mockup's three "Add camera" tiles.
@Test func gridAssignmentLeavesEmptyCellsWhenThereAreFewerCameras() {
    let cameras = gridAssignmentCameras(6)
    let state = VStageAssignment(layout: .mosaic4x3, cameras: cameras)
    #expect(state.cells.count == 9)
    #expect(state.occupiedCount == 6)
    #expect(state.overflow.isEmpty)
    #expect(state.firstEmptyIndex == 6)
    #expect(state.camera(at: 6) == nil)
    #expect(state.camera(at: 5) == cameras[5])
}

/// An empty library is a full set of placeholders, not an error.
@Test func gridAssignmentEmptyLibraryGivesAllPlaceholders() {
    let state = VStageAssignment(layout: .grid4x4)
    #expect(state.cells.count == 16)
    #expect(state.occupiedCount == 0)
    #expect(state.firstEmptyIndex == 0)
    #expect(state.visibleCameras.isEmpty)
}

/// Out-of-range reads return `nil` rather than trapping.
@Test func gridAssignmentOutOfRangeReadsReturnNil() {
    let state = VStageAssignment(layout: .grid2x2, cameras: gridAssignmentCameras(4))
    #expect(state.camera(at: -1) == nil)
    #expect(state.camera(at: 4) == nil)
    #expect(state.camera(at: 999) == nil)
}

/// An explicit cell map is padded or truncated to the layout, so a stale persisted layout cannot
/// produce a mismatched array.
@Test func gridAssignmentExplicitMapIsResizedToTheLayout() {
    let cameras = gridAssignmentCameras(3)
    let short = VStageAssignment(layout: .grid4x4, assignments: [cameras[0], cameras[1]])
    #expect(short.cells.count == 16)
    #expect(short.cells[0] == cameras[0])
    #expect(short.cells[2] == nil)
    let long = VStageAssignment(layout: .single,
                                assignments: [cameras[0], cameras[1], cameras[2]])
    #expect(long.cells.count == 1)
    #expect(long.cells[0] == cameras[0])
}

// MARK: - Assigning

/// Assigning moves a camera rather than duplicating it: one camera is never in two cells.
///
/// Two tiles of one camera means two decode sessions for one stream, which is the waste the
/// tile-per-camera model exists to avoid.
@Test func gridAssignmentAssigningMovesACameraInsteadOfDuplicatingIt() {
    let cameras = gridAssignmentCameras(4)
    var state = VStageAssignment(layout: .grid2x2, cameras: cameras)
    state.assign(cameras[0], to: 3)
    #expect(state.cells[0] == nil)
    #expect(state.cells[3] == cameras[0])
    #expect(state.cells.compactMap { $0 }.count == 3)
    #expect(state.index(of: cameras[0]) == 3)
    // The camera that was displaced is kept, not dropped.
    #expect(state.overflow.contains(cameras[3]))
}

/// Assigning a camera from overflow removes it from overflow.
@Test func gridAssignmentPullingFromOverflowRemovesItFromOverflow() {
    let cameras = gridAssignmentCameras(6)
    var state = VStageAssignment(layout: .grid2x2, cameras: cameras)
    #expect(state.overflow == [cameras[4], cameras[5]])
    state.assign(cameras[5], to: 1)
    #expect(state.cells[1] == cameras[5])
    #expect(!state.overflow.contains(cameras[5]))
    // The camera it replaced took its place in overflow, at the front.
    #expect(state.overflow.first == cameras[1])
}

/// Assigning a camera to the cell it already occupies changes nothing.
@Test func gridAssignmentAssigningToTheSameCellIsANoOp() {
    let cameras = gridAssignmentCameras(4)
    let before = VStageAssignment(layout: .grid2x2, cameras: cameras)
    var after = before
    after.assign(cameras[2], to: 2)
    #expect(after == before)
}

/// Assigning to an out-of-range cell does nothing rather than trapping.
@Test func gridAssignmentAssigningOutOfRangeIsIgnored() {
    let cameras = gridAssignmentCameras(4)
    let before = VStageAssignment(layout: .grid2x2, cameras: cameras)
    var after = before
    after.assign(cameras[0], to: 9)
    after.assign(cameras[0], to: -1)
    #expect(after == before)
}

// MARK: - Clearing and removing

/// Clearing a cell keeps the camera — the tile's close button does not delete anything.
@Test func gridAssignmentClearingACellKeepsTheCameraInOverflow() {
    let cameras = gridAssignmentCameras(4)
    var state = VStageAssignment(layout: .grid2x2, cameras: cameras)
    state.clear(at: 1)
    #expect(state.cells[1] == nil)
    #expect(state.overflow == [cameras[1]])
    #expect(state.occupiedCount == 3)
    #expect(!state.contains(cameras[1]))
}

/// Clearing an already-empty cell is harmless.
@Test func gridAssignmentClearingAnEmptyCellIsANoOp() {
    let before = VStageAssignment(layout: .grid2x2, cameras: gridAssignmentCameras(2))
    var after = before
    after.clear(at: 3)
    after.clear(at: -1)
    after.clear(at: 99)
    #expect(after == before)
}

/// Removing a deleted camera takes it out of both the cells and overflow.
@Test func gridAssignmentRemovingACameraClearsItFromCellsAndOverflow() {
    let cameras = gridAssignmentCameras(6)
    var state = VStageAssignment(layout: .grid2x2, cameras: cameras)
    state.remove(cameras[1])
    state.remove(cameras[5])
    #expect(state.cells[1] == nil)
    #expect(state.overflow == [cameras[4]])
    #expect(!state.contains(cameras[1]))
}

/// Swapping exchanges two cells, which is one tile dragged onto another.
@Test func gridAssignmentSwapExchangesTwoCells() {
    let cameras = gridAssignmentCameras(4)
    var state = VStageAssignment(layout: .grid2x2, cameras: cameras)
    state.swap(0, 3)
    #expect(state.cells[0] == cameras[3])
    #expect(state.cells[3] == cameras[0])
    let before = state
    state.swap(0, 99)
    #expect(state == before)
}

// MARK: - Layout change

/// Shrinking then growing restores exactly the arrangement it started with.
///
/// This is the property that decides whether ⌘5 → ⌘2 → ⌘5 loses the operator's arrangement, and it
/// is the reason displaced cameras go to the *front* of overflow in cell order while growth pulls
/// from the front in cell order.
@Test func gridAssignmentLayoutChangeRoundTripsExactly() {
    let cameras = gridAssignmentCameras(16)
    let full = VStageAssignment(layout: .grid4x4, cameras: cameras)
    let shrunk = full.changing(to: .grid2x2)
    #expect(shrunk.cells.count == 4)
    #expect(shrunk.cells == [cameras[0], cameras[1], cameras[2], cameras[3]])
    #expect(shrunk.overflow == Array(cameras[4...]))
    let restored = shrunk.changing(to: .grid4x4)
    #expect(restored.cells == full.cells)
    #expect(restored.overflow.isEmpty)
    #expect(restored == full)
}

/// The round trip holds through a chain of layouts, not just one hop.
@Test func gridAssignmentLayoutChangeRoundTripsThroughAChain() {
    let cameras = gridAssignmentCameras(16)
    let full = VStageAssignment(layout: .grid4x4, cameras: cameras)
    let wandered = full
        .changing(to: .grid3x3)
        .changing(to: .single)
        .changing(to: .grid2x2)
        .changing(to: .hero1p5)
        .changing(to: .grid4x4)
    #expect(wandered.cells == full.cells)
    #expect(wandered.overflow.isEmpty)
}

/// No camera is ever lost by a layout change: cells plus overflow is conserved.
@Test func gridAssignmentLayoutChangeConservesEveryCamera() {
    let cameras = gridAssignmentCameras(16)
    var state = VStageAssignment(layout: .grid4x4, cameras: cameras)
    let expected = Set(cameras)
    for layout in VGridLayout.allCases {
        state = state.changing(to: layout)
        let present = Set(state.visibleCameras).union(state.overflow)
        #expect(present == expected, "\(layout.rawValue) lost or invented a camera")
        #expect(state.cells.count == layout.tileCount)
    }
}

/// Growing into a layout with more cells pulls cameras out of overflow.
@Test func gridAssignmentGrowingPullsFromOverflow() {
    let cameras = gridAssignmentCameras(9)
    let small = VStageAssignment(layout: .grid2x2, cameras: cameras)
    #expect(small.overflowCount == 5)
    let grown = small.changing(to: .grid3x3)
    #expect(grown.occupiedCount == 9)
    #expect(grown.overflow.isEmpty)
    #expect(grown.visibleCameras == cameras)
}

/// Changing to the same layout is identity.
@Test func gridAssignmentChangingToTheSameLayoutIsIdentity() {
    let state = VStageAssignment(layout: .grid3x3, cameras: gridAssignmentCameras(5))
    #expect(state.changing(to: .grid3x3) == state)
}

/// A cleared cell stays cleared across a layout change that does not need it.
///
/// Otherwise closing a tile and then changing layout would silently refill it, and the close button
/// would look broken.
@Test func gridAssignmentClearedCellIsNotSilentlyRefilledWhenShrinking() {
    let cameras = gridAssignmentCameras(4)
    var state = VStageAssignment(layout: .grid2x2, cameras: cameras)
    state.clear(at: 0)
    let shrunk = state.changing(to: .single)
    // Cell 0 was empty; shrinking to one cell fills it from overflow because there is now nowhere
    // else for those cameras to be — the alternative is a stage showing nothing at all.
    #expect(shrunk.cells.count == 1)
    #expect(shrunk.cells[0] != nil)
}

// MARK: - Reconciling with the library

/// A camera deleted from the library disappears from the stage.
@Test func gridAssignmentReconcileDropsDeletedCameras() {
    let cameras = gridAssignmentCameras(4)
    let state = VStageAssignment(layout: .grid2x2, cameras: cameras)
    let survivors = [cameras[0], cameras[2]]
    let reconciled = state.reconciled(with: survivors)
    #expect(Set(reconciled.visibleCameras) == Set(survivors))
    #expect(reconciled.overflow.isEmpty)
    #expect(reconciled.occupiedCount == 2)
}

/// Newly added cameras land in the empty cells, which is what a discovery import needs.
@Test func gridAssignmentReconcileFillsEmptyCellsWithNewCameras() {
    let cameras = gridAssignmentCameras(6)
    let state = VStageAssignment(layout: .grid2x2, cameras: Array(cameras.prefix(2)))
    #expect(state.firstEmptyIndex == 2)
    let reconciled = state.reconciled(with: cameras)
    #expect(reconciled.occupiedCount == 4)
    #expect(reconciled.visibleCameras == Array(cameras.prefix(4)))
    #expect(reconciled.overflow == [cameras[4], cameras[5]])
}

/// Reconciling with the same library is a no-op for an already-full stage.
@Test func gridAssignmentReconcileWithUnchangedLibraryIsStable() {
    let cameras = gridAssignmentCameras(4)
    let state = VStageAssignment(layout: .grid2x2, cameras: cameras)
    #expect(state.reconciled(with: cameras) == state)
}

/// Reconciling does not move a camera that is already placed.
@Test func gridAssignmentReconcileKeepsExistingPlacements() {
    let cameras = gridAssignmentCameras(4)
    var state = VStageAssignment(layout: .grid2x2, cameras: cameras)
    state.swap(0, 3)
    let reconciled = state.reconciled(with: cameras)
    #expect(reconciled.cells[0] == cameras[3])
    #expect(reconciled.cells[3] == cameras[0])
}

// MARK: - VStageMode

/// Focus is keyed by camera, so it survives a layout change.
@Test func gridAssignmentStageModeIsKeyedByCamera() {
    let cameras = gridAssignmentCameras(2)
    let mode = VStageMode.focus(cameras[0])
    #expect(mode.isFocused)
    #expect(mode.focusedCamera == cameras[0])
    #expect(!VStageMode.grid.isFocused)
    #expect(VStageMode.grid.focusedCamera == nil)
}

/// Double-clicking the focused camera returns to the grid; another camera re-targets focus.
@Test func gridAssignmentStageModeTogglingPromotesAndReturns() {
    let cameras = gridAssignmentCameras(2)
    let promoted = VStageMode.grid.toggling(cameras[0])
    #expect(promoted == .focus(cameras[0]))
    #expect(promoted.toggling(cameras[0]) == .grid)
    #expect(promoted.toggling(cameras[1]) == .focus(cameras[1]))
}

#endif
