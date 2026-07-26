//
//  TimelineSegmentIndex.swift
//  VigilUI
//
//  The day's recorded segments, sorted, with the gaps between them made explicit, plus the
//  containment and neighbour queries the scrubber and the transport bar ask.
//  macOS-only. Implements docs/spec-isapi.md §15.1 and docs/UX.md §7.3.
//
//  HALF-OPEN, EVERYWHERE. A segment covers `start ..< end`. The instant `end` belongs to whatever
//  comes next and to nothing in this segment. That single convention removes a whole family of
//  off-by-one bugs: two device files that abut at 10:00:00 exactly produce no overlap and no hole,
//  the instant 10:00:00 belongs unambiguously to the second file, and a `contains` that used `...`
//  would report two segments for one instant and let the caller pick — differently each run,
//  depending on the sort's stability.
//
//  GAPS ARE DATA, NOT ABSENCE. `RecordDayIndex.minuteBins` is `[RecordType?]` for the same reason
//  this type materialises a `[TimelineGap]`: "no footage here" is a fact the user must be shown, and
//  it is distinct from "not loaded yet", which shimmers. A timeline that cannot name its gaps cannot
//  tell the user why playback stopped.
//

#if os(macOS)

import Foundation

import VigilISAPI

// MARK: - TimelineGap

/// A stretch of the day with no footage, between two known points.
///
/// A gap is bounded by whatever is on each side: another segment, or the edge of the day. Which it
/// is matters to the transport bar, so both neighbours are carried as optional indices rather than
/// being flattened away.
package struct TimelineGap: Sendable, Hashable, Identifiable {

    /// Stable within one index: the position this gap occupies in ``TimelineSegmentIndex/gaps``.
    /// Used for `ForEach` identity, where ``RecordSegment/id`` cannot be trusted — see
    /// ``TimelineSegmentIndex``.
    package let id: Int

    /// The first instant with no footage.
    package let start: Date

    /// The first instant that has footage again — or the end of the day when nothing follows.
    /// Exclusive, so the gap covers `start ..< end`.
    package let end: Date

    /// The segment immediately before the gap, or `nil` when the gap opens the day.
    package let precedingSegment: Int?

    /// The segment immediately after the gap, or `nil` when the gap closes the day.
    package let followingSegment: Int?

    package init(id: Int, start: Date, end: Date,
                 precedingSegment: Int?, followingSegment: Int?) {
        self.id = id
        self.start = start
        self.end = max(start, end)
        self.precedingSegment = precedingSegment
        self.followingSegment = followingSegment
    }

    /// The gap's length in seconds.
    package var duration: Double { end.timeIntervalSince(start) }

    /// Whether `instant` is inside the gap. Half-open.
    package func contains(_ instant: Date) -> Bool {
        instant >= start && instant < end
    }
}

// MARK: - TimelineSegmentIndex

