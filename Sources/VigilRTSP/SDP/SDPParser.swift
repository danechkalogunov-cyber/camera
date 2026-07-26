//
//  SDPParser.swift
//  VigilRTSP
//
//  The lenient SDP parser: bare LF, lone CR, a trailing NUL, a UTF-8 BOM, non-UTF-8 text and every
//  unknown attribute are tolerated. The only hard failures are "not text" and "no media section".
//  Implements docs/spec-rtsp.md §8.2, §8.4, §8.5 and docs/API_CONTRACT.md §4.3.
//

import Foundation
import VigilProtocols

/// Parses an `application/sdp` body into an `SDPDocument`.
///
/// The parser is deliberately forgiving. Hikvision firmware appends a NUL counted in
/// `Content-Length`, uses bare LF on some DVR builds, and emits private attributes
/// (`a=Media_header`, `a=appversion`) that must be ignored in silence rather than surfaced as
/// warnings. None of those may cost the user their video.
public struct SDPParser: Sendable {

    /// Parses `body`.
    ///
    /// - Parameter body: the raw response body, framing already removed.
    /// - Returns: the document, with at least one media section.
    /// - Throws: `RTSPError.sdpParse` when the body is empty or contains no `m=` line. Nothing
    ///   else throws: an unrecognised line goes to `unknownLines`, a malformed `a=rtpmap` leaves
    ///   the clock rate at zero, and an undecodable `sprop-*` is dropped.
    public static func parse(_ body: Data) throws(RTSPError) -> SDPDocument {
        let text = decodeText(sanitised(body))
        guard !text.isEmpty else { throw RTSPError.sdpParse("empty SDP body") }

        var document = SDPDocument()
        var sections: [Section] = []

        for rawLine in splitLines(text) {
            let line = SDPText.trimmedOWS(rawLine)
            guard !line.isEmpty else { continue }
            guard let (type, value) = splitTypedLine(line) else {
                document.unknownLines.append(line)
                continue
            }
            if type == "m" {
                sections.append(Section(index: sections.count, mediaLine: value))
                continue
            }
            if sections.isEmpty {
                applySessionLine(type: type, value: value, into: &document)
            } else {
                sections[sections.count - 1].apply(type: type, value: value)
            }
        }

        guard !sections.isEmpty else { throw RTSPError.sdpParse("no m= media section") }
        document.media = sections.map { $0.finish() }
        return document
    }

    // MARK: - Session-level lines

    private static func applySessionLine(type: Character, value: String,
                                         into document: inout SDPDocument) {
        switch type {
        case "v": document.version = Int(value) ?? 0
        case "o": document.origin = value
        case "s": document.sessionName = value
        case "i": document.information = value
        case "c": document.connection = parseConnection(value)
        case "b": document.bandwidthKbps = SectionParsing.bandwidth(value) ?? document.bandwidthKbps
        case "a":
            let attribute = SectionParsing.attribute(value)
            document.attributes.append(attribute)
            switch attribute.name {
            case "control": document.sessionControl = attribute.value
            case "range": document.rangeText = attribute.value
            default: break
            }
        default: break                      // t=, e=, p=, u=, z=, k=, r= carry nothing we use.
        }
    }

    // MARK: - Shared line helpers

    /// Splits `x=value`. Returns `nil` when the line is not of that shape, which sends it to
    /// `unknownLines` instead of failing the parse.
    private static func splitTypedLine(_ line: String) -> (Character, String)? {
        var index = line.startIndex
        guard index < line.endIndex else { return nil }
        let type = line[index]
        index = line.index(after: index)
        guard index < line.endIndex, line[index] == "=" else { return nil }
        return (type, String(line[line.index(after: index)...]))
    }

    /// `c=IN IP4 0.0.0.0`. Missing fields become empty strings rather than a failure.
    private static func parseConnection(_ value: String) -> SDPConnection {
        let parts = value.split(separator: " ", omittingEmptySubsequences: true)
        return SDPConnection(networkType: parts.count > 0 ? String(parts[0]) : "",
                             addressType: parts.count > 1 ? String(parts[1]) : "",
                             address: parts.count > 2 ? String(parts[2]) : "")
    }

    // MARK: - Byte-level preparation

