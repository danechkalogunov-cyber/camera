//
//  HostPolicy.swift
//  VigilProtocols
//
//  The pure, platform-independent LAN-only destination classifier (R-71).
//

import Foundation

/// The network scope of one destination before any socket is opened.
public enum HostClass: String, Sendable, Hashable, Codable {
    case loopback, privateLAN, linkLocal, multicast, publicInternet, invalid

    /// The only classes Vigil may open a socket to.
    @inlinable public var isEgressPermitted: Bool {
        self != .publicInternet && self != .invalid
    }
}

/// The single LAN-only egress gate shared by transports and HTTP clients.
public enum HostPolicy {

    /// Classifies an IPv4 literal, bracketed/bare IPv6 literal, or DNS name without resolving it.
    public static func classify(_ host: String) -> HostClass {
        let bare = unbracketed(host)
        guard !bare.isEmpty else { return .invalid }
        if let address = IPv4Address(bare) { return classify(address) }
        if bare.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E }) {
            return .invalid
        }
        if bare.contains(":"), let bytes = ipv6Bytes(bare) { return classifyIPv6(bytes) }
        if bare.contains(":") { return .invalid }
        return classifyName(bare)
    }

    /// Classifies an already parsed IPv4 address.
    public static func classify(_ address: IPv4Address) -> HostClass {
        if address.isUnspecified { return .invalid }
        if address.isLoopback { return .loopback }
        if address.isPrivate { return .privateLAN }
        if address.isLinkLocal { return .linkLocal }
        if address.isMulticast || address.isBroadcast { return .multicast }
        return .publicInternet
    }

    /// Classifies one numeric address returned by a platform resolver.
    ///
    /// Four bytes are an IPv4 address and sixteen bytes are IPv6, both in network byte order.
    /// Any other shape is invalid and therefore fails closed.
    public static func classify(resolvedAddress bytes: [UInt8]) -> HostClass {
        switch bytes.count {
        case 4:
            let raw = bytes.reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
            return classify(IPv4Address(rawValue: raw))
        case 16:
            return classifyIPv6(bytes)
        default:
            return .invalid
        }
    }

    /// Throws before I/O for a destination that cannot be local.
    public static func requirePermitted(_ host: String) throws(TransportError) {
        guard classify(host).isEgressPermitted else {
            throw TransportError.egressBlocked(host: host)
        }
    }

    // MARK: - DNS names

    private static func classifyName(_ raw: String) -> HostClass {
        var name = ASCII.lowercased(raw)
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty, name.utf8.count <= 253 else { return .invalid }
        if name == "localhost" || name.hasSuffix(".localhost") { return .loopback }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ validLabel($0) }) else { return .invalid }
        if labels.count == 1 || name.hasSuffix(".local") { return .linkLocal }
        // An ordinary DNS name is conservatively public until the platform resolver returns
        // concrete addresses. Drivers that support internal DNS perform that second-stage check.
        return .publicInternet
    }

    private static func validLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty, label.utf8.count <= 63,
              label.first != "-", label.last != "-" else { return false }
        return label.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D
        }
    }

    // MARK: - IPv6

    private static func unbracketed(_ host: String) -> String {
        var text = Substring(host)
        if text.hasPrefix("["), text.hasSuffix("]"), text.count >= 2 {
            text = text.dropFirst().dropLast()
        }
        if let percent = text.firstIndex(of: "%") { text = text[..<percent] }
        return String(text)
    }

    /// Small strict IPv6 parser used only for classification; returns 16 network-order bytes.
    private static func ipv6Bytes(_ text: String) -> [UInt8]? {
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        guard let left = groups(halves[0]) else { return nil }
        let right: [UInt16]
        if halves.count == 2 {
            guard let parsed = groups(halves[1]) else { return nil }
            right = parsed
        } else {
            right = []
        }
        let count = left.count + right.count
        let words: [UInt16]
        if halves.count == 2 {
            guard count < 8 else { return nil }
            words = left + Array(repeating: 0, count: 8 - count) + right
        } else {
            guard count == 8 else { return nil }
            words = left
        }
        return words.flatMap { [UInt8(truncatingIfNeeded: $0 >> 8), UInt8(truncatingIfNeeded: $0)] }
    }

    private static func groups(_ half: String) -> [UInt16]? {
        guard !half.isEmpty else { return [] }
        let tokens = half.split(separator: ":", omittingEmptySubsequences: false)
        var words: [UInt16] = []
        for (index, token) in tokens.enumerated() {
            guard !token.isEmpty else { return nil }
            if token.contains(".") {
                guard index == tokens.count - 1, let address = IPv4Address(String(token)) else {
                    return nil
                }
                words.append(UInt16(truncatingIfNeeded: address.rawValue >> 16))
                words.append(UInt16(truncatingIfNeeded: address.rawValue))
            } else {
                guard token.count <= 4, let value = UInt16(token, radix: 16) else { return nil }
                words.append(value)
            }
        }
        return words
    }

    private static func classifyIPv6(_ bytes: [UInt8]) -> HostClass {
        guard bytes.count == 16 else { return .invalid }
        if bytes.allSatisfy({ $0 == 0 }) { return .invalid }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 { return .loopback }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            let raw = (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16)
                | (UInt32(bytes[14]) << 8) | UInt32(bytes[15])
            return classify(IPv4Address(rawValue: raw))
        }
        if bytes[0] & 0xFE == 0xFC { return .privateLAN }
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return .linkLocal }
        if bytes[0] == 0xFF { return .multicast }
        return .publicInternet
    }
}
