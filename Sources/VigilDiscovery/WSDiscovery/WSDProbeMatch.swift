//
//  WSDProbeMatch.swift
//  VigilDiscovery
//
//  One ONVIF WS-Discovery `ProbeMatch`: endpoint reference, types, scopes and service URLs, plus the
//  hints those support — device class, vendor, and the MAC some firmware buries in its endpoint UUID.
//  See docs/spec-discovery.md §5.5, §5.6, §5.7 and docs/API_CONTRACT.md §4.6.
//

import Foundation
import VigilProtocols

/// A single `ProbeMatch` (or `Hello`) element decoded from a WS-Discovery datagram.
///
/// Everything here is what the device volunteered in one UDP packet. Discovery issues **no** further
/// ONVIF call — no `GetDeviceInformation`, no `GetCapabilities` — because those need WS-UsernameToken
/// authentication and would risk the account lockout that §6.10 exists to prevent. The `xAddrs` are
/// recorded verbatim so a future ONVIF module has them.
public struct WSDProbeMatch: Sendable, Hashable, Codable {

    /// `EndpointReference/Address`, e.g. `urn:uuid:2419d68a-2dd2-21b2-a205-c42f90abcdef`. The
    /// stable per-device identifier ONVIF guarantees, and the primary dedupe key.
    public let endpointAddress: String?

    /// `Types`, whitespace-split with any `prefix:` stripped, e.g. `["NetworkVideoTransmitter",
    /// "Device"]`.
    public let types: [String]

    /// `Scopes`, percent-decoded and interpreted (§5.6).
    public let scopes: ONVIFScopes

    /// `XAddrs`, whitespace-split, order preserved. These are device service URLs, not stream URLs.
    public let xAddrs: [String]

    /// `MetadataVersion`. A device bumps it when its configuration changes.
    public let metadataVersion: Int?

    /// `Header/RelatesTo`, verbatim. `nil` on `Hello` and on the firmware that omits it.
    public let relatesTo: String?

    /// `Header/MessageID` of this response, verbatim.
    public let messageID: String?

    /// `Header/AppSequence@InstanceId`. Changes when the device reboots.
    public let appSequenceInstanceID: String?

    /// UDP source address of the datagram — arbitrary source **port**, which is why nothing may be
    /// filtered by port (§5.1); the address is still the device's.
    public let observedFrom: IPv4Address

    /// Arrival time, from the injected clock.
    public let receivedAt: Date

    /// True when `relatesTo` matched one of this run's probe `MessageID`s.
    ///
    /// Not part of the wire format. An uncorrelated match is still ingested — plenty of firmware
    /// omits `RelatesTo`, and `Hello` never has one — but carries
    /// `WSDiscoveryCodec.uncorrelatedConfidencePenalty` (§5.5).
    public let isCorrelated: Bool

    /// Creates a match. Used by the decoder and by tests that drive the merge engine directly.
    public init(endpointAddress: String?, types: [String], scopes: ONVIFScopes, xAddrs: [String],
                metadataVersion: Int?, relatesTo: String?, messageID: String?,
                appSequenceInstanceID: String?, observedFrom: IPv4Address, receivedAt: Date,
                isCorrelated: Bool) {
        self.endpointAddress = endpointAddress
        self.types = types
        self.scopes = scopes
        self.xAddrs = xAddrs
        self.metadataVersion = metadataVersion
        self.relatesTo = relatesTo
        self.messageID = messageID
        self.appSequenceInstanceID = appSequenceInstanceID
        self.observedFrom = observedFrom
        self.receivedAt = receivedAt
        self.isCorrelated = isCorrelated
    }

    // MARK: - Derived

    /// The key a run dedupes on: the lowercased endpoint address when present, else the first
    /// `XAddr`, else the source address. A repeat updates `lastSeen` instead of adding a row (§5.5).
    public var dedupeKey: String {
        if let endpointAddress, !endpointAddress.isEmpty { return endpointAddress.lowercased() }
        if let first = xAddrs.first, !first.isEmpty { return "xaddr:" + first.lowercased() }
        return "source:\(observedFrom)"
    }

    /// The device class implied by `Types` and the PTZ scope hints (§5.5, §5.6).
    public var deviceClass: DeviceClass {
        let lowered = types.map { $0.lowercased() }
        if lowered.contains(where: { $0.contains("networkvideostorage") || $0.contains("recording") }) {
            return .nvr
        }
        if lowered.contains(where: { $0.contains("networkvideodisplay") }) { return .decoder }
        if lowered.contains(where: { $0.contains("networkvideotransmitter") }) {
            return scopes.indicatesPTZ ? .ptzCamera : .camera
        }
        return scopes.indicatesPTZ ? .ptzCamera : .unknown
    }

