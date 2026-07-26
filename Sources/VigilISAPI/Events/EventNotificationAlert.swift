//
//  EventNotificationAlert.swift
//  VigilISAPI
//
//  The `<EventNotificationAlert>` wire model: the event taxonomy, the heartbeat test, and the
//  detection-region polygons with their magnitude sniffing and Y flip.
//  Implements docs/spec-isapi.md §14.2–§14.4.
//
//  Two details decide whether the event feed is usable. The heartbeat — a `videoloss` / `inactive`
//  part with `activePostCount` 0, emitted every few seconds by an idle device — is the liveness
//  signal and must never reach the user as an event. And `dynChannelID`, when present, is the
//  channel the user sees on an NVR; `channelID` is the NVR's internal one, and showing it would
//  attribute every event to the wrong camera.
//

import Foundation
import VigilProtocols

// MARK: - EventKind

/// The event taxonomy. `other` preserves anything a newer firmware invents rather than dropping it.
///
/// Comparison is on the **lowercased** wire value, because the same event arrives as `VMD`,
/// `linedetection` and `regionEntrance` — three different casing conventions in one device.
public enum EventKind: Sendable, Hashable, Codable {
    case motion, lineCrossing, intrusion, regionEntrance, regionExit, faceDetected, tamper
    case alarmInput, videoLoss, diskFull, diskError, illegalAccess, networkBroken, ipConflict
    case badVideo, pir, unattendedBaggage, objectRemoved, audioException, sceneChange
    case other(String)

    /// Maps a wire `eventType`. Unknown values are never dropped; they surface with their raw name.
    public init(raw: String) {
        switch ISAPIVocabulary.normalize(raw) {
        case "vmd", "motiondetection": self = .motion
        case "linedetection": self = .lineCrossing
        case "fielddetection": self = .intrusion
        case "regionentrance": self = .regionEntrance
        case "regionexiting", "regionexit": self = .regionExit
        case "facedetection": self = .faceDetected
        case "tamperdetection", "shelteralarm": self = .tamper
        case "io": self = .alarmInput
        case "videoloss": self = .videoLoss
        case "diskfull": self = .diskFull
        case "diskerror": self = .diskError
        case "illegalaccess": self = .illegalAccess
        case "nicbroken": self = .networkBroken
        case "ipconflict": self = .ipConflict
        case "badvideo": self = .badVideo
        case "piralarm": self = .pir
        case "unattendedbaggage": self = .unattendedBaggage
        case "attendedbaggage": self = .objectRemoved
        case "audioexception": self = .audioException
        case "scenechangedetection": self = .sceneChange
        default: self = .other(raw)
        }
    }

    /// How loudly the UI should present this by default.
    public var defaultSeverity: EventSeverity {
        switch self {
        case .tamper, .videoLoss, .diskFull, .diskError, .networkBroken: .critical
        case .lineCrossing, .intrusion, .regionEntrance, .regionExit, .alarmInput,
             .illegalAccess, .ipConflict, .badVideo, .unattendedBaggage, .objectRemoved,
             .sceneChange: .warning
        case .motion, .faceDetected, .pir, .audioException, .other: .info
        }
    }
}

/// Default presentation weight for an event kind.
public enum EventSeverity: Int, Sendable, Hashable, Codable, Comparable, CaseIterable {
    case info, warning, critical

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Whether an alarm is beginning or ending.
public enum EventState: String, Sendable, Hashable, Codable {
    case active, inactive

