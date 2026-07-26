//
//  ASCIITests.swift
//  VigilProtocolsTests
//
//  Case folding, RFC 7230 classification, trimming and splitting for `ASCII`. The central
//  assertions are that folding touches only A–Z / a–z and that comparison is neither locale- nor
//  Unicode-sensitive — the Turkish dotless-I bug this type exists to prevent.
//  Covers docs/spec-rtsp.md §3.1/§4.5 and docs/spec-isapi.md §7.
//

import Testing

import VigilProtocols

// MARK: - Case folding

@Test func lowercasesEveryASCIIUppercaseLetter() {
    for byte in UInt8(ascii: "A")...UInt8(ascii: "Z") {
        #expect(ASCII.lowercased(byte) == byte + 0x20)
        #expect(ASCII.uppercased(byte) == byte)
    }
}

@Test func uppercasesEveryASCIILowercaseLetter() {
    for byte in UInt8(ascii: "a")...UInt8(ascii: "z") {
        #expect(ASCII.uppercased(byte) == byte - 0x20)
        #expect(ASCII.lowercased(byte) == byte)
    }
}

@Test func leavesEveryNonLetterASCIIByteUnchanged() {
    for value in 0...0x7F {
        let byte = UInt8(value)
        let isLetter = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
        guard !isLetter else { continue }
        #expect(ASCII.lowercased(byte) == byte, "byte 0x\(String(value, radix: 16))")
        #expect(ASCII.uppercased(byte) == byte, "byte 0x\(String(value, radix: 16))")
    }
    // The bytes adjacent to the letter ranges are the ones a `|= 0x20` bug corrupts first:
    // '@' 0x40, '[' 0x5B, '`' 0x60, '{' 0x7B.
    for byte in [UInt8(ascii: "@"), UInt8(ascii: "["), UInt8(ascii: "`"), UInt8(ascii: "{")] {
        #expect(ASCII.lowercased(byte) == byte)
        #expect(ASCII.uppercased(byte) == byte)
    }
}

@Test func neverAltersBytesAboveASCII() {
    for value in 0x80...0xFF {
        let byte = UInt8(value)
        #expect(ASCII.lowercased(byte) == byte, "byte 0x\(String(value, radix: 16))")
        #expect(ASCII.uppercased(byte) == byte, "byte 0x\(String(value, radix: 16))")
    }
}

@Test func lowercasesAndUppercasesASliceWithoutTouchingNonLetters() {
    let input = Array("Content-Length: 42 é".utf8)
    #expect(ASCII.lowercased(input) == Array("content-length: 42 é".utf8))
    #expect(ASCII.uppercased(input) == Array("CONTENT-LENGTH: 42 é".utf8))
}

@Test func lowercasesAMutableBufferInPlace() {
    var bytes = Array("RTSP/1.0 200 OK".utf8)
    ASCII.lowercaseInPlace(&bytes)
    #expect(bytes == Array("rtsp/1.0 200 ok".utf8))

    var slice = Array("ABCdef".utf8)[1...3]
    ASCII.lowercaseInPlace(&slice)
    #expect(Array(slice) == Array("bcd".utf8))
}

// MARK: - Locale and Unicode independence

/// The reason this file exists. A locale-aware `tolower` maps 'I' to U+0131 under `tr_TR`, and
/// Unicode full case folding maps U+0130 to "i" + U+0307. Either would break header matching.
@Test func caseFoldingIsNeitherLocaleNorUnicodeSensitive() {
    // Plain ASCII 'I' always folds to ASCII 'i', never to the dotless ı (U+0131).
    #expect(ASCII.lowercased(UInt8(ascii: "I")) == UInt8(ascii: "i"))

    // U+0130 LATIN CAPITAL LETTER I WITH DOT ABOVE is 0xC4 0xB0 in UTF-8: both bytes are above
    // ASCII, so neither is touched.
    let dottedCapitalI = Array("\u{130}".utf8)
    #expect(dottedCapitalI == [0xC4, 0xB0])
    #expect(ASCII.lowercased(dottedCapitalI) == dottedCapitalI)

    // U+0131 LATIN SMALL LETTER DOTLESS I is 0xC4 0xB1 and is likewise left alone.
    let dotlessI = Array("\u{131}".utf8)
    #expect(dotlessI == [0xC4, 0xB1])
    #expect(ASCII.uppercased(dotlessI) == dotlessI)

    // Neither Turkish letter is case-insensitively equal to ASCII "i" or "I".
    #expect(!ASCII.equalsIgnoringCase(dottedCapitalI, "i"))
    #expect(!ASCII.equalsIgnoringCase(dottedCapitalI, "I"))
    #expect(!ASCII.equalsIgnoringCase(dotlessI, "i"))
    #expect(!ASCII.equalsIgnoringCase(dotlessI, dottedCapitalI))
}

