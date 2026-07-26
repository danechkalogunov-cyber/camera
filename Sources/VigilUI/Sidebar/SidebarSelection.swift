//
//  SidebarSelection.swift
//  VigilUI
//
//  The selection state machine: plain click, ⌘-click, ⇧-range, arrow keys, and what happens to the
//  selection when the selected camera is deleted. Pure value semantics so every path is testable.
//  macOS-only. Implements docs/UX.md §4.3 (multi-select) and §1.3; docs/DESIGN.md §10.2 #7 (focus is
//  never lost).
//

#if os(macOS)

import Foundation

import VigilProtocols

// MARK: - VSidebarSelectionState

/// What the sidebar has selected, and the anchor a ⇧-click extends from.
///
/// ## Why the multi-selection is a separate set from the focus
///
/// The sidebar has two jobs at once. It drives the inspector, which binds to exactly one camera, and
/// it drives bulk operations — group membership, delete, multi-camera playback — which act on many.
/// Collapsing those into one `Set` loses the notion of "the one the inspector is showing", and
/// collapsing them into one `CameraID` loses bulk selection entirely. So ``focus`` is the row the
/// inspector follows and the row a ⌥-arrow moves from, and ``cameras`` is the set an operation
/// applies to. ``focus`` is always a member of ``cameras`` when it names a camera; that invariant is
/// asserted by the tests rather than assumed.
package struct VSidebarSelectionState: Sendable, Hashable {

    // MARK: - Stored Properties

    /// The row the inspector binds to and the keyboard moves from.
    package private(set) var focus: VSidebarSelection

    /// Every selected camera. Contains ``focus``'s camera when it has one; empty for the non-camera
    /// rows, which are never part of a multi-selection.
    package private(set) var cameras: Set<CameraID>

    /// The camera a ⇧-click measures its range from.
    package private(set) var anchor: CameraID?

    // MARK: - Initialisation

    /// The launch state: the "Current Layout" row, nothing multi-selected.
    package init() {
        self.focus = .live
        self.cameras = []
        self.anchor = nil
    }

    /// Creates a state directly, for restoring or for a test.
    package init(focus: VSidebarSelection, cameras: Set<CameraID> = [], anchor: CameraID? = nil) {
        self.focus = focus
        self.cameras = cameras
        self.anchor = anchor
    }

    // MARK: - Reading

    /// Whether a camera is part of the selection.
    package func isSelected(_ camera: CameraID) -> Bool {
        cameras.contains(camera)
    }

    /// Whether a row is the one the inspector is bound to.
    package func isFocused(_ selection: VSidebarSelection) -> Bool {
        focus == selection
    }

    /// Whether more than one camera is selected, which is what enables the bulk actions.
    package var isMultiple: Bool {
        cameras.count > 1
    }

    /// The single selected camera, or `nil` when none or several are selected.
    package var singleCamera: CameraID? {
        cameras.count == 1 ? cameras.first : nil
    }

    // MARK: - Mutating

    /// A plain click, or a keyboard move, onto any row.
    ///
    /// Replaces the whole selection: a plain click never adds to a multi-selection, which is what
    /// makes it the reliable way to get back to one camera.
    package mutating func select(_ selection: VSidebarSelection) {
        focus = selection
        if let camera = selection.selectedCamera {
            cameras = [camera]
            anchor = camera
        } else {
            cameras = []
            anchor = nil
        }
    }

    /// ⌘-click on a camera row: adds it to, or removes it from, the selection.
    ///
    /// Removing the focused camera moves the focus to another selected camera when there is one, so
    /// the inspector never binds to a row that is no longer selected. When the last camera is
    /// deselected the focus falls back to the layout row rather than to nothing, because "no
    /// selection at all" is not a state the inspector can render.
    package mutating func toggle(_ camera: CameraID, in order: [CameraID]) {
        if cameras.contains(camera) {
            cameras.remove(camera)
            if focus == .camera(camera) {
                if let next = Self.firstPresent(of: order, in: cameras) {
                    focus = .camera(next)
                } else {
                    focus = .live
                }
            }
            if anchor == camera {
                anchor = Self.firstPresent(of: order, in: cameras)
            }
        } else {
            cameras.insert(camera)
            focus = .camera(camera)
            anchor = camera
        }
    }

    /// ⇧-click on a camera row: selects the contiguous run from the anchor to this row, inclusive.
    ///
    /// - Parameters:
    ///   - camera: the row clicked.
    ///   - order: the cameras in the order they are **displayed**, which is what "contiguous" means
    ///     to the user. Passing the library order instead would select a run the user cannot see
    ///     when a search or a filter is active.
    ///
    /// The range replaces the selection rather than adding to it, matching every macOS list. The
    /// anchor is left where it was, so a second ⇧-click grows or shrinks the same run instead of
    /// walking the anchor along behind the pointer — that walking behaviour is the one thing users
    /// notice as wrong in a hand-rolled list.
    package mutating func extend(to camera: CameraID, in order: [CameraID]) {
        guard let target = order.firstIndex(of: camera) else { return }
        // With no usable anchor the ⇧-click behaves as a plain click and establishes one.
        guard let anchor, let start = order.firstIndex(of: anchor) else {
            select(.camera(camera))
            return
        }
        let lower = Swift.min(start, target)
        let upper = Swift.max(start, target)
        cameras = Set(order[lower...upper])
        focus = .camera(camera)
        self.anchor = anchor
    }

    /// Selects every camera in the displayed order — `⌘A`.
    package mutating func selectAll(in order: [CameraID]) {
        guard let first = order.first else { return }
        cameras = Set(order)
        anchor = first
        if focus.selectedCamera == nil {
            focus = .camera(first)
        }
    }

    /// Drops the multi-selection down to the focused camera — `Esc` step 9 (UX.md §11.1).
    ///
    /// Returns `true` when something actually changed, so the caller knows whether to consume the
    /// key event or let `Esc` fall through to the next step of its precedence chain.
    package mutating func collapseMultiSelection() -> Bool {
        guard cameras.count > 1 else { return false }
        if let camera = focus.selectedCamera {
            cameras = [camera]
            anchor = camera
        } else {
            cameras = []
            anchor = nil
        }
        return true
    }

    /// The selection after a camera has been deleted from the library.
    ///
    /// DESIGN.md §10.2 #7: "when a focused camera goes offline or a focused row is deleted, focus
    /// moves to the nearest sibling". The nearest sibling is the row that took the deleted row's
    /// place, or the one before it when the deleted row was last — which is what a user expects
    /// after pressing ⌫ repeatedly.
    ///
    /// - Parameters:
    ///   - camera: the camera that has gone.
    ///   - order: the displayed order **before** the removal.
    package mutating func removing(_ camera: CameraID, from order: [CameraID]) {
        cameras.remove(camera)
        if anchor == camera { anchor = nil }
        guard focus == .camera(camera) else { return }
        guard let index = order.firstIndex(of: camera) else {
            focus = .live
            return
        }
        var remaining = order
        remaining.remove(at: index)
        guard !remaining.isEmpty else {
            focus = .live
            cameras = []
            return
        }
        let successor = remaining[Swift.min(index, remaining.count - 1)]
        focus = .camera(successor)
        if cameras.isEmpty {
            cameras = [successor]
            anchor = successor
        }
    }

    /// The cameras to act on for a context-menu command invoked on `camera`.
    ///
    /// Right-clicking a row inside a multi-selection acts on the whole selection; right-clicking a
    /// row outside it acts on that row alone and does **not** silently extend the selection. This is
    /// the behaviour every Mac list has, and getting it wrong means a user deletes six cameras when
    /// they meant one.
    package func actionTargets(for camera: CameraID) -> [CameraID] {
        guard cameras.contains(camera), cameras.count > 1 else { return [camera] }
        return Array(cameras)
    }

    /// The selected cameras in displayed order, which is what a bulk operation should apply in.
    package func orderedSelection(in order: [CameraID]) -> [CameraID] {
        order.filter { cameras.contains($0) }
    }

    /// The first member of `order` that is also in `set`.
    private static func firstPresent(of order: [CameraID], in set: Set<CameraID>) -> CameraID? {
        order.first { set.contains($0) }
    }
}

#endif  // os(macOS)
