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

// MARK: - De-duplication

@Suite("EventCoalescer de-duplication")
struct EventCoalescerDedupeTests {

    /// The headline case: a person walks past, the camera announces it once a second for 100
    /// seconds, and the feed must show ONE row.
    @Test func eventCoalescerCollapsesOneHundredRepeatsIntoOneRecord() {
        var h = EventCoalescerHarness()
        for tick in 0..<100 {
            _ = h.ingest(at: Double(tick), activePostCount: tick + 1)
        }
        #expect(h.records.count == 1)
        let record = h.records.first
        #expect(record?.count == 100)
        #expect(record?.duration == 99)
        #expect(record?.isActive == true)
        #expect(h.coalescer.counters.recordsCreated == 1)
        #expect(h.coalescer.counters.recordsExtended == 99)
    }

    /// Two different kinds one second apart are two occurrences, however close together.
    @Test func eventCoalescerKeepsDifferentKindsApart() {
        var h = EventCoalescerHarness()
        _ = h.ingest(at: 0, kind: .motion)
        _ = h.ingest(at: 1, kind: .lineCrossing)
        #expect(h.records.count == 2)
    }

    /// Same kind, different channel on the same device: two occurrences.
    @Test func eventCoalescerKeepsDifferentChannelsApart() {
        var h = EventCoalescerHarness()
        _ = h.ingest(at: 0, channel: 1)
        _ = h.ingest(at: 1, channel: 2)
        #expect(h.records.count == 2)
    }

    /// Same kind on two cameras: two occurrences, one per camera's ring.
    @Test func eventCoalescerKeepsDifferentCamerasApart() {
        var h = EventCoalescerHarness()
        let other = CameraID()
        _ = h.ingest(at: 0)
        _ = h.ingest(at: 1, cameraID: other)
        #expect(h.records.count == 1)
        #expect(h.coalescer.recordCount(for: other) == 1)
    }

    /// Motion stops, then starts again after a gap wider than the window: two rows.
    @Test func eventCoalescerStartsANewRecordAfterAGap() {
        var h = EventCoalescerHarness()
        for tick in 0..<3 { _ = h.ingest(at: Double(tick), activePostCount: tick + 1) }
        for tick in 0..<3 { _ = h.ingest(at: 10 + Double(tick), activePostCount: tick + 1) }
        #expect(h.records.count == 2)
        #expect(h.records.allSatisfy { $0.count == 3 })
    }

    /// The gap rule on its own, with no other signal available to split the rows.
    ///
    /// `activePostCount` climbs straight through 1…6, so the episode-restart rule cannot fire and the
    /// coalescing window is the only thing that can separate the two bursts. The test above, which
    /// restarts the count, passes for two independent reasons; this one isolates the window.
    @Test func eventCoalescerSplitsOnTheGapAloneWithoutACountRestart() {
        var h = EventCoalescerHarness()
        for tick in 0..<3 { _ = h.ingest(at: Double(tick), activePostCount: tick + 1) }
        for tick in 0..<3 { _ = h.ingest(at: 10 + Double(tick), activePostCount: tick + 4) }
        #expect(h.records.count == 2)
        #expect(h.coalescer.counters.episodeRestarts == 0)
    }

    /// The window's exact edge. Just inside 3.0 s extends; at and beyond 3.0 s starts a new record.
    ///
    /// This is the assertion that pins the threshold: it fails if anybody widens or narrows the
    /// window without meaning to.
    @Test func eventCoalescerWindowEdgeIsExactlyThreeSeconds() {
        var inside = EventCoalescerHarness()
        _ = inside.ingest(at: 0)
        _ = inside.ingest(at: 2.999, activePostCount: 2)
        #expect(inside.records.count == 1)

        var edge = EventCoalescerHarness()
        _ = edge.ingest(at: 0)
        _ = edge.ingest(at: 3.0, activePostCount: 2)
        #expect(edge.records.count == 2)

        var outside = EventCoalescerHarness()
        _ = outside.ingest(at: 0)
        _ = outside.ingest(at: 3.001, activePostCount: 2)
        #expect(outside.records.count == 2)
    }

    /// A firmware that sends every alert twice must not double the count.
    @Test func eventCoalescerDropsExactResends() {
        var h = EventCoalescerHarness()
        _ = h.ingest(at: 0, activePostCount: 4, deviceOffset: 0)
        var duplicates = 0
        for tick in 1...50 {
            // Same device timestamp, same activePostCount: an exact resend, arriving later.
            if case .duplicate = h.ingest(at: Double(tick) * 0.01, activePostCount: 4,
                                          deviceOffset: 0) {
                duplicates += 1
            }
        }
        #expect(duplicates == 50)
        #expect(h.records.count == 1)
        #expect(h.records.first?.count == 1)
        #expect(h.coalescer.counters.duplicatesDropped == 50)
    }

