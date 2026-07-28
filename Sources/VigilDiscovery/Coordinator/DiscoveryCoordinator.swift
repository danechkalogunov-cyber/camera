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

    let environment: DiscoveryEnvironment
    let configuration: DiscoveryConfiguration

    // MARK: Run state

    var continuation: AsyncStream<DiscoveryEvent>.Continuation?
    var runTask: Task<Void, Never>?
    private var hasStarted = false
    /// True once `.finished` has been emitted. Every emitter checks it, so nothing can be reported
    /// after the run ended.
    var isFinished = false
    /// True from the first line of ``terminate(_:)``. Separate from ``isFinished`` because the
    /// wrap-up — the last phase summaries, the permission diagnostic, the frozen progress snapshot —
    /// must still reach the stream, and `isFinished` silences every emitter.
    var isTerminating = false
    /// True as soon as a stop is requested, before the final event is built. This is what stops a new
    /// probe from starting, and it is set synchronously inside the actor so there is no window in
    /// which a cancelled run still opens a socket.
    var stopping = false

    var plan: DiscoveryPlan?
    var merge = MergeEngine()
    var estimator = DiscoveryProgressEstimator(hostsPlanned: 0)
    var runStart = MediaInstant.zero
    var lastProgress = DiscoveryProgress()

    var openChannels: [any DatagramChannel] = []
    var diagnosticsRecorded: [DiscoveryDiagnostic] = []
    var diagnosticsSeen: Set<DiscoveryDiagnostic> = []
    var phaseSummaries: [PhaseSummary] = []
    var accumulators: [DiscoveryPhase: PhaseAccumulator] = [:]
    var activePhases: Set<DiscoveryPhase> = []

    /// Multicast is skipped and the sweep promoted. Decided from the entitlement status up front and
    /// again empirically if a channel refuses to open (§9.3).
    var isDegraded = false
    /// True for `.single(address:)`: one named address, no group probe, and therefore no multicast
    /// diagnostic and no `.fail` policy — the caller asked about one host, not about the network.
    var isSingleAddressRun = false
    var entitlements: EntitlementStatus
    /// The multicast listening window, fixed once at the start of the run so that a channel failing
    /// halfway through cannot shorten the window the other interfaces are still listening on.
    var multicastWindowValue = Duration.zero

    let sadpProbeUUID: UUID
    let wsdMessageIDs: [UUID]
    var sadpLimiter = SADPIngestLimiter()
    var wsdDedupe = WSDDedupeSet()

    var datagramsSent = 0
    var datagramsReceived = 0
    var tcpConnects = 0
    var httpRequests = 0
    var unicastSent = 0
    var unicastWindowStart = MediaInstant.zero
    var unicastInWindow = 0
    var budgetsReported: Set<BudgetKind> = []

    var unicastQueue: [IPv4Address] = []
    var unicastQueued: Set<UInt32> = []
    var unicastWSDEligible: Set<UInt32> = []
    var sweepFinished = false

    var sawOpenPort = false
    var sawRefusedPort = false
    var sawInboundDatagram = false
    var bonjourResults = 0
    var gatewayProbed: IPv4Address?
    var gatewaySilent = false

    // MARK: - Life cycle

    /// Creates a coordinator. Nothing happens until ``start()``.
    ///
    /// The run's message identifiers are drawn here, from `environment.uuidGenerator`, and never from
    /// `UUID()`: the SADP probe carries one `Uuid` and each WS-Discovery probe a distinct
    /// `MessageID`, and correlating an answer means comparing against exactly those values. Injecting
    /// them is what lets a test assert byte-exact probes and script a ProbeMatch that correlates
    /// (§4.2, §5.3). The SADP UUID is drawn first, so a scripted generator's first value is the one
    /// the SADP fixtures use.
    public init(environment: DiscoveryEnvironment,
                configuration: DiscoveryConfiguration = .default) {
        self.environment = environment
        self.configuration = configuration
        self.entitlements = environment.entitlements
        self.sadpProbeUUID = environment.uuidGenerator()
        // One identifier per scheduled probe, and at least one: a schedule may be empty in a
        // multicast-free configuration, and `messageID(at:)` must still have a value to fall back on.
        let probeCount = max(1, configuration.onvifProbeSchedule.count)
        self.wsdMessageIDs = (0..<probeCount).map { _ in environment.uuidGenerator() }
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
    struct PhaseAccumulator: Sendable {
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

        let planned: DiscoveryPlan
        switch SweepPlanner.plan(interfaces: interfaces, arp: arpEntries,
                                 configuration: configuration) {
        case let .success(value):
            planned = value
        case let .failure(error):
            environment.logger.error(.discovery, "discovery cannot start: \(error)")
            await terminate(.failed)
            return
        }
        plan = planned

        // `.started` is deliberately the run's first event: the sheet draws what will be scanned —
        // and what the guard refused — before any result can arrive, so a run that ends up finding
        // nothing has already explained its scope.
        yield(.started(planned))
        for diagnostic in planned.diagnostics { record(diagnostic) }
        endPhase(.planning)

        resolveMulticastAvailability()
        if isDegraded, !isSingleAddressRun, configuration.multicastUnavailablePolicy == .fail {
            // The caller would rather show an error than a partial list. The diagnostic already
            // explains why, and `DiscoverySummary` carries no error field, so the reason travels as
            // `.multicastUnavailable` in `summary.diagnostics` (§10.3).
            await terminate(.failed)
            return
        }

        multicastWindowValue = plannedMulticastWindow()
        estimator = DiscoveryProgressEstimator(hostsPlanned: sweepHosts(planned).count,
                                               portsPerHost: max(1, planned.tierAPorts.count),
                                               multicastWindow: multicastWindow)
        merge = MergeEngine(knownDevices: configuration.knownDevices,
                            plannedSubnets: planned.subnets)
        emitProgress(force: true)

        // Free identity: an ARP row costs no packet and yields a MAC, the strongest rung of the
        // ladder. Restricted to planned subnets so the router's neighbour on another network cannot
        // attach its MAC to one of our records (§6.3). Folded while `.arpSnapshot` is still open, so
        // the phase summary credits the records it actually produced.
        for entry in arpEntries {
            guard let observation = ObservationBuilder.observation(
                from: entry, observedAt: environment.clock.wallNow,
                plannedSubnets: planned.subnets) else { continue }
            enqueueUnicastTarget(entry.address)
            ingest(observation, phase: .arpSnapshot)
        }
        endPhase(.arpSnapshot)

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
}
