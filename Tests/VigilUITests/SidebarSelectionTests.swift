//
//  SidebarSelectionTests.swift
//  VigilUITests
//
//  Click, ⌘-click, ⇧-range, and what the selection does when the selected camera is deleted. The
//  range cases are inclusive at both ends, which is the boundary a hand-rolled list gets wrong.
//  Covers Sources/VigilUI/Sidebar/SidebarSelection.swift; see docs/UX.md §4.3, docs/DESIGN.md §10.2.
//

#if os(macOS)

import Foundation
import Testing

import VigilProtocols

@testable import VigilUI

// MARK: - Helpers

/// Five stable camera identifiers in a fixed order.
private func sidebarSelectionOrder(_ count: Int = 5) -> [CameraID] {
    (0..<count).map { index in
        let suffix = String(format: "%012x", index)
        return CameraID(UUID(uuidString: "00000000-0000-4000-8000-\(suffix)") ?? UUID())
    }
}

// MARK: - Initial state

/// The sidebar starts on the layout row with nothing multi-selected.
@Test func sidebarSelectionStartsOnTheLayoutRow() {
    let state = VSidebarSelectionState()
    #expect(state.focus == .live)
    #expect(state.cameras.isEmpty)
    #expect(state.anchor == nil)
    #expect(!state.isMultiple)
    #expect(state.singleCamera == nil)
}

// MARK: - Plain click

/// A plain click replaces the whole selection.
@Test func sidebarSelectionPlainClickReplacesTheSelection() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.extend(to: order[3], in: order)
    state.select(.camera(order[0]))
    #expect(state.focus == .camera(order[0]))
    #expect(state.cameras == [order[0]])
    #expect(state.anchor == order[0])
    #expect(state.singleCamera == order[0])
}

/// Selecting a non-camera row clears the camera selection: a group or a feed is not a camera.
@Test func sidebarSelectionNonCameraRowClearsTheCameraSelection() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.select(.camera(order[2]))
    state.select(.events)
    #expect(state.focus == .events)
    #expect(state.cameras.isEmpty)
    #expect(state.anchor == nil)
}

/// The focused camera is always a member of the selection.
@Test func sidebarSelectionFocusIsAlwaysAMemberOfTheSelection() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    let steps: [(String, (inout VSidebarSelectionState) -> Void)] = [
        ("select 1", { $0.select(.camera(order[1])) }),
        ("extend 4", { $0.extend(to: order[4], in: order) }),
        ("toggle 2", { $0.toggle(order[2], in: order) }),
        ("toggle 0", { $0.toggle(order[0], in: order) }),
        ("select all", { $0.selectAll(in: order) }),
        ("collapse", { _ = $0.collapseMultiSelection() }),
    ]
    for (label, step) in steps {
        step(&state)
        if let camera = state.focus.selectedCamera {
            #expect(state.cameras.contains(camera), "after \(label): focus is not selected")
        }
    }
}

// MARK: - Command-click

/// ⌘-click adds a camera to the selection and takes the focus.
@Test func sidebarSelectionCommandClickAddsToTheSelection() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.select(.camera(order[0]))
    state.toggle(order[2], in: order)
    #expect(state.cameras == [order[0], order[2]])
    #expect(state.focus == .camera(order[2]))
    #expect(state.isMultiple)
    #expect(state.singleCamera == nil)
}

/// ⌘-click on a selected camera removes it.
@Test func sidebarSelectionCommandClickRemovesASelectedCamera() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.selectAll(in: order)
    state.toggle(order[2], in: order)
    #expect(!state.isSelected(order[2]))
    #expect(state.cameras.count == 4)
}

/// Deselecting the focused camera moves the focus to another selected camera, in display order.
@Test func sidebarSelectionDeselectingTheFocusMovesFocusToAnotherSelectedCamera() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.select(.camera(order[1]))
    state.toggle(order[3], in: order)
    #expect(state.focus == .camera(order[3]))
    state.toggle(order[3], in: order)
    #expect(state.focus == .camera(order[1]))
    #expect(state.cameras == [order[1]])
}

