//
//  ParameterSets.swift
//  VigilProtocols
//
//  The codec configuration NAL units (VPS/SPS/PPS) for one video stream, in the single canonical
//  storage form the whole app agrees on, plus the FNV-1a fingerprint used to detect a change.
//  Implements docs/API_CONTRACT.md §3.5 and §2 R-53 (sets are attached only when they change).
//

import Foundation

// MARK: - ParameterSets

/// Codec configuration NAL units for one video stream.
///
/// **Canonical storage form — binding, no exceptions.** Every `Data` element is:
/// 1. **With** its NAL header (1 byte H.264, 2 bytes H.265).
/// 2. **Without** any Annex-B start code and **without** any length prefix.
/// 3. In **escaped, on-wire form** — emulation-prevention `0x03` bytes are still present.
/// 4. Byte-identical to what the camera sent, or to what base64-decoding `sprop-parameter-sets`
///    / `sprop-vps` / `sprop-sps` / `sprop-pps` produced.
///
/// This is exactly the form `avcC`, `hvcC` and
/// `CMVideoFormatDescriptionCreateFrom{H264,HEVC}ParameterSets` require. Parsing always unescapes
/// into a throwaway buffer; we never store unescaped RBSP.
///
/// Ordering within each array is ascending parameter-set id. A re-sent set with an id we already
/// hold **replaces** it in place — Hikvision re-sends SPS/PPS before every IDR, usually identical,
/// occasionally changed after a resolution change.
///
/// Every array may legally be empty: an SDP is allowed to omit `sprop-parameter-sets` entirely, in
/// which case the sets arrive in-band before the first IDR and this value is empty until then.
public struct ParameterSets: Sendable, Hashable, Codable {

    // MARK: - Stored Properties

    /// The codec these sets configure. Decides both the NAL header length and `orderedForCoreMedia`.
    public var codec: VideoCodec

    /// H.265 only; always empty for H.264 and MJPEG.
    public var vps: [Data]

    /// Sequence parameter sets, ascending by `seq_parameter_set_id`.
    public var sps: [Data]

    /// Picture parameter sets, ascending by `pic_parameter_set_id`.
    public var pps: [Data]

    // MARK: - Initialisation

    /// Builds a set. Nothing is validated or reordered: a caller that hands over bytes it could not
    /// parse still gets them back byte-identical, which is what R-53's "store and forward anyway"
    /// requires.
    public init(codec: VideoCodec, vps: [Data] = [], sps: [Data] = [], pps: [Data] = []) {
        self.codec = codec
        self.vps = vps
        self.sps = sps
        self.pps = pps
    }

    // MARK: - Computed Properties

    /// True when there are enough bytes to build a format description. VPS is optional for H.264
    /// and required in practice (though not by CoreMedia) for H.265.
    /// - Note: `isComplete` is about *bytes*, not parsability. A parameter set we cannot parse is
    ///   still stored and still forwarded; `VideoFormatInfo == nil` must never block decoding.
    @inlinable public var isComplete: Bool { !sps.isEmpty && !pps.isEmpty }

    /// In the order CoreMedia wants: `[SPS, PPS]` for H.264, `[VPS, SPS, PPS]` for H.265.
    @inlinable public var orderedForCoreMedia: [Data] {
        codec == .h265 ? vps + sps + pps : sps + pps
    }

    /// FNV-1a over every byte, in `orderedForCoreMedia` order. The cheap change detector.
    ///
    /// The codec and the per-set boundaries are deliberately **not** hashed: the fingerprint answers
    /// "did the configuration bytes change on this stream", and a stream's codec cannot change
    /// without the track being torn down. Empty sets fingerprint to the FNV offset basis.
    ///
    /// - Complexity: O(*n*) in the total byte count — a few hundred bytes, computed once per
    ///   parameter-set change, never per frame.
    public var fingerprint: UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01B3
        for set in orderedForCoreMedia {
            for byte in set {
                hash = (hash ^ UInt64(byte)) &* prime  // 64-bit modular by definition of FNV-1a
            }
        }
        return hash
    }
}
