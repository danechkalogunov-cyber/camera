//
//  SADPCodecTests.swift
//  VigilDiscoveryTests
//
//  The SADP probe is byte-exact and the three recorded ProbeMatch samples decode field for field,
//  including the factory-fresh camera whose `Activated=false` must reach the user as its own state.
//  Covers docs/spec-discovery.md §4.2, §4.4, §4.5, §13.2 tests 1–9, 19, 20.
//

import Foundation
import Testing
import VigilProtocols

@testable import VigilDiscovery

// MARK: - Result accessors

extension SADPDecodeResult {
    /// The match of a `.probeMatch` — a solicited answer only.
    var sadpSolicitedMatch: SADPProbeMatch? {
        if case let .probeMatch(match) = self { match } else { nil }
    }

    /// The match of either `.probeMatch` or `.foreignProbeMatch`.
    var sadpAnyMatch: SADPProbeMatch? {
        switch self {
        case let .probeMatch(match), let .foreignProbeMatch(match): match
        default: nil
        }
    }

    /// The payload of `.opaque`.
    var sadpOpaquePayload: SADPOpaquePayload? {
        if case let .opaque(payload) = self { payload } else { nil }
    }
}

// MARK: - Probe encoding

@Suite struct SADPProbeEncodingTests {

    /// Test 1. The probe must equal the §14.1 dump byte for byte: one wrong byte and firmware
    /// silently ignores the datagram, which looks exactly like an empty network.
    @Test func sadpProbeIsByteExactAgainstSpecDump() {
        let encoded = SADPCodec.encodeProbe(uuid: SADPFixtures.probeUUID)
        #expect(encoded == SADPFixtures.hexData(SADPFixtures.probeGoldenHex))
    }

    /// The §14.1 dump is 129 bytes, not the 121 the prose claims. Asserted so the discrepancy is
    /// recorded in a place that fails if anyone "fixes" the encoder to match the prose.
    @Test func sadpProbeIsOneHundredTwentyNineBytes() {
        #expect(SADPCodec.encodeProbe(uuid: SADPFixtures.probeUUID).count == 129)
        #expect(SADPFixtures.hexData(SADPFixtures.probeGoldenHex).count == 129)
    }

    /// Test 2. Uppercase, hyphenated, unbraced, 36 characters.
    @Test func sadpProbeUUIDIsUppercaseHyphenated() throws {
        let text = try #require(String(data: SADPCodec.encodeProbe(uuid: SADPFixtures.probeUUID),
                                       encoding: .utf8))
        let uuid = try #require(text.split(separator: "\n")
            .first { $0.hasPrefix("<Uuid>") }?
            .replacingOccurrences(of: "<Uuid>", with: "")
            .replacingOccurrences(of: "</Uuid>", with: ""))
        #expect(uuid.count == 36)
        #expect(!uuid.contains("{"))
        #expect(!uuid.contains("}"))
        #expect(uuid == uuid.uppercased())
        #expect(uuid.split(separator: "-").map(\.count) == [8, 4, 4, 4, 12])
    }

    /// `\n` only: some very old firmware chokes on `\r\n` inside the prolog.
    @Test func sadpProbeUsesLineFeedsOnlyAndNoTrailingNUL() {
        let bytes = [UInt8](SADPCodec.encodeProbe(uuid: SADPFixtures.probeUUID))
        #expect(!bytes.contains(0x0D))
        #expect(!bytes.contains(0x00))
        #expect(bytes.last == 0x0A)
    }

    /// §4.2: we deliberately omit the optional `<MAC>` element the official tool sends, so a scan
    /// does not broadcast our own MAC to every device on the LAN.
    @Test func sadpProbeOmitsOurOwnMAC() throws {
        let text = try #require(String(data: SADPCodec.encodeProbe(uuid: SADPFixtures.probeUUID),
                                       encoding: .utf8))
        #expect(!text.contains("<MAC>"))
        #expect(text.contains("<Types>inquiry</Types>"))
    }

    /// A fresh UUID changes only the UUID: the framing stays byte-identical.
    @Test func sadpProbeShapeIsIndependentOfUUID() throws {
        let other = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        let encoded = SADPCodec.encodeProbe(uuid: other)
        let golden = SADPFixtures.hexData(SADPFixtures.probeGoldenHex)
        #expect(encoded.count == golden.count)
        #expect(encoded.prefix(53) == golden.prefix(53))     // everything up to the UUID
        #expect(encoded.suffix(40) == golden.suffix(40))     // everything after it
    }
}

