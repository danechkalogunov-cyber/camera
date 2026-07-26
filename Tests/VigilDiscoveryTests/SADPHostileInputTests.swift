//
//  SADPHostileInputTests.swift
//  VigilDiscoveryTests
//
//  Port 37020 is an unauthenticated UDP group anything on the network can write to, so every shape of
//  garbage — truncated, oversized, obfuscated, entity-bombed, absurdly nested — must decode to a
//  value and never crash or allocate without bound.
//  Covers docs/spec-discovery.md §4.5, §4.8 and §13.2 tests 10, 13, 14, 15.
//

import Foundation
import Testing
import VigilProtocols

@testable import VigilDiscovery

@Suite struct SADPHostileInputTests {

    private static let source = IPv4Address(192, 168, 1, 64)

    private func decode(_ payload: Data) -> SADPDecodeResult {
        SADPCodec.decode(payload, from: Self.source, expectedUUID: SADPFixtures.probeUUID,
                         receivedAt: SADPFixtures.receivedAt)
    }

    // MARK: - Truncation

    /// Test 10. Every prefix of the recorded camera datagram, one byte at a time. A crash here is a
    /// remote denial of service, so the assertion is deliberately about the whole family of inputs
    /// rather than a hand-picked few.
    @Test func sadpEveryTruncatedPrefixDecodesToAValue() throws {
        let full = SADPFixtures.activatedCameraDatagram
        var partialMatches = 0
        for length in 0...full.count {
            let result = decode(full.prefix(length))
            switch result {
            case let .probeMatch(match), let .foreignProbeMatch(match):
                partialMatches += 1
                // The §4.5.1 salvage rule: a partial record must still identify a device.
                #expect(match.uuid != nil, "prefix \(length)")
                #expect(match.mac != nil || match.ipv4Address != nil, "prefix \(length)")
            case .malformed, .opaque, .ownProbeEcho, .foreignProbe:
                break
            }
        }
        // The document is complete well before its end, so plenty of prefixes salvage.
        #expect(partialMatches > 0)
        #expect(decode(full.prefix(0)) == .malformed(reason: "empty datagram", prefixHex: ""))
    }

