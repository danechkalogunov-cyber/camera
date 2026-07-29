//
//  ISAPIClient.swift
//  VigilISAPI
//
//  The HTTP client: verbs, lanes, pre-emptive Digest, the retry table and the two-failure auth
//  hard block.
//  Implements docs/spec-isapi.md §4 and §5, and docs/API_CONTRACT.md §4.5.
//
//  Two rules here are safety properties, not policies:
//    * **Two credentialed 401s per device account is terminal** (R-25), on a counter that outlives
//      this object. Hikvision locks an account for thirty minutes after roughly five failures,
//      against the camera's own web UI as well, so a client that keeps trying takes the camera away
//      from its owner.
//    * **Concurrency is capped per lane.** More than three concurrent control requests produces a
//      503 storm, and on 5.4.x firmware it can stall the RTSP service — the video the user is
//      watching — for seconds.
//

import Foundation
import VigilProtocols

// MARK: - ISAPIClient

/// One device's control-plane HTTP client.
///
/// Owns the challenge cache, the per-lane gates and the retry policy. It does **not** know what any
/// endpoint means: it returns responses and mapped errors, and the endpoint layer decodes them.
public actor ISAPIClient {

    /// Tunables. Every default is a measured device limit, not a preference.
    public struct Configuration: Sendable, Hashable {

        /// Simultaneous *control* requests to one device. Above three, Hikvision's small HTTP
        /// worker pool answers 503 and can stall RTSP.
        public var maxConcurrentControlRequests: Int = 3

        /// Simultaneous snapshot requests. A separate lane so a grid of thumbnails cannot starve a
        /// PTZ stop command.
        public var maxConcurrentSnapshotRequests: Int = 2

        /// Budget for the TCP handshake.
        public var connectTimeout: Duration = .seconds(4)

        /// Budget for a configuration or command request.
        public var controlTimeout: Duration = .seconds(8)

        /// Budget for `POST /ContentMgmt/search`, which is slow on a full NVR.
        public var searchTimeout: Duration = .seconds(15)

        /// Budget for a JPEG snapshot.
        public var snapshotTimeout: Duration = .seconds(6)

        /// Between-bytes budget for a long-lived stream. Doubles as stall detection.
        public var streamIdleTimeout: Duration = .seconds(30)

        /// Sent on every request.
        public var userAgent: String = "Vigil/1.0 (macOS)"

        /// Transient retries for idempotent requests.
        public var maxTransientRetries: Int = 2

        /// Whether Basic may be used when Digest cannot be computed — over TLS only, ever.
        public var allowBasicFallbackOverTLS: Bool = true

        /// Cap on a unary response body.
        public var maxUnaryBodyBytes: Int = 8 << 20

        /// PTZ continuous commands get a short budget: a stop that takes longer than this is worse
        /// than useless, and the caller re-sends.
        public var ptzTimeout: Duration = .seconds(2)

        /// Budget for an `/Image/` write, which moves hardware rather than a register.
        ///
        /// ⚠️ Longer than ``controlTimeout`` because the device answers a picture write only after
        /// it has *applied* it, and some of these are mechanical: `PUT …/ircutFilter` swings the
        /// infrared filter across the sensor and then waits out the auto-exposure settling that
        /// follows a day↔night change. A field log showed one refused at the 8 s control budget.
        /// Vigil's own ceiling is unchanged — `timeoutIntervalForResource` still caps the whole
        /// task — so a camera that has genuinely stopped answering is still given up on.
        public var imageWriteTimeout: Duration = .seconds(20)

        /// Default configuration.
        public init() {}
    }

    /// The lane an individual request travels on.
    public typealias Lane = HTTPLane

    // MARK: State

    /// Where the device is.
    public nonisolated let endpoint: ISAPIEndpoint

    /// The account. Replaced by `setCredential(_:)` when the user supplies a new one.
    var credential: Credential

    /// Tunables in force.
    let configuration: Configuration

    /// The firmware quirk record. Consulted for the request gate's ceiling and for Digest mode.
    private var quirks: DeviceQuirks

    /// The byte mover.
    let transport: any HTTPTransporting

    /// TLS policy. Held so a caller can ask, and so the client can refuse `https` on a build with
    /// no way to evaluate a certificate.
    let trustEvaluator: any ServerTrustEvaluating

    /// Time source for retry backoff. Injected, so a test never sleeps for real.
    let clock: any MonotonicClock

    /// Structured logging. Never receives a password: `Credential` masks itself.
    let logger: any LoggerProtocol

    /// The challenge cache and `nc` counter.
    let digest: DigestStore

    /// The lockout counter, shared process-wide by default.
    let lockout: AuthLockoutRegistry

    /// One gate per lane.
    var gates: [Lane: RequestGate]

    /// In-flight coalesced GETs, keyed `lane|method|url`.
    var inFlightGETs: [String: Task<CompletedRequest, any Error>] = [:]

    /// A finished request: the response and, when the body was XML, the parsed document — so the
    /// XML convenience methods never parse the same bytes twice.
    struct CompletedRequest: Sendable {
        var response: HTTPResponse
        var document: ISAPIDocument?
    }

    // MARK: Init

    /// Creates a client.
    ///
    /// - Parameters:
    ///   - endpoint: where the device is. `https` requires a `trustEvaluator` that can actually
    ///     evaluate a chain; the pure-layer conformance refuses, by design.
    ///   - credential: the device account.
    ///   - configuration: tunables.
    ///   - quirks: the firmware record. Exactly one field is read here — the concurrency override,
    ///     which drives the control gate's ceiling and can be changed later with `setQuirks(_:)`.
    ///     `digestNoQOP` is an *observation*, not an input: the challenge the device sends decides
    ///     which response form goes back, so no flag can make the client compute the wrong one.
    ///   - transport: the byte mover. Tests inject a fixture.
    ///   - trustEvaluator: TLS policy.
    ///   - clock: monotonic source for retry backoff.
    ///   - logger: structured logging sink.
    ///   - random: `cnonce` source; seed it in tests.
    ///   - lockoutRegistry: the credentialed-401 counter. Defaults to the process-wide registry so
    ///     the block survives a new client for the same device (R-25); tests pass their own.
    public init(endpoint: ISAPIEndpoint,
                credential: Credential,
                configuration: Configuration = .init(),
                quirks: DeviceQuirks = .init(),
                transport: any HTTPTransporting,
                trustEvaluator: any ServerTrustEvaluating = RefusingTrustEvaluator(),
                clock: any MonotonicClock,
                logger: any LoggerProtocol = NullLogger(),
                random: any RandomSource = SystemRandomSource(),
                lockoutRegistry: AuthLockoutRegistry = .shared) {
        self.endpoint = endpoint
        self.credential = credential
        self.configuration = configuration
        self.quirks = quirks
        self.transport = transport
        self.trustEvaluator = trustEvaluator
        self.clock = clock
        self.logger = logger
        self.lockout = lockoutRegistry
        self.digest = DigestStore(
            random: random,
            allowBasicFallback: endpoint.useTLS && configuration.allowBasicFallbackOverTLS)
        let controlLimit = quirks.maxConcurrentRequestsOverride
            ?? configuration.maxConcurrentControlRequests
        gates = [
            .control: RequestGate(limit: controlLimit),
            .snapshot: RequestGate(limit: configuration.maxConcurrentSnapshotRequests),
            .stream: RequestGate(limit: 1),
            .audio: RequestGate(limit: 1),
        ]
    }

    // MARK: Credential and lockout

    /// Consecutive credentialed 401s for this device account, across every lane and every client.
    public var authFailureCount: Int {
        get async {
            await lockout.failureCount(host: endpoint.host, port: endpoint.port,
                                       account: credential.account)
        }
    }

    /// True when the client refuses to send anything until a new credential arrives.
    public var isAuthBlocked: Bool {
        get async {
            await lockout.isBlocked(host: endpoint.host, port: endpoint.port,
                                    account: credential.account)
        }
    }

    /// Installs a new credential and clears both the challenge cache and the lockout counter.
    ///
    /// This is the **only** way out of `authBlockedLocally`: nothing time-based reopens it, because
    /// waiting does not make a wrong password right and every retry costs one of the device's five.
    public func setCredential(_ credential: Credential) async {
        await lockout.reset(host: endpoint.host, port: endpoint.port,
                            account: self.credential.account)
        self.credential = credential
        await digest.invalidate(reason: "credential changed")
        await lockout.reset(host: endpoint.host, port: endpoint.port, account: credential.account)
    }

    /// Applies a newly observed quirk record. The control gate's ceiling follows it immediately.
    public func setQuirks(_ quirks: DeviceQuirks) async {
        self.quirks = quirks
        let limit = quirks.maxConcurrentRequestsOverride
            ?? configuration.maxConcurrentControlRequests
        await gates[.control]?.setLimit(limit)
    }

    // MARK: Verbs

    /// `GET`, returning the raw response.
    ///
    /// Throws for anything the device reports as a failure — including HTTP 200 carrying
    /// `statusCode != 1`, which several firmwares do — so a 2xx return really is a success.
    public func get(_ resource: String, query: [URLQueryItem] = [],
                    lane: Lane = .control) async throws(ISAPIError) -> HTTPResponse {
        try await send(method: "GET", resource: resource, query: query, body: nil,
                       contentType: nil, lane: lane, idempotent: true).response
    }

    /// `PUT` with an XML body.
    ///
    /// - Parameter idempotent: `true` only for a request that is safe to repeat — in this module,
    ///   an all-zero PTZ `continuous` stop. Everything else is sent once.
    public func put(_ resource: String, query: [URLQueryItem] = [], body: Data?,
                    contentType: String = "application/xml",
                    lane: Lane = .control,
                    idempotent: Bool = false) async throws(ISAPIError) -> HTTPResponse {
        try await send(method: "PUT", resource: resource, query: query, body: body,
                       contentType: contentType, lane: lane, idempotent: idempotent).response
    }

    /// `POST` with a body.
    public func post(_ resource: String, query: [URLQueryItem] = [], body: Data?,
                     contentType: String = "application/xml",
                     lane: Lane = .control) async throws(ISAPIError) -> HTTPResponse {
        try await send(method: "POST", resource: resource, query: query, body: body,
                       contentType: contentType, lane: lane, idempotent: false).response
    }

    /// `DELETE`.
    public func delete(_ resource: String, query: [URLQueryItem] = [],
                       lane: Lane = .control) async throws(ISAPIError) -> HTTPResponse {
        try await send(method: "DELETE", resource: resource, query: query, body: nil,
                       contentType: nil, lane: lane, idempotent: false).response
    }

    // MARK: XML convenience

    /// `GET` returning a parsed document.
    ///
    /// - Throws: `.malformedResponse` when the body is not XML — an HTML login page from a device
    ///   with web authentication misconfigured is the case that matters, and it arrives with
    ///   HTTP 200.
    public func getXML(_ resource: String, query: [URLQueryItem] = [],
                       lane: Lane = .control) async throws(ISAPIError) -> ISAPIDocument {
        let completed = try await send(method: "GET", resource: resource, query: query, body: nil,
                                       contentType: nil, lane: lane, idempotent: true)
        guard let document = completed.document else {
            throw ISAPIError.unexpectedContentType(expected: "application/xml",
                                                   got: completed.response.contentType)
        }
        return document
    }

    /// `PUT` an XML body, returning the device's `<ResponseStatus>`.
    ///
    /// A device that answers 200 with an empty body is treated as success — several do for
    /// `/System/reboot` — and reported as `statusCode 1`.
    public func putXML(_ resource: String, body: XMLBuilder, query: [URLQueryItem] = [],
                       lane: Lane = .control,
                       idempotent: Bool = false) async throws(ISAPIError) -> ResponseStatus {
        let completed = try await send(method: "PUT", resource: resource, query: query,
                                       body: body.data(), contentType: "application/xml",
                                       lane: lane, idempotent: idempotent)
        if let document = completed.document, let status = ResponseStatus(document: document) {
            return status
        }
        return ResponseStatus(requestURL: resource, statusCode: ResponseStatus.Code.ok.rawValue,
                              statusString: "OK")
    }

    /// `POST` an XML body, returning the parsed answer.
    public func postXML(_ resource: String, body: XMLBuilder, query: [URLQueryItem] = [],
                        lane: Lane = .control) async throws(ISAPIError) -> ISAPIDocument {
        let completed = try await send(method: "POST", resource: resource, query: query,
                                       body: body.data(), contentType: "application/xml",
                                       lane: lane, idempotent: false)
        guard let document = completed.document else {
            throw ISAPIError.unexpectedContentType(expected: "application/xml",
                                                   got: completed.response.contentType)
        }
        return document
    }

    // MARK: Streams

    /// Opens a long-lived byte stream — the alert stream, or device→client audio.
    ///
    /// Authenticated pre-emptively when a challenge is already cached; when it is not, one 401 is
    /// absorbed and the stream is opened again. Beyond that the caller sees the failure, because a
    /// stream that reconnects on its own would burn the account's attempts invisibly.
    public func byteStream(_ resource: String, method: String = "GET",
                           query: [URLQueryItem] = [], headers: HTTPHeaders = .init())
        async throws(ISAPIError)
        -> (headers: HTTPHeaders, bytes: AsyncThrowingStream<Data, any Error>) {
        try await guardBeforeSending()
        let uri = endpoint.requestURI(resource, query: query)
        let url = try endpoint.url(resource, query: query)

        for attempt in 0..<2 {
            var request = HTTPRequest(url: url, method: method,
                                      headers: baseHeaders(extra: headers),
                                      body: nil, timeout: configuration.streamIdleTimeout,
                                      lane: .stream)
            let authorization = await digest.header(for: method, uri: uri, credential: credential)
            if let authorization { request.headers["Authorization"] = authorization }

            let opened = try await transport.stream(request)
            if opened.status == 401, attempt == 0 {
                let disposition = await digest.absorb(headers: opened.headers,
                                                      didSendAuthorization: authorization != nil,
                                                      isTLS: endpoint.useTLS)
                if case .retry = disposition { continue }
                throw await authFailure(disposition)
            }
            guard (200...299).contains(opened.status) else {
                if opened.status == 401 {
                    throw await authFailure(.authenticationFailed)
                }
                throw ISAPIErrorMapping.classify(httpStatus: opened.status, status: nil,
                                                 resource: resource,
                                                 username: credential.account).error
            }
            await noteAuthenticationSucceeded(sentAuthorization: authorization != nil)
            return (opened.headers, opened.bytes)
        }
        throw ISAPIError.authenticationFailed(username: credential.account)
    }

    /// Starts a chunked upload — the two-way audio push.
    public func chunkedUpload(_ resource: String,
                              contentType: String) async throws(ISAPIError) -> any HTTPUploadHandle {
        try await guardBeforeSending()
        let uri = endpoint.requestURI(resource, query: [])
        let url = try endpoint.url(resource, query: [])
        var request = HTTPRequest(url: url, method: "POST",
                                  headers: baseHeaders(extra: .init()), body: nil,
                                  timeout: configuration.streamIdleTimeout, lane: .audio)
        request.headers["Content-Type"] = contentType
        // A streamed body cannot be replayed after a 401, so the first attempt must already carry
        // a valid header (spec-isapi §5, reason 2). Callers issue a cheap GET first when the
        // challenge is not yet cached.
        if let authorization = await digest.header(for: "POST", uri: uri, credential: credential) {
            request.headers["Authorization"] = authorization
        }
        return try await transport.upload(request)
    }
}
