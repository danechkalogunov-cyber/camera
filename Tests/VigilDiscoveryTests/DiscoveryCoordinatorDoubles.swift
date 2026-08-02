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

/// A lock-guarded box.
///
/// Swift 6 makes `NSLock.lock()` unavailable from an asynchronous context — holding a lock across a
/// suspension point is a deadlock waiting to happen — so every double below keeps its mutable state
/// in one of these and touches it only inside ``withLock(_:)``, which is synchronous by construction.
final class LockedBox<Value>: @unchecked Sendable {
    // @unchecked is justified: `value` is reachable only through `withLock`, which holds `lock` for
    // the whole call. Nothing escapes but what the caller's closure returns.
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    /// Runs `body` with exclusive access. Never suspends, and must never be given work that does.
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

// MARK: - Virtual clock

/// A `DiscoveryClock` whose time only moves when every task that could run has run.
///
/// `VigilTestKit.VirtualClock` cannot serve here: it is a value type with no wall clock and its
/// `sleep(for:)` returns without suspending, which collapses a twelve-second run into a single
/// instant and loses exactly the phase offsets §2.2 is about. This clock instead keeps a set of
/// sleepers with absolute deadlines and hands them to ``startPump(stabilityYields:maximumAdvances:)``,
/// which advances time to the *earliest* deadline once the system has gone quiet. Virtual timestamps
/// are then exact — a probe scheduled for t=10 ms is sent at t=10 ms and nowhere else — while a 12 s
/// run still completes in milliseconds of real time.
///
/// Quiescence is inferred from ``activityCounter``, which every clock interaction bumps: a task that
/// is still working reads the clock, and one that registers or wakes changes the sleeper set. Time
/// only advances after that counter has been still for `stabilityYields` consecutive yields, so it
/// cannot skip past a probe that was about to schedule itself.
final class VirtualDiscoveryClock: DiscoveryClock, @unchecked Sendable {
    // @unchecked is justified: all mutable state lives in `state`, a LockedBox.

    private struct Sleeper {
        let deadline: MediaInstant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var current = MediaInstant.zero
        var sleepers: [Int: Sleeper] = [:]
        /// Ids cancelled before their sleeper was registered. Without this the continuation would
        /// never resume and a test would hang instead of failing.
        var cancelledEarly: Set<Int> = []
        /// Sleepers that have been resumed but whose task has not run again yet.
        ///
        /// This is what stops time from running away. A resumed continuation is invisible until its
        /// task is scheduled — it touches nothing and so bumps no activity counter — and a pump that
        /// advanced during that window could find only a distant deadline left and jump to it,
        /// turning a run that should complete in 3 s into one that hit a 12 s budget. Nothing may
        /// advance while this set is non-empty.
        var pendingWakes: Set<Int> = []
        var nextID = 0
        var activity = 0
        /// Every advance the pump made: from, to, and how many sleepers were waiting. Capped, and
        /// only ever read by a failing test's diagnostics.
        var advanceLog: [String] = []
    }

    private let state = LockedBox(State())
    private let epoch: Date

    /// Creates a clock reading zero. `epoch` is what `wallNow` counts from — a fixed date, so every
    /// `firstSeen`/`lastSeen` a test sees is reproducible.
    init(epoch: Date = Date(timeIntervalSince1970: 1_785_000_000)) {
        self.epoch = epoch
    }

    // MARK: DiscoveryClock

    var wallNow: Date {
        let nanoseconds = state.withLock { state -> Int64 in
            state.activity += 1
            return state.current.nanoseconds
        }
        return epoch.addingTimeInterval(Double(nanoseconds) / 1e9)
    }

    func now() -> MediaInstant {
        state.withLock { state in
            state.activity += 1
            return state.current
        }
    }