@Test func stringLowercasingIsASCIIOnlyAndDivergesFromUnicodeCaseFolding() {
    // "İSTANBUL": U+0130 followed by ASCII. We lowercase only the ASCII tail.
    let input = "\u{130}STANBUL"
    #expect(ASCII.lowercased(input) == "\u{130}stanbul")
    // Swift's Unicode-correct lowercasing expands U+0130 into "i" + U+0307, changing the byte
    // length. A parser keyed on byte offsets must not use it.
    #expect("\u{130}STANBUL".lowercased() == "i\u{307}stanbul")
    #expect(ASCII.lowercased(input) != input.lowercased())

    // A string with no ASCII uppercase letter comes back unchanged.
    #expect(ASCII.lowercased("content-length") == "content-length")
    #expect(ASCII.lowercased("videoResolutionWidth") == "videoresolutionwidth")
}

// MARK: - Case-insensitive comparison

@Test func caseInsensitiveComparisonCoversTheFullAlphabet() {
    let upper = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
    let lower = Array("abcdefghijklmnopqrstuvwxyz".utf8)
    #expect(ASCII.equalsIgnoringCase(upper, lower))
    #expect(ASCII.equalsIgnoringCase(lower, upper))
    #expect(ASCII.equalsIgnoringCase(upper, upper))
    for index in upper.indices {
        var mixed = lower
        mixed[index] = upper[index]
        #expect(ASCII.equalsIgnoringCase(mixed, upper), "letter \(index)")
    }
}

@Test func caseInsensitiveComparisonMatchesRealHeaderNames() {
    let name = Array("cOnTeNt-LeNgTh".utf8)
    #expect(ASCII.equalsIgnoringCase(name, "content-length"))
    #expect(ASCII.equalsIgnoringCase(name, "CONTENT-LENGTH"))
    #expect(!ASCII.equalsIgnoringCase(name, "content_length"))
    #expect(!ASCII.equalsIgnoringCase(name, "content-lengths"))
    #expect(!ASCII.equalsIgnoringCase(name, "content-lengt"))
    #expect(!ASCII.equalsIgnoringCase(Array("".utf8), "x"))
    #expect(ASCII.equalsIgnoringCase(Array("".utf8), Array("".utf8)))
}

