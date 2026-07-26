//
//  Base64.swift
//  VigilProtocols
//
//  RFC 4648 Base64 encoding plus a padding-tolerant decoder, because Hikvision emits SDP
//  `sprop-parameter-sets` / `sprop-sps` / `sprop-vps` values without `=` padding and
//  Foundation's `Data(base64Encoded:)` rejects them — a rejected SPS is a black stream.
//  Implements docs/spec-rtsp.md §6.3 and §8.6.
//
//  No `import Foundation`: everything here is plain Swift over `[UInt8]`.
//

// MARK: - Errors

/// Why a Base64 value could not be decoded.
///
/// Every case carries the byte offset (or character count) needed to diagnose the failure from a
/// single log line. Offsets are indices into the *input* bytes, counting whitespace, so they line
/// up with the raw SDP or XML text an operator is looking at.
public enum Base64Error: Error, Sendable, Hashable, CustomStringConvertible {

    /// A byte belongs to neither alphabet, or is whitespace where whitespace is not allowed.
    case invalidCharacter(byte: UInt8, offset: Int)

    /// A `=` appeared where no incomplete quantum was pending — `"="`, `"===="`, `"Zm9v="`.
    case misplacedPadding(offset: Int)

    /// An alphabet character appeared after padding had started — `"Zm9v=Zg=="`.
    case dataAfterPadding(offset: Int)

    /// The number of alphabet characters is 1 modulo 4, which cannot encode a whole number of
    /// bytes. This is what a truncated trailing group looks like.
    case invalidLength(significantCharacters: Int)

    /// Strict decoding only: the `=` count does not match the final quantum.
    case incorrectPadding(expected: Int, found: Int)

    /// Strict decoding only: the bits below the last whole byte are not zero (RFC 4648 §3.5), so
    /// the value is a non-canonical encoding. Lenient decoding discards these bits instead.
    case nonCanonicalTrailingBits(bits: UInt8)

    public var description: String {
        switch self {
        case let .invalidCharacter(byte, offset):
            return "base64: invalid character 0x\(Self.hex(byte)) at offset \(offset)"
        case let .misplacedPadding(offset):
            return "base64: '=' padding at offset \(offset) with no incomplete group pending"
        case let .dataAfterPadding(offset):
            return "base64: alphabet character at offset \(offset) after '=' padding"
        case let .invalidLength(significant):
            return "base64: \(significant) alphabet characters is 1 mod 4 and cannot be valid"
        case let .incorrectPadding(expected, found):
            return "base64: expected \(expected) '=' padding characters, found \(found)"
        case let .nonCanonicalTrailingBits(bits):
            return "base64: non-canonical trailing bits 0x\(Self.hex(bits)) in final group"
        }
    }

    /// Two lowercase hex digits. Local so this file needs no dependency on `HexEncoding`.
    private static func hex(_ byte: UInt8) -> String {
        let digits = "0123456789abcdef"
        let high = digits.index(digits.startIndex, offsetBy: Int(byte >> 4))
        let low = digits.index(digits.startIndex, offsetBy: Int(byte & 0x0F))
        return String([digits[high], digits[low]])
    }
}

// MARK: - Base64

/// Base64 encoding and decoding.
///
/// `decode(_:)` is deliberately **lenient**, because it is fed camera-supplied SDP and XML:
/// it accepts missing trailing padding, ignores embedded whitespace/CR/LF (SDP folds long
/// `a=fmtp` lines), and accepts the URL-safe alphabet alongside the standard one. It still
/// rejects genuinely impossible input rather than returning truncated bytes.
///
/// `decodeStrict(_:)` is RFC 4648 §4 to the letter and exists for the places where accepting a
/// sloppy value would hide a real bug — chiefly anything we generate ourselves and round-trip.
///
/// Encoding always produces the canonical form: standard alphabet, padded, no line breaks.
public enum Base64: Sendable {

    // MARK: Alphabets

    /// The two RFC 4648 alphabets.
    public enum Alphabet: Sendable, Hashable, CaseIterable {
        /// RFC 4648 §4: `A–Z`, `a–z`, `0–9`, `+`, `/`.
        case standard
        /// RFC 4648 §5: `A–Z`, `a–z`, `0–9`, `-`, `_`. Safe inside a URL path or query.
        case urlSafe
    }