/// Deselecting the last camera falls back to the layout row, never to no selection at all.
@Test func sidebarSelectionDeselectingTheLastCameraFallsBackToTheLayoutRow() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.select(.camera(order[0]))
    state.toggle(order[0], in: order)
    #expect(state.cameras.isEmpty)
    #expect(state.focus == .live)
    #expect(state.anchor == nil)
}

// MARK: - Shift-range

/// A ⇧-click selects the run from the anchor to the target, inclusive at both ends.
@Test func sidebarSelectionShiftRangeIsInclusiveAtBothEnds() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.select(.camera(order[1]))
    state.extend(to: order[3], in: order)
    #expect(state.cameras == [order[1], order[2], order[3]])
    #expect(state.cameras.count == 3)
    #expect(state.focus == .camera(order[3]))
}

/// A ⇧-click upwards selects the same run.
@Test func sidebarSelectionShiftRangeWorksUpwards() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.select(.camera(order[3]))
    state.extend(to: order[1], in: order)
    #expect(state.cameras == [order[1], order[2], order[3]])
    #expect(state.focus == .camera(order[1]))
}

/// The anchor does not walk: a second ⇧-click grows or shrinks the same run.
///
/// An anchor that followed the pointer would make ⇧-click behave like a lasso that keeps everything
/// it has ever touched, which is the single most noticeable defect in a hand-rolled list.
@Test func sidebarSelectionShiftRangeKeepsItsAnchorAcrossSuccessiveClicks() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.select(.camera(order[1]))
    state.extend(to: order[4], in: order)
    #expect(state.cameras.count == 4)
    state.extend(to: order[2], in: order)
    #expect(state.cameras == [order[1], order[2]])
    #expect(state.anchor == order[1])
}

/// ⇧-clicking the anchor itself selects just that row.
@Test func sidebarSelectionShiftClickOnTheAnchorSelectsOneRow() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.select(.camera(order[2]))
    state.extend(to: order[2], in: order)
    #expect(state.cameras == [order[2]])
}

/// With no anchor — a ⇧-click as the very first action — the click behaves as a plain click.
@Test func sidebarSelectionShiftClickWithoutAnAnchorBehavesAsAPlainClick() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.extend(to: order[2], in: order)
    #expect(state.cameras == [order[2]])
    #expect(state.anchor == order[2])
    #expect(state.focus == .camera(order[2]))
}

/// An anchor that is no longer in the displayed order — filtered out, or deleted — does not wedge
/// the range; the click establishes a new anchor.
@Test func sidebarSelectionShiftClickRecoversFromAStaleAnchor() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState(focus: .camera(order[0]),
                                       cameras: [order[0]],
                                       anchor: CameraID())
    state.extend(to: order[3], in: order)
    #expect(state.cameras == [order[3]])
    #expect(state.anchor == order[3])
}

/// ⇧-clicking a row that is not in the displayed order does nothing.
@Test func sidebarSelectionShiftClickOnAnUnknownRowIsIgnored() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.select(.camera(order[0]))
    let before = state
    state.extend(to: CameraID(), in: order)
    #expect(state == before)
}

// MARK: - Select all and collapse

/// ⌘A selects every visible camera.
@Test func sidebarSelectionSelectAllTakesEveryVisibleCamera() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.selectAll(in: order)
    #expect(state.cameras == Set(order))
    #expect(state.focus == .camera(order[0]))
    var empty = VSidebarSelectionState()
    empty.selectAll(in: [])
    #expect(empty.cameras.isEmpty)
}

/// ⌘A keeps an existing focus rather than jumping to the first row.
@Test func sidebarSelectionSelectAllKeepsAnExistingFocus() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.select(.camera(order[3]))
    state.selectAll(in: order)
    #expect(state.focus == .camera(order[3]))
}

