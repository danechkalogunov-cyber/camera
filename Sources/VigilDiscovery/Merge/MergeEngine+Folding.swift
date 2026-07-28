//
//  MergeEngine+Folding.swift
//  VigilDiscovery
//
//  Folding one probe's fields into a merged record, and everything derived from the result.
//  Split from MergeEngine.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

import Foundation
import VigilProtocols

// MARK: - Field folding and derived state

/// ⚠️ Members are `internal`, not `private`: Swift scopes `private` to one file.
/// `Scripts/lint.py`'s `split-access` rule fails the build on any left behind.
extension MergeEngine {

    // MARK: - Field folding

    /// The precedence rule of §7.3: an empty field always fills, a more trusted source always wins,
    /// and an equally trusted one wins only if it is newer.
    static func shouldOverwrite(existing: FieldStamp?, incoming: FieldStamp) -> Bool {
        guard let existing else { return true }
        if incoming.source.trust > existing.source.trust { return true }
        if incoming.source.trust < existing.source.trust { return false }
        return incoming.observedAt > existing.observedAt
    }

    /// Applies an observation's fields to a record and returns the keys that actually changed.
    private mutating func apply(_ observation: DeviceObservation, to index: Int) -> Set<DeviceFieldKey> {
        var device = entries[index].device
        var changed: Set<DeviceFieldKey> = []
        let stamp = FieldStamp(source: observation.source, observedAt: observation.observedAt)

        // Identity-bearing values arrive outside `fields`; fold them through the same path so their
        // provenance is stamped like everything else.
        var fields = observation.fields
        if let mac = observation.mac, fields[.mac] == nil { fields[.mac] = .mac(mac) }
        if let serial = observation.serialNumber, fields[.serialNumber] == nil {
            fields[.serialNumber] = .string(serial)
        }
        if fields[.address] == nil { fields[.address] = .ipv4(observation.address) }

        // Iterate the key enum, not the dictionary, so the order is identical on every run.
        for key in DeviceFieldKey.allCases {
            guard let value = fields[key] else { continue }
            switch key {
            case .openPorts:
                guard case let .ports(ports) = value else { continue }
                let before = device.openPorts
                device.openPorts.formUnion(ports)
                if device.openPorts != before {
                    changed.insert(.openPorts)
                    device.provenance[.openPorts] = stamp
                }
            case .onvifServiceURLs:
                guard case let .strings(urls) = value else { continue }
                let merged = mergedURLs(device.onvifServiceURLs, urls)
                if merged != device.onvifServiceURLs {
                    device.onvifServiceURLs = merged
                    changed.insert(.onvifServiceURLs)
                    device.provenance[.onvifServiceURLs] = stamp
                }
            case .onvifScopes:
                guard case let .scopes(scopes) = value else { continue }
                var merged = device.onvifScopes ?? ONVIFScopes()
                merged.formUnion(scopes)
                if merged != device.onvifScopes {
                    device.onvifScopes = merged
                    changed.insert(.onvifScopes)
                    device.provenance[.onvifScopes] = stamp
                }
            case .activation:
                guard case let .activation(state) = value else { continue }
                if applyActivation(state, source: observation.source, to: &device) {
                    changed.insert(.activation)
                    device.provenance[.activation] = stamp
                }
            case .vendor, .deviceClass:
                continue        // arbitrated below, not by the generic rule
            case .mac:
                guard case let .mac(mac) = value else { continue }
                if applyMAC(mac, isHint: observation.macIsHintOnly, stamp: stamp, to: &device) {
                    changed.insert(.mac)
                }
            default:
                guard Self.shouldOverwrite(existing: device.provenance[key],
                                           incoming: stamp) else {
                    continue
                }
                let before = self.value(of: key, in: device)
                assign(value, key: key, to: &device, source: observation.source)
                // The stamp is recorded whether or not the value moved: it says "a source of this
                // trust has spoken about this field", which is what later precedence decisions need.
                device.provenance[key] = stamp
                if self.value(of: key, in: device) != before { changed.insert(key) }
            }
        }
        device.sources.insert(observation.source)
        device.lastSeen = max(device.lastSeen, observation.observedAt)
        device.firstSeen = min(device.firstSeen, observation.observedAt)
        entries[index].device = device

        // Vendor and class go through the classifier's arbitration, never the generic rule.
        if let verdict = verdict(from: observation) {
            let combined = VendorClassifier.combine(existing: entries[index].verdict,
                                                    incoming: verdict)
            if combined.vendor != entries[index].device.vendor, combined.vendor != .unknown {
                entries[index].device.vendor = combined.vendor
                entries[index].device.provenance[.vendor] = stamp
                changed.insert(.vendor)
            }
            if combined.deviceClass.specificity > entries[index].device.deviceClass.specificity {
                entries[index].device.deviceClass = combined.deviceClass
                entries[index].device.provenance[.deviceClass] = stamp
                changed.insert(.deviceClass)
            }
            entries[index].verdict = combined
        }
        if observation.isForeignProbeMatch { entries[index].isForeign = true }
        return changed
    }

