//
//  DiscoveryCoordinatorDoubles.swift
//  VigilDiscoveryTests
//
//  The fake network a coordinator run is driven through: a virtual clock with a scheduler, scripted
//  datagram channels, a table-driven TCP prober and fingerprint exchanger, and a test bed that
//  assembles them into a `DiscoveryEnvironment` and collects a whole run's events. No socket, no
//  wall-clock wait, and every outbound byte passed through `DiscoveryCredentialGuard`.
//  Covers docs/spec-discovery.md §13.1; used by tests 78–100 of §13.7 and §13.8.
//

import Foundation
import Testing

import VigilProtocols
import VigilTestKit
@testable import VigilDiscovery

// MARK: - Scoped locking
// MARK: - Fingerprint exchanger

/// What a scripted host answers to each of the three fingerprint requests. `nil` means "closed the
/// connection", which the classifiers must survive.
struct MockHTTPResponses: Sendable {
    var rtspOptions: String?
    var isapiDeviceInfo: String?
    var root: String?

    init(rtspOptions: String? = nil, isapiDeviceInfo: String? = nil, root: String? = nil) {
        self.rtspOptions = rtspOptions
        self.isapiDeviceInfo = isapiDeviceInfo
        self.root = root
    }
}

/// Table-driven `ByteExchanging` that fails the test if any request carries authentication material.
///
/// §13.1 asks for exactly this: the "discovery never authenticates" rule enforced by the double, so
/// that no future change can quietly add a credential and still pass review.
final class MockExchanger: ByteExchanging, @unchecked Sendable {
    // @unchecked is justified: all mutable state lives in `state`, a LockedBox.

    private let table: [UInt32: MockHTTPResponses]
    private let clock: VirtualDiscoveryClock
    private let latency: Duration
    private let state = LockedBox([Data]())

    init(clock: VirtualDiscoveryClock, table: [UInt32: MockHTTPResponses] = [:],
         latency: Duration = .milliseconds(10)) {
        self.clock = clock
        self.table = table
        self.latency = latency
    }

    func exchange(host: IPv4Address, port: UInt16, useTLS: Bool, request: Data,
                  readLimit: Int, timeout: Duration,
                  interfaceName: String?) async throws(DiscoveryError) -> Data {
        DiscoveryCredentialGuard.requireNoCredentials(
            in: request, label: "fingerprint request to \(host):\(port)")
        state.withLock { $0.append(request) }
        if latency > .zero { try? await clock.sleep(for: latency) }
        let text = String(decoding: request, as: UTF8.self)
        let responses = table[host.rawValue]
        let answer: String?
        if text.hasPrefix("OPTIONS") {
            answer = responses?.rtspOptions
        } else if text.contains("/ISAPI/System/deviceInfo") {
            answer = responses?.isapiDeviceInfo
        } else {
            answer = responses?.root
        }
        guard let answer else { throw DiscoveryError.probeSendFailed }
        return Data(answer.utf8).prefix(readLimit)
    }

    /// Every request body sent, so a test can prove the credential guard was actually exercised.
    var requests: [Data] { state.withLock { $0 } }
}

// MARK: - Host facts

/// Returns a fixed interface list, or a failure.
struct StaticInterfaceEnumerator: InterfaceEnumerating {
    let list: [NetworkInterfaceInfo]
    let failure: DiscoveryError?
    /// Read on every call, purely so the virtual clock's scheduler can see that the run is alive
    /// during planning, which touches no clock of its own.
    let clock: VirtualDiscoveryClock?

    init(_ list: [NetworkInterfaceInfo], failure: DiscoveryError? = nil,
         clock: VirtualDiscoveryClock? = nil) {
        self.list = list
        self.failure = failure
        self.clock = clock
    }

    func interfaces() throws(DiscoveryError) -> [NetworkInterfaceInfo] {
        _ = clock?.now()
        if let failure { throw failure }
        return list
    }
}

/// Returns a fixed ARP snapshot, or a failure.
struct StaticARPTable: ARPTableProviding {
    let entries: [ARPEntry]
    let failure: DiscoveryError?
    /// See `StaticInterfaceEnumerator.clock`.
    let clock: VirtualDiscoveryClock?

    init(_ entries: [ARPEntry] = [], failure: DiscoveryError? = nil,
         clock: VirtualDiscoveryClock? = nil) {
        self.entries = entries
        self.failure = failure
        self.clock = clock
    }

