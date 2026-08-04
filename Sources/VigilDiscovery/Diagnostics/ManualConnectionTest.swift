//
//  ManualConnectionTest.swift
//  VigilDiscovery
//

import Foundation

import VigilProtocols

/// The credential-free prefix of Stream Doctor used by the manual-add form.
public struct ManualConnectionTest: Sendable {
    /// The same injected transports a discovery scan uses.
    public let environment: DiscoveryEnvironment

    /// Creates a test without constructing a second network stack.
    public init(environment: DiscoveryEnvironment) { self.environment = environment }

    /// Probes both configured ports and sends `OPTIONS` only when the RTSP port accepted TCP.
    public func run(host: IPv4Address, httpPort: UInt16, rtspPort: UInt16,
                    useTLS: Bool) async -> ManualConnectionTestResult {
        async let http = environment.tcpProbe.probe(host, port: httpPort,
                                                    timeout: .seconds(1), interfaceName: nil)
        async let rtsp = environment.tcpProbe.probe(host, port: rtspPort,
                                                    timeout: .seconds(1), interfaceName: nil)
        let (httpOutcome, rtspOutcome) = await (http, rtsp)
        var speaksRTSP = false
        if rtspOutcome == .open {
            let request = FingerprintCodec.rtspOptionsRequest(host: host, port: rtspPort)
            if let response = try? await environment.exchange.exchange(
                host: host, port: rtspPort, useTLS: useTLS, request: request,
                readLimit: 32 * 1_024, timeout: .seconds(1), interfaceName: nil) {
                speaksRTSP = FingerprintCodec.classifyRTSP(response).isRTSP
            }
        }
        return ManualConnectionTestResult(http: httpOutcome, rtsp: rtspOutcome,
                                          speaksRTSP: speaksRTSP)
    }
}

public struct ManualConnectionTestResult: Sendable, Hashable {
    /// Outcome of the control-plane TCP probe.
    public let http: TCPProbeOutcome
    /// Outcome of the RTSP TCP probe.
    public let rtsp: TCPProbeOutcome
    /// Whether the RTSP endpoint returned a syntactically recognisable RTSP response.
    public let speaksRTSP: Bool

    /// Creates a complete result suitable for tests and UI projection.
    public init(http: TCPProbeOutcome, rtsp: TCPProbeOutcome, speaksRTSP: Bool) {
        self.http = http
        self.rtsp = rtsp
        self.speaksRTSP = speaksRTSP
    }
}