    public init(raw: String?) {
        self = ISAPIVocabulary.normalize(raw ?? "") == "active" ? .active : .inactive
    }
}

// MARK: - Normalised geometry

/// A point in a 0…1, **top-left-origin** space, ready for a SwiftUI overlay with no further
/// conversion. Declared here rather than using `CGPoint` because `VigilISAPI` is pure and may not
/// import CoreGraphics.
public struct NormalizedPoint: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A rectangle in the same 0…1 top-left-origin space.
public struct NormalizedRect: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// MARK: - DetectionRegion

/// One detection polygon from `<DetectionRegionList>`.
public struct DetectionRegion: Sendable, Hashable, Codable {
    public let regionID: Int
    /// 0…100, when the device reports it.
    public let sensitivityLevel: Int?
    /// Normalised to 0…1 in a top-left-origin space. Two points are legitimate for a tripwire.
    public let polygon: [NormalizedPoint]
    /// The smart-event target box, same normalisation, present from 5.5+.
    public let targetRect: NormalizedRect?

    public init(regionID: Int, sensitivityLevel: Int?, polygon: [NormalizedPoint],
                targetRect: NormalizedRect?) {
        self.regionID = regionID
        self.sensitivityLevel = sensitivityLevel
        self.polygon = polygon
        self.targetRect = targetRect
    }

    /// Decodes every `<DetectionRegion>`, converting the wire's lower-left-origin integers into
    /// normalised top-left-origin points.
    ///
    /// Wire coordinates are 0…1000 on both axes, except on 5.5+ smart cameras which use 0…10000.
    /// The magnitude is the only discriminator the wire offers, and it is applied **per region**:
    /// mixing the two scales inside one document has not been observed, but scaling per region
    /// costs nothing and cannot make a well-formed document worse.
    ///
    /// A region with fewer than three points is dropped — except for `.lineCrossing`, where two
    /// points are a tripwire and dropping them would erase the drawn line.
    public static func list(node: XMLNode, kind: EventKind) -> [DetectionRegion] {
        node.nodes("DetectionRegionList/DetectionRegion[]").compactMap { region in
            let raw = region.nodes("RegionCoordinatesList/RegionCoordinates[]")
                .compactMap { point -> (Int, Int)? in
                    guard let x = point["positionX"].int,
                          let y = point["positionY"].int else { return nil }
                    return (x, y)
                }
            guard !raw.isEmpty else { return nil }
            let maximum = raw.reduce(0) { max($0, max($1.0, $1.1)) }
            let scale = ISAPIUnits.regionScale(forMaximumCoordinate: maximum)
            let polygon = raw.map {
                // The Y flip: the wire's origin is the image's lower-left, the UI's is upper-left.
                NormalizedPoint(x: Double($0.0) / scale, y: 1 - Double($0.1) / scale)
            }
            let minimumPoints = kind == .lineCrossing ? 2 : 3
            guard polygon.count >= minimumPoints else { return nil }
            return DetectionRegion(regionID: region["regionID"].int ?? 0,
                                   sensitivityLevel: region["sensitivityLevel"].int,
                                   polygon: polygon,
                                   targetRect: targetRect(in: region, scale: scale))
        }
    }

    /// Reads `<TargetRect>` if present, in the same normalisation as the polygon.
    private static func targetRect(in region: XMLNode, scale: Double) -> NormalizedRect? {
        guard let rect = region.node("TargetRect"),
              let x = rect["X|x"].double, let y = rect["Y|y"].double,
              let width = rect["width|Width"].double,
              let height = rect["height|Height"].double else { return nil }
        // The rect's Y is its lower edge in wire space, so the flipped top edge is
        // `1 - (y + height)`.
        return NormalizedRect(x: x / scale, y: 1 - (y + height) / scale,
                              width: width / scale, height: height / scale)
    }
}

// MARK: - EventNotificationAlert

/// One decoded `<EventNotificationAlert>` part.
public struct EventNotificationAlert: Sendable, Hashable, Codable {
    public let deviceIP: String?
    public let deviceMAC: String?
    /// `dynChannelID` when the NVR sent one, otherwise `channelID`, otherwise 0 for a device-wide
    /// event. On an NVR the dynamic channel is the one the user sees.
    public let channel: ChannelID
    public let channelName: String?
    public let timestamp: Date
    /// True when `dateTime` carried no zone and was read as UTC. The UI must not present such a
    /// timestamp to the second without the device's offset applied.
    public let timestampWasNaive: Bool
    public let kind: EventKind
    /// The device's own `eventType` string, kept for diagnostics and for `.other`.
    public let rawType: String
    public let state: EventState
    /// 0 for heartbeats; increasing while an alarm persists.
    public let activePostCount: Int
    /// `inputIOPortID`, for `io` events.
    public let ioPort: Int?
    public let regions: [DetectionRegion]
    /// JPEG bytes from a following `image/jpeg` part, when the device sent one.
    public var snapshot: Data?

