//
//  GroundTruth.swift
//  VigilTestKit
//
//  What the synthetic camera *intended* to send: the oracle every pipeline assertion compares
//  against. Recorded as the stream is generated, before any fault injection reaches the wire, so a
//  test can distinguish "the client lost it" from "the camera never sent it".
//  Implements docs/ARCHITECTURE.md §10.2 (`GroundTruth`, `ExpectedFrame`).
//

import Foundation
import VigilProtocols

// MARK: - CRC-32

/// The CRC-32 of ISO 3309 / ITU-T V.42 (the "zlib" polynomial, reflected 0xEDB88320).
///
/// Used only to fingerprint generated access units so a test can say *which* frame differs rather
/// than only that some frame does. Not a security primitive and never used as one.
public enum CRC32: Sendable {

    /// The reflected polynomial table, built once.
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
            return value
        }
    }()

    /// CRC-32 over `bytes`. The empty input hashes to 0, which is the standard result.
    public static func checksum(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        // The table is a constant 256 entries and the index is masked to a byte, so the subscript
        // cannot go out of range; taking the buffer pointer removes the bounds check per byte.
        crc = Self.table.withUnsafeBufferPointer { entries in
            var running = crc
            for byte in bytes {
                running = (running >> 8) ^ entries[Int((running ^ UInt32(byte)) & 0xFF)]
            }
            return running
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Expected frame

/// One access unit as generated, before it met the network.
public struct ExpectedFrame: Sendable, Hashable {

    /// Zero-based index in the generated stream.
    public var index: Int

    /// The 32-bit RTP timestamp the packets carry.
    public var rtpTimestamp: UInt32

    /// Presentation time relative to the first generated access unit, at 90 kHz. Unwrapped, so it
    /// keeps increasing across a 2³² RTP timestamp rollover.
    public var pts: MediaTimestamp

    /// `true` when the access unit starts with an IDR (H.264) or IRAP (H.265) slice.
    public var isKeyframe: Bool

    /// NAL type codes in decode order, parameter sets included when they were sent in band.
    public var nalTypes: [UInt8]

    /// Byte count of the length-prefixed access unit including every NAL, parameter sets included.
    public var byteCount: Int

    /// Byte count of the length-prefixed access unit counting coded slices only.
    public var sliceByteCount: Int

    /// CRC-32 of the length-prefixed access unit including every NAL.
    public var checksumIncludingParameterSets: UInt32

    /// CRC-32 of the length-prefixed access unit counting coded slices only.
    ///
    /// Two checksums exist because a depacketizer may legitimately either carry the in-band
    /// parameter sets inside the access unit or strip them and attach them to the frame. A test
    /// asserts against whichever the implementation under test documents; ``matches(_:)`` accepts
    /// either, so a checksum assertion never fails merely over that choice.
    public var checksumSlicesOnly: UInt32

    /// `true` when `data` is the length-prefixed form of this access unit under either convention.
    public func matches(_ data: Data) -> Bool {
        let crc = CRC32.checksum(data)
        return crc == checksumIncludingParameterSets || crc == checksumSlicesOnly
    }
}

// MARK: - Ground truth

/// The complete oracle for one synthetic run.
public struct GroundTruth: Sendable {

    /// Every access unit the camera generated, in order.
    public var frames: [ExpectedFrame] = []

    /// The parameter sets in force at the start of the stream.
    public var parameterSets: ParameterSets = ParameterSets(codec: .h264)

    /// Display and coded geometry, and the nominal frame rate.
    public var geometry: SyntheticGeometry = SyntheticGeometry(width: 16, height: 16, alignment: 16)

    /// Nominal frames per second the camera encoded at.
    public var frameRate: Double = 25

    /// RTP sequence numbers the loss injector actually discarded.
    public var injectedPacketLosses: [UInt16] = []

    /// Total RTP packets that reached the wire, duplicates included.
    public var emittedPacketCount: Int = 0

    /// Indices of access units that lost at least one packet.
    public var damagedAccessUnits: Set<Int> = []

    /// The seed that produced this run. Print it on failure; re-running with it reproduces
    /// the stream byte for byte.
    public var seed: UInt64 = 0

    /// An empty oracle, filled in by ``record(_:unwrappedTicks:)`` as the stream is generated.
    public init() {}

    // MARK: Derived expectations

    /// Access units the client is allowed to miss.
    ///
    /// A damaged access unit is unusable, and so is every subsequent one until the next keyframe,
    /// because their references are gone. This is the upper bound a loss test asserts against.
    public var expectedRecoverableFrameLosses: Int {
        guard !damagedAccessUnits.isEmpty else { return 0 }
        var lost = Set<Int>()
        for damaged in damagedAccessUnits {
            var index = damaged
            while index < frames.count {
                lost.insert(index)
                index += 1
                if index < frames.count && frames[index].isKeyframe { break }
            }
        }
        return lost.count
    }

    /// Indices of the keyframes in `frames`.
    public var keyframeIndices: [Int] {
        frames.enumerated().compactMap { $0.element.isKeyframe ? $0.offset : nil }
    }

    /// The frame with the given generated index, or `nil`.
    public func frame(index: Int) -> ExpectedFrame? {
        frames.first { $0.index == index }
    }

    // MARK: Recording

    /// Records one generated access unit. Called by ``SyntheticRTSPServer`` as it produces media,
    /// never by a test.
    ///
    /// `unwrappedTicks` is the 90 kHz presentation time counted from the first access unit, which is
    /// what makes the recorded PTS survive a 2³² RTP timestamp wrap.
    public mutating func record(_ unit: SyntheticAccessUnit, unwrappedTicks: Int64) {
        var all = Data()
        var slices = Data()
        let hevc = unit.parameterSets.codec == .h265
        for nal in unit.nals {
            let prefixed = Self.lengthPrefixed(nal)
            all.append(prefixed)
            if !Self.isParameterSet(nal, isHEVC: hevc) { slices.append(prefixed) }
        }
        frames.append(ExpectedFrame(
            index: unit.index,
            rtpTimestamp: unit.rtpTimestamp,
            pts: MediaTimestamp(value: unwrappedTicks, timescale: 90_000),
            isKeyframe: unit.isKeyframe,
            nalTypes: unit.nalTypeCodes,
            byteCount: all.count,
            sliceByteCount: slices.count,
            checksumIncludingParameterSets: CRC32.checksum(all),
            checksumSlicesOnly: CRC32.checksum(slices)
        ))
    }

    /// A NAL prefixed by its four-byte big-endian length, the form the decode path uses.
    private static func lengthPrefixed(_ nal: [UInt8]) -> Data {
        let length = UInt32(clamping: nal.count)
        var out = Data(capacity: nal.count + 4)
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(contentsOf: nal)
        return out
    }

    private static func isParameterSet(_ nal: [UInt8], isHEVC: Bool) -> Bool {
        guard let first = nal.first else { return false }
        if isHEVC {
            let code = (first >> 1) & 0x3F
            return code >= 32 && code <= 34
        }
        let code = first & 0x1F
        return code == 7 || code == 8
    }
}
