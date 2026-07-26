//
//  DepacketizerFixtures.swift
//  VigilRTPTests
//
//  Packet and NAL builders shared by the depacketizer suites. Every byte pattern here is
//  synthesised for the test unless a comment cites docs/spec-rtp.md §15; nothing in this file came
//  off real hardware.
//

import Foundation

import VigilProtocols
@testable import VigilRTP

// MARK: - DepacketizerFixture

/// Builders for RTP packets and NAL units. A namespace, never instantiated.
enum DepacketizerFixture {

    /// The dynamic payload type Hikvision uses for video.
    static let videoPayloadType: UInt8 = 96

    /// 90 kHz ticks in one frame at 25 fps.
    static let frameInterval: UInt32 = 3600

    /// Arrival instant `milliseconds` after the start of the test.
    static func instant(_ milliseconds: Int) -> MediaInstant {
        MediaInstant(nanoseconds: Int64(milliseconds) * 1_000_000)
    }

    /// Builds one RTP packet around a payload.
    static func packet(_ payload: [UInt8], sequence: UInt16, timestamp: UInt32,
                       marker: Bool = false,
                       payloadType: UInt8 = videoPayloadType) -> RTPPacket {
        RTPPacket(marker: marker, payloadType: payloadType, sequenceNumber: sequence,
                  timestamp: timestamp, ssrc: 0x1234_5678, payload: Data(payload))
    }

    // MARK: - H.264

    /// An H.264 slice NAL unit.
    ///
    /// - Parameters:
    ///   - type: `nal_unit_type`; 5 for IDR, 1 for a non-IDR slice.
    ///   - nri: `nal_ref_idc`. Zero marks the slice non-reference.
    ///   - firstMacroblock: when true the first RBSP byte has its top bit set, which is exactly
    ///     `first_mb_in_slice == 0`; when false the slice starts partway into the picture.
    ///   - body: bytes appended after the first RBSP byte, to make each slice distinguishable.
    static func h264Slice(type: UInt8, nri: UInt8 = 3, firstMacroblock: Bool,
                          body: [UInt8] = [0x11, 0x22]) -> [UInt8] {
        [(nri << 5) | type, firstMacroblock ? 0x88 : 0x0A] + body
    }

    /// Splits `nal` into FU-A packets of at most `chunk` payload bytes each.
    static func h264FragmentUnits(_ nal: [UInt8], chunk: Int) -> [[UInt8]] {
        guard let header = nal.first, nal.count > 1 else { return [] }
        let indicator = (header & 0xE0) | 28
        let type = header & 0x1F
        let body = Array(nal.dropFirst())
        var packets: [[UInt8]] = []
        var offset = 0
        while offset < body.count {
            let end = min(offset + chunk, body.count)
            let isStart = offset == 0
            let isEnd = end == body.count
            var fuHeader = type
            if isStart { fuHeader |= 0x80 }
            if isEnd { fuHeader |= 0x40 }
            packets.append([indicator, fuHeader] + Array(body[offset..<end]))
            offset = end
        }
        return packets
    }

    /// A STAP-A payload carrying `nals` in order.
    static func h264STAPA(_ nals: [[UInt8]]) -> [UInt8] {
        var payload: [UInt8] = [0x78]                    // F 0, NRI 3, type 24
        for nal in nals {
            payload.append(UInt8(truncatingIfNeeded: nal.count >> 8))
            payload.append(UInt8(truncatingIfNeeded: nal.count))
            payload += nal
        }
        return payload
    }

    /// The SPS from docs/spec-rtp.md §15.2.
    static let h264SPS: [UInt8] = [0x67, 0x4D, 0x00, 0x29, 0x95, 0xA8, 0x1E, 0x00, 0x89, 0xF9]

    /// The PPS from docs/spec-rtp.md §15.2.
    static let h264PPS: [UInt8] = [0x68, 0xEE, 0x3C, 0xB0]

    // MARK: - H.265

