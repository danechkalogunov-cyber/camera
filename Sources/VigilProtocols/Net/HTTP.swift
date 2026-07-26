//
//  HTTP.swift
//  VigilProtocols
//
//  The HTTP injection seam: headers, request, response, lane and the transport protocol that keeps
//  `VigilISAPI` tests off the network.
//  Implements docs/API_CONTRACT.md §3.14 (ruling R-17).
//
//  Written by impl:isapi-a because `ISAPIClient.init(…transport: any HTTPTransporting…)`
//  (API_CONTRACT §4.5) cannot compile without it and the W1 file was still missing; the
//  declarations are the contract's verbatim shape, so the owner of §3.14 can adopt this file
//  unchanged. `ISAPIHTTPTransporting` deliberately does not exist (R-17).
//

import Foundation

// MARK: - Headers

/// A case-insensitive, order-preserving HTTP header container.
///
/// Order matters on the wire for repeated headers (`WWW-Authenticate` may appear twice, Digest and
/// Basic), so this is a list and not a dictionary; lookup is case-insensitive because no two
/// firmwares spell `Content-Type` the same way. `subscript` reads and writes the **first** header
/// with a name, `all(_:)` returns every one in arrival order.
public struct HTTPHeaders: Sendable, Hashable, Codable, Sequence {

    /// Name/value pairs in the order they were added or received. Names keep their original
    /// casing so a diagnostics dump shows what the device actually sent.
    private var entries: [(name: String, value: String)]

    /// An empty header set.
    public init() { entries = [] }

    /// Builds a header set from ordered pairs. Duplicate names are kept, not merged.
    public init(_ pairs: [(String, String)]) {
        entries = pairs.map { (name: $0.0, value: $0.1) }
    }

    /// The first value for `name`, compared case-insensitively.
    ///
    /// Assigning replaces the first matching header in place and removes any later duplicates;
    /// assigning `nil` removes every header with that name.
    public subscript(_ name: String) -> String? {
        get {
            let key = name.lowercased()
            return entries.first { $0.name.lowercased() == key }?.value
        }
        set {
            let key = name.lowercased()
            guard let newValue else {
                entries.removeAll { $0.name.lowercased() == key }
                return
            }
            if let index = entries.firstIndex(where: { $0.name.lowercased() == key }) {
                entries[index].value = newValue
                var seen = false
                entries.removeAll { entry in
                    guard entry.name.lowercased() == key else { return false }
                    defer { seen = true }
                    return seen
                }
            } else {
                entries.append((name: name, value: newValue))
            }
        }
    }

    /// Every value for `name`, in arrival order. Empty when the header is absent.
    public func all(_ name: String) -> [String] {
        let key = name.lowercased()
        return entries.filter { $0.name.lowercased() == key }.map(\.value)
    }

    /// Appends a header without disturbing an existing one of the same name.
    public mutating func append(_ name: String, _ value: String) {
        entries.append((name: name, value: value))
    }

    /// Removes every header with `name`, compared case-insensitively.
    public mutating func remove(_ name: String) {
        let key = name.lowercased()
        entries.removeAll { $0.name.lowercased() == key }
    }

    /// Number of headers, counting duplicates separately.
    public var count: Int { entries.count }

    /// Iterates the pairs in order.
    public func makeIterator() -> IndexingIterator<[(name: String, value: String)]> {
        entries.makeIterator()
    }

    // MARK: Hashable

    public static func == (a: Self, b: Self) -> Bool {
        guard a.entries.count == b.entries.count else { return false }
        for (left, right) in zip(a.entries, b.entries) where left != right { return false }
        return true
    }

    public func hash(into hasher: inout Hasher) {
        for entry in entries {
            hasher.combine(entry.name)
            hasher.combine(entry.value)
        }
    }

    // MARK: Codable

    /// One encoded header: a JSON object, so a diagnostics bundle stays readable.
    private struct Entry: Codable {
        var name: String
        var value: String
    }

    public init(from decoder: any Decoder) throws {
        let list = try decoder.singleValueContainer().decode([Entry].self)
        entries = list.map { (name: $0.name, value: $0.value) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries.map { Entry(name: $0.name, value: $0.value) })
    }
}

// MARK: - Lane

