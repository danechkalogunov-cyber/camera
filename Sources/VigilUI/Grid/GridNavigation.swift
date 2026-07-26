//
//  GridNavigation.swift
//  VigilUI
//
//  Keyboard movement across the stage: the spatial rule for ⌥-arrows and the index rule for ⇥.
//  Pure functions over a layout, so the behaviour that decides whether the keyboard feels right is
//  testable without a window.
//  macOS-only. Implements docs/UX.md §5.7 (⌥-arrow geometry, no wrapping, ⇥ order) and
//  docs/DESIGN.md §10.2 #5 ("spatially, not by index … so a 1+5 mosaic behaves as it looks").
//

#if os(macOS)

import Foundation

// MARK: - VGridDirection

/// One arrow key, as used with `⌥` to move tile focus.
///
/// ⚠ Arrow keys **without** `⌥` drive PTZ on the focused tile (UX.md §5.7). That is the whole reason
/// tile navigation is modified, and it is why this type is not named after bare arrow keys.
package enum VGridDirection: Sendable, Hashable, CaseIterable {

    /// `⌥←`
    case left

    /// `⌥→`
    case right

    /// `⌥↑`
    case up

    /// `⌥↓`
    case down

    /// Whether the direction moves along the x axis.
    package var isHorizontal: Bool {
        self == .left || self == .right
    }

    /// The sign of movement along the direction's own axis.
    package var sign: Int {
        switch self {
        case .left, .up: return -1
        case .right, .down: return 1
        }
    }
}

// MARK: - VGridNavigator

