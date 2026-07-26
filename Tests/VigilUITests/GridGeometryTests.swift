//
//  GridGeometryTests.swift
//  VigilUITests
//
//  The unit-to-point mapping. These tests exist because a fractional tile edge is a visible grey
//  smear along a video well and an unequal gutter is a visible wobble, and neither is catchable by
//  reading the code.
//  Covers Sources/VigilUI/Grid/GridGeometry.swift; see docs/UX.md §5.1 and docs/DESIGN.md §3.6 #4.
//

#if os(macOS)

import Foundation
import Testing

@testable import VigilUI

// MARK: - Helpers

/// Widths that are deliberately awkward: primes, odd numbers, and sizes that divide badly by 12.
private let gridGeometryAwkwardExtents: [CGFloat] = [
    100, 101, 137, 480, 481, 700, 719, 863, 1024, 1279, 1280, 1440, 1441, 1607, 1920, 2559, 3840,
]

// MARK: - Edge invariants

/// Every unit boundary lands on a whole point, at every awkward size and in both axes.
///
/// This is the property the whole type exists for: a video well whose edge is at `x.5` is blended
/// along that edge and picks up a soft grey line where the design wants a crisp seam.
@Test func gridGeometryEveryUnitEdgeIsAWholeNumberOfPoints() {
    for extent in gridGeometryAwkwardExtents {
        let geometry = VGridGeometry(layout: .grid4x4,
                                     size: CGSize(width: extent, height: extent * 0.63))
        for unit in 0...VGridLayout.units {
            let x = geometry.columnEdge(unit)
            let y = geometry.rowEdge(unit)
            #expect(x == x.rounded(), "column edge \(unit) at width \(extent) is \(x)")
            #expect(y == y.rounded(), "row edge \(unit) at width \(extent) is \(y)")
        }
    }
}

/// The first edge is 0 and the last is `extent + gutter`, so the trailing tile ends exactly at
/// `extent`.
@Test func gridGeometryClosingEdgeMakesTheTrailingTileEndAtTheStageEdge() {
    for extent in gridGeometryAwkwardExtents {
        let geometry = VGridGeometry(layout: .grid3x3, size: CGSize(width: extent, height: extent))
        #expect(geometry.columnEdge(0) == 0)
        #expect(geometry.columnEdge(VGridLayout.units) == extent + geometry.gutter)
    }
}

/// Edges are monotonically non-decreasing, so no tile can be given a negative width.
@Test func gridGeometryEdgesAreMonotonic() {
    for extent in gridGeometryAwkwardExtents {
        let geometry = VGridGeometry(layout: .grid4x4, size: CGSize(width: extent, height: 200))
        for unit in 1...VGridLayout.units {
            #expect(geometry.columnEdge(unit) >= geometry.columnEdge(unit - 1))
        }
    }
}

/// An index past the ends clamps rather than extrapolating.
@Test func gridGeometryEdgeIndexClampsInsteadOfExtrapolating() {
    let geometry = VGridGeometry(layout: .single, size: CGSize(width: 1200, height: 800))
    #expect(geometry.columnEdge(-5) == geometry.columnEdge(0))
    #expect(geometry.columnEdge(99) == geometry.columnEdge(VGridLayout.units))
    #expect(geometry.rowEdge(-1) == geometry.rowEdge(0))
    #expect(geometry.rowEdge(13) == geometry.rowEdge(VGridLayout.units))
}

// MARK: - Coverage

