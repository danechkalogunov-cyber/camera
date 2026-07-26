//
//  VendorClassifier.swift
//  VigilDiscovery
//
//  The evidence table that turns fingerprints, scopes, open ports and an OUI into a vendor, a device
//  class and a confidence delta — including the answer that matters most to a user: "found, but not
//  Hikvision".
//  Implements docs/spec-discovery.md §6.8 and §6.9. Pure and table-driven.
//

import VigilProtocols

// MARK: - Evidence

/// Everything known about one candidate device at the moment of classification.
///
/// A value type on purpose: the classifier is a function of its input with no memory, so the same
/// evidence always produces the same verdict and a disagreement between two runs is always a
/// difference in evidence.
public struct ClassificationEvidence: Sendable, Hashable {

    /// A SADP ProbeMatch was parsed for this device. The strongest single signal there is.
    public var hasSADPProbeMatch: Bool
    /// SADP's `OEMinfo`, when non-empty: the device is a rebadge and ISAPI still applies.
    public var sadpOEMInfo: String?
    /// SADP's `DeviceDescription` / `DeviceType`, used for the device class.
    public var deviceDescription: String?
    /// The RTSP `OPTIONS` fingerprint, if one ran.
    public var rtsp: RTSPFingerprint?
    /// The HTTP fingerprint, if one ran.
    public var http: HTTPFingerprint?
    /// ONVIF scopes from a WS-Discovery ProbeMatch.
    public var onvifScopes: ONVIFScopes?
    /// True when a WS-Discovery ProbeMatch was seen at all, scopes or not.
    public var hasONVIFProbeMatch: Bool
    /// Ports observed open.
    public var openPorts: Set<UInt16>
    /// Bonjour service types this host advertised, e.g. `_axis-video._tcp`.
    public var bonjourTypes: [String]
    /// A MAC, used only for the OUI hint.
    public var mac: MACAddress?
    /// The vendor already recorded. The OUI hint is consulted **only** when this is `.unknown`, and
    /// a verdict never regresses a specific vendor back to a generic one.
    public var currentVendor: DeviceVendor

    public init(hasSADPProbeMatch: Bool = false, sadpOEMInfo: String? = nil,
                deviceDescription: String? = nil, rtsp: RTSPFingerprint? = nil,
                http: HTTPFingerprint? = nil, onvifScopes: ONVIFScopes? = nil,
                hasONVIFProbeMatch: Bool = false, openPorts: Set<UInt16> = [],
                bonjourTypes: [String] = [], mac: MACAddress? = nil,
                currentVendor: DeviceVendor = .unknown) {
        self.hasSADPProbeMatch = hasSADPProbeMatch
        self.sadpOEMInfo = sadpOEMInfo
        self.deviceDescription = deviceDescription
        self.rtsp = rtsp
        self.http = http
        self.onvifScopes = onvifScopes
        self.hasONVIFProbeMatch = hasONVIFProbeMatch
        self.openPorts = openPorts
        self.bonjourTypes = bonjourTypes
        self.mac = mac
        self.currentVendor = currentVendor
    }
}

/// The classifier's answer.
public struct ClassificationVerdict: Sendable, Hashable {
    public var vendor: DeviceVendor
    public var deviceClass: DeviceClass
    /// How much this verdict adds to the record's confidence (§7.6). The winner among conflicting
    /// verdicts is the one with the highest delta.
    public var confidenceDelta: Int

    public init(vendor: DeviceVendor, deviceClass: DeviceClass = .unknown,
                confidenceDelta: Int = 0) {
        self.vendor = vendor
        self.deviceClass = deviceClass
        self.confidenceDelta = confidenceDelta
    }

    /// Nothing concluded.
    public static let inconclusive = ClassificationVerdict(vendor: .unknown, confidenceDelta: 0)
}

// MARK: - Classifier

/// Applies the §6.8 evidence table.
///
/// Conflicts resolve by highest delta; a tie keeps the earlier verdict, and the table is written in
/// descending-trust order so "earlier" means "from the more trustworthy source". A specific vendor
/// is never replaced by a generic one — `.unknown` after `.hikvision` is a no-op, because forgetting
/// what we knew is strictly worse than keeping it.
public enum VendorClassifier {

