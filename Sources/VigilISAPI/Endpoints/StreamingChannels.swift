//
//  StreamingChannels.swift
//  VigilISAPI
//
//  `/ISAPI/Streaming/channels`: the streaming inventory, its wire units, and the read-modify-write
//  PUT that changes a substream without resetting everything the body omitted.
//  Implements docs/spec-isapi.md §12.1–§12.3.
//
//  Two rules dominate this file. First, the units are traps — `maxFrameRate` is fps × 100,
//  `keyFrameInterval` is milliseconds and `GovLength` is frames — so every crossing goes through
//  `ISAPIUnits` and nothing here does the arithmetic inline. Second, a configuration PUT must echo
//  the **whole** element back: Hikvision's validator rejects partial documents, and worse, some
//  firmwares accept one and silently reset every element it omitted to a factory default.
//

import Foundation
import VigilProtocols

// MARK: - Wire codecs

/// A `videoCodecType` value, mapped onto the one `VideoCodec` the app uses while keeping what the
/// device actually said.
///
/// `codec` is `nil` for MPEG-4 and SVAC: they are real wire values that Vigil cannot decode, and
/// collapsing them into `.h264` would produce a stream that opens and then shows nothing.
public struct VideoCodecWire: Sendable, Hashable, Codable {
    /// Exactly as the device wrote it: `H.265`, `H.264-BP`, `MJPEG`, …
    public let raw: String
    /// The decodable codec, or `nil` when Vigil has no decoder for it.
    public let codec: VideoCodec?
    /// `Baseline` / `Main` / `High` / `Main10`, from the profile element or the `-BP` suffix.
    public let profile: String?

    public init(raw: String, codec: VideoCodec?, profile: String?) {
        self.raw = raw
        self.codec = codec
        self.profile = profile
    }

    /// Parses prefix-first and case-insensitively, ignoring `.`, `-` and `_`, because the same
    /// codec is spelled `H.264`, `H264` and `h.264-mp` across firmware.
    ///
    /// The H.265 test must precede H.264: `h265` and `h264` share no prefix, but the profile
    /// suffixes (`-BP`, `-MP`, `-HP`) attach to both and are stripped by the same code.
    public init(raw: String, profileElement: String? = nil) {
        let normalized = ISAPIVocabulary.normalize(raw)
        var codec: VideoCodec?
        if normalized.hasPrefix("h265") || normalized.hasPrefix("hevc") { codec = .h265 }
        else if normalized.hasPrefix("h264") || normalized.hasPrefix("avc") { codec = .h264 }
        else if normalized.hasPrefix("mjpeg") || normalized.hasPrefix("jpeg") { codec = .mjpeg }
        var profile = profileElement
        if profile == nil {
            if normalized.hasSuffix("bp") { profile = "Baseline" }
            else if normalized.hasSuffix("mp") { profile = "Main" }
            else if normalized.hasSuffix("hp") { profile = "High" }
        }
        self.init(raw: raw, codec: codec, profile: profile)
    }

    /// True when Vigil can hand this stream to a hardware decoder.
    public var isDecodable: Bool { codec != nil }
}

/// An `audioCompressionType` value, mapped onto `AudioCodec` where one exists.
///
/// `G.722.1` and `MP2L2` are legal wire values with no `AudioCodec` case, so they decode to `nil`;
/// the raw string still reaches the UI, which is what tells a user why a stream has no audio.
public struct AudioCodecWire: Sendable, Hashable, Codable {
    public let raw: String
    public let codec: AudioCodec?

    public init(raw: String, codec: AudioCodec?) {
        self.raw = raw
        self.codec = codec
    }

    public init(raw: String) {
        switch ISAPIVocabulary.normalize(raw) {
        case "g711ulaw", "g711u", "pcmu", "g711mulaw": self.init(raw: raw, codec: .g711U)
        case "g711alaw", "g711a", "pcma": self.init(raw: raw, codec: .g711A)
        case "g726": self.init(raw: raw, codec: .g726)
        case "aac", "mpeg4aac": self.init(raw: raw, codec: .aac)
        case "pcm", "pcms16le": self.init(raw: raw, codec: .pcmS16LE)
        default: self.init(raw: raw, codec: nil)
        }
    }

