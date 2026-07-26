//
//  SidebarReorderTests.swift
//  VigilUITests
//
//  The pre-move/post-removal index adjustment. Dragging a row one place downwards is the case that
//  is wrong by exactly one in every implementation that skips this correction, so it is pinned from
//  several directions.
//  Covers Sources/VigilUI/Sidebar/SidebarReorder.swift; see docs/UX.md §4.3.
//

#if os(macOS)

import Foundation
import Testing

@testable import VigilUI

// MARK: - The downward-by-one case

/// Moving the first item to "before index 3" of four puts it third, not last.
///
/// This is the canonical off-by-one: `destination` is an index into the array *before* the dragged
/// row is removed, so once `a` is taken out the slot that was index 3 is index 2.
@Test func sidebarReorderMovingDownwardsLandsBeforeTheDestinationRow() {
    let items = ["a", "b", "c", "d"]
    #expect(VSidebarReorder.reordered(items, moving: ["a"], before: 3) == ["b", "c", "a", "d"])
}

/// Dragging a row one place down is a no-op in both spellings of "one place down".
///
/// Dropping between `b` and `c` when `b` is being dragged means "leave it where it is", and so does
/// dropping between `a` and `b`. An implementation without the correction moves the row by one on
/// one of these and not the other, which reads as the list fighting the user.
@Test func sidebarReorderDroppingARowBackWhereItCameFromChangesNothing() {
    let items = ["a", "b", "c", "d"]
    #expect(VSidebarReorder.reordered(items, moving: ["b"], before: 1) == items)
    #expect(VSidebarReorder.reordered(items, moving: ["b"], before: 2) == items)
    #expect(VSidebarReorder.isNoOp(items, moving: ["b"], before: 1))
    #expect(VSidebarReorder.isNoOp(items, moving: ["b"], before: 2))
    #expect(!VSidebarReorder.isNoOp(items, moving: ["b"], before: 3))
}

/// Moving upwards needs no correction and must not receive one.
@Test func sidebarReorderMovingUpwardsIsNotOverCorrected() {
    let items = ["a", "b", "c", "d"]
    #expect(VSidebarReorder.reordered(items, moving: ["d"], before: 0) == ["d", "a", "b", "c"])
    #expect(VSidebarReorder.reordered(items, moving: ["d"], before: 1) == ["a", "d", "b", "c"])
    #expect(VSidebarReorder.reordered(items, moving: ["c"], before: 1) == ["a", "c", "b", "d"])
}

/// Dropping at the very end appends.
@Test func sidebarReorderDroppingPastTheLastRowAppends() {
    let items = ["a", "b", "c", "d"]
    #expect(VSidebarReorder.reordered(items, moving: ["a"], before: 4) == ["b", "c", "d", "a"])
    #expect(VSidebarReorder.reordered(items, moving: ["b"], before: 4) == ["a", "c", "d", "b"])
}

// MARK: - Multi-row drags

/// A contiguous block keeps its internal order.
@Test func sidebarReorderMovesAContiguousBlockAsAUnit() {
    let items = ["a", "b", "c", "d", "e"]
    #expect(VSidebarReorder.reordered(items, moving: ["b", "c"], before: 5)
            == ["a", "d", "e", "b", "c"])
    #expect(VSidebarReorder.reordered(items, moving: ["b", "c"], before: 0)
            == ["b", "c", "a", "d", "e"])
}

/// A non-contiguous selection is gathered into one block, in **display** order rather than in the
/// order the drag collected them.
@Test func sidebarReorderGathersANonContiguousSelectionInDisplayOrder() {
    let items = ["a", "b", "c", "d", "e"]
    // Passed out of order on purpose.
    #expect(VSidebarReorder.reordered(items, moving: ["d", "a"], before: 3)
            == ["b", "c", "a", "d", "e"])
    #expect(VSidebarReorder.reordered(items, moving: ["e", "c", "a"], before: 0)
            == ["a", "c", "e", "b", "d"])
}

