//
//  URLSessionHTTPTransport.swift
//  VigilISAPI
//
//  The production transport: one ephemeral `URLSession` per lane, a continuation bridge for unary
//  requests, and a delegate-fed `AsyncThrowingStream` for long-lived ones.
//  Implements docs/spec-isapi.md §4.2 and §4.6, and docs/API_CONTRACT.md §4.5.
//
//  `URLSession` is available in Linux Foundation (`FoundationNetworking`), which is what lets this
//  module be a real HTTP client and still be a pure, Linux-tested target. Two portability rules
//  shape the file: `URLSession.data(for:delegate:)` is not reliably present on
//  swift-corelibs-foundation, so every request goes through our own bridge; and delegate state lives
//  in an **actor** rather than behind `@unchecked Sendable` (API_CONTRACT §2 R-33/R-52).
//
//  NOT VERIFIED BY ANY TEST IN THIS CONTAINER: there is no HTTP server to talk to here. Every test
//  in `VigilISAPITests` drives the client through a fixture transport instead. Spec-isapi §20.3
//  names this file as one of the three things that need a Mac and a live stub server.
//

import Foundation
import VigilProtocols
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Transport

/// The `URLSession`-backed transport.
///
/// Four sessions, created lazily, one per lane, all `URLSessionConfiguration.ephemeral`: Hikvision
/// sets a `WebSession` cookie that must not be reused across credential changes, and a disk cache
/// would hand back a stale snapshot. Keep-alive is essential — with it plus pre-emptive Digest a
/// snapshot costs one round trip; without it, three.
public struct URLSessionHTTPTransport: HTTPTransporting, Sendable {

    /// The lane pool, which owns every session and every in-flight task.
    private let pool: URLSessionLanePool

    /// Creates a transport.
    ///
    /// - Parameters:
    ///   - configuration: the client configuration whose timeouts and body cap the sessions adopt.
    ///   - logger: structured logging sink.
    public init(configuration: ISAPIClient.Configuration = .init(),
                logger: any LoggerProtocol = NullLogger()) {
        pool = URLSessionLanePool(configuration: configuration, logger: logger)
    }

    /// Performs a unary request. See `HTTPTransporting.perform(_:)`.
    public func perform(_ request: HTTPRequest) async throws(ISAPIError) -> HTTPResponse {
        try await pool.perform(request)
    }

    /// Opens a long-lived byte stream. See `HTTPTransporting.stream(_:)`.
    public func stream(_ request: HTTPRequest) async throws(ISAPIError)
        -> (status: Int, headers: HTTPHeaders, bytes: AsyncThrowingStream<Data, any Error>) {
        try await pool.stream(request)
    }

    /// Opens the caller-driven request body used by two-way audio. Darwin supplies bound streams;
    /// swift-corelibs Foundation does not, so Linux keeps the explicit unsupported result while the
    /// shipping macOS transport uses the same authenticated URLRequest and audio lane.
    public func upload(_ request: HTTPRequest) async throws(ISAPIError) -> any HTTPUploadHandle {
        #if os(macOS)
        return try await pool.upload(request)
        #else
        throw ISAPIError.notSupported(resource: request.url.path)
        #endif
    }
}

// MARK: - Lane pool