/// One track's footage for one day, prepared for drawing and for seeking.
///
/// Built once per day per camera and then queried; every method is O(log n) or better on the sorted
/// array, because at the 24 h zoom a mouse move can ask "what is under the pointer" sixty times a
/// second against a day that legitimately holds four thousand segments (docs/FEATURES.md §13 U5
/// budgets 4 ms for the whole redraw).
package struct TimelineSegmentIndex: Sendable {

    /// The segments, sorted by start and clipped to ``day``.
    package let segments: [RecordSegment]

    /// The gaps between them, in order, including any leading and trailing gap inside the day.
    package let gaps: [TimelineGap]

    /// The day the index covers.
    package let day: TimelineDay

    /// True when the device's own search was truncated, so the day is known to be incomplete.
    ///
    /// Carried through from ``RecordDayIndex/truncated`` because a truncated day must not be drawn
    /// as though its missing tail were a gap: absence of data and absence of footage are different
    /// facts and the UI says so differently.
    package let isTruncated: Bool

    // MARK: Construction

    /// Builds an index from raw segments.
    ///
    /// - Parameters:
    ///   - raw: the segments, in any order. Segments outside `day` are dropped; a segment that
    ///     *straddles* a day boundary is clipped to the day rather than dropped, which is the whole
    ///     reason this takes a day at all. A recording that runs 23:30 → 00:30 is one segment on the
    ///     wire and must appear on both days' timelines, as its own half of the run on each.
    ///   - day: the day to clip to.
    ///   - isTruncated: whether the search that produced `raw` hit its cap.
    package init(raw: [RecordSegment], day: TimelineDay, isTruncated: Bool = false) {
        self.day = day
        self.isTruncated = isTruncated
        let clipped = Self.clip(raw, to: day)
        self.segments = clipped
        self.gaps = Self.findGaps(in: clipped, day: day)
    }

    /// Builds an index from a device day index, which is the normal path.
    ///
    /// `RecordDayIndex.dayStartUTC` is the device-local midnight the device itself used, and it is
    /// *not* re-derived here: the day the segments were searched for is the day they must be drawn
    /// on, and recomputing midnight from a different calendar than the search used is exactly how an
    /// hour goes missing.
    package init(dayIndex: RecordDayIndex, day: TimelineDay) {
        self.init(raw: dayIndex.segments, day: day, isTruncated: dayIndex.truncated)
    }

    /// Sorts, drops what lies outside `day`, and clips what straddles its edges.
    ///
    /// A zero-length segment survives clipping. Devices do emit them — a recording stopped in the
    /// same second it started — and dropping them here would make the segment count disagree with
    /// the device's own `numOfMatches`, which is a diagnostic someone will one day compare.
    /// ``containing(_:)`` still reports no footage at that instant, which is the truth.
    static func clip(_ raw: [RecordSegment], to day: TimelineDay) -> [RecordSegment] {
        raw.compactMap { segment -> RecordSegment? in
            // Half-open intersection. A segment ending exactly at midnight belongs to the previous
            // day only; one starting exactly at midnight belongs to this day only.
            guard segment.start < day.end, segment.end > day.start else {
                // Keep a zero-length segment that sits inside the day, which the strict `>` above
                // rejects because its end does not exceed its start.
                guard segment.start == segment.end, day.contains(segment.start) else { return nil }
                return segment
            }
            let start = max(segment.start, day.start)
            let end = min(segment.end, day.end)
            guard start != segment.start || end != segment.end else { return segment }
            return RecordSegment(track: segment.track,
                                 start: start,
                                 end: end,
                                 codec: segment.codec,
                                 contentType: segment.contentType,
                                 recordType: segment.recordType,
                                 // The locator keeps its ORIGINAL span. Clipping is a presentation
                                 // concern; rewriting the locator's times would ask the device for a
                                 // range it never offered, and `PlaybackLocator`'s query is
                                 // byte-verbatim by contract (API_CONTRACT R-29).
                                 locator: segment.locator)
        }
        .sorted { a, b in
            a.start == b.start ? a.end < b.end : a.start < b.start
        }
    }

    /// Walks the sorted segments and records every uncovered stretch inside the day.
    ///
    /// Overlapping segments — which a device with two record types active really does return — do
    /// not create phantom gaps: the cursor only ever moves forward, so a segment nested inside
    /// another contributes nothing.
    static func findGaps(in sorted: [RecordSegment], day: TimelineDay) -> [TimelineGap] {
        var out: [TimelineGap] = []
        var cursor = day.start
        var previousIndex: Int?
        for (index, segment) in sorted.enumerated() {
            if segment.start > cursor {
                out.append(TimelineGap(id: out.count, start: cursor, end: segment.start,
                                       precedingSegment: previousIndex,
                                       followingSegment: index))
            }
            if segment.end > cursor {
                cursor = segment.end
                previousIndex = index
            } else if previousIndex == nil {
                // A zero-length or fully-nested first segment still counts as "the thing before the
                // next gap", so the transport's ⌘← has something to go back to.
                previousIndex = index
            }
        }
        if cursor < day.end {
            out.append(TimelineGap(id: out.count, start: cursor, end: day.end,
                                   precedingSegment: previousIndex,
                                   followingSegment: nil))
        }
        return out
    }

    // MARK: Queries

    /// Whether the day holds no footage at all.
    package var isEmpty: Bool { segments.isEmpty }

    /// Whether the day is one unbroken recording from midnight to midnight.
    ///
    /// Surfaced because it is a real and common shape — a camera set to continuous recording — and
    /// because it is the case where a naive gap-finder produces a spurious zero-width gap at each
    /// end. A test asserts this is `true` and that ``gaps`` is empty for that day.
    package var isFullyCovered: Bool { !segments.isEmpty && gaps.isEmpty }

    /// Total recorded seconds, counting overlapping segments once.
    package var recordedSeconds: Double {
        max(0, day.spanSeconds - gaps.reduce(0) { $0 + $1.duration })
    }

    /// 0…1 coverage of the day. Uses the day's *true* length, so a 23-hour day that is fully
    /// recorded reports 1.0 rather than 0.958.
    package var coverageFraction: Double {
        guard day.spanSeconds > 0 else { return 0 }
        return min(1, max(0, recordedSeconds / day.spanSeconds))
    }

    /// The index of the segment containing `instant`, or `nil` when it lies in a gap.
    ///
    /// Half-open. Where segments overlap, the **last** one that starts at or before `instant` and
    /// still contains it wins, so the most recently started recording is the one played — matching
    /// the severity precedence `RecordDayIndex` applies to its minute bins.
    package func containing(_ instant: Date) -> Int? {
        guard !segments.isEmpty else { return nil }
        // Every segment starting after `instant` is irrelevant; scan back from the last that does
        // not. The backward walk is bounded in practice because clipping removed nested duplicates
        // of any consequence, and it is correct regardless of how deeply they nest.
        var index = Self.lastIndex(in: segments, startingAtOrBefore: instant)
        while let current = index {
            let segment = segments[current]
            if instant >= segment.start && instant < segment.end { return current }
            index = current > 0 ? current - 1 : nil
            // Once the candidate's start is more than the longest seen span behind us there can be
            // nothing left, but the loop terminates on its own at index 0 and days are bounded, so
            // no extra bookkeeping is warranted.
        }
        return nil
    }

    /// The gap containing `instant`, or `nil` when `instant` has footage or lies outside the day.
    package func gap(containing instant: Date) -> TimelineGap? {
        gaps.first { $0.contains(instant) }
    }

    /// The first segment starting at or after `instant`.
    package func firstSegment(startingAtOrAfter instant: Date) -> Int? {
        var low = 0
        var high = segments.count
        while low < high {
            let mid = low + (high - low) / 2
            if segments[mid].start < instant { low = mid + 1 } else { high = mid }
        }
        return low < segments.count ? low : nil
    }

    /// The last segment starting at or before `instant`.
    package func lastSegment(startingAtOrBefore instant: Date) -> Int? {
        Self.lastIndex(in: segments, startingAtOrBefore: instant)
    }

    /// The next segment edge strictly after `instant` — what ⌘→ jumps to.
    ///
    /// Edges, not starts: the end of the segment you are in is a place a reviewer wants to reach,
    /// because it is where the footage stops.
    package func nextEdge(after instant: Date) -> Date? {
        var best: Date?
        for segment in segments {
            for edge in [segment.start, segment.end] where edge > instant {
                if best == nil || edge < (best ?? edge) { best = edge }
            }
            // Sorted by start, so once a segment starts after a known-better edge nothing can improve
            // on it — but its *end* still could not, since ends are ≥ starts. Safe to stop.
            if let best, segment.start > best { break }
        }
        return best
    }

    /// The previous segment edge strictly before `instant` — what ⌘← jumps to.
    package func previousEdge(before instant: Date) -> Date? {
        var best: Date?
        for segment in segments {
            for edge in [segment.start, segment.end] where edge < instant {
                if best == nil || edge > (best ?? edge) { best = edge }
            }
        }
        return best
    }

    /// Every segment edge inside `window`, for magnetism.
    package func edges(in window: TimelineWindow) -> [Date] {
        var out: [Date] = []
        for segment in segments where window.intersects(from: segment.start, to: segment.end) {
            if window.contains(segment.start) { out.append(segment.start) }
            if window.contains(segment.end) { out.append(segment.end) }
        }
        return out
    }

    /// The segments that are at least partly visible in `window`, as index/segment pairs.
    ///
    /// Returned as indices as well as values because everything downstream — the seek resolution,
    /// the `ForEach` identity, the locator lookup — refers to segments by index into ``segments``.
    package func visible(in window: TimelineWindow) -> [(index: Int, segment: RecordSegment)] {
        var out: [(index: Int, segment: RecordSegment)] = []
        // A binary search for the first candidate, then a forward walk that stops at the first
        // segment starting past the window. Overlapping segments mean the first *visible* one may
        // start before the first one whose start is inside the window, so the search rewinds while
        // the previous segment still reaches into the window.
        var first = firstSegment(startingAtOrAfter: window.start) ?? segments.count
        while first > 0, segments[first - 1].end > window.start {
            first -= 1
        }
        var index = first
        while index < segments.count, segments[index].start < window.end {
            let segment = segments[index]
            if window.intersects(from: segment.start, to: segment.end) {
                out.append((index, segment))
            }
            index += 1
        }
        return out
    }

    /// The gaps at least partly visible in `window`.
    package func visibleGaps(in window: TimelineWindow) -> [TimelineGap] {
        gaps.filter { window.intersects(from: $0.start, to: $0.end) }
    }

    // MARK: Private

    /// Binary search: the last index whose segment starts at or before `instant`.
    static func lastIndex(in segments: [RecordSegment],
                          startingAtOrBefore instant: Date) -> Int? {
        var low = 0
        var high = segments.count
        while low < high {
            let mid = low + (high - low) / 2
            if segments[mid].start <= instant { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }
}

#endif  // os(macOS)
