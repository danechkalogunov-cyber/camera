//
//  EventCoalescer.swift
//  VigilCore
//
//  The de-duplication engine and the bounded per-camera ring: the part that turns two hundred
//  identical announcements of one person walking past into one row with a duration.
//  Implements docs/spec-core.md §11.3 and docs/FEATURES.md item 1384.
//
//  A plain `struct` with `mutating` methods and **no clock of its own** — every instant arrives as a
//  parameter. That is what makes the whole rule testable without an actor, a device or a wall clock
//  (IMPL_RULES: "parsers and state machines are plain structs that an owning actor drives"), and it
//  is why a de-duplication window can be asserted at all: a 3-second rule tested against `Date()`
//  is a test that passes on a fast machine and fails on a loaded one.
//
//  Two independent time bases, deliberately:
//    * MONOTONIC (`MediaInstant`) decides whether a window is still open. Wall time steps when NTP
//      corrects it, and a window measured against it can close instantly or never.
//    * WALL (`Date`) fills `firstAt`/`lastAt`, because those are shown to a person.
//

#if os(macOS)

import Foundation
import VigilISAPI
import VigilProtocols

// MARK: - EventRateScope

/// Which ceiling refused to create a record.
public enum EventRateScope: String, Sendable, Hashable, Codable {
    /// This camera exceeded `EventBounds.newRecordsPerCameraPerMinute`.
    case camera
    /// The whole app exceeded `EventBounds.newRecordsPerApplicationPerMinute`.
    case application
}

// MARK: - EventIngestOutcome

/// What one alert did to the store. Every alert produces exactly one of these, so a caller can
/// count them and a test can assert on them without inspecting the ring.
public enum EventIngestOutcome: Sendable, Hashable {

    /// The device's periodic liveness part. Never an event, never stored.
    case heartbeat

    /// A byte-for-byte resend of an announcement already counted — same key, same device timestamp,
    /// same `activePostCount`. Dropped, but it keeps the open window alive.
    case duplicate(EventID)

    /// A new occurrence.
    case created(EventRecord)

    /// An ongoing occurrence, extended. `record.count` and `record.duration` have grown.
    case extended(EventRecord)

    /// The device said `inactive`: the occurrence ended. The window is closed, so the next alert
    /// starts a new record regardless of the coalescing window.
    case closed(EventRecord)

    /// A rate ceiling refused to create a new record. Existing records still coalesce.
    /// `stormNotice` is the once-an-hour synthetic record that explains the suppression, when this
    /// alert was the one that raised it.
    case suppressed(scope: EventRateScope, stormNotice: EventRecord?)

    /// The record this outcome concerns, when there is one.
    public var record: EventRecord? {
        switch self {
        case .created(let record), .extended(let record), .closed(let record): record
        case .suppressed(_, let notice): notice
        case .heartbeat, .duplicate: nil
        }
    }
}

// MARK: - EventStoreCounters

/// Observable totals. The test suite reads these instead of trying to observe timing, and the
/// diagnostics bundle prints them.
public struct EventStoreCounters: Sendable, Hashable, Codable {
    public var alertsIngested = 0
    public var heartbeatsRejected = 0
    public var duplicatesDropped = 0
    public var recordsCreated = 0
    public var recordsExtended = 0
    public var recordsClosed = 0
    /// Announcements whose `activePostCount` restarted, i.e. a new alarm episode inside the
    /// coalescing window.
    public var episodeRestarts = 0
    public var suppressedByRateLimit = 0
    public var stormNoticesRaised = 0
    /// Records pushed out of a per-camera ring by a newer one.
    public var recordsEvicted = 0
    /// Whole cameras dropped because `EventBounds.cameras` was exceeded.
    public var camerasEvicted = 0
    /// Open windows dropped because `EventBounds.openWindowsPerKey` or the per-camera window cap was
    /// exceeded. A dropped window merges the next alert into a new record; nothing is lost.
    public var openWindowsForced = 0

    public init() {}
}

// MARK: - InstantRing

