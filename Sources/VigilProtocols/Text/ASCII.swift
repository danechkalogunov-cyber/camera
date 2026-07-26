//
//  ASCII.swift
//  VigilProtocols
//
//  Allocation-free ASCII case folding, RFC 7230 classification, trimming and splitting over byte
//  buffers. Protocol header matching must never depend on a locale or on Unicode case folding;
//  these run once per header line, so they take slices and raw buffers rather than `String`.
//  Implements docs/spec-rtsp.md §3.1/§4.5 and docs/spec-isapi.md §7 (lenient input, strict output).
//
//  No `import Foundation`: plain Swift over `Collection<UInt8>`.
//

/// ASCII-only text primitives for protocol parsing.
///
/// Everything here is defined on byte values, not characters. `lowercased(_:)` maps `A…Z` to
/// `a…z` and leaves **every** other byte — punctuation, digits, and all of `0x80…0xFF` — exactly
/// as it is. That is the whole point of the file:
///
/// * `String.lowercased()` performs full Unicode case folding, so `"İ"` (U+0130) becomes
///   `"i" + U+0307` and a byte-length-sensitive parser silently changes shape.
/// * C's `tolower` and any locale-aware equivalent map `"I"` to `"ı"` (U+0131) under `tr_TR`, so
///   a header named `Content-Length` stops matching on a Turkish system. That bug is the reason
///   this type exists; never reintroduce a locale-sensitive comparison in a parser.
///
/// All operations are allocation-free unless the doc comment says otherwise, and all of them
/// accept `ArraySlice<UInt8>`, `UnsafeRawBufferPointer`, `Data` and `String.UTF8View` alike.
public enum ASCII: Sendable {

    // MARK: - Case folding

    /// `A…Z` → `a…z`. Every other byte, including `0x80…0xFF`, is returned unchanged.
    @inlinable
    public static func lowercased(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte | 0x20 : byte
    }

    /// `a…z` → `A…Z`. Every other byte, including `0x80…0xFF`, is returned unchanged.
    @inlinable
    public static func uppercased(_ byte: UInt8) -> UInt8 {
        (byte >= 0x61 && byte <= 0x7A) ? byte & ~0x20 : byte
    }

    /// ASCII-lowercases every byte of `bytes`.
    ///
    /// Allocates the result array; use `equalsIgnoringCase` for comparisons and
    /// `lowercaseInPlace` for buffers you own, both of which do not allocate.
    public static func lowercased(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        bytes.map { lowercased($0) }
    }

    /// ASCII-uppercases every byte of `bytes`. Allocates the result array.
    public static func uppercased(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        bytes.map { uppercased($0) }
    }

    /// ASCII-lowercases a mutable buffer in place. Accepts `[UInt8]`, `ArraySlice<UInt8>` and
    /// `UnsafeMutableRawBufferPointer`.
    public static func lowercaseInPlace<Buffer: MutableCollection<UInt8>>(_ bytes: inout Buffer) {
        var index = bytes.startIndex
        while index != bytes.endIndex {
            bytes[index] = lowercased(bytes[index])
            bytes.formIndex(after: &index)
        }
    }

    /// ASCII-lowercases a string: `A…Z` only, never Unicode case folding.
    ///
    /// Use this — not `String.lowercased()` — for any key derived from wire text, such as an
    /// ISAPI element name or an `a=fmtp` parameter name. Returns `string` itself (no allocation)
    /// when it contains no ASCII uppercase letter, which is the common case.
    public static func lowercased(_ string: String) -> String {
        guard string.utf8.contains(where: isUppercaseLetter) else { return string }
        // Lowercasing only 0x41…0x5A can never touch a UTF-8 continuation byte (all ≥ 0x80), so
        // mapping the code units cannot corrupt a multi-byte scalar.
        return String(decoding: string.utf8.map { lowercased($0) }, as: UTF8.self)
    }

    // MARK: - Classification

    /// `A…Z`.
    @inlinable
    public static func isUppercaseLetter(_ byte: UInt8) -> Bool { byte >= 0x41 && byte <= 0x5A }

    /// `a…z`.
    @inlinable
    public static func isLowercaseLetter(_ byte: UInt8) -> Bool { byte >= 0x61 && byte <= 0x7A }