/// A row of tiles plus its gutters covers the stage exactly, with no remainder.
///
/// Checked across every uniform layout and every awkward width: the sum of the tile widths plus
/// `(columns - 1)` gutters must equal the stage width to the point.
@Test func gridGeometryTilesPlusGuttersCoverTheStageExactly() {
    let cases: [(VGridLayout, Int)] = [(.single, 1), (.grid2x2, 2), (.grid3x3, 3), (.grid4x4, 4)]
    for (layout, columns) in cases {
        for extent in gridGeometryAwkwardExtents {
            let geometry = VGridGeometry(layout: layout,
                                         size: CGSize(width: extent, height: extent))
            // The top row of the layout, in cell order.
            let topRow = layout.cells.filter { $0.y == 0 }
            #expect(topRow.count == columns)
            let widths = topRow.map { geometry.frame(of: $0).width }
            let total = widths.reduce(0, +) + geometry.gutter * CGFloat(columns - 1)
            #expect(total == extent,
                    "\(layout.rawValue) at \(extent): tiles total \(total)")
        }
    }
}

/// Two horizontally adjacent tiles are separated by exactly the gutter — never 1 pt, never 3 pt.
@Test func gridGeometryGapBetweenAdjacentTilesIsExactlyTheGutter() {
    for extent in gridGeometryAwkwardExtents {
        let geometry = VGridGeometry(layout: .grid4x4, size: CGSize(width: extent, height: extent))
        let topRow = geometry.layout.cells.filter { $0.y == 0 }.map { geometry.frame(of: $0) }
        for (left, right) in zip(topRow, topRow.dropFirst()) {
            #expect(right.minX - left.maxX == geometry.gutter,
                    "at \(extent): gap is \(right.minX - left.maxX)")
        }
    }
}

/// Vertically adjacent tiles are separated by exactly the gutter too.
@Test func gridGeometryVerticalGapBetweenAdjacentTilesIsExactlyTheGutter() {
    for extent in gridGeometryAwkwardExtents {
        let geometry = VGridGeometry(layout: .grid3x3, size: CGSize(width: 900, height: extent))
        let leftColumn = geometry.layout.cells.filter { $0.x == 0 }.map { geometry.frame(of: $0) }
        for (upper, lower) in zip(leftColumn, leftColumn.dropFirst()) {
            #expect(lower.minY - upper.maxY == geometry.gutter,
                    "at \(extent): vertical gap is \(lower.minY - upper.maxY)")
        }
    }
}

// MARK: - Spans

/// A hero absorbs the gutters it crosses, so it is one continuous well rather than four with seams.
///
/// A 2 × 2-cell hero in a 4 × 4 grid must be exactly two tile widths plus one gutter wide.
@Test func gridGeometryHeroAbsorbsTheGuttersItSpans() throws {
    let geometry = VGridGeometry(layout: .grid4x4, size: CGSize(width: 1607, height: 1013))
    let single = geometry.frame(of: VLayoutRect(x: 0, y: 0, w: 3, h: 3))
    let neighbour = geometry.frame(of: VLayoutRect(x: 3, y: 0, w: 3, h: 3))
    let spanning = geometry.frame(of: VLayoutRect(x: 0, y: 0, w: 6, h: 3))
    #expect(spanning.width == single.width + geometry.gutter + neighbour.width)
    #expect(spanning.minX == single.minX)
    #expect(spanning.maxX == neighbour.maxX)
}

/// The single layout fills the whole tile area.
@Test func gridGeometrySingleLayoutFillsTheStage() throws {
    let size = CGSize(width: 1440, height: 823)
    let geometry = VGridGeometry(layout: .single, size: size)
    let frame = try #require(geometry.frame(atIndex: 0))
    #expect(frame.origin == .zero)
    #expect(frame.size == size)
}

