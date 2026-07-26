//
//  MergeEngineTests.swift
//  VigilDiscoveryTests
//
//  The identity ladder and the merge model: every rung, a record that gains a MAC late and must
//  merge rather than duplicate, the two address events, sticky activation, field precedence by
//  source trust, confidence scoring and the deterministic sort order.
//  Covers docs/spec-discovery.md §7 and §10.4; tests 65–77 of §13.6.
//

import Foundation
import Testing

import VigilProtocols
@testable import VigilDiscovery

@Suite struct MergeEngineBehaviour {

    // MARK: - Fixtures

    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    static func at(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }

    static let lan = IPv4Subnet(network: IPv4Address(192, 168, 1, 0), prefixLength: 24)
    static let hikvisionSerial = "DS-2CD2143G0-I20200114AAWRD12345678"

    static func mac(_ text: String) throws -> MACAddress { try #require(MACAddress(text)) }

    static func sweep(_ address: IPv4Address, ports: Set<UInt16> = [80, 554],
                      at seconds: Double = 0) -> DeviceObservation {
        DeviceObservation(source: .tcpSweep, observedAt: at(seconds), address: address,
                          fields: [.openPorts: .ports(ports), .httpPort: .port(80)])
    }

    static func arp(_ address: IPv4Address, _ mac: MACAddress,
                    at seconds: Double = 0) -> DeviceObservation {
        DeviceObservation(source: .arpCache, observedAt: at(seconds), address: address, mac: mac)
    }

    static func sadp(_ address: IPv4Address, mac: MACAddress? = nil, serial: String? = nil,
                     model: String? = "DS-2CD2143G0-I", activation: ActivationState = .activated,
                     at seconds: Double = 0) -> DeviceObservation {
        var fields: [DeviceFieldKey: FieldValue] = [
            .vendor: .vendor(.hikvision),
            .activation: .activation(activation),
            .commandPort: .port(8_000),
        ]
        if let model { fields[.model] = .string(model) }
        return DeviceObservation(source: .sadpMulticast, observedAt: at(seconds), address: address,
                                 mac: mac, serialNumber: serial, fields: fields)
    }

    static func events(_ engine: inout MergeEngine,
                       _ observations: [DeviceObservation]) -> [DiscoveryEvent] {
        observations.flatMap { engine.ingest($0) }
    }

    static func count(_ events: [DiscoveryEvent], of kind: EventKind) -> Int {
        events.filter { event in
            switch (event, kind) {
            case (.deviceFound, .found), (.deviceUpdated, .updated), (.deviceMerged, .merged),
                 (.addressChanged, .addressChanged), (.addressReused, .addressReused),
                 (.diagnostic, .diagnostic):
                true
            default:
                false
            }
        }.count
    }

    enum EventKind { case found, updated, merged, addressChanged, addressReused, diagnostic }

    // MARK: - The ladder

    /// Test 66: `endpoint` → `serial` → `mac` as keys arrive, all on one record.
    @Test func mergeEngineClimbsTheIdentityLadder() throws {
        var engine = MergeEngine(plannedSubnets: [Self.lan])
        let address = IPv4Address(192, 168, 1, 64)
        let mac = try Self.mac("c4:2f:90:ab:cd:ef")

        let first = engine.ingest(Self.sweep(address))
        #expect(Self.count(first, of: .found) == 1)
        #expect(engine.devices.first?.id == .endpoint(address, 80))

        let second = engine.ingest(Self.sadp(address, serial: Self.hikvisionSerial, at: 1))
        #expect(Self.count(second, of: .found) == 0)
        #expect(Self.count(second, of: .updated) == 1)
        let serialKey = try #require(IdentityNormalizer.serialKey(Self.hikvisionSerial))
        #expect(engine.devices.first?.id == .serial(serialKey))

        let third = engine.ingest(Self.arp(address, mac, at: 2))
        #expect(Self.count(third, of: .updated) == 1)
        #expect(engine.devices.count == 1)
        let device = try #require(engine.devices.first)
        #expect(device.id == .mac(mac))
        #expect(device.alternateIdentities.contains(.serial(serialKey)))
        #expect(device.alternateIdentities.contains(.endpoint(address, 80)))
    }

    /// Test 65: three sources for one host collapse to one record, one `.deviceFound`, and the
    /// remaining events are updates.
    @Test func mergeEngineSweepThenARPThenSADPCollapsesToOne() throws {
        var engine = MergeEngine(plannedSubnets: [Self.lan])
        let address = IPv4Address(192, 168, 1, 64)
        let mac = try Self.mac("c4:2f:90:ab:cd:ef")
        let all = Self.events(&engine, [Self.sweep(address),
                                        Self.arp(address, mac, at: 1),
                                        Self.sadp(address, mac: mac, serial: Self.hikvisionSerial,
                                                  at: 2)])
        #expect(Self.count(all, of: .found) == 1)
        #expect(Self.count(all, of: .updated) == 2)
        #expect(engine.devices.count == 1)
        #expect(engine.devices.first?.id == .mac(mac))
        #expect(engine.devices.first?.sources == [.tcpSweep, .arpCache, .sadpMulticast])
    }

    /// The rule the brief calls out: a record that gains a MAC late must merge, not duplicate.
    ///
    /// Two provisional records exist — one keyed by serial, one by ONVIF UUID at a different
    /// address — and an observation carrying both keys proves they are one device.
    @Test func mergeEngineMergesWhenALaterKeyProvesTwoRecordsAreOne() throws {
        var engine = MergeEngine(plannedSubnets: [Self.lan])
        let serialAddress = IPv4Address(192, 168, 1, 64)
        let uuidAddress = IPv4Address(192, 168, 1, 65)
        let uuid = "urn:uuid:2419d68a-2dd2-21b2-a205-c42f90abcdef"

        _ = engine.ingest(Self.sadp(serialAddress, serial: Self.hikvisionSerial))
        _ = engine.ingest(DeviceObservation(source: .wsDiscovery, observedAt: Self.at(1),
                                            address: uuidAddress, onvifUUID: uuid,
                                            fields: [.onvifServiceURLs:
                                                        .strings(["http://192.168.1.65/onvif"])]))
        #expect(engine.devices.count == 2)

        let mac = try Self.mac("c4:2f:90:ab:cd:ef")
        let unifying = DeviceObservation(source: .manual, observedAt: Self.at(2),
                                         address: serialAddress, mac: mac,
                                         serialNumber: Self.hikvisionSerial, onvifUUID: uuid)
        let events = engine.ingest(unifying)
        #expect(Self.count(events, of: .merged) == 1)
        #expect(engine.devices.count == 1)

        let merged = try #require(engine.devices.first)
        #expect(merged.id == .mac(mac))
        let onvifKey = try #require(IdentityNormalizer.onvifKey(uuid))
        #expect(merged.alternateIdentities.contains(.onvifUUID(onvifKey)))
        // The absorbed record's knowledge survives the merge.
        #expect(merged.onvifServiceURLs == ["http://192.168.1.65/onvif"])
        #expect(merged.sources.contains(.wsDiscovery))

        // The surviving row is the one with the strongest identity, and nothing else is emitted for
        // the absorbed record afterwards.
        let laterSweep = engine.ingest(Self.sweep(uuidAddress, at: 3))
        #expect(Self.count(laterSweep, of: .found) == 0)
        #expect(engine.devices.count == 1)
    }

    /// Test 67: two different MACs at one address are two devices, with a diagnostic explaining it.
    /// Merging them would be the bug that hands a replaced device the old one's identity.
    @Test func mergeEngineNeverMergesDifferentMACs() throws {
        var engine = MergeEngine(plannedSubnets: [Self.lan])
        let address = IPv4Address(192, 168, 1, 64)
        let first = try Self.mac("c4:2f:90:ab:cd:ef")
        let second = try Self.mac("bc:ad:28:11:22:33")

        _ = engine.ingest(Self.sadp(address, mac: first, serial: Self.hikvisionSerial))
        let events = engine.ingest(Self.arp(address, second, at: 1))
        #expect(engine.devices.count == 2)
        #expect(Self.count(events, of: .found) == 1)
        #expect(Self.count(events, of: .diagnostic) == 1)
        #expect(engine.diagnostics.contains(.identityConflict(address: address, macA: first,
                                                             macB: second)))
        // The SADP record keeps its own MAC: the higher-trust source wins the address.
        let sadpRecord = try #require(engine.devices.first { $0.id == .mac(first) })
        #expect(sadpRecord.mac == first)
        #expect(sadpRecord.serialNumber == Self.hikvisionSerial)
    }

    /// Two different serials never merge either, even at one address.
    @Test func mergeEngineNeverMergesDifferentSerials() throws {
        var engine = MergeEngine()
        let address = IPv4Address(192, 168, 1, 64)
        _ = engine.ingest(Self.sadp(address, serial: Self.hikvisionSerial))
        _ = engine.ingest(Self.sadp(address, serial: "DS-2CD2347G2-LU20260401AAWRJ98765432", at: 1))
        #expect(engine.devices.count == 2)
    }

    /// Test 68: case and whitespace differences unify; a four-character serial is no key at all.
    @Test func mergeEngineNormalisesSerialsBeforeComparing() throws {
        var engine = MergeEngine()
        _ = engine.ingest(Self.sadp(IPv4Address(192, 168, 1, 64),
                                    serial: " ds-2cd2143g0-i20200114aawrd12345678 "))
        _ = engine.ingest(Self.sadp(IPv4Address(192, 168, 1, 77), serial: Self.hikvisionSerial,
                                    at: 1))
        #expect(engine.devices.count == 1)

        var other = MergeEngine()
        _ = other.ingest(Self.sadp(IPv4Address(192, 168, 1, 64), serial: "1234"))
        let device = try #require(other.devices.first)
        #expect(device.id == .endpoint(IPv4Address(192, 168, 1, 64), 80))
    }

    // MARK: - Field precedence

    /// Test 69: open ports accumulate across tiers and are never replaced.
    @Test func mergeEngineUnionsOpenPorts() throws {
        var engine = MergeEngine(plannedSubnets: [Self.lan])
        let address = IPv4Address(192, 168, 1, 64)
        _ = engine.ingest(Self.sweep(address, ports: [80, 554]))
        _ = engine.ingest(Self.sweep(address, ports: [8_000], at: 1))
        let device = try #require(engine.devices.first)
        #expect(device.openPorts == [80, 554, 8_000])
        #expect(device.reachability == .reachable)
    }

    /// Test 70: `.notActivated` is sticky. A later ONVIF sighting that says nothing about activation
    /// must not clear the one fact that makes the camera unusable.
    @Test func mergeEngineActivationIsSticky() throws {
        var engine = MergeEngine()
        let address = IPv4Address(192, 168, 1, 64)
        _ = engine.ingest(Self.sadp(address, serial: Self.hikvisionSerial,
                                    activation: .notActivated))
        #expect(engine.devices.first?.activation == .notActivated)
        #expect(engine.devices.first?.needsActivation == true)

        _ = engine.ingest(DeviceObservation(source: .wsDiscovery, observedAt: Self.at(1),
                                            address: address,
                                            fields: [.model: .string("Camera")]))
        #expect(engine.devices.first?.activation == .notActivated)

        // Even an explicit `.activated` from a source that cannot see activation is refused.
        _ = engine.ingest(DeviceObservation(source: .wsDiscovery, observedAt: Self.at(2),
                                            address: address,
                                            fields: [.activation: .activation(.activated)]))
        #expect(engine.devices.first?.activation == .notActivated)

        // A newer SADP observation may clear it, because SADP is authoritative here.
        _ = engine.ingest(Self.sadp(address, serial: Self.hikvisionSerial, activation: .activated,
                                    at: 3))
        #expect(engine.devices.first?.activation == .activated)
    }

    /// Test 71: SADP's model beats an ONVIF hardware string; a manual value beats everything.
    @Test func mergeEngineResolvesFieldsByTrustThenTime() throws {
        var engine = MergeEngine()
        let address = IPv4Address(192, 168, 1, 64)
        _ = engine.ingest(Self.sadp(address, serial: Self.hikvisionSerial, model: "DS-2CD2143G0-I"))
        _ = engine.ingest(DeviceObservation(source: .wsDiscovery, observedAt: Self.at(5),
                                            address: address,
                                            fields: [.model: .string("NetworkVideoTransmitter")]))
        #expect(engine.devices.first?.model == "DS-2CD2143G0-I")

        _ = engine.ingest(DeviceObservation(source: .manual, observedAt: Self.at(6),
                                            address: address,
                                            fields: [.displayName: .string("Front door")]))
        #expect(engine.devices.first?.displayName == "Front door")
        #expect(engine.devices.first?.resolvedName == "Front door")

        // Same source, newer wins.
        _ = engine.ingest(Self.sadp(address, serial: Self.hikvisionSerial, model: "DS-2CD2143G0-IS",
                                    at: 10))
        #expect(engine.devices.first?.model == "DS-2CD2143G0-IS")
    }

    /// The precedence predicate itself, including the empty-field and equal-trust cases.
    @Test func mergeEngineShouldOverwriteFollowsTrustThenRecency() {
        let sadpEarly = FieldStamp(source: .sadpMulticast, observedAt: Self.at(0))
        let sadpLate = FieldStamp(source: .sadpMulticast, observedAt: Self.at(1))
        let sweep = FieldStamp(source: .tcpSweep, observedAt: Self.at(2))
        #expect(MergeEngine.shouldOverwrite(existing: nil, incoming: sweep))
        #expect(MergeEngine.shouldOverwrite(existing: sweep, incoming: sadpEarly))
        #expect(!MergeEngine.shouldOverwrite(existing: sadpEarly, incoming: sweep))
        #expect(MergeEngine.shouldOverwrite(existing: sadpEarly, incoming: sadpLate))
        #expect(!MergeEngine.shouldOverwrite(existing: sadpLate, incoming: sadpEarly))
    }

    /// A hint MAC never becomes an identity, and a real MAC replaces it without merging anything.
    @Test func mergeEngineTreatsHintMACsAsCorroborationOnly() throws {
        var engine = MergeEngine()
        let address = IPv4Address(192, 168, 1, 64)
        let mac = try Self.mac("c4:2f:90:ab:cd:ef")
        _ = engine.ingest(DeviceObservation(source: .wsDiscovery, observedAt: Self.at(0),
                                            address: address, mac: mac, macIsHintOnly: true))
        var device = try #require(engine.devices.first)
        #expect(device.mac == mac)
        #expect(device.macIsHintOnly)
        #expect(device.id == .endpoint(address, 80))

        _ = engine.ingest(Self.arp(address, mac, at: 1))
        device = try #require(engine.devices.first)
        #expect(device.macIsHintOnly == false)
        #expect(device.id == .mac(mac))
        #expect(engine.devices.count == 1)
    }

    // MARK: - Address events (§7.4)

    /// Test 72: a saved camera on a new lease is one row plus `.addressChanged` — never two rows.
    @Test func mergeEngineEmitsAddressChangedForAKnownDeviceThatMoved() throws {
        let mac = try Self.mac("c4:2f:90:ab:cd:ef")
        let saved = KnownDeviceSnapshot(identity: .mac(mac), mac: mac,
                                        lastKnownAddress: IPv4Address(192, 168, 1, 64),
                                        displayName: "Front door")
        var engine = MergeEngine(knownDevices: [saved], plannedSubnets: [Self.lan])
        let events = engine.ingest(Self.sadp(IPv4Address(192, 168, 1, 77), mac: mac,
                                             serial: Self.hikvisionSerial))
        #expect(engine.devices.count == 1)
        #expect(Self.count(events, of: .addressChanged) == 1)
        #expect(Self.count(events, of: .addressReused) == 0)

        let changed = events.compactMap { event -> (DeviceIdentity, IPv4Address, IPv4Address)? in
            if case let .addressChanged(identity, from, to) = event { return (identity, from, to) }
            return nil
        }
        #expect(changed.count == 1)
        #expect(changed.first?.0 == .mac(mac))
        #expect(changed.first?.1 == IPv4Address(192, 168, 1, 64))
        #expect(changed.first?.2 == IPv4Address(192, 168, 1, 77))

        // Re-seeing it at the same new address does not repeat the event.
        let again = engine.ingest(Self.sweep(IPv4Address(192, 168, 1, 77), at: 1))
        #expect(Self.count(again, of: .addressChanged) == 0)
    }

    /// The same, matched by serial when the saved record has no MAC.
    @Test func mergeEngineMatchesKnownDeviceBySerialWhenMACIsAbsent() throws {
        let serialKey = try #require(IdentityNormalizer.serialKey(Self.hikvisionSerial))
        let saved = KnownDeviceSnapshot(identity: .serial(serialKey),
                                        serialNumber: Self.hikvisionSerial,
                                        lastKnownAddress: IPv4Address(192, 168, 1, 64))
        var engine = MergeEngine(knownDevices: [saved], plannedSubnets: [Self.lan])
        let events = engine.ingest(Self.sadp(IPv4Address(192, 168, 1, 90),
                                             serial: Self.hikvisionSerial))
        #expect(Self.count(events, of: .addressChanged) == 1)
    }

    /// Test 73 — the one that protects credentials: a **new MAC at an old IP** is `.addressReused`,
    /// the new device is a new record, and the saved camera is not re-pointed.
    @Test func mergeEngineEmitsAddressReusedForANewMACAtAnOldAddress() throws {
        let savedMAC = try Self.mac("c4:2f:90:ab:cd:ef")
        let strangerMAC = try Self.mac("3c:ef:8c:11:22:33")
        let address = IPv4Address(192, 168, 1, 64)
        let saved = KnownDeviceSnapshot(identity: .mac(savedMAC), mac: savedMAC,
                                        lastKnownAddress: address, displayName: "Front door")
        var engine = MergeEngine(knownDevices: [saved], plannedSubnets: [Self.lan])

        let events = engine.ingest(Self.arp(address, strangerMAC))
        #expect(Self.count(events, of: .addressReused) == 1)
        #expect(Self.count(events, of: .addressChanged) == 0)

        let reused = events.compactMap { event -> (IPv4Address, DeviceIdentity, DeviceIdentity)? in
            if case let .addressReused(at, previous, now) = event { return (at, previous, now) }
            return nil
        }
        #expect(reused.first?.0 == address)
        #expect(reused.first?.1 == .mac(savedMAC))
        #expect(reused.first?.2 == .mac(strangerMAC))

        // The record that exists is the stranger's. Nothing claims the saved camera's identity, and
        // nothing carries the user's own name for it.
        let devices = engine.devices
        #expect(devices.count == 1)
        #expect(devices.first?.id == .mac(strangerMAC))
        #expect(devices.first?.displayName == nil)
        #expect(!devices.contains { $0.id == .mac(savedMAC) })

        // And it is emitted only once, however many times the stranger answers.
        let again = engine.ingest(Self.sweep(address, at: 1))
        #expect(Self.count(again, of: .addressReused) == 0)
    }

    /// Without a hard identity we say nothing: a bare sweep hit at a saved address must not mark a
    /// working camera as replaced.
    @Test func mergeEngineDoesNotClaimReuseWithoutEvidence() throws {
        let savedMAC = try Self.mac("c4:2f:90:ab:cd:ef")
        let address = IPv4Address(192, 168, 1, 64)
        let saved = KnownDeviceSnapshot(identity: .mac(savedMAC), mac: savedMAC,
                                        lastKnownAddress: address)
        var engine = MergeEngine(knownDevices: [saved], plannedSubnets: [Self.lan])
        let events = engine.ingest(Self.sweep(address))
        #expect(Self.count(events, of: .addressReused) == 0)
        #expect(Self.count(events, of: .addressChanged) == 0)
    }

    /// A known device at its known address is an ordinary update — no address event at all.
    @Test func mergeEngineKnownDeviceAtKnownAddressIsAnUpdate() throws {
        let mac = try Self.mac("c4:2f:90:ab:cd:ef")
        let address = IPv4Address(192, 168, 1, 64)
        let saved = KnownDeviceSnapshot(identity: .mac(mac), mac: mac, lastKnownAddress: address)
        var engine = MergeEngine(knownDevices: [saved], plannedSubnets: [Self.lan])
        let events = engine.ingest(Self.sadp(address, mac: mac, serial: Self.hikvisionSerial))
        #expect(Self.count(events, of: .found) == 1)
        #expect(Self.count(events, of: .addressChanged) == 0)
        #expect(Self.count(events, of: .addressReused) == 0)
    }

    // MARK: - Reachability

    /// Test 74: the factory-fresh camera on the wrong subnet. Visible, and honestly not addable.
    @Test func mergeEngineMarksOffSubnetDevicesUnaddable() throws {
        let planned = [IPv4Subnet(network: IPv4Address(10, 0, 20, 0), prefixLength: 24)]
        var engine = MergeEngine(plannedSubnets: planned)
        let events = engine.ingest(Self.sadp(IPv4Address(192, 168, 1, 64),
                                             serial: Self.hikvisionSerial,
                                             activation: .notActivated))
        let device = try #require(engine.devices.first)
        #expect(device.reachability == .offSubnet)
        #expect(device.isAddable == false)
        #expect(device.needsActivation)
        #expect(Self.count(events, of: .diagnostic) == 1)
        let diagnostic = engine.diagnostics.first { diagnostic in
            if case .offSubnetDeviceSeen = diagnostic { return true }
            return false
        }
        #expect(diagnostic?.severity == .actionRequired)
    }

    /// Inside our subnets but silent on every port: addable, because SADP found it and the user may
    /// still want it.
    @Test func mergeEngineMarksSilentOnSubnetDevicesAddressableNoPorts() throws {
        var engine = MergeEngine(plannedSubnets: [Self.lan])
        _ = engine.ingest(Self.sadp(IPv4Address(192, 168, 1, 64), serial: Self.hikvisionSerial))
        let device = try #require(engine.devices.first)
        #expect(device.reachability == .addressableNoPorts)
        #expect(device.isAddable)
    }

    // MARK: - Confidence and ordering

    /// Test 75: the §7.6 arithmetic, one case per clause.
    @Test func mergeEngineScoresConfidencePerTheTable() throws {
        let mac = try Self.mac("c4:2f:90:ab:cd:ef")

        // SADP with MAC, serial and model: 45 + 15 + 10 + 10.
        var engine = MergeEngine()
        _ = engine.ingest(Self.sadp(IPv4Address(192, 168, 1, 64), mac: mac,
                                    serial: Self.hikvisionSerial))
        #expect(engine.devices.first?.confidence == 80)

        // ARP alone: 15 for the MAC, minus 5 because existence is all it proves.
        var arpOnly = MergeEngine()
        _ = arpOnly.ingest(Self.arp(IPv4Address(192, 168, 1, 70), mac))
        #expect(arpOnly.devices.first?.confidence == 10)

        // A bare sweep hit with 554 open: 10 for the RTSP port and nothing else.
        var sweepOnly = MergeEngine()
        _ = sweepOnly.ingest(Self.sweep(IPv4Address(192, 168, 1, 71), ports: [554]))
        #expect(sweepOnly.devices.first?.confidence == 10)

        // Sources beyond the first are worth 5 each, capped at 15.
        var many = MergeEngine()
        let address = IPv4Address(192, 168, 1, 72)
        _ = many.ingest(Self.sweep(address, ports: [80, 554]))
        _ = many.ingest(Self.arp(address, mac, at: 1))
        _ = many.ingest(Self.sadp(address, mac: mac, serial: Self.hikvisionSerial, at: 2))
        // 45 vendor + 15 mac + 10 serial + 10 model + 10 (two extra sources) + 10 port 554.
        #expect(many.devices.first?.confidence == 100)

        // A foreign ProbeMatch costs 10.
        var foreign = MergeEngine()
        var observation = Self.sadp(IPv4Address(192, 168, 1, 73), mac: mac,
                                    serial: Self.hikvisionSerial)
        observation.isForeignProbeMatch = true
        _ = foreign.ingest(observation)
        #expect(foreign.devices.first?.confidence == 70)

        // Nothing at all stays at zero and is not counted as a device.
        var empty = MergeEngine()
        _ = empty.ingest(DeviceObservation(source: .bonjour, observedAt: Self.at(0),
                                           address: IPv4Address(192, 168, 1, 74)))
        #expect(empty.devices.first?.confidence == 0)
        #expect(empty.deviceCount == 0)
        #expect(empty.candidateCount == 1)
    }

    /// Test 76: across a long script, `.deviceFound` fires exactly once per distinct device.
    @Test func mergeEngineEmitsOneDeviceFoundPerRecord() throws {
        var engine = MergeEngine(plannedSubnets: [Self.lan])
        var macs: [MACAddress] = []
        for index in 0..<5 {
            macs.append(try Self.mac("c4:2f:90:00:00:0\(index)"))
        }
        var events: [DiscoveryEvent] = []
        for round in 0..<60 {
            for (index, mac) in macs.enumerated() {
                let address = IPv4Address(192, 168, 1, UInt8(64 + index))
                let time = Double(round)
                switch round % 3 {
                case 0: events += engine.ingest(Self.sweep(address, at: time))
                case 1: events += engine.ingest(Self.arp(address, mac, at: time))
                default: events += engine.ingest(Self.sadp(address, mac: mac,
                                                           serial: "SN-DEVICE-\(index)-000\(index)",
                                                           at: time))
                }
            }
        }
        #expect(events.count > 100)
        #expect(Self.count(events, of: .found) == 5)
        #expect(engine.devices.count == 5)
        #expect(Self.count(events, of: .merged) == 0)
    }

    /// Test 77: the snapshot order does not depend on the order observations arrived in.
    @Test func mergeEngineSortOrderIsDeterministic() throws {
        let macs = [try Self.mac("c4:2f:90:00:00:01"), try Self.mac("3c:ef:8c:00:00:02"),
                    try Self.mac("ac:cc:8e:00:00:03")]
        var script: [DeviceObservation] = []
        for (index, mac) in macs.enumerated() {
            let address = IPv4Address(192, 168, 1, UInt8(64 + index))
            script.append(Self.sweep(address, ports: [80, 554], at: Double(index)))
            script.append(Self.arp(address, mac, at: Double(index) + 0.1))
            script.append(Self.sadp(address, mac: mac, serial: "SN-ORDER-\(index)-0000",
                                    at: Double(index) + 0.2))
        }

        var forward = MergeEngine(plannedSubnets: [Self.lan])
        _ = Self.events(&forward, script)
        var reversed = MergeEngine(plannedSubnets: [Self.lan])
        _ = Self.events(&reversed, script.reversed())

        #expect(forward.devices.map(\.id) == reversed.devices.map(\.id))
        #expect(forward.devices.map(\.confidence) == reversed.devices.map(\.confidence))
        // Higher confidence first, then ISAPI-capable, then address.
        #expect(forward.devices.map(\.confidence).sorted(by: >) == forward.devices.map(\.confidence))
    }

    /// ISAPI-capable devices sort ahead of equally-confident others, and addresses break the tie.
    @Test func mergeEngineOrdersISAPICapableDevicesFirst() {
        var hikvision = DiscoveredDevice(id: .endpoint(IPv4Address(192, 168, 1, 90), 80),
                                        address: IPv4Address(192, 168, 1, 90),
                                        firstSeen: Self.at(0), lastSeen: Self.at(0))
        hikvision.vendor = .hikvision
        hikvision.confidence = 50
        var dahua = DiscoveredDevice(id: .endpoint(IPv4Address(192, 168, 1, 10), 80),
                                    address: IPv4Address(192, 168, 1, 10),
                                    firstSeen: Self.at(0), lastSeen: Self.at(0))
        dahua.vendor = .dahua
        dahua.confidence = 50
        #expect(MergeEngine.isOrderedBefore(hikvision, dahua))
        #expect(!MergeEngine.isOrderedBefore(dahua, hikvision))
    }

    /// The derived properties a UI row is built from.
    @Test func mergeEngineDerivedPropertiesDescribeTheDevice() throws {
        var engine = MergeEngine(plannedSubnets: [Self.lan])
        let address = IPv4Address(192, 168, 1, 64)
        _ = engine.ingest(Self.sweep(address, ports: [80, 554]))
        _ = engine.ingest(Self.sadp(address, serial: Self.hikvisionSerial, at: 1))
        let device = try #require(engine.devices.first)
        #expect(device.resolvedName == "DS-2CD2143G0-I")
        #expect(device.isapiBaseURL?.absoluteString == "http://192.168.1.64")
        #expect(device.suggestedRTSPPath == "/Streaming/Channels/101")
        #expect(device.commandPort == 8_000)
        #expect(device.vendor.supportsISAPI)
    }

    /// HTTPS is preferred only when 443 answered and the plain port did not.
    @Test func mergeEnginePrefersHTTPSOnlyWhenPlainPortIsClosed() throws {
        var engine = MergeEngine(plannedSubnets: [Self.lan])
        let address = IPv4Address(192, 168, 1, 65)
        _ = engine.ingest(DeviceObservation(
            source: .tcpSweep, observedAt: Self.at(0), address: address,
            fields: [.openPorts: .ports([443]), .httpPort: .port(80), .httpsPort: .port(443)]))
        #expect(engine.devices.first?.isapiBaseURL?.absoluteString == "https://192.168.1.65")
    }

    /// A record with no name at all still has something to show the user.
    @Test func mergeEngineResolvedNameFallsBackToTheAddress() throws {
        var engine = MergeEngine()
        _ = engine.ingest(Self.sweep(IPv4Address(192, 168, 1, 99)))
        #expect(engine.devices.first?.resolvedName == "Camera at 192.168.1.99")
    }

    /// The key cap bounds memory without losing the records already found (§7.2).
    @Test func mergeEngineRespectsTheKeySpaceCap() {
        var engine = MergeEngine(keyLimit: 4)
        for index in 0..<40 {
            _ = engine.ingest(Self.sweep(IPv4Address(10, 0, 0, UInt8(index + 1))))
        }
        #expect(engine.candidateCount == 40)
    }
}

