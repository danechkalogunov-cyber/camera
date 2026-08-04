//
//  VInspectorCharts.swift
//  VigilUI
//
//  The two pictures the inspector draws: the 60 s sparkline over its inset well, and the storage
//  meter beneath the Device block.
//  macOS-only. Implements docs/DESIGN.md §9.21 (sparkline), §6.1 (E0 well), §7.4 #32 (path
//  animation) and docs/UX.md §6.1, §6.2.
//
//  ⛔ THE PERFORMANCE RULE THIS FILE OBEYS. UX.md §6.2: "Sparklines are drawn in a `Canvas` with a
//  single `Path`, throttled to 4 Hz (not 60 Hz) — the numbers update at 1 Hz. The Inspector must
//  cost < 0.4 ms per frame." So: one `Canvas`, one stroked `Path` and one filled `Path`, no
//  per-point views, no `ForEach`, and **no timer of its own**. The series arrives as an array in
//  ``VInspectorState``; this view redraws when that array changes and at no other time.
//
//  `.drawingGroup()` is deliberately not applied. §7.9's checklist names it for `VSparkline`, but a
//  `Canvas` already rasterises off the main render tree, and stacking a second offscreen pass on it
//  costs a texture per redraw for no gain. Noted rather than silently skipped.
//

#if os(macOS)

import SwiftUI

// MARK: - VInspectorSparkline