    /// Classifies one device's evidence.
    public static func classify(_ evidence: ClassificationEvidence) -> ClassificationVerdict {
        var candidates: [ClassificationVerdict] = []

        if evidence.hasSADPProbeMatch {
            let isOEM = !(evidence.sadpOEMInfo?.isEmpty ?? true)
            candidates.append(ClassificationVerdict(vendor: isOEM ? .hikvisionOEM : .hikvision,
                                                    confidenceDelta: 45))
        }
        if let http = evidence.http, http.isapiPathPresent {
            let hikServer = http.serverHeader.map(FingerprintCodec.vendorForServerHeader)
                == .hikvision
            candidates.append(ClassificationVerdict(vendor: hikServer ? .hikvision : .hikvisionOEM,
                                                    confidenceDelta: hikServer ? 35 : 25))
        }
        if evidence.openPorts.contains(37_777) {
            candidates.append(ClassificationVerdict(vendor: .dahua, confidenceDelta: 30))
        }
        if evidence.bonjourTypes.contains(where: { $0.contains("axis-video") }) {
            candidates.append(ClassificationVerdict(vendor: .axis, confidenceDelta: 30))
        }
        if let rtsp = evidence.rtsp, let realm = rtsp.realm {
            let vendor = FingerprintCodec.vendorForRealm(realm)
            if vendor.isSpecific {
                // Axis realms carry a MAC and are far harder to fake by accident than a generic
                // Hikvision-shaped realm, so they score with the port-level evidence.
                candidates.append(ClassificationVerdict(vendor: vendor,
                                                        confidenceDelta: vendor == .axis ? 30 : 20))
            }
        }
        if let scopes = evidence.onvifScopes {
            let text = [scopes.name, scopes.hardware].compactMap { $0 }.joined(separator: " ")
            if let vendor = vendorFromONVIFText(text) {
                candidates.append(ClassificationVerdict(vendor: vendor, confidenceDelta: 20))
            }
        }
        if let server = evidence.http?.serverHeader {
            let vendor = FingerprintCodec.vendorForServerHeader(server)
            if vendor.isSpecific {
                candidates.append(ClassificationVerdict(vendor: vendor, confidenceDelta: 20))
            }
        }
        if evidence.hasONVIFProbeMatch {
            candidates.append(ClassificationVerdict(vendor: .genericONVIF, confidenceDelta: 15))
        }
        if evidence.rtsp?.isRTSP == true {
            candidates.append(ClassificationVerdict(vendor: .genericRTSP, confidenceDelta: 10))
        }
        // OUI is a hint: consulted only when nothing else named a vendor (§6.9).
        if !evidence.currentVendor.isSpecific,
           !candidates.contains(where: { $0.vendor.isSpecific }),
           let mac = evidence.mac, let vendor = vendorForOUI(mac) {
            candidates.append(ClassificationVerdict(vendor: vendor, confidenceDelta: 10))
        }
        if !evidence.openPorts.isEmpty {
            candidates.append(ClassificationVerdict(vendor: .unknown, confidenceDelta: 5))
        }

        let deviceClass = classifyDeviceClass(evidence)
        guard var best = candidates.max(by: { $0.confidenceDelta < $1.confidenceDelta }) else {
            return ClassificationVerdict(vendor: evidence.currentVendor, deviceClass: deviceClass,
                                         confidenceDelta: 0)
        }
        // `max(by:)` keeps the last maximal element; the table is trust-ordered, so re-scan for the
        // first one instead — a tie must keep the earlier, more trusted verdict.
        if let first = candidates.first(where: { $0.confidenceDelta == best.confidenceDelta }) {
            best = first
        }
        // Never regress a specific vendor to a generic one.
        if evidence.currentVendor.isSpecific, !best.vendor.isSpecific {
            best.vendor = evidence.currentVendor
        }
        best.deviceClass = deviceClass
        return best
    }

    /// Folds a new verdict into an existing one with the same arbitration rules, for the merge
    /// engine: the higher delta wins, ties keep `existing`, and a specific vendor or a more specific
    /// device class is never lost.
    public static func combine(existing: ClassificationVerdict,
                               incoming: ClassificationVerdict) -> ClassificationVerdict {
        var result = incoming.confidenceDelta > existing.confidenceDelta ? incoming : existing
        if existing.vendor.isSpecific, !result.vendor.isSpecific { result.vendor = existing.vendor }
        if incoming.vendor.isSpecific, !result.vendor.isSpecific { result.vendor = incoming.vendor }
        result.confidenceDelta = max(existing.confidenceDelta, incoming.confidenceDelta)
        if existing.deviceClass.specificity > result.deviceClass.specificity {
            result.deviceClass = existing.deviceClass
        }
        if incoming.deviceClass.specificity > result.deviceClass.specificity {
            result.deviceClass = incoming.deviceClass
        }
        return result
    }