/// A fixed-size ring of monotonic instants, used only to answer "how many events in the last N
/// seconds". Allocated once; the rate limiter therefore cannot grow with the storm it limits.
struct InstantRing: Sendable {
    private var storage: [Int64]
    private var head = 0
    private var filled = 0

    init(capacity: Int) {
        storage = [Int64](repeating: .min, count: max(1, capacity))
    }

    var capacity: Int { storage.count }

    /// How many recorded instants are within `seconds` of `now`.
    func count(within seconds: Double, of now: MediaInstant) -> Int {
        let cutoff = now.nanoseconds - Int64(seconds * 1e9)
        var total = 0
        for index in 0..<filled where storage[index] >= cutoff {
            total += 1
        }
        return total
    }

    /// Records an instant, overwriting the oldest when full.
    mutating func append(_ instant: MediaInstant) {
        storage[head] = instant.nanoseconds
        head = (head + 1) % storage.count
        filled = min(filled + 1, storage.count)
    }
}

// MARK: - EventRing

/// The bounded, arrival-ordered ring of one camera's records.
///
/// Arrival order, not device-timestamp order: appends are monotonic in receipt time, whereas a
/// device's own clock can jump backwards and coalescing moves an older record's `lastAt` forward, so
/// a strictly time-sorted structure would need re-sorting on every extension. `newestFirst()`
/// therefore returns newest-arrival-first, which for every device with a sane clock is also
/// newest-first by time; `EventStore` sorts explicitly when it merges cameras.
///
/// Not generic, on purpose: a generic type may not hold a `static let` (it does not compile on
/// macOS, and the Linux build cannot see it because the whole file is inside `#if os(macOS)`), and
/// this ring has no second element type in its future.
struct EventRing: Sendable {

    /// Slots. `nil` is either never-used or deleted.
    private var storage: [EventRecord?]
    /// Index of the oldest occupied slot.
    private var head = 0
    /// Slots spanned from `head`, deleted ones included. This is what the capacity bounds.
    private var span = 0
    /// Where each live record sits, so an extension is O(1) and does not scan.
    private var slotByID: [EventID: Int] = [:]

    let capacity: Int

    init(capacity: Int) {
        let slots = max(1, capacity)
        self.capacity = slots
        self.storage = [EventRecord?](repeating: nil, count: slots)
    }

    /// Live records held.
    var count: Int { slotByID.count }

    var isEmpty: Bool { slotByID.isEmpty }

    /// The newest live record, or `nil`.
    var newest: EventRecord? {
        for offset in stride(from: span - 1, through: 0, by: -1) {
            if let record = storage[(head + offset) % capacity] { return record }
        }
        return nil
    }

    /// The oldest live record, or `nil`.
    var oldest: EventRecord? {
        for offset in 0..<span {
            if let record = storage[(head + offset) % capacity] { return record }
        }
        return nil
    }

    /// Appends, evicting the oldest slot when full. Returns the evicted record, if the slot held a
    /// live one.
    ///
    /// The newest record is never the one dropped: eviction always takes `head`, and the append
    /// always lands at the tail.
    @discardableResult
    mutating func append(_ record: EventRecord) -> EventRecord? {
        var evicted: EventRecord?
        if span == capacity {
            evicted = storage[head]
            if let evicted { slotByID.removeValue(forKey: evicted.id) }
            storage[head] = nil
            head = (head + 1) % capacity
            span -= 1
        }
        let slot = (head + span) % capacity
        storage[slot] = record
        slotByID[record.id] = slot
        span += 1
        return evicted
    }

    /// The live record with this id, or `nil` if it was never here, was deleted, or has been evicted.
    func record(id: EventID) -> EventRecord? {
        guard let slot = slotByID[id] else { return nil }
        return storage[slot]
    }

    /// Applies `transform` to the record with this id in place. Returns the new value, or `nil` when
    /// the record is no longer held.
    @discardableResult
    mutating func update(id: EventID,
                         _ transform: (inout EventRecord) -> Void) -> EventRecord? {
        guard let slot = slotByID[id], var record = storage[slot] else { return nil }
        transform(&record)
        storage[slot] = record
        return record
    }

