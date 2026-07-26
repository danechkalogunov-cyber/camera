//
//  WSDiscoveryProbeTests.swift
//  VigilDiscoveryTests
//
//  The three Probe envelopes, byte for byte against §5.2, including the two namespace years whose
//  confusion is the single most common reason an ONVIF Probe is silently ignored.
//  Covers docs/spec-discovery.md §5.2, §5.3 and §13.3 tests 21, 22.
//

import Foundation
import Testing

@testable import VigilDiscovery

@Suite struct WSDiscoveryProbeTests {

    private static let messageID = UUID(uuidString: "9A6F2C41-8B3D-4A7E-9F10-2C5B8E7D3A91")
        ?? UUID()

    /// The §5.2 envelope, transcribed line by line from the specification and joined with CRLF.
    private static var goldenNVTEnvelope: String {
        [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<e:Envelope xmlns:e=\"http://www.w3.org/2003/05/soap-envelope\"",
            "            xmlns:w=\"http://schemas.xmlsoap.org/ws/2004/08/addressing\"",
            "            xmlns:d=\"http://schemas.xmlsoap.org/ws/2005/04/discovery\"",
            "            xmlns:dn=\"http://www.onvif.org/ver10/network/wsdl\">",
            "  <e:Header>",
            "    <w:MessageID>urn:uuid:9a6f2c41-8b3d-4a7e-9f10-2c5b8e7d3a91</w:MessageID>",
            "    <w:To e:mustUnderstand=\"true\">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>",
            "    <w:Action e:mustUnderstand=\"true\">"
                + "http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>",
            "  </e:Header>",
            "  <e:Body>",
            "    <d:Probe>",
            "      <d:Types>dn:NetworkVideoTransmitter</d:Types>",
            "    </d:Probe>",
            "  </e:Body>",
            "</e:Envelope>",
        ].joined(separator: "\r\n")
    }

    /// Test 21. Byte-exact.
    @Test func wsdProbeEnvelopeIsByteExact() {
        let encoded = WSDiscoveryCodec.encodeProbe(messageID: Self.messageID,
                                                   types: .networkVideoTransmitter)
        #expect(encoded == Data(Self.goldenNVTEnvelope.utf8))
    }

    /// The two namespace years, both mandatory and easy to get wrong: WS-Addressing is 2004/08,
    /// WS-Discovery is 2005/04.
    @Test func wsdProbeCarriesBothNamespaceYears() throws {
        let text = try #require(String(
            data: WSDiscoveryCodec.encodeProbe(messageID: Self.messageID,
                                               types: .networkVideoTransmitter),
            encoding: .utf8))
        #expect(text.contains("xmlns:w=\"http://schemas.xmlsoap.org/ws/2004/08/addressing\""))
        #expect(text.contains("xmlns:d=\"http://schemas.xmlsoap.org/ws/2005/04/discovery\""))
        #expect(text.contains("<e:Envelope xmlns:e=\"http://www.w3.org/2003/05/soap-envelope\""))
        #expect(!text.contains("http://schemas.xmlsoap.org/soap/envelope"))     // never SOAP 1.1
    }

    /// `mustUnderstand="true"` on both `To` and `Action`, qualified with the envelope prefix.
    @Test func wsdProbeMarksToAndActionMustUnderstand() throws {
        let text = try #require(String(
            data: WSDiscoveryCodec.encodeProbe(messageID: Self.messageID,
                                               types: .networkVideoTransmitter),
            encoding: .utf8))
        #expect(text.contains("<w:To e:mustUnderstand=\"true\">"))
        #expect(text.contains("<w:Action e:mustUnderstand=\"true\">"))
        #expect(text.contains("urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>"))
    }

    /// CRLF throughout, and no trailing break: the datagram ends with the envelope.
    @Test func wsdProbeUsesCRLFAndNoTrailingBreak() {
        let bytes = [UInt8](WSDiscoveryCodec.encodeProbe(messageID: Self.messageID,
                                                         types: .networkVideoTransmitter))
        #expect(bytes.suffix(11) == Array("</e:Envelope>".utf8).suffix(11))
        // Every LF is preceded by a CR.
        for (index, byte) in bytes.enumerated() where byte == 0x0A {
            #expect(index > 0 && bytes[index - 1] == 0x0D)
        }
    }

    /// §5.2: no `ReplyTo` (the anonymous default is what UDP wants) and no empty `Scopes` element
    /// (legal, but some firmware reads it as "match nothing").
    @Test func wsdProbeOmitsReplyToAndEmptyScopes() throws {
        for variant in WSDProbeTypes.allCases {
            let text = try #require(String(
                data: WSDiscoveryCodec.encodeProbe(messageID: Self.messageID, types: variant),
                encoding: .utf8))
            #expect(!text.contains("ReplyTo"), "variant \(variant)")
            #expect(!text.contains("Scopes"), "variant \(variant)")
        }
    }

    /// Test 22. The three schedule entries differ exactly as §5.3 describes, and the schedule is
    /// the three of them in order.
    @Test func wsdProbeVariantsDifferAsScheduled() throws {
        func body(_ types: WSDProbeTypes) throws -> String {
            try #require(String(data: WSDiscoveryCodec.encodeProbe(messageID: Self.messageID,
                                                                    types: types),
                                encoding: .utf8))
        }
        let first = try body(.networkVideoTransmitter)
        let second = try body(.networkVideoTransmitterAndDevice)
        let third = try body(.wildcard)

        #expect(first.contains("<d:Types>dn:NetworkVideoTransmitter</d:Types>"))
        #expect(second.contains("<d:Types>dn:NetworkVideoTransmitter tds:Device</d:Types>"))
        #expect(second.contains("xmlns:tds=\"http://www.onvif.org/ver10/device/wsdl\""))
        #expect(!first.contains("tds"))
        #expect(third.contains("<d:Probe/>"))
        #expect(!third.contains("<d:Types>"))
        #expect(WSDiscoveryCodec.probeSchedule == [.networkVideoTransmitter,
                                                   .networkVideoTransmitterAndDevice, .wildcard])
    }

    /// Each probe carries a **fresh** MessageID, lowercase and `urn:uuid:`-prefixed, and the run
    /// records all three so answers can be correlated.
    @Test func wsdProbeMessageIDsAreFreshLowercaseAndCorrelatable() throws {
        let ids = [UUID(), UUID(), UUID()]
        var recorded: Set<String> = []
        for (index, variant) in WSDiscoveryCodec.probeSchedule.enumerated() {
            let text = try #require(String(
                data: WSDiscoveryCodec.encodeProbe(messageID: ids[index], types: variant),
                encoding: .utf8))
            let expected = "<w:MessageID>urn:uuid:\(ids[index].uuidString.lowercased())</w:MessageID>"
            #expect(text.contains(expected))
            recorded.insert("urn:uuid:\(ids[index].uuidString.lowercased())")
        }
        #expect(recorded.count == 3)
        // A response relating to any of the three correlates.
        for id in recorded {
            #expect(Set(recorded.map(WSDiscoveryCodec.normalizedMessageID))
                .contains(WSDiscoveryCodec.normalizedMessageID(id.uppercased())))
        }
    }

    /// Nothing a probe can carry is a credential. There is no parameter for one, which is the
    /// mechanical half of §6.10; this is the byte-level half.
    @Test func wsdProbeNeverCarriesCredentials() {
        for variant in WSDProbeTypes.allCases {
            let probe = WSDiscoveryCodec.encodeProbe(messageID: Self.messageID, types: variant)
            #expect(DiscoveryCredentialGuard.violations(in: probe).isEmpty, "variant \(variant)")
        }
    }
}
