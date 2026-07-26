//
//  DiscoveryModelTests.swift
//  VigilDiscoveryTests
//
//  The value types the rest of the app sees: identity-only equality on a record, the Codable round
//  trip that persistence depends on, the trust ladder that drives field precedence, the probe-result
//  liveness helpers, and the diagnostics a user actually reads.
//  Covers docs/spec-discovery.md §3, §7.3, §8 and §12.
//

import Foundation
import Testing

import VigilProtocols
@testable import VigilDiscovery

@Suite struct DiscoveryModelBehaviour {

    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static func device() throws -> DiscoveredDevice {
        let mac = try #require(MACAddress("c4:2f:90:ab:cd:ef"))
        var device = DiscoveredDevice(id: .mac(mac), address: IPv4Address(192, 168, 1, 64),
                                     firstSeen: epoch, lastSeen: epoch.addingTimeInterval(3))
        device.alternateIdentities = [.endpoint(IPv4Address(192, 168, 1, 64), 80)]
        device.mac = mac
        device.serialNumber = "DS-2CD2143G0-I20200114AAWRD12345678"
        device.model = "DS-2CD2143G0-I"
        device.vendor = .hikvision
        device.deviceClass = .camera
        device.activation = .notActivated
        device.reachability = .reachable
        device.openPorts = [80, 554, 8_000]
        device.commandPort = 8_000
        device.onvifScopes = ONVIFScopes(name: "HIKVISION DS-2CD2143G0-I", profiles: ["Streaming"],
                                         raw: ["onvif://www.onvif.org/name/HIKVISION"])
        device.onvifServiceURLs = ["http://192.168.1.64/onvif/device_service"]
        device.bootTime = epoch
        device.sources = [.sadpMulticast, .tcpSweep]
        device.provenance = [.model: FieldStamp(source: .sadpMulticast, observedAt: epoch),
                            .openPorts: FieldStamp(source: .tcpSweep, observedAt: epoch)]
        device.confidence = 85
        return device
    }

    // MARK: - Identity semantics

    /// A record hashes and compares on identity alone: merging mutates every other field in place,
    /// and the UI keys rows by `id`.
    @Test func discoveryModelDeviceEqualityUsesIdentityOnly() throws {
        let first = try Self.device()
        var second = first
        second.confidence = 3
        second.address = IPv4Address(10, 0, 0, 1)
        second.vendor = .dahua
        #expect(first == second)
        #expect(Set([first, second]).count == 1)
    }

    /// The record survives a Codable round trip: `library.json` and the discovery cache both need it.
    @Test func discoveryModelDeviceRoundTripsThroughCodable() throws {
        let original = try Self.device()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoded = try JSONDecoder().decode(DiscoveredDevice.self,
                                               from: try encoder.encode(original))
        #expect(decoded.id == original.id)
        #expect(decoded.mac == original.mac)
        #expect(decoded.serialNumber == original.serialNumber)
        #expect(decoded.openPorts == original.openPorts)
        #expect(decoded.vendor == original.vendor)
        #expect(decoded.activation == original.activation)
        #expect(decoded.onvifScopes == original.onvifScopes)
        #expect(decoded.provenance == original.provenance)
        #expect(decoded.confidence == original.confidence)
        #expect(decoded.alternateIdentities == original.alternateIdentities)
    }

    /// Every `FieldValue` shape round trips too, since observations are logged and replayed.
    @Test func discoveryModelFieldValueRoundTripsEveryCase() throws {
        let mac = try #require(MACAddress("c4:2f:90:ab:cd:ef"))
        let values: [FieldValue] = [
            .string("DS-2CD2143G0-I"), .int(16), .bool(true), .port(8_000),
            .ipv4(IPv4Address(192, 168, 1, 64)), .date(Self.epoch), .ports([80, 554]),
            .strings(["a", "b"]), .scopes(ONVIFScopes(name: "Camera")), .vendor(.hikvision),
            .deviceClass(.nvr), .activation(.notActivated), .reachability(.offSubnet), .mac(mac),
        ]
        let encoded = try JSONEncoder().encode(values)
        #expect(try JSONDecoder().decode([FieldValue].self, from: encoded) == values)
    }