    /// Applies `transform` to every live record.
    mutating func mutateEach(_ transform: (inout EventRecord) -> Void) {
        for offset in 0..<span {
            let slot = (head + offset) % capacity
            guard var record = storage[slot] else { continue }
            transform(&record)
            storage[slot] = record
        }
    }

    /// Deletes records by id, tombstoning their slots. Returns how many were actually held.
    ///
    /// A tombstone keeps occupying its slot until the ring wraps past it. That is deliberate: it
    /// keeps append O(1) and the bound is on slots, so a delete can never *increase* memory.
    @discardableResult
    mutating func remove(ids: Set<EventID>) -> Int {
        var removed = 0
        for id in ids {
            guard let slot = slotByID.removeValue(forKey: id) else { continue }
            storage[slot] = nil
            removed += 1
        }
        trimHead()
        return removed
    }

    /// Empties the ring, keeping its storage.
    mutating func removeAll() {
        for index in storage.indices { storage[index] = nil }
        slotByID.removeAll(keepingCapacity: true)
        head = 0
        span = 0
    }

    /// Live records, newest arrival first, at most `limit` of them.
    func newestFirst(limit: Int) -> [EventRecord] {
        guard limit > 0 else { return [] }
        var out: [EventRecord] = []
        out.reserveCapacity(min(limit, slotByID.count))
        for offset in stride(from: span - 1, through: 0, by: -1) {
            guard let record = storage[(head + offset) % capacity] else { continue }
            out.append(record)
            if out.count == limit { break }
        }
        return out
    }

    /// Drops leading tombstones so a run of deletes returns slots to the ring immediately.
    private mutating func trimHead() {
        while span > 0, storage[head] == nil {
            head = (head + 1) % capacity
            span -= 1
        }
    }
}

// MARK: - EventCoalescer

/// The de-duplication rule, the per-camera rings and the rate ceilings — all of it pure.
///
/// # What makes two alerts the same event
///
/// A Hikvision device re-announces an active alarm about once a second for its whole duration, with
/// `activePostCount` climbing. Three things decide whether an incoming alert extends a record or
/// starts one:
///
/// 1. **Key.** Same camera, same channel, same `EventKind` (`EventCoalesceKey`).
/// 2. **Window.** The record's last announcement was within `coalesceWindowSeconds` (default 3.0),
///    measured on the MONOTONIC clock. Why 3.0 s: the re-announce interval is 1–2 s
///    (spec-isapi §14.3, spec-core §11.3), so 3.0 s is 1.5–3× it — one dropped or delayed
///    announcement, or a second of scheduling jitter, cannot split one walk-past into two rows,
///    while a genuine second event (one person leaves, another arrives) is still separated. Below
///    ~2.5 s a single missed announcement splits the row; above ~5 s two distinct passes merge, and
///    the row's duration stops meaning anything.
/// 3. **Target.** A `human` and a `vehicle` in the same zone are two events and must not merge.
///    But the DSP drops the target box on some announcements of the *same* object, so
///    `.unclassified` is treated as a wildcard: it joins the open window and a later classified
///    announcement *upgrades* it. Only two **different classified** targets split.
///
/// Three things override the window and force a new record:
///
/// * An `inactive` announcement closes the record immediately, so the next alert starts a new one
///   however soon it arrives.
/// * `activePostCount` going **backwards** after it had climbed above 1 — the device restarted its
///   episode counter, which is a new alarm even inside 3 s. Guarded on "had climbed above 1" so the
///   firmwares that hard-code `activePostCount` to 1 do not turn every repeat into a new row.
/// * The record having been evicted from the ring in the meantime.
///
/// And one thing drops an alert entirely: an exact resend — same key, same device timestamp, same
/// `activePostCount` — which some firmwares send twice. It still refreshes the window, so a stream
/// of pure duplicates cannot create a fresh record every 3 seconds.
struct EventCoalescer: Sendable {

    // MARK: Open window

    /// A record still being extended.
    struct OpenWindow: Sendable {
        var id: EventID
        var target: DetectionTarget
        /// Monotonic instant of the last announcement, including dropped duplicates.
        var lastSeen: MediaInstant
        /// The device timestamp and count of the last *counted* announcement, for duplicate and
        /// episode-restart detection.
        var lastDeviceTime: Date
        var lastActivePostCount: Int
    }