    /// `.notActivated` is sticky within a run: only a newer SADP observation or a successful ISAPI
    /// read may clear it, and a source with no opinion never clears it (§7.3). Getting this wrong
    /// hides the one fact that makes a camera unusable.
    private func applyActivation(_ state: ActivationState, source: DiscoverySource,
                                 to device: inout DiscoveredDevice) -> Bool {
        guard state != .unknown else { return false }
        if device.activation == .notActivated, state != .notActivated {
            let mayClear = source == .sadpMulticast || source == .sadpUnicast
                || source == .isapiFingerprint || source == .manual
            guard mayClear else { return false }
        }
        guard device.activation != state else { return false }
        device.activation = state
        return true
    }

    /// A real MAC replaces a hint; a hint never replaces a real MAC, and never becomes an identity.
    private func applyMAC(_ mac: MACAddress, isHint: Bool, stamp: FieldStamp,
                          to device: inout DiscoveredDevice) -> Bool {
        if let existing = device.mac {
            if existing == mac {
                if device.macIsHintOnly, !isHint {
                    device.macIsHintOnly = false
                    device.provenance[.mac] = stamp
                    return true
                }
                return false
            }
            if device.macIsHintOnly, !isHint {
                device.mac = mac
                device.macIsHintOnly = false
                device.provenance[.mac] = stamp
                return true
            }
            guard !isHint,
                  Self.shouldOverwrite(existing: device.provenance[.mac], incoming: stamp) else {
                return false
            }
            device.mac = mac
            device.macIsHintOnly = false
            device.provenance[.mac] = stamp
            return true
        }
        device.mac = mac
        device.macIsHintOnly = isHint
        device.provenance[.mac] = stamp
        return true
    }

    /// The vendor verdict an observation implies: its own, if the mechanism ran the classifier, else
    /// one derived from the source and any vendor field it carried.
    private func verdict(from observation: DeviceObservation) -> ClassificationVerdict? {
        if let verdict = observation.verdict { return verdict }
        var vendor = DeviceVendor.unknown
        if case let .vendor(value) = observation.fields[.vendor] { vendor = value }
        var deviceClass = DeviceClass.unknown
        if case let .deviceClass(value) = observation.fields[.deviceClass] { deviceClass = value }
        guard vendor != .unknown || deviceClass != .unknown else { return nil }
        return ClassificationVerdict(vendor: vendor, deviceClass: deviceClass,
                                     confidenceDelta: defaultDelta(for: observation.source,
                                                                   vendor: vendor))
    }

    /// Confidence weight for a vendor claim from a source that did not run the classifier itself.
    /// The numbers mirror the §6.8 table so a hand-built observation scores like a real one.
    private func defaultDelta(for source: DiscoverySource, vendor: DeviceVendor) -> Int {
        guard vendor != .unknown else { return 0 }
        switch source {
        case .sadpMulticast, .sadpUnicast: return 45
        case .manual: return 40
        case .isapiFingerprint: return 35
        case .rtspFingerprint: return 20
        case .wsDiscovery: return vendor.isSpecific ? 20 : 15
        case .bonjour: return vendor == .axis ? 30 : 10
        case .tcpSweep: return vendor == .dahua ? 30 : 5
        case .arpCache, .persisted: return 10
        }
    }

    // MARK: - Derived state

    /// Promotes the record's `id` to the strongest identity bound to it, and keeps every other
    /// identity as an alternate. This is the rung-climbing of §7.1: `endpoint` → `serial` → `mac`.
    private mutating func promoteIdentity(of index: Int) {
        var device = entries[index].device
        var candidates = device.alternateIdentities
        candidates.insert(device.id)
        if let mac = device.mac, !device.macIsHintOnly, mac.isUsableIdentity {
            candidates.insert(.mac(mac))
        }
        if let serial = device.serialNumber.flatMap(IdentityNormalizer.serialKey) {
            candidates.insert(.serial(serial))
        }
        let strongest = candidates.max { lhs, rhs in
            if lhs.strength != rhs.strength { return lhs.strength < rhs.strength }
            return lhs.description > rhs.description      // stable tie-break
        }
        if let strongest { device.id = strongest }
        candidates.remove(device.id)
        device.alternateIdentities = candidates
        entries[index].device = device
    }

