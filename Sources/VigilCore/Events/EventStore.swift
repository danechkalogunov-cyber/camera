//
//  EventStore.swift
//  VigilCore
//
//  The actor that owns the camera-side event history: a bounded, arrival-ordered ring per camera,
//  de-duplicated, and broadcast to whoever is watching the feed.
//  Implements docs/spec-core.md §11.1 and §11.3, and docs/API_CONTRACT.md §2 R-62 / R-65.
//
//  The actor is a thin shell on purpose. It owns the clocks, the identity source, the logger and the
//  broadcast, and nothing else: every decision — is this the same event, is this a duplicate, has
//  this camera exceeded its ceiling, which record is evicted — lives in the pure `EventCoalescer`
//  next door, where it is driven by injected instants and reproduces exactly under test.
//
//  Vigil runs NO detection model. Every event here was detected by the camera's own DSP and reported
//  over ISAPI; `DetectionTarget` is the device's classification, not ours.
//

#if os(macOS)

import Foundation
import VigilISAPI
import VigilProtocols

// MARK: - EventStoreChange

/// What the store just did, for the feed and for the badge count.
///
/// Delivered through a `Broadcaster` with `.bufferingNewest(256)`, the standing policy for event-
/// shaped streams (API_CONTRACT §2 R-65): a UI that stops reading drops its own oldest changes and
/// never stalls ingest.
public enum EventStoreChange: Sendable, Hashable {
    /// A new row appeared.
    case created(EventRecord)
    /// An existing row grew: `count` and `duration` changed, identity did not.
    case extended(EventRecord)
    /// The device said the occurrence ended.
    case closed(EventRecord)
    /// Rows were deleted, by the user or by `forget(cameraID:)`.
    case removed(Set<EventID>)
    /// Read state changed for one or more rows. Carries no payload: the badge recomputes, and a
    /// mark-all-read on 500 rows must not produce 500 elements.
    case readStateChanged
    /// A rate ceiling refused new rows for this camera. `notice` is the synthetic "event storm"
    /// record when this was the announcement that raised one.
    case suppressed(cameraID: CameraID, scope: EventRateScope, notice: EventRecord?)
}

// MARK: - EventStore

