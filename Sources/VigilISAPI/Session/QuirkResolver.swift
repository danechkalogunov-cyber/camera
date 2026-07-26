//
//  QuirkResolver.swift
//  VigilISAPI
//
//  The firmware quirk matrix as data, and the four — and only four — places a quirk is consulted:
//  the path builder, the body builder, the response interpretation and the request gate.
//  Implements docs/spec-isapi.md §19 and docs/API_CONTRACT.md §4.5.
//
//  The point of this type is negative: it exists so that no `if firmware.hasPrefix("5.2")` ever
//  appears at a call site. A device's behaviour arrives as an `Observation`, is folded into a
//  `DeviceQuirks` record that `VigilCore` persists on the camera row, and is read back out through
//  exactly the four accessors grouped below. A fifth consultation point is a review-blocking
//  defect, not a style preference: the flags are only meaningful if the set of places that read
//  them is enumerable.
//
//  A plain value type, driven by the owning actor: the pure layer declares no actors here
//  (IMPL_RULES) and a resolver that could be mutated from two tasks would make the `deviceBusy`
//  window non-deterministic.
//

import Foundation
import VigilProtocols

// MARK: - QuirkResolver

/// One device's quirk record plus the small amount of state needed to learn it.
///
/// Mutating members fold an observation in; non-mutating members are the consultation points. Every
/// consultation point is pure — same record in, same answer out — so a firmware workaround can be
/// tested without a transport.
public struct QuirkResolver: Sendable {

    /// The four sanctioned places a quirk may be read (docs/spec-isapi.md §19).
    ///
    /// Exposed so the diagnostics bundle can state, per device, which points a quirk actually
    /// changed the behaviour of — and so a test can assert that a new workaround was added at one
    /// of these and not at a fifth.
    public enum ConsultationPoint: String, Sendable, Hashable, CaseIterable {
        /// Which resource string a request is sent to, and which query items ride along.
        case pathBuilder
        /// What bytes a request body carries.
        case bodyBuilder
        /// How an answer's values are interpreted once parsed.
        case responseInterpretation
        /// How many requests may be in flight, and how authentication is computed.
        case requestGate
    }

    /// Something the device did that decides a flag.
    ///
    /// Each case names the *evidence*, never the conclusion, so the mapping from evidence to flag
    /// stays in one switch that can be read end to end.
    public enum Observation: Sendable, Hashable {
        /// A three-digit `/Streaming/channels/{ch}0{q}` resource answered 404 or `notSupport`.
        case streamingChannelIDRejected
        /// `/picture` answered `403 notSupport` while carrying resolution query items.
        case snapshotResolutionQueryRejected
        /// `PUT …/momentary` answered `notSupport` or 404.
        case momentaryRejected
        /// A drag-to-zoom calibration decided the `position3D` Y origin (docs/spec-isapi.md §13.5).
        case position3DOriginCalibrated(topLeft: Bool)
        /// `CMSearchDescription` with a record-type filter drew `badParameters`/`invalidXMLContent`.
        case recordTypeFilterRejected
        /// A playback range echo came back interpreted in device-local time (§15.3).
        case playbackTimesAreDeviceLocal
        /// The daily-distribution accelerator answered at this resource.
        case dailyDistributionResolved(resource: String)
        /// The event-schedule query answered at this resource.
        case eventScheduleResolved(resource: String)
        /// The alert stream's `Content-Type` carried no boundary and one had to be sniffed.
        case alertStreamBoundarySniffed
        /// The `WWW-Authenticate` challenge carried no `qop`, so RFC 2069 is the verified form.
        case digestChallengeLackedQOP
        /// `/InputProxy/channels/status` (the list form) answered 404.
        case inputProxyStatusListRejected
        /// A `<Sharpness>` document used this casing for the level element.
        case sharpnessElementCasing(capitalized: Bool)
        /// The device answered `deviceBusy`/503 at this instant on the injected clock.
        case deviceBusy(at: MediaInstant)
    }

    // MARK: State

    /// The record as it stands. `VigilCore` persists this verbatim on the camera row.
    public private(set) var quirks: DeviceQuirks

