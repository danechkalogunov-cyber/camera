//
//  SDPMediaDescription.swift
//  VigilRTSP
//
//  One `m=` section: the selected payload type, its `rtpmap`/`fmtp` parameters and the parameter
//  sets decoded from `sprop-*`. Also the small ASCII/text helpers the SDP layer shares.
//  Implements docs/spec-rtsp.md §8.1, §8.4, §8.5, §8.6 and docs/API_CONTRACT.md §4.3.
//

import Foundation
import VigilProtocols

// MARK: - SDPText

/// ASCII-only text helpers for the SDP and framing layers.
///
/// Unicode case folding is deliberately not used: `İ` must not fold to `i`, or a hostile session
/// name could make two different attribute names compare equal (docs/spec-rtsp.md §2.2).
enum SDPText {

    /// Lowercases `A...Z` and nothing else.
    static func lowercasedASCII(_ text: String) -> String {
        String(decoding: text.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 &+ 0x20 : $0 }, as: UTF8.self)
    }

    /// Trims spaces and horizontal tabs from both ends. Does not touch CR/LF: the line splitter
    /// has already removed those, and a stray CR inside a value is data, not whitespace.
    static func trimmedOWS(_ text: some StringProtocol) -> String {
        var slice = Substring(text)
        while let first = slice.first, first == " " || first == "\t" { slice.removeFirst() }
        while let last = slice.last, last == " " || last == "\t" { slice.removeLast() }
        return String(slice)
    }

    /// Splits at the **first** occurrence of `separator`, returning `nil` when it never occurs.
    /// Used for `name=value` where the value may itself contain the separator — base64 padding in
    /// `sprop-parameter-sets` is exactly that case.
    static func splitOnce(_ text: some StringProtocol,
                          separator: Character) -> (head: String, tail: String)? {
        guard let index = text.firstIndex(of: separator) else { return nil }
        return (String(text[text.startIndex..<index]),
                String(text[text.index(after: index)...]))
    }
}

// MARK: - SDPMediaDescription

/// One media section, reduced to the single payload type Vigil will actually receive.
///
/// An `m=` line may offer several formats. The parser keeps every offered payload type in
/// `formats` (so `VigilRTP` can detect a mid-stream payload-type change) but resolves
/// `payloadType`, `encodingName`, `clockRate` and `fmtp` to the **first offered format Vigil
/// recognises**, falling back to the first format when none is recognised
/// (docs/spec-rtsp.md §8.4).
public struct SDPMediaDescription: Sendable, Hashable {

