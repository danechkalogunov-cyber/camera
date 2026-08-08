//
//  AlertStreamMonitor.swift
//  VigilISAPI
//
//  The consumer of `GET /ISAPI/Event/notification/alertStream`: one long-lived multipart response
//  per device, heartbeats suppressed, JPEG parts paired with the event they belong to, and a
//  backoff that never turns into a hot loop.
//  Implements docs/spec-isapi.md §14.6 and docs/API_CONTRACT.md §2 R-28.
//
//  Exactly **one** of these per device, never per channel: an NVR multiplexes every channel onto one
//  stream, and opening several streams to one device exhausts its HTTP workers. `ISAPIDeviceSession`
//  memoises it; `VigilCore.EventCenter` references it and never constructs one.
//
//  A `403`, `404` or `405` means the device does not have this feature, and the answer is to say so
//  — `.notSupported`, permanently, shown in the camera's health panel. There is deliberately **no**
//  synthetic polling fallback: an invented event stream is worse than an honestly absent one.
//

import Foundation
import VigilProtocols

// MARK: - AlertStreamState

/// What the monitor is doing, for the UI badge.
public enum AlertStreamState: Sendable, Hashable {
    /// Constructed but not started.
    case idle
    /// Opening the response.
    case connecting
    /// Receiving. `since` is when the current connection was established.
    case streaming(since: Date)
    /// The device answered 403/404/405. Terminal; no further connections are attempted.
    case notSupported
    /// A second 401. Terminal until `VigilCore` supplies a new credential.
    case authFailed
    /// Waiting out a backoff step. `retryAt` drives the countdown in the health panel.
    case failed(reason: String, retryAt: Date)
    /// Deliberately declared because docs/API_CONTRACT.md §4.5 declares it, and deliberately never
    /// entered: R-28 forbids a polling fallback for the alert stream.
    case polling(interval: Duration)
    /// `stop()` was called.
    case stopped
}

// MARK: - AlertStreamMonitor

