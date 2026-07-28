//
//  DiscoveryCoordinator+Sweep.swift
//  VigilDiscovery
//
//  Walking the subnet address by address, inside the budget the run was given.
//  Split from DiscoveryCoordinator.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

import Foundation
import VigilProtocols

// MARK: - The unicast sweep

/// ⚠️ Members are `internal`, not `private`: Swift scopes `private` to one file.
/// `Scripts/lint.py`'s `split-access` rule fails the build on any left behind.
extension DiscoveryCoordinator {

    // MARK: - Sweep

    /// Hosts this run will probe, after `resumeFrom` — the "Keep scanning" continuation of a run that
    /// hit its deadline (§8.3).
    func sweepHosts(_ plan: DiscoveryPlan) -> [IPv4Address] {
        let skip = max(0, min(configuration.resumeFrom, plan.hostOrder.count))
        return Array(plan.hostOrder.dropFirst(skip))
    }

    func runSweep(_ plan: DiscoveryPlan) async {
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
        endPhase(.sweepB)
        endPhase(.fingerprint)
    }

    /// One host: tier A, then tier B if anything answered, then the fingerprints.
    ///
    /// Runs off the actor — `SweepWorker` is a plain value — so `limit` of these are genuinely
    /// concurrent. Only the bookkeeping hops back onto the actor.
    private nonisolated func probeOneHost(_ host: IPv4Address, worker: SweepWorker,
                                          tierA: [UInt16], tierB: [UInt16]) async {
        let first = await worker.connect(host: host, ports: tierA)
        var result = HostProbeResult(address: host, portOutcomes: first.outcomes)
        let connects = first.connectsAttempted
        var tierBConnects = 0
        var requests = 0

        if result.isAlive, await shouldProbeTierB(portCount: tierB.count) {
            let second = await worker.connect(host: host, ports: tierB)
            for (port, outcome) in second.outcomes { result.portOutcomes[port] = outcome }
            tierBConnects = second.connectsAttempted
        }
        if !result.openPorts.isEmpty, await shouldFingerprint() {
            let batch = await worker.fingerprint(host: host, openPorts: result.openPorts)
            result.rtsp = batch.rtsp
            result.http = batch.http
            requests = batch.requestsAttempted
        }
        await completeHost(result, connects: connects, tierBConnects: tierBConnects,
                           requests: requests)
    }

    /// Whether tier B may run, and the denominator growth it causes.
    ///
    /// The growth is recorded here rather than at completion time so the bar slows down while the
    /// extra work is outstanding instead of jumping when it lands (§8.2).
    private func shouldProbeTierB(portCount: Int) -> Bool {
        guard !stopping, portCount > 0 else { return false }
        estimator.schedulePortProbes(portCount)
        beginPhase(.sweepB)
        return true
    }

    private func shouldFingerprint() -> Bool {
        guard !stopping else { return false }
        beginPhase(.fingerprint)
        return true
    }

    /// Folds one host's results in and updates every counter the progress bar reads.
    ///
    /// Tier A and tier B connects are counted apart so each phase summary reports the SYNs it was
    /// actually responsible for; a support log that blamed tier A for tier B's traffic would send the
    /// reader looking in the wrong place.
    private func completeHost(_ result: HostProbeResult, connects: Int, tierBConnects: Int,
                              requests: Int) {
        tcpConnects += connects + tierBConnects
        httpRequests += requests
        accumulators[.sweepA]?.connectsAttempted += connects
        accumulators[.sweepB]?.connectsAttempted += tierBConnects
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
        // A caller who named one address gets exactly that address probed. Two extra SYNs to a host
        // they did not ask about would be a surprise, and the heuristic the canary feeds needs 20
        // probed hosts before it can say anything anyway.
        guard !isSingleAddressRun else { return }
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
}
