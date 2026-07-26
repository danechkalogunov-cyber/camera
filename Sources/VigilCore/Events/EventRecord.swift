//
//  EventRecord.swift
//  VigilCore
//
//  The domain event: what one real-world occurrence looks like after the camera's repeated
//  announcements of it have been collapsed into a single row with a duration.
//  Implements docs/spec-core.md §4.7 and §11.3, and docs/API_CONTRACT.md §2 R-62.
//
//  `VigilISAPI.EventNotificationAlert` is the WIRE type — one `<EventNotificationAlert>` part, of
//  which a single person walking past a camera produces one per second for as long as they are in
//  frame. `EventRecord` is the DOMAIN type: one row, `count` alerts, `firstAt…lastAt` span. R-62 is
//  explicit that these are two types and neither replaces the other.
//
//  NOTHING HERE RUNS A DETECTION MODEL. `DetectionTarget` is the camera DSP's own classification,
//  received over ISAPI and reported verbatim; Vigil never infers it from pixels.
//
//  Bounded by construction: no image bytes live in a record. A 4 MiB JPEG per alert times a 512-slot
//  ring times 32 cameras is 64 GiB, so the ring holds metadata only and `hasSnapshot` records that
//  the device sent an image. Persisting the image is `EventCenter`'s job (spec-core §11.4), which
//  writes it to the on-disk thumbnail cache and not into memory.
//

#if os(macOS)

import Foundation
import VigilISAPI
import VigilProtocols

// MARK: - DetectionTarget

/// What the camera's own DSP said it saw, when smart events are enabled.
///
/// Hikvision AcuSense devices classify a moving object before they raise the alarm and report the
/// class alongside the event; that classification is the whole reason Vigil can mark people and
/// cars without running an inference model of its own.
///
/// `other` preserves a class a newer firmware invents rather than discarding it, exactly as
/// `EventKind.other` does for the event type.
public enum DetectionTarget: Sendable, Hashable, Codable {
    /// The device sent no classification: classic motion detection, or a smart event whose DSP
    /// dropped the target box on this particular announcement. **Not** "nothing was there".
    case unclassified
    case human
    /// A car, van, lorry or bus — the device does not distinguish them.
    case vehicle
    /// Bicycle, motorbike, scooter. Reported separately by 6.x firmwares.
    case nonMotorVehicle
    case animal
    case other(String)

    /// Maps a wire classification value, comparing on the normalised (lowercased, punctuation-free)
    /// form because the same class arrives as `human`, `Human` and `HUMAN` across firmwares.
    ///
    /// An empty or whitespace-only value is `.unclassified`, not `.other("")`.
    ///
    /// `nonmotorvehicle` is tested **before** `vehicle`, because the former contains the latter and
    /// the wrong order would file every bicycle as a car.
    public init(wireValue raw: String) {
        let value = ISAPIVocabulary.normalize(raw)
        if value.isEmpty {
            self = .unclassified
        } else if value.contains("nonmotor") || value.contains("bike")
                    || value.contains("bicycle") || value.contains("motorcycle") {
            self = .nonMotorVehicle
        } else if value.contains("human") || value.contains("person")
                    || value.contains("people") || value.contains("pedestrian") {
            self = .human
        } else if value.contains("vehicle") || value.contains("car") {
            self = .vehicle
        } else if value.contains("animal") || value.contains("pet") {
            self = .animal
        } else {
            self = .other(raw)
        }
    }

    /// Recovers a classification from the device's raw `eventType`, for the firmwares that encode it
    /// there rather than in a separate element.
    ///
    /// - Important: this is a **fallback**, and it is the only route available today. The
    ///   classification's primary home on the wire is
    ///   `<DetectionRegionList><DetectionRegion><detectionTarget>`, and
    ///   `VigilISAPI.DetectionRegion` does not currently decode that element — so a device that puts
    ///   the class only there arrives here as `.unclassified` until `VigilISAPI` surfaces it. That is
    ///   a one-field change in a module this file does not own; see the note in the final report.
    ///   Recording an `.unclassified` event is correct and lossless in the meantime: the event is
    ///   still stored, still deduplicated, and still shown — only the person/car badge is absent.
    ///
    /// Returns `.unclassified` when the raw type carries no class, which is the common case
    /// (`VMD`, `linedetection`, `fielddetection` on their own say nothing about the target).
    public static func inferred(fromRawEventType raw: String) -> DetectionTarget {
        let value = ISAPIVocabulary.normalize(raw)
        // Only the class words are looked for. A bare event type must not be guessed at: a
        // `fielddetection` with no class is genuinely unclassified, and inventing `.human` for it
        // would be exactly the fabricated inference this module must not contain.
        for probe in ["nonmotorvehicle", "human", "person", "pedestrian", "vehicle", "animal"]
        where value.contains(probe) {
            return DetectionTarget(wireValue: probe)
        }
        return .unclassified
    }

