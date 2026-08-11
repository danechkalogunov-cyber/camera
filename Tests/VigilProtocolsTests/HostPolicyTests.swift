import Foundation
import Testing

@testable import VigilProtocols

@Suite struct HostPolicyTests {

    @Test func classifiesEveryIPv4Boundary() {
        let cases: [(String, HostClass)] = [
            ("0.0.0.0", .invalid), ("127.0.0.1", .loopback), ("127.255.255.254", .loopback),
            ("10.0.0.1", .privateLAN), ("10.255.255.254", .privateLAN),
            ("172.15.255.255", .publicInternet), ("172.16.0.0", .privateLAN),
            ("172.31.255.255", .privateLAN), ("172.32.0.0", .publicInternet),
            ("192.168.0.1", .privateLAN), ("192.169.0.1", .publicInternet),
            ("169.253.255.255", .publicInternet), ("169.254.0.1", .linkLocal),
            ("100.64.0.1", .publicInternet), ("224.0.0.1", .multicast),
            ("239.255.255.250", .multicast), ("255.255.255.255", .multicast),
            ("8.8.8.8", .publicInternet),
        ]
        for (host, expected) in cases { #expect(HostPolicy.classify(host) == expected) }
    }

    @Test func classifiesIPv6IncludingMappedIPv4AndZones() {
        let cases: [(String, HostClass)] = [
            ("::", .invalid), ("::1", .loopback), ("[::1]", .loopback),
            ("fc00::1", .privateLAN), ("fdff:ffff::1", .privateLAN),
            ("fe80::1", .linkLocal), ("[fe80::1%25en0]", .linkLocal),
            ("ff02::c", .multicast), ("2001:4860:4860::8888", .publicInternet),
            ("::ffff:192.168.1.64", .privateLAN),
            ("::ffff:169.254.1.2", .linkLocal), ("::ffff:8.8.8.8", .publicInternet),
        ]
        for (host, expected) in cases { #expect(HostPolicy.classify(host) == expected) }
    }

    @Test func classifiesLocalAndOrdinaryDNSNamesConservatively() {
        let cases: [(String, HostClass)] = [
            ("localhost", .loopback), ("camera.localhost", .loopback),
            ("camera", .linkLocal), ("Camera.LOCAL", .linkLocal),
            ("camera.local.", .linkLocal), ("nvr.example.internal", .publicInternet),
            ("camera.example.com", .publicInternet),
        ]
        for (host, expected) in cases { #expect(HostPolicy.classify(host) == expected) }
    }

    @Test func rejectsMalformedDestinationsRatherThanGuessing() {
        let malformed = [
            "", " camera.local", "camera..local", "-camera.local", "camera-.local",
            "camera_local", "1.2.3", "01.2.3.4", "256.1.1.1", ":::1", "1::2::3",
            "[fe80::1", String(repeating: "a", count: 64) + ".local",
        ]
        for host in malformed { #expect(HostPolicy.classify(host) == .invalid, "\(host)") }
    }

    @Test func requirePermittedUsesTheSameClassification() throws {
        try HostPolicy.requirePermitted("192.168.1.64")
        try HostPolicy.requirePermitted("camera.local")
        #expect(throws: TransportError.egressBlocked(host: "8.8.8.8")) {
            try HostPolicy.requirePermitted("8.8.8.8")
        }
        #expect(throws: TransportError.egressBlocked(host: "camera.example.com")) {
            try HostPolicy.requirePermitted("camera.example.com")
        }
    }

    @Test func classifiesResolverBytesWithoutPlatformNetworkingTypes() {
        #expect(HostPolicy.classify(resolvedAddress: [192, 168, 1, 64]) == .privateLAN)
        #expect(HostPolicy.classify(resolvedAddress: [8, 8, 8, 8]) == .publicInternet)
        #expect(HostPolicy.classify(resolvedAddress: Array(repeating: 0, count: 15) + [1])
                == .loopback)
        #expect(HostPolicy.classify(resolvedAddress: [1, 2, 3]) == .invalid)
    }

    @Test func rtspEndpointKeepsTheCredentialFreeWireAddress() throws {
        let endpoint = RTSPEndpoint(host: "192.168.1.64", path: "/Streaming/Channels/101")
        #expect(endpoint.host == "192.168.1.64")
        #expect(endpoint.port == 554)
        #expect(endpoint.path == "/Streaming/Channels/101")
        #expect(endpoint.transport == .tcpInterleaved)

        let data = try JSONEncoder().encode(endpoint)
        #expect(try JSONDecoder().decode(RTSPEndpoint.self, from: data) == endpoint)
    }
}
