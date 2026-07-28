//
//  EventRing.swift
//  VigilCore
//
//  The fixed-capacity rings the coalescer counts in, and the outcome it reports.
//  macOS-only. Split from EventCoalescer.swift, which docs/API_CONTRACT.md §7.2 caps at 600
//  lines.
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

#endif  // os(macOS)
