//
//  RecordingSegmentPlanner.swift
//  VigilVideo
//
//  When a rotating recording closes one file and opens the next — and, more importantly, when it
//  must *not*, because the sample in hand is not a keyframe.
//  Implements docs/spec-core.md §9.7 and docs/FEATURES.md F-REC-01 acceptance 5 / 6.
//
//  Pure arithmetic: no CoreMedia object, no clock read, no I/O. It is exercised for real on Linux by
//  the shadow harness under scratchpad/shadow-recording; the whole-file `#if os(macOS)` is here only
//  because `VigilVideo` is a macOS-only target.
//

#if os(macOS)

// MARK: - RecordingSegmentReason

/// Why a segment ends. Carried into the clip record and into the log line, so a user asking "why do
/// I have four files" gets an answer rather than a shrug.
public enum RecordingSegmentReason: String, Sendable, Hashable, Codable {

    /// `Limits.maximumSeconds` of *written media time* elapsed. Not wall-clock time: a stream that
    /// stalled for a minute has not recorded a minute, and rotating on wall time would produce a
    /// file shorter than the limit with no explanation.
    case durationLimit

    /// The file is approaching `Limits.maximumBytes`. The default sits below 4 GiB because that is
    /// where MP4 has to switch from 32-bit `stco` chunk offsets to 64-bit `co64`, and several
    /// players — including hardware ones customers own — mishandle the transition.
    case sizeLimit

    /// The stream's coded format changed. Passthrough cannot span it: the file carries exactly one
    /// `sourceFormatHint` per track, so the samples after the change would be decoded against the
    /// parameter sets from before it.
    case formatChanged

    /// The source timeline jumped further than `RecordingTimeline.newSegmentGapSeconds`.
    case timestampDiscontinuity

    /// Free space fell below the reserve. The segment is closed and **not** reopened.
    case diskPressure

    /// The user, or app termination, asked for it.
    case requestedByOwner
}

// MARK: - RecordingSegmentPlanner

/// Decides, per sample, whether the current file continues.
///
/// **The rule this type exists to enforce.** A rotation must land on a keyframe. Closing a
/// passthrough file at an arbitrary sample gives the *next* file a P-frame for its first sample,
/// which is the unplayable-file failure `RecordingKeyframeGate` documents — and `AVAssetWriter`
/// reports nothing at all, because from its point of view both files are well-formed. So a limit
/// being reached does not close anything: it **arms** the planner, and the next keyframe performs
/// the rotation. A timer tick can arm; only a keyframe can rotate.
///
/// Two reasons bypass the wait, because waiting is worse than a hard boundary: a format change (the
/// samples after it cannot be written into this file at all) and disk pressure (there may be no
/// space for another GOP). Both close immediately and are reported as such.
public struct RecordingSegmentPlanner: Sendable {

    // MARK: - Nested Types

    /// Rotation budgets.
    public struct Limits: Sendable, Hashable {

        /// Written media seconds per file. spec-core §9.7's default is 30 minutes.
        public var maximumSeconds: Double

        /// Bytes per file. 3.5 GiB by default — see `RecordingSegmentReason.sizeLimit`.
        public var maximumBytes: Int64

        /// Builds a set of limits. A non-positive value disables that limit rather than rotating on
        /// every sample, which is what a literal reading of "≤ 0" would do.
        public init(maximumSeconds: Double = 1_800,
                    maximumBytes: Int64 = 3_758_096_384) {
            self.maximumSeconds = maximumSeconds
            self.maximumBytes = maximumBytes
        }
    }

    /// What the caller does with the sample it is holding.
    package enum Decision: Sendable, Hashable {

        /// Write it into the current file.
        case write

        /// Finish the current file, open the next, and write this sample as its first sample. Only
        /// ever returned for a keyframe.
        case rotate(RecordingSegmentReason)

        /// Finish the current file **without** writing this sample, and open the next one. Returned
        /// only for `formatChanged`, where the sample cannot legally go into the current file.
        case closeBeforeWriting(RecordingSegmentReason)

        /// Finish and do not reopen. The sample is not written.
        case stop(RecordingSegmentReason)
    }

