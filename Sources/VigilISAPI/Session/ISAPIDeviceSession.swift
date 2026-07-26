//
//  ISAPIDeviceSession.swift
//  VigilISAPI
//
//  The per-device actor: the TTL caches, the negative-capability cache, the read-modify-write-then-
//  re-GET discipline, and the state the connect sequence and the feature families build on.
//  Implements docs/spec-isapi.md §18 and docs/API_CONTRACT.md §4.5 (with R-24, R-28, R-30).
//
//  One instance per device, and the only thing above it — `VigilCore` — is expected to hold exactly
//  one. Three invariants are the reason this type exists at all rather than each screen calling the
//  endpoint families itself:
//
//    * **A cache miss is the only reason a request happens.** The TTL table in docs/spec-isapi.md
//      §18.1 is authoritative, and a device that has said "not supported" is not asked again for
//      24 h (§18.3). A camera that answers forty pointless requests per session is a camera whose
//      RTSP service stutters while the user watches.
//    * **Every configuration write is read-modify-write on the full element, then re-`GET`**
//      (R-30). The value the caller gets back is the device's clamped value, never the requested
//      one, because the UI must show what the device accepted.
//    * **Quirks are consulted in four places and learned in one.** `QuirkResolver` owns the four;
//      this actor owns the learning, and hands the record back through `observedQuirks` for
//      `VigilCore` to persist on the camera row.
//
//  Members the feature families need are `internal` rather than `private`: `private` is file-scoped
//  in Swift and the families live in `ISAPIDeviceSession+Features.swift` and
//  `ISAPIDeviceSession+Connect.swift`. Nothing here is `public` that a caller outside the module
//  does not need.
//

import Foundation
import VigilProtocols

// MARK: - QuirkApplying

/// The one thing the session tells the request layer when it learns a quirk.
///
/// The request gate is the fourth consultation point (docs/spec-isapi.md §19) and it lives inside
/// `ISAPIClient`, which the session is not required to own — tests inject a plain `ISAPIRequesting`.
/// A one-method protocol keeps the point explicit and injectable instead of a conditional cast.
public protocol QuirkApplying: Sendable {

    /// Applies a newly learned record. Implementations must make the concurrency ceiling follow it.
    func applyQuirks(_ quirks: DeviceQuirks) async
}

extension ISAPIClient: QuirkApplying {

    /// Forwards to `setQuirks(_:)`, which re-limits the control gate immediately.
    public func applyQuirks(_ quirks: DeviceQuirks) async {
        await setQuirks(quirks)
    }
}

// MARK: - ISAPIDeviceSession

