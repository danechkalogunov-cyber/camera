//
//  RecordingTimeline.swift
//  VigilVideo
//
//  Rebases a live stream's presentation timestamps onto a file timeline, and names the two
//  discontinuities that would otherwise become a frozen frame or a rejected sample.
//  Implements docs/spec-core.md §9.5 and docs/FEATURES.md F-REC-01 acceptance 4.
//
//  **No compiler in this container has CoreMedia**, so every call carries the framework signature it
//  was written against and the arithmetic is exercised on Linux through the shadow harness under
//  scratchpad/shadow-recording, which compiles this file against stubs of those signatures.
//
//  The arithmetic here is the whole reason the file is a separate type rather than three `var`s
//  inside the recorder: it is pure, it has no CoreMedia object in it — only `CMTime`, which is a
//  plain struct — and it is therefore the one part of passthrough recording that can be tested
//  exhaustively instead of reasoned about.
//

#if os(macOS)

import CoreMedia

// MARK: - RecordingDiscontinuity

/// A timing anomaly that was corrected, so the recorder can report it instead of silently shipping
/// a file whose timeline lies.
///
/// Both cases are *corrections already applied*, not failures: the sample that carried the anomaly
/// is still written. A `.requiresNewSegment` gap is the only one the timeline refuses, because a
/// jump that large is a different recording (spec-core §9.7).
package enum RecordingDiscontinuity: Sendable, Hashable {

    /// The source timeline jumped forward by more than the tolerance, so the epoch was shifted and
    /// the file advanced by one nominal frame duration instead of by the whole gap. Without this a
    /// camera whose clock resynchronises mid-clip produces a file with a multi-second frozen frame
    /// that every player renders as a hang.
    case epochShifted(gapSeconds: Double)

    /// The source timeline did not advance, so the sample was placed one tick after its predecessor.
    /// A file needs strictly increasing presentation times; equal or decreasing ones make
    /// `AVAssetWriterInput.append` fail, and the failure surfaces as a truncated file.
    case nonMonotonic(rawGapSeconds: Double)
}

// MARK: - RecordingSampleTiming

/// The timing to stamp on one sample buffer, already rebased onto the file's timeline.
package struct RecordingSampleTiming: Sendable, Hashable {

    /// Presentation time on the file timeline. Strictly greater than the previous sample's.
    package var presentation: CMTime

    /// Decode time on the file timeline, or `CMTime.invalid` when the source declared none —
    /// which is every Hikvision live profile, because they have no B-frames. `.invalid` tells
    /// CoreMedia "decode order equals presentation order"; a synthesised DTS is forbidden
    /// (API_CONTRACT §2 R-06).
    package var decode: CMTime

    /// Sample duration. Always valid and strictly positive: a zero duration makes the last sample
    /// of the file zero-length, which `AVAssetReader` reports as a truncated track.
    package var duration: CMTime

    package init(presentation: CMTime, decode: CMTime, duration: CMTime) {
        self.presentation = presentation
        self.decode = decode
        self.duration = duration
    }
}

// MARK: - RecordingTimeline