/// The mosaic's hero and its neighbours line up: the hero's trailing edge plus a gutter is the
/// third column's leading edge, and its bottom plus a gutter is the last row's top.
@Test func gridGeometryMosaicHeroAlignsWithItsNeighbours() throws {
    let geometry = VGridGeometry(layout: .mosaic4x3, size: CGSize(width: 1167, height: 1155))
    let cells = VGridLayout.mosaic4x3.cells
    let hero = geometry.frame(of: try #require(cells.first))
    let rightOfHero = geometry.frame(of: try #require(cells.first { $0.x == 6 && $0.y == 0 }))
    let belowHero = geometry.frame(of: try #require(cells.first { $0.x == 0 && $0.y == 8 }))
    #expect(rightOfHero.minX - hero.maxX == geometry.gutter)
    #expect(belowHero.minY - hero.maxY == geometry.gutter)
}

// MARK: - Degenerate sizes

/// A zero size — which `GeometryReader` reports on its first pass — produces zero-sized tiles and
/// no trap.
@Test func gridGeometryZeroSizeProducesEmptyFramesWithoutTrapping() {
    let geometry = VGridGeometry(layout: .grid4x4, size: .zero)
    #expect(geometry.frames.count == 16)
    for frame in geometry.frames {
        #expect(frame.width == 0)
        #expect(frame.height == 0)
    }
}

/// A negative size is clamped to zero rather than producing inverted rectangles.
@Test func gridGeometryNegativeSizeIsClampedToZero() {
    let geometry = VGridGeometry(layout: .grid2x2, size: CGSize(width: -500, height: -20))
    #expect(geometry.size.width == 0)
    #expect(geometry.size.height == 0)
    #expect(geometry.frames.allSatisfy { $0.width == 0 && $0.height == 0 })
}

/// A stage narrower than its gutters yields zero-width tiles, never negative ones.
@Test func gridGeometryTinyStageNeverProducesNegativeWidths() {
    for extent in [CGFloat(0), 1, 2, 3, 8, 12, 24] {
        let geometry = VGridGeometry(layout: .grid4x4,
                                     size: CGSize(width: extent, height: extent))
        for frame in geometry.frames {
            #expect(frame.width >= 0, "width \(frame.width) at extent \(extent)")
            #expect(frame.height >= 0, "height \(frame.height) at extent \(extent)")
        }
    }
}

/// A negative gutter is clamped to zero.
@Test func gridGeometryNegativeGutterIsClampedToZero() {
    let geometry = VGridGeometry(layout: .grid2x2, size: CGSize(width: 800, height: 600),
                                 gutter: -4)
    #expect(geometry.gutter == 0)
    let topRow = geometry.layout.cells.filter { $0.y == 0 }.map { geometry.frame(of: $0) }
    #expect(topRow.count == 2)
    #expect(topRow[0].maxX == topRow[1].minX)
}

// MARK: - Frames and indices

/// `frames` has one rectangle per tile, in cell order.
@Test func gridGeometryFramesMatchTheCellCount() {
    for layout in VGridLayout.allCases {
        let geometry = VGridGeometry(layout: layout, size: CGSize(width: 1280, height: 720))
        #expect(geometry.frames.count == layout.tileCount)
        #expect(geometry.frame(atIndex: layout.tileCount) == nil)
        #expect(geometry.frame(atIndex: -1) == nil)
    }
}

/// The centre helper agrees with the frame it is derived from.
@Test func gridGeometryCentreIsTheMidpointOfTheFrame() {
    let geometry = VGridGeometry(layout: .grid3x3, size: CGSize(width: 901, height: 601))
    for cell in VGridLayout.grid3x3.cells {
        let frame = geometry.frame(of: cell)
        let centre = geometry.centre(of: cell)
        #expect(centre.x == frame.midX)
        #expect(centre.y == frame.midY)
    }
}

/// The geometry's restated tokens have not drifted from `VTheme`.
///
/// `VGridGeometry` deliberately restates the gutter and the stage inset as plain numbers so it can
/// be exercised off the main actor. That is only safe if the two cannot silently diverge, which is
/// what this pins.
@Test @MainActor func gridGeometryRestatedTokensMatchVTheme() {
    #expect(VGridGeometry.defaultGutter == VTheme.Metrics.tileGutter)
    #expect(VGridGeometry.defaultStageInset == VTheme.Metrics.stageInset)
}

#endif
