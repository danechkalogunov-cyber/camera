//
//  ByteExchanger.swift
//  VigilTransport
//
//  One request/response over a fresh TCP or TLS connection, for fingerprinting.
//  macOS-only. Backs `VigilDiscovery.ByteExchanging`; see docs/spec-discovery.md §6.7 and §11.2.
//
//  ⛔ THERE IS NO CREDENTIAL PARAMETER, and its absence is the point. "Discovery never
//  authenticates" is enforced by this type's shape rather than by review: a caller cannot express
//  an `Authorization` header without hand-writing one into `request`, which the test doubles scan
//  for and fail on (§6.10). Do not add one — route credentialed traffic through `VigilISAPI`, which
//  applies a real trust policy.
//

#if os(macOS)

import Foundation
import Network
import os

import VigilDiscovery
import VigilProtocols

// MARK: - ByteExchanger

/// Sends a fixed request and reads a bounded answer.
public struct ByteExchanger: ByteExchanging {

    private let queue: DispatchQueue

    /// Creates an exchanger.
    public init(queue: DispatchQueue = DispatchQueue(label: "vigil.discovery.exchange")) {
        self.queue = queue
    }

    /// Sends `request` and returns at most `readLimit` bytes of the answer.
    ///
    /// - Returns: whatever came back, possibly empty. A truncated or empty answer is **data**, not
    ///   an error: the fingerprint classifiers are total over any bytes, and a device that closes
    ///   the connection after two bytes has still told us something about itself.
    /// - Throws: `.probeSendFailed` when the exchange never happened at all.
    public func exchange(host: VigilProtocols.IPv4Address, port: UInt16, useTLS: Bool,
                         request: Data, readLimit: Int, timeout: Duration,
                         interfaceName: String?) async throws(DiscoveryError) -> Data {
        guard let address = Network.IPv4Address(host.description),
              let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw DiscoveryError.probeSendFailed
        }
        let endpoint = NWEndpoint.hostPort(host: .ipv4(address), port: endpointPort)
        let parameters = useTLS ? Self.tlsParameters() : NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.loopback]
        parameters.includePeerToPeer = false
        if let interfaceName, let interface = NWInterfaceIndex.named(interfaceName) {
            parameters.requiredInterface = interface
        }
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }

        let connection = NWConnection(to: endpoint, using: parameters)
        let result = await Self.run(connection, request: request, readLimit: readLimit,
                                    queue: queue, timeout: timeout)
        connection.cancel()
        guard let result else { throw DiscoveryError.probeSendFailed }
        return result
    }

    // MARK: - Private Helpers

    /// TLS that accepts **any** certificate.
    ///
    /// ⚠️ Permissible only because no credential ever crosses this connection (§11.2). A camera's
    /// certificate is self-signed by definition and rejecting it would make HTTPS fingerprinting
    /// impossible; what makes that safe is the rule at the top of this file, not the TLS options.
    /// `VigilISAPI` applies real trust policy to credentialed traffic and must keep doing so.
    private static func tlsParameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, _, complete in complete(true) },
            DispatchQueue(label: "vigil.discovery.tls.verify"))
        return NWParameters(tls: tls)
    }

    /// Connects, writes, reads once, and gives up at the deadline.
    ///
    /// One read, not a loop to `readLimit`: a fingerprint lives in the first packet — an RTSP
    /// `OPTIONS` reply, an HTTP status line and `Server:` header — and looping until the peer closes
    /// would hold a connection open against a device that keeps it alive for a minute.
    private static func run(_ connection: NWConnection, request: Data, readLimit: Int,
                            queue: DispatchQueue, timeout: Duration) async -> Data? {
        await withCheckedContinuation { continuation in
            let box = ExchangeOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: request, completion: .contentProcessed { error in
                        guard error == nil else { return box.finish(continuation, with: nil) }
                        connection.receive(minimumIncompleteLength: 1,
                                           maximumLength: max(1, readLimit)) { data, _, _, _ in
                            // An empty answer is still an answer; only a total failure is nil.
                            box.finish(continuation, with: data ?? Data())
                        }
                    })
                case .failed, .cancelled:
                    box.finish(continuation, with: nil)
                case let .waiting(error):
                    // `.waiting` retries for ever inside `NWConnection`. For a bounded probe it is
                    // the verdict.
                    _ = error
                    box.finish(continuation, with: nil)
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout.seconds) {
                box.finish(continuation, with: nil)
            }
        }
    }
}

// MARK: - ExchangeOnce

/// Resumes once. See `OnceBox` in TCPConnectProber.swift for why every one of these needs a guard.
private struct ExchangeOnce: Sendable {

    private let isDone = OSAllocatedUnfairLock<Bool>(initialState: false)

    func finish(_ continuation: CheckedContinuation<Data?, Never>, with value: Data?) {
        let shouldResume = isDone.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        guard shouldResume else { return }
        continuation.resume(returning: value)
    }
}

#endif  // os(macOS)
