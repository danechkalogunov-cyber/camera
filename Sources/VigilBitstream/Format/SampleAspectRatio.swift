//
//  SampleAspectRatio.swift
//  VigilBitstream
//
//  ITU-T H.264 Table E-1 / H.265 Table E-1 (identical): `aspect_ratio_idc` to a sample aspect ratio.
//  See docs/spec-bitstream.md §8.5 and docs/API_CONTRACT.md §4.2.
//

// MARK: - SampleAspectRatio

/// The `aspect_ratio_idc` table shared by both codecs.
///
/// **The sanity rule is binding:** if either component is zero, if `aspect_ratio_info_present_flag`
/// is 0, or if the idc is one of the reserved values 17…254, the SAR is **1:1**. Hikvision routinely
/// omits the SAR entirely on substreams, so 1:1 is the common case and must never become a divide
/// by zero or a NaN in a layout calculation.
public enum SampleAspectRatio {

    /// `aspect_ratio_idc` → `(sarWidth, sarHeight)`.
    ///
    /// idc 0 is *Unspecified* and idc 255 is *Extended_SAR*, whose two 16-bit components are read
    /// from the bitstream; neither has an entry, and both are handled by the parser. 17…254 are
    /// reserved and also absent, so a lookup miss always means "substitute 1:1".
    public static let table: [UInt8: (Int, Int)] = [
        1: (1, 1), 2: (12, 11), 3: (10, 11), 4: (16, 11),
        5: (40, 33), 6: (24, 11), 7: (20, 11), 8: (32, 11),
        9: (80, 33), 10: (18, 11), 11: (15, 11), 12: (64, 33),
        13: (160, 99), 14: (4, 3), 15: (3, 2), 16: (2, 1),
    ]

    /// The `aspect_ratio_idc` value that means "the two components follow in the bitstream".
    public static let extendedSAR: UInt8 = 255

    /// The ratio for `idc`, or `nil` when the idc is unspecified, reserved, or Extended_SAR.
    ///
    /// Callers substitute 1:1 for `nil`; the distinction is kept so `H264SPS.aspectRatioIDC` can
    /// record what the stream actually said.
    public static func ratio(for idc: UInt8) -> (width: Int, height: Int)? {
        guard let entry = table[idc] else { return nil }
        return (entry.0, entry.1)
    }

    /// Applies the sanity rule: a non-positive component in either place becomes 1:1.
    ///
    /// Used wherever a SAR reaches geometry, because `sar_height == 0` is expressible in a VUI and
    /// an infinite pixel aspect ratio would poison every layout calculation downstream.
    public static func sanitised(width: Int, height: Int) -> (width: Int, height: Int) {
        (width > 0 && height > 0) ? (width, height) : (1, 1)
    }
}
