//
//  RequestDouble.swift
//  VigilISAPITests
//
//  The `ISAPIRequesting` double every endpoint-family suite is driven through: it records the exact
//  bytes that would have gone on the wire and replays canned documents, with no transport, no
//  sockets and no clock.
//  Supports docs/spec-isapi.md §20.1.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilISAPI

// MARK: - RecordedRequest

/// One request the double absorbed.
struct RecordedRequest: Sendable, Equatable {
    var method: String
    var resource: String
    var query: [String: String]
    var body: Data?

    /// The body as UTF-8 text, for byte-for-byte assertions.
    var bodyText: String? { body.flatMap { String(data: $0, encoding: .utf8) } }
}

// MARK: - RequestDouble

/// Records requests and answers them from a route table.
///
/// Routes are matched by **suffix** on the resource, so a test can register
/// `"/PTZCtrl/channels/1/presets"` without repeating the whole path, and the first matching route
/// wins. A resource with no route answers an empty `<ResponseStatus>` with `statusCode 1`, which is
/// what a real device does for most successful writes.
actor RequestDouble: ISAPIRequesting {

    /// A canned answer.
    struct Route: Sendable {
        var suffix: String
        var xml: String?
        var bytes: Data?
        var error: ISAPIError?
        /// Consumed in order when a test needs page 1 then page 2 from the same resource.
        var sequence: [String] = []
    }

    private(set) var recorded: [RecordedRequest] = []
    private var routes: [Route] = []
    private var sequenceCursors: [String: Int] = [:]
    private var streamChunks: [Data] = []
    private var streamContentType: String?
    private var waiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init() {}

    // MARK: Configuration

    func route(_ suffix: String, xml: String) {
        routes.append(Route(suffix: suffix, xml: xml))
    }

    func route(_ suffix: String, bytes: Data) {
        routes.append(Route(suffix: suffix, bytes: bytes))
    }

    func route(_ suffix: String, failing error: ISAPIError) {
        routes.append(Route(suffix: suffix, error: error))
    }

    /// Answers successive requests to the same resource with successive documents.
    func route(_ suffix: String, pages: [String]) {
        routes.append(Route(suffix: suffix, sequence: pages))
    }

    func setStream(contentType: String?, chunks: [Data]) {
        streamContentType = contentType
        streamChunks = chunks
    }

    // MARK: Inspection

    var requestCount: Int { recorded.count }

    func requests(to suffix: String) -> [RecordedRequest] {
        recorded.filter { $0.resource.hasSuffix(suffix) }
    }

    /// Suspends until at least `count` requests have been recorded.
    ///
    /// Deterministic where polling would not be: the continuation is resumed from inside the
    /// recording step, so a test never spins and never depends on a scheduler.
    func waitForRequests(atLeast count: Int) async {
        if recorded.count >= count { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    // MARK: ISAPIRequesting

    func getDocument(_ resource: String, query: [URLQueryItem],
                     lane: HTTPLane) async throws(ISAPIError) -> ISAPIDocument {
        record("GET", resource, query, nil)
        return try await document(for: resource)
    }

    func getBytes(_ resource: String, query: [URLQueryItem],
                  lane: HTTPLane) async throws(ISAPIError) -> Data {
        record("GET", resource, query, nil)
        guard let route = match(resource) else { return Data() }
        if let error = route.error { throw error }
        if let bytes = route.bytes { return bytes }
        return Data(route.xml?.utf8 ?? "".utf8)
    }

    func putDocument(_ resource: String, body: Data?, query: [URLQueryItem],
                     lane: HTTPLane) async throws(ISAPIError) -> ISAPIDocument? {
        record("PUT", resource, query, body)
        guard let route = match(resource) else { return nil }
        if let error = route.error { throw error }
        return try? await document(for: resource, consuming: false)
    }

    func postDocument(_ resource: String, body: Data?, query: [URLQueryItem],
                      lane: HTTPLane) async throws(ISAPIError) -> ISAPIDocument {
        record("POST", resource, query, body)
        return try await document(for: resource)
    }

    func deleteDocument(_ resource: String, query: [URLQueryItem],
                        lane: HTTPLane) async throws(ISAPIError) -> ISAPIDocument? {
        record("DELETE", resource, query, nil)
        guard let route = match(resource) else { return nil }
        if let error = route.error { throw error }
        return try? await document(for: resource, consuming: false)
    }

    func openStream(_ resource: String, query: [URLQueryItem],
                    headers: [String: String]) async throws(ISAPIError) -> ISAPIByteStream {
        record("GET", resource, query, nil)
        if let route = match(resource), let error = route.error { throw error }
        let chunks = streamChunks
        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        return ISAPIByteStream(contentType: streamContentType, bytes: stream)
    }

    // MARK: Internals

    private func record(_ method: String, _ resource: String,
                       _ query: [URLQueryItem], _ body: Data?) {
        var items: [String: String] = [:]
        for item in query { items[item.name] = item.value ?? "" }
        recorded.append(RecordedRequest(method: method, resource: resource,
                                        query: items, body: body))
        let reached = waiters.filter { $0.threshold <= recorded.count }
        waiters.removeAll { $0.threshold <= recorded.count }
        for waiter in reached { waiter.continuation.resume() }
    }

    private func match(_ resource: String) -> Route? {
        routes.first { resource.hasSuffix($0.suffix) }
    }

    private func document(for resource: String,
                          consuming: Bool = true) async throws(ISAPIError) -> ISAPIDocument {
        guard let route = match(resource) else {
            return try ISAPIDocument(parsing: Data(Self.okStatus.utf8))
        }
        if let error = route.error { throw error }
        if !route.sequence.isEmpty {
            let cursor = sequenceCursors[route.suffix] ?? 0
            let index = min(cursor, route.sequence.count - 1)
            if consuming { sequenceCursors[route.suffix] = cursor + 1 }
            return try ISAPIDocument(parsing: Data(route.sequence[index].utf8))
        }
        guard let xml = route.xml else {
            return try ISAPIDocument(parsing: Data(Self.okStatus.utf8))
        }
        return try ISAPIDocument(parsing: Data(xml.utf8))
    }

    static let okStatus = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ResponseStatus version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
        <statusCode>1</statusCode><statusString>OK</statusString><subStatusCode>ok</subStatusCode>
        </ResponseStatus>
        """
}

// MARK: - GateClock

/// Releases sleepers only when a test says so.
///
/// `VirtualClock.sleep` returns immediately, which turns the PTZ keep-alive loop into a spin. This
/// clock blocks instead, so a test can allow exactly one re-send and then assert.
actor SleepGate {
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var order: [UUID] = []
    private var credits = 0

    /// Suspends until a credit is available or the calling task is cancelled.
    ///
    /// Cancellation matters: a cancelled PTZ keep-alive must not leave a parked waiter behind that
    /// later steals the credit the stop path needs.
    func wait() async {
        if credits > 0 {
            credits -= 1
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                waiters[id] = continuation
                order.append(id)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Lets `count` sleepers through, banking credit when none is waiting yet.
    func release(_ count: Int = 1) {
        for _ in 0..<count {
            guard let id = order.first, let continuation = waiters[id] else {
                credits += 1
                continue
            }
            order.removeFirst()
            waiters[id] = nil
            continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        continuation.resume()
    }
}

/// A clock whose `sleep` blocks on a `SleepGate` and whose `now()` never moves.
struct GateClock: MonotonicClock {
    let gate: SleepGate

    func now() -> MediaInstant { .zero }

    func sleep(for duration: Duration) async throws { await gate.wait() }

    func sleep(until deadline: MediaInstant) async throws { await gate.wait() }
}

// MARK: - FixedWallClock

/// A wall clock frozen at one instant, so state values are comparable.
struct FixedWallClock: WallClock {
    let value: Date

    init(_ value: Date = Date(timeIntervalSince1970: 1_714_560_896)) {
        self.value = value
    }

    var now: Date { value }
}

// MARK: - Settling

/// Yields the cooperative pool until `condition` holds, up to a bounded number of hops.
///
/// The bound is what keeps a broken expectation a *failure* rather than a hung suite: nothing here
/// waits on wall-clock time, so a condition that is never going to hold costs microseconds.
func settle(until condition: () async -> Bool, hops: Int = 20_000) async {
    for _ in 0..<hops {
        if await condition() { return }
        await Task.yield()
    }
}

// MARK: - UploadDouble

/// An `HTTPUploadHandle` that records what was written, and can be made to fail on demand.
actor UploadDouble: HTTPUploadHandle {
    private(set) var chunks: [Data] = []
    private(set) var finished = false
    private var failing: ISAPIError?

    init(failing: ISAPIError? = nil) {
        self.failing = failing
    }

    func send(_ chunk: Data) async throws(ISAPIError) {
        if let failing { throw failing }
        chunks.append(chunk)
    }

    func finish() async { finished = true }

    var isOpen: Bool { !finished }
}
