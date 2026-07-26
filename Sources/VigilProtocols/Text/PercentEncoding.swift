//
//  PercentEncoding.swift
//  VigilProtocols
//
//  RFC 3986 percent-encoding and decoding with an explicit allowed-byte set, used for RTSP URLs
//  (userinfo, path segments) and ISAPI query parameters. `URLComponents` is unusable here: it
//  escapes `=` in path segments inconsistently across platforms and rejects Hikvision query forms.
//  Implements docs/spec-rtsp.md §10.1 and docs/spec-isapi.md §4.1.
//
//  No `import Foundation`: plain Swift over `[UInt8]` and `String`.
//

// MARK: - Errors

/// Why a percent-encoded value could not be decoded.
///
/// Offsets are byte indices into the input, so a log line points at the exact escape.
public enum PercentEncodingError: Error, Sendable, Hashable, CustomStringConvertible {

    /// A `%` with fewer than two bytes after it — `"pass%"` or `"pass%4"`.
    case truncatedEscape(offset: Int)

    /// A byte after `%` is not a hex digit — `"%ZZ"`, `"%2Z"`, `"%G1"`.
    case invalidHexDigit(byte: UInt8, offset: Int)

    /// The decoded bytes are not valid UTF-8, so they cannot become a `String`.
    ///
    /// Only `decode(_:)` throws this; `decodeBytes(utf8:)` returns the bytes losslessly.
    case invalidUTF8(byteCount: Int)

    public var description: String {
        switch self {
        case let .truncatedEscape(offset):
            return "percent-encoding: truncated '%' escape at offset \(offset)"
        case let .invalidHexDigit(byte, offset):
            return "percent-encoding: byte 0x\(Self.hex(byte)) at offset \(offset) is not a hex digit"
        case let .invalidUTF8(byteCount):
            return "percent-encoding: \(byteCount) decoded bytes are not valid UTF-8"
        }
    }

    private static func hex(_ byte: UInt8) -> String {
        let digits = "0123456789abcdef"
        let high = digits.index(digits.startIndex, offsetBy: Int(byte >> 4))
        let low = digits.index(digits.startIndex, offsetBy: Int(byte & 0x0F))
        return String([digits[high], digits[low]])
    }
}

// MARK: - PercentEncoding

/// RFC 3986 percent-encoding.
///
/// Decoding is permissive about the input it accepts — both hex cases, and any escape at all,
/// including `%00` and over-escaped unreserved characters — but it never guesses: a malformed
/// escape throws rather than passing the `%` through, because silently accepting `"%zz"` turns a
/// wrong password into a confusing 401 instead of a parse error.
///
/// **`+` is never treated as a space.** That convention belongs to
/// `application/x-www-form-urlencoded` form bodies, not to URIs. A Hikvision device does not
/// decode `+` as a space either, which is why `AllowedBytes.queryComponent` escapes `+` as `%2B`.
public enum PercentEncoding: Sendable {

    // MARK: Allowed-byte sets

    /// A set of byte values that may appear literally, i.e. unescaped.
    ///
    /// Membership is a 256-bit bitmap, so `contains(_:)` is a shift and a mask — no allocation and
    /// no hashing on the encode path. Byte values ≥ 0x80 can be inserted, but doing so produces a
    /// URI that is not RFC 3986 conformant; every predefined set below is ASCII-only.
    public struct AllowedBytes: Sendable, Hashable {
        private var word0: UInt64 = 0
        private var word1: UInt64 = 0
        private var word2: UInt64 = 0
        private var word3: UInt64 = 0

        /// An empty set: every byte gets escaped.
        public init() {}

        /// The set of bytes making up an ASCII literal, e.g. `AllowedBytes("-._~")`.
        public init(_ characters: StaticString) {
            insert(contentsOf: characters)
        }

        /// The set of bytes in an arbitrary sequence.
        public init(bytes: some Sequence<UInt8>) {
            for byte in bytes { insert(byte) }
        }

