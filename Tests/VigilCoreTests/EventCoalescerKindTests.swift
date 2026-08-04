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

// MARK: - The seven kinds

@Suite("EventCoalescer event kinds")
struct EventCoalescerKindTests {

    /// Motion, line crossing, intrusion, field detection, tamper and video loss all arrive, keep
    /// their raw wire type, and carry the severity the spec assigns.
    @Test func eventCoalescerCoversEveryRequiredKind() {
        var h = EventCoalescerHarness()
        let expected: [(EventKind, EventSeverity)] = [
            (.motion, .info),
            (.lineCrossing, .warning),
            (.intrusion, .warning),
            (.regionEntrance, .warning),
            (.regionExit, .warning),
            (.tamper, .critical),
            (.videoLoss, .critical),
        ]
        for (index, pair) in expected.enumerated() {
            // 10 s apart, so no two can coalesce for reasons of proximity.
            _ = h.ingest(at: Double(index) * 10, kind: pair.0, activePostCount: 1)
        }
        #expect(h.records.count == expected.count)
        for pair in expected {
            let record = h.records.first { $0.kind == pair.0 }
            #expect(record?.severity == pair.1, "severity for \(pair.0)")
            #expect(record?.rawEventType == EventAlertFixture.wireType(for: pair.0))
        }
    }

    /// `fielddetection` is the wire name for intrusion; `EventKind(raw:)` must map it, and the store
    /// must file it as `.intrusion`.
    @Test func eventCoalescerMapsFieldDetectionToIntrusion() {
        #expect(EventKind(raw: "fielddetection") == .intrusion)
        #expect(EventKind(raw: "FieldDetection") == .intrusion)
        var h = EventCoalescerHarness()
        _ = h.ingest(at: 0, kind: EventKind(raw: "fielddetection"), rawType: "fielddetection")
        #expect(h.records.first?.kind == .intrusion)
        #expect(h.records.first?.severity == .warning)
    }

    /// `shelteralarm` is the other spelling of tamper, and both must land on one kind.
    @Test func eventCoalescerMapsShelterAlarmToTamper() {
        #expect(EventKind(raw: "shelteralarm") == .tamper)
        #expect(EventKind(raw: "tamperdetection") == .tamper)
    }

    /// An `io` alarm keeps its port number.
    @Test func eventCoalescerKeepsTheAlarmInputPort() {
        var h = EventCoalescerHarness()
        let alert = EventAlertFixture.alert(kind: .alarmInput, ioPort: 3)
        _ = h.coalescer.ingest(alert, cameraID: h.camera, target: nil,
                               receiptTime: EventAlertFixture.deviceEpoch, now: .zero,
                               newID: h.ids.next())
        #expect(h.records.first?.ioPort == 3)
    }

    /// A device-wide fault arrives with channel 0 and is marked as such.
    @Test func eventCoalescerMarksDeviceWideFaults() {
        var h = EventCoalescerHarness()
        _ = h.ingest(at: 0, kind: .diskFull, channel: 0)
        #expect(h.records.first?.isDeviceWide == true)
    }

    /// An unknown event type is never dropped: it keeps its raw name.
    @Test func eventCoalescerKeepsUnknownEventTypes() {
        var h = EventCoalescerHarness()
        _ = h.ingest(at: 0, kind: EventKind(raw: "thermometryAlarm"), rawType: "thermometryAlarm")
        #expect(h.records.first?.kind == .other("thermometryAlarm"))
        #expect(h.records.first?.rawEventType == "thermometryAlarm")
    }
}


#endif