    // MARK: - Configuration

    package var limits: Limits

    // MARK: - State

    /// Zero-based index of the file being written. Feeds the `{seq}` naming token.
    package private(set) var segmentIndex: Int = 0

    /// The reason latched by a limit, waiting for a keyframe to act on.
    package private(set) var pendingReason: RecordingSegmentReason?

    /// A reason that must not wait for a keyframe.
    private var immediateReason: RecordingSegmentReason?

    /// True once `stop` has been returned, so a late sample cannot revive the recording.
    package private(set) var isStopped: Bool = false

    // MARK: - Initialisation

    /// Builds a planner on its first segment.
    package init(limits: Limits = Limits()) {
        self.limits = limits
    }

    // MARK: - Package API

    /// True when a limit has been reached and the planner is waiting for a keyframe.
    ///
    /// The UI shows "finishing this file" from it, which is the honest description: the file is
    /// already over its limit and stays open until the encoder produces an IDR.
    package var isAwaitingKeyframeToRotate: Bool { pendingReason != nil }

    /// Decides what happens to one sample.
    ///
    /// - Parameters:
    ///   - isKeyframe: True for an IDR/IRAP. The only value that permits a rotation.
    ///   - writtenSeconds: Media seconds already in the current file
    ///     (`RecordingTimeline.writtenSeconds`), **not** wall-clock elapsed time.
    ///   - writtenBytes: Bytes already in the current file, as reported by the file system rather
    ///     than as a sum of sample sizes, so container overhead counts towards the limit.
    package mutating func evaluate(isKeyframe: Bool, writtenSeconds: Double,
                                   writtenBytes: Int64) -> Decision {
        if isStopped { return .stop(.requestedByOwner) }

        if let reason = immediateReason {
            immediateReason = nil
            pendingReason = nil
            switch reason {
            case .diskPressure, .requestedByOwner:
                isStopped = true
                return .stop(reason)
            case .formatChanged, .timestampDiscontinuity:
                segmentIndex += 1
                return .closeBeforeWriting(reason)
            case .durationLimit, .sizeLimit:
                // Not reachable through `requireImmediateClose`, which only accepts the reasons
                // above; handled rather than ignored so a future caller cannot fall through into
                // "write anyway".
                segmentIndex += 1
                return .closeBeforeWriting(reason)
            }
        }

        if pendingReason == nil, let reason = reasonForLimit(writtenSeconds: writtenSeconds,
                                                            writtenBytes: writtenBytes) {
            pendingReason = reason
        }

        guard let reason = pendingReason else { return .write }

        // The latch stays set until a keyframe arrives. This is the load-bearing line: without it a
        // rotation lands wherever the limit happened to be reached and the next file starts with a
        // P-frame.
        guard isKeyframe else { return .write }

        pendingReason = nil
        segmentIndex += 1
        return .rotate(reason)
    }

    /// Arms a rotation that must happen at the next keyframe, whatever the limits say.
    ///
    /// Used for a reason the planner cannot see for itself — a timestamp discontinuity the timeline
    /// reported, or an operator asking for a fresh file. An already-latched reason is not replaced:
    /// the first reason is the true one and the second would be a consequence of it.
    package mutating func requireRotationAtNextKeyframe(_ reason: RecordingSegmentReason) {
        guard pendingReason == nil else { return }
        pendingReason = reason
    }

    /// Arms a close that must not wait for a keyframe.
    ///
    /// - Parameter reason: `.formatChanged` and `.timestampDiscontinuity` close and reopen;
    ///   `.diskPressure` and `.requestedByOwner` close and stay stopped.
    package mutating func requireImmediateClose(_ reason: RecordingSegmentReason) {
        immediateReason = reason
    }

    /// Which limit, if any, has been reached.
    private func reasonForLimit(writtenSeconds: Double, writtenBytes: Int64)
        -> RecordingSegmentReason? {
        if limits.maximumSeconds > 0, writtenSeconds >= limits.maximumSeconds {
            return .durationLimit
        }
        if limits.maximumBytes > 0, writtenBytes >= limits.maximumBytes {
            return .sizeLimit
        }
        return nil
    }
}

#endif