    /// The wire spelling Hikvision expects when Vigil writes this codec back.
    public static func wireName(for codec: AudioCodec) -> String {
        switch codec {
        case .g711U: "G.711ulaw"
        case .g711A: "G.711alaw"
        case .g726: "G.726"
        case .aac: "AAC"
        case .pcmS16LE: "PCM"
        }
    }
}

// MARK: - Supporting value types

/// How the encoder is told to spend bits.
public enum BitrateControl: Sendable, Hashable, Codable {
    /// Constant bitrate, in kbit/s.
    case cbr(kbps: Int)
    /// Variable bitrate: ceiling and floor in kbit/s, plus the 0…100 quality index some firmware
    /// uses instead of the caps.
    case vbr(upper: Int, lower: Int, quality: Int)

    /// The ceiling, whichever mode is in use — the number that actually predicts link load.
    public var peakKbps: Int {
        switch self {
        case .cbr(let kbps): kbps
        case .vbr(let upper, _, _): upper
        }
    }
}

/// `videoScanType`.
public enum ScanType: String, Sendable, Hashable, Codable {
    case progressive, interlaced, unknown

    public init(raw: String?) {
        switch ISAPIVocabulary.normalize(raw ?? "") {
        case "progressive": self = .progressive
        case "interlace", "interlaced": self = .interlaced
        default: self = .unknown
        }
    }
}

/// `rtpTransportType` on the unicast element — what the device would prefer.
public enum RTPTransportWire: String, Sendable, Hashable, Codable {
    case tcp, udp, unknown

    public init(raw: String?) {
        switch ISAPIVocabulary.normalize(raw ?? "") {
        case "rtptcp", "tcp": self = .tcp
        case "rtpudp", "udp": self = .udp
        default: self = .unknown
        }
    }
}

/// The multicast block, kept because a device configured to multicast and a device not configured
/// to multicast fail in completely different ways.
public struct MulticastConfig: Sendable, Hashable, Codable {
    public let enabled: Bool
    public let destinationIP: String?
    public let videoPort: Int?
    public let audioPort: Int?

    public init(enabled: Bool, destinationIP: String?, videoPort: Int?, audioPort: Int?) {
        self.enabled = enabled
        self.destinationIP = destinationIP
        self.videoPort = videoPort
        self.audioPort = audioPort
    }
}

// MARK: - StreamingChannelConfig

/// One `<StreamingChannel>` element: everything the app knows about a single encoder output.
public struct StreamingChannelConfig: Sendable, Hashable, Codable {
    public let id: StreamingChannelID
    public var channelName: String?
    public var enabled: Bool
    public var codec: VideoCodecWire
    public var width: Int
    public var height: Int
    /// Frames per second, already divided out of the fps × 100 wire encoding. `nil` when the
    /// device reported a non-positive rate, which means "unknown", not "zero".
    public var frameRate: Double?
    public var bitrateControl: BitrateControl
    /// Milliseconds, not frames.
    public var keyFrameIntervalMS: Int
    /// GOP length in **frames**. Authoritative for the decoder's keyframe expectation when both
    /// this and `keyFrameIntervalMS` are present.
    public var govLength: Int?
    public var smartCodecEnabled: Bool
    public var svcEnabled: Bool
    public var scanType: ScanType
    public var audioEnabled: Bool
    public var audioCodec: AudioCodecWire?
    public var rtspPort: Int
    /// RTP payload cap in bytes. Above 1400 with UDP transport this is an MTU hazard.
    public var maxPacketSize: Int
    public var preferredRTPTransport: RTPTransportWire
    public var multicast: MulticastConfig?
    /// The element exactly as the device sent it, retained for read-modify-write PUTs. Not part
    /// of equality or of the persisted form: it is a transport detail, not device state.
    public var originalNode: XMLNode? = nil

