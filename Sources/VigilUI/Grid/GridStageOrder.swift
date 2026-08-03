//
//  GridStageOrder.swift
//  VigilUI
//
//  Which cameras the stage shows, and in what order.
//  macOS-only. Implements docs/UX.md §1.3 (a selected group opens into the stage) and §5.1.
//
//  ⛔ THIS LIVES HERE SO IT CAN BE TESTED. It was written inline in `MainWindowView`, in the app
//  target, which has no test bundle — and it shipped with a latent crash that reading caught and no
//  test could have: the "streaming camera first" rule was expressed as
//  `sorted { left, _ in left == live }`, which is not a strict weak ordering. Swift's introsort is
//  entitled to treat that as undefined and traps with "not a valid strict weak ordering" once the
//  array is long enough to leave the insertion-sort path, so a library of four looked correct and
//  one of thirty would have taken the window down. `GridStageOrderTests` pins that at thirty.
//

#if os(macOS)

import Foundation

import VigilProtocols

// MARK: - VStageOrder

/// The stage's camera order, as a pure function of the library and the current selection.
@MainActor
package enum VStageOrder {

    /// Every camera that belongs on the stage, streaming one first.
    ///
    /// - Parameters:
    ///   - library: the user's cameras, in the order they arranged them.
    ///   - live: the camera that currently has a session. Included even when the library does not
    ///     hold it yet — it is filed on its first frame, and until then it is still what is on
    ///     screen, so a stage that omitted it would show a picture in no cell.
    ///   - isInSelectedGroup: membership test for the selected group, or `nil` when no group is
    ///     selected. Passed as a predicate so this stays free of the group store: the rule is about
    ///     ordering, not about where membership is kept.
    /// - Returns: the cameras to assign to cells. May be empty — a selected group with no members
    ///   is an empty stage, which is the honest answer rather than showing every camera and making
    ///   the GROUPS section decorative.
    package static func resolve(library: [CameraID],
                                live: CameraID,
                                isInSelectedGroup: ((CameraID) -> Bool)? = nil) -> [CameraID] {
        var ids = library
        if !ids.contains(live) { ids.insert(live, at: 0) }
        if let isInSelectedGroup {
            ids = ids.filter(isInSelectedGroup)
        }
        // ⛔ Partitioned with two filters, never `sorted(by:)`. See the file header: the obvious
        // comparator is not a strict weak ordering and traps at scale. This spelling is also stable,
        // which the comparator was not — two idle cameras keep their library order.
        return ids.filter { $0 == live } + ids.filter { $0 != live }
    }
}

#endif  // os(macOS)