    /// True when the device actually said something about the target.
    public var isClassified: Bool { self != .unclassified }

    /// A stable, non-localised token for logs and for the localisation key the UI builds.
    /// Never user-facing text — `VigilUI` localises from this.
    public var token: String {
        switch self {
        case .unclassified: "unclassified"
        case .human: "human"
        case .vehicle: "vehicle"
        case .nonMotorVehicle: "nonMotorVehicle"
        case .animal: "animal"
        case .other(let raw): "other:\(raw)"
        }
    }
}

// MARK: - EventBounds

/// Every limit in this subsystem, in one value, so a reviewer can read the memory ceiling off a
/// single page and a test can shrink it to something a unit test can fill.
///
/// The defaults are sized for the worst case the customer actually has: a camera pointed at a busy
/// street, sensitivity high, announcing an active alarm once a second all day.
public struct EventBounds: Sendable, Hashable {

    /// The de-duplication window, in seconds, in ONE place.
    ///
    /// Both initialisers read it. They used to carry the literal twice — the stored-property
    /// initialiser and the explicit initialiser's default argument — which meant a change to one
    /// silently left the other behind and the window tests kept passing against the stale value. A
    /// negative control caught it; this constant is the fix.
    ///
    /// Not inside a generic type, so the `static let` is legal on macOS (see
    /// docs/BUILD-VERIFICATION.md on `static` stored properties in generics).
    public static let defaultCoalesceWindowSeconds: Double = 3.0

    /// Default clock-skew tolerance, in seconds, in one place, for the same reason.
    public static let defaultClockSkewToleranceSeconds: Double = 60

    /// Records retained per camera, oldest evicted first.
    ///
    /// 512 because the per-camera creation ceiling below is 10 new records a minute, so 512 slots
    /// hold at least 51 minutes of a **storm** and, at a realistic few events a minute, most of a
    /// day. Longer history is the on-disk `EventLog`'s job (spec-core §5.11, capacity 5000); this
    /// ring is the hot in-memory view the feed reads.
    public var recordsPerCamera: Int = 512

    /// Cameras tracked at once. Beyond it the least-recently-active camera's ring is dropped.
    ///
    /// 64 is `ChannelID`'s plausible range — the most channels one Hikvision NVR can address — and
    /// twice the 32-camera wall the app is designed for, so it can never be hit by a legitimate
    /// library and still cannot grow without bound if something enumerates garbage.
    public var cameras: Int = 64

    /// Detection polygons kept per record. Devices send one or two; a hostile or broken device
    /// could send thousands, and the ring must not grow with them.
    public var regionsPerRecord: Int = 4

    /// Points kept per polygon. A tripwire is 2, an intrusion zone 3–8; 32 is generous.
    ///
    /// With both caps, one record's geometry is at most 4 × 32 points ≈ 2 KiB, so a full ring is
    /// ≈1 MiB per camera and ≈64 MiB across the 64-camera ceiling **in the worst case**; a realistic
    /// record carries one 4-point polygon and the ring costs ≈100 KiB per camera.
    public var polygonPointsPerRegion: Int = 32

    /// Distinct open (still-being-extended) records allowed per (camera, channel, kind).
    ///
    /// One per plausible simultaneous target class — a person and a car in the same intrusion zone
    /// are two events — plus slack. Beyond it the oldest open window is closed, which merges rather
    /// than loses.
    public var openWindowsPerKey: Int = 4

    /// The de-duplication window, in seconds. See `EventCoalescer` for the derivation.
    public var coalesceWindowSeconds: Double = Self.defaultCoalesceWindowSeconds

    /// New records per camera per rolling minute (spec-core §11.3). Beyond it alerts still extend
    /// existing records; only creation stops.
    public var newRecordsPerCameraPerMinute: Int = 10

    /// New records app-wide per rolling minute (spec-core §11.3).
    public var newRecordsPerApplicationPerMinute: Int = 60

