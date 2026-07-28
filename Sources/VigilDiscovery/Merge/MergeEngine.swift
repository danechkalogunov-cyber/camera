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
    struct Entry: Sendable {
        var device: DiscoveredDevice
        /// The best vendor verdict seen so far, arbitrated per §6.8.
        var verdict: ClassificationVerdict
        /// False once this record has been absorbed by a merge.
        var isAlive: Bool
        /// True when the only SADP evidence came from another client's ProbeMatch (§4.5).
        var isForeign: Bool
    }

    var entries: [Entry] = []

    // Union-find over identity keys. `nodeOfKey` interns a key; `parent`/`rank` are the forest;
    // `recordOfRoot` maps a root node to the record it stands for.
    private var nodeOfKey: [String: Int] = [:]
    private var parent: [Int] = []
    private var rank: [Int] = []
    private var recordOfRoot: [Int: Int] = [:]

    let knownDevices: [KnownDeviceSnapshot]
    let plannedSubnets: [IPv4Subnet]
    private let keyLimit: Int
    var emittedAddressEvents: Set<String> = []
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
            if Self.shouldOverwrite(existing: target.provenance[key], incoming: stamp) {
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
    func mergedURLs(_ base: [String], _ extra: [String]) -> [String] {
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
}