    public init(deviceIP: String?, deviceMAC: String?, channel: ChannelID, channelName: String?,
                timestamp: Date, timestampWasNaive: Bool, kind: EventKind, rawType: String,
                state: EventState, activePostCount: Int, ioPort: Int?,
                regions: [DetectionRegion], snapshot: Data? = nil) {
        self.deviceIP = deviceIP
        self.deviceMAC = deviceMAC
        self.channel = channel
        self.channelName = channelName
        self.timestamp = timestamp
        self.timestampWasNaive = timestampWasNaive
        self.kind = kind
        self.rawType = rawType
        self.state = state
        self.activePostCount = activePostCount
        self.ioPort = ioPort
        self.regions = regions
        self.snapshot = snapshot
    }

    /// The device's periodic liveness part, which must never be surfaced as an event.
    ///
    /// All four conditions are required. A real video-loss alarm clearing also arrives as
    /// `videoloss`/`inactive`, but with a non-zero `activePostCount`; treating that as a heartbeat
    /// would hide a camera going dark.
    public var isHeartbeat: Bool {
        kind == .videoLoss && state == .inactive && activePostCount == 0 && regions.isEmpty
    }

    /// Decodes one alert document.
    ///
    /// `eventType` is required — a part without one carries no event. `dateTime` is not: a device
    /// with an unset clock still has something worth reporting, so a missing or unparsable time
    /// falls back to `receivedAt` and is flagged naive.
    ///
    /// - Parameter receivedAt: the time the part arrived, injected by the caller. The pure layer
    ///   never reads a clock itself.
    public init(document: ISAPIDocument, receivedAt: Date) throws(ISAPIError) {
        let rawType = try document["eventType"].requireString("EventNotificationAlert")
        let kind = EventKind(raw: rawType)
        let rawTime = document["dateTime"].string
        let parsed = document["dateTime"].date
        // A time with no zone designator was read as UTC by the parser; say so, so the session can
        // re-interpret it against the device's own offset.
        let naive = parsed == nil || !(rawTime.map(Self.carriesZone) ?? false)
        let channelValue = document["dynChannelID"].int ?? document["channelID"].int ?? 0
        self.init(deviceIP: document["ipAddress"].string,
                  deviceMAC: document["macAddress"].string,
                  channel: ChannelID(channelValue),
                  channelName: document["channelName"].string,
                  timestamp: parsed ?? receivedAt,
                  timestampWasNaive: naive,
                  kind: kind,
                  rawType: rawType,
                  state: EventState(raw: document["eventState"].string),
                  activePostCount: document["activePostCount"].int ?? 0,
                  ioPort: document["inputIOPortID"].int,
                  regions: DetectionRegion.list(node: document.root, kind: kind),
                  snapshot: nil)
    }

    /// True when a timestamp string carries a zone designator (`Z`, `±hh:mm` or `±hhmm`).
    ///
    /// Only the last five or six characters are examined, so the hyphens in the date part cannot
    /// be mistaken for a negative offset.
    static func carriesZone(_ raw: String) -> Bool {
        if raw.hasSuffix("Z") || raw.hasSuffix("z") { return true }
        for length in [6, 5] where raw.count > length {
            let tail = raw.suffix(length)
            guard let sign = tail.first, sign == "+" || sign == "-" else { continue }
            if tail.dropFirst().allSatisfy({ $0.isNumber || $0 == ":" }) { return true }
        }
        return false
    }
}
