//
//  TimelineSeek.swift
//  VigilUI
//
//  What a seek MEANS: turning an instant the user picked into a decision about what to play.
//  Contains the ruling on a seek that lands in a gap.
//  macOS-only. Implements docs/UX.md §7.3/§7.6 and docs/FEATURES.md §13.
//
//  ════════════════════════════════════════════════════════════════════════════════════════════════
//  RULING — A SEEK INTO A GAP IS HONOURED, NOT SNAPPED.
//  ════════════════════════════════════════════════════════════════════════════════════════════════
//
//  The docs do not rule on this. UX.md §7.3 says only "click positions the playhead and seeks", with
//  no gap caveat, and no `R-` ruling in API_CONTRACT.md covers it. It is decided here, and this
//  comment is the decision.
//
//  **The playhead goes exactly where the user put it. Playback does not.**
//
//  Concretely, for a requested instant with no footage:
//    * ``TimelineSeek/requested`` is preserved bit-for-bit. The playhead does not move under the
//      pointer, the timecode readout shows the instant the user actually chose, and clicking the
//      same pixel twice gives the same answer.
//    * No RTSP `PLAY` is issued for the gap. The device's answer to a range it never recorded is
//      `457` — "requested time range not recorded" (docs/spec-rtsp.md §13) — so asking is a
//      guaranteed error and a wasted round trip.
//    * The video well shows `No recording at HH:mm` and playback is *armed* to resume at
//      ``TimelineSeek/resumesAt``, the start of the following segment, when the clock reaches it.
//    * At the end of the day's footage there is nothing to arm: the transport stops and says
//      "End of recording".
//
//  Four reasons, in order of weight.
//
//  1. **The multi-camera case is already ruled this way, and one camera must not disagree with
//     four.** UX.md §7.6: "A camera with no recording at the current instant shows a black pane with
//     `No recording at 10:14` and its lane is dimmed — it does not stall the others."
//     FEATURES.md §13: a camera with no footage at the playhead "rejoins automatically when coverage
//     resumes". Synchronised playback drives every pane from one absolute-UTC playhead; if a
//     single-camera seek silently relocated that playhead to the nearest footage, the same gesture
//     would mean two different instants depending on how many cameras were open. Honouring the
//     request is the only rule that makes one camera the n = 1 case of n.
//
//  2. **Snapping would make the gesture lie.** A scrubber that moves the playhead somewhere the user
//     did not put it has no repeatable meaning: two clicks a pixel apart either side of a gap's
//     midpoint would jump in opposite directions, and the user cannot tell from the result where
//     they actually clicked. It is also unrecoverable — there is no gesture for "no, I meant the
//     empty bit", and a reviewer establishing that nothing was recorded between 02:00 and 04:00
//     needs to be able to park there and read the clock.
//
//  3. **Explicit segment navigation already exists, so implicit snapping is redundant.** `⌘←`/`⌘→`
//     jump recording-segment edges (UX.md §7.5), and *release-time magnetism* — 6 pt to a segment
//     boundary, an event marker or a whole minute, ⌥ to defeat (DESIGN.md §7.4 #20) — already
//     catches the overwhelmingly common near-miss, before the request ever becomes a seek. Magnetism
//     is applied by ``TimelineGeometry/snappedInstant(atX:candidates:tolerance:)`` on the way in.
//     That ordering is what makes honouring the gap defensible rather than pedantic: by the time a
//     request reaches this file, the user has missed the footage by more than 6 pt, which at any
//     zoom is a deliberate choice.
//
//  4. **It matches what playback does when it runs into a gap forwards.** FEATURES.md §13: `±10 s`
//     jumps cross segment boundaries by "automatically issuing a new `PLAY` for the next segment".
//     Coverage resuming, not the cursor teleporting, is already the model.
//
//  The cost of being wrong is small and recoverable in the direction we chose: a user who lands in a
//  gap sees exactly why and presses `⌘→`. Had we snapped, a user who *wanted* the gap has no gesture
//  at all.
//

#if os(macOS)

import Foundation

import VigilISAPI

// MARK: - TimelineSeekResolution

