//
//  RTSPHeaderScannerTests.swift
//  VigilRTSPTests
//
//  The quote-aware splitting primitives every header parser is built on. The cases that matter are
//  the ones where a value contains the separator it is being split on.
//  Covers docs/spec-rtsp.md §4.6.
//

import Testing

@testable import VigilRTSP

@Suite struct RTSPHeaderScannerTests {

    @Test func headerScannerClassifiesTokenBytes() {
        #expect(RTSPHeaderScanner.isTokenByte(UInt8(ascii: "A")))
        #expect(RTSPHeaderScanner.isTokenByte(UInt8(ascii: "-")))
        #expect(!RTSPHeaderScanner.isTokenByte(UInt8(ascii: ":")))
        #expect(!RTSPHeaderScanner.isTokenByte(UInt8(ascii: " ")))
        #expect(!RTSPHeaderScanner.isTokenByte(UInt8(ascii: "\"")))
        #expect(!RTSPHeaderScanner.isTokenByte(0x7F))
        #expect(!RTSPHeaderScanner.isTokenByte(0x80))
    }

    @Test func headerScannerRecognisesWholeTokens() {
        #expect(RTSPHeaderScanner.isToken("Content-Length"))
        #expect(!RTSPHeaderScanner.isToken(""))
        #expect(!RTSPHeaderScanner.isToken("Content Length"))
        #expect(!RTSPHeaderScanner.isToken("a=Media_header"))
    }

    /// The realm of a Hikvision camera contains a comma often enough that comma-splitting a
    /// challenge is the classic parser bug.
    @Test func headerScannerKeepsCommasInsideQuotedStrings() {
        let value = Substring("Digest realm=\"IP Camera(52491), Building 3\", nonce=\"abc\"")
        let parts = RTSPHeaderScanner.topLevelSplit(value, on: ",")
        #expect(parts.count == 2)
        #expect(parts[0] == "Digest realm=\"IP Camera(52491), Building 3\"")
        #expect(RTSPHeaderScanner.trimmingOWS(parts[1]) == "nonce=\"abc\"")
    }

    @Test func headerScannerKeepsSemicolonsInsideQuotedURLs() {
        let value = Substring("url=\"rtsp://h/a?b=1;c=2\";seq=52937;rtptime=2599730432")
        let parameters = RTSPHeaderScanner.parameters(value)
        #expect(parameters.count == 3)
        #expect(parameters[0].name == "url")
        #expect(parameters[0].value == "rtsp://h/a?b=1;c=2")
        #expect(parameters[1].value == "52937")
        #expect(parameters[2].value == "2599730432")
    }

    @Test func headerScannerTreatsValuelessFieldsAsFlags() {
        let parameters = RTSPHeaderScanner.parameters(Substring("RTP/AVP/TCP;unicast;interleaved=0-1"))
        #expect(parameters.map(\.name) == ["RTP/AVP/TCP", "unicast", "interleaved"])
        #expect(parameters[0].value.isEmpty)
        #expect(parameters[1].value.isEmpty)
        #expect(parameters[2].value == "0-1")
    }

    @Test func headerScannerTrimsWhitespaceAroundNamesAndValues() {
        let parameters = RTSPHeaderScanner.parameters(Substring("  mode = \"play\" ; ssrc = 48A9C1B2 "))
        #expect(parameters.count == 2)
        #expect(parameters[0].name == "mode")
        #expect(parameters[0].value == "play")
        #expect(parameters[1].name == "ssrc")
        #expect(parameters[1].value == "48A9C1B2")
    }

    @Test func headerScannerPreservesEmptyFieldsWhenSplitting() {
        #expect(RTSPHeaderScanner.topLevelSplit(Substring("a,,b"), on: ",").count == 3)
        #expect(RTSPHeaderScanner.topLevelSplit(Substring(""), on: ",") == [""])
    }

    @Test func headerScannerUnquotesOneLayerAndUnescapes() {
        #expect(RTSPHeaderScanner.unquote(Substring("\"plain\"")) == "plain")
        #expect(RTSPHeaderScanner.unquote(Substring("bare")) == "bare")
        #expect(RTSPHeaderScanner.unquote(Substring("\"say \\\"hi\\\"\"")) == "say \"hi\"")
        #expect(RTSPHeaderScanner.unquote(Substring("\"unterminated")) == "\"unterminated")
        #expect(RTSPHeaderScanner.unquote(Substring("\"\"")) == "")
    }

    @Test func headerScannerQuoteRoundTripsThroughUnquote() {
        for value in ["admin", "IP Camera(52491)", "a\"b", "back\\slash", ""] {
            let quoted = RTSPHeaderScanner.quote(value)
            #expect(quoted.hasPrefix("\"") && quoted.hasSuffix("\""))
            #expect(RTSPHeaderScanner.unquote(Substring(quoted)) == value)
        }
    }

    @Test func headerScannerFindsUnquotedSeparatorsOnly() {
        let text = Substring("realm=\"a=b\", nonce=\"c\"")
        let equals = RTSPHeaderScanner.firstUnquotedIndex(of: "=", in: text)
        #expect(equals == text.index(text.startIndex, offsetBy: 5))
        #expect(RTSPHeaderScanner.firstUnquotedIndex(of: ";", in: text) == nil)
    }

    @Test func headerScannerAnUnterminatedQuoteKeepsTheRestAsOneField() {
        let parts = RTSPHeaderScanner.topLevelSplit(Substring("a=\"open, still open"), on: ",")
        #expect(parts.count == 1)
    }
}
