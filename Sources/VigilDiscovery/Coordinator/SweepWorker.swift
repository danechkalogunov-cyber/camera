//
//  SweepWorker.swift
//  VigilDiscovery
//
//  The per-host half of the sweep: TCP connect probes on a port list, and then at most three short
//  fingerprint exchanges. Deliberately a plain `Sendable` value with no actor isolation, so the
//  coordinator can run `maxInFlightConnects` of these at once instead of serialising every probe on
//  its own executor.
//  Implements docs/spec-discovery.md §6.5, §6.6, §6.7 and the per-host budgets of §6.10.
//

import Foundation
import VigilProtocols

/// What one batch of connects cost and learned.
struct ConnectBatch: Sendable {
    /// Outcome per port attempted.
    var outcomes: [UInt16: TCPProbeOutcome]
    /// Connects actually attempted, for the run-wide budget.
    var connectsAttempted: Int
}

/// What the fingerprints learned, and how many requests it took.
struct FingerprintBatch: Sendable {
    var rtsp: RTSPFingerprint?
    var http: HTTPFingerprint?
    /// Exchanges attempted. Never more than `SweepWorker.maxRequestsPerHost` (§6.10).
    var requestsAttempted: Int
}

/// Probes one host without touching any shared state.
///
/// Everything it needs is injected and `Sendable`, which is what lets the coordinator fan out 128 of
/// these at once. Nothing here can express a credential: the only bytes it sends are the ones
/// `FingerprintCodec` builds, and that type has no credential parameter (§6.10).
struct SweepWorker: Sendable {

    /// Largest fingerprint response buffered. A camera's 401 is a few hundred bytes; a login page can
    /// be megabytes, and nothing past the header block tells us anything.
    static let readLimit = 4_096

    /// Hard ceiling on fingerprint exchanges per host (§6.10).
    static let maxRequestsPerHost = 3

    /// Ports treated as HTTP, in preference order. 80 first: a device with both 80 and 443 open is
    /// better fingerprinted in the clear than through a self-signed TLS stack that may not complete.
    static let httpPortPreference: [UInt16] = [80, 8_080, 8_000, 443]

    /// Ports treated as RTSP, in preference order.
    static let rtspPortPreference: [UInt16] = [554, 8_554]

    let tcpProbe: any TCPProbing
    let exchange: any ByteExchanging
    let connectTimeout: Duration
    let fingerprintTimeout: Duration
    let interfaceName: String?

    /// Probes `ports` on `host`, in the order given.
    ///
    /// Ports are probed **sequentially**, so one host contributes exactly one in-flight connect and
    /// the 128-connect ceiling is a simple count of live workers. Cancellation is checked between
    /// ports, so `cancel()` stops the network within one connect timeout. Every outcome is recorded,
    /// including timeouts: "everything timed out" is the evidence the local-network-permission
    /// heuristic needs (§9.4).
    func connect(host: IPv4Address, ports: [UInt16]) async -> ConnectBatch {
        var outcomes: [UInt16: TCPProbeOutcome] = [:]
        var connects = 0
        for port in ports {
            if Task.isCancelled { break }
            outcomes[port] = await tcpProbe.probe(host, port: port, timeout: connectTimeout,
                                                 interfaceName: interfaceName)
            connects += 1
        }
        return ConnectBatch(outcomes: outcomes, connectsAttempted: connects)
    }

    /// Runs the RTSP and HTTP fingerprints for a host whose `openPorts` are known.
    ///
    /// RTSP goes first because it is the cheapest strong signal — a realm names the vendor outright.
    /// The `/` follow-up is sent **only** when the ISAPI request produced no answer at all: a device
    /// that answered 404 has already told us it is not Hikvision, and asking again would spend a
    /// request to learn the same thing.
    func fingerprint(host: IPv4Address, openPorts: Set<UInt16>) async -> FingerprintBatch {
        var batch = FingerprintBatch(requestsAttempted: 0)
        guard !openPorts.isEmpty, !Task.isCancelled else { return batch }

        if let rtspPort = Self.rtspPortPreference.first(where: openPorts.contains) {
            let request = FingerprintCodec.rtspOptionsRequest(host: host, port: rtspPort)
            let response = await send(request, to: host, port: rtspPort, useTLS: false)
            batch.requestsAttempted += 1
            if let response { batch.rtsp = FingerprintCodec.classifyRTSP(response) }
        }

        guard let httpPort = Self.httpPortPreference.first(where: openPorts.contains),
              batch.requestsAttempted < Self.maxRequestsPerHost, !Task.isCancelled else {
            return batch
        }
        let useTLS = httpPort == 443
        let isapi = await send(FingerprintCodec.isapiDeviceInfoRequest(host: host),
                               to: host, port: httpPort, useTLS: useTLS)
        batch.requestsAttempted += 1
        if let isapi { batch.http = FingerprintCodec.classifyHTTP(isapi, isISAPIPath: true) }

        guard batch.http?.statusCode == nil, batch.requestsAttempted < Self.maxRequestsPerHost,
              !Task.isCancelled else {
            return batch
        }
        let root = await send(FingerprintCodec.rootRequest(host: host),
                              to: host, port: httpPort, useTLS: useTLS)
        batch.requestsAttempted += 1
        if let root { batch.http = FingerprintCodec.classifyHTTP(root, isISAPIPath: false) }
        return batch
    }

    /// One exchange, returning `nil` when it failed. A failure is not worth propagating: plenty of
    /// devices close the connection on an unexpected request, and that tells us only that this
    /// particular fingerprint is unavailable.
    private func send(_ request: Data, to host: IPv4Address, port: UInt16,
                      useTLS: Bool) async -> Data? {
        do {
            return try await exchange.exchange(host: host, port: port, useTLS: useTLS,
                                               request: request, readLimit: Self.readLimit,
                                               timeout: fingerprintTimeout,
                                               interfaceName: interfaceName)
        } catch {
            return nil
        }
    }
}
