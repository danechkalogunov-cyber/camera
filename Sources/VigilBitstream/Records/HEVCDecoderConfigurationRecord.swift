//
//  HEVCDecoderConfigurationRecord.swift
//  VigilBitstream
//
//  Build, serialize and parse the ISO/IEC 14496-15 §8.3.3.1 `hvcC` record: a 23-byte fixed header
//  whose first thirteen bytes are the SPS profile_tier_level, followed by one array per NAL type.
//  Implements docs/spec-bitstream.md §17, and is verified byte-for-byte against §17.1.
//

import Foundation
import VigilProtocols

// MARK: - HEVCDecoderConfigurationRecord

/// The `hvcC` decoder configuration record for an H.265 stream.
///
/// Two mistakes account for nearly every broken `hvcC` in the wild, and both are structural rather
/// than arithmetic:
///
/// 1. **The record stores parsed field values; the arrays store on-wire bytes.** The constraint
///    flags appear once at offset 6 unescaped (`B0 00 00 00 00 00`) and again inside the SPS NAL
///    unit escaped (`B0 00 00 03 00 00 03 00`). They are not the same bytes and must not be copied
///    from one place to the other.
/// 2. **`avgFrameRate` is in frames per 256 seconds**, not frames per second. 25 fps is `0x1900`.
///    Off by that factor of 256, QuickTime reports a 0.1 fps movie.
///
/// The profile/tier/level fields come from the **SPS**, never from the VPS: ISO requires them to
/// agree for a single-layer stream, and the SPS is the parameter set that governs the pictures.
public struct HEVCDecoderConfigurationRecord: Sendable, Hashable {

    // MARK: - NALArray

    /// One `hvcC` array: every stored NAL unit of a single type.
    ///
    /// A struct rather than a tuple because the record must stay `Hashable`, and because array
    /// completeness is a per-array property that a tuple would let a caller forget.
    public struct NALArray: Sendable, Hashable {

        /// `array_completeness`. True asserts that no NAL unit of this type appears in the samples.
        /// Vigil sets it for VPS/SPS/PPS, which it guarantees, and clears it for SEI, which is
        /// emitted in-band on nearly every frame by Hikvision firmware.
        public var arrayCompleteness: Bool

        /// `NAL_unit_type`: 32 VPS, 33 SPS, 34 PPS, 39 prefix SEI.
        public var nalUnitType: UInt8

        /// The NAL units, each with its 2-byte header, escaped, no start code or length prefix.
        public var nalUnits: [Data]

        /// Builds an array. Nothing is validated; an unknown `nalUnitType` is legal and is retained
        /// so that a round trip through this type is byte-exact.
        public init(arrayCompleteness: Bool, nalUnitType: UInt8, nalUnits: [Data]) {
            self.arrayCompleteness = arrayCompleteness
            self.nalUnitType = nalUnitType
            self.nalUnits = nalUnits
        }
    }

    // MARK: - Stored Properties

    /// Profile, tier, level and the 48-bit constraint flags — record offsets 1…12.
    public var ptl: ProfileTierLevel

    /// `min_spatial_segmentation_idc`, 12 bits. From the SPS VUI bitstream-restriction block, 0
    /// when absent.
    public var minSpatialSegmentationIDC: UInt16

    /// `parallelismType`, 2 bits. From the PPS (§14); 0 ("unknown") when no PPS parsed.
    public var parallelismType: UInt8

    /// `chromaFormat` — `chroma_format_idc` from the SPS.
    public var chromaFormat: UInt8

    /// `bitDepthLumaMinus8`.
    public var bitDepthLumaMinus8: UInt8

    /// `bitDepthChromaMinus8`.
    public var bitDepthChromaMinus8: UInt8

    /// `avgFrameRate` in frames per **256** seconds. 0 means unspecified.
    public var avgFrameRate: UInt16

    /// `constantFrameRate`: 0 unknown, 1 constant. Vigil never writes 2.
    public var constantFrameRate: UInt8

    /// `numTemporalLayers` — `sps_max_sub_layers_minus1 + 1`, or 0 when no SPS parsed.
    public var numTemporalLayers: UInt8

    /// `temporalIdNested` — `sps_temporal_id_nesting_flag`.
    public var temporalIDNested: Bool

