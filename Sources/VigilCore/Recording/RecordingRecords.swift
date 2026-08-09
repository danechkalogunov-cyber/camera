//
//  RecordingRecords.swift
//  VigilCore
//
//  What a recording reports about itself: why it ended, which camera it came from, the
//  segments it produced, and how far along it is.
//  macOS-only. Split from ClipRecorder.swift, which docs/API_CONTRACT.md §7.2 caps at 600
//  lines.
//

#if os(macOS)

import CoreMedia
import Foundation
import VigilProtocols

// MARK: - RecordingEndReason

/// Why a recording stopped. Reaches the clip record and the log line.
public enum RecordingEndReason: String, Sendable, Hashable, Codable {
    case userStopped
    case durationLimit
    case sizeLimit
    case diskFull
    case formatChanged
    case timestampDiscontinuity
    case streamLost
    case appQuitting
    case noKeyframe
    case writeError
    case cancelled
}

// MARK: - RecordingCameraInfo

/// The little the recorder needs to know about the camera: enough to name a file and a log line.
///
/// Deliberately not `Camera`. The recorder has no business with hosts, ports or credentials, and
/// taking the full record would make every recorder test construct one.
public struct RecordingCameraInfo: Sendable, Hashable {

    /// Identity, for log lines and for the clip record.
    public var id: CameraID

    /// Slug for `{camera}`.
    public var slug: String

    /// Display name for `{cameraName}`.
    public var name: String

    /// The zone file names are rendered in — the user's, so `..._231500` is the time on the clock in
    /// the room rather than in UTC.
    public var timeZone: TimeZone

    public init(id: CameraID, slug: String, name: String, timeZone: TimeZone = .current) {
        self.id = id
        self.slug = slug
        self.name = name
        self.timeZone = timeZone
    }
}

// MARK: - RecordingSegmentRecord

/// One finished file.
public struct RecordingSegmentRecord: Sendable, Hashable {

    /// Zero-based index within the recording. Rendered one-based as `{seq}`.
    public var index: Int

    /// Where the file ended up. For an interrupted recording this still carries the `.partial`
    /// suffix, and `isPartial` is true.
    public var url: URL

    /// Wall-clock time of the first written sample.
    public var startedAt: Date

    /// Wall-clock time of the last written sample.
    public var endedAt: Date

    /// Media seconds in the file — the number `AVAsset.duration` will report, not wall-clock elapsed.
    public var mediaSeconds: Double

    /// Size on disk after the finish, from the file system rather than from a sum of sample sizes, so
    /// container overhead is included.
    public var byteCount: Int64

    public var samplesWritten: Int
    public var samplesDropped: Int

    /// True when `finishWriting` did not complete, so the `moov` atom was never written. The file is
    /// still playable up to its last completed fragment and is kept, named `.partial`, for the
    /// recovery scan to adopt.
    public var isPartial: Bool

    public var endReason: RecordingEndReason
}

// MARK: - RecordingProgress

/// What the tile's REC badge shows.
public struct RecordingProgress: Sendable, Hashable {

    /// Media seconds in the current file.
    public var currentSegmentSeconds: Double

    /// Media seconds across every file of this recording, finished ones included.
    public var totalSeconds: Double

    /// Bytes appended to the current file, as a payload estimate.
    public var currentSegmentBytes: Int64

    public var samplesWritten: Int
    public var samplesDropped: Int

    /// Frames discarded because the clip has not opened yet. A non-zero value with a zero
    /// `samplesWritten` is the honest description of "recording, waiting for a keyframe".
    public var heldAwaitingKeyframe: Int

    /// True while the gate is shut.
    public var isAwaitingFirstKeyframe: Bool

    /// True when a limit has been reached and the recorder is waiting for a keyframe to roll over.
    public var isAwaitingKeyframeToRotate: Bool

    /// Files already closed.
    public var completedSegments: Int

    /// Free bytes at the last check.
    public var freeBytes: Int64
}

#endif  // os(macOS)
