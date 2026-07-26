//
//  MergeEngine.swift
//  VigilDiscovery
//
//  Folds every mechanism's observations into one list of devices: union-find over the identity
//  ladder, field-level precedence by source trust, confidence scoring, and the three address events
//  that keep a saved camera from being silently re-pointed at a stranger.
//  Implements docs/spec-discovery.md §7. Pure, synchronous, driven by an owning actor.
//

import Foundation
import VigilProtocols

/// Merges observations into `DiscoveredDevice` records.
///
/// Two rules here are user-visible and easy to get wrong, so they are stated as tests as well as
/// code:
///
/// * a camera whose IP changed emits `.addressChanged` and stays one row — it must never appear
///   twice;
/// * a **new MAC at an old IP** emits `.addressReused` and must never re-point a saved camera,
///   because a replaced device would otherwise inherit the previous one's identity and credentials.
///
/// Emission discipline: exactly one `.deviceFound` per record, ever. Everything later is
/// `.deviceUpdated(changes:)` or `.deviceMerged`.
public struct MergeEngine: Sendable {

    // MARK: - Stored state

    /// One record plus the bookkeeping that is not part of the public model.
    private struct Entry: Sendable {
        var device: DiscoveredDevice
        /// The best vendor verdict seen so far, arbitrated per §6.8.
        var verdict: ClassificationVerdict
        /// False once this record has been absorbed by a merge.
        var isAlive: Bool
        /// True when the only SADP evidence came from another client's ProbeMatch (§4.5).
        var isForeign: Bool
    }

    private var entries: [Entry] = []

    // Union-find over identity keys. `nodeOfKey` interns a key; `parent`/`rank` are the forest;
    // `recordOfRoot` maps a root node to the record it stands for.
    private var nodeOfKey: [String: Int] = [:]
    private var parent: [Int] = []
    private var rank: [Int] = []
    private var recordOfRoot: [Int: Int] = [:]

    private let knownDevices: [KnownDeviceSnapshot]
    private let plannedSubnets: [IPv4Subnet]
    private let keyLimit: Int
    private var emittedAddressEvents: Set<String> = []
    private var reportedOffSubnet: Set<UInt32> = []
    private var reportedConflicts: Set<String> = []

    /// Diagnostics raised while merging, in order. Also returned as `.diagnostic` events.
    public private(set) var diagnostics: [DiscoveryDiagnostic] = []

    /// Creates an engine.
    ///
    /// - Parameters:
    ///   - knownDevices: cameras the app already has saved, from `VigilCore`. Drives the address
    ///     events; an empty list simply means no address event can fire.
    ///   - plannedSubnets: the subnets this run covers, used to decide reachability. Empty leaves
    ///     reachability at whatever an observation stated.
    ///   - keyLimit: cap on interned identity keys per run (§7.2). Past it, new keys are not
    ///     created: a flood of forged serials costs memory, not correctness.
    public init(knownDevices: [KnownDeviceSnapshot] = [], plannedSubnets: [IPv4Subnet] = [],
                keyLimit: Int = 8_192) {
        self.knownDevices = knownDevices
        self.plannedSubnets = plannedSubnets
        self.keyLimit = max(keyLimit, 1)
    }

    // MARK: - Public surface

    /// Every live record, in the stable order of §10.4: confidence descending, ISAPI-capable first,
    /// then address, then identity. Deterministic regardless of the order observations arrived in,
    /// so a SwiftUI list does not reshuffle as evidence lands.
    public var devices: [DiscoveredDevice] {
        entries.filter(\.isAlive).map(\.device).sorted(by: Self.isOrderedBefore)
    }

    /// All live records, however weak.
    public var candidateCount: Int { entries.lazy.filter(\.isAlive).count }

    /// Records confident enough to present as devices rather than "possible devices" (§7.6).
    public var deviceCount: Int {
        entries.lazy.filter { $0.isAlive && $0.device.confidence >= 30 }.count
    }

