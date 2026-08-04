//
//  DiscoveryCoordinatorTests.swift
//  VigilDiscoveryTests
//
//  The orchestration itself, driven entirely through fake sockets on a virtual clock: phase order and
//  overlap, the 20 Hz progress emitter, the ETA rules, the concurrency ceiling, the time budget,
//  cancellation, the politeness budgets, and the guarantee that not one byte of a credential leaves.
//  Covers docs/spec-discovery.md §2.2, §8.1–§8.4 and §6.10; tests 78–90 of §13.7.
//

import Foundation
import Testing

import VigilProtocols
@testable import VigilDiscovery

// A run drives dozens of concurrent tasks through one virtual clock, and the clock's scheduler
// infers quiescence from them. Two of those running at once on a small machine starve each other's
// tasks and make the inference wrong, so the coordinator suites run one test at a time.
extension DiscoveryCoordinatorOrchestration {
    // MARK: - 87. Budgets

    /// Test 87. A politeness budget that runs out stops the sending and keeps the results, with a
    /// diagnostic that says so. A scan that is politely incomplete beats one that looks like a flood.
    @Test func discoveryCoordinatorReportsBudgetExhaustionAndKeepsResults() async {
        let bed = DiscoveryTestBed(Self.cameraScript())
        var configuration = Self.configuration(Self.smallRange)
        // Six probes are scheduled (three SADP, three WS-Discovery) plus the unicast follow-ups.
        configuration.maxDatagramsPerRun = 4
        let result = await bed.run(configuration)

        #expect(result.terminationReason == .completed)
        let budget = result.diagnostics.compactMap { diagnostic -> Int? in
            if case let .budgetExhausted(kind, limit) = diagnostic, kind == .datagrams {
                return limit
            }
            return nil
        }
        #expect(budget == [4], "expected exactly one datagram-budget diagnostic: \(result.trace)")
        #expect(bed.allSent.count == 4, "more datagrams left than the budget allowed")
        // Everything found before the budget ran out is still reported: the SADP camera and the
        // swept host. A budget bounds what we *send*, never what we keep.
        #expect(result.devices.count == 2)
        #expect(result.devices.contains { $0.address == IPv4Address(192, 168, 1, 64) })
        #expect(result.devices.contains { $0.address == IPv4Address(192, 168, 1, 12) })
    }

    /// The TCP connect budget of `4 × plannedHosts + 512` bounds the sweep the same way.
    @Test func discoveryCoordinatorStopsTheSweepAtTheConnectBudget() async {
        var script = DiscoveryTestBed.Script()
        script.answerLatency = .milliseconds(5)
        let bed = DiscoveryTestBed(script)
        var configuration = Self.configuration(Self.mediumRange)
        configuration.tierAPorts = [80]
        let result = await bed.run(configuration)

        #expect(result.terminationReason == .completed)
        let limit = configuration.maxTCPConnects(plannedHosts: 30)
        #expect(bed.prober.probes.count <= limit)
    }

    // MARK: - 88. Resuming

