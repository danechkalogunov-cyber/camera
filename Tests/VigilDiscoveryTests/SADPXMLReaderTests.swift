//
//  SADPXMLReaderTests.swift
//  VigilDiscoveryTests
//
//  The lenient XML layer under both decoders: the flat SADP reader, the bare-ampersand repair, and
//  the scanner bounds that make an unauthenticated datagram harmless.
//  Covers docs/spec-discovery.md §4.5.1 and §5.5.
//

import Foundation
import Testing

@testable import VigilDiscovery

@Suite struct SADPXMLReaderTests {

    // MARK: - Flat collection

    @Test func sadpReaderKeysOnLowercasedLocalNamesAndTrimsValues() {
        let document = SADPXMLReader.read("""
            <?xml version="1.0"?>
            <ProbeMatch>
              <HttpPort>  80\t</HttpPort>
              <hik:DeviceSN>DS-1</hik:DeviceSN>
              <MAC>
                c4-2f-90-ab-cd-ef
              </MAC>
            </ProbeMatch>
            """)
        #expect(document.rootName == "probematch")
        #expect(document.isWellFormed)
        #expect(document.elements["httpport"] == "80")
        #expect(document.elements["devicesn"] == "DS-1")
        #expect(document.elements["mac"] == "c4-2f-90-ab-cd-ef")
        #expect(document.elements["probematch"] == nil)      // the root carries no value
    }

    @Test func sadpReaderKeepsTheLastValueForARepeatedElement() {
        let document = SADPXMLReader.read("<P><HttpPort>80</HttpPort><HttpPort>8080</HttpPort></P>")
        #expect(document.elements["httpport"] == "8080")
    }

    @Test func sadpReaderHandlesSelfClosingAndEmptyElements() {
        let document = SADPXMLReader.read("<ProbeMatch><OEMinfo/><Salt></Salt></ProbeMatch>")
        #expect(document.elements["oeminfo"] == "")
        #expect(document.elements["salt"] == "")
        #expect(document.isWellFormed)
    }

    @Test func sadpReaderDecodesPredefinedAndNumericEntities() {
        let document = SADPXMLReader.read(
            "<P><A>a&amp;b</A><B>&lt;tag&gt;</B><C>&quot;q&quot;&apos;</C><D>&#65;&#x42;</D></P>")
        #expect(document.elements["a"] == "a&b")
        #expect(document.elements["b"] == "<tag>")
        #expect(document.elements["c"] == "\"q\"'")
        #expect(document.elements["d"] == "AB")
    }

    @Test func sadpReaderReadsCDATAVerbatim() {
        let document = SADPXMLReader.read("<P><A><![CDATA[a & <b> \"c\"]]></A></P>")
        #expect(document.elements["a"] == "a & <b> \"c\"")
    }

    @Test func sadpReaderSkipsCommentsAndDeclarations() {
        let document = SADPXMLReader.read("""
            <?xml version="1.0"?>
            <!-- a comment with <tags> and & inside -->
            <!DOCTYPE P [ <!ENTITY x "y"> ]>
            <P><A>1</A></P>
            """)
        #expect(document.rootName == "p")
        #expect(document.elements["a"] == "1")
        #expect(document.elements.count == 1)
    }

    @Test func sadpReaderReportsTruncationAsNotWellFormed() {
        let document = SADPXMLReader.read("<ProbeMatch><HttpPort>80")
        #expect(!document.isWellFormed)
        #expect(document.elements["httpport"] == "80")       // still flushed, still usable
    }

    @Test func sadpReaderReturnsNoRootForTextOnlyInput() {
        let document = SADPXMLReader.read("just some text, no markup at all")
        #expect(document.rootName == nil)
        #expect(document.elements.isEmpty)
        #expect(SADPXMLReader.read("").rootName == nil)
    }

    // MARK: - Ampersand repair

    /// The golden cases for the §4.5.1 sanitising pass, including the numeric reference the
    /// specification's own regex would have corrupted.
    @Test func sadpAmpersandRepairEscapesOnlyBareAmpersands() {
        #expect(SADPXMLReader.escapingBareAmpersands("Lobby & Dock") == "Lobby &amp; Dock")
        #expect(SADPXMLReader.escapingBareAmpersands("a &amp; b") == "a &amp; b")
        #expect(SADPXMLReader.escapingBareAmpersands("&lt;&gt;&quot;&apos;") == "&lt;&gt;&quot;&apos;")
        #expect(SADPXMLReader.escapingBareAmpersands("&#38;") == "&#38;")
        #expect(SADPXMLReader.escapingBareAmpersands("&#x26;") == "&#x26;")
        #expect(SADPXMLReader.escapingBareAmpersands("trailing &") == "trailing &amp;")
        #expect(SADPXMLReader.escapingBareAmpersands("a&&b") == "a&amp;&amp;b")
        #expect(SADPXMLReader.escapingBareAmpersands("&verylongentityname;")
                    == "&amp;verylongentityname;")
        #expect(SADPXMLReader.escapingBareAmpersands("no ampersand here") == "no ampersand here")
    }

    /// Escaping then decoding is the identity on the value the user sees, which is what makes the
    /// pass safe to apply unconditionally.
    @Test func sadpAmpersandRepairRoundTripsThroughTheReader() {
        let document = SADPXMLReader.read("<P><A>R&D & more</A></P>")
        #expect(document.elements["a"] == "R&D & more")
    }
}