    func snapshot() throws(DiscoveryError) -> [ARPEntry] {
        _ = clock?.now()
        if let failure { throw failure }
        return entries
    }
}

/// Yields a fixed set of Bonjour services for the browsed types and then finishes.
struct ScriptedBonjourBrowser: ServiceBrowsing {
    let services: [BonjourService]

    init(_ services: [BonjourService] = []) {
        self.services = services
    }

    func browse(types: [String]) -> AsyncStream<BonjourService> {
        let matching = services.filter { types.contains($0.type) }
        return AsyncStream { continuation in
            for service in matching { continuation.yield(service) }
            continuation.finish()
        }
    }
}

// MARK: - Test bed

/// A scripted LAN, assembled into a `DiscoveryEnvironment` and run to completion.
///
/// One instance per test: it keeps every channel the coordinator opened, so a test can assert what
/// was sent, when, and whether it was closed.
final class DiscoveryTestBed: @unchecked Sendable {
    // @unchecked is justified: all mutable state lives in `state`, a LockedBox; the rest is `let`.

    /// Everything the fake network knows. The defaults describe an empty but healthy `/24`.
    struct Script: Sendable {
        var interfaces: [NetworkInterfaceInfo] = [DiscoveryTestBed.defaultInterface]
        var interfaceFailure: DiscoveryError?
        var arp: [ARPEntry] = []
        var arpFailure: DiscoveryError?
        var bonjour: [BonjourService] = []
        /// Answers delivered on the SADP multicast channel of the first interface.
        var sadpAnswers: [ScriptedDatagram] = []
        /// Answers delivered on the WS-Discovery multicast channel of the first interface.
        var wsdAnswers: [ScriptedDatagram] = []
        /// Answers delivered on the unicast channel — the degraded mode's only inbound path.
        var unicastAnswers: [ScriptedDatagram] = []
        var ports: [UInt32: [UInt16: TCPProbeOutcome]] = [:]
        var http: [UInt32: MockHTTPResponses] = [:]
        var answerLatency = Duration.milliseconds(5)
        var fingerprintLatency = Duration.milliseconds(10)
        var neverAnswers = false
        /// Thrown by the multicast factory for every spec — "multicast is refused outright".
        var multicastFailure: DiscoveryError?
        /// Preferred local ports whose first bind fails, forcing the ephemeral retry (test 98).
        var bindFailurePorts: Set<UInt16> = []
        /// Thrown by the unicast factory.
        var unicastFailure: DiscoveryError?
        /// Injected into every channel's `send`.
        var sendFailure: DiscoveryError?

        init() {}
    }

    private struct State {
        var channels: [MockDatagramChannel] = []
        var uuidIndex = 0
    }

    /// The interface every test uses unless it says otherwise: a plain wired `/24`.
    static let defaultInterface = NetworkInterfaceInfo(
        name: "en0", address: IPv4Address(192, 168, 1, 10), netmask: IPv4Address(255, 255, 255, 0))

    /// The identifiers a run draws, in order: the SADP `Uuid` first, then the WS-Discovery
    /// `MessageID`s. The first two are the fixtures' own values, so a scripted ProbeMatch correlates.
    static let scriptedUUIDs: [UUID] = [
        SADPFixtures.probeUUID,
        UUID(uuidString: "9A6F2C41-8B3D-4A7E-9F10-2C5B8E7D3A91") ?? UUID(),
        UUID(uuidString: "0F0F0F0F-0000-4000-8000-000000000002") ?? UUID(),
        UUID(uuidString: "0F0F0F0F-0000-4000-8000-000000000003") ?? UUID(),
        UUID(uuidString: "0F0F0F0F-0000-4000-8000-000000000004") ?? UUID(),
    ]

    let script: Script
    let clock = VirtualDiscoveryClock()
    let logger = RecordingLogger()
    let prober: MockTCPProber
    let exchanger: MockExchanger

    private let state = LockedBox(State())

    init(_ script: Script = Script()) {
        self.script = script
        prober = MockTCPProber(clock: clock, table: script.ports,
                               answerLatency: script.answerLatency,
                               neverAnswers: script.neverAnswers)
        exchanger = MockExchanger(clock: clock, table: script.http,
                                  latency: script.fingerprintLatency)
    }

    // MARK: Channels

    /// Every channel the coordinator opened, in order.
    var channels: [MockDatagramChannel] { state.withLock { $0.channels } }

