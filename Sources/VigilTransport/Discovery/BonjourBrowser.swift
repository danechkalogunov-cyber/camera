//
//  BonjourBrowser.swift
//  VigilTransport
//
//  Bonjour browsing and resolution, over `Network.NWBrowser`.
//  macOS-only. Backs `VigilDiscovery.ServiceBrowsing`; see docs/spec-discovery.md §6.8.
//
//  The cheapest rung of the ladder: a device that advertises `_rtsp._tcp` gives up its name, its
//  address and often its model in a TXT record, for one browse and no probe at all. Few Hikvision
//  cameras do — but an NVR frequently does, and the instance name is the friendliest label any
//  device on the segment ever offers.
//

#if os(macOS)

import Foundation
import Network
import os

import VigilDiscovery
import VigilProtocols

// MARK: - BonjourBrowser

/// Browses service types and resolves what it finds.
///
/// **Never throws.** A browse that will not start is indistinguishable from a network with no
/// Bonjour on it, and neither is fatal to a run (§6.8).
public struct BonjourBrowser: ServiceBrowsing {

    private let queue: DispatchQueue

    /// Creates a browser.
    public init(queue: DispatchQueue = DispatchQueue(label: "vigil.discovery.bonjour")) {
        self.queue = queue
    }

    /// Browses `types` until the returned stream is cancelled.
    ///
    /// One `NWBrowser` per type, because `NWBrowser` takes exactly one descriptor. They share a
    /// stream and are all cancelled together when the consumer stops iterating.
    public func browse(types: [String]) -> AsyncStream<BonjourService> {
        AsyncStream { continuation in
            let browsers = types.map { type in
                Self.browser(for: type, queue: queue, continuation: continuation)
            }
            continuation.onTermination = { _ in
                for browser in browsers { browser.cancel() }
            }
            for browser in browsers { browser.start(queue: queue) }
        }
    }

    // MARK: - Private Helpers

    /// One browser, wired to yield resolved services into `continuation`.
    private static func browser(
        for type: String, queue: DispatchQueue,
        continuation: AsyncStream<BonjourService>.Continuation) -> NWBrowser {
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: type, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case let .service(name, serviceType, domain, _) = result.endpoint else {
                    continue
                }
                let txt = Self.txt(from: result.metadata)
                // ⛔ Yielded before resolution, and again after it if resolution succeeds. A record
                // with no address contributes nothing to the merge — discovery keys everything on
                // an address — but the *name* is worth having early, and a resolve that never
                // completes must not swallow the sighting entirely.
                continuation.yield(BonjourService(name: name, type: serviceType, domain: domain,
                                                  address: nil, port: nil, txt: txt))
                resolve(result.endpoint, type: serviceType, name: name, domain: domain,
                        txt: txt, queue: queue, continuation: continuation)
            }
        }
        // A browser that cannot start is a network without Bonjour. Nothing is reported and nothing
        // fails: §6.8 is explicit that the two are indistinguishable and neither ends a run.
        browser.stateUpdateHandler = { _ in }
        return browser
    }

    /// Resolves one endpoint to an address and port, then yields the completed record.
    ///
    /// A short-lived `NWConnection` is the supported way to resolve a Bonjour endpoint: there is no
    /// resolve API on `NWBrowser`. It is cancelled as soon as the path carries an address — nothing
    /// is sent, exactly as in `TCPConnectProber`.
    private static func resolve(_ endpoint: NWEndpoint, type: String, name: String, domain: String,
                                txt: [String: String], queue: DispatchQueue,
                                continuation: AsyncStream<BonjourService>.Continuation) {
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.loopback]
        let connection = NWConnection(to: endpoint, using: parameters)
        let box = ResolveOnce()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready, .preparing:
                guard let remote = connection.currentPath?.remoteEndpoint,
                      case let .hostPort(host, port) = remote,
                      case let .ipv4(address) = host,
                      // Through the string form: the two IPv4 types disagree about byte order.
                      let parsed = VigilProtocols.IPv4Address(String(describing: address)) else {
                    return
                }
                guard box.claim() else { return }
                continuation.yield(BonjourService(name: name, type: type, domain: domain,
                                                  address: parsed, port: port.rawValue, txt: txt))
                connection.cancel()
            case .failed, .cancelled:
                _ = box.claim()
                connection.cancel()
            case .setup, .waiting:
                break
            @unknown default:
                break
            }
        }
        connection.start(queue: queue)
        // Resolution is best-effort and must not leak a connection when a device advertises a name
        // it will not answer for.
        queue.asyncAfter(deadline: .now() + 5) {
            _ = box.claim()
            connection.cancel()
        }
    }

    /// TXT record keys and values, keys lowercased as the protocol requires.
    private static func txt(from metadata: NWBrowser.Result.Metadata) -> [String: String] {
        guard case let .bonjour(record) = metadata else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in record.dictionary {
            out[key.lowercased()] = value
        }
        return out
    }
}

// MARK: - ResolveOnce

/// Lets exactly one of the racing paths through. Unlike the continuation guards elsewhere this one
/// gates a *yield*, not a resume — a stream tolerates extra values, but a duplicate record would
/// reach the merge engine as a second sighting of the same device.
private struct ResolveOnce: Sendable {

    private let isDone = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// True for the first caller only.
    func claim() -> Bool {
        isDone.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
    }
}

// MARK: - SystemDiscoveryClock

/// The clock a real run uses.
///
/// Two readings, deliberately not one: `wallNow` is what a record shows a user and may jump when
/// NTP corrects, while `now()` is monotonic and is what a deadline and an ETA must be measured on.
/// Using the wall clock for a deadline makes a sweep stop early — or never — when the clock steps.
public struct SystemDiscoveryClock: DiscoveryClock {

    /// Creates a clock.
    public init() {}

    public var wallNow: Date { Date() }

    public func now() -> MediaInstant {
        MediaInstant(nanoseconds: Int64(DispatchTime.now().uptimeNanoseconds))
    }

    /// Cancellable sleep.
    ///
    /// `Task.sleep` and not a timer: it throws `CancellationError` on cancellation, which is the
    /// mechanism §8.4 relies on to close every socket inside 50 ms. A sleep that swallowed
    /// cancellation would make a stopped scan keep its sockets open until its next deadline.
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

#endif  // os(macOS)
