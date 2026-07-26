//
//  GridLayout.swift
//  VigilUI
//
//  The stage's layout vocabulary, as unit rectangles on a 12 × 12 grid. Pure arithmetic — no
//  SwiftUI, no VTheme — because an off-by-one here is a visibly misaligned seam, and this is the
//  one part of the grid that can be tested on any platform.
//  macOS-only. Implements docs/UX.md §5.1 (layout modes, the 12 × 12 unit grid) with the geometry
//  tokens from docs/DESIGN.md §5.1 (gutter 2 pt, stage inset 8 pt).
//

#if os(macOS)

import Foundation

// MARK: - VLayoutRect

/// One tile's rectangle in **unit** coordinates on the 12 × 12 grid.
///
/// Units, not points, are what UX.md §5.1 makes the persistable format, and the reason is worth
/// keeping in view: every layout — including a user's custom mosaic — is then the same kind of value,
/// so one geometry routine serves all of them and a saved layout survives any window size.
package struct VLayoutRect: Sendable, Hashable, Codable {

    /// Leading edge, `0…12`.
    package let x: Int

    /// Top edge, `0…12`.
    package let y: Int

    /// Width in units, `≥ 1`.
    package let w: Int

    /// Height in units, `≥ 1`.
    package let h: Int

    /// Creates a unit rectangle. Spans are clamped to at least one unit so no tile can be
    /// zero-sized; the values are otherwise taken as given, because validation of a *set* of rects
    /// (overlap, coverage) is the layout's business and not a single rect's.
    package init(x: Int, y: Int, w: Int, h: Int) {
        self.x = x
        self.y = y
        self.w = Swift.max(1, w)
        self.h = Swift.max(1, h)
    }

    /// The centre, in units, doubled — so it stays an `Int` and comparisons are exact.
    ///
    /// Halving would make `(0, 0, 3, 3)` centre on `1.5` and invite a float comparison into
    /// keyboard navigation. Doubling keeps the arithmetic integral, which is what makes the
    /// navigation tests deterministic rather than nearly deterministic.
    package var doubledCentre: (x: Int, y: Int) {
        (x: 2 * x + w, y: 2 * y + h)
    }

    /// Whether two rectangles overlap. Used to validate a custom mosaic.
    package func overlaps(_ other: VLayoutRect) -> Bool {
        x < other.x + other.w && other.x < x + w && y < other.y + other.h && other.y < y + h
    }

    /// Whether the rectangle lies inside the 12 × 12 grid.
    package var isInsideGrid: Bool {
        x >= 0 && y >= 0 && x + w <= VGridLayout.units && y + h <= VGridLayout.units
    }
}

// MARK: - VGridLayout

