//
//  Codecs.swift
//  VigilProtocols
//
//  The three codec enums every media type is parameterised on: one for video, one for audio, and the
//  flat union `EncodedFrame` carries.
//  Implements docs/API_CONTRACT.md §3.4 and §2 R-04 (two narrow enums plus a union, not one wide
//  enum) and §2 R-58 (the decode-weight table).
//
//  No `import` on purpose: these are plain enums over `String`.
//

// MARK: - VideoCodec

/// A video codec Vigil can carry. `mjpeg` is present because F-DEC-05 and the class-D
/// JPEG-poll tile mode both name it; it is not NAL-based and has no parameter sets.
///
/// There is no `.unknown` case: a codec we cannot name is a parse failure at the SDP boundary, not a
/// value that flows into the pipeline.
public enum VideoCodec: String, Sendable, Hashable, Codable, CaseIterable {
    case h264, h265, mjpeg

    /// Bytes of NAL header preceding the RBSP: 1 for H.264, 2 for H.265, 0 for MJPEG.
    @inlinable public var nalHeaderLength: Int {
        switch self { case .h264: 1; case .h265: 2; case .mjpeg: 0 }
    }

    /// True for the two codecs whose access units are NAL units, so a caller may read
    /// `nalHeaderLength` and expect `ParameterSets` to be meaningful.
    @inlinable public var isNALBased: Bool { self != .mjpeg }

    /// Relative hardware-decode cost per pixel per second, normalised to H.264 = 1.0.
    /// The bit-depth surcharge is applied separately by `DecodeCost` (API_CONTRACT §2 R-58).
    @inlinable public var decodeWeight: Double {
        switch self { case .h264: 1.00; case .h265: 1.35; case .mjpeg: 0.45 }
    }
}

// MARK: - AudioCodec

/// An audio codec Vigil can carry. `pcmS16LE` is not a wire format: it is what `VigilRTP` produces
/// after decoding G.711 or G.726 in the pure layer.
public enum AudioCodec: String, Sendable, Hashable, Codable, CaseIterable {
    case aac, g711A, g711U, g726, pcmS16LE

    /// True when the codec can be muxed into MP4 without re-encoding. Only AAC can.
    /// G.711 in a `.mov` is legal; in an `.mp4` it is not, which is why `ClipRecorder` picks the
    /// container from the audio codec unless the user forced one.
    @inlinable public var isMP4Muxable: Bool { self == .aac }

    /// True when `VigilRTP` decodes it to `.pcmS16LE` in the pure layer.
    @inlinable public var isDecodedInPureLayer: Bool { self == .g711A || self == .g711U || self == .g726 }

    /// The rate assumed when the SDP omits one. Never a substitute for the advertised clock rate —
    /// it is the fallback for a camera that answers `a=rtpmap:` with no rate at all.
    @inlinable public var defaultSampleRate: Int32 {
        switch self { case .aac: 16_000; case .g726: 8_000; default: 8_000 }
    }
}

// MARK: - MediaCodec

/// The flat union carried by `EncodedFrame`. Two narrow enums plus one union beats one wide enum,
/// because `ParameterSets` and `VideoFormatInfo` genuinely cannot be audio (API_CONTRACT §2 R-04).
public enum MediaCodec: Sendable, Hashable, Codable, CustomStringConvertible {
    case video(VideoCodec)
    case audio(AudioCodec)

    /// The video codec, or `nil` when this is an audio track.
    @inlinable public var video: VideoCodec? { if case .video(let c) = self { c } else { nil } }

    /// The audio codec, or `nil` when this is a video track.
    @inlinable public var audio: AudioCodec? { if case .audio(let c) = self { c } else { nil } }

    /// True for every video case, including `.mjpeg`.
    @inlinable public var isVideo: Bool { video != nil }

    /// The underlying codec's raw value, e.g. `"h265"`. Diagnostic only.
    public var description: String { video?.rawValue ?? audio?.rawValue ?? "unknown" }
}
