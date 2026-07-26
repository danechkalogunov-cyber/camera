//
//  RTSPRequestBuilder.swift
//  VigilRTSP
//
//  Canonical request emission: one fixed header order, one place that decides `Content-Length`.
//  The order is fixed so golden fixtures are byte-stable and so `Authorization` is always computed
//  against a finished URI rather than one that is still being assembled.
//  Implements docs/spec-rtsp.md §3.2–3.4.
//

import Foundation

/// Assembles `RTSPRequest` values in the canonical header order.
///
/// The builder is stateless apart from the `User-Agent`; `CSeq`, the session id and the
/// `Authorization` value are supplied per request by the session machine, which owns that state.
public struct RTSPRequestBuilder: Sendable {

    /// The `User-Agent` sent on every request.
    ///
    /// Never empty: some Hikvision firmware answers `400` to a request with an empty `User-Agent`,
    /// so an empty string is replaced by `"Vigil"` at construction rather than trapping — this is
    /// configuration, and configuration must not be able to crash a viewer.
    public let userAgent: String

    /// Creates a builder.
    public init(userAgent: String = "Vigil/1.0") {
        self.userAgent = userAgent.isEmpty ? "Vigil" : userAgent
    }

    // MARK: - Options

    /// Everything that varies per request, in the order the headers are emitted.
    ///
    /// A `nil` field means "omit the header". Values are written verbatim; the builder never
    /// re-encodes them, because `Transport` and `Range` are built by types that already know their
    /// own grammar.
    public struct Options: Sendable {

        /// `Session` id. Present on the second and later `SETUP`s of an aggregate too, which is why
        /// it is not derived from `method.requiresSession`.
        public var session: String?
        /// A complete `Authorization` value, produced by `RTSPAuthenticator`.
        public var authorization: String?
        /// `Require`, for the ONVIF replay path (`onvif-replay`).
        public var require: String?
        /// `Accept`; `DESCRIBE` sends `application/sdp`.
        public var accept: String?
        /// `Transport`, on `SETUP`.
        public var transport: String?
        /// `Range`, on `PLAY`.
        public var range: String?
        /// `Scale`, on `PLAY` when the scale is not 1.0.
        public var scale: String?
        /// `Rate-Control`, on `PLAY` when rate control is disabled (`no`).
        public var rateControl: String?
        /// `Frames`, for ONVIF replay intra-only playback.
        public var frames: String?
        /// Anything else, emitted after the fixed headers and before the entity headers.
        public var additional: RTSPHeaders
        /// `Content-Type`; required when a body is present.
        public var contentType: String?
        /// The body. `Content-Length` is emitted if and only if this is non-empty.
        public var body: Data

        /// Creates an empty option set.
        public init(session: String? = nil, authorization: String? = nil, require: String? = nil,
                    accept: String? = nil, transport: String? = nil, range: String? = nil,
                    scale: String? = nil, rateControl: String? = nil, frames: String? = nil,
                    additional: RTSPHeaders = .init(), contentType: String? = nil,
                    body: Data = Data()) {
            self.session = session
            self.authorization = authorization
            self.require = require
            self.accept = accept
            self.transport = transport
            self.range = range
            self.scale = scale
            self.rateControl = rateControl
            self.frames = frames
            self.additional = additional
            self.contentType = contentType
            self.body = body
        }
    }

    // MARK: - Building

    /// Builds a request with headers in the canonical order of docs/spec-rtsp.md §3.2.
    ///
    /// `uri` goes on the request line unchanged and must therefore already be the exact string the
    /// Digest `uri=` parameter was computed over — per track for `SETUP`, query included for
    /// playback. `cseq` is the caller's; a retry after a `401` must use a **new** one, because
    /// reusing a `CSeq` breaks Hikvision's pipeline bookkeeping.
    ///
    /// `Content-Length` is emitted exactly when the body is non-empty. A bodyless `GET_PARAMETER`
    /// keepalive therefore carries neither `Content-Length` nor `Content-Type`, which is the form
    /// Hikvision answers `200` to.
    public func build(method: RTSPMethod, uri: String, cseq: UInt32,
                      options: Options = .init()) -> RTSPRequest {
        var headers = RTSPHeaders()
        headers.append("CSeq", String(cseq))
        if let session = options.session { headers.append("Session", session) }
        if let authorization = options.authorization {
            headers.append("Authorization", authorization)
        }
        headers.append("User-Agent", userAgent)
        if let require = options.require { headers.append("Require", require) }
        if let accept = options.accept { headers.append("Accept", accept) }
        if let transport = options.transport { headers.append("Transport", transport) }
        if let range = options.range { headers.append("Range", range) }
        if let scale = options.scale { headers.append("Scale", scale) }
        if let rateControl = options.rateControl { headers.append("Rate-Control", rateControl) }
        if let frames = options.frames { headers.append("Frames", frames) }
        for field in options.additional { headers.append(field.name, field.value) }
        if !options.body.isEmpty {
            if let contentType = options.contentType { headers.append("Content-Type", contentType) }
            headers.append("Content-Length", String(options.body.count))
        }
        return RTSPRequest(method: method, uri: uri, headers: headers,
                           body: options.body, cseq: cseq)
    }

    /// Builds the `200 OK` Vigil answers a server-initiated request with (docs/spec-rtsp.md §16).
    ///
    /// Echoes the request's `CSeq` and `Session`, which is all any Hikvision `ANNOUNCE` handler
    /// looks at. A request that carried no `CSeq` gets none back rather than a fabricated zero.
    public func acknowledgement(for request: RTSPRequest,
                                status: RTSPStatus = .ok) -> RTSPResponse {
        var headers = RTSPHeaders()
        if let cseq = request.headers.first("CSeq") { headers.append("CSeq", cseq) }
        if let session = request.headers.first("Session") { headers.append("Session", session) }
        return RTSPResponse(status: status, reasonPhrase: status.canonicalReason,
                            headers: headers, body: Data(),
                            cseq: request.headers.int("CSeq").flatMap { UInt32(exactly: $0) })
    }
}
