//
//  DiscoveryCoordinator+Probes.swift
//  VigilDiscovery
//
//  The remaining probes and the machinery around a run: Bonjour, the ticker and its
//  deadline, termination, budgets, emission and waiting.
//  Split from DiscoveryCoordinator.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

import Foundation
import VigilProtocols

// MARK: - Probes and run machinery

/// ⚠️ Members are `internal`, not `private`: Swift scopes `private` to one file.
/// `Scripts/lint.py`'s `split-access` rule fails the build on any left behind.
extension DiscoveryCoordinator {

    // MARK: - Unicast SADP and WS-Discovery

    /// Queues a host for a unicast probe. Called for every ARP entry and every host that answered,
    /// which is where the degraded mode gets its reach (§4.9).
    func enqueueUnicastTarget(_ host: IPv4Address, allowWSD: Bool = false) {
        if allowWSD { unicastWSDEligible.insert(host.rawValue) }
        guard unicastQueued.insert(host.rawValue).inserted else { return }
        unicastQueue.append(host)
    }

    func runUnicastProbes(_ plan: DiscoveryPlan) async {
        guard configuration.mode.includesSweep else { return }
        if isDegraded {
            // No multicast means no off-subnet reach and no group answers, so every planned host is
            // asked directly instead (§9.5).
            for host in sweepHosts(plan) { enqueueUnicastTarget(host) }
        }
        // Same rule as the multicast opener: a run that is stopping opens nothing. See the note
        // there for why task-group cancellation does not cover it.
        guard !stopping, !isFinished else { return }
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

    func runBonjourBrowse() async {
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

    func runProgressTicker() async {
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

    func runDeadlineWatchdog() async {
        guard await pause(until: overallDeadline) else { return }
        guard !isFinished, !stopping else { return }
        environment.logger.notice(.discovery, "discovery deadline reached after "
                                    + "\(Int(elapsed.seconds)) s")
        stopping = true
        await terminate(.deadline)
    }

    // MARK: - Termination

    func terminate(_ reason: DiscoverySummary.TerminationReason) async {
        // `isTerminating` is the re-entrancy guard and it is set before the first `await`, so the
        // watchdog, `cancel()` and the end of `run()` racing each other still produce one ending.
        guard !isTerminating, !isFinished else { return }
        isTerminating = true
        stopping = true
        activePhases = [.finished]

        // The wrap-up runs *before* `isFinished`, which silences every emitter. All three of these
        // are things the UI needs: the summaries of phases that were still open, the permission
        // diagnostic, and one last progress snapshot — which for a cancelled run is what leaves the
        // bar frozen where it stopped and the ETA gone, rather than mid-animation towards a number
        // that will never arrive (§8.4).
        for phase in accumulators.keys.sorted(by: { $0.specificity < $1.specificity }) {
            endPhase(phase)
        }
        evaluatePermissionHeuristic()
        emitProgress(force: true)
        isFinished = true

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

        // ⛔ THE SOCKETS CLOSE BEFORE `.finished` IS SAID, NOT AFTER. This was the other way round,
        // and it made the last event a lie: `.finished` means the run is over, a consumer is
        // entitled to act on it — `DiscoveryScanModel` releases the coordinator, the sheet goes
        // away — and every one of those actions happened while this run still owned open multicast
        // sockets. Nothing leaked permanently, because the awaits below did complete; the window
        // was just wide enough to be observed, which is precisely what
        // `discoveryCoordinatorCancelBeforeTheFirstProbeStillFinishes` observed on CI after
        // passing for weeks. A test that only fails when the consumer is faster than a socket close
        // is not flaky — it is a race being reported intermittently, which is how races present.
        //
        // Ordering it this way costs the summary whatever a close takes. That is the right price:
        // the whole claim `.finished` makes is that the network has gone quiet.
        await closeChannels()

        continuation?.yield(.finished(summary))
        continuation?.finish()
        continuation = nil
        runTask?.cancel()
    }

    private func closeChannels() async {
        let channels = openChannels
        openChannels = []
        for channel in channels { await channel.close() }
    }

    /// Takes ownership of an open channel so termination can close it.
    ///
    /// ⚠️ A CHANNEL THAT ARRIVES AFTER THE END IS CLOSED, NOT STORED. Every caller reaches this
    /// line as `let channel = await openSomething(); register(channel)`, and that `await` is a
    /// suspension point the run can end across — `cancel()` from a dismissed sheet is the ordinary
    /// way it happens, and it happens *most* easily on the very first probe, when the opener is the
    /// only thing in flight. Appending then would put a live socket on a list `closeChannels()` has
    /// already drained and will never read again: a multicast socket held for the process's
    /// lifetime by a scan the user closed a second after opening.
    ///
    /// This is what `discoveryCoordinatorCancelBeforeTheFirstProbeStillFinishes` was reporting. It
    /// had passed for weeks and started failing on a CI runner, which is exactly how a race
    /// presents — the assertion was right the whole time and the timing finally exposed it.
    ///
    /// ⚠️ SYNCHRONOUS, AND THE CLOSE IS SPAWNED RATHER THAN AWAITED. The obvious spelling is
    /// `async` with `await channel.close()`, and it was written that way first. But both callers
    /// sit on the multicast probe path, where `DiscoveryCoordinatorTests` asserts probe times to
    /// the millisecond against a *virtual* clock whose pump infers quiescence from the tasks in
    /// flight. Making this `async` put a suspension point between opening a channel and scheduling
    /// its probes, which is precisely the kind of extra hop that inference is sensitive to. The
    /// guarantee does not need it: the late path is not the hot path — it runs only for a channel
    /// that finished opening after the run ended — so a spawned close costs nothing real and keeps
    /// the ordinary path exactly as timed as it was.
    func register(_ channel: any DatagramChannel) {
        guard !isTerminating, !isFinished else {
            Task { await channel.close() }
            return
        }
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

    func resolveMulticastAvailability() {
        if case .single = configuration.mode {
            // A named address needs no group probe, and asking for one would trigger the local
            // network prompt for nothing. This is not a degradation the user should be told about —
            // nothing was lost — so no diagnostic is recorded and the `.fail` policy does not apply.
            isSingleAddressRun = true
            isDegraded = true
            return
        }
        guard !entitlements.shouldAttemptMulticast else { return }
        noteMulticastUnavailable(.entitlementMissing)
    }

    func noteMulticastUnavailable(_ reason: MulticastUnavailableReason) {
        entitlements.multicastVerifiedWorking = false
        guard !isDegraded else { return }
        isDegraded = true
        record(.multicastUnavailable(reason: reason))
    }

    // MARK: - Budgets

    /// Claims one datagram against the run cap. Exhaustion stops sending and keeps every result;
    /// a scan that is politely incomplete beats one that looks like a flood (§6.10).
    func claimDatagram(phase: DiscoveryPhase) -> Bool {
        guard datagramsSent < configuration.maxDatagramsPerRun else {
            recordBudget(.datagrams, limit: configuration.maxDatagramsPerRun)
            return false
        }
        datagramsSent += 1
        accumulators[phase]?.datagramsSent += 1
        return true
    }

    /// Claims connects against the per-run ceiling of `4 × plannedHosts + 512` (§6.10).
    func claimConnects(_ count: Int, hosts: Int) -> Bool {
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

    func yield(_ event: DiscoveryEvent) {
        guard !isFinished else { return }
        continuation?.yield(event)
    }

    /// Records a diagnostic once and emits it. Duplicates are dropped: a flood diagnostic that itself
    /// floods is worse than none.
    func record(_ diagnostic: DiscoveryDiagnostic) {
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
    func emitProgress(force: Bool = false) {
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

    func beginPhase(_ phase: DiscoveryPhase) {
        guard accumulators[phase] == nil else { return }
        accumulators[phase] = PhaseAccumulator(start: environment.clock.now())
        activePhases.insert(phase)
    }

    func endPhase(_ phase: DiscoveryPhase) {
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
    func pause(for duration: Duration) async -> Bool {
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
    ///
    /// ⚠️ Goes through `sleep(until:)` rather than converting to a duration here. The two are the
    /// same thing on a real clock; on the virtual one the tests drive, converting to a duration
    /// measures against a reading that can be stale by the time the sleeper is filed, and the
    /// difference lands directly in the probe timestamps §2.2 pins to the millisecond. See the note
    /// on `DiscoveryClock.sleep(until:)`.
    @discardableResult
    func pause(until offset: Duration) async -> Bool {
        guard !stopping, !isFinished else { return false }
        let deadline = runStart + offset
        guard deadline > environment.clock.now() else { return !Task.isCancelled }
        do {
            try await environment.clock.sleep(until: deadline)
        } catch {
            return false
        }
        return !stopping && !isFinished && !Task.isCancelled
    }
}