    /// One camera's state.
    struct CameraState: Sendable {
        var ring: EventRing
        var open: [EventCoalesceKey: [OpenWindow]] = [:]
        var creations: InstantRing
        var lastActivity: MediaInstant
        var lastStormNotice: MediaInstant?
        var suppressedSinceNotice = 0
    }

    let bounds: EventBounds
    private(set) var counters = EventStoreCounters()
    private var cameras: [CameraID: CameraState] = [:]
    private var applicationCreations: InstantRing

    /// Hard ceiling on open windows per camera, independent of how many distinct `(channel, kind)`
    /// pairs a device invents. A device that sends a fresh `eventType` string every second would
    /// otherwise grow this dictionary without bound; expired windows are pruned first, and only then
    /// is the oldest forced closed.
    var maxOpenWindowsPerCamera: Int { max(bounds.openWindowsPerKey, bounds.openWindowsPerKey * 8) }

    init(bounds: EventBounds = EventBounds()) {
        self.bounds = bounds
        self.applicationCreations = InstantRing(capacity: bounds.newRecordsPerApplicationPerMinute)
    }

    // MARK: Reading

    var trackedCameraCount: Int { cameras.count }

    var totalRecordCount: Int { cameras.values.reduce(0) { $0 + $1.ring.count } }

    func recordCount(for cameraID: CameraID) -> Int { cameras[cameraID]?.ring.count ?? 0 }

    func openWindowCount(for cameraID: CameraID) -> Int {
        cameras[cameraID]?.open.values.reduce(0) { $0 + $1.count } ?? 0
    }

    func record(id: EventID, cameraID: CameraID) -> EventRecord? {
        cameras[cameraID]?.ring.record(id: id)
    }

    func records(for cameraID: CameraID, limit: Int) -> [EventRecord] {
        cameras[cameraID]?.ring.newestFirst(limit: min(limit, bounds.maxQueryLimit)) ?? []
    }

    /// Newest-first across every tracked camera, merged by `firstAt` and then by id so the order is
    /// total and reproducible.
    ///
    /// Each camera contributes at most `limit` records before the merge, so the work is bounded by
    /// `cameras × limit` and never by total history.
    func records(limit: Int) -> [EventRecord] {
        let capped = min(max(0, limit), bounds.maxQueryLimit)
        guard capped > 0 else { return [] }
        var merged: [EventRecord] = []
        merged.reserveCapacity(min(capped * cameras.count, capped * bounds.cameras))
        for state in cameras.values {
            merged.append(contentsOf: state.ring.newestFirst(limit: capped))
        }
        merged.sort { left, right in
            left.firstAt == right.firstAt
                ? left.id.description > right.id.description
                : left.firstAt > right.firstAt
        }
        return Array(merged.prefix(capped))
    }

    var unreadCount: Int {
        cameras.values.reduce(0) { total, state in
            total + state.ring.newestFirst(limit: state.ring.capacity).reduce(0) {
                $0 + ($1.isRead ? 0 : 1)
            }
        }
    }

    // MARK: Mutating — feed state

    mutating func markRead(ids: Set<EventID>) {
        guard !ids.isEmpty else { return }
        for cameraID in cameras.keys {
            cameras[cameraID]?.ring.mutateEach { record in
                if ids.contains(record.id) { record.isRead = true }
            }
        }
    }

    mutating func markAllRead() {
        for cameraID in cameras.keys {
            cameras[cameraID]?.ring.mutateEach { $0.isRead = true }
        }
    }

    /// Deletes records and forgets any open window pointing at them, so a deleted record can never
    /// be resurrected by a later announcement.
    @discardableResult
    mutating func delete(ids: Set<EventID>) -> Int {
        guard !ids.isEmpty else { return 0 }
        var removed = 0
        for cameraID in cameras.keys {
            guard var state = cameras[cameraID] else { continue }
            removed += state.ring.remove(ids: ids)
            for (key, windows) in state.open {
                let kept = windows.filter { !ids.contains($0.id) }
                if kept.isEmpty { state.open.removeValue(forKey: key) } else { state.open[key] = kept }
            }
            cameras[cameraID] = state
        }
        return removed
    }

