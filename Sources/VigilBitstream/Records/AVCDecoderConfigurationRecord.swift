//
//  AVCDecoderConfigurationRecord.swift
//  VigilBitstream
//
//  Build, serialize and parse the ISO/IEC 14496-15 §5.3.3.1 `avcC` record. Used for MP4 muxing,
//  for reading back our own recordings and NVR downloads, and — on Linux, where there is no
//  VideoToolbox — as the only executable regression test of parameter-set handling.
//  Implements docs/spec-bitstream.md §16.
//

import Foundation
import VigilProtocols

// MARK: - AVCDecoderConfigurationRecord

/// The `avcC` decoder configuration record for an H.264 stream.
///
/// `lengthSizeMinusOne` is **always 3** in Vigil: every NAL unit anywhere in the app carries a
/// 4-byte big-endian length prefix, there is no configuration knob, and a record that says
/// otherwise is rejected on parse rather than silently producing a stream the depacketizer cannot
/// read.
///
/// Bytes 1–3 are copied **verbatim** from the SPS NAL unit rather than recomputed from a parsed
/// model. `profile_compatibility` is the packed constraint-flag byte including its two reserved
/// bits; re-deriving it from six booleans is exactly how the bit order gets flipped.
public struct AVCDecoderConfigurationRecord: Sendable, Hashable {

    // MARK: - Stored Properties

    /// `AVCProfileIndication` — SPS NAL byte 1.
    public var avcProfileIndication: UInt8

    /// `profile_compatibility` — SPS NAL byte 2, the packed `constraint_setN_flag` byte.
    public var profileCompatibility: UInt8

    /// `AVCLevelIndication` — SPS NAL byte 3.
    public var avcLevelIndication: UInt8

    /// Always 3. Any other value on parse throws `.unsupportedLengthSize`.
    public var lengthSizeMinusOne: UInt8

    /// SPS NAL units, each with its 1-byte header, escaped, no start code or length prefix.
    public var sequenceParameterSets: [Data]

    /// PPS NAL units, in the same canonical form.
    public var pictureParameterSets: [Data]

    /// `chroma_format` from the trailing extension; `nil` when the record carries no extension.
    public var chromaFormat: UInt8?

    /// `bit_depth_luma_minus8` from the trailing extension.
    public var bitDepthLumaMinus8: UInt8?

    /// `bit_depth_chroma_minus8` from the trailing extension.
    public var bitDepthChromaMinus8: UInt8?

    /// SPS-extension NAL units (type 13). Stored and re-emitted, never parsed.
    public var sequenceParameterSetExt: [Data]

    // MARK: - Bounds

    /// A parameter-set array field is 16 bits wide, so a longer set cannot be expressed. The §4
    /// cap of 4096 bytes for a parameter set is the tighter, security-relevant bound.
    private static let maxParameterSetBytes = 4096

    /// `numOfSequenceParameterSets` is a 5-bit field; the §4 policy cap is 8 sets per type.
    private static let maxParameterSetCount = 8

    /// The ISO profile set that carries the trailing extension. **Not** the SPS chroma-extension
    /// set: 144 appears here and 244 does not, a historical artefact of the ISO text that predates
    /// the renumbering of High 4:4:4 to 244. Mixing the two lists up is the classic `avcC` bug.
    private static let extensionProfiles: Set<UInt8> = [100, 110, 122, 144]

    // MARK: - Initialisation

