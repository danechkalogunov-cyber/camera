//
//  TimelineBarLayout.swift
//  VigilUI
//
//  Turning segments and gaps into pixel runs: the minimum-width rule that keeps a three-second alarm
//  visible, and the guarantee that widening a segment never swallows a gap.
//  macOS-only. Implements docs/UX.md §7.3 and docs/DESIGN.md §9.14.
//
//  THE TWO REQUIREMENTS THAT FIGHT EACH OTHER.
//
//  (a) A short segment must be visible. At the 24 h zoom across 1 200 pt one point is 72 s, so a 20 s
//      alarm clip is 0.28 pt — invisible, and it is the single most important thing on the bar.
//      UX.md §7.3 sets the floor at 2 pt.
//  (b) A gap must be visible. "There is no footage between 02:00 and 04:00" is a fact a reviewer
//      relies on, and a bar that paints over its own gaps is worse than useless because it is
//      confidently wrong.
//
//  Widen every short segment and adjacent ones merge, erasing the gap between them. Honour every gap
//  and short segments vanish. Neither is acceptable, so the resolution is explicit and asymmetric:
//
//    • A run's LEFT edge is always the exact geometric position of its segment's start. Never
//      shifted, never nudged, not by a fraction of a point. This is what keeps the bar and the
//      playhead in agreement — a run that moved to make room would put the paint somewhere the click
//      arithmetic disagrees with, and that is the "lands a second off" bug wearing a different hat.
//    • A run may only grow RIGHTWARDS, and only into space that is genuinely empty.
//    • Growth stops `minimumGapWidth` short of the next run's exact left edge whenever a real time
//      gap separates them. So a gap wide enough to see is never painted over — the segment gives up
//      its minimum width first, and says so via ``TimelineSegmentRun/isCompressed``.
//    • Where two segments actually abut in time, growth may run right up to the next edge, because
//      there is no gap to protect and a visible seam would be a lie in the other direction.
//
//  Every one of those is stated as an invariant and tested. `isCompressed` exists so the drawing
//  layer can add the 1 pt outer glow UX.md §7.3 asks for and make a sub-minimum run visible by
//  bleeding outside its own box, which is the only honest way to show something narrower than the
//  minimum without moving it.
//

#if os(macOS)

import Foundation

import VigilISAPI

// MARK: - TimelineSegmentRun

/// One segment's painted box on the bar.
package struct TimelineSegmentRun: Sendable, Hashable, Identifiable {

    /// Identity for `ForEach`, derived from the segment's index in the day.
    ///
    /// ⛔ Deliberately **not** ``RecordSegment/id``. That is `"\(track)-\(Int(start))"`, which
    /// collides for two segments of the same track starting in the same second — which happens, with
    /// a continuous and a motion recording opening together. Duplicate ids in a `ForEach` are
    /// undefined behaviour in SwiftUI and manifest as a view that stops updating or a crash in the
    /// diffing engine, both of which are far harder to diagnose than the collision that caused them.
    package let id: Int

    /// The index of the segment in ``TimelineSegmentIndex/segments``.
    package let segmentIndex: Int

    /// Why the segment exists. Drives the colour.
    package let recordType: RecordType

    /// The run's left edge, in points. Always the exact geometric position of the segment's start,
    /// clipped to the bar.
    package let x: Double

    /// The run's painted width, in points. At least the exact geometric width, and at most enough to
    /// reach the minimum without crossing a protected gap.
    package let width: Double

    /// The exact geometric width, before any minimum was applied. Kept so the drawing layer can tell
    /// how much of the box is real and a test can assert the widening rule.
    package let exactWidth: Double

    /// True when the run could not reach the minimum width because a gap had to be preserved. The
    /// drawing layer answers this with the 1 pt outer glow of UX.md §7.3.
    package let isCompressed: Bool

    /// True when the segment continues past the bar's leading edge — draw a square left corner and
    /// no left cap.
    package let isClippedAtStart: Bool

    /// True when the segment continues past the bar's trailing edge.
    package let isClippedAtEnd: Bool

    /// The run's right edge.
    package var maxX: Double { x + width }
}

// MARK: - TimelineGapRun

/// One gap's box on the bar — where the dotted "no recording" baseline is drawn.
package struct TimelineGapRun: Sendable, Hashable, Identifiable {
    package let id: Int
    package let x: Double
    package let width: Double
    package var maxX: Double { x + width }
}

// MARK: - TimelineExactRun

/// A segment's *exact* box, before the minimum-width rule is applied.
///
/// File-scope rather than nested inside the layout function because ``TimelineBarLayout/availableRoom``
/// takes one, and a function nested in a method body cannot be reached by a test. The gap rule is the
/// part of this file most worth testing directly, so it gets a signature a test can call.
struct TimelineExactRun {
    let segmentIndex: Int
    let recordType: RecordType
    /// Exact left edge, clipped to the bar.
    let x: Double
    /// Exact width, clipped to the bar.
    let width: Double
    let clippedStart: Bool
    let clippedEnd: Bool
    /// The segment's unclipped start and end, so the abutment test is done in time rather than in
    /// pixels.
    let segmentStart: Date
    let segmentEnd: Date
}