    /// Recent `deviceBusy` answers, newest last. Trimmed to the window on every observation, so it
    /// cannot grow with uptime.
    private var busyInstants: [MediaInstant] = []

    /// How many `deviceBusy` answers inside `busyWindowSeconds` force the concurrency override.
    ///
    /// Three in ten seconds is the documented trigger for low-end cameras (docs/spec-isapi.md §19);
    /// two would fire on a single burst of thumbnail requests.
    public static let busyCountForOverride = 3

    /// The window the `deviceBusy` count is taken over.
    public static let busyWindowSeconds: Double = 10

    /// The control-request ceiling a `deviceBusy` storm drops the device to.
    public static let busyConcurrencyCeiling = 2

    /// Starts from a record — a persisted one, or the defaults for a device never seen before.
    public init(quirks: DeviceQuirks = DeviceQuirks()) {
        self.quirks = quirks
    }

    // MARK: Seeding

    /// The record to start from for a device whose `deviceInfo` has just been read.
    ///
    /// Only the rows docs/spec-isapi.md §19 marks **seed** are set here; every other row in the
    /// matrix is marked **obs** and stays at its default until the device proves otherwise, because
    /// a wrong seed costs a wrong request on hardware nobody in this project owns.
    ///
    /// - Parameters:
    ///   - info: the identity just read from `/System/deviceInfo`.
    ///   - learned: what was already persisted for this device. Observations win over seeds, so a
    ///     row this device has already contradicted is left alone.
    public static func seeded(for info: DeviceInfo,
                             onto learned: DeviceQuirks = DeviceQuirks()) -> DeviceQuirks {
        var seeded = learned
        // Seeded true and never cleared: 5.2.x rejects a body with no `<?xml …?>`, and the
        // declaration is 39 bytes that no firmware has been observed to object to.
        seeded.requiresXMLDeclarationInBody = true
        // 5.4.x–5.5.x spell the sharpness level element in lower case. Reads use alternation
        // regardless, so this flag only decides what a read-modify-write body echoes when the
        // element is absent from the document the device sent — a wrong seed is recoverable, and a
        // right one saves a mis-cased write on the most common firmware generation in the field.
        let version = info.firmwareVersion
        if version.major == 5, (4...5).contains(version.minor) {
            seeded.sharpnessElementIsCapitalized = false
        }
        return seeded
    }

    // MARK: Learning

    /// Folds one observation in.
    ///
    /// - Returns: `true` when the record changed, which is the caller's cue to persist it and — for
    ///   the concurrency row — to re-apply it to the request gate. Returning `false` for a repeat
    ///   observation is what keeps a 32-channel NVR from writing the camera row 32 times.
    @discardableResult
    public mutating func observe(_ observation: Observation) -> Bool {
        let before = quirks
        switch observation {
        case .streamingChannelIDRejected:
            quirks.streamingChannelIDIsSingleDigit = true
        case .snapshotResolutionQueryRejected:
            quirks.snapshotIgnoresResolutionQuery = true
        case .momentaryRejected:
            quirks.momentaryUnsupported = true
        case let .position3DOriginCalibrated(topLeft):
            quirks.ptz3DOriginIsTopLeft = topLeft
        case .recordTypeFilterRejected:
            quirks.recordTypeFilterUnsupported = true
        case .playbackTimesAreDeviceLocal:
            quirks.playbackTimesAreDeviceLocal = true
        case let .dailyDistributionResolved(resource):
            quirks.dailyDistributionPath = resource
        case let .eventScheduleResolved(resource):
            quirks.eventSchedulePath = resource
        case .alertStreamBoundarySniffed:
            quirks.alertStreamBoundaryFromSniff = true
        case .digestChallengeLackedQOP:
            quirks.digestNoQOP = true
        case .inputProxyStatusListRejected:
            quirks.inputProxyStatusListUnsupported = true
        case let .sharpnessElementCasing(capitalized):
            quirks.sharpnessElementIsCapitalized = capitalized
        case let .deviceBusy(at):
            absorbBusy(at)
        }
        return quirks != before
    }