    /// Test 88. "Keep scanning" after a deadline resumes from `hostOrder[resumeFrom]`; the hosts the
    /// first run already covered are not probed again.
    @Test func discoveryCoordinatorResumeFromSkipsTheHostsAlreadyProbed() async {
        var script = DiscoveryTestBed.Script()
        script.answerLatency = .milliseconds(1)
        let bed = DiscoveryTestBed(script)
        var configuration = DiscoveryConfiguration()
        configuration.mode = .subnets([IPv4Subnet(network: IPv4Address(192, 168, 1, 0),
                                                  prefixLength: 24)])
        configuration.resumeFrom = 100
        configuration.tierAPorts = [80]
        configuration.maxInFlightConnects = 64
        let result = await bed.run(configuration)

        let plan = result.plan
        #expect(plan != nil)
        let order = plan?.hostOrder ?? []
        #expect(order.count == 254)
        #expect(result.summary?.hostsPlanned == 154)
        #expect(result.summary?.hostsProbed == 154)

        let probed = bed.prober.probedHosts
        let skipped = Set(order.prefix(100).map(\.rawValue))
        let gateway = plan?.interfaces.first?.likelyGateway?.rawValue
        // The gateway canary is a deliberate extra two connects before the sweep proper (§9.4).
        #expect(probed.subtracting(skipped.symmetricDifference([gateway ?? 0]))
            .isSuperset(of: [order[100].rawValue]))
        #expect(probed.intersection(skipped).subtracting([gateway ?? 0]).isEmpty,
                "a host before resumeFrom was probed again")
    }

    // MARK: - 89. Single address

    /// Test 89. `.single(address:)` probes exactly that address: no multicast group, no gateway
    /// canary, no other host, and it is over quickly. This is the post-activation re-check.
    @Test func discoveryCoordinatorSingleAddressModeProbesOnlyThatAddress() async {
        let target = IPv4Address(192, 168, 1, 64)
        var script = DiscoveryTestBed.Script()
        script.ports = [target.rawValue: CoordinatorFixtures.hikvisionPorts]
        script.http = [target.rawValue:
            MockHTTPResponses(rtspOptions: CoordinatorFixtures.hikvisionRTSP(),
                              isapiDeviceInfo: CoordinatorFixtures.hikvisionISAPI401)]
        script.unicastAnswers = [ScriptedDatagram(delay: .milliseconds(30),
                                                  text: SADPFixtures.activatedCameraXML,
                                                  source: target, sourcePort: SADPCodec.port)]
        let bed = DiscoveryTestBed(script)
        let result = await bed.run(.single(address: target))

        #expect(result.terminationReason == .completed)
        #expect(bed.multicastChannels.isEmpty, "a named address needs no group probe")
        #expect(bed.prober.probedHosts == [target.rawValue])
        #expect(result.summary?.hostsPlanned == 1)
        #expect(result.summary?.hostsProbed == 1)
        #expect(result.summary?.elapsed ?? .zero < .milliseconds(1_500))
        // No multicast means no `multicastUnavailable` noise: nothing was lost, so nothing is said.
        #expect(!result.diagnostics.contains { diagnostic in
            if case .multicastUnavailable = diagnostic { return true }
            return false
        })
        #expect(result.devices.count == 1)
        #expect(result.devices.first?.vendor == .hikvision)
    }

    /// `.single` ignores the `.fail` policy: the caller asked about one host, not about the network,
    /// so "multicast is unavailable" is not a reason to refuse.
    @Test func discoveryCoordinatorSingleAddressIgnoresTheFailPolicy() async {
        let target = IPv4Address(192, 168, 1, 64)
        var script = DiscoveryTestBed.Script()
        script.ports = [target.rawValue: CoordinatorFixtures.webOnlyPorts]
        let bed = DiscoveryTestBed(script)
        var configuration = DiscoveryConfiguration.single(address: target)
        configuration.multicastUnavailablePolicy = .fail
        let result = await bed.run(configuration)

        #expect(result.terminationReason == .completed)
    }

    // MARK: - A run that finds nothing

    /// The empty network. Everything times out, nothing is on the group, and the run still ends
    /// cleanly with a summary the UI can explain: hosts planned, hosts probed, no devices.
    @Test func discoveryCoordinatorRunThatFindsNothingStillEndsCleanly() async {
        let bed = DiscoveryTestBed()
        let result = await bed.run(Self.configuration(Self.smallRange))

        #expect(result.terminationReason == .completed)
        #expect(result.devices.isEmpty)
        #expect(result.deviceFoundEvents.isEmpty)
        #expect(result.summary?.hostsPlanned == 6)
        #expect(result.summary?.hostsProbed == 6)
        #expect(result.coordinatorSnapshot.isEmpty)
        // A plan was still published, so the sheet can say what it looked at.
        #expect(result.plan?.subnets == [Self.smallRange])
        // Six hosts is far too few to accuse macOS of blocking us (§9.4).
        #expect(!result.diagnostics.contains { diagnostic in
            if case .localNetworkPermissionLikelyDenied = diagnostic { return true }
            return false
        })
        #expect(bed.channels.allSatisfy { $0.isClosed })
        // `.started` is the first event, and `.finished` the last.
        var sawStarted = false
        if case .started = result.events.first { sawStarted = true }
        #expect(sawStarted)
        var sawFinished = false
        if case .finished = result.events.last { sawFinished = true }
        #expect(sawFinished)
    }

    /// A machine with no usable interface cannot scan, and says so instead of pretending to.
    @Test func discoveryCoordinatorFailsWhenNoInterfaceIsEligible() async {
        var script = DiscoveryTestBed.Script()
        script.interfaces = [NetworkInterfaceInfo(name: "lo0", address: IPv4Address(127, 0, 0, 1),
                                                  netmask: IPv4Address(255, 0, 0, 0))]
        let bed = DiscoveryTestBed(script)
        let result = await bed.run()

        #expect(result.terminationReason == .failed)
        #expect(result.devices.isEmpty)
        #expect(result.plan == nil)
    }

    // MARK: - One device, two protocols

    /// A camera that answers both SADP and WS-Discovery is **one** row, not two: the two sightings
    /// share an endpoint key, so the merge engine unifies them and the identity is promoted to the
    /// MAC that SADP supplied. Exactly one `.deviceFound` is emitted, ever.
    @Test func discoveryCoordinatorMergesOneDeviceAnsweringTwoProtocols() async {
        let camera = IPv4Address(192, 168, 1, 64)
        var script = DiscoveryTestBed.Script()
        script.sadpAnswers = [ScriptedDatagram(delay: .milliseconds(40),
                                               text: SADPFixtures.activatedCameraXML,
                                               source: camera, sourcePort: SADPCodec.port)]
        script.wsdAnswers = [ScriptedDatagram(delay: .milliseconds(120),
                                              text: WSDFixtures.hikvisionProbeMatchXML,
                                              source: camera)]
        script.ports = [camera.rawValue: CoordinatorFixtures.hikvisionPorts]
        script.http = [camera.rawValue:
            MockHTTPResponses(rtspOptions: CoordinatorFixtures.hikvisionRTSP(),
                              isapiDeviceInfo: CoordinatorFixtures.hikvisionISAPI401)]
        let bed = DiscoveryTestBed(script)
        let result = await bed.run(Self.configuration(
            IPv4Subnet(network: IPv4Address(192, 168, 1, 64), prefixLength: 30)))

        #expect(result.devices.count == 1, "two protocols produced \(result.devices.count) rows")
        #expect(result.deviceFoundEvents.count == 1)
        #expect(!result.deviceUpdatedEvents.isEmpty, "the second protocol changed nothing")

        let device = result.devices.first
        #expect(device?.id == .mac(MACAddress(0xC4, 0x2F, 0x90, 0xAB, 0xCD, 0xEF)))
        #expect(device?.vendor == .hikvision)
        #expect(device?.sources.contains(.sadpMulticast) == true)
        #expect(device?.sources.contains(.wsDiscovery) == true)
        // The ONVIF service URL and the SADP serial both survived the merge.
        #expect(device?.serialNumber == "DS-2CD2143G0-I20200114AAWRD12345678")
        #expect(device?.onvifServiceURLs.isEmpty == false)
    }

    // MARK: - 90. No credentials, ever

    /// Test 90. Across a whole run — three SADP probes, three WS-Discovery probes, unicast probes and
    /// every fingerprint request — not one byte of authentication material is sent. The doubles fail
    /// the test themselves on any violation; this asserts they were actually given something to scan,
    /// because a guard that never ran is not a guard.
    @Test func discoveryCoordinatorSendsNoCredentialsAnywhere() async {
        let camera = IPv4Address(192, 168, 1, 12)
        var script = Self.cameraScript()
        script.arp = [ARPEntry(address: camera,
                               mac: MACAddress(0xC4, 0x2F, 0x90, 0x11, 0x22, 0x33))]
        let bed = DiscoveryTestBed(script)
        let result = await bed.run(Self.configuration(Self.smallRange))

        #expect(result.terminationReason == .completed)
        let datagrams = bed.allSent
        #expect(datagrams.count >= 6)
        #expect(!bed.exchanger.requests.isEmpty)
        for datagram in datagrams {
            #expect(DiscoveryCredentialGuard.violations(in: datagram.payload).isEmpty)
        }
        for request in bed.exchanger.requests {
            #expect(DiscoveryCredentialGuard.violations(in: request).isEmpty)
        }
        // And the fingerprints really were the ones §6.6/§6.7 specify, not something inert.
        let texts = bed.exchanger.requests.map { String(decoding: $0, as: UTF8.self) }
        #expect(texts.contains { $0.hasPrefix("OPTIONS rtsp://") })
        #expect(texts.contains { $0.contains("/ISAPI/System/deviceInfo") })
    }
}
