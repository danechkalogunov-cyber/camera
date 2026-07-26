//
//  DiscoveryCoordinator.swift
//  VigilDiscovery
//
//  The actor that runs a discovery: it plans, opens the injected channels, sequences the three
//  mechanisms with their overlapping windows, sweeps under a concurrency ceiling and a set of
//  politeness budgets, folds every sighting through the merge engine, coalesces progress at 20 Hz,
//  and ends — completed, deadlined, cancelled or failed — always delivering what it found.
//  Implements docs/spec-discovery.md §2 (phases and budget), §8 (progress, ETA, cancellation),
//  §9.5 (degraded mode), §10.3 (public surface) and §12 (diagnostics).
//

import Foundation
import VigilProtocols

// MARK: - Coordinator

/// Runs one discovery and reports it as a stream of events.
///
/// One run per instance. Everything that touches the network arrives through
/// `DiscoveryEnvironment`, so the whole sequencing — phase overlap, the time budget, cancellation,
/// the degraded mode and every diagnostic — is exercised on Linux with no sockets at all.
///
/// Three guarantees the UI is built on, and each is enforced here rather than left to the view:
///
/// * **Exactly one `.deviceFound` per record.** Everything later is `.deviceUpdated` or
///   `.deviceMerged`, so a list can insert a row with an animation and then mutate it in place.
/// * **A run always ends with `.finished`.** A deadline and a cancellation are not failures: both
///   deliver every device found so far, because partial results are the normal case on a big network.
/// * **No credential is ever sent.** No protocol in `Transport/Protocols.swift` has a credential
///   parameter and no code path here writes an `Authorization` header. Hikvision locks an account
///   after roughly five failed authentications, so a discovery pass that tried even one password
///   would lock every camera on the network at once (§6.10).
public actor DiscoveryCoordinator {

    // MARK: Timing and safety constants

    /// When the multicast channels open, relative to the run start (§2.2). The small offset exists so
    /// the plan is on screen before any packet leaves.
    public static let multicastStartOffset = Duration.milliseconds(10)

    /// Unicast SADP send rate, datagrams per second (§4.9). Set by politeness to the firmware, not
    /// by bandwidth: 256 × 129 bytes is 33 kB/s.
    public static let unicastRatePerSecond = 256

    /// Hard cap on unicast probes in one run (§4.9).
    public static let maxUnicastDatagrams = 4_096

    /// In-flight connects when multicast is unavailable: there is no multicast traffic left to
    /// protect, so the sweep is promoted (§9.5).
    public static let degradedMaxInFlightConnects = 192

    /// How often the throughput EWMA is folded and progress is reconsidered (§8.2).
    public static let tickInterval = Duration.milliseconds(100)

    /// Service types browsed. Every one of these must also appear in `Info.plist`'s
    /// `NSBonjourServices`, or the browse silently returns nothing (§9.2).
    public static let bonjourServiceTypes = ["_rtsp._tcp", "_http._tcp", "_axis-video._tcp"]

    /// Below this many probed hosts the local-network-permission heuristic stays disarmed, so a scan
    /// of a tiny or empty range never accuses the OS (§9.4).
    public static let permissionHeuristicMinimumHosts = 20

    // MARK: Injected

    private let environment: DiscoveryEnvironment
    private let configuration: DiscoveryConfiguration

    // MARK: Run state

    private var continuation: AsyncStream<DiscoveryEvent>.Continuation?
    private var runTask: Task<Void, Never>?
    private var hasStarted = false
    /// True once `.finished` has been emitted. Every emitter checks it, so nothing can be reported
    /// after the run ended.
    private var isFinished = false
    /// True as soon as a stop is requested, before the final event is built. This is what stops a new
    /// probe from starting, and it is set synchronously inside the actor so there is no window in
    /// which a cancelled run still opens a socket.
    private var stopping = false

    private var plan: DiscoveryPlan?
    private var merge = MergeEngine()
    private var estimator = DiscoveryProgressEstimator(hostsPlanned: 0)
    private var runStart = MediaInstant.zero
    private var lastProgress = DiscoveryProgress()

    private var openChannels: [any DatagramChannel] = []
    private var diagnosticsRecorded: [DiscoveryDiagnostic] = []
    private var diagnosticsSeen: Set<DiscoveryDiagnostic> = []
    private var phaseSummaries: [PhaseSummary] = []
    private var accumulators: [DiscoveryPhase: PhaseAccumulator] = [:]
    private var activePhases: Set<DiscoveryPhase> = []

    /// Multicast is skipped and the sweep promoted. Decided from the entitlement status up front and
    /// again empirically if a channel refuses to open (§9.3).
    private var isDegraded = false
    private var entitlements: EntitlementStatus

    private var sadpProbeUUID = UUID()
    private var wsdMessageIDs: [UUID] = []
    private var sadpLimiter = SADPIngestLimiter()
    private var wsdDedupe = WSDDedupeSet()

    private var datagramsSent = 0
    private var datagramsReceived = 0
    private var tcpConnects = 0
    private var httpRequests = 0
    private var unicastSent = 0
    private var unicastWindowStart = MediaInstant.zero
    private var unicastInWindow = 0
    private var budgetsReported: Set<BudgetKind> = []

    private var unicastQueue: [IPv4Address] = []
    private var unicastQueued: Set<UInt32> = []
    private var unicastWSDEligible: Set<UInt32> = []
    private var sweepFinished = false

    private var sawOpenPort = false
    private var sawRefusedPort = false
    private var sawInboundDatagram = false
    private var bonjourResults = 0
    private var gatewayProbed: IPv4Address?
    private var gatewaySilent = false

    // MARK: - Life cycle

    /// Creates a coordinator. Nothing happens until ``start()``.
    public init(environment: DiscoveryEnvironment,
                configuration: DiscoveryConfiguration = .default) {
        self.environment = environment
        self.configuration = configuration
        self.entitlements = environment.entitlements
    }

    /// Starts the run and returns its event stream.
    ///
    /// The stream is the run's only consumer. Breaking out of a `for await` over it terminates the
    /// stream, which cancels the run and closes every socket — there is no way to leak a running
    /// sweep (§8.4).
    ///
    /// Calling this twice on one instance is a programmer error. Rather than trapping in a networked
    /// app, the second call logs an error and returns an already-finished stream, so a mistaken
    /// double-start shows up as an empty result instead of a crash on a customer's Mac.
    public func start() -> AsyncStream<DiscoveryEvent> {
        let (stream, continuation) = AsyncStream<DiscoveryEvent>.makeStream(
            bufferingPolicy: .unbounded)
        guard !hasStarted else {
            environment.logger.error(.discovery, "DiscoveryCoordinator.start() called twice; "
                                        + "one run per instance")
            continuation.finish()
            return stream
        }
        hasStarted = true
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            // The sheet was dismissed, or the consumer broke out of its loop. Either way the run has
            // no audience left and must stop touching the network.
            Task { await self?.cancel() }
        }
        runTask = Task { await self.run() }
        return stream
    }

    /// Stops the run.
    ///
    /// Returns immediately: the flag that prevents any further probe is set inside the actor before
    /// this returns, and the final `.finished(.cancelled)` follows on the stream. Accumulated results
    /// survive — ``snapshot`` still returns everything merged so far.
    public func cancel() {
        guard !isFinished, !stopping else { return }
        stopping = true
        estimator.cancel()
        runTask?.cancel()
        Task { await self.terminate(.cancelled) }
    }

    /// Everything merged so far, in the stable order of §10.4. Safe to read at any point in a run.
    public var snapshot: [DiscoveredDevice] { merge.devices }

    /// The most recently emitted progress snapshot.
    public var progress: DiscoveryProgress { lastProgress }

    /// Every diagnostic raised so far, in the order they were raised.
    public var diagnostics: [DiscoveryDiagnostic] { diagnosticsRecorded }

    // MARK: - The run

    /// Which child of the run's task group finished, so the endless ones can be cancelled when the
    /// work they accompany is done.
    private enum RunTaskKind: Sendable { case core, ticker, watchdog, bonjour }

    /// Counters for one phase, folded into a `PhaseSummary` when it ends.
    private struct PhaseAccumulator: Sendable {
        var start: MediaInstant
        var devicesContributed = 0
        var datagramsSent = 0
        var datagramsReceived = 0
        var connectsAttempted = 0
    }

    private func run() async {
        runStart = environment.clock.now()
        unicastWindowStart = runStart
        beginPhase(.planning)

        var interfaces: [NetworkInterfaceInfo] = []
        do {
            interfaces = try environment.interfaces.interfaces()
        } catch {
            // Not fatal by itself: `.single` names an address and needs no interface list. The plan
            // below decides whether the run can continue.
            environment.logger.error(.discovery, "interface enumeration failed: \(error)")
        }

        // The ARP snapshot is read *before* planning, not after it as the §2.2 table implies: the
        // narrowing rule of §6.2 and the host ordering of §6.2 both consume it, so it has to exist
        // before there is a plan to order.
        beginPhase(.arpSnapshot)
        var arpEntries: [ARPEntry] = []
        do {
            arpEntries = try environment.arp.snapshot()
        } catch {
            environment.logger.notice(.discovery, "ARP snapshot unavailable: \(error)")
        }
        endPhase(.arpSnapshot)

        let planned: DiscoveryPlan
        switch SweepPlanner.plan(interfaces: interfaces, arp: arpEntries,
                                 configuration: configuration) {
        case let .success(value):
            planned = value
        case let .failure(error):
            environment.logger.error(.discovery, "discovery cannot start: \(error)")
            endPhase(.planning)
            await terminate(.failed)
            return
        }
        plan = planned
        endPhase(.planning)

        yield(.started(planned))
        for diagnostic in planned.diagnostics { record(diagnostic) }

        resolveMulticastAvailability()
        if isDegraded, configuration.multicastUnavailablePolicy == .fail {
            // The caller would rather show an error than a partial list. The diagnostic already
            // explains why, and `DiscoverySummary` carries no error field, so the reason travels as
            // `.multicastUnavailable` in `summary.diagnostics` (§10.3).
            await terminate(.failed)
            return
        }

        estimator = DiscoveryProgressEstimator(hostsPlanned: sweepHosts(planned).count,
                                               portsPerHost: max(1, planned.tierAPorts.count),
                                               multicastWindow: multicastWindow)
        merge = MergeEngine(knownDevices: configuration.knownDevices,
                            plannedSubnets: planned.subnets)
        emitProgress(force: true)

        // Free identity: an ARP row costs no packet and yields a MAC, the strongest rung of the
        // ladder. Restricted to planned subnets so the router's neighbour on another network cannot
        // attach its MAC to one of our records (§6.3).
        for entry in arpEntries {
            guard let observation = ObservationBuilder.observation(
                from: entry, observedAt: environment.clock.wallNow,
                plannedSubnets: planned.subnets) else { continue }
            enqueueUnicastTarget(entry.address)
            ingest(observation, phase: .arpSnapshot)
        }

        await withTaskGroup(of: RunTaskKind.self) { group in
            group.addTask { await self.runCoreWork(planned); return .core }
            group.addTask { await self.runProgressTicker(); return .ticker }
            group.addTask { await self.runDeadlineWatchdog(); return .watchdog }
            if configuration.mode.includesSweep {
                group.addTask { await self.runBonjourBrowse(); return .bonjour }
            }
            while let finished = await group.next() {
                // The ticker, the watchdog and the Bonjour browse all run until told to stop; the
                // core work is what defines the end of the run.
                if finished == .core || finished == .watchdog { group.cancelAll() }
            }
        }

        guard !stopping else { return }
        // A run may finish early once nothing new is arriving (§2.2). Nothing else is running by
        // now, so the quiet period is a plain wait.
        activePhases = [.settling]
        _ = await pause(for: configuration.settleQuietPeriod)
        await terminate(.completed)
    }

    /// The mechanisms themselves: two multicast phases, the sweep, and the unicast SADP fallback.
    private func runCoreWork(_ plan: DiscoveryPlan) async {
        await withTaskGroup(of: Void.self) { group in
            if !isDegraded, !plan.multicastInterfaces.isEmpty {
                group.addTask { await self.runMulticastPhase(.sadp, plan: plan) }
                group.addTask { await self.runMulticastPhase(.onvif, plan: plan) }
            }
            if configuration.mode.includesSweep {
                group.addTask { await self.runSweep(plan) }
                group.addTask { await self.runUnicastProbes(plan) }
            }
        }
    }

    // MARK: - Multicast phases

    /// The listening window: from the run start to the last probe plus the listen tail (§2.2).
    private var multicastWindow: Duration {
        guard !isDegraded, configuration.mode != .single(address: .init(0, 0, 0, 0), ports: []),
              !multicastSchedule.isEmpty else { return .zero }
        let last = multicastSchedule.max() ?? .zero
        return Self.multicastStartOffset + last + configuration.multicastListenTail
    }

    /// The probe schedule shared by both multicast mechanisms, longest of the two so the window
    /// covers both.
    private var multicastSchedule: [Duration] {
        let sadp = configuration.sadpProbeSchedule
        let onvif = configuration.onvifProbeSchedule
        return sadp.count >= onvif.count ? sadp : onvif
    }

    private func runMulticastPhase(_ phase: DiscoveryPhase, plan: DiscoveryPlan) async {
        guard await pause(until: Self.multicastStartOffset) else { return }
        guard !stopping else { return }
        beginPhase(phase)
        await withTaskGroup(of: Void.self) { group in
            for interface in plan.interfaces {
                group.addTask { await self.runMulticastChannel(phase, interface: interface) }
            }
        }
        if phase == .sadp {
            for flood in sadpLimiter.floodedSources {
                record(.sadpFlood(from: flood.source, dropped: flood.dropped))
            }
        }
        endPhase(phase)
    }

    /// One channel on one interface: probes out on the schedule, datagrams in until the window ends.
    ///
    /// Multicast joins are per-interface, so a Mac docked with Ethernet *and* Wi-Fi *and* a
    /// Thunderbolt bridge needs three channels — cameras are commonly reachable on only one of
    /// them (§4.1).
    private func runMulticastChannel(_ phase: DiscoveryPhase,
                                    interface: NetworkInterfaceInfo) async {
        let port = phase == .sadp ? SADPCodec.port : WSDiscoveryCodec.port
        let spec = MulticastGroupSpec(group: .discoveryMulticastGroup, port: port,
                                      preferredLocalPort: port,
                                      localAddress: interface.address,
                                      interfaceName: interface.name)
        guard let channel = await openMulticastChannel(spec, phase: phase) else { return }
        register(channel)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.listen(phase, on: channel) }
            group.addTask {
                await self.sendMulticastProbes(phase, on: channel)
                // Closing ends the inbound stream, which is what lets the listener above return.
                await channel.close()
            }
        }
    }

    /// Opens a channel, taking the ephemeral-port fallback when the preferred port is unavailable.
    ///
    /// Binding 37020 matters: most Hikvision firmware multicasts its ProbeMatch back to the group
    /// port rather than unicasting to our source port, so an ephemeral bind misses those devices
    /// entirely. The fallback still hears firmware that unicasts, so results are partial, not
    /// empty (§4.1).
    private func openMulticastChannel(_ spec: MulticastGroupSpec,
                                     phase: DiscoveryPhase) async -> (any DatagramChannel)? {
        do {
            return try await environment.makeMulticastChannel(spec)
        } catch {
            switch error {
            case .channelBindFailed:
                record(phase == .sadp
                    ? .sadpDegradedEphemeralPort(interface: spec.interfaceName)
                    : .onvifDegradedEphemeralPort(interface: spec.interfaceName))
                do {
                    return try await environment.makeMulticastChannel(spec.ephemeralFallback)
                } catch {
                    noteMulticastUnavailable(.joinFailed)
                    return nil
                }
            case let .multicastUnavailable(reason):
                noteMulticastUnavailable(reason)
                return nil
            default:
                noteMulticastUnavailable(.joinFailed)
                return nil
            }
        }
    }

    private func sendMulticastProbes(_ phase: DiscoveryPhase,
                                    on channel: any DatagramChannel) async {
        let schedule = phase == .sadp ? configuration.sadpProbeSchedule
            : configuration.onvifProbeSchedule
        let port = phase == .sadp ? SADPCodec.port : WSDiscoveryCodec.port
        for (index, offset) in schedule.enumerated() {
            guard await pause(until: Self.multicastStartOffset + offset) else { break }
            guard !stopping, claimDatagram(phase: phase) else { break }
            let payload = phase == .sadp
                ? SADPCodec.encodeProbe(uuid: sadpProbeUUID)
                : WSDiscoveryCodec.encodeProbe(messageID: messageID(at: index),
                                               types: probeTypes(at: index))
            do {
                try await channel.send(payload, to: .discoveryMulticastGroup, port: port)
            } catch {
                if case let .multicastUnavailable(reason) = error {
                    noteMulticastUnavailable(reason)
                    break
                }
                environment.logger.notice(.discovery, "probe send failed on "
                                            + "\(channel.interfaceName ?? "?"): \(error)")
            }
        }
        // Keep listening for the tail after the last probe: slow NVRs answer 1.5–2 s late (§2.2).
        _ = await pause(until: multicastWindow)
    }

    /// The `MessageID` for WS-Discovery probe `index`, all of which are in the run's expected set so
    /// an answer can be correlated (§5.3).
    private func messageID(at index: Int) -> UUID {
        guard index < wsdMessageIDs.count else { return environment.uuidGenerator() }
        return wsdMessageIDs[index]
    }

    /// The `Types` filter for WS-Discovery probe `index`: NVT, then NVT+Device, then the wildcard.
    /// A schedule longer than three repeats the wildcard, which is the widest of the three.
    private func probeTypes(at index: Int) -> WSDProbeTypes {
        let schedule = WSDiscoveryCodec.probeSchedule
        guard index < schedule.count else { return .wildcard }
        return schedule[index]
    }

    private func listen(_ phase: DiscoveryPhase, on channel: any DatagramChannel) async {
        for await datagram in channel.inboundDatagrams() {
            guard !isFinished else { break }
            sawInboundDatagram = true
            datagramsReceived += 1
            accumulators[phase]?.datagramsReceived += 1
            if phase == .sadp {
                ingestSADP(datagram, source: .sadpMulticast, phase: .sadp)
            } else {
                ingestWSD(datagram, phase: .onvif)
            }
        }
    }

    // MARK: - Ingestion

    /// Folds a SADP datagram in. Everything on the group is classified rather than filtered: our own
    /// looped-back probe, another tool's probe, another tool's answers and obfuscated payloads all
    /// have a defined meaning and none of them may abort a run (§4.5, §4.8).
    private func ingestSADP(_ datagram: InboundDatagram, source: DiscoverySource,
                            phase: DiscoveryPhase) {
        guard sadpLimiter.admit(from: datagram.source) else { return }
        let result = SADPCodec.decode(datagram.payload, from: datagram.source,
                                      expectedUUID: sadpProbeUUID, receivedAt: datagram.receivedAt)
        switch result {
        case let .probeMatch(match):
            ingest(SADPCodec.observation(from: match, source: source), phase: phase)
        case let .foreignProbeMatch(match):
            ingest(SADPCodec.observation(from: match, source: source, isForeignProbeMatch: true),
                   phase: phase)
        case let .foreignProbe(uuid):
            record(.foreignDiscoveryClientActive(uuid: uuid))
        case .ownProbeEcho:
            break
        case let .opaque(payload):
            record(.sadpOpaquePayload(from: payload.source, length: payload.length,
                                      prefixHex: payload.prefixHex,
                                      entropy: payload.entropyBitsPerByte))
            ingest(SADPCodec.degradedObservation(from: payload, source: source,
                                                 observedAt: datagram.receivedAt), phase: phase)
        case let .malformed(reason, prefixHex):
            environment.logger.debug(.discovery, "SADP datagram from \(datagram.source) "
                                        + "unusable: \(reason) [\(prefixHex)]")
        }
    }

    /// Folds a WS-Discovery datagram in. Correlation is by `RelatesTo`, never by source port: answers
    /// arrive as unicast from arbitrary ports and a port filter would drop most real cameras (§5.1).
    private func ingestWSD(_ datagram: InboundDatagram, phase: DiscoveryPhase) {
        let expected = Set(wsdMessageIDs.map { "urn:uuid:" + $0.uuidString.lowercased() })
        let outcome = WSDiscoveryCodec.decodeProbeMatches(datagram.payload, from: datagram.source,
                                                          expectedMessageIDs: expected,
                                                          receivedAt: datagram.receivedAt)
        switch outcome {
        case let .probeMatches(matches), let .hello(matches):
            for match in matches {
                // Three probes go out and a device answers all three, often multicasting a copy as
                // well; without the dedupe one camera would produce five events (§5.5).
                guard wsdDedupe.insert(match) else { continue }
                ingest(WSDiscoveryCodec.observation(from: match), phase: phase)
            }
        case .bye, .otherAction:
            break
        case let .notSOAP(prefixHex):
            environment.logger.debug(.discovery, "non-SOAP datagram from \(datagram.source) "
                                        + "[\(prefixHex)]")
        }
    }

    /// Folds one observation through the merge engine and emits whatever it produced.
    private func ingest(_ observation: DeviceObservation, phase: DiscoveryPhase) {
        guard !isFinished else { return }
        let events = merge.ingest(observation)
        guard !events.isEmpty else { return }
        var contributed = 0
        for event in events {
            switch event {
            case let .diagnostic(diagnostic):
                record(diagnostic)
                continue
            case .deviceFound, .deviceUpdated:
                contributed += 1
            default:
                break
            }
            yield(event)
        }
        accumulators[phase]?.devicesContributed += contributed
        emitProgress(force: true)
    }

    // MARK: - Sweep

    /// Hosts this run will probe, after `resumeFrom` — the "Keep scanning" continuation of a run that
    /// hit its deadline (§8.3).
    private func sweepHosts(_ plan: DiscoveryPlan) -> [IPv4Address] {
        let skip = max(0, min(configuration.resumeFrom, plan.hostOrder.count))
        return Array(plan.hostOrder.dropFirst(skip))
    }

    private func runSweep(_ plan: DiscoveryPlan) async {
        // The sweep normally starts late so multicast answers land on an idle NIC; with no multicast
        // running there is nothing to protect, so it starts at once (§9.5).
        let delay = isDegraded ? .zero : configuration.sweepStartDelay
        guard await pause(until: delay) else { return }
        guard !stopping else { return }

        beginPhase(.sweepA)
        await probeGatewayCanary(plan)

        let hosts = sweepHosts(plan)
        let worker = makeWorker()
        let tierA = plan.tierAPorts
        let tierB = configuration.tierBPorts
        let limit = max(1, min(effectiveConcurrency, max(1, hosts.count)))
        var next = 0

        await withTaskGroup(of: Void.self) { group in
            while next < hosts.count, next < limit {
                let host = hosts[next]
                group.addTask { await self.probeOneHost(host, worker: worker,
                                                       tierA: tierA, tierB: tierB) }
                next += 1
            }
            while await group.next() != nil {
                guard !stopping, next < hosts.count, claimConnects(1, hosts: hosts.count) else {
                    continue
                }
                let host = hosts[next]
                group.addTask { await self.probeOneHost(host, worker: worker,
                                                       tierA: tierA, tierB: tierB) }
                next += 1
            }
        }
        sweepFinished = true
        endPhase(.sweepA)
        if accumulators[.fingerprint] != nil { endPhase(.fingerprint) }
    }

    /// One host: tier A, then tier B if anything answered, then the fingerprints.
    ///
    /// Runs off the actor — `SweepWorker` is a plain value — so `limit` of these are genuinely
    /// concurrent. Only the bookkeeping hops back onto the actor.
    private nonisolated func probeOneHost(_ host: IPv4Address, worker: SweepWorker,
                                          tierA: [UInt16], tierB: [UInt16]) async {
        let first = await worker.connect(host: host, ports: tierA)
        var result = HostProbeResult(address: host, portOutcomes: first.outcomes)
        var connects = first.connectsAttempted
        var requests = 0

        if result.isAlive, await shouldProbeTierB(portCount: tierB.count) {
            let second = await worker.connect(host: host, ports: tierB)
            for (port, outcome) in second.outcomes { result.portOutcomes[port] = outcome }
            connects += second.connectsAttempted
        }
        if !result.openPorts.isEmpty, await shouldFingerprint() {
            let batch = await worker.fingerprint(host: host, openPorts: result.openPorts)
            result.rtsp = batch.rtsp
            result.http = batch.http
            requests = batch.requestsAttempted
        }
        await completeHost(result, connects: connects, requests: requests)
    }

    /// Whether tier B may run, and the denominator growth it causes.
    ///
    /// The growth is recorded here rather than at completion time so the bar slows down while the
    /// extra work is outstanding instead of jumping when it lands (§8.2).
    private func shouldProbeTierB(portCount: Int) -> Bool {
        guard !stopping, portCount > 0 else { return false }
        estimator.schedulePortProbes(portCount)
        activePhases.insert(.sweepB)
        return true
    }

    private func shouldFingerprint() -> Bool {
        guard !stopping else { return false }
        if accumulators[.fingerprint] == nil { beginPhase(.fingerprint) }
        return true
    }

    /// Folds one host's results in and updates every counter the progress bar reads.
    private func completeHost(_ result: HostProbeResult, connects: Int, requests: Int) {
        tcpConnects += connects
        httpRequests += requests
        accumulators[.sweepA]?.connectsAttempted += connects
        estimator.completeHost(alive: result.isAlive)
        estimator.completePortProbes(result.portOutcomes.count)
        for outcome in result.portOutcomes.values {
            if outcome == .open { sawOpenPort = true }
            if outcome == .refused { sawRefusedPort = true }
        }
        if result.isAlive { enqueueUnicastTarget(result.address, allowWSD: true) }
        let observations = ObservationBuilder.observations(from: result,
                                                          observedAt: environment.clock.wallNow)
        for observation in observations {
            ingest(observation, phase: observation.source == .tcpSweep ? .sweepA : .fingerprint)
        }
        emitProgress()
    }

    /// Probes the interface's likely gateway on 80 and 443 before the sweep proper.
    ///
    /// Two connects buy the one signal the local-network-permission heuristic cannot do without: a
    /// real LAN always has *something* at the gateway, so a gateway that is silent on both ports
    /// while everything else is silent too means macOS is blocking us rather than the network being
    /// empty (§9.4).
    private func probeGatewayCanary(_ plan: DiscoveryPlan) async {
        guard let gateway = plan.interfaces.compactMap(\.likelyGateway).first else { return }
        guard claimConnects(2, hosts: plan.hostsPlanned) else { return }
        gatewayProbed = gateway
        let worker = makeWorker()
        let batch = await worker.connect(host: gateway, ports: [80, 443])
        tcpConnects += batch.connectsAttempted
        gatewaySilent = !batch.outcomes.isEmpty
            && batch.outcomes.values.allSatisfy { !$0.provesHostAlive }
        for outcome in batch.outcomes.values {
            if outcome == .open { sawOpenPort = true }
            if outcome == .refused { sawRefusedPort = true }
        }
    }

    private func makeWorker() -> SweepWorker {
        SweepWorker(tcpProbe: environment.tcpProbe, exchange: environment.exchange,
                    connectTimeout: configuration.tcpConnectTimeout,
                    fingerprintTimeout: configuration.fingerprintTimeout,
                    interfaceName: plan?.interfaces.first?.name)
    }

    /// In-flight connects allowed. The degraded mode's promotion applies only to the shipping default
    /// — a test or an Advanced setting that asked for a specific number keeps it.
    private var effectiveConcurrency: Int {
        guard isDegraded, configuration.maxInFlightConnects == 128 else {
            return configuration.maxInFlightConnects
        }
        return Self.degradedMaxInFlightConnects
    }

    // MARK: - Unicast SADP and WS-Discovery

    /// Queues a host for a unicast probe. Called for every ARP entry and every host that answered,
    /// which is where the degraded mode gets its reach (§4.9).
    private func enqueueUnicastTarget(_ host: IPv4Address, allowWSD: Bool = false) {
        if allowWSD { unicastWSDEligible.insert(host.rawValue) }
        guard unicastQueued.insert(host.rawValue).inserted else { return }
        unicastQueue.append(host)
    }

    private func runUnicastProbes(_ plan: DiscoveryPlan) async {
        guard configuration.mode.includesSweep else { return }
        if isDegraded {
            // No multicast means no off-subnet reach and no group answers, so every planned host is
            // asked directly instead (§9.5).
            for host in sweepHosts(plan) { enqueueUnicastTarget(host) }
        }
        guard let channel = await openUnicastChannel() else { return }
        register(channel)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.listenUnicast(on: channel) }
            group.addTask {
                await self.drainUnicastQueue(on: channel)
                await channel.close()
            }
        }
    }

    private func openUnicastChannel() async -> (any DatagramChannel)? {
        do {
            return try await environment.makeUnicastChannel(plan?.interfaces.first?.name)
        } catch {
            environment.logger.notice(.discovery, "unicast channel unavailable: \(error)")
            return nil
        }
    }

    private func drainUnicastQueue(on channel: any DatagramChannel) async {
        while !stopping, !isFinished {
            guard let host = dequeueUnicastTarget() else {
                if sweepFinished { break }
                guard await pause(for: .milliseconds(50)) else { break }
                continue
            }
            guard await awaitUnicastRateSlot() else { break }
            guard claimUnicastDatagram(), claimDatagram(phase: .sadp) else { break }
            do {
                try await channel.send(SADPCodec.encodeProbe(uuid: sadpProbeUUID),
                                       to: host, port: SADPCodec.port)
            } catch {
                environment.logger.debug(.discovery, "unicast SADP to \(host) failed: \(error)")
            }
            guard isDegraded, unicastWSDEligible.contains(host.rawValue) else { continue }
            guard claimUnicastDatagram(), claimDatagram(phase: .onvif) else { break }
            // A real subset of ONVIF firmware answers a unicast Probe; it is cheap and it is the
            // only ONVIF reach a degraded run has (§9.5 item 4).
            do {
                try await channel.send(WSDiscoveryCodec.encodeProbe(messageID: messageID(at: 0),
                                                                    types: probeTypes(at: 0)),
                                       to: host, port: WSDiscoveryCodec.port)
            } catch {
                environment.logger.debug(.discovery, "unicast WSD to \(host) failed: \(error)")
            }
        }
    }

    private func dequeueUnicastTarget() -> IPv4Address? {
        guard !unicastQueue.isEmpty else { return nil }
        return unicastQueue.removeFirst()
    }

    /// Enforces the 256 datagrams/second unicast rate by waiting for the next window when the
    /// current one is full. Returns false when the run is stopping.
    private func awaitUnicastRateSlot() async -> Bool {
        guard unicastInWindow >= Self.unicastRatePerSecond else { return true }
        let windowEnd = unicastWindowStart + .seconds(1)
        let remaining = windowEnd - environment.clock.now()
        if remaining > .zero, await pause(for: remaining) == false { return false }
        unicastWindowStart = environment.clock.now()
        unicastInWindow = 0
        return !stopping
    }

    private func claimUnicastDatagram() -> Bool {
        guard unicastSent < Self.maxUnicastDatagrams else {
            recordBudget(.datagrams, limit: Self.maxUnicastDatagrams)
            return false
        }
        unicastSent += 1
        unicastInWindow += 1
        return true
    }

    /// Unicast answers arrive on one channel for two protocols, so they are told apart by content:
    /// a SOAP envelope is WS-Discovery, anything else is offered to the SADP decoder, which is total
    /// over any bytes. Dispatching by source port would be wrong — §5.1 forbids it.
    private func listenUnicast(on channel: any DatagramChannel) async {
        for await datagram in channel.inboundDatagrams() {
            guard !isFinished else { break }
            sawInboundDatagram = true
            datagramsReceived += 1
            if looksLikeSOAP(datagram.payload) {
                ingestWSD(datagram, phase: .onvif)
            } else {
                ingestSADP(datagram, source: .sadpUnicast, phase: .sadp)
            }
        }
    }

    private func looksLikeSOAP(_ payload: Data) -> Bool {
        payload.range(of: Data("Envelope".utf8)) != nil
    }

    // MARK: - Bonjour

    private func runBonjourBrowse() async {
        beginPhase(.bonjour)
        for await service in environment.bonjour.browse(types: Self.bonjourServiceTypes) {
            guard !isFinished else { break }
            bonjourResults += 1
            guard let address = service.address else { continue }
            ingest(bonjourObservation(service, address: address), phase: .bonjour)
        }
        endPhase(.bonjour)
    }

    private func bonjourObservation(_ service: BonjourService,
                                    address: IPv4Address) -> DeviceObservation {
        var fields: [DeviceFieldKey: FieldValue] = [.bonjourName: .string(service.name)]
        if let port = service.port {
            if service.type.contains("rtsp") { fields[.rtspPort] = .port(port) }
            if service.type.contains("http") { fields[.httpPort] = .port(port) }
        }
        let verdict = VendorClassifier.classify(
            ClassificationEvidence(bonjourTypes: [service.type]))
        return DeviceObservation(source: .bonjour, observedAt: environment.clock.wallNow,
                                 address: address, fields: fields, verdict: verdict)
    }

    // MARK: - Ticker and deadline

    private func runProgressTicker() async {
        while await pause(for: Self.tickInterval) {
            guard !isFinished else { return }
            estimator.tick(at: elapsed)
            emitProgress()
        }
    }

    /// The overall deadline: 12 s for a `/24`, 8 s more per doubling, 40 % more when degraded, capped
    /// at three minutes. Hitting it is not a failure — the results are delivered and the UI offers to
    /// keep scanning from `hostsProbed` (§8.3).
    private var overallDeadline: Duration {
        if let override = configuration.overallDeadlineOverride { return override }
        let hosts = plan?.hostsPlanned ?? 0
        return isDegraded ? DiscoveryDeadline.degraded(hostsPlanned: hosts)
            : DiscoveryDeadline.overall(hostsPlanned: hosts)
    }

    private func runDeadlineWatchdog() async {
        guard await pause(until: overallDeadline) else { return }
        guard !isFinished, !stopping else { return }
        environment.logger.notice(.discovery, "discovery deadline reached after "
                                    + "\(Int(elapsed.seconds)) s")
        stopping = true
        await terminate(.deadline)
    }

    // MARK: - Termination

    private func terminate(_ reason: DiscoverySummary.TerminationReason) async {
        guard !isFinished else { return }
        isFinished = true
        stopping = true
        activePhases = [.finished]

        for phase in accumulators.keys { endPhase(phase) }
        evaluatePermissionHeuristic()

        let devices = merge.devices
        let summary = DiscoverySummary(terminationReason: reason, devices: devices,
                                       elapsed: elapsed,
                                       hostsProbed: estimator.hostsProbed,
                                       hostsPlanned: estimator.hostsPlanned,
                                       phases: phaseSummaries,
                                       diagnostics: diagnosticsRecorded,
                                       entitlements: entitlements)
        environment.logger.info(.discovery, "discovery finished: \(reason.rawValue), "
                                    + "\(devices.count) device(s), \(datagramsSent) datagram(s) "
                                    + "sent, \(tcpConnects) connect(s)")
        continuation?.yield(.finished(summary))
        continuation?.finish()
        continuation = nil

        await closeChannels()
        runTask?.cancel()
    }

    private func closeChannels() async {
        let channels = openChannels
        openChannels = []
        for channel in channels { await channel.close() }
    }

    private func register(_ channel: any DatagramChannel) {
        openChannels.append(channel)
    }

    /// The §9.4 heuristic. Every clause must hold, because accusing macOS wrongly sends a user to a
    /// settings pane that will not help. `VigilUI` shows the remediation panel only on macOS 15 and
    /// later, where the Local Network pane exists; the pure layer cannot and does not test the OS
    /// version.
    private func evaluatePermissionHeuristic() {
        guard !sawInboundDatagram, bonjourResults == 0, !sawOpenPort, !sawRefusedPort,
              gatewaySilent, estimator.hostsProbed >= Self.permissionHeuristicMinimumHosts,
              let interface = plan?.interfaces.first else { return }
        entitlements.localNetworkPermission = .likelyDenied
        record(.localNetworkPermissionLikelyDenied(interface: interface.name,
                                                   gateway: gatewayProbed))
    }

    // MARK: - Multicast availability

    private func resolveMulticastAvailability() {
        if case .single = configuration.mode {
            // A named address needs no group probe, and asking for one would trigger the local
            // network prompt for nothing.
            isDegraded = true
            return
        }
        guard !entitlements.shouldAttemptMulticast else { return }
        noteMulticastUnavailable(.entitlementMissing)
    }

    private func noteMulticastUnavailable(_ reason: MulticastUnavailableReason) {
        entitlements.multicastVerifiedWorking = false
        guard !isDegraded else { return }
        isDegraded = true
        record(.multicastUnavailable(reason: reason))
    }

    // MARK: - Budgets

    /// Claims one datagram against the run cap. Exhaustion stops sending and keeps every result;
    /// a scan that is politely incomplete beats one that looks like a flood (§6.10).
    private func claimDatagram(phase: DiscoveryPhase) -> Bool {
        guard datagramsSent < configuration.maxDatagramsPerRun else {
            recordBudget(.datagrams, limit: configuration.maxDatagramsPerRun)
            return false
        }
        datagramsSent += 1
        accumulators[phase]?.datagramsSent += 1
        return true
    }

    /// Claims connects against the per-run ceiling of `4 × plannedHosts + 512` (§6.10).
    private func claimConnects(_ count: Int, hosts: Int) -> Bool {
        let limit = configuration.maxTCPConnects(plannedHosts: hosts)
        guard tcpConnects + count <= limit else {
            recordBudget(.tcpConnects, limit: limit)
            return false
        }
        return true
    }

    private func recordBudget(_ kind: BudgetKind, limit: Int) {
        guard budgetsReported.insert(kind).inserted else { return }
        record(.budgetExhausted(kind: kind, limit: limit))
    }

    // MARK: - Emission

    private var elapsed: Duration { environment.clock.now() - runStart }

    private func yield(_ event: DiscoveryEvent) {
        guard !isFinished else { return }
        continuation?.yield(event)
    }

    /// Records a diagnostic once and emits it. Duplicates are dropped: a flood diagnostic that itself
    /// floods is worse than none.
    private func record(_ diagnostic: DiscoveryDiagnostic) {
        guard diagnosticsSeen.insert(diagnostic).inserted else { return }
        diagnosticsRecorded.append(diagnostic)
        switch diagnostic.severity {
        case .info:
            environment.logger.debug(.discovery, "diagnostic: \(diagnostic)")
        case .warning:
            environment.logger.notice(.discovery, "diagnostic: \(diagnostic)")
        case .actionRequired:
            environment.logger.notice(.discovery, "action required: \(diagnostic)")
        }
        yield(.diagnostic(diagnostic))
    }

    /// Emits a progress snapshot, coalesced to 20 Hz. `force` — set by every device event — always
    /// emits, so the counter never lags a row the user can already see (§8.1).
    private func emitProgress(force: Bool = false) {
        guard !isFinished else { return }
        let at = elapsed
        guard estimator.shouldEmit(at: at, force: force) else { return }
        estimator.setDeviceCounts(found: merge.deviceCount, candidates: merge.candidateCount)
        let snapshot = estimator.snapshot(at: at, phase: narrowestActivePhase,
                                          activePhases: activePhases)
        lastProgress = snapshot
        continuation?.yield(.progress(snapshot))
    }

    /// The label the UI shows: the narrowest active phase, because "Identifying 192.168.1.64" says
    /// more than "Scanning".
    private var narrowestActivePhase: DiscoveryPhase {
        activePhases.max { $0.specificity < $1.specificity } ?? .planning
    }

    // MARK: - Phases

    private func beginPhase(_ phase: DiscoveryPhase) {
        guard accumulators[phase] == nil else { return }
        accumulators[phase] = PhaseAccumulator(start: environment.clock.now())
        activePhases.insert(phase)
    }

    private func endPhase(_ phase: DiscoveryPhase) {
        guard let accumulator = accumulators.removeValue(forKey: phase) else { return }
        activePhases.remove(phase)
        let summary = PhaseSummary(phase: phase,
                                   duration: environment.clock.now() - accumulator.start,
                                   devicesContributed: accumulator.devicesContributed,
                                   datagramsSent: accumulator.datagramsSent,
                                   datagramsReceived: accumulator.datagramsReceived,
                                   connectsAttempted: accumulator.connectsAttempted)
        phaseSummaries.append(summary)
        yield(.phaseCompleted(phase, summary))
    }

    // MARK: - Waiting

    /// Sleeps for `duration`, reporting whether the run may continue afterwards.
    ///
    /// Returns false when the sleep was cancelled or the run is stopping, which is how every loop in
    /// this actor learns to stop without checking two conditions of its own.
    @discardableResult
    private func pause(for duration: Duration) async -> Bool {
        guard !stopping, !isFinished else { return false }
        guard duration > .zero else { return !Task.isCancelled }
        do {
            try await environment.clock.sleep(for: duration)
        } catch {
            return false
        }
        return !stopping && !isFinished && !Task.isCancelled
    }

    /// Sleeps until `offset` after the run started. Returns immediately when that moment has passed,
    /// so a phase that was scheduled while the machine was busy starts late rather than never.
    @discardableResult
    private func pause(until offset: Duration) async -> Bool {
        await pause(for: (runStart + offset) - environment.clock.now())
    }
}