    /// Forgets one camera entirely — its ring and its open windows.
    mutating func forget(cameraID: CameraID) {
        cameras.removeValue(forKey: cameraID)
    }

    // MARK: Mutating — ingest

    /// Folds one wire alert into the store.
    ///
    /// - Parameters:
    ///   - alert: the decoded `<EventNotificationAlert>` part. Heartbeats are rejected here as well
    ///     as by `AlertStreamMonitor`, because a synthetic or replayed alert can reach this method
    ///     without passing the monitor.
    ///   - cameraID: which camera the alert is filed against. Channel-to-camera demultiplexing is
    ///     `EventMonitorService`'s job; by the time an alert is here it is already attributed.
    ///   - target: the device's classification when the caller has one. `nil` means "derive what can
    ///     be derived from the raw event type", which is `.unclassified` for most firmwares.
    ///   - receiptTime: wall-clock arrival, injected. Used for `firstAt`/`lastAt` when the device's
    ///     own clock cannot be trusted.
    ///   - now: the monotonic reading for the same moment. Decides window expiry and rate limits.
    ///   - newID: an identity to use if a record is created. Minting it outside keeps this method
    ///     free of randomness, so a test replays exactly.
    mutating func ingest(_ alert: EventNotificationAlert,
                         cameraID: CameraID,
                         target explicitTarget: DetectionTarget?,
                         receiptTime: Date,
                         now: MediaInstant,
                         newID: EventID) -> EventIngestOutcome {
        counters.alertsIngested += 1
        guard !alert.isHeartbeat else {
            counters.heartbeatsRejected += 1
            return .heartbeat
        }

        let target = explicitTarget ?? DetectionTarget.inferred(fromRawEventType: alert.rawType)
        let stamp = timestamps(for: alert, receiptTime: receiptTime)
        let key = EventCoalesceKey(cameraID: cameraID, channel: alert.channel, kind: alert.kind)

        ensureCamera(cameraID, now: now)
        pruneWindows(cameraID: cameraID, now: now)
        cameras[cameraID]?.lastActivity = now

        if let matched = match(key: key, target: target, cameraID: cameraID) {
            switch extend(matched, key: key, alert: alert, cameraID: cameraID, target: target,
                          stamp: stamp, now: now) {
            case .some(let outcome):
                return outcome
            case .none:
                break               // the window was stale or the episode restarted: create instead
            }
        }
        return create(key: key, alert: alert, cameraID: cameraID, target: target, stamp: stamp,
                      now: now, newID: newID)
    }

    // MARK: Timestamps

    /// The absolute time to file the event under, and why.
    struct Stamp: Sendable {
        var effective: Date
        var deviceTime: Date
        var usedReceiptTime: Bool
        var deviceTimeWasNaive: Bool
    }

    /// Decides whether to believe the device's clock.
    ///
    /// A camera with an unset clock, or one that sends local time with no zone, otherwise scatters
    /// its events across the timeline — years away, in the worst case seen in the field. Beyond
    /// `clockSkewToleranceSeconds` of disagreement, or on a zone-less timestamp, receipt time is used
    /// and the device's own value is preserved in `deviceTime` for diagnosis (spec-core §11.3).
    func timestamps(for alert: EventNotificationAlert, receiptTime: Date) -> Stamp {
        let skew = abs(alert.timestamp.timeIntervalSince(receiptTime))
        let distrust = alert.timestampWasNaive || skew > bounds.clockSkewToleranceSeconds
        return Stamp(effective: distrust ? receiptTime : alert.timestamp,
                     deviceTime: alert.timestamp,
                     usedReceiptTime: distrust,
                     deviceTimeWasNaive: alert.timestampWasNaive)
    }

    // MARK: Matching