    /// Suspends until the pump advances time by `duration`, or the task is cancelled.
    ///
    /// ⛔ THE DEADLINE IS FIXED HERE, NOT WHERE THE SLEEPER REGISTERS. `register` used to compute
    /// `state.current + duration`, and between this call and that line there is a suspension —
    /// `withCheckedThrowingContinuation` — across which the pump can advance. Every nanosecond it
    /// advanced in that window was then added *on top of* the requested duration, because the
    /// caller had already measured `duration` against the older reading.
    ///
    /// `discoveryCoordinatorSequencesPhasesOnTheSpecTimetable` measured the whole thing for us. The
    /// multicast phase asks to pause until 10 ms; the pump sees only the scripted datagram's 40 ms
    /// sleeper, because this one has not registered yet; it jumps to 40 ms; the sleeper files at
    /// 50 ms. Probes came out at [50, 550, 1050] against a schedule of [10, 510, 1010] — one
    /// uniform 40 ms shift, exactly the script's own answer delay, which is what named the
    /// mechanism.
    ///
    /// ⚠️ Capturing the deadline here was necessary and **not sufficient**, and the same test said
    /// so: the next run gave [10, 510, 1050]. Two probes exact, one still adrift, because a caller
    /// that wants an absolute instant has to convert it to a duration against `now()` *before*
    /// calling this, and the pump can advance in that gap too. That is what `sleep(until:)` below
    /// exists for, and why `pause(until:)` goes through it. This overload is now only for sleeps
    /// that are genuinely relative — a poll interval, a rate-limit window — where there is no
    /// absolute instant to drift from.
    ///
    /// Nothing about any of this is a production concern: a real monotonic clock does not jump, so
    /// `now()` and a registration a moment later agree. It is only reachable on a clock something
    /// else winds forward.
    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        guard duration > .zero else { return }
        // Counts as activity on purpose: a task that has read the clock in order to sleep is not a
        // task the pump should conclude has gone quiet.
        let deadline = state.withLock { state -> MediaInstant in
            state.activity += 1
            return state.current + duration
        }
        try await sleep(untilRegistered: deadline)
    }

    /// The absolute spelling, which is the one that cannot drift.
    ///
    /// Overriding the protocol's default is the entire point: the default converts to a duration
    /// against `now()`, and on this clock the pump can advance between that reading and the moment
    /// the sleeper is filed. Taking the deadline as given removes the arithmetic and therefore the
    /// window — a deadline already in the past is filed as-is and fires on the next advance.
    func sleep(until deadline: MediaInstant) async throws {
        try Task.checkCancellation()
        state.withLock { $0.activity += 1 }
        try await sleep(untilRegistered: deadline)
    }