    /// An H.265 slice NAL unit.
    ///
    /// - Parameters:
    ///   - type: `nal_unit_type`; 19 is IDR_W_RADL, 1 is TRAIL_R, 8 and 9 are RASL.
    ///   - temporalID: `nuh_temporal_id_plus1`, which must be at least 1.
    ///   - firstSlice: sets `first_slice_segment_in_pic_flag`, the top bit of the third byte.
    ///   - body: bytes appended after that, to make each slice distinguishable.
    static func h265Slice(type: UInt8, temporalID: UInt8 = 1, firstSlice: Bool,
                          body: [UInt8] = [0x33, 0x44]) -> [UInt8] {
        [(type << 1) & 0x7E, temporalID & 0x07, firstSlice ? 0xAF : 0x2F] + body
    }

    /// Splits `nal` into FU packets of at most `chunk` payload bytes each.
    ///
    /// - Parameter donl: when non-`nil`, a DONL is inserted into the start fragment only, which is
    ///   what `sprop-max-don-diff > 0` means on the wire.
    static func h265FragmentUnits(_ nal: [UInt8], chunk: Int, donl: UInt16? = nil) -> [[UInt8]] {
        guard nal.count > 2 else { return [] }
        let type = (nal[0] >> 1) & 0x3F
        let hdr0 = (nal[0] & 0x81) | (49 << 1)
        let hdr1 = nal[1]
        let body = Array(nal.dropFirst(2))
        var packets: [[UInt8]] = []
        var offset = 0
        while offset < body.count {
            let end = min(offset + chunk, body.count)
            let isStart = offset == 0
            let isEnd = end == body.count
            var fuHeader = type
            if isStart { fuHeader |= 0x80 }
            if isEnd { fuHeader |= 0x40 }
            var packet: [UInt8] = [hdr0, hdr1]
            if isStart, let donl {
                packet.append(UInt8(truncatingIfNeeded: donl >> 8))
                packet.append(UInt8(truncatingIfNeeded: donl))
            }
            packet.append(fuHeader)
            packet += Array(body[offset..<end])
            packets.append(packet)
            offset = end
        }
        return packets
    }

    /// The VPS, SPS and PPS from the AP vector in docs/spec-rtp.md §15.4.
    static let h265VPS: [UInt8] = [0x40, 0x01, 0x0C, 0x01, 0xFF, 0xFF]
    static let h265SPS: [UInt8] = [0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03]
    static let h265PPS: [UInt8] = [0x44, 0x01, 0xC1, 0x72]

    // MARK: - Assertions support

    /// Splits a length-prefixed `EncodedFrame.data` back into NAL units.
    ///
    /// Returns `nil` when the buffer is not well-formed, which is itself a useful assertion: the
    /// contract requires 4-byte big-endian prefixes and forbids Annex-B start codes.
    static func splitLengthPrefixed(_ data: Data) -> [[UInt8]]? {
        var nals: [[UInt8]] = []
        var index = data.startIndex
        while index < data.endIndex {
            guard data.endIndex - index >= 4 else { return nil }
            var length = 0
            for offset in 0..<4 { length = length << 8 | Int(data[index + offset]) }
            index += 4
            guard length > 0, data.endIndex - index >= length else { return nil }
            nals.append([UInt8](data[index..<(index + length)]))
            index += length
        }
        return nals
    }

    /// Every `malformed` reason in an event list.
    static func malformedReasons(_ events: [DepacketizerEvent]) -> [MalformedReason] {
        events.compactMap { if case .malformed(let reason) = $0 { reason } else { nil } }
    }

    /// Every `unsupported` feature in an event list.
    static func unsupportedFeatures(_ events: [DepacketizerEvent]) -> [UnsupportedFeature] {
        events.compactMap { if case .unsupported(let feature) = $0 { feature } else { nil } }
    }

    /// Every `parameterSetsChanged` payload in an event list.
    static func parameterSetChanges(_ events: [DepacketizerEvent]) -> [ParameterSets] {
        events.compactMap { if case .parameterSetsChanged(let sets) = $0 { sets } else { nil } }
    }

    /// A configuration with the keyframe gate open, so a test can drive non-IDR pictures directly.
    static let ungatedLive = DepacketizerConfiguration(waitForKeyframeOnStart: false)
}
