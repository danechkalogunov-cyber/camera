//
//  StreamQuality.swift
//  VigilProtocols
//
//  Which encoder a stream comes from, what a decode pipeline is keyed by, how the
//  stream is transported, and how deep the jitter buffer runs.
//
//  Implements docs/API_CONTRACT.md §3.7 (rulings R-13, R-55, R-63).
//

// MARK: - Quality

/// Which of a device's encoders a stream comes from.
///
/// There is **no `.auto` case**: "automatic" is the absence of an override, spelled
/// `StreamQuality?` (API_CONTRACT §2 R-55). `StreamProfile.Kind` and `StreamIndex` do not exist.
///
/// The raw value is the Hikvision stream digit, so `StreamingChannelID` is
/// `channel * 100 + quality.rawValue`. Ordering is `main < sub < third`, i.e. ascending raw value,
/// which is *descending* picture quality — compare explicitly rather than relying on intuition.
public enum StreamQuality: Int, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case main = 1
    case sub = 2
    case third = 3

    /// The lowercase wire and log spelling. This is also the `Codable` representation.
    public var stringValue: String {
        switch self {
        case .main: "main"
        case .sub: "sub"
        case .third: "third"
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Decodes the lowercase string form, not the integer form.
    ///
    /// Matching is case-insensitive, so `"Main"` from a hand-edited `library.json` still decodes.
    /// Any other value throws `DecodingError.dataCorrupted` rather than defaulting: silently
    /// substituting `.main` for a typo would pull a 4K stream into a thumbnail.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw.lowercased() {
        case "main": self = .main
        case "sub": self = .sub
        case "third": self = .third
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown StreamQuality \"\(raw)\"; expected main, sub or third")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
}

// MARK: - Stream key

/// What a decode pipeline, an audio route and a budget grant are keyed by.
///
/// A camera alone is not enough: during the 150 ms keyframe-gated crossfade of a quality switch,
/// main and sub are both live (API_CONTRACT §2 R-63). `StreamIdentifier` does not exist.
public struct StreamKey: Sendable, Hashable, Codable, CustomStringConvertible {
    public var camera: CameraID
    public var quality: StreamQuality

    public init(camera: CameraID, quality: StreamQuality) {
        self.camera = camera
        self.quality = quality
    }

    /// `3f9c1a20/sub` — the short camera id and the quality, the form used in log lines and in
    /// queue names. Never the full UUID, which makes a log line unreadable.
    public var description: String { "\(camera.short)/\(quality.stringValue)" }
}

// MARK: - Transport

/// How the RTP data for a stream reaches us.
public enum RTSPTransportKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// Controller policy: reuse the last proven transport, starting with TCP for a new camera.
    case auto
    /// `Transport: RTP/AVP/TCP;unicast;interleaved=0-1`. **The default** — it traverses every LAN
    /// and needs no inbound ports.
    case tcpInterleaved
    /// `RTP/AVP;unicast;client_port=n-n+1`. Lower latency, but blocked by many networks.
    case udpUnicast
    /// `RTP/AVP;multicast`. One sender, many viewers; unavailable on most Wi-Fi.
    case udpMulticast
    /// `rtsps`, port 322, trust-on-first-use leaf pinning shared with ISAPI.
    case tcpTLS

    @inlinable public var isUDP: Bool { self == .udpUnicast || self == .udpMulticast }

    /// 322 for `rtsps`, 554 otherwise. A device on a non-default port overrides this.
    @inlinable public var defaultPort: Int { self == .tcpTLS ? 322 : 554 }
}

// MARK: - Latency

/// Jitter-buffer depth / decode-queue trade-off, chosen per camera.
///
/// The three presets trade glass-to-glass latency against tolerance of a lossy link. `balanced` is
/// the default because it survives a congested Wi-Fi hop without visible stutter.
public enum LatencyPreset: String, Sendable, Hashable, Codable, CaseIterable {
    /// 40 ms / 8 packets, decode queue 2, aggressive drop-to-keyframe.
    case low
    /// 120 ms / 24 packets, decode queue 3. **The default.**
    case balanced
    /// 350 ms / 64 packets, decode queue 5, never drop unless the queue is full.
    case quality

    /// Target depth of the reorder buffer in media time.
    @inlinable public var jitterBufferDepth: Duration {
        switch self {
        case .low: .milliseconds(40)
        case .balanced: .milliseconds(120)
        case .quality: .milliseconds(350)
        }
    }

    /// Hard packet ceiling on the reorder buffer, enforced alongside `jitterBufferDepth` so a
    /// stream whose timestamps are nonsense cannot grow the buffer without bound.
    @inlinable public var jitterBufferPackets: Int {
        switch self {
        case .low: 8
        case .balanced: 24
        case .quality: 64
        }
    }

    /// How many access units may wait for the decoder before frames are dropped.
    @inlinable public var decodeQueueDepth: Int {
        switch self {
        case .low: 2
        case .balanced: 3
        case .quality: 5
        }
    }
}
