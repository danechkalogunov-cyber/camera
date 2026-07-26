//
//  SyntheticCameraProfile.swift
//  VigilTestKit
//
//  Everything about the camera we are pretending to be: model, firmware, codec, geometry, auth mode,
//  RTSP path shape and the set of quirks in force. Four named presets match real devices.
//  Implements docs/ARCHITECTURE.md §10.2 and docs/API_CONTRACT.md §4.13.
//

import VigilProtocols

// MARK: - Auth mode

/// How the synthetic camera challenges a client.
public enum SyntheticAuthMode: String, Sendable, Hashable, CaseIterable {

    /// No challenge at all. Rare on real firmware; used to isolate media failures from auth ones.
    case none

    /// `WWW-Authenticate: Basic realm="…"`.
    case basic

    /// RFC 2069 Digest with no `qop` parameter — the primary Hikvision path.
    case digestNoQop

    /// RFC 2617 Digest with `qop="auth"`, `nc` and `cnonce`.
    case digestQopAuth

    /// `true` when the mode requires the client to send an `Authorization` header at all.
    public var requiresCredential: Bool { self != .none }
}

// MARK: - Profile

/// A synthetic Hikvision device.
///
/// Every field that can vary between real firmware revisions is here, because the point of the
/// fixture is to make those differences testable. `seed` drives **all** randomness — packet loss,
/// duplication, reordering, marker-bit noise, nonce generation and slice filler — so a run is
/// byte-identical for a given seed and a failing test is replayable from the seed it prints.
public struct SyntheticCameraProfile: Sendable, Hashable {

    /// The device class, which decides the default RTSP path shape.
    public enum Model: Sendable, Hashable {

        /// A single-channel IP camera, e.g. `DS-2CD2143G2-I`.
        case ipCamera(model: String)

        /// An NVR with `channels` channels, addressed as `/Streaming/Channels/<ch><stream>`.
        case nvr(channels: Int)

        /// A legacy analogue encoder: interlaced 4CIF, `/h264/ch1/main/av_stream` paths.
        case analogEncoder
    }

    // MARK: Identity

    /// Device class. Decides the default RTSP path shape and the label in failure messages.
    public var model: Model

    /// Advertised firmware string. Affects the SDP `s=` line and the `Server` header only.
    public var firmware: String

    /// The realm the camera puts in its `WWW-Authenticate` challenge.
    public var realm: String

    // MARK: Media

    /// Video codec the camera encodes in, which selects the whole packetization path.
    public var videoCodec: VideoCodec

    /// Coded picture width in luma samples, before any cropping/conformance window.
    public var width: Int

    /// Displayed picture height. 1080 is coded as 1088 in H.264 and cropped, which the fixture does.
    public var height: Int

    /// Frames per second. Drives the SPS/VPS timing info and the virtual-clock frame cadence.
    public var frameRate: Double

    /// Access units between IRAPs, inclusive of the IRAP itself. Must be at least 1.
    public var gopLength: Int

    /// Target video bitrate, which sizes the synthetic slice payloads.
    public var bitrateKbps: Int

    /// Packetization MTU. Any NAL larger than this minus RTP/FU overhead is fragmented.
    public var mtu: Int

    // MARK: RTSP

    /// Path of the requested stream, without host or scheme.
    public var streamPath: String

    /// How the camera challenges: none, Basic, RFC 2069 Digest or RFC 2617 `qop=auth` Digest.
    public var authMode: SyntheticAuthMode
    /// The account the camera will accept. Anything else is answered with `401`.
    public var username: String

    /// The secret the camera will accept. Present in the fixture only; never a real credential.
    public var password: String

    /// `timeout=` advertised in the `Session` header of the SETUP response.
    public var sessionTimeoutSeconds: Int

    /// When `false` the camera answers `GET_PARAMETER` with `501`, and a client must keep the
    /// session alive with `OPTIONS` instead.
    public var supportsGetParameter: Bool

    // MARK: Faults and determinism

    /// Faults in force. Each is individually switchable and each has its own pipeline test.
    public var quirks: Set<Quirk>

    /// Drives every pseudorandom decision in the fixture. **Print this on failure.**
    public var seed: UInt64

    // MARK: Init

    /// Creates a profile. Every argument has a default matching a current-firmware H.265 camera, so
    /// a test that cares about one axis names only that axis.
    public init(
        model: Model = .ipCamera(model: "DS-2CD2143G2-I"),
        firmware: String = "V5.7.3 build 210506",
        realm: String = "IP Camera(C1234)",
        videoCodec: VideoCodec = .h265,
        width: Int = 1920,
        height: Int = 1080,
        frameRate: Double = 25,
        gopLength: Int = 25,
        bitrateKbps: Int = 2048,
        mtu: Int = 1400,
        streamPath: String = "/Streaming/Channels/101",
        authMode: SyntheticAuthMode = .digestNoQop,
        username: String = "admin",
        password: String = "Vigil12345",
        sessionTimeoutSeconds: Int = 60,
        supportsGetParameter: Bool = true,
        quirks: Set<Quirk> = [],
        seed: UInt64 = 0x5649_4749_4C00
    ) {
        self.model = model
        self.firmware = firmware
        self.realm = realm
        self.videoCodec = videoCodec
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.gopLength = Swift.max(gopLength, 1)
        self.bitrateKbps = Swift.max(bitrateKbps, 32)
        self.mtu = Swift.max(mtu, 128)
        self.streamPath = streamPath
        self.authMode = authMode
        self.username = username
        self.password = password
        self.sessionTimeoutSeconds = Swift.min(Swift.max(sessionTimeoutSeconds, 10), 600)
        self.supportsGetParameter = supportsGetParameter
        self.quirks = quirks
        self.seed = seed
    }