    /// Recomputes reachability from the plan. Returns true when it changed.
    private mutating func updateReachability(of index: Int) -> Bool {
        guard !plannedSubnets.isEmpty else { return false }
        let device = entries[index].device
        let resolved: Reachability
        if !plannedSubnets.contains(where: { $0.contains(device.address) }) {
            resolved = .offSubnet
        } else if !device.openPorts.isEmpty {
            resolved = .reachable
        } else {
            resolved = .addressableNoPorts
        }
        guard resolved != device.reachability else { return false }
        entries[index].device.reachability = resolved
        return true
    }

    /// Recomputes the confidence score from scratch (§7.6). Never merged, always derived, so two
    /// runs that saw the same evidence agree on the number.
    private mutating func rescore(_ index: Int) {
        let entry = entries[index]
        let device = entry.device
        var score = max(0, entry.verdict.confidenceDelta)
        if let mac = device.mac, !device.macIsHintOnly, mac.isUsableIdentity { score += 15 }
        if device.serialNumber != nil { score += 10 }
        if device.model != nil { score += 10 }
        score += min(15, max(0, device.sources.count - 1) * 5)
        if device.openPorts.contains(554) { score += 10 }
        if device.sources.allSatisfy(\.isExistenceOnly), !device.sources.isEmpty { score -= 5 }
        if entry.isForeign { score -= 10 }
        entries[index].device.confidence = min(100, max(0, score))
    }

    // MARK: - Known-device events (§7.4)

    /// Compares a record against every saved camera and emits the address events.
    ///
    /// A match by MAC or serial at a different address is `.addressChanged`: one row, the user's own
    /// camera name, an "Update" action. A **different** device at a saved address is
    /// `.addressReused`: the new device is listed as new and the saved camera is left pointing where
    /// it was. Each is emitted at most once per record, snapshot and address pair.
    private mutating func knownDeviceEvents(for index: Int) -> [DiscoveryEvent] {
        guard !knownDevices.isEmpty else { return [] }
        let device = entries[index].device
        var events: [DiscoveryEvent] = []

        for snapshot in knownDevices {
            let sameDevice = matches(device, snapshot)
            if sameDevice {
                guard device.address != snapshot.lastKnownAddress else { continue }
                let signature = "changed|\(snapshot.identity.key)|\(snapshot.lastKnownAddress)"
                    + "|\(device.address)"
                guard emittedAddressEvents.insert(signature).inserted else { continue }
                events.append(.addressChanged(device.id, from: snapshot.lastKnownAddress,
                                              to: device.address))
            } else if device.address == snapshot.lastKnownAddress, differs(device, snapshot) {
                let signature = "reused|\(snapshot.identity.key)|\(device.id.key)"
                guard emittedAddressEvents.insert(signature).inserted else { continue }
                events.append(.addressReused(device.address, previous: snapshot.identity,
                                             now: device.id))
            }
        }
        return events
    }

    /// True when the record is the saved camera: same non-hint MAC, or same normalised serial.
    private func matches(_ device: DiscoveredDevice, _ snapshot: KnownDeviceSnapshot) -> Bool {
        if let recordMAC = device.mac, !device.macIsHintOnly, let savedMAC = snapshot.mac,
           recordMAC == savedMAC {
            return true
        }
        if let recordSerial = device.serialNumber.flatMap(IdentityNormalizer.serialKey),
           let savedSerial = snapshot.serialKey, recordSerial == savedSerial {
            return true
        }
        // The saved identity itself may be the only thing stored.
        return device.id == snapshot.identity || device.alternateIdentities.contains(snapshot.identity)
    }

    /// True when we can positively say this is a **different** device from the saved one, rather
    /// than merely lacking evidence. Only a hard identity counts: without one we say nothing, since
    /// claiming reuse on a guess would mark a working camera as missing.
    private func differs(_ device: DiscoveredDevice, _ snapshot: KnownDeviceSnapshot) -> Bool {
        if let recordMAC = device.mac, !device.macIsHintOnly, let savedMAC = snapshot.mac {
            return recordMAC != savedMAC
        }
        if let recordSerial = device.serialNumber.flatMap(IdentityNormalizer.serialKey),
           let savedSerial = snapshot.serialKey {
            return recordSerial != savedSerial
        }
        return false
    }

    // MARK: - Field access