    /// The §10.4 comparator, exposed so a caller inserting a row can use exactly the same order.
    public static func isOrderedBefore(_ lhs: DiscoveredDevice, _ rhs: DiscoveredDevice) -> Bool {
        if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
        let lhsISAPI = lhs.vendor.supportsISAPI
        let rhsISAPI = rhs.vendor.supportsISAPI
        if lhsISAPI != rhsISAPI { return lhsISAPI }
        if lhs.address.rawValue != rhs.address.rawValue {
            return lhs.address.rawValue < rhs.address.rawValue
        }
        return lhs.id.description < rhs.id.description
    }

    // MARK: - Ingestion

    /// Folds one observation in and returns everything that happened, in emission order.
    ///
    /// The sequence is: `.deviceMerged` (when a new key proved two provisional records were one),
    /// then `.deviceFound` **or** `.deviceUpdated`, then any `.diagnostic`, then the address events
    /// of §7.4. A record that changed nothing produces no event at all.
    public mutating func ingest(_ observation: DeviceObservation) -> [DiscoveryEvent] {
        var events: [DiscoveryEvent] = []
        let identities = observation.identities

        // 1. Resolve which existing records these keys already point at.
        var candidateRecords: [Int] = []
        for identity in identities {
            guard let node = nodeOfKey[identity.key] else { continue }
            let root = find(node)
            guard let record = recordOfRoot[root], entries[record].isAlive else { continue }
            if !candidateRecords.contains(record) { candidateRecords.append(record) }
        }

        // 2. Split by whether merging them with this observation would contradict a hard identity.
        let compatible = candidateRecords.filter { isCompatible(observation, with: entries[$0]) }
        let conflicting = candidateRecords.filter { !isCompatible(observation, with: entries[$0]) }

        // 3. Pick or create the record this observation belongs to.
        let target: Int
        var isNewRecord = false
        switch compatible.count {
        case 0:
            target = makeRecord(from: observation)
            isNewRecord = true
        case 1:
            target = compatible[0]
        default:
            let (winner, absorbed) = collapse(compatible)
            target = winner
            events.append(.deviceMerged(absorbed: absorbed, into: entries[winner].device.id))
        }

        // 4. Bind keys. A key already owned by a contradicting record keeps its owner: that is the
        //    within-run form of address reuse, and re-pointing it would merge two devices.
        let blocked = Set(conflicting)
        var bindable: [DeviceIdentity] = []
        for identity in identities {
            if let node = nodeOfKey[identity.key], let owner = recordOfRoot[find(node)],
               entries[owner].isAlive, blocked.contains(owner) {
                continue
            }
            bindable.append(identity)
        }
        bind(bindable, to: target)

        // 5. Fold the fields.
        var changed = apply(observation, to: target)

        // 6. Promote the identity and recompute everything derived from the whole record.
        promoteIdentity(of: target)
        if updateReachability(of: target) { changed.insert(.reachability) }
        rescore(target)

        if isNewRecord {
            events.append(.deviceFound(entries[target].device))
        } else if !changed.isEmpty {
            events.append(.deviceUpdated(entries[target].device, changes: changed))
        }

        // 7. Diagnostics that this observation produced.
        for other in conflicting {
            if let diagnostic = conflictDiagnostic(observation, with: entries[other]) {
                diagnostics.append(diagnostic)
                events.append(.diagnostic(diagnostic))
            }
        }
        if entries[target].device.reachability == .offSubnet,
           reportedOffSubnet.insert(entries[target].device.address.rawValue).inserted {
            let diagnostic = DiscoveryDiagnostic.offSubnetDeviceSeen(
                address: entries[target].device.address, ourSubnets: plannedSubnets)
            diagnostics.append(diagnostic)
            events.append(.diagnostic(diagnostic))
        }

        // 8. The saved-camera events.
        events.append(contentsOf: knownDeviceEvents(for: target))
        return events
    }

    // MARK: - Union-find

