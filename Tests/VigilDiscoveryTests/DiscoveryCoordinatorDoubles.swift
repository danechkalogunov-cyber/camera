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
    /// ⛔ `quietChecks` WAS RAISED TO 20 AND PUT BACK. Do not raise it again without reading this.
    ///
    /// The reasoning looked sound: the residual timetable flake is the pump advancing before a task
    /// that is about to sleep has filed its deadline, nothing observable distinguishes "about to
    /// sleep" from "finished", so the only lever is waiting longer before believing the quiet.
    ///
    /// It made things worse, and measurably. Every advance costs at least
    /// `quietChecks × checkInterval` of real time, so 8 → 20 took a step from 2 ms to 5 ms — while
    /// `DiscoveryTestBed.run`'s settle loop stayed capped at 200 × 250 µs = 50 ms. Teardown stopped
    /// fitting inside that budget, and `discoveryCoordinatorStreamTerminationCancelsTheRun` — which
    /// had been passing — began failing on **both** macOS and Linux, on the same assertion. Two
    /// platforms agreeing is not a flake; it was a regression, and it was mine.
    ///
    /// The lesson worth more than the number: this pump and that settle loop are coupled through
    /// real time, and tuning either alone moves the failure somewhere else rather than removing it.
    /// The timetable flake is still open and is documented in docs/BUILD-VERIFICATION.md; the fix
    /// for it is a deterministic scheduler, not a more patient one.
    ///
    /// ⛔ 2026-08-02: A SECOND ATTEMPT TO FIX THIS WAS MADE AND REVERTED. Read this before a third.
    ///
    /// It fired again with `sleep(until:)` in place, `[10, 550, 1010]` — one probe adrift on one
    /// channel, where the old defect shifted every probe on both uniformly. Three consecutive runs
    /// gave the identical number, which looked like determinism rather than a race, so the window
    /// after the wake was closed: `advanceToEarliestDeadline` minted one "settle credit" per task it
    /// woke and the pump waited, bounded, for each of them to read the clock before advancing again.
    ///
    /// It did not work. The very next run gave `[10, 510, 1050]` — the second probe fixed, the third
    /// adrift by the same 40 ms — so the mechanism moved the symptom instead of removing it. It also
    /// cost the suite 8.4 s → 10.9 s. That is the outcome this comment's own paragraph above
    /// predicts, in a new costume, and it is the second time this session that has happened here.
    ///
    /// Two beliefs were wrong and both were mine. Three identical failures are not evidence of
    /// determinism: the run *before* them and the run after both passed, so the sample was three
    /// draws from a loaded die, not a proof. And "close the window after the wake" is not a
    /// different kind of fix from "wait longer" — it is the same inference dressed up, because a
    /// credit spent is still a heuristic about whether a task has run.
    ///
    /// The failure is intermittent, it is in this harness and not in production, and the only fix
    /// that removes the class is a custom executor advanced when its queue is empty. See
    /// docs/BUILD-VERIFICATION.md.
    ///
    /// ⛔ Nor should the nanosecond assertion be loosened instead. On a virtual clock exact is the
    /// correct expectation; three separate times this session a timing failure that looked like
    /// noise turned out to be a real defect, and a tolerance would have buried every one.
    func startPump(quietChecks: Int = 8, checkInterval: Duration = .microseconds(250),
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