    /// Records a `deviceBusy` and applies the concurrency override once the window fills.
    ///
    /// The window is trimmed against the *new* instant rather than a clock read, so this stays a
    /// pure function of the observations it was given and a test can drive it with three fixed
    /// instants.
    private mutating func absorbBusy(_ instant: MediaInstant) {
        busyInstants.append(instant)
        let cutoff = instant.nanoseconds - Int64(Self.busyWindowSeconds * 1e9)
        busyInstants.removeAll { $0.nanoseconds < cutoff }
        guard busyInstants.count >= Self.busyCountForOverride else { return }
        let current = quirks.maxConcurrentRequestsOverride ?? Int.max
        quirks.maxConcurrentRequestsOverride = min(current, Self.busyConcurrencyCeiling)
    }

    // MARK: - Consultation point 1: the path builder

    /// The resource for one stream's configuration.
    ///
    /// 5.1.x cameras answer only `/Streaming/channels/1`; the three-digit form 404s there. The
    /// single-digit form addresses the main stream only, so a sub-stream request keeps the
    /// three-digit spelling even on a device with the quirk — asking for `…/channels/1` and getting
    /// the main stream's configuration back would silently write main-stream settings into the
    /// substream row.
    public func streamingChannelResource(_ id: StreamingChannelID) -> String {
        guard quirks.streamingChannelIDIsSingleDigit, id.quality == .main else {
            return ISAPIResource.streamingChannel(id)
        }
        return ISAPIResource.streamingChannelSingleDigit(id.channel)
    }

    /// The snapshot request to actually send.
    ///
    /// A device that answered `403 notSupport` to the resolution query items is asked without them
    /// from then on, rather than being asked and retried every time.
    public func snapshotRequest(_ request: SnapshotWireRequest) -> SnapshotWireRequest {
        quirks.snapshotIgnoresResolutionQuery ? request.withoutResolutionQuery : request
    }

    /// True when the proxied-channel status list may be asked for in one request.
    ///
    /// `false` on DS-76xx/77xx, where the list form 404s and per-channel status is the only way.
    public var usesInputProxyStatusList: Bool {
        !quirks.inputProxyStatusListUnsupported
    }

    /// The daily-distribution resources to try, in order.
    ///
    /// Once one has answered, it is the only one tried: the probe costs a `POST` that some NVRs
    /// answer slowly, and repeating it every time the month view opens is visible to the user.
    public var dailyDistributionResources: [String] {
        if let resolved = quirks.dailyDistributionPath { return [resolved] }
        return [ISAPIResource.dailyDistributionTracks, ISAPIResource.dailyDistributionSearch]
    }

    /// The event-schedule resources to try for one trigger, in order.
    public func eventScheduleResources(triggerID: String) -> [String] {
        if let resolved = quirks.eventSchedulePath { return [resolved] }
        return [ISAPIResource.eventSchedule(triggerID), ISAPIResource.eventSchedules]
    }

    // MARK: - Consultation point 2: the body builder

    /// The bytes of a read-modify-write body.
    ///
    /// The declaration is included whenever `requiresXMLDeclarationInBody` is set, which is its
    /// seeded value and the only value Vigil ever sends — the flag exists so that a device found to
    /// reject the declaration can be handled by clearing one field on its camera row instead of by
    /// a code change. The element's own attributes, `version` and `xmlns` included, are whatever
    /// the device sent on the `GET`, because `XMLNode` round-trips them (docs/spec-isapi.md §17.2).
    public func bodyBytes(_ node: XMLNode) -> Data {
        node.serialized(declaration: quirks.requiresXMLDeclarationInBody)
    }

    /// The bytes of a constructed body.
    public func bodyBytes(_ builder: XMLBuilder) -> Data {
        guard quirks.requiresXMLDeclarationInBody else {
            return Data(builder.elementString.utf8)
        }
        return builder.data()
    }

    /// True when a recording search may carry a record-type filter.
    ///
    /// `false` once the device has rejected one; the caller then asks for every type and filters
    /// client-side, which is slower but not wrong.
    public var recordSearchMayFilterByType: Bool {
        !quirks.recordTypeFilterUnsupported
    }