    /// Picks the open window an alert belongs to, or `nil` for "this is a new occurrence".
    ///
    /// Expired windows have already been pruned, so every candidate here is live.
    func match(key: EventCoalesceKey, target: DetectionTarget,
               cameraID: CameraID) -> OpenWindow? {
        guard let candidates = cameras[cameraID]?.open[key], !candidates.isEmpty else { return nil }
        if let exact = candidates.first(where: { $0.target == target }) { return exact }
        if target.isClassified {
            // The DSP had not classified the object when the record was created; this announcement
            // names it. Upgrade rather than split.
            return candidates.first { !$0.target.isClassified }
        }
        // An unclassified announcement of something already classified: the DSP dropped the box for
        // one frame. Attach to the most recent window instead of starting a row.
        return candidates.max { $0.lastSeen < $1.lastSeen }
    }

    // MARK: Extension

    /// Extends `window`'s record, or returns `nil` when the caller must create a record instead.
    private mutating func extend(_ window: OpenWindow, key: EventCoalesceKey,
                                 alert: EventNotificationAlert, cameraID: CameraID,
                                 target: DetectionTarget, stamp: Stamp,
                                 now: MediaInstant) -> EventIngestOutcome? {
        guard var state = cameras[cameraID] else { return nil }
        guard state.ring.record(id: window.id) != nil else {
            // Evicted by newer traffic while still "open". Drop the window; the alert becomes a new
            // record, which is the honest outcome — the old row is gone from the ring.
            removeWindow(window.id, key: key, from: &state)
            cameras[cameraID] = state
            return nil
        }

        // An exact resend. Refresh the window so a duplicate-only stream cannot age out and create a
        // second record, but count nothing.
        if alert.activePostCount == window.lastActivePostCount,
           alert.timestamp == window.lastDeviceTime {
            counters.duplicatesDropped += 1
            touchWindow(window.id, key: key, in: &state) { $0.lastSeen = now }
            cameras[cameraID] = state
            return .duplicate(window.id)
        }

        // The device restarted its episode counter: a new alarm, even inside the window.
        if window.lastActivePostCount > 1, alert.activePostCount < window.lastActivePostCount {
            counters.episodeRestarts += 1
            removeWindow(window.id, key: key, from: &state)
            cameras[cameraID] = state
            return nil
        }

        let clamped = EventRecord.clampedRegions(alert.regions, bounds: bounds)
        let isActive = alert.state == .active
        let updated = state.ring.update(id: window.id) { record in
            record.count += 1
            // Only ever forward: a device clock that steps backwards must not shrink a duration.
            record.lastAt = max(record.lastAt, stamp.effective)
            record.severity = max(record.severity, alert.kind.defaultSeverity)
            if !clamped.isEmpty { record.regions = clamped }
            if alert.snapshot != nil { record.hasSnapshot = true }
            if target.isClassified, !record.target.isClassified { record.target = target }
            if let port = alert.ioPort { record.ioPort = port }
            record.isActive = isActive
            if stamp.usedReceiptTime { record.usedReceiptTime = true }
        }
        guard let updated else {
            removeWindow(window.id, key: key, from: &state)
            cameras[cameraID] = state
            return nil
        }

        if isActive {
            touchWindow(window.id, key: key, in: &state) {
                $0.lastSeen = now
                $0.lastDeviceTime = alert.timestamp
                $0.lastActivePostCount = alert.activePostCount
                if target.isClassified, !$0.target.isClassified { $0.target = target }
            }
            cameras[cameraID] = state
            counters.recordsExtended += 1
            return .extended(updated)
        }
        // `inactive` ends the occurrence. Closing the window is what makes the next alert a new row
        // however soon it arrives (spec-core §11.3).
        removeWindow(window.id, key: key, from: &state)
        cameras[cameraID] = state
        counters.recordsClosed += 1
        return .closed(updated)
    }

    // MARK: Creation