/// Owns the sessions and the in-flight tasks.
///
/// Everything `URLSession` touches is isolated here: `URLSession` and `URLSessionTask` are not
/// `Sendable` on corelibs, so they never cross an isolation boundary — which is also why the
/// cancellation handler cancels *by identifier* rather than by capturing the task.
actor URLSessionLanePool {

    /// Sessions by lane, created on first use.
    private var sessions: [HTTPLane: URLSession] = [:]

    /// In-flight unary tasks, keyed by our own identifier so cancellation needs no capture.
    private var inFlight: [Int: URLSessionTask] = [:]

    /// Next task identifier.
    private var nextID = 0

    /// Timeouts and the body cap.
    private let configuration: ISAPIClient.Configuration

    /// Structured logging.
    private let logger: any LoggerProtocol

    init(configuration: ISAPIClient.Configuration, logger: any LoggerProtocol) {
        self.configuration = configuration
        self.logger = logger
    }

    // MARK: Unary

    /// Performs one request through the continuation bridge.
    func perform(_ request: HTTPRequest) async throws(ISAPIError) -> HTTPResponse {
        try await HTTPDestinationGuard.requirePermitted(request.url)
        let session = session(for: request.lane)
        let urlRequest = Self.makeURLRequest(request)
        let id = nextID
        nextID += 1
        let cap = configuration.maxUnaryBodyBytes

        do {
            let result: HTTPResponse = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let task = session.dataTask(with: urlRequest) { data, response, error in
                        if let error {
                            continuation.resume(throwing: Self.map(error, request: request))
                            return
                        }
                        guard let http = response as? HTTPURLResponse else {
                            continuation.resume(throwing: ISAPIError.notConnected(
                                "no HTTP response for \(request.url.path)"))
                            return
                        }
                        let body = data ?? Data()
                        guard body.count <= cap else {
                            continuation.resume(
                                throwing: ISAPIError.responseTooLarge(bytes: body.count))
                            return
                        }
                        continuation.resume(returning: HTTPResponse(
                            statusCode: http.statusCode,
                            headers: Self.headers(from: http),
                            body: body))
                    }
                    inFlight[id] = task
                    task.resume()
                }
            } onCancel: {
                // `onCancel` is synchronous and non-isolated, and `URLSessionTask` is not
                // `Sendable`, so the task is cancelled by identifier from inside the actor.
                Task { await self.cancel(id: id) }
            }
            inFlight[id] = nil
            return result
        } catch let error as ISAPIError {
            inFlight[id] = nil
            throw error
        } catch {
            inFlight[id] = nil
            throw ISAPIError.notConnected(String(describing: error))
        }
    }

    /// Cancels an in-flight unary task.
    func cancel(id: Int) {
        inFlight[id]?.cancel()
        inFlight[id] = nil
    }

    // MARK: Streaming

    #if os(macOS)
    /// Starts a streamed upload backed by Foundation's bound input/output stream pair.
    func upload(_ request: HTTPRequest) async throws(ISAPIError) -> any HTTPUploadHandle {
        try await HTTPDestinationGuard.requirePermitted(request.url)
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 64 * 1024,
                               inputStream: &input, outputStream: &output)
        guard let input, let output else {
            throw ISAPIError.notConnected("could not create the audio upload stream")
        }
        let streams = BoundHTTPStreams(input: input, output: output)
        var urlRequest = Self.makeURLRequest(request)
        urlRequest.httpBodyStream = streams.input
        urlRequest.setValue("chunked", forHTTPHeaderField: "Transfer-Encoding")
        let session = URLSession(configuration: Self.configuration(for: .audio,
                                                                   configuration: configuration),
                                 delegate: SameHostRedirectDelegate(), delegateQueue: nil)
        let task = session.uploadTask(withStreamedRequest: urlRequest)
        streams.output.open()
        let handle = DarwinHTTPUploadHandle(streams: streams, task: task,
                                            session: session, request: request)
        task.resume()
        return handle
    }
    #endif

    /// Opens a streaming request on its own session, so the delegate's lifetime is the stream's.
    func stream(_ request: HTTPRequest) async throws(ISAPIError)
        -> (status: Int, headers: HTTPHeaders, bytes: AsyncThrowingStream<Data, any Error>) {
        try await HTTPDestinationGuard.requirePermitted(request.url)
        let (bytes, byteContinuation) = AsyncThrowingStream<Data, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(64))
        let (heads, headContinuation) = AsyncStream<StreamHead>.makeStream()

        let delegate = StreamingDelegate(bytes: byteContinuation, heads: headContinuation)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: Self.configuration(for: request.lane,
                                                                   configuration: configuration),
                                 delegate: delegate,
                                 delegateQueue: queue)
        let task = session.dataTask(with: Self.makeURLRequest(request))
        task.resume()

        var iterator = heads.makeAsyncIterator()
        guard let head = await iterator.next() else {
            session.invalidateAndCancel()
            throw ISAPIError.streamEnded(afterBytes: 0)
        }
        return (head.statusCode, head.headers, bytes)
    }

    // MARK: Sessions

    /// The session for a lane, created on first use.
    private func session(for lane: HTTPLane) -> URLSession {
        if let existing = sessions[lane] { return existing }
        let created = URLSession(configuration: Self.configuration(for: lane,
                                                                  configuration: configuration),
                                 delegate: SameHostRedirectDelegate(), delegateQueue: nil)
        sessions[lane] = created
        return created
    }

    /// The lane's session configuration (§4.2).
    static func configuration(for lane: HTTPLane,
                              configuration: ISAPIClient.Configuration) -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpCookieAcceptPolicy = .never
        cfg.connectionProxyDictionary = [:]
        // HTTP/1 pipelining stays off — Hikvision mis-handles pipelined GETs. `URLSession` defaults
        // it off and the property that used to set it is deprecated, so there is nothing to assign.
        cfg.httpAdditionalHeaders = ["Accept": "*/*", "Connection": "keep-alive"]
        cfg.allowsCellularAccess = false            // LAN only.
        switch lane {
        case .control:
            cfg.httpMaximumConnectionsPerHost = 3
            cfg.timeoutIntervalForRequest = seconds(configuration.controlTimeout)
            cfg.timeoutIntervalForResource = 30
        case .snapshot:
            cfg.httpMaximumConnectionsPerHost = 2
            cfg.timeoutIntervalForRequest = seconds(configuration.snapshotTimeout)
            cfg.timeoutIntervalForResource = 8
        case .stream, .audio:
            cfg.httpMaximumConnectionsPerHost = 1
            cfg.timeoutIntervalForRequest = seconds(configuration.streamIdleTimeout)
            cfg.timeoutIntervalForResource = 0      // No overall limit: the stream is the point.
        }
        return cfg
    }

    /// A `Duration` as seconds, for the `URLSession` API's `TimeInterval`s.
    static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    /// Builds the `URLRequest`. Headers are set verbatim: `Authorization` is computed by
    /// `ISAPIClient` and must reach the wire unaltered.
    static func makeURLRequest(_ request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = seconds(request.timeout)
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for entry in request.headers {
            urlRequest.setValue(entry.value, forHTTPHeaderField: entry.name)
        }
        return urlRequest
    }

    /// Copies a response's headers into the module's container.
    static func headers(from response: HTTPURLResponse) -> HTTPHeaders {
        var headers = HTTPHeaders()
        for (name, value) in response.allHeaderFields {
            guard let name = name as? String, let value = value as? String else { continue }
            headers.append(name, value)
        }
        return headers
    }

    /// Maps a `URLError` to the module's error taxonomy.
    ///
    /// A task Vigil cancelled surfaces as `URLError.cancelled`; it becomes `.cancelled`, never a
    /// `URLError`, so a caller never sees a network error for its own cancellation.
    static func map(_ error: any Error, request: HTTPRequest) -> ISAPIError {
        guard let urlError = error as? URLError else {
            return .notConnected(String(describing: error))
        }
        switch urlError.code {
        case .cancelled:
            return .cancelled
        case .timedOut:
            // ⚠️ The method is part of the resource here, and it is the difference between a
            // diagnosable report and a shrug. A write like `setIRCut` is a read-modify-write: GET,
            // PUT, GET, and then a fourth read of the whole image block. All four name the same
            // path, so `timedOut(resource: "/ISAPI/Image/channels/1/ircutFilter")` on its own does
            // not say whether the camera was slow to *answer* or slow to *act* — and those call for
            // opposite fixes.
            return .timedOut(resource: "\(request.method) \(request.url.path)",
                             seconds: seconds(request.timeout))
        case .dataLengthExceedsMaximum:
            return .responseTooLarge(bytes: 0)
        default:
            return .notConnected("\(urlError.code.rawValue) \(urlError.localizedDescription)")
        }
    }
}

