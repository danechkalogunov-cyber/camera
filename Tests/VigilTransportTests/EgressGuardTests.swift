//
//  EgressGuardTests.swift
//  VigilTransportTests
//
//  The LAN-only egress gate: which literals are permitted, which are refused, and which names
//  cannot be classified until a resolver has answered.
//  Covers docs/API_CONTRACT.md §2 R-71 and the two-stage design documented in EgressGuard.swift.
//
//  macOS-only, like the target it tests. On Linux this file compiles to nothing and none of these
//  cases run — the classifier itself is plain Swift over `VigilProtocols` and would be perfectly
//  testable on Linux if R-71's `HostPolicy` existed in the pure layer, which is one more reason to
//  finish moving it there.
//

#if os(macOS)

import Testing

import VigilProtocols
@testable import VigilTransport

@Suite struct EgressGuardClassification {

    // MARK: - Literals that must be permitted

    @Test func egressGuardPermitsEveryLocalIPv4Literal() {
        let permitted = ["127.0.0.1", "10.0.0.5", "172.16.4.9", "172.31.255.254", "192.168.1.64",
                         "169.254.10.20", "239.255.255.250", "255.255.255.255"]
        for host in permitted {
            #expect(EgressGuard.classify(host) == .permitted, "\(host) is on the LAN")
        }
    }

    @Test func egressGuardPermitsLocalIPv6Literals() {
        let permitted = ["::1", "fe80::1", "[fe80::1%25en0]", "fd00::1234", "ff02::c"]
        for host in permitted {
            #expect(EgressGuard.classify(host) == .permitted, "\(host) is on the LAN")
        }
    }

    // MARK: - Literals that must be refused

    @Test func egressGuardRefusesPublicLiterals() {
        // 172.32/12 and 192.169/16 are just outside RFC 1918 and are the classic off-by-one.
        let refused = ["8.8.8.8", "1.1.1.1", "172.32.0.1", "192.169.1.1", "2606:4700::1111", "",
                       "::", "not-an-address:::"]
        for host in refused {
            #expect(EgressGuard.classify(host) == .refused, "\(host) must never get a socket")
        }
    }

    // MARK: - Names

    @Test func egressGuardPermitsNamesThatCanOnlyResolveLocally() {
        for host in ["localhost", "nvr", "NVR", "doorbell.local", "doorbell.local.", "Camera.LOCAL"] {
            #expect(EgressGuard.classify(host) == .permitted, "\(host) resolves only on the link")
        }
    }

    @Test func egressGuardDefersOrdinaryDNSNamesUntilTheyResolve() {
        // The defect this replaced: every one of these was refused outright, so a camera on an
        // internal domain could not be connected to at all.
        for host in ["nvr.example.internal", "cam1.lan.example.com", "hikvision.example.org"] {
            #expect(EgressGuard.classify(host) == .unresolvedName,
                    "\(host) cannot be classified before it resolves")
        }
    }

    // MARK: - Stage two: resolved addresses

    /// `count` zero bytes, for building an address literal that reads like the `::` it stands for.
    static func zeros(_ count: Int) -> [UInt8] { [UInt8](repeating: 0, count: count) }

    @Test func egressGuardPermitsResolvedLocalAddresses() {
        let ipv4: [[UInt8]] = [[192, 168, 1, 64], [127, 0, 0, 1], [10, 1, 2, 3]]
        for address in ipv4 {
            #expect(EgressGuard.isPermitted(resolvedAddress: address))
        }
        let loopback: [UInt8] = Self.zeros(15) + [1]                            // ::1
        let uniqueLocal: [UInt8] = [0xFD, 0x00] + Self.zeros(13) + [1]          // fd00::1
        let mapped: [UInt8] = Self.zeros(10) + [0xFF, 0xFF, 192, 168, 1, 64]    // ::ffff:192.168.1.64
        for address in [loopback, uniqueLocal, mapped] {
            #expect(EgressGuard.isPermitted(resolvedAddress: address))
        }
    }

    @Test func egressGuardRefusesResolvedPublicAddresses() {
        let google: [UInt8] = [8, 8, 8, 8]
        let ipv6: [UInt8] = [0x26, 0x06, 0x47, 0x00] + Self.zeros(10) + [0x11, 0x11]
        // A public address wearing an IPv6 shape must not slip past: ::ffff:8.8.8.8.
        let mapped: [UInt8] = Self.zeros(10) + [0xFF, 0xFF, 8, 8, 8, 8]
        for address in [google, ipv6, mapped] {
            #expect(!EgressGuard.isPermitted(resolvedAddress: address))
        }
    }

    @Test func egressGuardRefusesAnAddressOfAnUnknownLength() {
        // A shape this code does not understand is a shape it must not connect to.
        for length in [0, 1, 3, 5, 15, 17] {
            let address = [UInt8](repeating: 10, count: length)
            #expect(!EgressGuard.isPermitted(resolvedAddress: address),
                    "\(length) bytes is not an address")
        }
    }

    @Test func egressGuardThrowsTheSameErrorAtBothStages() throws {
        #expect(throws: TransportError.egressBlocked(host: "8.8.8.8")) {
            try EgressGuard.requirePermitted("8.8.8.8")
        }
        #expect(throws: TransportError.egressBlocked(host: "nvr.example.internal")) {
            try EgressGuard.requirePermitted(resolvedAddress: [8, 8, 8, 8],
                                             host: "nvr.example.internal")
        }
        // A name that cannot be classified yet is not refused by stage one.
        let decision = try EgressGuard.requirePermitted("nvr.example.internal")
        #expect(decision == .unresolvedName)
    }
}

#endif  // os(macOS)