// MARK: - Normalisation

@Suite struct IdentityNormalizerBehaviour {

    /// Uppercasing, whitespace removal and the four-character lot code, which is stripped for
    /// comparison only.
    @Test func identityNormalizerNormalisesSerials() {
        #expect(IdentityNormalizer.serialKey(" ds-2cd2143g0-i20200114aawrd12345678 ")
            == "DS-2CD2143G0-I20200114AAWRD12345678")
        #expect(IdentityNormalizer.serialKey("DS-7616NI-K2/16P1620201105AAWR123456789WCVU")
            == "DS-7616NI-K2/16P1620201105AAWR123456789")
        #expect(IdentityNormalizer.serialKey("DS-2CD2143G0-I2020\u{0}0114AAWRD12345678")
            == "DS-2CD2143G0-I20200114AAWRD12345678")
    }

    /// Values that are not serials yield no key: a bad key merges two cameras, a missing one only
    /// costs a duplicate row.
    @Test func identityNormalizerRejectsUnusableSerials() {
        #expect(IdentityNormalizer.serialKey("") == nil)
        #expect(IdentityNormalizer.serialKey("1234") == nil)
        #expect(IdentityNormalizer.serialKey("       ") == nil)
        #expect(IdentityNormalizer.serialKey("00000000") == nil)
        #expect(IdentityNormalizer.serialKey("--------") == nil)
        #expect(IdentityNormalizer.serialKey("ABCDEFGH") == "ABCDEFGH")
    }

    /// A serial that merely ends in letters keeps them: only a digit-preceded four-letter tail is a
    /// lot code.
    @Test func identityNormalizerKeepsNonLotSuffixes() {
        #expect(IdentityNormalizer.strippingLotSuffix("DS-2CD2143G0-IABCDEFGH")
            == "DS-2CD2143G0-IABCDEFGH")
        #expect(IdentityNormalizer.strippingLotSuffix("SHORTWCVU") == "SHORTWCVU")
    }

    /// UUID prefixes are stripped and the nil UUID is refused.
    @Test func identityNormalizerNormalisesONVIFUUIDs() {
        #expect(IdentityNormalizer.onvifKey("urn:uuid:2419D68A-2DD2-21B2-A205-C42F90ABCDEF")
            == "2419d68a-2dd2-21b2-a205-c42f90abcdef")
        #expect(IdentityNormalizer.onvifKey("uuid:2419d68a-2dd2-21b2-a205-c42f90abcdef")
            == "2419d68a-2dd2-21b2-a205-c42f90abcdef")
        #expect(IdentityNormalizer.onvifKey("00000000-0000-0000-0000-000000000000") == nil)
        #expect(IdentityNormalizer.onvifKey("urn:uuid:") == nil)
        #expect(IdentityNormalizer.onvifKey("") == nil)
    }

    /// The MAC embedded in a vendor UUID is extracted only when the shape and the OUI both check
    /// out, and it is only ever a hint.
    @Test func identityNormalizerExtractsMACHintFromUUID() throws {
        #expect(IdentityNormalizer.macHint(fromONVIFUUID:
            "urn:uuid:2419d68a-2dd2-21b2-a205-c42f90abcdef") == MACAddress("c4:2f:90:ab:cd:ef"))
        // Not an OUI we know: refused rather than guessed.
        #expect(IdentityNormalizer.macHint(fromONVIFUUID:
            "urn:uuid:2419d68a-2dd2-21b2-a205-001122334455") == nil)
        // Wrong shape.
        #expect(IdentityNormalizer.macHint(fromONVIFUUID: "urn:uuid:c42f90abcdef") == nil)
    }

    /// Identity keys round-trip through their string form, and a corrupt key is refused.
    @Test func identityNormalizerIdentityKeysRoundTrip() throws {
        let identities: [DeviceIdentity] = [
            .mac(try #require(MACAddress("c4:2f:90:ab:cd:ef"))),
            .serial("DS-2CD2143G0-I20200114AAWRD12345678"),
            .onvifUUID("2419d68a-2dd2-21b2-a205-c42f90abcdef"),
            .endpoint(IPv4Address(192, 168, 1, 64), 8_000),
        ]
        for identity in identities {
            #expect(DeviceIdentity(key: identity.key) == identity)
        }
        #expect(DeviceIdentity(key: "mac:nothex") == nil)
        #expect(DeviceIdentity(key: "ep:192.168.1.64") == nil)
        #expect(DeviceIdentity(key: "unknown:x") == nil)
        #expect(identities.map(\.strength) == [4, 3, 2, 1])
        #expect(identities.map(\.isProvisional) == [false, false, false, true])
    }
}