    private func sleep(untilRegistered deadline: MediaInstant) async throws {
        let id = reserveID()
        // Runs whether the sleep completed or threw: either way this task is running again, and the
        // pump is free to consider advancing.
        defer { clearWake(id) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(id: id, deadline: deadline, continuation: continuation)
            }
        } onCancel: {
            cancelSleeper(id)
        }
    }

    // MARK: Inspection

    /// The reading, without counting as activity — for a test's own assertions.
    var reading: MediaInstant { state.withLock { $0.current } }

    /// Bumped by every clock interaction. The pump's liveness signal, not a meaningful number.
    var activityCounter: Int { state.withLock { $0.activity } }

    /// How many tasks are asleep right now.
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    /// True while a resumed sleeper has not yet run. The pump must not advance time in that window.
    var hasPendingWakes: Bool { state.withLock { !$0.pendingWakes.isEmpty } }

    /// Every advance made, as `from->to ms(n=sleepers)`. Include it in a failure message when a run
    /// ended at an unexpected instant: it shows precisely where time went.
    var advanceLog: [String] { state.withLock { $0.advanceLog } }

    // MARK: Scheduling

    /// Advances to the earliest deadline and wakes everything due.
    ///
    /// Returns false when nothing was asleep, which tells the pump that time has nowhere to go and
    /// that whatever the system is doing, it is not waiting on a clock.
    @discardableResult
    func advanceToEarliestDeadline() -> Bool {
        let due: [Sleeper] = state.withLock { state in
            guard let earliest = state.sleepers.values.map(\.deadline).min() else { return [] }
            if state.advanceLog.count < 400 {
                let all = state.sleepers.values.map { $0.deadline.nanoseconds / 1_000_000 }
                    .sorted().map(String.init).joined(separator: ",")
                state.advanceLog.append("\(state.current.nanoseconds / 1_000_000)"
                    + "->[\(all)]")
            }
            if earliest > state.current { state.current = earliest }
            let ready = state.sleepers.filter { $0.value.deadline <= state.current }
            for id in ready.keys {
                state.sleepers.removeValue(forKey: id)
                state.pendingWakes.insert(id)
            }
            state.activity += 1
            return Array(ready.values)
        }
        // Resumed outside the lock: a continuation may run synchronously and re-enter this clock.
        for sleeper in due { sleeper.continuation.resume() }
        return !due.isEmpty
    }

    /// Starts the scheduler. Cancel the returned task once the run under test has ended.
    ///
    /// The loop deliberately does **not** busy-wait. An earlier version spun on `Task.yield()` and
    /// polled the activity counter, which hammered this clock's lock from one thread and starved the
    /// very tasks it was waiting for: time then ran away — a probe due at 510 ms was stamped 12 s —
    /// because "nothing touched the clock" was indistinguishable from "nothing got a chance to".
    /// Sleeping between checks costs a few hundred microseconds of real time per advance and gives
    /// the runtime room to schedule pending work. No assertion depends on these durations; they only
    /// decide how patient the scheduler is before it accepts that everything is asleep.
    ///
    /// - Parameters:
    ///   - quietChecks: consecutive checks with no clock activity and no outstanding wake that count
    ///     as quiescence.
    ///   - checkInterval: real time between checks.
    ///   - maximumAdvances: a stuck run must not spin forever; the pump stops after this many steps,
    ///     and the test bed's event cap then ends the run.
    /// ⚠️ `quietChecks` was 8 (2 ms). Raised because that is the only honest axis left on the
    /// remaining failure, and the failure is worth understanding before touching this number again.
    ///
    /// An absolute `sleep(until:)` stopped a filed deadline from *drifting*, and the probe timetable
    /// went from three probes adrift to one. What it cannot stop is the clock overshooting **before**
    /// the sleeper is filed: the pump advances to the earliest deadline it can see, and a task that
    /// is about to sleep at 510 ms is, from here, indistinguishable from a task that has finished.
    /// So the pump jumps to whatever *is* registered, the 510 ms sleeper files into a past instant,
    /// and its probe is stamped late.
    ///
    /// Nothing observable distinguishes "about to sleep" from "done" — the runtime exposes no such
    /// thing — so the only lever is how long this waits before believing the quiet. Longer is more
    /// correct and slower: every advance costs at least `quietChecks × checkInterval` of real time,
    /// and a coordinator test makes hundreds of advances. This is the knob if the discovery suite
    /// becomes too slow, and it is a mitigation rather than a fix.
    ///
    /// ⛔ Do not "fix" the remaining flake by loosening the nanosecond assertion instead. On a
    /// virtual clock, exact is the correct expectation; three times this session a timing failure
    /// that looked like noise turned out to be a real defect, and a tolerance would have buried
    /// every one of them.
    func startPump(quietChecks: Int = 20, checkInterval: Duration = .microseconds(250),
                   maximumAdvances: Int = 100_000) -> Task<Void, Never> {
        Task { [weak self] in
            var advances = 0
            while !Task.isCancelled, advances < maximumAdvances {
                guard let clock = self else { return }
                var quiet = 0
                while quiet < quietChecks, !Task.isCancelled {
                    let before = clock.activityCounter
                    await Task.yield()
                    try? await Task.sleep(for: checkInterval)
                    let stillQuiet = clock.activityCounter == before && !clock.hasPendingWakes
                    quiet = stillQuiet ? quiet + 1 : 0
                }
                if Task.isCancelled { return }
                if clock.advanceToEarliestDeadline() { advances += 1 }
            }
        }
    }

    // MARK: Private

    private func reserveID() -> Int {
        state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
    }

    /// Files an already-computed deadline. See `sleep(for:)` for why it is not computed here.
    ///
    /// A deadline that is already in the past is filed as-is rather than clamped: the next
    /// `advanceToEarliestDeadline` sees `deadline <= current` and wakes it immediately, which is the
    /// correct meaning of "this sleep was due before it was registered".
    private func register(id: Int, deadline: MediaInstant,
                          continuation: CheckedContinuation<Void, any Error>) {
        let wasCancelled = state.withLock { state -> Bool in
            state.activity += 1
            if state.cancelledEarly.remove(id) != nil { return true }
            state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
            return false
        }
        if wasCancelled { continuation.resume(throwing: CancellationError()) }
    }

    /// Marks a woken sleeper as running again.
    private func clearWake(_ id: Int) {
        state.withLock { state in
            if state.pendingWakes.remove(id) != nil { state.activity += 1 }
        }
    }

    private func cancelSleeper(_ id: Int) {
        let sleeper = state.withLock { state -> Sleeper? in
            state.activity += 1
            if let existing = state.sleepers.removeValue(forKey: id) { return existing }
            state.cancelledEarly.insert(id)
            return nil
        }
        sleeper?.continuation.resume(throwing: CancellationError())
    }
}

