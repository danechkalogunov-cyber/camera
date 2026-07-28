//
//  SystemARPTableReader.swift
//  VigilTransport
//
//  The kernel's ARP cache, read through `sysctl(PF_ROUTE, NET_RT_FLAGS, RTF_LLINFO)`.
//  macOS-only. Backs `VigilDiscovery.ARPTableProviding`; see docs/spec-discovery.md §6.3.
//
//  Why this is worth a file. A MAC address is the strongest rung of the identity ladder — it
//  survives a DHCP lease change, which an IP does not — and the ARP cache yields one for **no
//  packet at all**, for every host this Mac has recently spoken to. Everything else in discovery
//  costs a probe.
//

#if os(macOS)

import Darwin
import Foundation

import VigilDiscovery
import VigilProtocols

// MARK: - SystemARPTableReader

/// Reads the ARP cache.
public struct SystemARPTableReader: ARPTableProviding {

    /// Creates a reader.
    public init() {}

    /// The current cache.
    ///
    /// - Returns: one entry per **resolved** row. An incomplete row — an address the kernel has
    ///   ARPed for and not yet heard back about — carries no MAC and is dropped; see the comment
    ///   at the drop for why a placeholder would be worse than the omission.
    /// - Throws: `.arpReadFailed(errno:)` when the sysctl failed.
    public func snapshot() throws(DiscoveryError) -> [ARPEntry] {
        // AF_INET, not AF_UNSPEC: the sysctl would otherwise hand back the IPv6 neighbour table
        // interleaved with this one, and `sdl_alen` alone cannot tell them apart.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]

        var needed = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &needed, nil, 0) == 0 else {
            throw DiscoveryError.arpReadFailed(errno: errno)
        }
        // An empty cache is a legal answer, not a failure: a Mac that has just woken has one.
        guard needed > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: needed)
        let status = buffer.withUnsafeMutableBytes { raw -> Int32 in
            sysctl(&mib, UInt32(mib.count), raw.baseAddress, &needed, nil, 0)
        }
        guard status == 0 else { throw DiscoveryError.arpReadFailed(errno: errno) }

        return Self.parse(buffer, byteCount: needed)
    }

    // MARK: - Private Helpers

    /// Walks the routing messages the kernel wrote into `buffer`.
    ///
    /// ⚠️ The length to walk is the sysctl's **second** answer, not `buffer.count`. The first call
    /// asks for a size and the kernel adds slack; walking the whole allocation would read past the
    /// last message into zeroed memory and decode a row of zeroes as an entry for `0.0.0.0`.
    private static func parse(_ buffer: [UInt8], byteCount: Int) -> [ARPEntry] {
        var out: [ARPEntry] = []
        var offset = 0
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            // `rt_msghdr`, not `rt_msghdr2`: `NET_RT_FLAGS` writes the plain header. The `2` variant
            // is larger, and using it here would skip every message shorter than it — which is all
            // of them.
            while offset + MemoryLayout<rt_msghdr>.size <= byteCount {
                let header = base.advanced(by: offset)
                    .assumingMemoryBound(to: rt_msghdr.self).pointee
                let length = Int(header.rtm_msglen)
                // A zero or negative length would spin here for ever; a length past the end would
                // read the neighbouring allocation. Either means the message stream is not what
                // this code was written against, and stopping is the only safe response.
                guard length > 0, offset + length <= byteCount else { return }
                defer { offset += length }

                if let entry = read(base.advanced(by: offset), messageLength: length) {
                    out.append(entry)
                }
            }
        }
        return out
    }

    /// One routing message as an `ARPEntry`, or `nil` when it is not a usable ARP row.
    private static func read(_ message: UnsafeRawPointer, messageLength: Int) -> ARPEntry? {
        let headerSize = MemoryLayout<rt_msghdr>.size
        guard messageLength > headerSize else { return nil }
        let header = message.assumingMemoryBound(to: rt_msghdr.self).pointee

        // The two addresses follow the header back to back: the destination (an IPv4 sockaddr_in)
        // and the gateway (a link-layer sockaddr_dl holding the MAC).
        let destination = message.advanced(by: headerSize)
        guard destination.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
                == UInt8(AF_INET) else { return nil }
        let sin = destination.assumingMemoryBound(to: sockaddr_in.self).pointee
        let address = IPv4Address(rawValue: UInt32(bigEndian: sin.sin_addr.s_addr))

        // Each sockaddr is padded to a 4-byte boundary, and a zero `sa_len` means "one word".
        let destinationLength = Self.padded(Int(
            destination.assumingMemoryBound(to: sockaddr.self).pointee.sa_len))
        // The link-layer address must fit inside this message. Reading past `rtm_msglen` walks
        // into the next message and decodes its header bytes as a MAC.
        let gatewayOffset = headerSize + destinationLength
        guard gatewayOffset + MemoryLayout<sockaddr_dl>.size <= messageLength else { return nil }
        let gateway = message.advanced(by: gatewayOffset)
        let link = gateway.assumingMemoryBound(to: sockaddr_dl.self).pointee

        guard link.sdl_family == UInt8(AF_LINK) else { return nil }
        // ⛔ An incomplete row is dropped, not returned with a placeholder. `ARPEntry.mac` is not
        // optional — the type says an entry *has* a MAC — and the whole value of this reader is
        // that a MAC is stronger identity than an address. Inventing `00:00:00:00:00:00` to fill
        // the field would put a shared fake identity on every unanswered address on the segment,
        // and the merge engine would fuse them into one device.
        guard let mac = Self.mac(in: link) else { return nil }
        return ARPEntry(address: address,
                        mac: mac,
                        interfaceIndex: Int32(link.sdl_index),
                        isIncomplete: false)
    }

    /// The six MAC bytes out of a `sockaddr_dl`, or `nil` when the row has no link address.
    ///
    /// `sdl_data` holds the interface name first and the address after it, so the offset is
    /// `sdl_nlen` — reading from zero yields the first three characters of `en0` as the start of a
    /// MAC, which is a plausible-looking value and completely wrong.
    private static func mac(in link: sockaddr_dl) -> MACAddress? {
        guard link.sdl_alen == 6 else { return nil }
        var storage = link
        let bytes: [UInt8]? = withUnsafeBytes(of: &storage.sdl_data) { raw in
            let start = Int(link.sdl_nlen)
            guard start >= 0, start + 6 <= raw.count else { return nil }
            return (0..<6).map { raw[start + $0] }
        }
        guard let bytes, bytes.count == 6 else { return nil }
        return MACAddress(bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5])
    }

    /// A `sockaddr`'s length rounded up to the routing socket's 4-byte alignment.
    private static func padded(_ length: Int) -> Int {
        length > 0 ? (length + 3) & ~3 : 4
    }
}

#endif  // os(macOS)
