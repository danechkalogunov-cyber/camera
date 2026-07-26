//
//  GridNavigationTests.swift
//  VigilUITests
//
//  ⌥-arrow movement. The spatial rule is only distinguishable from an index rule on a hero layout,
//  which is exactly where an index rule sends focus to a tile the user is not looking at — so the
//  hero cases carry most of the weight here.
//  Covers Sources/VigilUI/Grid/GridNavigation.swift; see docs/UX.md §5.7, docs/DESIGN.md §10.2 #5.
//

#if os(macOS)

import Testing

@testable import VigilUI

// MARK: - Uniform grids

/// On a 3 × 3 the four directions behave exactly as the grid looks.
@Test func gridNavigatorMovesOrthogonallyOnAUniformGrid() {
    let navigator = VGridNavigator(layout: .grid3x3)
    // Indices: 0 1 2 / 3 4 5 / 6 7 8, centre is 4.
    #expect(navigator.move(from: 4, .left) == 3)
    #expect(navigator.move(from: 4, .right) == 5)
    #expect(navigator.move(from: 4, .up) == 1)
    #expect(navigator.move(from: 4, .down) == 7)
}

/// Movement never wraps: an edge returns `nil` so the caller can nudge and pass the key on.
@Test func gridNavigatorDoesNotWrapAtAnyEdge() {
    let navigator = VGridNavigator(layout: .grid3x3)
    #expect(navigator.move(from: 0, .left) == nil)
    #expect(navigator.move(from: 0, .up) == nil)
    #expect(navigator.move(from: 2, .right) == nil)
    #expect(navigator.move(from: 6, .left) == nil)
    #expect(navigator.move(from: 8, .right) == nil)
    #expect(navigator.move(from: 8, .down) == nil)
    // The end of a row does not fall through to the start of the next.
    #expect(navigator.move(from: 5, .right) == nil)
    #expect(navigator.move(from: 3, .left) == nil)
}

/// A 4 × 4 walk across the whole grid lands where arithmetic says it should.
@Test func gridNavigatorTraversesAFourByFourGridConsistently() {
    let navigator = VGridNavigator(layout: .grid4x4)
    for row in 0..<4 {
        for column in 0..<4 {
            let index = row * 4 + column
            #expect(navigator.move(from: index, .right) == (column < 3 ? index + 1 : nil))
            #expect(navigator.move(from: index, .left) == (column > 0 ? index - 1 : nil))
            #expect(navigator.move(from: index, .down) == (row < 3 ? index + 4 : nil))
            #expect(navigator.move(from: index, .up) == (row > 0 ? index - 4 : nil))
        }
    }
}

/// The single layout has nowhere to go in any direction.
@Test func gridNavigatorSingleLayoutHasNoMoves() {
    let navigator = VGridNavigator(layout: .single)
    for direction in VGridDirection.allCases {
        #expect(navigator.move(from: 0, direction) == nil)
    }
    #expect(navigator.tileCount == 1)
}

// MARK: - Hero layouts, where the spatial rule earns its keep

/// Leaving the 1+5 hero rightwards reaches the tile beside it, not the next array element.
///
/// `hero1p5` cells are: 0 hero (0,0,8,8), 1 (8,0,4,4), 2 (8,4,4,4), 3 (0,8,4,4), 4 (4,8,4,4),
/// 5 (8,8,4,4). The hero's centre is (4,4) in units. Rightwards, cells 1 and 2 are both candidates
/// at the same x; cell 1's centre (10,2) is 2 units off-axis and cell 2's (10,6) is also 2 — a tie,
/// broken towards the lower index, which is the upper tile. That is the readable answer.
@Test func gridNavigatorLeavesTheHeroRightwardsToTheAdjacentColumn() {
    let navigator = VGridNavigator(layout: .hero1p5)
    let right = navigator.move(from: 0, .right)
    #expect(right == 1)
    #expect(navigator.move(from: 0, .down) == 3)
    #expect(navigator.move(from: 0, .up) == nil)
    #expect(navigator.move(from: 0, .left) == nil)
}