/// The camera-side event history.
///
/// # Bounds
///
/// Everything is bounded, because a camera pointed at a busy street announces an active alarm once a
/// second forever. The numbers and their justifications live in `EventBounds`; in summary, per
/// camera at most `recordsPerCamera` (512) records and 32 open coalescing windows, at most `cameras`
/// (64) cameras tracked, at most `regionsPerRecord` × `polygonPointsPerRegion` (4 × 32) points of
/// geometry per record, and **no image bytes at all** — so the worst case is ≈1 MiB per camera and a
/// realistic case ≈100 KiB, with no growth path in either.
public actor EventStore {

    // MARK: State

    private var coalescer: EventCoalescer
    private let clock: any MonotonicClock
    private let wallClock: any WallClock
    private let logger: any LoggerProtocol
    private let makeID: @Sendable () -> EventID
    private let changeFeed = Broadcaster<EventStoreChange>(bufferingPolicy: .bufferingNewest(256))

    /// - Parameters:
    ///   - bounds: every limit. Shrink it in a test to fill a ring in a few lines.
    ///   - clock: monotonic; decides window expiry and the rate ceilings. Nothing here reads a clock
    ///     any other way, which is the only reason a 3-second rule can be tested at all.
    ///   - wallClock: supplies receipt time for records whose device clock is not to be trusted.
    ///   - makeID: identity source. Injected so a test can hand out predictable ids.
    public init(bounds: EventBounds = EventBounds(),
                clock: any MonotonicClock,
                wallClock: any WallClock,
                logger: any LoggerProtocol = NullLogger(),
                makeID: @escaping @Sendable () -> EventID = { EventID() }) {
        self.coalescer = EventCoalescer(bounds: bounds)
        self.clock = clock
        self.wallClock = wallClock
        self.logger = logger
        self.makeID = makeID
    }

    // MARK: Ingest

    /// Folds one alert from a camera into the history.
    ///
    /// Returns what happened, so the caller can count outcomes without inspecting the ring. A
    /// heartbeat, an exact resend and a rate-limited announcement all return without storing
    /// anything.
    ///
    /// - Parameters:
    ///   - alert: the decoded wire part.
    ///   - cameraID: the camera it is filed against — already demultiplexed from the device's
    ///     channel by `EventMonitorService`.
    ///   - target: the device's own classification, when the caller has one out of band. `nil` lets
    ///     the store derive whatever the raw event type carries.
    @discardableResult
    public func ingest(_ alert: EventNotificationAlert, from cameraID: CameraID,
                       target: DetectionTarget? = nil) -> EventIngestOutcome {
        let outcome = coalescer.ingest(alert,
                                      cameraID: cameraID,
                                      target: target,
                                      receiptTime: wallClock.now,
                                      now: clock.now(),
                                      newID: makeID())
        switch outcome {
        case .created(let record):
            publish(.created(record))
        case .extended(let record):
            publish(.extended(record))
        case .closed(let record):
            publish(.closed(record))
        case .suppressed(let scope, let notice):
            // One line per suppression would itself be a storm; the counter carries the volume and
            // the synthetic record carries the user-visible explanation.
            if let notice {
                logger.notice(.core, "event storm on camera \(cameraID.short): \(notice.count) "
                              + "records suppressed, scope \(scope.rawValue)")
            }
            publish(.suppressed(cameraID: cameraID, scope: scope, notice: notice))
        case .heartbeat, .duplicate:
            break
        }
        return outcome
    }

    // MARK: Queries

    /// Newest first across every camera. `limit` is clamped to `EventBounds.maxQueryLimit`.
    public func recent(limit: Int = 200) -> [EventRecord] {
        coalescer.records(limit: limit)
    }

    /// Newest first for one camera. `limit` is clamped to `EventBounds.maxQueryLimit`.
    public func recent(cameraID: CameraID, limit: Int = 200) -> [EventRecord] {
        coalescer.records(for: cameraID, limit: limit)
    }

    /// One record, or `nil` when it was deleted or has aged out of the ring.
    public func record(id: EventID, cameraID: CameraID) -> EventRecord? {
        coalescer.record(id: id, cameraID: cameraID)
    }

    /// Unread rows across every camera. This is the badge number.
    public func unreadCount() -> Int { coalescer.unreadCount }

    /// Rows currently held for one camera.
    public func recordCount(cameraID: CameraID) -> Int { coalescer.recordCount(for: cameraID) }

    /// Rows currently held across every camera.
    public func totalRecordCount() -> Int { coalescer.totalRecordCount }

    /// Cameras with history.
    public func trackedCameraCount() -> Int { coalescer.trackedCameraCount }

    /// Open coalescing windows for a camera. Exposed for tests and the diagnostics bundle: it is the
    /// number that shows whether the de-duplication state itself is leaking.
    public func openWindowCount(cameraID: CameraID) -> Int {
        coalescer.openWindowCount(for: cameraID)
    }

    /// Totals since construction.
    public func counters() -> EventStoreCounters { coalescer.counters }

    /// The bounds this store was built with.
    public func bounds() -> EventBounds { coalescer.bounds }

    // MARK: Feed state

    public func markRead(_ ids: Set<EventID>) {
        guard !ids.isEmpty else { return }
        coalescer.markRead(ids: ids)
        publish(.readStateChanged)
    }

    public func markAllRead() {
        coalescer.markAllRead()
        publish(.readStateChanged)
    }

    /// Deletes rows. Any open coalescing window pointing at a deleted row is forgotten too, so a
    /// deleted row cannot be resurrected by the next announcement of the same alarm.
    public func delete(_ ids: Set<EventID>) {
        guard !ids.isEmpty else { return }
        let removed = coalescer.delete(ids: ids)
        guard removed > 0 else { return }
        publish(.removed(ids))
    }

    /// Drops one camera's whole history — called when a camera is removed from the library.
    public func forget(cameraID: CameraID) {
        let doomed = Set(coalescer.records(for: cameraID, limit: coalescer.bounds.maxQueryLimit)
            .map(\.id))
        coalescer.forget(cameraID: cameraID)
        if !doomed.isEmpty { publish(.removed(doomed)) }
    }

    // MARK: Streams

    /// A fresh stream of changes.
    ///
    /// A factory, not a property: a stored `AsyncStream` has exactly one consumer and the second
    /// caller silently receives nothing (API_CONTRACT §2 R-27, R-65).
    public nonisolated func changes() -> AsyncStream<EventStoreChange> {
        changeFeed.stream()
    }

    /// Completes every consumer's stream. Called on shutdown.
    public func finish() async {
        await changeFeed.finish()
    }

    /// How many consumers of `changes()` have finished registering.
    ///
    /// `Broadcaster.stream()` registers asynchronously by contract, so a test that starts producing
    /// before its own registration lands would race the first change. This is the seam that makes
    /// that wait deterministic; nothing in the app uses it.
    func changeConsumerCount() async -> Int { await changeFeed.consumerCount }

    /// Hands a change to the broadcaster without blocking ingest on the fan-out.
    ///
    /// Only the broadcaster and the value are captured — never `self` — so the send cannot extend the
    /// actor's lifetime or reorder against a later ingest.
    private func publish(_ change: EventStoreChange) {
        let feed = changeFeed
        Task { await feed.yield(change) }
    }
}

#endif
