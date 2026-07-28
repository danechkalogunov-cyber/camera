//
//  SystemInterfaceEnumerator.swift
//  VigilTransport
//
//  The machine's own IPv4 interfaces, from `getifaddrs(3)`.
//  macOS-only. Backs `VigilDiscovery.InterfaceEnumerating`; see docs/spec-discovery.md §6.1.
//
//  ⛔ This applies NO policy. Loopback, AWDL, tunnels and link-local addresses all come back, and
//  `SweepPlanner` decides what to do with them. That split is the whole reason discovery's rules
//  are testable on Linux while this file is not: every judgement lives in the pure module, and the
//  only thing here is the syscall.
//

#if os(macOS)

import Darwin
import Foundation

import VigilDiscovery
import VigilProtocols

// MARK: - SystemInterfaceEnumerator

/// Reads the interface list from the OS.
///
/// A `struct` and not an actor: `getifaddrs` is a synchronous syscall against a snapshot the kernel
/// builds for the caller, and there is no state here to protect.
public struct SystemInterfaceEnumerator: InterfaceEnumerating {

    /// Creates an enumerator.
    public init() {}

    /// Every IPv4 interface the OS reported, unfiltered.
    ///
    /// - Returns: one entry per interface that has an `AF_INET` address **and** is up. An interface
    ///   that is administratively down cannot carry a probe, so including it would only make the
    ///   planner filter it again; `IFF_UP` is a fact about the link, not a policy about discovery.
    /// - Throws: `.interfaceEnumerationFailed(errno:)` when the syscall failed.
    public func interfaces() throws(DiscoveryError) -> [NetworkInterfaceInfo] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else {
            throw DiscoveryError.interfaceEnumerationFailed(errno: errno)
        }
        defer { freeifaddrs(head) }

        var out: [NetworkInterfaceInfo] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let info = Self.read(entry.pointee) else { continue }
            out.append(info)
        }
        return out
    }

    // MARK: - Private Helpers

    /// One `ifaddrs` row as a `NetworkInterfaceInfo`, or `nil` when it is not a usable IPv4 link.
    private static func read(_ entry: ifaddrs) -> NetworkInterfaceInfo? {
        guard let rawAddress = entry.ifa_addr,
              rawAddress.pointee.sa_family == UInt8(AF_INET),
              let rawMask = entry.ifa_netmask else { return nil }

        let flags = Int32(entry.ifa_flags)
        guard flags & IFF_UP != 0 else { return nil }

        let name = String(cString: entry.ifa_name)
        let address = ipv4(from: rawAddress)
        let netmask = ipv4(from: rawMask)

        return NetworkInterfaceInfo(
            name: name,
            address: address,
            netmask: netmask,
            isPointToPoint: flags & IFF_POINTOPOINT != 0,
            // ⚠️ Inferred from the name, and deliberately not from `SIOCGIFMEDIA`. The ioctl needs
            // a socket and answers with a media type whose Wi-Fi encoding differs by driver; the
            // one thing this flag is used for is preferring wired interfaces first, and being
            // wrong about a renamed adapter costs an ordering, not a result.
            isWireless: name.hasPrefix("en") && Self.wirelessNames.contains(name),
            mtu: Self.mtu(of: entry))
    }

    /// The BSD names Apple hardware uses for Wi-Fi. `en0` is Wi-Fi on every Mac laptop and the
    /// wired port on a Mac with Ethernet, which is exactly why the guess is only an ordering hint.
    private static let wirelessNames: Set<String> = ["en0", "en1"]

    /// The interface MTU, or the Ethernet default when the row carries no `ifa_data`.
    private static func mtu(of entry: ifaddrs) -> Int {
        guard let data = entry.ifa_data else { return 1_500 }
        let metrics = data.assumingMemoryBound(to: if_data.self).pointee
        return metrics.ifi_mtu > 0 ? Int(metrics.ifi_mtu) : 1_500
    }

    /// The address inside a `sockaddr`, in host byte order.
    ///
    /// `sin_addr.s_addr` is network byte order, and `IPv4Address.rawValue` is host order — the two
    /// agree on a big-endian machine and disagree on every machine this ships to, which is the kind
    /// of bug that shows up as a subnet scan of the wrong /24.
    private static func ipv4(from raw: UnsafeMutablePointer<sockaddr>) -> IPv4Address {
        raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
            IPv4Address(rawValue: UInt32(bigEndian: pointer.pointee.sin_addr.s_addr))
        }
    }
}

#endif  // os(macOS)