@Test func caseInsensitiveComparisonWorksOnASliceOfALargerBuffer() throws {
    let line = Array("WWW-Authenticate: Digest realm=\"IP Camera(51253)\"".utf8)
    let (name, value) = ASCII.splitOnce(line, on: UInt8(ascii: ":"))
    #expect(ASCII.equalsIgnoringCase(name, "www-authenticate"))
    let trimmed = ASCII.trimmingLinearWhitespace(try #require(value))
    #expect(ASCII.hasPrefixIgnoringCase(trimmed, "digest "))
}

@Test func caseInsensitiveComparisonWorksOverAnUnsafeRawBufferPointer() {
    let bytes = Array("RTSP/1.0".utf8)
    bytes.withUnsafeBytes { raw in
        #expect(ASCII.equalsIgnoringCase(raw, "rtsp/1.0"))
        #expect(ASCII.hasPrefixIgnoringCase(raw, "rtsp/"))
        #expect(!ASCII.equalsIgnoringCase(raw, "rtsp/1.1"))
        #expect(Array(ASCII.trimmingLinearWhitespace(raw)) == bytes)
    }
}

@Test func prefixComparisonHandlesBoundaryCases() {
    let bytes = Array("Basic".utf8)
    #expect(ASCII.hasPrefixIgnoringCase(bytes, "BASIC"))
    #expect(ASCII.hasPrefixIgnoringCase(bytes, "b"))
    #expect(ASCII.hasPrefixIgnoringCase(bytes, ""))
    #expect(!ASCII.hasPrefixIgnoringCase(bytes, "basics"))
    #expect(!ASCII.hasPrefixIgnoringCase(Array("".utf8), "b"))
}

// MARK: - Classification

@Test func tokenClassificationMatchesRFC7230() {
    // RFC 7230 §3.2.6: tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+" / "-" / "." /
    //                          "^" / "_" / "`" / "|" / "~" / DIGIT / ALPHA
    let punctuation = Set(Array("!#$%&'*+-.^_`|~".utf8))
    for value in 0...0xFF {
        let byte = UInt8(value)
        let isAlphanumeric = (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A)
        let expected = isAlphanumeric || punctuation.contains(byte)
        #expect(ASCII.isTokenByte(byte) == expected, "byte 0x\(String(value, radix: 16))")
    }
    // The separators that force a quoted string are explicitly not token bytes.
    for byte in Array("\"(),/:;<=>?@[\\]{} \t".utf8) {
        #expect(!ASCII.isTokenByte(byte))
    }
    #expect(ASCII.isToken(Array("Content-Length".utf8)))
    #expect(!ASCII.isToken(Array("Content Length".utf8)))
    #expect(!ASCII.isToken(Array("".utf8)), "an empty slice is not a token")
}

@Test func whitespaceClassificationSeparatesLinearWhitespaceFromLineEndings() {
    #expect(ASCII.isLinearWhitespace(UInt8(ascii: " ")))
    #expect(ASCII.isLinearWhitespace(0x09))
    #expect(!ASCII.isLinearWhitespace(0x0D))
    #expect(!ASCII.isLinearWhitespace(0x0A))
    #expect(!ASCII.isLinearWhitespace(0x0B))
    #expect(ASCII.isNewline(0x0D))
    #expect(ASCII.isNewline(0x0A))
    #expect(ASCII.isWhitespace(0x20))
    #expect(ASCII.isWhitespace(0x09))
    #expect(ASCII.isWhitespace(0x0D))
    #expect(ASCII.isWhitespace(0x0A))
    for value in 0...0xFF where ![0x09, 0x0A, 0x0D, 0x20].contains(value) {
        #expect(!ASCII.isWhitespace(UInt8(value)), "byte 0x\(String(value, radix: 16))")
    }
}

@Test func letterAndDigitAndHexClassification() {
    #expect(ASCII.isLetter(UInt8(ascii: "Z")))
    #expect(ASCII.isLetter(UInt8(ascii: "z")))
    #expect(!ASCII.isLetter(UInt8(ascii: "0")))
    #expect(ASCII.isDigit(UInt8(ascii: "0")))
    #expect(ASCII.isDigit(UInt8(ascii: "9")))
    #expect(!ASCII.isDigit(UInt8(ascii: "/")))
    #expect(!ASCII.isDigit(UInt8(ascii: ":")))
    #expect(ASCII.isVisible(0x21))
    #expect(ASCII.isVisible(0x7E))
    #expect(!ASCII.isVisible(0x20))
    #expect(!ASCII.isVisible(0x7F))
    #expect(!ASCII.isVisible(0x80))
}

@Test func hexDigitValueAcceptsBothCasesAndRejectsEverythingElse() {
    #expect(ASCII.hexDigitValue(UInt8(ascii: "0")) == 0)
    #expect(ASCII.hexDigitValue(UInt8(ascii: "9")) == 9)
    #expect(ASCII.hexDigitValue(UInt8(ascii: "a")) == 10)
    #expect(ASCII.hexDigitValue(UInt8(ascii: "A")) == 10)
    #expect(ASCII.hexDigitValue(UInt8(ascii: "f")) == 15)
    #expect(ASCII.hexDigitValue(UInt8(ascii: "F")) == 15)
    #expect(ASCII.hexDigitValue(UInt8(ascii: "g")) == nil)
    #expect(ASCII.hexDigitValue(UInt8(ascii: "G")) == nil)
    #expect(ASCII.hexDigitValue(UInt8(ascii: "/")) == nil)
    #expect(ASCII.hexDigitValue(0xFF) == nil)
    let hexDigits = Set(Array("0123456789abcdefABCDEF".utf8))
    for value in 0...0xFF {
        #expect(ASCII.isHexDigit(UInt8(value)) == hexDigits.contains(UInt8(value)))
    }
}

// MARK: - Trimming

@Test func trimsLeadingAndTrailingLinearWhitespaceOnly() {
    let value = Array(" \t Digest realm=\"x\" \t ".utf8)
    #expect(Array(ASCII.trimmingLinearWhitespace(value)) == Array("Digest realm=\"x\"".utf8))
    // Interior whitespace is preserved.
    #expect(Array(ASCII.trimmingLinearWhitespace(Array("a  b".utf8))) == Array("a  b".utf8))
    // CR and LF are framing, not padding: trimmingLinearWhitespace leaves them.
    #expect(Array(ASCII.trimmingLinearWhitespace(Array(" a\r\n".utf8))) == Array("a\r\n".utf8))
    // Degenerate inputs.
    #expect(ASCII.trimmingLinearWhitespace(Array("".utf8)).isEmpty)
    #expect(ASCII.trimmingLinearWhitespace(Array("   ".utf8)).isEmpty)
    #expect(ASCII.trimmingLinearWhitespace(Array("\t\t".utf8)).isEmpty)
}

@Test func trimmingWhitespaceAlsoDropsCarriageReturnAndLineFeed() {
    #expect(Array(ASCII.trimmingWhitespace(Array(" a\r\n".utf8))) == Array("a".utf8))
    #expect(Array(ASCII.trimmingWhitespace(Array("\r\n\r\n".utf8))).isEmpty)
    #expect(Array(ASCII.trimmingWhitespace(Array("42".utf8))) == Array("42".utf8))
}

@Test func trimmingReturnsASliceOfTheOriginalBuffer() {
    let buffer = Array("  abc  ".utf8)
    let trimmed = ASCII.trimmingLinearWhitespace(buffer)
    // Indices are still those of the parent buffer, which is what makes it allocation-free.
    #expect(trimmed.startIndex == 2)
    #expect(trimmed.endIndex == 5)
}

// MARK: - Splitting

@Test func splitKeepsEmptySubsequencesByDefault() {
    // A parameter that is present but empty is not the same as an absent one.
    let parameters = Array("mode=;config=1408;".utf8)
    let parts = ASCII.split(parameters, on: UInt8(ascii: ";"))
    #expect(parts.count == 3)
    #expect(Array(parts[0]) == Array("mode=".utf8))
    #expect(Array(parts[1]) == Array("config=1408".utf8))
    #expect(parts[2].isEmpty)

    let compacted = ASCII.split(parameters, on: UInt8(ascii: ";"), omittingEmptySubsequences: true)
    #expect(compacted.count == 2)
}

@Test func splitHonoursMaxSplits() {
    let parts = ASCII.split(Array("a,b,c,d".utf8), on: UInt8(ascii: ","), maxSplits: 1)
    #expect(parts.count == 2)
    #expect(Array(parts[0]) == Array("a".utf8))
    #expect(Array(parts[1]) == Array("b,c,d".utf8))
}

@Test func splitOnceSplitsAtTheFirstSeparatorOnly() {
    let line = Array("a=fmtp:96 profile-level-id=640028".utf8)
    let (head, tail) = ASCII.splitOnce(line, on: UInt8(ascii: ":"))
    #expect(Array(head) == Array("a=fmtp".utf8))
    #expect(Array(tail ?? []) == Array("96 profile-level-id=640028".utf8))

    // A value containing the separator keeps it.
    let control = Array("control:rtsp://host:554/path".utf8)
    let (name, rest) = ASCII.splitOnce(control, on: UInt8(ascii: ":"))
    #expect(Array(name) == Array("control".utf8))
    #expect(Array(rest ?? []) == Array("rtsp://host:554/path".utf8))
}

@Test func splitOnceDistinguishesAbsentFromEmptyTail() {
    let (head, tail) = ASCII.splitOnce(Array("no-separator".utf8), on: UInt8(ascii: ":"))
    #expect(Array(head) == Array("no-separator".utf8))
    #expect(tail == nil)

    let (name, value) = ASCII.splitOnce(Array("X-Empty:".utf8), on: UInt8(ascii: ":"))
    #expect(Array(name) == Array("X-Empty".utf8))
    #expect(value?.isEmpty == true)

    let (empty, remainder) = ASCII.splitOnce(Array(":value".utf8), on: UInt8(ascii: ":"))
    #expect(empty.isEmpty)
    #expect(Array(remainder ?? []) == Array("value".utf8))

    let (nothing, none) = ASCII.splitOnce(Array("".utf8), on: UInt8(ascii: ":"))
    #expect(nothing.isEmpty)
    #expect(none == nil)
}