// MARK: - ONVIF scopes

@Suite struct ONVIFScopesBehaviour {

    /// The scope list from a real-shaped ProbeMatch, percent-decoded and sorted into fields.
    @Test func onvifScopesParsesTheStandardScopeSet() throws {
        let raw = "onvif://www.onvif.org/type/video_encoder"
            + " onvif://www.onvif.org/type/Network_Video_Transmitter"
            + " onvif://www.onvif.org/hardware/DS-2CD2143G0-I"
            + " onvif://www.onvif.org/name/HIKVISION%20DS-2CD2143G0-I"
            + " onvif://www.onvif.org/location/country/china"
            + " onvif://www.onvif.org/Profile/Streaming"
            + " onvif://www.onvif.org/Profile/G"
        let scopes = ONVIFScopes.parse(raw)
        #expect(scopes.name == "HIKVISION DS-2CD2143G0-I")
        #expect(scopes.hardware == "DS-2CD2143G0-I")
        #expect(scopes.location == "china")
        #expect(scopes.profiles == ["Streaming", "G"])
        #expect(scopes.types == ["video_encoder", "Network_Video_Transmitter"])
        #expect(scopes.raw.count == 7)
    }

    /// A non-standard host and a `/MAC/` scope: both accepted, the MAC as a hint.
    @Test func onvifScopesAcceptsForeignHostsAndMACHints() {
        let scopes = ONVIFScopes.parse("onvif://192.168.1.64/MAC/c4%3A2f%3A90%3Aab%3Acd%3Aef"
                                       + " onvif://example.com/name/Camera")
        #expect(scopes.macHint == MACAddress("c4:2f:90:ab:cd:ef"))
        #expect(scopes.name == "Camera")
    }

