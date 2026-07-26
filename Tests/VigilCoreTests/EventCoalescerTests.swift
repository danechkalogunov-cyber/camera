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

// MARK: - Harness

/// Drives a coalescer along a virtual timeline. `seconds` is both the monotonic reading and the
/// wall-clock offset, so device time and receipt time agree unless a test deliberately skews them.
private struct EventCoalescerHarness {
    var coalescer: EventCoalescer
    let ids = EventIDSequence()
    let camera = CameraID()

    init(bounds: EventBounds = EventBounds(recordsPerCamera: 512, cameras: 64,
                                           newRecordsPerCameraPerMinute: 1_000,
                                           newRecordsPerApplicationPerMinute: 10_000)) {
        coalescer = EventCoalescer(bounds: bounds)
    }

    /// Ingests one alert at `seconds` on the virtual timeline.
    @discardableResult
    mutating func ingest(at seconds: Double,
                         kind: EventKind = .motion,
                         channel: ChannelID = 1,
                         state: EventState = .active,
                         activePostCount: Int = 1,
                         deviceOffset: Double? = nil,
                         naive: Bool = false,
                         regions: [DetectionRegion] = [],
                         snapshot: Data? = nil,
                         rawType: String? = nil,
                         target: DetectionTarget? = nil,
                         cameraID: CameraID? = nil) -> EventIngestOutcome {
        let alert = EventAlertFixture.alert(kind: kind,
                                           rawType: rawType,
                                           channel: channel,
                                           state: state,
                                           activePostCount: activePostCount,
                                           offset: deviceOffset ?? seconds,
                                           naive: naive,
                                           regions: regions,
                                           snapshot: snapshot)
        return coalescer.ingest(alert,
                                cameraID: cameraID ?? camera,
                                target: target,
                                receiptTime: EventAlertFixture.deviceEpoch
                                    .addingTimeInterval(seconds),
                                now: MediaInstant(nanoseconds: Int64(seconds * 1e9)),
                                newID: ids.next())
    }

    var records: [EventRecord] { coalescer.records(for: camera, limit: 500) }
}

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
