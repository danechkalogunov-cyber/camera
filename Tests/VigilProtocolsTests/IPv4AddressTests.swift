//
//  IPv4AddressTests.swift
//  VigilProtocolsTests
//
//  Parsing, rendering and classification of VigilProtocols.IPv4Address.
//  Covers docs/spec-discovery.md §1.3. Range boundaries are taken from the RFCs cited per test;
//  no value here is claimed to come from real hardware.
//

import Foundation
import Testing
import VigilProtocols

@Suite struct IPv4AddressTests {

    // MARK: - Round-trip and boundaries

    @Test func parsesAndRendersTheAllZeroAddress() throws {
        let address = try #require(IPv4Address("0.0.0.0"))
        #expect(address.rawValue == 0)
        #expect(address.description == "0.0.0.0")
        #expect(IPv4Address(address.description) == address)
    }

    @Test func parsesAndRendersTheAllOnesAddress() throws {
        let address = try #require(IPv4Address("255.255.255.255"))
        #expect(address.rawValue == 0xFFFF_FFFF)
        #expect(address.description == "255.255.255.255")
        #expect(IPv4Address(address.description) == address)
    }

    @Test func octetInitializerMatchesHostOrderRawValue() {
        // §1.3 states the expected packing explicitly: 192.168.1.64 == 0xC0A80140.
        #expect(IPv4Address(192, 168, 1, 64).rawValue == 0xC0A8_0140)
        #expect(IPv4Address(rawValue: 0xC0A8_0140).description == "192.168.1.64")
    }

    @Test func octetsDecomposeMostSignificantFirst() {
        let octets = IPv4Address(rawValue: 0xC0A8_0140).octets
        #expect(octets.0 == 192)
        #expect(octets.1 == 168)
        #expect(octets.2 == 1)
        #expect(octets.3 == 64)
    }

    @Test func everyOctetBoundaryRoundTrips() {
        for text in ["0.0.0.1", "1.0.0.0", "0.255.0.255", "255.0.255.0", "9.8.7.0", "10.0.0.255"] {
            #expect(IPv4Address(text)?.description == text, "\(text) should round-trip")
        }
    }

    @Test func comparableOrdersByNumericAddress() {
        #expect(IPv4Address(10, 0, 0, 2) < IPv4Address(10, 0, 0, 10))
        #expect(IPv4Address(10, 0, 0, 255) < IPv4Address(10, 0, 1, 0))
        #expect(IPv4Address(rawValue: 0) < IPv4Address(rawValue: 0xFFFF_FFFF))
        #expect(!(IPv4Address(1, 2, 3, 4) < IPv4Address(1, 2, 3, 4)))
    }

    // MARK: - Rejection of malformed text

    @Test(arguments: [
        "256.1.1.1",        // octet above 255
        "1.2.3",            // too few components
        "1.2.3.4.5",        // too many components
        "01.2.3.4",         // leading zero: would read as octal elsewhere
        "1.2.3.-1",         // sign is not a digit
        "",                 // empty
        " 1.2.3.4",         // leading whitespace
        "1.2.3.4 ",         // trailing whitespace
    ]) func rejectsMalformedDottedQuad(_ text: String) {
        #expect(IPv4Address(text) == nil, "'\(text)' must not parse")
    }

    @Test(arguments: [
        "1.2.3.00", "1.2.03.4", "0000.0.0.0",       // leading zeros in any position
        "1.2.3.4.", ".1.2.3.4", "1..2.3", "1.2..3",  // empty components
        "1.2.3.1234", "999.1.1.1",                   // too many digits
        "1.2.3.4/24", "1.2.3.4:80", "1,2,3,4",       // trailing syntax from other formats
        "0x1.2.3.4", "c0a8.0140", "hello",           // non-decimal
        "1.2.3.4\n", "1.2 .3.4", "1.2.3. 4",         // embedded whitespace
        "+1.2.3.4", "-1.2.3.4", "١.٢.٣.٤",           // signs and non-ASCII digits
    ]) func rejectsFurtherMalformedDottedQuad(_ text: String) {
        #expect(IPv4Address(text) == nil, "'\(text)' must not parse")
    }

    @Test func acceptsZeroComponentsButNotPaddedZeros() {
        #expect(IPv4Address("0.0.0.0") != nil)
        #expect(IPv4Address("10.0.0.0") != nil)
        #expect(IPv4Address("00.0.0.0") == nil)
    }

    // MARK: - RFC 1918 private blocks, exact first and last address of each

    @Test func recognisesTheTenSlashEightBlock() {
        #expect(IPv4Address(10, 0, 0, 0).isPrivate)
        #expect(IPv4Address(10, 255, 255, 255).isPrivate)
        #expect(!IPv4Address(9, 255, 255, 255).isPrivate)
        #expect(!IPv4Address(11, 0, 0, 0).isPrivate)
    }