    /// Removes a leading UTF-8 BOM and every trailing NUL or ASCII space/tab/CR/LF.
    ///
    /// Hikvision 5.4.x appends a NUL to the SDP **and counts it in `Content-Length`**, so it
    /// arrives inside the body and would otherwise become a stray unknown line.
    private static func sanitised(_ body: Data) -> [UInt8] {
        var bytes = [UInt8](body)
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            bytes.removeFirst(3)
        }
        while let last = bytes.last,
              last == 0x00 || last == 0x20 || last == 0x09 || last == 0x0D || last == 0x0A {
            bytes.removeLast()
        }
        return bytes
    }

    /// UTF-8 where possible, ISO-8859-1 byte mapping otherwise.
    ///
    /// A camera with a Chinese `s=` line on a mis-configured firmware must not kill the stream, so
    /// there is no failure path: every byte sequence maps to some string.
    private static func decodeText(_ bytes: [UInt8]) -> String {
        if let text = String(bytes: bytes, encoding: .utf8) { return text }
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(bytes.count)
        for byte in bytes { scalars.append(UnicodeScalar(byte)) }
        return String(scalars)
    }

    /// Splits on CRLF, bare LF **and** lone CR. All three have been observed.
    private static func splitLines(_ text: String) -> [Substring] {
        text.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" || $0 == "\r" })
    }
}

// MARK: - Section accumulator

/// Mutable scratch state for one `m=` section, finalised into an `SDPMediaDescription`.
private struct Section {

    var index: Int
    var mediaType = ""
    var port: UInt16 = 0
    var proto = "RTP/AVP"
    var formats: [UInt8] = []
    var rtpmaps: [UInt8: SDPRTPMap] = [:]
    var fmtps: [UInt8: String] = [:]
    var control: String?
    var bandwidthKbps: Int?
    var dimensions: Resolution?
    var framerate: Double?
    var direction: SDPDirection = .sendrecv
    var attributes: [SDPAttribute] = []

    /// `m=video 0 RTP/AVP 96 97`. A `port/count` form keeps only the port; the count is
    /// meaningless for RTSP-controlled media.
    init(index: Int, mediaLine: String) {
        self.index = index
        let parts = mediaLine.split(separator: " ", omittingEmptySubsequences: true)
        if parts.count > 0 { mediaType = String(parts[0]) }
        if parts.count > 1 {
            let portField = parts[1].split(separator: "/", omittingEmptySubsequences: true).first
            port = UInt16(portField ?? "0") ?? 0
        }
        if parts.count > 2 { proto = String(parts[2]) }
        for field in parts.dropFirst(3) {
            if let value = UInt8(field) { formats.append(value) }
        }
    }

    mutating func apply(type: Character, value: String) {
        switch type {
        case "b": bandwidthKbps = SectionParsing.bandwidth(value) ?? bandwidthKbps
        case "a": applyAttribute(value)
        default: break                      // c=, i=, k= carry nothing the transport layer needs.
        }
    }

    private mutating func applyAttribute(_ value: String) {
        let attribute = SectionParsing.attribute(value)
        attributes.append(attribute)
        switch attribute.name {
        case "control":
            control = attribute.value       // Duplicate a=control: the last one wins (§8.2).
        case "rtpmap":
            if let map = SectionParsing.rtpmap(attribute.value) { rtpmaps[map.payloadType] = map }
        case "fmtp":
            if let (payloadType, parameters) = SectionParsing.fmtp(attribute.value) {
                fmtps[payloadType] = parameters
            }
        case "x-dimensions":
            dimensions = SectionParsing.dimensions(attribute.value)
        case "framerate", "x-framerate":
            framerate = attribute.value.flatMap { Double(SDPText.trimmedOWS($0)) }
        case "recvonly", "sendonly", "sendrecv", "inactive":
            direction = SDPDirection(rawValue: attribute.name) ?? .sendrecv
        default:
            break                           // Media_header, appversion, x-onvif-track, x-qt-*, …
        }
    }

    /// Chooses the payload type and materialises the immutable description.
    func finish() -> SDPMediaDescription {
        let chosen = selectFormat()
        let rtpmap = chosen.flatMap { rtpmaps[$0] }
        let fallback = chosen.flatMap { SDPCodecTable.staticFormat($0) }
        let encodingName = rtpmap?.encodingName ?? fallback?.0 ?? ""
        let clockRate = rtpmap.map { $0.clockRate } ?? fallback?.1 ?? 0
        let channels = rtpmap?.channels ?? fallback?.2
        let parameters = chosen.flatMap { fmtps[$0] }.map(SectionParsing.fmtpParameters) ?? [:]
        let codec = SDPCodecTable.codec(forEncoding: encodingName)

        return SDPMediaDescription(
            index: index,
            kind: SDPMediaDescription.Kind(rawValue: SDPText.lowercasedASCII(mediaType))
                ?? .application,
            mediaType: mediaType,
            port: port,
            proto: proto,
            formats: formats,
            payloadType: chosen ?? 0,
            encodingName: encodingName,
            clockRate: clockRate,
            channels: channels,
            fmtp: parameters,
            control: control,
            parameterSets: SDPMediaDescription.extractParameterSets(codec: codec, fmtp: parameters),
            bandwidthKbps: bandwidthKbps,
            hintedDimensions: dimensions,
            framerate: framerate,
            direction: direction,
            attributes: attributes)
    }