/// What the archive holds at a requested instant.
///
/// Five cases, each of which the transport bar and the video well present differently. They are
/// exhaustive over the day: an instant inside the day is in exactly one of them, and an instant
/// outside it is reported as ``outsideDay``.
package enum TimelineSeekResolution: Sendable, Hashable {

    /// There is footage. Play `segment` from `offsetSeconds` into it.
    case footage(segment: Int, offsetSeconds: Double)

    /// The instant is inside `gap`, with footage on both sides. Show "No recording at …" and arm a
    /// resume at the following segment.
    case gap(TimelineGap)

    /// The instant precedes the day's first footage. Distinguished from ``gap(_:)`` because the copy
    /// differs — "Recording starts at 06:12", not "No recording at 03:40" — and because there is
    /// nothing to step back to.
    case beforeFootage(firstSegment: Int)

    /// The instant follows the day's last footage. Nothing is armed; the transport says
    /// "End of recording".
    case afterFootage(lastSegment: Int)

    /// The day holds no footage at all.
    case emptyDay

    /// The instant is not in this day. The caller should change day first — the date navigator and
    /// the month calendar are the gestures for that.
    case outsideDay

    /// Whether anything can be played at the requested instant.
    package var hasFootage: Bool {
        if case .footage = self { return true }
        return false
    }
}

// MARK: - TimelineSeek

/// One resolved seek: what the user asked for, and what the player should do about it.
///
/// Deliberately a *value*, computed and then handed on, rather than a method on the player: it is
/// the whole of the decision, it is inspectable in a test without a device, and the player's job is
/// reduced to obeying it.
package struct TimelineSeek: Sendable, Hashable {

    /// Exactly the instant the user asked for, after magnetism and after clamping to the day, and
    /// never adjusted afterwards. This is what the playhead and the timecode readout show.
    package let requested: Date

    /// What the archive holds there.
    package let resolution: TimelineSeekResolution

    /// Where playback should actually begin, or `nil` when there is nothing to play.
    ///
    /// Equal to ``requested`` when there is footage. In a gap it is the start of the following
    /// segment — the instant playback is *armed* for, not a place the playhead moves to.
    package let resumesAt: Date?

    /// The segment playback will use, if any — the index whose ``RecordSegment/locator`` the RTSP
    /// layer needs.
    package let playbackSegment: Int?

    /// Whether the player should be running after this seek.
    ///
    /// False in a gap and past the end of footage. The transport's play button reflects this, so the
    /// UI never shows "playing" over a still black well.
    package var isPlayable: Bool { resumesAt != nil }

    /// Whether playback begins later than the user asked — i.e. whether a "resumes at …" note is
    /// owed to them.
    package var isDeferred: Bool {
        guard let resumesAt else { return false }
        return resumesAt > requested
    }

    /// How long the user will wait, in archive seconds, before footage resumes. Zero when it does
    /// not.
    package var deferralSeconds: Double {
        guard let resumesAt, resumesAt > requested else { return 0 }
        return resumesAt.timeIntervalSince(requested)
    }

    // MARK: Resolution

    /// Resolves `instant` against `index`, applying the ruling at the top of this file.
    ///
    /// - Parameters:
    ///   - instant: the requested instant. Clamped into the index's day, so a drag that ran off
    ///     either end of the bar resolves against the day's edge rather than reporting
    ///     ``TimelineSeekResolution/outsideDay``. An instant genuinely outside the day — from a deep
    ///     link, or the date navigator mid-change — is reported as ``outsideDay`` and left alone.
    ///   - index: the day's footage.
    package static func resolve(_ instant: Date, in index: TimelineSegmentIndex) -> TimelineSeek {
        // A day of zero length cannot contain anything; treat it as outside rather than dividing by
        // it anywhere downstream.
        guard index.day.spanSeconds > 0 else {
            return TimelineSeek(requested: instant, resolution: .outsideDay,
                                resumesAt: nil, playbackSegment: nil)
        }
        // `clamp` admits the day's exclusive end, because a playhead may rest there. Resolution
        // below then correctly reports it as after the last footage.
        let requested = index.day.clamp(instant)

        guard !index.isEmpty else {
            return TimelineSeek(requested: requested, resolution: .emptyDay,
                                resumesAt: nil, playbackSegment: nil)
        }

        if let segment = index.containing(requested) {
            let offset = requested.timeIntervalSince(index.segments[segment].start)
            return TimelineSeek(requested: requested,
                                resolution: .footage(segment: segment, offsetSeconds: offset),
                                resumesAt: requested,
                                playbackSegment: segment)
        }

        // No footage here. Which side of the day's footage are we on?
        let following = index.firstSegment(startingAtOrAfter: requested)
        let preceding = index.lastSegment(startingAtOrBefore: requested)

        guard let following else {
            // Nothing starts at or after `requested`: we are past the end of the day's last
            // recording. Nothing is armed — arming a resume that can never fire would leave the
            // transport showing "waiting" forever.
            let last = index.segments.count - 1
            return TimelineSeek(requested: requested,
                                resolution: .afterFootage(lastSegment: last),
                                resumesAt: nil, playbackSegment: nil)
        }

        let resumesAt = index.segments[following].start
        guard preceding != nil else {
            // Nothing starts at or before `requested`: we are before the day's first recording.
            return TimelineSeek(requested: requested,
                                resolution: .beforeFootage(firstSegment: following),
                                resumesAt: resumesAt,
                                playbackSegment: following)
        }

        // A gap with footage on both sides. `gap(containing:)` is authoritative for the bounds —
        // it accounts for overlapping segments, which a naive "previous end to next start" would
        // get wrong when a long segment encloses a short one.
        let gap = index.gap(containing: requested)
            ?? TimelineGap(id: -1,
                           start: index.segments[index.segments.count - 1].end,
                           end: resumesAt,
                           precedingSegment: preceding,
                           followingSegment: following)
        return TimelineSeek(requested: requested,
                            resolution: .gap(gap),
                            resumesAt: resumesAt,
                            playbackSegment: following)
    }

    /// Creates a resolved seek. Use ``resolve(_:in:)`` — this exists for tests that need to build an
    /// expectation and for the deep-link path, which already knows its answer.
    package init(requested: Date, resolution: TimelineSeekResolution,
                 resumesAt: Date?, playbackSegment: Int?) {
        self.requested = requested
        self.resolution = resolution
        self.resumesAt = resumesAt
        self.playbackSegment = playbackSegment
    }
}