    /// Always 3.
    public var lengthSizeMinusOne: UInt8

    /// The arrays, in ascending `nalUnitType`: 32, 33, 34, then 39 when SEI is carried.
    public var arrays: [NALArray]

    // MARK: - Bounds

    private static let maxParameterSetBytes = 4096
    private static let maxNALUnitsPerArray = 8
    private static let fixedHeaderBytes = 23

    // MARK: - Initialisation

    /// Builds a record from parameter-set bytes and a parsed SPS.
    ///
    /// - Parameters:
    ///   - vps: VPS NAL units in canonical form (§2.1). May be empty, though CoreMedia wants one.
    ///   - sps: SPS NAL units.
    ///   - pps: PPS NAL units.
    ///   - sei: optional prefix-SEI NAL units to carry out of band; `array_completeness` is 0 for
    ///     them because SEI also appears in the samples.
    ///   - parsedSPS: the parse of `sps.first`. Supplies every field of the fixed header except
    ///     `parallelismType`.
    ///   - parsedPPS: the parse of `pps.first`, or `nil`, which yields `parallelismType == 0`.
    /// - Throws: `.emptyNALUnit` for a zero-length set, `.tooLarge` for a set over 4096 bytes or
    ///   more than eight sets of one type.
    public init(vps: [Data], sps: [Data], pps: [Data], sei: [Data] = [],
                parsedSPS: H265SPS, parsedPPS: H265PPS?) throws(BitstreamError) {
        try HEVCDecoderConfigurationRecord.validate(vps)
        try HEVCDecoderConfigurationRecord.validate(sps)
        try HEVCDecoderConfigurationRecord.validate(pps)
        try HEVCDecoderConfigurationRecord.validate(sei)

        self.ptl = parsedSPS.ptl
        self.minSpatialSegmentationIDC =
            UInt16(clamping: max(0, parsedSPS.minSpatialSegmentationIDC))
        self.parallelismType = parsedPPS?.parallelismType ?? 0
        self.chromaFormat = parsedSPS.chromaFormatIDC
        self.bitDepthLumaMinus8 = UInt8(clamping: parsedSPS.bitDepthLuma - 8)
        self.bitDepthChromaMinus8 = UInt8(clamping: parsedSPS.bitDepthChroma - 8)

        // frames per 256 seconds, rounded; 0 when the VUI carried no usable timing.
        if let fps = parsedSPS.frameRate {
            self.avgFrameRate = UInt16(clamping: Int((fps * 256).rounded()))
        } else {
            self.avgFrameRate = 0
        }
        // "Constant" is claimed only on the evidence the VUI actually provides: timing information
        // present and the stream coding frames rather than fields. Never 2 — Vigil does not do
        // temporal-layer-aware muxing.
        let hasTiming = parsedSPS.frameRate != nil
        self.constantFrameRate = (hasTiming && !parsedSPS.fieldSeqFlag) ? 1 : 0
        self.numTemporalLayers = UInt8(clamping: parsedSPS.numTemporalLayers)
        self.temporalIDNested = parsedSPS.temporalIDNestingFlag
        self.lengthSizeMinusOne = 3

        var built = [NALArray]()
        if !vps.isEmpty { built.append(NALArray(arrayCompleteness: true, nalUnitType: 32,
                                                nalUnits: vps)) }
        if !sps.isEmpty { built.append(NALArray(arrayCompleteness: true, nalUnitType: 33,
                                                nalUnits: sps)) }
        if !pps.isEmpty { built.append(NALArray(arrayCompleteness: true, nalUnitType: 34,
                                                nalUnits: pps)) }
        // SEI is emitted in-band on nearly every frame, so this array is never complete.
        if !sei.isEmpty { built.append(NALArray(arrayCompleteness: false, nalUnitType: 39,
                                                nalUnits: sei)) }
        self.arrays = built
    }

