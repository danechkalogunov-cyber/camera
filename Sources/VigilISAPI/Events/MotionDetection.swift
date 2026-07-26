//
//  MotionDetection.swift
//  VigilISAPI
//
//  `GET`/`PUT /ISAPI/System/Video/inputs/channels/{ch}/motionDetection`, including the `gridMap`
//  hex encoding that everyone gets wrong. Implements docs/spec-isapi.md §14.9.
//
//  The grid is **top-left origin and row-major** — unlike the detection-region polygons of §14.4,
//  which are lower-left origin. That inconsistency is the device's, not ours, and the two are kept
//  apart deliberately: `MotionGrid` never flips Y, `DetectionRegion` always does.
//
//  `gridMap` is `rows × ceil(columns / 4)` hex digits. Each row contributes
//  `4 × ceil(columns / 4)` bits, most significant bit first, where bit *k* from the top of the
//  row's first hex digit is column *k*. Bits past `columns` are padding and must be written as 0 —
//  firmware has been observed to reject a map with dirty padding.
//

import Foundation
import VigilProtocols

// MARK: - MotionGrid

/// The motion-detection cell mask.
public struct MotionGrid: Sendable, Hashable, Codable {
    public let rows: Int
    public let columns: Int
    /// Row-major, `rows * columns` entries.
    public private(set) var cells: [Bool]

    /// An all-off grid. `rows` and `columns` below 1 are clamped up: a zero-dimension grid would
    /// serialise to an empty `gridMap`, which the device treats as "detect nothing" everywhere.
    public init(rows: Int, columns: Int) {
        self.rows = max(1, rows)
        self.columns = max(1, columns)
        cells = [Bool](repeating: false, count: self.rows * self.columns)
    }

    /// Decodes a `gridMap` hex string.
    ///
    /// Returns `nil` for a non-hex character or for a string too short for the declared geometry.
    /// A string that is *longer* is accepted and the excess ignored: some firmware pads the map to
    /// a fixed 64-row buffer regardless of the grid it advertises.
    public init?(hex: String, rows: Int, columns: Int) {
        guard rows > 0, columns > 0 else { return nil }
        let digitsPerRow = (columns + 3) / 4
        var digits: [UInt8] = []
        digits.reserveCapacity(hex.count)
        for character in hex where !character.isWhitespace {
            guard let value = character.hexDigitValue, value >= 0, value <= 15 else { return nil }
            digits.append(UInt8(value))
        }
        guard digits.count >= rows * digitsPerRow else { return nil }
        self.rows = rows
        self.columns = columns
        var cells = [Bool](repeating: false, count: rows * columns)
        for row in 0..<rows {
            for column in 0..<columns {
                let digit = digits[row * digitsPerRow + column / 4]
                // Bit 3 of the nibble is column 0 of that group: most significant bit first.
                let bit = 3 - (column % 4)
                cells[row * columns + column] = (digit >> UInt8(bit)) & 1 == 1
            }
        }
        self.cells = cells
    }

    /// Reads or writes one cell. Out-of-range coordinates read `false` and ignore a write, because
    /// a rasteriser that runs one pixel past the edge must not crash a viewer.
    public subscript(row: Int, column: Int) -> Bool {
        get {
            guard (0..<rows).contains(row), (0..<columns).contains(column) else { return false }
            return cells[row * columns + column]
        }
        set {
            guard (0..<rows).contains(row), (0..<columns).contains(column) else { return }
            cells[row * columns + column] = newValue
        }
    }

    /// The `gridMap` hex string, with every padding bit forced to zero.
    public var hexString: String {
        let digitsPerRow = (columns + 3) / 4
        var out = String()
        out.reserveCapacity(rows * digitsPerRow)
        let alphabet = Array("0123456789abcdef")
        for row in 0..<rows {
            for digitIndex in 0..<digitsPerRow {
                var nibble = 0
                for bit in 0..<4 {
                    let column = digitIndex * 4 + bit
                    guard column < columns, self[row, column] else { continue }
                    nibble |= 1 << (3 - bit)
                }
                out.append(alphabet[nibble])
            }
        }
        return out
    }

    /// True when every cell is on — the default Vigil offers new users.
    public var isFullFrame: Bool { cells.allSatisfy { $0 } }

    /// Sets every cell.
    public mutating func fill(_ value: Bool) {
        cells = [Bool](repeating: value, count: rows * columns)
    }

    /// Rasterises a normalised (0…1, **top-left origin**) polygon into cells.
    ///
    /// A cell is set when its centre is inside the polygon, by even-odd ray casting. Fewer than
    /// three points sets nothing rather than guessing at a degenerate shape.
    public mutating func set(polygon: [NormalizedPoint], to value: Bool) {
        guard polygon.count >= 3 else { return }
        for row in 0..<rows {
            let y = (Double(row) + 0.5) / Double(rows)
            for column in 0..<columns {
                let x = (Double(column) + 0.5) / Double(columns)
                if Self.contains(polygon: polygon, x: x, y: y) {
                    cells[row * columns + column] = value
                }
            }
        }
    }

