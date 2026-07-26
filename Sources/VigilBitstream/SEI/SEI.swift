//
//  SEI.swift
//  VigilBitstream
//
//  Supplemental enhancement information: the message enumerator, which is identical for H.264 and
//  H.265, plus the two messages Vigil acts on — `recovery_point`, which can open the IRAP gate, and
//  `pic_timing`, from which only `pic_struct` is taken.
//  Implements docs/spec-bitstream.md §19.
//

import VigilProtocols

// MARK: - RecoveryPoint

/// A `recovery_point` SEI message (H.264 §D.2.8, H.265 §D.3.8).
///
/// This is the only way a stream that never sends an IDR can be started: it tells the decoder that
/// pictures from `recoveryCount` onwards will be correct even though decoding began mid-GOP.
public struct RecoveryPoint: Sendable, Hashable {

    /// `recovery_frame_cnt` (H.264, unsigned) or `recovery_poc_cnt` (H.265, signed).
    public var recoveryCount: Int32

    /// `exact_match_flag`. When 0 the recovered pictures may differ slightly from a clean decode;
    /// Vigil's strict policy requires 1 before opening the gate on an SEI alone.
    public var exactMatch: Bool

    /// `broken_link_flag`. When 1 the stream was spliced and pictures before the recovery point
    /// reference frames that do not exist. **Never** open the gate on one of these.
    public var brokenLink: Bool

    /// `changing_slice_group_idc`. H.264 only; 0 for H.265 and for every stream Vigil has seen.
    public var changingSliceGroupIDC: UInt8

    /// Builds a value directly, for tests and for the gate's fixtures.
    public init(recoveryCount: Int32 = 0, exactMatch: Bool = false, brokenLink: Bool = false,
                changingSliceGroupIDC: UInt8 = 0) {
        self.recoveryCount = recoveryCount
        self.exactMatch = exactMatch
        self.brokenLink = brokenLink
        self.changingSliceGroupIDC = changingSliceGroupIDC
    }
}

// MARK: - PictureTiming

/// The one field Vigil takes from a `pic_timing` SEI message.
public struct PictureTiming: Sendable, Hashable {

    /// `pic_struct`: 0 frame, 1 top field, 2 bottom field, 3/4 interlaced frame, 5/6 interlaced
    /// with repeat, 7 frame doubling, 8 frame tripling (H.264 Table D-1).
    ///
    /// Used to set `isProgressive` when `frame_mbs_only_flag` is 0, and for the diagnostics HUD.
    /// **Never** used to compute presentation times: live timing is RTP, recorded timing is the
    /// container's.
    public var picStruct: UInt8

    /// Builds a value directly.
    public init(picStruct: UInt8 = 0) { self.picStruct = picStruct }

    /// True for the `pic_struct` values that denote a field or an interlaced frame (1…6).
    @inlinable public var indicatesInterlaced: Bool { (1 ... 6).contains(picStruct) }
}

// MARK: - SEI

/// The SEI enumerator and the two message parsers. A namespace, never instantiated.
public enum SEI {

    /// Payload types Vigil recognises. Everything else is skipped by its declared size.
    public enum PayloadType {

        /// `buffering_period`.
        public static let bufferingPeriod = 0

        /// `pic_timing` — `pic_struct` only.
        public static let picTiming = 1

        /// `user_data_unregistered`. **Hikvision's private per-frame metadata.** Deliberately
        /// ignored: RTCP SR/NTP mapping in `VigilRTP` is the authoritative wall clock, and trusting
        /// a vendor SEI would create a second, conflicting time base.
        public static let userDataUnregistered = 5

        /// `recovery_point` — can open the IRAP gate (§20.2).
        public static let recoveryPoint = 6

        /// `mastering_display_colour_volume`, H.265 only. Forwarded for HDR metadata.
        public static let masteringDisplayColourVolume = 137

        /// `content_light_level_info`, H.265 only.
        public static let contentLightLevelInfo = 144
    }

    /// The §4 cap on an SEI NAL. Larger ones are refused before anything is copied.
    private static let maxSEIBytes = 65_536

    // MARK: - Enumeration