/// Moving every item is a no-op.
@Test func sidebarReorderMovingEverythingIsANoOp() {
    let items = ["a", "b", "c"]
    #expect(VSidebarReorder.reordered(items, moving: items, before: 0) == items)
    #expect(VSidebarReorder.reordered(items, moving: items, before: 3) == items)
}

// MARK: - Invariants

/// The result is always a permutation of the input: nothing is created, lost or duplicated.
///
/// Swept over every subset of a five-item list and every destination, which is the cheapest way to
/// be sure the arithmetic cannot drop a camera.
@Test func sidebarReorderAlwaysReturnsAPermutation() {
    let items = ["a", "b", "c", "d", "e"]
    for mask in 0..<(1 << items.count) {
        let moving = items.enumerated().compactMap { index, item in
            (mask & (1 << index)) != 0 ? item : nil
        }
        guard !moving.isEmpty else { continue }
        for destination in -2...(items.count + 2) {
            let result = VSidebarReorder.reordered(items, moving: moving, before: destination)
            #expect(result.count == items.count,
                    "moving \(moving) before \(destination) changed the count")
            #expect(Set(result) == Set(items),
                    "moving \(moving) before \(destination) changed the membership")
        }
    }
}

/// Out-of-range destinations clamp rather than trapping.
@Test func sidebarReorderClampsOutOfRangeDestinations() {
    let items = ["a", "b", "c"]
    #expect(VSidebarReorder.reordered(items, moving: ["c"], before: -5) == ["c", "a", "b"])
    #expect(VSidebarReorder.reordered(items, moving: ["a"], before: 99) == ["b", "c", "a"])
}

/// Items that are not in the list are ignored.
@Test func sidebarReorderIgnoresUnknownItems() {
    let items = ["a", "b", "c"]
    #expect(VSidebarReorder.reordered(items, moving: ["z"], before: 0) == items)
    #expect(VSidebarReorder.reordered(items, moving: [], before: 1) == items)
    #expect(VSidebarReorder.reordered(items, moving: ["z", "a"], before: 3) == ["b", "c", "a"])
}

/// An empty list survives a drag.
@Test func sidebarReorderHandlesAnEmptyList() {
    let empty: [String] = []
    #expect(VSidebarReorder.reordered(empty, moving: ["a"], before: 0) == empty)
}

/// The exposed insertion index agrees with what `reordered` actually did.
@Test func sidebarReorderInsertionIndexAgreesWithTheReorderedResult() {
    let items = ["a", "b", "c", "d", "e"]
    for moving in [["a"], ["c"], ["e"], ["b", "c"], ["a", "e"]] {
        for destination in 0...items.count {
            let index = VSidebarReorder.insertionIndex(in: items, moving: moving,
                                                       before: destination)
            let result = VSidebarReorder.reordered(items, moving: moving, before: destination)
            let block = items.filter { moving.contains($0) }
            #expect(Array(result[index..<(index + block.count)]) == block,
                    "moving \(moving) before \(destination): block not at \(index)")
        }
    }
}

// MARK: - Keyboard equivalents

/// ⌥⌘↑ moves one place up, and declines at the top.
@Test func sidebarReorderMoveUpDestinationStepsOnePlaceAndStopsAtTheTop() throws {
    let items = ["a", "b", "c", "d"]
    let up = try #require(VSidebarReorder.destinationForMoveUp(items, moving: ["c"]))
    #expect(VSidebarReorder.reordered(items, moving: ["c"], before: up) == ["a", "c", "b", "d"])
    #expect(VSidebarReorder.destinationForMoveUp(items, moving: ["a"]) == nil)
    #expect(VSidebarReorder.destinationForMoveUp(items, moving: ["z"]) == nil)
}

