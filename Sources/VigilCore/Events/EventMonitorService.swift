//
//  EventMonitorService.swift
//  VigilCore
//
//  Owns the alert-stream subscriptions: one `AlertStreamMonitor` per DEVICE, restarted with backoff
//  when it gives up, with every alert demultiplexed to a camera and folded into `EventStore`.
//  Implements docs/spec-core.md §11.2 and docs/spec-isapi.md §14.6.
//
//  ONE MONITOR PER DEVICE, NOT PER CAMERA. This is the one place the wording of the task and the
//  wire reality differ, and the wire wins: an NVR multiplexes every channel onto a single
//  `alertStream` response, and `AlertStreamMonitor`'s own header is explicit that opening several
//  streams to one device exhausts its HTTP workers. Cameras sharing `host:port` therefore share a
//  subscription and are separated by `channelID` (spec-core §11.2). For the customer's single
//  cameras — one camera per address — this *is* one monitor per camera.
//
//  Two supervision layers, deliberately:
//    * `AlertStreamMonitor` supervises the CONNECTION. A camera that goes offline, a switch that
//      reboots, a device that closes the response — all of that is its backoff ladder's job, and
//      duplicating it here would produce two ladders fighting each other.
//    * This service supervises the MONITOR. It handles the cases the monitor cannot: it could not be
//      built at all (no credential yet), or it reached a terminal state and stopped for good.
//
//  Nothing here runs a detection model. Alerts are received, attributed and stored.
//

#if os(macOS)

import Foundation
import VigilISAPI
import VigilProtocols

// MARK: - EventDeviceKey

/// A device, as the alert stream sees it: one long-lived response per `host:port`.
///
/// `description` is `host:port` and never contains a credential — no account, no secret, no token
/// (spec-core §6.1 rule 3). It is safe to log verbatim, and it is a LAN address by construction:
/// nothing here resolves or reaches anything the user did not add.
public struct EventDeviceKey: Sendable, Hashable, CustomStringConvertible {

    /// Lowercased host, so `CAM-1.local` and `cam-1.local` are one device and not two streams.
    public let host: String
    public let port: Int
    public let useTLS: Bool

    public init(host: String, port: Int, useTLS: Bool) {
        self.host = host.lowercased()
        self.port = port
        self.useTLS = useTLS
    }

    /// The device a camera lives on. `useTLS` participates because an http and an https stream to the
    /// same port would be two different responses.
    public init(camera: Camera) {
        self.init(host: camera.host, port: camera.httpPort, useTLS: camera.useTLS)
    }

    public var description: String { "\(host):\(port)" }
}

// MARK: - EventMonitorFactory

/// Builds the monitor for one device, or returns `nil` when it cannot be built yet — no credential
/// in the Keychain, or the device session has not been established.
///
/// A closure rather than a protocol because the thing that knows how to build an `ISAPIRequesting` is
/// the app's session layer, which this file must not depend on: it is being written in parallel, and
/// an event service that cannot be constructed without it could not be tested at all. `nil` is a
/// retryable failure — the service backs off and asks again.
public typealias EventMonitorFactory =
    @Sendable (EventDeviceKey) async -> AlertStreamMonitor?

// MARK: - EventMonitorEvent

/// What the service is doing, for the health panel and for tests.
public enum EventMonitorEvent: Sendable, Hashable {
    /// A subscription was created and its monitor started.
    case started(EventDeviceKey)
    /// A subscription was torn down: the last enabled camera on the device went away.
    case stopped(EventDeviceKey)
    /// The device's monitor changed state. Mirrors `AlertStreamMonitor` verbatim.
    case state(EventDeviceKey, AlertStreamState)
    /// The service is about to restart a monitor that gave up.
    case restartScheduled(EventDeviceKey, afterSeconds: Double, attempt: Int)
    /// The monitor could not be built; the service will ask again after `afterSeconds`.
    case monitorUnavailable(EventDeviceKey, afterSeconds: Double, attempt: Int)
    /// The service has stopped trying. `.notSupported` after the re-probe budget, or `.authFailed`,
    /// which needs a new credential and is never retried automatically.
    case gaveUp(EventDeviceKey, AlertStreamState)
    /// An alert was attributed to a camera and stored.
    case ingested(CameraID, EventIngestOutcome)
    /// An alert named a channel no enabled camera on that device claims. Counted, not stored.
    case unattributed(EventDeviceKey, channel: ChannelID)
    /// `Policy.maxDevices` was reached and this device was not subscribed.
    case refusedOverCapacity(EventDeviceKey)
}

