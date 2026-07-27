//
//  VGridStageViewTests.swift
//  VigilUITests
//
//  The stage's pure decisions: slot ordering, which cells come out empty, the identity a tile is
//  keyed by, where a promoted tile goes, and what the keyboard does. Nothing here renders a view —
//  these are exactly the parts that can be wrong without looking wrong until an operator uses them.
//  Covers Sources/VigilUI/Grid/GridStagePlan.swift and the helpers VGridStageView drives; see
//  docs/UX.md §5.1, §5.4, §5.6, §5.7 and docs/DESIGN.md §7.7.
//

#if os(macOS)

import Foundation
import Testing

import VigilProtocols

@testable import VigilUI

// MARK: - Helpers

/// A deterministic run of camera identifiers, so a failure message names a stable index.
private func gridStageCameras(_ count: Int) -> [CameraID] {
    (0..<count).map { index in
        let suffix = String(format: "%012x", index)
        let text = "00000000-0000-4000-8000-\(suffix)"
        return CameraID(UUID(uuidString: text) ?? UUID())
    }
}

/// A plan for a layout filled with `count` cameras.
private func gridStageFilledPlan(_ layout: VGridLayout, _ count: Int) -> VStagePlan {
    VStagePlan(layout: layout, cameras: gridStageCameras(count))
}

// MARK: - Slot ordering

/// A plan has exactly one slot per layout cell, in cell order, carrying that cell's rectangle.
///
/// Cell order is tab order, digit order and assignment order at once (UX.md §5.1), so a plan that
/// reordered or dropped a cell would misplace every one of them.
@Test func gridStagePlanHasOneSlotPerCellInCellOrder() {
    for layout in VGridLayout.allCases {
        let plan = gridStageFilledPlan(layout, 0)
        #expect(plan.slots.count == layout.tileCount, "\(layout.rawValue)")
        #expect(plan.tileCount == layout.tileCount)
        for (index, cell) in layout.cells.enumerated() {
            #expect(plan.slots[index].index == index, "\(layout.rawValue) slot \(index)")
            #expect(plan.slots[index].rect == cell, "\(layout.rawValue) slot \(index)")
        }
    }
}

/// Cameras take the leading cells and every cell after them is empty.
///
/// This is the mockup's stage: nine cells, six cameras, three "Add camera" placeholders at the end
/// (`design/mockups/01-main-window.html`).
@Test func gridStagePlacesEmptyCellsAfterAssignedTiles() {
    let cameras = gridStageCameras(6)
    let plan = VStagePlan(layout: .mosaic4x3, cameras: cameras)
    #expect(plan.occupiedIndices == [0, 1, 2, 3, 4, 5])
    #expect(plan.emptyIndices == [6, 7, 8])
    for index in 0..<6 {
        #expect(plan.camera(at: index) == cameras[index])
        #expect(plan.slots[index].isEmpty == false)
    }
    for index in 6..<9 {
        #expect(plan.camera(at: index) == nil)
        #expect(plan.slots[index].isEmpty)
    }
}

/// For every layout and every camera count, occupied and empty cells partition the grid and nothing
/// is lost between them.
@Test func gridStageEmptyAndOccupiedIndicesPartitionEveryLayout() {
    for layout in VGridLayout.allCases {
        for count in [0, 1, 3, layout.tileCount - 1, layout.tileCount, layout.tileCount + 5] {
            guard count >= 0 else { continue }
            let plan = gridStageFilledPlan(layout, count)
            let expectedOccupied = Swift.min(count, layout.tileCount)
            #expect(plan.occupiedIndices.count == expectedOccupied,
                    "\(layout.rawValue) with \(count) cameras")
            #expect(plan.emptyIndices.count == layout.tileCount - expectedOccupied,
                    "\(layout.rawValue) with \(count) cameras")
            let union = Set(plan.occupiedIndices).union(plan.emptyIndices)
            #expect(union == Set(0..<layout.tileCount), "\(layout.rawValue) with \(count) cameras")
            #expect(Set(plan.occupiedIndices).isDisjoint(with: plan.emptyIndices))
        }
    }
}

/// An emptied cell becomes an empty slot **in place** — the cameras after it do not shuffle up.
///
/// UX.md §5.3: closing a tile clears that cell. If the plan compacted instead, closing the first
/// tile of a 2 × 2 would appear to move every other camera.
@Test func gridStageClearedCellBecomesAnEmptySlotInPlace() {
    let cameras = gridStageCameras(4)
    var assignment = VStageAssignment(layout: .grid2x2, cameras: cameras)
    assignment.clear(at: 1)
    let plan = VStagePlan(assignment: assignment)
    #expect(plan.emptyIndices == [1])
    #expect(plan.camera(at: 0) == cameras[0])
    #expect(plan.camera(at: 2) == cameras[2])
    #expect(plan.camera(at: 3) == cameras[3])
}