/// ⌥⌘↓ moves one place down, and declines at the bottom.
@Test func sidebarReorderMoveDownDestinationStepsOnePlaceAndStopsAtTheBottom() throws {
    let items = ["a", "b", "c", "d"]
    let down = try #require(VSidebarReorder.destinationForMoveDown(items, moving: ["b"]))
    #expect(VSidebarReorder.reordered(items, moving: ["b"], before: down) == ["a", "c", "b", "d"])
    #expect(VSidebarReorder.destinationForMoveDown(items, moving: ["d"]) == nil)
}

/// A contiguous block steps as a block rather than passing through itself.
@Test func sidebarReorderKeyboardMovesAContiguousBlockAsAUnit() throws {
    let items = ["a", "b", "c", "d", "e"]
    let up = try #require(VSidebarReorder.destinationForMoveUp(items, moving: ["c", "d"]))
    #expect(VSidebarReorder.reordered(items, moving: ["c", "d"], before: up)
            == ["a", "c", "d", "b", "e"])
    let down = try #require(VSidebarReorder.destinationForMoveDown(items, moving: ["b", "c"]))
    #expect(VSidebarReorder.reordered(items, moving: ["b", "c"], before: down)
            == ["a", "d", "b", "c", "e"])
}

/// Repeated ⌥⌘↓ walks a row to the bottom and then declines, without ever losing an item.
@Test func sidebarReorderRepeatedKeyboardMovesWalkToTheEndAndStop() {
    var items = ["a", "b", "c", "d"]
    var steps = 0
    while let destination = VSidebarReorder.destinationForMoveDown(items, moving: ["a"]) {
        items = VSidebarReorder.reordered(items, moving: ["a"], before: destination)
        steps += 1
        #expect(steps <= 4, "move-down did not terminate")
        #expect(Set(items) == Set(["a", "b", "c", "d"]))
    }
    #expect(items == ["b", "c", "d", "a"])
    #expect(steps == 3)
}

/// Repeated ⌥⌘↑ does the same in the other direction.
@Test func sidebarReorderRepeatedKeyboardMovesWalkToTheStartAndStop() {
    var items = ["a", "b", "c", "d"]
    var steps = 0
    while let destination = VSidebarReorder.destinationForMoveUp(items, moving: ["d"]) {
        items = VSidebarReorder.reordered(items, moving: ["d"], before: destination)
        steps += 1
        #expect(steps <= 4, "move-up did not terminate")
    }
    #expect(items == ["d", "a", "b", "c"])
    #expect(steps == 3)
}

// MARK: - Drop indicator

/// The insertion indicator snaps to the nearer gap, with the boundary at each row's midpoint.
@Test func sidebarReorderDropIndicatorSnapsAtRowMidpoints() {
    // Rows are 44 pt (VTheme.Metrics.Row.camera). Midpoint of row 0 is 22.
    #expect(VSidebarReorder.insertionIndex(forOffset: 0, rowHeight: 44, count: 6) == 0)
    #expect(VSidebarReorder.insertionIndex(forOffset: 21, rowHeight: 44, count: 6) == 0)
    #expect(VSidebarReorder.insertionIndex(forOffset: 22, rowHeight: 44, count: 6) == 1)
    #expect(VSidebarReorder.insertionIndex(forOffset: 44, rowHeight: 44, count: 6) == 1)
    #expect(VSidebarReorder.insertionIndex(forOffset: 66, rowHeight: 44, count: 6) == 2)
}

/// The indicator clamps to the ends and never exceeds the row count.
@Test func sidebarReorderDropIndicatorClampsToTheList() {
    #expect(VSidebarReorder.insertionIndex(forOffset: -100, rowHeight: 44, count: 3) == 0)
    #expect(VSidebarReorder.insertionIndex(forOffset: 9999, rowHeight: 44, count: 3) == 3)
    #expect(VSidebarReorder.insertionIndex(forOffset: 10, rowHeight: 0, count: 3) == 0)
    #expect(VSidebarReorder.insertionIndex(forOffset: 10, rowHeight: 44, count: 0) == 0)
}

#endif
