//
//  DiscoveryDiagnostic.swift
//  VigilDiscovery
//
//  Everything a discovery run wants to tell the user or a support engineer that is not a device and
//  not a fatal error: refusals, narrowings, clamps, conflicts and missing capabilities.
//  Implements docs/spec-discovery.md §12, plus the entitlement status of §9.3.
//

import VigilProtocols

// MARK: - DiscoveryDiagnostic

/// A non-fatal finding from a discovery run.
///
/// Diagnostics are values, not log lines: the UI groups them in the discovery sheet's "Diagnostics"
/// disclosure and promotes the `.actionRequired` ones into visible remediation. Anything that
/// changes what the user sees — a refused subnet, a narrowed sweep, missing multicast — must appear
/// here, because a scan that silently did less than the user believes is worse than a scan that
/// failed.
public enum DiscoveryDiagnostic: Sendable, Hashable, Codable {

    /// SADP could not bind its preferred local port and fell back to an ephemeral one; some firmware
    /// only answers to port 37020.
    case sadpDegradedEphemeralPort(interface: String)
    /// The same, for WS-Discovery's port 3702.
    case onvifDegradedEphemeralPort(interface: String)
    /// A SADP datagram that was not XML: length, first bytes and Shannon entropy, so an obfuscated
    /// firmware variant can be recognised from a support log.
    case sadpOpaquePayload(from: IPv4Address, length: Int, prefixHex: String, entropy: Double)
    /// One source flooded us and datagrams past the per-source cap were dropped.
    case sadpFlood(from: IPv4Address, dropped: Int)
    /// A SADP payload that was neither valid UTF-8 nor a recognised binary variant.
    case nonUTF8SADPPayload(from: IPv4Address)
    /// Another SADP client is probing this network; its ProbeMatches are visible to us.
    case foreignDiscoveryClientActive(uuid: String)
    /// A subnet was refused outright as too wide to sweep (§6.2). Never retried, never overridable.
    case subnetTooWide(subnet: IPv4Subnet, hostCount: Int)
    /// A large-but-legal subnet was narrowed to the `/24`s worth sweeping.
    case subnetNarrowed(from: IPv4Subnet, to: [IPv4Subnet])
    /// In-flight connects were clamped below the configured value by the file-descriptor limit.
    case concurrencyClamped(to: Int, fileDescriptorLimit: Int)
    /// Multicast is unavailable, so the run degraded to a unicast sweep (§9.5).
    case multicastUnavailable(reason: MulticastUnavailableReason)
    /// Every probe on an interface was silent, including the gateway: macOS is probably blocking
    /// local-network access rather than the network being empty (§9.4).
    case localNetworkPermissionLikelyDenied(interface: String, gateway: IPv4Address?)
    /// Two different MACs claimed one address inside a single run. We keep both records rather than
    /// merging them, and this says why (§7.2).
    case identityConflict(address: IPv4Address, macA: MACAddress, macB: MACAddress)
    /// A politeness budget ran out and the remaining work was abandoned, keeping results (§6.10).
    case budgetExhausted(kind: BudgetKind, limit: Int)
    /// A VPN or tunnel interface was skipped. Sweeping a corporate tunnel is hostile.
    case tunnelInterfaceSkipped(name: String)
    /// A device answered from outside every subnet we hold — a factory-fresh camera on 192.168.1.64
    /// while the Mac is on 10.0.20.0/24. Visible, not connectable (§4.7).
    case offSubnetDeviceSeen(address: IPv4Address, ourSubnets: [IPv4Subnet])

    /// How loudly the UI should present this.
    public enum Severity: String, Sendable, Hashable, Codable {
        /// Background detail; the diagnostics disclosure only.
        case info
        /// The scan did less than the user might assume, or something is degraded.
        case warning
        /// The user must do something (grant permission, move a camera onto this subnet).
        case actionRequired
    }

    /// Severity of this diagnostic.
    public var severity: Severity {
        switch self {
        case .subnetTooWide, .subnetNarrowed, .multicastUnavailable, .budgetExhausted,
             .sadpDegradedEphemeralPort, .onvifDegradedEphemeralPort, .identityConflict:
            .warning
        case .localNetworkPermissionLikelyDenied, .offSubnetDeviceSeen:
            .actionRequired
        case .sadpOpaquePayload, .sadpFlood, .nonUTF8SADPPayload, .foreignDiscoveryClientActive,
             .concurrencyClamped, .tunnelInterfaceSkipped:
            .info
        }
    }

