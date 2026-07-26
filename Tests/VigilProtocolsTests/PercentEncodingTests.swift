//
//  PercentEncodingTests.swift
//  VigilProtocolsTests
//
//  RFC 3986 percent-encoding for RTSP URLs and ISAPI query parameters. The load-bearing
//  assertions are that `+` is never a space (this is a URI, not a form body) and that malformed
//  escapes throw instead of passing the `%` through.
//  Covers docs/spec-rtsp.md §10.1 and docs/spec-isapi.md §4.1.
//

import Testing

import VigilProtocols

private typealias Allowed = PercentEncoding.AllowedBytes

// MARK: - Round trip

@Test func roundTripsThroughTheUnreservedSet() throws {
    let samples = [
        "",
        "simple",
        "with space",
        "slash/and?question",
        "Hik@12345",
        "#hash&amp=1;2",
        "unicode é ü 中文",
        "control\u{00}\u{01}\u{7F}",
        "percent % literal",
        "already%20encoded",
    ]
    for sample in samples {
        let encoded = PercentEncoding.encode(sample, allowing: .unreserved)
        #expect(try PercentEncoding.decode(encoded) == sample, "\(sample.debugDescription)")
    }
}

@Test func roundTripsEveryByteValue() throws {
    let all = (0...255).map { UInt8($0) }
    let encoded = PercentEncoding.encode(utf8: all, allowing: .unreserved)
    #expect(try PercentEncoding.decodeBytes(utf8: Array(encoded.utf8)) == all)
}

@Test func unreservedCharactersAreNeverEscaped() {
    // RFC 3986 §2.3: ALPHA / DIGIT / "-" / "." / "_" / "~".
    let unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    #expect(PercentEncoding.encode(unreserved, allowing: .unreserved) == unreserved)
}

// MARK: - Escape form

@Test func encodeUsesUppercaseHex() {
    // RFC 3986 §2.1 prefers uppercase in an escape.
    #expect(PercentEncoding.encode(" ", allowing: .unreserved) == "%20")
    #expect(PercentEncoding.encode("/", allowing: .unreserved) == "%2F")
    #expect(PercentEncoding.encode("\u{7F}", allowing: .unreserved) == "%7F")
    #expect(PercentEncoding.encode("é", allowing: .unreserved) == "%C3%A9")
    #expect(PercentEncoding.encode(utf8: [0x00, 0xAB, 0xFF], allowing: .unreserved) == "%00%AB%FF")
}

@Test func decodeAcceptsBothUppercaseAndLowercaseHex() throws {
    #expect(try PercentEncoding.decode("%2F") == "/")
    #expect(try PercentEncoding.decode("%2f") == "/")
    #expect(try PercentEncoding.decode("%7E") == "~")
    #expect(try PercentEncoding.decode("%7e") == "~")
    #expect(try PercentEncoding.decode("%c3%a9") == "é")
    #expect(try PercentEncoding.decode("%C3%a9") == "é")
    // Over-escaping an unreserved character is legal input and decodes normally.
    #expect(try PercentEncoding.decode("%41%42%43") == "ABC")
}

// MARK: - '+' is not a space

@Test func plusIsNotDecodedAsASpace() throws {
    // application/x-www-form-urlencoded maps '+' to space. A URI does not, and neither does
    // Hikvision, so a password of "a+b" must survive as "a+b".
    #expect(try PercentEncoding.decode("a+b") == "a+b")
    #expect(try PercentEncoding.decode("Hik+12345") == "Hik+12345")
    #expect(try PercentEncoding.decode("%2B") == "+")
    #expect(try PercentEncoding.decode("a+b%20c") == "a+b c")
}

@Test func queryComponentEncodesPlusAsPercent2B() {
    // docs/spec-isapi.md §4.1: query items are encoded with '+' as %2B because the device does
    // not decode '+' as a space.
    #expect(PercentEncoding.encode("a+b", allowing: .queryComponent) == "a%2Bb")
    #expect(PercentEncoding.encode("a b", allowing: .queryComponent) == "a%20b")
    #expect(PercentEncoding.encode("a&b=c", allowing: .queryComponent) == "a%26b%3Dc")
}

// MARK: - Allowed-set behaviour

@Test func allowedSetChoiceDecidesWhatSurvives() {
    #expect(PercentEncoding.encode("/", allowing: .path) == "/")
    #expect(PercentEncoding.encode("/", allowing: .pathSegment) == "%2F")
    // Hikvision control segments are literally "trackID=1"; '=' is a sub-delim and must survive
    // inside a path segment (docs/spec-rtsp.md §8.3).
    #expect(PercentEncoding.encode("trackID=1", allowing: .pathSegment) == "trackID=1")
    #expect(PercentEncoding.encode("trackID=1", allowing: .queryComponent) == "trackID%3D1")
    #expect(PercentEncoding.encode("?", allowing: .path) == "%3F")
    #expect(PercentEncoding.encode("?", allowing: .query) == "?")
}

@Test func userInfoComponentEscapesEveryAuthoritySeparator() throws {
    // Hikvision passwords commonly contain '@', '#', '/' and ':'.
    let password = "Hik@12345#/:"
    let encoded = PercentEncoding.encode(password, allowing: .userInfoComponent)
    #expect(encoded == "Hik%4012345%23%2F%3A")
    #expect(try PercentEncoding.decode(encoded) == password)
}

