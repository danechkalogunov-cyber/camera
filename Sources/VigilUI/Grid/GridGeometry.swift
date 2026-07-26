//
//  GridGeometry.swift
//  VigilUI
//
//  Turns a stage size into an exact rectangle per tile. Pure arithmetic; the invariant it exists to
//  guarantee is that tile edges land on whole points, every gutter is exactly the gutter, and the
//  tiles together cover the stage with nothing left over.
//  macOS-only. Implements docs/UX.md §5.1 (unit → point mapping) with docs/DESIGN.md §5.1's tokens
//  and §3.6 clause 4's justification for the 2 pt canvas seam.
//

#if os(macOS)

import Foundation

// MARK: - VGridGeometry

/// The stage's tile rectangles for one layout at one size.
///
/// ## Why the edges are computed cumulatively rather than by dividing
///
/// UX.md §5.1 states the mapping as `unitW = usableW / 12`, then `cellRect.x = p + x * (unitW + g)`
/// and `cellRect.w = w * unitW + (w - 1) * g`. Taken literally that produces a fractional `unitW`
/// for almost every real window width, and three things then go wrong at once — all three visible:
///
/// 1. A video well whose edge is at `x.5` is composited with a blend along that edge, so the picture
///    picks up a soft grey line where the design wants a crisp 2 pt canvas seam.
/// 2. The rounding error accumulates across the row, so the seams come out 2 pt, then 3 pt, then
///    2 pt — which reads as a wobble in a 4 × 4 grid.
/// 3. The trailing column stops short of, or overhangs, the stage by up to a point.
///
/// So the *unit boundaries* are computed first, as whole points, and the widths are derived from
/// them:
///
///     edge(u) = round((extent + gutter) * u / 12)      for u in 0...12
///     x       = edge(rect.x)
///     w       = edge(rect.x + rect.w) - edge(rect.x) - gutter
///
/// `edge(0)` is `0` and `edge(12)` is `extent + gutter`, so the trailing tile ends exactly at
/// `extent`; two tiles that share a boundary are separated by exactly `gutter`; a span absorbs the
/// gutters it crosses for free; and every coordinate is integral. Individual tiles may differ by a
/// point, which is correct — the remainder has to go somewhere, and a one-point difference between
/// tiles is invisible where a moving seam is not.
///
/// This is the same mapping the document describes, evaluated in an order that does not accumulate
/// error. The stage inset `p` is deliberately **not** in here: the view applies it as padding and
/// this type measures the area inside it, so the inset cannot be double-counted.
///
/// Deliberately not `Hashable`: it is derived from a layout and a size on every layout pass and is
/// never a dictionary key or an `animation(_:value:)` argument, so a conformance would only be one
/// more thing that has to keep holding.
package struct VGridGeometry: Sendable {

    // MARK: - Stored Properties

    /// The layout being measured.
    package let layout: VGridLayout

    /// The area available to the tiles, *inside* the stage inset.
    package let size: CGSize

    /// The canvas seam between two adjacent tiles.
    package let gutter: CGFloat

    // MARK: - Initialisation

    /// Measures a layout.
    ///
    /// - Parameters:
    ///   - layout: which arrangement to measure.
    ///   - size: the space the tiles are to fill, already reduced by the stage inset. Negative
    ///     components are clamped to zero rather than trapping, because a SwiftUI `GeometryReader`
    ///     reports a zero size on its first pass and a stage can be dragged narrower than its
    ///     tiles.
    ///   - gutter: the seam between tiles; defaults to the design's 2 pt.
    package init(layout: VGridLayout,
                 size: CGSize,
                 gutter: CGFloat = VGridGeometry.defaultGutter) {
        self.layout = layout
        self.size = CGSize(width: Swift.max(0, size.width), height: Swift.max(0, size.height))
        self.gutter = Swift.max(0, gutter)
    }

    /// 2 pt — the value of `VTheme.Metrics.tileGutter`, restated as a plain number so this file
    /// stays free of the main-actor-isolated token namespace and can be exercised off the main
    /// actor. The two must not diverge; `GridGeometryTests` pins them together.
    package static let defaultGutter: CGFloat = 2

    /// 8 pt — the value of `VTheme.Metrics.stageInset`, restated for the same reason. Applied by the
    /// view as padding, never by this type.
    package static let defaultStageInset: CGFloat = 8

    // MARK: - Edges

    /// The horizontal point boundary of unit column `unit`, for `unit` in `0...12`.
    package func columnEdge(_ unit: Int) -> CGFloat {
        Self.edge(unit, extent: size.width, gutter: gutter)
    }

    /// The vertical point boundary of unit row `unit`, for `unit` in `0...12`.
    package func rowEdge(_ unit: Int) -> CGFloat {
        Self.edge(unit, extent: size.height, gutter: gutter)
    }

    /// The shared boundary arithmetic. See the type's discussion for why it is written this way.
    ///
    /// `unit` is clamped to `0...12`, so a caller that walks one past the end gets the closing edge
    /// rather than an extrapolated value.
    private static func edge(_ unit: Int, extent: CGFloat, gutter: CGFloat) -> CGFloat {
        let units = VGridLayout.units
        let clamped = Swift.min(Swift.max(unit, 0), units)
        return ((extent + gutter) * CGFloat(clamped) / CGFloat(units)).rounded()
    }

    // MARK: - Frames

    /// The rectangle for one unit rect, in the tile area's own coordinates.
    ///
    /// A spanning cell's rectangle covers its units *and* the gutters between them, which is what
    /// makes a hero one continuous video well rather than four wells with seams through it.
    package func frame(of rect: VLayoutRect) -> CGRect {
        let x = columnEdge(rect.x)
        let y = rowEdge(rect.y)
        let right = columnEdge(rect.x + rect.w)
        let bottom = rowEdge(rect.y + rect.h)
        return CGRect(x: x,
                      y: y,
                      width: Swift.max(0, right - x - gutter),
                      height: Swift.max(0, bottom - y - gutter))
    }

    /// Every tile's rectangle, in cell order.
    package var frames: [CGRect] {
        layout.cells.map(frame(of:))
    }

    /// The rectangle for the tile at a cell index, or `nil` when the index is out of range.
    package func frame(atIndex index: Int) -> CGRect? {
        let cells = layout.cells
        guard index >= 0, index < cells.count else { return nil }
        return frame(of: cells[index])
    }

    /// The centre of a unit rect's rectangle, for SwiftUI's `.position(x:y:)`.
    ///
    /// Provided because `.position` takes a centre, and computing it at each call site is exactly
    /// the sort of arithmetic that gets a `/ 2` wrong.
    package func centre(of rect: VLayoutRect) -> CGPoint {
        let frame = frame(of: rect)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// The whole tile area's rectangle, for the focus transition's end state.
    package var stageFrame: CGRect {
        CGRect(origin: .zero, size: size)
    }
}

#endif  // os(macOS)
