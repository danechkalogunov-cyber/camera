//
//  Base64Tests.swift
//  VigilProtocolsTests
//
//  RFC 4648 conformance for `Base64`, plus the padding/whitespace/URL-safe leniency that
//  Hikvision SDP requires and the rejection cases that keep leniency from becoming garbage.
//  Covers docs/spec-rtsp.md §6.3, §8.6 and the `Base64Tests` row of §18.
//

import Testing

import VigilProtocols

// MARK: - Fixtures

/// RFC 4648 §10 "Test Vectors". Quoted exactly as published.
private let rfc4648Vectors: [(plain: String, encoded: String)] = [
    ("", ""),
    ("f", "Zg=="),
    ("fo", "Zm8="),
    ("foo", "Zm9v"),
    ("foob", "Zm9vYg=="),
    ("fooba", "Zm9vYmE="),
    ("foobar", "Zm9vYmFy"),
]

/// Decodes a hex string used as an expected value. Local to this file so the Base64 tests do not
/// depend on another agent's `HexEncoding`.
private func expectedBytes(hex: String) -> [UInt8] {
    var out = [UInt8]()
    var high: UInt8?
    for character in hex.utf8 {
        guard let value = ASCII.hexDigitValue(character) else { continue }
        if let pending = high {
            out.append(pending << 4 | value)
            high = nil
        } else {
            high = value
        }
    }
    return out
}

/// Removes trailing `=` so a padded published value can be tested in its unpadded form.
private func unpadded(_ encoded: String) -> String {
    String(encoded.reversed().drop { $0 == "=" }.reversed())
}

// MARK: - Encoding

@Test func encodeMatchesRFC4648TestVectors() {
    for vector in rfc4648Vectors {
        #expect(Base64.encode(Array(vector.plain.utf8)) == vector.encoded)
    }
}

@Test func encodeOmitsPaddingWhenAskedTo() {
    for vector in rfc4648Vectors {
        let expected = unpadded(vector.encoded)
        #expect(Base64.encode(Array(vector.plain.utf8), padded: false) == expected)
    }
}

@Test func encodeUsesURLSafeAlphabetWhenAskedTo() {
    // 0xFB 0xFF is the shortest payload that produces both '+' and '/' in the standard alphabet.
    let payload: [UInt8] = [0xFB, 0xFF]
    #expect(Base64.encode(payload) == "+/8=")
    #expect(Base64.encode(payload, alphabet: .urlSafe) == "-_8=")
    #expect(Base64.encode(payload, alphabet: .urlSafe, padded: false) == "-_8")
}

// MARK: - Decoding

@Test func decodeMatchesRFC4648TestVectors() throws {
    for vector in rfc4648Vectors {
        #expect(try Base64.decode(vector.encoded) == Array(vector.plain.utf8))
        #expect(try Base64.decodeStrict(vector.encoded) == Array(vector.plain.utf8))
    }
}

@Test func decodeAcceptsEmptyInput() throws {
    #expect(try Base64.decode("") == [])
    #expect(try Base64.decodeStrict("") == [])
}

@Test func roundTripsEveryByteValueAtEveryLength() throws {
    let allByteValues = (0...255).map { UInt8($0) }
    for length in 0...allByteValues.count {
        let payload = Array(allByteValues[0..<length])
        let padded = Base64.encode(payload)
        #expect(try Base64.decode(padded) == payload, "padded, length \(length)")
        #expect(try Base64.decodeStrict(padded) == payload, "strict, length \(length)")
        #expect(try Base64.decode(Base64.encode(payload, padded: false)) == payload,
                "unpadded, length \(length)")
        #expect(try Base64.decode(Base64.encode(payload, alphabet: .urlSafe)) == payload,
                "url-safe, length \(length)")
    }
}

@Test func decodeAcceptsMissingPaddingInAllThreeCases() throws {
    // 0 / 1 / 2 padding characters, each with and without the '=' present.
    let cases: [(padded: String, plain: [UInt8])] = [
        ("Zm9vYmFy", Array("foobar".utf8)),   // 0 padding bytes
        ("Zm9vYmE=", Array("fooba".utf8)),    // 1 padding byte
        ("Zm9vYg==", Array("foob".utf8)),     // 2 padding bytes
    ]
    for item in cases {
        #expect(try Base64.decode(item.padded) == item.plain)
        #expect(try Base64.decode(unpadded(item.padded)) == item.plain)
    }
}

@Test func decodeIgnoresWhitespaceAtEveryPosition() throws {
    let encoded = "Zm9vYmE="
    let expected = Array("fooba".utf8)
    // SDP folds long a=fmtp lines and XML pretty-printers indent blobs, so whitespace can land
    // anywhere, including immediately before the padding.
    for whitespace in [" ", "\t", "\r\n", " \r\n\t "] {
        for position in 0...encoded.count {
            let index = encoded.index(encoded.startIndex, offsetBy: position)
            var folded = encoded
            folded.insert(contentsOf: whitespace, at: index)
            #expect(try Base64.decode(folded) == expected,
                    "whitespace \(whitespace.debugDescription) at \(position)")
        }
    }
}

