//
//  RTPTrackFormatAdapter.swift
//  VigilRTP
//
//  The one place an SDP media section's `a=rtpmap` / `a=fmtp` fields become a configured
//  `RTPTrackFormat`: encoding-name resolution, the clock-rate fallbacks, `a=fmtp` key normalisation
//  and the Base64 `sprop-*` parameter sets, with a typed error for every way it can fail.
//  Implements docs/API_CONTRACT.md §4.7 and §5.9 (`RTPTrackFormatAdapter`).
//
//  It takes **fields, not an SDP type**, for the reason `RTPTrackFormat` gives: `VigilRTP` must stay
//  usable for UDP, file replay and unit fixtures with no RTSP session at all, so it may not import
//  `VigilRTSP`. The typed overloads that take `SDPMediaDescription` / `RTSPTrack` are three lines
//  each and live in the module that can see both — `VigilCore` in the app, the harness on Linux.
//  Keeping the substance here is what makes it Linux-testable; see
//  `Tests/VigilRTPTests/RTPTrackFormatAdapterTests.swift`.
//

import Foundation
import VigilProtocols

// MARK: - RTPTrackFormatAdapter

/// Builds `RTPTrackFormat` values from the fields an SDP media section carries.
///
/// Everything here is deliberately tolerant of the shapes real cameras emit and intolerant of the
/// ones that cannot be played:
///
/// * Encoding names are matched **case-insensitively** — Hikvision firmware writes `H264` and
///   `h264`, `MPEG4-GENERIC` and `mpeg4-generic`, depending on the build.
/// * `a=fmtp` keys are lower-cased; values are left **verbatim**, because Base64 is case-sensitive
///   and lower-casing an `sprop-parameter-sets` value destroys it.
/// * `sprop-parameter-sets` (H.264) and `sprop-vps` / `sprop-sps` / `sprop-pps` (H.265) are decoded
///   with `VigilProtocols.Base64`, which tolerates the missing `=` padding Hikvision emits and that
///   Foundation's decoder rejects outright.
/// * A codec Vigil cannot depacketize throws `RTPError.unsupportedEncoding` **here**, rather than
///   producing a receiver that silently emits no frames.
public enum RTPTrackFormatAdapter {

    // MARK: - Making a format

    /// Builds the track format for one media section.
    ///
    /// - Parameters:
    ///   - payloadType: the RTP payload type from the `m=` line, i.e. the one `a=rtpmap` describes.
    ///   - encodingName: the `a=rtpmap` encoding name, in whatever case the camera wrote it. Pass
    ///     the empty string when the section carried no `a=rtpmap` at all; the RFC 3551 static
    ///     binding for `payloadType` is then used, and a payload type with no static binding is an
    ///     error rather than a guess.
    ///   - clockRate: the `a=rtpmap` clock rate in Hz. **Zero means "the SDP did not say"** and is
    ///     replaced by the value the payload format fixes — 90 kHz for video (every RFC that defines
    ///     an H.264 or H.265 payload format fixes it there), the codec's default sample rate for
    ///     audio. A negative rate is not an omission and is refused.
    ///   - channels: the audio channel count from `a=rtpmap:… /<channels>`; `nil` for video.
    ///   - fmtp: the `a=fmtp` parameters. Keys may arrive in any case and are normalised here, so a
    ///     caller that has not already lower-cased them does not silently lose
    ///     `packetization-mode` or `sprop-max-don-diff`.
    ///   - parameterSets: already-decoded parameter sets, when the caller has them — `VigilRTSP`'s
    ///     SDP parser decodes `sprop-*` on the way past, and re-decoding is wasted work. Pass `nil`
    ///     and they are decoded from `fmtp` here instead.
    ///
    /// - Returns: a format ready for `RTPTrackReceiver` and `DepacketizerFactory`.
    ///
    /// - Throws: `RTPError.unsupportedEncoding` when the encoding names a payload format Vigil does
    ///   not depacketize, or when the section has no `a=rtpmap` and no static binding — the payload
    ///   names the offending encoding, or the payload type, so one log line diagnoses it.
    ///   `RTPError.invalidClockRate` for a negative rate.
    public static func make(payloadType: UInt8,
                            encodingName: String,
                            clockRate: Int32,
                            channels: Int32? = nil,
                            fmtp: [String: String] = [:],
                            parameterSets: ParameterSets? = nil) throws(RTPError) -> RTPTrackFormat {
        let parameters = normalisedFmtp(fmtp)
        let name = trimmed(encodingName)

        guard !name.isEmpty else {
            return try makeFromStaticBinding(payloadType: payloadType,
                                             clockRate: clockRate,
                                             channels: channels,
                                             fmtp: parameters)
        }
        guard let codec = RTPTrackFormat.resolveCodec(name) else {
            throw RTPError.unsupportedEncoding(name)
        }

        let rate = resolvedClockRate(clockRate, codec: codec)
        let sets = parameterSets ?? Self.parameterSets(for: codec, fmtp: parameters)
        return try RTPTrackFormat(payloadType: payloadType,
                                  encodingName: name,
                                  clockRate: rate,
                                  channels: channels,
                                  fmtp: parameters,
                                  parameterSets: sets)
    }