    /// Reads a field out of a record as a `FieldValue`, for change detection and for absorbing.
    private func value(of key: DeviceFieldKey, in device: DiscoveredDevice) -> FieldValue? {
        switch key {
        case .address: .ipv4(device.address)
        case .httpPort: .port(device.httpPort)
        case .httpsPort: device.httpsPort.map { .port($0) }
        case .rtspPort: .port(device.rtspPort)
        case .commandPort: device.commandPort.map { .port($0) }
        case .mac: device.mac.map { .mac($0) }
        case .serialNumber: device.serialNumber.map { .string($0) }
        case .model: device.model.map { .string($0) }
        case .displayName: device.displayName.map { .string($0) }
        case .vendor: .vendor(device.vendor)
        case .deviceClass: .deviceClass(device.deviceClass)
        case .firmwareVersion: device.firmwareVersion.map { .string($0) }
        case .dspVersion: device.dspVersion.map { .string($0) }
        case .bootTime: device.bootTime.map { .date($0) }
        case .activation: .activation(device.activation)
        case .subnetMask: device.subnetMask.map { .ipv4($0) }
        case .gateway: device.gateway.map { .ipv4($0) }
        case .ipv6Address: device.ipv6Address.map { .string($0) }
        case .dhcpEnabled: device.dhcpEnabled.map { .bool($0) }
        case .analogChannelCount: device.analogChannelCount.map { .int($0) }
        case .digitalChannelCount: device.digitalChannelCount.map { .int($0) }
        case .onvifServiceURLs: .strings(device.onvifServiceURLs)
        case .onvifScopes: device.onvifScopes.map { .scopes($0) }
        case .bonjourName: device.bonjourName.map { .string($0) }
        case .openPorts: .ports(device.openPorts)
        case .rtspRealm: device.rtspRealm.map { .string($0) }
        case .httpServerHeader: device.httpServerHeader.map { .string($0) }
        case .passwordResetAbility: device.passwordResetAbility.map { .bool($0) }
        case .supportsHCPlatform: device.supportsHCPlatform.map { .bool($0) }
        case .reachability: .reachability(device.reachability)
        }
    }

    /// Writes a `FieldValue` into a record. A value of the wrong shape for its key is ignored rather
    /// than coerced: a mechanism that puts a string in `httpPort` loses that field, not the record.
    func assign(_ value: FieldValue, key: DeviceFieldKey, to device: inout DiscoveredDevice,
                        source: DiscoverySource) {
        switch (key, value) {
        case let (.address, .ipv4(address)): device.address = address
        case let (.httpPort, .port(port)): device.httpPort = port
        case let (.httpsPort, .port(port)): device.httpsPort = port
        case let (.rtspPort, .port(port)): device.rtspPort = port
        case let (.commandPort, .port(port)): device.commandPort = port
        case let (.mac, .mac(mac)): device.mac = mac
        case let (.serialNumber, .string(text)): device.serialNumber = text
        case let (.model, .string(text)): device.model = text
        case let (.displayName, .string(text)): device.displayName = text
        case let (.vendor, .vendor(vendor)) where vendor != .unknown: device.vendor = vendor
        case let (.deviceClass, .deviceClass(value))
            where value.specificity > device.deviceClass.specificity:
            device.deviceClass = value
        case let (.firmwareVersion, .string(text)): device.firmwareVersion = text
        case let (.dspVersion, .string(text)): device.dspVersion = text
        case let (.bootTime, .date(date)): device.bootTime = date
        case let (.activation, .activation(state)): _ = applyActivation(state, source: source,
                                                                        to: &device)
        case let (.subnetMask, .ipv4(address)): device.subnetMask = address
        case let (.gateway, .ipv4(address)): device.gateway = address
        case let (.ipv6Address, .string(text)): device.ipv6Address = text
        case let (.dhcpEnabled, .bool(flag)): device.dhcpEnabled = flag
        case let (.analogChannelCount, .int(count)): device.analogChannelCount = count
        case let (.digitalChannelCount, .int(count)): device.digitalChannelCount = count
        case let (.onvifServiceURLs, .strings(urls)):
            device.onvifServiceURLs = mergedURLs(device.onvifServiceURLs, urls)
        case let (.onvifScopes, .scopes(scopes)): device.onvifScopes = scopes
        case let (.bonjourName, .string(text)): device.bonjourName = text
        case let (.openPorts, .ports(ports)): device.openPorts.formUnion(ports)
        case let (.rtspRealm, .string(text)): device.rtspRealm = text
        case let (.httpServerHeader, .string(text)): device.httpServerHeader = text
        case let (.passwordResetAbility, .bool(flag)): device.passwordResetAbility = flag
        case let (.supportsHCPlatform, .bool(flag)): device.supportsHCPlatform = flag
        case let (.reachability, .reachability(value)): device.reachability = value
        default: break
        }
    }
}