// MARK: - Scripted datagrams

/// One datagram a fake channel will deliver, `delay` after the channel is opened.
struct ScriptedDatagram: Sendable {
    var delay: Duration
    var payload: Data
    var source: IPv4Address
    /// Deliberately not the group port by default: §5.1 forbids filtering on the source port, and a
    /// coordinator that did would drop this datagram.
    var sourcePort: UInt16

    init(delay: Duration, payload: Data, source: IPv4Address, sourcePort: UInt16 = 51_234) {
        self.delay = delay
        self.payload = payload
        self.source = source
        self.sourcePort = sourcePort
    }

    /// A datagram carrying `text` as UTF-8, which is how every SADP and WS-Discovery fixture arrives.
    init(delay: Duration, text: String, source: IPv4Address, sourcePort: UInt16 = 51_234) {
        self.init(delay: delay, payload: Data(text.utf8), source: source, sourcePort: sourcePort)
    }
}

// MARK: - Datagram channel

/// A `DatagramChannel` that records everything sent and replays a script of inbound datagrams.
///
/// Every payload handed to ``send(_:to:port:)`` goes through `DiscoveryCredentialGuard`, so a change
/// that started writing an `Authorization` header — or a password anywhere in a probe — fails the
/// suite here rather than locking a customer's cameras (§6.10).
final class MockDatagramChannel: DatagramChannel, @unchecked Sendable {
    // @unchecked is justified: all mutable state lives in `state`, a LockedBox.

    /// One recorded outbound datagram, with the virtual instant it left at.
    struct SentDatagram: Sendable, Hashable {
        let payload: Data
        let host: IPv4Address
        let port: UInt16
        let at: MediaInstant
    }

    private struct State {
        var sent: [SentDatagram] = []
        var isClosed = false
        var closedAt: MediaInstant?
        var continuation: AsyncStream<InboundDatagram>.Continuation?
        var delivery: Task<Void, Never>?
    }

    let localPort: UInt16
    let interfaceName: String?
    /// The group this channel joined, or `nil` for the unicast channel.
    let spec: MulticastGroupSpec?
    /// When the coordinator opened this channel, in virtual time.
    let openedAt: MediaInstant

    private let clock: VirtualDiscoveryClock
    private let script: [ScriptedDatagram]
    private let sendFailure: DiscoveryError?
    private let state = LockedBox(State())

    init(localPort: UInt16, interfaceName: String?, spec: MulticastGroupSpec?,
         clock: VirtualDiscoveryClock, script: [ScriptedDatagram],
         sendFailure: DiscoveryError? = nil) {
        self.localPort = localPort
        self.interfaceName = interfaceName
        self.spec = spec
        self.clock = clock
        self.script = script
        self.sendFailure = sendFailure
        openedAt = clock.now()
    }

    // MARK: DatagramChannel

    func send(_ payload: Data, to host: IPv4Address, port: UInt16) async throws(DiscoveryError) {
        DiscoveryCredentialGuard.requireNoCredentials(
            in: payload, label: "datagram to \(host):\(port) on \(interfaceName ?? "?")")
        let at = clock.now()
        state.withLock { state in
            state.sent.append(SentDatagram(payload: payload, host: host, port: port, at: at))
        }
        if let sendFailure { throw sendFailure }
    }

    func inboundDatagrams() -> AsyncStream<InboundDatagram> {
        let (stream, continuation) = AsyncStream<InboundDatagram>.makeStream(
            bufferingPolicy: .unbounded)
        let alreadyClosed = state.withLock { state -> Bool in
            guard !state.isClosed else { return true }
            state.continuation = continuation
            return false
        }
        if alreadyClosed {
            continuation.finish()
            return stream
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await deliver(to: continuation)
        }
        state.withLock { $0.delivery = task }
        return stream
    }