    /// The RFC 3551 static binding for a section with no `a=rtpmap`, which Hikvision audio
    /// substreams do emit. The caller's `a=fmtp` is kept: a static payload type may still carry one.
    private static func makeFromStaticBinding(payloadType: UInt8,
                                              clockRate: Int32,
                                              channels: Int32?,
                                              fmtp: [String: String]) throws(RTPError)
        -> RTPTrackFormat {
        guard let binding = RTPTrackFormat.staticBinding(for: payloadType) else {
            throw RTPError.unsupportedEncoding("payload type \(payloadType) with no a=rtpmap")
        }
        return try RTPTrackFormat(payloadType: payloadType,
                                  encodingName: binding.encodingName,
                                  clockRate: clockRate > 0 ? clockRate : binding.clockRate,
                                  channels: channels ?? binding.channels,
                                  fmtp: fmtp,
                                  parameterSets: nil)
    }

    // MARK: - Fields

    /// Lower-cases every `a=fmtp` key and leaves every value byte-for-byte alone.
    ///
    /// ASCII-only folding, not Unicode: `İ` must not fold to `i`, or two different parameter names
    /// could compare equal (docs/spec-rtsp.md §2.2). Two keys that differ only in case collapse to
    /// one; the winner is the last in ascending order of the original key, which is arbitrary but
    /// **deterministic** — a dictionary's own iteration order is not, and a value that changed
    /// between runs would be the worst kind of bug to chase.
    public static func normalisedFmtp(_ fmtp: [String: String]) -> [String: String] {
        guard fmtp.contains(where: { $0.key != ASCII.lowercased($0.key) }) else { return fmtp }
        var out: [String: String] = [:]
        out.reserveCapacity(fmtp.count)
        for (key, value) in fmtp.sorted(by: { $0.key < $1.key }) {
            out[ASCII.lowercased(key)] = value
        }
        return out
    }

    /// The clock rate to use, applying the payload format's fixed rate when the SDP omitted one.
    ///
    /// Only an **absent** rate (exactly zero) is substituted. A rate the camera actually stated is
    /// passed through untouched, even when it disagrees with the RFC: `RTPTrackFormat`'s
    /// `hasUnexpectedVideoClockRate` reports that as the camera bug it is, and silently correcting
    /// it here would hide it.
    private static func resolvedClockRate(_ clockRate: Int32, codec: MediaCodec) -> Int32 {
        guard clockRate == 0 else { return clockRate }
        switch codec {
        case .video:
            return RTPTrackFormat.videoClockRate
        case .audio(let audio):
            return audio.defaultSampleRate
        }
    }

