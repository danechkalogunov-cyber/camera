//
//  EgressGuard.swift
//  VigilTransport
//
//  The LAN-only egress gate every socket in this module passes through before it is created. Vigil
//  talks to the local network and nowhere else, and that has to be a property of the code rather
//  than a promise in a README.
//  Implements docs/API_CONTRACT.md §5.9 (`EgressGuard.swift`) and §2 R-71.
//
//  DEVIATION, and it wants closing. R-71 puts the classifier in `VigilProtocols`
//  (`Net/HostPolicy.swift`: `HostPolicy.classify(_:)` and `HostPolicy.requirePermitted(_:)`) so it
//  is pure and Linux-tested. That file does not exist in the repository yet and this target may not
//  create it — it belongs to another agent's file rows. The rules below are therefore a stand-in
//  with the same refusals and the same error. When `HostPolicy` lands, delete every private member
//  here and make `requirePermitted` a one-line forward to it; nothing else in this module reads the
//  classifier, so that change is local.
//

#if os(macOS)

import Foundation
import VigilProtocols

// MARK: - EgressGuard

/// Refuses a destination that is not on the local network, **before** a socket exists.
///
/// The check is deliberately conservative: a host it cannot classify is refused. Refusing a
/// reachable camera is a bug report; reaching the public internet is a broken promise, and only one
/// of those is recoverable.
package enum EgressGuard {

    /// Throws `TransportError.egressBlocked` for a destination outside the LAN.
    ///
    /// - Parameter host: an IPv4 literal, an IPv6 literal (bracketed or bare, zone id permitted),
    ///   or a DNS name. Never a URL.
    package static func requirePermitted(_ host: String) throws(TransportError) {
        guard isPermitted(host) else {
            throw TransportError.egressBlocked(host: host)
        }
    }

    /// Whether `host` is a destination Vigil may open a socket to.
    ///
    /// Permitted: loopback, RFC 1918 private space, link-local (169.254/16 and `fe80::/10`), IPv4
    /// multicast and broadcast, IPv6 unique-local (`fc00::/7`) and multicast (`ff00::/8`),
    /// `localhost`, any `*.local` mDNS name, and any single-label name (`nvr`), which can only be
    /// resolved by mDNS or by a LAN resolver.
    ///
    /// Refused: every global unicast address, and every multi-label DNS name that is not `*.local`.
    /// A refused DNS name is the case R-71 describes as `.publicInternet` **until resolved** — the
    /// classification is correct here only because Vigil's R1 flow gives an address, not a name.
    /// The moment a resolver enters the picture, the resolved address must be re-checked and this
    /// rule revisited; see the agent's uncertainty list.
    package static func isPermitted(_ host: String) -> Bool {
        let bare = unbracketed(host)
        guard !bare.isEmpty else { return false }

        if let address = IPv4Address(bare) {
            return address.isLoopback
                || address.isPrivate
                || address.isLinkLocal
                || address.isMulticast
                || address.isBroadcast
        }
        if bare.contains(":") {
            return isPermittedIPv6(bare)
        }
        return isLocalName(bare)
    }

    // MARK: - Host shapes

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

    /// Classifies an IPv6 literal from its first hextet, which is all these prefixes need.
    ///
    /// Refuses anything it cannot read as hexadecimal, including the unspecified address `::`.
    private static func isPermittedIPv6(_ text: String) -> Bool {
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

    /// Whether a DNS name can only resolve on the local link.
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
