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

// MARK: - Timestamps

@Suite("EventCoalescer timestamps")
struct EventCoalescerTimestampTests {

    /// A device whose clock agrees with ours is believed.
    @Test func eventCoalescerBelievesASaneDeviceClock() {
        var h = EventCoalescerHarness()
        _ = h.ingest(at: 5, deviceOffset: 5)
        #expect(h.records.first?.usedReceiptTime == false)
        #expect(h.records.first?.firstAt == EventAlertFixture.deviceEpoch.addingTimeInterval(5))
    }

    /// A device whose clock is minutes out is not: the row is filed at receipt time and the device's
    /// own value is kept for diagnosis.
    @Test func eventCoalescerFallsBackToReceiptTimeOnSkew() {
        var h = EventCoalescerHarness()
        _ = h.ingest(at: 0, deviceOffset: 3_600)
        let record = h.records.first
        #expect(record?.usedReceiptTime == true)
        #expect(record?.firstAt == EventAlertFixture.deviceEpoch)
        #expect(record?.deviceTime == EventAlertFixture.deviceEpoch.addingTimeInterval(3_600))
    }

    /// Skew exactly at the tolerance is still believed; one second past it is not.
    @Test func eventCoalescerSkewToleranceEdge() {
        var atEdge = EventCoalescerHarness()
        _ = atEdge.ingest(at: 0, deviceOffset: 60)
        #expect(atEdge.records.first?.usedReceiptTime == false)

        var past = EventCoalescerHarness()
        _ = past.ingest(at: 0, deviceOffset: 61)
        #expect(past.records.first?.usedReceiptTime == true)
    }

    /// A zone-less device timestamp is flagged and not trusted for ordering.
    @Test func eventCoalescerDistrustsANaiveTimestamp() {
        var h = EventCoalescerHarness()
        _ = h.ingest(at: 0, deviceOffset: 0, naive: true)
        #expect(h.records.first?.usedReceiptTime == true)
        #expect(h.records.first?.deviceTimeWasNaive == true)
    }

    /// A device clock that steps backwards mid-occurrence must not shrink the row's duration.
    @Test func eventCoalescerNeverShrinksADuration() {
        var h = EventCoalescerHarness()
        _ = h.ingest(at: 0, activePostCount: 1, deviceOffset: 0)
        _ = h.ingest(at: 1, activePostCount: 2, deviceOffset: 1)
        _ = h.ingest(at: 2, activePostCount: 3, deviceOffset: 0.5)   // device clock stepped back
        let record = h.records.first
        #expect(record?.duration == 1)
        #expect((record?.duration ?? -1) >= 0)
    }

    /// A JPEG on any announcement marks the row, and the bytes are not retained by the store.
    @Test func eventCoalescerRecordsThatASnapshotArrived() {
        var h = EventCoalescerHarness()
        _ = h.ingest(at: 0, activePostCount: 1)
        #expect(h.records.first?.hasSnapshot == false)
        _ = h.ingest(at: 1, activePostCount: 2, snapshot: Data(repeating: 0xFF, count: 32))
        #expect(h.records.first?.hasSnapshot == true)
    }
}


#endif