    /// Builds a record from parameter-set bytes.
    ///
    /// The first SPS is parsed to recover `chroma_format` and the bit depths for the trailing
    /// extension. A parse failure is **not** fatal: the extension then defaults to 4:2:0 8-bit,
    /// which is what every stream that reaches this path actually is, and the parameter sets — the
    /// only part a decoder needs — are still emitted.
    ///
    /// - Parameters:
    ///   - sps: at least one SPS, each 4…4096 bytes, in canonical form (§2.1).
    ///   - pps: zero or more PPS NAL units. An empty list is legal in the record format, though not
    ///     useful to a decoder.
    ///   - spsExt: SPS-extension NAL units, emitted only when the profile carries the extension.
    /// - Throws: `.emptyNALUnit` when `sps` is empty or an SPS is shorter than its four header
    ///   bytes, and `.tooLarge` when a set exceeds 4096 bytes or there are more than eight of them.
    public init(sps: [Data], pps: [Data], spsExt: [Data] = []) throws(BitstreamError) {
        guard let first = sps.first else { throw BitstreamError.emptyNALUnit }
        guard first.count >= 4 else { throw BitstreamError.emptyNALUnit }
        try AVCDecoderConfigurationRecord.validate(sps)
        try AVCDecoderConfigurationRecord.validate(pps)
        try AVCDecoderConfigurationRecord.validate(spsExt)

        let bytes = [UInt8](first)
        self.avcProfileIndication = bytes[1]
        self.profileCompatibility = bytes[2]
        self.avcLevelIndication = bytes[3]
        self.lengthSizeMinusOne = 3
        self.sequenceParameterSets = sps
        self.pictureParameterSets = pps
        self.sequenceParameterSetExt = spsExt

        if AVCDecoderConfigurationRecord.extensionProfiles.contains(bytes[1]) {
            let parsed = try? withNALPointer(bytes) { (raw) throws(BitstreamError) -> H264SPS in
                try H264Parser.parseSPS(raw)
            }
            self.chromaFormat = parsed.map { $0.chromaFormatIDC } ?? 1
            self.bitDepthLumaMinus8 = parsed.map { UInt8(clamping: $0.bitDepthLuma - 8) } ?? 0
            self.bitDepthChromaMinus8 = parsed.map { UInt8(clamping: $0.bitDepthChroma - 8) } ?? 0
        } else {
            self.chromaFormat = nil
            self.bitDepthLumaMinus8 = nil
            self.bitDepthChromaMinus8 = nil
        }
    }

    /// Builds a record from already-known field values, for tests and for a caller reconstructing
    /// one from a container. Nothing is validated.
    public init(avcProfileIndication: UInt8, profileCompatibility: UInt8, avcLevelIndication: UInt8,
                sequenceParameterSets: [Data], pictureParameterSets: [Data],
                chromaFormat: UInt8? = nil, bitDepthLumaMinus8: UInt8? = nil,
                bitDepthChromaMinus8: UInt8? = nil, sequenceParameterSetExt: [Data] = []) {
        self.avcProfileIndication = avcProfileIndication
        self.profileCompatibility = profileCompatibility
        self.avcLevelIndication = avcLevelIndication
        self.lengthSizeMinusOne = 3
        self.sequenceParameterSets = sequenceParameterSets
        self.pictureParameterSets = pictureParameterSets
        self.chromaFormat = chromaFormat
        self.bitDepthLumaMinus8 = bitDepthLumaMinus8
        self.bitDepthChromaMinus8 = bitDepthChromaMinus8
        self.sequenceParameterSetExt = sequenceParameterSetExt
    }

