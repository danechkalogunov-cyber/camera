//
//  G711.swift
//  VigilRTP
//
//  ITU-T G.711 µ-law and A-law companding, decoded in the pure layer so `VigilVideo` never sees a
//  compressed G.711 buffer. The closed forms below are the CCITT reference algorithms; the decode
//  path runs through the 256-entry tables they generate.
//  See docs/spec-rtp.md §9.2, §9.3 and docs/API_CONTRACT.md §4.4.
//

import Foundation

import VigilProtocols

// MARK: - G711

/// µ-law and A-law conversion. A namespace, never instantiated.
///
/// Decoding is table-driven: 512 bytes per law, resident in L1, one load per sample. Encoding uses
/// the closed form — talk-back is 8 kHz mono, so 8 000 calls a second is immeasurable.
public enum G711 {

    // MARK: - Nested Types

    /// Which companding law a payload uses.
    public enum Law: Sendable, Hashable {
        case aLaw, muLaw
    }

    // MARK: - Public API

    /// Decodes a G.711 payload to interleaved signed 16-bit little-endian PCM.
    ///
    /// - Parameters:
    ///   - bytes: one byte per sample. An empty payload yields empty output.
    ///   - law: µ-law (PCMU, payload type 0) or A-law (PCMA, payload type 8).
    /// - Returns: exactly `bytes.count * 2` bytes.
    public static func decode(_ bytes: Data, law: Law) -> Data {
        let table = law == .aLaw ? aLawTable : muLawTable
        var out = Data(count: bytes.count * 2)
        out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            var offset = 0
            for byte in bytes {
                let sample = UInt16(bitPattern: table[Int(byte)])
                raw[offset] = UInt8(truncatingIfNeeded: sample)
                raw[offset + 1] = UInt8(truncatingIfNeeded: sample >> 8)
                offset += 2
            }
        }
        return out
    }

    /// Encodes interleaved signed 16-bit little-endian PCM to G.711, for talk-back.
    ///
    /// - Parameters:
    ///   - pcm: little-endian `Int16` samples. A trailing odd byte is ignored.
    ///   - law: the target law.
    /// - Returns: one byte per whole sample.
    public static func encode(_ pcm: Data, law: Law) -> Data {
        var out = Data(capacity: pcm.count / 2)
        var index = pcm.startIndex
        let end = pcm.startIndex + (pcm.count & ~1)
        while index < end {
            let value = Int16(bitPattern: UInt16(pcm[index]) | UInt16(pcm[index + 1]) << 8)
            out.append(law == .aLaw ? linearToALaw(value) : linearToMuLaw(value))
            index += 2
        }
        return out
    }

    /// The 256-entry µ-law decode table, generated once from `muLawToLinear`.
    public static let muLawTable: [Int16] = (0...255).map { muLawToLinear(UInt8($0)) }

    /// The 256-entry A-law decode table, generated once from `aLawToLinear`.
    public static let aLawTable: [Int16] = (0...255).map { aLawToLinear(UInt8($0)) }

    // MARK: - Public API — closed forms

    /// One µ-law byte to a linear sample, per the CCITT reference `ulaw2linear`.
    ///
    /// The wire byte is stored inverted, with a bias of 132 and a peak magnitude of 32 124. Both
    /// zero encodings, `0xFF` and `0x7F`, decode to 0.
    @inlinable public static func muLawToLinear(_ byte: UInt8) -> Int16 {
        let value = ~byte
        var magnitude = ((Int32(value & 0x0F) << 3) + 0x84) << Int32((value & 0x70) >> 4)
        magnitude = value & 0x80 != 0 ? 0x84 - magnitude : magnitude - 0x84
        return Int16(truncatingIfNeeded: magnitude)
    }

    /// One A-law byte to a linear sample, per the CCITT reference `alaw2linear`.
    ///
    /// A-law XORs the wire byte with `0x55`, has no bias, and a peak magnitude of 32 256. Its sign
    /// convention is the opposite of µ-law's: the sign bit set means **positive**.
    @inlinable public static func aLawToLinear(_ byte: UInt8) -> Int16 {
        let value = byte ^ 0x55
        let segment = Int32((value & 0x70) >> 4)
        var magnitude = Int32(value & 0x0F) << 4
        switch segment {
        case 0: magnitude += 8
        case 1: magnitude += 0x108
        default: magnitude = (magnitude + 0x108) << (segment - 1)
        }
        return Int16(truncatingIfNeeded: value & 0x80 != 0 ? magnitude : -magnitude)
    }

    /// One linear sample to µ-law, per the CCITT reference `linear2ulaw`.
    ///
    /// `muLawToLinear(linearToMuLaw(x)) == x` holds for every byte except `0x7F`, the negative-zero
    /// encoding, which decodes to 0 and therefore re-encodes as `0xFF`.
    @inlinable public static func linearToMuLaw(_ pcm: Int16) -> UInt8 {
        var value = Int32(pcm) >> 2
        let mask: UInt8 = value < 0 ? 0x7F : 0xFF
        if value < 0 { value = -value }
        value = min(value, 8159) + (0x84 >> 2)
        let segment = segmentIndex(value, boundaries: muLawSegmentEnds)
        guard segment < 8 else { return 0x7F ^ mask }
        let code = UInt8(truncatingIfNeeded: segment << 4)
            | UInt8(truncatingIfNeeded: (value >> Int32(segment + 1)) & 0x0F)
        return code ^ mask
    }

    /// One linear sample to A-law, per the CCITT reference `linear2alaw`. Round-trips exactly.
    @inlinable public static func linearToALaw(_ pcm: Int16) -> UInt8 {
        var value = Int32(pcm) >> 3
        let mask: UInt8 = value >= 0 ? 0xD5 : 0x55
        if value < 0 { value = -value - 1 }
        value = min(value, 4095)
        let segment = segmentIndex(value, boundaries: aLawSegmentEnds)
        guard segment < 8 else { return 0x7F ^ mask }
        let shift = Int32(segment < 2 ? 1 : segment)
        let code = UInt8(truncatingIfNeeded: segment << 4)
            | UInt8(truncatingIfNeeded: (value >> shift) & 0x0F)
        return code ^ mask
    }

    // MARK: - Private Helpers

    /// Upper bounds of the eight µ-law segments.
    @usableFromInline static let muLawSegmentEnds: [Int32] =
        [0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF, 0x1FFF]

    /// Upper bounds of the eight A-law segments.
    @usableFromInline static let aLawSegmentEnds: [Int32] =
        [0x1F, 0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF]

    /// The index of the first segment whose upper bound is at least `value`, or 8.
    @usableFromInline static func segmentIndex(_ value: Int32, boundaries: [Int32]) -> Int {
        for (index, bound) in boundaries.enumerated() where value <= bound { return index }
        return boundaries.count
    }
}
