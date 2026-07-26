//
//  ISAPIRequesting.swift
//  VigilISAPI
//
//  The narrow request surface the endpoint families call, so that every typed endpoint is
//  testable against a fixture double with no `URLSession`, no sockets and no `ISAPIClient`.
//  Implements docs/API_CONTRACT.md §4.5 and docs/spec-isapi.md §4, §20.1.
//
//  `ISAPIClient` (docs/spec-isapi.md §4) is the production conformance; it owns Digest, the lane
//  matrix, coalescing and the retry table. Nothing in `Endpoints/` or `Events/` needs any of that,
//  and coupling to the full actor would make every endpoint test drag a transport behind it — so
//  the families depend on this seven-method protocol instead. The adapter that conforms the real
//  client lives in exactly one file so a signature drift is a one-file fix.
//

import Foundation
import VigilProtocols

// MARK: - Lanes

/// Which connection pool a request belongs to.
///
/// The device runs a small HTTP worker pool, so a burst of grid thumbnails must not be able to
/// starve a PTZ stop; separating the lanes is what guarantees it (docs/spec-isapi.md §4.2).
/// `.ptz` is `.control` with the documented one-slot over-subscription — a dropped stop command
/// leaves a camera spinning, which is the worst failure this module has.
public enum ISAPILane: String, Sendable, Hashable, CaseIterable {
    /// Ordinary configuration reads and writes. Concurrency 3 per device.
    case control
    /// PTZ writes. `.control` plus one over-subscribed slot, and a 2 s timeout.
    case ptz
    /// Recording search. `.control` with the longer 15 s budget.
    case search
    /// JPEG snapshots. Concurrency 2 per device, 6 app-wide, excess dropped not queued.
    case snapshot
    /// Long-lived reads: the alert stream and device-to-client audio.
    case stream
    /// The chunked two-way-audio upload.
    case audio
}

// MARK: - ISAPIRequesting

/// Everything an endpoint family needs from the HTTP client.
///
/// All methods report failure as `ISAPIError`; a conformance is responsible for mapping HTTP
/// status, `ResponseStatus` documents and transport failures onto it (docs/spec-isapi.md §9.3)
/// before returning. A `nil` document means "the device answered 2xx with a body that was empty
/// or was not XML" — which several firmwares do for a successful `PUT` — and is **not** an error.
public protocol ISAPIRequesting: Sendable {

    /// `GET` a resource that must answer with a parsable XML document.
    ///
    /// - Parameters:
    ///   - resource: path **without** the `/ISAPI` prefix, e.g. `"/System/deviceInfo"`.
    ///   - query: percent-encoded by the conformance; `+` must survive as `%2B`.
    ///   - lane: the connection pool to use.
    func getDocument(_ resource: String, query: [URLQueryItem],
                     lane: ISAPILane) async throws(ISAPIError) -> ISAPIDocument

    /// `GET` a resource whose body is not XML — the JPEG snapshot path.
    ///
    /// The body is returned verbatim, including when the device mislabels its `Content-Type`;
    /// content sniffing is the caller's job (docs/spec-isapi.md §12.5).
    func getBytes(_ resource: String, query: [URLQueryItem],
                  lane: ISAPILane) async throws(ISAPIError) -> Data

    /// `PUT` an XML body. Pass `nil` for the empty-bodied verbs (`/goto`, `/start`, `/open`),
    /// which must still carry an explicit `Content-Length: 0`.
    func putDocument(_ resource: String, body: Data?, query: [URLQueryItem],
                     lane: ISAPILane) async throws(ISAPIError) -> ISAPIDocument?

    /// `POST` an XML body; the response must parse as XML (`CMSearchResult`, distributions).
    func postDocument(_ resource: String, body: Data?, query: [URLQueryItem],
                      lane: ISAPILane) async throws(ISAPIError) -> ISAPIDocument

    /// `DELETE` a resource. Returns the `ResponseStatus` document when the device sends one.
    func deleteDocument(_ resource: String, query: [URLQueryItem],
                        lane: ISAPILane) async throws(ISAPIError) -> ISAPIDocument?

    /// Opens a long-lived response and yields its body as it arrives.
    ///
    /// The stream must be back-pressured: when the consumer stops reading, the underlying task is
    /// cancelled rather than buffered. `contentType` carries the multipart boundary parameter.
    func openStream(_ resource: String, query: [URLQueryItem], headers: [String: String])
        async throws(ISAPIError) -> ISAPIByteStream
}

/// The result of opening a long-lived response.
public struct ISAPIByteStream: Sendable {
    /// The full `Content-Type` header value, boundary parameter included, or `nil` if absent.
    public let contentType: String?
    /// Body bytes in arrival order. Finishes when the device closes the response.
    public let bytes: AsyncThrowingStream<Data, any Error>

    public init(contentType: String?, bytes: AsyncThrowingStream<Data, any Error>) {
        self.contentType = contentType
        self.bytes = bytes
    }
}

// MARK: - Convenience

public extension ISAPIRequesting {

    /// `GET` on the `.control` lane with no query.
    func getDocument(_ resource: String) async throws(ISAPIError) -> ISAPIDocument {
        try await getDocument(resource, query: [], lane: .control)
    }

    /// `PUT` an XML body on the `.control` lane.
    @discardableResult
    func putDocument(_ resource: String,
                     body: Data?) async throws(ISAPIError) -> ISAPIDocument? {
        try await putDocument(resource, body: body, query: [], lane: .control)
    }

    /// `PUT` a body built with `XMLBuilder`, on a caller-chosen lane.
    @discardableResult
    func put(_ resource: String, _ builder: XMLBuilder,
             lane: ISAPILane = .control) async throws(ISAPIError) -> ISAPIDocument? {
        try await putDocument(resource, body: builder.data(), query: [], lane: lane)
    }

    /// `PUT` with no body at all — the `/goto`, `/start`, `/stop`, `/open`, `/close` verbs.
    @discardableResult
    func putEmpty(_ resource: String,
                  lane: ISAPILane = .control) async throws(ISAPIError) -> ISAPIDocument? {
        try await putDocument(resource, body: nil, query: [], lane: lane)
    }

    /// `POST` a body built with `XMLBuilder`.
    func post(_ resource: String, _ builder: XMLBuilder,
              lane: ISAPILane = .search) async throws(ISAPIError) -> ISAPIDocument {
        try await postDocument(resource, body: builder.data(), query: [], lane: lane)
    }
}
