//
//  VTimelineBandRenderer.swift
//  VigilUI
//
//  The archive band's paint: every rectangle and every colour resolved ahead of the `Canvas`, and
//  the non-isolated renderer that draws them.
//  macOS-only. Implements docs/DESIGN.md §9.14 (density band, gap baseline) and §10.5 (hatch).
//
//  WHY THE RENDERER TAKES A PRE-RESOLVED PAINT. `Canvas`'s renderer is a plain escaping closure
//  with no declared isolation, so reading a `@MainActor` token — which every `VTheme` value is —
//  from inside it would be a concurrency error. `VTimelineBarView` resolves the whole band into
//  ``VTimelineBandPaint`` on the main actor first, and this file is a pure function of that value.
//

#if os(macOS)

import Foundation
import SwiftUI

// MARK: - VTimelineBandPaint

/// Every rectangle and every colour the band renderer needs, resolved before the `Canvas` runs.
///
/// This type is what keeps `VTheme` — all of which is `@MainActor` — out of a closure that has no
/// declared isolation. Nothing in ``VTimelineBandRenderer`` reads anything but this value.
struct VTimelineBandPaint {

    /// One painted segment run.
    struct Box {
        let rect: CGRect
        let fill: SwiftUI.Color
        /// Non-`nil` when the run could not reach the minimum width and gets the 1 pt outer glow of
        /// UX.md §7.3 instead of being moved.
        let glow: SwiftUI.Color?
        let hatch: VTimelineHatch
    }

    /// The band's recessed well.
    let well: CGRect
    let wellRadius: CGFloat
    let wellFill: SwiftUI.Color

    /// The segment runs, left to right.
    let boxes: [Box]

    /// The dotted "no recording" baselines, one per drawable gap, as `from ... to` x pairs at
    /// ``baselineY``.
    let gapSpans: [ClosedRange<CGFloat>]
    let baselineY: CGFloat
    let gapInk: SwiftUI.Color
    let gapDash: [CGFloat]

    /// The local-clip strip.
    let clipWell: CGRect
    let clipRadius: CGFloat
    let clipWellFill: SwiftUI.Color
    let clipBoxes: [CGRect]
    let clipFill: SwiftUI.Color

    /// 1 pt, the width of every line this renderer strokes.
    let hairline: CGFloat

    /// The ink the hatch is drawn in, or `nil` when `differentiateWithoutColor` is off.
    let hatchInk: SwiftUI.Color?
}

// MARK: - VTimelineBandRenderer

/// Paints a ``VTimelineBandPaint``.
///
/// A non-isolated namespace on purpose: it is called from inside `Canvas`'s renderer closure, which
/// carries no isolation, and it touches nothing but its argument.
enum VTimelineBandRenderer {

    /// Draws the band, then the clip strip. Back to front: well, gap baselines, runs, hatch.
    ///
    ///     func fill(_ path: Path, with shading: GraphicsContext.Shading, style: FillStyle)
    ///     func stroke(_ path: Path, with shading: GraphicsContext.Shading, style: StrokeStyle)
    ///     static func color(_ color: Color) -> GraphicsContext.Shading
    static func draw(_ paint: VTimelineBandPaint, in context: inout GraphicsContext) {
        context.fill(Path(roundedRect: paint.well,
                          cornerRadius: paint.wellRadius,
                          style: .continuous),
                     with: .color(paint.wellFill))

        // Gaps first: their dotted baseline sits under any run that widened into them, which is the
        // visual counterpart of TimelineBarLayout's promise that a drawn gap keeps uncovered width.
        if !paint.gapSpans.isEmpty {
            var baseline = Path()
            for span in paint.gapSpans {
                baseline.move(to: CGPoint(x: span.lowerBound, y: paint.baselineY))
                baseline.addLine(to: CGPoint(x: span.upperBound, y: paint.baselineY))
            }
            context.stroke(baseline,
                           with: .color(paint.gapInk),
                           style: StrokeStyle(lineWidth: paint.hairline, dash: paint.gapDash))
        }

        for box in paint.boxes {
            context.fill(Path(box.rect), with: .color(box.fill))
            if let glow = box.glow {
                let outline = Path(box.rect.insetBy(dx: -paint.hairline, dy: 0))
                context.stroke(outline, with: .color(glow), lineWidth: paint.hairline)
            }
            if let ink = paint.hatchInk {
                drawHatch(box.hatch, rect: box.rect, ink: ink,
                          lineWidth: paint.hairline, in: &context)
            }
        }

        context.fill(Path(roundedRect: paint.clipWell,
                          cornerRadius: paint.clipRadius,
                          style: .continuous),
                     with: .color(paint.clipWellFill))
        for clip in paint.clipBoxes {
            context.fill(Path(roundedRect: clip, cornerRadius: paint.clipRadius,
                              style: .continuous),
                         with: .color(paint.clipFill))
        }
    }

    /// The 45° hatch that carries recording type without colour (DESIGN.md §10.5).
    ///
    ///     func drawLayer(content: (inout GraphicsContext) throws -> Void) rethrows
    ///     mutating func clip(to path: Path, style: FillStyle, options: GraphicsContext.ClipOptions)
    static func drawHatch(_ hatch: VTimelineHatch,
                          rect: CGRect,
                          ink: SwiftUI.Color,
                          lineWidth: CGFloat,
                          in context: inout GraphicsContext) {
        let pitch = hatch.pitch
        guard pitch > 0, rect.width > 0, rect.height > 0 else { return }
        context.drawLayer { layer in
            layer.clip(to: Path(rect))
            var lines = Path()
            var offset = -rect.height
            // Bounded independently of the arithmetic: a run as wide as the bar at a 3 pt pitch is
            // ~400 lines, and the cap stops a degenerate pitch from stalling the renderer.
            var drawn = 0
            let limit = 512
            while offset < rect.width, drawn < limit {
                lines.move(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
                lines.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.minY))
                if hatch == .cross {
                    lines.move(to: CGPoint(x: rect.minX + offset, y: rect.minY))
                    lines.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.maxY))
                }
                offset += pitch
                drawn += 1
            }
            layer.stroke(lines, with: .color(ink), lineWidth: lineWidth)
        }
    }
}

#endif  // os(macOS)