@Test func decodeAcceptsURLSafeAlphabetInterchangeably() throws {
    let expected: [UInt8] = [0xFB, 0xFF]
    #expect(try Base64.decode("+/8=") == expected)
    #expect(try Base64.decode("-_8=") == expected)
    #expect(try Base64.decode("-_8") == expected)
    // A mixed value is nonsense but unambiguous, so leniency accepts it rather than guessing.
    #expect(try Base64.decode("+_8=") == expected)
}

// MARK: - Rejection

@Test func decodeRejectsCharacterOutsideBothAlphabets() {
    #expect(throws: Base64Error.invalidCharacter(byte: UInt8(ascii: "$"), offset: 2)) {
        try Base64.decode("Zm$vYmFy")
    }
    // Bytes above ASCII are never alphabet characters.
    #expect(throws: Base64Error.invalidCharacter(byte: 0xFF, offset: 1)) {
        try Base64.decode(utf8: [UInt8(ascii: "Z"), 0xFF, UInt8(ascii: "9"), UInt8(ascii: "v")])
    }
}

@Test func decodeRejectsLengthOfOneModuloFour() {
    // Nine alphabet characters cannot encode a whole number of bytes.
    #expect(throws: Base64Error.invalidLength(significantCharacters: 9)) {
        try Base64.decode("Zm9vYmFyZ")
    }
    #expect(throws: Base64Error.invalidLength(significantCharacters: 1)) {
        try Base64.decode("Z")
    }
    // Whitespace does not change the count that matters.
    #expect(throws: Base64Error.invalidLength(significantCharacters: 9)) {
        try Base64.decode("Zm9v\r\n YmFyZ")
    }
}

@Test func decodeRejectsTruncatedFinalGroup() {
    // "Zm9vYmE=" with its last data character lost: the trailing group holds a single sextet.
    #expect(throws: Base64Error.invalidLength(significantCharacters: 5)) {
        try Base64.decode("Zm9vY=")
    }
    #expect(throws: Base64Error.invalidLength(significantCharacters: 5)) {
        try Base64.decode("Zm9vY")
    }
}

@Test func decodeRejectsMisplacedAndTrailingPadding() {
    // '=' with no incomplete group pending.
    #expect(throws: Base64Error.misplacedPadding(offset: 0)) { try Base64.decode("=") }
    #expect(throws: Base64Error.misplacedPadding(offset: 0)) { try Base64.decode("====") }
    #expect(throws: Base64Error.misplacedPadding(offset: 4)) { try Base64.decode("Zm9v=") }
}

@Test func decodeRejectsAlphabetCharacterAfterPadding() {
    #expect(throws: Base64Error.dataAfterPadding(offset: 3)) { try Base64.decode("Zg=Z") }
    #expect(throws: Base64Error.dataAfterPadding(offset: 4)) { try Base64.decode("Zg==Zg==") }
}

@Test func base64DecodeOrNilReportsFailureWithoutThrowing() {
    #expect(Base64.decodeOrNil("Zm9vYmFy") == Array("foobar".utf8))
    #expect(Base64.decodeOrNil("Zm9vYmFyZ") == nil)
    #expect(Base64.decodeOrNil("Zm$vYmFy") == nil)
}

// MARK: - Strict decoding

@Test func strictDecodeRejectsWhatLenientDecodeAccepts() {
    #expect(throws: Base64Error.incorrectPadding(expected: 1, found: 0)) {
        try Base64.decodeStrict("Zm9vYmE")
    }
    #expect(throws: Base64Error.incorrectPadding(expected: 2, found: 0)) {
        try Base64.decodeStrict("Zm9vYg")
    }
    #expect(throws: Base64Error.invalidCharacter(byte: UInt8(ascii: "\n"), offset: 4)) {
        try Base64.decodeStrict("Zm9v\nYmFy")
    }
    #expect(throws: Base64Error.invalidCharacter(byte: UInt8(ascii: "-"), offset: 0)) {
        try Base64.decodeStrict("-_8=")
    }
}

@Test func strictDecodeRejectsNonCanonicalTrailingBits() throws {
    // "Zg==" and "Zh==" both carry the byte 0x66; only the first has zero trailing bits
    // (RFC 4648 §3.5). Lenient decoding discards them, strict decoding refuses.
    #expect(try Base64.decode("Zg==") == [0x66])
    #expect(try Base64.decode("Zh==") == [0x66])
    #expect(try Base64.decodeStrict("Zg==") == [0x66])
    #expect(throws: Base64Error.nonCanonicalTrailingBits(bits: 0x01)) {
        try Base64.decodeStrict("Zh==")
    }
}

// MARK: - Hikvision parameter sets

