//
//  HTTPDestinationGuard.swift
//  VigilISAPI
//
//  The R-71 LAN-only gate for URLSession. No URLSessionTask exists until this check succeeds.
//

import Dispatch
import Foundation
import VigilProtocols

#if canImport(Glibc)
import Glibc
#endif

/// Resolves ordinary DNS names before URLSession gets a chance to open a connection.
///
/// Literal and link-local names are decided by `HostPolicy` without DNS. Ordinary multi-label
/// names are allowed only when every A/AAAA answer is local; one public answer blocks the host.
enum HTTPDestinationGuard {

    enum Resolution: Sendable, Equatable {
        case addresses([[UInt8]])
        case unavailable
    }

    typealias Resolver = @Sendable (String) async -> Resolution

    static func requirePermitted(_ url: URL) async throws(ISAPIError) {
        try await requirePermitted(url, resolver: resolve)
    }

    /// Resolver injection keeps all policy branches deterministic and socket-free in unit tests.
    static func requirePermitted(_ url: URL,
                                 resolver: Resolver) async throws(ISAPIError) {
        guard let host = url.host, !host.isEmpty else {
            throw ISAPIError.notConnected("request URL has no host")
        }

        let classification = HostPolicy.classify(host)
        if classification.isEgressPermitted { return }
        if classification == .invalid || isAddressLiteral(host) {
            throw blocked(host)
        }

        switch await resolver(host) {
        case .addresses(let addresses):
            guard !addresses.isEmpty,
                  addresses.allSatisfy({
                      HostPolicy.classify(resolvedAddress: $0).isEgressPermitted
                  }) else {
                throw blocked(host)
            }
        case .unavailable:
            throw ISAPIError.notConnected("could not resolve \(host)")
        }
    }

    private static func isAddressLiteral(_ host: String) -> Bool {
        IPv4Address(host) != nil || host.contains(":")
    }

    private static func blocked(_ host: String) -> ISAPIError {
        // HTTPTransporting is typed to ISAPIError, so the transport-domain egress failure is
        // adapted at this boundary while preserving a stable, non-secret destination detail.
        .notConnected("egress policy blocked \(host)")
    }

    private static func resolve(_ host: String) async -> Resolution {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: resolveSynchronously(host))
            }
        }
    }

    /// One blocking system lookup, kept off Swift's cooperative executor.
    private static func resolveSynchronously(_ host: String) -> Resolution {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC

        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let head = list else {
            return .unavailable
        }
        defer { freeaddrinfo(head) }

        var addresses: [[UInt8]] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let entry = cursor {
            cursor = entry.pointee.ai_next
            if let bytes = addressBytes(entry.pointee) { addresses.append(bytes) }
        }
        return addresses.isEmpty ? .unavailable : .addresses(addresses)
    }

    private static func addressBytes(_ entry: addrinfo) -> [UInt8]? {
        guard let address = entry.ai_addr else { return nil }
        switch entry.ai_family {
        case AF_INET:
            var value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr
            }
            return withUnsafeBytes(of: &value) { Array($0) }
        case AF_INET6:
            var value = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                $0.pointee.sin6_addr
            }
            return withUnsafeBytes(of: &value) { Array($0) }
        default:
            return nil
        }
    }
}
