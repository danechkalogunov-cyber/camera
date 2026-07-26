//
//  WSDiscoveryDecodeTests.swift
//  VigilDiscoveryTests
//
//  ProbeMatches, Hello, Bye and everything else that lands on 239.255.255.250:3702, including the
//  prefix and namespace variants firmware really sends and the datagrams built to make us allocate.
//  Covers docs/spec-discovery.md §5.5, §5.6, §5.7 and §13.3 tests 23–35.
//

import Foundation
import Testing
import VigilProtocols

@testable import VigilDiscovery

extension WSDDecodeOutcome {
    /// The matches of `.probeMatches` or `.hello`.
    var wsdMatches: [WSDProbeMatch]? {
        switch self {
        case let .probeMatches(matches), let .hello(matches): matches
        default: nil
        }
    }
}

@Suite struct WSDiscoveryDecodeTests {

    private static let source = IPv4Address(192, 168, 1, 64)
    private static let expectedIDs: Set<String> = [WSDFixtures.probeMessageID]

    private func decode(_ xml: String,
                        expecting ids: Set<String> = WSDiscoveryDecodeTests.expectedIDs,
                        from source: IPv4Address = WSDiscoveryDecodeTests.source)
        -> WSDDecodeOutcome {
        WSDiscoveryCodec.decodeProbeMatches(Data(xml.utf8), from: source, expectedMessageIDs: ids,
                                           receivedAt: WSDFixtures.receivedAt)
    }

    // MARK: - The recorded Hikvision sample