    func close() async {
        let at = clock.now()
        let closing = state.withLock { state -> (AsyncStream<InboundDatagram>.Continuation?,
                                                 Task<Void, Never>?)? in
            guard !state.isClosed else { return nil }
            state.isClosed = true
            state.closedAt = at
            let continuation = state.continuation
            let delivery = state.delivery
            state.continuation = nil
            state.delivery = nil
            return (continuation, delivery)
        }
        guard let closing else { return }
        closing.1?.cancel()
        closing.0?.finish()
    }

    // MARK: Inspection

    var sent: [SentDatagram] { state.withLock { $0.sent } }
    var isClosed: Bool { state.withLock { $0.isClosed } }

    /// When the coordinator closed this channel, in virtual time. `nil` while it is still open.
    var closedAt: MediaInstant? { state.withLock { $0.closedAt } }

    // MARK: Private

    /// Replays the script on the injected clock, so a datagram scheduled for t=40 ms arrives at
    /// exactly t=40 ms. The stream is *not* finished when the script runs out: a real channel stays
    /// open until it is closed, and the coordinator's listen loop must end because of that close, not
    /// because the device stopped talking.
    private func deliver(to continuation: AsyncStream<InboundDatagram>.Continuation) async {
        var reached = Duration.zero
        for entry in script.sorted(by: { $0.delay < $1.delay }) {
            let wait = entry.delay - reached
            if wait > .zero {
                do {
                    try await clock.sleep(for: wait)
                } catch {
                    return
                }
            }
            reached = entry.delay
            if isClosed { return }
            continuation.yield(InboundDatagram(payload: entry.payload, source: entry.source,
                                               sourcePort: entry.sourcePort,
                                               interfaceName: interfaceName,
                                               receivedAt: clock.wallNow))
        }
    }
}

// MARK: - TCP prober

/// Table-driven TCP connect probing with per-probe virtual latency.
///
/// It also records the high-water mark of simultaneous probes, which is the only way to observe the
/// `maxInFlightConnects` ceiling from outside the coordinator (test 83).
final class MockTCPProber: TCPProbing, @unchecked Sendable {
    // @unchecked is justified: all mutable state lives in `state`, a LockedBox.

    struct ProbeRecord: Sendable, Hashable {
        let host: IPv4Address
        let port: UInt16
        let at: MediaInstant
    }

    private struct State {
        var records: [ProbeRecord] = []
        var inFlight = 0
        var peak = 0
    }

    private let table: [UInt32: [UInt16: TCPProbeOutcome]]
    private let clock: VirtualDiscoveryClock
    private let answerLatency: Duration
    /// True for a network where nothing answers *and never will* — a stalled accept queue rather than
    /// a fast refusal. This is what makes a run reach its deadline instead of completing.
    private let neverAnswers: Bool
    private let state = LockedBox(State())

    init(clock: VirtualDiscoveryClock, table: [UInt32: [UInt16: TCPProbeOutcome]] = [:],
         answerLatency: Duration = .milliseconds(5), neverAnswers: Bool = false) {
        self.clock = clock
        self.table = table
        self.answerLatency = answerLatency
        self.neverAnswers = neverAnswers
    }

    func probe(_ host: IPv4Address, port: UInt16, timeout: Duration,
               interfaceName: String?) async -> TCPProbeOutcome {
        let outcome = table[host.rawValue]?[port] ?? .timedOut
        enter(host: host, port: port)
        defer { leave() }
        // A host that answers does so in a millisecond or two; a silent one costs the whole budget.
        let wait: Duration = neverAnswers ? .seconds(3_600)
            : (outcome.provesHostAlive ? answerLatency : timeout)
        do {
            try await clock.sleep(for: wait)
        } catch {
            return .timedOut
        }
        return outcome
    }

    /// Every probe attempted, in start order.
    var probes: [ProbeRecord] { state.withLock { $0.records } }

    /// Distinct hosts probed.
    var probedHosts: Set<UInt32> { Set(probes.map(\.host.rawValue)) }

    /// The greatest number of probes in flight at once.
    var peakInFlight: Int { state.withLock { $0.peak } }

    private func enter(host: IPv4Address, port: UInt16) {
        let at = clock.now()
        state.withLock { state in
            state.records.append(ProbeRecord(host: host, port: port, at: at))
            state.inFlight += 1
            state.peak = max(state.peak, state.inFlight)
        }
    }

    private func leave() {
        state.withLock { $0.inFlight -= 1 }
    }
}

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
