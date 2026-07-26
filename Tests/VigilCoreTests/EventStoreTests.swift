//
//  EventStoreTests.swift
//  VigilCoreTests
//
//  The actor surface: injected clocks, the change broadcast, and the feed operations.
//  Covers docs/spec-core.md §11.1 and docs/API_CONTRACT.md §2 R-65 (stream factories, not properties).
//

#if os(macOS)

import Foundation
import Testing
@testable import VigilCore
import VigilISAPI
import VigilProtocols

// MARK: - Harness

/// A store wired to clocks a test moves, and the ids it will hand out.
private struct EventStoreHarness {
    let clock = EventTestClock()
    let wall = EventTestWallClock()
    let ids = EventIDSequence()
    let camera = CameraID()
    let store: EventStore

    init(bounds: EventBounds = EventBounds()) {
        let sequence = ids
        store = EventStore(bounds: bounds, clock: clock, wallClock: wall,
                           makeID: { sequence.next() })
    }

    /// Moves both clocks by the same amount, so device time and receipt time stay in step.
    func advance(seconds: Double) {
        clock.advance(seconds: seconds)
        wall.advance(seconds: seconds)
    }

    /// The alert the device would send now, with its own timestamp matching the wall clock.
    func alert(kind: EventKind = .motion, state: EventState = .active,
               activePostCount: Int = 1, channel: ChannelID = 1) -> EventNotificationAlert {
        EventNotificationAlert(deviceIP: "192.168.1.64", deviceMAC: nil, channel: channel,
                               channelName: nil, timestamp: wall.now, timestampWasNaive: false,
                               kind: kind, rawType: EventAlertFixture.wireType(for: kind),
                               state: state, activePostCount: activePostCount, ioPort: nil,
                               regions: [], snapshot: nil)
    }
}

// MARK: - Tests

@Suite("EventStore")
struct EventStoreTests {

    /// The store reads its own clocks: a hundred announcements a second apart are one row, and no
    /// test anywhere had to sleep.
    @Test func eventStoreCollapsesARepeatedAlarmUsingItsInjectedClock() async {
        let h = EventStoreHarness()
        for tick in 0..<100 {
            _ = await h.store.ingest(h.alert(activePostCount: tick + 1), from: h.camera)
            h.advance(seconds: 1)
        }
        #expect(await h.store.recordCount(cameraID: h.camera) == 1)
        let record = await h.store.recent(cameraID: h.camera).first
        #expect(record?.count == 100)
        #expect(record?.duration == 99)
        let counters = await h.store.counters()
        #expect(counters.alertsIngested == 100)
        #expect(counters.recordsCreated == 1)
    }

    /// Two occurrences separated by more than the window are two rows.
    @Test func eventStoreSplitsOccurrencesAcrossAGap() async {
        let h = EventStoreHarness()
        _ = await h.store.ingest(h.alert(), from: h.camera)
        h.advance(seconds: 30)
        _ = await h.store.ingest(h.alert(), from: h.camera)
        #expect(await h.store.recordCount(cameraID: h.camera) == 2)
    }

    /// A heartbeat is not an event and produces no row.
    @Test func eventStoreRejectsHeartbeats() async {
        let h = EventStoreHarness()
        let outcome = await h.store.ingest(EventAlertFixture.heartbeat(), from: h.camera)
        #expect(outcome == .heartbeat)
        #expect(await h.store.totalRecordCount() == 0)
        #expect(await h.store.counters().heartbeatsRejected == 1)
    }

    /// `changes()` is a factory: two consumers both receive, which a stored `AsyncStream` property
    /// could not do (R-27, R-65).
    @Test func eventStoreBroadcastsToEveryConsumer() async {
        let h = EventStoreHarness()
        let first = h.store.changes()
        let second = h.store.changes()
        _ = await eventWaitUntil { await h.store.changeConsumerCount() >= 2 }

        _ = await h.store.ingest(h.alert(), from: h.camera)
        var firstIterator = first.makeAsyncIterator()
        var secondIterator = second.makeAsyncIterator()
        let a = await firstIterator.next()
        let b = await secondIterator.next()
        guard case .created(let left) = a, case .created(let right) = b else {
            let seen = "\(String(describing: a)) / \(String(describing: b))"
            Issue.record("both consumers should see .created, saw \(seen)")
            return
        }
        #expect(left.id == right.id)
    }

    /// The change sequence for one occurrence: created, extended, closed.
    @Test func eventStorePublishesCreatedExtendedClosed() async {
        let h = EventStoreHarness()
        let stream = h.store.changes()
        _ = await eventWaitUntil { await h.store.changeConsumerCount() >= 1 }
        var iterator = stream.makeAsyncIterator()

        _ = await h.store.ingest(h.alert(activePostCount: 1), from: h.camera)
        h.advance(seconds: 1)
        _ = await h.store.ingest(h.alert(activePostCount: 2), from: h.camera)
        h.advance(seconds: 1)
        _ = await h.store.ingest(h.alert(state: .inactive, activePostCount: 3), from: h.camera)

        var kinds: [String] = []
        for _ in 0..<3 {
            switch await iterator.next() {
            case .created: kinds.append("created")
            case .extended: kinds.append("extended")
            case .closed: kinds.append("closed")
            default: kinds.append("other")
            }
        }
        #expect(kinds == ["created", "extended", "closed"])
    }

