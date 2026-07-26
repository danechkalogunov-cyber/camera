//
//  EgressGuard.swift
//  VigilTransport
//
//  The LAN-only egress gate every socket in this module passes through. Vigil talks to the local
//  network and nowhere else, and that has to be a property of the code rather than a promise in a
//  README.
//  Implements docs/API_CONTRACT.md §5.9 (`EgressGuard.swift`) and §2 R-71.
//
//  TWO STAGES, BECAUSE A NAME CANNOT BE CLASSIFIED BEFORE IT RESOLVES. An IP literal is decided
//  before a socket exists and never reaches the network if it is refused. A DNS name that is not
//  obviously local — `nvr.example.internal`, which is what most sites with an NVR actually have —
//  cannot be classified at all until a resolver has answered, so it is allowed **past this check**
//  and the rule is enforced on the address `NWConnection` reports once the connection is ready
//  (`RTSPConnection.enforceResolvedEgress`). A resolved public address fails the connection with
//  the same `TransportError.egressBlocked` the pre-check would have thrown: the guarantee is
//  unchanged, only its timing is. Refusing every multi-label name up front — which this file used
//  to do — makes an internal domain unusable, and that is a real defect, not caution.
//
//  DEVIATION, and it wants closing. R-71 puts the classifier in `VigilProtocols`
//  (`Net/HostPolicy.swift`: `HostPolicy.classify(_:)` and `HostPolicy.requirePermitted(_:)`) so it
//  is pure and Linux-tested. That file still does not exist and this target may not create it — it
//  belongs to another agent's file rows. The rules below are a stand-in with the same refusals and
//  the same error. When `HostPolicy` lands, the literal classification here becomes a forward to
//  it; the resolved-address stage stays, because `HostPolicy` as specified has no entry point for
//  raw address bytes and the contract's own doc comment says "the caller re-checks the resolved
//  address" — this is that caller.
//

#if os(macOS)

import Foundation
import VigilProtocols

// MARK: - EgressGuard