    private static func validate(_ sets: [Data]) throws(BitstreamError) {
        guard sets.count <= maxParameterSetCount else {
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

    /// Emits the record exactly as ISO/IEC 14496-15 §5.3.3.1 defines it.
    ///
    /// The trailing extension is written only for profiles 100, 110, 122 and 144; for anything
    /// else the record ends after the PPS array, which is what every muxer expects for Main and
    /// Baseline. Reserved bit patterns are written as all-ones, as the standard requires.
    public func serialized() -> Data {
        var out = Data()
        out.reserveCapacity(32 + sequenceParameterSets.reduce(0) { $0 + $1.count + 2 }
                              + pictureParameterSets.reduce(0) { $0 + $1.count + 2 })
        out.append(0x01)                                            // configurationVersion
        out.append(avcProfileIndication)
        out.append(profileCompatibility)
        out.append(avcLevelIndication)
        out.append(0xFC | (lengthSizeMinusOne & 0x03))              // 0xFF
        out.append(0xE0 | UInt8(truncatingIfNeeded: sequenceParameterSets.count))
        for set in sequenceParameterSets { AVCDecoderConfigurationRecord.append(set, to: &out) }
        out.append(UInt8(truncatingIfNeeded: pictureParameterSets.count))
        for set in pictureParameterSets { AVCDecoderConfigurationRecord.append(set, to: &out) }

        if AVCDecoderConfigurationRecord.extensionProfiles.contains(avcProfileIndication) {
            out.append(0xFC | ((chromaFormat ?? 1) & 0x03))
            out.append(0xF8 | ((bitDepthLumaMinus8 ?? 0) & 0x07))
            out.append(0xF8 | ((bitDepthChromaMinus8 ?? 0) & 0x07))
            out.append(UInt8(truncatingIfNeeded: sequenceParameterSetExt.count))
            for set in sequenceParameterSetExt {
                AVCDecoderConfigurationRecord.append(set, to: &out)
            }
        }
        return out
    }

    private static func append(_ set: Data, to out: inout Data) {
        out.append(UInt8(truncatingIfNeeded: set.count >> 8))
        out.append(UInt8(truncatingIfNeeded: set.count))
        out.append(contentsOf: set)
    }

    // MARK: - Parsing

    /// Parses an `avcC` record.
    ///
    /// Recovery is deliberately generous after the mandatory header: a truncated array terminates
    /// the parse and whatever parameter sets were read in full are kept, because the SPS and PPS we
    /// already recovered are what a decoder needs and a partially written record is still useful.
    /// The trailing extension is read whenever at least four bytes remain, regardless of profile —
    /// some muxers omit it for High and others emit it for Main.
    ///
    /// - Throws: `.emptyNALUnit` when the record is shorter than its 7-byte fixed header,
    ///   `.unsupportedRecordVersion` for a `configurationVersion` other than 1, and
    ///   `.unsupportedLengthSize` for a `lengthSizeMinusOne` other than 3.
    public init(parsing data: Data) throws(BitstreamError) {
        // One copy up front: `Data` slices are not zero-based, and every indexing bug in a record
        // parser written directly against `Data` comes from forgetting that.
        let bytes = [UInt8](data)
        guard bytes.count >= 7 else { throw BitstreamError.emptyNALUnit }
        guard bytes[0] == 1 else { throw BitstreamError.unsupportedRecordVersion(bytes[0]) }
        let lengthSize = bytes[4] & 0x03
        guard lengthSize == 3 else { throw BitstreamError.unsupportedLengthSize(lengthSize) }

        self.avcProfileIndication = bytes[1]
        self.profileCompatibility = bytes[2]
        self.avcLevelIndication = bytes[3]
        self.lengthSizeMinusOne = 3

        var cursor = 5
        let spsCount = Int(bytes[cursor] & 0x1F)
        cursor += 1
        self.sequenceParameterSets = AVCDecoderConfigurationRecord.readSets(bytes, &cursor,
                                                                            count: spsCount)
        var ppsCount = 0
        if cursor < bytes.count {
            ppsCount = Int(bytes[cursor])
            cursor += 1
        }
        self.pictureParameterSets = AVCDecoderConfigurationRecord.readSets(bytes, &cursor,
                                                                           count: ppsCount)

        if bytes.count - cursor >= 4 {
            self.chromaFormat = bytes[cursor] & 0x03
            self.bitDepthLumaMinus8 = bytes[cursor + 1] & 0x07
            self.bitDepthChromaMinus8 = bytes[cursor + 2] & 0x07
            let extCount = Int(bytes[cursor + 3])
            cursor += 4
            self.sequenceParameterSetExt = AVCDecoderConfigurationRecord.readSets(bytes, &cursor,
                                                                                   count: extCount)
        } else {
            self.chromaFormat = nil
            self.bitDepthLumaMinus8 = nil
            self.bitDepthChromaMinus8 = nil
            self.sequenceParameterSetExt = []
        }
    }

    /// Reads up to `count` length-prefixed NAL units, stopping early and silently at the first one
    /// that does not fit. A lying count therefore truncates the result instead of throwing.
    private static func readSets(_ bytes: [UInt8], _ cursor: inout Int, count: Int) -> [Data] {
        var out = [Data]()
        out.reserveCapacity(min(count, maxParameterSetCount))
        for _ in 0 ..< count {
            guard cursor + 2 <= bytes.count else { return out }
            let length = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
            guard length > 0, cursor + 2 + length <= bytes.count else { return out }
            out.append(Data(bytes[(cursor + 2) ..< (cursor + 2 + length)]))
            cursor += 2 + length
        }
        return out
    }

    // MARK: - Public API

    /// The parameter sets in Vigil's canonical form, ready for the store or for CoreMedia.
    /// SPS-extension NAL units are not included: they are an `avcC` concern only.
    public var parameterSets: ParameterSets {
        ParameterSets(codec: .h264, sps: sequenceParameterSets, pps: pictureParameterSets)
    }
}

// MARK: - Typed-throws pointer bridge

/// Runs `body` over `bytes` as a raw buffer while preserving typed throws. `withUnsafeBytes` is
/// `rethrows`, which would erase `BitstreamError` to `any Error`.
private func withNALPointer<T>(
    _ bytes: [UInt8],
    _ body: (UnsafeRawBufferPointer) throws(BitstreamError) -> T
) throws(BitstreamError) -> T {
    var outcome: Result<T, BitstreamError>?
    bytes.withUnsafeBytes { raw in
        do {
            outcome = .success(try body(raw))
        } catch {
            outcome = .failure(error)
        }
    }
    switch outcome {
    case .success(let value): return value
    case .failure(let error): throw error
    case nil: throw BitstreamError.emptyNALUnit   // unreachable: the closure always runs
    }
}