    // MARK: Device class

    /// Infers what kind of box this is from a SADP device description and ONVIF scopes.
    /// Unrecognised text yields `.unknown`, which never overwrites a known class (§7.3).
    static func classifyDeviceClass(_ evidence: ClassificationEvidence) -> DeviceClass {
        var result = DeviceClass.unknown
        if let description = evidence.deviceDescription?.uppercased() {
            if description.contains("NVR") { result = .nvr }
            else if description.contains("DVR") { result = .dvr }
            else if description.contains("DOORBELL") || description.contains("DOOR STATION") {
                result = .doorbell
            } else if description.contains("ENCODER") { result = .encoder }
            else if description.contains("DECODER") { result = .decoder }
            else if description.contains("ACCESS") { result = .accessControl }
            else if description.contains("PTZ") || description.contains("SPEED DOME") {
                result = .ptzCamera
            } else if description.contains("CAMERA") || description.contains("IPC") {
                result = .camera
            }
        }
        if let scopes = evidence.onvifScopes {
            if scopes.indicatesPTZ {
                result = .ptzCamera
            } else if result.specificity == 0,
                      scopes.types.contains(where: { $0.contains("Network_Video_Transmitter") }) {
                result = .camera
            }
        }
        return result
    }

    // MARK: ONVIF text

    /// Vendor inference from ONVIF `name`/`hardware` text (§5.7).
    static func vendorFromONVIFText(_ text: String) -> DeviceVendor? {
        let upper = text.uppercased()
        guard !upper.isEmpty else { return nil }
        if upper.contains("HIKVISION") { return .hikvision }
        for prefix in ["HWI-", "HWN-"] where containsToken(upper, prefix) { return .hikvisionOEM }
        for prefix in ["DS-", "IDS-"] where containsToken(upper, prefix) { return .hikvision }
        if upper.contains("DAHUA") { return .dahua }
        for prefix in ["IPC-", "DH-", "SD5", "SD6", "NVR4"] where containsToken(upper, prefix) {
            return .dahua
        }
        if upper.contains("AXIS") { return .axis }
        if upper.contains("REOLINK") { return .reolink }
        if upper.contains("UBIQUITI") || upper.contains("UNIFI") { return .unifi }
        return nil
    }

    /// True when `token` starts the text or starts a whitespace-delimited word inside it — an
    /// anchored match, so a model number that merely *contains* `DS-` does not count.
    private static func containsToken(_ text: String, _ token: String) -> Bool {
        if text.hasPrefix(token) { return true }
        return text.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .contains { $0.hasPrefix(token) }
    }

    // MARK: OUI

    /// Widely-observed OUI assignments, keyed by the lowercase 6-hex-digit OUI (§6.9).
    ///
    /// Embedded rather than loaded from `Resources/oui-seed.json`: the `VigilDiscovery` target
    /// declares no resources, and a table of fifteen entries is not worth a `Bundle.module`
    /// dependency that fails silently when a build system forgets to copy it. Hint-only, weight 10,
    /// consulted only when nothing else named a vendor.
    public static let ouiTable: [String: DeviceVendor] = [
        "4419b6": .hikvision, "c42f90": .hikvision, "bcad28": .hikvision, "4cbd8f": .hikvision,
        "2857be": .hikvision, "54c415": .hikvision, "a41437": .hikvision,
        "3cef8c": .dahua, "4c11bf": .dahua, "9002a9": .dahua, "e0508b": .dahua,
        "00408c": .axis, "accc8e": .axis, "b8a44f": .axis,
        "ec71db": .reolink,
        "788a20": .unifi, "f09fc2": .unifi, "74acb9": .unifi,
    ]

    /// The vendor for a MAC's OUI, or `nil` when it is not in the table. Locally-administered and
    /// multicast addresses never match: their OUI is meaningless.
    public static func vendorForOUI(_ mac: MACAddress) -> DeviceVendor? {
        guard mac.isUsableIdentity, !mac.isLocallyAdministered else { return nil }
        return ouiTable[mac.ouiHex.lowercased()]
    }
}