    /// How far a device clock may disagree with ours before we stop believing it and timestamp from
    /// receipt instead (spec-core §11.3).
    public var clockSkewToleranceSeconds: Double = Self.defaultClockSkewToleranceSeconds

    /// How often a camera may raise the synthetic "event storm" record. Once an hour: the record
    /// exists to explain a suppression, and one an hour explains it without becoming the storm.
    public var stormNoticeIntervalSeconds: Double = 3600

    /// Ceiling on any query's `limit`, so a caller cannot ask for a million rows.
    public var maxQueryLimit: Int = 500

    public init() {}

    /// Every bound explicitly, for tests that need a ring small enough to fill.
    ///
    /// Values below 1 are clamped to 1 rather than trapping: a bound is configuration, and a
    /// configuration mistake must not take the app down.
    public init(recordsPerCamera: Int, cameras: Int, regionsPerRecord: Int = 4,
                polygonPointsPerRegion: Int = 32, openWindowsPerKey: Int = 4,
                coalesceWindowSeconds: Double = EventBounds.defaultCoalesceWindowSeconds,
                newRecordsPerCameraPerMinute: Int = 10,
                newRecordsPerApplicationPerMinute: Int = 60,
                clockSkewToleranceSeconds: Double =
                    EventBounds.defaultClockSkewToleranceSeconds,
                stormNoticeIntervalSeconds: Double = 3600,
                maxQueryLimit: Int = 500) {
        self.recordsPerCamera = max(1, recordsPerCamera)
        self.cameras = max(1, cameras)
        self.regionsPerRecord = max(0, regionsPerRecord)
        self.polygonPointsPerRegion = max(2, polygonPointsPerRegion)
        self.openWindowsPerKey = max(1, openWindowsPerKey)
        self.coalesceWindowSeconds = max(0, coalesceWindowSeconds)
        self.newRecordsPerCameraPerMinute = max(1, newRecordsPerCameraPerMinute)
        self.newRecordsPerApplicationPerMinute = max(1, newRecordsPerApplicationPerMinute)
        self.clockSkewToleranceSeconds = max(0, clockSkewToleranceSeconds)
        self.stormNoticeIntervalSeconds = max(0, stormNoticeIntervalSeconds)
        self.maxQueryLimit = max(1, maxQueryLimit)
    }
}

// MARK: - EventRecord

/// One real-world occurrence: the camera announced it `count` times between `firstAt` and `lastAt`,
/// and the feed shows it as a single row with a duration.
public struct EventRecord: Identifiable, Sendable, Hashable, Codable {

    /// Stable identity, minted when the record is created and unchanged by every extension.
    public var id: EventID

    /// The camera the event is filed against. A device-wide fault (`channel == 0`) is filed against
    /// the device's first camera so it cannot be lost; `isDeviceWide` distinguishes it.
    public var cameraID: CameraID

    /// The device video input the alert named: `dynChannelID` on an NVR, `channelID` otherwise,
    /// `0` for a device-wide event.
    public var channel: ChannelID

    /// The taxonomy value. `VigilISAPI.EventKind` is the one event taxonomy (API_CONTRACT R-61).
    public var kind: EventKind

    /// The device's own `eventType` string, verbatim, so an unrecognised event stays diagnosable.
    public var rawEventType: String

    /// The camera DSP's classification. `.unclassified` when the device sent none.
    public var target: DetectionTarget

    /// Presentation weight. Starts at `kind.defaultSeverity` and only ever rises, so one `critical`
    /// announcement in a run of `info` ones is not lost by a later extension.
    public var severity: EventSeverity

    /// When the occurrence started, absolute.
    public var firstAt: Date

    /// When it was last announced, absolute. Extended by coalescing; this is what gives the row its
    /// duration.
    public var lastAt: Date

    /// How many alerts collapsed into this record. 1 for a one-shot event.
    public var count: Int

    /// True while the device is still announcing it. Set false by an `inactive` alert.
    public var isActive: Bool

    /// The device's own timestamp from the alert that created the record, kept even when it was not
    /// trusted for `firstAt`, so a skewed camera clock is diagnosable from the record itself.
    public var deviceTime: Date

    /// True when the device's clock disagreed with ours by more than
    /// `EventBounds.clockSkewToleranceSeconds`, or its timestamp carried no zone, and `firstAt` /
    /// `lastAt` therefore come from local receipt time instead (spec-core §11.3).
    public var usedReceiptTime: Bool