@Test func allowedSetSupportsCustomMembership() {
    var custom = Allowed()
    custom.insert(UInt8(ascii: "a"))
    custom.insert(contentsOf: "xyz")
    custom.insert(contentsOf: UInt8(ascii: "0")...UInt8(ascii: "9"))
    #expect(custom.contains(UInt8(ascii: "a")))
    #expect(custom.contains(UInt8(ascii: "z")))
    #expect(custom.contains(UInt8(ascii: "5")))
    #expect(!custom.contains(UInt8(ascii: "b")))
    #expect(PercentEncoding.encode("abz09", allowing: custom) == "a%62z09")

    let merged = custom.union(Allowed("b"))
    #expect(merged.contains(UInt8(ascii: "b")))
    #expect(Allowed() == Allowed())
    #expect(merged != custom)

    // The bitmap must address all four words: 0x00-0x3F, 0x40-0x7F, 0x80-0xBF, 0xC0-0xFF.
    var full = Allowed()
    for value in 0...255 { full.insert(UInt8(value)) }
    for value in 0...255 { #expect(full.contains(UInt8(value)), "byte \(value)") }
    var empty = Allowed()
    empty.insert(0xFF)
    #expect(empty.contains(0xFF))
    #expect(!empty.contains(0xFE))
    #expect(!empty.contains(0x3F))
}

// MARK: - Malformed input

@Test func throwsOnTruncatedEscape() {
    #expect(throws: PercentEncodingError.truncatedEscape(offset: 0)) {
        try PercentEncoding.decode("%")
    }
    #expect(throws: PercentEncodingError.truncatedEscape(offset: 3)) {
        try PercentEncoding.decode("abc%")
    }
    #expect(throws: PercentEncodingError.truncatedEscape(offset: 3)) {
        try PercentEncoding.decode("abc%4")
    }
    #expect(throws: PercentEncodingError.truncatedEscape(offset: 6)) {
        try PercentEncoding.decode("%41%42%4")
    }
}

@Test func throwsOnNonHexEscape() {
    #expect(throws: PercentEncodingError.invalidHexDigit(byte: UInt8(ascii: "Z"), offset: 1)) {
        try PercentEncoding.decode("%ZZ")
    }
    #expect(throws: PercentEncodingError.invalidHexDigit(byte: UInt8(ascii: "Z"), offset: 2)) {
        try PercentEncoding.decode("%2Z")
    }
    #expect(throws: PercentEncodingError.invalidHexDigit(byte: UInt8(ascii: "G"), offset: 1)) {
        try PercentEncoding.decode("%G1")
    }
    #expect(throws: PercentEncodingError.invalidHexDigit(byte: UInt8(ascii: "%"), offset: 1)) {
        try PercentEncoding.decode("%%20")
    }
    // The offset points into the input, past the characters that decoded cleanly: the second
    // '%' sits at input offset 5, so its first hex digit is offset 6.
    #expect(throws: PercentEncodingError.invalidHexDigit(byte: UInt8(ascii: " "), offset: 6)) {
        try PercentEncoding.decode("ab%41% 0")
    }
}

@Test func throwsWhenDecodedBytesAreNotValidUTF8() throws {
    // A lone 0xFF can never appear in UTF-8. `decode` refuses rather than substituting U+FFFD,
    // which would silently corrupt a password; `decodeBytes` returns it untouched.
    #expect(throws: PercentEncodingError.invalidUTF8(byteCount: 1)) {
        try PercentEncoding.decode("%FF")
    }
    #expect(try PercentEncoding.decodeBytes(utf8: Array("%FF".utf8)) == [0xFF])
    // A truncated multi-byte sequence is rejected the same way.
    #expect(throws: PercentEncodingError.invalidUTF8(byteCount: 1)) {
        try PercentEncoding.decode("%C3")
    }
    #expect(try PercentEncoding.decodeBytes(utf8: Array("%C3%A9".utf8)) == [0xC3, 0xA9])
}

@Test func percentDecodeOrNilReportsFailureWithoutThrowing() {
    #expect(PercentEncoding.decodeOrNil("a%20b") == "a b")
    #expect(PercentEncoding.decodeOrNil("a%2") == nil)
    #expect(PercentEncoding.decodeOrNil("%ZZ") == nil)
    #expect(PercentEncoding.decodeOrNil("") == "")
}

// MARK: - Degenerate input

@Test func handlesEmptyAndEscapeOnlyInput() throws {
    #expect(PercentEncoding.encode("", allowing: .unreserved) == "")
    #expect(try PercentEncoding.decode("") == "")
    #expect(try PercentEncoding.decodeBytes(utf8: Array("".utf8)) == [])
    #expect(try PercentEncoding.decodeBytes(utf8: Array("%00".utf8)) == [0x00])
    #expect(try PercentEncoding.decodeBytes(utf8: Array("%25".utf8)) == Array("%".utf8))
    #expect(try PercentEncoding.decode("%25%32%30") == "%20", "decoding is not applied twice")
}

@Test func decodesARealisticISAPIRequestURI() throws {
    // docs/spec-isapi.md §6: the digest URI is the request line's path plus query, verbatim.
    let uri = "/ISAPI/Streaming/channels/101/picture?videoResolutionWidth=640"
    #expect(try PercentEncoding.decode(uri) == uri, "nothing to unescape leaves it untouched")

    let starttime = "20240501T043456Z"
    let encoded = PercentEncoding.encode(starttime, allowing: .queryComponent)
    #expect(encoded == starttime)
}
