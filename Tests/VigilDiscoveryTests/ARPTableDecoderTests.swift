//
//  ARPTableDecoderTests.swift
//  VigilDiscoveryTests
//
//  The ARP decoders: the `sysctl(PF_ROUTE)` binary walk and the `arp -an` text form, including every
//  truncation of the binary blob — a hostile or short buffer must lose entries, never crash.
//  Covers docs/spec-discovery.md §6.3 and §14.5; tests 47–49 of §13.4.
//
//  The binary blob here is SYNTHESISED from the §14.5 layout reference, not captured from a Mac:
//  this container is Linux and has no `sysctl(PF_ROUTE)`. Field offsets and the 92-byte `rt_msghdr`
//  size follow that appendix exactly, so the test verifies the decoder against the documented
//  layout rather than against real hardware.
//

import Foundation
import Testing

import VigilProtocols
@testable import VigilDiscovery

@Suite struct ARPTableDecoderBehaviour {

    // MARK: - Blob construction

    /// Size of `struct rt_msghdr` on Apple platforms (§14.5).
    static let routeHeaderLength = 92

    /// Builds one `rt_msghdr` + `sockaddr_in` + `sockaddr_dl` record.
    ///
    /// `mac` of `nil` produces `sdl_alen == 0`: the kernel probed the address but never resolved it.
    static func record(_ address: IPv4Address, mac: MACAddress?, interfaceName: String = "en0",
                       index: UInt16 = 4) -> [UInt8] {
        let name = Array(interfaceName.utf8)
        let macBytes = mac?.bytes ?? []
        let dataLength = name.count + macBytes.count
        let sdlLength = 8 + dataLength
        let paddedDL = ARPTableDecoder.roundup(sdlLength)
        let total = routeHeaderLength + 16 + paddedDL

        var bytes = [UInt8](repeating: 0, count: routeHeaderLength)
        bytes[0] = UInt8(total & 0xFF)
        bytes[1] = UInt8((total >> 8) & 0xFF)
        bytes[2] = 5                                    // rtm_version
        bytes[3] = 4                                    // rtm_type (RTM_GET)

        // sockaddr_in: len, family, port, address, zero padding.
        let octets = address.octets
        bytes += [16, 2, 0, 0, octets.0, octets.1, octets.2, octets.3]
        bytes += [UInt8](repeating: 0, count: 8)

        // sockaddr_dl: len, family, index (LE), type, nlen, alen, slen, then name + MAC.
        var dl: [UInt8] = [UInt8(sdlLength), 18, UInt8(index & 0xFF), UInt8(index >> 8), 6,
                           UInt8(name.count), UInt8(macBytes.count), 0]
        dl += name
        dl += macBytes
        dl += [UInt8](repeating: 0, count: paddedDL - sdlLength)
        return bytes + dl
    }

    static func decode(_ bytes: [UInt8]) -> [ARPEntry] {
        bytes.withUnsafeBytes { ARPTableDecoder.decodeRouteDump($0, byteCount: bytes.count) }
    }

    static func mac(_ text: String) throws -> MACAddress {
        try #require(MACAddress(text))
    }

    // MARK: - Route dump

    /// Test 47's shape: several complete entries plus one the kernel never resolved.
    @Test func arpTableDecoderDecodesRouteDump() throws {
        let hikvision = try Self.mac("c4:2f:90:ab:cd:ef")
        let dahua = try Self.mac("3c:ef:8c:11:22:33")
        var blob = Self.record(IPv4Address(192, 168, 1, 1), mac: hikvision, index: 4)
        blob += Self.record(IPv4Address(192, 168, 1, 64), mac: dahua, interfaceName: "en1", index: 5)
        blob += Self.record(IPv4Address(192, 168, 1, 99), mac: nil)

        let entries = Self.decode(blob)
        #expect(entries.count == 3)
        #expect(entries[0].address == IPv4Address(192, 168, 1, 1))
        #expect(entries[0].mac == hikvision)
        #expect(entries[0].interfaceIndex == 4)
        #expect(entries[0].isIncomplete == false)
        #expect(entries[1].mac == dahua)
        #expect(entries[1].interfaceIndex == 5)
        #expect(entries[2].address == IPv4Address(192, 168, 1, 99))
        #expect(entries[2].isIncomplete)
        #expect(entries[2].isUsableIdentity == false)
    }

    /// Test 48: every prefix of the blob decodes safely and yields a prefix of the entries. This is
    /// the fuzz case that matters — a `sysctl` race gives us a short buffer for real.
    @Test func arpTableDecoderTruncatedBlobIsSafe() throws {
        let first = try Self.mac("c4:2f:90:00:00:01")
        let second = try Self.mac("c4:2f:90:00:00:02")
        var blob = Self.record(IPv4Address(10, 0, 0, 2), mac: first)
        blob += Self.record(IPv4Address(10, 0, 0, 3), mac: second)
        let full = Self.decode(blob)
        #expect(full.count == 2)

        for length in 0...blob.count {
            let entries = Self.decode(Array(blob.prefix(length)))
            #expect(entries.count <= full.count)
            #expect(entries == Array(full.prefix(entries.count)))
        }
    }

    /// A record whose `sdl_len` claims more name and address bytes than it has is skipped, not read.
    @Test func arpTableDecoderRejectsOverlongLinkLayerLengths() throws {
        var blob = Self.record(IPv4Address(10, 0, 0, 4), mac: try Self.mac("c4:2f:90:00:00:03"))
        // sdl_alen sits at offset 6 of the sockaddr_dl, which follows the header and sockaddr_in.
        let dlBase = Self.routeHeaderLength + 16
        blob[dlBase + 6] = 200
        #expect(Self.decode(blob).isEmpty)
    }