// MARK: - Redirect egress

/// URLSession follows redirects by default. A cross-host redirect would bypass the destination
/// preflight, so production sessions accept only same-host redirects (for example HTTP → HTTPS).
private final class SameHostRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(HTTPRedirectPolicy.allows(from: response.url, to: request.url)
                          ? request : nil)
    }
}

enum HTTPRedirectPolicy {
    static func allows(from original: URL?, to redirect: URL?) -> Bool {
        guard let originalHost = original?.host?.lowercased(),
              let redirectHost = redirect?.host?.lowercased() else { return false }
        return originalHost == redirectHost
    }
}

#if os(macOS)

/// A bound stream pair is deliberately consumed by different owners: URLSession reads `input`
/// while ``DarwinHTTPUploadHandle`` serializes every write to `output`. Foundation does not mark
/// streams `Sendable`, so this wrapper records that ownership contract for Swift 6.
private final class BoundHTTPStreams: @unchecked Sendable {
    let input: InputStream
    let output: OutputStream

    init(input: InputStream, output: OutputStream) {
        self.input = input
        self.output = output
    }
}

/// Actor-isolated writer for a URLSession streamed upload. The 64 KiB bound-stream buffer is far
/// larger than the talk queue's 80 ms maximum batch; a full buffer yields briefly instead of
/// blocking the cooperative executor, and a peer close becomes the domain's normal network error.
private actor DarwinHTTPUploadHandle: HTTPUploadHandle {
    private let streams: BoundHTTPStreams
    private let task: URLSessionUploadTask
    private let session: URLSession
    private let request: HTTPRequest
    private var finished = false

    init(streams: BoundHTTPStreams, task: URLSessionUploadTask,
         session: URLSession, request: HTTPRequest) {
        self.streams = streams
        self.task = task
        self.session = session
        self.request = request
    }

    var isOpen: Bool {
        !finished && task.state != .completed && task.state != .canceling
    }

    func send(_ chunk: Data) async throws(ISAPIError) {
        guard isOpen else { throw transportFailure() }
        var offset = 0
        while offset < chunk.count {
            if let error = task.error { throw URLSessionLanePool.map(error, request: request) }
            guard streams.output.streamStatus != .error && streams.output.streamStatus != .closed else {
                throw transportFailure()
            }
            if !streams.output.hasSpaceAvailable {
                try? await Task.sleep(for: .milliseconds(2))
                continue
            }
            let written = chunk.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return 0
                }
                return streams.output.write(base.advanced(by: offset), maxLength: chunk.count - offset)
            }
            guard written >= 0 else { throw transportFailure() }
            if written == 0 {
                try? await Task.sleep(for: .milliseconds(2))
            } else {
                offset += written
            }
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        streams.output.close()
        session.finishTasksAndInvalidate()
    }

    private func transportFailure() -> ISAPIError {
        if let error = task.error { return URLSessionLanePool.map(error, request: request) }
        if let error = streams.output.streamError {
            return ISAPIError.notConnected(String(describing: error))
        }
        return ISAPIError.notConnected("the camera closed the audio upload")
    }
}