/// Esc collapses a multi-selection to the focused camera, and reports whether it did anything.
@Test func sidebarSelectionCollapseReportsWhetherItChangedAnything() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.select(.camera(order[1]))
    #expect(state.collapseMultiSelection() == false)
    state.extend(to: order[4], in: order)
    #expect(state.collapseMultiSelection() == true)
    #expect(state.cameras == [order[4]])
    #expect(state.collapseMultiSelection() == false)
}

// MARK: - Deletion

/// Deleting the focused camera moves the focus to the row that took its place.
@Test func sidebarSelectionDeletingTheFocusMovesToTheNextRow() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.select(.camera(order[2]))
    state.removing(order[2], from: order)
    #expect(state.focus == .camera(order[3]))
    #expect(state.cameras == [order[3]])
}

/// Deleting the last row moves the focus backwards, so repeated ⌫ keeps working.
@Test func sidebarSelectionDeletingTheLastRowMovesFocusBackwards() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.select(.camera(order[4]))
    state.removing(order[4], from: order)
    #expect(state.focus == .camera(order[3]))
}

/// Deleting the only camera falls back to the layout row.
@Test func sidebarSelectionDeletingTheOnlyCameraFallsBackToTheLayoutRow() {
    let order = sidebarSelectionOrder(1)
    var state = VSidebarSelectionState()
    state.select(.camera(order[0]))
    state.removing(order[0], from: order)
    #expect(state.focus == .live)
    #expect(state.cameras.isEmpty)
}

/// Deleting an unfocused member of a multi-selection leaves the focus alone.
@Test func sidebarSelectionDeletingAnUnfocusedMemberKeepsTheFocus() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.select(.camera(order[0]))
    state.extend(to: order[2], in: order)
    state.removing(order[1], from: order)
    #expect(state.focus == .camera(order[2]))
    #expect(state.cameras == [order[0], order[2]])
}

/// Repeatedly deleting the focused camera walks the list and never lands on nothing.
@Test func sidebarSelectionRepeatedDeletionNeverLosesFocus() {
    var order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.select(.camera(order[0]))
    while let focused = state.focus.selectedCamera {
        #expect(order.contains(focused), "focus landed on a camera that is not in the list")
        state.removing(focused, from: order)
        order.removeAll { $0 == focused }
    }
    #expect(order.isEmpty)
    #expect(state.focus == .live)
}

/// Deleting a camera that was never selected is harmless.
@Test func sidebarSelectionDeletingAnUnselectedCameraIsHarmless() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.select(.camera(order[0]))
    let before = state
    state.removing(order[4], from: order)
    #expect(state == before)
}

// MARK: - Context-menu targets

/// Right-clicking inside a multi-selection acts on the whole selection.
@Test func sidebarSelectionContextMenuActsOnTheWholeSelectionFromInsideIt() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.select(.camera(order[0]))
    state.extend(to: order[2], in: order)
    let targets = Set(state.actionTargets(for: order[1]))
    #expect(targets == [order[0], order[1], order[2]])
}

/// Right-clicking outside the selection acts on that row alone, and does not extend the selection.
///
/// Getting this wrong means a user deletes six cameras when they meant one.
@Test func sidebarSelectionContextMenuActsOnOneRowFromOutsideTheSelection() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.select(.camera(order[0]))
    state.extend(to: order[2], in: order)
    #expect(state.actionTargets(for: order[4]) == [order[4]])
    // The selection itself is untouched by asking the question.
    #expect(state.cameras == [order[0], order[1], order[2]])
}

/// A single selection always yields exactly that row.
@Test func sidebarSelectionContextMenuOnASingleSelectionYieldsOneRow() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.select(.camera(order[3]))
    #expect(state.actionTargets(for: order[3]) == [order[3]])
}

/// A bulk operation receives its targets in display order, not in set order.
@Test func sidebarSelectionOrderedSelectionFollowsDisplayOrder() {
    let order = sidebarSelectionOrder()
    var state = VSidebarSelectionState()
    state.select(.camera(order[4]))
    state.toggle(order[1], in: order)
    state.toggle(order[3], in: order)
    #expect(state.orderedSelection(in: order) == [order[1], order[3], order[4]])
}

#endif