/// Turns source presentation times into file presentation times.
///
/// The invariant this type exists to hold: **the value handed to
/// `AVAssetWriter.startSession(atSourceTime:)` is the presentation timestamp of the first sample
/// actually written, computed here, never a literal `CMTime.zero`.** Passing zero while appending
/// samples that start at an arbitrary RTP timestamp produces a file whose first sample is minutes
/// into the session: QuickTime opens it, reports a duration of hours, and shows nothing. Read
/// `sessionStart` after the first `admit` returned `.write`, and pass exactly that.
///
/// With `rebaseToZero` left at its default the first sample's rebased time *is* zero, so the two
/// spellings agree — but they agree because the value was computed from the sample, which is the
/// point.
package struct RecordingTimeline: Sendable {

    // MARK: - Nested Types

    /// What to do with one candidate sample.
    package enum Admission: Sendable, Hashable {

        /// Write it, with this timing. `discontinuity` is non-`nil` when a correction was applied.
        case write(RecordingSampleTiming, discontinuity: RecordingDiscontinuity?)

        /// The source time is unusable — `CMTime.invalid`, indefinite, or one of the infinities.
        /// The sample is dropped; a file cannot carry a sample with no time.
        case rejectInvalidTimestamp

        /// The gap is too large to be a dropout: this is a new recording. The caller finishes the
        /// current segment and opens the next one starting from this sample.
        case requiresNewSegment(gapSeconds: Double)
    }

    // MARK: - Configuration

    /// Longest forward gap preserved verbatim. Below it a gap is a dropout and **must** stay in the
    /// file: F-REC-01 acceptance 4 requires that a ten-minute recording containing a four-second
    /// outage is ten minutes long, not nine minutes fifty-six.
    package var maximumPreservedGapSeconds: Double = 10

    /// Forward gap that ends the segment instead of being corrected (spec-core §9.7).
    package var newSegmentGapSeconds: Double = 60

    /// True to make the file start at zero. False keeps the source timeline, which is only useful
    /// when several files must share one clock.
    package let rebaseToZero: Bool

    /// Duration used when a sample declares none, and the amount the file advances across a shifted
    /// epoch. 30 fps at 90 kHz — the same last resort as `DurationEstimator` step 4.
    package var nominalDuration: CMTime = CMTime(value: 3_000, timescale: 90_000)

    // MARK: - State

    /// Source presentation time of the first admitted sample. `nil` before the first one.
    package private(set) var epoch: CMTime?

    /// What is subtracted from every source time. Starts at `epoch` and grows across a shifted
    /// epoch, so a correction applies to every later sample rather than to one.
    package private(set) var offset: CMTime = CMTime.zero

    /// File presentation time of the first written sample — the argument for
    /// `startSession(atSourceTime:)`. `nil` until a sample has been admitted.
    package private(set) var sessionStart: CMTime?

    /// Source presentation time of the previous admitted sample, for the gap measurement.
    package private(set) var previousSource: CMTime?

    /// File presentation time of the previous admitted sample, for the monotonicity clamp.
    package private(set) var previousPresentation: CMTime?

    /// File presentation time plus duration of the previous admitted sample — the argument for
    /// `endSession(atSourceTime:)`. Ending the session at the last sample's *start* truncates the
    /// final frame's duration to zero.
    package private(set) var sessionEnd: CMTime?

    /// Samples admitted so far.
    package private(set) var admittedCount: Int = 0

    // MARK: - Initialisation

    /// Builds a timeline.
    ///
    /// - Parameter rebaseToZero: `true` (the default) makes the file start at `CMTime.zero`.
    package init(rebaseToZero: Bool = true) {
        self.rebaseToZero = rebaseToZero
    }

    // MARK: - Package API

    /// Elapsed file time, in seconds, from the session start to the end of the last written sample.
    ///
    /// This — not wall-clock elapsed time — is what a duration limit must be measured against, so a
    /// stream that stalls for a minute does not roll the file over while nothing is being written.
    package var writtenSeconds: Double {
        guard let start = sessionStart, let end = sessionEnd else { return 0 }
        // `func CMTimeGetSeconds(_ time: CMTime) -> Float64`
        // `func CMTimeSubtract(_ lhs: CMTime, _ rhs: CMTime) -> CMTime`
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(end, start))
        return elapsed.isFinite && elapsed > 0 ? elapsed : 0
    }

    /// Rebases one sample's timing, or says why it cannot be written.
    ///
    /// - Parameters:
    ///   - presentation: Source presentation time, in the source's own timescale (90 kHz for RTP).
    ///   - decode: Source decode time, or `CMTime.invalid` when the source declared none.
    ///   - duration: Sample duration. A non-positive or invalid duration falls back to
    ///     `nominalDuration`, because the display and the reader both need a positive one.
    /// - Returns: `.write` with the rebased timing, `.rejectInvalidTimestamp`, or
    ///   `.requiresNewSegment` when the gap is larger than `newSegmentGapSeconds`.
    package mutating func admit(presentation: CMTime, decode: CMTime,
                                duration: CMTime) -> Admission {
        // `var isNumeric: Bool` on CMTime is false for invalid, indefinite and both infinities —
        // exactly the four values that cannot be a sample's time.
        guard presentation.isNumeric else { return .rejectInvalidTimestamp }

        let sampleDuration = usableDuration(duration)

        guard let previousSourceTime = previousSource,
              let previousFileTime = previousPresentation else {
            return admitFirst(presentation: presentation, decode: decode,
                              duration: sampleDuration)
        }

        let rawGap = CMTimeGetSeconds(CMTimeSubtract(presentation, previousSourceTime))
        guard rawGap.isFinite else { return .rejectInvalidTimestamp }

        if rawGap > newSegmentGapSeconds {
            return .requiresNewSegment(gapSeconds: rawGap)
        }

        var discontinuity: RecordingDiscontinuity?

        if rawGap > maximumPreservedGapSeconds {
            // Collapse the jump to one nominal frame: shift the offset by everything above it.
            // `func CMTimeAdd(_ lhs: CMTime, _ rhs: CMTime) -> CMTime`
            let excess = CMTimeSubtract(CMTimeSubtract(presentation, previousSourceTime),
                                        nominalDuration)
            offset = CMTimeAdd(offset, excess)
            discontinuity = .epochShifted(gapSeconds: rawGap)
        }

        var filePresentation = CMTimeSubtract(presentation, offset)

        // `func CMTimeCompare(_ time1: CMTime, _ time2: CMTime) -> Int32` returns -1, 0 or 1.
        if CMTimeCompare(filePresentation, previousFileTime) <= 0 {
            filePresentation = CMTimeAdd(previousFileTime, oneTick(like: presentation))
            // A backwards or repeated timestamp is a bug upstream, not something to average away:
            // it is reported even though the sample is still written.
            discontinuity = .nonMonotonic(rawGapSeconds: rawGap)
        }

        let timing = RecordingSampleTiming(
            presentation: filePresentation,
            decode: rebasedDecode(decode, presentation: filePresentation),
            duration: sampleDuration)
        remember(source: presentation, timing: timing)
        return .write(timing, discontinuity: discontinuity)
    }

    /// Forgets everything. Call when opening a new segment so the next file starts at its own zero.
    package mutating func reset() {
        epoch = nil
        offset = CMTime.zero
        sessionStart = nil
        previousSource = nil
        previousPresentation = nil
        sessionEnd = nil
        admittedCount = 0
    }

    // MARK: - Private Helpers

    /// Admits the very first sample and fixes the session start from it.
    private mutating func admitFirst(presentation: CMTime, decode: CMTime,
                                     duration: CMTime) -> Admission {
        epoch = presentation
        offset = rebaseToZero ? presentation : CMTime.zero
        let filePresentation = CMTimeSubtract(presentation, offset)
        let timing = RecordingSampleTiming(
            presentation: filePresentation,
            decode: rebasedDecode(decode, presentation: filePresentation),
            duration: duration)
        sessionStart = filePresentation
        remember(source: presentation, timing: timing)
        return .write(timing, discontinuity: nil)
    }

    /// Records the sample that was just admitted.
    private mutating func remember(source: CMTime, timing: RecordingSampleTiming) {
        previousSource = source
        previousPresentation = timing.presentation
        sessionEnd = CMTimeAdd(timing.presentation, timing.duration)
        admittedCount += 1
    }

    /// The rebased decode time, or `.invalid`.
    ///
    /// A DTS after its own PTS is nonsense that `AVAssetWriter` rejects, and the correct response is
    /// to drop the claim rather than to invent an ordering: `.invalid` means "decode order equals
    /// presentation order", which is true for every stream that has no B-frames.
    private func rebasedDecode(_ decode: CMTime, presentation: CMTime) -> CMTime {
        guard decode.isNumeric else { return CMTime.invalid }
        let rebased = CMTimeSubtract(decode, offset)
        guard CMTimeCompare(rebased, presentation) <= 0 else { return CMTime.invalid }
        return rebased
    }

    /// `duration` when it is usable, else `nominalDuration`.
    private func usableDuration(_ duration: CMTime) -> CMTime {
        guard duration.isNumeric, CMTimeCompare(duration, CMTime.zero) > 0 else {
            return nominalDuration
        }
        return duration
    }

    /// One tick of `time`'s timescale — the smallest increment that keeps the file monotonic.
    ///
    /// Signature: `CMTime.init(value: CMTimeValue, timescale: CMTimeScale)`, where
    /// `CMTimeValue == Int64` and `CMTimeScale == Int32`. A non-positive timescale cannot reach
    /// here: `isNumeric` is false for it.
    private func oneTick(like time: CMTime) -> CMTime {
        CMTime(value: 1, timescale: time.timescale > 0 ? time.timescale : 90_000)
    }
}

#endif