/// Coming back into the hero from any of its neighbours lands on the hero.
@Test func gridNavigatorReturnsIntoTheHeroFromEveryNeighbour() {
    let navigator = VGridNavigator(layout: .hero1p5)
    #expect(navigator.move(from: 1, .left) == 0)
    #expect(navigator.move(from: 2, .left) == 0)
    #expect(navigator.move(from: 3, .up) == 0)
    #expect(navigator.move(from: 4, .up) == 0)
}

/// The 1+7 hero behaves the same way with three tiles down its trailing edge.
///
/// Cells: 0 hero (0,0,9,9); 1…3 at x = 9, y = 0/3/6; 4…7 at y = 9, x = 0/3/6/9.
///
/// ⌥↓ from the hero is the case that motivates the facing restriction in `VGridNavigator`: without
/// it, cell 3 — only 3 units lower but 6 units to the side — would win on raw cost and focus would
/// leave the hero diagonally. With it, the candidates are the bottom-row tiles the hero actually
/// sits above (4, 5, 6) and the nearest-aligned of those wins.
@Test func gridNavigatorHandlesTheOnePlusSevenHero() {
    let navigator = VGridNavigator(layout: .hero1p7)
    #expect(navigator.move(from: 0, .right) == 2)   // hero centre y = 4.5 → middle of the three
    #expect(navigator.move(from: 0, .down) == 5)    // straight down, not cell 3
    #expect(navigator.move(from: 2, .left) == 0)
    #expect(navigator.move(from: 1, .down) == 2)
    #expect(navigator.move(from: 3, .down) == 7)
}

/// ⌥↓ out of a hero stays inside the hero's own column band rather than drifting sideways.
///
/// Stated as its own test because it is the single behaviour the facing restriction exists for, and
/// a future simplification back to the bare cost formula must fail here rather than silently
/// regress the feel of the mosaic.
@Test func gridNavigatorLeavingAHeroDownwardsStaysWithinItsColumns() throws {
    for layout in [VGridLayout.hero1p5, .hero1p7, .mosaic4x3] {
        let navigator = VGridNavigator(layout: layout)
        let cells = layout.cells
        let hero = try #require(cells.first)
        let landed = try #require(navigator.move(from: 0, .down))
        let target = cells[landed]
        // The tile it lands on must overlap the hero's horizontal extent.
        #expect(target.x < hero.x + hero.w && hero.x < target.x + target.w,
                "\(layout.rawValue): down from the hero left its columns → cell \(landed)")
        // …and must genuinely be below it.
        #expect(target.y >= hero.y, "\(layout.rawValue): down from the hero went up")
    }
}

/// ⌥→ out of a hero likewise stays inside the hero's own row band.
@Test func gridNavigatorLeavingAHeroRightwardsStaysWithinItsRows() throws {
    for layout in [VGridLayout.hero1p5, .hero1p7, .mosaic4x3] {
        let navigator = VGridNavigator(layout: layout)
        let cells = layout.cells
        let hero = try #require(cells.first)
        let landed = try #require(navigator.move(from: 0, .right))
        let target = cells[landed]
        #expect(target.y < hero.y + hero.h && hero.y < target.y + target.h,
                "\(layout.rawValue): right from the hero left its rows → cell \(landed)")
        #expect(target.x >= hero.x + hero.w - 1,
                "\(layout.rawValue): right from the hero did not move rightwards")
    }
}

/// The mosaic the mockup renders navigates as it looks.
@Test func gridNavigatorHandlesTheMockupMosaic() throws {
    let navigator = VGridNavigator(layout: .mosaic4x3)
    let cells = VGridLayout.mosaic4x3.cells
    // Index of a cell by its unit origin, so the test reads in the mockup's terms.
    func index(x: Int, y: Int) throws -> Int {
        try #require(cells.firstIndex { $0.x == x && $0.y == y })
    }
    let hero = 0
    let garage = try index(x: 6, y: 0)
    let lobby = try index(x: 9, y: 0)
    let backYard = try index(x: 6, y: 4)
    let hallway = try index(x: 0, y: 8)
    // Hero → right reaches Garage (the nearer column), not Lobby.
    #expect(navigator.move(from: hero, .right) == garage)
    // Hero → down reaches Hallway, directly beneath it.
    #expect(navigator.move(from: hero, .down) == hallway)
    // Garage → right is Lobby; Garage → down is Back Yard; Garage → left returns to the hero.
    #expect(navigator.move(from: garage, .right) == lobby)
    #expect(navigator.move(from: garage, .down) == backYard)
    #expect(navigator.move(from: garage, .left) == hero)
    // Lobby is on the trailing edge.
    #expect(navigator.move(from: lobby, .right) == nil)
}