// MARK: - TimelineBarLayout

/// The bar's painted geometry for one camera lane.
package struct TimelineBarLayout: Sendable, Hashable {

    /// The segment boxes, ordered left to right, never overlapping.
    package let runs: [TimelineSegmentRun]

    /// The gap boxes wide enough to draw. Gaps narrower than ``minimumGapWidth`` are omitted rather
    /// than drawn sub-pixel, because a dotted baseline half a point wide reads as an artefact.
    package let gapRuns: [TimelineGapRun]

    /// The minimum painted width of a segment, in points. UX.md §7.3: 2 pt.
    package let minimumWidth: Double

    /// The minimum preserved width of a gap, in points.
    package let minimumGapWidth: Double

    /// UX.md §7.3's floor. `VTheme.Space.hair` is the same value; taken as a parameter so this file
    /// stays free of the theme and therefore of SwiftUI.
    package static let defaultMinimumWidth: Double = 2

    /// One point — the thinnest a dotted baseline can be and still be a line.
    /// `VTheme.Stroke.thin` is the same value.
    package static let defaultMinimumGapWidth: Double = 1

    // MARK: Layout

    /// Lays out the visible part of `index` across `geometry`.
    ///
    /// - Parameters:
    ///   - index: the day's footage.
    ///   - geometry: the pixel mapping.
    ///   - minimumWidth: the visibility floor for a segment.
    ///   - minimumGapWidth: the width a real gap is guaranteed to keep.
    package static func lay(out index: TimelineSegmentIndex,
                            in geometry: TimelineGeometry,
                            minimumWidth: Double = defaultMinimumWidth,
                            minimumGapWidth: Double = defaultMinimumGapWidth) -> TimelineBarLayout {
        let window = geometry.window
        let visible = index.visible(in: window)

        // Pass 1 — exact geometry, clipped to the bar. Nothing is adjusted yet, because the decision
        // about how far a run may grow needs its right-hand neighbour's exact position, which is
        // only known once every exact position is.
        var exact: [TimelineExactRun] = []
        exact.reserveCapacity(visible.count)
        for (segmentIndex, segment) in visible {
            let clippedStart = segment.start < window.start
            let clippedEnd = segment.end > window.end
            let from = max(segment.start, window.start)
            let to = min(segment.end, window.end)
            let x = geometry.clampedX(at: from)
            let right = geometry.clampedX(at: to)
            exact.append(TimelineExactRun(segmentIndex: segmentIndex,
                                         recordType: segment.recordType,
                                         x: x,
                                         width: max(0, right - x),
                                         clippedStart: clippedStart,
                                         clippedEnd: clippedEnd,
                                         segmentStart: segment.start,
                                         segmentEnd: segment.end))
        }

        // Pass 2 — apply the minimum width, rightwards only, respecting gaps.
        var runs: [TimelineSegmentRun] = []
        runs.reserveCapacity(exact.count)
        for (position, item) in exact.enumerated() {
            let room = availableRoom(from: item.x,
                                     exactRight: item.x + item.width,
                                     ownEnd: item.segmentEnd,
                                     next: position + 1 < exact.count ? exact[position + 1] : nil,
                                     barWidth: geometry.width,
                                     minimumGapWidth: minimumGapWidth)
            // Grow towards the minimum, but never past the room available, and never *shrink* below
            // the exact width — a segment 40 pt wide is not reduced because its neighbour is close.
            let target = max(item.width, min(minimumWidth, max(room, item.width)))
            runs.append(TimelineSegmentRun(id: item.segmentIndex,
                                           segmentIndex: item.segmentIndex,
                                           recordType: item.recordType,
                                           x: item.x,
                                           width: target,
                                           exactWidth: item.width,
                                           isCompressed: target < minimumWidth,
                                           isClippedAtStart: item.clippedStart,
                                           isClippedAtEnd: item.clippedEnd))
        }

        // Pass 3 — the gap boxes, from the index's own gap list so overlapping segments cannot
        // invent one. Only those at least `minimumGapWidth` wide are drawn.
        var gapRuns: [TimelineGapRun] = []
        for gap in index.visibleGaps(in: window) {
            let x = geometry.clampedX(at: max(gap.start, window.start))
            let right = geometry.clampedX(at: min(gap.end, window.end))
            let width = right - x
            guard width >= minimumGapWidth else { continue }
            gapRuns.append(TimelineGapRun(id: gap.id, x: x, width: width))
        }

        return TimelineBarLayout(runs: runs, gapRuns: gapRuns,
                                 minimumWidth: minimumWidth,
                                 minimumGapWidth: minimumGapWidth)
    }

    /// How far right a run beginning at `x` may grow. **The gap-preservation rule.**
    ///
    /// Three cases:
    ///
    /// * No next run — grow to the end of the bar.
    /// * The next segment abuts or overlaps this one in *time*, **or** the gap between them is too
    ///   narrow to be drawn at all — grow right up to the next run's left edge. In the abutting case
    ///   there is no gap to protect and a 1 pt seam would draw a break in a continuous recording,
    ///   which is the same class of lie as hiding a real gap. In the sub-pixel case there is a real
    ///   gap but no way to represent it: pass 3 discards gaps narrower than `minimumGapWidth`, so
    ///   reserving space for one would sacrifice a segment's visibility to protect something that is
    ///   never painted. The two passes have to agree about which gaps exist, and this is where they
    ///   agree — a defect found by the invariant tests, which had a 20-second alarm clip left
    ///   invisible in order to reserve 0.28 pt for an undrawn gap.
    /// * A drawable gap separates them — stop `minimumGapWidth` short of the next run's left edge, so
    ///   the gap keeps at least that much *uncovered* width no matter how short either segment is.
    ///
    /// The result is floored at zero, so a run with no room stays at its exact width and is flagged
    /// ``TimelineSegmentRun/isCompressed``.
    ///
    /// - Parameters:
    ///   - x: the run's exact left edge.
    ///   - exactRight: the run's exact right edge, which is where any following gap begins.
    ///   - ownEnd: the segment's unclipped end, so abutment is judged in time rather than in pixels.
    ///   - next: the following run, if any.
    static func availableRoom(from x: Double, exactRight: Double, ownEnd: Date,
                              next: TimelineExactRun?, barWidth: Double,
                              minimumGapWidth: Double) -> Double {
        guard let next else { return max(0, barWidth - x) }
        // Abutment is a fact about time, not about pixels: two segments 0.4 pt apart at the 24 h zoom
        // are half a minute apart in the archive, and that gap is real even though it is sub-pixel.
        let abuts = next.segmentStart <= ownEnd
        // Whether it is DRAWABLE, however, is a fact about pixels — and it has to be the same
        // judgement pass 3 makes, or the two disagree.
        let gapIsDrawable = !abuts && (next.x - exactRight) >= minimumGapWidth
        let limit = gapIsDrawable ? next.x - minimumGapWidth : next.x
        return max(0, limit - x)
    }

    package init(runs: [TimelineSegmentRun], gapRuns: [TimelineGapRun],
                 minimumWidth: Double, minimumGapWidth: Double) {
        self.runs = runs
        self.gapRuns = gapRuns
        self.minimumWidth = minimumWidth
        self.minimumGapWidth = minimumGapWidth
    }

    // MARK: Invariants

    /// Checks the four layout invariants, returning the names of any that fail.
    ///
    /// A method rather than a set of `precondition`s: `precondition` in `Sources/` would crash a
    /// shipping app over a cosmetic disagreement, and the point of these is to be asserted by tests
    /// across a wide range of generated inputs. Returning names rather than a `Bool` makes a failure
    /// diagnosable from the test output alone.
    package func invariantFailures() -> [String] {
        var failures: [String] = []
        for (position, run) in runs.enumerated() {
            if run.width < run.exactWidth - 1e-9 {
                failures.append("run \(position) is narrower than its exact width")
            }
            if run.width < 0 || !run.width.isFinite {
                failures.append("run \(position) has a nonsense width")
            }
            guard position + 1 < runs.count else { continue }
            let next = runs[position + 1]
            if run.x > next.x + 1e-9 {
                failures.append("run \(position) starts after run \(position + 1)")
            }
            if run.maxX > next.x + 1e-9 {
                failures.append("run \(position) overlaps run \(position + 1)")
            }
        }
        for (position, gap) in gapRuns.enumerated() where gap.width < minimumGapWidth - 1e-9 {
            failures.append("gap run \(position) is below the minimum gap width")
        }
        // Every drawn gap must RETAIN at least `minimumGapWidth` of uncovered width.
        //
        // Note carefully what this does and does not say. It is not "no run may overlap a gap by more
        // than a point" — that was the first formulation and it was simply the wrong property: a run
        // widened by 1.17 pt into a 2.5 pt gap leaves 1.33 pt of gap still visible, which satisfies
        // the requirement completely, yet the old check called it a failure. What the user needs is
        // that the gap remains *visible*, and visibility is about what is left over, not about what
        // was taken. Getting this backwards would have driven a correct implementation into a
        // contortion to satisfy a test that was wrong.
        for gap in gapRuns {
            var covered = 0.0
            for run in runs where run.x < gap.maxX - 1e-9 && run.maxX > gap.x + 1e-9 {
                covered += min(run.maxX, gap.maxX) - max(run.x, gap.x)
            }
            let remaining = gap.width - covered
            if remaining < minimumGapWidth - 1e-9 {
                failures.append("gap \(gap.id) has only \(remaining) pt left uncovered of "
                                + "\(gap.width) pt, below the \(minimumGapWidth) pt minimum")
            }
        }
        return failures
    }
}

#endif  // os(macOS)