    @Test func recognisesTheOneSevenTwoSixteenSlashTwelveBlock() {
        #expect(IPv4Address(172, 16, 0, 0).isPrivate)
        #expect(IPv4Address(172, 31, 255, 255).isPrivate)
        #expect(!IPv4Address(172, 15, 255, 255).isPrivate)
        #expect(!IPv4Address(172, 32, 0, 0).isPrivate)
    }

    @Test func recognisesTheOneNineTwoOneSixEightSlashSixteenBlock() {
        #expect(IPv4Address(192, 168, 0, 0).isPrivate)
        #expect(IPv4Address(192, 168, 255, 255).isPrivate)
        #expect(!IPv4Address(192, 167, 255, 255).isPrivate)
        #expect(!IPv4Address(192, 169, 0, 0).isPrivate)
        #expect(IPv4Address.hikvisionFactoryDefault.isPrivate)
    }

    @Test func publicAddressesAreNotPrivate() {
        #expect(!IPv4Address(8, 8, 8, 8).isPrivate)
        #expect(!IPv4Address(0, 0, 0, 0).isPrivate)
        #expect(!IPv4Address(255, 255, 255, 255).isPrivate)
    }

    // MARK: - Other classifications

    @Test func recognisesLoopback() {
        #expect(IPv4Address(127, 0, 0, 0).isLoopback)
        #expect(IPv4Address(127, 0, 0, 1).isLoopback)
        #expect(IPv4Address(127, 255, 255, 255).isLoopback)
        #expect(!IPv4Address(126, 255, 255, 255).isLoopback)
        #expect(!IPv4Address(128, 0, 0, 0).isLoopback)
        #expect(IPv4Address.loopback.description == "127.0.0.1")
    }

    @Test func recognisesLinkLocal() {
        // RFC 3927: 169.254.0.0 – 169.254.255.255.
        #expect(IPv4Address(169, 254, 0, 0).isLinkLocal)
        #expect(IPv4Address(169, 254, 255, 255).isLinkLocal)
        #expect(!IPv4Address(169, 253, 255, 255).isLinkLocal)
        #expect(!IPv4Address(169, 255, 0, 0).isLinkLocal)
    }

    @Test func recognisesMulticast() {
        // RFC 5771: 224.0.0.0 – 239.255.255.255.
        #expect(IPv4Address(224, 0, 0, 0).isMulticast)
        #expect(IPv4Address(239, 255, 255, 255).isMulticast)
        #expect(IPv4Address.discoveryMulticastGroup.isMulticast)
        #expect(IPv4Address.discoveryMulticastGroup.description == "239.255.255.250")
        #expect(!IPv4Address(223, 255, 255, 255).isMulticast)
        #expect(!IPv4Address(240, 0, 0, 0).isMulticast)
    }

    @Test func recognisesLimitedBroadcast() {
        #expect(IPv4Address(255, 255, 255, 255).isBroadcast)
        #expect(IPv4Address.broadcast.isBroadcast)
        #expect(!IPv4Address(255, 255, 255, 254).isBroadcast)
        #expect(!IPv4Address(192, 168, 1, 255).isBroadcast)
    }

    @Test func recognisesUnspecified() {
        #expect(IPv4Address(0, 0, 0, 0).isUnspecified)
        #expect(IPv4Address.unspecified.isUnspecified)
        #expect(!IPv4Address(0, 0, 0, 1).isUnspecified)
    }

    @Test func classificationsAreMutuallyConsistentForARoutableCamera() {
        let camera = IPv4Address.hikvisionFactoryDefault
        #expect(camera.isPrivate)
        #expect(!camera.isLoopback)
        #expect(!camera.isLinkLocal)
        #expect(!camera.isMulticast)
        #expect(!camera.isBroadcast)
        #expect(!camera.isUnspecified)
    }

    // MARK: - Named constants

    @Test func hikvisionFactoryDefaultIsTheDocumentedAddress() {
        // §4.7 / §6.2: the factory address a camera answers on out of the box.
        #expect(IPv4Address.hikvisionFactoryDefault.description == "192.168.1.64")
        #expect(IPv4Address.hikvisionFactoryDefault.rawValue == 0xC0A8_0140)
    }

    // MARK: - Codable

    @Test func codableUsesTheDottedQuadStringForm() throws {
        // Wrapped in an array so the test does not depend on top-level-fragment support.
        let address = IPv4Address(10, 0, 20, 5)
        let json = try JSONEncoder().encode([address])
        #expect(String(decoding: json, as: UTF8.self) == "[\"10.0.20.5\"]")
        #expect(try JSONDecoder().decode([IPv4Address].self, from: json) == [address])
    }

    @Test func decodingRejectsMalformedText() {
        let json = Data("[\"1.2.3\"]".utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([IPv4Address].self, from: json)
        }
    }
}