    // MARK: Derived

    /// Nominal seconds between access units. Never zero: a frame rate at or below zero is treated
    /// as 25 fps so a malformed profile cannot make the harness loop forever.
    public var framePeriodSeconds: Double {
        frameRate > 0 ? 1.0 / frameRate : 1.0 / 25.0
    }

    /// RTP timestamp increment per access unit at the 90 kHz video clock, at least 1.
    public var ticksPerFrame: UInt32 {
        let ticks = 90_000.0 * framePeriodSeconds
        return UInt32(Swift.max(1.0, ticks.rounded()))
    }

    /// Average coded bytes per access unit implied by `bitrateKbps` and `frameRate`.
    public var averageFrameBytes: Int {
        let perSecond = Double(bitrateKbps) * 1000.0 / 8.0
        return Swift.max(96, Int(perSecond * framePeriodSeconds))
    }

    /// The RTP payload type the camera advertises. 96 everywhere Hikvision is concerned.
    public var payloadType: UInt8 { 96 }

    /// The SDP `a=rtpmap` encoding name for `videoCodec`.
    public var encodingName: String {
        switch videoCodec {
        case .h264: "H264"
        case .h265: "H265"
        case .mjpeg: "JPEG"
        }
    }

    /// A copy with `quirk` added.
    public func adding(_ quirk: Quirk) -> Self {
        var copy = self
        copy.quirks.insert(quirk)
        return copy
    }

    /// A copy with every quirk in `added` present.
    public func adding(_ added: some Sequence<Quirk>) -> Self {
        var copy = self
        for quirk in added { copy.quirks.insert(quirk) }
        return copy
    }

    /// A copy with a different seed, for re-running the same scenario on fresh randomness.
    public func reseeded(_ seed: UInt64) -> Self {
        var copy = self
        copy.seed = seed
        return copy
    }
}

// MARK: - Presets

public extension SyntheticCameraProfile {

    /// Current-firmware H.265 camera: 1920×1080 at 25 fps, digest with `qop="auth"`,
    /// `/Streaming/Channels/101`. This is what a `DS-2CD2xxx` shipping today looks like.
    static func hevcCamera(seed: UInt64 = 0x5649_4749_4C00) -> Self {
        Self(
            model: .ipCamera(model: "DS-2CD2386G2-IU"),
            firmware: "V5.7.13 build 220802",
            videoCodec: .h265,
            width: 1920,
            height: 1080,
            frameRate: 25,
            gopLength: 25,
            bitrateKbps: 2048,
            streamPath: "/Streaming/Channels/101",
            authMode: .digestQopAuth,
            seed: seed
        )
    }

    /// Older H.264 camera: 1280×720 at 20 fps, RFC 2069 digest with no `qop`, coded height 720 so
    /// no cropping is involved — the counterpart to `hevcCamera`'s 1080-in-1088 crop.
    static func ds2cd2143g2(seed: UInt64 = 0x5649_4749_4C00) -> Self {
        Self(
            model: .ipCamera(model: "DS-2CD2143G2-I"),
            firmware: "V5.5.82 build 190909",
            videoCodec: .h264,
            width: 1280,
            height: 720,
            frameRate: 20,
            gopLength: 40,
            bitrateKbps: 1536,
            streamPath: "/Streaming/Channels/101",
            authMode: .digestNoQop,
            seed: seed
        )
    }

    /// NVR channel 3, substream: `/Streaming/Channels/302`, 704×576 H.264 at 12.5 fps.
    /// Coded height 576 is a multiple of 16, coded width 704 likewise — the analogue geometry.
    static func ds7608nvr(channels: Int = 8, channel: Int = 3, seed: UInt64 = 0x5649_4749_4C00) -> Self {
        let clamped = Swift.min(Swift.max(channel, 1), Swift.max(channels, 1))
        return Self(
            model: .nvr(channels: Swift.max(channels, 1)),
            firmware: "V4.30.085 build 200509",
            realm: "DS-7608NI-K2",
            videoCodec: .h264,
            width: 704,
            height: 576,
            frameRate: 12.5,
            gopLength: 25,
            bitrateKbps: 768,
            streamPath: "/Streaming/Channels/\(clamped)02",
            authMode: .digestQopAuth,
            seed: seed
        )
    }

    /// Legacy RTSP path form still served by older encoders and by cameras in "compatible" mode:
    /// `/h264/ch1/main/av_stream`, Basic auth, 704×576 interlaced-era geometry.
    static func legacyPathCamera(seed: UInt64 = 0x5649_4749_4C00) -> Self {
        Self(
            model: .analogEncoder,
            firmware: "V5.2.5 build 141201",
            realm: "Hikvision",
            videoCodec: .h264,
            width: 704,
            height: 576,
            frameRate: 25,
            gopLength: 50,
            bitrateKbps: 1024,
            streamPath: "/h264/ch1/main/av_stream",
            authMode: .basic,
            seed: seed
        )
    }

    /// Every preset, for tests that must cover the whole inventory.
    static func allPresets(seed: UInt64 = 0x5649_4749_4C00) -> [Self] {
        [hevcCamera(seed: seed), ds2cd2143g2(seed: seed), ds7608nvr(seed: seed),
         legacyPathCamera(seed: seed)]
    }

    /// A short human label used in test failure messages.
    var label: String {
        switch model {
        case let .ipCamera(name): "\(name)/\(videoCodec.rawValue)"
        case let .nvr(channels): "NVR-\(channels)ch/\(videoCodec.rawValue)"
        case .analogEncoder: "analog/\(videoCodec.rawValue)"
        }
    }
}