        /// `true` when `byte` may appear literally.
        public func contains(_ byte: UInt8) -> Bool {
            let word: UInt64
            switch byte >> 6 {
            case 0: word = word0
            case 1: word = word1
            case 2: word = word2
            default: word = word3
            }
            return (word >> UInt64(byte & 0x3F)) & 1 == 1
        }

        /// Adds a single byte.
        public mutating func insert(_ byte: UInt8) {
            let bit: UInt64 = 1 << UInt64(byte & 0x3F)
            switch byte >> 6 {
            case 0: word0 |= bit
            case 1: word1 |= bit
            case 2: word2 |= bit
            default: word3 |= bit
            }
        }

        /// Adds every byte of an ASCII literal.
        public mutating func insert(contentsOf characters: StaticString) {
            characters.withUTF8Buffer { buffer in
                for byte in buffer { insert(byte) }
            }
        }

        /// Adds an inclusive range of byte values, e.g. `UInt8(ascii: "A")...UInt8(ascii: "Z")`.
        public mutating func insert(contentsOf range: ClosedRange<UInt8>) {
            for byte in range { insert(byte) }
        }

        /// The union of two sets.
        public func union(_ other: AllowedBytes) -> AllowedBytes {
            var result = self
            result.word0 |= other.word0
            result.word1 |= other.word1
            result.word2 |= other.word2
            result.word3 |= other.word3
            return result
        }

        // MARK: Predefined sets

        /// RFC 3986 §2.3 `unreserved`: `ALPHA` / `DIGIT` / `-` / `.` / `_` / `~`.
        ///
        /// The safest choice for any single component: everything else is escaped, and
        /// over-escaping an unreserved-equivalent byte is always accepted by a conformant peer.
        public static let unreserved: AllowedBytes = {
            var set = AllowedBytes("-._~")
            set.insert(contentsOf: UInt8(ascii: "A")...UInt8(ascii: "Z"))
            set.insert(contentsOf: UInt8(ascii: "a")...UInt8(ascii: "z"))
            set.insert(contentsOf: UInt8(ascii: "0")...UInt8(ascii: "9"))
            return set
        }()

        /// RFC 3986 §2.2 `sub-delims`: `! $ & ' ( ) * + , ; =`.
        public static let subDelims = AllowedBytes("!$&'()*+,;=")

        /// RFC 3986 §3.3 `pchar`: `unreserved` / `sub-delims` / `:` / `@`.
        ///
        /// For one path segment. `/` is escaped, so a segment cannot inject a new path level.
        /// Note `=` is allowed, which is required for Hikvision's `trackID=1` control segments.
        public static let pathSegment = unreserved.union(subDelims).union(AllowedBytes(":@"))

        /// A whole path: `pchar` plus `/`.
        public static let path = pathSegment.union(AllowedBytes("/"))

        /// RFC 3986 §3.4 `query`: `pchar` / `/` / `?`. For a query string taken verbatim.
        public static let query = path.union(AllowedBytes("?"))

        /// One query parameter name or value: `unreserved` only.
        ///
        /// Deliberately stricter than `query`: `&`, `=`, `;` and `+` must be escaped so they
        /// cannot be read as separators, and `+` in particular must go out as `%2B` because
        /// Hikvision does not decode `+` as a space (docs/spec-isapi.md §4.1).
        public static let queryComponent = unreserved

        /// One userinfo component (username or password): `unreserved` only.
        ///
        /// Hikvision passwords commonly contain `@`, `#`, `/` and `:`; all of them are escaped so
        /// a rebuilt URL cannot be re-parsed with a different authority.
        public static let userInfoComponent = unreserved
    }

    // MARK: Encoding

    private static let percentByte = UInt8(ascii: "%")

    /// Uppercase because RFC 3986 §2.1 prefers uppercase hex in an escape.
    private static let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

