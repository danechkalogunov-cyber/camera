//
//  EncodedFrame.swift
//  VigilProtocols
//
//  The one media type that crosses from the pure layer into `VigilVideo`: one access unit or one
//  audio buffer, its timing, its classification, and the audio format description that goes with it.
//  Implements docs/API_CONTRACT.md §3.5 and §2 R-02 / R-06 / R-08 / R-53 / R-54.
//

import Foundation

// MARK: - AudioFormatInfo

/// Everything a decoder needs about an audio stream that is not in the samples themselves.
public struct AudioFormatInfo: Sendable, Hashable, Codable {

    // MARK: - Stored Properties

    /// The codec the samples are in — for `pcmS16LE` the stream was already decoded in the pure layer.
    public var codec: AudioCodec

    /// Samples per second, from the SDP clock rate. Never assumed; `AudioCodec.defaultSampleRate`
    /// is the fallback only when the camera advertised none.
    public var sampleRate: Int32

    /// Channel count. 1 for every Hikvision audio profile we have seen.
    public var channels: Int32

    /// 1024 for AAC-LC, 960 for AAC-LC/960, 1 for PCM and G.711.
    public var framesPerPacket: Int32

    /// AAC `AudioSpecificConfig`, verbatim, for `kAudioConverterDecompressionMagicCookie`.
    /// **Never** smuggled through `ParameterSets.sps[0]` (API_CONTRACT §2 R-54).
    public var magicCookie: Data?

    // MARK: - Initialisation

    /// Builds an audio format description. Nothing is validated here: a zero or negative sample rate
    /// is a protocol error the RTP track format reports, not a trap this type takes.
    public init(codec: AudioCodec, sampleRate: Int32, channels: Int32,
                framesPerPacket: Int32, magicCookie: Data? = nil) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.framesPerPacket = framesPerPacket
        self.magicCookie = magicCookie
    }
}

// MARK: - FrameDropClass

/// How droppable a frame is under queue pressure. Derived by `VigilRTP` while depacketizing,
/// because that is the only place the NAL headers are already in hand.
public enum FrameDropClass: UInt8, Sendable, Hashable, Codable, Comparable {

    /// Referenced by later frames. Dropping it corrupts everything until the next IRAP.
    case required = 0

    /// H.264: every VCL NAL of the AU had `nal_ref_idc == 0`.
    case droppableNonReference = 1

    /// H.265: `nuh_temporal_id > 0` with `sps_temporal_id_nesting_flag == 1`.
    case droppableTemporal = 2

    /// Ascending droppability: `.required < .droppableNonReference < .droppableTemporal`, so
    /// "drop the most droppable first" is a `max` and a queue can sort on it directly.
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

// MARK: - EncodedFrame

/// One access unit (video) or one audio buffer.
///
/// **This is the only media type that crosses from the pure layer into `VigilVideo`.**
/// Foundation-only by construction. `spec-rtp.md`, `spec-bitstream.md` and
/// `spec-video-pipeline.md` all restate it; this declaration is the normative one
/// (API_CONTRACT §2 R-02).
public struct EncodedFrame: Sendable, Equatable {

    // MARK: - Payload

    /// Video: concatenated NAL units, each preceded by a **4-byte big-endian length**
    /// (AVCC/HVCC style, `nalUnitHeaderLength == 4`). **Never Annex-B.** Start codes never appear.
    /// There is no configuration knob and no conversion step on the live path: the depacketizers
    /// write the 4-byte length directly as they reassemble, and `VigilVideo` hands `data`
    /// straight to `CMBlockBufferCreateWithMemoryBlock`.
    ///
    /// The length counts the NAL unit only, header included, prefix excluded, so the buffer is
    /// walked as `[len₀][nal₀][len₁][nal₁]…` and a length that runs past the end of `data` is a
    /// corrupt frame, not a value any reader may trust.
    ///
    /// Audio, `.aac`: one raw AAC access unit — no ADTS header, no length prefix.
    /// Audio, `.pcmS16LE`: interleaved signed 16-bit little-endian samples.
    /// Video, `.mjpeg`: one complete JPEG, SOI to EOI, no length prefix.
    public var data: Data