/// Refuses a destination that is not on the local network.
///
/// Conservative wherever an answer is available: an address it cannot classify is refused. Refusing
/// a reachable camera is a bug report; reaching the public internet is a broken promise, and only
/// one of those is recoverable. Where no answer is available yet — a DNS name before resolution —
/// it says so rather than guessing, and the caller re-checks after the resolver has spoken.
package enum EgressGuard {

    // MARK: - Decision

    /// What the pre-connect check concluded about a destination.
    package enum Decision: Sendable, Hashable {

        /// A literal on the local network, or a name that can only resolve locally. Connect.
        case permitted

        /// A literal outside the local network. Never connected to.
        case refused

        /// A DNS name that cannot be classified until it resolves. The connection may be attempted,
        /// and the resolved address must be passed to ``requirePermitted(resolvedAddress:host:)``
        /// before anything is written to it.
        case unresolvedName
    }

    // MARK: - Stage one: before the socket exists

    /// Classifies a destination without resolving it.
    ///
    /// - Parameter host: an IPv4 literal, an IPv6 literal (bracketed or bare, zone id permitted),
    ///   or a DNS name. Never a URL.
    ///
    /// Permitted literals: loopback, RFC 1918 private space, link-local (169.254/16 and `fe80::/10`),
    /// IPv4 multicast and broadcast, IPv6 unique-local (`fc00::/7`) and multicast (`ff00::/8`).
    /// Permitted names: `localhost`, any `*.local` mDNS name, and any single-label name (`nvr`),
    /// which a resolver can only answer from the local link or a LAN resolver.
    ///
    /// Refused: every global unicast literal, and anything empty or unparseable.
    ///
    /// Everything else — every ordinary multi-label DNS name — is `.unresolvedName`.
    package static func classify(_ host: String) -> Decision {
        let bare = unbracketed(host)
        guard !bare.isEmpty else { return .refused }

        if let address = IPv4Address(bare) {
            return isPermitted(address) ? .permitted : .refused
        }
        if bare.contains(":") {
            return isPermittedIPv6Literal(bare) ? .permitted : .refused
        }
        return isLocalName(bare) ? .permitted : .unresolvedName
    }

    /// Throws `TransportError.egressBlocked` for a destination that is already known to be off the
    /// LAN. A name that cannot be classified yet passes, and the caller must re-check the address it
    /// resolves to.
    ///
    /// - Returns: the decision, so the caller knows whether stage two is still owed.
    @discardableResult
    package static func requirePermitted(_ host: String) throws(TransportError) -> Decision {
        let decision = classify(host)
        guard decision != .refused else {
            throw TransportError.egressBlocked(host: host)
        }
        return decision
    }

    // MARK: - Stage two: once the resolver has answered

    /// Whether a resolved address is on the local network.
    ///
    /// - Parameter addressBytes: the address exactly as the platform reports it — **4 bytes** for
    ///   IPv4, **16 bytes** for IPv6, network byte order, no zone id. `Network.IPAddress.rawValue`
    ///   is in this form. An IPv4-mapped IPv6 address (`::ffff:a.b.c.d`) is classified as the IPv4
    ///   address it carries, because that is what the packets will actually go to.
    ///
    /// Any other length is refused: it is a shape this code does not understand, and the whole
    /// point of the guard is that an unclassifiable destination does not get a socket.
    package static func isPermitted(resolvedAddress addressBytes: some Collection<UInt8>) -> Bool {
        let bytes = Array(addressBytes)
        switch bytes.count {
        case 4:
            let raw = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
            return isPermitted(IPv4Address(rawValue: raw))
        case 16:
            return isPermittedIPv6(bytes)
        default:
            return false
        }
    }

    /// Throws `TransportError.egressBlocked` when a resolved address is off the LAN.
    ///
    /// - Parameters:
    ///   - addressBytes: see ``isPermitted(resolvedAddress:)``.
    ///   - host: the name the caller asked for, so the error names what the user typed rather than
    ///     an address they have never seen.
    package static func requirePermitted(resolvedAddress addressBytes: some Collection<UInt8>,
                                         host: String) throws(TransportError) {
        guard isPermitted(resolvedAddress: addressBytes) else {
            throw TransportError.egressBlocked(host: host)
        }
    }

    // MARK: - IPv4

    /// The permitted IPv4 classes. Unchanged from the first implementation of this file: it was
    /// correct, and the two-stage change is only about names.
    private static func isPermitted(_ address: IPv4Address) -> Bool {
        address.isLoopback
            || address.isPrivate
            || address.isLinkLocal
            || address.isMulticast
            || address.isBroadcast
    }

    // MARK: - IPv6

    /// Strips the brackets a URL puts round an IPv6 literal and any `%zone` suffix.
    ///
    /// `"[fe80::1%25en0]"` → `"fe80::1"`. The zone is removed because it identifies an interface,
    /// not an address, and it must not affect the classification.
    private static func unbracketed(_ host: String) -> String {
        var text = Substring(host)
        if text.hasPrefix("["), text.hasSuffix("]"), text.count >= 2 {
            text = text.dropFirst().dropLast()
        }
        if let percent = text.firstIndex(of: "%") {
            text = text[text.startIndex ..< percent]
        }
        return String(text)
    }

    /// Classifies an IPv6 **literal** from its first hextet, which is all these prefixes need.
    ///
    /// Refuses anything it cannot read as hexadecimal, including the unspecified address `::`.
    private static func isPermittedIPv6Literal(_ text: String) -> Bool {
        let lowered = ASCII.lowercased(text)
        if lowered == "::1" {
            return true                                   // loopback
        }
        let leading = lowered.prefix { $0 != ":" }
        guard !leading.isEmpty, let group = UInt16(leading, radix: 16) else {
            return false
        }
        if group >= 0xFE80, group <= 0xFEBF {
            return true                                   // link-local, fe80::/10
        }
        if group >= 0xFC00, group <= 0xFDFF {
            return true                                   // unique local, fc00::/7
        }
        if group >= 0xFF00 {
            return true                                   // multicast, ff00::/8
        }
        return false
    }

    /// Classifies sixteen IPv6 address bytes. Same prefixes as the literal form, plus the
    /// IPv4-mapped range, which a dual-stack resolver can hand back for an IPv4-only camera.
    private static func isPermittedIPv6(_ bytes: [UInt8]) -> Bool {
        // ::ffff:a.b.c.d — ten zero bytes, then 0xFF 0xFF, then the IPv4 address.
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return isPermitted(resolvedAddress: bytes[12..<16])
        }
        // ::1
        if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] == 1 {
            return true
        }
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 {
            return true                                   // link-local, fe80::/10
        }
        if bytes[0] & 0xFE == 0xFC {
            return true                                   // unique local, fc00::/7
        }
        if bytes[0] == 0xFF {
            return true                                   // multicast, ff00::/8
        }
        return false
    }

    // MARK: - Names

    /// Whether a DNS name can only resolve on the local link, so no resolver can point it at the
    /// public internet.
    private static func isLocalName(_ name: String) -> Bool {
        var lowered = ASCII.lowercased(name)
        if lowered.hasSuffix(".") {
            lowered = String(lowered.dropLast())          // a fully qualified name's root label
        }
        guard !lowered.isEmpty else { return false }
        if lowered == "localhost" { return true }
        if lowered.hasSuffix(".local") { return true }
        return !lowered.contains(".")                     // single label: mDNS or a LAN resolver
    }
}

#endif