    private static let standardAlphabet: [UInt8] = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8
    )

    private static let urlSafeAlphabet: [UInt8] = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8
    )

    private static let paddingByte = UInt8(ascii: "=")

    // MARK: Encoding

    /// Encodes `bytes` as Base64.
    ///
    /// - Parameters:
    ///   - bytes: the payload; any `Sequence` of bytes, so `Data`, `[UInt8]` and slices all work.
    ///   - alphabet: `.standard` (the wire default everywhere in this project) or `.urlSafe`.
    ///   - padded: when `false` the trailing `=` characters are omitted. Only for callers that
    ///     must match a peer which does the same; our own output is padded.
    /// - Returns: an ASCII string with no line breaks. Empty input encodes to the empty string.
    public static func encode(
        _ bytes: some Sequence<UInt8>,
        alphabet: Alphabet = .standard,
        padded: Bool = true
    ) -> String {
        var out = [UInt8]()
        out.reserveCapacity(((bytes.underestimatedCount + 2) / 3) * 4)
        let table = alphabet == .standard ? standardAlphabet : urlSafeAlphabet
        // The table is indexed once per output character; taking the buffer pointer once removes
        // the per-character bounds check from the inner loop.
        table.withUnsafeBufferPointer { alpha in
            var iterator = bytes.makeIterator()
            while let byte0 = iterator.next() {
                let byte1 = iterator.next()
                let byte2 = iterator.next()
                let quantum = (UInt32(byte0) << 16)
                    | (UInt32(byte1 ?? 0) << 8)
                    | UInt32(byte2 ?? 0)
                out.append(alpha[Int((quantum >> 18) & 0x3F)])
                out.append(alpha[Int((quantum >> 12) & 0x3F)])
                if byte1 == nil {
                    if padded {
                        out.append(paddingByte)
                        out.append(paddingByte)
                    }
                } else {
                    out.append(alpha[Int((quantum >> 6) & 0x3F)])
                    if byte2 == nil {
                        if padded { out.append(paddingByte) }
                    } else {
                        out.append(alpha[Int(quantum & 0x3F)])
                    }
                }
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Decoding

    /// Decodes leniently: missing padding, embedded whitespace/CR/LF and the URL-safe alphabet
    /// are all accepted.
    ///
    /// - Throws: `Base64Error` when the input cannot represent a byte sequence — a character
    ///   outside both alphabets, padding in an impossible position, data after padding, or a
    ///   character count of 1 modulo 4. Never returns partially-decoded bytes.
    public static func decode(_ text: String) throws(Base64Error) -> [UInt8] {
        try decode(utf8: text.utf8)
    }

    /// Lenient decode over raw UTF-8/ASCII bytes, for parsers that already hold a slice and must
    /// not build a `String` first.
    public static func decode(utf8 bytes: some Collection<UInt8>) throws(Base64Error) -> [UInt8] {
        switch decodeCore(bytes, policy: .lenient) {
        case let .success(out): return out
        case let .failure(error): throw error
        }
    }

    /// Lenient decode that reports failure as `nil`.
    ///
    /// For call sites that must continue past a bad value — SDP parameter-set extraction skips an
    /// undecodable `sprop-*` and relies on in-band parameter sets (docs/spec-rtsp.md §8.6).
    /// Prefer `decode(_:)` wherever the error can actually be logged.
    public static func decodeOrNil(_ text: String) -> [UInt8]? {
        switch decodeCore(text.utf8, policy: .lenient) {
        case let .success(out): return out
        case .failure: return nil
        }
    }

    /// Decodes strictly per RFC 4648 §4: standard alphabet only, mandatory padding, no embedded
    /// whitespace, and trailing bits below the last whole byte must be zero.
    ///
    /// - Throws: `Base64Error` for any deviation, including the unpadded and URL-safe forms that
    ///   `decode(_:)` accepts.
    public static func decodeStrict(_ text: String) throws(Base64Error) -> [UInt8] {
        try decodeStrict(utf8: text.utf8)
    }

    /// Strict decode over raw UTF-8/ASCII bytes. See `decodeStrict(_:)`.
    public static func decodeStrict(
        utf8 bytes: some Collection<UInt8>
    ) throws(Base64Error) -> [UInt8] {
        switch decodeCore(bytes, policy: .strict) {
        case let .success(out): return out
        case let .failure(error): throw error
        }
    }

    // MARK: - Decoder core

    /// What a decode run is willing to accept.
    private struct Policy: Sendable {
        /// Accept `-` and `_` as 62 and 63 in addition to `+` and `/`.
        let allowsURLSafeAlphabet: Bool
        /// Skip SP, HTAB, LF, VT, FF and CR anywhere in the input.
        let allowsWhitespace: Bool
        /// Require the exact `=` count implied by the final quantum.
        let requiresExactPadding: Bool
        /// Reject a final group whose sub-byte trailing bits are non-zero.
        let requiresCanonicalTrailingBits: Bool

        static let lenient = Policy(
            allowsURLSafeAlphabet: true,
            allowsWhitespace: true,
            requiresExactPadding: false,
            requiresCanonicalTrailingBits: false
        )

        static let strict = Policy(
            allowsURLSafeAlphabet: false,
            allowsWhitespace: false,
            requiresExactPadding: true,
            requiresCanonicalTrailingBits: true
        )
    }

    /// Table slots for bytes that are not alphabet characters.
    private static let slotInvalid: Int8 = -1
    private static let slotWhitespace: Int8 = -2
    private static let slotPadding: Int8 = -3

    /// Standard alphabet only: `-` and `_` map to `slotInvalid`.
    private static let standardDecodeTable: [Int8] = makeDecodeTable(includingURLSafe: false)

    /// Standard plus URL-safe: `-` → 62 and `_` → 63 alongside `+` and `/`.
    private static let lenientDecodeTable: [Int8] = makeDecodeTable(includingURLSafe: true)

    /// Builds a 128-entry ASCII lookup table. Bytes ≥ 0x80 are never looked up.
    private static func makeDecodeTable(includingURLSafe: Bool) -> [Int8] {
        var table = [Int8](repeating: slotInvalid, count: 128)
        for (value, character) in standardAlphabet.enumerated() {
            table[Int(character)] = Int8(truncatingIfNeeded: value)
        }
        if includingURLSafe {
            table[Int(UInt8(ascii: "-"))] = 62
            table[Int(UInt8(ascii: "_"))] = 63
        }
        table[Int(paddingByte)] = slotPadding
        // SDP folds long lines and XML pretty-printers indent Base64 blobs, so every ASCII
        // whitespace byte is skippable, not just SP and CRLF.
        for whitespace in [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20] {
            table[whitespace] = slotWhitespace
        }
        return table
    }

    /// The single decode implementation.
    ///
    /// Returns a `Result` rather than throwing so the body can run inside
    /// `withUnsafeBufferPointer` — a `rethrows` closure cannot carry a typed throw.
    private static func decodeCore(
        _ bytes: some Collection<UInt8>,
        policy: Policy
    ) -> Result<[UInt8], Base64Error> {
        let table = policy.allowsURLSafeAlphabet ? lenientDecodeTable : standardDecodeTable
        return table.withUnsafeBufferPointer { slots -> Result<[UInt8], Base64Error> in
            var out = [UInt8]()
            out.reserveCapacity((bytes.count / 4) * 3 + 3)
            var quantum: UInt32 = 0
            var sextets = 0          // alphabet characters buffered in the current 4-char group
            var significant = 0      // alphabet characters seen in total
            var padding = 0          // '=' characters seen
            var offset = -1

            for byte in bytes {
                offset += 1
                let slot = byte < 0x80 ? slots[Int(byte)] : slotInvalid

                if slot >= 0 {
                    guard padding == 0 else {
                        return .failure(.dataAfterPadding(offset: offset))
                    }
                    quantum = (quantum << 6) | UInt32(UInt8(bitPattern: slot))
                    sextets += 1
                    significant += 1
                    if sextets == 4 {
                        out.append(UInt8(truncatingIfNeeded: quantum >> 16))
                        out.append(UInt8(truncatingIfNeeded: quantum >> 8))
                        out.append(UInt8(truncatingIfNeeded: quantum))
                        quantum = 0
                        sextets = 0
                    }
                } else if slot == slotWhitespace {
                    guard policy.allowsWhitespace else {
                        return .failure(.invalidCharacter(byte: byte, offset: offset))
                    }
                } else if slot == slotPadding {
                    // Padding is only meaningful for an incomplete group; `=` at a group boundary
                    // is nonsense in both modes.
                    guard sextets != 0 else {
                        return .failure(.misplacedPadding(offset: offset))
                    }
                    padding += 1
                } else {
                    return .failure(.invalidCharacter(byte: byte, offset: offset))
                }
            }

            switch sextets {
            case 0:
                if policy.requiresExactPadding, padding != 0 {
                    return .failure(.incorrectPadding(expected: 0, found: padding))
                }
            case 2:
                // 12 buffered bits: one whole byte plus 4 trailing bits.
                if policy.requiresExactPadding, padding != 2 {
                    return .failure(.incorrectPadding(expected: 2, found: padding))
                }
                let trailing = UInt8(truncatingIfNeeded: quantum & 0x0F)
                if policy.requiresCanonicalTrailingBits, trailing != 0 {
                    return .failure(.nonCanonicalTrailingBits(bits: trailing))
                }
                out.append(UInt8(truncatingIfNeeded: quantum >> 4))
            case 3:
                // 18 buffered bits: two whole bytes plus 2 trailing bits.
                if policy.requiresExactPadding, padding != 1 {
                    return .failure(.incorrectPadding(expected: 1, found: padding))
                }
                let trailing = UInt8(truncatingIfNeeded: quantum & 0x03)
                if policy.requiresCanonicalTrailingBits, trailing != 0 {
                    return .failure(.nonCanonicalTrailingBits(bits: trailing))
                }
                out.append(UInt8(truncatingIfNeeded: quantum >> 10))
                out.append(UInt8(truncatingIfNeeded: quantum >> 2))
            default:
                // sextets == 1: six bits cannot become a byte, no matter what follows.
                return .failure(.invalidLength(significantCharacters: significant))
            }

            return .success(out)
        }
    }
}
