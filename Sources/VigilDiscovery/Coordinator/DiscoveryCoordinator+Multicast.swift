//
//  DiscoveryCoordinator+Multicast.swift
//  VigilDiscovery
//
//  The multicast phases: SADP and WS-Discovery over the whole segment at once.
//  Split from DiscoveryCoordinator.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

import Foundation
import VigilProtocols

// MARK: - Multicast phases

/// ⚠️ Members are `internal`, not `private`: Swift scopes `private` to one file.
/// `Scripts/lint.py`'s `split-access` rule fails the build on any left behind.
extension DiscoveryCoordinator {

    // MARK: - Multicast phases

    /// The listening window, as fixed at the start of the run: run start to the last probe plus the
    /// listen tail — 10 ms + 1 000 ms + 2 500 ms = 3 510 ms with the shipping schedule (§2.2).
    var multicastWindow: Duration { multicastWindowValue }

    /// Computes that window, once, before any channel opens.
    ///
    /// It must not be recomputed later, and that is not a style preference: one interface failing to
    /// join flips ``isDegraded``, and a recomputed window would then collapse to zero for the
    /// interfaces that *are* listening — cutting their tail short and, worse, jumping the progress
    /// bar's multicast quarter to complete while SADP is still running.
    func plannedMulticastWindow() -> Duration {
        guard !isDegraded, !isSingleAddressRun, !multicastSchedule.isEmpty else { return .zero }
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

    func runMulticastPhase(_ phase: DiscoveryPhase, plan: DiscoveryPlan) async {
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
        // ⛔ Checked before the socket is made, not after. `register` closes a channel that arrives
        // too late, but a cancelled scan should not have *opened* one — a multicast join is a
        // visible act on the segment, and doing it after the user closed the sheet is the kind of
        // thing that gets an app noticed by a network administrator. The group's own cancellation
        // does not cover this: `addTask` children always run their body, and neither the factory
        // call nor the actor hop after it throws on cancellation.
        guard !stopping, !isFinished else { return }
        let port = phase == .sadp ? SADPCodec.port : WSDiscoveryCodec.port
        let spec = MulticastGroupSpec(group: .discoveryMulticastGroup, port: port,
                                      preferredLocalPort: port,
                                      localAddress: interface.address,
                                      interfaceName: interface.name)
        guard let channel = await openMulticastChannel(spec, phase: phase) else { return }
        await register(channel)
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
    func messageID(at index: Int) -> UUID {
        guard index < wsdMessageIDs.count else { return environment.uuidGenerator() }
        return wsdMessageIDs[index]
    }

    /// The `Types` filter for WS-Discovery probe `index`: NVT, then NVT+Device, then the wildcard.
    /// A schedule longer than three repeats the wildcard, which is the widest of the three.
    func probeTypes(at index: Int) -> WSDProbeTypes {
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
}