// MARK: - Identity

/// A slot's identity is its **camera**, so a camera that moves cell keeps the same identity.
///
/// ⛔ This is what stops a layout change from tearing down a decode session (UX.md §5.1 acceptance
/// #3): `ForEach` re-uses the view whose identity is unchanged. Keying by cell index would hand
/// cell 0 a different camera and rebuild the tile — and the `AVSampleBufferDisplayLayer` with it.
@Test func gridStageSlotIdentityFollowsTheCameraNotTheCell() throws {
    let cameras = gridStageCameras(4)
    var assignment = VStageAssignment(layout: .grid2x2, cameras: cameras)
    let before = try #require(VStagePlan(assignment: assignment).slot(at: 0))
    assignment.swap(0, 3)
    let after = VStagePlan(assignment: assignment)
    let moved = try #require(after.slot(at: 3))
    #expect(moved.camera == before.camera)
    #expect(moved.id == before.id)
    #expect(moved.index != before.index)
}

/// The same camera keeps its identity across a layout change, and the identity is the UUID string
/// DESIGN.md §7.7 names for the `stage` `matchedGeometryEffect` namespace.
@Test func gridStageSlotIdentitySurvivesALayoutChange() throws {
    let cameras = gridStageCameras(4)
    let small = VStageAssignment(layout: .grid2x2, cameras: cameras)
    let large = small.changing(to: .grid4x4)
    let before = try #require(VStagePlan(assignment: small).slot(at: 2))
    let after = try #require(VStagePlan(assignment: large).slot(at: 2))
    #expect(before.id == after.id)
    #expect(before.id == cameras[2].rawValue.uuidString)
}

/// Empty cells have identities of their own, all distinct, and none of them can collide with a
/// camera's UUID string.
@Test func gridStageEmptySlotIdentitiesAreUniqueAndDistinctFromCameras() {
    let plan = gridStageFilledPlan(.grid4x4, 3)
    let ids = plan.slots.map { $0.id }
    #expect(Set(ids).count == ids.count)
    for index in plan.emptyIndices {
        #expect(plan.slots[index].id.hasPrefix(VStageSlot.emptyIDPrefix))
    }
    for index in plan.occupiedIndices {
        #expect(plan.slots[index].id.hasPrefix(VStageSlot.emptyIDPrefix) == false)
    }
}

/// A tile payload's identifier is derived from its identity, so the two cannot disagree about which
/// camera a tile is.
@Test func gridStageCameraIdentifierDerivesFromTheIdentity() {
    let uuid = UUID()
    let model = VStageCamera(camera: LiveCameraIdentity(id: uuid,
                                                        name: "Front Door",
                                                        host: "192.168.1.64"),
                             state: .live)
    #expect(model.id == CameraID(uuid))
    #expect(model.id.rawValue == uuid)
}

// MARK: - Lookup

/// Reads outside the grid return `nil` rather than trapping — a focused index can outlive the
/// layout that produced it.
@Test func gridStageLookupsRejectOutOfRangeIndices() {
    let plan = gridStageFilledPlan(.grid2x2, 4)
    #expect(plan.slot(at: -1) == nil)
    #expect(plan.slot(at: 4) == nil)
    #expect(plan.camera(at: -1) == nil)
    #expect(plan.camera(at: 99) == nil)
}

/// A camera on the stage is found at its cell; one that is not on the stage is not found at all.
@Test func gridStageFindsTheCellACameraOccupies() {
    let cameras = gridStageCameras(5)
    let plan = VStagePlan(layout: .grid2x2, cameras: cameras)
    #expect(plan.index(of: cameras[0]) == 0)
    #expect(plan.index(of: cameras[3]) == 3)
    // The fifth camera did not fit a four-cell layout, so it is in overflow, not in a cell.
    #expect(plan.index(of: cameras[4]) == nil)
    #expect(plan.overflowCount == 1)
}

/// The overflow count is the assignment's, which is what the `+3` chip prints (UX.md §5.1).
@Test func gridStageOverflowCountComesFromTheAssignment() {
    #expect(gridStageFilledPlan(.grid4x4, 20).overflowCount == 4)
    #expect(gridStageFilledPlan(.grid4x4, 16).overflowCount == 0)
    #expect(gridStageFilledPlan(.single, 3).overflowCount == 2)
}

// MARK: - Geometry

/// Every slot's rectangle is the geometry's rectangle for that cell, in cell order.
@Test func gridStageSlotFramesMatchTheMeasuredGeometry() {
    let size = CGSize(width: 1281, height: 719)
    for layout in VGridLayout.allCases {
        let plan = gridStageFilledPlan(layout, layout.tileCount)
        let geometry = VGridGeometry(layout: layout, size: size)
        for slot in plan.slots {
            #expect(plan.frame(for: slot, in: geometry) == geometry.frame(of: slot.rect),
                    "\(layout.rawValue) slot \(slot.index)")
        }
    }
}