/// Reads one device's event stream and republishes it as decoded, de-heartbeated notifications.
public actor AlertStreamMonitor {

    // MARK: Policy

    /// The reconnect and liveness numbers.
    public struct Policy: Sendable, Hashable {
        /// Backoff ladder in seconds; the last value repeats.
        public var backoffSeconds: [Double] = [1, 2, 4, 8, 15, 30, 60]
        /// Fraction of the step to jitter by, ±. Keeps a rack of 32 cameras from reconnecting in
        /// lockstep after a switch reboot.
        public var jitterFraction: Double = 0.20
        /// A connection that has lasted this long and delivered a part resets the ladder.
        public var healthyResetSeconds: Double = 120
        /// A gap this long *between two chunks* forces a reconnect.
        ///
        /// Evaluated when a chunk arrives, not on a timer: a device that stops sending entirely is
        /// caught by the transport's own idle timeout on the `.stream` lane
        /// (`Configuration.streamIdleTimeout`), which ends the byte stream and lands the loop in
        /// `backOff`. A second, time-driven watchdog inside this actor would need a task racing the
        /// pump; it is not implemented and `livenessProbeAfterIdleSeconds` is therefore not yet
        /// consulted.
        public var idleWatchdogSeconds: Double = 90
        /// Reserved. docs/spec-isapi.md §14.6 specifies a `userCheck` probe after this much
        /// silence; see the note on `idleWatchdogSeconds` for why it is not wired up yet.
        public var livenessProbeAfterIdleSeconds: Double = 60
        /// How long a decoded event waits for a JPEG part that may never come.
        public var snapshotPairingWindowSeconds: Double = 1.5
        /// Attach `image/jpeg` parts to the preceding event.
        public var attachSnapshots: Bool = true
        /// Cap on an accumulated JPEG. Over this the image is dropped and the event still emitted.
        public var snapshotMaxBytes: Int = 4 * 1024 * 1024
        /// Cap on an accumulated XML part.
        public var textPartMaxBytes: Int = 256 * 1024

        public init() {}
    }

    // MARK: State

    private let requests: any ISAPIRequesting
    private let policy: Policy
    private let clock: any MonotonicClock
    private let wallClock: any WallClock
    private var random: any RandomSource
    private let logger: any LoggerProtocol

    private let events = Broadcaster<EventNotificationAlert>(bufferingPolicy: .bufferingNewest(256))
    private let states = Broadcaster<AlertStreamState>(replaysLatest: true,
                                                       bufferingPolicy: .bufferingNewest(16))

    private var runner: Task<Void, Never>?
    private var currentState: AlertStreamState = .idle
    private var attempt = 0

    /// Decoded alerts waiting to be handed to ``events``, in arrival order. See ``publish(_:)``.
    ///
    /// ⚠️ Named for what it holds, because `AlertPartAssembler` in this same file has a `pending`
    /// of its own meaning something else entirely — the one event holding a slot open for a JPEG.
    private var pendingAlerts: [EventNotificationAlert] = []

    /// Counters the test suite reads instead of measuring wall-clock behaviour.
    public private(set) var connectionAttempts = 0
    public private(set) var suppressedHeartbeats = 0
    public private(set) var emittedEvents = 0
    /// The backoff delays actually chosen, in order, so the ladder and its jitter are assertable.
    public private(set) var backoffHistory: [Double] = []

    /// - Parameters:
    ///   - requests: the HTTP surface. The stream is opened on the `.stream` lane.
    ///   - clock: drives every delay. No wall-clock sleeps anywhere.
    ///   - wallClock: supplies the `Date` values the states carry, and nothing else.
    ///   - random: the jitter source. Seeded in tests so a failure reproduces.
    public init(requests: any ISAPIRequesting, policy: Policy = .init(),
                clock: any MonotonicClock, wallClock: any WallClock,
                random: any RandomSource = SystemRandomSource(),
                logger: any LoggerProtocol = NullLogger()) {
        self.requests = requests
        self.policy = policy
        self.clock = clock
        self.wallClock = wallClock
        self.random = random
        self.logger = logger
    }

    // MARK: Public surface

    /// The current state.
    public var state: AlertStreamState { currentState }

    /// A fresh stream of decoded events, heartbeats already removed.
    ///
    /// A factory rather than a property (API_CONTRACT §2 R-65): a stored `AsyncStream` has exactly
    /// one consumer and the second caller silently receives nothing.
    public nonisolated func notifications() -> AsyncStream<EventNotificationAlert> {
        events.stream()
    }

    /// A fresh stream of state changes, replaying the current state to a new consumer.
    public nonisolated func stateChanges() -> AsyncStream<AlertStreamState> {
        states.stream()
    }

    /// ``notifications()``, registered before this returns.
    ///
    /// ⛔ For the caller that also **starts** this monitor. `notifications()` is `nonisolated` and
    /// therefore registers its consumer in a detached step, so an alert delivered between the
    /// subscription and its registration goes to nobody — and a device with an alert already
    /// waiting delivers one the instant the stream opens. Awaiting registration is the whole
    /// difference, and it is why `EventMonitorService` uses this one.
    public func registeredNotifications() async -> AsyncStream<EventNotificationAlert> {
        await events.registeredStream()
    }

    /// ``stateChanges()``, registered before this returns. Same reason.
    public func registeredStateChanges() async -> AsyncStream<AlertStreamState> {
        await states.registeredStream()
    }

    /// How many consumers of `notifications()` have finished registering.
    ///
    /// `Broadcaster.stream()` registers asynchronously by contract, so a test that starts the read
    /// loop before its own registration lands would race the first event and hang. This is the
    /// seam that makes that wait deterministic; nothing in the app uses it.
    func eventConsumerCount() async -> Int { await events.consumerCount }

    /// The same, for `stateChanges()`.
    func stateConsumerCount() async -> Int { await states.consumerCount }

    /// Starts the read loop. Idempotent, and a no-op once the state is terminal.
    public func start() {
        guard runner == nil else { return }
        switch currentState {
        case .notSupported, .authFailed:
            return          // terminal: only a new credential or a re-probe may revive it
        default:
            break
        }
        runner = Task { [weak self] in
            await self?.run()
        }
    }

    /// Stops the read loop and completes both streams' current consumers.
    public func stop() async {
        runner?.cancel()
        runner = nil
        transition(to: .stopped)
    }

    /// Clears a terminal state so `start()` will try again — called by `VigilCore` on a credential
    /// change or a "re-probe device" action, never automatically.
    public func reset() {
        attempt = 0
        currentState = .idle
    }

    // MARK: The loop

    private func run() async {
        while !Task.isCancelled {
            connectionAttempts += 1
            transition(to: .connecting)
            do {
                try await readOneConnection()
                // A clean end is still an end: the device closed the response, so reconnect.
                guard !Task.isCancelled else { return }
                await backOff(reason: "stream ended")
            } catch {
                // `readOneConnection` throws `ISAPIError` and nothing else, so this is exhaustive.
                guard !Task.isCancelled else { return }
                if let terminal = Self.terminalState(for: error) {
                    logger.notice(.isapi, "alert stream terminal: \(error)")
                    transition(to: terminal)
                    return
                }
                await backOff(reason: "\(error)")
            }
        }
    }

    /// The states from which no further connection is attempted.
    static func terminalState(for error: ISAPIError) -> AlertStreamState? {
        switch error {
        case .notSupported, .notFound, .insufficientPermission: .notSupported
        case .authenticationFailed, .authBlockedLocally, .accountLocked: .authFailed
        default: nil
        }
    }

    /// Opens the stream and pumps it until it ends. Returns normally on a clean end.
    private func readOneConnection() async throws(ISAPIError) {
        let opened = try await requests.openStream(
            ISAPIResource.alertStream, query: [],
            headers: ["Accept": "multipart/mixed"])
        let connectedAt = wallClock.now
        let connectedInstant = clock.now()
        transition(to: .streaming(since: connectedAt))

        var assembler = AlertPartAssembler(policy: policy)
        var parser: MultipartStreamParser?
        var sniffBuffer = Data()
        if let contentType = opened.contentType,
           let boundary = MultipartStreamParser.boundary(fromContentType: contentType) {
            parser = MultipartStreamParser(boundary: boundary,
                                           limits: assembler.parserLimits)
        }
        var lastByteInstant = connectedInstant
        var deliveredAPart = false

        do {
            for try await chunk in opened.bytes {
                if Task.isCancelled { return }
                // The gap is measured against the *previous* arrival: updating first and then
                // comparing would compare an instant with itself and never fire.
                let arrival = clock.now()
                let idleGap = arrival.seconds(since: lastByteInstant)
                lastByteInstant = arrival
                if idleGap > policy.idleWatchdogSeconds {
                    throw ISAPIError.streamEnded(afterBytes: 0)
                }
                if parser == nil {
                    // No boundary in the header: buffer a little and sniff the first delimiter line
                    // out of the body. Seen on one 5.1.x build.
                    sniffBuffer.append(chunk)
                    guard let sniffed =
                            MultipartStreamParser.sniffBoundary(inPreamble: sniffBuffer) else {
                        if sniffBuffer.count > 512 {
                            throw ISAPIError.multipartProtocolError(
                                "no multipart boundary in the header or the first 512 bytes")
                        }
                        continue
                    }
                    logger.notice(.isapi, "alert stream boundary sniffed from the body")
                    var fresh = MultipartStreamParser(boundary: sniffed,
                                                      limits: assembler.parserLimits)
                    let outputs = try fresh.ingest(sniffBuffer)
                    parser = fresh
                    sniffBuffer = Data()
                    deliveredAPart = deliver(outputs, into: &assembler) || deliveredAPart
                // In order, and before the next read: an alert decoded is an alert delivered.
                await drain()
                    continue
                }
                guard var live = parser else { continue }
                let outputs = try live.ingest(chunk)
                parser = live
                deliveredAPart = deliver(outputs, into: &assembler) || deliveredAPart
                // In order, and before the next read: an alert decoded is an alert delivered.
                await drain()
                // A connection that has carried a part and lasted long enough is healthy; forget
                // the previous failures so the next one starts at the bottom of the ladder.
                if deliveredAPart,
                   clock.now().seconds(since: connectedInstant) >= policy.healthyResetSeconds {
                    attempt = 0
                }
            }
        } catch let error as ISAPIError {
            flush(&assembler)
            await drain()
            throw error
        } catch {
            flush(&assembler)
            await drain()
            throw ISAPIError.streamEnded(afterBytes: 0)
        }
        if var live = parser { deliver(live.finish(), into: &assembler); parser = live }
        flush(&assembler)
        await drain()
    }

    /// Feeds parser outputs into the assembler and publishes whatever completed.
    ///
    /// Returns `true` when at least one part completed, which is the "the stream is alive" signal
    /// the healthy-reset rule needs.
    @discardableResult
    private func deliver(_ outputs: [MultipartStreamParser.Output],
                         into assembler: inout AlertPartAssembler) -> Bool {
        var sawPart = false
        for output in outputs {
            for ready in assembler.accept(output, now: wallClock.now) {
                sawPart = true
                publish(ready)
            }
            if case .partEnded = output { sawPart = true }
        }
        // Flush a pending event whose pairing window has closed, so an event is never delayed
        // waiting for an image the device is not going to send.
        for ready in assembler.flushExpired(now: wallClock.now) { publish(ready) }
        return sawPart
    }

    /// Publishes any event still pending, at the end of a connection.
    private func flush(_ assembler: inout AlertPartAssembler) {
        for ready in assembler.flushAll() { publish(ready) }
    }

    /// Queues one decoded event, unless it is a heartbeat. ``drain()`` is what delivers it.
    ///
    /// ⛔ IT USED TO BE `Task { await broadcaster.yield(alert) }`, ONE TASK PER ALERT, AND THAT LOST
    /// EVENTS. Two ways: thirty tasks racing each other deliver in whatever order the executor
    /// feels like, and — worse — a task that has not run yet when the stream closes finds a
    /// finished broadcaster and its element is discarded in silence. On an idle machine they all
    /// landed first; on a loaded CI runner a scripted device that sent thirty alarms produced a row
    /// counting twenty-one, and no log line anywhere said nine were gone.
    ///
    /// Queue here, deliver in order from the read loop, and *await* the delivery — so the stream
    /// cannot be finished out from under an event that has already been decoded.
    private func publish(_ alert: EventNotificationAlert) {
        guard !alert.isHeartbeat else {
            suppressedHeartbeats += 1
            return
        }
        emittedEvents += 1
        pendingAlerts.append(alert)
    }

    /// Hands everything ``publish(_:)`` has queued to the broadcaster, in the order it arrived.
    private func drain() async {
        guard !pendingAlerts.isEmpty else { return }
        let batch = pendingAlerts
        pendingAlerts.removeAll(keepingCapacity: true)
        for alert in batch {
            await events.yield(alert)
        }
    }

    /// Advances the ladder, publishes `.failed`, and waits.
    private func backOff(reason: String) async {
        let base = policy.backoffSeconds.isEmpty
            ? 1.0
            : policy.backoffSeconds[min(attempt, policy.backoffSeconds.count - 1)]
        let delay = jittered(base)
        backoffHistory.append(delay)
        attempt += 1
        transition(to: .failed(reason: reason,
                               retryAt: wallClock.now.addingTimeInterval(delay)))
        try? await clock.sleep(for: .seconds(delay))
    }

    /// Applies ±`jitterFraction` to a delay.
    private func jittered(_ base: Double) -> Double {
        guard policy.jitterFraction > 0 else { return base }
        // One 64-bit draw mapped to [-1, 1]; a seeded generator therefore produces the same ladder
        // on every platform.
        let unit = Double(random.next() >> 11) / Double(UInt64(1) << 53)
        let factor = 1 + (unit * 2 - 1) * policy.jitterFraction
        return max(0, base * factor)
    }

    private func transition(to next: AlertStreamState) {
        guard next != currentState else { return }
        currentState = next
        let broadcaster = states
        Task { await broadcaster.yield(next) }
    }
}