    /// Which codec `data` is in, and therefore which of the two payload layouts above applies.
    public var codec: MediaCodec

    // MARK: - Time

    /// Presentation time, in the track's own timescale (90 kHz for RTP video).
    public var pts: MediaTimestamp

    /// `nil` when the stream does not reorder — which is every Hikvision live profile and all
    /// audio. Populated only for recorded content with B-frames, where `dts <= pts` is guaranteed.
    /// `VigilVideo` treats `nil` as "dts == pts" and must never synthesise a decode order
    /// (API_CONTRACT §2 R-06).
    public var dts: MediaTimestamp?

    /// Always present for audio; present for video only when the frame rate is known.
    public var duration: MediaTimestamp?

    /// Arrival of the **last** packet of this access unit. The anchor for the glass-to-glass
    /// latency estimate.
    public var receivedAt: MediaInstant

    // MARK: - Classification

    /// IDR (H.264 NAL type 5) or IRAP (H.265 types 16–23). **Not** "an I-slice"
    /// — that distinction drives sync samples in recordings and the `NotSync` attachment.
    public var isKeyframe: Bool

    /// How droppable this frame is under queue pressure.
    public var dropClass: FrameDropClass

    /// True when at least one NAL was lost or truncated. `VigilVideo` drops these unless
    /// `AppSettings.decodeCorruptFrames` is on (default off).
    public var isCorrupt: Bool

    // MARK: - Format

    /// Non-`nil` **only on the first frame after the sets changed**, including the very first
    /// frame. `VigilVideo` must retain the last non-`nil` value for the lifetime of the stream
    /// and must not expect a resend after a decoder reset (API_CONTRACT §2 R-53).
    public var parameterSets: ParameterSets?

    /// Non-`nil` on the first audio frame and whenever the audio configuration changes.
    public var audioFormat: AudioFormatInfo?

    // MARK: - Accounting

    /// Extended (unwrapped) RTP sequence numbers of the first and last packet that fed this frame.
    /// `nil` for frames produced from a file rather than from RTP.
    public var sequenceRange: ClosedRange<UInt32>?

    /// Monotonic access-unit counter for this stream, starting at 0 and never reset except by
    /// `Depacketizer.reset()`. Gap accounting compares consecutive values.
    public var accessUnitIndex: UInt64

    /// Number of NAL units in `data`, so `VigilVideo` can size scratch arrays without rescanning.
    public var nalCount: Int

    // MARK: - Computed Properties

    /// Payload size in bytes, length prefixes included. The unit every bitrate statistic counts in.
    @inlinable public var byteCount: Int { data.count }

    /// The video codec, or `nil` for an audio frame.
    @inlinable public var videoCodec: VideoCodec? { codec.video }

    // MARK: - Initialisation

    /// Builds a frame. The defaults describe the common live case: no reordering, no duration, a
    /// non-droppable intact frame with no format change attached.
    public init(data: Data, codec: MediaCodec, pts: MediaTimestamp,
                dts: MediaTimestamp? = nil, duration: MediaTimestamp? = nil,
                receivedAt: MediaInstant, isKeyframe: Bool,
                dropClass: FrameDropClass = .required, isCorrupt: Bool = false,
                parameterSets: ParameterSets? = nil, audioFormat: AudioFormatInfo? = nil,
                sequenceRange: ClosedRange<UInt32>? = nil, accessUnitIndex: UInt64 = 0,
                nalCount: Int = 0) {
        self.data = data
        self.codec = codec
        self.pts = pts
        self.dts = dts
        self.duration = duration
        self.receivedAt = receivedAt
        self.isKeyframe = isKeyframe
        self.dropClass = dropClass
        self.isCorrupt = isCorrupt
        self.parameterSets = parameterSets
        self.audioFormat = audioFormat
        self.sequenceRange = sequenceRange
        self.accessUnitIndex = accessUnitIndex
        self.nalCount = nalCount
    }
}