    /// RFC 5234 `ALPHA`: `A…Z` / `a…z`.
    @inlinable
    public static func isLetter(_ byte: UInt8) -> Bool {
        isUppercaseLetter(byte) || isLowercaseLetter(byte)
    }

    /// RFC 5234 `DIGIT`: `0…9`.
    @inlinable
    public static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    /// RFC 5234 `HEXDIG`, both cases.
    @inlinable
    public static func isHexDigit(_ byte: UInt8) -> Bool { hexDigitValue(byte) != nil }

    /// The numeric value 0…15 of a hex digit, or `nil` if `byte` is not one. Both cases.
    @inlinable
    public static func hexDigitValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30           // 0…9
        case 0x41...0x46: return byte - 0x41 + 10      // A…F
        case 0x61...0x66: return byte - 0x61 + 10      // a…f
        default: return nil
        }
    }

    /// RFC 7230 linear whitespace (`OWS` / `BWS`): SP or HTAB only.
    ///
    /// CR and LF are deliberately excluded — inside a header field they are framing, not padding.
    @inlinable
    public static func isLinearWhitespace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }

    /// CR (0x0D) or LF (0x0A).
    @inlinable
    public static func isNewline(_ byte: UInt8) -> Bool { byte == 0x0D || byte == 0x0A }

    /// SP, HTAB, CR or LF: linear whitespace plus line terminators.
    @inlinable
    public static func isWhitespace(_ byte: UInt8) -> Bool {
        isLinearWhitespace(byte) || isNewline(byte)
    }

    /// RFC 7230 `tchar`, the set a header name or a token-valued parameter may use:
    /// `ALPHA` / `DIGIT` / `! # $ % & ' * + - . ^ _ ` | ~`.
    ///
    /// Note what is **not** a token character and therefore always needs a quoted string:
    /// space, `"`, `(`, `)`, `,`, `/`, `:`, `;`, `<`, `=`, `>`, `?`, `@`, `[`, `\`, `]`, `{`, `}`.
    @inlinable
    public static func isTokenByte(_ byte: UInt8) -> Bool {
        if isLetter(byte) || isDigit(byte) { return true }
        switch byte {
        case UInt8(ascii: "!"), UInt8(ascii: "#"), UInt8(ascii: "$"), UInt8(ascii: "%"),
             UInt8(ascii: "&"), UInt8(ascii: "'"), UInt8(ascii: "*"), UInt8(ascii: "+"),
             UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "^"), UInt8(ascii: "_"),
             UInt8(ascii: "`"), UInt8(ascii: "|"), UInt8(ascii: "~"):
            return true
        default:
            return false
        }
    }

    /// RFC 5234 `VCHAR`: a visible ASCII character, `0x21…0x7E`.
    @inlinable
    public static func isVisible(_ byte: UInt8) -> Bool { byte >= 0x21 && byte <= 0x7E }

    /// `true` when every byte of `bytes` is an RFC 7230 `tchar`. An empty slice is **not** a
    /// valid token, so this returns `false` for it.
    public static func isToken(_ bytes: some Collection<UInt8>) -> Bool {
        !bytes.isEmpty && bytes.allSatisfy(isTokenByte)
    }

    // MARK: - Case-insensitive comparison

    /// Compares two byte sequences for equality, folding ASCII case only.
    ///
    /// Allocation-free and locale-independent. Bytes ≥ 0x80 compare literally, so two different
    /// UTF-8 encodings of the "same" letter are **not** equal — which is what a header matcher
    /// wants.
    public static func equalsIgnoringCase(
        _ lhs: some Collection<UInt8>,
        _ rhs: some Collection<UInt8>
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var left = lhs.startIndex
        var right = rhs.startIndex
        while left != lhs.endIndex {
            if lowercased(lhs[left]) != lowercased(rhs[right]) { return false }
            lhs.formIndex(after: &left)
            rhs.formIndex(after: &right)
        }
        return true
    }

    /// Compares `bytes` against an ASCII literal, folding ASCII case only.
    ///
    /// `StaticString` is used so the literal's UTF-8 is a compile-time constant and the
    /// comparison allocates nothing: `ASCII.equalsIgnoringCase(name, "content-length")`.
    public static func equalsIgnoringCase(
        _ bytes: some Collection<UInt8>,
        _ literal: StaticString
    ) -> Bool {
        literal.withUTF8Buffer { equalsIgnoringCase(bytes, $0) }
    }

    /// `true` when `bytes` starts with `prefix`, folding ASCII case only.
    public static func hasPrefixIgnoringCase(
        _ bytes: some Collection<UInt8>,
        _ prefix: some Collection<UInt8>
    ) -> Bool {
        guard bytes.count >= prefix.count else { return false }
        var left = bytes.startIndex
        var right = prefix.startIndex
        while right != prefix.endIndex {
            if lowercased(bytes[left]) != lowercased(prefix[right]) { return false }
            bytes.formIndex(after: &left)
            prefix.formIndex(after: &right)
        }
        return true
    }

    /// `true` when `bytes` starts with the ASCII literal `prefix`, folding ASCII case only.
    public static func hasPrefixIgnoringCase(
        _ bytes: some Collection<UInt8>,
        _ prefix: StaticString
    ) -> Bool {
        prefix.withUTF8Buffer { hasPrefixIgnoringCase(bytes, $0) }
    }

    // MARK: - Trimming

    /// Drops leading and trailing RFC 7230 linear whitespace (SP and HTAB) and returns a slice of
    /// the original buffer. Nothing is copied.
    public static func trimmingLinearWhitespace<Bytes: BidirectionalCollection<UInt8>>(
        _ bytes: Bytes
    ) -> Bytes.SubSequence {
        trimming(bytes, while: isLinearWhitespace)
    }

    /// Drops leading and trailing SP, HTAB, CR and LF and returns a slice of the original buffer.
    ///
    /// Use this for a header value taken from a buffer whose line terminator has not been removed
    /// yet; use `trimmingLinearWhitespace` once framing is off.
    public static func trimmingWhitespace<Bytes: BidirectionalCollection<UInt8>>(
        _ bytes: Bytes
    ) -> Bytes.SubSequence {
        trimming(bytes, while: isWhitespace)
    }

    private static func trimming<Bytes: BidirectionalCollection<UInt8>>(
        _ bytes: Bytes,
        while shouldDrop: (UInt8) -> Bool
    ) -> Bytes.SubSequence {
        var start = bytes.startIndex
        var end = bytes.endIndex
        while start != end, shouldDrop(bytes[start]) { bytes.formIndex(after: &start) }
        while start != end {
            let previous = bytes.index(before: end)
            guard shouldDrop(bytes[previous]) else { break }
            end = previous
        }
        return bytes[start..<end]
    }

    // MARK: - Splitting

    /// Splits `bytes` on every occurrence of `separator`.
    ///
    /// Unlike `Collection.split(separator:)` this **keeps** empty subsequences by default,
    /// because a protocol field that is present but empty (`a=fmtp:96 mode=;config=1408`) is not
    /// the same as an absent one. The returned slices share the input's storage; only the array
    /// spine is allocated.
    public static func split<Bytes: Collection<UInt8>>(
        _ bytes: Bytes,
        on separator: UInt8,
        maxSplits: Int = .max,
        omittingEmptySubsequences: Bool = false
    ) -> [Bytes.SubSequence] {
        bytes.split(
            maxSplits: maxSplits,
            omittingEmptySubsequences: omittingEmptySubsequences
        ) { $0 == separator }
    }

    /// Splits `bytes` at the **first** `separator` only, allocating nothing.
    ///
    /// This is the header-line workhorse: `Content-Length: 42` splits on `:` into
    /// `("Content-Length", " 42")`, and a value containing further colons stays intact.
    ///
    /// - Returns: `tail` is `nil` when `separator` does not occur, and an empty slice when it
    ///   occurs as the last byte — the two cases are distinguishable, which matters for a header
    ///   with an empty value.
    public static func splitOnce<Bytes: Collection<UInt8>>(
        _ bytes: Bytes,
        on separator: UInt8
    ) -> (head: Bytes.SubSequence, tail: Bytes.SubSequence?) {
        guard let position = bytes.firstIndex(of: separator) else {
            return (bytes[bytes.startIndex..<bytes.endIndex], nil)
        }
        let afterSeparator = bytes.index(after: position)
        return (bytes[bytes.startIndex..<position], bytes[afterSeparator..<bytes.endIndex])
    }
}
