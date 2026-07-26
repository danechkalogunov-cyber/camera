//
//  VideoFormatInfo+Parse.swift
//  VigilBitstream
//
//  The bridge from a parsed parameter set to the neutral `VideoFormatInfo` the rest of Vigil reads:
//  cropping and conformance-window derivation, the two different frame-rate formulas, the SAR
//  sanity rule and the profile/level names.
//  Implements docs/spec-bitstream.md §8.6, §8.7, §13.5 and API_CONTRACT §4.2.
//

import VigilProtocols

// MARK: - H.264

extension VideoFormatInfo {

    /// Builds a format description from a parsed H.264 SPS.
    ///
    /// **Reports the cropped display size and the coded allocation size separately.** 1080p H.264
    /// is coded 1920×1088 and displayed 1920×1080; the renderer, the window and the recorder read
    /// `displayWidth`/`displayHeight`, while the decoder allocates from `codedWidth`/`codedHeight`.
    ///
    /// The crop units are macroblock-derived (H.264 §7.4.2.1.1): `CropUnitX` is `SubWidthC`, and
    /// `CropUnitY` is `SubHeightC × (2 − frame_mbs_only_flag)`, so an interlaced stream removes
    /// **four** luma rows per unit of `frame_crop_bottom_offset` rather than two.
    ///
    /// Frame rate is `time_scale / (2 × num_units_in_tick)` — H.264 counts field ticks — and is
    /// accepted only when the tick is non-zero and the result lies in 1…240 fps. It is metadata:
    /// the presentation clock comes from RTP timestamps, never from here.
    public init(_ sps: H264SPS) {
        // The derivations live on `H264SPS` so that a caller holding only the parsed model gets the
        // same numbers; duplicating them here is how the reported size and the allocated size come
        // to disagree.
        let crop = sps.frameCropping
        let sar = VideoFormatInfo.sanitisedSAR(width: sps.sarWidth, height: sps.sarHeight)
        let geometry = FrameGeometry(
            codedWidth: sps.codedWidth, codedHeight: sps.codedHeight,
            cropLeft: sps.cropUnitX * crop.left, cropTop: sps.cropUnitY * crop.top,
            cropWidth: max(0, sps.displayWidth), cropHeight: max(0, sps.displayHeight),
            sarWidth: sar.width, sarHeight: sar.height,
            bitDepth: sps.bitDepthLuma,
            fieldOrder: sps.frameMbsOnlyFlag ? .progressive : .topFieldFirst,
            color: VideoFormatInfo.colorInfo(primaries: sps.colourPrimaries,
                                             transfer: sps.transferCharacteristics,
                                             matrix: sps.matrixCoefficients,
                                             fullRange: sps.videoFullRangeFlag,
                                             codedHeight: sps.codedHeight))

        self.init(codec: .h264,
                  geometry: geometry,
                  frameRate: sps.frameRate,
                  profileIDC: sps.profileIDC,
                  constraintFlags: sps.constraintFlags,
                  levelIDC: sps.levelIDC,
                  tier: 0,
                  chromaFormatIDC: sps.chromaFormatIDC,
                  maxNumReorderFrames: sps.maxNumReorderFrames,
                  maxDecFrameBuffering: sps.maxDecFrameBuffering,
                  minSpatialSegmentationIDC: 0,
                  numTemporalLayers: 1,
                  temporalIDNested: false,
                  profileName: sps.profileName,
                  levelName: sps.levelName)
    }
}

// MARK: - H.265

extension VideoFormatInfo {