    /// The sharpness read-modify-write **element** for `level`.
    ///
    /// `ImageWrite.sharpness` writes whichever casing the device's own document used. This adds the
    /// only case it cannot cover: a `<Sharpness>` element that carries no level element at all, for
    /// which the casing has to come from somewhere, and the quirk record is that somewhere.
    ///
    /// Returns the node rather than the bytes so the caller can put it through the same
    /// read-modify-write helper as every other setting — one place that checks the root name
    /// survived the patch, and one place that serialises.
    public func sharpnessNode(_ node: XMLNode, level: Int) -> XMLNode {
        guard !node.has("SharpnessLevel|sharpnessLevel") else {
            return ImageWrite.sharpness(node, level: level)
        }
        return node.setting(quirks.sharpnessElementIsCapitalized ? "SharpnessLevel"
                                                                 : "sharpnessLevel",
                            to: String(min(100, max(0, level))), createIfMissing: true)
    }

    /// The sharpness read-modify-write body for `level`. Serialises ``sharpnessNode(_:level:)``.
    public func sharpnessBody(_ node: XMLNode, level: Int) -> Data {
        bodyBytes(sharpnessNode(node, level: level))
    }

    // MARK: - Consultation point 3: response interpretation

    /// True when `position3D` coordinates must be built with an upper-left Y origin.
    ///
    /// `nil` in the record means "not calibrated"; the documented majority behaviour — lower-left —
    /// is the answer until a calibration says otherwise.
    public var position3DOriginIsTopLeft: Bool {
        quirks.ptz3DOriginIsTopLeft ?? false
    }

    /// The search window to send for `query`.
    ///
    /// Several DVRs interpret `starttime` as device-local even though it carries `Z`. Shifting the
    /// requested window *forward* by the device's own UTC offset makes the device's local reading
    /// land on the instant the user asked for.
    public func searchWindow(_ query: RecordSearchQuery,
                             deviceUTCOffsetSeconds: Int) -> RecordSearchQuery {
        guard quirks.playbackTimesAreDeviceLocal, deviceUTCOffsetSeconds != 0 else { return query }
        var shifted = query
        let offset = Double(deviceUTCOffsetSeconds)
        shifted.start = query.start.addingTimeInterval(offset)
        shifted.end = query.end.addingTimeInterval(offset)
        return shifted
    }

    /// The segment times to show for what such a device returned.
    ///
    /// The inverse of `searchWindow(_:deviceUTCOffsetSeconds:)`: the device echoes the times it
    /// understood, so they come back device-local and have to be shifted back before anything
    /// compares them against a real `Date`. The `PlaybackLocator` is deliberately **not** rewritten
    /// — its path and query go back to the device verbatim (API_CONTRACT §2 R-29), and the device
    /// wants its own spelling of the time.
    public func correctedSegmentTimes(_ segments: [RecordSegment],
                                     deviceUTCOffsetSeconds: Int) -> [RecordSegment] {
        guard quirks.playbackTimesAreDeviceLocal, deviceUTCOffsetSeconds != 0 else { return segments }
        let offset = Double(-deviceUTCOffsetSeconds)
        return segments.map { segment in
            RecordSegment(track: segment.track,
                          start: segment.start.addingTimeInterval(offset),
                          end: segment.end.addingTimeInterval(offset),
                          codec: segment.codec,
                          contentType: segment.contentType,
                          recordType: segment.recordType,
                          locator: segment.locator)
        }
    }

    // MARK: - Consultation point 4: the request gate

    /// The number of concurrent control requests this device tolerates.
    ///
    /// - Parameter configured: the ceiling from `ISAPIClient.Configuration`, used when the device
    ///   has given no reason to lower it.
    public func controlConcurrencyLimit(configured: Int) -> Int {
        guard let override = quirks.maxConcurrentRequestsOverride else { return configured }
        return max(1, min(configured, override))
    }

    /// True when Digest must be computed in the RFC 2069 no-`qop` form.
    ///
    /// An observation, not an input: `DigestStore` decides from the challenge it actually received.
    /// This is here so the diagnostics bundle and the persisted record agree with what happened.
    public var digestUsesNoQOPForm: Bool {
        quirks.digestNoQOP
    }
}