    /// A known-device snapshot normalises its stored serial the same way the engine does.
    @Test func discoveryModelKnownDeviceSnapshotNormalisesItsSerial() throws {
        let snapshot = KnownDeviceSnapshot(identity: .endpoint(IPv4Address(192, 168, 1, 64), 80),
                                          serialNumber: " ds-2cd2143g0-i20200114aawrd12345678 ",
                                          lastKnownAddress: IPv4Address(192, 168, 1, 64))
        #expect(snapshot.serialKey == "DS-2CD2143G0-I20200114AAWRD12345678")
        let unusable = KnownDeviceSnapshot(identity: .endpoint(IPv4Address(192, 168, 1, 64), 80),
                                          serialNumber: "12",
                                          lastKnownAddress: IPv4Address(192, 168, 1, 64))
        #expect(unusable.serialKey == nil)
    }

    // MARK: - Trust ladder

    /// §7.3's ordering, spelled out: the user outranks SADP, SADP outranks a header sniff, and
    /// anything we merely persisted comes last.
    @Test func discoveryModelSourceTrustIsOrdered() {
        let ordered: [DiscoverySource] = [.manual, .sadpMulticast, .isapiFingerprint, .wsDiscovery,
                                          .rtspFingerprint, .tcpSweep, .bonjour, .arpCache,
                                          .persisted]
        #expect(ordered.map(\.trust) == [100, 90, 70, 60, 50, 30, 25, 20, 10])
        #expect(DiscoverySource.sadpUnicast.trust == DiscoverySource.sadpMulticast.trust)
        #expect(DiscoverySource.allCases.allSatisfy { $0.trust > 0 })
        #expect(DiscoverySource.arpCache.isExistenceOnly)
        #expect(DiscoverySource.bonjour.isExistenceOnly)
        #expect(!DiscoverySource.sadpMulticast.isExistenceOnly)
    }

    /// The vendor properties the UI and `VigilCore` branch on.
    @Test func discoveryModelVendorCapabilitiesAreExplicit() {
        #expect(DeviceVendor.hikvision.supportsISAPI)
        #expect(DeviceVendor.hikvisionOEM.supportsISAPI)
        #expect(!DeviceVendor.dahua.supportsISAPI)
        #expect(!DeviceVendor.genericONVIF.supportsISAPI)
        #expect(DeviceVendor.dahua.isSpecific)
        #expect(!DeviceVendor.genericRTSP.isSpecific)
        #expect(!DeviceVendor.unknown.isSpecific)
        #expect(DeviceVendor.dahua.displayName == "Dahua")
        #expect(DeviceVendor.allCases.allSatisfy { !$0.displayName.isEmpty })
    }

    /// Device-class specificity, which is what stops `.ptzCamera` being demoted to `.camera`.
    @Test func discoveryModelDeviceClassSpecificityRanks() {
        #expect(DeviceClass.unknown.specificity == 0)
        #expect(DeviceClass.camera.specificity == 1)
        #expect(DeviceClass.ptzCamera.specificity > DeviceClass.camera.specificity)
        #expect(DeviceClass.nvr.specificity > DeviceClass.camera.specificity)
    }

    // MARK: - Probe results

    /// A refused port proves a host exists; a silent host does not; policy blocks are called out
    /// separately because they mean "ask macOS", not "nothing is there".
    @Test func discoveryModelHostProbeResultReportsLiveness() {
        let refused = HostProbeResult(address: IPv4Address(10, 0, 0, 2),
                                     portOutcomes: [80: .refused])
        #expect(refused.isAlive)
        #expect(!refused.isSilent)
        #expect(refused.openPorts.isEmpty)

        let open = HostProbeResult(address: IPv4Address(10, 0, 0, 3),
                                   portOutcomes: [80: .open, 554: .timedOut])
        #expect(open.openPorts == [80])
        #expect(open.isAlive)

        let silent = HostProbeResult(address: IPv4Address(10, 0, 0, 4),
                                     portOutcomes: [80: .timedOut, 554: .timedOut])
        #expect(!silent.isAlive)
        #expect(silent.isSilent)

        let blocked = HostProbeResult(address: IPv4Address(10, 0, 0, 5),
                                      portOutcomes: [80: .blockedByPolicy])
        #expect(blocked.wasBlockedByPolicy)
        #expect(blocked.isSilent)

        let unprobed = HostProbeResult(address: IPv4Address(10, 0, 0, 6))
        #expect(!unprobed.isSilent)
        #expect(TCPProbeOutcome.unreachable(POSIXCode(rawValue: 65)).provesHostAlive == false)
    }