/// A 60-sample line over a shaded area, in an inset well.
///
/// The empty state is a first-class case, not a degenerate one: a stream that has just connected
/// has no ring yet, and §9.21 says it shows a flat baseline and "No data yet" rather than a path
/// through one point that implies a measurement nobody made.
@MainActor
package struct VInspectorSparkline: View {

    // MARK: - Geometry

    /// 1.25 pt stroke, round caps and joins (§9.21).
    package static let lineWidth: CGFloat = 1.25

    /// The area fill runs from `colour α 0.22` to transparent, top to bottom (§9.21).
    ///
    /// ⚠️ The mockup's gradient peaks at α 0.42. 0.22 is used because §9.21 is the normative
    /// number and because the higher value visibly lightens the well behind the line. Reported.
    package static let fillAlpha: Double = 0.22

    /// The 3 pt dot on the newest sample (§9.21).
    package static let latestPointRadius: CGFloat = 3

    // MARK: - Stored Properties

    /// The samples, oldest first. Empty renders the empty state.
    package let values: [Double]

    /// The metric's colour: `accent` for bitrate, `ok` for fps, `warn` for loss (§9.21).
    package let tint: SwiftUI.Color

    /// The smallest y upper bound worth drawing, in the series' own units. It stops an idle stream
    /// from magnifying its own rounding noise into a mountain range.
    package let floor: Double

    @Environment(\.vMotionEnabled) private var motionEnabled

    // MARK: - Initialisation

    /// Creates a sparkline.
    ///
    /// - Parameters:
    ///   - values: the samples, oldest first.
    ///   - tint: the metric's colour.
    ///   - floor: the minimum y upper bound. Pass the smallest reading that is worth a full-height
    ///     plot — for bitrate, roughly one megabit.
    package init(values: [Double], tint: SwiftUI.Color, floor: Double) {
        self.values = values
        self.tint = tint
        self.floor = floor
    }

    // MARK: - View

    package var body: some View {
        ZStack {
            if values.isEmpty {
                emptyState
            } else {
                plot
            }
        }
        .frame(height: VInspectorMetrics.chartHeight)
        .frame(maxWidth: .infinity)
        .background(VTheme.Color.Layer.surfaceRaised,
                    in: VTheme.Radius.shape(VTheme.Radius.sm))
        .overlay {
            VTheme.Radius.shape(VTheme.Radius.sm)
                .strokeBorder(VTheme.Color.Stroke.subtle, lineWidth: VTheme.Border.thin)
                .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Private Helpers

    /// The whole plot in one `Canvas`: area, line, latest point.
    ///
    /// `Canvas`'s renderer is `(inout GraphicsContext, CGSize) -> Void`; every call below is on
    /// that context, so the entire chart is one layer.
    ///
    ///     init(opaque: Bool = false, colorMode: ColorRenderingMode = .nonLinear,
    ///          rendersAsynchronously: Bool = false,
    ///          renderer: @escaping (inout GraphicsContext, CGSize) -> Void)
    ///
    /// Every value the renderer needs is hoisted into a local `let` first. The renderer is a
    /// plain escaping closure with no declared isolation, so reading a `@MainActor` static — which
    /// all of this type's geometry is, along with the rest of `VTheme` — from inside it would be a
    /// concurrency error. Capturing six `Sendable` locals instead sidesteps the question entirely.
    private var plot: some View {
        let series = values
        let stroke = tint
        let base = floor
        let width = Self.lineWidth
        let alpha = Self.fillAlpha
        let dotRadius = Self.latestPointRadius
        return Canvas { context, size in
            let bound = VInspectorSparklineScale.upperBound(series, floor: base)
            let points = VInspectorSparklineScale.points(series, in: size, upperBound: bound)
            guard let first = points.first, let last = points.last else { return }

            var line = Path()
            line.move(to: first)
            for point in points.dropFirst() {
                line.addLine(to: point)
            }

            var area = line
            area.addLine(to: CGPoint(x: last.x, y: size.height))
            area.addLine(to: CGPoint(x: first.x, y: size.height))
            area.closeSubpath()

            //     func fill(_ path: Path, with shading: GraphicsContext.Shading,
            //               style: FillStyle = FillStyle())
            context.fill(area, with: .linearGradient(
                Gradient(colors: [stroke.opacity(alpha), stroke.opacity(0)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)))

            //     func stroke(_ path: Path, with shading: GraphicsContext.Shading,
            //                 style: StrokeStyle)
            context.stroke(line, with: .color(stroke),
                           style: StrokeStyle(lineWidth: width, lineCap: .round,
                                              lineJoin: .round))

            let dot = CGRect(x: last.x - dotRadius, y: last.y - dotRadius,
                             width: dotRadius * 2, height: dotRadius * 2)
            context.fill(Path(ellipseIn: dot), with: .color(stroke))
        }
        .padding(.horizontal, VTheme.Space.hair)
        .padding(.vertical, VTheme.Space.xxs)
        // §7.4 #32: the path interpolates over 200 ms, linear — the data arrives at a fixed 1 Hz
        // and any easing on it reads as jitter. Under reduced motion the path is replaced instantly.
        .animation(VTheme.Motion.resolved(VTheme.Motion.sparkline, reduced: !motionEnabled,
                                          fallback: nil),
                   value: values)
    }

    /// §9.21's empty state: a flat baseline and one line of text, never a path.
    private var emptyState: some View {
        Text("No data yet", bundle: .vigilUI)
            .vType(VTheme.Typography.caption1)
            .foregroundStyle(VTheme.Color.Text.tertiary)
    }
}

// MARK: - VInspectorMeter

/// The 6 pt storage bar.
///
/// A bar rather than a ring because the quantity is a proportion of a line — "74 % of 4 TB" — and
/// because UX.md §6.1 specifies a 6 pt bar. The track is the E0 inset fill so the bar reads as cut
/// into the surface rather than laid on it (§6.1).
@MainActor
package struct VInspectorMeter: View {

    /// 0…1. Values outside are clamped, so a device reporting more used than it has still draws.
    package let fraction: Double

    /// How worried to be about the level, which recolours the fill.
    package let tint: VInspectorHealthTint

    /// Creates a meter.
    package init(fraction: Double, tint: VInspectorHealthTint = .neutral) {
        self.fraction = fraction
        self.tint = tint
    }

    package var body: some View {
        let clamped = fraction.isFinite ? Swift.min(1, Swift.max(0, fraction)) : 0
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(VTheme.Color.Layer.inset)
                Capsule(style: .continuous)
                    .fill(fill)
                    .frame(width: proxy.size.width * clamped)
            }
        }
        .frame(height: VInspectorMetrics.meterHeight)
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(VTheme.Color.Stroke.subtle, lineWidth: VTheme.Border.thin)
                .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }

    /// Accent by default, and the semantic colour once the level says so.
    ///
    /// ⚠️ The mockup fills the bar with a gradient from `#7B61FF` to `#4E3BC7`. The second stop is
    /// not a token, so the gradient runs `accent → accentFill`, which is the same hue travelling
    /// the same direction with values the theme actually owns. Reported.
    private var fill: LinearGradient {
        let colours: [SwiftUI.Color]
        switch tint {
        case .neutral, .ok:
            colours = [VTheme.Color.Semantic.accent, VTheme.Color.Semantic.accentFill]
        case .warn:
            colours = [VTheme.Color.Semantic.warn, VTheme.Color.Semantic.warn]
        case .danger:
            colours = [VTheme.Color.Semantic.danger, VTheme.Color.Semantic.dangerFill]
        }
        return LinearGradient(colors: colours, startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - Previews

#if DEBUG && !VIGIL_NO_PREVIEWS
#Preview("Inspector charts") {
    VStack(alignment: .leading, spacing: VTheme.Space.md) {
        VInspectorSparkline(values: [3.1, 3.4, 3.2, 4.0, 3.8, 4.4, 4.1, 4.6, 4.2, 4.9]
                                .map { $0 * 1_000_000 },
                            tint: VTheme.Color.Semantic.accent,
                            floor: 1_000_000)
        VInspectorSparkline(values: [], tint: VTheme.Color.Semantic.accent, floor: 1_000_000)
        VInspectorMeter(fraction: 0.74)
        VInspectorMeter(fraction: 0.96, tint: .danger)
    }
    .padding(VTheme.Space.lg)
    .frame(width: VTheme.Metrics.inspectorWidth)
    .background(VTheme.Color.Layer.surface)
}
#endif

#endif  // os(macOS)