#endif

// MARK: - Streaming delegate

/// The response head, handed to the caller before any body byte.
struct StreamHead: Sendable {
    var statusCode: Int
    var headers: HTTPHeaders
}

/// Feeds a streaming response into an `AsyncThrowingStream`.
///
/// Holds only the two continuations, both of which are `Sendable` and both of which tolerate being
/// finished more than once — which is why this class needs no lock and no `@unchecked Sendable`.
/// Back-pressure is the stream's `.bufferingNewest(64)` policy: once the consumer stops draining,
/// the oldest chunks are dropped rather than the process growing without bound.
private final class StreamingDelegate: NSObject, URLSessionDataDelegate {

    /// Where body bytes go.
    private let bytes: AsyncThrowingStream<Data, any Error>.Continuation

    /// Where the response head goes, exactly once.
    private let heads: AsyncStream<StreamHead>.Continuation

    init(bytes: AsyncThrowingStream<Data, any Error>.Continuation,
         heads: AsyncStream<StreamHead>.Continuation) {
        self.bytes = bytes
        self.heads = heads
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            heads.yield(StreamHead(statusCode: http.statusCode,
                                   headers: URLSessionLanePool.headers(from: http)))
            heads.finish()
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(HTTPRedirectPolicy.allows(from: response.url, to: request.url)
                          ? request : nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bytes.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: (any Error)?) {
        heads.finish()
        bytes.finish(throwing: error)
        session.finishTasksAndInvalidate()
    }
}