    /// True when the device's `dateTime` carried no zone designator and was read as UTC. The UI must
    /// not present such a time to the second.
    public var deviceTimeWasNaive: Bool

    /// Detection geometry from the most recent announcement that carried any, already normalised to
    /// 0…1 top-left-origin by `VigilISAPI`. Truncated to `EventBounds.regionsPerRecord`.
    public var regions: [DetectionRegion]

    /// True when at least one announcement arrived with a JPEG part. The bytes are **not** held
    /// here; see this file's header.
    public var hasSnapshot: Bool

    /// `inputIOPortID`, for `io` events.
    public var ioPort: Int?

    /// Feed read state. Set by `EventStore.markRead`.
    public var isRead: Bool

    /// True when Vigil raised the record itself rather than the device: currently only the
    /// "event storm" notice.
    public var isSynthetic: Bool

    public init(id: EventID, cameraID: CameraID, channel: ChannelID, kind: EventKind,
                rawEventType: String, target: DetectionTarget, severity: EventSeverity,
                firstAt: Date, lastAt: Date, count: Int, isActive: Bool, deviceTime: Date,
                usedReceiptTime: Bool, deviceTimeWasNaive: Bool, regions: [DetectionRegion],
                hasSnapshot: Bool, ioPort: Int?, isRead: Bool = false, isSynthetic: Bool = false) {
        self.id = id
        self.cameraID = cameraID
        self.channel = channel
        self.kind = kind
        self.rawEventType = rawEventType
        self.target = target
        self.severity = severity
        self.firstAt = firstAt
        self.lastAt = lastAt
        self.count = count
        self.isActive = isActive
        self.deviceTime = deviceTime
        self.usedReceiptTime = usedReceiptTime
        self.deviceTimeWasNaive = deviceTimeWasNaive
        self.regions = regions
        self.hasSnapshot = hasSnapshot
        self.ioPort = ioPort
        self.isRead = isRead
        self.isSynthetic = isSynthetic
    }

    /// How long the occurrence lasted, in seconds. `0` for a single announcement.
    ///
    /// Never negative: `lastAt` is only ever moved forward, and a device timestamp that goes
    /// backwards is clamped by the coalescer rather than producing a negative duration here.
    public var duration: Double { max(0, lastAt.timeIntervalSince(firstAt)) }

    /// True for a fault that belongs to the device rather than one of its inputs — `diskfull`,
    /// `nicbroken`, `illegalaccess` — which arrive with no channel at all.
    public var isDeviceWide: Bool { channel.value == 0 }

    /// The de-duplication key: what makes two announcements "the same event".
    public var coalesceKey: EventCoalesceKey {
        EventCoalesceKey(cameraID: cameraID, channel: channel, kind: kind)
    }
}

// MARK: - EventCoalesceKey

/// The identity of an ongoing occurrence: same camera, same channel, same kind.
///
/// `DetectionTarget` is deliberately **not** part of the key — it is compared separately, because a
/// smart camera drops the target box on some announcements of the same walk-past and a key that
/// included the class would split one person into two rows every time the DSP blinked. See
/// `EventCoalescer.match` for the rule that uses both.
public struct EventCoalesceKey: Sendable, Hashable {
    public let cameraID: CameraID
    public let channel: ChannelID
    public let kind: EventKind

    public init(cameraID: CameraID, channel: ChannelID, kind: EventKind) {
        self.cameraID = cameraID
        self.channel = channel
        self.kind = kind
    }
}

// MARK: - Alert projection

extension EventRecord {

    /// Clamps an alert's geometry to the configured bounds, keeping the first `regionsPerRecord`
    /// regions and truncating each polygon.
    ///
    /// Truncation is preferred to dropping: half a polygon still draws a recognisable shape, and a
    /// device that sends 4000 points has not sent a better one.
    static func clampedRegions(_ regions: [DetectionRegion],
                               bounds: EventBounds) -> [DetectionRegion] {
        guard bounds.regionsPerRecord > 0 else { return [] }
        return regions.prefix(bounds.regionsPerRecord).map { region in
            guard region.polygon.count > bounds.polygonPointsPerRegion else { return region }
            return DetectionRegion(regionID: region.regionID,
                                   sensitivityLevel: region.sensitivityLevel,
                                   polygon: Array(region.polygon.prefix(bounds.polygonPointsPerRegion)),
                                   targetRect: region.targetRect)
        }
    }
}

#endif
