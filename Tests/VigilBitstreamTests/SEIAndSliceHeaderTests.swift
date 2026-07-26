//
//  SEIAndSliceHeaderTests.swift
//  VigilBitstreamTests
//
//  SEI enumeration and the two messages Vigil acts on, plus the first-slice-of-picture predicate
//  that `VigilRTP` calls once per NAL. Covers docs/spec-bitstream.md §19 and §20.1, including the
//  verified `recovery_point` vectors and T-SL-1.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilBitstream

// MARK: - SEI

@Suite struct SEIEnumerationTests {

    /// §19.3, verified vector: H.264 SEI NAL, one `recovery_point` message of one byte.
    private static let h264RecoveryPointNAL: [UInt8] = [0x06, 0x06, 0x01, 0xC4, 0x80]
    /// §19.3, verified vector: H.265 prefix SEI NAL with the same message.
    private static let h265RecoveryPointNAL: [UInt8] = [0x4E, 0x01, 0x06, 0x01, 0xD0, 0x80]

    @Test func seiEnumerateYieldsTypeAndPayloadForH264() throws {
        var seen = [(Int, [UInt8])]()
        try Self.h264RecoveryPointNAL.withUnsafeBytes { raw in
            try SEI.enumerate(nalUnit: raw, codec: .h264) { type, payload in
                seen.append((type, Array(payload)))
            }
        }
        #expect(seen.count == 1)
        #expect(seen.first?.0 == 6)
        #expect(seen.first?.1 == [0xC4])
    }

    @Test func seiParsesTheH264RecoveryPointVector() throws {
        let point = try SEI.parseRecoveryPoint([0xC4], codec: .h264)
        #expect(point.recoveryCount == 0)
        #expect(point.exactMatch)
        #expect(!point.brokenLink)
        #expect(point.changingSliceGroupIDC == 0)
    }

    @Test func seiParsesTheH265RecoveryPointVector() throws {
        // The payload byte differs from H.264's purely because `recovery_poc_cnt` is se(v) and
        // there is no `changing_slice_group_idc`: D0 = 1 1 0 then alignment.
        let point = try SEI.parseRecoveryPoint([0xD0], codec: .h265)
        #expect(point.recoveryCount == 0)
        #expect(point.exactMatch)
        #expect(!point.brokenLink)
        #expect(point.changingSliceGroupIDC == 0)
    }

    @Test func seiFirstRecoveryPointFindsTheMessageInBothCodecs() {
        let h264 = Self.h264RecoveryPointNAL.withUnsafeBytes {
            SEI.firstRecoveryPoint(nalUnit: $0, codec: .h264)
        }
        #expect(h264?.exactMatch == true)
        let h265 = Self.h265RecoveryPointNAL.withUnsafeBytes {
            SEI.firstRecoveryPoint(nalUnit: $0, codec: .h265)
        }
        #expect(h265?.exactMatch == true)
    }

    @Test func seiEnumerateSkipsUnknownMessagesByTheirDeclaredSize() throws {
        // A Hikvision-style user_data_unregistered (type 5, 16 bytes of UUID) followed by the
        // recovery_point we actually care about. Advancing by payloadSize is what keeps the second
        // message reachable.
        var nal: [UInt8] = [0x06, 0x05, 0x10]
        nal.append(contentsOf: [UInt8](repeating: 0xAA, count: 16))
        nal.append(contentsOf: [0x06, 0x01, 0xC4, 0x80])
        var types = [Int]()
        try nal.withUnsafeBytes { raw in
            try SEI.enumerate(nalUnit: raw, codec: .h264) { type, _ in types.append(type) }
        }
        #expect(types == [5, 6])
    }

    @Test func seiEnumerateHandlesTheFFContinuationEncoding() throws {
        // payloadType 260 = 255 + 5, payloadSize 256 = 255 + 1.
        var nal: [UInt8] = [0x06, 0xFF, 0x05, 0xFF, 0x01]
        nal.append(contentsOf: [UInt8](repeating: 0x11, count: 256))
        nal.append(0x80)
        var seen = [(Int, Int)]()
        try nal.withUnsafeBytes { raw in
            try SEI.enumerate(nalUnit: raw, codec: .h264) { type, payload in
                seen.append((type, payload.count))
            }
        }
        #expect(seen.count == 1)
        #expect(seen.first?.0 == 260)
        #expect(seen.first?.1 == 256)
    }