/// Per-device request lane.
///
/// Hikvision devices run a small HTTP worker pool; more than a handful of concurrent requests
/// reliably produces `503 deviceBusy` and, on 5.4.x firmware, can stall the RTSP service for
/// seconds. Separate lanes stop a burst of grid thumbnails from starving a PTZ stop command.
public enum HTTPLane: String, Sendable, Hashable, Codable, CaseIterable {
    /// Configuration and command requests. Limit 3 per device.
    case control
    /// JPEG snapshots. Limit 2 per device, 6 app-wide.
    case snapshot
    /// Long-lived byte streams: `alertStream` and device→client audio.
    case stream
    /// Chunked client→device audio upload.
    case audio
}

// MARK: - Request and response

/// One HTTP request, already fully addressed and authenticated.
public struct HTTPRequest: Sendable {

    /// Absolute URL including any query string.
    public var url: URL

    /// Upper-case method verb: `GET`, `PUT`, `POST`, `DELETE`.
    public var method: String

    /// Request headers. `Authorization` is attached by `ISAPIClient`, never by the transport.
    public var headers: HTTPHeaders

    /// Request body, or `nil`. An empty (non-nil) body still sends `Content-Length: 0`.
    public var body: Data?

    /// Per-request budget. Overrides the lane default.
    public var timeout: Duration

    /// Which lane, and therefore which session and which concurrency budget.
    public var lane: HTTPLane

    /// Builds a request. Defaults match the control lane's 8-second budget.
    public init(url: URL, method: String = "GET", headers: HTTPHeaders = .init(),
                body: Data? = nil, timeout: Duration = .seconds(8), lane: HTTPLane = .control) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.lane = lane
    }
}

/// One complete HTTP response. Streaming responses never become one of these.
public struct HTTPResponse: Sendable {

    /// The HTTP status line code.
    public let statusCode: Int

    /// Response headers as received, order preserved.
    public let headers: HTTPHeaders

    /// The complete body. Capped by the transport; an over-long body is an error, not a truncation.
    public let body: Data

    /// Builds a response. Used by the production transport and by test doubles alike.
    public init(statusCode: Int, headers: HTTPHeaders = .init(), body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// The `Content-Type` header, or `nil`. Never trusted for JPEG detection — some 5.2.x devices
    /// answer a snapshot with `text/html` and a JPEG body, so callers sniff the SOI marker.
    public var contentType: String? { headers["Content-Type"] }
}

// MARK: - Transport

/// The injection seam that keeps `VigilISAPI` tests off the network, and lets `VigilDiscovery`'s
/// ONVIF `GetStreamUri` fallback work without importing `VigilISAPI`.
///
/// Implementations do not authenticate, do not retry and do not interpret status codes: they move
/// bytes and report what happened. `ISAPIHTTPTransporting` does not exist (API_CONTRACT §2 R-17).
public protocol HTTPTransporting: Sendable {

    /// Performs a unary request and returns the complete response.
    ///
    /// Throws `.timedOut` when the budget expires, `.cancelled` when the calling task is
    /// cancelled, and `.responseTooLarge` when the body exceeds the transport's cap.
    func perform(_ request: HTTPRequest) async throws(ISAPIError) -> HTTPResponse

    /// Opens a long-lived byte stream (`alertStream`, two-way audio download).
    ///
    /// Back-pressured: the stream buffers at most a bounded number of chunks and a
    /// `.terminated`/`.dropped` continuation cancels the underlying task. The returned status and
    /// headers arrive as soon as the response head is available, before any body byte.
    func stream(_ request: HTTPRequest) async throws(ISAPIError)
        -> (status: Int, headers: HTTPHeaders, bytes: AsyncThrowingStream<Data, any Error>)

    /// Starts a chunked upload with a caller-driven body (two-way audio push).
    func upload(_ request: HTTPRequest) async throws(ISAPIError) -> any HTTPUploadHandle
}

/// A chunked upload in progress. Every method is safe to call from any task.
public protocol HTTPUploadHandle: Sendable {

    /// Writes one chunk. Throws once the device or the transport has closed the connection.
    func send(_ chunk: Data) async throws(ISAPIError)

    /// Closes the body and lets the request complete. Idempotent.
    func finish() async

    /// False once the peer closed, the task failed, or `finish()` completed.
    var isOpen: Bool { get async }
}
