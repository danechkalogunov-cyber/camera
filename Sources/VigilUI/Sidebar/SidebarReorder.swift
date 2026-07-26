//
//  SidebarReorder.swift
//  VigilUI
//
//  Drag-to-reorder arithmetic: where a drop lands, and what the list looks like afterwards. Pure
//  functions, because the index adjustment below is the single most reliable off-by-one in any
//  drag-reorder implementation and it is invisible until a user drags a row one place down.
//  macOS-only. Implements docs/UX.md §4.3 (reorder) and §10.2 #4 (⌥⌘↑/↓ keyboard equivalents).
//

#if os(macOS)

import Foundation

// MARK: - VSidebarDropPosition

/// Where a drag is hovering, which is what decides the insertion indicator's shape.
///
/// The three cases are visually distinct by design (UX.md §4.3): a 2 pt accent insertion line
/// between rows, a dashed accent stroke around a group row, and nothing at all when the drop is not
/// allowed. Making "not allowed" an explicit case rather than an optional means a caller cannot
/// accidentally render an indicator for a drop that will be rejected.
package enum VSidebarDropPosition: Sendable, Hashable {

    /// Insert before the row at this display index. `index == count` means "after the last row".
    case between(index: Int)

    /// Join the group whose row this is.
    case onGroup(index: Int)

    /// Nothing will happen. The ghost returns to its origin with `rubber` (UX.md §7.4 #37).
    case rejected
}

// MARK: - VSidebarReorder

/// Reorder arithmetic.
///
/// ## The index adjustment, stated once
///
/// Every drag-reorder API in Cocoa and SwiftUI — `onMove(perform:)`, `NSTableViewDataSource`,
/// `DropDelegate` — reports the destination as an index into the array **before** the dragged rows
/// are removed. Moving item 0 of `[a, b, c, d]` to "before index 3" must produce `[b, c, a, d]`, not
/// `[b, c, d, a]`: once `a` is taken out, the position that used to be index 3 is index 2.
///
/// The correction is to subtract the number of moved items that were located **before** the
/// destination:
///
///     insertionIndex = destination − (moved items whose original index < destination)
///
/// It is one line, it is wrong by exactly one in the most common case (dragging a row downwards by
/// one place), and it is the reason this arithmetic lives in a tested function instead of inside a
/// closure in a view.
package enum VSidebarReorder {

    // MARK: - Moving

    /// The list after moving some of its items.
    ///
    /// - Parameters:
    ///   - items: the list, in display order.
    ///   - moving: the items being dragged. Items not present in `items` are ignored. Their relative
    ///     order in the result follows `items`, not `moving`, so a multi-row drag keeps the order the
    ///     user could see rather than the order the drag happened to collect them in.
    ///   - destination: the index in the **pre-move** `items` that the block should land before.
    ///     `items.count` means "at the end". Out-of-range values are clamped.
    /// - Returns: the reordered list. Always a permutation of `items` — nothing is created or lost.
    package static func reordered<Item: Hashable>(_ items: [Item],
                                                  moving: [Item],
                                                  before destination: Int) -> [Item] {
        let movingSet = Set(moving)
        guard !movingSet.isEmpty else { return items }
        // Ordered by display position, so a multi-row drag preserves what the user saw.
        let block = items.filter { movingSet.contains($0) }
        guard !block.isEmpty else { return items }
        let target = Swift.min(Swift.max(destination, 0), items.count)
        // The correction described above.
        let movedBefore = items.prefix(target).reduce(into: 0) { total, item in
            if movingSet.contains(item) { total += 1 }
        }
        let remainder = items.filter { !movingSet.contains($0) }
        let insertion = Swift.min(Swift.max(target - movedBefore, 0), remainder.count)
        var out = Array(remainder[..<insertion])
        out.append(contentsOf: block)
        out.append(contentsOf: remainder[insertion...])
        return out
    }

    /// The post-removal insertion index for a pre-removal destination.
    ///
    /// Exposed on its own because the library protocol takes a pre-move destination while some
    /// callers hold a post-removal array; having both spellings in one place is what stops one of
    /// them being re-derived incorrectly at a call site.
    package static func insertionIndex<Item: Hashable>(in items: [Item],
                                                       moving: [Item],
                                                       before destination: Int) -> Int {
        let movingSet = Set(moving)
        let target = Swift.min(Swift.max(destination, 0), items.count)
        let movedBefore = items.prefix(target).reduce(into: 0) { total, item in
            if movingSet.contains(item) { total += 1 }
        }
        return Swift.max(target - movedBefore, 0)
    }

    /// Whether a move would actually change the order.
    ///
    /// Used to skip the 250 ms debounced persist (UX.md §4.3) and to avoid animating a list that is
    /// not moving — dropping a row back where it came from should look like nothing happened, because
    /// nothing did.
    package static func isNoOp<Item: Hashable>(_ items: [Item],
                                               moving: [Item],
                                               before destination: Int) -> Bool {
        reordered(items, moving: moving, before: destination) == items
    }

    // MARK: - Keyboard equivalents

    /// The destination for ⌥⌘↑ — move the selection one place towards the top.
    ///
    /// DESIGN.md §10.2 #4 requires a keyboard equivalent for every drag. Returns `nil` when the
    /// selection is already at the top, so the caller can decline the key rather than animating a
    /// move that does nothing.
    ///
    /// The destination is expressed in the pre-move coordinate system, like every other destination
    /// here, so it can be handed straight to ``reordered(_:moving:before:)``.
    package static func destinationForMoveUp<Item: Hashable>(_ items: [Item],
                                                             moving: [Item]) -> Int? {
        let movingSet = Set(moving)
        guard let first = items.firstIndex(where: { movingSet.contains($0) }) else { return nil }
        // Walk back past any other selected rows so a contiguous block moves as a block.
        var target = first - 1
        while target >= 0, movingSet.contains(items[target]) {
            target -= 1
        }
        return target >= 0 ? target : nil
    }

    /// The destination for ⌥⌘↓ — move the selection one place towards the bottom.
    package static func destinationForMoveDown<Item: Hashable>(_ items: [Item],
                                                               moving: [Item]) -> Int? {
        let movingSet = Set(moving)
        guard let last = items.lastIndex(where: { movingSet.contains($0) }) else { return nil }
        var target = last + 1
        while target < items.count, movingSet.contains(items[target]) {
            target += 1
        }
        // `target` is the row to move past, so the block lands *after* it: destination is one
        // further on in pre-move coordinates.
        return target < items.count ? target + 1 : nil
    }

    // MARK: - Drop indicator

    /// Which insertion index a pointer at `offset` inside a list of rows is proposing.
    ///
    /// - Parameters:
    ///   - offset: the pointer's distance from the top of the list's content.
    ///   - rowHeight: the uniform row height. Values ≤ 0 return `0` rather than dividing by zero.
    ///   - count: how many rows there are.
    /// - Returns: an index in `0...count`. The boundary is the row's midpoint, so the indicator
    ///   snaps to whichever gap is nearer — which is what makes a drop feel like it went where the
    ///   user aimed rather than where the row started.
    package static func insertionIndex(forOffset offset: CGFloat,
                                       rowHeight: CGFloat,
                                       count: Int) -> Int {
        guard rowHeight > 0, count > 0 else { return 0 }
        let raw = ((offset / rowHeight) + 0.5).rounded(.down)
        let clamped = Swift.min(Swift.max(raw, 0), CGFloat(count))
        return Int(clamped)
    }
}

#endif  // os(macOS)
