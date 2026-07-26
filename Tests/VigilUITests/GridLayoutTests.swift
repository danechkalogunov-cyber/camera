//
//  GridLayoutTests.swift
//  VigilUITests
//
//  The stage's layout table: cell counts, well-formedness, coverage, and the ⌘-digit map. These are
//  the numbers a wrong tile count or a misplaced hero comes from.
//  Covers Sources/VigilUI/Grid/GridLayout.swift; see docs/UX.md §5.1.
//

#if os(macOS)

import Testing

@testable import VigilUI

// MARK: - Tile counts

/// The four uniform steps are the 1 / 4 / 9 / 16 the brief names.
@Test func gridLayoutUniformStepsHaveTheExpectedTileCounts() {
    #expect(VGridLayout.single.tileCount == 1)
    #expect(VGridLayout.grid2x2.tileCount == 4)
    #expect(VGridLayout.grid3x3.tileCount == 9)
    #expect(VGridLayout.grid4x4.tileCount == 16)
    #expect(VGridLayout.uniformSteps == [.single, .grid2x2, .grid3x3, .grid4x4])
}

/// The hero layouts have the counts their names claim: 1+5 = 6, 1+7 = 8, 2+8 = 10.
@Test func gridLayoutHeroStepsHaveTheExpectedTileCounts() {
    #expect(VGridLayout.hero1p5.tileCount == 6)
    #expect(VGridLayout.hero1p7.tileCount == 8)
    #expect(VGridLayout.dual2p8.tileCount == 10)
}

/// The mockup's stage is nine tiles: a 2 × 2 hero plus eight, in a 4 × 3 cell arrangement.
///
/// `design/mockups/01-main-window.html` renders `repeat(4, 1fr) × repeat(3, 1fr)` with the hero at
/// `grid-column: 1/3; grid-row: 1/3`. Columns are three units wide and rows four units tall, so the
/// hero is 6 × 8 units and every other cell is 3 × 4.
@Test func gridLayoutMosaicMatchesTheApprovedMockup() throws {
    let layout = VGridLayout.mosaic4x3
    #expect(layout.tileCount == 9)
    let cells = layout.cells
    let hero = try #require(cells.first)
    #expect(hero == VLayoutRect(x: 0, y: 0, w: 6, h: 8))
    #expect(cells.dropFirst().allSatisfy { $0.w == 3 && $0.h == 4 })
    // Four columns at 0, 3, 6, 9 and three rows at 0, 4, 8.
    #expect(Set(cells.dropFirst().map(\.x)) == [0, 3, 6, 9])
    #expect(Set(cells.dropFirst().map(\.y)) == [0, 4, 8])
    // The hero's own cells are not also handed out as single tiles.
    #expect(!cells.dropFirst().contains { $0.x < 6 && $0.y < 8 })
}

// MARK: - Well-formedness

/// No layout puts a cell outside the grid or on top of another cell.
///
/// This is the invariant that a hand-written rectangle table gets wrong, and it is cheap to prove
/// for all eight layouts at once rather than trusting the arithmetic by eye.
@Test func gridLayoutEveryLayoutIsWellFormed() {
    for layout in VGridLayout.allCases {
        #expect(layout.isWellFormed, "\(layout.rawValue) is not well formed")
    }
}

/// Every layout tiles the 12 × 12 grid completely — 144 units, no gap and no overlap.
///
/// A layout that covered less than 144 would leave a strip of bare canvas at an edge, which reads
/// as a misaligned stage rather than as a design.
@Test func gridLayoutEveryLayoutCoversTheWholeGrid() {
    for layout in VGridLayout.allCases {
        #expect(layout.coveredArea == 144, "\(layout.rawValue) covers \(layout.coveredArea)")
    }
}

/// Cell order is row-major for the uniform grids, which is what makes ⇥ order read naturally.
@Test func gridLayoutUniformCellsAreRowMajor() {
    let cells = VGridLayout.grid3x3.cells
    #expect(cells.count == 9)
    #expect(cells[0] == VLayoutRect(x: 0, y: 0, w: 4, h: 4))
    #expect(cells[1] == VLayoutRect(x: 4, y: 0, w: 4, h: 4))
    #expect(cells[2] == VLayoutRect(x: 8, y: 0, w: 4, h: 4))
    #expect(cells[3] == VLayoutRect(x: 0, y: 4, w: 4, h: 4))
    #expect(cells[8] == VLayoutRect(x: 8, y: 8, w: 4, h: 4))
}