    private mutating func create(key: EventCoalesceKey, alert: EventNotificationAlert,
                                 cameraID: CameraID, target: DetectionTarget, stamp: Stamp,
                                 now: MediaInstant, newID: EventID) -> EventIngestOutcome {
        guard var state = cameras[cameraID] else {
            return .suppressed(scope: .application, stormNotice: nil)
        }
        if let scope = refusedScope(state: state, now: now) {
            counters.suppressedByRateLimit += 1
            state.suppressedSinceNotice += 1
            let notice = stormNotice(&state, cameraID: cameraID, stamp: stamp, now: now,
                                     newID: newID)
            cameras[cameraID] = state
            return .suppressed(scope: scope, stormNotice: notice)
        }

        let isActive = alert.state == .active
        let record = EventRecord(id: newID,
                                 cameraID: cameraID,
                                 channel: alert.channel,
                                 kind: alert.kind,
                                 rawEventType: alert.rawType,
                                 target: target,
                                 severity: alert.kind.defaultSeverity,
                                 firstAt: stamp.effective,
                                 lastAt: stamp.effective,
                                 count: 1,
                                 isActive: isActive,
                                 deviceTime: stamp.deviceTime,
                                 usedReceiptTime: stamp.usedReceiptTime,
                                 deviceTimeWasNaive: stamp.deviceTimeWasNaive,
                                 regions: EventRecord.clampedRegions(alert.regions, bounds: bounds),
                                 hasSnapshot: alert.snapshot != nil,
                                 ioPort: alert.ioPort)
        if state.ring.append(record) != nil { counters.recordsEvicted += 1 }
        state.creations.append(now)
        applicationCreations.append(now)
        counters.recordsCreated += 1
        // A record that arrived already `inactive` — a clearing announcement for an occurrence we
        // never saw start, e.g. because Vigil connected mid-alarm. It is stored, but no window
        // opens: there is nothing left to extend.
        if isActive {
            openWindow(OpenWindow(id: newID, target: target, lastSeen: now,
                                  lastDeviceTime: alert.timestamp,
                                  lastActivePostCount: alert.activePostCount),
                       key: key, in: &state)
        }
        cameras[cameraID] = state
        return .created(record)
    }

    /// Which ceiling, if any, refuses a new record.
    private func refusedScope(state: CameraState, now: MediaInstant) -> EventRateScope? {
        if state.creations.count(within: 60, of: now) >= bounds.newRecordsPerCameraPerMinute {
            return .camera
        }
        if applicationCreations.count(within: 60, of: now)
            >= bounds.newRecordsPerApplicationPerMinute {
            return .application
        }
        return nil
    }

    /// Raises the synthetic "event storm" record, at most once per
    /// `EventBounds.stormNoticeIntervalSeconds` per camera.
    ///
    /// It bypasses the rate ceiling on purpose: it is the row that tells the user why the feed went
    /// quiet, so suppressing the explanation along with the events would be the worst of both.
    private mutating func stormNotice(_ state: inout CameraState, cameraID: CameraID,
                                      stamp: Stamp, now: MediaInstant,
                                      newID: EventID) -> EventRecord? {
        if let last = state.lastStormNotice,
           now.seconds(since: last) < bounds.stormNoticeIntervalSeconds {
            return nil
        }
        let suppressed = state.suppressedSinceNotice
        let record = EventRecord(id: newID,
                                 cameraID: cameraID,
                                 channel: 0,
                                 kind: .other("eventStorm"),
                                 rawEventType: "vigil.eventStorm",
                                 target: .unclassified,
                                 severity: .warning,
                                 firstAt: stamp.effective,
                                 lastAt: stamp.effective,
                                 count: suppressed,
                                 isActive: false,
                                 deviceTime: stamp.deviceTime,
                                 usedReceiptTime: true,
                                 deviceTimeWasNaive: false,
                                 regions: [],
                                 hasSnapshot: false,
                                 ioPort: nil,
                                 isSynthetic: true)
        if state.ring.append(record) != nil { counters.recordsEvicted += 1 }
        state.lastStormNotice = now
        state.suppressedSinceNotice = 0
        counters.stormNoticesRaised += 1
        return record
    }

    // MARK: Camera and window bookkeeping