    public init(id: StreamingChannelID, channelName: String?, enabled: Bool,
                codec: VideoCodecWire, width: Int, height: Int, frameRate: Double?,
                bitrateControl: BitrateControl, keyFrameIntervalMS: Int, govLength: Int?,
                smartCodecEnabled: Bool, svcEnabled: Bool, scanType: ScanType,
                audioEnabled: Bool, audioCodec: AudioCodecWire?, rtspPort: Int,
                maxPacketSize: Int, preferredRTPTransport: RTPTransportWire,
                multicast: MulticastConfig?, originalNode: XMLNode?) {
        self.id = id
        self.channelName = channelName
        self.enabled = enabled
        self.codec = codec
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitrateControl = bitrateControl
        self.keyFrameIntervalMS = keyFrameIntervalMS
        self.govLength = govLength
        self.smartCodecEnabled = smartCodecEnabled
        self.svcEnabled = svcEnabled
        self.scanType = scanType
        self.audioEnabled = audioEnabled
        self.audioCodec = audioCodec
        self.rtspPort = rtspPort
        self.maxPacketSize = maxPacketSize
        self.preferredRTPTransport = preferredRTPTransport
        self.multicast = multicast
        self.originalNode = originalNode
    }

    /// Decodes one `<StreamingChannel>` element.
    ///
    /// The `id` is required and must be a well-formed `channel * 100 + stream`: a device that
    /// reports a bare `1` is exercising the single-digit firmware quirk, and inventing a
    /// `StreamingChannelID` from it would address channel 0. Such an element is rejected here so
    /// the caller can apply the quirk explicitly.
    public init(node: XMLNode) throws(ISAPIError) {
        let rawID = try node["id"].requireInt("StreamingChannel")
        guard let id = StreamingChannelID(rawValue: rawID) else {
            throw ISAPIError.malformedResponse(
                "StreamingChannel: <id>\(rawID)</id> is not channel * 100 + stream in 1...3")
        }
        let video = node.node("Video")
        let audio = node.node("Audio")
        let transport = node.node("Transport")
        let profile = video?["H265Profile|H264Profile|profile"].string
        let quality = video?["videoQualityControlType"].string ?? "VBR"
        let control: BitrateControl
        if ISAPIVocabulary.normalize(quality) == "cbr" {
            control = .cbr(kbps: video?["constantBitRate"].int ?? 0)
        } else {
            control = .vbr(upper: video?["vbrUpperCap"].int ?? 0,
                           lower: video?["vbrLowerCap"].int ?? 0,
                           quality: video?["fixedQuality"].int ?? 0)
        }
        let multicastNode = transport?.node("Multicast")
        let multicast = multicastNode.map {
            MulticastConfig(enabled: $0["enabled"].bool ?? false,
                            destinationIP: $0["destIPAddress"].string,
                            videoPort: $0["videoDestPortNo"].int,
                            audioPort: $0["audioDestPortNo"].int)
        }
        let audioRaw = audio?["audioCompressionType"].string
        self.init(id: id,
                  channelName: node["channelName"].string,
                  enabled: node["enabled"].bool ?? true,
                  codec: VideoCodecWire(raw: video?["videoCodecType"].string ?? "",
                                        profileElement: profile),
                  width: video?["videoResolutionWidth"].int ?? 0,
                  height: video?["videoResolutionHeight"].int ?? 0,
                  frameRate: ISAPIUnits.frameRate(fromWire: video?["maxFrameRate"].int ?? 0),
                  bitrateControl: control,
                  keyFrameIntervalMS: video?["keyFrameInterval"].int ?? 0,
                  govLength: video?["GovLength"].int,
                  smartCodecEnabled: video?["SmartCodec/enabled"].bool ?? false,
                  svcEnabled: video?["SVC/enabled"].bool ?? false,
                  scanType: ScanType(raw: video?["videoScanType"].string),
                  audioEnabled: audio?["enabled"].bool ?? false,
                  audioCodec: audioRaw.map { AudioCodecWire(raw: $0) },
                  rtspPort: transport?["rtspPortNo"].int ?? 554,
                  maxPacketSize: transport?["maxPacketSize"].int ?? 0,
                  preferredRTPTransport:
                    RTPTransportWire(raw: transport?["Unicast/rtpTransportType"].string),
                  multicast: multicast,
                  originalNode: node)
    }