    var multicastChannels: [MockDatagramChannel] { channels.filter { $0.spec != nil } }
    var unicastChannels: [MockDatagramChannel] { channels.filter { $0.spec == nil } }
    var sadpChannels: [MockDatagramChannel] { channels.filter { $0.spec?.port == SADPCodec.port } }
    var wsdChannels: [MockDatagramChannel] {
        channels.filter { $0.spec?.port == WSDiscoveryCodec.port }
    }

    /// Every outbound datagram from every channel, in send order.
    var allSent: [MockDatagramChannel.SentDatagram] {
        channels.flatMap(\.sent).sorted { $0.at.nanoseconds < $1.at.nanoseconds }
    }

    // MARK: Environment

    func environment(entitlements: EntitlementStatus) -> DiscoveryEnvironment {
        // Both factories spell out their signature inside the literal as well as outside it: Swift
        // 6.1 does not infer a closure's typed `throws(DiscoveryError)` from the contextual type and
        // otherwise widens it to `any Error`, which does not convert.
        let multicast: @Sendable (MulticastGroupSpec) async throws(DiscoveryError)
            -> any DatagramChannel = {
                (spec: MulticastGroupSpec) async throws(DiscoveryError) -> any DatagramChannel in
                try self.makeMulticast(spec)
            }
        let unicast: @Sendable (String?) async throws(DiscoveryError)
            -> any DatagramChannel = {
                (name: String?) async throws(DiscoveryError) -> any DatagramChannel in
                try self.makeUnicast(name)
            }
        return DiscoveryEnvironment(
            makeMulticastChannel: multicast,
            makeUnicastChannel: unicast,
            tcpProbe: prober,
            exchange: exchanger,
            interfaces: StaticInterfaceEnumerator(script.interfaces,
                                                  failure: script.interfaceFailure, clock: clock),
            arp: StaticARPTable(script.arp, failure: script.arpFailure, clock: clock),
            bonjour: ScriptedBonjourBrowser(script.bonjour),
            clock: clock,
            logger: logger,
            entitlements: entitlements,
            uuidGenerator: { [self] in nextUUID() })
    }

    private func makeMulticast(_ spec: MulticastGroupSpec) throws(DiscoveryError)
        -> any DatagramChannel {
        if let failure = script.multicastFailure { throw failure }
        if spec.preferredLocalPort != 0, script.bindFailurePorts.contains(spec.preferredLocalPort) {
            throw DiscoveryError.channelBindFailed(port: spec.preferredLocalPort, "EADDRINUSE")
        }
        // Only the first interface's channels carry the script: a device answering on two links at
        // once is real, but it would double every count a test is trying to pin down.
        let isPrimary = spec.interfaceName == script.interfaces.first?.name
        let inbound: [ScriptedDatagram]
        switch (isPrimary, spec.port) {
        case (true, SADPCodec.port): inbound = script.sadpAnswers
        case (true, WSDiscoveryCodec.port): inbound = script.wsdAnswers
        default: inbound = []
        }
        let channel = MockDatagramChannel(
            localPort: spec.preferredLocalPort == 0 ? 49_152 : spec.preferredLocalPort,
            interfaceName: spec.interfaceName, spec: spec, clock: clock, script: inbound,
            sendFailure: script.sendFailure)
        remember(channel)
        return channel
    }

    private func makeUnicast(_ interfaceName: String?) throws(DiscoveryError)
        -> any DatagramChannel {
        if let failure = script.unicastFailure { throw failure }
        let channel = MockDatagramChannel(localPort: 49_153, interfaceName: interfaceName,
                                          spec: nil, clock: clock,
                                          script: script.unicastAnswers,
                                          sendFailure: script.sendFailure)
        remember(channel)
        return channel
    }

    private func remember(_ channel: MockDatagramChannel) {
        state.withLock { $0.channels.append(channel) }
    }

    private func nextUUID() -> UUID {
        state.withLock { state in
            let uuid = Self.scriptedUUIDs[state.uuidIndex % Self.scriptedUUIDs.count]
            state.uuidIndex += 1
            return uuid
        }
    }

    // MARK: Running

    /// What a reaction hook wants the consumer to do next.
    enum Reaction: Sendable { case keepConsuming, stopConsuming }