/// One device's control plane.
public actor ISAPIDeviceSession {

    // MARK: Dependencies

    /// The HTTP surface. Every request goes through the wrappers below, never directly.
    let requests: any ISAPIRequesting

    /// The request gate, when the session owns one. `nil` when a caller injected a bare
    /// `ISAPIRequesting` that has no gate to re-limit.
    private let gate: (any QuirkApplying)?

    /// Freshness and rate limiting. The only monotonic time source; no `Task.sleep` here.
    ///
    /// `internal` rather than `private` because the feature families hand it to the `PTZController`
    /// and the `AlertStreamMonitor` they build, and both must share this session's clock — a monitor
    /// on a different clock would back off against time the rest of the session cannot see.
    let clock: any MonotonicClock

    /// Supplies the `Date` values models carry (`probedAt`, alert-stream state) and nothing else.
    let wallClock: any WallClock

    /// Search-id source. Injected so a recorded search body is reproducible from a seed.
    var random: any RandomSource

    /// Structured logging. Never receives a credential: `Credential` masks itself.
    let logger: any LoggerProtocol

    /// The client tunables, needed for the concurrency ceiling the gate point computes.
    let configuration: ISAPIClient.Configuration

    /// The TTL table in force.
    let ttl: CacheTTL

    // MARK: State

    /// The quirk record and the four consultation points.
    var resolver: QuirkResolver

    /// Templates this device has refused (docs/spec-isapi.md §18.3).
    var negative = NegativeCapabilityCache()

    var deviceInfoBox: Timestamped<DeviceInfo>?
    var capabilitiesBox: Timestamped<DeviceCapabilitiesWire>?
    /// The firmware the cached capabilities were read on: §18.1 keys that row by firmware version,
    /// so an upgrade discards it however fresh it is.
    var capabilitiesFirmware: String?
    var timeBox: Timestamped<DeviceTime>?
    var statusBox: Timestamped<DeviceStatus>?
    var channelsBox: Timestamped<[DeviceChannel]>?
    var streamingBox: Timestamped<[StreamingChannelConfig]>?
    var recordTracksBox: Timestamped<[RecordTrack]>?
    var storageBox: Timestamped<StorageInfo>?
    var eventTriggersBox: Timestamped<[EventTrigger]>?
    var ptzCapabilityBoxes: [ChannelID: Timestamped<PTZCapabilitiesWire>] = [:]
    var imageBoxes: [ChannelID: Timestamped<ImageSettings>] = [:]
    var dayIndexBoxes: [DayIndexKey: Timestamped<RecordDayIndex>] = [:]
    var monthCalendarBoxes: [MonthKey: Timestamped<MonthRecordCalendar>] = [:]

    /// One `PTZController` per channel, so a held joystick and a preset recall share one keep-alive.
    var ptzControllers: [ChannelID: PTZController] = [:]

    /// The one alert stream monitor for this device (R-28). Created on first ask, never per channel.
    var alertMonitor: AlertStreamMonitor?

    /// Recent keyframe requests per channel, for the R-24 rate limit.
    private var keyFrameRequests: [ChannelID: [MediaInstant]] = [:]

    /// How many keyframe requests the rate limit swallowed. Read by the diagnostics panel, and by
    /// the tests instead of a wall clock.
    public private(set) var suppressedKeyFrameRequests = 0

    // MARK: Constants

    /// Minimum gap between two keyframe requests for one channel (R-24).
    public static let keyFrameMinimumIntervalSeconds: Double = 2

    /// Ceiling on keyframe requests for one channel inside `keyFrameBurstWindowSeconds`. Beyond it
    /// the session stops asking and `VigilCore` escalates to a reconnect (R-24).
    public static let keyFrameBurstLimit = 5

    /// The window `keyFrameBurstLimit` is counted over.
    public static let keyFrameBurstWindowSeconds: Double = 30

    /// Templates a refusal must never suppress.
    ///
    /// §18.3 scopes the negative cache to *capability-bearing* resources. These four are not: they
    /// are how Vigil finds out whether the device is reachable at all, and the streaming-channel
    /// resource additionally has two spellings whose 404 is the signal that selects the other one
    /// (docs/spec-isapi.md §19, `streamingChannelIDIsSingleDigit`). Suppressing any of them for 24 h
    /// would turn one bad answer into a device that cannot be re-probed without restarting Vigil.
    static let unsuppressableTemplates: Set<String> = [
        ISAPIResource.template(of: ISAPIResource.deviceInfo),
        ISAPIResource.template(of: ISAPIResource.userCheck),
        ISAPIResource.template(of: ISAPIResource.systemStatus),
        ISAPIResource.template(of: ISAPIResource.streamingChannels),
        ISAPIResource.template(of: ISAPIResource.streamingChannelSingleDigit(.first)),
    ]

    // MARK: Init

    /// Builds a session that owns its own `ISAPIClient`.
    ///
    /// - Parameters:
    ///   - endpoint: where the device is.
    ///   - credential: the device account. Never logged, never put in a URL.
    ///   - configuration: client tunables; also the ceiling the gate consultation point starts from.
    ///   - quirks: the persisted record for this device, or the defaults for a new one.
    ///   - transport: the byte mover.
    ///   - trustEvaluator: TLS policy. The pure-layer default refuses `https`, by design.
    ///   - clock: freshness and rate limiting.
    ///   - wallClock: the `Date` values models carry.
    ///   - logger: structured logging sink.
    ///   - random: search-id source.
    public init(endpoint: ISAPIEndpoint,
                credential: Credential,
                configuration: ISAPIClient.Configuration = .init(),
                quirks: DeviceQuirks = DeviceQuirks(),
                transport: any HTTPTransporting,
                trustEvaluator: any ServerTrustEvaluating = RefusingTrustEvaluator(),
                clock: any MonotonicClock,
                wallClock: any WallClock = SystemWallClock(),
                logger: any LoggerProtocol = NullLogger(),
                random: any RandomSource = SystemRandomSource()) {
        let client = ISAPIClient(endpoint: endpoint, credential: credential,
                                 configuration: configuration, quirks: quirks,
                                 transport: transport, trustEvaluator: trustEvaluator,
                                 clock: clock, logger: logger, random: random)
        self.init(requests: client, gate: client, configuration: configuration, quirks: quirks,
                  clock: clock, wallClock: wallClock, logger: logger, random: random)
    }

    /// Builds a session over an existing request surface.
    ///
    /// This is the initializer the tests use, and the one a caller that already holds an
    /// `ISAPIClient` should use, so a device never ends up with two clients and therefore two
    /// independent concurrency gates pointed at one small HTTP worker pool.
    ///
    /// - Parameters:
    ///   - requests: the request surface.
    ///   - gate: what to tell when the concurrency quirk changes. Pass the client; pass `nil` when
    ///     `requests` has no gate.
    ///   - ttl: the freshness table. The default is the authoritative one (§18.1).
    public init(requests: any ISAPIRequesting,
                gate: (any QuirkApplying)? = nil,
                configuration: ISAPIClient.Configuration = .init(),
                quirks: DeviceQuirks = DeviceQuirks(),
                clock: any MonotonicClock,
                wallClock: any WallClock = SystemWallClock(),
                logger: any LoggerProtocol = NullLogger(),
                random: any RandomSource = SystemRandomSource(),
                ttl: CacheTTL = CacheTTL()) {
        self.requests = requests
        self.gate = gate
        self.configuration = configuration
        self.resolver = QuirkResolver(quirks: quirks)
        self.clock = clock
        self.wallClock = wallClock
        self.logger = logger
        self.random = random
        self.ttl = ttl
    }

    // MARK: - Request wrappers

    /// The instant every freshness decision inside one call is taken against.
    ///
    /// One read per decision point, never two: two reads inside one call can straddle a TTL
    /// boundary and make a function serve a cached value it has just declared stale.
    func now() -> MediaInstant { clock.now() }

    /// `GET` a document, with the negative cache in front and the quirk learner behind.
    ///
    /// Every read in this actor goes through here. That is what makes "asked once, refused, never
    /// asked again" a property of the session rather than of each caller remembering to check.
    func get(_ resource: String, query: [URLQueryItem] = [],
             lane: HTTPLane = .control) async throws(ISAPIError) -> ISAPIDocument {
        try suppressionCheck(resource)
        do {
            return try await requests.getDocument(resource, query: query, lane: lane)
        } catch {
            await note(error, for: resource)
            throw error
        }
    }

    /// `GET` a non-XML body — the snapshot path.
    func getBytes(_ resource: String, query: [URLQueryItem],
                  lane: HTTPLane) async throws(ISAPIError) -> Data {
        try suppressionCheck(resource)
        do {
            return try await requests.getBytes(resource, query: query, lane: lane)
        } catch {
            await note(error, for: resource)
            throw error
        }
    }

    /// `PUT` a body. `nil` is the empty-bodied verb, which still carries `Content-Length: 0`.
    @discardableResult
    func put(_ resource: String, body: Data?,
             lane: HTTPLane = .control) async throws(ISAPIError) -> ISAPIDocument? {
        try suppressionCheck(resource)
        do {
            return try await requests.putDocument(resource, body: body, query: [], lane: lane)
        } catch {
            await note(error, for: resource)
            throw error
        }
    }

    /// `POST` a body that must answer with XML.
    func post(_ resource: String, body: Data?,
              lane: HTTPLane = .control) async throws(ISAPIError) -> ISAPIDocument {
        try suppressionCheck(resource)
        do {
            return try await requests.postDocument(resource, body: body, query: [], lane: lane)
        } catch {
            await note(error, for: resource)
            throw error
        }
    }

    /// Throws `.notSupported` with no round trip when this template is suppressed.
    func suppressionCheck(_ resource: String) throws(ISAPIError) {
        guard negative.isSuppressed(resource, at: now(), ttl: ttl.negativeCapability) else { return }
        throw ISAPIError.notSupported(resource: resource)
    }

    /// Folds a failure into the negative cache and the quirk record.
    ///
    /// `insufficientPermission` is deliberately **not** cached: the endpoint exists, and a different
    /// account would reach it — caching it would hide PTZ from a user who then fixes their
    /// credentials and cannot work out why nothing came back.
    func note(_ error: ISAPIError, for resource: String) async {
        switch error {
        case .notSupported, .notFound:
            guard !Self.unsuppressableTemplates.contains(ISAPIResource.template(of: resource)) else {
                return
            }
            negative.remember(resource, at: now())
            logger.debug(.isapi, "negative capability cached",
                         ["template": ISAPIResource.template(of: resource)])
        case .deviceBusy:
            await learn(.deviceBusy(at: now()))
        default:
            break
        }
    }

    /// Folds an observation in and, when the record changed, re-applies it to the request gate.
    ///
    /// **Quirk consultation point 4 (the request gate)** is the `applyQuirks` call: the control
    /// gate's ceiling follows `maxConcurrentRequestsOverride` from here and from nowhere else.
    func learn(_ observation: QuirkResolver.Observation) async {
        guard resolver.observe(observation) else { return }
        let quirks = resolver.quirks
        logger.notice(.isapi, "device quirk observed", [
            "concurrency": quirks.maxConcurrentRequestsOverride.map(String.init) ?? "-",
            "limit": String(resolver.controlConcurrencyLimit(
                configured: configuration.maxConcurrentControlRequests)),
        ])
        await gate?.applyQuirks(quirks)
    }

    // MARK: - Identity

    /// `GET /ISAPI/System/deviceInfo`. Cached 24 h; the identity anchor and the seed for the quirk
    /// record.
    public func deviceInfo(force: Bool = false) async throws(ISAPIError) -> DeviceInfo {
        if !force, let box = deviceInfoBox, box.isFresh(at: now(), ttl: ttl.deviceInfo) {
            return box.value
        }
        let info = try DeviceInfo(document: try await get(ISAPIResource.deviceInfo))
        deviceInfoBox = Timestamped(value: info, storedAt: now())
        // Seeding runs on the record as it stands, so an observation already made for this device
        // survives a re-read of `deviceInfo`: §19 says observations win over seeds.
        resolver = QuirkResolver(quirks: QuirkResolver.seeded(for: info, onto: resolver.quirks))
        return info
    }

    /// `GET /ISAPI/System/status`. Cached 5 s.
    ///
    /// A drop in `uptime` means the device rebooted, which flushes every cache: capabilities can
    /// change across a firmware upgrade, and a negative capability recorded before the reboot may
    /// have been fixed by it.
    public func status() async throws(ISAPIError) -> DeviceStatus {
        if let box = statusBox, box.isFresh(at: now(), ttl: ttl.deviceStatus) {
            return box.value
        }
        let status = DeviceStatus(document: try await get(ISAPIResource.systemStatus))
        let rebooted = statusBox.map { status.indicatesRebootSince($0.value) } ?? false
        if rebooted {
            logger.notice(.isapi, "device reboot detected; flushing caches")
            invalidateCaches()
        }
        statusBox = Timestamped(value: status, storedAt: now())
        return status
    }

    /// `GET /ISAPI/System/time`. Cached 5 min. Vigil never writes device time.
    public func time(force: Bool = false) async throws(ISAPIError) -> DeviceTime {
        if !force, let box = timeBox, box.isFresh(at: now(), ttl: ttl.deviceTime) {
            return box.value
        }
        let value = try DeviceTime(document: try await get(ISAPIResource.systemTime))
        timeBox = Timestamped(value: value, storedAt: now())
        return value
    }

    /// `GET /ISAPI/System/capabilities`. Cached 24 h **and** keyed by firmware version.
    ///
    /// A failure here is not an error — some 5.1.x devices simply do not have the endpoint — so the
    /// defaults for the device family are returned instead, with every row still marked unresolved
    /// for the functional probes in the connect sequence to settle.
    public func capabilities(force: Bool = false)
        async throws(ISAPIError) -> DeviceCapabilitiesWire {
        let info = try await deviceInfo()
        let firmware = info.firmwareVersion.raw
        if !force, let box = capabilitiesBox, capabilitiesFirmware == firmware,
           box.isFresh(at: now(), ttl: ttl.capabilities) {
            return box.value
        }
        var wire: DeviceCapabilitiesWire
        do {
            let document = try await get(ISAPIResource.capabilities)
            wire = DeviceCapabilitiesWire(document: document, family: info.family,
                                          probedAt: wallClock.now)
        } catch {
            logger.info(.isapi, "capabilities unavailable; using family defaults",
                        ["reason": error.userMessageKey])
            wire = DeviceCapabilitiesWire(family: info.family, probedAt: wallClock.now)
        }
        capabilitiesBox = Timestamped(value: wire, storedAt: now())
        capabilitiesFirmware = firmware
        return wire
    }

    /// Replaces the cached capability snapshot — the connect sequence's probe results land here.
    func storeCapabilities(_ wire: DeviceCapabilitiesWire, firmware: String) {
        capabilitiesBox = Timestamped(value: wire, storedAt: now())
        capabilitiesFirmware = firmware
    }

    /// `GET /ISAPI/System/Network/interfaces`. Not cached: read only by the diagnostics panel.
    public func networkInterfaces() async throws(ISAPIError) -> [NetworkInterfaceWire] {
        NetworkInterfaceWire.list(document: try await get(ISAPIResource.networkInterfaces))
    }

    /// `GET /ISAPI/Security/userCheck` — the cheapest authenticated call, and the only one that
    /// reports lock-out state.
    ///
    /// Never cached: its whole value is being current. A thrown `.accountLocked` and a returned
    /// result whose `shouldBlockFurtherAttempts` is true mean the same thing; which one happens
    /// depends on the firmware, so callers must handle both.
    public func checkCredentials() async throws(ISAPIError) -> UserCheckResult {
        let document = try await get(ISAPIResource.userCheck)
        return UserCheckResult(document: document, httpStatus: 200)
    }

    /// `GET /ISAPI/Security/users`. Read for permission diagnostics only; Vigil never writes users.
    public func users() async throws(ISAPIError) -> [DeviceUser] {
        DeviceUser.list(document: try await get(ISAPIResource.users))
    }

    // MARK: - Channel inventory

    /// The channel inventory (R1.3). Cached 60 s, and invalidated by any stream write.
    ///
    /// Composed from up to four sources, each of which may be missing: the streaming channels, the
    /// NVR's proxied channels and their status, and the local video inputs. A failure of
    /// `/Streaming/channels` synthesises channel 1 rather than returning nothing, because an empty
    /// camera list is a worse answer than an optimistic one that fails visibly at the RTSP layer.
    public func channels(force: Bool = false) async throws(ISAPIError) -> [DeviceChannel] {
        if !force, let box = channelsBox, box.isFresh(at: now(), ttl: ttl.channels) {
            return box.value
        }
        let streaming: [StreamingChannelConfig]
        do {
            streaming = try await streamingChannels(force: force)
        } catch {
            logger.warning(.isapi, "streaming channel list failed; synthesising channel 1",
                           ["reason": error.userMessageKey])
            let fallback = ChannelInventory.fallbackSingleChannel()
            channelsBox = Timestamped(value: fallback, storedAt: now())
            return fallback
        }
        let proxied = await proxyChannels()
        let status = await proxyStatus(for: proxied.map(\.channel))
        let inventory = ChannelInventory.merge(streaming: streaming,
                                               inputProxy: proxied,
                                               proxyStatus: status,
                                               videoInputs: await videoInputs())
        channelsBox = Timestamped(value: inventory, storedAt: now())
        return inventory
    }

    /// Proxied channels, or empty. Best-effort: a camera has no such endpoint.
    func proxyChannels() async -> [InputProxyChannel] {
        do {
            return InputProxyChannel.list(document: try await get(ISAPIResource.inputProxyChannels))
        } catch {
            return []
        }
    }

    /// Proxied channel status for `channels`.
    ///
    /// **Quirk consultation point 1 (path builder):** the list form is one request and is always
    /// preferred, but it 404s on DS-76xx/77xx. The first refusal is recorded, and from then on the
    /// per-channel form is used — which is why the channel ids have to be passed in rather than read
    /// from the inventory this call is helping to build.
    func proxyStatus(for channels: [ChannelID]) async -> [InputProxyChannelStatus] {
        if resolver.usesInputProxyStatusList {
            do {
                let document = try await get(ISAPIResource.inputProxyStatusList)
                return InputProxyChannelStatus.list(document: document)
            } catch {
                await learn(.inputProxyStatusListRejected)
            }
        }
        var out: [InputProxyChannelStatus] = []
        for channel in channels {
            do {
                let document = try await get(ISAPIResource.inputProxyStatus(channel))
                if let status = InputProxyChannelStatus(node: document.root) { out.append(status) }
            } catch {
                continue
            }
        }
        return out
    }

    /// Local video inputs, or empty.
    func videoInputs() async -> [VideoInputChannel] {
        do {
            return VideoInputChannel.list(document: try await get(ISAPIResource.videoInputChannels))
        } catch {
            return []
        }
    }

    // MARK: - Streaming

    /// `GET /ISAPI/Streaming/channels`. Cached 30 s, invalidated by any stream write.
    public func streamingChannels(force: Bool = false)
        async throws(ISAPIError) -> [StreamingChannelConfig] {
        if !force, let box = streamingBox, box.isFresh(at: now(), ttl: ttl.streamingChannels) {
            return box.value
        }
        let document = try await get(ISAPIResource.streamingChannels)
        let decoded = StreamingChannelConfig.list(document: document)
        if !decoded.skipped.isEmpty {
            logger.warning(.isapi, "streaming channels skipped",
                           ["ids": decoded.skipped.map(String.init).joined(separator: ",")])
        }
        streamingBox = Timestamped(value: decoded.channels, storedAt: now())
        return decoded.channels
    }

    /// One stream's configuration, freshly read.
    ///
    /// **Quirk consultation point 1 (path builder):** 5.1.x cameras answer only the single-digit
    /// resource. A 404 or `notSupport` on the three-digit form of a *main* stream is what teaches the
    /// session that, and the request is then retried once at the single-digit resource — so the
    /// first stream configuration a 5.1.x camera is asked for costs two round trips and every
    /// subsequent one costs one. A substream keeps the three-digit spelling either way: the
    /// single-digit resource returns the main stream, and writing that back would overwrite the
    /// main stream's configuration with the substream's.
    public func streamingChannel(_ id: StreamingChannelID)
        async throws(ISAPIError) -> StreamingChannelConfig {
        do {
            let document = try await get(resolver.streamingChannelResource(id))
            return try StreamingChannelConfig(node: document.root)
        } catch {
            guard Self.suggestsWrongResourceSpelling(error), id.quality == .main,
                  !resolver.quirks.streamingChannelIDIsSingleDigit else {
                throw error
            }
            await learn(.streamingChannelIDRejected)
            let document = try await get(resolver.streamingChannelResource(id))
            return try StreamingChannelConfig(node: document.root)
        }
    }

    /// True for the failures that mean "this resource spelling is wrong", not "the device is unwell".
    static func suggestsWrongResourceSpelling(_ error: ISAPIError) -> Bool {
        switch error {
        case .notFound, .notSupported: true
        default: false
        }
    }

    /// Writes one stream's configuration: read-modify-write on the full element, then re-`GET`
    /// (R-30).
    ///
    /// - Returns: the configuration the device is actually running, read back after the write —
    ///   never the requested one. `maxFrameRate` is clamped to what the sensor and the chosen
    ///   resolution allow, and showing the user their own request would misreport the camera.
    /// - Throws: `.device(statusCode:sub:)` with `badParameters` for a patch that client-side
    ///   validation already knows the device will reject, so an obviously bad value costs no round
    ///   trip; `.malformedResponse` when the device sent an element with nothing to modify.
    public func updateStream(_ id: StreamingChannelID, _ patch: StreamingChannelPatch)
        async throws(ISAPIError) -> StreamingChannelConfig {
        let failures = patch.validationFailures()
        guard failures.isEmpty else {
            logger.warning(.isapi, "stream patch refused locally",
                           ["reasons": failures.joined(separator: "; ")])
            throw ISAPIError.device(statusCode: 4, sub: ResponseStatus.SubStatus.badParameters)
        }
        let current = try await streamingChannel(id)
        guard let element = current.originalNode else {
            throw ISAPIError.malformedResponse(
                "no <StreamingChannel> element to modify for channel \(id.value)")
        }
        let resource = resolver.streamingChannelResource(id)
        // **Quirk consultation point 2 (body builder):** the declaration, and the device's own
        // `version` and `xmlns` attributes, ride back out with the element untouched (R-30).
        try await put(resource, body: resolver.bodyBytes(patch.applied(to: element)))
        // Any stream write invalidates the stream and channel rows (§18.1), and it must happen
        // *before* the confirming read or that read would be served from the cache it just staled.
        streamingBox = nil
        channelsBox = nil
        return try await streamingChannel(id)
    }

    /// `GET …/picture`. Never cached here: `VigilCore` owns thumbnail retention.
    ///
    /// **Quirk consultation point 1 (path builder):** a device that refused the resolution query is
    /// asked without it from then on. The first refusal is retried immediately, so the caller still
    /// gets its image, and the negative entry that refusal just made is dropped — the resource is
    /// supported, only the query was not.
    public func snapshot(_ request: SnapshotWireRequest) async throws(ISAPIError) -> Data {
        let effective = resolver.snapshotRequest(request)
        do {
            let body = try await getBytes(effective.resource, query: effective.query, lane: .snapshot)
            return try SnapshotPayload.validate(body, contentType: nil)
        } catch {
            guard Self.suggestsQueryWasRefused(error), !effective.query.isEmpty else { throw error }
            negative.forget(effective.resource)
            await learn(.snapshotResolutionQueryRejected)
            let retry = effective.withoutResolutionQuery
            let body = try await getBytes(retry.resource, query: retry.query, lane: .snapshot)
            return try SnapshotPayload.validate(body, contentType: nil)
        }
    }

    /// True for the answers a `/picture` request with resolution query items draws on the firmwares
    /// that do not implement it: `403 notSupport` maps to `.notSupported`, a bare 403 to
    /// `.insufficientPermission`, and some builds answer 400 as `badParameters`.
    static func suggestsQueryWasRefused(_ error: ISAPIError) -> Bool {
        switch error {
        case .notSupported, .insufficientPermission: true
        case let .device(_, sub): sub == ResponseStatus.SubStatus.badParameters
        default: false
        }
    }

    // MARK: - Keyframe request (R-24)

    /// Asks the device for an immediate I-frame (R-24, docs/FEATURES.md F-DEC-05).
    ///
    /// The primary rung of the keyframe chain. Rate-limited to one request per channel per 2 s and
    /// five per 30 s; over either limit this is a **silent no-op** and `suppressedKeyFrameRequests`
    /// grows. Suppression is not an error, because the caller chooses its fallback rung from
    /// `keyFrameRequestIsAvailable(channel:)` rather than from a thrown error — and because a
    /// keyframe-request storm is how an NVR is made unresponsive.
    ///
    /// Two spellings are tried: `…/requestKeyFrame` on current firmware and `…/keyFrame` on older
    /// builds. The first refusal is cached by template, so a device without the feature costs two
    /// round trips once and none afterwards.
    public func requestKeyFrame(channel: ChannelID) async throws(ISAPIError) {
        guard keyFrameRequestIsAvailable(channel: channel) else {
            suppressedKeyFrameRequests += 1
            return
        }
        keyFrameRequests[channel, default: []].append(now())
        let id = StreamingChannelID(channel: channel, quality: .main)
        do {
            try await put(Self.requestKeyFrameResource(id), body: nil)
        } catch {
            guard Self.suggestsWrongResourceSpelling(error) else { throw error }
            try await put(Self.legacyKeyFrameResource(id), body: nil)
        }
    }

    /// True when the R-24 rate limit would let a keyframe request through right now.
    ///
    /// Exposed so `VigilCore` can go straight to its fallback rung instead of calling into a no-op.
    /// Trims the window as it reads it, so the history cannot grow with uptime.
    public func keyFrameRequestIsAvailable(channel: ChannelID) -> Bool {
        let instant = now()
        let cutoff = instant.nanoseconds - Int64(Self.keyFrameBurstWindowSeconds * 1e9)
        let recent = (keyFrameRequests[channel] ?? []).filter { $0.nanoseconds >= cutoff }
        keyFrameRequests[channel] = recent
        guard recent.count < Self.keyFrameBurstLimit else { return false }
        guard let last = recent.last else { return true }
        return instant.seconds(since: last) >= Self.keyFrameMinimumIntervalSeconds
    }

    /// `PUT /ISAPI/Streaming/channels/{id}/requestKeyFrame`.
    ///
    /// Spelled here rather than in `ISAPIResource` because the keyframe request is not in the
    /// Appendix A endpoint table that file mirrors: it comes from docs/spec-rtp.md §7 and
    /// docs/FEATURES.md F-DEC-05. Folding it into `ISAPIResource` is a one-line follow-up.
    static func requestKeyFrameResource(_ id: StreamingChannelID) -> String {
        "/Streaming/channels/\(id.value)/requestKeyFrame"
    }

    /// The legacy spelling some older firmware uses instead.
    static func legacyKeyFrameResource(_ id: StreamingChannelID) -> String {
        "/Streaming/channels/\(id.value)/keyFrame"
    }

    // MARK: - Lifecycle

    /// The quirk record as it now stands. `VigilCore` persists this on the camera row.
    public var observedQuirks: DeviceQuirks { resolver.quirks }

    /// Templates this device has refused, for the diagnostics bundle.
    public var suppressedCapabilityTemplates: [String] { negative.suppressedTemplates }

    /// `PUT /ISAPI/System/reboot`.
    ///
    /// A lost connection or a timeout **after** the request went out counts as success
    /// (docs/spec-isapi.md §17.3): the device stopped answering because it is rebooting, which is
    /// what was asked for. Every cache is flushed either way.
    public func reboot() async throws(ISAPIError) {
        do {
            try await put(ISAPIResource.reboot, body: nil)
        } catch {
            invalidateCaches()
            switch error {
            case .notConnected, .timedOut, .streamEnded:
                logger.info(.isapi, "reboot lost its connection, which means it landed")
                return
            default:
                throw error
            }
        }
        invalidateCaches()
    }

    /// Drops every cached value and every negative entry.
    ///
    /// Called on a credential change, a detected reboot, `AlertStreamState.authFailed` and an
    /// endpoint change (docs/spec-isapi.md §18.1). The quirk record deliberately survives: it
    /// describes the firmware, not the session, and re-learning it costs the user real round trips.
    public func invalidateCaches() {
        deviceInfoBox = nil
        capabilitiesBox = nil
        capabilitiesFirmware = nil
        timeBox = nil
        statusBox = nil
        channelsBox = nil
        streamingBox = nil
        recordTracksBox = nil
        storageBox = nil
        eventTriggersBox = nil
        ptzCapabilityBoxes.removeAll()
        imageBoxes.removeAll()
        dayIndexBoxes.removeAll()
        monthCalendarBoxes.removeAll()
        negative.clear()
    }

    /// Stops everything this session owns: every PTZ keep-alive, the alert stream, every cache.
    ///
    /// PTZ is stopped **first**, with the triple zero-stop discipline `PTZController.stop()`
    /// implements, because a camera left panning after the app quits is the one failure a user
    /// cannot undo from inside Vigil.
    public func shutdown() async {
        for controller in ptzControllers.values {
            await controller.stop()
        }
        ptzControllers.removeAll()
        await alertMonitor?.stop()
        alertMonitor = nil
        invalidateCaches()
    }
}

// MARK: - Cache keys

/// Identifies one day's recording index.
struct DayIndexKey: Sendable, Hashable {
    var track: TrackID
    /// Midnight UTC of the day, as the caller supplied it.
    var dayStartUTC: Date
}

/// Identifies one month's recording calendar.
struct MonthKey: Sendable, Hashable {
    var track: TrackID
    var year: Int
    var month: Int
}
