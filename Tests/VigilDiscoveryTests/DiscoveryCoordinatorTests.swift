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
@Suite(.serialized) struct DiscoveryCoordinatorOrchestration {

    // MARK: - Helpers

    /// A `/29` inside the default interface's `/24`: six hosts, so a whole run's probe traffic is
    /// small enough to reason about host by host.
    static let smallRange = IPv4Subnet(network: IPv4Address(192, 168, 1, 8), prefixLength: 29)

    /// A `/27`: 30 hosts, the smallest range that can arm the §9.4 permission heuristic.
    static let mediumRange = IPv4Subnet(network: IPv4Address(192, 168, 1, 32), prefixLength: 27)

    static func configuration(_ subnet: IPv4Subnet,
                              deadline: Duration? = nil) -> DiscoveryConfiguration {
        var configuration = DiscoveryConfiguration()
        configuration.mode = .subnets([subnet])
        configuration.overallDeadlineOverride = deadline
        return configuration
    }

    /// One Hikvision camera at 192.168.1.12, answering SADP, TCP and both fingerprints.
    static func cameraScript() -> DiscoveryTestBed.Script {
        var script = DiscoveryTestBed.Script()
        script.sadpAnswers = [ScriptedDatagram(delay: .milliseconds(40),
                                               text: SADPFixtures.activatedCameraXML,
                                               source: IPv4Address(192, 168, 1, 64),
                                               sourcePort: SADPCodec.port)]
        script.ports = [IPv4Address(192, 168, 1, 12).rawValue: CoordinatorFixtures.hikvisionPorts]
        script.http = [IPv4Address(192, 168, 1, 12).rawValue:
            MockHTTPResponses(rtspOptions: CoordinatorFixtures.hikvisionRTSP(),
                              isapiDeviceInfo: CoordinatorFixtures.hikvisionISAPI401)]
        return script
    }

    // MARK: - 78. Phase ordering and overlap

    /// Test 78. The §2.2 timetable, measured on the virtual clock: both multicast mechanisms start at
    /// t=10 ms, the sweep at t=250 ms, and the multicast channels close at t=3 510 ms — the last probe
    /// at 1 000 ms plus the 2 500 ms listen tail. The offsets are the whole design: the sweep is held
    /// back so multicast answers land on an idle NIC, and the tail exists because slow NVRs answer
    /// two seconds late.
    @Test func discoveryCoordinatorSequencesPhasesOnTheSpecTimetable() async {
        let bed = DiscoveryTestBed(Self.cameraScript())
        let result = await bed.run(Self.configuration(Self.smallRange))

        #expect(result.terminationReason == .completed)

        let sadp = bed.sadpChannels.first
        let wsd = bed.wsdChannels.first
        let sadpProbes = sadp?.sent ?? []
        let wsdProbes = wsd?.sent ?? []
        #expect(sadpProbes.count == 3)
        #expect(wsdProbes.count == 3)
        // 10 ms + the [0, 500, 1000] schedule.
        let trace = bed.clock.advanceLog.joined(separator: " ")
        #expect(sadpProbes.map(\.at.nanoseconds) == [10_000_000, 510_000_000, 1_010_000_000],
                "virtual time went: \(trace)")
        #expect(wsdProbes.map(\.at.nanoseconds) == [10_000_000, 510_000_000, 1_010_000_000])
        #expect(sadpProbes.allSatisfy { $0.host == .discoveryMulticastGroup })
        #expect(sadpProbes.allSatisfy { $0.port == SADPCodec.port })
        #expect(wsdProbes.allSatisfy { $0.port == WSDiscoveryCodec.port })

        // The window is fixed at the start of the run, so both channels close together at 3 510 ms
        // however the phases interleaved.
        #expect(sadp?.closedAt?.nanoseconds == 3_510_000_000)
        #expect(wsd?.closedAt?.nanoseconds == 3_510_000_000)