    /// The vendor ONVIF alone supports, by the §5.7 table.
    ///
    /// Only the name and hardware scopes are evidence here; a later ISAPI fingerprint may upgrade a
    /// `genericONVIF` to a Hikvision family member, and the merge engine's trust ordering decides.
    /// `HWI-`/`HWN-` are HiLook, which is Hikvision's own OEM line and keeps the ISAPI surface.
    public var inferredVendor: DeviceVendor {
        let text = [scopes.name, scopes.hardware].compactMap { $0 }.joined(separator: " ").uppercased()
        let hardware = (scopes.hardware ?? "").uppercased()
        guard !text.isEmpty else { return .genericONVIF }
        if hardware.hasPrefix("HWI-") || hardware.hasPrefix("HWN-") { return .hikvisionOEM }
        if text.contains("HIKVISION") || hardware.hasPrefix("IDS-")
            || Self.matchesModelPrefix(hardware, letters: "DS-") { return .hikvision }
        if text.contains("DAHUA") || hardware.hasPrefix("IPC-") || hardware.hasPrefix("DH-")
            || Self.matchesModelPrefix(hardware, letters: "SD")
            || Self.matchesModelPrefix(hardware, letters: "NVR") { return .dahua }
        if text.contains("AXIS") { return .axis }
        if text.contains("REOLINK") { return .reolink }
        if text.contains("UBIQUITI") || text.contains("UNIFI") { return .unifi }
        return .genericONVIF
    }

    /// A MAC recovered from the last twelve hex digits of the endpoint UUID — Hikvision and Dahua
    /// both embed it there — or `nil` when the UUID is not `8-4-4-4-12` hex or the digits do not
    /// form a usable unicast address.
    ///
    /// **A hint, never an identity** (§5.6). It may corroborate a MAC learned from SADP or ARP and
    /// may seed the vendor, but promoting it alone would merge two distinct cameras whose vendors
    /// happen to mint UUIDs the same way, and that error costs far more than the hint is worth. The
    /// specification additionally gates it on the OUI being in the vendor table; that check lives
    /// with the classifier, which owns the table, and applies on top of this shape check.
    public var endpointUUIDMACHint: MACAddress? {
        guard let endpointAddress else { return nil }
        var text = Substring(endpointAddress.lowercased())
        for prefix in ["urn:uuid:", "uuid:"] where text.hasPrefix(prefix) {
            text = text.dropFirst(prefix.count)
        }
        let groups = text.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5,
              groups.map(\.count) == [8, 4, 4, 4, 12],
              groups.allSatisfy({ $0.allSatisfy(\.isHexDigit) }),
              let mac = MACAddress(String(groups[4])), mac.isUsableIdentity else { return nil }
        return mac
    }

    /// The IPv4 hosts named by `XAddrs`, in order, ignoring IPv6 and unparseable URLs. The sweep
    /// uses these to probe a device that answered ONVIF from an address we had not planned.
    public var xAddrHosts: [IPv4Address] {
        var result: [IPv4Address] = []
        for url in xAddrs {
            guard let host = Self.host(ofURL: url), let address = IPv4Address(host) else { continue }
            if !result.contains(address) { result.append(address) }
        }
        return result
    }

    /// True when `hardware` starts with `letters` immediately followed by a digit — the shape of a
    /// model number like `DS-2CD…` or `SD5A…`, which a word such as "Dsomething" would not match.
    private static func matchesModelPrefix(_ hardware: String, letters: String) -> Bool {
        guard hardware.hasPrefix(letters) else { return false }
        let rest = hardware.dropFirst(letters.count)
        guard let first = rest.first else { return false }
        return first.isNumber
    }

    /// The host component of an absolute URL, without brackets, port or credentials. Returns `nil`
    /// for a bracketed IPv6 literal, which v1 never connects to.
    private static func host(ofURL url: String) -> String? {
        guard let schemeRange = url.range(of: "://") else { return nil }
        let authority = url[schemeRange.upperBound...].prefix { $0 != "/" }
        guard !authority.isEmpty, !authority.contains("[") else { return nil }
        let afterCredentials = authority.split(separator: "@").last ?? authority
        let host = afterCredentials.split(separator: ":").first ?? afterCredentials
        return host.isEmpty ? nil : String(host)
    }
}
