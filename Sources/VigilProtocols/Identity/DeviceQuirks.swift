//
//  DeviceQuirks.swift
//  VigilProtocols
//
//  The firmware quirk record: the observed and seeded behaviour flags that four — and only four —
//  places consult, so a workaround never becomes an `if firmware.hasPrefix("5.2")` at a call site.
//  Implements docs/spec-isapi.md §19 and docs/API_CONTRACT.md §3.14.
//
//  Written by impl:isapi-a because `ISAPIClient.init(…quirks:…)` (API_CONTRACT §4.5) cannot compile
//  without it and the W1 file was still missing. Decoding is forward-compatible on purpose: a
//  record written by a later schema must still load, because it is persisted on the camera record.
//

// MARK: - DeviceQuirks

/// What one device's firmware does differently, as data.
///
/// Every flag is either resolved by observation or seeded from a model/firmware match and then
/// corrected by observation. The record is consulted in exactly four places — the path builder, the
/// body builder, the parser configuration and the request gate — and nowhere else.
public struct DeviceQuirks: Sendable, Hashable, Codable {

    /// Version of this record's layout. Bumped when a flag's meaning changes, never for additions.
    public var schemaVersion: Int

    /// 5.1.x cameras answer only `/Streaming/channels/1`; the three-digit form 404s.
    public var streamingChannelIDIsSingleDigit: Bool

    /// `403 notSupport` when `/picture` carries resolution query items. Retry with no query.
    public var snapshotIgnoresResolutionQuery: Bool

    /// `PUT /PTZCtrl/channels/{ch}/momentary` is absent; emulate with continuous plus a stop.
    public var momentaryUnsupported: Bool

    /// `position3D`'s Y origin is upper-left rather than lower-left. `nil` until calibrated.
    public var ptz3DOriginIsTopLeft: Bool?

    /// `CMSearchDescription` rejects the record-type filter; filter client-side instead.
    public var recordTypeFilterUnsupported: Bool

    /// Playback `starttime` is interpreted as device-local even when it carries `Z`.
    public var playbackTimesAreDeviceLocal: Bool

    /// Resolved endpoint for the daily-distribution query, or `nil` when it has not been probed.
    public var dailyDistributionPath: String?

    /// Resolved endpoint for the event schedule query, or `nil` when it has not been probed.
    public var eventSchedulePath: String?

    /// The multipart boundary had to be sniffed from the body because the header lacked one.
    public var alertStreamBoundaryFromSniff: Bool

    /// 5.2.x rejects a request body with no `<?xml …?>` declaration. Seeded `true`; always sent.
    public var requiresXMLDeclarationInBody: Bool

    /// The device challenges without `qop`, so the RFC 2069 response form is the one it verifies.
    public var digestNoQOP: Bool

    /// Hard cap on concurrent control requests, overriding the configuration. Set to 2 after three
    /// `deviceBusy` answers inside ten seconds.
    public var maxConcurrentRequestsOverride: Int?

    /// `/InputProxy/channels/status` (the list form) 404s; per-channel status is the only way.
    public var inputProxyStatusListUnsupported: Bool

    /// `<SharpnessLevel>` is capitalised on this firmware. Reads use alternation regardless; this
    /// only decides what a read-modify-write body echoes back.
    public var sharpnessElementIsCapitalized: Bool

    /// A record with every flag at its documented default.
    public init(schemaVersion: Int = 1,
                streamingChannelIDIsSingleDigit: Bool = false,
                snapshotIgnoresResolutionQuery: Bool = false,
                momentaryUnsupported: Bool = false,
                ptz3DOriginIsTopLeft: Bool? = nil,
                recordTypeFilterUnsupported: Bool = false,
                playbackTimesAreDeviceLocal: Bool = false,
                dailyDistributionPath: String? = nil,
                eventSchedulePath: String? = nil,
                alertStreamBoundaryFromSniff: Bool = false,
                requiresXMLDeclarationInBody: Bool = true,
                digestNoQOP: Bool = false,
                maxConcurrentRequestsOverride: Int? = nil,
                inputProxyStatusListUnsupported: Bool = false,
                sharpnessElementIsCapitalized: Bool = true) {
        self.schemaVersion = schemaVersion
        self.streamingChannelIDIsSingleDigit = streamingChannelIDIsSingleDigit
        self.snapshotIgnoresResolutionQuery = snapshotIgnoresResolutionQuery
        self.momentaryUnsupported = momentaryUnsupported
        self.ptz3DOriginIsTopLeft = ptz3DOriginIsTopLeft
        self.recordTypeFilterUnsupported = recordTypeFilterUnsupported
        self.playbackTimesAreDeviceLocal = playbackTimesAreDeviceLocal
        self.dailyDistributionPath = dailyDistributionPath
        self.eventSchedulePath = eventSchedulePath
        self.alertStreamBoundaryFromSniff = alertStreamBoundaryFromSniff
        self.requiresXMLDeclarationInBody = requiresXMLDeclarationInBody
        self.digestNoQOP = digestNoQOP
        self.maxConcurrentRequestsOverride = maxConcurrentRequestsOverride
        self.inputProxyStatusListUnsupported = inputProxyStatusListUnsupported
        self.sharpnessElementIsCapitalized = sharpnessElementIsCapitalized
    }

    /// Decodes tolerantly: any absent key keeps its default, so a record written before a flag
    /// existed still loads instead of costing the user their learned quirks.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys, _ fallback: Bool) throws -> Bool {
            try c.decodeIfPresent(Bool.self, forKey: key) ?? fallback
        }
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        streamingChannelIDIsSingleDigit = try flag(.streamingChannelIDIsSingleDigit, false)
        snapshotIgnoresResolutionQuery = try flag(.snapshotIgnoresResolutionQuery, false)
        momentaryUnsupported = try flag(.momentaryUnsupported, false)
        ptz3DOriginIsTopLeft = try c.decodeIfPresent(Bool.self, forKey: .ptz3DOriginIsTopLeft)
        recordTypeFilterUnsupported = try flag(.recordTypeFilterUnsupported, false)
        playbackTimesAreDeviceLocal = try flag(.playbackTimesAreDeviceLocal, false)
        dailyDistributionPath = try c.decodeIfPresent(String.self, forKey: .dailyDistributionPath)
        eventSchedulePath = try c.decodeIfPresent(String.self, forKey: .eventSchedulePath)
        alertStreamBoundaryFromSniff = try flag(.alertStreamBoundaryFromSniff, false)
        requiresXMLDeclarationInBody = try flag(.requiresXMLDeclarationInBody, true)
        digestNoQOP = try flag(.digestNoQOP, false)
        maxConcurrentRequestsOverride =
            try c.decodeIfPresent(Int.self, forKey: .maxConcurrentRequestsOverride)
        inputProxyStatusListUnsupported = try flag(.inputProxyStatusListUnsupported, false)
        sharpnessElementIsCapitalized = try flag(.sharpnessElementIsCapitalized, true)
    }
}