    /// Decodes every `<StreamingChannel>` in a `<StreamingChannelList>`.
    ///
    /// Elements that fail to decode are **skipped, not fatal**: a 32-channel NVR with one
    /// malformed entry must still show the other 31. The skipped ids are returned so the caller
    /// can log them once instead of silently losing channels.
    public static func list(document: ISAPIDocument)
        -> (channels: [StreamingChannelConfig], skipped: [Int]) {
        var channels: [StreamingChannelConfig] = []
        var skipped: [Int] = []
        for node in document.nodes("StreamingChannel[]") {
            do {
                channels.append(try StreamingChannelConfig(node: node))
            } catch {
                skipped.append(node["id"].int ?? -1)
            }
        }
        return (channels, skipped)
    }

    /// `true` when the RTP payload cap would fragment at a standard 1500-byte MTU while the device
    /// prefers UDP — the configuration that produces "works on TCP, tears on UDP".
    public var hasMTUHazard: Bool {
        maxPacketSize > 1400 && preferredRTPTransport == .udp
    }

    /// Equality and hashing ignore `originalNode`, which is a verbatim copy of the same data.
    public static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.channelName == b.channelName && a.enabled == b.enabled
            && a.codec == b.codec && a.width == b.width && a.height == b.height
            && a.frameRate == b.frameRate && a.bitrateControl == b.bitrateControl
            && a.keyFrameIntervalMS == b.keyFrameIntervalMS && a.govLength == b.govLength
            && a.smartCodecEnabled == b.smartCodecEnabled && a.svcEnabled == b.svcEnabled
            && a.scanType == b.scanType && a.audioEnabled == b.audioEnabled
            && a.audioCodec == b.audioCodec && a.rtspPort == b.rtspPort
            && a.maxPacketSize == b.maxPacketSize
            && a.preferredRTPTransport == b.preferredRTPTransport && a.multicast == b.multicast
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(width)
        hasher.combine(height)
        hasher.combine(keyFrameIntervalMS)
        hasher.combine(codec)
    }

    enum CodingKeys: String, CodingKey {
        case id, channelName, enabled, codec, width, height, frameRate, bitrateControl
        case keyFrameIntervalMS, govLength, smartCodecEnabled, svcEnabled, scanType
        case audioEnabled, audioCodec, rtspPort, maxPacketSize, preferredRTPTransport, multicast
    }
}

// MARK: - StreamingChannelPatch

/// The subset of a stream's configuration Vigil is willing to change.
///
/// Every field is optional and `nil` means "leave alone"; the patch is applied onto the device's
/// own element, never onto a hand-built one.
public struct StreamingChannelPatch: Sendable, Hashable {
    public var codec: VideoCodec?
    public var width: Int?
    public var height: Int?
    public var frameRate: Double?
    public var bitrateControl: BitrateControl?
    public var keyFrameIntervalMS: Int?
    public var govLength: Int?
    public var smartCodecEnabled: Bool?
    public var audioEnabled: Bool?

    public init(codec: VideoCodec? = nil, width: Int? = nil, height: Int? = nil,
                frameRate: Double? = nil, bitrateControl: BitrateControl? = nil,
                keyFrameIntervalMS: Int? = nil, govLength: Int? = nil,
                smartCodecEnabled: Bool? = nil, audioEnabled: Bool? = nil) {
        self.codec = codec
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitrateControl = bitrateControl
        self.keyFrameIntervalMS = keyFrameIntervalMS
        self.govLength = govLength
        self.smartCodecEnabled = smartCodecEnabled
        self.audioEnabled = audioEnabled
    }

    /// True when the patch would change nothing, so the caller can skip the round trip entirely.
    public var isEmpty: Bool {
        codec == nil && width == nil && height == nil && frameRate == nil && bitrateControl == nil
            && keyFrameIntervalMS == nil && govLength == nil && smartCodecEnabled == nil
            && audioEnabled == nil
    }

