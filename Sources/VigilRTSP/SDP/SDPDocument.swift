//
//  SDPDocument.swift
//  VigilRTSP
//
//  The SDP line model: the session-level document, its attribute list, the `c=` connection value
//  and the `a=rtpmap` value type. Parsing lives in SDPParser.swift; this file is data only.
//  Implements docs/spec-rtsp.md §8.1 and docs/API_CONTRACT.md §4.3.
//

import Foundation

// MARK: - SDPAttribute

/// One `a=` line. `a=recvonly` is a flag attribute (`value == nil`); `a=control:trackID=1` is a
/// valued attribute whose value is everything after the first colon, verbatim.
///
/// `name` is ASCII-lowercased for lookup because Hikvision spells its private attributes in mixed
/// case (`a=Media_header`); `originalName` keeps the spelling for logs.
public struct SDPAttribute: Sendable, Hashable {

    /// ASCII-lowercased attribute name, e.g. `"media_header"`.
    public var name: String

    /// The name exactly as it appeared on the wire.
    public var originalName: String

    /// Everything after the first `:`, verbatim (never trimmed of inner spaces). `nil` for a flag.
    public var value: String?

    /// Stores the three parts as given; no validation, because an SDP attribute has no grammar
    /// beyond "name, optional colon, rest of line".
    public init(name: String, originalName: String, value: String?) {
        self.name = name
        self.originalName = originalName
        self.value = value
    }
}

// MARK: - SDPConnection

/// A `c=` line: `c=IN IP4 0.0.0.0`. RTSP-controlled media never uses this address — the transport
/// is negotiated by `SETUP` — so it is parsed for completeness and diagnostics only.
public struct SDPConnection: Sendable, Hashable {

    /// Network type, always `"IN"` in practice.
    public var networkType: String

    /// Address type, `"IP4"` or `"IP6"`.
    public var addressType: String

    /// The address, including any `/ttl/count` suffix exactly as written.
    public var address: String

    /// Stores the three fields verbatim.
    public init(networkType: String, addressType: String, address: String) {
        self.networkType = networkType
        self.addressType = addressType
        self.address = address
    }
}

// MARK: - SDPRTPMap

/// One `a=rtpmap:<pt> <encoding>/<clock>[/<params>]` line.
public struct SDPRTPMap: Sendable, Hashable {

    /// The dynamic or static payload type this map describes.
    public var payloadType: UInt8

    /// Encoding name with its **original** case (`H264`, `mpeg4-generic`, `PCMA`). Comparison is
    /// case-insensitive everywhere; the case is preserved only so logs match the wire.
    public var encodingName: String

    /// RTP clock rate in Hz. Zero when the line omitted or malformed it, which the caller treats
    /// as "unusable track" rather than dividing by it.
    public var clockRate: Int32

    /// The trailing `/<params>` field: the channel count for audio, absent for video.
    public var encodingParameters: String?

    /// Stores the parsed fields. A `clockRate` of zero is representable on purpose so a malformed
    /// line survives to be reported instead of trapping.
    public init(payloadType: UInt8, encodingName: String, clockRate: Int32,
                encodingParameters: String? = nil) {
        self.payloadType = payloadType
        self.encodingName = encodingName
        self.clockRate = clockRate
        self.encodingParameters = encodingParameters
    }

    /// Channel count parsed from `encodingParameters`, or `nil` when absent or not a number.
    public var channels: Int32? {
        guard let text = encodingParameters, let value = Int32(text) else { return nil }
        return value
    }
}

// MARK: - SDPDirection

/// The direction flag of a media section. Hikvision always sends `a=recvonly` for a stream we
/// consume; `sendrecv` is the SDP default when no flag is present.
public enum SDPDirection: String, Sendable, Hashable, CaseIterable {
    case recvonly, sendonly, sendrecv, inactive
}

// MARK: - SDPDocument

/// A parsed session description.
///
/// Every field is optional or defaulted because the parser never fails on a missing line: the only
/// hard requirements are that the body decodes to text and contains at least one `m=` section
/// (docs/spec-rtsp.md §8.2).
public struct SDPDocument: Sendable, Hashable {

    /// `v=`. Zero when absent — no device has ever sent anything else.
    public var version: Int

    /// `o=`, verbatim.
    public var origin: String?

    /// `s=`. Hikvision sends `Media Presentation`. Non-UTF-8 bytes here are transliterated rather
    /// than rejected, because a mojibake session name must not cost the user their video.
    public var sessionName: String?

    /// `i=`, verbatim.
    public var information: String?

    /// Session-level `c=`.
    public var connection: SDPConnection?

    /// Session-level `b=AS:` in kilobits per second.
    public var bandwidthKbps: Int?

    /// Session-level `a=control`. `"*"` means "the aggregate is the request URI" (§8.3 step 3).
    public var sessionControl: String?

    /// Session-level `a=range` **verbatim** (e.g. `npt=now-`). `VigilRTSP` parses it into an
    /// `RTSPRange` only where it is used, so the SDP model has no dependency on the header layer.
    public var rangeText: String?

    /// Every session-level `a=` line in order, including the ones we ignore.
    public var attributes: [SDPAttribute]

    /// The media sections in `m=` order. Never empty — an SDP without one is a parse error.
    public var media: [SDPMediaDescription]

    /// Lines that had no `=` at all, kept for logging. Never a parse error.
    public var unknownLines: [String]

    /// Builds an empty document. The parser fills it in field by field.
    public init(version: Int = 0,
                origin: String? = nil,
                sessionName: String? = nil,
                information: String? = nil,
                connection: SDPConnection? = nil,
                bandwidthKbps: Int? = nil,
                sessionControl: String? = nil,
                rangeText: String? = nil,
                attributes: [SDPAttribute] = [],
                media: [SDPMediaDescription] = [],
                unknownLines: [String] = []) {
        self.version = version
        self.origin = origin
        self.sessionName = sessionName
        self.information = information
        self.connection = connection
        self.bandwidthKbps = bandwidthKbps
        self.sessionControl = sessionControl
        self.rangeText = rangeText
        self.attributes = attributes
        self.media = media
        self.unknownLines = unknownLines
    }

    /// First session-level attribute with this (case-insensitive) name, or `nil`.
    public func attribute(_ name: String) -> SDPAttribute? {
        let wanted = SDPText.lowercasedASCII(name)
        return attributes.first { $0.name == wanted }
    }
}