// MARK: - AlertPartAssembler

/// Turns a sequence of multipart parts into decoded events, pairing each `image/jpeg` part with the
/// XML part immediately before it.
///
/// A plain `struct` with `mutating` methods, so the pairing rules and the 1.5 s flush are testable
/// without an actor, a clock or a network (API_CONTRACT §2 R-32).
struct AlertPartAssembler: Sendable {

    private let policy: AlertStreamMonitor.Policy

    private enum PartKind: Sendable { case text, image, other }
    private var kind: PartKind = .other
    private var partBuffer = Data()
    private var partOverflowed = false
    /// The decoded event waiting to see whether a JPEG follows it.
    private var pending: (alert: EventNotificationAlert, since: Date)?

    init(policy: AlertStreamMonitor.Policy) {
        self.policy = policy
    }

    /// The parser limits implied by this policy.
    var parserLimits: MultipartStreamParser.Limits {
        MultipartStreamParser.Limits(maxTextPartBytes: policy.textPartMaxBytes,
                                     maxBinaryPartBytes: policy.snapshotMaxBytes)
    }

    /// Consumes one parser output and returns any events it completed.
    mutating func accept(_ output: MultipartStreamParser.Output,
                         now: Date) -> [EventNotificationAlert] {
        switch output {
        case .partBegan(let headers, _):
            let contentType = (headers["content-type"] ?? "").lowercased()
            if contentType.contains("xml") { kind = .text }
            else if contentType.contains("image/") { kind = .image }
            else { kind = contentType.isEmpty ? .text : .other }
            partBuffer = Data()
            partOverflowed = false
            return []
        case .partData(let data):
            let cap = kind == .image ? policy.snapshotMaxBytes : policy.textPartMaxBytes
            guard partBuffer.count + data.count <= cap else {
                partOverflowed = true
                partBuffer = Data()
                return []
            }
            partBuffer.append(data)
            return []
        case .partTruncated:
            partOverflowed = true
            partBuffer = Data()
            return []
        case .partEnded:
            return completePart(now: now)
        case .streamEnded:
            return flushAll()
        }
    }

