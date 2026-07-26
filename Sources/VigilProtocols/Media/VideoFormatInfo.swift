//
//  VideoFormatInfo.swift
//  VigilProtocols
//
//  The neutral description of a decoded video format: geometry, profile/tier/level and the reorder
//  limits, plus the single predicate that decides whether a decode session can be kept alive.
//  Implements docs/API_CONTRACT.md §3.6 and §2 R-50 (`VigilVideo.VideoFormat` does not exist).
//
//  No `import` on purpose: `String`, `Double` and the fixed-width integers are all stdlib.
//

// MARK: - VideoFormatInfo

/// The neutral, platform-independent description of a decoded video format.
///
/// `VigilBitstream` produces it from SPS/VPS/PPS; `VigilVideo` converts it to a
/// `CMVideoFormatDescription` in exactly one file; `VigilRender` reads `geometry`.
/// `VigilVideo.VideoFormat` does not exist (API_CONTRACT §2 R-50).
public struct VideoFormatInfo: Sendable, Hashable, Codable {

    // MARK: - Stored Properties

    /// The codec this format describes.
    public var codec: VideoCodec

    /// Coded size, crop, SAR, bit depth, scan type and colour.
    public var geometry: FrameGeometry

    /// Parsed from the VUI. **Metadata only** — RTP timestamps drive the live clock and the
    /// container drives recorded playback. The fallback chain is VUI → RTP-measured → ISAPI → 25.0.
    /// H.264 divides by `2 × num_units_in_tick`; H.265 does not divide by 2.
    public var frameRate: Double?

    /// `profile_idc` (H.264) or `general_profile_idc` (H.265).
    public var profileIDC: UInt8

    /// H.264 only: the eight `constraint_setN_flag` bits.
    public var constraintFlags: UInt8

    /// `level_idc` (H.264) or `general_level_idc` (H.265).
    public var levelIDC: UInt8

    /// H.265 only. 0 = Main tier, 1 = High tier.
    public var tier: UInt8

    /// 0 monochrome, 1 = 4:2:0, 2 = 4:2:2, 3 = 4:4:4. Vigil decodes 1 and (H.265) 2.
    public var chromaFormatIDC: UInt8

    /// VUI `max_num_reorder_frames` / `sps_max_num_reorder_pics`. Zero for every live profile,
    /// which is what lets `dts` stay `nil` (API_CONTRACT §2 R-06).
    public var maxNumReorderFrames: Int

    /// VUI `max_dec_frame_buffering` / `sps_max_dec_pic_buffering_minus1 + 1`.
    public var maxDecFrameBuffering: Int

    /// VUI `min_spatial_segmentation_idc`. Feeds the decoder's parallelism hint only.
    public var minSpatialSegmentationIDC: Int

    /// `sps_max_sub_layers_minus1 + 1` for H.265; 1 for H.264.
    public var numTemporalLayers: Int

    /// H.265 `sps_temporal_id_nesting_flag`. Required before a frame may be classed
    /// `.droppableTemporal`.
    public var temporalIDNested: Bool

    /// "High", "Main 10", "Baseline"… For the inspector, never for control flow.
    public var profileName: String

    /// "4.1", "5.1"… For the inspector.
    public var levelName: String

    // MARK: - Initialisation

    /// Builds a format description.
    ///
    /// Everything except the codec and the geometry defaults to "not parsed": a bitstream parser
    /// that reads only what it needs still produces a usable value, and the inspector shows an empty
    /// profile name rather than a wrong one.
    public init(codec: VideoCodec, geometry: FrameGeometry, frameRate: Double? = nil,
                profileIDC: UInt8 = 0, constraintFlags: UInt8 = 0, levelIDC: UInt8 = 0,
                tier: UInt8 = 0, chromaFormatIDC: UInt8 = 1,
                maxNumReorderFrames: Int = 0, maxDecFrameBuffering: Int = 0,
                minSpatialSegmentationIDC: Int = 0, numTemporalLayers: Int = 1,
                temporalIDNested: Bool = false,
                profileName: String = "", levelName: String = "") {
        self.codec = codec
        self.geometry = geometry
        self.frameRate = frameRate
        self.profileIDC = profileIDC
        self.constraintFlags = constraintFlags
        self.levelIDC = levelIDC
        self.tier = tier
        self.chromaFormatIDC = chromaFormatIDC
        self.maxNumReorderFrames = maxNumReorderFrames
        self.maxDecFrameBuffering = maxDecFrameBuffering
        self.minSpatialSegmentationIDC = minSpatialSegmentationIDC
        self.numTemporalLayers = numTemporalLayers
        self.temporalIDNested = temporalIDNested
        self.profileName = profileName
        self.levelName = levelName
    }

    // MARK: - Computed Properties

    // Passthroughs so `spec-bitstream.md`'s prose still reads correctly.

    /// Allocation width, in luma samples.
    @inlinable public var codedWidth: Int { geometry.codedWidth }

    /// Allocation height, in luma samples.
    @inlinable public var codedHeight: Int { geometry.codedHeight }

    /// Displayed width after cropping and SAR correction.
    @inlinable public var displayWidth: Int { geometry.displaySize.width }

    /// Displayed height, which is the crop height.
    @inlinable public var displayHeight: Int { geometry.displaySize.height }

    /// Sample aspect ratio numerator.
    @inlinable public var sarWidth: Int { geometry.sarWidth }

    /// Sample aspect ratio denominator.
    @inlinable public var sarHeight: Int { geometry.sarHeight }

    /// Luma bit depth: 8 or 10.
    @inlinable public var bitDepthLuma: Int { geometry.bitDepth }

    /// True when the picture is not interlaced.
    @inlinable public var isProgressive: Bool { geometry.isProgressive }

    /// Width of one sample divided by its height.
    @inlinable public var pixelAspectRatio: Double { geometry.pixelAspectRatio }

    /// Displayed width over displayed height.
    @inlinable public var displayAspectRatio: Double { geometry.displayAspect }

    /// Coded pixel count, the input to the decode-budget cost formula (API_CONTRACT §2 R-58).
    @inlinable public var codedPixels: Int { geometry.codedWidth * geometry.codedHeight }

    // MARK: - Public API

    /// **A format change is exactly this and nothing else:** codec, coded width, coded height,
    /// chroma format, or luma bit depth. Anything else (crop, SAR, colour, frame rate, level)
    /// bumps the `generation` counter — rebuild the format description, keep the decode session.
    @inlinable public func isDecoderCompatible(with other: VideoFormatInfo) -> Bool {
        codec == other.codec
            && geometry.codedWidth == other.geometry.codedWidth
            && geometry.codedHeight == other.geometry.codedHeight
            && chromaFormatIDC == other.chromaFormatIDC
            && geometry.bitDepth == other.geometry.bitDepth
    }
}