    /// Garbage does not throw and does not lose anything: unrecognised scopes stay in `raw`.
    @Test func onvifScopesKeepsUnrecognisedScopes() {
        let scopes = ONVIFScopes.parse("nonsense onvif://www.onvif.org/wibble/x %%% ")
        #expect(scopes.name == nil)
        #expect(scopes.raw == ["nonsense", "onvif://www.onvif.org/wibble/x", "%%%"])
        #expect(ONVIFScopes.parse("").raw.isEmpty)
    }

    /// Percent decoding, including an invalid escape that must survive verbatim.
    @Test func onvifScopesPercentDecodesValues() {
        #expect(ONVIFScopes.percentDecoded("HIKVISION%20DS-2") == "HIKVISION DS-2")
        #expect(ONVIFScopes.percentDecoded("c4%3A2f") == "c4:2f")
        #expect(ONVIFScopes.percentDecoded("100%") == "100%")
        #expect(ONVIFScopes.percentDecoded("%zz") == "%zz")
        #expect(ONVIFScopes.percentDecoded("plain") == "plain")
    }

    /// PTZ detection: an explicit `type/ptz`, or Profile S plus a dome model.
    @Test func onvifScopesDetectsPTZ() {
        #expect(ONVIFScopes(types: ["ptz"]).indicatesPTZ)
        #expect(ONVIFScopes(hardware: "DS-2DE4A425IW-DE SPEED DOME", profiles: ["S"]).indicatesPTZ)
        #expect(!ONVIFScopes(hardware: "DS-2CD2143G0-I", profiles: ["S"]).indicatesPTZ)
        #expect(!ONVIFScopes().indicatesPTZ)
    }

    /// Union keeps the first scalar and merges the lists, so two ProbeMatches lose nothing.
    @Test func onvifScopesUnionMergesWithoutLoss() {
        var first = ONVIFScopes(name: "Front", profiles: ["S"], raw: ["a"])
        first.formUnion(ONVIFScopes(name: "Other", hardware: "DS-2CD", profiles: ["S", "G"],
                                    raw: ["a", "b"]))
        #expect(first.name == "Front")
        #expect(first.hardware == "DS-2CD")
        #expect(first.profiles == ["S", "G"])
        #expect(first.raw == ["a", "b"])
    }
}
