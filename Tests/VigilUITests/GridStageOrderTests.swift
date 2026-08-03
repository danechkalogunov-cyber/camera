//
//  GridStageOrderTests.swift
//  VigilUITests
//
//  Which cameras reach the stage, and in what order.
//  Covers Sources/VigilUI/Grid/GridStageOrder.swift; see docs/UX.md §1.3 and §5.1.
//
//  ⛔ The reason this file exists is `stageOrderSurvivesALibraryLargeEnoughToLeaveInsertionSort`.
//  The rule shipped expressed as `sorted { left, _ in left == live }`, which is not a strict weak
//  ordering — Swift's introsort is entitled to treat that as undefined, and it traps with "not a
//  valid strict weak ordering" only once the array is long enough to leave the insertion-sort path.
//  A library of four looked perfect. Thirty would have taken the window down.
//

#if os(macOS)

import Foundation
import Testing

import VigilProtocols

@testable import VigilUI

// MARK: - Helpers

/// Stable, readable identifiers so a failure names an index rather than a random UUID.
private func stageOrderCameras(_ count: Int) -> [CameraID] {
    (0..<count).map { index in
        let suffix = String(format: "%012x", index)
        return CameraID(UUID(uuidString: "00000000-0000-4000-8000-\(suffix)") ?? UUID())
    }
}

// MARK: - Ordering

/// The streaming camera leads, whatever its place in the library.
@MainActor
@Test func stageOrderPutsTheStreamingCameraFirst() {
    let cameras = stageOrderCameras(4)
    let order = VStageOrder.resolve(library: cameras, live: cameras[3])
    #expect(order.first == cameras[3])
    // Everything else keeps library order behind it — the partition is stable, which the comparator
    // this replaced was not.
    #expect(order == [cameras[3], cameras[0], cameras[1], cameras[2]])
}

/// A camera that is streaming but not yet filed still gets a cell.
///
/// It is filed on its first frame, so between connecting and that frame the library does not hold
/// it — and a stage that dropped it would be showing a picture in no cell at all.
@MainActor
@Test func stageOrderIncludesAStreamingCameraTheLibraryDoesNotHoldYet() {
    let cameras = stageOrderCameras(3)
    let stranger = stageOrderCameras(9).last ?? cameras[0]
    let order = VStageOrder.resolve(library: cameras, live: stranger)
    #expect(order.first == stranger)
    #expect(order.count == 4)
}

/// No duplicates when the streaming camera is already in the library.
@MainActor
@Test func stageOrderDoesNotDuplicateTheStreamingCamera() {
    let cameras = stageOrderCameras(5)
    let order = VStageOrder.resolve(library: cameras, live: cameras[2])
    #expect(order.count == cameras.count)
    #expect(Set(order).count == order.count)
}

// MARK: - Groups

/// A selected group narrows the stage to its members.
@MainActor
@Test func stageOrderNarrowsToTheSelectedGroup() {
    let cameras = stageOrderCameras(5)
    let members: Set<CameraID> = [cameras[1], cameras[3]]
    let order = VStageOrder.resolve(library: cameras,
                                    live: cameras[3],
                                    isInSelectedGroup: { members.contains($0) })
    #expect(order == [cameras[3], cameras[1]])
}

/// The streaming camera is dropped when it is not in the selected group.
///
/// Deliberate: selecting a group means "show me this group", and exempting whichever camera happens
/// to be playing would make the GROUPS section decorative — the rule UX.md §1.3 is there to avoid.
@MainActor
@Test func stageOrderDropsTheStreamingCameraOutsideTheSelectedGroup() {
    let cameras = stageOrderCameras(4)
    let members: Set<CameraID> = [cameras[0]]
    let order = VStageOrder.resolve(library: cameras,
                                    live: cameras[2],
                                    isInSelectedGroup: { members.contains($0) })
    #expect(order == [cameras[0]])
}

/// A group with no members is an empty stage, not every camera.
@MainActor
@Test func stageOrderIsEmptyForAGroupWithNoMembers() {
    let cameras = stageOrderCameras(3)
    let order = VStageOrder.resolve(library: cameras,
                                    live: cameras[0],
                                    isInSelectedGroup: { _ in false })
    #expect(order.isEmpty)
}

// MARK: - The regression this file was written for

/// Thirty cameras, which is past the point an invalid comparator starts trapping.
///
/// `sorted(by:)` with `{ left, _ in left == live }` reports `a < b` and `b < a` as both false for
/// any two idle cameras. Swift's sort switches from insertion sort to introsort above a threshold
/// in the low tens and validates the comparator on the way, so the crash appears at scale and not
/// before. Thirty is comfortably past it; the assertion is that this returns at all.
@MainActor
@Test func stageOrderSurvivesALibraryLargeEnoughToLeaveInsertionSort() {
    let cameras = stageOrderCameras(30)
    let order = VStageOrder.resolve(library: cameras, live: cameras[29])
    #expect(order.count == 30)
    #expect(order.first == cameras[29])
    #expect(order.last == cameras[28])
}

#endif  // os(macOS)
