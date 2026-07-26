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

        /// Default configuration.
        public init() {}
    }

    /// The lane an individual request travels on.
    public typealias Lane = HTTPLane

    // MARK: State

    /// Where the device is.
    public nonisolated let endpoint: ISAPIEndpoint

    /// The account. Replaced by `setCredential(_:)` when the user supplies a new one.
    private var credential: Credential

    /// Tunables in force.
    private let configuration: Configuration

    /// The firmware quirk record. Consulted for the request gate's ceiling and for Digest mode.
    private var quirks: DeviceQuirks

    /// The byte mover.
    private let transport: any HTTPTransporting

    /// TLS policy. Held so a caller can ask, and so the client can refuse `https` on a build with
    /// no way to evaluate a certificate.
    private let trustEvaluator: any ServerTrustEvaluating

    /// Time source for retry backoff. Injected, so a test never sleeps for real.
    private let clock: any MonotonicClock

    /// Structured logging. Never receives a password: `Credential` masks itself.
    private let logger: any LoggerProtocol

    /// The challenge cache and `nc` counter.
    private let digest: DigestStore

    /// The lockout counter, shared process-wide by default.
    private let lockout: AuthLockoutRegistry

    /// One gate per lane.
    private var gates: [Lane: RequestGate]

    /// In-flight coalesced GETs, keyed `lane|method|url`.
    private var inFlightGETs: [String: Task<CompletedRequest, any Error>] = [:]

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
    ///   - quirks: the firmware record. Only two fields are read here — the concurrency override
    ///     and `digestNoQOP` — and both are re-read on every request, so learning a quirk mid-run
    ///     takes effect immediately.
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

    // MARK: The request pipeline

    /// Sends one request, applying coalescing, the gate, Digest and the retry table.
    func send(method: String, resource: String, query: [URLQueryItem], body: Data?,
              contentType: String?, lane: Lane,
              idempotent: Bool) async throws(ISAPIError) -> CompletedRequest {
        try await guardBeforeSending()
        let url = try endpoint.url(resource, query: query)

        // Identical concurrent GETs share one round trip (§4.4). Never for a body-bearing verb,
        // and never on the long-lived lanes.
        guard method == "GET", lane == .control || lane == .snapshot else {
            return try await execute(method: method, resource: resource, url: url, query: query,
                                     body: body, contentType: contentType, lane: lane,
                                     idempotent: idempotent)
        }
        let key = "\(lane.rawValue)|\(method)|\(url.absoluteString)"
        if let existing = inFlightGETs[key] {
            do {
                return try await existing.value
            } catch let error as ISAPIError {
                throw error
            } catch {
                throw ISAPIError.notConnected(String(describing: error))
            }
        }
        let task = Task { [self] in
            try await execute(method: method, resource: resource, url: url, query: query,
                              body: body, contentType: contentType, lane: lane,
                              idempotent: idempotent)
        }
        inFlightGETs[key] = task
        do {
            let completed = try await task.value
            inFlightGETs[key] = nil
            return completed
        } catch let error as ISAPIError {
            inFlightGETs[key] = nil
            throw error
        } catch {
            inFlightGETs[key] = nil
            throw ISAPIError.notConnected(String(describing: error))
        }
    }

    /// Acquires the lane's permit and runs the attempt loop.
    private func execute(method: String, resource: String, url: URL, query: [URLQueryItem],
                         body: Data?, contentType: String?, lane: Lane,
                         idempotent: Bool) async throws(ISAPIError) -> CompletedRequest {
        guard let gate = gates[lane] else {
            throw ISAPIError.notConnected("no gate for lane \(lane.rawValue)")
        }
        // PTZ, and only PTZ, may over-subscribe the control gate by exactly one slot: a dropped
        // stop command leaves a camera spinning.
        let isPTZ = resource.hasPrefix("/PTZCtrl/") || resource.hasPrefix("PTZCtrl/")
        do {
            try await gate.acquire(overSubscribeByOne: isPTZ && lane == .control)
        } catch {
            throw ISAPIError.cancelled
        }
        // Explicit release on both paths rather than a `defer`: releasing a permit is an `await`
        // on another actor, and a `defer` cannot await without spawning a task that outlives the
        // failure it is cleaning up after.
        do {
            let completed = try await attemptLoop(method: method, resource: resource, url: url,
                                                  query: query, body: body,
                                                  contentType: contentType, lane: lane,
                                                  idempotent: idempotent)
            await gate.release()
            return completed
        } catch {
            await gate.release()
            throw error
        }
    }

    /// The attempt loop: authenticate, send, classify, maybe retry.
    private func attemptLoop(method: String, resource: String, url: URL, query: [URLQueryItem],
                             body: Data?, contentType: String?, lane: Lane,
                             idempotent: Bool) async throws(ISAPIError) -> CompletedRequest {
        let uri = endpoint.requestURI(resource, query: query)
        var transientAttempts = 0
        var authRetries = 0

        while true {
            try await guardBeforeSending()
            if Task.isCancelled { throw ISAPIError.cancelled }

            var request = HTTPRequest(url: url, method: method, headers: baseHeaders(extra: .init()),
                                      body: body, timeout: timeout(for: lane, resource: resource),
                                      lane: lane)
            if let contentType { request.headers["Content-Type"] = contentType }
            // An empty-bodied PUT must still say so: URLSession omits `Content-Length` for a nil
            // body on some paths and Hikvision answers HTTP 400 (spec-isapi §13).
            if body == nil, method == "PUT" || method == "POST" {
                request.headers["Content-Length"] = "0"
            }
            let authorization = await digest.header(for: method, uri: uri, credential: credential)
            if let authorization { request.headers["Authorization"] = authorization }

            let response: HTTPResponse
            do {
                response = try await transport.perform(request)
            } catch {
                guard idempotent, isTransient(error),
                      transientAttempts < configuration.maxTransientRetries else { throw error }
                try await backoff(Self.transportDelays[min(transientAttempts,
                                                           Self.transportDelays.count - 1)])
                transientAttempts += 1
                continue
            }

            if response.statusCode == 401 {
                let disposition = await digest.absorb(headers: response.headers,
                                                      didSendAuthorization: authorization != nil,
                                                      isTLS: endpoint.useTLS)
                if case .retry = disposition, authRetries < 2 {
                    authRetries += 1
                    continue
                }
                let terminal: DigestStore.Disposition =
                    disposition == .retry ? .authenticationFailed : disposition
                throw await authFailure(terminal)
            }

            await noteAuthenticationSucceeded(sentAuthorization: authorization != nil)
            await digest.adoptNextNonce(headers: response.headers)

            let document: ISAPIDocument?
            do {
                document = try ISAPIResponseValidator.validate(response, resource: resource,
                                                               username: credential.account)
            } catch {
                let retryable = isRetryableDeviceFailure(error) && idempotent
                guard retryable, transientAttempts < configuration.maxTransientRetries else {
                    throw error
                }
                try await backoff(Self.busyDelays[min(transientAttempts,
                                                      Self.busyDelays.count - 1)])
                transientAttempts += 1
                continue
            }
            return CompletedRequest(response: response, document: document)
        }
    }

    // MARK: Policy helpers

    /// Delays after a transport failure: 250 ms then 750 ms (§4.7).
    static let transportDelays: [Duration] = [.milliseconds(250), .milliseconds(750)]

    /// Delays after a 503 or `deviceBusy`: 400 ms then 1200 ms (§4.7).
    static let busyDelays: [Duration] = [.milliseconds(400), .milliseconds(1200)]

    /// Refuses to send at all once the account is two credentialed 401s deep, and refuses `https`
    /// on a build whose trust evaluator cannot evaluate anything.
    private func guardBeforeSending() async throws(ISAPIError) {
        if Task.isCancelled { throw ISAPIError.cancelled }
        let failures = await lockout.failureCount(host: endpoint.host, port: endpoint.port,
                                                  account: credential.account)
        if failures >= AuthLockoutRegistry.maximumFailures {
            throw ISAPIError.authBlockedLocally(failures: failures)
        }
        if endpoint.useTLS,
           case .reject = trustEvaluator.evaluate(host: endpoint.host, port: endpoint.port,
                                                  chainDER: []) {
            throw ISAPIError.tlsUnavailableOnThisPlatform
        }
    }

    /// Headers every request carries.
    private func baseHeaders(extra: HTTPHeaders) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers["User-Agent"] = configuration.userAgent
        headers["Accept"] = "*/*"
        for entry in extra { headers[entry.name] = entry.value }
        return headers
    }

    /// The budget for a request, by lane and by resource.
    private func timeout(for lane: Lane, resource: String) -> Duration {
        switch lane {
        case .snapshot: return configuration.snapshotTimeout
        case .stream, .audio: return configuration.streamIdleTimeout
        case .control:
            if resource.contains("/PTZCtrl/") { return configuration.ptzTimeout }
            if resource.contains("/ContentMgmt/search") { return configuration.searchTimeout }
            return configuration.controlTimeout
        }
    }

    /// True for a transport failure worth repeating.
    private func isTransient(_ error: ISAPIError) -> Bool {
        switch error {
        case .timedOut, .notConnected: return true
        default: return false
        }
    }

    /// True for a device answer the retry table repeats: 503 and `deviceBusy`.
    private func isRetryableDeviceFailure(_ error: ISAPIError) -> Bool {
        if case .deviceBusy = error { return true }
        if case let .http(status, _) = error, status == 503 { return true }
        return false
    }

    /// Sleeps `delay` on the injected clock. A cancelled sleep becomes `.cancelled`.
    private func backoff(_ delay: Duration) async throws(ISAPIError) {
        do {
            try await clock.sleep(for: delay)
        } catch {
            throw ISAPIError.cancelled
        }
    }

    /// Records a credentialed 401 and produces the error to throw.
    ///
    /// The **second** failure is terminal and reported as `.authBlockedLocally`, which no schedule
    /// retries: only a new credential clears it.
    private func authFailure(_ disposition: DigestStore.Disposition) async -> ISAPIError {
        if case let .unsupported(scheme) = disposition {
            return .unsupportedAuthentication(scheme)
        }
        let failures = await lockout.recordFailure(host: endpoint.host, port: endpoint.port,
                                                   account: credential.account)
        logger.warning(.isapi, "authentication rejected by \(endpoint.host)",
                       ["account": credential.account, "failures": String(failures)])
        if failures >= AuthLockoutRegistry.maximumFailures {
            return .authBlockedLocally(failures: failures)
        }
        return .authenticationFailed(username: credential.account)
    }

    /// Clears the failure counter after a request that carried credentials succeeded.
    private func noteAuthenticationSucceeded(sentAuthorization: Bool) async {
        guard sentAuthorization else { return }
        await lockout.reset(host: endpoint.host, port: endpoint.port, account: credential.account)
    }
}