    /// Builds a record from already-known field values, for tests and for reconstruction from a
    /// container. Nothing is validated.
    public init(ptl: ProfileTierLevel, minSpatialSegmentationIDC: UInt16 = 0,
                parallelismType: UInt8 = 0, chromaFormat: UInt8 = 1,
                bitDepthLumaMinus8: UInt8 = 0, bitDepthChromaMinus8: UInt8 = 0,
                avgFrameRate: UInt16 = 0, constantFrameRate: UInt8 = 0,
                numTemporalLayers: UInt8 = 1, temporalIDNested: Bool = false,
                arrays: [NALArray] = []) {
        self.ptl = ptl
        self.minSpatialSegmentationIDC = minSpatialSegmentationIDC
        self.parallelismType = parallelismType
        self.chromaFormat = chromaFormat
        self.bitDepthLumaMinus8 = bitDepthLumaMinus8
        self.bitDepthChromaMinus8 = bitDepthChromaMinus8
        self.avgFrameRate = avgFrameRate
        self.constantFrameRate = constantFrameRate
        self.numTemporalLayers = numTemporalLayers
        self.temporalIDNested = temporalIDNested
        self.lengthSizeMinusOne = 3
        self.arrays = arrays
    }

    private static func validate(_ sets: [Data]) throws(BitstreamError) {
        guard sets.count <= maxNALUnitsPerArray else {
            throw BitstreamError.tooLarge(bytes: sets.count)
        }
        for set in sets {
            guard !set.isEmpty else { throw BitstreamError.emptyNALUnit }
            guard set.count <= maxParameterSetBytes else {
                throw BitstreamError.tooLarge(bytes: set.count)
            }
        }
    }

    // MARK: - Serialization