    /// A truncation mid-document that still carries identity is salvaged, and says so.
    @Test func sadpSalvagedRecordIsFlaggedAsRecovered() throws {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <ProbeMatch>
            <Uuid>1F9B2A6C-4E1D-4F5A-9C3E-7A2B5D8E0C11</Uuid>
            <MAC>c4-2f-90-ab-cd-ef</MAC>
            <HttpPort>80
            """
        let match = try #require(decode(Data(xml.utf8)).sadpSolicitedMatch)
        #expect(match.isRecoveredFromMalformedXML)
        #expect(match.mac?.description == "c4:2f:90:ab:cd:ef")
        #expect(match.httpPort == 80)               // the last element's text is still flushed
    }

    /// A truncation that carries no identity at all is refused rather than turned into a phantom
    /// device: an empty row in the discovery sheet is worse than no row.
    @Test func sadpTruncationWithoutIdentityIsMalformed() {
        let xml = "<?xml version=\"1.0\"?>\n<ProbeMatch>\n<DeviceDescription>IPCam"
        guard case let .malformed(reason, prefixHex) = decode(Data(xml.utf8)) else {
            Issue.record("expected .malformed")
            return
        }
        #expect(reason.contains("Uuid"))
        #expect(prefixHex.count == 32)              // 16 bytes, hex
    }

    // MARK: - Size and shape

    /// One byte over the cap is refused without being parsed. The cap is what bounds every
    /// allocation downstream of it.
    @Test func sadpOversizedDatagramIsRefusedByTheCap() {
        let padding = String(repeating: " ", count: SADPCodec.maxDatagramBytes)
        let payload = Data((SADPFixtures.activatedCameraXML + padding).utf8)
        #expect(payload.count > SADPCodec.maxDatagramBytes)
        guard case let .malformed(reason, _) = decode(payload) else {
            Issue.record("expected .malformed for an oversized datagram")
            return
        }
        #expect(reason.contains("8192"))
    }

    /// Exactly at the cap still parses: the boundary is inclusive.
    @Test func sadpDatagramExactlyAtTheCapStillParses() {
        let base = SADPFixtures.activatedCameraXML
        let padding = String(repeating: " ",
                             count: SADPCodec.maxDatagramBytes - Data(base.utf8).count)
        let payload = Data((base + padding).utf8)
        #expect(payload.count == SADPCodec.maxDatagramBytes)
        #expect(decode(payload).sadpSolicitedMatch != nil)
    }

    /// An XML document whose root is something else entirely.
    @Test func sadpUnexpectedRootElementIsMalformed() {
        guard case let .malformed(reason, _) = decode(Data("<Hello><a>1</a></Hello>".utf8)) else {
            Issue.record("expected .malformed")
            return
        }
        #expect(reason.contains("hello"))
    }

    /// A BOM, leading whitespace and CRLF line endings are all tolerated.
    @Test func sadpToleratesBOMWhitespaceAndCRLF() throws {
        var payload = Data([0xEF, 0xBB, 0xBF, 0x0D, 0x0A, 0x20])
        payload.append(Data(SADPFixtures.activatedCameraXML
            .replacingOccurrences(of: "\n", with: "\r\n").utf8))
        let match = try #require(decode(payload).sadpSolicitedMatch)
        #expect(match.mac?.description == "c4:2f:90:ab:cd:ef")
        #expect(match.deviceSN == "DS-2CD2143G0-I20200114AAWRD12345678")
    }

    /// Values that cannot be a port, a number or an address leave their field `nil` instead of
    /// wrapping around, trapping, or being clamped to something plausible.
    @Test func sadpAbsurdNumericValuesDecodeToNil() throws {
        let xml = SADPFixtures.activatedCameraXML
            .replacingOccurrences(of: "<HttpPort>80</HttpPort>", with: "<HttpPort>70000</HttpPort>")
            .replacingOccurrences(of: "<HttpsPort>443</HttpsPort>", with: "<HttpsPort>0</HttpsPort>")
            .replacingOccurrences(of: "<RtspPort>554</RtspPort>", with: "<RtspPort>-1</RtspPort>")
            .replacingOccurrences(of: "<CommandPort>8000</CommandPort>",
                                  with: "<CommandPort>8000 </CommandPort>")
            .replacingOccurrences(of: "<DiskNumber>0</DiskNumber>",
                                  with: "<DiskNumber>99999999999999999999</DiskNumber>")
            .replacingOccurrences(of: "<IPv4Gateway>192.168.1.1</IPv4Gateway>",
                                  with: "<IPv4Gateway>192.168.1.256</IPv4Gateway>")
        let match = try #require(decode(Data(xml.utf8)).sadpSolicitedMatch)
        #expect(match.httpPort == nil)
        #expect(match.httpsPort == nil)
        #expect(match.rtspPort == nil)
        #expect(match.commandPort == 8000)          // surrounding whitespace is trimmed, not rejected
        #expect(match.diskNumber == nil)
        #expect(match.ipv4Gateway == nil)
        #expect(match.raw["httpport"] == "70000")   // the offending text survives for the log
    }

    /// A single element holding thousands of characters must not upset the parser or the serial
    /// splitter, and must not become a model.
    @Test func sadpAbsurdlyLongFieldIsHandled() throws {
        let long = String(repeating: "A", count: 6_000)
        let xml = SADPFixtures.activatedCameraXML.replacingOccurrences(
            of: "<DeviceSN>DS-2CD2143G0-I20200114AAWRD12345678</DeviceSN>",
            with: "<DeviceSN>\(long)</DeviceSN>")
        let match = try #require(decode(Data(xml.utf8)).sadpSolicitedMatch)
        #expect(match.deviceSN?.count == 6_000)
        #expect(match.model == nil)
        #expect(match.mac?.description == "c4:2f:90:ab:cd:ef")
    }

    /// `splitSerial` is a linear scan, so a very long serial is merely slow-free work, not a hazard.
    @Test func sadpSerialSplitHandlesVeryLongInput() {
        let long = String(repeating: "9", count: 50_000)
        let split = SADPCodec.splitSerial(long)
        #expect(split.model == nil)
        #expect(split.remainder.count == 50_000)
    }

    // MARK: - Entity and nesting bombs

    /// A billion-laughs document. Entity declarations are skipped whole rather than expanded, so the
    /// reference stays verbatim and the payload cannot grow at all.
    @Test func sadpEntityBombIsNotExpanded() throws {
        var lines = ["<?xml version=\"1.0\"?>", "<!DOCTYPE ProbeMatch [",
                     "<!ENTITY lol \"lol\">"]
        for level in 1...9 {
            let inner = level == 1 ? "lol" : "lol\(level - 1)"
            let body = Array(repeating: "&\(inner);", count: 10).joined()
            lines.append("<!ENTITY lol\(level) \"\(body)\">")
        }
        lines.append("]>")
        lines.append("<ProbeMatch>")
        lines.append("<Uuid>1F9B2A6C-4E1D-4F5A-9C3E-7A2B5D8E0C11</Uuid>")
        lines.append("<MAC>c4-2f-90-ab-cd-ef</MAC>")
        lines.append("<DeviceDescription>&lol9;</DeviceDescription>")
        lines.append("</ProbeMatch>")
        let payload = Data(lines.joined(separator: "\n").utf8)
        #expect(payload.count < SADPCodec.maxDatagramBytes)

        let match = try #require(decode(payload).sadpSolicitedMatch)
        #expect(match.deviceDescription == "&lol9;")
        #expect(match.mac?.description == "c4:2f:90:ab:cd:ef")
    }

    /// Deep nesting stops at the depth bound instead of recursing. The scanner keeps a stack of
    /// names, so there is no Swift stack to overflow in the first place.
    @Test func sadpDeeplyNestedDocumentStopsAtTheDepthBound() {
        let nested = String(repeating: "<a>", count: 2_000)
        let payload = Data(("<ProbeMatch>" + nested).utf8)
        #expect(payload.count < SADPCodec.maxDatagramBytes)
        // No identity survived, so this is refused — the point is that it returns at all.
        guard case .malformed = decode(payload) else {
            Issue.record("expected .malformed for a nesting bomb")
            return
        }
    }

    /// Mismatched end tags are a parse failure, not a trap.
    @Test func sadpMismatchedEndTagsAreTolerated() throws {
        let xml = """
            <ProbeMatch>
            <Uuid>1F9B2A6C-4E1D-4F5A-9C3E-7A2B5D8E0C11</Uuid>
            <MAC>c4-2f-90-ab-cd-ef</MAC></Nope>
            <HttpPort>80</HttpPort>
            </ProbeMatch>
            """
        let match = try #require(decode(Data(xml.utf8)).sadpSolicitedMatch)
        #expect(match.isRecoveredFromMalformedXML)
        #expect(match.httpPort == 80)
    }

    // MARK: - Obfuscated payloads

    /// Test 13. The XOR-recovered payload must decode to exactly the plaintext record.
    @Test func sadpXORObfuscatedPayloadRecoversTheSameRecord() throws {
        let plain = try #require(decode(SADPFixtures.activatedCameraDatagram).sadpSolicitedMatch)
        let recovered = try #require(decode(SADPFixtures.xorObfuscatedCameraDatagram)
            .sadpSolicitedMatch)
        #expect(plain == recovered)
    }

    /// Recovery is not special-cased to one key.
    @Test func sadpXORRecoveryWorksForEveryKey() throws {
        for key: UInt8 in [0x01, 0x42, 0x7F, 0xFF] {
            let scrambled = Data(SADPFixtures.activatedCameraDatagram.map { $0 ^ key })
            let match = try #require(decode(scrambled).sadpSolicitedMatch, "key \(key)")
            #expect(match.mac?.description == "c4:2f:90:ab:cd:ef", "key \(key)")
        }
    }

    /// Test 14. Random bytes are neither XML nor XOR-recoverable, so they degrade to `.opaque` with
    /// the entropy that tells a support engineer it was encrypted rather than merely scrambled.
    @Test func sadpUnrecoverableRandomPayloadBecomesOpaque() throws {
        let payload = try #require(decode(SADPFixtures.randomOpaqueDatagram).sadpOpaquePayload)
        #expect(payload.length == 700)
        #expect(payload.source == Self.source)
        #expect(payload.prefixHex.count == 64)      // 32 bytes
        #expect(payload.entropyBitsPerByte > 7.0)
        #expect(payload.entropyBitsPerByte <= 8.0)
        #expect(!payload.looksCompressed)
    }

    /// Test 15. Compressed payloads are recorded, never inflated: no dependency-free inflate exists
    /// in the pure layer and writing one for a case no capture has confirmed would be speculation.
    @Test func sadpGzipMagicIsRecordedAndNotInflated() throws {
        let payload = try #require(decode(SADPFixtures.gzipMagicDatagram).sadpOpaquePayload)
        #expect(payload.looksCompressed)
        #expect(payload.prefixHex.hasPrefix("1f8b0800"))
    }

    /// zlib's three common headers are recognised too.
    @Test func sadpZlibMagicIsRecognised() throws {
        for second: UInt8 in [0x01, 0x9C, 0xDA] {
            var bytes: [UInt8] = [0x78, second]
            bytes.append(contentsOf: Array(repeating: 0xA5, count: 64))
            let payload = try #require(decode(Data(bytes)).sadpOpaquePayload)
            #expect(payload.looksCompressed, "second byte \(second)")
        }
    }

    /// Plain text that is not XML and not recoverable.
    @Test func sadpPlainTextGarbageBecomesOpaque() throws {
        let payload = try #require(decode(Data("hello world, not a camera".utf8))
            .sadpOpaquePayload)
        #expect(payload.length == 25)
        #expect(!payload.looksCompressed)
        #expect(payload.entropyBitsPerByte > 3.0)
    }

    /// A payload that survives the XOR prefix test but is not a usable document falls back to
    /// `.opaque` rather than being reported as a malformed camera.
    @Test func sadpXORPrefixWithoutAUsableDocumentFallsBackToOpaque() throws {
        let bytes = Array("<?xml version=\"1.0\"?><Nonsense/>".utf8).map { $0 ^ 0x33 }
        let payload = try #require(decode(Data(bytes)).sadpOpaquePayload)
        #expect(payload.length == bytes.count)
    }

    /// Entropy is a plain measurement: uniform input scores 8, a single repeated byte scores 0.
    @Test func sadpEntropyMeasuresWhatItClaims() {
        #expect(SADPCodec.shannonEntropyBitsPerByte([UInt8]()) == 0)
        #expect(SADPCodec.shannonEntropyBitsPerByte(Array(repeating: 0x41, count: 512)) == 0)
        let uniform = (0...255).map { UInt8($0) }
        #expect(abs(SADPCodec.shannonEntropyBitsPerByte(uniform) - 8.0) < 0.000_001)
        let xmlEntropy = SADPCodec.shannonEntropyBitsPerByte(SADPFixtures.activatedCameraDatagram)
        #expect(xmlEntropy > 3.5 && xmlEntropy < 6.0)
    }
}