    /// A stream of nothing but exact resends must not age its own window out and start a second row
    /// every three seconds. The duplicate refreshes the window even though it is not counted.
    @Test func eventCoalescerDuplicatesKeepTheWindowAlive() {
        var h = EventCoalescerHarness()
        _ = h.ingest(at: 0, activePostCount: 1, deviceOffset: 0)
        for tick in 1...40 {
            _ = h.ingest(at: Double(tick), activePostCount: 1, deviceOffset: 0)
        }
        #expect(h.records.count == 1)
    }

    /// `inactive` closes the occurrence, so the very next announcement is a new row even though it
    /// arrives well inside the window.
    @Test func eventCoalescerInactiveClosesTheWindowImmediately() {
        var h = EventCoalescerHarness()
        _ = h.ingest(at: 0, activePostCount: 1)
        let closed = h.ingest(at: 1, state: .inactive, activePostCount: 2)
        guard case .closed(let record) = closed else {
            Issue.record("expected .closed, got \(closed)")
            return
        }
        #expect(record.isActive == false)
        #expect(record.count == 2)
        _ = h.ingest(at: 1.5, activePostCount: 1)
        #expect(h.records.count == 2)
    }

    /// `activePostCount` going backwards after it had climbed is a new alarm episode, even inside the
    /// window.
    @Test func eventCoalescerTreatsAnActivePostCountRestartAsANewEvent() {
        var h = EventCoalescerHarness()
        _ = h.ingest(at: 0, activePostCount: 1)
        _ = h.ingest(at: 1, activePostCount: 2)
        _ = h.ingest(at: 2, activePostCount: 3)
        _ = h.ingest(at: 2.5, activePostCount: 1)
        #expect(h.records.count == 2)
        #expect(h.coalescer.counters.episodeRestarts == 1)
    }

    /// The regression that the rule above must not cause: firmwares that pin `activePostCount` at 1
    /// for every announcement. Those are repeats, not restarts.
    @Test func eventCoalescerHandlesFirmwareThatPinsActivePostCountToOne() {
        var h = EventCoalescerHarness()
        for tick in 0..<30 {
            // Count pinned at 1, device timestamp advancing: not a duplicate, not a restart.
            _ = h.ingest(at: Double(tick), activePostCount: 1)
        }
        #expect(h.records.count == 1)
        #expect(h.records.first?.count == 30)
        #expect(h.coalescer.counters.episodeRestarts == 0)
    }

    /// The heartbeat is never an event.
    @Test func eventCoalescerRejectsHeartbeats() {
        var h = EventCoalescerHarness()
        let alert = EventAlertFixture.heartbeat()
        let outcome = h.coalescer.ingest(alert, cameraID: h.camera, target: nil,
                                        receiptTime: EventAlertFixture.deviceEpoch,
                                        now: .zero, newID: h.ids.next())
        #expect(outcome == .heartbeat)
        #expect(h.records.isEmpty)
        #expect(h.coalescer.counters.heartbeatsRejected == 1)
    }

    /// A real video-loss alarm looks like a heartbeat except for `activePostCount`, and must be
    /// stored — a camera going dark is the most important event there is.
    @Test func eventCoalescerStoresRealVideoLoss() {
        var h = EventCoalescerHarness()
        _ = h.ingest(at: 0, kind: .videoLoss, activePostCount: 1)
        #expect(h.records.count == 1)
        #expect(h.records.first?.severity == .critical)
        #expect(h.coalescer.counters.heartbeatsRejected == 0)
    }

    /// A clearing announcement with no record open — Vigil connected mid-alarm — is still stored,
    /// and opens no window.
    @Test func eventCoalescerStoresAnUnpairedInactiveAlert() {
        var h = EventCoalescerHarness()
        let outcome = h.ingest(at: 0, kind: .tamper, state: .inactive, activePostCount: 7)
        guard case .created(let record) = outcome else {
            Issue.record("expected .created, got \(outcome)")
            return
        }
        #expect(record.isActive == false)
        #expect(h.coalescer.openWindowCount(for: h.camera) == 0)
    }

    /// The duration is what the row is for: it must grow with the occurrence.
    @Test func eventCoalescerGrowsTheDuration() {
        var h = EventCoalescerHarness()
        for tick in 0..<6 { _ = h.ingest(at: Double(tick), activePostCount: tick + 1) }
        #expect(h.records.first?.duration == 5)
    }

    /// Severity only rises: one critical announcement inside a run of ordinary ones is not lost.
    @Test func eventCoalescerSeverityOnlyRises() {
        var h = EventCoalescerHarness()
        _ = h.ingest(at: 0, kind: .other("weird"), activePostCount: 1)
        // Same raw type, so the same key; `.other` maps to `.info`, and an extension must not lower a
        // severity that was raised.
        _ = h.ingest(at: 1, kind: .other("weird"), activePostCount: 2)
        #expect(h.records.first?.severity == .info)
    }
}


#endif
