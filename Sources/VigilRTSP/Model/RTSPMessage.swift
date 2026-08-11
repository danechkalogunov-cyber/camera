//
//  RTSPMessage.swift
//  VigilRTSP
//
//  The request and response value types, the byte-exact serializer, and the tagged union the wire
//  decoder emits. Serialization is strict CRLF; parsing lives in Wire/RTSPWireDecoder.swift.
//  Implements docs/spec-rtsp.md §2.3, §3.1 and §3.3, and docs/API_CONTRACT.md §4.3.
//

import Foundation

import VigilProtocols

// MARK: - Request

/// A request Vigil sends, or a server-initiated request it received (`ANNOUNCE`, `OPTIONS`,
/// `REDIRECT`; docs/spec-rtsp.md §16).
public struct RTSPRequest: Sendable, Equatable, CustomStringConvertible {

    /// The method, which also decides whether a body and a `Session` header are legal.
    public var method: RTSPMethod

    /// The Request-URI **exactly as it goes on the wire**: absolute, no userinfo, percent-encoding
    /// preserved verbatim. The Digest `uri=` parameter must equal this string byte for byte
    /// (docs/spec-rtsp.md §6.4), so nothing may re-derive it later.
    public var uri: String

    /// The header block, already in canonical emission order when `RTSPRequestBuilder` made it.
    public var headers: RTSPHeaders

    /// The body. Empty unless `method.allowsRequestBody`.
    public var body: Data

    /// The sequence number. Mirrored into a leading `CSeq` header by `serialized()` when the block
    /// does not already carry one.
    public var cseq: UInt32

    /// Creates a request. No validation happens here: the builder owns the header policy, and the
    /// decoder must be able to represent whatever a device actually sent.
    public init(method: RTSPMethod, uri: String, headers: RTSPHeaders = .init(),
                body: Data = Data(), cseq: UInt32 = 0) {
        self.method = method
        self.uri = uri
        self.headers = headers
        self.body = body
        self.cseq = cseq
    }

    /// The byte-exact wire form: `METHOD SP uri SP RTSP/1.0 CRLF`, one `name: value CRLF` per
    /// field, a bare `CRLF`, then the body.
    ///
    /// Deterministic for a given value — the golden fixtures compare bytes. A `CSeq` header is
    /// inserted at the front when the block lacks one, so a hand-built request cannot go out
    /// without the field Hikvision uses for its pipeline bookkeeping.
    ///
    /// Non-ASCII in a header value (a Chinese-firmware `realm` reaches `Authorization` unchanged)
    /// is written as raw UTF-8, which is the same byte sequence Digest hashed.
    public func serialized() -> Data {
        var block = headers
        if !block.has("CSeq") { block.insertFirst("CSeq", String(cseq)) }
        var out = Data(capacity: 256 + body.count)
        out.appendASCII(method.rawValue)
        out.append(0x20)
        out.appendASCII(uri)
        out.append(0x20)
        out.appendASCII("RTSP/1.0")
        out.appendCRLF()
        for field in block {
            out.appendASCII(field.name)
            out.appendASCII(": ")
            out.appendASCII(field.value)
            out.appendCRLF()
        }
        out.appendCRLF()
        out.append(body)
        return out
    }

    /// A one-line, redacted summary for logs: `DESCRIBE rtsp://host/path CSeq 3`.
    ///
    /// Never the serialized form — that contains `Authorization`. Use `redactedTranscript` when a
    /// full dump is genuinely needed.
    public var description: String {
        "\(method.rawValue) \(Redact.url(uri)) CSeq \(cseq)"
    }

    /// The full message as text with every secret elided, for the diagnostics bundle.
    ///
    /// Request bodies are summarised by length. SDP is received in responses and is retained there
    /// because codec, control-URI and timing lines are essential when diagnosing negotiation.
    public var redactedTranscript: String {
        var text = "\(method.rawValue) \(Redact.url(uri)) RTSP/1.0\n"
        text += headers.description
        if !body.isEmpty { text += "\n<body \(body.count) bytes>" }
        return text
    }
}

// MARK: - Response

/// A response received from a device, or one Vigil sends back to a server-initiated request.
public struct RTSPResponse: Sendable, Equatable, CustomStringConvertible {

    /// The status code as sent.
    public var status: RTSPStatus

    /// The reason phrase as sent. Empty when the device omitted it (`RTSP/1.0 401`, seen on
    /// DS-2CD1xxx); never used for a decision.
    public var reasonPhrase: String

    /// The header block in receive order, duplicates preserved.
    public var headers: RTSPHeaders

