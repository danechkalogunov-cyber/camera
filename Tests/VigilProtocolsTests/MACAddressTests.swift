//
//  MACAddressTests.swift
//  VigilProtocolsTests
//
//  Parsing every textual MAC form camera firmware emits, canonical rendering, and the flag bits.
//  Covers docs/spec-discovery.md §1.3 and the OUI hint of §6.9.
//  The OUI c4:2f:90 is the one §6.9 lists for Hikvision; the remaining addresses are synthesised.
//

import Foundation
import Testing
import VigilProtocols

@Suite struct MACAddressTests {

    /// The example address used throughout §1.3, packed as that section documents.
    static let packed: UInt64 = 0x0000_C42F_90AB_CDEF

    // MARK: - The four textual forms

    @Test(arguments: [
        "c4:2f:90:ab:cd:ef",        // ISAPI / ONVIF scopes
        "c4-2f-90-ab-cd-ef",        // SADP <MAC>
        "c42f.90ab.cdef",           // switch tables
        "c42f90abcdef",             // Axis realms, Bonjour names
    ]) func allSeparatorFormsParseToTheSameValue(_ text: String) throws {
        let mac = try #require(MACAddress(text), "'\(text)' should parse")
        #expect(mac.rawValue == Self.packed)
    }

    @Test func parsingIsCaseInsensitiveAndCanonicalisesToLowercase() throws {
        let upper = try #require(MACAddress("C4-2F-90-AB-CD-EF"))
        let mixed = try #require(MACAddress("c4:2F:90:aB:Cd:eF"))
        let bareUpper = try #require(MACAddress("C42F90ABCDEF"))
        #expect(upper == mixed)
        #expect(mixed == bareUpper)
        #expect(upper.description == "c4:2f:90:ab:cd:ef")
        #expect(mixed.description == "c4:2f:90:ab:cd:ef")
        #expect(bareUpper.description == "c4:2f:90:ab:cd:ef")
    }

    @Test func canonicalFormKeepsLeadingZeroNibbles() throws {
        let mac = try #require(MACAddress(rawValue: 0x0000_0000_0000_0001))
        #expect(mac.description == "00:00:00:00:00:01")
        #expect(MACAddress("00:00:00:00:00:01") == mac)
    }

    @Test func descriptionRoundTripsForEveryForm() throws {
        for text in ["c4:2f:90:ab:cd:ef", "C4-2F-90-AB-CD-EF", "c42f.90ab.cdef", "c42f90abcdef"] {
            let mac = try #require(MACAddress(text))
            #expect(MACAddress(mac.description) == mac)
        }
    }

    // MARK: - Byte and raw-value construction

    @Test func octetInitializerAgreesWithParsing() {
        #expect(MACAddress(0xC4, 0x2F, 0x90, 0xAB, 0xCD, 0xEF).rawValue == Self.packed)
        #expect(MACAddress(0xC4, 0x2F, 0x90, 0xAB, 0xCD, 0xEF) == MACAddress("c4:2f:90:ab:cd:ef"))
    }

    @Test func bytesRoundTrip() throws {
        let mac = try #require(MACAddress(bytes: [0xC4, 0x2F, 0x90, 0xAB, 0xCD, 0xEF]))
        #expect(mac.rawValue == Self.packed)
        #expect(mac.bytes == [0xC4, 0x2F, 0x90, 0xAB, 0xCD, 0xEF])
        #expect(MACAddress(bytes: mac.bytes) == mac)
    }

