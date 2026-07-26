//
//  RTPTrackFormat.swift
//  VigilRTP
//
//  `VigilRTP`'s own description of one media track, plus payload-type binding and the depacketizer
//  factory.
//  Implements docs/spec-rtp.md §4.1 / §4.2 and docs/API_CONTRACT.md §4.4 / §5.5
//  (`Track/RTPTrackFormat.swift`).
//

import Foundation
import VigilProtocols

/// One RTP track's negotiated format.
///
/// This is `VigilRTP`'s **own** input struct, not an SDP type. The six-line adapter from
/// `VigilRTSP.SDPMediaDescription` lives in `VigilTransport` on macOS and in the fixture on Linux,
/// never here, because `VigilRTP` must stay usable for UDP, file replay and unit fixtures with no
/// RTSP session at all.
public struct RTPTrackFormat: Sendable, Hashable {

    // MARK: - Stored Properties

    /// The payload type this track's packets carry. Exactly one payload type per receiver.
    public var payloadType: UInt8

    /// The `a=rtpmap` encoding name as received. Compared case-insensitively throughout.
    public var encodingName: String

    /// Ticks per second of the media clock: 90 000 for video, the sample rate for audio.
    public var clockRate: Int32

    /// Channel count, when the SDP gave one.
    public var channels: Int32?

    /// The `a=fmtp` parameters, with keys **already lower-cased by the caller**.
    public var fmtp: [String: String]

    /// Parameter sets from `sprop-parameter-sets` / `sprop-vps|sps|pps`, already Base64-decoded.
    public var parameterSets: ParameterSets?

    /// The codec this track carries, resolved and validated at initialisation.
    public let codec: MediaCodec

    // MARK: - Initialisation

    /// Creates a track format, resolving and validating the codec.
    ///
    /// - Throws: `RTPError.invalidClockRate` when `clockRate` is zero or negative — every timestamp
    ///   derived from it would be wrong, so this must fail loudly rather than produce silent
    ///   nonsense. `RTPError.unsupportedEncoding` when `encodingName` names a payload format Vigil
    ///   does not depacketize (MJPEG over RTP, MP4V-ES, Opus, G.729 and the rest).
    public init(payloadType: UInt8,
                encodingName: String,
                clockRate: Int32,
                channels: Int32?,
                fmtp: [String: String],
                parameterSets: ParameterSets?) throws(RTPError) {
        guard clockRate > 0 else { throw .invalidClockRate(clockRate) }
        guard let resolved = Self.resolveCodec(encodingName) else {
            throw .unsupportedEncoding(encodingName)
        }
        self.payloadType = payloadType
        self.encodingName = encodingName
        self.clockRate = clockRate
        self.channels = channels
        self.fmtp = fmtp
        self.parameterSets = parameterSets
        self.codec = resolved
    }

    // MARK: - Computed Properties

    /// True for H.264 and H.265.
    public var isVideo: Bool { codec.isVideo }

    /// The RTP clock rate a video track must use. Every RFC that defines an H.264 or H.265 payload
    /// format fixes it at 90 kHz; a video track advertising anything else is a camera bug that the
    /// receiver reports rather than silently honours.
    public static let videoClockRate: Int32 = 90_000

    /// True when this is a video track whose advertised clock rate is not 90 kHz.
    public var hasUnexpectedVideoClockRate: Bool {
        isVideo && clockRate != Self.videoClockRate
    }

    /// A named `a=fmtp` value, looked up case-insensitively on the key.
    public func fmtpValue(_ key: String) -> String? {
        if let direct = fmtp[key] { return direct }
        let lowered = key.lowercased()
        return fmtp.first { $0.key.lowercased() == lowered }?.value
    }

    // MARK: - Payload-type binding

    /// The RFC 3551 static payload-type binding, for an SDP that omits `a=rtpmap`.
    ///
    /// Hikvision NVRs do sometimes omit it for G.711. Payload type 26 (JPEG) resolves to `nil`
    /// deliberately: still images come from the ISAPI JPEG endpoint, not from RTP.
    public static func staticBinding(for payloadType: UInt8) -> RTPTrackFormat? {
        switch payloadType {
        case 0:
            return try? RTPTrackFormat(payloadType: 0, encodingName: "PCMU", clockRate: 8000,
                                       channels: 1, fmtp: [:], parameterSets: nil)
        case 8:
            return try? RTPTrackFormat(payloadType: 8, encodingName: "PCMA", clockRate: 8000,
                                       channels: 1, fmtp: [:], parameterSets: nil)
        default:
            return nil
        }
    }

    /// Maps an `a=rtpmap` encoding name onto a codec.
    ///
    /// Case-insensitive: SDP encoding names are case-insensitive by RFC 4566, and Hikvision firmware
    /// writes both `mpeg4-generic` and `MPEG4-GENERIC` depending on the build.
    public static func resolveCodec(_ encodingName: String) -> MediaCodec? {
        switch encodingName.lowercased() {
        case "h264": .video(.h264)
        case "h265", "hevc": .video(.h265)
        case "mpeg4-generic": .audio(.aac)
        case "pcma": .audio(.g711A)
        case "pcmu": .audio(.g711U)
        case "g726", "g726-32", "aal2-g726-32": .audio(.g726)
        default: nil
        }
    }
}

// MARK: - DepacketizerFactory

/// Builds the depacketizer a track needs.
///
/// Video only for now: the first-light slice does not request audio at all
/// (`.vigil/SLICE.md`), and the AAC and G.711/G.726 depacketizers land with the audio wave. An audio
/// format reaching this factory therefore throws `.unsupportedEncoding` rather than returning a
/// depacketizer that would emit nothing.
public enum DepacketizerFactory {

    /// Creates the depacketizer for `format`.
    ///
    /// - Throws: `RTPError.unsupportedEncoding` for a codec this build cannot depacketize.
    public static func make(
        for format: RTPTrackFormat,
        configuration: DepacketizerConfiguration = .liveDefault
    ) throws(RTPError) -> AnyDepacketizer {
        switch format.codec {
        case .video(.h264):
            return .h264(H264Depacketizer(clockRate: format.clockRate,
                                          configuration: configuration,
                                          initialParameterSets: format.parameterSets))
        case .video(.h265):
            // `sprop-max-don-diff > 0` means the sender may interleave, which switches on the DONL
            // field in every FU and AP. Hikvision never sets it, but an NVR proxying a third-party
            // camera can.
            let donDiff = Int(format.fmtpValue("sprop-max-don-diff") ?? "0") ?? 0
            return .h265(H265Depacketizer(clockRate: format.clockRate,
                                          configuration: configuration,
                                          initialParameterSets: format.parameterSets,
                                          usesDONL: donDiff > 0))
        default:
            throw .unsupportedEncoding(format.encodingName)
        }
    }
}
