//
//  DeviceSessionTests.swift
//  VigilISAPITests
//
//  The device session: the TTL table, the negative-capability cache, the read-modify-write-then-
//  re-GET discipline, the four quirk consultation points, and the ten-step connect sequence.
//  Covers docs/spec-isapi.md §17.1, §18.1, §18.2, §18.3 and §19.
//
//  Every test drives a `RequestDouble`, so what is asserted is the exact traffic the session would
//  have put on the wire and the exact bytes of every body — not a mock's expectation of them.
//  Nothing here waits: freshness is driven by `SessionTestClock.advance(by:)` and the wall clock is
//  frozen, so a TTL boundary is asserted at the boundary rather than near it.
//
//  Fixtures are hand-written from the samples in docs/spec-isapi.md §10, §11, §15 and §17.2. Where a
//  value is not in the spec it is synthesised and says so — none of it came from real hardware.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilISAPI

// MARK: - Namespace preservation (§8, §17.2)

@Suite struct ISAPIDocumentNamespaceSuite {

    /// The defect this suite exists for: the parser used to drop every `xmlns*` attribute, so no
    /// read-modify-write body Vigil sent could carry the namespace that §8 and §17.2 require and
    /// that some 5.4.x builds reject a `<Color>` without.
    @Test func isapiDocumentNamespacePreservesTheDefaultDeclaration() throws {
        let document = try ISAPIDocument(parsing: Data("""
            <Color version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">\
            <brightnessLevel>50</brightnessLevel></Color>
            """.utf8))
        #expect(document.root.attributes["xmlns"] == "http://www.hikvision.com/ver20/XMLSchema")
        #expect(document["@xmlns"].string == "http://www.hikvision.com/ver20/XMLSchema")
    }

    /// A prefixed declaration keeps its **whole** name. Reducing `xmlns:hik` to `hik` — which is
    /// what prefix-stripping would do — writes back an attribute the device never sent and loses
    /// the declaration entirely.
    @Test func isapiDocumentNamespacePreservesAPrefixedDeclarationVerbatim() throws {
        let document = try ISAPIDocument(parsing: Data("""
            <Color xmlns:hik="http://www.hikvision.com/ver20/XMLSchema" version="2.0">\
            <brightnessLevel>50</brightnessLevel></Color>
            """.utf8))
        #expect(document.root.attributes["xmlns:hik"] == "http://www.hikvision.com/ver20/XMLSchema")
        #expect(document.root.attributes["hik"] == nil)
        let text = String(decoding: document.root.serialized(declaration: false), as: UTF8.self)
        #expect(text.contains("xmlns:hik=\"http://www.hikvision.com/ver20/XMLSchema\""))
    }

    /// Prefix-stripping on *names* is deliberate and must survive the fix: it is what keeps every
    /// path expression in this module namespace-agnostic.
    @Test func isapiDocumentNamespaceStillStripsPrefixesFromNames() throws {
        let document = try ISAPIDocument(parsing: Data("""
            <hik:Color xmlns:hik="http://www.hikvision.com/ver20/XMLSchema" hik:version="2.0">\
            <hik:brightnessLevel>50</hik:brightnessLevel></hik:Color>
            """.utf8))
        #expect(document.rootName == "Color")
        #expect(document["brightnessLevel"].int == 50)
        // The prefix came off the ordinary attribute's name, and its lowercased local name is what
        // an `@attr` path matches.
        #expect(document["@version"].string == "2.0")
        // The declaration did not lose its prefix.
        #expect(document.root.attributes["xmlns:hik"] != nil)
    }

    /// `xmlnsfoo` is an ordinary attribute, not a declaration. The old `hasPrefix("xmlns")` test
    /// swallowed it; the exact rule does not.
    @Test func isapiDocumentNamespaceKeepsAnAttributeThatMerelyStartsWithXmlns() throws {
        let document = try ISAPIDocument(parsing: Data(
            "<Color xmlnsExtra=\"7\"><brightnessLevel>50</brightnessLevel></Color>".utf8))
        #expect(document.root.attributes["xmlnsextra"] == "7")
    }

    /// End to end: a `<Color>` read from the device and patched comes back out with both attributes
    /// the spec sample shows, in the spec sample's order.
    @Test func isapiDocumentNamespaceRoundTripsThroughAReadModifyWriteBody() throws {
        let document = try ISAPIDocument(parsing: Data(SessionFixtures.color.utf8))
        let patched = ImageWrite.color(document.root, brightness: 62, contrast: nil,
                                       saturation: nil)
        let text = String(decoding: patched.serialized(), as: UTF8.self)
        #expect(text.contains("<Color version=\"2.0\" "
                              + "xmlns=\"http://www.hikvision.com/ver20/XMLSchema\">"))
        #expect(text.contains("<brightnessLevel>62</brightnessLevel>"))
        // And it still parses, which is the only thing the device actually cares about.
        let reparsed = try ISAPIDocument(parsing: patched.serialized())
        #expect(reparsed["brightnessLevel"].int == 62)
        #expect(reparsed["@xmlns"].string == "http://www.hikvision.com/ver20/XMLSchema")
    }
}