    /// Interns `key`, returning its node, or `nil` when the per-run key cap is reached.
    private mutating func node(for key: String) -> Int? {
        if let existing = nodeOfKey[key] { return existing }
        guard nodeOfKey.count < keyLimit else { return nil }
        let index = parent.count
        parent.append(index)
        rank.append(0)
        nodeOfKey[key] = index
        return index
    }

    /// Path-compressed find.
    private mutating func find(_ node: Int) -> Int {
        var root = node
        while parent[root] != root { root = parent[root] }
        var cursor = node
        while parent[cursor] != root {
            let next = parent[cursor]
            parent[cursor] = root
            cursor = next
        }
        return root
    }

    /// Union by rank. Returns the surviving root.
    private mutating func union(_ lhs: Int, _ rhs: Int) -> Int {
        let a = find(lhs)
        let b = find(rhs)
        guard a != b else { return a }
        if rank[a] < rank[b] {
            parent[a] = b
            return b
        }
        parent[b] = a
        if rank[a] == rank[b] { rank[a] += 1 }
        return a
    }

    /// Binds identity keys to a record, unioning them into one set.
    ///
    /// Every key that reaches here has been cleared for this record: a key still owned by a
    /// contradicting record is filtered out by the caller, which is what stops a new MAC at an old
    /// IP from dragging the old record along with it.
    private mutating func bind(_ identities: [DeviceIdentity], to record: Int) {
        var nodes: [Int] = []
        for identity in identities {
            guard let node = node(for: identity.key) else { continue }
            nodes.append(node)
            entries[record].device.alternateIdentities.insert(identity)
        }
        guard let first = nodes.first else { return }
        var root = find(first)
        for node in nodes.dropFirst() {
            let other = find(node)
            guard other != root else { continue }
            let merged = union(other, root)
            // The losing root no longer stands for anything; drop its mapping so a stale entry can
            // never resurrect a record that has been folded away.
            if merged != other { recordOfRoot[other] = nil }
            if merged != root { recordOfRoot[root] = nil }
            root = merged
        }
        recordOfRoot[root] = record
    }

    // MARK: - Records

    /// Creates a record from an observation, seeded with everything the observation already knows.
    private mutating func makeRecord(from observation: DeviceObservation) -> Int {
        let identity = observation.identities.first
            ?? .endpoint(observation.address, observation.impliedHTTPPort)
        var device = DiscoveredDevice(id: identity, address: observation.address,
                                      firstSeen: observation.observedAt,
                                      lastSeen: observation.observedAt)
        device.alternateIdentities = Set(observation.identities)
        entries.append(Entry(device: device, verdict: .inconclusive, isAlive: true,
                             isForeign: observation.isForeignProbeMatch))
        return entries.count - 1
    }

    /// Merges several records into one. The survivor has the strongest identity, ties broken by the
    /// earliest `firstSeen` — the row the user has been looking at longest is the one that stays.
    private mutating func collapse(_ records: [Int]) -> (winner: Int, absorbed: [DeviceIdentity]) {
        let ordered = records.sorted { lhs, rhs in
            let left = entries[lhs].device
            let right = entries[rhs].device
            if left.id.strength != right.id.strength { return left.id.strength > right.id.strength }
            return left.firstSeen < right.firstSeen
        }
        guard let winner = ordered.first else { return (records[0], []) }
        var absorbedIdentities: [DeviceIdentity] = []
        for index in ordered.dropFirst() {
            absorbedIdentities.append(entries[index].device.id)
            absorb(index, into: winner)
        }
        return (winner, absorbedIdentities)
    }

