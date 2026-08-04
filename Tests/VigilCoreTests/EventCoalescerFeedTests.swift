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

// MARK: - Feed operations

@Suite("EventCoalescer feed operations")
struct EventCoalescerFeedTests {

    @Test func eventCoalescerCountsAndMarksUnread() {
        var h = EventCoalescerHarness()
        for index in 0..<3 { _ = h.ingest(at: Double(index) * 10, state: .inactive) }
        #expect(h.coalescer.unreadCount == 3)
        let first = h.records.first
        h.coalescer.markRead(ids: Set([first?.id].compactMap { $0 }))
        #expect(h.coalescer.unreadCount == 2)
        h.coalescer.markAllRead()
        #expect(h.coalescer.unreadCount == 0)
    }

    /// A deleted row is gone, and the window that pointed at it is forgotten, so the next
    /// announcement of the same alarm creates a new row rather than resurrecting the deleted one.
    @Test func eventCoalescerDeleteForgetsTheOpenWindow() {
        var h = EventCoalescerHarness()
        _ = h.ingest(at: 0, activePostCount: 1)
        guard let id = h.records.first?.id else {
            Issue.record("no record to delete")
            return
        }
        #expect(h.coalescer.delete(ids: [id]) == 1)
        #expect(h.records.isEmpty)
        #expect(h.coalescer.openWindowCount(for: h.camera) == 0)
        _ = h.ingest(at: 1, activePostCount: 2)
        #expect(h.records.count == 1)
        #expect(h.records.first?.id != id)
    }

    /// Cross-camera queries are newest-first and bounded by the query limit.
    @Test func eventCoalescerMergesCamerasNewestFirst() {
        var h = EventCoalescerHarness()
        let other = CameraID()
        _ = h.ingest(at: 0, state: .inactive, cameraID: h.camera)
        _ = h.ingest(at: 10, state: .inactive, cameraID: other)
        _ = h.ingest(at: 20, state: .inactive, cameraID: h.camera)
        let merged = h.coalescer.records(limit: 10)
        #expect(merged.count == 3)
        #expect(merged.map(\.firstAt) == merged.map(\.firstAt).sorted(by: >))
        #expect(h.coalescer.records(limit: 2).count == 2)
        #expect(h.coalescer.records(limit: 0).isEmpty)
    }

    /// `forget` drops a whole camera.
    @Test func eventCoalescerForgetsACamera() {
        var h = EventCoalescerHarness()
        _ = h.ingest(at: 0, state: .inactive)
        h.coalescer.forget(cameraID: h.camera)
        #expect(h.coalescer.trackedCameraCount == 0)
        #expect(h.records.isEmpty)
    }

    /// A query limit above `maxQueryLimit` is clamped rather than honoured.
    @Test func eventCoalescerClampsTheQueryLimit() {
        var h = EventCoalescerHarness(bounds: EventBounds(recordsPerCamera: 32, cameras: 4,
                                                          newRecordsPerCameraPerMinute: 1_000,
                                                          newRecordsPerApplicationPerMinute: 10_000,
                                                          maxQueryLimit: 2))
        for index in 0..<5 { _ = h.ingest(at: Double(index) * 10, state: .inactive) }
        #expect(h.coalescer.records(for: h.camera, limit: 100).count == 2)
        #expect(h.coalescer.records(limit: 100).count == 2)
    }
}

#endif