    /// A record whose declared length is shorter than a header ends the walk instead of looping.
    @Test func arpTableDecoderStopsOnUnderlongRecord() throws {
        var blob = Self.record(IPv4Address(10, 0, 0, 5), mac: try Self.mac("c4:2f:90:00:00:04"))
        blob[0] = 4
        blob[1] = 0
        #expect(Self.decode(blob).isEmpty)
    }

    /// A second sockaddr that is not `AF_LINK` yields no entry for that record, and the walk carries
    /// on to the next one.
    @Test func arpTableDecoderSkipsNonLinkSockaddr() throws {
        var first = Self.record(IPv4Address(10, 0, 0, 6), mac: try Self.mac("c4:2f:90:00:00:05"))
        first[Self.routeHeaderLength + 16 + 1] = 2       // pretend it is another sockaddr_in
        let blob = first + Self.record(IPv4Address(10, 0, 0, 7),
                                       mac: try Self.mac("c4:2f:90:00:00:06"))
        let entries = Self.decode(blob)
        #expect(entries.count == 1)
        #expect(entries[0].address == IPv4Address(10, 0, 0, 7))
    }

    /// Random bytes are not a route dump. The requirement is only that nothing traps.
    @Test func arpTableDecoderSurvivesGarbage() {
        var seed: UInt64 = 0x5EED_1234_5EED_1234
        var bytes: [UInt8] = []
        for _ in 0..<4_096 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes.append(UInt8(truncatingIfNeeded: seed >> 33))
        }
        _ = Self.decode(bytes)
        _ = Self.decode([])
        _ = Self.decode([0, 0, 0])
    }

    /// `byteCount` larger than the buffer must not read past it.
    @Test func arpTableDecoderClampsByteCountToBuffer() {
        let bytes: [UInt8] = [0xFF, 0xFF, 5, 4]
        let entries = bytes.withUnsafeBytes {
            ARPTableDecoder.decodeRouteDump($0, byteCount: 1 << 20)
        }
        #expect(entries.isEmpty)
    }

    /// `roundup` follows the BSD `SA_SIZE` rule, including zero mapping to 4 — without which a
    /// zero-length sockaddr would advance the cursor by nothing and hang the walk.
    @Test func arpTableDecoderRoundupMatchesBSDRule() {
        #expect(ARPTableDecoder.roundup(0) == 4)
        #expect(ARPTableDecoder.roundup(1) == 4)
        #expect(ARPTableDecoder.roundup(4) == 4)
        #expect(ARPTableDecoder.roundup(5) == 8)
        #expect(ARPTableDecoder.roundup(16) == 16)
        #expect(ARPTableDecoder.roundup(17) == 20)
    }

    // MARK: - Text form

    /// Test 49: the `arp -an` form, including a single-digit octet and an unresolved row.
    @Test func arpTableDecoderParsesARPText() throws {
        let text = """
        ? (192.168.1.1) at c4:2f:90:ab:cd:ef on en0 ifscope [ethernet]
        camera.local (192.168.1.64) at 3c:ef:8c:1:22:33 on en0 ifscope [ethernet]
        ? (192.168.1.99) at (incomplete) on en0 ifscope [ethernet]
        nonsense line with no parentheses
        ? (not-an-address) at c4:2f:90:ab:cd:ef on en0
        """
        let entries = ARPTableDecoder.decodeARPText(text)
        #expect(entries.count == 3)
        #expect(entries[0].mac == (try Self.mac("c4:2f:90:ab:cd:ef")))
        #expect(entries[1].address == IPv4Address(192, 168, 1, 64))
        #expect(entries[1].mac == (try Self.mac("3c:ef:8c:01:22:33")))
        #expect(entries[2].isIncomplete)
    }

    /// An empty string is not an error.
    @Test func arpTableDecoderParsesEmptyText() {
        #expect(ARPTableDecoder.decodeARPText("").isEmpty)
    }

    // MARK: - Identity gating

    /// Test 50: an entry outside every planned subnet never attaches its MAC to a record. The
    /// router's neighbour on another network is not one of our cameras.
    @Test func arpTableDecoderEntriesOutsidePlanAreIgnored() throws {
        let planned = [IPv4Subnet(network: IPv4Address(192, 168, 1, 0), prefixLength: 24)]
        let inside = ARPEntry(address: IPv4Address(192, 168, 1, 64),
                             mac: try Self.mac("c4:2f:90:ab:cd:ef"))
        let outside = ARPEntry(address: IPv4Address(172, 16, 4, 4),
                               mac: try Self.mac("c4:2f:90:ab:cd:ee"))
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ObservationBuilder.observation(from: inside, observedAt: stamp,
                                              plannedSubnets: planned) != nil)
        #expect(ObservationBuilder.observation(from: outside, observedAt: stamp,
                                              plannedSubnets: planned) == nil)
    }

    /// An incomplete entry proves an address is in use but is never an identity.
    @Test func arpTableDecoderIncompleteEntryYieldsNoObservation() {
        let entry = ARPEntry(address: IPv4Address(192, 168, 1, 70),
                             mac: MACAddress(0, 0, 0, 0, 0, 0), isIncomplete: true)
        #expect(ObservationBuilder.observation(from: entry,
                                              observedAt: Date(timeIntervalSince1970: 0)) == nil)
    }
}
