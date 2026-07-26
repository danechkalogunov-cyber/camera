//
//  ISAPIClientAdapter.swift
//  VigilISAPI
//
//  The one file that joins `ISAPIClient` to `ISAPIRequesting`, so a change to either signature is a
//  change to sixty lines rather than to every endpoint family.
//  Implements docs/API_CONTRACT.md §4.5.
//
//  Nothing here interprets a status code or maps an error: `ISAPIClient` has already done that
//  (docs/spec-isapi.md §9.3) and doing it twice would let the two disagree. All this does is decide
//  whether a `PUT`/`DELETE` response body was XML worth parsing, which the client's own verbs
//  deliberately leave to the caller because a successful `PUT` legitimately has no body at all.
//

import Foundation
import VigilProtocols

extension ISAPIClient: ISAPIRequesting {

    public func getDocument(_ resource: String, query: [URLQueryItem],
                            lane: HTTPLane) async throws(ISAPIError) -> ISAPIDocument {
        try await getXML(resource, query: query, lane: lane)
    }

    public func getBytes(_ resource: String, query: [URLQueryItem],
                         lane: HTTPLane) async throws(ISAPIError) -> Data {
        try await get(resource, query: query, lane: lane).body
    }

    public func putDocument(_ resource: String, body: Data?, query: [URLQueryItem],
                            lane: HTTPLane) async throws(ISAPIError) -> ISAPIDocument? {
        // An all-zero PTZ stop is the only body this module ever repeats; the client's retry table
        // needs to be told, and the resource plus an empty-ish body is not enough to infer it.
        let idempotent = resource.hasSuffix("/continuous") && Self.isZeroStopBody(body)
        let response = try await put(resource, query: query, body: body,
                                    lane: lane, idempotent: idempotent)
        return Self.document(from: response)
    }

    public func postDocument(_ resource: String, body: Data?, query: [URLQueryItem],
                             lane: HTTPLane) async throws(ISAPIError) -> ISAPIDocument {
        let response = try await post(resource, query: query, body: body, lane: lane)
        guard let document = Self.document(from: response) else {
            throw ISAPIError.unexpectedContentType(expected: "application/xml",
                                                   got: response.contentType)
        }
        return document
    }

    public func deleteDocument(_ resource: String, query: [URLQueryItem],
                               lane: HTTPLane) async throws(ISAPIError) -> ISAPIDocument? {
        Self.document(from: try await delete(resource, query: query, lane: lane))
    }

    public func openStream(_ resource: String, query: [URLQueryItem],
                           headers: [String: String]) async throws(ISAPIError) -> ISAPIByteStream {
        let opened = try await byteStream(resource, method: "GET", query: query,
                                         headers: HTTPHeaders(headers.map { ($0.key, $0.value) }))
        return ISAPIByteStream(contentType: opened.headers["Content-Type"], bytes: opened.bytes)
    }

    // MARK: Helpers

    /// Parses the body when it is XML, and returns `nil` when it is not.
    ///
    /// A device that answers a successful `PUT` with an empty body — several do — must not look
    /// like a failure, which is why this returns an optional rather than throwing.
    private static func document(from response: HTTPResponse) -> ISAPIDocument? {
        guard !response.body.isEmpty, ISAPIDocument.looksLikeXML(response.body) else { return nil }
        return try? ISAPIDocument(parsing: response.body)
    }

    /// True for the `<PTZData>` body whose three axes are all zero.
    ///
    /// Matched on the serialised bytes rather than by re-parsing: this runs on the PTZ stop path,
    /// where the whole point is to get three writes out as fast as possible.
    private static func isZeroStopBody(_ body: Data?) -> Bool {
        guard let body, body.count < 256, let text = String(data: body, encoding: .utf8) else {
            return false
        }
        return text.contains("<pan>0</pan>") && text.contains("<tilt>0</tilt>")
            && text.contains("<zoom>0</zoom>")
    }
}