@Suite struct LenientXMLScannerTests {

    private func events(_ source: String,
                        limits: XMLScanLimits = .discovery) -> ([LenientXMLScanner.Event],
                                                                LenientXMLScanner.Outcome) {
        var collected: [LenientXMLScanner.Event] = []
        let outcome = LenientXMLScanner.scan(source, limits: limits) { collected.append($0) }
        return (collected, outcome)
    }

    @Test func scannerEmitsBalancedStartTextEndEvents() {
        let (collected, outcome) = events("<a><b>x</b></a>")
        #expect(collected == [.start(name: "a", attributes: [:]),
                              .start(name: "b", attributes: [:]),
                              .text("x"),
                              .end(name: "b"),
                              .end(name: "a")])
        #expect(outcome.isBalanced)
        #expect(outcome.elementCount == 2)
        #expect(!outcome.hitLimit)
    }

    @Test func scannerLowercasesNamesAndStripsPrefixes() {
        let (collected, _) = events("<Env:Body Foo:Bar=\"1\"/>")
        #expect(collected == [.start(name: "body", attributes: ["bar": "1"]),
                              .end(name: "body")])
    }

    @Test func scannerClosesUnterminatedElementsAtEndOfInput() {
        let (collected, outcome) = events("<a><b>x")
        #expect(collected == [.start(name: "a", attributes: [:]),
                              .start(name: "b", attributes: [:]),
                              .text("x"),
                              .end(name: "b"),
                              .end(name: "a")])
        #expect(!outcome.isBalanced)
    }

    @Test func scannerRecoversFromAnEndTagThatWasNeverOpened() {
        let (collected, outcome) = events("<a></b><c>1</c></a>")
        #expect(!outcome.isBalanced)
        #expect(collected.contains(.text("1")))
        #expect(collected.last == .end(name: "a"))
    }

    @Test func scannerReadsAttributesInEverySpelling() {
        let (collected, _) = events("<a x=\"1\" y='2' z=3 flag w = \"4\" >")
        #expect(collected.first == .start(name: "a",
                                          attributes: ["x": "1", "y": "2", "z": "3", "w": "4"]))
    }

    @Test func scannerKeepsABareLessThanAsText() {
        let (collected, _) = events("<a>3 < 4</a>")
        #expect(collected.contains { event in
            if case let .text(value) = event { return value.contains("<") }
            return false
        })
    }

    /// The depth bound is the reason a nesting bomb cannot overflow the stack: the scanner keeps a
    /// stack of names on the heap and simply stops.
    @Test func scannerStopsAtTheDepthBound() {
        let deep = String(repeating: "<a>", count: 500)
        let (collected, outcome) = events(deep, limits: XMLScanLimits(maxDepth: 8))
        #expect(outcome.hitLimit)
        #expect(!outcome.isBalanced)
        #expect(collected.count < 40)
    }

    @Test func scannerStopsAtTheElementBound() {
        let many = (0..<200).map { "<e\($0)/>" }.joined()
        let (_, outcome) = events(many, limits: XMLScanLimits(maxElements: 10))
        #expect(outcome.hitLimit)
        #expect(outcome.elementCount == 11)         // the one that tripped the bound is counted
    }

    @Test func scannerBoundsTextLength() {
        let long = String(repeating: "x", count: 5_000)
        var text = ""
        let outcome = LenientXMLScanner.scan("<a>\(long)</a>", limits: XMLScanLimits(maxTextBytes: 64)) {
            if case let .text(value) = $0 { text += value }
        }
        #expect(text.count == 64)
        #expect(outcome.hitLimit)
    }

    /// Entity declarations are skipped whole, so no reference can expand — the structural reason the
    /// billion-laughs family is not a threat here.
    @Test func scannerNeverExpandsCustomEntities() {
        let (collected, _) = events("""
            <!DOCTYPE a [<!ENTITY lol "haha"><!ENTITY lol2 "&lol;&lol;">]>
            <a>&lol2;</a>
            """)
        #expect(collected.contains(.text("&lol2;")))
    }

    /// An internal subset containing `>` must not end the declaration early.
    @Test func scannerSkipsADeclarationWithABracketedSubset() {
        let (collected, outcome) = events("<!DOCTYPE a [<!ELEMENT a (#PCDATA)> ]><a>1</a>")
        #expect(outcome.isBalanced)
        #expect(collected == [.start(name: "a", attributes: [:]), .text("1"), .end(name: "a")])
    }

    @Test func scannerHandlesUnterminatedConstructsWithoutSpinning() {
        for source in ["<", "</", "<!--", "<![CDATA[", "<?", "<!", "<a", "<a x=\"", "<a x='y",
                       "</a", "<a/", "&", "&#", "&#x", "&amp"] {
            let (_, outcome) = events(source)
            _ = outcome                             // the assertion is that this returns at all
        }
        #expect(Bool(true))
    }

    @Test func scannerDecodesTextToLatin1WhenNotUTF8() {
        let (text, isUTF8) = LenientXMLScanner.decodedText([0x3C, 0x61, 0x3E, 0xB0])
        #expect(!isUTF8)
        #expect(text == "<a>\u{00B0}")
        let (valid, wasUTF8) = LenientXMLScanner.decodedText(Array("<a>é".utf8))
        #expect(wasUTF8)
        #expect(valid == "<a>é")
    }
}