        let firstProbe = bed.prober.probes.map(\.at.nanoseconds).min()
        #expect(firstProbe == 250_000_000)
        #expect(result.phase(.planning) != nil)
        #expect(result.phase(.sadp) != nil)
        #expect(result.phase(.onvif) != nil)
        #expect(result.phase(.sweepA) != nil)
    }

    /// The multicast listening window is decided once. A channel that fails to open halfway through
    /// flips the run to degraded, and if the window were recomputed the interfaces still listening
    /// would have their tail cut off and the progress bar's multicast quarter would jump to complete.
    @Test func discoveryCoordinatorKeepsTheMulticastWindowFixedForTheWholeRun() async {
        var script = Self.cameraScript()
        script.interfaces = [DiscoveryTestBed.defaultInterface,
                             NetworkInterfaceInfo(name: "en1",
                                                  address: IPv4Address(192, 168, 1, 11),
                                                  netmask: IPv4Address(255, 255, 255, 0))]
        let bed = DiscoveryTestBed(script)
        let result = await bed.run(Self.configuration(Self.smallRange))

        #expect(result.terminationReason == .completed)
        // Four channels: SADP and WS-Discovery on each of the two links (§4.1).
        #expect(bed.multicastChannels.count == 4)
        for channel in bed.multicastChannels {
            #expect(channel.closedAt?.nanoseconds == 3_510_000_000)
        }
        let window = result.progressEvents.map(\.multicastWindowRemaining).max()
        #expect((window ?? .zero) <= .milliseconds(3_510))
    }

    // MARK: - 79–82. Progress and ETA

    /// Test 79. The fraction never decreases, even though tier B grows the denominator mid-run.
    @Test func discoveryCoordinatorFractionNeverDecreases() async {
        var script = Self.cameraScript()
        // Several live hosts, so tier B is scheduled repeatedly while the bar is moving.
        for last: UInt8 in [9, 10, 11, 12, 13, 14] {
            script.ports[IPv4Address(192, 168, 1, last).rawValue] = CoordinatorFixtures
                .hikvisionPorts
        }
        let bed = DiscoveryTestBed(script)
        let result = await bed.run(Self.configuration(Self.smallRange))

        let fractions = result.progressEvents.compactMap(\.fraction)
        #expect(fractions.count > 3)
        var previous = 0.0
        for fraction in fractions {
            #expect(fraction >= previous - 1e-9, "fraction went backwards: \(fractions)")
            #expect(fraction <= 1.0)
            previous = fraction
        }
        // The denominator really did grow: tier B adds three ports for each of the six live hosts.
        let planned = result.progressEvents.map(\.portProbesPlanned)
        #expect((planned.max() ?? 0) > (planned.min() ?? 0))
    }

    /// Test 80. Progress is coalesced to at most 20 emissions per second. Measured on a run that
    /// finds nothing, because a device event legitimately forces an extra emission and would mask the
    /// throttle; the forcing itself is asserted separately below.
    @Test func discoveryCoordinatorCoalescesProgressToTwentyHertz() async {
        var script = DiscoveryTestBed.Script()
        // 30 silent hosts: many completions, no device events at all.
        script.answerLatency = .milliseconds(5)
        let bed = DiscoveryTestBed(script)
        let result = await bed.run(Self.configuration(Self.mediumRange))

        #expect(result.progressEvents.count > 5)
        var perSecond: [Int: Int] = [:]
        for progress in result.progressEvents {
            perSecond[Int(progress.elapsed.asSeconds), default: 0] += 1
        }
        #expect(result.deviceFoundEvents.isEmpty)
        for (second, count) in perSecond {
            #expect(count <= 21, "second \(second) carried \(count) progress events")
        }
    }

    /// Test 80, second half. A device event forces an immediate progress emission, so the counter in
    /// the sheet's header can never lag a row the user can already see (§8.1).
    @Test func discoveryCoordinatorForcesProgressAfterEveryDeviceEvent() async {
        let bed = DiscoveryTestBed(Self.cameraScript())
        let result = await bed.run(Self.configuration(Self.smallRange))

        #expect(!result.deviceFoundEvents.isEmpty)
        for (index, event) in result.events.enumerated() where event.forcesProgressEmission {
            // One ingest can also raise a diagnostic — an off-subnet sighting, an identity
            // conflict — and those are emitted between the device event and the forced snapshot.
            var next = index + 1
            while next < result.events.count, case .diagnostic = result.events[next] { next += 1 }
            var isProgress = false
            if next < result.events.count, case .progress = result.events[next] { isProgress = true }
            #expect(isProgress, "event \(index) was not followed by progress: \(result.trace)")
        }
        // And the forced snapshot already knows about the device it followed.
        if let foundIndex = result.firstIndex(where: { $0.isDeviceFound }) {
            var next = foundIndex + 1
            while next < result.events.count, case .diagnostic = result.events[next] { next += 1 }
            if next < result.events.count, case let .progress(progress) = result.events[next] {
                #expect(progress.candidatesFound >= 1)
            }
        }
    }

    /// Test 81. No ETA for the first 750 ms, and none while throughput is too low to extrapolate
    /// from. A wrong number is worse than no number.
    @Test func discoveryCoordinatorSuppressesTheETAEarly() async {
        let bed = DiscoveryTestBed(Self.cameraScript())
        let result = await bed.run(Self.configuration(Self.mediumRange))

        let early = result.progressEvents.filter { $0.elapsed < .milliseconds(750) }
        #expect(!early.isEmpty)
        for progress in early {
            #expect(progress.estimatedRemaining == nil)
            #expect(progress.estimatedRemainingText == nil)
        }
    }

    /// Test 82. A displayed ETA may fall freely but may not grow by more than 20 % between
    /// emissions: a jittery ETA reads as a broken app even when the arithmetic is right.
    @Test func discoveryCoordinatorETADoesNotJumpUpward() async {
        var script = DiscoveryTestBed.Script()
        script.ports = [IPv4Address(192, 168, 1, 40).rawValue: CoordinatorFixtures.hikvisionPorts]
        script.http = [IPv4Address(192, 168, 1, 40).rawValue:
            MockHTTPResponses(rtspOptions: CoordinatorFixtures.hikvisionRTSP())]
        let bed = DiscoveryTestBed(script)
        let result = await bed.run(Self.configuration(Self.mediumRange))

        var previous: Double?
        for progress in result.progressEvents {
            guard let eta = progress.estimatedRemaining?.asSeconds else {
                previous = nil
                continue
            }
            if let previous {
                #expect(eta <= previous * 1.2 + 1e-6,
                        "ETA grew from \(previous) s to \(eta) s in one emission")
            }
            previous = eta
        }
    }

    // MARK: - 83. Concurrency ceiling

    /// Test 83. Simultaneous connects never exceed `maxInFlightConnects`. Ports are probed
    /// sequentially per host, so the ceiling is a count of live hosts and this is the only place it
    /// can be observed from outside.
    @Test func discoveryCoordinatorNeverExceedsTheConcurrencyCeiling() async {
        var script = DiscoveryTestBed.Script()
        script.answerLatency = .milliseconds(20)
        let bed = DiscoveryTestBed(script)
        var configuration = Self.configuration(Self.mediumRange)
        configuration.maxInFlightConnects = 6
        let result = await bed.run(configuration)

        #expect(result.terminationReason == .completed)
        #expect(bed.prober.peakInFlight <= 6, "peak was \(bed.prober.peakInFlight)")
        #expect(bed.prober.peakInFlight > 1, "the sweep did not actually run concurrently")
        // 30 planned hosts plus the gateway canary, which is a deliberate extra host (§9.4).
        let gateway = result.plan?.interfaces.first?.likelyGateway?.rawValue
        #expect(bed.prober.probedHosts.subtracting([gateway ?? 0]).count == 30)
        // Every host was probed exactly once per tier A port: no retries within a run (§6.10).
        let perHostPort = Dictionary(grouping: bed.prober.probes) { "\($0.host):\($0.port)" }
        #expect(perHostPort.values.allSatisfy { $0.count == 1 })
    }

    // MARK: - 84. The time budget

    /// Test 84. A network where nothing ever answers must still end, on the deadline, delivering
    /// whatever multicast found. A deadline is not a failure and never discards records.
    @Test func discoveryCoordinatorDeadlineTerminatesWithResults() async {
        var script = Self.cameraScript()
        script.neverAnswers = true
        let bed = DiscoveryTestBed(script)
        var configuration = Self.configuration(Self.mediumRange)
        configuration.overallDeadlineOverride = .seconds(6)
        let result = await bed.run(configuration)

        #expect(result.terminationReason == .deadline)
        // The SADP camera arrived at 40 ms and survives the deadline.
        #expect(result.devices.count == 1)
        #expect(result.devices.first?.address == IPv4Address(192, 168, 1, 64))
        let summary = result.summary
        #expect(summary?.hasUnscannedHosts == true)
        #expect(summary?.hostsProbed == 0)
        #expect((summary?.elapsed ?? .zero) >= .seconds(6))
        #expect((summary?.elapsed ?? .zero) < .seconds(7))
        // Every socket is shut, even though the sweep was still mid-flight.
        #expect(bed.channels.allSatisfy { $0.isClosed })
    }

    /// The deadline is sized from the plan when no override is given: 12 s for a `/24` or smaller.
    @Test func discoveryCoordinatorUsesTheSizedDeadlineWhenNoOverrideIsGiven() async {
        var script = DiscoveryTestBed.Script()
        script.neverAnswers = true
        let bed = DiscoveryTestBed(script)
        let result = await bed.run(Self.configuration(Self.mediumRange))

        #expect(result.terminationReason == .deadline)
        let elapsed = result.summary?.elapsed ?? .zero
        #expect(elapsed >= DiscoveryDeadline.base)
        #expect(elapsed < DiscoveryDeadline.base + .seconds(1))
    }

    // MARK: - 85–86. Cancellation

    /// Test 85. `cancel()` mid-sweep ends the run as `.cancelled`, closes every socket, and stops
    /// probing. The bar freezes where it stood and the ETA disappears — an ETA for work that will
    /// never happen is a lie (§8.4).
    @Test func discoveryCoordinatorCancelFreezesProgressAndClosesEverything() async {
        var script = DiscoveryTestBed.Script()
        script.answerLatency = .milliseconds(20)
        script.ports = [IPv4Address(192, 168, 1, 40).rawValue: CoordinatorFixtures.hikvisionPorts]
        let bed = DiscoveryTestBed(script)
        var configuration = Self.configuration(Self.mediumRange)
        configuration.maxInFlightConnects = 4
        let result = await bed.run(configuration) { event, coordinator in
            // Cancel as soon as the sweep is visibly under way, which is a point in the event
            // sequence rather than a moment on any clock.
            if case let .progress(progress) = event, progress.hostsProbed >= 4 {
                await coordinator.cancel()
            }
            return .keepConsuming
        }

        #expect(result.terminationReason == .cancelled)
        #expect(bed.channels.allSatisfy { $0.isClosed })
        // Results survive a cancellation.
        #expect((result.summary?.hostsProbed ?? 0) >= 4)
        #expect(result.summary?.hasUnscannedHosts == true)

        // The last progress snapshot is the frozen one: no ETA, and a fraction that did not move
        // past the previous emission.
        let progressEvents = result.progressEvents
        let last = progressEvents.last
        #expect(last?.estimatedRemaining == nil)
        #expect(last?.estimatedRemainingText == nil)
        #expect(last?.phase == .finished)
        if progressEvents.count >= 2 {
            let previous = progressEvents[progressEvents.count - 2]
            if let frozen = last?.fraction, let before = previous.fraction {
                #expect(frozen == before, "the bar moved after cancellation")
            }
        }
        // Nothing keeps touching the network once the run has ended.
        let probesAtEnd = bed.prober.probes.count
        for _ in 0..<200 { await Task.yield() }
        #expect(bed.prober.probes.count == probesAtEnd)
        #expect(bed.prober.probedHosts.count < 30, "the sweep ran to completion despite cancel()")
    }

    /// Test 86. Breaking out of the `for await` — the sheet being dismissed — terminates the stream,
    /// which cancels the run through `onTermination`. There is no way to leak a running sweep.
    @Test func discoveryCoordinatorStreamTerminationCancelsTheRun() async {
        var script = DiscoveryTestBed.Script()
        script.answerLatency = .milliseconds(20)
        let bed = DiscoveryTestBed(script)
        let result = await bed.run(Self.configuration(Self.mediumRange)) { event, _ in
            if case let .progress(progress) = event, progress.hostsProbed >= 2 {
                return .stopConsuming
            }
            return .keepConsuming
        }

        // No `.finished` was consumed — we walked away before it.
        #expect(result.summary == nil)
        #expect(bed.channels.allSatisfy { $0.isClosed }, "a socket outlived its consumer")
        let probesAtEnd = bed.prober.probes.count
        for _ in 0..<200 { await Task.yield() }
        #expect(bed.prober.probes.count == probesAtEnd)
    }

    /// Cancelling before anything happened still produces a well-formed ending rather than a hang.
    @Test func discoveryCoordinatorCancelBeforeTheFirstProbeStillFinishes() async {
        let bed = DiscoveryTestBed(Self.cameraScript())
        let result = await bed.run(Self.configuration(Self.smallRange)) { event, coordinator in
            if case .started = event { await coordinator.cancel() }
            return .keepConsuming
        }

        #expect(result.terminationReason == .cancelled)
        #expect(result.devices.isEmpty)
        #expect(bed.channels.allSatisfy { $0.isClosed })
    }

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