// MARK: - ProbeMatch decoding

@Suite struct SADPProbeMatchDecodeTests {

    private static let cameraSource = IPv4Address(192, 168, 1, 64)

    /// Test 3. Every field of §4.4.1, including the ones this type does not model, which must
    /// survive in `raw`.
    @Test func sadpDecodesActivatedCameraFieldForField() throws {
        let result = SADPCodec.decode(SADPFixtures.activatedCameraDatagram,
                                      from: Self.cameraSource,
                                      expectedUUID: SADPFixtures.probeUUID,
                                      receivedAt: SADPFixtures.receivedAt)
        let match = try #require(result.sadpSolicitedMatch)

        #expect(match.uuid == "1F9B2A6C-4E1D-4F5A-9C3E-7A2B5D8E0C11")
        #expect(match.deviceType == 0)
        #expect(match.deviceDescription == "IPCamera")
        #expect(match.deviceSN == "DS-2CD2143G0-I20200114AAWRD12345678")
        #expect(match.commandPort == 8000)
        #expect(match.httpPort == 80)
        #expect(match.httpsPort == 443)
        #expect(match.rtspPort == 554)
        #expect(match.mac?.description == "c4:2f:90:ab:cd:ef")
        #expect(match.ipv4Address == IPv4Address(192, 168, 1, 64))
        #expect(match.ipv4SubnetMask == IPv4Address(255, 255, 255, 0))
        #expect(match.ipv4Gateway == IPv4Address(192, 168, 1, 1))
        #expect(match.ipv6Address == "fe80::c62f:90ff:feab:cdef")
        #expect(match.dhcp == false)
        #expect(match.softwareVersion == "V5.5.82build 190910")
        #expect(match.dspVersion == "V7.3 build 190430")
        #expect(match.bootTimeLocalString == "2026-07-19 06:14:02")
        #expect(match.activated == true)
        #expect(match.passwordResetAbility == true)
        #expect(match.supportHCPlatform == true)
        #expect(match.analogChannelNum == 0)
        #expect(match.digitalChannelNum == 0)
        #expect(match.diskNumber == 0)
        #expect(match.oemInfo == nil)
        #expect(match.deviceLock == false)
        #expect(match.observedFrom == Self.cameraSource)
        #expect(match.receivedAt == SADPFixtures.receivedAt)
        #expect(match.payloadEncoding == .utf8)
        #expect(!match.isRecoveredFromMalformedXML)

        // Derived
        #expect(match.model == "DS-2CD2143G0-I")
        #expect(match.activationState == .activated)
        #expect(match.deviceClass == .camera)
        #expect(match.vendor == .hikvision)
        #expect(match.normalizedFirmwareVersion == "V5.5.82 build 190910")

        // Unmodelled elements, verbatim
        #expect(match.raw.count == 33)
        #expect(match.raw["sdkovertlsport"] == "8443")
        #expect(match.raw["ipv6gateway"] == "::")
        #expect(match.raw["ipv6masklen"] == "64")
        #expect(match.raw["resetability"] == "true")
        #expect(match.raw["passwordresetmodesecond"] == "true")
        #expect(match.raw["hcplatformenable"] == "false")
        #expect(match.raw["supportsecurityquestion"] == "true")
        #expect(match.raw["salt"] == "d41d8cd98f00b204e9800998ecf8427e")
    }

    /// Test 4. The whole point of parsing SADP: a factory-fresh camera has **no password**, so a
    /// connection attempt can only fail. It must arrive as `.notActivated`, not as an error.
    @Test func sadpDecodesNotActivatedCameraAsItsOwnState() throws {
        let result = SADPCodec.decode(Data(SADPFixtures.notActivatedCameraXML.utf8),
                                      from: Self.cameraSource,
                                      expectedUUID: SADPFixtures.probeUUID,
                                      receivedAt: SADPFixtures.receivedAt)
        let match = try #require(result.sadpSolicitedMatch)

        #expect(match.activated == false)
        #expect(match.activationState == .notActivated)
        #expect(match.passwordResetAbility == false)
        #expect(match.mac?.description == "44:19:b6:11:22:33")
        #expect(match.model == "DS-2CD2347G2-LU")
        #expect(match.deviceClass == .camera)
        #expect(match.httpsPort == nil)          // firmware 5.7.3 omits it
        #expect(match.rtspPort == nil)           // absent: the caller defaults to 554
        #expect(match.ipv6Address == nil)        // "::" is not an address

        let observation = SADPCodec.observation(from: match, source: .sadpMulticast)
        #expect(observation.fields[.activation] == .activation(.notActivated))
    }

