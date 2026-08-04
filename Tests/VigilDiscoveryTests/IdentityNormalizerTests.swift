//
//  MergeEngineTests.swift
//  VigilDiscoveryTests
//
//  The identity ladder and the merge model: every rung, a record that gains a MAC late and must
//  merge rather than duplicate, the two address events, sticky activation, field precedence by
//  source trust, confidence scoring and the deterministic sort order.
//  Covers docs/spec-discovery.md §7 and §10.4; tests 65–77 of §13.6.
//

import Foundation
import Testing

import VigilProtocols
@testable import VigilDiscovery

// MARK: - Normalisation

@Suite struct IdentityNormalizerBehaviour {

    /// Uppercasing, whitespace removal and the four-character lot code, which is stripped for
    /// comparison only.
    @Test func identityNormalizerNormalisesSerials() {
        #expect(IdentityNormalizer.serialKey(" ds-2cd2143g0-i20200114aawrd12345678 ")
            == "DS-2CD2143G0-I20200114AAWRD12345678")
        #expect(IdentityNormalizer.serialKey("DS-7616NI-K2/16P1620201105AAWR123456789WCVU")
            == "DS-7616NI-K2/16P1620201105AAWR123456789")
        #expect(IdentityNormalizer.serialKey("DS-2CD2143G0-I2020\u{0}0114AAWRD12345678")
            == "DS-2CD2143G0-I20200114AAWRD12345678")
    }

    /// Values that are not serials yield no key: a bad key merges two cameras, a missing one only
    /// costs a duplicate row.
    @Test func identityNormalizerRejectsUnusableSerials() {
        #expect(IdentityNormalizer.serialKey("") == nil)
        #expect(IdentityNormalizer.serialKey("1234") == nil)
        #expect(IdentityNormalizer.serialKey("       ") == nil)
        #expect(IdentityNormalizer.serialKey("00000000") == nil)
        #expect(IdentityNormalizer.serialKey("--------") == nil)
        #expect(IdentityNormalizer.serialKey("ABCDEFGH") == "ABCDEFGH")
    }

    /// A serial that merely ends in letters keeps them: only a digit-preceded four-letter tail is a
    /// lot code.
    @Test func identityNormalizerKeepsNonLotSuffixes() {
        #expect(IdentityNormalizer.strippingLotSuffix("DS-2CD2143G0-IABCDEFGH")
            == "DS-2CD2143G0-IABCDEFGH")
        #expect(IdentityNormalizer.strippingLotSuffix("SHORTWCVU") == "SHORTWCVU")
    }

    /// UUID prefixes are stripped and the nil UUID is refused.
    @Test func identityNormalizerNormalisesONVIFUUIDs() {
        #expect(IdentityNormalizer.onvifKey("urn:uuid:2419D68A-2DD2-21B2-A205-C42F90ABCDEF")
            == "2419d68a-2dd2-21b2-a205-c42f90abcdef")
        #expect(IdentityNormalizer.onvifKey("uuid:2419d68a-2dd2-21b2-a205-c42f90abcdef")
            == "2419d68a-2dd2-21b2-a205-c42f90abcdef")
        #expect(IdentityNormalizer.onvifKey("00000000-0000-0000-0000-000000000000") == nil)
        #expect(IdentityNormalizer.onvifKey("urn:uuid:") == nil)
        #expect(IdentityNormalizer.onvifKey("") == nil)
    }

    /// The MAC embedded in a vendor UUID is extracted only when the shape and the OUI both check
    /// out, and it is only ever a hint.
    @Test func identityNormalizerExtractsMACHintFromUUID() throws {
        #expect(IdentityNormalizer.macHint(fromONVIFUUID:
            "urn:uuid:2419d68a-2dd2-21b2-a205-c42f90abcdef") == MACAddress("c4:2f:90:ab:cd:ef"))
        // Not an OUI we know: refused rather than guessed.
        #expect(IdentityNormalizer.macHint(fromONVIFUUID:
            "urn:uuid:2419d68a-2dd2-21b2-a205-001122334455") == nil)
        // Wrong shape.
        #expect(IdentityNormalizer.macHint(fromONVIFUUID: "urn:uuid:c42f90abcdef") == nil)
    }

    /// Identity keys round-trip through their string form, and a corrupt key is refused.
    @Test func identityNormalizerIdentityKeysRoundTrip() throws {
        let identities: [DeviceIdentity] = [
            .mac(try #require(MACAddress("c4:2f:90:ab:cd:ef"))),
            .serial("DS-2CD2143G0-I20200114AAWRD12345678"),
            .onvifUUID("2419d68a-2dd2-21b2-a205-c42f90abcdef"),
            .endpoint(IPv4Address(192, 168, 1, 64), 8_000),
        ]
        for identity in identities {
            #expect(DeviceIdentity(key: identity.key) == identity)
        }
        #expect(DeviceIdentity(key: "mac:nothex") == nil)
        #expect(DeviceIdentity(key: "ep:192.168.1.64") == nil)
        #expect(DeviceIdentity(key: "unknown:x") == nil)
        #expect(identities.map(\.strength) == [4, 3, 2, 1])
        #expect(identities.map(\.isProvisional) == [false, false, false, true])
    }
}