    /// Emits a pending event whose pairing window has closed.
    mutating func flushExpired(now: Date) -> [EventNotificationAlert] {
        guard let held = pending,
              now.timeIntervalSince(held.since) >= policy.snapshotPairingWindowSeconds else {
            return []
        }
        pending = nil
        return [held.alert]
    }

    /// Emits anything still held, at the end of a connection.
    mutating func flushAll() -> [EventNotificationAlert] {
        defer { pending = nil }
        return pending.map { [$0.alert] } ?? []
    }

    /// Finishes the current part.
    private mutating func completePart(now: Date) -> [EventNotificationAlert] {
        defer {
            partBuffer = Data()
            partOverflowed = false
            kind = .other
        }
        switch kind {
        case .text:
            guard !partOverflowed, !partBuffer.isEmpty else { return flushPending() }
            guard let document = try? ISAPIDocument(parsing: partBuffer),
                  let alert = try? EventNotificationAlert(document: document, receivedAt: now)
            else {
                // A part that will not decode is not worth stalling the pending event for.
                return flushPending()
            }
            // The previous event never got an image; emit it and hold this one instead.
            let released = flushPending()
            if policy.attachSnapshots {
                pending = (alert, now)
                return released
            }
            return released + [alert]
        case .image:
            guard var held = pending?.alert else { return [] }
            if !partOverflowed, !partBuffer.isEmpty { held.snapshot = partBuffer }
            pending = nil
            return [held]
        case .other:
            return []
        }
    }

    /// Releases the pending event without an image.
    private mutating func flushPending() -> [EventNotificationAlert] {
        defer { pending = nil }
        return pending.map { [$0.alert] } ?? []
    }
}