/// The hero is always cell 0, so slot 0 means "the primary position" in every layout.
@Test func gridLayoutHeroIsAlwaysTheFirstCell() throws {
    for layout in [VGridLayout.hero1p5, .hero1p7, .mosaic4x3] {
        let cells = layout.cells
        let hero = try #require(cells.first)
        for other in cells.dropFirst() {
            #expect(hero.w >= other.w && hero.h >= other.h,
                    "\(layout.rawValue): cell 0 is not the largest")
        }
    }
    #expect(VGridLayout.hero1p5.hasHero)
    #expect(!VGridLayout.grid3x3.hasHero)
    #expect(!VGridLayout.single.hasHero)
}

// MARK: - Shortcuts

/// ⌘-digits follow the picker's order, **not** the tile count: ⌘2 is four tiles, ⌘4 is nine.
///
/// Pinned because reading the digits as counts would put the wrong layout on every shortcut, and
/// nothing else in the code would look wrong.
@Test func gridLayoutShortcutDigitsFollowPickerOrderNotTileCount() {
    #expect(VGridLayout.single.shortcutDigit == "1")
    #expect(VGridLayout.grid2x2.shortcutDigit == "2")
    #expect(VGridLayout.hero1p5.shortcutDigit == "3")
    #expect(VGridLayout.grid3x3.shortcutDigit == "4")
    #expect(VGridLayout.grid4x4.shortcutDigit == "5")
    #expect(VGridLayout.layout(forShortcutDigit: "4") == .grid3x3)
    #expect(VGridLayout.layout(forShortcutDigit: "9") == nil)
    #expect(VGridLayout.layout(forShortcutDigit: "x") == nil)
}

/// Every layout has a distinct digit, so no shortcut is ambiguous.
@Test func gridLayoutShortcutDigitsAreUnique() {
    let digits = VGridLayout.allCases.map(\.shortcutDigit)
    #expect(Set(digits).count == digits.count)
}

/// Raw values match UX.md §5.1's `LayoutMode` spelling, so a persisted layout needs no mapping.
@Test func gridLayoutRawValuesMatchTheDocumentedPersistenceNames() {
    #expect(VGridLayout.single.rawValue == "single")
    #expect(VGridLayout.grid2x2.rawValue == "grid2x2")
    #expect(VGridLayout.hero1p5.rawValue == "hero1p5")
    #expect(VGridLayout.grid3x3.rawValue == "grid3x3")
    #expect(VGridLayout.grid4x4.rawValue == "grid4x4")
    #expect(VGridLayout.hero1p7.rawValue == "hero1p7")
    #expect(VGridLayout.dual2p8.rawValue == "dual2p8")
}

// MARK: - VLayoutRect

/// A zero or negative span becomes one unit rather than a zero-sized tile.
@Test func gridLayoutRectClampsSpansToAtLeastOneUnit() {
    let rect = VLayoutRect(x: 2, y: 3, w: 0, h: -4)
    #expect(rect.w == 1)
    #expect(rect.h == 1)
    #expect(rect.x == 2)
    #expect(rect.y == 3)
}

/// Centres are held doubled so the arithmetic stays integral for odd spans.
@Test func gridLayoutRectDoubledCentreIsExactForOddSpans() {
    // A 3 × 3 cell at the origin centres on (1.5, 1.5) — doubled, (3, 3).
    #expect(VLayoutRect(x: 0, y: 0, w: 3, h: 3).doubledCentre == (x: 3, y: 3))
    #expect(VLayoutRect(x: 0, y: 0, w: 12, h: 12).doubledCentre == (x: 12, y: 12))
    #expect(VLayoutRect(x: 9, y: 6, w: 3, h: 3).doubledCentre == (x: 21, y: 15))
}

/// Overlap is exclusive at the shared edge: two cells that merely touch do not overlap.
@Test func gridLayoutRectOverlapTreatsSharedEdgesAsDisjoint() {
    let left = VLayoutRect(x: 0, y: 0, w: 6, h: 6)
    let right = VLayoutRect(x: 6, y: 0, w: 6, h: 6)
    let below = VLayoutRect(x: 0, y: 6, w: 6, h: 6)
    let straddling = VLayoutRect(x: 5, y: 0, w: 6, h: 6)
    #expect(!left.overlaps(right))
    #expect(!left.overlaps(below))
    #expect(left.overlaps(straddling))
    #expect(left.overlaps(left))
}

/// A rect that runs off the 12-unit grid is rejected, which is what validates a custom mosaic.
@Test func gridLayoutRectDetectsOffGridRectangles() {
    #expect(VLayoutRect(x: 0, y: 0, w: 12, h: 12).isInsideGrid)
    #expect(VLayoutRect(x: 9, y: 9, w: 3, h: 3).isInsideGrid)
    #expect(!VLayoutRect(x: 10, y: 0, w: 3, h: 3).isInsideGrid)
    #expect(!VLayoutRect(x: 0, y: 10, w: 3, h: 3).isInsideGrid)
    #expect(!VLayoutRect(x: -1, y: 0, w: 3, h: 3).isInsideGrid)
}

#endif