    /// The media kind from the `m=` line. Anything that is not `video` or `audio` is reported as
    /// `application`, with the wire spelling preserved in `mediaType`.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case video, audio, application
    }

    // MARK: Stored Properties

    /// Index of this section in `m=` order, from zero. Stable for the life of the session and used
    /// as the track id everywhere downstream.
    public var index: Int

    /// The parsed kind.
    public var kind: Kind

    /// The `m=` media type verbatim (`video`, `audio`, `application`, `text`, …).
    public var mediaType: String

    /// The `m=` port. Always zero for RTSP-controlled media, and always ignored: the transport
    /// comes from the `Transport` header, never from here.
    public var port: UInt16

    /// The `m=` transport protocol, e.g. `"RTP/AVP"`.
    public var proto: String

    /// Every payload type offered on the `m=` line, in order.
    public var formats: [UInt8]

    /// The selected payload type.
    public var payloadType: UInt8

    /// Encoding name of the selected format, original case (`H264`, `H265`, `PCMA`). Empty when
    /// the format has neither an `rtpmap` nor a static assignment.
    public var encodingName: String

    /// RTP clock rate of the selected format in Hz; zero when unknown.
    public var clockRate: Int32

    /// Audio channel count, from `a=rtpmap:… /<channels>`; `nil` for video or when absent.
    public var channels: Int32?

    /// `a=fmtp` parameters of the selected format. **Keys are ASCII-lowercased, values verbatim**
    /// because base64 is case-sensitive (docs/API_CONTRACT.md §4.3, docs/spec-rtsp.md §8.5).
    public var fmtp: [String: String]

    /// Raw `a=control` value, unresolved. `ControlURLResolver` turns it into a SETUP URI.
    public var control: String?

    /// Parameter sets decoded from `sprop-*`, for H.264 and H.265 only; `nil` for every other
    /// codec. **Empty sets are normal, not an error**: Hikvision repeats SPS/PPS in band before
    /// every IDR, so a stream starts fine without them (docs/spec-rtsp.md §8.6).
    public var parameterSets: ParameterSets?

    /// `b=AS:` for this section, in kilobits per second.
    public var bandwidthKbps: Int?

    /// `a=x-dimensions:1920,1080` — a resolution hint that lets the UI size a view before the SPS
    /// arrives. Never authoritative; the bitstream is.
    public var hintedDimensions: Resolution?

    /// `a=framerate` or `a=x-framerate`.
    public var framerate: Double?

    /// The direction flag; `sendrecv` when the section has none.
    public var direction: SDPDirection

    /// Every `a=` line of this section, in order, including the ignored Hikvision extras.
    public var attributes: [SDPAttribute]

    // MARK: Initialisation

    /// Builds a media description. Every argument is defaulted so the parser can fill fields in
    /// the order the lines arrive.
    public init(index: Int = 0,
                kind: Kind = .application,
                mediaType: String = "",
                port: UInt16 = 0,
                proto: String = "RTP/AVP",
                formats: [UInt8] = [],
                payloadType: UInt8 = 0,
                encodingName: String = "",
                clockRate: Int32 = 0,
                channels: Int32? = nil,
                fmtp: [String: String] = [:],
                control: String? = nil,
                parameterSets: ParameterSets? = nil,
                bandwidthKbps: Int? = nil,
                hintedDimensions: Resolution? = nil,
                framerate: Double? = nil,
                direction: SDPDirection = .sendrecv,
                attributes: [SDPAttribute] = []) {
        self.index = index
        self.kind = kind
        self.mediaType = mediaType
        self.port = port
        self.proto = proto
        self.formats = formats
        self.payloadType = payloadType
        self.encodingName = encodingName
        self.clockRate = clockRate
        self.channels = channels
        self.fmtp = fmtp
        self.control = control
        self.parameterSets = parameterSets
        self.bandwidthKbps = bandwidthKbps
        self.hintedDimensions = hintedDimensions
        self.framerate = framerate
        self.direction = direction
        self.attributes = attributes
    }

    // MARK: Computed Properties

    /// The codec Vigil will decode, or `nil` when the encoding is one we cannot handle
    /// (`MP4V-ES`, `MPEG4-LATM`, `vnd.onvif.metadata`, an unknown name, or no `rtpmap` at all).
    public var codec: MediaCodec? { SDPCodecTable.codec(forEncoding: encodingName) }

    /// H.264 `packetization-mode`; `nil` when absent. Mode 2 (interleaved) is unsupported and the
    /// session machine refuses the track rather than producing scrambled video.
    public var packetizationMode: Int? { fmtp["packetization-mode"].flatMap(Int.init) }

    /// H.265 `sprop-max-don-diff`; zero when absent. Must be forwarded to `VigilRTP`: a non-zero
    /// value means the payload carries DONL fields that change the depacketizer's layout.
    public var spropMaxDONDiff: Int { fmtp["sprop-max-don-diff"].flatMap(Int.init) ?? 0 }

    /// AAC `config=` decoded from hex, or `nil` when absent or not valid hex.
    public var aacConfig: [UInt8]? { fmtp["config"].flatMap(SDPCodecTable.hexBytes) }
}

// MARK: - SDPCodecTable

/// The encoding-name → codec table of docs/spec-rtsp.md §8.4, plus the RFC 3551 static payload
/// types Hikvision omits an `a=rtpmap` for.
enum SDPCodecTable {

    /// Case-insensitive encoding-name lookup. Returns `nil` for names Vigil cannot decode, which
    /// is not an error here: the session machine decides whether a track is usable.
    static func codec(forEncoding name: String) -> MediaCodec? {
        switch SDPText.lowercasedASCII(name) {
        case "h264": .video(.h264)
        case "h265", "hevc": .video(.h265)
        case "jpeg": .video(.mjpeg)
        case "mpeg4-generic": .audio(.aac)
        case "pcma": .audio(.g711A)
        case "pcmu": .audio(.g711U)
        case "g726-16", "g726-24", "g726-32", "g726-40": .audio(.g726)
        default: nil
        }
    }

