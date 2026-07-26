//
//  ARPTableDecoder.swift
//  VigilDiscovery
//
//  Decoding of the kernel's ARP table: the `sysctl(PF_ROUTE)` binary dump macOS returns, and the
//  `arp -an` text form used for pasted diagnostics and tests.
//  Implements docs/spec-discovery.md §6.3 and §14.5. Bounds-checked at every step: the input is a
//  buffer of C structs and a truncated one must yield fewer entries, never a crash.
//

import VigilProtocols

/// Parsers for the two shapes an ARP cache reaches us in.
///
/// Reading ARP is the cheapest identity in the whole pipeline: no packet is sent and the result is a
/// MAC per on-link IP, which is the strongest rung of the identity ladder. The decoding is pure so
/// it can be fuzzed and unit-tested on Linux against a recorded blob, far from `sysctl`.
public enum ARPTableDecoder {

    /// `AF_LINK`, the address family of a `sockaddr_dl`.
    private static let afLink: UInt8 = 18
    /// `AF_INET`.
    private static let afINet: UInt8 = 2
    /// Length of a `sockaddr_in`.
    private static let sockaddrInLength = 16
    /// Fixed prefix of a `sockaddr_dl` before `sdl_data`.
    private static let sockaddrDLHeader = 8
    /// Size of an `rt_msghdr` on Apple platforms — the walk skips this to reach the addresses.
    private static let routeHeaderLength = 92

    /// Rounds a `sa_len` up to the next multiple of 4, treating 0 as 4 — the BSD `SA_SIZE` rule. A
    /// zero-length sockaddr would otherwise advance the cursor by nothing and loop forever.
    @inline(__always)
    static func roundup(_ length: Int) -> Int {
        length > 0 ? (1 + ((length - 1) | 3)) : 4
    }

    /// Decodes a `sysctl(CTL_NET, PF_ROUTE, …, NET_RT_FLAGS, RTF_LLINFO)` dump.
    ///
    /// Walks `rt_msghdr` records using `rtm_msglen` (`UInt16` at offset 0, little-endian on every
    /// Apple platform we support). Within a record the first sockaddr is the `sockaddr_in` holding
    /// the IPv4 address and the second, at `roundup(sa_len)` further on, is the `sockaddr_dl` holding
    /// the link-layer address.
    ///
    /// Every read is bounds-checked against both the record and the buffer. Records that are
    /// truncated, that declare a length shorter than a header, whose family is not `AF_LINK(18)`, or
    /// whose `sdl_nlen + sdl_alen + 8` exceeds `sdl_len` are skipped; a record with `sdl_alen == 0`
    /// becomes an `isIncomplete` entry, which counts as "a host exists here" but never as identity.
    /// A hostile or truncated blob yields the entries parsed so far.
    public static func decodeRouteDump(_ raw: UnsafeRawBufferPointer, byteCount: Int) -> [ARPEntry] {
        var entries: [ARPEntry] = []
        let limit = min(byteCount, raw.count)
        guard limit > 0 else { return entries }

        var offset = 0
        while offset + routeHeaderLength <= limit {
            let messageLength = Int(loadUInt16LE(raw, offset))
            // A record must be at least a header, and must fit; either failure ends the walk.
            guard messageLength >= routeHeaderLength, offset + messageLength <= limit else { break }
            let recordEnd = offset + messageLength

            var cursor = offset + routeHeaderLength
            guard let address = decodeSockaddrIn(raw, at: cursor, end: recordEnd) else {
                offset = recordEnd
                continue
            }
            let inLength = Int(raw[cursor])
            cursor += roundup(inLength == 0 ? sockaddrInLength : inLength)

            if let (mac, index, incomplete) = decodeSockaddrDL(raw, at: cursor, end: recordEnd) {
                entries.append(ARPEntry(address: address, mac: mac, interfaceIndex: index,
                                        isIncomplete: incomplete))
            }
            offset = recordEnd
        }
        return entries
    }

    /// Reads the IPv4 address out of a `sockaddr_in` at `offset`, or `nil` when the family is wrong
    /// or the struct does not fit inside the record.
    private static func decodeSockaddrIn(_ raw: UnsafeRawBufferPointer, at offset: Int,
                                         end: Int) -> IPv4Address? {
        guard offset + sockaddrInLength <= end, offset + sockaddrInLength <= raw.count else {
            return nil
        }
        guard raw[offset + 1] == afINet else { return nil }
        // sin_addr sits at offset 4 in network byte order.
        let value = UInt32(raw[offset + 4]) << 24 | UInt32(raw[offset + 5]) << 16
            | UInt32(raw[offset + 6]) << 8 | UInt32(raw[offset + 7])
        return IPv4Address(rawValue: value)
    }