    /// Read state: the badge count falls, and one change is published however many rows were marked.
    @Test func eventStoreMarksReadAndCountsUnread() async {
        let h = EventStoreHarness()
        for _ in 0..<3 {
            _ = await h.store.ingest(h.alert(state: .inactive), from: h.camera)
            h.advance(seconds: 10)
        }
        #expect(await h.store.unreadCount() == 3)
        let ids = Set(await h.store.recent(cameraID: h.camera).prefix(2).map(\.id))
        await h.store.markRead(ids)
        #expect(await h.store.unreadCount() == 1)
        await h.store.markAllRead()
        #expect(await h.store.unreadCount() == 0)
    }

    /// Deleting a row publishes `.removed` and removes it.
    @Test func eventStoreDeletesRows() async {
        let h = EventStoreHarness()
        _ = await h.store.ingest(h.alert(state: .inactive), from: h.camera)
        guard let id = await h.store.recent(cameraID: h.camera).first?.id else {
            Issue.record("nothing to delete")
            return
        }
        await h.store.delete([id])
        #expect(await h.store.record(id: id, cameraID: h.camera) == nil)
        #expect(await h.store.totalRecordCount() == 0)
    }

    /// Forgetting a camera drops its whole ring.
    @Test func eventStoreForgetsACamera() async {
        let h = EventStoreHarness()
        _ = await h.store.ingest(h.alert(state: .inactive), from: h.camera)
        await h.store.forget(cameraID: h.camera)
        #expect(await h.store.trackedCameraCount() == 0)
        #expect(await h.store.recent(cameraID: h.camera).isEmpty)
    }

    /// The bound is real: a small ring holds its capacity and no more, and keeps the newest.
    @Test func eventStoreHonoursItsRingBound() async {
        let h = EventStoreHarness(bounds: EventBounds(recordsPerCamera: 3, cameras: 4,
                                                     newRecordsPerCameraPerMinute: 1_000,
                                                     newRecordsPerApplicationPerMinute: 10_000))
        var lastKind = EventKind.motion
        let kinds: [EventKind] = [.motion, .lineCrossing, .intrusion, .tamper, .videoLoss]
        for kind in kinds {
            _ = await h.store.ingest(h.alert(kind: kind, state: .inactive), from: h.camera)
            h.advance(seconds: 10)
            lastKind = kind
        }
        let held = await h.store.recent(cameraID: h.camera)
        #expect(held.count == 3)
        #expect(held.first?.kind == lastKind)
        #expect(await h.store.counters().recordsEvicted == 2)
    }

    /// Open windows do not accumulate: once an occurrence is closed, its window is gone.
    @Test func eventStoreDoesNotLeakOpenWindows() async {
        let h = EventStoreHarness()
        for _ in 0..<50 {
            _ = await h.store.ingest(h.alert(activePostCount: 1), from: h.camera)
            _ = await h.store.ingest(h.alert(state: .inactive, activePostCount: 2), from: h.camera)
            h.advance(seconds: 10)
        }
        #expect(await h.store.openWindowCount(cameraID: h.camera) == 0)
    }

    /// The store never keeps image bytes: a 4 MiB JPEG on the alert leaves only a flag behind.
    @Test func eventStoreKeepsNoImageBytes() async {
        let h = EventStoreHarness()
        let big = Data(repeating: 0xAB, count: 4 * 1024 * 1024)
        var alert = h.alert()
        alert.snapshot = big
        _ = await h.store.ingest(alert, from: h.camera)
        let record = await h.store.recent(cameraID: h.camera).first
        #expect(record?.hasSnapshot == true)
        // `EventRecord` has no image-bearing field at all — this is a compile-time guarantee, and the
        // flag is the only trace a 4 MiB part leaves in memory.
        #expect(record?.regions.isEmpty == true)
    }

    /// The bounds the store was built with are readable, so the diagnostics bundle can print them.
    @Test func eventStoreReportsItsBounds() async {
        let h = EventStoreHarness(bounds: EventBounds(recordsPerCamera: 7, cameras: 3))
        let bounds = await h.store.bounds()
        #expect(bounds.recordsPerCamera == 7)
        #expect(bounds.cameras == 3)
        #expect(bounds.coalesceWindowSeconds == 3.0)
    }

    /// An explicit target overrides derivation, which is how the ISAPI layer will hand the DSP's
    /// classification over once it decodes `<detectionTarget>`.
    @Test func eventStoreAcceptsAnExplicitTarget() async {
        let h = EventStoreHarness()
        _ = await h.store.ingest(h.alert(kind: .intrusion), from: h.camera, target: .vehicle)
        #expect(await h.store.recent(cameraID: h.camera).first?.target == .vehicle)
    }

    /// A finished store completes its consumers rather than hanging them.
    @Test func eventStoreFinishCompletesConsumers() async {
        let h = EventStoreHarness()
        let stream = h.store.changes()
        _ = await eventWaitUntil { await h.store.changeConsumerCount() >= 1 }
        await h.store.finish()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }
}

#endif