    /// The substream configuration Vigil offers as its one-click "Optimize for grid" action.
    ///
    /// SmartCodec is switched **off** deliberately: its long-GOP behaviour delays the first
    /// keyframe by 4–8 s, which is the whole tile-open budget.
    public static let gridOptimizedSubstream = StreamingChannelPatch(
        codec: .h264, width: 640, height: 360, frameRate: 12,
        bitrateControl: .vbr(upper: 512, lower: 32, quality: 60),
        keyFrameIntervalMS: 2000, smartCodecEnabled: false)

    /// Client-side pre-validation, so an obviously bad value costs no round trip and produces a
    /// sentence instead of `badParameters` (docs/spec-isapi.md §12.3).
    ///
    /// Returns the reasons the patch is unacceptable; an empty array means "send it".
    public func validationFailures() -> [String] {
        var failures: [String] = []
        if let frameRate {
            let wire = ISAPIUnits.wireFrameRate(fromFPS: frameRate)
            if wire < 50 || wire > 6000 {
                failures.append("frame rate \(frameRate) fps is outside 0.5…60 fps")
            } else if wire % 25 != 0 {
                failures.append("frame rate \(frameRate) fps is not a multiple of 0.25 fps")
            }
        }
        if let keyFrameIntervalMS, !(20...10000).contains(keyFrameIntervalMS) {
            failures.append("key-frame interval \(keyFrameIntervalMS) ms is outside 20…10000 ms")
        }
        if let govLength, !(1...400).contains(govLength) {
            failures.append("GOP length \(govLength) is outside 1…400 frames")
        }
        if case .vbr(let upper, let lower, _) = bitrateControl {
            if !(32...16384).contains(upper) {
                failures.append("VBR ceiling \(upper) kbit/s is outside 32…16384")
            }
            if lower > upper {
                failures.append("VBR floor \(lower) exceeds the ceiling \(upper)")
            }
        }
        if case .cbr(let kbps) = bitrateControl, !(32...16384).contains(kbps) {
            failures.append("CBR rate \(kbps) kbit/s is outside 32…16384")
        }
        if (width == nil) != (height == nil) {
            failures.append("width and height must be set together")
        }
        return failures
    }

    /// Applies the patch onto the device's own `<StreamingChannel>` element.
    ///
    /// Every element Vigil does not model — and every element a future firmware adds — round-trips
    /// untouched, which is the entire point of read-modify-write. Elements are only created when
    /// the patch needs them: `createIfMissing` is off for the fields that the device is entitled
    /// not to have (`GovLength`, `SmartCodec`), because inventing them has been observed to draw
    /// `invalidXMLContent`.
    public func applied(to node: XMLNode) -> XMLNode {
        var result = node
        if let codec {
            let name: String = switch codec {
            case .h264: "H.264"
            case .h265: "H.265"
            case .mjpeg: "MJPEG"
            }
            result = result.setting("Video/videoCodecType", to: name)
        }
        if let width { result = result.setting("Video/videoResolutionWidth", to: String(width)) }
        if let height { result = result.setting("Video/videoResolutionHeight", to: String(height)) }
        if let frameRate {
            result = result.setting("Video/maxFrameRate",
                                    to: String(ISAPIUnits.wireFrameRate(fromFPS: frameRate)))
        }
        if let keyFrameIntervalMS {
            result = result.setting("Video/keyFrameInterval", to: String(keyFrameIntervalMS))
        }
        if let govLength { result = result.setting("Video/GovLength", to: String(govLength)) }
        switch bitrateControl {
        case .cbr(let kbps):
            result = result.setting("Video/videoQualityControlType", to: "CBR")
            result = result.setting("Video/constantBitRate", to: String(kbps))
        case .vbr(let upper, let lower, let quality):
            result = result.setting("Video/videoQualityControlType", to: "VBR")
            result = result.setting("Video/vbrUpperCap", to: String(upper))
            result = result.setting("Video/vbrLowerCap", to: String(lower))
            result = result.setting("Video/fixedQuality", to: String(quality))
        case nil:
            break
        }
        if let smartCodecEnabled {
            result = result.setting("Video/SmartCodec/enabled",
                                    to: smartCodecEnabled ? "true" : "false")
        }
        if let audioEnabled {
            result = result.setting("Audio/enabled", to: audioEnabled ? "true" : "false")
        }
        return result
    }
}