    /// Creates the camera's state if absent, evicting the least recently active camera when the
    /// ceiling is reached.
    ///
    /// Eviction is by `lastActivity`, tie-broken by id, so which camera goes is deterministic and a
    /// failing test reproduces.
    private mutating func ensureCamera(_ cameraID: CameraID, now: MediaInstant) {
        if cameras[cameraID] != nil { return }
        if cameras.count >= bounds.cameras {
            // An explicit loop, not `map` + `min(by:)`: the tuple-returning version defeated the
            // type checker outright ("unable to type-check this expression in reasonable time").
            var victim: CameraID?
            var victimAt = MediaInstant(nanoseconds: .max)
            for (id, state) in cameras {
                let at = state.lastActivity
                if at < victimAt || (at == victimAt && id.description < (victim?.description ?? "")) {
                    victim = id
                    victimAt = at
                }
            }
            if let victim {
                cameras.removeValue(forKey: victim)
                counters.camerasEvicted += 1
            }
        }
        cameras[cameraID] = CameraState(
            ring: EventRing(capacity: bounds.recordsPerCamera),
            creations: InstantRing(capacity: bounds.newRecordsPerCameraPerMinute),
            lastActivity: now)
    }

    /// Drops every window whose last announcement is older than the coalescing window, then enforces
    /// the per-camera window ceiling.
    private mutating func pruneWindows(cameraID: CameraID, now: MediaInstant) {
        guard var state = cameras[cameraID] else { return }
        var changed = false
        for (key, windows) in state.open {
            let live = windows.filter {
                now.seconds(since: $0.lastSeen) < bounds.coalesceWindowSeconds
            }
            if live.count != windows.count {
                changed = true
                if live.isEmpty { state.open.removeValue(forKey: key) } else { state.open[key] = live }
            }
        }
        if enforceWindowCeiling(&state) { changed = true }
        if changed { cameras[cameraID] = state }
    }

    /// Forces the globally oldest windows closed until the per-camera ceiling holds.
    ///
    /// A forced window would have expired within `coalesceWindowSeconds` anyway; the consequence is
    /// that the next announcement opens a new record instead of extending one, never a lost event.
    /// Returns whether anything was closed.
    private mutating func enforceWindowCeiling(_ state: inout CameraState) -> Bool {
        var total = state.open.values.reduce(0) { $0 + $1.count }
        var closedAny = false
        while total > maxOpenWindowsPerCamera {
            var oldest: (key: EventCoalesceKey, id: EventID, at: MediaInstant)?
            for (key, windows) in state.open {
                for window in windows where oldest == nil || window.lastSeen < (oldest?.at ?? .zero) {
                    oldest = (key, window.id, window.lastSeen)
                }
            }
            guard let oldest else { break }
            removeWindow(oldest.id, key: oldest.key, from: &state)
            counters.openWindowsForced += 1
            closedAny = true
            total -= 1
        }
        return closedAny
    }

    /// Registers a window, enforcing `EventBounds.openWindowsPerKey` by dropping the oldest.
    private mutating func openWindow(_ window: OpenWindow, key: EventCoalesceKey,
                                     in state: inout CameraState) {
        var windows = state.open[key] ?? []
        windows.append(window)
        if windows.count > bounds.openWindowsPerKey {
            windows.sort { $0.lastSeen < $1.lastSeen }
            windows.removeFirst(windows.count - bounds.openWindowsPerKey)
            counters.openWindowsForced += 1
        }
        state.open[key] = windows
        // The per-key cap is not the whole bound: a device inventing distinct event types opens one
        // window per type, so the per-camera ceiling is re-checked here rather than only on the way
        // in. Checking it before the insert instead would force a live window closed even when no
        // new one was about to be added.
        _ = enforceWindowCeiling(&state)
    }

    private func removeWindow(_ id: EventID, key: EventCoalesceKey, from state: inout CameraState) {
        guard var windows = state.open[key] else { return }
        windows.removeAll { $0.id == id }
        if windows.isEmpty { state.open.removeValue(forKey: key) } else { state.open[key] = windows }
    }

    private func touchWindow(_ id: EventID, key: EventCoalesceKey, in state: inout CameraState,
                             _ transform: (inout OpenWindow) -> Void) {
        guard var windows = state.open[key],
              let index = windows.firstIndex(where: { $0.id == id }) else { return }
        transform(&windows[index])
        state.open[key] = windows
    }
}

#endif