    /// Even-odd point-in-polygon test.
    static func contains(polygon: [NormalizedPoint], x: Double, y: Double) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[j]
            if (a.y > y) != (b.y > y) {
                let denominator = b.y - a.y
                if denominator != 0 {
                    let crossing = (b.x - a.x) * (y - a.y) / denominator + a.x
                    if x < crossing { inside.toggle() }
                }
            }
            j = i
        }
        return inside
    }
}

// MARK: - MotionDetectionConfig

/// The whole `<MotionDetection>` element, plus the node it came from so a PUT can echo it back.
public struct MotionDetectionConfig: Sendable, Hashable {
    public var enabled: Bool
    /// 0…100, higher is more sensitive.
    public var sensitivity: Int
    /// 1…10 frames between samples.
    public var samplingInterval: Int
    /// Milliseconds.
    public var startTriggerMS: Int
    public var endTriggerMS: Int
    public var grid: MotionGrid
    /// The element as the device sent it, for read-modify-write.
    public var originalNode: XMLNode?

    public init(enabled: Bool, sensitivity: Int, samplingInterval: Int, startTriggerMS: Int,
                endTriggerMS: Int, grid: MotionGrid, originalNode: XMLNode? = nil,
                sensitivityPath: String? = nil, gridMapPath: String? = nil) {
        self.enabled = enabled
        self.sensitivity = sensitivity
        self.samplingInterval = samplingInterval
        self.startTriggerMS = startTriggerMS
        self.endTriggerMS = endTriggerMS
        self.grid = grid
        self.originalNode = originalNode
        self.sensitivityPath = sensitivityPath
        self.gridMapPath = gridMapPath
    }

    /// Where this device keeps `sensitivityLevel`, resolved on read. `nil` when it has none.
    public var sensitivityPath: String?
    /// Where this device keeps `gridMap`, resolved on read.
    public var gridMapPath: String?

    /// The nestings firmware uses for the sensitivity element, in order.
    ///
    /// These are separate *whole paths* rather than one `|` alternation because `|` alternates
    /// within a segment: `a/b|c/d` means `a` then `b|c` then `d`, which matches nothing here. Reads
    /// could use the `||` whole-path form, but `XMLNode.setting` accepts only a single
    /// alternative — so the concrete path is resolved once, on read, and reused for the write.
    static let sensitivityCandidates = ["MotionDetectionLayout/sensitivityLevel",
                                        "MotionDetectionLayout/layout/sensitivityLevel",
                                        "sensitivityLevel"]
    /// The same, for the grid map.
    static let gridMapCandidates = ["MotionDetectionLayout/layout/gridMap",
                                    "MotionDetectionLayout/gridMap",
                                    "gridMap"]

    /// The first candidate path that resolves against `node`.
    static func resolve(_ candidates: [String], in node: XMLNode) -> String? {
        candidates.first { node.has($0) }
    }

    /// Decodes a `<MotionDetection>` document.
    ///
    /// The grid geometry defaults to the near-universal 22 columns × 18 rows when the device omits
    /// `<Grid>`. A `gridMap` that does not decode against the declared geometry yields an all-off
    /// grid rather than a thrown error: the enable toggle and the sensitivity slider are still
    /// worth showing, and a wrong mask is easier to explain than a blank panel.
    public init(document: ISAPIDocument) {
        let rows = document["Grid/rowGranularity"].int ?? 18
        let columns = document["Grid/columnGranularity"].int ?? 22
        let sensitivityPath = Self.resolve(Self.sensitivityCandidates, in: document.root)
        let gridMapPath = Self.resolve(Self.gridMapCandidates, in: document.root)
        let hex = gridMapPath.flatMap { document[$0].string } ?? ""
        let grid = MotionGrid(hex: hex, rows: rows, columns: columns)
            ?? MotionGrid(rows: rows, columns: columns)
        self.init(enabled: document["enabled"].bool ?? false,
                  sensitivity: sensitivityPath.flatMap { document[$0].int } ?? 0,
                  samplingInterval: document["samplingInterval"].int ?? 2,
                  startTriggerMS: document["startTriggerTime"].int ?? 500,
                  endTriggerMS: document["endTriggerTime"].int ?? 500,
                  grid: grid,
                  originalNode: document.root,
                  sensitivityPath: sensitivityPath,
                  gridMapPath: gridMapPath)
    }

    /// Applies the requested changes onto the device's own element.
    ///
    /// Returns `nil` when there is no original node to patch — the caller must then re-`GET`
    /// rather than construct a body, because a hand-built `<MotionDetection>` is exactly the
    /// partial document Hikvision's validator rejects.
    public func patchedNode(enabled: Bool?, sensitivity: Int?, grid: MotionGrid?) -> XMLNode? {
        guard var node = originalNode else { return nil }
        if let enabled { node = node.setting("enabled", to: enabled ? "true" : "false") }
        if let sensitivity, let path = sensitivityPath {
            node = node.setting(path, to: String(min(100, max(0, sensitivity))))
        }
        if let grid, let path = gridMapPath {
            node = node.setting(path, to: grid.hexString)
        }
        return node
    }
}