/// Keyboard movement between tiles.
///
/// ## The spatial rule, and why it is not "index ± 1"
///
/// UX.md §5.7 specifies ⌥-arrow movement geometrically: the candidates are the cells whose centre
/// lies in the half-plane of the direction, and the winner minimises
/// `primaryAxisDistance + 0.35 × perpendicularOffset`. DESIGN.md §10.2 #5 gives the reason in one
/// line — "so a 1+5 mosaic behaves as it looks". An index-based rule is indistinguishable from the
/// spatial one on a uniform grid and completely wrong on a hero layout, where `→` from the hero
/// would land on whichever cell happened to be next in the array rather than on the cell the user
/// is looking at.
///
/// The `0.35` weight is what makes the rule prefer the cell most nearly straight ahead while still
/// allowing a diagonal when nothing is directly in line. It is applied here as integer arithmetic —
/// centres are held doubled (``VLayoutRect/doubledCentre``) and the cost is scaled by 100 — so the
/// comparison is exact and the tests are deterministic rather than nearly deterministic.
///
/// **Movement does not wrap.** `→` on the trailing column returns `nil`. Wrapping to the next row is
/// how a list behaves, not how a grid of camera views behaves: an operator holding `→` to scan a row
/// expects it to stop, and a wrap would silently move their eye a row down while the picture under
/// it changed. UX.md §5.7 asks for a 3 pt nudge at the bump instead; returning `nil` is what lets
/// the caller play it.
///
/// Every cell is reachable, including the ones past the last camera: those render the "Add camera"
/// placeholder, which is an action, and an action a mouse can reach must have a keyboard path.
package struct VGridNavigator: Sendable {

    // MARK: - Stored Properties

    /// The arrangement being navigated.
    package let layout: VGridLayout

    /// ``VGridLayout/cells``, resolved once. Every move scans them, so recomputing the array per
    /// candidate would make a key press quadratic in the tile count for no reason.
    private let cells: [VLayoutRect]

    // MARK: - Initialisation

    /// Creates a navigator for a layout.
    package init(layout: VGridLayout) {
        self.layout = layout
        self.cells = layout.cells
    }

    // MARK: - Public API

    /// How many tiles there are to move between.
    package var tileCount: Int {
        cells.count
    }

    /// The cell index reached by pressing an ⌥-arrow.
    ///
    /// - Parameters:
    ///   - index: the cell focus is on. Out-of-range values return `nil`.
    ///   - direction: the arrow pressed.
    /// - Returns: the cell to move to, or `nil` when nothing lies in that direction — in which case
    ///   the caller should play the bump nudge and **not** consume the key event, so `⌥→` at the
    ///   trailing edge can still hand focus onwards.
    package func move(from index: Int, _ direction: VGridDirection) -> Int? {
        guard index >= 0, index < cells.count else { return nil }
        let source = cells[index]
        let origin = source.doubledCentre
        // Two passes over one gathered list: prefer candidates that the source actually faces, and
        // fall back to the unrestricted half-plane only when it faces nothing. See `isFacing`.
        var facing: (index: Int, cost: Int)?
        var anywhere: (index: Int, cost: Int)?
        for (candidate, rect) in cells.enumerated() where candidate != index {
            let centre = rect.doubledCentre
            // Measured along the direction's own sign, so a candidate behind the origin has a
            // negative advance and is discarded by the half-plane test.
            let advance: Int
            let perpendicular: Int
            if direction.isHorizontal {
                advance = (centre.x - origin.x) * direction.sign
                perpendicular = abs(centre.y - origin.y)
            } else {
                advance = (centre.y - origin.y) * direction.sign
                perpendicular = abs(centre.x - origin.x)
            }
            guard advance > 0 else { continue }
            // 100 × primary + 35 × perpendicular is `primary + 0.35 × perpendicular` without a
            // float, so ties break identically on every run — and towards the lower index, which is
            // the upper or leading tile, because `>=` keeps the incumbent.
            let cost = advance * 100 + perpendicular * 35
            if anywhere.map({ cost < $0.cost }) ?? true {
                anywhere = (index: candidate, cost: cost)
            }
            guard Self.isFacing(source, rect, along: direction) else { continue }
            if facing.map({ cost < $0.cost }) ?? true {
                facing = (index: candidate, cost: cost)
            }
        }
        return (facing ?? anywhere)?.index
    }

    /// Whether `candidate` lies within the band `source` sweeps as it moves along `direction`.
    ///
    /// ## Why this restriction is here, given that UX.md §5.7 does not state it
    ///
    /// The documented rule — half-plane, then minimise
    /// `primaryAxisDistance + 0.35 × perpendicularOffset` — is exact on a uniform grid and produces
    /// one surprising result on a hero layout, because a *nearer but offset* cell can beat a
    /// *farther but aligned* one. In `hero1p7`, ⌥↓ from the hero would land on the bottom tile of the
    /// trailing column: its centre is only 3 units below the hero's, so its primary distance of 6
    /// (doubled) beats the bottom row's 12 even after the 0.35 penalty on being 6 units off to the
    /// side. Focus would jump diagonally out of the hero when the user pressed *down*.
    ///
    /// DESIGN.md §10.2 #5 states the requirement the formula is meant to satisfy — ⌥-arrows move
    /// "spatially … so a 1+5 mosaic behaves as it looks" — so the formula is kept exactly as
    /// written and used as the *tiebreaker*, with candidates first restricted to the ones the source
    /// tile actually faces. On a uniform grid this changes nothing at all: an aligned neighbour
    /// always overlaps. On a hero layout it is the difference between down meaning down and down
    /// meaning down-and-slightly-right.
    ///
    /// The fallback matters too: a tile at the trailing edge of a row faces nothing directly below
    /// it in some custom mosaics, and in that case the unrestricted rule is better than refusing to
    /// move.
    private static func isFacing(_ source: VLayoutRect,
                                 _ candidate: VLayoutRect,
                                 along direction: VGridDirection) -> Bool {
        if direction.isHorizontal {
            return candidate.y < source.y + source.h && source.y < candidate.y + candidate.h
        }
        return candidate.x < source.x + source.w && source.x < candidate.x + candidate.w
    }

    /// The first cell, for `Home`.
    package var firstIndex: Int? {
        cells.isEmpty ? nil : 0
    }

    /// The last cell, for `End`.
    package var lastIndex: Int? {
        cells.isEmpty ? nil : cells.count - 1
    }

    /// The next cell in `⇥` order, which is cell-index order.
    ///
    /// Returns `nil` at the end rather than wrapping, because `⇥` past the last tile has to reach
    /// the inspector (UX.md §5.7).
    package func next(after index: Int) -> Int? {
        let candidate = index + 1
        return candidate < cells.count ? candidate : nil
    }

    /// The previous cell in `⇧⇥` order. `nil` before the first, which hands focus to the sidebar.
    package func previous(before index: Int) -> Int? {
        let candidate = index - 1
        return candidate >= 0 && candidate < cells.count ? candidate : nil
    }

    /// The cell nearest an index that no longer exists, after a layout change shrank the grid.
    ///
    /// DESIGN.md §10.2 #7: "Focus is never lost." A layout change from sixteen tiles to four leaves
    /// a focused index of 11 pointing at nothing, and the honest answer is the last tile rather than
    /// no focus at all.
    package func clamped(_ index: Int) -> Int? {
        guard !cells.isEmpty else { return nil }
        return Swift.min(Swift.max(index, 0), cells.count - 1)
    }
}

#endif  // os(macOS)