    /// Reads the link-layer address out of a `sockaddr_dl` at `offset`.
    ///
    /// Returns `nil` when the struct does not fit, the family is not `AF_LINK`, or the declared name
    /// and address lengths run past `sdl_len` — the exact check §14.5 calls for. A resolved MAC that
    /// is all-zero, broadcast or multicast is returned with `isIncomplete: true` so it can order the
    /// sweep without ever becoming an identity.
    private static func decodeSockaddrDL(_ raw: UnsafeRawBufferPointer, at offset: Int,
                                         end: Int) -> (MACAddress, Int32, Bool)? {
        guard offset + sockaddrDLHeader <= end, offset + sockaddrDLHeader <= raw.count else {
            return nil
        }
        let declaredLength = Int(raw[offset])
        guard raw[offset + 1] == afLink else { return nil }
        let structureLength = declaredLength == 0 ? sockaddrDLHeader : declaredLength
        guard offset + structureLength <= end, offset + structureLength <= raw.count else {
            return nil
        }
        let index = Int32(UInt16(raw[offset + 2]) | UInt16(raw[offset + 3]) << 8)
        let nameLength = Int(raw[offset + 5])
        let addressLength = Int(raw[offset + 6])
        guard sockaddrDLHeader + nameLength + addressLength <= structureLength else { return nil }
        guard addressLength == 6 else {
            // An entry the kernel has probed but not resolved. It proves the address is in use.
            return (MACAddress(0, 0, 0, 0, 0, 0), index, true)
        }
        let base = offset + sockaddrDLHeader + nameLength
        let mac = MACAddress(raw[base], raw[base + 1], raw[base + 2],
                             raw[base + 3], raw[base + 4], raw[base + 5])
        return (mac, index, !mac.isUsableIdentity)
    }

    /// Little-endian `UInt16` load that never reads past the buffer.
    private static func loadUInt16LE(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt16 {
        guard offset + 1 < raw.count else { return 0 }
        return UInt16(raw[offset]) | UInt16(raw[offset + 1]) << 8
    }

    // MARK: - Text form

    /// Parses `arp -an` output.
    ///
    /// Accepts the macOS shape `? (192.168.1.64) at c4:2f:90:ab:cd:ef on en0 ifscope [ethernet]`,
    /// tolerates a hostname in place of `?`, and treats `(incomplete)` as an incomplete entry.
    /// Lines it cannot understand are skipped silently: this parser exists for pasted diagnostics,
    /// where partial input is the norm.
    public static func decodeARPText(_ text: String) -> [ARPEntry] {
        var entries: [ARPEntry] = []
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard let open = line.firstIndex(of: "("),
                  let close = line[open...].firstIndex(of: ")") else { continue }
            let addressText = String(line[line.index(after: open)..<close])
            guard let address = IPv4Address(addressText) else { continue }

            let remainder = line[line.index(after: close)...]
            let fields = remainder.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let atIndex = fields.firstIndex(where: { $0 == "at" }),
                  atIndex + 1 < fields.endIndex else { continue }
            let macField = String(fields[atIndex + 1])
            if macField.hasPrefix("(incomplete") || macField == "incomplete" {
                entries.append(ARPEntry(address: address, mac: MACAddress(0, 0, 0, 0, 0, 0),
                                        interfaceIndex: 0, isIncomplete: true))
                continue
            }
            guard let mac = MACAddress(normaliseTextMAC(macField)) else { continue }
            entries.append(ARPEntry(address: address, mac: mac, interfaceIndex: 0,
                                    isIncomplete: !mac.isUsableIdentity))
        }
        return entries
    }

    /// `arp` prints octets without a leading zero (`c4:2f:90:0:cd:ef`). Pad each group to two hex
    /// digits so `MACAddress(_:)`, which is strict by design, accepts it.
    private static func normaliseTextMAC(_ text: String) -> String {
        let groups = text.split(separator: ":", omittingEmptySubsequences: false)
        guard groups.count == 6 else { return text }
        return groups.map { $0.count == 1 ? "0" + $0 : String($0) }.joined(separator: ":")
    }
}