    @Test func seiEnumerateThrowsOnADeclaredSizeBeyondTheNAL() {
        let nal: [UInt8] = [0x06, 0x06, 0x20, 0x01, 0x02]      // claims 32 bytes, carries 2
        #expect(throws: BitstreamError.truncatedSEI) {
            try nal.withUnsafeBytes { raw in
                try SEI.enumerate(nalUnit: raw, codec: .h264) { _, _ in }
            }
        }
    }

    @Test func seiEnumerateSurvivesEveryTruncation() {
        var nal: [UInt8] = [0x06, 0x05, 0x10]
        nal.append(contentsOf: [UInt8](repeating: 0xAA, count: 16))
        nal.append(contentsOf: [0x06, 0x01, 0xC4, 0x80])
        for length in 0 ... nal.count {
            let prefix = Array(nal.prefix(length))
            prefix.withUnsafeBytes { raw in
                try? SEI.enumerate(nalUnit: raw, codec: .h264) { _, _ in }
            }
        }
    }

    @Test func seiRejectsAnOversizedSEINAL() {
        let huge = [UInt8](repeating: 0x00, count: 65_537)
        #expect(throws: BitstreamError.tooLarge(bytes: 65_537)) {
            try huge.withUnsafeBytes { raw in
                try SEI.enumerate(nalUnit: raw, codec: .h264) { _, _ in }
            }
        }
    }

    @Test func seiPictureTimingReadsPicStructOnlyWhenTheSPSSaysItIsPresent() throws {
        var sps = H264SPS()
        sps.picStructPresentFlag = false
        #expect(try SEI.parsePictureTiming([0x30], sps: sps).picStruct == 0)

        sps.picStructPresentFlag = true
        // 0x30 = 0011 0000 -> pic_struct = 3 (top field then bottom field).
        let timing = try SEI.parsePictureTiming([0x30], sps: sps)
        #expect(timing.picStruct == 3)
        #expect(timing.indicatesInterlaced)
    }

    @Test func seiPictureTimingSkipsTheHRDDelaysWithTheSPSWidths() throws {
        // The widths come from the SPS's HRD, not from a constant: 8 + 8 bits of delay, then
        // pic_struct = 1 in the top nibble of the third byte.
        var sps = H264SPS()
        sps.cpbDpbDelaysPresentFlag = true
        sps.cpbRemovalDelayLength = 8
        sps.dpbOutputDelayLength = 8
        sps.picStructPresentFlag = true
        let timing = try SEI.parsePictureTiming([0xFF, 0xFF, 0x10], sps: sps)
        #expect(timing.picStruct == 1)
    }
}

// MARK: - SliceHeader

@Suite struct SliceHeaderPredicateTests {

    @Test func sliceHeaderDetectsTheFirstSliceOfAnH264Picture() {
        // T-SL-1. `first_mb_in_slice` is the first ue(v), so ue(0) is a leading 1 bit.
        // first_mb_in_slice = 0  -> "1"      -> 0x88
        // first_mb_in_slice = 1  -> "010"    -> 0x40…
        // first_mb_in_slice = 99 -> six zeros then a 1 -> 0x03…
        let first: [UInt8] = [0x65, 0x88, 0x84]
        let second: [UInt8] = [0x41, 0x44, 0x00]
        let ninetyNinth: [UInt8] = [0x41, 0x03, 0x21]
        #expect(first.withUnsafeBytes {
            SliceHeader.isFirstSliceOfPicture(nalUnit: $0, codec: .h264)
        })
        #expect(!second.withUnsafeBytes {
            SliceHeader.isFirstSliceOfPicture(nalUnit: $0, codec: .h264)
        })
        #expect(!ninetyNinth.withUnsafeBytes {
            SliceHeader.isFirstSliceOfPicture(nalUnit: $0, codec: .h264)
        })
    }

    @Test func sliceHeaderDetectsTheFirstSliceSegmentOfAnH265Picture() {
        // `first_slice_segment_in_pic_flag` is literally the first RBSP bit, after two header bytes.
        let first: [UInt8] = [0x26, 0x01, 0xAF, 0x00]
        let continuation: [UInt8] = [0x26, 0x01, 0x2F, 0x00]
        #expect(first.withUnsafeBytes {
            SliceHeader.isFirstSliceOfPicture(nalUnit: $0, codec: .h265)
        })
        #expect(!continuation.withUnsafeBytes {
            SliceHeader.isFirstSliceOfPicture(nalUnit: $0, codec: .h265)
        })
    }

    @Test func sliceHeaderReturnsFalseForANALWithNoPayload() {
        let h264Stub: [UInt8] = [0x65]
        let h265Stub: [UInt8] = [0x26, 0x01]
        let empty: [UInt8] = []
        #expect(!h264Stub.withUnsafeBytes {
            SliceHeader.isFirstSliceOfPicture(nalUnit: $0, codec: .h264)
        })
        #expect(!h265Stub.withUnsafeBytes {
            SliceHeader.isFirstSliceOfPicture(nalUnit: $0, codec: .h265)
        })
        #expect(!empty.withUnsafeBytes {
            SliceHeader.isFirstSliceOfPicture(nalUnit: $0, codec: .h264)
        })
    }

    @Test func sliceHeaderReadsTheH264SliceType() {
        // first_mb_in_slice = 0 ("1"), slice_type = 7 (ue(7) = "0001000") -> 0b1000_1000 = 0x88.
        let idr: [UInt8] = [0x65, 0x88]
        #expect(idr.withUnsafeBytes { SliceHeader.sliceType(nalUnit: $0, codec: .h264) } == 7)
        #expect(SliceHeader.isIntraSliceType(7))
        #expect(!SliceHeader.isIntraSliceType(5))
        // H.265's slice type sits behind the PPS id and the extra slice-header bits, so it is not
        // cheaply available and must be reported as unknown rather than guessed.
        let hevc: [UInt8] = [0x26, 0x01, 0x80, 0x00]
        #expect(hevc.withUnsafeBytes { SliceHeader.sliceType(nalUnit: $0, codec: .h265) } == nil)
    }

    @Test func sliceHeaderSliceTypeReturnsNilRatherThanCrashingOnJunk() {
        for byte in UInt8.min ... UInt8.max {
            let nal: [UInt8] = [0x65, byte]
            _ = nal.withUnsafeBytes { SliceHeader.sliceType(nalUnit: $0, codec: .h264) }
        }
        let stub: [UInt8] = [0x65]
        #expect(stub.withUnsafeBytes { SliceHeader.sliceType(nalUnit: $0, codec: .h264) } == nil)
    }
}
