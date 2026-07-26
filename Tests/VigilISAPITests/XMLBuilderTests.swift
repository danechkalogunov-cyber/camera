//
//  XMLBuilderTests.swift
//  VigilISAPITests
//
//  The request-body builder: the declaration 5.2.x firmware insists on, the five escapes, and the
//  element order Hikvision's XML validator enforces.
//  Covers docs/spec-isapi.md §8.
//

import Foundation
import Testing
@testable import VigilISAPI

@Suite struct XMLBuilderTests {

    /// Every body opens with the declaration: a 5.2.x device answers `invalidXMLFormat` without it.
    @Test func xmlBuilderAlwaysEmitsTheDeclaration() {
        var builder = XMLBuilder("PTZData")
        builder.add("pan", 0)
        let text = builder.stringValue
        #expect(text.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"))
        #expect(builder.data() == Data(text.utf8))
    }

    /// Element order is insertion order, because `<PTZData>` and `<CMSearchDescription>` are
    /// order-sensitive on several firmwares.
    @Test func xmlBuilderPreservesElementOrder() {
        var builder = XMLBuilder("CMSearchDescription")
        builder.add("searchID", "A-1")
        builder.add("maxResults", 40)
        builder.add("searchResultPostion", 0)
        #expect(builder.stringValue.hasSuffix(
            "<CMSearchDescription><searchID>A-1</searchID><maxResults>40</maxResults>"
            + "<searchResultPostion>0</searchResultPostion></CMSearchDescription>"))
    }

    /// Exactly five escapes, and nothing else — no numeric character references.
    @Test func xmlBuilderEscapesTheFiveEntities() {
        var builder = XMLBuilder("Name")
        builder.add("value", "a&b<c>d\"e'f")
        #expect(builder.stringValue.contains("<value>a&amp;b&lt;c&gt;d&quot;e&apos;f</value>"))
    }

    /// Booleans go out as `true`/`false` — the only spelling every firmware accepts on input — and
    /// integers carry no grouping or plus sign.
    @Test func xmlBuilderRendersIntegersAndBooleans() {
        var builder = XMLBuilder("Video")
        builder.add("enabled", true)
        builder.add("disabled", false)
        builder.add("width", 3840)
        builder.add("offset", -12)
        let text = builder.stringValue
        #expect(text.contains("<enabled>true</enabled>"))
        #expect(text.contains("<disabled>false</disabled>"))
        #expect(text.contains("<width>3840</width>"))
        #expect(text.contains("<offset>-12</offset>"))
    }

    /// Constructed bodies carry no `xmlns` and no `version`; read-modify-write bodies echo back
    /// exactly what the `GET` returned.
    @Test func xmlBuilderOmitsNamespaceUnlessEchoed() {
        var constructed = XMLBuilder("PTZData")
        constructed.add("pan", 30)
        // The declaration carries `version="1.0"`; the *element* must carry no attribute at all.
        #expect(constructed.stringValue.contains("xmlns") == false)
        #expect(constructed.stringValue.contains("<PTZData>"))
        #expect(constructed.elementString == "<PTZData><pan>30</pan></PTZData>")

        var echoed = XMLBuilder("Color", attributes: [
            ("version", "2.0"),
            ("xmlns", "http://www.hikvision.com/ver20/XMLSchema"),
        ])
        echoed.add("brightnessLevel", 50)
        let text = echoed.stringValue
        #expect(text.contains("<Color version=\"2.0\" "
                              + "xmlns=\"http://www.hikvision.com/ver20/XMLSchema\">"))
    }

    /// Nested elements are built in place and produce exactly one declaration.
    @Test func xmlBuilderNestsChildrenWithoutASecondDeclaration() {
        var builder = XMLBuilder("PTZData")
        builder.addChild("Momentary") { child in
            child.add("duration", 500)
        }
        builder.addChild("pan", attributes: [("unit", "percent")]) { child in
            child.add("value", 30)
        }
        let text = builder.stringValue
        #expect(text.components(separatedBy: "<?xml").count == 2)
        #expect(text.contains("<Momentary><duration>500</duration></Momentary>"))
        #expect(text.contains("<pan unit=\"percent\"><value>30</value></pan>"))
    }

    /// An element with no children and no text is self-closing, which is what the device sends back.
    @Test func xmlBuilderEmitsSelfClosingEmptyElements() {
        let builder = XMLBuilder("PTZData")
        #expect(builder.stringValue.hasSuffix("<PTZData/>"))
    }

    /// Optional adds emit nothing for `nil`, so a partial patch never sends a field the caller did
    /// not set — the difference between changing brightness and resetting contrast to zero.
    @Test func xmlBuilderSkipsAbsentOptionalValues() {
        var builder = XMLBuilder("Color")
        builder.addIfPresent("brightnessLevel", 60)
        builder.addIfPresent("contrastLevel", Int?.none)
        builder.addIfPresent("name", String?.none)
        builder.addIfPresent("enabled", Bool?.none)
        let text = builder.stringValue
        #expect(text.contains("<brightnessLevel>60</brightnessLevel>"))
        #expect(text.contains("contrastLevel") == false)
        #expect(text.contains("enabled") == false)
    }

    /// A round-tripped subtree can be spliced back in verbatim, which is how a read-modify-write
    /// body keeps elements Vigil does not model.
    @Test func xmlBuilderSplicesRawFragments() throws {
        let document = try ISAPIDocument(parsing: Data(
            "<Color><unknownFuture>keep</unknownFuture></Color>".utf8))
        let subtree = try #require(document.node("unknownFuture"))
        var builder = XMLBuilder("Color")
        builder.add("brightnessLevel", 50)
        builder.addRaw(String(decoding: subtree.serialized(declaration: false), as: UTF8.self))
        #expect(builder.stringValue.contains("<unknownFuture>keep</unknownFuture>"))
    }
}