    /// The first offered format Vigil recognises; failing that the first with an `rtpmap`; failing
    /// that the first offered at all (docs/spec-rtsp.md §8.4).
    private func selectFormat() -> UInt8? {
        for format in formats {
            let name = rtpmaps[format]?.encodingName ?? SDPCodecTable.staticFormat(format)?.0
            if let name, SDPCodecTable.codec(forEncoding: name) != nil { return format }
        }
        return formats.first { rtpmaps[$0] != nil } ?? formats.first
    }
}

// MARK: - Attribute value parsing

/// Value parsers shared by the section accumulator. Every one returns `nil` rather than throwing:
/// a malformed attribute degrades the track, it does not fail the document.
private enum SectionParsing {

    static func attribute(_ value: String) -> SDPAttribute {
        guard let (head, tail) = SDPText.splitOnce(value, separator: ":") else {
            let name = SDPText.trimmedOWS(value)
            return SDPAttribute(name: SDPText.lowercasedASCII(name), originalName: name, value: nil)
        }
        let name = SDPText.trimmedOWS(head)
        return SDPAttribute(name: SDPText.lowercasedASCII(name), originalName: name,
                            value: SDPText.trimmedOWS(tail))
    }

    static func bandwidth(_ value: String) -> Int? {
        guard let (modifier, amount) = SDPText.splitOnce(value, separator: ":"),
              SDPText.lowercasedASCII(SDPText.trimmedOWS(modifier)) == "as" else { return nil }
        return Int(SDPText.trimmedOWS(amount))
    }

    /// `96 H264/90000` or `104 mpeg4-generic/16000/1`.
    static func rtpmap(_ value: String?) -> SDPRTPMap? {
        guard let value else { return nil }
        let parts = value.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let payloadType = UInt8(parts[0]) else { return nil }
        let fields = parts[1].split(separator: "/", omittingEmptySubsequences: false)
        guard let name = fields.first, !name.isEmpty else { return nil }
        let clockRate = fields.count > 1 ? Int32(fields[1]) ?? 0 : 0
        let encodingParameters = fields.count > 2 ? String(fields[2]) : nil
        return SDPRTPMap(payloadType: payloadType, encodingName: String(name),
                         clockRate: clockRate, encodingParameters: encodingParameters)
    }

    /// `96 profile-level-id=640028; packetization-mode=1; sprop-parameter-sets=…`
    static func fmtp(_ value: String?) -> (UInt8, String)? {
        guard let value,
              let (head, tail) = SDPText.splitOnce(value, separator: " "),
              let payloadType = UInt8(SDPText.trimmedOWS(head)) else { return nil }
        return (payloadType, tail)
    }

    /// Splits on `;`, then on the **first** `=`. Keys are ASCII-lowercased; values are kept
    /// verbatim because `sprop-parameter-sets` is base64 and base64 is case-sensitive.
    static func fmtpParameters(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        for piece in raw.split(separator: ";", omittingEmptySubsequences: true) {
            let trimmed = SDPText.trimmedOWS(piece)
            guard !trimmed.isEmpty else { continue }
            if let (name, value) = SDPText.splitOnce(trimmed, separator: "=") {
                let key = SDPText.lowercasedASCII(SDPText.trimmedOWS(name))
                guard !key.isEmpty else { continue }
                out[key] = SDPText.trimmedOWS(value)
            } else {
                out[SDPText.lowercasedASCII(trimmed)] = ""
            }
        }
        return out
    }

    /// `a=x-dimensions:1920,1080`.
    static func dimensions(_ value: String?) -> Resolution? {
        guard let value, let (width, height) = SDPText.splitOnce(value, separator: ","),
              let w = Int(SDPText.trimmedOWS(width)), let h = Int(SDPText.trimmedOWS(height)),
              w > 0, h > 0 else { return nil }
        return Resolution(width: w, height: h)
    }
}
