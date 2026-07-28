//
//  DiscoveryCoordinator+Ingestion.swift
//  VigilDiscovery
//
//  Taking what a probe found and folding it into the merged result set.
//  Split from DiscoveryCoordinator.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

import Foundation
import VigilProtocols

// MARK: - Ingestion

/// ⚠️ Members are `internal`, not `private`: Swift scopes `private` to one file.
/// `Scripts/lint.py`'s `split-access` rule fails the build on any left behind.
extension DiscoveryCoordinator {

    // MARK: - Ingestion

    /// Folds a SADP datagram in. Everything on the group is classified rather than filtered: our own
    /// looped-back probe, another tool's probe, another tool's answers and obfuscated payloads all
    /// have a defined meaning and none of them may abort a run (§4.5, §4.8).
    func ingestSADP(_ datagram: InboundDatagram, source: DiscoverySource,
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
    func ingestWSD(_ datagram: InboundDatagram, phase: DiscoveryPhase) {
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
    func ingest(_ observation: DeviceObservation, phase: DiscoveryPhase) {
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
}
