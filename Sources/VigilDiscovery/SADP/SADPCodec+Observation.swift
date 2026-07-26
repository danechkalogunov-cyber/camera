//
//  SADPCodec+Observation.swift
//  VigilDiscovery
//
//  Projection of a decoded SADP ProbeMatch into the neutral `DeviceObservation` the merge engine
//  folds, and the per-run ingest limiter that keeps a datagram storm bounded.
//  See docs/spec-discovery.md §4.5.5, §7 and docs/API_CONTRACT.md §4.6.
//

import Foundation
import VigilProtocols

extension SADPCodec {

    /// Projects a `ProbeMatch` into a source-neutral observation.
    ///
    /// Only fields the datagram actually carried are populated: an absent key means "this source has
    /// no opinion", never "cleared". That distinction is what lets a later ONVIF sighting, which
    /// cannot see activation at all, avoid clearing a `notActivated` state the camera told us about
    /// (§7.3).
    ///
    /// The observation's address is the device's own `IPv4Address` when it sent one, falling back to
    /// the datagram's source. Those differ in exactly the case that matters: a factory camera on
    /// 192.168.1.64 reached over link-local multicast from another subnet (§4.7).
    ///
    /// - Parameters:
    ///   - match: the decoded datagram.
    ///   - source: `.sadpMulticast` or `.sadpUnicast`. The payload is identical either way and both
    ///     carry the same trust weight; only the provenance label differs (§4.9).
    ///   - isForeignProbeMatch: true when this answered another client's probe, which the merge
    ///     engine scores down as corroborating rather than solicited.
    ///   - bootTimeZone: the zone to interpret `BootTime` in, or `nil` to omit the field. The device
    ///     sends wall-clock digits with no zone, so the pure layer refuses to guess one (§4.5.4).
    public static func observation(from match: SADPProbeMatch,
                                   source: DiscoverySource,
                                   isForeignProbeMatch: Bool = false,
                                   bootTimeZone: TimeZone? = nil) -> DeviceObservation {
        let address = match.ipv4Address ?? match.observedFrom
        var fields: [DeviceFieldKey: FieldValue] = [:]
        fields[.address] = .ipv4(address)
        fields[.vendor] = .vendor(match.vendor)
        if match.deviceClass != .unknown { fields[.deviceClass] = .deviceClass(match.deviceClass) }
        if let value = match.httpPort { fields[.httpPort] = .port(value) }
        if let value = match.httpsPort { fields[.httpsPort] = .port(value) }
        if let value = match.rtspPort { fields[.rtspPort] = .port(value) }
        if let value = match.commandPort { fields[.commandPort] = .port(value) }
        if let value = match.mac { fields[.mac] = .mac(value) }
        if let value = match.deviceSN { fields[.serialNumber] = .string(value) }
        if let value = match.model { fields[.model] = .string(value) }
        if let value = match.normalizedFirmwareVersion { fields[.firmwareVersion] = .string(value) }
        if let value = match.dspVersion { fields[.dspVersion] = .string(value) }
        if let value = match.ipv4SubnetMask { fields[.subnetMask] = .ipv4(value) }
        if let value = match.ipv4Gateway { fields[.gateway] = .ipv4(value) }
        if let value = match.ipv6Address { fields[.ipv6Address] = .string(value) }
        if let value = match.dhcp { fields[.dhcpEnabled] = .bool(value) }
        if let value = match.analogChannelNum { fields[.analogChannelCount] = .int(value) }
        if let value = match.digitalChannelNum { fields[.digitalChannelCount] = .int(value) }
        if let value = match.passwordResetAbility { fields[.passwordResetAbility] = .bool(value) }
        if let value = match.supportHCPlatform { fields[.supportsHCPlatform] = .bool(value) }
        if match.activated != nil { fields[.activation] = .activation(match.activationState) }
        if let zone = bootTimeZone, let boot = match.bootTime(in: zone) {
            fields[.bootTime] = .date(boot)
        }

        return DeviceObservation(source: source,
                                 observedAt: match.receivedAt,
                                 address: address,
                                 mac: match.mac,
                                 macIsHintOnly: false,
                                 serialNumber: match.deviceSN,
                                 fields: fields,
                                 isForeignProbeMatch: isForeignProbeMatch)
    }

    /// The degraded observation built from a datagram we could not parse at all (§4.8.3).
    ///
    /// Something answered on port 37020, and only Hikvision-family devices talk there, so the record
    /// is emitted with the vendor known and everything else blank. The sweep and the ISAPI
    /// fingerprint then fill in ports, model and realm for that host — which is precisely why the
    /// sweep still runs when SADP "worked".
    public static func degradedObservation(from payload: SADPOpaquePayload,
                                           source: DiscoverySource,
                                           observedAt: Date) -> DeviceObservation {
        DeviceObservation(source: source,
                          observedAt: observedAt,
                          address: payload.source,
                          fields: [.address: .ipv4(payload.source),
                                   .vendor: .vendor(.hikvision)])
    }
}

// MARK: - Flood protection

/// Per-run admission control for SADP datagrams (§4.5.5).
///
/// A misbehaving device, or two other discovery tools arguing on the group, can put thousands of
/// datagrams on 37020 in a second. The limiter bounds both the total and the per-source share, so
/// ingest cost is capped no matter what the network does. It is a plain value with no clock: it
/// counts datagrams, not time, which makes the behaviour identical in a test and in the field.
public struct SADPIngestLimiter: Sendable, Hashable {

    /// Total datagrams admitted per run.
    public let runLimit: Int
    /// Datagrams admitted per source address per run.
    public let perSourceLimit: Int

    private var admittedTotal = 0
    private var admittedBySource: [IPv4Address: Int] = [:]
    private var droppedBySource: [IPv4Address: Int] = [:]

    /// Creates a limiter with the §4.5.5 caps, or tighter ones for a test.
    public init(runLimit: Int = SADPCodec.maxDatagramsPerRun,
                perSourceLimit: Int = SADPCodec.maxDatagramsPerSource) {
        self.runLimit = runLimit
        self.perSourceLimit = perSourceLimit
    }

    /// Records one datagram and reports whether it may be decoded.
    ///
    /// Dropping is counted per source so the caller can emit exactly one
    /// `DiscoveryDiagnostic.sadpFlood(from:dropped:)` per offender at the end of a phase rather than
    /// one per datagram — a flood diagnostic that itself floods is worse than none.
    public mutating func admit(from source: IPv4Address) -> Bool {
        let forSource = admittedBySource[source] ?? 0
        guard admittedTotal < runLimit, forSource < perSourceLimit else {
            droppedBySource[source, default: 0] += 1
            return false
        }
        admittedTotal += 1
        admittedBySource[source] = forSource + 1
        return true
    }

    /// Total datagrams admitted so far.
    public var admittedCount: Int { admittedTotal }

    /// How many datagrams from `source` were refused.
    public func droppedCount(from source: IPv4Address) -> Int { droppedBySource[source] ?? 0 }

    /// Every source that had at least one datagram refused, with its count, sorted by address so a
    /// diagnostic list is deterministic.
    public var floodedSources: [(source: IPv4Address, dropped: Int)] {
        droppedBySource.sorted { $0.key < $1.key }.map { (source: $0.key, dropped: $0.value) }
    }
}