    /// Trims spaces and horizontal tabs from both ends of an encoding name.
    private static func trimmed(_ text: String) -> String {
        var slice = Substring(text)
        while let first = slice.first, first == " " || first == "\t" { slice.removeFirst() }
        while let last = slice.last, last == " " || last == "\t" { slice.removeLast() }
        return String(slice)
    }

    // MARK: - Parameter sets

    /// Decodes the `sprop-*` parameter sets an SDP `a=fmtp` line carries.
    ///
    /// H.264 reads `sprop-parameter-sets`, whose value is a comma-separated list of Base64 NAL
    /// units sorted into SPS (type 7) and PPS (type 8) by their own header. H.265 reads
    /// `sprop-vps`, `sprop-sps` and `sprop-pps` separately and keeps only NALs whose type matches
    /// the field they arrived in (32, 33, 34), because a camera that puts an SPS in `sprop-pps` has
    /// told us nothing trustworthy about it.
    ///
    /// Decoding is **lenient** (`Base64.decodeOrNil`): Hikvision omits the `=` padding and
    /// Foundation's `Data(base64Encoded:)` rejects that outright, which would turn a perfectly good
    /// stream into a black tile. An element that still fails to decode, or that carries the wrong
    /// NAL type, is skipped rather than throwing — SPS/PPS are repeated in band before every IDR,
    /// so the stream starts anyway (docs/spec-rtsp.md §8.6).
    ///
    /// - Returns: `nil` for a codec that has no parameter sets, and an **empty** `ParameterSets` for
    ///   a codec that has them when the SDP carried none. Those two cases mean different things and
    ///   the caller must not conflate them.
    public static func parameterSets(for codec: MediaCodec,
                                     fmtp: [String: String]) -> ParameterSets? {
        let parameters = normalisedFmtp(fmtp)
        switch codec {
        case .video(.h264):
            var sets = ParameterSets(codec: .h264)
            for nal in decodeList(parameters["sprop-parameter-sets"]) {
                guard let header = nal.first else { continue }
                switch header & 0x1F {
                case 7: sets.sps.append(Data(nal))
                case 8: sets.pps.append(Data(nal))
                default: continue          // SEI (6) and stray slice NALs are dropped deliberately.
                }
            }
            return sets

        case .video(.h265):
            var sets = ParameterSets(codec: .h265)
            append(decodeList(parameters["sprop-vps"]), ofType: 32, to: &sets.vps)
            append(decodeList(parameters["sprop-sps"]), ofType: 33, to: &sets.sps)
            append(decodeList(parameters["sprop-pps"]), ofType: 34, to: &sets.pps)
            return sets

        default:
            return nil
        }
    }

    /// Splits a `sprop-*` value on `,` and lenient-Base64-decodes each element, dropping the
    /// elements that do not decode and the ones that decode to nothing. An absent value yields an
    /// empty array, which is not an error.
    private static func decodeList(_ value: String?) -> [[UInt8]] {
        guard let value, !value.isEmpty else { return [] }
        return value.split(separator: ",", omittingEmptySubsequences: true).compactMap { piece in
            let text = trimmed(String(piece))
            guard !text.isEmpty, let bytes = Base64.decodeOrNil(text), !bytes.isEmpty else {
                return nil
            }
            return bytes
        }
    }

    /// Appends the H.265 NALs whose type field matches `type` (32 VPS, 33 SPS, 34 PPS).
    ///
    /// The type lives in bits 1…6 of the first header byte (RFC 7798 §1.1.4). A one-byte NAL is
    /// still readable here — the second header byte carries only the layer and temporal ids — so
    /// truncation is not rejected at this level.
    private static func append(_ nals: [[UInt8]], ofType type: UInt8, to out: inout [Data]) {
        for nal in nals {
            guard let header = nal.first, (header >> 1) & 0x3F == type else { continue }
            out.append(Data(nal))
        }
    }
}
