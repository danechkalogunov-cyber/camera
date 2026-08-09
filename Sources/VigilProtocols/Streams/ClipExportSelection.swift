//
//  ClipExportSelection.swift
//  VigilProtocols
//
//  Pure in/out range and progress arithmetic for docs/FEATURES.md F-PLB-04.
//

import Foundation

/// The requested UTC range of one archive export.
public struct ClipExportSelection: Sendable, Hashable, Codable {
    public private(set) var inPoint: Date?
    public private(set) var outPoint: Date?

    public init(inPoint: Date? = nil, outPoint: Date? = nil) {
        self.inPoint = inPoint
        self.outPoint = outPoint
    }

    public mutating func setIn(_ instant: Date) { inPoint = instant }
    public mutating func setOut(_ instant: Date) { outPoint = instant }
    public mutating func clear() { self = ClipExportSelection() }

    /// Ordered even when O was pressed before I. The handles may cross while editing; export never
    /// asks a device for a negative interval.
    public var range: Range<Date>? {
        guard let inPoint, let outPoint, inPoint != outPoint else { return nil }
        return min(inPoint, outPoint)..<max(inPoint, outPoint)
    }

    public var duration: TimeInterval {
        guard let range else { return 0 }
        return range.upperBound.timeIntervalSince(range.lowerBound)
    }

    public func progress(mediaSeconds: TimeInterval) -> Double {
        guard duration > 0, mediaSeconds.isFinite else { return 0 }
        return min(1, max(0, mediaSeconds / duration))
    }
}

/// The JSON handed out beside an exported clip. It separates requested UTC from what the writer
/// could prove, so firmware that does not report the preceding keyframe never becomes invented
/// precision in evidence metadata.
public struct ClipExportSidecar: Sendable, Hashable, Codable {
    public struct TimeRange: Sendable, Hashable, Codable {
        public var start: Date
        public var end: Date
        public init(start: Date, end: Date) { self.start = start; self.end = end }
    }

    public var cameraID: CameraID
    public var cameraName: String
    public var maskedDeviceSerial: String?
    public var requested: TimeRange
    public var actualStart: Date?
    public var actualDurationSeconds: Double
    public var codec: VideoCodec?
    public var resolution: Resolution?
    public var vigilVersion: String

    public init(cameraID: CameraID, cameraName: String, maskedDeviceSerial: String?,
                requested: TimeRange, actualStart: Date?, actualDurationSeconds: Double,
                codec: VideoCodec?, resolution: Resolution?, vigilVersion: String) {
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.maskedDeviceSerial = maskedDeviceSerial
        self.requested = requested
        self.actualStart = actualStart
        self.actualDurationSeconds = actualDurationSeconds
        self.codec = codec
        self.resolution = resolution
        self.vigilVersion = vigilVersion
    }
}