    /// Test 23. Field for field, including both service URLs in order.
    @Test func wsdDecodesHikvisionProbeMatch() throws {
        let matches = try #require(decode(WSDFixtures.hikvisionProbeMatchXML).wsdMatches)
        #expect(matches.count == 1)
        let match = try #require(matches.first)

        #expect(match.endpointAddress == WSDFixtures.hikvisionEndpoint)
        #expect(match.types == ["NetworkVideoTransmitter", "Device"])
        #expect(match.xAddrs == ["http://192.168.1.64/onvif/device_service",
                                 "http://[fe80::c62f:90ff:feab:cdef]/onvif/device_service"])
        #expect(match.metadataVersion == 10)
        #expect(match.relatesTo == WSDFixtures.probeMessageID)
        #expect(match.messageID == WSDFixtures.responseMessageID)
        #expect(match.appSequenceInstanceID == "1751030401")
        #expect(match.observedFrom == Self.source)
        #expect(match.receivedAt == WSDFixtures.receivedAt)
        #expect(match.isCorrelated)
        #expect(match.deviceClass == .camera)
        #expect(match.inferredVendor == .hikvision)
        #expect(match.dedupeKey == WSDFixtures.hikvisionEndpoint)
        #expect(match.xAddrHosts == [IPv4Address(192, 168, 1, 64)])   // the IPv6 URL is skipped
    }

    /// Test 24. Percent-decoding is not optional: without it the name reads `HIKVISION%20DS-…` and
    /// the MAC hint reads `c4%3A2f…`.
    @Test func wsdScopesArePercentDecoded() throws {
        let match = try #require(decode(WSDFixtures.hikvisionProbeMatchXML).wsdMatches?.first)
        #expect(match.scopes.name == "HIKVISION DS-2CD2143G0-I")
        #expect(match.scopes.macHint?.description == "c4:2f:90:ab:cd:ef")
        #expect(match.scopes.raw.contains("onvif://www.onvif.org/name/HIKVISION DS-2CD2143G0-I"))
    }

    /// Test 25. Hardware and location, including the deeper `location/country/<v>` spelling.
    @Test func wsdScopeHardwareAndLocation() throws {
        let hik = try #require(decode(WSDFixtures.hikvisionProbeMatchXML).wsdMatches?.first)
        #expect(hik.scopes.hardware == "DS-2CD2143G0-I")
        #expect(hik.scopes.location == "china")

        let dahua = try #require(decode(WSDFixtures.dahuaProbeMatchXML).wsdMatches?.first)
        #expect(dahua.scopes.location == "china")      // from location/country/china
    }

    /// Test 26. Profiles and types accumulate in order, and every scope survives in `raw`.
    @Test func wsdProfilesAndTypesCollected() throws {
        let match = try #require(decode(WSDFixtures.hikvisionProbeMatchXML).wsdMatches?.first)
        #expect(match.scopes.profiles == ["Streaming", "G", "T"])
        #expect(match.scopes.types == ["Network_Video_Transmitter", "video_encoder"])
        #expect(match.scopes.raw.count == 9)
    }

    /// Test 27. Prefixes are cosmetic; only local names matter.
    @Test func wsdDecodingIsNamespacePrefixAgnostic() throws {
        let original = try #require(decode(WSDFixtures.hikvisionProbeMatchXML).wsdMatches?.first)
        let renamed = try #require(decode(WSDFixtures.alternatePrefixProbeMatchXML).wsdMatches?.first)
        #expect(original == renamed)
    }

    /// Test 28. Firmware that declares no namespaces at all still parses.
    @Test func wsdDecodesEnvelopeWithoutNamespaceDeclarations() throws {
        let match = try #require(decode(WSDFixtures.noNamespaceProbeMatchXML).wsdMatches?.first)
        #expect(match.endpointAddress == WSDFixtures.hikvisionEndpoint)
        #expect(match.types == ["NetworkVideoTransmitter", "Device"])
        #expect(match.scopes.name == "HIKVISION DS-2CD2143G0-I")
        #expect(match.xAddrs.count == 2)
        #expect(match.isCorrelated)
    }

    // MARK: - Correlation

    /// Test 29. An unknown or absent `RelatesTo` still ingests — plenty of firmware omits it — but
    /// is flagged so the merge engine can apply the penalty.
    @Test func wsdUncorrelatedMatchIsStillIngested() throws {
        let unknown = try #require(decode(WSDFixtures.hikvisionProbeMatchXML,
                                          expecting: ["urn:uuid:00000000-0000-4000-8000-000000000000"])
            .wsdMatches?.first)
        #expect(!unknown.isCorrelated)
        #expect(unknown.endpointAddress == WSDFixtures.hikvisionEndpoint)
        #expect(WSDiscoveryCodec.uncorrelatedConfidencePenalty == -5)

        let none = try #require(decode(WSDFixtures.hikvisionProbeMatchXML, expecting: [])
            .wsdMatches?.first)
        #expect(!none.isCorrelated)
    }

    /// Test 30. `uuid:x` and `urn:uuid:X` are the same identifier; firmware differs on which it
    /// echoes, and accepting only one spelling would drop half the answers on some networks.
    @Test func wsdMessageIDNormalisationAcceptsBothSpellings() throws {
        #expect(WSDiscoveryCodec.normalizedMessageID("urn:uuid:9A6F2C41-8B3D-4A7E-9F10-2C5B8E7D3A91")
                    == "9a6f2c41-8b3d-4a7e-9f10-2c5b8e7d3a91")
        #expect(WSDiscoveryCodec.normalizedMessageID("uuid:9a6f2c41-8b3d-4a7e-9f10-2c5b8e7d3a91")
                    == "9a6f2c41-8b3d-4a7e-9f10-2c5b8e7d3a91")
        #expect(WSDiscoveryCodec.normalizedMessageID("  9A6F2C41-8B3D-4A7E-9F10-2C5B8E7D3A91 ")
                    == "9a6f2c41-8b3d-4a7e-9f10-2c5b8e7d3a91")

        let shortForm: Set<String> = ["uuid:9A6F2C41-8B3D-4A7E-9F10-2C5B8E7D3A91"]
        let match = try #require(decode(WSDFixtures.hikvisionProbeMatchXML, expecting: shortForm)
            .wsdMatches?.first)
        #expect(match.isCorrelated)
    }

    // MARK: - Vendor and class

    /// Test 31. The "found, but not Hikvision" path, which the UI must state plainly.
    @Test func wsdDahuaProbeMatchIsClassifiedAsDahua() throws {
        let match = try #require(decode(WSDFixtures.dahuaProbeMatchXML,
                                        from: IPv4Address(10, 0, 20, 31)).wsdMatches?.first)
        #expect(match.inferredVendor == .dahua)
        #expect(match.scopes.hardware == "IPC-HDW4433C-A")
        #expect(match.deviceClass == .camera)
        #expect(match.metadataVersion == 1)
        #expect(match.xAddrHosts == [IPv4Address(10, 0, 20, 31)])
        #expect(!match.inferredVendor.supportsISAPI)
    }

    /// The §5.7 inference table, exercised through the scopes that drive it.
    @Test func wsdVendorInferenceFollowsTheSpecTable() {
        func vendor(name: String?, hardware: String?) -> DeviceVendor {
            let scopes = ONVIFScopes(name: name, hardware: hardware, raw: ["x"])
            return WSDProbeMatch(endpointAddress: nil, types: [], scopes: scopes, xAddrs: [],
                                 metadataVersion: nil, relatesTo: nil, messageID: nil,
                                 appSequenceInstanceID: nil,
                                 observedFrom: IPv4Address(10, 0, 0, 1),
                                 receivedAt: WSDFixtures.receivedAt, isCorrelated: false)
                .inferredVendor
        }
        #expect(vendor(name: "HIKVISION DS-2CD2143G0-I", hardware: nil) == .hikvision)
        #expect(vendor(name: nil, hardware: "DS-2CD2143G0-I") == .hikvision)
        #expect(vendor(name: nil, hardware: "iDS-2CD7A46G0") == .hikvision)
        #expect(vendor(name: nil, hardware: "HWI-B140H") == .hikvisionOEM)
        #expect(vendor(name: nil, hardware: "HWN-4108MH") == .hikvisionOEM)
        #expect(vendor(name: "DAHUA something", hardware: nil) == .dahua)
        #expect(vendor(name: nil, hardware: "IPC-HDW4433C-A") == .dahua)
        #expect(vendor(name: nil, hardware: "DH-SD1A404XB") == .dahua)
        #expect(vendor(name: nil, hardware: "SD5A425XB") == .dahua)
        #expect(vendor(name: nil, hardware: "NVR5216-EI") == .dahua)
        #expect(vendor(name: "AXIS M3045-V", hardware: nil) == .axis)
        #expect(vendor(name: "Reolink RLC-810A", hardware: nil) == .reolink)
        #expect(vendor(name: "Some Other Camera", hardware: "XYZ-1") == .genericONVIF)
        #expect(vendor(name: nil, hardware: nil) == .genericONVIF)
        // "DS" without a following digit is a word, not a model number.
        #expect(vendor(name: nil, hardware: "DS-Cinema") == .genericONVIF)
    }

    /// Recorders and decoders are told apart by `Types`; a PTZ scope promotes a camera.
    @Test func wsdDeviceClassComesFromTypesAndScopes() throws {
        func deviceClass(types: [String], scopes: ONVIFScopes = ONVIFScopes()) -> DeviceClass {
            WSDProbeMatch(endpointAddress: nil, types: types, scopes: scopes, xAddrs: [],
                          metadataVersion: nil, relatesTo: nil, messageID: nil,
                          appSequenceInstanceID: nil, observedFrom: IPv4Address(10, 0, 0, 1),
                          receivedAt: WSDFixtures.receivedAt, isCorrelated: false).deviceClass
        }
        #expect(deviceClass(types: ["NetworkVideoTransmitter"]) == .camera)
        #expect(deviceClass(types: ["NetworkVideoStorage"]) == .nvr)
        #expect(deviceClass(types: ["Recording"]) == .nvr)
        #expect(deviceClass(types: ["NetworkVideoDisplay"]) == .decoder)
        #expect(deviceClass(types: ["Device"]) == .unknown)
        #expect(deviceClass(types: ["NetworkVideoTransmitter"],
                            scopes: ONVIFScopes(types: ["ptz"], raw: ["x"])) == .ptzCamera)
    }

    // MARK: - Hello and Bye

    /// Test 32. A Hello is an unsolicited ProbeMatch; a Bye names the device that is leaving.
    @Test func wsdHelloAndByeAreHandled() throws {
        guard case let .hello(matches) = decode(WSDFixtures.helloXML) else {
            Issue.record("expected .hello")
            return
        }
        #expect(matches.count == 1)
        #expect(matches.first?.endpointAddress == WSDFixtures.hikvisionEndpoint)
        #expect(matches.first?.relatesTo == nil)          // Hello never has one
        #expect(matches.first?.isCorrelated == false)
        #expect(matches.first?.scopes.name == "HIKVISION DS-2CD2143G0-I")

        #expect(decode(WSDFixtures.byeXML)
                    == .bye(endpointAddress: WSDFixtures.hikvisionEndpoint))
    }

    /// An action we do not act on is reported, not mistaken for a device.
    @Test func wsdOtherActionIsReportedVerbatim() {
        #expect(decode(WSDFixtures.resolveActionXML)
                    == .otherAction("http://schemas.xmlsoap.org/ws/2005/04/discovery/Resolve"))
    }

    /// Body evidence decides even when the `Action` header is missing entirely.
    @Test func wsdBodyEvidenceWorksWithoutAnActionHeader() throws {
        let xml = WSDFixtures.hikvisionProbeMatchXML.replacingOccurrences(
            of: "<wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches</wsa:Action>",
            with: "")
        let matches = try #require(decode(xml).wsdMatches)
        #expect(matches.count == 1)
    }

    // MARK: - MAC hints

    /// Test 33. The endpoint UUID's tail is a MAC-shaped coincidence waiting to merge two cameras.
    /// It is a hint, and the observation says so.
    @Test func wsdEndpointUUIDMACIsHintOnly() throws {
        let match = try #require(decode(WSDFixtures.hikvisionProbeMatchXML).wsdMatches?.first)
        #expect(match.endpointUUIDMACHint?.description == "c4:2f:90:ab:cd:ef")

        let observation = WSDiscoveryCodec.observation(from: match)
        #expect(observation.macIsHintOnly)
        #expect(observation.mac?.description == "c4:2f:90:ab:cd:ef")
        // The identity ladder must not offer a MAC identity for a hint.
        #expect(!observation.identities.contains(where: { identity in
            if case .mac = identity { return true }
            return false
        }))
        #expect(observation.identities.contains(.onvifUUID(WSDFixtures.hikvisionEndpoint
            .replacingOccurrences(of: "urn:uuid:", with: ""))))
    }

    /// A UUID that is not `8-4-4-4-12` hex, or whose tail is not a usable unicast address, yields no
    /// hint at all rather than a plausible-looking wrong one.
    @Test func wsdEndpointUUIDHintRejectsUnusableShapes() {
        func hint(_ endpoint: String?) -> MACAddress? {
            WSDProbeMatch(endpointAddress: endpoint, types: [], scopes: ONVIFScopes(), xAddrs: [],
                          metadataVersion: nil, relatesTo: nil, messageID: nil,
                          appSequenceInstanceID: nil, observedFrom: IPv4Address(10, 0, 0, 1),
                          receivedAt: WSDFixtures.receivedAt,
                          isCorrelated: false).endpointUUIDMACHint
        }
        #expect(hint(nil) == nil)
        #expect(hint("urn:uuid:2419d68a-2dd2-21b2-a205-c42f90abcdef")?.description
                    == "c4:2f:90:ab:cd:ef")
        #expect(hint("uuid:2419d68a-2dd2-21b2-a205-c42f90abcdef") != nil)
        #expect(hint("urn:uuid:2419d68a-2dd2-21b2-a205-c42f90abcde") == nil)   // 11 nibbles
        #expect(hint("urn:uuid:not-a-uuid-at-all") == nil)
        #expect(hint("urn:uuid:2419d68a-2dd2-21b2-a205-000000000000") == nil)  // all-zero
        #expect(hint("urn:uuid:2419d68a-2dd2-21b2-a205-ffffffffffff") == nil)  // broadcast
        #expect(hint("urn:uuid:2419d68a-2dd2-21b2-a205-01005e000001") == nil)  // multicast bit
        #expect(hint("some-other-identifier") == nil)
    }

    // MARK: - Observation projection

    @Test func wsdObservationCarriesScopesURLsAndVendor() throws {
        let match = try #require(decode(WSDFixtures.hikvisionProbeMatchXML).wsdMatches?.first)
        let observation = WSDiscoveryCodec.observation(from: match)
        #expect(observation.source == .wsDiscovery)
        #expect(observation.observedAt == WSDFixtures.receivedAt)
        #expect(observation.address == Self.source)
        #expect(observation.onvifUUID == WSDFixtures.hikvisionEndpoint)
        #expect(observation.serialNumber == nil)          // ONVIF never gives us one
        #expect(observation.fields[.vendor] == .vendor(.hikvision))
        #expect(observation.fields[.deviceClass] == .deviceClass(.camera))
        #expect(observation.fields[.displayName] == .string("HIKVISION DS-2CD2143G0-I"))
        #expect(observation.fields[.model] == .string("DS-2CD2143G0-I"))
        #expect(observation.fields[.onvifServiceURLs] == .strings(match.xAddrs))
        #expect(observation.fields[.onvifScopes] == .scopes(match.scopes))
        #expect(observation.fields[.activation] == nil)   // ONVIF cannot see activation at all
    }

    /// Test 5.5's dedupe rule: a device answering all three probes is one row, not three.
    @Test func wsdDedupeCollapsesRepeatAnswers() throws {
        var set = WSDDedupeSet()
        let first = try #require(decode(WSDFixtures.hikvisionProbeMatchXML).wsdMatches?.first)
        let again = try #require(decode(WSDFixtures.hikvisionProbeMatchXML).wsdMatches?.first)
        #expect(set.insert(first))
        #expect(!set.insert(again))
        #expect(set.contains(again))
        #expect(set.count == 1)

        let dahua = try #require(decode(WSDFixtures.dahuaProbeMatchXML).wsdMatches?.first)
        #expect(set.insert(dahua))
        #expect(set.count == 2)
    }

    /// Without an endpoint reference the key falls back to the first XAddr, then to the source, so a
    /// device that omits its identifier still collapses to one row.
    @Test func wsdDedupeKeyFallsBackWhenEndpointIsAbsent() {
        func match(endpoint: String?, xAddrs: [String]) -> WSDProbeMatch {
            WSDProbeMatch(endpointAddress: endpoint, types: [], scopes: ONVIFScopes(),
                          xAddrs: xAddrs, metadataVersion: nil, relatesTo: nil, messageID: nil,
                          appSequenceInstanceID: nil, observedFrom: IPv4Address(10, 0, 20, 7),
                          receivedAt: WSDFixtures.receivedAt, isCorrelated: false)
        }
        #expect(match(endpoint: "URN:UUID:ABC", xAddrs: []).dedupeKey == "urn:uuid:abc")
        #expect(match(endpoint: nil, xAddrs: ["http://10.0.20.7/onvif"]).dedupeKey
                    == "xaddr:http://10.0.20.7/onvif")
        #expect(match(endpoint: nil, xAddrs: []).dedupeKey == "source:10.0.20.7")
    }
}