    /// Runs one discovery to its end and returns everything it emitted.
    ///
    /// - Parameters:
    ///   - configuration: the run's configuration.
    ///   - entitlements: multicast present by default, because that is the shipping case.
    ///   - eventLimit: a safety valve. A coordinator that never finished would otherwise hang the
    ///     suite; breaking out of the loop tears the stream down, which cancels the run.
    ///   - react: called for every event, on the consuming task. This is where a test cancels
    ///     mid-run — at an exact point in the event sequence rather than after a wall-clock delay.
    func run(_ configuration: DiscoveryConfiguration = .default,
             entitlements: EntitlementStatus = EntitlementStatus(multicastEntitlementPresent: true),
             eventLimit: Int = 40_000,
             react: (@Sendable (DiscoveryEvent, DiscoveryCoordinator) async -> Reaction)? = nil)
        async -> DiscoveryRunResult {

        let pump = clock.startPump()
        let coordinator = DiscoveryCoordinator(environment: environment(entitlements: entitlements),
                                              configuration: configuration)
        var events: [DiscoveryEvent] = []
        let stream = await coordinator.start()
        for await event in stream {
            events.append(event)
            if let react, await react(event, coordinator) == .stopConsuming { break }
            if events.count >= eventLimit { break }
        }
        // A torn-down stream cancels the run asynchronously; give that a bounded number of yields to
        // land, so a test can assert on closed channels without waiting on the wall clock.
        //
        // ⚠️ THE FLOOR IS NOT PADDING. This loop used to exit the moment nothing was open, and on a
        // cancel-at-`.started` run *nothing has been opened yet* — so it exited immediately, the
        // test read `bed.channels` while a factory call was still in flight, and the channel that
        // landed a microsecond later was open when it was counted. That is what made
        // `discoveryCoordinatorCancelBeforeTheFirstProbeStillFinishes` fail on CI after passing for
        // weeks: the assertion was racing the *opener*, not the closer, and an empty list is not
        // evidence that the list will stay empty. Waiting a fixed minimum first gives an in-flight
        // open time to appear and be closed.
        var spins = 0
        while spins < 200, spins < 8 || channels.contains(where: { !$0.isClosed }) {
            // Real sleeps rather than yields, for the same reason the pump uses them: a yield loop
            // starves the cancellation it is waiting for.
            try? await Task.sleep(for: .microseconds(250))
            spins += 1
        }
        let snapshot = await coordinator.snapshot
        let progress = await coordinator.progress
        let diagnostics = await coordinator.diagnostics
        pump.cancel()
        return DiscoveryRunResult(events: events, coordinatorSnapshot: snapshot,
                                  coordinatorProgress: progress,
                                  coordinatorDiagnostics: diagnostics)
    }
}

// MARK: - Run result

/// One run's event stream, with the projections tests actually assert on.
struct DiscoveryRunResult: Sendable {

    let events: [DiscoveryEvent]
    /// `coordinator.snapshot`, read after the stream ended.
    let coordinatorSnapshot: [DiscoveredDevice]
    let coordinatorProgress: DiscoveryProgress
    let coordinatorDiagnostics: [DiscoveryDiagnostic]

    /// The plan from `.started`, or `nil` when planning failed.
    var plan: DiscoveryPlan? {
        for event in events {
            if case let .started(plan) = event { return plan }
        }
        return nil
    }

    /// The final summary. `nil` only when the stream was torn down before the run ended.
    var summary: DiscoverySummary? {
        for event in events.reversed() {
            if case let .finished(summary) = event { return summary }
        }
        return nil
    }

    var terminationReason: DiscoverySummary.TerminationReason? { summary?.terminationReason }
    var devices: [DiscoveredDevice] { summary?.devices ?? coordinatorSnapshot }

    /// Diagnostics as the summary reports them, falling back to the coordinator for a torn-down run.
    var diagnostics: [DiscoveryDiagnostic] { summary?.diagnostics ?? coordinatorDiagnostics }

    var progressEvents: [DiscoveryProgress] {
        events.compactMap {
            if case let .progress(progress) = $0 { return progress }
            return nil
        }
    }

    var deviceFoundEvents: [DiscoveredDevice] {
        events.compactMap {
            if case let .deviceFound(device) = $0 { return device }
            return nil
        }
    }

    var deviceUpdatedEvents: [DiscoveredDevice] {
        events.compactMap {
            if case let .deviceUpdated(device, _) = $0 { return device }
            return nil
        }
    }

    var mergedEvents: [(absorbed: [DeviceIdentity], into: DeviceIdentity)] {
        events.compactMap {
            if case let .deviceMerged(absorbed, into) = $0 { return (absorbed, into) }
            return nil
        }
    }

