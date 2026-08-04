//
//  SettingsAndStorageTests.swift
//  VigilISAPITests
//
//  The motion grid's `gridMap` encoding, the image sub-resources and their read-modify-write
//  patches, JPEG snapshot policy and sniffing, storage volumes in decimal MB, two-way audio codec
//  negotiation, and the event-trigger and schedule readers.
//  Covers docs/spec-isapi.md §12.5, §14.7–§14.9, §15.4, §16 and §17.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilISAPI

// MARK: - MotionGridSuite

@Suite struct MotionGridSuite {

    @Test func motionGridRoundTripsThe22By18HexMap() throws {
        // 18 rows × ceil(22/4) = 6 hex digits = 108 characters.
        #expect(SettingsFixtures.sixRowGridMap.count == 108)
        let grid = try #require(MotionGrid(hex: SettingsFixtures.sixRowGridMap,
                                           rows: 18, columns: 22))
        #expect(grid.rows == 18)
        #expect(grid.columns == 22)
        // `fffffc` sets bits 0…21 of the row: every column on, both padding bits off.
        for column in 0..<22 { #expect(grid[0, column], "row 0 column \(column)") }
        for column in 0..<22 { #expect(!grid[6, column], "row 6 column \(column)") }
        #expect(grid.hexString == SettingsFixtures.sixRowGridMap)
    }

    @Test func motionGridWritesPaddingBitsAsZero() {
        // The last two bits of each 22-column row are padding and must be written as zero;
        // firmware has been observed to reject a map with dirty padding.
        var grid = MotionGrid(rows: 18, columns: 22)
        grid.fill(true)
        #expect(grid.isFullFrame)
        let hex = grid.hexString
        #expect(hex.count == 108)
        // Each row is `fffffc`: five full nibbles plus `1100`.
        #expect(hex == String(repeating: "fffffc", count: 18))
    }

    @Test func motionGridIsTopLeftOriginAndRowMajor() {
        // Unlike detection-region polygons, the grid does **not** flip Y: the first row is the
        // image's top row (docs/spec-isapi.md §14.9).
        var grid = MotionGrid(rows: 4, columns: 4)
        grid[0, 0] = true
        // Row 0, column 0 is the most significant bit of the first hex digit.
        #expect(grid.hexString == "8" + "0" + "0" + "0")
        grid[0, 0] = false
        grid[3, 3] = true
        #expect(grid.hexString == "0001")
    }

    @Test func motionGridHandlesAnOddColumnCount() {
        // 25 columns ⇒ ceil(25/4) = 7 hex digits per row.
        var grid = MotionGrid(rows: 2, columns: 25)
        grid.fill(true)
        let hex = grid.hexString
        #expect(hex.count == 14)
        // The last digit carries only column 24: bit 3 of the nibble.
        #expect(hex == "ffffff8ffffff8")
        let round = MotionGrid(hex: hex, rows: 2, columns: 25)
        #expect(round?.isFullFrame == true)
    }

    @Test func motionGridRejectsMalformedHex() {
        #expect(MotionGrid(hex: "zzzz", rows: 1, columns: 4) == nil)
        // Too short for the declared geometry.
        #expect(MotionGrid(hex: "ff", rows: 18, columns: 22) == nil)
        #expect(MotionGrid(hex: "", rows: 1, columns: 1) == nil)
        // Longer is accepted: some firmware pads to a fixed 64-row buffer.
        #expect(MotionGrid(hex: String(repeating: "f", count: 400), rows: 18, columns: 22) != nil)
    }

    @Test func motionGridSubscriptIgnoresOutOfRange() {
        var grid = MotionGrid(rows: 2, columns: 2)
        #expect(!grid[99, 99])
        grid[99, 99] = true         // must not trap
        #expect(!grid.isFullFrame)
        // Zero dimensions clamp up rather than producing an empty map, which the device reads as
        // "detect nothing".
        let clamped = MotionGrid(rows: 0, columns: 0)
        #expect(clamped.rows == 1)
        #expect(clamped.columns == 1)
    }

    @Test func motionGridRasterisesAPolygon() {
        var grid = MotionGrid(rows: 10, columns: 10)
        // The top-left quadrant, in normalised top-left-origin coordinates.
        grid.set(polygon: [NormalizedPoint(x: 0, y: 0), NormalizedPoint(x: 0.5, y: 0),
                           NormalizedPoint(x: 0.5, y: 0.5), NormalizedPoint(x: 0, y: 0.5)],
                 to: true)
        #expect(grid[0, 0])
        #expect(grid[4, 4])
        #expect(!grid[5, 5])
        #expect(!grid[9, 9])
        #expect(!grid[0, 9])
        // Fewer than three points sets nothing rather than guessing at a degenerate shape.
        var untouched = MotionGrid(rows: 4, columns: 4)
        untouched.set(polygon: [NormalizedPoint(x: 0, y: 0), NormalizedPoint(x: 1, y: 1)], to: true)
        #expect(!untouched.isFullFrame)
        #expect(untouched.cells.allSatisfy { !$0 })
    }
}
