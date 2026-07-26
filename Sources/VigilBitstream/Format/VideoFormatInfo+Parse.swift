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
        let chromaArrayType: UInt8 = sps.separateColourPlaneFlag ? 0 : sps.chromaFormatIDC
        let sub = VideoFormatInfo.subSampling(sps.chromaFormatIDC,
                                              separateColourPlane: sps.separateColourPlaneFlag)
        let frameMbsOnly = sps.frameMbsOnlyFlag
        let codedWidth = sps.picWidthInMbs * 16
        let codedHeight = (frameMbsOnly ? 1 : 2) * sps.picHeightInMapUnits * 16

        let cropUnitX = chromaArrayType == 0 ? 1 : sub.width
        let cropUnitY = chromaArrayType == 0
            ? (frameMbsOnly ? 1 : 2)
            : sub.height * (frameMbsOnly ? 1 : 2)
        let crop = sps.frameCropping
        let cropLeft = cropUnitX * crop.left
        let cropTop = cropUnitY * crop.top
        let cropWidth = max(0, codedWidth - cropUnitX * (crop.left + crop.right))
        let cropHeight = max(0, codedHeight - cropUnitY * (crop.top + crop.bottom))

        let sar = VideoFormatInfo.sanitisedSAR(width: sps.sarWidth, height: sps.sarHeight)
        let geometry = FrameGeometry(
            codedWidth: codedWidth, codedHeight: codedHeight,
            cropLeft: cropLeft, cropTop: cropTop, cropWidth: cropWidth, cropHeight: cropHeight,
            sarWidth: sar.width, sarHeight: sar.height,
            bitDepth: sps.bitDepthLuma,
            fieldOrder: frameMbsOnly ? .progressive : .topFieldFirst,
            color: VideoFormatInfo.colorInfo(primaries: sps.colourPrimaries,
                                             transfer: sps.transferCharacteristics,
                                             matrix: sps.matrixCoefficients,
                                             fullRange: sps.videoFullRangeFlag,
                                             codedHeight: codedHeight))

        // H.264 time_scale counts field ticks, hence the factor of two absent from the H.265 form.
        var fps: Double?
        if let tick = sps.numUnitsInTick, let scale = sps.timeScale, tick > 0 {
            let candidate = Double(scale) / (2.0 * Double(tick))
            if candidate >= 1.0, candidate <= 240.0 { fps = candidate }
        }

        self.init(codec: .h264,
                  geometry: geometry,
                  frameRate: fps,
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
                  profileName: VideoFormatInfo.h264ProfileName(sps.profileIDC,
                                                               constraintFlags: sps.constraintFlags),
                  levelName: VideoFormatInfo.h264LevelName(sps.levelIDC,
                                                           constraintFlags: sps.constraintFlags))
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

    /// `SubWidthC` and `SubHeightC` from H.264 Table 6-1 / H.265 Table 6-1, which are identical.
    ///
    /// Monochrome leaves them undefined in both standards; 1 is returned because the only caller
    /// guards on `ChromaArrayType == 0` before using them.
    static func subSampling(_ chromaFormatIDC: UInt8,
                            separateColourPlane: Bool) -> (width: Int, height: Int) {
        if separateColourPlane { return (1, 1) }
        switch chromaFormatIDC {
        case 1: return (2, 2)       // 4:2:0
        case 2: return (2, 1)       // 4:2:2
        case 3: return (1, 1)       // 4:4:4
        default: return (1, 1)      // monochrome
        }
    }

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

    /// H.264 profile name (spec-bitstream §8.7).
    ///
    /// "Constrained Baseline" requires `constraint_set1_flag`, mask `0x40` — **not** `0x80`, which
    /// is `constraint_set0_flag`. Confusing the two mislabels every Baseline substream.
    static func h264ProfileName(_ idc: UInt8, constraintFlags: UInt8) -> String {
        let constraintSet1 = constraintFlags & 0b0100_0000 != 0
        switch idc {
        case 66: return constraintSet1 ? "Constrained Baseline" : "Baseline"
        case 77: return "Main"
        case 88: return "Extended"
        case 100: return "High"
        case 110: return "High 10"
        case 122: return "High 4:2:2"
        case 244: return "High 4:4:4 Predictive"
        case 44: return "CAVLC 4:4:4 Intra"
        default: return "Unknown (\(idc))"
        }
    }

    /// H.264 level name (spec-bitstream §8.7). Level "1b" is `level_idc == 11` with
    /// `constraint_set3_flag` set, or the historical `level_idc == 9`.
    static func h264LevelName(_ idc: UInt8, constraintFlags: UInt8) -> String {
        let constraintSet3 = constraintFlags & 0b0001_0000 != 0
        if idc == 9 || (idc == 11 && constraintSet3) { return "1b" }
        return "\(idc / 10).\(idc % 10)"
    }
}