    /// Enumerates the SEI messages in one SEI NAL unit.
    ///
    /// Both `payloadType` and `payloadSize` use the `0xFF`-continuation encoding, and the payload
    /// is byte-aligned and occupies exactly `payloadSize` bytes. That is what makes this robust:
    /// even for a message we do not understand we advance exactly `payloadSize` bytes and carry on,
    /// so one unknown vendor message cannot hide the `recovery_point` behind it.
    ///
    /// `payload` is the **unescaped** payload, valid only for the duration of the call.
    ///
    /// - Parameters:
    ///   - nalUnit: the SEI NAL including its header (type 6 for H.264, 39/40 for H.265).
    ///   - codec: decides the NAL header length only.
    ///   - body: receives `(payloadType, payload)` for each message, in bitstream order.
    /// - Throws: `.tooLarge` above 64 KiB, `.truncatedSEI` when a declared size runs past the end
    ///   of the NAL, and whatever `body` throws.
    public static func enumerate(
        nalUnit: UnsafeRawBufferPointer, codec: VideoCodec,
        _ body: (Int, ArraySlice<UInt8>) throws(BitstreamError) -> Void
    ) throws(BitstreamError) {
        guard nalUnit.count <= maxSEIBytes else {
            throw BitstreamError.tooLarge(bytes: nalUnit.count)
        }
        let rbsp = try RBSP.unescape(nalUnit, skippingHeaderBytes: codec.nalHeaderLength)
        var index = 0
        while index < rbsp.count {
            var payloadType = 0
            while index < rbsp.count, rbsp[index] == 0xFF {
                payloadType += 255
                index += 1
            }
            guard index < rbsp.count else { return }        // ran into rbsp_trailing_bits
            payloadType += Int(rbsp[index])
            index += 1

            var payloadSize = 0
            while index < rbsp.count, rbsp[index] == 0xFF {
                payloadSize += 255
                index += 1
            }
            guard index < rbsp.count else { throw BitstreamError.truncatedSEI }
            payloadSize += Int(rbsp[index])
            index += 1

            guard payloadSize >= 0, index + payloadSize <= rbsp.count else {
                throw BitstreamError.truncatedSEI
            }
            try body(payloadType, rbsp[index ..< (index + payloadSize)])
            index += payloadSize

            // A lone trailing 0x80 is `rbsp_trailing_bits()`, not a `buffering_period` message of
            // size 0 followed by garbage. Stopping here is what keeps the enumerator from
            // reporting a spurious final message on every conforming SEI NAL.
            if index == rbsp.count - 1, rbsp[index] == 0x80 { return }
        }
    }

    // MARK: - recovery_point

    /// Parses a `recovery_point` payload.
    ///
    /// The two codecs differ in the first field — H.264 codes `recovery_frame_cnt` as `ue(v)` and
    /// H.265 codes `recovery_poc_cnt` as `se(v)` — and H.264 has two extra bits of
    /// `changing_slice_group_idc`. Passing the wrong codec yields a value that parses without
    /// error and is wrong, which is why the codec is a required argument rather than inferred.
    ///
    /// - Parameter payload: the already-unescaped payload from `enumerate`.
    /// - Throws: `.unexpectedEndOfData` when the payload is shorter than the message.
    public static func parseRecoveryPoint(
        _ payload: ArraySlice<UInt8>, codec: VideoCodec
    ) throws(BitstreamError) -> RecoveryPoint {
        var r = try RBSPBitReader(rbsp: Array(payload))
        switch codec {
        case .h264:
            let count = try r.ue("recovery_frame_cnt", max: 65_535)
            return RecoveryPoint(recoveryCount: Int32(clamping: count),
                                 exactMatch: try r.flag(),
                                 brokenLink: try r.flag(),
                                 changingSliceGroupIDC: UInt8(truncatingIfNeeded: try r.u(2)))
        case .h265:
            let count = try r.se()
            return RecoveryPoint(recoveryCount: count,
                                 exactMatch: try r.flag(),
                                 brokenLink: try r.flag(),
                                 changingSliceGroupIDC: 0)
        case .mjpeg:
            throw BitstreamError.unsupportedSyntax("recovery_point is not an MJPEG concept")
        }
    }

    // MARK: - pic_timing

    /// Parses a `pic_timing` payload as far as `pic_struct`, and no further.
    ///
    /// `pic_timing` is context-dependent: its leading delay fields exist only when the active SPS
    /// had `CpbDpbDelaysPresentFlag`, and their **widths come from that SPS's HRD**. That is the
    /// whole reason `H264SPS` retains `cpbRemovalDelayLength` and `dpbOutputDelayLength`; guessing
    /// 24 bits for a stream that coded 5 would read `pic_struct` out of the middle of a delay.
    ///
    /// The `clock_timestamp` loop after `pic_struct` is never parsed.
    ///
    /// - Returns: the parsed value, or `pic_struct == 0` when the SPS says the field is absent.
    /// - Throws: `.unexpectedEndOfData` when the payload is shorter than the SPS implies.
    public static func parsePictureTiming(
        _ payload: ArraySlice<UInt8>, sps: H264SPS
    ) throws(BitstreamError) -> PictureTiming {
        var r = try RBSPBitReader(rbsp: Array(payload))
        if sps.cpbDpbDelaysPresentFlag {
            try r.skip(sps.cpbRemovalDelayLength)           // cpb_removal_delay
            try r.skip(sps.dpbOutputDelayLength)            // dpb_output_delay
        }
        guard sps.picStructPresentFlag else { return PictureTiming(picStruct: 0) }
        return PictureTiming(picStruct: UInt8(truncatingIfNeeded: try r.u(4)))
    }

    // MARK: - Convenience

    /// Returns the first `recovery_point` message in an SEI NAL unit, or `nil`.
    ///
    /// Malformed messages are swallowed and reported as `nil`: an SEI we cannot read must never
    /// prevent a picture from being decoded, and the only consequence is that the IRAP gate waits
    /// for a real IRAP instead of opening early.
    public static func firstRecoveryPoint(
        nalUnit: UnsafeRawBufferPointer, codec: VideoCodec
    ) -> RecoveryPoint? {
        var found: RecoveryPoint?
        try? enumerate(nalUnit: nalUnit, codec: codec) { (type, payload) in
            guard found == nil, type == PayloadType.recoveryPoint else { return }
            found = try? parseRecoveryPoint(payload, codec: codec)
        }
        return found
    }
}
