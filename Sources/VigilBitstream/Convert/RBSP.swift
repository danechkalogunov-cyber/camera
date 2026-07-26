//
//  RBSP.swift
//  VigilBitstream
//
//  Emulation-prevention byte removal and insertion: the conversion between a NAL unit as it appears
//  on the wire and the RBSP a syntax parser reads.
//  See docs/spec-bitstream.md §6 and docs/API_CONTRACT.md §4.2.
//

import VigilProtocols

// MARK: - RBSP

/// The escaped ↔ unescaped conversion for NAL unit payloads.
///
/// Inside a NAL unit an encoder inserts an `emulation_prevention_three_byte` (`0x03`) wherever the
/// raw bytes would otherwise produce `00 00 00`, `00 00 01`, `00 00 02` or `00 00 03` and so look
/// like a start code. Removing them is the first step of every syntax parse.
///
/// **Vigil stores parameter sets escaped** (docs/spec-bitstream.md §2.1), because that is the form
/// `avcC`, `hvcC` and the CoreMedia constructors want. Unescaping always produces a throwaway
/// buffer, and it happens only for parameter sets and SEI — a few hundred bytes a few times per
/// GOP. Slice data is never unescaped.
public enum RBSP {

    // MARK: - Unescaping

    /// Removes emulation-prevention bytes from a NAL unit, returning its RBSP.
    ///
    /// The strict form of the rule is implemented: a `0x03` is dropped only when it is preceded by
    /// exactly two `0x00` bytes **and** followed by a byte ≤ `0x03` or by the end of the NAL. A
    /// conforming encoder can never emit `00 00 03 xx` with `xx > 0x03`, so this agrees with the
    /// looser "drop any `0x03` after two zeros" form on every conforming stream, and additionally
    /// refuses to corrupt data from non-conforming firmware.
    ///
    /// - Parameters:
    ///   - nal: The NAL unit including its header.
    ///   - header: Bytes of NAL header to skip — pass `codec.nalHeaderLength`. The header itself is
    ///     never part of the RBSP and never contains an emulation-prevention byte.
    /// - Returns: The unescaped RBSP, which is never empty.
    /// - Throws: `BitstreamError.emptyNALUnit` when the NAL has no payload beyond its header, or
    ///   when every payload byte was an emulation-prevention byte; `.tooLarge` when the NAL exceeds
    ///   `Limits.maxUnescapeBytes`, which bounds the one allocation on the parse path.
    public static func unescape(
        _ nal: UnsafeRawBufferPointer, skippingHeaderBytes header: Int
    ) throws(BitstreamError) -> [UInt8] {
        guard header >= 0, nal.count > header else { throw BitstreamError.emptyNALUnit }
        guard nal.count <= Limits.maxUnescapeBytes else {
            throw BitstreamError.tooLarge(bytes: nal.count)
        }
        var out = [UInt8]()
        out.reserveCapacity(nal.count - header)
        var zeroRun = 0
        var i = header
        let n = nal.count
        while i < n {
            let b = nal[i]
            if zeroRun >= 2, b == 0x03 {
                let isLast = (i + 1 == n)
                if isLast || nal[i + 1] <= 0x03 {
                    zeroRun = 0
                    i += 1
                    continue                        // drop the emulation-prevention byte
                }
            }
            out.append(b)
            zeroRun = (b == 0x00) ? zeroRun + 1 : 0
            i += 1
        }
        guard !out.isEmpty else { throw BitstreamError.emptyNALUnit }
        return out
    }

    /// Number of emulation-prevention bytes `unescape` would remove, computed without allocating.
    ///
    /// Diagnostics only — it answers "how much of this NAL is escaping overhead". Returns 0 for a
    /// buffer shorter than `header`, rather than failing, because a diagnostic must never throw.
    public static func escapeByteCount(_ nal: UnsafeRawBufferPointer, skippingHeaderBytes header: Int) -> Int {
        guard header >= 0, nal.count > header else { return 0 }
        var count = 0
        var zeroRun = 0
        var i = header
        let n = nal.count
        while i < n {
            let b = nal[i]
            if zeroRun >= 2, b == 0x03, i + 1 == n || nal[i + 1] <= 0x03 {
                count += 1
                zeroRun = 0
                i += 1
                continue
            }
            zeroRun = (b == 0x00) ? zeroRun + 1 : 0
            i += 1
        }
        return count
    }

    // MARK: - Escaping

    /// Inserts emulation-prevention bytes, turning an RBSP into a NAL payload.
    ///
    /// The inverse of `unescape`: `unescape(escape(x))` is `x` for every input. A trailing `00 00`
    /// gains a `0x03` because a NAL unit may not end in `0x00`.
    ///
    /// Used only by test fixtures and by the debug bitstream writer — **never** on the receive path,
    /// where parameter sets are stored exactly as the camera sent them.
    public static func escape(_ rbsp: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(rbsp.count + rbsp.count / 64 + 4)
        var zeroRun = 0
        for b in rbsp {
            if zeroRun >= 2, b <= 0x03 {
                out.append(0x03)
                zeroRun = 0
            }
            out.append(b)
            zeroRun = (b == 0x00) ? zeroRun + 1 : 0
        }
        return out
    }

    // MARK: - Raw-buffer bridging

    /// Runs `body` over `bytes` viewed as a raw buffer, preserving the typed error.
    ///
    /// `Array.withUnsafeBytes` is declared `rethrows`, which erases a typed `throws(BitstreamError)`
    /// back to an untyped `throws` and so cannot be called from a typed-throws function. This
    /// captures the error inside the closure and rethrows it with its type intact, which is what
    /// lets the `base64` and `Data` entry points share one implementation with the raw-buffer ones.
    static func withRawBytes<T>(
        _ bytes: [UInt8], _ body: (UnsafeRawBufferPointer) throws(BitstreamError) -> T
    ) throws(BitstreamError) -> T {
        var result: T?
        var failure: BitstreamError?
        bytes.withUnsafeBytes { raw in
            do throws(BitstreamError) {
                result = try body(raw)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        guard let result else { throw BitstreamError.emptyNALUnit }
        return result
    }
}
