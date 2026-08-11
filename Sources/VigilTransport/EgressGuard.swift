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
//  Stage one forwards to the pure, Linux-tested `VigilProtocols.HostPolicy`. The resolved-address
//  stage remains here because it consumes Network.framework's raw address bytes after DNS.
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
        let classification = HostPolicy.classify(host)
        if classification.isEgressPermitted { return .permitted }
        if classification == .invalid { return .refused }
        // Ordinary multi-label DNS is conservatively `.publicInternet` before resolution. Internal
        // DNS still has to work, so only literals are refused here; names owe the stage-two check.
        if IPv4Address(bare) != nil || bare.contains(":") {
            return .refused
        }
        return .unresolvedName
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
        HostPolicy.classify(address).isEgressPermitted
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

    /// Classifies sixteen IPv6 address bytes. Same prefixes as the literal form, plus the
    /// IPv4-mapped range, which a dual-stack resolver can hand back for an IPv4-only camera.
    private static func isPermittedIPv6(_ bytes: [UInt8]) -> Bool {
        HostPolicy.classify(resolvedAddress: bytes).isEgressPermitted
    }

}

#endif