/// How many tiles the stage shows, and where each one sits.
///
/// ## Why a unit grid rather than rows × columns
///
/// A rows × columns model cannot express the layouts the design actually asks for. The approved
/// mockup (`design/shots/01-main-window.png`, generated from `design/mockups/01-main-window.html`)
/// lays the stage out as `repeat(4, 1fr) × repeat(3, 1fr)` with the selected tile at
/// `grid-column: 1/3; grid-row: 1/3` — a spanning hero. UX.md §5.1 generalises that to eight modes
/// on a 12 × 12 unit grid, and 12 is chosen because it divides by 2, 3 **and** 4, so the uniform
/// 2 × 2, 3 × 3 and 4 × 4 grids all land on exact unit boundaries with no remainder.
///
/// The four uniform steps the slice brief names — 1 / 4 / 9 / 16 — are ``single``, ``grid2x2``,
/// ``grid3x3`` and ``grid4x4``. The hero layouts are the same arithmetic with one larger rectangle.
///
/// Raw values match UX.md §5.1's `LayoutMode` spelling exactly, so persisting a layout and reading
/// it back through `VigilCore` later needs no mapping table.
package enum VGridLayout: String, Sendable, Hashable, CaseIterable, Identifiable, Codable {

    /// One tile filling the stage. `⌘1`.
    case single

    /// 2 × 2, four tiles. `⌘2`.
    case grid2x2

    /// A 2 × 2-of-3 hero plus five: six tiles. `⌘3`. The layout the picker's third icon draws.
    case hero1p5

    /// 3 × 3, nine tiles. `⌘4`.
    case grid3x3

    /// 4 × 4, sixteen tiles. `⌘5`.
    case grid4x4

    /// A larger hero plus seven: eight tiles. `⌘6`.
    case hero1p7

    /// Two heroes over eight: ten tiles. `⌘7`.
    case dual2p8

    /// 4 × 3 cells with a 2 × 2 hero: nine tiles. The arrangement the approved mockup renders.
    case mosaic4x3

    /// Stable identity for `ForEach`.
    package var id: String { rawValue }

    /// The grid is 12 units on each axis (UX.md §5.1).
    package static let units = 12

    // MARK: - Cells

    /// Every tile's unit rectangle, in **cell order** — which is tab order, digit order, and the
    /// order cameras are assigned into.
    ///
    /// A hero is always first, so slot 0 is the position a primary camera occupies in every layout.
    ///
    /// Cheap (at most sixteen small structs) but not free: compute it once per layout change and
    /// pass it down rather than calling it inside a per-tile `body`.
    package var cells: [VLayoutRect] {
        switch self {
        case .single:
            return [VLayoutRect(x: 0, y: 0, w: 12, h: 12)]
        case .grid2x2:
            return Self.uniform(divisions: 2)
        case .grid3x3:
            return Self.uniform(divisions: 3)
        case .grid4x4:
            return Self.uniform(divisions: 4)
        case .hero1p5:
            // Hero 8 × 8, two 4 × 4 down the trailing edge, three 4 × 4 along the bottom.
            return [
                VLayoutRect(x: 0, y: 0, w: 8, h: 8),
                VLayoutRect(x: 8, y: 0, w: 4, h: 4),
                VLayoutRect(x: 8, y: 4, w: 4, h: 4),
                VLayoutRect(x: 0, y: 8, w: 4, h: 4),
                VLayoutRect(x: 4, y: 8, w: 4, h: 4),
                VLayoutRect(x: 8, y: 8, w: 4, h: 4),
            ]
        case .hero1p7:
            // Hero 9 × 9, three 3 × 3 down the trailing edge, four 3 × 3 along the bottom.
            return [
                VLayoutRect(x: 0, y: 0, w: 9, h: 9),
                VLayoutRect(x: 9, y: 0, w: 3, h: 3),
                VLayoutRect(x: 9, y: 3, w: 3, h: 3),
                VLayoutRect(x: 9, y: 6, w: 3, h: 3),
                VLayoutRect(x: 0, y: 9, w: 3, h: 3),
                VLayoutRect(x: 3, y: 9, w: 3, h: 3),
                VLayoutRect(x: 6, y: 9, w: 3, h: 3),
                VLayoutRect(x: 9, y: 9, w: 3, h: 3),
            ]
        case .dual2p8:
            // Two 6 × 6 heroes over two rows of four 3 × 3.
            var out = [VLayoutRect(x: 0, y: 0, w: 6, h: 6), VLayoutRect(x: 6, y: 0, w: 6, h: 6)]
            for row in 0..<2 {
                for column in 0..<4 {
                    out.append(VLayoutRect(x: column * 3, y: 6 + row * 3, w: 3, h: 3))
                }
            }
            return out
        case .mosaic4x3:
            // Four columns of 3 units, three rows of 4 units, with a 2 × 2-cell hero. This is the
            // mockup's stage: `repeat(4, 1fr) × repeat(3, 1fr)` with the hero at 1/3 × 1/3.
            var out = [VLayoutRect(x: 0, y: 0, w: 6, h: 8)]
            for row in 0..<3 {
                for column in 0..<4 {
                    if row < 2 && column < 2 { continue }
                    out.append(VLayoutRect(x: column * 3, y: row * 4, w: 3, h: 4))
                }
            }
            return out
        }
    }

    /// A uniform `divisions × divisions` grid, row-major.
    ///
    /// `12 / divisions` is exact for 1, 2, 3 and 4, which is the whole reason the unit grid is 12
    /// units wide. A `divisions` that does not divide 12 would leave a gap at the trailing edge, so
    /// only the four that do are ever passed in.
    private static func uniform(divisions: Int) -> [VLayoutRect] {
        let step = units / divisions
        var out: [VLayoutRect] = []
        out.reserveCapacity(divisions * divisions)
        for row in 0..<divisions {
            for column in 0..<divisions {
                out.append(VLayoutRect(x: column * step, y: row * step, w: step, h: step))
            }
        }
        return out
    }

    /// How many tiles this layout shows.
    package var tileCount: Int {
        cells.count
    }

    /// Whether the layout's first cell is larger than its others.
    package var hasHero: Bool {
        guard let first = cells.first else { return false }
        return cells.dropFirst().contains { $0.w < first.w || $0.h < first.h }
    }

    // MARK: - Validity

    /// Whether every cell is inside the grid and no two cells overlap.
    ///
    /// The built-in layouts all satisfy this by construction; the check exists so a test can prove
    /// that rather than assume it, and so a user's custom mosaic can be validated by the same rule
    /// (UX.md §5.2 rejects overlaps and off-grid rects).
    package var isWellFormed: Bool {
        let all = cells
        guard all.allSatisfy(\.isInsideGrid) else { return false }
        for (index, rect) in all.enumerated() {
            for other in all[all.index(after: index)...] where rect.overlaps(other) {
                return false
            }
        }
        return true
    }

    /// The total unit area the cells cover. `144` when the layout tiles the grid completely.
    package var coveredArea: Int {
        cells.reduce(into: 0) { $0 += $1.w * $1.h }
    }

    // MARK: - Picker

    /// The four uniform steps the slice brief names, in ascending tile count.
    package static let uniformSteps: [VGridLayout] = [.single, .grid2x2, .grid3x3, .grid4x4]

    /// The layouts the toolbar picker offers, in the order the mockup shows them: one, four, the
    /// hero, then nine.
    package static let pickerSteps: [VGridLayout] = [.single, .grid2x2, .hero1p5, .grid3x3]

    /// The digit that selects this layout with `⌘`, per UX.md §5.1.
    ///
    /// ⚠ The digit is **not** the tile count: `⌘2` is the four-tile grid and `⌘3` is the six-tile
    /// hero, because the digits follow the picker's order rather than arithmetic. Getting this
    /// backwards would put the wrong layout on every shortcut, so it is stated here once.
    package var shortcutDigit: Character {
        switch self {
        case .single: return "1"
        case .grid2x2: return "2"
        case .hero1p5: return "3"
        case .grid3x3: return "4"
        case .grid4x4: return "5"
        case .hero1p7: return "6"
        case .dual2p8: return "7"
        case .mosaic4x3: return "8"
        }
    }

    /// The layout a `⌘`-digit selects, or `nil` when the digit is not a layout shortcut.
    package static func layout(forShortcutDigit digit: Character) -> VGridLayout? {
        allCases.first { $0.shortcutDigit == digit }
    }
}

#endif  // os(macOS)