    /// A firmware that predates `<Activated>` must read as `.unknown`, never as "fine": guessing
    /// "activated" here would hide the one condition the user has to act on.
    @Test func sadpMissingActivatedElementIsUnknownNotActivated() throws {
        let xml = SADPFixtures.notActivatedCameraXML
            .replacingOccurrences(of: "<Activated>false</Activated>\n", with: "")
        let match = try #require(SADPCodec.decode(Data(xml.utf8), from: Self.cameraSource,
                                                  expectedUUID: nil,
                                                  receivedAt: SADPFixtures.receivedAt)
            .sadpSolicitedMatch)
        #expect(match.activated == nil)
        #expect(match.activationState == .unknown)
        let observation = SADPCodec.observation(from: match, source: .sadpMulticast)
        #expect(observation.fields[.activation] == nil)     // "no opinion", not "cleared"
    }

    /// Test 5. An NVR: channel counts and disks decide the class, and the empty `<OEMinfo>` must
    /// not be mistaken for a rebrand.
    @Test func sadpDecodesNVRWithChannelsAndDisks() throws {
        let match = try #require(SADPCodec.decode(Data(SADPFixtures.nvrXML.utf8),
                                                  from: IPv4Address(10, 0, 20, 11),
                                                  expectedUUID: SADPFixtures.probeUUID,
                                                  receivedAt: SADPFixtures.receivedAt)
            .sadpSolicitedMatch)
        #expect(match.digitalChannelNum == 16)
        #expect(match.analogChannelNum == 0)
        #expect(match.diskNumber == 2)
        #expect(match.deviceClass == .nvr)
        #expect(match.deviceType == 2)
        #expect(match.dhcp == true)
        #expect(match.model == "DS-7616NI-K2/16P16")
        #expect(match.oemInfo == nil)
        #expect(match.vendor == .hikvision)
        #expect(match.raw["oeminfo"] == "")
    }

    /// A non-empty `OEMinfo` is a rebrand: ISAPI still works, the branding does not.
    @Test func sadpOEMInfoMarksHikvisionOEM() throws {
        let match = try #require(SADPCodec.decode(Data(SADPFixtures.oemCameraXML.utf8),
                                                  from: Self.cameraSource, expectedUUID: nil,
                                                  receivedAt: SADPFixtures.receivedAt)
            .sadpSolicitedMatch)
        #expect(match.oemInfo == "HiLook")
        #expect(match.vendor == .hikvisionOEM)
        #expect(match.model == "HWI-B140H")
    }

    /// Test 6. Every separator firmware emits reduces to the same address.
    @Test func sadpAcceptsEveryMACSeparatorVariant() throws {
        let spellings = ["c4-2f-90-ab-cd-ef", "C4:2F:90:AB:CD:EF", "c42f90abcdef", "c42f.90ab.cdef"]
        for spelling in spellings {
            let xml = SADPFixtures.activatedCameraXML
                .replacingOccurrences(of: "<MAC>c4-2f-90-ab-cd-ef</MAC>", with: "<MAC>\(spelling)</MAC>")
            let match = try #require(SADPCodec.decode(Data(xml.utf8), from: Self.cameraSource,
                                                      expectedUUID: nil,
                                                      receivedAt: SADPFixtures.receivedAt)
                .sadpSolicitedMatch)
            #expect(match.mac?.rawValue == 0xC42F_90AB_CDEF, "spelling \(spelling)")
        }
    }

    /// A MAC that is not twelve nibbles leaves the field `nil` — it does not fail the record, and
    /// the offending text stays in `raw` for the log.
    @Test func sadpUnparseableMACLeavesFieldNilAndKeepsRaw() throws {
        let xml = SADPFixtures.activatedCameraXML
            .replacingOccurrences(of: "<MAC>c4-2f-90-ab-cd-ef</MAC>", with: "<MAC>c4-2f-90-ab-cd</MAC>")
        let match = try #require(SADPCodec.decode(Data(xml.utf8), from: Self.cameraSource,
                                                  expectedUUID: nil,
                                                  receivedAt: SADPFixtures.receivedAt)
            .sadpSolicitedMatch)
        #expect(match.mac == nil)
        #expect(match.raw["mac"] == "c4-2f-90-ab-cd")
        #expect(match.ipv4Address == IPv4Address(192, 168, 1, 64))
    }

    /// Test 7. A future firmware's new element must not be dropped.
    @Test func sadpPreservesUnknownElements() throws {
        let xml = SADPFixtures.activatedCameraXML
            .replacingOccurrences(of: "<DiskNumber>0</DiskNumber>",
                                  with: "<DiskNumber>0</DiskNumber>\n<FutureThing>42</FutureThing>")
        let match = try #require(SADPCodec.decode(Data(xml.utf8), from: Self.cameraSource,
                                                  expectedUUID: nil,
                                                  receivedAt: SADPFixtures.receivedAt)
            .sadpSolicitedMatch)
        #expect(match.raw["futurething"] == "42")
    }

    /// Test 8. Element names vary in case across firmware, and OEM builds sometimes add a namespace
    /// prefix; both must land in the same field.
    @Test func sadpElementNamesAreCaseAndPrefixInsensitive() throws {
        let xml = SADPFixtures.activatedCameraXML
            .replacingOccurrences(of: "<DeviceSN>", with: "<DEVICESN>")
            .replacingOccurrences(of: "</DeviceSN>", with: "</DEVICESN>")
            .replacingOccurrences(of: "<HttpPort>", with: "<hik:httpport>")
            .replacingOccurrences(of: "</HttpPort>", with: "</hik:httpport>")
        let match = try #require(SADPCodec.decode(Data(xml.utf8), from: Self.cameraSource,
                                                  expectedUUID: nil,
                                                  receivedAt: SADPFixtures.receivedAt)
            .sadpSolicitedMatch)
        #expect(match.deviceSN == "DS-2CD2143G0-I20200114AAWRD12345678")
        #expect(match.httpPort == 80)
    }

    /// Test 9. Hikvision ships documents with a bare `&`. Strict parsing loses a real camera.
    @Test func sadpRecoversUnescapedAmpersand() throws {
        let match = try #require(SADPCodec.decode(Data(SADPFixtures.unescapedAmpersandXML.utf8),
                                                  from: Self.cameraSource, expectedUUID: nil,
                                                  receivedAt: SADPFixtures.receivedAt)
            .sadpSolicitedMatch)
        #expect(match.deviceDescription == "Lobby & Dock")
        #expect(match.mac?.description == "c4:2f:90:ab:cd:ef")
        #expect(!match.isRecoveredFromMalformedXML)
    }

    /// Test 19. A GB18030 byte is not valid UTF-8. The record must survive, with the encoding
    /// recorded so the caller can raise `nonUTF8SADPPayload`.
    @Test func sadpFallsBackToLatin1ForNonUTF8Payload() throws {
        let match = try #require(SADPCodec.decode(SADPFixtures.latin1CameraDatagram,
                                                  from: Self.cameraSource, expectedUUID: nil,
                                                  receivedAt: SADPFixtures.receivedAt)
            .sadpSolicitedMatch)
        #expect(match.payloadEncoding == .isoLatin1Fallback)
        #expect(match.deviceDescription == "IPCamera\u{00B0}")
        // The fields that decide whether the camera is usable are ASCII and unaffected.
        #expect(match.deviceSN == "DS-2CD2143G0-I20200114AAWRD12345678")
        #expect(match.mac?.description == "c4:2f:90:ab:cd:ef")
        #expect(match.httpPort == 80)
    }

    /// Test 11. Our own probe, looped back by the local stack.
    @Test func sadpOwnProbeEchoIsRecognised() {
        let result = SADPCodec.decode(SADPCodec.encodeProbe(uuid: SADPFixtures.probeUUID),
                                      from: IPv4Address(10, 0, 20, 5),
                                      expectedUUID: SADPFixtures.probeUUID,
                                      receivedAt: SADPFixtures.receivedAt)
        #expect(result == .ownProbeEcho)
    }

    /// A probe from another SADP client. Not a device, but proof that multicast reception works —
    /// which is exactly what a silent run cannot tell us.
    @Test func sadpForeignProbeIsReportedWithItsUUID() {
        let result = SADPCodec.decode(Data(SADPFixtures.foreignProbeXML.utf8),
                                      from: IPv4Address(10, 0, 20, 9),
                                      expectedUUID: SADPFixtures.probeUUID,
                                      receivedAt: SADPFixtures.receivedAt)
        #expect(result == .foreignProbe(uuid: "7C1E4B90-0000-4000-8000-ABCDEF012345"))
    }

    /// Without an expected UUID we cannot claim a probe is ours, so it reads as foreign.
    @Test func sadpProbeWithoutExpectedUUIDIsNotClaimedAsOurs() {
        let result = SADPCodec.decode(SADPCodec.encodeProbe(uuid: SADPFixtures.probeUUID),
                                      from: IPv4Address(10, 0, 20, 5), expectedUUID: nil,
                                      receivedAt: SADPFixtures.receivedAt)
        #expect(result == .foreignProbe(uuid: "1F9B2A6C-4E1D-4F5A-9C3E-7A2B5D8E0C11"))
    }

    /// Test 12. A ProbeMatch answering somebody else's probe is still a real device on our LAN, so
    /// it is ingested — flagged, so the merge engine can score it down.
    @Test func sadpForeignProbeMatchIsIngestedAndFlagged() throws {
        let xml = SADPFixtures.activatedCameraXML.replacingOccurrences(
            of: "1F9B2A6C-4E1D-4F5A-9C3E-7A2B5D8E0C11",
            with: "7C1E4B90-0000-4000-8000-ABCDEF012345")
        let result = SADPCodec.decode(Data(xml.utf8), from: Self.cameraSource,
                                      expectedUUID: SADPFixtures.probeUUID,
                                      receivedAt: SADPFixtures.receivedAt)
        #expect(result.sadpSolicitedMatch == nil)
        let match = try #require(result.sadpAnyMatch)
        #expect(match.mac?.description == "c4:2f:90:ab:cd:ef")
        #expect(SADPCodec.foreignProbeMatchConfidencePenalty == -10)

        let observation = SADPCodec.observation(from: match, source: .sadpMulticast,
                                                isForeignProbeMatch: true)
        #expect(observation.isForeignProbeMatch)
    }

    /// Correlation is case-insensitive: firmware echoes our UUID in whatever case it likes.
    @Test func sadpUUIDCorrelationIsCaseInsensitive() {
        let xml = SADPFixtures.activatedCameraXML.replacingOccurrences(
            of: "1F9B2A6C-4E1D-4F5A-9C3E-7A2B5D8E0C11",
            with: "1f9b2a6c-4e1d-4f5a-9c3e-7a2b5d8e0c11")
        let result = SADPCodec.decode(Data(xml.utf8), from: Self.cameraSource,
                                      expectedUUID: SADPFixtures.probeUUID,
                                      receivedAt: SADPFixtures.receivedAt)
        #expect(result.sadpSolicitedMatch != nil)
    }
}