    /// The body, exactly `Content-Length` bytes. Empty when the header was absent.
    public var body: Data

    /// The `CSeq` the device echoed, or `nil` when it omitted it — a protocol violation the session
    /// machine logs and ignores rather than treating as fatal.
    public var cseq: UInt32?

    /// Creates a response.
    public init(status: RTSPStatus, reasonPhrase: String = "", headers: RTSPHeaders = .init(),
                body: Data = Data(), cseq: UInt32? = nil) {
        self.status = status
        self.reasonPhrase = reasonPhrase
        self.headers = headers
        self.body = body
        self.cseq = cseq
    }

    /// The byte-exact wire form. Vigil sends responses only to server-initiated requests
    /// (docs/spec-rtsp.md §16); the reason phrase falls back to the canonical one when empty.
    public func serialized() -> Data {
        var out = Data(capacity: 128 + body.count)
        out.appendASCII("RTSP/1.0 ")
        out.appendASCII(String(status.rawValue))
        out.append(0x20)
        out.appendASCII(reasonPhrase.isEmpty ? status.canonicalReason : reasonPhrase)
        out.appendCRLF()
        for field in headers {
            out.appendASCII(field.name)
            out.appendASCII(": ")
            out.appendASCII(field.value)
            out.appendCRLF()
        }
        out.appendCRLF()
        out.append(body)
        return out
    }

    /// A one-line, redacted summary for logs: `401 Unauthorized CSeq 2 body 0 B`.
    public var description: String {
        let sequence = cseq.map(String.init) ?? "-"
        return "\(status.rawValue) \(reasonPhrase.isEmpty ? status.canonicalReason : reasonPhrase) "
            + "CSeq \(sequence) body \(body.count) B"
    }

    /// The full message as text with every secret elided (`WWW-Authenticate` included).
    /// SDP bodies are retained; other payloads are represented only by their size.
    public var redactedTranscript: String {
        var text = "RTSP/1.0 \(status.rawValue) "
        text += reasonPhrase.isEmpty ? status.canonicalReason : reasonPhrase
        text += "\n" + headers.description
        if !body.isEmpty {
            if headers.first("Content-Type")?.lowercased().hasPrefix("application/sdp") == true {
                text += "\n\n" + String(decoding: body, as: UTF8.self)
            } else {
                text += "\n<body \(body.count) bytes>"
            }
        }
        return Redact.secrets(in: text)
    }
}

// MARK: - Incoming

/// One complete unit read off the connection.
///
/// A `$` interleaved frame, an RTSP response, a server-initiated RTSP request, or a framing fault.
/// `.malformed` exists because the decoder does not throw (API_CONTRACT §4.3): a fault must be able
/// to arrive *after* the events that were already decodable from the same chunk, and a `throws`
/// signature would discard them.
public enum RTSPIncoming: Sendable, Equatable {

    /// A response to one of our requests.
    case response(RTSPResponse)

    /// A request the server originated. Vigil answers `ANNOUNCE`, `OPTIONS` and `GET_PARAMETER`.
    case request(RTSPRequest)

    /// One complete RTP or RTCP packet from an interleaved channel, payload only.
    case interleaved(channel: UInt8, payload: Data)

    /// The byte stream could not be framed. `fault.isRecoverable` says whether the decoder
    /// resynchronized (and may still produce more events) or stopped for good.
    case malformed(RTSPFramingFault)
}

// MARK: - Framing faults

/// Exactly what the decoder rejected, and why.
///
/// This is the diagnosable half of a framing failure; `rtspError` maps it onto the domain error the
/// session machine reports (API_CONTRACT §2 R-10 keeps the error *enums* in `VigilProtocols`, and
/// that enum is deliberately coarser than this one — `.headerTooLarge` cannot tell an oversized
/// start line from a 40 KiB header block, and a support log needs to).
public enum RTSPFramingFault: Sendable, Hashable, CustomStringConvertible {

