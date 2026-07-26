//
//  WSDiscoveryCodec+Observation.swift
//  VigilDiscovery
//
//  Projection of a WS-Discovery ProbeMatch into the neutral `DeviceObservation` the merge engine
//  folds, and the per-run dedupe set that keeps a device's three answers to three probes as one row.
//  See docs/spec-discovery.md §5.5, §5.6, §5.7 and docs/API_CONTRACT.md §4.6.
//

import Foundation
import VigilProtocols

extension WSDiscoveryCodec {

    /// Projects a `ProbeMatch` into a source-neutral observation.
    ///
    /// Two properties of this projection are load-bearing:
    ///
    /// * **Every MAC it carries is a hint.** Both the `MAC` scope and the endpoint-UUID tail are
    ///   advisory (§5.6), so `macIsHintOnly` is always true and the merge engine will never build a
    ///   `DeviceIdentity.mac` from this observation. A hint may still corroborate a MAC that SADP or
    ///   ARP supplied.
    /// * **The ONVIF UUID is a real identity**, rank 2 on the ladder, because a device's
    ///   `EndpointReference` is stable across reboots and address changes.
    ///
    /// The address is the datagram's source: an ONVIF answer arrives from the device itself, while
    /// `XAddrs` may name an address the device believes it has. `xAddrHosts` records the latter for
    /// the sweep.
    public static func observation(from match: WSDProbeMatch) -> DeviceObservation {
        var fields: [DeviceFieldKey: FieldValue] = [:]
        fields[.address] = .ipv4(match.observedFrom)
        fields[.vendor] = .vendor(match.inferredVendor)
        if match.deviceClass != .unknown { fields[.deviceClass] = .deviceClass(match.deviceClass) }
        if !match.xAddrs.isEmpty { fields[.onvifServiceURLs] = .strings(match.xAddrs) }
        if !match.scopes.isEmpty { fields[.onvifScopes] = .scopes(match.scopes) }
        if let name = match.scopes.name, !name.isEmpty { fields[.displayName] = .string(name) }
        if let hardware = match.scopes.hardware, !hardware.isEmpty {
            fields[.model] = .string(hardware)
        }

        return DeviceObservation(source: .wsDiscovery,
                                 observedAt: match.receivedAt,
                                 address: match.observedFrom,
                                 mac: match.scopes.macHint ?? match.endpointUUIDMACHint,
                                 macIsHintOnly: true,
                                 onvifUUID: match.endpointAddress,
                                 fields: fields)
    }
}

// MARK: - Dedupe

/// Per-run dedupe for WS-Discovery answers (§5.5).
///
/// Three probes go out per interface and a device answers all three, often multicasting a copy as
/// well; without dedupe a single camera would produce five events. The key is the endpoint
/// reference, falling back to the first `XAddr` and then to the source address, so a device that
/// omits its `EndpointReference` still collapses to one row rather than fanning out.
public struct WSDDedupeSet: Sendable, Hashable {

    private var seen: Set<String> = []

    /// Creates an empty set for one run.
    public init() {}

    /// Records a match and reports whether it is the first sighting of that device.
    ///
    /// A repeat returns `false`; the caller updates `lastSeen` rather than emitting a new device.
    public mutating func insert(_ match: WSDProbeMatch) -> Bool {
        seen.insert(match.dedupeKey).inserted
    }

    /// True when this device has already been seen in this run.
    public func contains(_ match: WSDProbeMatch) -> Bool { seen.contains(match.dedupeKey) }

    /// How many distinct devices have been recorded.
    public var count: Int { seen.count }
}
