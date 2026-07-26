//
//  WSDiscoveryHostileInputTests.swift
//  VigilDiscoveryTests
//
//  Port 3702 is a shared, unauthenticated group: SSDP-adjacent traffic, other protocols, and anything
//  a hostile host cares to send. Every one of those must decode to a value under a fixed bound.
//  Covers docs/spec-discovery.md §5.5 and §13.3 tests 34, 35.
//

import Foundation
import Testing
import VigilProtocols

@testable import VigilDiscovery

@Suite struct WSDiscoveryHostileInputTests {

    private static let source = IPv4Address(10, 0, 20, 31)

    private func decode(_ payload: Data) -> WSDDecodeOutcome {
        WSDiscoveryCodec.decodeProbeMatches(payload, from: Self.source,
                                           expectedMessageIDs: [WSDFixtures.probeMessageID],
                                           receivedAt: WSDFixtures.receivedAt)
    }

    // MARK: - Not SOAP at all

    /// Test 35. Random bytes are not an envelope, and saying so is the whole job.
    @Test func wsdGarbageIsNotSOAP() {
        guard case let .notSOAP(prefixHex) = decode(SADPFixtures.randomOpaqueDatagram) else {
            Issue.record("expected .notSOAP")
            return
        }
        #expect(prefixHex.count == 32)              // first 16 bytes
    }

    @Test func wsdEmptyDatagramIsNotSOAP() {
        #expect(decode(Data()) == .notSOAP(prefixHex: ""))
    }

    /// A SADP ProbeMatch is well-formed XML — on the wrong port. It must not be mistaken for ONVIF.
    @Test func wsdRejectsASADPDatagramSentToTheWrongPort() {
        guard case .notSOAP = decode(SADPFixtures.activatedCameraDatagram) else {
            Issue.record("a SADP ProbeMatch is not a SOAP envelope")
            return
        }
    }

    /// And the mirror: an ONVIF envelope on 37020 is malformed SADP, not a phantom camera.
    @Test func wsdEnvelopeSentToTheSADPDecoderIsMalformed() {
        let result = SADPCodec.decode(Data(WSDFixtures.hikvisionProbeMatchXML.utf8),
                                      from: Self.source, expectedUUID: SADPFixtures.probeUUID,
                                      receivedAt: SADPFixtures.receivedAt)
        guard case let .malformed(reason, _) = result else {
            Issue.record("expected .malformed, got \(result)")
            return
        }
        #expect(reason.contains("envelope"))
    }

    /// One byte over the cap is refused without being parsed.
    @Test func wsdOversizedDatagramIsRefusedByTheCap() {
        let padding = String(repeating: " ", count: WSDiscoveryCodec.maxDatagramBytes)
        let payload = Data((WSDFixtures.hikvisionProbeMatchXML + padding).utf8)
        #expect(payload.count > WSDiscoveryCodec.maxDatagramBytes)
        guard case .notSOAP = decode(payload) else {
            Issue.record("expected .notSOAP for an oversized datagram")
            return
        }
    }