    /// No CRLF within `maxStartLine` bytes.
    case startLineTooLong(bytes: Int)
    /// One header line exceeded `maxHeaderLine` bytes without terminating.
    case headerLineTooLong(bytes: Int)
    /// The accumulated header block exceeded `maxHeaderBlock` bytes.
    case headerBlockTooLarge(bytes: Int)
    /// More than `maxHeaderFields` fields in one block.
    case tooManyHeaderFields(count: Int)
    /// `Content-Length` exceeded `maxBody`.
    case bodyTooLarge(declared: Int, limit: Int)
    /// `Content-Length` was not a non-negative base-10 integer.
    case malformedContentLength(String)
    /// Two `Content-Length` headers disagreed. Refused as request smuggling, even on a LAN.
    case conflictingContentLength(String, String)
    /// A `2xx` `application/sdp` response with no `Content-Length`. Unusable over interleaved TCP,
    /// where there is no "read to end of connection" mode.
    case missingContentLength(cseq: UInt32?)
    /// The start line was an HTTP status line: something that is not an RTSP server is listening on
    /// this port. Terminal — resynchronizing against an HTTP server never converges.
    case notRTSP(startLine: String)
    /// The start line was neither `RTSP/1.x <code> …` nor `<METHOD> <uri> RTSP/1.x`.
    case malformedStartLine(String)
    /// A request start line naming a method Vigil does not implement.
    case unknownMethod(String)
    /// Buffered bytes passed `receiveHighWater` with no complete unit in sight.
    case receiveBufferOverflow(bytes: Int)
    /// Resynchronization scanned past `maxResyncScan` without finding a frame or a status line.
    case unrecoverableFraming(scanned: Int)
    /// A `$` frame named a channel no `SETUP` negotiated. Triggers resynchronization.
    case unknownInterleavedChannel(UInt8)

    /// The domain error the session machine surfaces for this fault.
    ///
    /// Size violations become `.headerTooLarge`, framing confusion becomes `.interleaveDesync`, and
    /// everything a parser rejected becomes `.malformedResponse`.
    public var rtspError: RTSPError {
        switch self {
        case .startLineTooLong(let bytes): .headerTooLarge(bytes: bytes)
        case .headerLineTooLong(let bytes): .headerTooLarge(bytes: bytes)
        case .headerBlockTooLarge(let bytes): .headerTooLarge(bytes: bytes)
        case .tooManyHeaderFields(let count): .headerTooLarge(bytes: count)
        case .bodyTooLarge(let declared, _): .headerTooLarge(bytes: declared)
        case .receiveBufferOverflow(let bytes): .headerTooLarge(bytes: bytes)
        case .unknownInterleavedChannel: .interleaveDesync(recovered: true)
        case .unrecoverableFraming: .interleaveDesync(recovered: false)
        default: .malformedResponse
        }
    }

    /// Whether the decoder can keep going on this connection.
    ///
    /// Recoverable faults resynchronize; the rest put the decoder in its terminal state, where it
    /// drops its buffer and returns no further events, so a hostile peer cannot make it grow.
    public var isRecoverable: Bool {
        switch self {
        case .malformedStartLine, .unknownMethod, .unknownInterleavedChannel: true
        default: false
        }
    }

    public var description: String {
        switch self {
        case .startLineTooLong(let bytes): "start line exceeded \(bytes) bytes with no CRLF"
        case .headerLineTooLong(let bytes): "header line exceeded \(bytes) bytes with no CRLF"
        case .headerBlockTooLarge(let bytes): "header block exceeded \(bytes) bytes"
        case .tooManyHeaderFields(let count): "header block carried more than \(count) fields"
        case .bodyTooLarge(let declared, let limit):
            "Content-Length \(declared) exceeds the \(limit) byte cap"
        case .malformedContentLength(let raw): "Content-Length is not a byte count: \"\(raw)\""
        case .conflictingContentLength(let first, let second):
            "two Content-Length headers disagree: \"\(first)\" and \"\(second)\""
        case .missingContentLength(let cseq):
            "SDP response for CSeq \(cseq.map(String.init) ?? "-") carried no Content-Length"
        case .notRTSP(let line): "the peer is not an RTSP server; it answered \"\(line)\""
        case .malformedStartLine(let line): "unparseable start line \"\(line)\""
        case .unknownMethod(let method): "server-initiated request used method \"\(method)\""
        case .receiveBufferOverflow(let bytes): "\(bytes) bytes buffered with no complete message"
        case .unrecoverableFraming(let scanned): "resync scanned \(scanned) bytes and found nothing"
        case .unknownInterleavedChannel(let channel): "interleaved frame on unknown channel \(channel)"
        }
    }
}

// MARK: - Byte helpers

extension Data {

    /// Appends the UTF-8 bytes of `text`.
    ///
    /// Named `ASCII` because everything Vigil generates is ASCII by construction; a non-ASCII value
    /// that arrived from a device is passed through as the UTF-8 it already was, rather than being
    /// escaped or rejected — Digest hashed those same bytes (docs/spec-rtsp.md §3.3).
    fileprivate mutating func appendASCII(_ text: String) {
        append(contentsOf: text.utf8)
    }

    /// Appends CR LF. Vigil never emits a bare LF.
    fileprivate mutating func appendCRLF() {
        append(contentsOf: [0x0D, 0x0A] as [UInt8])
    }
}