    /// Text for a user, or `nil` for purely technical findings that only belong in a support log.
    /// Concrete numbers are included deliberately: "Vigil scanned 3 likely ranges" is actionable in
    /// a way that "the network is large" is not.
    public var userFacingMessage: String? {
        switch self {
        case let .subnetTooWide(subnet, hostCount):
            "Your network \(subnet) has \(hostCount) addresses — too many to scan safely. "
                + "Enter a camera's address directly, or scan a smaller range."
        case let .subnetNarrowed(from, to):
            "Your network is large (\(from)). Vigil scanned \(to.count) likely "
                + "\(to.count == 1 ? "range" : "ranges") instead of every address."
        case let .multicastUnavailable(reason):
            "Vigil is checking each address individually (\(reason.rawValue)). This is slower and "
                + "won't find cameras on a different subnet."
        case let .localNetworkPermissionLikelyDenied(interface, _):
            "Nothing on \(interface) answered. macOS may be blocking Vigil's access to your local "
                + "network — check Privacy & Security ▸ Local Network."
        case let .offSubnetDeviceSeen(address, subnets):
            "A device answered from \(address), which is not on your network "
                + "(\(subnets.map(\.description).joined(separator: ", "))). Change its address, or "
                + "connect this Mac to the same network, before adding it."
        case let .budgetExhausted(kind, limit):
            "Vigil stopped early after \(limit) \(kind.rawValue) to stay gentle on your network. "
                + "Results found so far are shown."
        case let .identityConflict(address, macA, macB):
            "Two devices claimed \(address) (\(macA) and \(macB)). Both are listed separately."
        case .sadpDegradedEphemeralPort, .onvifDegradedEphemeralPort:
            "Another app is using the camera-discovery port, so some cameras may not answer."
        case .sadpOpaquePayload, .sadpFlood, .nonUTF8SADPPayload, .foreignDiscoveryClientActive,
             .concurrencyClamped, .tunnelInterfaceSkipped:
            nil
        }
    }
}

// MARK: - Entitlement status

/// What we know about our own ability to use multicast and the local network.
///
/// Both halves matter and neither is sufficient alone: the entitlement can be present in the
/// signature while macOS still refuses the traffic, and on macOS 14 an unentitled build often works.
/// So the static answer is a hint and the empirical one is authoritative (§9.3).
public struct EntitlementStatus: Sendable, Hashable, Codable {

    /// From our own code signature: is `com.apple.developer.networking.multicast` present?
    public var multicastEntitlementPresent: Bool
    /// Empirical: did a multicast channel actually start and send? `nil` until one resolves.
    public var multicastVerifiedWorking: Bool?
    /// What the local-network permission appears to be, from observed behaviour.
    public var localNetworkPermission: LocalNetworkPermission

    public init(multicastEntitlementPresent: Bool = false,
                multicastVerifiedWorking: Bool? = nil,
                localNetworkPermission: LocalNetworkPermission = .unknown) {
        self.multicastEntitlementPresent = multicastEntitlementPresent
        self.multicastVerifiedWorking = multicastVerifiedWorking
        self.localNetworkPermission = localNetworkPermission
    }

    /// True when multicast should be attempted at all: the entitlement is present and nothing has
    /// yet proved it does not work.
    public var shouldAttemptMulticast: Bool {
        multicastEntitlementPresent && multicastVerifiedWorking != false
    }

    /// Nothing known yet — the state every run starts in.
    public static let unknown = EntitlementStatus()
}

/// What the macOS Local Network permission appears to be, inferred from behaviour rather than asked
/// for: there is no API that reports it.
public enum LocalNetworkPermission: String, Sendable, Hashable, Codable {
    /// Not yet exercised.
    case unknown
    /// At least one inbound datagram arrived or one LAN handshake completed.
    case granted
    /// The §9.4 heuristic tripped: a populated subnet in which absolutely nothing answered.
    case likelyDenied
}