    /// An interface's subnet and gateway guess, including the invalid-netmask case.
    @Test func discoveryModelInterfaceDerivesSubnetAndGateway() {
        let interface = NetworkInterfaceInfo(name: "en0", address: IPv4Address(192, 168, 1, 10),
                                             netmask: IPv4Address(255, 255, 255, 0))
        #expect(interface.subnet == IPv4Subnet(network: IPv4Address(192, 168, 1, 0),
                                               prefixLength: 24))
        #expect(interface.likelyGateway == IPv4Address(192, 168, 1, 1))

        let broken = NetworkInterfaceInfo(name: "en1", address: IPv4Address(192, 168, 1, 10),
                                          netmask: IPv4Address(255, 0, 255, 0))
        #expect(broken.subnet == nil)
        #expect(broken.likelyGateway == nil)

        let pointToPoint = NetworkInterfaceInfo(name: "utun0", address: IPv4Address(10, 8, 0, 2),
                                                netmask: IPv4Address(255, 255, 255, 255))
        #expect(pointToPoint.likelyGateway == nil)      // a /32 has no first usable host to guess
    }

    // MARK: - Configuration

    /// The politeness budget of §6.10 and the tier A port set.
    @Test func discoveryModelConfigurationComputesBudgets() {
        let configuration = DiscoveryConfiguration.default
        #expect(configuration.maxTCPConnects(plannedHosts: 254) == 4 * 254 + 512)
        #expect(configuration.maxTCPConnects(plannedHosts: 0) == 512)
        #expect(configuration.maxTCPConnects(plannedHosts: -3) == 512)
        #expect(configuration.maxDatagramsPerRun == 8_192)
        #expect(configuration.tcpConnectTimeout == .milliseconds(350))
        #expect(configuration.fingerprintTimeout == .milliseconds(600))
        #expect(configuration.maxInFlightConnects == 128)
        #expect(configuration.effectiveTierAPorts == [554, 80])
        #expect(configuration.tierBPorts == [8_000, 443, 8_080])
        #expect(configuration.tierCPorts == [37_777, 8_554, 2_020])
        #expect(configuration.sadpProbeSchedule == [.zero, .milliseconds(500),
                                                    .milliseconds(1_000)])
    }

    /// Only `.multicastOnly` skips the sweep.
    @Test func discoveryModelModeKnowsWhetherItSweeps() {
        #expect(DiscoveryConfiguration.Mode.fullScan.includesSweep)
        #expect(!DiscoveryConfiguration.Mode.multicastOnly.includesSweep)
        #expect(DiscoveryConfiguration.Mode.subnets([]).includesSweep)
        #expect(DiscoveryConfiguration.Mode
            .single(address: IPv4Address(192, 168, 1, 64), ports: [80]).includesSweep)
    }

    // MARK: - Entitlements and diagnostics

    /// The empirical result outranks the signature: an entitlement that demonstrably does not work
    /// must not be retried on every run.
    @Test func discoveryModelEntitlementStatusGatesMulticast() {
        #expect(!EntitlementStatus.unknown.shouldAttemptMulticast)
        #expect(EntitlementStatus(multicastEntitlementPresent: true).shouldAttemptMulticast)
        #expect(!EntitlementStatus(multicastEntitlementPresent: true,
                                   multicastVerifiedWorking: false).shouldAttemptMulticast)
        #expect(EntitlementStatus(multicastEntitlementPresent: true,
                                  multicastVerifiedWorking: true).shouldAttemptMulticast)
        #expect(EntitlementStatus.unknown.localNetworkPermission == .unknown)
    }

    /// Diagnostics that change what the user sees carry text; purely technical ones do not.
    @Test func discoveryModelDiagnosticsSpeakPlainlyWhereItMatters() {
        let subnet = IPv4Subnet(network: IPv4Address(10, 0, 0, 0), prefixLength: 16)
        let narrowed = DiscoveryDiagnostic.subnetNarrowed(
            from: subnet, to: [IPv4Subnet(network: IPv4Address(10, 0, 1, 0), prefixLength: 24)])
        #expect(narrowed.userFacingMessage?.contains("1 likely range") == true)
        #expect(narrowed.severity == .warning)

        let denied = DiscoveryDiagnostic.localNetworkPermissionLikelyDenied(
            interface: "en0", gateway: IPv4Address(192, 168, 1, 1))
        #expect(denied.severity == .actionRequired)
        #expect(denied.userFacingMessage?.contains("Local Network") == true)

        let offSubnet = DiscoveryDiagnostic.offSubnetDeviceSeen(
            address: IPv4Address(192, 168, 1, 64), ourSubnets: [subnet])
        #expect(offSubnet.severity == .actionRequired)
        #expect(offSubnet.userFacingMessage?.contains("192.168.1.64") == true)

        let multicast = DiscoveryDiagnostic.multicastUnavailable(reason: .entitlementMissing)
        #expect(multicast.userFacingMessage?.contains("different subnet") == true)

        let technical = DiscoveryDiagnostic.concurrencyClamped(to: 64, fileDescriptorLimit: 256)
        #expect(technical.userFacingMessage == nil)
        #expect(technical.severity == .info)
        #expect(DiscoveryDiagnostic.tunnelInterfaceSkipped(name: "utun3").userFacingMessage == nil)
    }

    /// Diagnostics are Codable so a support bundle can carry them verbatim.
    @Test func discoveryModelDiagnosticsRoundTripThroughCodable() throws {
        let diagnostics: [DiscoveryDiagnostic] = [
            .subnetTooWide(subnet: IPv4Subnet(network: IPv4Address(10, 0, 0, 0), prefixLength: 8),
                           hostCount: 16_777_214),
            .budgetExhausted(kind: .tcpConnects, limit: 1_528),
            .sadpOpaquePayload(from: IPv4Address(192, 168, 1, 64), length: 96, prefixHex: "deadbeef",
                               entropy: 7.5),
        ]
        let encoded = try JSONEncoder().encode(diagnostics)
        #expect(try JSONDecoder().decode([DiscoveryDiagnostic].self, from: encoded) == diagnostics)
    }

    // MARK: - Summaries

    /// A deadlined run reports what is left, which is what the "Keep scanning" button needs.
    @Test func discoveryModelSummaryKnowsWhatIsLeft() throws {
        let summary = DiscoverySummary(terminationReason: .deadline, devices: [try Self.device()],
                                       elapsed: .seconds(45), hostsProbed: 12_480,
                                       hostsPlanned: 65_534)
        #expect(summary.hasUnscannedHosts)
        #expect(summary.devices.count == 1)
        let complete = DiscoverySummary(terminationReason: .completed, devices: [],
                                        elapsed: .seconds(3), hostsProbed: 254, hostsPlanned: 254)
        #expect(!complete.hasUnscannedHosts)
    }

    /// Phase summaries are Codable and carry the counters a support log needs.
    @Test func discoveryModelPhaseSummaryCarriesCounters() throws {
        let summary = PhaseSummary(phase: .sadp, duration: .milliseconds(3_500),
                                   devicesContributed: 2, datagramsSent: 3, datagramsReceived: 7,
                                   connectsAttempted: 0)
        let decoded = try JSONDecoder().decode(PhaseSummary.self,
                                               from: try JSONEncoder().encode(summary))
        #expect(decoded == summary)
        #expect(decoded.duration == .milliseconds(3_500))
    }
}