// MARK: - Relative seeks

extension TimelineSeek {

    /// The transport bar's relative jumps, in seconds. Negative goes back.
    ///
    /// These are *wall-clock* jumps, not footage jumps: `+10 s` means ten seconds later in the day,
    /// which may land in a gap, and that is correct. A `+10 s` that skipped gaps would advance an
    /// unpredictable distance and make two presses land somewhere no single press could.
    package enum Jump: Sendable, Hashable {
        /// `←` / `→` — ±10 s (UX.md §7.5).
        case tenSeconds(forward: Bool)
        /// `⇧←` / `⇧→` — ±1 min.
        case oneMinute(forward: Bool)
        /// One frame, at the stream's frame rate. Pauses first, per UX.md §7.5.
        case frame(forward: Bool, frameRate: Double)

        /// The signed offset in seconds.
        package var seconds: Double {
            switch self {
            case .tenSeconds(let forward): forward ? 10 : -10
            case .oneMinute(let forward): forward ? 60 : -60
            case .frame(let forward, let frameRate):
                // A frame rate of zero or nonsense degrades to a 40 ms step — one frame at 25 fps,
                // the rate every Hikvision default lands on — rather than to a division by zero.
                (forward ? 1 : -1) / (frameRate.isFinite && frameRate > 0 ? frameRate : 25)
            }
        }
    }

    /// Applies `jump` to ``requested`` and re-resolves.
    package func jumping(_ jump: Jump, in index: TimelineSegmentIndex) -> TimelineSeek {
        Self.resolve(requested.addingTimeInterval(jump.seconds), in: index)
    }

    /// The seek `⌘→` produces: the next segment edge, or this seek unchanged at the end of the day.
    package func nextEdge(in index: TimelineSegmentIndex) -> TimelineSeek {
        guard let edge = index.nextEdge(after: requested) else { return self }
        return Self.resolve(edge, in: index)
    }

    /// The seek `⌘←` produces: the previous segment edge, or this seek unchanged at the day's start.
    package func previousEdge(in index: TimelineSegmentIndex) -> TimelineSeek {
        guard let edge = index.previousEdge(before: requested) else { return self }
        return Self.resolve(edge, in: index)
    }
}

#endif  // os(macOS)