/// Every reachable move is reversible on a uniform grid — going right then left returns.
///
/// Reversibility is not guaranteed for a hero layout (leaving a wide tile and coming back cannot
/// remember which neighbour it left from), so it is asserted only where it must hold.
@Test func gridNavigatorMovesAreReversibleOnUniformGrids() {
    for layout in [VGridLayout.grid2x2, .grid3x3, .grid4x4] {
        let navigator = VGridNavigator(layout: layout)
        for index in 0..<navigator.tileCount {
            let pairs: [(VGridDirection, VGridDirection)] =
                [(.right, .left), (.left, .right), (.up, .down), (.down, .up)]
            for (forward, back) in pairs {
                guard let moved = navigator.move(from: index, forward) else { continue }
                #expect(navigator.move(from: moved, back) == index,
                        "\(layout.rawValue): \(index) \(forward) → \(moved) did not reverse")
            }
        }
    }
}

/// No move ever returns the index it started from, and no move leaves the valid range.
@Test func gridNavigatorNeverReturnsTheOriginOrAnOutOfRangeIndex() {
    for layout in VGridLayout.allCases {
        let navigator = VGridNavigator(layout: layout)
        for index in 0..<navigator.tileCount {
            for direction in VGridDirection.allCases {
                guard let moved = navigator.move(from: index, direction) else { continue }
                #expect(moved != index, "\(layout.rawValue): \(direction) from \(index) stayed")
                #expect(moved >= 0 && moved < navigator.tileCount)
            }
        }
    }
}

// MARK: - Out-of-range input

/// An out-of-range starting index returns `nil` rather than trapping.
@Test func gridNavigatorRejectsOutOfRangeStartingIndices() {
    let navigator = VGridNavigator(layout: .grid2x2)
    for direction in VGridDirection.allCases {
        #expect(navigator.move(from: -1, direction) == nil)
        #expect(navigator.move(from: 4, direction) == nil)
        #expect(navigator.move(from: 999, direction) == nil)
    }
}

// MARK: - Tab order, Home, End

/// ⇥ walks cell order and stops at the ends so focus can leave the stage.
@Test func gridNavigatorTabOrderStopsAtBothEndsInsteadOfWrapping() {
    let navigator = VGridNavigator(layout: .grid2x2)
    #expect(navigator.next(after: 0) == 1)
    #expect(navigator.next(after: 2) == 3)
    #expect(navigator.next(after: 3) == nil)
    #expect(navigator.previous(before: 3) == 2)
    #expect(navigator.previous(before: 0) == nil)
    #expect(navigator.previous(before: 99) == nil)
    #expect(navigator.firstIndex == 0)
    #expect(navigator.lastIndex == 3)
}

/// A focused index that a smaller layout no longer has clamps to the last tile, so focus is never
/// lost (DESIGN.md §10.2 #7).
@Test func gridNavigatorClampsAFocusedIndexAfterTheLayoutShrinks() {
    let small = VGridNavigator(layout: .grid2x2)
    #expect(small.clamped(11) == 3)
    #expect(small.clamped(-4) == 0)
    #expect(small.clamped(2) == 2)
    let single = VGridNavigator(layout: .single)
    #expect(single.clamped(15) == 0)
}

/// The direction table is self-consistent.
@Test func gridNavigatorDirectionAxesAndSignsAreCorrect() {
    #expect(VGridDirection.left.isHorizontal)
    #expect(VGridDirection.right.isHorizontal)
    #expect(!VGridDirection.up.isHorizontal)
    #expect(!VGridDirection.down.isHorizontal)
    #expect(VGridDirection.left.sign == -1)
    #expect(VGridDirection.up.sign == -1)
    #expect(VGridDirection.right.sign == 1)
    #expect(VGridDirection.down.sign == 1)
}

#endif