    /// Percent-encodes `text`'s UTF-8, letting through only the bytes in `allowed`.
    ///
    /// - Parameters:
    ///   - text: the component to encode. Non-ASCII scalars are encoded as their UTF-8 bytes,
    ///     one escape per byte (`"é"` → `"%C3%A9"`).
    ///   - allowed: which bytes may appear literally. There is no default: the correct set
    ///     depends on where in the URI the result goes, and guessing is how `/` ends up
    ///     unescaped inside a segment.
    /// - Returns: an ASCII string. Escapes use uppercase hex.
    public static func encode(_ text: String, allowing allowed: AllowedBytes) -> String {
        encode(utf8: text.utf8, allowing: allowed)
    }

    /// Percent-encodes raw bytes. See `encode(_:allowing:)`.
    public static func encode(
        utf8 bytes: some Sequence<UInt8>,
        allowing allowed: AllowedBytes
    ) -> String {
        var out = [UInt8]()
        out.reserveCapacity(bytes.underestimatedCount + 8)
        hexDigits.withUnsafeBufferPointer { digits in
            for byte in bytes {
                if allowed.contains(byte) {
                    out.append(byte)
                } else {
                    out.append(percentByte)
                    out.append(digits[Int(byte >> 4)])
                    out.append(digits[Int(byte & 0x0F)])
                }
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Decoding

    /// Percent-decodes `text` and interprets the result as UTF-8.
    ///
    /// Accepts uppercase and lowercase hex. `+` is left as `+`. Any byte that is not part of an
    /// escape passes through unchanged, including bytes that "should" have been escaped.
    ///
    /// - Throws: `PercentEncodingError.truncatedEscape` or `.invalidHexDigit` for a malformed
    ///   escape, and `.invalidUTF8` when the decoded bytes are not valid UTF-8 — use
    ///   `decodeBytes(utf8:)` when arbitrary bytes must survive.
    public static func decode(_ text: String) throws(PercentEncodingError) -> String {
        let bytes = try decodeBytes(utf8: text.utf8)
        let decoded = String(decoding: bytes, as: UTF8.self)
        // `String(decoding:)` substitutes U+FFFD for invalid sequences, which would silently
        // corrupt a password. Round-tripping the UTF-8 is the portable way to detect that.
        guard decoded.utf8.elementsEqual(bytes) else {
            throw PercentEncodingError.invalidUTF8(byteCount: bytes.count)
        }
        return decoded
    }

    /// Percent-decodes `text`, reporting failure as `nil`.
    ///
    /// For call sites that must continue past a bad value. Prefer `decode(_:)` where the error can
    /// be logged.
    public static func decodeOrNil(_ text: String) -> String? {
        do {
            return try decode(text)
        } catch {
            return nil
        }
    }

    /// Percent-decodes raw bytes losslessly, without any UTF-8 interpretation.
    ///
    /// - Throws: `PercentEncodingError.truncatedEscape` when a `%` has fewer than two bytes after
    ///   it, `.invalidHexDigit` when either of those bytes is not a hex digit.
    public static func decodeBytes(
        utf8 bytes: some Collection<UInt8>
    ) throws(PercentEncodingError) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var index = bytes.startIndex
        var offset = 0
        while index != bytes.endIndex {
            let byte = bytes[index]
            guard byte == percentByte else {
                out.append(byte)
                bytes.formIndex(after: &index)
                offset += 1
                continue
            }
            let highIndex = bytes.index(after: index)
            guard highIndex != bytes.endIndex else {
                throw PercentEncodingError.truncatedEscape(offset: offset)
            }
            let lowIndex = bytes.index(after: highIndex)
            guard lowIndex != bytes.endIndex else {
                throw PercentEncodingError.truncatedEscape(offset: offset)
            }
            guard let high = ASCII.hexDigitValue(bytes[highIndex]) else {
                throw PercentEncodingError.invalidHexDigit(
                    byte: bytes[highIndex],
                    offset: offset + 1
                )
            }
            guard let low = ASCII.hexDigitValue(bytes[lowIndex]) else {
                throw PercentEncodingError.invalidHexDigit(
                    byte: bytes[lowIndex],
                    offset: offset + 2
                )
            }
            out.append(high << 4 | low)
            index = bytes.index(after: lowIndex)
            offset += 3
        }
        return out
    }
}
