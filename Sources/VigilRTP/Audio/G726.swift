//
//  G726.swift
//  VigilRTP
//
//  ITU-T G.726 ADPCM at 32 kbit/s (4 bits per sample, 8 kHz), decode only. Transcribed from the
//  CCITT reference implementation; every intermediate keeps the reference's integer widths, because
//  an ADPCM predictor that is almost right sounds like distortion and cannot be fixed by ear.
//  See docs/spec-rtp.md §9.4 and docs/API_CONTRACT.md §4.4.
//

import Foundation

import VigilProtocols

// MARK: - G726

/// G.726-32 decoding. A namespace; the adaptive state lives in `DecoderState`.
///
/// **Conformance status.** The ITU-T G.726 test sequences named in `docs/spec-rtp.md` §9.4 are not
/// present in this repository and cannot be fetched here, so byte-exactness against them is
/// unverified. What *is* verified is the packing, the framing, the state's stability over long
/// inputs, and that hostile input cannot crash or allocate without bound. Encoding is deliberately
/// absent: talk-back negotiates G.711 µ-law, so no encoder is needed and shipping an unvalidated
/// one would be worse than shipping none.
public enum G726 {

    // MARK: - Nested Types

    /// The adaptive predictor and quantizer state for one direction of one stream.
    ///
    /// Field widths mirror the reference `struct g72x_state`: `yl` is a long, everything else is a
    /// short, and the truncation on store is part of the algorithm rather than an accident.
    public struct DecoderState: Sendable, Equatable {
        var yl: Int32 = 34_816
        var yu: Int32 = 544
        var dms: Int32 = 0
        var dml: Int32 = 0
        var ap: Int32 = 0
        var a: [Int32] = [0, 0]
        var b: [Int32] = [0, 0, 0, 0, 0, 0]
        var pk: [Int32] = [0, 0]
        var dq: [Int32] = [32, 32, 32, 32, 32, 32]
        var sr: [Int32] = [32, 32]
        var td = false

        /// Creates the reset state the ITU specifies for the start of a stream.
        public init() {}
    }

    /// How 4-bit codewords are packed into octets.
    public enum Packing: Sendable, Hashable {
        /// RFC 3551 §4.5.4 `G726-32`: sample 0 in bits 7…4, sample 1 in bits 3…0.
        case rfc3551
        /// RFC 3551 §4.5.6 `AAL2-G726-32`: the opposite in-octet order.
        case aal2
    }

    // MARK: - Public API

    /// Decodes a G.726-32 payload to interleaved signed 16-bit little-endian PCM, starting from a
    /// fresh predictor state.
    ///
    /// Suitable only for a single self-contained buffer: a real stream must carry its state across
    /// packets, so use `decode32k(_:state:packing:)` there.
    public static func decode32k(_ bytes: Data) -> Data {
        var state = DecoderState()
        return decode32k(bytes, state: &state, packing: .rfc3551)
    }

