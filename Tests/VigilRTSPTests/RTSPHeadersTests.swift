//
//  RTSPHeadersTests.swift
//  VigilRTSPTests
//
//  The header container: case-insensitive lookup with ASCII-only folding, duplicate preservation,
//  order preservation, OWS trimming, obs-folding and redaction.
//  Covers docs/spec-rtsp.md §2.2 and the RTSPHeadersTests row of §18.2.
//

import Testing

@testable import VigilRTSP

@Suite struct RTSPHeadersTests {

    @Test func headersLookUpNamesCaseInsensitively() {
        let headers = RTSPHeaders([("CSeq", "3"), ("Content-Type", "application/sdp")])
        #expect(headers.first("cseq") == "3")
        #expect(headers.first("CSEQ") == "3")
        #expect(headers.first("Content-type") == "application/sdp")
        #expect(headers.has("CONTENT-TYPE"))
        #expect(headers.first("Session") == nil)
    }

    @Test func headersPreserveOriginalCasingAndOrder() {
        let headers = RTSPHeaders([("CSeq", "1"), ("user-agent", "Vigil/1.0"), ("Accept", "x")])
        #expect(headers.fields.map(\.name) == ["CSeq", "user-agent", "Accept"])
        #expect(headers.fields.map(\.lowercasedName) == ["cseq", "user-agent", "accept"])
    }

    @Test func headersKeepDuplicatesInReceiveOrder() {
        var headers = RTSPHeaders()
        headers.append("WWW-Authenticate", "Digest realm=\"a\"")
        headers.append("www-authenticate", "Basic realm=\"a\"")
        #expect(headers.all("WWW-Authenticate").count == 2)
        #expect(headers.all("WWW-Authenticate")[0].hasPrefix("Digest"))
        #expect(headers.all("WWW-Authenticate")[1].hasPrefix("Basic"))
        #expect(headers.first("WWW-Authenticate")?.hasPrefix("Digest") == true)
    }

    /// `İ` (U+0130) lowercases to `i̇` under Unicode rules. Folding it to `i` would let
    /// `CSeİq`-shaped names collide with real ones, so the container must fold ASCII only.
    @Test func headersFoldASCIIOnlyNotUnicode() {
        let headers = RTSPHeaders([("SESSİON", "1"), ("Session", "2")])
        #expect(headers.first("session") == "2")
        #expect(headers.all("session") == ["2"])
        #expect(headers.first("SESSİON") == "1")
    }

    @Test func headersTrimSurroundingWhitespaceFromValues() {
        let headers = RTSPHeaders([("CSeq", "  4\t"), ("Range", "\tnpt=0.000-  ")])
        #expect(headers.first("CSeq") == "4")
        #expect(headers.int("CSeq") == 4)
        #expect(headers.first("Range") == "npt=0.000-")
    }

    @Test func headersIntRejectsNonNumericValues() {
        let headers = RTSPHeaders([("Content-Length", "12abc"), ("CSeq", "-3")])
        #expect(headers.int("Content-Length") == nil)
        #expect(headers.int("CSeq") == -3)
        #expect(headers.int("Absent") == nil)
    }

    @Test func headersJoinListValuedFields() {
        var headers = RTSPHeaders([("Public", "OPTIONS, DESCRIBE")])
        headers.append("Public", "SETUP, PLAY")
        #expect(headers.joined("public") == "OPTIONS, DESCRIBE, SETUP, PLAY")
        #expect(headers.joined("Unsupported") == nil)
    }

    @Test func headersSetReplacesEveryDuplicateInPlace() {
        var headers = RTSPHeaders([("A", "1"), ("Session", "old"), ("B", "2")])
        headers.append("session", "older")
        headers.set("Session", "new")
        #expect(headers.all("Session") == ["new"])
        #expect(headers.fields.map(\.name) == ["A", "Session", "B"])
    }

    @Test func headersRemoveDropsEveryMatch() {
        var headers = RTSPHeaders([("A", "1"), ("Session", "x")])
        headers.append("SESSION", "y")
        headers.remove("session")
        #expect(headers.all("Session").isEmpty)
        #expect(headers.fields.count == 1)
    }

    @Test func headersFoldContinuationIntoPreviousValue() {
        var headers = RTSPHeaders([("Public", "OPTIONS,")])
        let folded = headers.foldIntoLast("   DESCRIBE")
        #expect(folded)
        #expect(headers.first("Public") == "OPTIONS, DESCRIBE")
    }

    @Test func headersFoldFailsWithNothingToFoldInto() {
        var headers = RTSPHeaders()
        let folded = headers.foldIntoLast(" orphan")
        #expect(!folded)
        #expect(headers.fields.isEmpty)
    }

    @Test func headersDescriptionRedactsAuthorizationValues() {
        let headers = RTSPHeaders([
            ("CSeq", "3"),
            ("Authorization", "Digest username=\"admin\", response=\"33439787cead5b387dab032b929cd5aa\""),
        ])
        let text = headers.description
        #expect(text.contains("CSeq: 3"))
        #expect(!text.contains("33439787cead5b387dab032b929cd5aa"))
    }

    @Test func headersInsertFirstPutsFieldAtFront() {
        var headers = RTSPHeaders([("User-Agent", "Vigil/1.0")])
        headers.insertFirst("CSeq", "9")
        #expect(headers.fields.first?.name == "CSeq")
        #expect(headers.fields.count == 2)
    }
}