// MARK: - EventMonitorCounters

/// Totals since construction. The test suite asserts on these rather than on timing.
public struct EventMonitorCounters: Sendable, Hashable, Codable {
    public var monitorsStarted = 0
    public var monitorsStopped = 0
    public var restartsScheduled = 0
    public var monitorBuildFailures = 0
    public var alertsForwarded = 0
    public var unattributedAlerts = 0
    public var devicesRefusedOverCapacity = 0
    public var terminalUnsupported = 0
    public var terminalAuthFailed = 0

    public init() {}
}

// MARK: - EventMonitorService

/// Keeps exactly one alert-stream subscription per device alive for as long as the library wants it.
///
/// # Bounds
///
/// * **One** `AlertStreamMonitor` per `EventDeviceKey`, guaranteed by the dictionary that holds them:
///   there is no code path that constructs a second one for a key that already has one, and
///   `reconcile` on an unchanged library mutates the channel map and touches nothing else.
/// * At most `Policy.maxDevices` (32) subscriptions. Beyond it devices are refused deterministically
///   — sorted by `host:port`, so which ones are refused does not depend on dictionary order — with a
///   `.refusedOverCapacity` event and a warning. 32 is the camera count the app is designed around.
/// * At most **one** supervisor `Task` per subscription, and the notification pump is a *child* of it
///   inside a task group, so cancelling the supervisor cancels the pump. That is what makes a
///   removal leak-proof: one handle to cancel, and structured concurrency accounts for the rest.
/// * `maxUnsupportedReprobes` (3) bounds re-probing a device that answered 403/404/405.
public actor EventMonitorService {

    /// Persists an optional device JPEG after the store assigns the stable event identity.
    public typealias SnapshotSink = @Sendable (EventID, CameraID, Data) async -> Void

    // MARK: Policy

    public struct Policy: Sendable, Hashable {

        /// Subscriptions allowed at once.
        public var maxDevices: Int = 32

        /// Service-level restart ladder, in seconds; the last value repeats. Deliberately the same
        /// shape as the monitor's own ladder, but it is a *different* ladder for a different failure:
        /// this one counts "the monitor gave up", not "the connection dropped".
        public var restartBackoffSeconds: [Double] = [1, 2, 4, 8, 15, 30, 60]

        /// ±fraction of jitter, so 32 cameras coming back after a switch reboot do not resubscribe in
        /// lockstep.
        public var jitterFraction: Double = 0.20

        /// How many times a `.notSupported` device is re-probed before the service accepts the answer.
        ///
        /// spec-isapi §14.6 calls 403/404/405 permanent, and it is right that there must be no
        /// polling fallback and no hammering. But a Hikvision device that is *rebooting* answers 404
        /// to everything for a while, and accepting that as "this model has no event stream" would
        /// silently kill events until the app restarts. Three re-probes spread over the ladder is not
        /// hammering, and after them the answer is taken as final.
        public var maxUnsupportedReprobes: Int = 3

        public init() {}
    }

    // MARK: Subscription

    /// One device's subscription. `generation` is the anti-duplicate guard: every alert and every
    /// state carries the generation of the supervisor that produced it, and anything from a previous
    /// generation is dropped, so a monitor that is being torn down cannot double-ingest into the
    /// generation that replaced it.
    private struct Subscription {
        var camerasByChannel: [ChannelID: CameraID]
        /// The camera a device-wide event (channel 0) is filed against: the lowest channel on the
        /// device. Deterministic, so the same fault always lands on the same row.
        var representative: CameraID
        var monitor: AlertStreamMonitor?
        var supervisor: Task<Void, Never>?
        var generation: Int
        var lastState: AlertStreamState = .idle
        /// Set when the service has stopped trying. The entry stays, so `reconcile` does not
        /// cheerfully build a fresh monitor for a device that just told us it has no event stream.
        var terminal: AlertStreamState?
    }

    // MARK: State

    private let store: EventStore
    private nonisolated let policy: Policy
    private nonisolated let clock: any MonotonicClock
    private nonisolated let logger: any LoggerProtocol
    private nonisolated let makeMonitor: EventMonitorFactory
    private nonisolated let snapshotSink: SnapshotSink
    private var random: any RandomSource

    private var subscriptions: [EventDeviceKey: Subscription] = [:]
    private var generationCounter = 0
    private var totals = EventMonitorCounters()
    private let feed = Broadcaster<EventMonitorEvent>(bufferingPolicy: .bufferingNewest(256))

    /// - Parameters:
    ///   - store: where attributed alerts go.
    ///   - clock: drives every backoff. No `Task.sleep` anywhere in this file.
    ///   - random: jitter source; seed it and a failing run reproduces.
    ///   - makeMonitor: builds one device's monitor, or `nil` to be asked again later.
    public init(store: EventStore,
                policy: Policy = Policy(),
                clock: any MonotonicClock,
                random: any RandomSource = SystemRandomSource(),
                logger: any LoggerProtocol = NullLogger(),
                snapshotSink: @escaping SnapshotSink = { _, _, _ in },
                makeMonitor: @escaping EventMonitorFactory) {
        self.store = store
        self.policy = policy
        self.clock = clock
        self.random = random
        self.logger = logger
        self.snapshotSink = snapshotSink
        self.makeMonitor = makeMonitor
    }

    // MARK: Reconciliation

    /// Makes the live subscriptions match the library. Idempotent: call it after any change.
    ///
    /// A camera that is already covered by a live subscription only refreshes that subscription's
    /// channel map — no monitor is constructed, no task is spawned and no stream is re-subscribed.
    /// That is what stops a repeated `reconcile` from quietly building a second subscription to the
    /// same device, which is the failure that shows up as every event appearing twice.
    public func reconcile(cameras: [Camera]) async {
        var wanted: [EventDeviceKey: [Camera]] = [:]
        for camera in cameras where camera.isEnabled {
            wanted[EventDeviceKey(camera: camera), default: []].append(camera)
        }

        // Deterministic ordering, so which devices fall outside `maxDevices` never depends on
        // dictionary iteration order.
        let ordered = wanted.keys.sorted { $0.description < $1.description }
        var admitted: Set<EventDeviceKey> = []
        for key in ordered {
            if subscriptions[key] != nil || admitted.count + subscriptions.count < policy.maxDevices {
                admitted.insert(key)
            } else {
                totals.devicesRefusedOverCapacity += 1
                logger.warning(.core, "event subscription refused, \(policy.maxDevices) device "
                               + "limit reached: \(key.description)")
                publish(.refusedOverCapacity(key))
            }
        }

        for key in subscriptions.keys where !admitted.contains(key) {
            await remove(key)
        }
        for key in ordered where admitted.contains(key) {
            let cams = wanted[key] ?? []
            let map = Dictionary(cams.map { ($0.channel, $0.id) }, uniquingKeysWith: { first, _ in
                first          // two cameras on one channel is a library mistake; keep the first
            })
            let representative = cams.min { $0.channel < $1.channel }?.id
            guard let representative else { continue }
            if var existing = subscriptions[key] {
                existing.camerasByChannel = map
                existing.representative = representative
                subscriptions[key] = existing
                continue
            }
            generationCounter += 1
            let generation = generationCounter
            subscriptions[key] = Subscription(camerasByChannel: map,
                                              representative: representative,
                                              monitor: nil,
                                              supervisor: nil,
                                              generation: generation)
            let task = Task { [weak self] in
                guard let self else { return }
                await self.supervise(key: key, generation: generation)
            }
            subscriptions[key]?.supervisor = task
            totals.monitorsStarted += 1
            publish(.started(key))
        }
    }

    /// Tears down every subscription. Called on sleep and at shutdown.
    public func stopAll() async {
        for key in subscriptions.keys {
            await remove(key)
        }
    }

    /// Re-arms a device that stopped on `.authFailed`.
    ///
    /// Never automatic: a wrong password retried on a ladder is how an account gets locked out
    /// (spec-core §6.8). Only a new credential may clear it, and only the user supplies one.
    public func credentialsChanged(for key: EventDeviceKey) async {
        guard var entry = subscriptions[key], entry.terminal != nil else { return }
        entry.terminal = nil
        entry.supervisor?.cancel()
        generationCounter += 1
        let generation = generationCounter
        entry.generation = generation
        entry.supervisor = nil
        subscriptions[key] = entry
        let task = Task { [weak self] in
            guard let self else { return }
            await self.supervise(key: key, generation: generation)
        }
        subscriptions[key]?.supervisor = task
        totals.monitorsStarted += 1
        publish(.started(key))
    }

    // MARK: Introspection

    public func deviceStates() -> [EventDeviceKey: AlertStreamState] {
        subscriptions.mapValues { $0.terminal ?? $0.lastState }
    }

    /// Live subscriptions. One per device, never more — assert on this after a repeated reconcile.
    public func subscriptionCount() -> Int { subscriptions.count }

    /// Devices with a running supervisor task. A removal that leaked would show up here.
    public func activeSupervisorCount() -> Int {
        subscriptions.values.reduce(0) { $0 + (($1.supervisor?.isCancelled == false) ? 1 : 0) }
    }

    public func cameras(on key: EventDeviceKey) -> [ChannelID: CameraID] {
        subscriptions[key]?.camerasByChannel ?? [:]
    }

    public func counters() -> EventMonitorCounters { totals }

    /// A fresh stream of service events. A factory, not a property (API_CONTRACT §2 R-27, R-65).
    public nonisolated func events() -> AsyncStream<EventMonitorEvent> { feed.stream() }

    /// Completes every consumer's stream.
    public func finish() async { await feed.finish() }

    /// Registered consumers of `events()`, for tests that must not race their own registration.
    func eventConsumerCount() async -> Int { await feed.consumerCount }

    // MARK: Supervision

    /// One device's whole life: acquire a monitor, keep it running, restart it when it gives up.
    ///
    /// Returns only on cancellation or when the service has decided to stop trying.
    private func supervise(key: EventDeviceKey, generation: Int) async {
        var attempt = 0
        var monitor: AlertStreamMonitor?
        while monitor == nil {
            if Task.isCancelled || !isCurrent(key: key, generation: generation) { return }
            monitor = await makeMonitor(key)
            if monitor == nil {
                totals.monitorBuildFailures += 1
                let delay = nextDelay(&attempt)
                publish(.monitorUnavailable(key, afterSeconds: delay, attempt: attempt))
                do {
                    try await clock.sleep(for: .seconds(delay))
                } catch {
                    return          // cancelled while waiting
                }
            }
        }
        guard let monitor, isCurrent(key: key, generation: generation) else { return }
        subscriptions[key]?.monitor = monitor

        // ⛔ BOTH STREAMS ARE REGISTERED BEFORE THE DEVICE IS STARTED, and the order is the whole
        // point. `notifications()` registers its consumer in a detached step, so subscribing inside
        // the child task and then calling `restart` below left a window in which the monitor could
        // deliver its first alert to a broadcaster with no consumers — and a device with an alert
        // already waiting delivers one the instant the stream opens. The alert was not late, it was
        // gone: no record, no retry, no complaint. CI found it as a test whose scripted camera
        // sends exactly one alert and closes; a real camera hides it, because the next alert makes
        // the loss look like nothing happened.
        let alerts = await monitor.registeredNotifications()
        let states = await monitor.registeredStateChanges()

        // The pump and the state watcher are children of this task, so one `cancel()` on the
        // supervisor stops both and nothing is left holding a broadcaster continuation.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                for await alert in alerts {
                    guard let self else { return }
                    await self.handle(alert, key: key, generation: generation)
                }
            }
            group.addTask { [weak self] in
                guard let self else { return }
                await self.watchStates(states, of: monitor, key: key, generation: generation)
            }
            await self.restart(monitor)
            await group.waitForAll()
        }
    }

    /// Consumes the monitor's state changes and applies the service's own restart policy.
    ///
    /// The stream is passed in rather than opened here, so that it is registered before the device
    /// is started — see the note in ``supervise(key:generation:)``.
    private func watchStates(_ states: AsyncStream<AlertStreamState>,
                             of monitor: AlertStreamMonitor, key: EventDeviceKey,
                             generation: Int) async {
        var attempt = 0
        var reprobes = 0
        for await state in states {
            if Task.isCancelled { return }
            guard isCurrent(key: key, generation: generation) else { return }
            record(state: state, key: key, generation: generation)
            switch state {
            case .streaming:
                attempt = 0             // a healthy connection forgets the previous failures
            case .notSupported:
                reprobes += 1
                if reprobes > policy.maxUnsupportedReprobes {
                    totals.terminalUnsupported += 1
                    giveUp(key: key, state: state)
                    return
                }
                if await !sleepBeforeRestart(&attempt, key: key) { return }
                await restart(monitor)
            case .authFailed:
                totals.terminalAuthFailed += 1
                giveUp(key: key, state: state)
                return
            case .idle, .connecting, .failed, .polling, .stopped:
                break                   // the monitor's own ladder owns these
            }
        }
    }

    /// The only sequence that actually restarts an `AlertStreamMonitor`.
    ///
    /// `stop()` first, and not because we want it stopped: the monitor's `runner` task handle is
    /// cleared by `stop()` and by nothing else, while `start()` is a no-op whenever `runner != nil`.
    /// After a terminal state its `run()` loop has returned but the handle is still set, so
    /// `reset()` + `start()` alone would silently do nothing. `stop()` → `reset()` → `start()` is
    /// therefore the whole restart, in that order.
    private func restart(_ monitor: AlertStreamMonitor) async {
        await monitor.stop()
        await monitor.reset()
        await monitor.start()
    }

    /// Waits out one backoff step. Returns `false` if the wait was cancelled.
    private func sleepBeforeRestart(_ attempt: inout Int, key: EventDeviceKey) async -> Bool {
        let delay = nextDelay(&attempt)
        totals.restartsScheduled += 1
        publish(.restartScheduled(key, afterSeconds: delay, attempt: attempt))
        do {
            try await clock.sleep(for: .seconds(delay))
            return true
        } catch {
            return false
        }
    }

    /// Advances the ladder and applies ±`jitterFraction`.
    ///
    /// One 64-bit draw mapped to [-1, 1], exactly as `AlertStreamMonitor` does it, so a seeded
    /// generator produces the same ladder on every platform.
    private func nextDelay(_ attempt: inout Int) -> Double {
        let ladder = policy.restartBackoffSeconds
        let base = ladder.isEmpty ? 1.0 : ladder[min(attempt, ladder.count - 1)]
        attempt += 1
        guard policy.jitterFraction > 0 else { return base }
        let unit = Double(random.next() >> 11) / Double(UInt64(1) << 53)
        return max(0, base * (1 + (unit * 2 - 1) * policy.jitterFraction))
    }

    // MARK: Alert attribution

    /// Files one alert against a camera and folds it into the store.
    ///
    /// Attribution, in order:
    /// 1. the channel the alert names, when an enabled camera on this device claims it;
    /// 2. the device's representative camera for a device-wide event (`channel == 0`) — a full disk
    ///    or a broken NIC belongs to the device, and the store is keyed by camera, so filing it
    ///    against the lowest channel is what keeps it from being dropped. `EventRecord.isDeviceWide`
    ///    tells the UI to render it as the device's, not the camera's;
    /// 3. the only camera on the device, when there is exactly one — a single camera that reports an
    ///    unexpected channel number is common, and dropping its events would be absurd;
    /// 4. otherwise nothing: counted as `.unattributed`, because guessing which of an NVR's 32
    ///    channels an event belongs to would put it on the wrong camera.
    private func handle(_ alert: EventNotificationAlert, key: EventDeviceKey,
                        generation: Int) async {
        guard let entry = subscriptions[key], entry.generation == generation else { return }
        let cameraID: CameraID?
        if let exact = entry.camerasByChannel[alert.channel] {
            cameraID = exact
        } else if alert.channel.value == 0 {
            cameraID = entry.representative
        } else if entry.camerasByChannel.count == 1 {
            cameraID = entry.camerasByChannel.values.first
        } else {
            cameraID = nil
        }
        guard let cameraID else {
            totals.unattributedAlerts += 1
            logger.debug(.core, "alert on unclaimed channel \(alert.channel) from "
                         + "\(key.description)")
            publish(.unattributed(key, channel: alert.channel))
            return
        }
        // ⚠️ `alertsForwarded` counts alerts this service *accepted and sent on*, and it is
        // deliberately incremented before the `await` rather than after it. It is bookkeeping, not
        // a synchronisation point: nothing in the app gates on it, and `publish(.ingested)` below —
        // the signal the UI actually consumes — is correctly ordered after the store write.
        //
        // Do not "fix" this by moving it below the ingest to make some test's wait work. That
        // trades one race for the opposite one: four tests in EventMonitorServiceTests wait for the
        // *store* to reach N and then assert the counter, and the counter would then be a hop
        // behind them. A test that needs to read the store must wait on the store.
        totals.alertsForwarded += 1
        let outcome = await store.ingest(alert, from: cameraID)
        if let snapshot = alert.snapshot, let record = outcome.record {
            await snapshotSink(record.id, cameraID, snapshot)
        }
        publish(.ingested(cameraID, outcome))
    }

    // MARK: Bookkeeping

    /// True while this generation is still the live one for the key.
    private func isCurrent(key: EventDeviceKey, generation: Int) -> Bool {
        subscriptions[key]?.generation == generation
    }

    private func record(state: AlertStreamState, key: EventDeviceKey, generation: Int) {
        guard var entry = subscriptions[key], entry.generation == generation else { return }
        entry.lastState = state
        subscriptions[key] = entry
        publish(.state(key, state))
    }

    /// Stops trying for this device, keeping the entry so `reconcile` will not rebuild it.
    ///
    /// Cancelling the supervisor from inside one of its own children is intentional: it is the one
    /// handle that owns both the pump and this watcher, so cancelling it releases every resource the
    /// subscription held while leaving the recorded verdict in place.
    private func giveUp(key: EventDeviceKey, state: AlertStreamState) {
        guard var entry = subscriptions[key] else { return }
        entry.terminal = state
        let supervisor = entry.supervisor
        entry.supervisor = nil
        subscriptions[key] = entry
        logger.notice(.core, "event stream given up for \(key.description): \(state)")
        publish(.gaveUp(key, state))
        supervisor?.cancel()
    }

    /// Cancels a subscription's supervisor, stops its monitor and forgets it.
    private func remove(_ key: EventDeviceKey) async {
        guard let entry = subscriptions.removeValue(forKey: key) else { return }
        entry.supervisor?.cancel()
        await entry.monitor?.stop()
        totals.monitorsStopped += 1
        publish(.stopped(key))
    }

    /// Hands an event to the broadcaster without blocking the caller on the fan-out. Captures the
    /// broadcaster and the value only — never `self`.
    private func publish(_ event: EventMonitorEvent) {
        let feed = feed
        Task { await feed.yield(event) }
    }
}

#endif