    /// The recorded sample is comfortably inside the cap, which is what makes the cap safe to apply.
    @Test func wsdRecordedSampleIsWellInsideTheCap() {
        #expect(Data(WSDFixtures.hikvisionProbeMatchXML.utf8).count
                    < WSDiscoveryCodec.maxDatagramBytes / 2)
    }

    // MARK: - Truncation

    /// Every prefix of the recorded envelope. A crash here is a remote denial of service.
    @Test func wsdEveryTruncatedPrefixDecodesToAValue() {
        let full = Data(WSDFixtures.hikvisionProbeMatchXML.utf8)
        for length in 0...full.count {
            let outcome = decode(full.prefix(length))
            if let matches = outcome.wsdMatches {
                for match in matches {
                    #expect(match.types.count <= WSDiscoveryCodec.maxTypesPerMatch)
                    #expect(match.xAddrs.count <= WSDiscoveryCodec.maxXAddrsPerMatch)
                    #expect(match.scopes.raw.count <= WSDiscoveryCodec.maxScopesPerMatch)
                }
            }
        }
    }

    /// A truncation in the middle of the scope list still yields the device, with whatever scopes
    /// arrived — losing a camera because its last scope was cut off would be the wrong trade.
    @Test func wsdTruncationInsideScopesStillYieldsTheDevice() throws {
        let full = WSDFixtures.hikvisionProbeMatchXML
        guard let cut = full.range(of: "onvif://www.onvif.org/hardware") else {
            Issue.record("fixture changed")
            return
        }
        let matches = try #require(decode(Data(full[full.startIndex..<cut.lowerBound].utf8))
            .wsdMatches)
        let match = try #require(matches.first)
        #expect(match.endpointAddress == WSDFixtures.hikvisionEndpoint)
        #expect(match.scopes.profiles == ["Streaming", "G", "T"])
        #expect(match.scopes.hardware == nil)
    }

    // MARK: - Per-datagram caps

    /// Test 34. Two hundred ProbeMatch elements in one datagram: 64 are kept, the rest are counted
    /// and dropped. The cap is what stops a 3 kB datagram from becoming an unbounded array.
    @Test func wsdOversizedProbeMatchListIsTruncatedAtSixtyFour() throws {
        let xml = WSDFixtures.manyProbeMatchesXML(count: 200)
        #expect(Data(xml.utf8).count < WSDiscoveryCodec.maxDatagramBytes)
        let matches = try #require(decode(Data(xml.utf8)).wsdMatches)
        #expect(matches.count == WSDiscoveryCodec.maxProbeMatchesPerDatagram)
        #expect(matches.count == 64)

        // The drop count is tracked so a future diagnostic can report it.
        var collector = WSDiscoveryCodec.EnvelopeCollector()
        _ = LenientXMLScanner.scan(xml) { collector.apply($0) }
        #expect(collector.matches.count == 64)
        #expect(collector.droppedMatches == 136)
    }

    /// Scopes are capped in count and in length, and the truncation is visible rather than silent.
    @Test func wsdScopeListIsCappedInCountAndLength() {
        let many = (0..<40).map { "onvif://www.onvif.org/type/t\($0)" }.joined(separator: " ")
        let capped = WSDiscoveryCodec.parseScopes(many)
        #expect(capped.raw.count == WSDiscoveryCodec.maxScopesPerMatch)
        #expect(capped.types.count == 32)

        let long = "onvif://www.onvif.org/name/" + String(repeating: "A", count: 600)
        let truncated = WSDiscoveryCodec.parseScopes(long)
        #expect(truncated.raw.first?.count == WSDiscoveryCodec.maxScopeCharacters)
        #expect(truncated.name?.count == WSDiscoveryCodec.maxScopeCharacters - 27)
    }

    /// XAddrs and Types are capped too.
    @Test func wsdXAddrsAndTypesAreCapped() {
        let urls = (0..<20).map { "http://10.0.20.\($0)/onvif/device_service" }.joined(separator: " ")
        #expect(WSDiscoveryCodec.splitXAddrs(urls).count == WSDiscoveryCodec.maxXAddrsPerMatch)
        let types = (0..<50).map { "dn:Type\($0)" }.joined(separator: " ")
        #expect(WSDiscoveryCodec.splitTypes(types).count == WSDiscoveryCodec.maxTypesPerMatch)
        #expect(WSDiscoveryCodec.splitTypes("dn:A  tds:B\tC\nd:E").first == "A")
        #expect(WSDiscoveryCodec.splitTypes("NoPrefix") == ["NoPrefix"])
    }

    /// A scope that is not an `onvif://` URI at all is kept in `raw` and interpreted as nothing.
    @Test func wsdUnrecognisedScopesAreKeptButNotInterpreted() {
        let scopes = WSDiscoveryCodec.parseScopes("""
            http://example.com/not-onvif onvif://www.onvif.org/ onvif:// \
            onvif://192.168.1.64/name/Local%20Camera %ZZ onvif://host/name/
            """)
        #expect(scopes.raw.count == 6)
        #expect(scopes.name == "Local Camera")      // any host is accepted, as §5.6 requires
        #expect(scopes.hardware == nil)
        #expect(scopes.raw.contains("%ZZ"))         // an invalid escape is kept verbatim
    }

    /// An envelope whose body is empty, and one with no body at all.
    @Test func wsdEmptyBodiesDecodeToAnEmptyList() {
        let empty = """
            <?xml version="1.0"?>
            <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
              <s:Body><d:ProbeMatches xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"/>
              </s:Body>
            </s:Envelope>
            """
        #expect(decode(Data(empty.utf8)) == .probeMatches([]))
        let bare = "<s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\"/>"
        #expect(decode(Data(bare.utf8)) == .otherAction(""))
    }

    /// A nesting bomb inside an envelope stops at the depth bound and yields no matches.
    @Test func wsdNestingBombIsBounded() {
        let nested = String(repeating: "<a>", count: 2_000)
        let xml = "<s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\">" + nested
        #expect(Data(xml.utf8).count < WSDiscoveryCodec.maxDatagramBytes)
        let outcome = decode(Data(xml.utf8))
        #expect(outcome.wsdMatches?.isEmpty ?? true)
    }

    /// An entity bomb inside an envelope expands to nothing, because declarations are skipped whole.
    @Test func wsdEntityBombIsNotExpanded() throws {
        var lines = ["<?xml version=\"1.0\"?>", "<!DOCTYPE s:Envelope [",
                     "<!ENTITY lol \"lol\">"]
        for level in 1...8 {
            let inner = level == 1 ? "lol" : "lol\(level - 1)"
            lines.append("<!ENTITY lol\(level) \"\(Array(repeating: "&\(inner);", count: 10).joined())\">")
        }
        lines.append("]>")
        lines.append("<s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\"")
        lines.append("            xmlns:d=\"http://schemas.xmlsoap.org/ws/2005/04/discovery\">")
        lines.append("<s:Body><d:ProbeMatches><d:ProbeMatch>")
        lines.append("<d:XAddrs>&lol8;</d:XAddrs>")
        lines.append("</d:ProbeMatch></d:ProbeMatches></s:Body></s:Envelope>")
        let payload = Data(lines.joined(separator: "\n").utf8)
        #expect(payload.count < WSDiscoveryCodec.maxDatagramBytes)

        let match = try #require(decode(payload).wsdMatches?.first)
        #expect(match.xAddrs == ["&lol8;"])
    }

    /// Non-UTF-8 bytes inside an otherwise valid envelope do not lose the device.
    @Test func wsdToleratesNonUTF8Bytes() throws {
        var payload = Data(WSDFixtures.hikvisionProbeMatchXML.utf8)
        guard let range = payload.range(of: Data("china".utf8)) else {
            Issue.record("fixture changed")
            return
        }
        payload.replaceSubrange(range.upperBound..<range.upperBound, with: [0xB0])
        let match = try #require(decode(payload).wsdMatches?.first)
        #expect(match.endpointAddress == WSDFixtures.hikvisionEndpoint)
        #expect(match.scopes.location?.hasPrefix("china") == true)
    }

    /// Attribute-heavy and comment-heavy envelopes parse to the same device.
    @Test func wsdToleratesCommentsAndUnexpectedAttributes() throws {
        let xml = WSDFixtures.hikvisionProbeMatchXML
            .replacingOccurrences(of: "<wsdd:ProbeMatch>",
                                  with: "<!-- a comment --><wsdd:ProbeMatch a=\"1\" b='2' c=3>")
        let match = try #require(decode(Data(xml.utf8)).wsdMatches?.first)
        #expect(match.endpointAddress == WSDFixtures.hikvisionEndpoint)
    }
}