    /// RFC 3551 static payload types: `(encoding, clockRate, channels)`. Used when a media section
    /// lists a static type with no `a=rtpmap`, which Hikvision audio substreams do.
    static func staticFormat(_ payloadType: UInt8) -> (String, Int32, Int32?)? {
        switch payloadType {
        case 0: ("PCMU", 8_000, 1)
        case 8: ("PCMA", 8_000, 1)
        case 14: ("MPA", 90_000, nil)
        case 26: ("JPEG", 90_000, nil)
        case 33: ("MP2T", 90_000, nil)
        default: nil
        }
    }

    /// Decodes an even-length hex string. Returns `nil` on an odd length or a non-hex digit, so a
    /// malformed `config=` degrades to "no AAC config" instead of throwing.
    static func hexBytes(_ text: String) -> [UInt8]? {
        let digits = Array(text.utf8)
        guard !digits.isEmpty, digits.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else {
                return nil
            }
            out.append(high << 4 | low)
            index += 2
        }
        return out
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }
}

// MARK: - Parameter-set extraction

extension SDPMediaDescription {

    /// Decodes `sprop-parameter-sets` (H.264) or `sprop-vps`/`sprop-sps`/`sprop-pps` (H.265) from
    /// `fmtp` into raw NAL bytes, **without** a start code and **without** a length prefix.
    ///
    /// Every value may be a comma-separated list and may be **unpadded** base64 — Hikvision emits
    /// both forms — so decoding goes through `VigilProtocols.Base64`, which is padding-tolerant.
    /// A value that fails to decode, or a NAL whose type does not match the field it arrived in,
    /// is skipped: the stream still starts from the in-band parameter sets that precede every IDR.
    ///
    /// Returns `nil` for a codec that has no parameter sets, and an **empty** `ParameterSets` when
    /// the codec has them but the SDP carried none. The two cases are different and the caller
    /// must not conflate them.
    static func extractParameterSets(codec: MediaCodec?,
                                     fmtp: [String: String]) -> ParameterSets? {
        switch codec {
        case .video(.h264):
            var sets = ParameterSets(codec: .h264)
            for nal in decodeList(fmtp["sprop-parameter-sets"]) {
                guard let first = nal.first else { continue }
                switch first & 0x1F {
                case 7: sets.sps.append(Data(nal))
                case 8: sets.pps.append(Data(nal))
                default: continue        // SEI (6) and stray slice NALs are dropped deliberately.
                }
            }
            return sets
        case .video(.h265):
            var sets = ParameterSets(codec: .h265)
            appendH265(decodeList(fmtp["sprop-vps"]), expecting: 32, into: &sets.vps)
            appendH265(decodeList(fmtp["sprop-sps"]), expecting: 33, into: &sets.sps)
            appendH265(decodeList(fmtp["sprop-pps"]), expecting: 34, into: &sets.pps)
            return sets
        default:
            return nil
        }
    }

    /// Splits a `sprop-*` value on `,` and lenient-base64-decodes each element, dropping the ones
    /// that do not decode. An absent value yields an empty array.
    private static func decodeList(_ value: String?) -> [[UInt8]] {
        guard let value, !value.isEmpty else { return [] }
        return value.split(separator: ",", omittingEmptySubsequences: true).compactMap { piece in
            let trimmed = SDPText.trimmedOWS(piece)
            guard !trimmed.isEmpty, let bytes = Base64.decodeOrNil(trimmed), !bytes.isEmpty else {
                return nil
            }
            return bytes
        }
    }

    /// Appends H.265 NALs whose type field matches `expecting` (32 VPS, 33 SPS, 34 PPS).
    private static func appendH265(_ nals: [[UInt8]], expecting type: UInt8, into out: inout [Data]) {
        for nal in nals {
            guard let first = nal.first, (first >> 1) & 0x3F == type else { continue }
            out.append(Data(nal))
        }
    }
}