    /// Emits the record exactly as ISO/IEC 14496-15 §8.3.3.1 defines it.
    ///
    /// Reserved bits are written as all-ones, which is what the standard specifies and what every
    /// reference `hvcC` in the wild contains; writing zeros there produces a record `AVFoundation`
    /// accepts but that differs byte-for-byte from every other muxer's.
    public func serialized() -> Data {
        var capacity = HEVCDecoderConfigurationRecord.fixedHeaderBytes
        for array in arrays {
            capacity += 3
            for nal in array.nalUnits { capacity += nal.count + 2 }
        }
        var out = Data()
        out.reserveCapacity(capacity)
        out.append(0x01)                                            // configurationVersion
        out.append((ptl.generalProfileSpace & 0x03) << 6
                   | (ptl.generalTierFlag & 0x01) << 5
                   | (ptl.generalProfileIDC & 0x1F))
        let compat = ptl.generalProfileCompatibilityFlags
        for shift in stride(from: 24, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: compat >> UInt32(shift)))
        }
        out.append(contentsOf: ptl.constraintIndicatorBytes)        // the verbatim 48-bit region
        out.append(ptl.generalLevelIDC)
        out.append(0xF0 | UInt8(truncatingIfNeeded: (minSpatialSegmentationIDC >> 8) & 0x0F))
        out.append(UInt8(truncatingIfNeeded: minSpatialSegmentationIDC))
        out.append(0xFC | (parallelismType & 0x03))
        out.append(0xFC | (chromaFormat & 0x03))
        out.append(0xF8 | (bitDepthLumaMinus8 & 0x07))
        out.append(0xF8 | (bitDepthChromaMinus8 & 0x07))
        out.append(UInt8(truncatingIfNeeded: avgFrameRate >> 8))
        out.append(UInt8(truncatingIfNeeded: avgFrameRate))
        var trailer: UInt8 = (constantFrameRate & 0x03) << 6
        trailer |= (numTemporalLayers & 0x07) << 3
        if temporalIDNested { trailer |= 0x04 }
        trailer |= lengthSizeMinusOne & 0x03
        out.append(trailer)
        out.append(UInt8(truncatingIfNeeded: arrays.count))
        for array in arrays {
            out.append((array.arrayCompleteness ? 0x80 : 0x00) | (array.nalUnitType & 0x3F))
            out.append(UInt8(truncatingIfNeeded: array.nalUnits.count >> 8))
            out.append(UInt8(truncatingIfNeeded: array.nalUnits.count))
            for nal in array.nalUnits {
                out.append(UInt8(truncatingIfNeeded: nal.count >> 8))
                out.append(UInt8(truncatingIfNeeded: nal.count))
                out.append(contentsOf: nal)
            }
        }
        return out
    }

    // MARK: - Parsing

    /// Parses an `hvcC` record.
    ///
    /// A truncated or over-stated array terminates the parse; whatever arrays were read in full are
    /// kept, and unknown `NAL_unit_type` values are retained in `arrays` so a round trip through a
    /// well-formed record is byte-exact. A record whose `numOfArrays` lies about how many arrays
    /// follow therefore yields the arrays that are really there, without throwing and without
    /// allocating from the stated count.
    ///
    /// - Throws: `.emptyNALUnit` when shorter than the 23-byte fixed header,
    ///   `.unsupportedRecordVersion` for a version other than 1, and `.unsupportedLengthSize` for a
    ///   `lengthSizeMinusOne` other than 3 — Vigil has no 1- or 2-byte-length code path anywhere.
    public init(parsing data: Data) throws(BitstreamError) {
        // One copy up front: `Data` slices are not zero-based.
        let bytes = [UInt8](data)
        guard bytes.count >= HEVCDecoderConfigurationRecord.fixedHeaderBytes else {
            throw BitstreamError.emptyNALUnit
        }
        guard bytes[0] == 1 else { throw BitstreamError.unsupportedRecordVersion(bytes[0]) }
        let lengthSize = bytes[21] & 0x03
        guard lengthSize == 3 else { throw BitstreamError.unsupportedLengthSize(lengthSize) }

        var compat: UInt32 = 0
        for index in 2 ..< 6 { compat = (compat << 8) | UInt32(bytes[index]) }
        var constraint: UInt64 = 0
        for index in 6 ..< 12 { constraint = (constraint << 8) | UInt64(bytes[index]) }
        self.ptl = ProfileTierLevel(
            generalProfileSpace: (bytes[1] >> 6) & 0x03,
            generalTierFlag: (bytes[1] >> 5) & 0x01,
            generalProfileIDC: bytes[1] & 0x1F,
            generalProfileCompatibilityFlags: compat,
            generalConstraintIndicatorFlags: constraint,
            generalLevelIDC: bytes[12],
            subLayerLevelIDC: [])

        self.minSpatialSegmentationIDC = UInt16(bytes[13] & 0x0F) << 8 | UInt16(bytes[14])
        self.parallelismType = bytes[15] & 0x03
        self.chromaFormat = bytes[16] & 0x03
        self.bitDepthLumaMinus8 = bytes[17] & 0x07
        self.bitDepthChromaMinus8 = bytes[18] & 0x07
        self.avgFrameRate = UInt16(bytes[19]) << 8 | UInt16(bytes[20])
        self.constantFrameRate = (bytes[21] >> 6) & 0x03
        self.numTemporalLayers = (bytes[21] >> 3) & 0x07
        self.temporalIDNested = bytes[21] & 0x04 != 0
        self.lengthSizeMinusOne = 3

        let statedArrayCount = Int(bytes[22])
        var cursor = 23
        var parsed = [NALArray]()
        parsed.reserveCapacity(min(statedArrayCount, 8))
        for _ in 0 ..< statedArrayCount {
            guard cursor + 3 <= bytes.count else { break }
            let completeness = bytes[cursor] & 0x80 != 0
            let nalType = bytes[cursor] & 0x3F
            let statedNALCount = Int(bytes[cursor + 1]) << 8 | Int(bytes[cursor + 2])
            cursor += 3
            var units = [Data]()
            var truncated = false
            for _ in 0 ..< statedNALCount {
                guard cursor + 2 <= bytes.count else { truncated = true; break }
                let length = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
                guard length > 0, cursor + 2 + length <= bytes.count else {
                    truncated = true
                    break
                }
                units.append(Data(bytes[(cursor + 2) ..< (cursor + 2 + length)]))
                cursor += 2 + length
            }
            parsed.append(NALArray(arrayCompleteness: completeness, nalUnitType: nalType,
                                   nalUnits: units))
            if truncated { break }
        }
        self.arrays = parsed
    }

    // MARK: - Public API

    /// NAL units of one type, or an empty array when the record carries none.
    public func nalUnits(ofType type: UInt8) -> [Data] {
        arrays.first { $0.nalUnitType == type }?.nalUnits ?? []
    }

    /// The parameter sets in Vigil's canonical form, ready for the store or for CoreMedia.
    /// SEI arrays are not included — they are not parameter sets.
    public var parameterSets: ParameterSets {
        ParameterSets(codec: .h265, vps: nalUnits(ofType: 32), sps: nalUnits(ofType: 33),
                      pps: nalUnits(ofType: 34))
    }
}
