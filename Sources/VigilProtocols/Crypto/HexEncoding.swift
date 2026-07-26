//
//  HexEncoding.swift
//  VigilProtocols
//
//  Hexadecimal encoding (lowercase and uppercase) and a strict decoder. Shared by the MD5, SHA-1 and
//  SHA-256 primitives for their hex helpers, and by the Hikvision request builders that carry byte
//  strings as hex (e.g. the `config=1210` style values).
//  Implements docs/spec-rtsp.md §6.3 (`MD5.hex`) and docs/spec-isapi.md §5.2 (`hexStringLowercase`).
//
//  No `import Foundation`: plain `String` and `Collection` are sufficient here, and the pure layer
//  prefers no import where `Swift` suffices (docs/ARCHITECTURE.md §12).
//

// MARK: - Hex

/// Hexadecimal conversion between bytes and text.
///
/// Encoding always emits exactly two characters per byte with no separator and no prefix. Decoding
/// is deliberately strict — see ``Hex/decode(_:)-(some StringProtocol)`` — because the values it
/// parses come off the network and a silently-truncated decode would become a wrong hash or a wrong
/// camera parameter rather than a diagnosable error.
public enum Hex {

    /// ASCII digits used for lowercase output, indexed by nibble value.
    private static let lowercaseDigits: [UInt8] = Array("0123456789abcdef".utf8)

    /// ASCII digits used for uppercase output, indexed by nibble value.
    private static let uppercaseDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

    /// Why a hexadecimal string could not be decoded.
    ///
    /// Both cases carry the offending position so a log line identifies the exact byte at fault.
    public enum DecodeError: Error, Equatable, Sendable {

        /// The input contained an odd number of hex characters, so the last nibble has no partner.
        /// `count` is the number of characters (UTF-8 bytes) seen.
        case oddLength(count: Int)

        /// `byte` — an ASCII code unit — at UTF-8 offset `index` is not in `0-9`, `a-f` or `A-F`.
        case invalidCharacter(byte: UInt8, index: Int)
    }

    // MARK: Encoding

    /// Hexadecimal text for `bytes`, two characters per byte, in order.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to encode. An empty collection yields the empty string.
    ///   - uppercase: `true` for `A-F`, `false` (the default) for `a-f`. RFC 2617 Digest and every
    ///     Hikvision hex field we emit require lowercase, so lowercase is the default.
    /// - Returns: The encoded text; never contains separators, whitespace or a `0x` prefix.
    public static func encode<Bytes: Collection<UInt8>>(_ bytes: Bytes, uppercase: Bool = false) -> String {
        let digits = uppercase ? uppercaseDigits : lowercaseDigits
        var characters: [UInt8] = []
        characters.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            characters.append(digits[Int(byte >> 4)])
            characters.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: characters, as: UTF8.self)
    }

    /// Lowercase hexadecimal text for `bytes`. Equivalent to `encode(bytes, uppercase: false)`.
    public static func lowercase<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> String {
        encode(bytes, uppercase: false)
    }

    /// Uppercase hexadecimal text for `bytes`. Equivalent to `encode(bytes, uppercase: true)`.
    public static func uppercase<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> String {
        encode(bytes, uppercase: true)
    }

    // MARK: Decoding

    /// Decodes hexadecimal text into bytes, rejecting anything that is not exactly hexadecimal.
    ///
    /// Strict by design: no whitespace is skipped, no `0x` prefix is accepted, no odd trailing
    /// nibble is padded. Mixed case is accepted because Hikvision firmware is inconsistent about it.
    ///
    /// - Parameter string: The text to decode. The empty string decodes to an empty array.
    /// - Returns: One byte per two input characters, in order.
    /// - Throws: ``DecodeError/oddLength(count:)`` if the input has an odd number of UTF-8 bytes;
    ///   ``DecodeError/invalidCharacter(byte:index:)`` for the first non-hex byte, where `index` is
    ///   an offset into the UTF-8 encoding of `string` (so a multi-byte character is reported at the
    ///   offset of its first code unit that fails).
    public static func decode(_ string: some StringProtocol) throws(DecodeError) -> [UInt8] {
        try decode(bytes: Array(string.utf8))
    }

    /// Decodes hexadecimal text supplied as ASCII bytes. See ``decode(_:)-(some StringProtocol)``
    /// for the accepted syntax and the errors thrown.
    public static func decode<Bytes: Collection<UInt8>>(bytes: Bytes) throws(DecodeError) -> [UInt8] {
        let count = bytes.count
        guard count % 2 == 0 else { throw DecodeError.oddLength(count: count) }
        var out: [UInt8] = []
        out.reserveCapacity(count / 2)
        var high: UInt8?
        var index = 0
        for byte in bytes {
            guard let nibble = Self.nibble(byte) else {
                throw DecodeError.invalidCharacter(byte: byte, index: index)
            }
            if let pending = high {
                out.append(pending << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
            index += 1
        }
        return out
    }

    /// Decodes hexadecimal text, returning `nil` instead of throwing when the input is not valid
    /// hex. Use this where the caller has nothing to log; prefer ``decode(_:)-(some StringProtocol)``
    /// when the reason matters.
    public static func decodeOrNil(_ string: some StringProtocol) -> [UInt8]? {
        try? decode(string)
    }

    /// The numeric value of one ASCII hex digit, or `nil` if `byte` is not a hex digit.
    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30 ... 0x39: byte - 0x30            // '0'-'9'
        case 0x61 ... 0x66: byte - 0x61 + 10       // 'a'-'f'
        case 0x41 ... 0x46: byte - 0x41 + 10       // 'A'-'F'
        default: nil
        }
    }
}

// MARK: - Convenience on byte collections

extension Collection where Element == UInt8 {

    /// Lowercase hexadecimal text for these bytes, two characters per byte, no separators.
    ///
    /// This is the spelling used by the Digest formulae in docs/spec-isapi.md §5.2, where
    /// `H(x) = MD5(x).hexStringLowercase`.
    public var hexStringLowercase: String { Hex.encode(self, uppercase: false) }

    /// Uppercase hexadecimal text for these bytes, two characters per byte, no separators.
    public var hexStringUppercase: String { Hex.encode(self, uppercase: true) }
}
