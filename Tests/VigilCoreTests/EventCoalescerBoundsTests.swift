//
//  EventCoalescerTests.swift
//  VigilCoreTests
//
//  The de-duplication rule and the bounded ring, tested directly: no actor, no clock, no device.
//  Covers docs/spec-core.md §11.3 and the seven event kinds of docs/spec-isapi.md §14.3.
//
//  `@testable` because `EventCoalescer` and `EventRing` are internal on purpose — they are the
//  mechanism, and `EventStore` is the API. Testing the mechanism directly is what makes a 3-second
//  window assertable at all: every instant here is a literal.
//

#if os(macOS)

import Foundation
import Testing
@testable import VigilCore
import VigilISAPI
import VigilProtocols

// MARK: - Bounds

@Suite("EventCoalescer bounds")
struct EventCoalescerBoundsTests {

    /// The ring drops the OLDEST and never the newest.
    @Test func eventCoalescerRingDropsOldestNotNewest() {
        var h = EventCoalescerHarness(bounds: EventBounds(recordsPerCamera: 4, cameras: 4,
                                                          newRecordsPerCameraPerMinute: 1_000,
                                                          newRecordsPerApplicationPerMinute: 10_000))
        for index in 0..<10 {
            // 10 s apart and always `inactive`, so each is its own record with no open window.
            _ = h.ingest(at: Double(index) * 10, kind: .motion, state: .inactive,
                         activePostCount: index + 1)
        }
        let held = h.records
        #expect(held.count == 4)
        // Newest first: the last four created, in reverse creation order.
        #expect(held.map(\.firstAt) == (6...9).reversed().map {
            EventAlertFixture.deviceEpoch.addingTimeInterval(Double($0) * 10)
        })
        #expect(h.coalescer.counters.recordsEvicted == 6)
    }

    /// Filling the ring never loses the newest record, at any fill level.
    @Test func eventCoalescerRingKeepsTheNewestRecordAtEveryFill() {
        for total in 1...12 {
            var h = EventCoalescerHarness(
                bounds: EventBounds(recordsPerCamera: 4, cameras: 4,
                                    newRecordsPerCameraPerMinute: 1_000,
                                    newRecordsPerApplicationPerMinute: 10_000))
            for index in 0..<total {
                _ = h.ingest(at: Double(index) * 10, state: .inactive, activePostCount: index + 1)
            }
            let newest = h.records.first
            #expect(newest?.firstAt == EventAlertFixture.deviceEpoch
                        .addingTimeInterval(Double(total - 1) * 10), "fill \(total)")
            #expect(h.records.count == min(total, 4), "fill \(total)")
        }
    }

    /// `EventRing` on its own: append past capacity, and the oldest goes.
    @Test func eventCoalescerRingBufferEvictsInOrder() {
        var ring = EventRing(capacity: 3)
        let ids = EventIDSequence()
        var made: [EventRecord] = []
        for index in 0..<5 {
            let record = EventRecord(id: ids.next(), cameraID: CameraID(), channel: 1,
                                     kind: .motion, rawEventType: "VMD", target: .unclassified,
                                     severity: .info,
                                     firstAt: EventAlertFixture.deviceEpoch
                                        .addingTimeInterval(Double(index)),
                                     lastAt: EventAlertFixture.deviceEpoch
                                        .addingTimeInterval(Double(index)),
                                     count: 1, isActive: false,
                                     deviceTime: EventAlertFixture.deviceEpoch,
                                     usedReceiptTime: false, deviceTimeWasNaive: false,
                                     regions: [], hasSnapshot: false, ioPort: nil)
            made.append(record)
            let evicted = ring.append(record)
            if index < 3 {
                #expect(evicted == nil)
            } else {
                #expect(evicted?.id == made[index - 3].id)
            }
        }
        #expect(ring.count == 3)
        #expect(ring.newest?.id == made[4].id)
        #expect(ring.oldest?.id == made[2].id)
        #expect(ring.record(id: made[0].id) == nil)
        #expect(ring.newestFirst(limit: 10).map(\.id) == [made[4].id, made[3].id, made[2].id])
        #expect(ring.newestFirst(limit: 0).isEmpty)
    }

    /// A record evicted while its window was still open does not resurrect: the next announcement
    /// starts a fresh row rather than updating a record that is gone.
    @Test func eventCoalescerDoesNotResurrectAnEvictedRecord() {
        var h = EventCoalescerHarness(bounds: EventBounds(recordsPerCamera: 2, cameras: 4,
                                                          newRecordsPerCameraPerMinute: 1_000,
                                                          newRecordsPerApplicationPerMinute: 10_000))
        _ = h.ingest(at: 0, kind: .motion, activePostCount: 1)
        _ = h.ingest(at: 0.5, kind: .tamper, activePostCount: 1)
        _ = h.ingest(at: 1.0, kind: .videoLoss, activePostCount: 1)   // evicts the motion record
        // Still inside the 3 s window for motion, but its record has been evicted.
        _ = h.ingest(at: 1.5, kind: .motion, activePostCount: 2)
        #expect(h.records.count == 2)
        #expect(h.records.contains { $0.kind == .motion && $0.count == 1 })
    }

    /// Geometry is clamped, so a device that sends thousands of points cannot grow the ring.
    @Test func eventCoalescerClampsRegionsAndPolygons() {
        var h = EventCoalescerHarness(bounds: EventBounds(recordsPerCamera: 8, cameras: 4,
                                                          regionsPerRecord: 2,
                                                          polygonPointsPerRegion: 5,
                                                          newRecordsPerCameraPerMinute: 1_000,
                                                          newRecordsPerApplicationPerMinute: 10_000))
        let regions = (1...20).map { EventAlertFixture.region(id: $0, points: 400) }
        _ = h.ingest(at: 0, kind: .intrusion, regions: regions)
        let stored = h.records.first?.regions ?? []
        #expect(stored.count == 2)
        #expect(stored.allSatisfy { $0.polygon.count == 5 })
    }

    /// A tripwire's two points survive clamping — dropping them would erase the drawn line.
    @Test func eventCoalescerKeepsATwoPointTripwire() {
        var h = EventCoalescerHarness()
        let line = DetectionRegion(regionID: 1, sensitivityLevel: 60,
                                   polygon: [NormalizedPoint(x: 0.1, y: 0.9),
                                             NormalizedPoint(x: 0.8, y: 0.4)],
                                   targetRect: nil)
        _ = h.ingest(at: 0, kind: .lineCrossing, regions: [line])
        #expect(h.records.first?.regions.first?.polygon.count == 2)
    }

    /// Geometry from the newest announcement that has any is kept; an announcement with none does
    /// not erase the last known polygon.
    @Test func eventCoalescerKeepsTheLastKnownGeometry() {
        var h = EventCoalescerHarness()
        _ = h.ingest(at: 0, kind: .intrusion, regions: [EventAlertFixture.region(id: 1)])
        _ = h.ingest(at: 1, kind: .intrusion, activePostCount: 2, regions: [])
        #expect(h.records.first?.regions.count == 1)
        _ = h.ingest(at: 2, kind: .intrusion, activePostCount: 3,
                     regions: [EventAlertFixture.region(id: 9)])
        #expect(h.records.first?.regions.first?.regionID == 9)
    }

    /// Open windows are bounded however many distinct event types a device invents.
    @Test func eventCoalescerBoundsOpenWindows() {
        var h = EventCoalescerHarness()
        for index in 0..<400 {
            // 400 distinct raw types inside one window: every one opens a window if unbounded.
            _ = h.ingest(at: Double(index) * 0.001, kind: .other("kind\(index)"),
                         rawType: "kind\(index)")
        }
        #expect(h.coalescer.openWindowCount(for: h.camera) <= h.coalescer.maxOpenWindowsPerCamera)
        #expect(h.coalescer.counters.openWindowsForced > 0)
    }

    /// Two targets is normal, but a device inventing target classes cannot grow the window list past
    /// `openWindowsPerKey`.
    @Test func eventCoalescerBoundsWindowsPerKey() {
        var h = EventCoalescerHarness(bounds: EventBounds(recordsPerCamera: 64, cameras: 4,
                                                          openWindowsPerKey: 2,
                                                          newRecordsPerCameraPerMinute: 1_000,
                                                          newRecordsPerApplicationPerMinute: 10_000))
        for index in 0..<10 {
            _ = h.ingest(at: Double(index) * 0.01, kind: .intrusion,
                         target: .other("class\(index)"))
        }
        #expect(h.coalescer.openWindowCount(for: h.camera) <= 2)
    }

    /// The camera ceiling: the least recently active camera's ring is dropped, and the newcomer is
    /// tracked.
    @Test func eventCoalescerEvictsTheLeastRecentlyActiveCamera() {
        var h = EventCoalescerHarness(bounds: EventBounds(recordsPerCamera: 8, cameras: 2,
                                                          newRecordsPerCameraPerMinute: 1_000,
                                                          newRecordsPerApplicationPerMinute: 10_000))
        let first = CameraID()
        let second = CameraID()
        let third = CameraID()
        _ = h.ingest(at: 0, cameraID: first)
        _ = h.ingest(at: 10, cameraID: second)
        _ = h.ingest(at: 20, cameraID: third)
        #expect(h.coalescer.trackedCameraCount == 2)
        #expect(h.coalescer.recordCount(for: first) == 0)
        #expect(h.coalescer.recordCount(for: third) == 1)
        #expect(h.coalescer.counters.camerasEvicted == 1)
    }

    /// The per-camera ceiling stops new rows but keeps extending the rows that exist — a storm must
    /// not make the feed lie about the events already in it.
    @Test func eventCoalescerAppliesThePerCameraRateCeiling() {
        var h = EventCoalescerHarness(bounds: EventBounds(recordsPerCamera: 64, cameras: 4,
                                                          newRecordsPerCameraPerMinute: 3,
                                                          newRecordsPerApplicationPerMinute: 100))
        // Three rows allowed, each `inactive` so nothing stays open.
        for index in 0..<3 {
            _ = h.ingest(at: Double(index), state: .inactive, activePostCount: index + 1)
        }
        let refused = h.ingest(at: 4, state: .inactive, activePostCount: 9)
        guard case .suppressed(let scope, _) = refused else {
            Issue.record("expected .suppressed, got \(refused)")
            return
        }
        #expect(scope == .camera)
        #expect(h.coalescer.counters.suppressedByRateLimit == 1)

        // An open record still coalesces while suppressed.
        var live = EventCoalescerHarness(bounds: EventBounds(recordsPerCamera: 64, cameras: 4,
                                                             newRecordsPerCameraPerMinute: 1,
                                                             newRecordsPerApplicationPerMinute: 100))
        _ = live.ingest(at: 0, activePostCount: 1)
        let extended = live.ingest(at: 1, activePostCount: 2)
        #expect(extended.record?.count == 2)
    }

    /// The ceiling is a rolling minute, not a lifetime quota.
    @Test func eventCoalescerRateCeilingRollsOff() {
        var h = EventCoalescerHarness(bounds: EventBounds(recordsPerCamera: 64, cameras: 4,
                                                          newRecordsPerCameraPerMinute: 2,
                                                          newRecordsPerApplicationPerMinute: 100))
        _ = h.ingest(at: 0, state: .inactive)
        _ = h.ingest(at: 1, state: .inactive)
        if case .created = h.ingest(at: 2, state: .inactive) {
            Issue.record("third record inside the minute should have been suppressed")
        }
        // 61 s after the first two, the window has rolled off.
        guard case .created = h.ingest(at: 62, state: .inactive) else {
            Issue.record("a record after the rolling minute should be created")
            return
        }
    }

    /// The storm notice appears once and explains itself, and does not repeat inside the hour.
    @Test func eventCoalescerRaisesOneStormNoticePerHour() {
        var h = EventCoalescerHarness(bounds: EventBounds(recordsPerCamera: 64, cameras: 4,
                                                          newRecordsPerCameraPerMinute: 1,
                                                          newRecordsPerApplicationPerMinute: 100,
                                                          stormNoticeIntervalSeconds: 3_600))
        _ = h.ingest(at: 0, state: .inactive)
        var notices = 0
        for index in 1...20 {
            if case .suppressed(_, let notice) = h.ingest(at: Double(index), state: .inactive),
               notice != nil {
                notices += 1
            }
        }
        #expect(notices == 1)
        #expect(h.coalescer.counters.stormNoticesRaised == 1)
        let storm = h.records.first { $0.isSynthetic }
        #expect(storm?.kind == .other("eventStorm"))
        #expect(storm?.severity == .warning)
    }
}


#endif