    var diagnosticEvents: [DiscoveryDiagnostic] {
        events.compactMap {
            if case let .diagnostic(diagnostic) = $0 { return diagnostic }
            return nil
        }
    }

    var phaseSummaries: [PhaseSummary] {
        events.compactMap {
            if case let .phaseCompleted(_, summary) = $0 { return summary }
            return nil
        }
    }

    /// The summary of `phase`, if it completed.
    func phase(_ phase: DiscoveryPhase) -> PhaseSummary? {
        phaseSummaries.first { $0.phase == phase }
    }

    /// The index of the first event satisfying `predicate`, for ordering assertions.
    func firstIndex(where predicate: (DiscoveryEvent) -> Bool) -> Int? {
        events.firstIndex(where: predicate)
    }

    /// A one-line description of the event sequence, so a failure message is readable.
    var trace: String {
        events.map { event in
            switch event {
            case .started: "started"
            case let .progress(progress):
                "progress(\(Int(progress.elapsed.asSeconds * 1_000))ms)"
            case let .deviceFound(device): "found(\(device.address))"
            case let .deviceUpdated(device, _): "updated(\(device.address))"
            case .deviceMerged: "merged"
            case .addressChanged: "addressChanged"
            case .addressReused: "addressReused"
            case let .phaseCompleted(phase, _): "phase(\(phase.rawValue))"
            case let .diagnostic(diagnostic): "diagnostic(\(diagnostic))"
            case let .finished(summary): "finished(\(summary.terminationReason.rawValue))"
            }
        }.joined(separator: " ")
    }
}

// MARK: - Fingerprint fixtures

/// Fingerprint responses used by more than one orchestration test.
enum CoordinatorFixtures {

    /// A Hikvision camera's RTSP `OPTIONS` answer: the realm names the vendor outright (§6.6).
    static func hikvisionRTSP(realm: String = "IP Camera(52799)") -> String {
        "RTSP/1.0 401 Unauthorized\r\n"
            + "CSeq: 1\r\n"
            + "WWW-Authenticate: Digest realm=\"\(realm)\", nonce=\"4d3e2f1a\", stale=\"FALSE\"\r\n"
            + "\r\n"
    }

    /// The ISAPI 401 a Hikvision device answers with — `Server: App-webs/` plus a realm (§6.7).
    static let hikvisionISAPI401 = "HTTP/1.1 401 Unauthorized\r\n"
        + "Server: App-webs/\r\n"
        + "WWW-Authenticate: Digest realm=\"IP Camera(52799)\", nonce=\"1f2e3d4c\"\r\n"
        + "Content-Length: 0\r\n"
        + "\r\n"

    /// A device with an HTTP server but no ISAPI surface at all.
    static let notISAPI404 = "HTTP/1.1 404 Not Found\r\n"
        + "Server: nginx\r\n"
        + "Content-Length: 0\r\n"
        + "\r\n"

    /// A printer: answers on 80, is emphatically not a camera.
    static let printerRoot = "HTTP/1.1 200 OK\r\n"
        + "Server: HP HTTP Server; HP ENVY 5540 series\r\n"
        + "Content-Type: text/html\r\n"
        + "\r\n"
        + "<html><head><title>HP ENVY</title></head></html>"

    /// An Axis camera's RTSP realm, which carries the device's MAC (§6.6).
    static let axisRTSP = "RTSP/1.0 401 Unauthorized\r\n"
        + "CSeq: 1\r\n"
        + "WWW-Authenticate: Digest realm=\"AXIS_ACCC8E123456\", nonce=\"aabbccdd\"\r\n"
        + "\r\n"

    /// A Dahua camera's RTSP realm.
    static let dahuaRTSP = "RTSP/1.0 401 Unauthorized\r\n"
        + "CSeq: 1\r\n"
        + "WWW-Authenticate: Digest realm=\"Login to 4a2b1c\", nonce=\"99887766\"\r\n"
        + "\r\n"

    /// Every port a Hikvision camera answers on: tier A plus the SDK port.
    static let hikvisionPorts: [UInt16: TCPProbeOutcome] = [
        554: .open, 80: .open, 8_000: .open, 443: .refused, 8_080: .refused,
    ]

    /// A host that exists but has nothing we recognise open beyond a web server.
    static let webOnlyPorts: [UInt16: TCPProbeOutcome] = [
        80: .open, 554: .refused, 8_000: .refused, 443: .refused, 8_080: .refused,
    ]
}