/// The promoted camera takes the whole tile area, and only that camera.
///
/// "Tile fullscreen" fills the stage while the sidebar and inspector stay put (UX.md §2.5, §5.6).
@Test func gridStagePromotedCameraFillsTheWholeTileArea() throws {
    let cameras = gridStageCameras(9)
    let plan = VStagePlan(layout: .grid3x3, cameras: cameras)
    let geometry = VGridGeometry(layout: .grid3x3, size: CGSize(width: 1200, height: 800))
    let promoted = cameras[4]
    let promotedSlot = try #require(plan.slot(at: 4))
    #expect(plan.frame(for: promotedSlot, in: geometry, promoted: promoted) == geometry.stageFrame)
    for slot in plan.slots where slot.index != 4 {
        #expect(plan.frame(for: slot, in: geometry, promoted: promoted)
                == geometry.frame(of: slot.rect), "slot \(slot.index)")
    }
}

/// A promoted camera that is no longer on the stage promotes nothing, so every cell keeps its
/// rectangle instead of collapsing.
@Test func gridStagePromotingAnAbsentCameraLeavesEveryCellAlone() {
    let plan = gridStageFilledPlan(.grid2x2, 4)
    let stranger = try? #require(gridStageCameras(9).last)
    let geometry = VGridGeometry(layout: .grid2x2, size: CGSize(width: 900, height: 600))
    for slot in plan.slots {
        #expect(plan.frame(for: slot, in: geometry, promoted: stranger)
                == geometry.frame(of: slot.rect), "slot \(slot.index)")
    }
}

// MARK: - Keyboard

/// The plan's movement is the navigator's movement, for every layout, cell and direction.
///
/// Delegation rather than reimplementation is the property worth pinning: the stage and
/// `VGridNavigator` can then never disagree about what `⌥→` does on a hero layout.
@Test func gridStageFocusMovementDelegatesToTheNavigator() {
    for layout in VGridLayout.allCases {
        let plan = gridStageFilledPlan(layout, layout.tileCount)
        let navigator = VGridNavigator(layout: layout)
        for index in 0..<layout.tileCount {
            for direction in VGridDirection.allCases {
                #expect(plan.move(from: index, direction) == navigator.move(from: index, direction),
                        "\(layout.rawValue) \(index) \(direction)")
            }
        }
    }
}

/// ⌥→ and ⌥↓ move one cell on a uniform grid, and ⌥← and ⌥↑ come back.
@Test func gridStageFocusMovesOneCellOnAUniformGrid() {
    let plan = gridStageFilledPlan(.grid2x2, 4)
    #expect(plan.move(from: 0, .right) == 1)
    #expect(plan.move(from: 0, .down) == 2)
    #expect(plan.move(from: 3, .left) == 2)
    #expect(plan.move(from: 3, .up) == 1)
}

/// Movement does not wrap: an arrow at the edge returns `nil`, which is the caller's cue to play
/// the 3 pt bump and let the key event travel onwards (UX.md §5.7).
@Test func gridStageFocusDoesNotWrapAtAnyEdge() {
    let plan = gridStageFilledPlan(.grid3x3, 9)
    #expect(plan.move(from: 2, .right) == nil)
    #expect(plan.move(from: 0, .up) == nil)
    #expect(plan.move(from: 0, .left) == nil)
    #expect(plan.move(from: 8, .down) == nil)
    #expect(plan.move(from: 8, .right) == nil)
}

/// A single-tile stage has nowhere to go in any direction, and an out-of-range start moves nothing.
@Test func gridStageFocusOnASingleTileHasNoMoves() {
    let plan = gridStageFilledPlan(.single, 1)
    for direction in VGridDirection.allCases {
        #expect(plan.move(from: 0, direction) == nil)
        #expect(plan.move(from: 7, direction) == nil)
    }
}

/// `⇥` order is cell order and stops at both ends, so focus can reach the sidebar and the
/// inspector rather than looping inside the stage forever.
@Test func gridStageTabOrderStopsAtBothEndsInsteadOfWrapping() {
    let plan = gridStageFilledPlan(.grid2x2, 4)
    #expect(plan.firstIndex == 0)
    #expect(plan.lastIndex == 3)
    #expect(plan.next(after: 0) == 1)
    #expect(plan.next(after: 3) == nil)
    #expect(plan.previous(before: 3) == 2)
    #expect(plan.previous(before: 0) == nil)
}

/// A focused index that a shrinking layout left pointing at nothing clamps to the nearest cell.
///
/// DESIGN.md §10.2 #7: focus is never lost.
@Test func gridStageFocusClampsAfterTheLayoutShrinks() {
    let plan = gridStageFilledPlan(.grid2x2, 4)
    #expect(plan.clamped(11) == 3)
    #expect(plan.clamped(-4) == 0)
    #expect(plan.clamped(2) == 2)
}

#endif
