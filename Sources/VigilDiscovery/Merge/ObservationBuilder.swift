//
//  ObservationBuilder.swift
//  VigilDiscovery
//
//  Turns sweep and ARP results into `DeviceObservation`s, so the merge engine has exactly one input
//  shape whatever mechanism produced the evidence.
//  Implements docs/spec-discovery.md §6.5–§6.9 as they feed §7. Pure.
//

import Foundation
import VigilProtocols

/// Builds observations from the sweep's raw results.
///
/// The split into one observation per source is deliberate: field precedence is by source trust, so
/// the RTSP realm and the ISAPI `Server` header must arrive stamped separately even though they came
/// from the same host in the same second.
public enum ObservationBuilder {

    /// Ports we prefer as "the" HTTP port, in order. The provisional identity is `ip:httpPort`, so
    /// this order decides which endpoint key a bare sweep hit produces.
    static let httpPortPreference: [UInt16] = [80, 8_080, 443, 8_000]

    /// Every observation a probed host yields: one for the connect results, one per fingerprint.
    ///
    /// A host that answered nothing at all yields no observations — a timeout is not evidence of a
    /// device, and creating a record for one would fill the list with the whole subnet.
    public static func observations(from result: HostProbeResult,
                                    observedAt: Date) -> [DeviceObservation] {
        guard result.isAlive else { return [] }
        var observations: [DeviceObservation] = []
        let open = result.openPorts
        let httpPort = httpPortPreference.first(where: open.contains) ?? 80
        let rtspPort: UInt16 = open.contains(554) ? 554 : (open.contains(8_554) ? 8_554 : 554)

        var sweepFields: [DeviceFieldKey: FieldValue] = [
            .openPorts: .ports(open),
            .httpPort: .port(httpPort),
            .rtspPort: .port(rtspPort),
        ]
        if open.contains(443) { sweepFields[.httpsPort] = .port(443) }
        if open.contains(8_000) { sweepFields[.commandPort] = .port(8_000) }
        observations.append(DeviceObservation(
            source: .tcpSweep, observedAt: observedAt, address: result.address,
            fields: sweepFields,
            verdict: VendorClassifier.classify(evidence(from: result))))

        if let rtsp = result.rtsp, rtsp.isRTSP {
            var fields: [DeviceFieldKey: FieldValue] = [:]
            if let realm = rtsp.realm { fields[.rtspRealm] = .string(realm) }
            if rtsp.vendor != .unknown { fields[.vendor] = .vendor(rtsp.vendor) }
            observations.append(DeviceObservation(
                source: .rtspFingerprint, observedAt: observedAt, address: result.address,
                // An AXIS_<hex12> realm carries the device's MAC, but a realm is trivially forged:
                // it corroborates, it never identifies.
                mac: rtsp.macHint, macIsHintOnly: rtsp.macHint != nil,
                fields: fields,
                verdict: VendorClassifier.classify(evidence(from: result))))
        }

        if let http = result.http {
            var fields: [DeviceFieldKey: FieldValue] = [:]
            if let server = http.serverHeader { fields[.httpServerHeader] = .string(server) }
            if http.vendor != .unknown { fields[.vendor] = .vendor(http.vendor) }
            if http.notActivated { fields[.activation] = .activation(.notActivated) }
            var mac: MACAddress?
            if let inline = http.inlineDeviceInfo {
                if let model = inline.model { fields[.model] = .string(model) }
                if let firmware = inline.firmwareVersion {
                    fields[.firmwareVersion] = .string(firmware)
                }
                mac = inline.macAddress
            }
            // A 200 that carried <DeviceInfo> also carried an authoritative serial and MAC.
            observations.append(DeviceObservation(
                source: .isapiFingerprint, observedAt: observedAt, address: result.address,
                mac: mac, macIsHintOnly: false,
                serialNumber: http.inlineDeviceInfo?.serialNumber,
                fields: fields,
                verdict: VendorClassifier.classify(evidence(from: result))))
        }
        return observations
    }

    /// Assembles the classifier's evidence from one host's probe results.
    public static func evidence(from result: HostProbeResult,
                                currentVendor: DeviceVendor = .unknown,
                                bonjourTypes: [String] = [],
                                mac: MACAddress? = nil) -> ClassificationEvidence {
        ClassificationEvidence(rtsp: result.rtsp, http: result.http,
                               openPorts: Set(result.portOutcomes.keys.filter {
                                   result.portOutcomes[$0] == .open
                               }),
                               bonjourTypes: bonjourTypes, mac: mac,
                               currentVendor: currentVendor)
    }

    /// An ARP entry as an observation: an address and a MAC, and nothing else.
    ///
    /// Returns `nil` for an incomplete or unusable entry — a probed-but-unresolved row proves an
    /// address is in use but must never become an identity (§6.3). `plannedSubnets`, when non-empty,
    /// restricts entries to addresses this run actually planned, so the router's neighbour on
    /// another network cannot attach its MAC to one of our records.
    public static func observation(from entry: ARPEntry, observedAt: Date,
                                   plannedSubnets: [IPv4Subnet] = []) -> DeviceObservation? {
        guard entry.isUsableIdentity else { return nil }
        if !plannedSubnets.isEmpty,
           !plannedSubnets.contains(where: { $0.contains(entry.address) }) {
            return nil
        }
        return DeviceObservation(source: .arpCache, observedAt: observedAt, address: entry.address,
                                 mac: entry.mac, macIsHintOnly: false)
    }
}