/// The bug this file exists to prevent: a camera that omits `=` padding on `sprop-parameter-sets`
/// must still produce the same SPS bytes, because `Data(base64Encoded:)` returns nil for it and a
/// rejected SPS is a black stream. Values and hex from docs/spec-rtsp.md §8.8 and §8.9.
@Test func hikvisionH264ParameterSetsDecodeIdenticallyWithAndWithoutPadding() throws {
    let sps = "Z2QAKKzZQHgCJ+WEAAADAAQAAAMAwjxgySA="
    let pps = "aO48sA=="
    let expectedSPS = expectedBytes(hex: "67640028ACD940780227E584000003000400000300C23C60C920")
    let expectedPPS = expectedBytes(hex: "68EE3CB0")

    #expect(expectedSPS.count == 26)
    #expect(try Base64.decode(sps) == expectedSPS)
    #expect(try Base64.decode(unpadded(sps)) == expectedSPS)
    #expect(try Base64.decode(pps) == expectedPPS)
    #expect(try Base64.decode(unpadded(pps)) == expectedPPS)

    // The first byte must survive intact: §8.6 classifies the NAL by `nal[0] & 0x1F`.
    let firstSPSByte = try #require(Base64.decode(unpadded(sps)).first)
    let firstPPSByte = try #require(Base64.decode(unpadded(pps)).first)
    #expect(firstSPSByte & 0x1F == 7)
    #expect(firstPPSByte & 0x1F == 8)
}

@Test func hikvisionSubstreamParameterSetsDecodeIdenticallyWithAndWithoutPadding() throws {
    let sps = "Z00AHp2oXBPy4CIAAAMAIAAABlHixdQ="
    let pps = "aO48gA=="
    let expectedSPS = expectedBytes(hex: "674D001E9DA85C13F2E022000003002000000651E2C5D4")
    let expectedPPS = expectedBytes(hex: "68EE3C80")

    #expect(try Base64.decode(sps) == expectedSPS)
    #expect(try Base64.decode(unpadded(sps)) == expectedSPS)
    #expect(try Base64.decode(pps) == expectedPPS)
    #expect(try Base64.decode(unpadded(pps)) == expectedPPS)
}

@Test func hikvisionH265ParameterSetsDecodeIdenticallyWithAndWithoutPadding() throws {
    // sprop-vps is already unpadded on the wire (32 characters, a whole number of quanta) —
    // the exact shape Foundation happens to accept, kept here so the pair is symmetric.
    let vps = "QAEMAf//AWAAAAMAsAAAAwAAAwBdlZgJ"
    let sps = "QgEBAWAAAAMAsAAAAwAAAwBdoAKAgC0WWVmkkyuAQEAAAAMAQAAAB4I="
    let pps = "RAHBcrRiQA=="
    let expectedVPS = expectedBytes(hex: "40010C01FFFF016000000300B0000003000003005D959809")
    let expectedSPS = expectedBytes(
        hex: "420101016000000300B0000003000003005DA00280802D165959A4932B804040000003004000000782"
    )
    let expectedPPS = expectedBytes(hex: "4401C172B46240")

    #expect(expectedVPS.count == 24)
    #expect(expectedSPS.count == 41)
    #expect(expectedPPS.count == 7)
    #expect(try Base64.decode(vps) == expectedVPS)
    #expect(try Base64.decode(sps) == expectedSPS)
    #expect(try Base64.decode(unpadded(sps)) == expectedSPS)
    #expect(try Base64.decode(pps) == expectedPPS)
    #expect(try Base64.decode(unpadded(pps)) == expectedPPS)

    // §8.6 classifies H.265 NALs by `(nal[0] >> 1) & 0x3F`: 32 VPS, 33 SPS, 34 PPS.
    let firstVPSByte = try #require(Base64.decode(vps).first)
    let firstSPSByte = try #require(Base64.decode(unpadded(sps)).first)
    let firstPPSByte = try #require(Base64.decode(unpadded(pps)).first)
    #expect((firstVPSByte >> 1) & 0x3F == 32)
    #expect((firstSPSByte >> 1) & 0x3F == 33)
    #expect((firstPPSByte >> 1) & 0x3F == 34)
}

@Test func hikvisionParameterSetsSurviveALineFoldedFmtpValue() throws {
    // A camera that wraps the a=fmtp line mid-value: the SDP reader hands us the two halves
    // joined by CRLF and a leading space.
    let folded = "Z2QAKKzZQHgCJ+WEAAAD\r\n AAQAAAMAwjxgySA"
    let expected = expectedBytes(hex: "67640028ACD940780227E584000003000400000300C23C60C920")
    #expect(try Base64.decode(folded) == expected)
}

@Test func encodeThenDecodeRoundTripsAHikvisionSPS() throws {
    let expected = expectedBytes(hex: "67640028ACD940780227E584000003000400000300C23C60C920")
    #expect(Base64.encode(expected) == "Z2QAKKzZQHgCJ+WEAAADAAQAAAMAwjxgySA=")
    #expect(try Base64.decodeStrict(Base64.encode(expected)) == expected)
}