    @Test func byteInitializerRejectsTheWrongLength() {
        #expect(MACAddress(bytes: [UInt8]()) == nil)
        #expect(MACAddress(bytes: [1, 2, 3, 4, 5]) == nil)
        #expect(MACAddress(bytes: [1, 2, 3, 4, 5, 6, 7]) == nil)
        // A five-byte window of a longer buffer must not be read as a MAC either.
        #expect(MACAddress(bytes: Data([1, 2, 3, 4, 5, 6, 7]).prefix(5)) == nil)
        #expect(MACAddress(bytes: Data([1, 2, 3, 4, 5, 6, 7]).prefix(6))?.description
                    == "01:02:03:04:05:06")
    }

    @Test func rawValueInitializerRejectsBitsAboveFortySeven() {
        #expect(MACAddress(rawValue: 0xFFFF_FFFF_FFFF) != nil)
        #expect(MACAddress(rawValue: 0x0001_0000_0000_0000) == nil)
        #expect(MACAddress(rawValue: UInt64.max) == nil)
    }

    // MARK: - Rejection of malformed text

    @Test(arguments: [
        "c42f90abcde",              // 11 digits
        "c42f90abcdef0",            // 13 digits
        "c4:2f:90:ab:cd:eg",        // non-hex digit
        "c4:2f:90:ab:cd",           // 10 digits, right shape
        "",                         // empty
        "c4:2f:90:ab:cd:ef:01",     // seven groups
        "c4:2f-90:ab:cd:ef",        // mixed separators
        ":c4:2f:90:ab:cd:ef",       // leading separator
        "c4:2f:90:ab:cd:ef:",       // trailing separator
        "c4::2f:90:ab:cd:ef",       // doubled separator
        "c4:2f:90:ab:cdef",         // uneven groups
        " c42f90abcdef",            // leading whitespace
        "c42f90abcdef ",            // trailing whitespace
        "c4 2f 90 ab cd ef",        // space separators are not accepted
        "0xc42f90abcdef",           // hex literal prefix
    ]) func rejectsMalformedText(_ text: String) {
        #expect(MACAddress(text) == nil, "'\(text)' must not parse")
    }

    // MARK: - Flags

    @Test func recognisesBroadcast() throws {
        let broadcast = try #require(MACAddress("ff:ff:ff:ff:ff:ff"))
        #expect(broadcast.isBroadcast)
        #expect(broadcast.isMulticast)             // the group bit is set in ff:...
        #expect(broadcast.isLocallyAdministered)   // as is the local bit
        #expect(!broadcast.isUsableIdentity)
    }

    @Test func recognisesMulticast() throws {
        // 01:00:5e:... is the IPv4 multicast mapping range; the group bit is bit 0 of octet 0.
        let multicast = try #require(MACAddress("01:00:5e:7f:ff:fa"))
        #expect(multicast.isMulticast)
        #expect(!multicast.isBroadcast)
        #expect(!multicast.isLocallyAdministered)
        #expect(!multicast.isUsableIdentity)

        let unicast = try #require(MACAddress("c4:2f:90:ab:cd:ef"))
        #expect(!unicast.isMulticast)
    }

    @Test func recognisesLocallyAdministeredBit() throws {
        let local = try #require(MACAddress("02:00:00:00:00:01"))
        let alsoLocal = try #require(MACAddress("06:1a:2b:3c:4d:5e"))
        let global = try #require(MACAddress("c4:2f:90:ab:cd:ef"))
        let alsoGlobal = try #require(MACAddress("00:40:8c:11:22:33"))
        #expect(local.isLocallyAdministered)
        #expect(alsoLocal.isLocallyAdministered)
        #expect(!global.isLocallyAdministered)
        #expect(!alsoGlobal.isLocallyAdministered)
        // A locally administered address is still a usable identity: it is stable per interface.
        #expect(local.isUsableIdentity)
    }

    @Test func allZeroAddressIsNeverAnIdentity() throws {
        let zero = try #require(MACAddress(rawValue: 0))
        #expect(!zero.isUsableIdentity)
        #expect(zero.description == "00:00:00:00:00:00")
    }

    // MARK: - OUI

    @Test func exposesTheOUIAsAValueAndAsASeedTableKey() throws {
        let mac = try #require(MACAddress("c4:2f:90:ab:cd:ef"))
        #expect(mac.oui == 0xC4_2F90)
        #expect(mac.ouiHex == "c42f90")

        // §6.9 lists these keys for Hikvision and Axis; the key shape is what matters here.
        let hikvision = try #require(MACAddress("44-19-B6-01-02-03"))
        let axis = try #require(MACAddress("accc8e123456"))
        let zeroOUI = try #require(MACAddress("00:00:00:ff:ff:ff"))
        #expect(hikvision.ouiHex == "4419b6")
        #expect(axis.ouiHex == "accc8e")
        #expect(zeroOUI.ouiHex == "000000")
        #expect(zeroOUI.oui == 0)
    }

    // MARK: - Codable

    @Test func codableUsesTheCanonicalStringForm() throws {
        let mac = try #require(MACAddress("C4-2F-90-AB-CD-EF"))
        let json = try JSONEncoder().encode([mac])
        #expect(String(decoding: json, as: UTF8.self) == "[\"c4:2f:90:ab:cd:ef\"]")
        #expect(try JSONDecoder().decode([MACAddress].self, from: json) == [mac])
    }

    @Test func decodingAcceptsAnyFormButRejectsGarbage() throws {
        let expected = try #require(MACAddress("c4:2f:90:ab:cd:ef"))
        let hyphenated = Data("[\"C4-2F-90-AB-CD-EF\"]".utf8)
        #expect(try JSONDecoder().decode([MACAddress].self, from: hyphenated) == [expected])
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([MACAddress].self, from: Data("[\"nope\"]".utf8))
        }
    }
}