    /// Decodes a G.726-32 payload, carrying the predictor state across packets.
    ///
    /// - Parameters:
    ///   - bytes: two codewords per byte.
    ///   - state: the adaptive state, updated in place. Resetting it mid-stream produces an audible
    ///     click, so reset only on an SSRC change or a reconnect.
    ///   - packing: in-octet codeword order, chosen by the SDP encoding name.
    /// - Returns: exactly `bytes.count * 4` bytes — two samples per byte, two bytes per sample.
    public static func decode32k(_ bytes: Data, state: inout DecoderState,
                                 packing: Packing) -> Data {
        var out = Data(count: bytes.count * 4)
        out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            var offset = 0
            for byte in bytes {
                let high = Int32((byte >> 4) & 0x0F)
                let low = Int32(byte & 0x0F)
                let first = packing == .rfc3551 ? high : low
                let second = packing == .rfc3551 ? low : high
                // Unrolled rather than looped over a literal array: this runs once per byte and an
                // array literal here would allocate 8 000 times a second.
                let a = UInt16(bitPattern: decodeSample(first, state: &state))
                raw[offset] = UInt8(truncatingIfNeeded: a)
                raw[offset + 1] = UInt8(truncatingIfNeeded: a >> 8)
                let b = UInt16(bitPattern: decodeSample(second, state: &state))
                raw[offset + 2] = UInt8(truncatingIfNeeded: b)
                raw[offset + 3] = UInt8(truncatingIfNeeded: b >> 8)
                offset += 4
            }
        }
        return out
    }

    // MARK: - Private Helpers — tables

    /// Powers of two, the quantiser's exponent ladder.
    private static let power2: [Int32] = [
        1, 2, 4, 8, 0x10, 0x20, 0x40, 0x80,
        0x100, 0x200, 0x400, 0x800, 0x1000, 0x2000, 0x4000,
    ]

    /// Inverse quantiser, 4-bit rate.
    private static let dqlnTable: [Int32] = [
        -2048, 4, 135, 213, 273, 323, 373, 425,
        425, 373, 323, 273, 213, 135, 4, -2048,
    ]

    /// Quantiser scale-factor adaptation weights, 4-bit rate.
    private static let wiTable: [Int32] = [
        -12, 18, 41, 64, 112, 198, 355, 1122,
        1122, 355, 198, 112, 64, 41, 18, -12,
    ]

    /// Adaptation-speed control weights, 4-bit rate.
    private static let fiTable: [Int32] = [
        0, 0, 0, 0x200, 0x200, 0x200, 0x600, 0xE00,
        0xE00, 0x600, 0x200, 0x200, 0x200, 0, 0, 0,
    ]

    // MARK: - Private Helpers — the decoder

    /// One codeword to one linear sample. Mirrors the reference `g726_32_decoder`.
    private static func decodeSample(_ code: Int32, state: inout DecoderState) -> Int16 {
        let index = code & 0x0F
        let sezi = predictorZero(state)
        let sez = sezi >> 1
        let sei = sezi + predictorPole(state)
        let se = sei >> 1
        let y = stepSize(state)
        let dq = reconstruct(sign: index & 0x08, dqln: dqlnTable[Int(index)], y: y)
        let sr = dq < 0 ? se - (dq & 0x3FFF) : se + dq
        let dqsez = sr - se + sez
        update(y: y, wi: wiTable[Int(index)] << 5, fi: fiTable[Int(index)],
               dq: dq, sr: sr, dqsez: dqsez, state: &state)
        return Int16(clamping: sr << 2)
    }

    /// The index of the first table entry greater than `value`, or the table's count.
    private static func quantize(_ value: Int32) -> Int32 {
        for (index, bound) in power2.enumerated() where value < bound { return Int32(index) }
        return Int32(power2.count)
    }

    /// Floating-point multiply of a predictor coefficient by a stored sample.
    private static func fmult(_ an: Int32, _ srn: Int32) -> Int32 {
        let anmag = an > 0 ? an : ((-an) & 0x1FFF)
        let anexp = quantize(anmag) - 6
        let anmant = anmag == 0 ? 32 : (anexp >= 0 ? anmag >> anexp : anmag << (-anexp))
        let wanexp = anexp + ((srn >> 6) & 0x0F) - 13
        let wanmant = (anmant * (srn & 0x3F) + 0x30) >> 4
        let value = wanexp >= 0 ? (wanmant << wanexp) & 0x7FFF : wanmant >> (-wanexp)
        return (an ^ srn) < 0 ? -value : value
    }

    /// The six-zero part of the predictor.
    private static func predictorZero(_ state: DecoderState) -> Int32 {
        var total: Int32 = 0
        for index in 0..<6 { total += fmult(state.b[index] >> 2, state.dq[index]) }
        return total
    }

    /// The two-pole part of the predictor.
    private static func predictorPole(_ state: DecoderState) -> Int32 {
        fmult(state.a[1] >> 2, state.sr[1]) + fmult(state.a[0] >> 2, state.sr[0])
    }

    /// Blends the fast and slow quantiser scale factors through the adaptation-speed control.
    private static func stepSize(_ state: DecoderState) -> Int32 {
        guard state.ap < 256 else { return state.yu }
        var y = state.yl >> 6
        let difference = state.yu - y
        let speed = state.ap >> 2
        if difference > 0 {
            y += (difference * speed) >> 6
        } else if difference < 0 {
            y += (difference * speed + 0x3F) >> 6
        }
        return y
    }

    /// The inverse adaptive quantiser.
    private static func reconstruct(sign: Int32, dqln: Int32, y: Int32) -> Int32 {
        let dql = dqln + (y >> 2)
        guard dql >= 0 else { return sign != 0 ? -0x8000 : 0 }
        let exponent = (dql >> 7) & 15
        let mantissa = 128 + (dql & 127)
        let magnitude = (mantissa << 7) >> (14 - exponent)
        return sign != 0 ? magnitude - 0x8000 : magnitude
    }

    /// Adapts every coefficient after one sample. Mirrors the reference `update` for `code_size` 4.
    ///
    /// RATIONALE: this is one long function on purpose. It is a line-by-line transcription of the
    /// reference, and splitting it into "tidy" helpers would make it impossible to check against
    /// the ITU document, which is the only way this code can ever be reviewed.
    private static func update(y: Int32, wi: Int32, fi: Int32, dq: Int32, sr: Int32,
                               dqsez: Int32, state: inout DecoderState) {
        let pk0: Int32 = dqsez < 0 ? 1 : 0
        let magnitude = dq & 0x7FFF

        // TRANS: decide whether this sample looks like modem data rather than voice.
        let ylint = state.yl >> 15
        let ylfrac = (state.yl >> 10) & 0x1F
        let threshold = (32 + ylfrac) << ylint
        let limited = ylint > 9 ? 31 << 10 : threshold
        let dataThreshold = (limited + (limited >> 1)) >> 1
        let isData = state.td && magnitude > dataThreshold

        // Quantizer scale factor adaptation.
        state.yu = Int32(Int16(truncatingIfNeeded: y + ((wi - y) >> 5)))
        state.yu = min(max(state.yu, 544), 5120)
        state.yl += state.yu + ((-state.yl) >> 6)

        var a2p = state.a[1]
        if isData {
            state.a = [0, 0]
            state.b = [0, 0, 0, 0, 0, 0]
            a2p = 0
        } else {
            let pks1 = pk0 ^ state.pk[0]
            a2p = state.a[1] - (state.a[1] >> 7)
            if dqsez != 0 {
                let fa1 = pks1 != 0 ? state.a[0] : -state.a[0]
                if fa1 < -8191 {
                    a2p -= 0x100
                } else if fa1 > 8191 {
                    a2p += 0xFF
                } else {
                    a2p += fa1 >> 5
                }
                if (pk0 ^ state.pk[1]) != 0 {
                    if a2p <= -12_160 {
                        a2p = -12_288
                    } else if a2p >= 12_416 {
                        a2p = 12_288
                    } else {
                        a2p -= 0x80
                    }
                } else if a2p <= -12_416 {
                    a2p = -12_288
                } else if a2p >= 12_160 {
                    a2p = 12_288
                } else {
                    a2p += 0x80
                }
            }
            state.a[1] = a2p
            state.a[0] -= state.a[0] >> 8
            if dqsez != 0 { state.a[0] += pks1 == 0 ? 192 : -192 }
            let limit = 15_360 - a2p
            state.a[0] = min(max(state.a[0], -limit), limit)
            for index in 0..<6 {
                state.b[index] -= state.b[index] >> 8
                if magnitude != 0 {
                    state.b[index] += (dq ^ state.dq[index]) >= 0 ? 128 : -128
                }
                state.b[index] = Int32(Int16(truncatingIfNeeded: state.b[index]))
            }
        }

        for index in stride(from: 5, to: 0, by: -1) { state.dq[index] = state.dq[index - 1] }
        // FLOAT A: dq[0] becomes a 4-bit exponent and 6-bit mantissa.
        if magnitude == 0 {
            state.dq[0] = dq >= 0 ? 0x20 : Int32(Int16(bitPattern: 0xFC20))
        } else {
            let exponent = quantize(magnitude)
            let packed = (exponent << 6) + ((magnitude << 6) >> exponent)
            state.dq[0] = dq >= 0 ? packed : packed - 0x400
        }

        state.sr[1] = state.sr[0]
        // FLOAT B: the same encoding for the reconstructed signal.
        if sr == 0 {
            state.sr[0] = 0x20
        } else if sr > 0 {
            let exponent = quantize(sr)
            state.sr[0] = (exponent << 6) + ((sr << 6) >> exponent)
        } else if sr > -32_768 {
            let mag = -sr
            let exponent = quantize(mag)
            state.sr[0] = (exponent << 6) + ((mag << 6) >> exponent) - 0x400
        } else {
            state.sr[0] = Int32(Int16(bitPattern: 0xFC20))
        }

        state.pk[1] = state.pk[0]
        state.pk[0] = pk0

        // TONE: a2p below the threshold means the sample-to-sample correlation collapsed.
        state.td = isData ? false : a2p < -11_776

        // Adaptation speed control.
        state.dms += (fi - state.dms) >> 5
        state.dml += ((fi << 2) - state.dml) >> 7
        if isData {
            state.ap = 256
        } else if y < 1536 || state.td
                    || abs((state.dms << 2) - state.dml) >= (state.dml >> 3) {
            state.ap += (0x200 - state.ap) >> 4
        } else {
            state.ap += (-state.ap) >> 4
        }
    }
}