    /// Builds a format description from a parsed H.265 SPS.
    ///
    /// The conformance-window offsets are in **chroma sample units**, so they are multiplied by
    /// `SubWidthC`/`SubHeightC` — unlike H.264's crop units, which are already macroblock-derived.
    /// For 4:2:0 each unit of offset therefore removes two luma columns or rows.
    ///
    /// Frame rate is `time_scale / num_units_in_tick`, with **no factor of two**. That asymmetry
    /// with H.264 is the single most common reported-fps bug.
    ///
    /// - Parameters:
    ///   - sps: the parsed SPS. Everything in the returned value comes from here.
    ///   - vps: the VPS, used only to fill `temporalIDNested` when no SPS-derived value is
    ///     meaningful. ISO/IEC 14496-15 requires the two to agree for a single-layer stream and the
    ///     SPS wins when they do not (spec-bitstream §12).
    ///   - pps: accepted so that callers can pass the whole parameter-set triple; no field of
    ///     `VideoFormatInfo` derives from the PPS today. `parallelismType` lives in `hvcC` only.
    public init(_ sps: H265SPS, vps: H265VPS?, pps: H265PPS?) {
        _ = pps
        let sar = VideoFormatInfo.sanitisedSAR(width: sps.sarWidth, height: sps.sarHeight)
        let geometry = FrameGeometry(
            codedWidth: sps.codedWidth, codedHeight: sps.codedHeight,
            cropLeft: sps.cropLeft, cropTop: sps.cropTop,
            cropWidth: sps.displayWidth, cropHeight: sps.displayHeight,
            sarWidth: sar.width, sarHeight: sar.height,
            bitDepth: sps.bitDepthLuma,
            fieldOrder: sps.fieldSeqFlag ? .topFieldFirst : .progressive,
            color: VideoFormatInfo.colorInfo(primaries: sps.colourPrimaries,
                                             transfer: sps.transferCharacteristics,
                                             matrix: sps.matrixCoefficients,
                                             fullRange: sps.videoFullRangeFlag,
                                             codedHeight: sps.codedHeight))

        self.init(codec: .h265,
                  geometry: geometry,
                  frameRate: sps.frameRate,
                  profileIDC: sps.ptl.generalProfileIDC,
                  constraintFlags: 0,
                  levelIDC: sps.ptl.generalLevelIDC,
                  tier: sps.ptl.generalTierFlag,
                  chromaFormatIDC: sps.chromaFormatIDC,
                  maxNumReorderFrames: sps.maxNumReorderPics,
                  maxDecFrameBuffering: sps.maxDecPicBuffering,
                  minSpatialSegmentationIDC: sps.minSpatialSegmentationIDC,
                  numTemporalLayers: sps.numTemporalLayers,
                  temporalIDNested: sps.temporalIDNestingFlag || (vps?.temporalIDNestingFlag ?? false),
                  profileName: sps.ptl.profileName,
                  levelName: sps.ptl.levelName)
    }
}

// MARK: - Shared derivations

extension VideoFormatInfo {

    /// The SAR sanity rule: a zero or negative component means "unspecified", which is 1:1.
    ///
    /// Hikvision routinely omits the SAR entirely on substreams, and a `sar_height` of 0 is
    /// expressible in a VUI; either would poison every aspect-ratio calculation downstream.
    static func sanitisedSAR(width: Int, height: Int) -> (width: Int, height: Int) {
        (width > 0 && height > 0) ? (width, height) : (1, 1)
    }

    /// Maps the VUI colour codepoints onto `ColorInfo`.
    ///
    /// When the VUI carries no colour description we fall back to BT.709 for HD and BT.601 for
    /// anything shorter than 576 coded rows, which is what every Hikvision encoder actually
    /// produces and what a viewer without the fallback renders visibly wrong (green-shifted faces
    /// on D1 substreams).
    static func colorInfo(primaries: UInt8?, transfer: UInt8?, matrix: UInt8?,
                          fullRange: Bool, codedHeight: Int) -> ColorInfo {
        var info = codedHeight < 576 ? ColorInfo.bt601Video : ColorInfo.bt709Video
        info.range = fullRange ? .full : .video
        if let matrix {
            switch matrix {
            case 1: info.matrix = .bt709
            case 5, 6: info.matrix = .bt601
            case 9, 10: info.matrix = .bt2020ncl
            default: info.matrix = .unspecified
            }
        }
        if let transfer {
            switch transfer {
            case 1, 14, 15: info.transfer = .bt709   // 14/15 are BT.709's curve at 10/12 bits
            case 6: info.transfer = .smpte170m
            case 13: info.transfer = .srgb
            case 16: info.transfer = .pq
            case 18: info.transfer = .hlg
            default: info.transfer = .unspecified
            }
        }
        if let primaries {
            switch primaries {
            case 1: info.primaries = .bt709
            case 5, 6, 7: info.primaries = .smpte170m
            case 9: info.primaries = .bt2020
            default: info.primaries = .unspecified
            }
        }
        return info
    }
}