    /// Folds an absorbed record's knowledge into the survivor and marks it dead.
    private mutating func absorb(_ source: Int, into destination: Int) {
        let donor = entries[source].device
        var target = entries[destination].device

        for key in DeviceFieldKey.allCases {
            guard let stamp = donor.provenance[key] else { continue }
            guard let value = value(of: key, in: donor) else { continue }
            if shouldOverwrite(existing: target.provenance[key], incoming: stamp) {
                assign(value, key: key, to: &target, source: stamp.source)
                target.provenance[key] = stamp
            }
        }
        target.openPorts.formUnion(donor.openPorts)
        target.sources.formUnion(donor.sources)
        target.alternateIdentities.formUnion(donor.alternateIdentities)
        target.alternateIdentities.insert(donor.id)
        target.onvifServiceURLs = mergedURLs(target.onvifServiceURLs, donor.onvifServiceURLs)
        if var scopes = target.onvifScopes, let donorScopes = donor.onvifScopes {
            scopes.formUnion(donorScopes)
            target.onvifScopes = scopes
        } else {
            target.onvifScopes = target.onvifScopes ?? donor.onvifScopes
        }
        target.firstSeen = min(target.firstSeen, donor.firstSeen)
        target.lastSeen = max(target.lastSeen, donor.lastSeen)
        if target.mac == nil || (target.macIsHintOnly && donor.mac != nil && !donor.macIsHintOnly) {
            target.mac = donor.mac ?? target.mac
            target.macIsHintOnly = donor.macIsHintOnly
        }

        entries[destination].device = target
        entries[destination].verdict = VendorClassifier.combine(existing: entries[destination].verdict,
                                                               incoming: entries[source].verdict)
        entries[destination].isForeign = entries[destination].isForeign && entries[source].isForeign
        entries[source].isAlive = false

        // Re-point every key that stood for the absorbed record. The roots are collected first: the
        // dictionary must not be mutated while it is being iterated.
        let staleRoots = recordOfRoot.compactMap { $0.value == source ? $0.key : nil }
        for root in staleRoots { recordOfRoot[root] = destination }
    }

    /// Appends URLs that are not already present, preserving order.
    private func mergedURLs(_ base: [String], _ extra: [String]) -> [String] {
        var seen = Set(base)
        var result = base
        for url in extra where seen.insert(url).inserted { result.append(url) }
        return result
    }

    // MARK: - Compatibility

    /// True unless merging would contradict a hard identity: two different non-hint MACs, or two
    /// different normalised serials. Those are never merged (§7.2) — the cost of being wrong is a
    /// stranger's device inheriting a saved camera's credentials.
    private func isCompatible(_ observation: DeviceObservation, with entry: Entry) -> Bool {
        if let observed = observation.mac, !observation.macIsHintOnly, observed.isUsableIdentity,
           let existing = entry.device.mac, !entry.device.macIsHintOnly, existing.isUsableIdentity,
           observed != existing {
            return false
        }
        if let observedSerial = observation.serialNumber.flatMap(IdentityNormalizer.serialKey),
           let existingSerial = entry.device.serialNumber.flatMap(IdentityNormalizer.serialKey),
           observedSerial != existingSerial {
            return false
        }
        return true
    }

    /// The diagnostic for a refused merge, emitted once per address-and-MAC pair.
    private mutating func conflictDiagnostic(_ observation: DeviceObservation,
                                             with entry: Entry) -> DiscoveryDiagnostic? {
        guard let observed = observation.mac, !observation.macIsHintOnly,
              let existing = entry.device.mac, !entry.device.macIsHintOnly,
              observed != existing else { return nil }
        let signature = "\(observation.address)|\(min(observed.rawValue, existing.rawValue))"
            + "|\(max(observed.rawValue, existing.rawValue))"
        guard reportedConflicts.insert(signature).inserted else { return nil }
        return .identityConflict(address: observation.address, macA: existing, macB: observed)
    }

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
                guard shouldOverwrite(existing: device.provenance[key], incoming: stamp) else {
                    continue
                }
                let before = self.value(of: key, in: device)
                assign(value, key: key, to: &device, source: observation.source)
                if self.value(of: key, in: device) != before {
                    changed.insert(key)
                    device.provenance[key] = stamp
                } else {
                    device.provenance[key] = stamp
                }
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
            guard !isHint, shouldOverwrite(existing: device.provenance[.mac], incoming: stamp) else {
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
    private func assign(_ value: FieldValue, key: DeviceFieldKey, to device: inout DiscoveredDevice,
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
