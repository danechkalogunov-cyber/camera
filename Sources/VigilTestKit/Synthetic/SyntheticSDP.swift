//
//  SyntheticSDP.swift
//  VigilTestKit
//
//  Builds the SDP a Hikvision camera answers DESCRIBE with, including the `sprop-*` forms of the
//  parameter sets the fixture actually generated, so the client derives the same geometry from the
//  SDP as it would from the in-band NALs. Quirks reshape it: unpadded base64, no `sprop-*` at all,
//  proprietary attributes, absolute control URLs and a literal `$` in the body.
//  Implements docs/ARCHITECTURE.md §10.2.
//

import VigilProtocols

// MARK: - Builder

/// Renders one session description for a profile.
public struct SyntheticSDPBuilder: Sendable {

    private let profile: SyntheticCameraProfile
    private let host: String
    private let sessionVersion: UInt64

    /// - Parameters:
    ///   - host: the address the camera believes it is reachable at, used in `o=` and in absolute
    ///     control URLs.
    ///   - sessionVersion: the `o=` session id/version, derived from the seed so it is stable.
    public init(profile: SyntheticCameraProfile, host: String, sessionVersion: UInt64) {
        self.profile = profile
        self.host = host
        self.sessionVersion = sessionVersion
    }

    /// The base URL track control resolves against, with the trailing slash Hikvision sends.
    public var contentBase: String { "rtsp://\(host)\(profile.streamPath)/" }

    /// The `a=control` value for the video track, absolute or relative per the quirk set.
    public var trackControl: String {
        profile.quirks.contains(.absoluteControlURL)
            ? "rtsp://\(host)\(profile.streamPath)/trackID=1"
            : "trackID=1"
    }

    /// The complete SDP body, CRLF-terminated on every line as RFC 4566 requires.
    ///
    /// - Parameter parameterSetNALs: the NAL units the fixture generated, in VPS/SPS/PPS order.
    ///   They are base64-encoded into `sprop-*`; when ``Quirk/parameterSetsOnlyInBand`` is set the
    ///   `sprop-*` attributes are omitted entirely and the client must learn the geometry in band.
    public func body(parameterSetNALs: [[UInt8]]) -> String {
        var lines: [String] = []
        lines.append("v=0")
        lines.append("o=- \(sessionVersion) 1 IN IP4 \(host)")
        lines.append(sessionName)
        lines.append("i=\(profile.firmware)")
        lines.append("c=IN IP4 0.0.0.0")
        lines.append("t=0 0")
        lines.append("a=tool:LIVE555 Streaming Media v2013.04.08")
        lines.append("a=type:broadcast")
        lines.append("a=control:*")
        lines.append("a=range:npt=0-")
        if profile.quirks.contains(.extraSDPAttributes) {
            lines.append("a=appversion:1.0")
            lines.append("a=Media_header:MEDIAINFO=494D4B48010200000400000100000000000000000000;")
            lines.append("a=x-dimensions:\(profile.width),\(profile.height)")
        }
        lines.append("m=video 0 RTP/AVP \(profile.payloadType)")
        lines.append("b=AS:\(profile.bitrateKbps)")
        lines.append("a=rtpmap:\(profile.payloadType) \(profile.encodingName)/90000")
        if let fmtp = fmtpLine(parameterSetNALs: parameterSetNALs) {
            lines.append(fmtp)
        }
        lines.append("a=control:\(trackControl)")
        lines.append("a=recvonly")
        return lines.map { $0 + "\r\n" }.joined()
    }

    // MARK: Pieces

    /// The `s=` line. ``Quirk/dollarInResponseBody`` puts a literal `$` in it, which is the byte a
    /// naive interleave scanner treats as the start of a media frame.
    private var sessionName: String {
        profile.quirks.contains(.dollarInResponseBody)
            ? "s=Media Presentation $Ch1$"
            : "s=Media Presentation"
    }

    /// The `a=fmtp` line, or `nil` when there is nothing to say.
    private func fmtpLine(parameterSetNALs: [[UInt8]]) -> String? {
        let suppressed = profile.quirks.contains(.parameterSetsOnlyInBand)
        let padded = !profile.quirks.contains(.unpaddedSpropBase64)
        switch profile.videoCodec {
        case .h264:
            var parameters = ["packetization-mode=1"]
            let sps = parameterSetNALs.first { ($0.first.map { $0 & 0x1F } ?? 0) == 7 }
            let pps = parameterSetNALs.first { ($0.first.map { $0 & 0x1F } ?? 0) == 8 }
            if let sps, sps.count >= 4 {
                parameters.append("profile-level-id=" + Hex.uppercase(sps[1...3]))
            }
            if !suppressed, let sps, let pps {
                let encoded = [sps, pps]
                    .map { Base64.encode($0, alphabet: .standard, padded: padded) }
                    .joined(separator: ",")
                parameters.append("sprop-parameter-sets=\(encoded)")
            }
            return "a=fmtp:\(profile.payloadType) " + parameters.joined(separator: ";")
        case .h265:
            guard !suppressed else { return nil }
            var parameters: [String] = []
            for nal in parameterSetNALs {
                guard let first = nal.first else { continue }
                let encoded = Base64.encode(nal, alphabet: .standard, padded: padded)
                switch (first >> 1) & 0x3F {
                case 32: parameters.append("sprop-vps=\(encoded)")
                case 33: parameters.append("sprop-sps=\(encoded)")
                case 34: parameters.append("sprop-pps=\(encoded)")
                default: continue
                }
            }
            guard !parameters.isEmpty else { return nil }
            return "a=fmtp:\(profile.payloadType) " + parameters.joined(separator: ";")
        case .mjpeg:
            return nil
        }
    }
}