// MARK: - Observation projection

@Suite struct SADPObservationTests {

    /// The full field projection a camera contributes to the merge engine.
    @Test func sadpObservationCarriesEveryObservedField() throws {
        let match = try #require(SADPCodec.decode(SADPFixtures.activatedCameraDatagram,
                                                  from: IPv4Address(192, 168, 1, 64),
                                                  expectedUUID: SADPFixtures.probeUUID,
                                                  receivedAt: SADPFixtures.receivedAt)
            .sadpSolicitedMatch)
        let observation = SADPCodec.observation(from: match, source: .sadpMulticast)

        #expect(observation.source == .sadpMulticast)
        #expect(observation.observedAt == SADPFixtures.receivedAt)
        #expect(observation.address == IPv4Address(192, 168, 1, 64))
        #expect(observation.mac?.description == "c4:2f:90:ab:cd:ef")
        #expect(!observation.macIsHintOnly)                 // SADP read it off the device
        #expect(observation.serialNumber == "DS-2CD2143G0-I20200114AAWRD12345678")
        #expect(observation.onvifUUID == nil)
        #expect(observation.fields[.httpPort] == .port(80))
        #expect(observation.fields[.httpsPort] == .port(443))
        #expect(observation.fields[.rtspPort] == .port(554))
        #expect(observation.fields[.commandPort] == .port(8000))
        #expect(observation.fields[.model] == .string("DS-2CD2143G0-I"))
        #expect(observation.fields[.firmwareVersion] == .string("V5.5.82 build 190910"))
        #expect(observation.fields[.dspVersion] == .string("V7.3 build 190430"))
        #expect(observation.fields[.subnetMask] == .ipv4(IPv4Address(255, 255, 255, 0)))
        #expect(observation.fields[.gateway] == .ipv4(IPv4Address(192, 168, 1, 1)))
        #expect(observation.fields[.dhcpEnabled] == .bool(false))
        #expect(observation.fields[.vendor] == .vendor(.hikvision))
        #expect(observation.fields[.deviceClass] == .deviceClass(.camera))
        #expect(observation.fields[.activation] == .activation(.activated))
        #expect(observation.fields[.passwordResetAbility] == .bool(true))
        #expect(observation.fields[.supportsHCPlatform] == .bool(true))
        #expect(observation.fields[.bootTime] == nil)       // no zone was supplied
        #expect(!observation.isForeignProbeMatch)
    }

    /// Test 20. Unicast SADP is the same payload through the same decoder; only the provenance
    /// label differs, and both weigh the same because the bytes are identical (§4.9).
    @Test func sadpUnicastUsesTheSameDecoderAndDiffersOnlyInSource() throws {
        let multicast = try #require(SADPCodec.decode(SADPFixtures.activatedCameraDatagram,
                                                      from: IPv4Address(192, 168, 1, 64),
                                                      expectedUUID: SADPFixtures.probeUUID,
                                                      receivedAt: SADPFixtures.receivedAt)
            .sadpSolicitedMatch)
        let unicast = try #require(SADPCodec.decode(SADPFixtures.activatedCameraDatagram,
                                                    from: IPv4Address(192, 168, 1, 64),
                                                    expectedUUID: SADPFixtures.probeUUID,
                                                    receivedAt: SADPFixtures.receivedAt)
            .sadpSolicitedMatch)
        #expect(multicast == unicast)

        let one = SADPCodec.observation(from: multicast, source: .sadpMulticast)
        let two = SADPCodec.observation(from: unicast, source: .sadpUnicast)
        #expect(one.source == .sadpMulticast)
        #expect(two.source == .sadpUnicast)
        #expect(one.fields == two.fields)
        #expect(DiscoverySource.sadpUnicast.trust == DiscoverySource.sadpMulticast.trust)
    }

    /// §4.7: a factory camera answers over link-local multicast from an address that is not on our
    /// LAN. The observation must carry the **device's** address, which is what makes the off-subnet
    /// diagnosis possible at all.
    @Test func sadpObservationPrefersTheDeviceAddressOverTheDatagramSource() throws {
        let match = try #require(SADPCodec.decode(Data(SADPFixtures.notActivatedCameraXML.utf8),
                                                  from: IPv4Address(10, 0, 20, 77),
                                                  expectedUUID: nil,
                                                  receivedAt: SADPFixtures.receivedAt)
            .sadpSolicitedMatch)
        let observation = SADPCodec.observation(from: match, source: .sadpMulticast)
        #expect(observation.address == IPv4Address(192, 168, 1, 64))
        #expect(match.observedFrom == IPv4Address(10, 0, 20, 77))
    }

    /// When the device sent no address of its own, the datagram source is all we have.
    @Test func sadpObservationFallsBackToTheDatagramSource() throws {
        let xml = SADPFixtures.activatedCameraXML
            .replacingOccurrences(of: "<IPv4Address>192.168.1.64</IPv4Address>",
                                  with: "<IPv4Address>0.0.0.0</IPv4Address>")
        let match = try #require(SADPCodec.decode(Data(xml.utf8), from: IPv4Address(10, 0, 20, 12),
                                                  expectedUUID: nil,
                                                  receivedAt: SADPFixtures.receivedAt)
            .sadpSolicitedMatch)
        #expect(match.ipv4Address == nil)
        #expect(SADPCodec.observation(from: match, source: .sadpMulticast).address
                    == IPv4Address(10, 0, 20, 12))
    }

    /// The degraded record from an unparseable datagram: vendor known, nothing else claimed (§4.8.3).
    @Test func sadpDegradedObservationClaimsOnlyTheVendor() throws {
        let payload = try #require(SADPCodec.decode(SADPFixtures.randomOpaqueDatagram,
                                                    from: IPv4Address(10, 0, 20, 31),
                                                    expectedUUID: SADPFixtures.probeUUID,
                                                    receivedAt: SADPFixtures.receivedAt)
            .sadpOpaquePayload)
        let observation = SADPCodec.degradedObservation(from: payload, source: .sadpMulticast,
                                                        observedAt: SADPFixtures.receivedAt)
        #expect(observation.address == IPv4Address(10, 0, 20, 31))
        #expect(observation.fields[.vendor] == .vendor(.hikvision))
        #expect(observation.fields.count == 2)
        #expect(observation.mac == nil)
        #expect(SADPCodec.opaquePayloadConfidence == 35)
    }
}