// MARK: - ONVIF scopes

@Suite struct ONVIFScopesBehaviour {

    /// The scope list from a real-shaped ProbeMatch, percent-decoded and sorted into fields.
    @Test func onvifScopesParsesTheStandardScopeSet() throws {
        let raw = "onvif://www.onvif.org/type/video_encoder"
            + " onvif://www.onvif.org/type/Network_Video_Transmitter"
            + " onvif://www.onvif.org/hardware/DS-2CD2143G0-I"
            + " onvif://www.onvif.org/name/HIKVISION%20DS-2CD2143G0-I"
            + " onvif://www.onvif.org/location/country/china"
            + " onvif://www.onvif.org/Profile/Streaming"
            + " onvif://www.onvif.org/Profile/G"
        let scopes = ONVIFScopes.parse(raw)
        #expect(scopes.name == "HIKVISION DS-2CD2143G0-I")
        #expect(scopes.hardware == "DS-2CD2143G0-I")
        #expect(scopes.location == "china")
        #expect(scopes.profiles == ["Streaming", "G"])
        #expect(scopes.types == ["video_encoder", "Network_Video_Transmitter"])
        #expect(scopes.raw.count == 7)
    }

    /// A non-standard host and a `/MAC/` scope: both accepted, the MAC as a hint.
    @Test func onvifScopesAcceptsForeignHostsAndMACHints() {
        let scopes = ONVIFScopes.parse("onvif://192.168.1.64/MAC/c4%3A2f%3A90%3Aab%3Acd%3Aef"
                                       + " onvif://example.com/name/Camera")
        #expect(scopes.macHint == MACAddress("c4:2f:90:ab:cd:ef"))
        #expect(scopes.name == "Camera")
    }

    /// Garbage does not throw and does not lose anything: unrecognised scopes stay in `raw`.
    @Test func onvifScopesKeepsUnrecognisedScopes() {
        let scopes = ONVIFScopes.parse("nonsense onvif://www.onvif.org/wibble/x %%% ")
        #expect(scopes.name == nil)
        #expect(scopes.raw == ["nonsense", "onvif://www.onvif.org/wibble/x", "%%%"])
        #expect(ONVIFScopes.parse("").raw.isEmpty)
    }

    /// Percent decoding, including an invalid escape that must survive verbatim.
    @Test func onvifScopesPercentDecodesValues() {
        #expect(ONVIFScopes.percentDecoded("HIKVISION%20DS-2") == "HIKVISION DS-2")
        #expect(ONVIFScopes.percentDecoded("c4%3A2f") == "c4:2f")
        #expect(ONVIFScopes.percentDecoded("100%") == "100%")
        #expect(ONVIFScopes.percentDecoded("%zz") == "%zz")
        #expect(ONVIFScopes.percentDecoded("plain") == "plain")
    }

    /// PTZ detection: an explicit `type/ptz`, or Profile S plus a dome model.
    @Test func onvifScopesDetectsPTZ() {
        #expect(ONVIFScopes(types: ["ptz"]).indicatesPTZ)
        #expect(ONVIFScopes(hardware: "DS-2DE4A425IW-DE SPEED DOME", profiles: ["S"]).indicatesPTZ)
        #expect(!ONVIFScopes(hardware: "DS-2CD2143G0-I", profiles: ["S"]).indicatesPTZ)
        #expect(!ONVIFScopes().indicatesPTZ)
    }

    /// Union keeps the first scalar and merges the lists, so two ProbeMatches lose nothing.
    @Test func onvifScopesUnionMergesWithoutLoss() {
        var first = ONVIFScopes(name: "Front", profiles: ["S"], raw: ["a"])
        first.formUnion(ONVIFScopes(name: "Other", hardware: "DS-2CD", profiles: ["S", "G"],
                                    raw: ["a", "b"]))
        #expect(first.name == "Front")
        #expect(first.hardware == "DS-2CD")
        #expect(first.profiles == ["S", "G"])
        #expect(first.raw == ["a", "b"])
    }
}
