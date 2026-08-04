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

// MARK: - Target classification

@Suite("EventCoalescer human / vehicle classification")
struct EventCoalescerTargetTests {

    /// A person and a car in the same intrusion zone are two events.
    @Test func eventCoalescerSplitsHumanFromVehicle() {
        var h = EventCoalescerHarness()
        _ = h.ingest(at: 0, kind: .intrusion, target: .human)
        _ = h.ingest(at: 1, kind: .intrusion, activePostCount: 2, target: .vehicle)
        #expect(h.records.count == 2)
        #expect(Set(h.records.map(\.target)) == Set([DetectionTarget.human, .vehicle]))
    }

    /// Two announcements of the same person stay one row.
    @Test func eventCoalescerMergesRepeatedHumanAnnouncements() {
        var h = EventCoalescerHarness()
        for tick in 0..<10 {
            _ = h.ingest(at: Double(tick), kind: .intrusion, activePostCount: tick + 1,
                         target: .human)
        }
        #expect(h.records.count == 1)
        #expect(h.records.first?.target == .human)
        #expect(h.records.first?.count == 10)
    }

    /// The DSP blink: the target box vanishes for one announcement of the same walk-past. That must
    /// not split the row.
    @Test func eventCoalescerTreatsUnclassifiedAsAWildcard() {
        var h = EventCoalescerHarness()
        _ = h.ingest(at: 0, kind: .intrusion, target: .human)
        _ = h.ingest(at: 1, kind: .intrusion, activePostCount: 2, target: .unclassified)
        _ = h.ingest(at: 2, kind: .intrusion, activePostCount: 3, target: .human)
        #expect(h.records.count == 1)
        #expect(h.records.first?.count == 3)
        #expect(h.records.first?.target == .human)
    }

    /// The DSP classifies late: the row was opened unclassified and is upgraded, not duplicated.
    @Test func eventCoalescerUpgradesAnUnclassifiedRecord() {
        var h = EventCoalescerHarness()
        _ = h.ingest(at: 0, kind: .lineCrossing, target: .unclassified)
        _ = h.ingest(at: 1, kind: .lineCrossing, activePostCount: 2, target: .vehicle)
        #expect(h.records.count == 1)
        #expect(h.records.first?.target == .vehicle)
    }

    /// The wire vocabulary, including the trap: `nonMotorVehicle` contains `vehicle`, so order
    /// matters.
    @Test func eventCoalescerDetectionTargetReadsWireValues() {
        #expect(DetectionTarget(wireValue: "human") == .human)
        #expect(DetectionTarget(wireValue: "Human") == .human)
        #expect(DetectionTarget(wireValue: "person") == .human)
        #expect(DetectionTarget(wireValue: "vehicle") == .vehicle)
        #expect(DetectionTarget(wireValue: "VEHICLE") == .vehicle)
        #expect(DetectionTarget(wireValue: "nonMotorVehicle") == .nonMotorVehicle)
        #expect(DetectionTarget(wireValue: "non-motor-vehicle") == .nonMotorVehicle)
        #expect(DetectionTarget(wireValue: "bicycle") == .nonMotorVehicle)
        #expect(DetectionTarget(wireValue: "animal") == .animal)
        #expect(DetectionTarget(wireValue: "") == .unclassified)
        #expect(DetectionTarget(wireValue: "   ") == .unclassified)
        #expect(DetectionTarget(wireValue: "tractor") == .other("tractor"))
    }

    /// A bare event type says nothing about the target and must not be guessed at.
    @Test func eventCoalescerDetectionTargetDoesNotInventAClass() {
        #expect(DetectionTarget.inferred(fromRawEventType: "fielddetection") == .unclassified)
        #expect(DetectionTarget.inferred(fromRawEventType: "VMD") == .unclassified)
        #expect(DetectionTarget.inferred(fromRawEventType: "linedetection") == .unclassified)
    }

    /// Where a firmware does put the class in `eventType`, it is recovered.
    @Test func eventCoalescerDetectionTargetRecoversAClassFromTheRawType() {
        #expect(DetectionTarget.inferred(fromRawEventType: "humanDetection") == .human)
        #expect(DetectionTarget.inferred(fromRawEventType: "vehicleDetection") == .vehicle)
        #expect(DetectionTarget.inferred(fromRawEventType: "nonMotorVehicleDetection")
                == .nonMotorVehicle)
    }

    /// With no explicit target, the store derives one from the raw type and files it on the record.
    @Test func eventCoalescerDerivesTargetWhenTheCallerHasNone() {
        var h = EventCoalescerHarness()
        _ = h.ingest(at: 0, kind: .other("vehicleDetection"), rawType: "vehicleDetection")
        #expect(h.records.first?.target == .vehicle)
    }
}


#endif
