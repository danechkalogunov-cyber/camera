//
//  ADTS.swift
//  VigilRTP
//
//  The 7-byte ADTS header, for debug dumps, sidecar files and fixtures only. The live decode path
//  uses `AudioConverter` with the `AudioSpecificConfig` as its magic cookie and never sees ADTS.
//  See docs/spec-rtp.md §8.6 and docs/API_CONTRACT.md §4.4.
//

import Foundation

import VigilProtocols

// MARK: - ADTS

/// Builds ADTS headers. A namespace, never instantiated.
///
/// ADTS is deliberately not on the runtime path: it exists so a raw AAC dump can be handed to
/// `ffprobe`, and so the recorder can write a sidecar `.aac` file. `protection_absent` is always 1,
/// so there is no CRC and the header is always seven bytes.
public enum ADTS {

    /// The number of bytes an ADTS header occupies when `protection_absent` is 1.
    public static let headerByteCount = 7

    /// Builds an ADTS header for one AAC access unit.
    ///
    /// - Parameters:
    ///   - auByteCount: the size of the raw AAC access unit that follows. `aac_frame_length`
    ///     is this plus seven.
    ///   - format: the audio format, whose `magicCookie` supplies `audioObjectType` and whose
    ///     `sampleRate` and `channels` supply the rest.
    /// - Returns: exactly seven bytes. A sample rate outside the ISO table falls back to index 4
    ///   (44 100 Hz) rather than producing an out-of-range field; a negative `auByteCount` is
    ///   clamped to zero.
    public static func header(auByteCount: Int, format: AudioFormatInfo) -> [UInt8] {
        let length = max(0, auByteCount) + headerByteCount
        let objectType = AudioSpecificConfig.objectType(of: format.magicCookie) ?? 2
        let profile = UInt8(min(max(objectType - 1, 0), 3))
        let frequencyIndex = AudioSpecificConfig.frequencyIndex(for: format.sampleRate) ?? 4
        let channels = UInt8(min(max(format.channels, 1), 7))
        let bounded = min(length, 0x1FFF)
        return [
            0xFF,
            0xF1,                                       // MPEG-4, layer 0, protection absent
            (profile << 6) | ((frequencyIndex & 0x0F) << 2) | (channels >> 2),
            ((channels & 0x03) << 6) | UInt8(truncatingIfNeeded: bounded >> 11),
            UInt8(truncatingIfNeeded: (bounded >> 3) & 0xFF),
            (UInt8(truncatingIfNeeded: bounded & 0x07) << 5) | 0x1F,
            0xFC,                                       // buffer fullness 0x7FF, 1 raw data block
        ]
    }
}
