//
//  EventMonitorServiceTests.swift
//  VigilCoreTests
//
//  Subscription lifecycle, channel attribution and restart policy, driven end to end from real
//  `multipart/mixed` alert-stream bytes through `AlertStreamMonitor` into `EventStore`.
//  Covers docs/spec-core.md §11.2 and docs/spec-isapi.md §14.6.
//
//  Every scripted device reaches a terminal answer, so no test can spin: the monitor's own ladder and
//  the service's re-probe budget both run out, on a clock that never sleeps.
//

#if os(macOS)

import Foundation
import Testing
@testable import VigilCore
import VigilISAPI
import VigilProtocols

// MARK: - Support

/// A monitor factory whose first `nilAnswers` calls fail, modelling "no credential yet".
///
/// `@unchecked Sendable`, justified: the one mutable field is read and written only inside `lock`.
private final class EventFactoryScript: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let nilAnswers: Int
    private let monitor: AlertStreamMonitor

    init(nilAnswers: Int, monitor: AlertStreamMonitor) {
        self.nilAnswers = nilAnswers
        self.monitor = monitor
    }

    func next() -> AlertStreamMonitor? {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return calls > nilAnswers ? monitor : nil
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private actor EventSnapshotCapture {
    private(set) var values: [(EventID, CameraID, Data)] = []

    func append(eventID: EventID, cameraID: CameraID, data: Data) {
        values.append((eventID, cameraID, data))
    }

    var count: Int { values.count }
}

/// The pieces every test here needs: clocks, a store, and a service wired to a scripted device.
private struct EventServiceHarness {
    let clock = EventTestClock()
    let wall = EventTestWallClock()
    let ids = EventIDSequence()
    let store: EventStore

    init(bounds: EventBounds = EventBounds()) {
        let sequence = ids
        store = EventStore(bounds: bounds, clock: clock, wallClock: wall,
                           makeID: { sequence.next() })
    }

    /// A monitor over a scripted device. The snapshot pairing window is left at its default; the
    /// stream's end flushes the last event, which is the path a real device's close takes too.
    func monitor(_ requests: EventScriptedRequests) -> AlertStreamMonitor {
        AlertStreamMonitor(requests: requests, clock: clock, wallClock: wall,
                           random: SplitMix64RandomSource(seed: 7))
    }

    func service(policy: EventMonitorService.Policy = EventMonitorService.Policy(),
                 snapshotSink: @escaping EventMonitorService.SnapshotSink = { _, _, _ in },
                 makeMonitor: @escaping EventMonitorFactory) -> EventMonitorService {
        EventMonitorService(store: store, policy: policy, clock: clock,
                           random: SplitMix64RandomSource(seed: 11),
                           snapshotSink: snapshotSink, makeMonitor: makeMonitor)
    }

    /// A policy with a small re-probe budget, so the terminal path resolves in a few steps.
    static func fastPolicy(maxDevices: Int = 32, reprobes: Int = 2) -> EventMonitorService.Policy {
        var policy = EventMonitorService.Policy()
        policy.maxDevices = maxDevices
        policy.maxUnsupportedReprobes = reprobes
        policy.restartBackoffSeconds = [0.001]
        return policy
    }
}

// MARK: - Tests

@Suite("EventMonitorService")
struct EventMonitorServiceTests {

    /// The whole chain, from bytes to a row: real multipart framing, real XML, real decoding, real
    /// de-duplication.
    @Test func eventMonitorServiceIngestsAnAlertFromRealMultipartBytes() async {
        let h = EventServiceHarness()
        let camera = eventTestCamera()
        let requests = EventScriptedRequests(script: [
            .bytes([EventMultipartFixture.part(eventType: "VMD", channel: 1,
                                               state: "active", count: 1),
                    EventMultipartFixture.closing()]),
        ])
        let monitor = h.monitor(requests)
        let service = h.service(policy: EventServiceHarness.fastPolicy()) { _ in monitor }

        await service.reconcile(cameras: [camera])
        let arrived = await eventWaitUntil { await h.store.totalRecordCount() == 1 }
        #expect(arrived)
        let record = await h.store.recent(cameraID: camera.id).first
        #expect(record?.kind == .motion)
        #expect(record?.rawEventType == "VMD")
        #expect(record?.channel == 1)
        #expect(await service.counters().alertsForwarded == 1)
        await service.stopAll()
    }

    /// The store intentionally keeps only `hasSnapshot`; the bytes leave through the sink after the
    /// stable EventID exists, so the app can name and cache them without retaining image data in the
    /// event ring.
    @Test func eventMonitorServiceForwardsPairedSnapshotWithStoredIdentity() async throws {
        let h = EventServiceHarness()
        let camera = eventTestCamera()
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let capture = EventSnapshotCapture()
        let requests = EventScriptedRequests(script: [
            .bytes([EventMultipartFixture.part(eventType: "VMD", channel: 1,
                                               state: "active", count: 1),
                    EventMultipartFixture.image(jpeg),
                    EventMultipartFixture.closing()]),
        ])
        let monitor = h.monitor(requests)
        let service = h.service(
            policy: EventServiceHarness.fastPolicy(),
            snapshotSink: { eventID, cameraID, data in
                await capture.append(eventID: eventID, cameraID: cameraID, data: data)
            },
            makeMonitor: { _ in monitor })

        await service.reconcile(cameras: [camera])
        #expect(await eventWaitUntil { await capture.count == 1 })
        let stored = try #require(await h.store.recent(cameraID: camera.id).first)
        let captured = await capture.values
        let forwarded = try #require(captured.first)
        #expect(forwarded.0 == stored.id)
        #expect(forwarded.1 == camera.id)
        #expect(forwarded.2 == jpeg)
        #expect(stored.hasSnapshot)
        await service.stopAll()
    }

    /// One device, two cameras: ONE subscription, and each channel's events land on its own camera.
    /// A device-wide fault (channel 0) is filed against the lowest channel rather than dropped, and
    /// an unclaimed channel is counted, not guessed at.
    @Test func eventMonitorServiceDemultiplexesChannelsOnOneSubscription() async {
        let h = EventServiceHarness()
        let first = eventTestCamera(channel: 1)
        let second = eventTestCamera(channel: 2)
        let requests = EventScriptedRequests(script: [
            .bytes([EventMultipartFixture.part(eventType: "VMD", channel: 1,
                                               state: "active", count: 1),
                    EventMultipartFixture.part(eventType: "linedetection", channel: 2,
                                               state: "active", count: 1),
                    EventMultipartFixture.part(eventType: "diskfull", channel: 0,
                                               state: "active", count: 1),
                    EventMultipartFixture.part(eventType: "tamperdetection", channel: 9,
                                               state: "active", count: 1),
                    EventMultipartFixture.closing()]),
        ])
        let monitor = h.monitor(requests)
        let service = h.service(policy: EventServiceHarness.fastPolicy()) { _ in monitor }

        await service.reconcile(cameras: [first, second])
        #expect(await service.subscriptionCount() == 1)
        let done = await eventWaitUntil { await service.counters().unattributedAlerts == 1 }
        #expect(done)
        _ = await eventWaitUntil { await h.store.recordCount(cameraID: first.id) == 2 }

        let firstRecords = await h.store.recent(cameraID: first.id)
        let secondRecords = await h.store.recent(cameraID: second.id)
        #expect(firstRecords.count == 2)                       // channel 1 plus the device-wide fault
        #expect(firstRecords.contains { $0.kind == .diskFull && $0.isDeviceWide })
        #expect(secondRecords.count == 1)
        #expect(secondRecords.first?.kind == .lineCrossing)
        #expect(await service.counters().alertsForwarded == 3)
        await service.stopAll()
    }

    /// A single camera that reports an unexpected channel number still gets its events: with one
    /// camera on the device there is nothing to confuse it with.
    @Test func eventMonitorServiceAttributesToTheOnlyCameraOnADevice() async {
        let h = EventServiceHarness()
        let camera = eventTestCamera(channel: 1)
        let requests = EventScriptedRequests(script: [
            .bytes([EventMultipartFixture.part(eventType: "VMD", channel: 101,
                                               state: "active", count: 1),
                    EventMultipartFixture.closing()]),
        ])
        let monitor = h.monitor(requests)
        let service = h.service(policy: EventServiceHarness.fastPolicy()) { _ in monitor }
        await service.reconcile(cameras: [camera])
        #expect(await eventWaitUntil { await h.store.recordCount(cameraID: camera.id) == 1 })
        #expect(await service.counters().unattributedAlerts == 0)
        await service.stopAll()
    }

    /// Reconciling an unchanged library must not build a second subscription, spawn a second pump, or
    /// deliver the same alert twice. A duplicated subscription shows up as `alertsForwarded == 2`.
    @Test func eventMonitorServiceReconcileIsIdempotent() async {
        let h = EventServiceHarness()
        let camera = eventTestCamera()
        let requests = EventScriptedRequests(script: [
            .bytes([EventMultipartFixture.part(eventType: "VMD", channel: 1,
                                               state: "active", count: 1),
                    EventMultipartFixture.closing()]),
        ])
        let monitor = h.monitor(requests)
        let service = h.service(policy: EventServiceHarness.fastPolicy()) { _ in monitor }

        await service.reconcile(cameras: [camera])
        await service.reconcile(cameras: [camera])
        await service.reconcile(cameras: [camera])
        #expect(await service.subscriptionCount() == 1)
        #expect(await service.counters().monitorsStarted == 1)
        #expect(await eventWaitUntil { await h.store.totalRecordCount() == 1 })
        // Let any second pump that should not exist have every chance to deliver a copy.
        for _ in 0..<200 { await Task.yield() }
        #expect(await service.counters().alertsForwarded == 1)
        #expect(await h.store.recent(cameraID: camera.id).first?.count == 1)
        await service.stopAll()
    }

    /// A camera leaving the library tears its subscription down: no monitor, no task, no entry.
    @Test func eventMonitorServiceRemovesASubscriptionWithoutLeaking() async {
        let h = EventServiceHarness()
        let camera = eventTestCamera()
        let requests = EventScriptedRequests(script: [.bytes([EventMultipartFixture.closing()])])
        let monitor = h.monitor(requests)
        let service = h.service(policy: EventServiceHarness.fastPolicy()) { _ in monitor }

        await service.reconcile(cameras: [camera])
        #expect(await service.subscriptionCount() == 1)
        await service.reconcile(cameras: [])
        #expect(await service.subscriptionCount() == 0)
        #expect(await service.activeSupervisorCount() == 0)
        #expect(await service.counters().monitorsStopped == 1)
    }

    /// A disabled camera is not subscribed at all.
    @Test func eventMonitorServiceIgnoresDisabledCameras() async {
        let h = EventServiceHarness()
        let requests = EventScriptedRequests(script: [.bytes([EventMultipartFixture.closing()])])
        let monitor = h.monitor(requests)
        let service = h.service(policy: EventServiceHarness.fastPolicy()) { _ in monitor }
        await service.reconcile(cameras: [eventTestCamera(enabled: false)])
        #expect(await service.subscriptionCount() == 0)
    }

    /// Cameras on different hosts get their own subscriptions; cameras on one host share one.
    @Test func eventMonitorServiceGroupsCamerasByDevice() async {
        let h = EventServiceHarness()
        let service = h.service(policy: EventServiceHarness.fastPolicy()) { _ in nil }
        await service.reconcile(cameras: [eventTestCamera(host: "192.168.1.10", channel: 1),
                                          eventTestCamera(host: "192.168.1.10", channel: 2),
                                          eventTestCamera(host: "192.168.1.11", channel: 1)])
        #expect(await service.subscriptionCount() == 2)
        let key = EventDeviceKey(host: "192.168.1.10", port: 80, useTLS: false)
        #expect(await service.cameras(on: key).count == 2)
        await service.stopAll()
    }

    /// Host case must not split one device into two subscriptions.
    @Test func eventMonitorServiceDeviceKeyIsCaseInsensitive() {
        let upper = EventDeviceKey(host: "CAM-1.local", port: 80, useTLS: false)
        let lower = EventDeviceKey(host: "cam-1.local", port: 80, useTLS: false)
        #expect(upper == lower)
        #expect(upper.description == "cam-1.local:80")
        // The key is what gets logged; it must never carry a credential.
        #expect(!upper.description.contains("@"))
    }

    /// The device ceiling: beyond it devices are refused deterministically, and the refusal is
    /// reported rather than silent.
    @Test func eventMonitorServiceBoundsTheNumberOfSubscriptions() async {
        let h = EventServiceHarness()
        let service = h.service(policy: EventServiceHarness.fastPolicy(maxDevices: 2)) { _ in nil }
        let cameras = (1...5).map { eventTestCamera(host: "192.168.1.\($0)") }
        await service.reconcile(cameras: cameras)
        #expect(await service.subscriptionCount() == 2)
        #expect(await service.counters().devicesRefusedOverCapacity == 3)
        // Deterministic: the two lowest `host:port` strings win.
        let keys = Set(await service.deviceStates().keys.map(\.host))
        #expect(keys == Set(["192.168.1.1", "192.168.1.2"]))
        await service.stopAll()
    }

    /// A monitor that cannot be built yet — no credential — is retried on the ladder, not abandoned.
    @Test func eventMonitorServiceRetriesWhenTheMonitorCannotBeBuilt() async {
        let h = EventServiceHarness()
        let camera = eventTestCamera()
        let requests = EventScriptedRequests(script: [
            .bytes([EventMultipartFixture.part(eventType: "VMD", channel: 1,
                                               state: "active", count: 1),
                    EventMultipartFixture.closing()]),
        ])
        let script = EventFactoryScript(nilAnswers: 2, monitor: h.monitor(requests))
        let service = h.service(policy: EventServiceHarness.fastPolicy()) { _ in script.next() }

        await service.reconcile(cameras: [camera])
        #expect(await eventWaitUntil { await h.store.totalRecordCount() == 1 })
        #expect(await service.counters().monitorBuildFailures == 2)
        #expect(script.callCount >= 3)
        await service.stopAll()
    }

    /// A device that answers 403/404/405 is re-probed a bounded number of times and then believed.
    /// The budget is what lets a rebooting camera come back; the bound is what stops a hot loop.
    @Test func eventMonitorServiceReprobesAnUnsupportedDeviceThenGivesUp() async {
        let h = EventServiceHarness()
        let camera = eventTestCamera()
        let requests = EventScriptedRequests(
            script: [],
            whenExhausted: .notSupported(resource: "/Event/notification/alertStream"))
        let monitor = h.monitor(requests)
        let service = h.service(policy: EventServiceHarness.fastPolicy(reprobes: 2)) { _ in monitor }

        await service.reconcile(cameras: [camera])
        #expect(await eventWaitUntil { await service.counters().terminalUnsupported == 1 })
        #expect(await service.deviceStates().values.contains(.notSupported))
        #expect(await service.counters().restartsScheduled == 2)
        #expect(await service.activeSupervisorCount() == 0)
        // The entry stays, so a later reconcile does not cheerfully start over.
        await service.reconcile(cameras: [camera])
        #expect(await service.counters().monitorsStarted == 1)
        await service.stopAll()
    }

    /// A second 401 is terminal and is NEVER retried automatically: a wrong password on a ladder is
    /// how an account gets locked out. Only a new credential re-arms it.
    @Test func eventMonitorServiceNeverRetriesAuthFailureUntilCredentialsChange() async {
        let h = EventServiceHarness()
        let camera = eventTestCamera()
        let requests = EventScriptedRequests(
            script: [], whenExhausted: .authenticationFailed(username: "admin"))
        let monitor = h.monitor(requests)
        let service = h.service(policy: EventServiceHarness.fastPolicy()) { _ in monitor }

        await service.reconcile(cameras: [camera])
        #expect(await eventWaitUntil { await service.counters().terminalAuthFailed == 1 })
        #expect(await service.counters().restartsScheduled == 0)
        #expect(await service.deviceStates().values.contains(.authFailed))

        let key = EventDeviceKey(camera: camera)
        await service.credentialsChanged(for: key)
        #expect(await service.counters().monitorsStarted == 2)
        await service.stopAll()
    }

    /// A camera that goes offline and comes back: the first connection fails transiently, the
    /// monitor's own ladder reconnects, and the event from the second connection is stored exactly
    /// once. No service-level restart was needed, and nothing was duplicated.
    @Test func eventMonitorServiceSurvivesACameraGoingOfflineAndComingBack() async {
        let h = EventServiceHarness()
        let camera = eventTestCamera()
        let requests = EventScriptedRequests(script: [
            .failure(.streamEnded(afterBytes: 0)),
            .bytes([EventMultipartFixture.part(eventType: "fielddetection", channel: 1,
                                               state: "active", count: 1),
                    EventMultipartFixture.closing()]),
        ])
        let monitor = h.monitor(requests)
        let service = h.service(policy: EventServiceHarness.fastPolicy()) { _ in monitor }

        await service.reconcile(cameras: [camera])
        #expect(await eventWaitUntil { await h.store.totalRecordCount() == 1 })
        #expect(await h.store.recent(cameraID: camera.id).first?.kind == .intrusion)
        #expect(await service.counters().alertsForwarded == 1)
        #expect(requests.openCount >= 2)
        await service.stopAll()
    }

    /// `stopAll` leaves nothing running, which is what app sleep needs.
    @Test func eventMonitorServiceStopAllReleasesEverything() async {
        let h = EventServiceHarness()
        let requests = EventScriptedRequests(script: [.bytes([EventMultipartFixture.closing()])])
        let monitor = h.monitor(requests)
        let service = h.service(policy: EventServiceHarness.fastPolicy()) { _ in monitor }
        await service.reconcile(cameras: [eventTestCamera(host: "192.168.1.5"),
                                          eventTestCamera(host: "192.168.1.6")])
        #expect(await service.subscriptionCount() == 2)
        await service.stopAll()
        #expect(await service.subscriptionCount() == 0)
        #expect(await service.activeSupervisorCount() == 0)
        #expect(await service.counters().monitorsStopped == 2)
    }

    /// Repeated announcements arriving over the wire — the real reason this subsystem exists —
    /// collapse into one row with a duration, not thirty.
    @Test func eventMonitorServiceCollapsesARepeatedWireAlarmIntoOneRow() async {
        let h = EventServiceHarness()
        let camera = eventTestCamera()
        var parts: [Data] = []
        for tick in 1...30 {
            // The device re-announces every second with a climbing count, exactly as §14.3 describes.
            let second = String(format: "%02d", tick % 60)
            parts.append(EventMultipartFixture.part(
                eventType: "VMD", channel: 1, state: "active", count: tick,
                dateTime: "2024-05-01T12:35:\(second)+08:00"))
        }
        parts.append(EventMultipartFixture.closing())
        let requests = EventScriptedRequests(script: [.bytes(parts)])
        let monitor = h.monitor(requests)
        let service = h.service(policy: EventServiceHarness.fastPolicy()) { _ in monitor }

        await service.reconcile(cameras: [camera])
        // ⚠️ Waits on the ROW, not on `alertsForwarded`. The counter is incremented before the
        // store write — deliberately, see the note in `EventMonitorService.handle(_:key:generation:)`
        // — so "30 forwarded" is true while the last few are still going in. This test used to gate
        // on the counter and then read the store, and on a loaded CI runner it read a store five
        // ingests behind: `recordCount` was still 0 and the row's count was 25. Every other test in
        // this file already waits on the store; this one is now consistent with them.
        #expect(await eventWaitUntil { await h.store.recent(cameraID: camera.id).first?.count == 30 })
        #expect(await h.store.recordCount(cameraID: camera.id) == 1)
        let record = await h.store.recent(cameraID: camera.id).first
        #expect(record?.count == 30)
        #expect(record?.isActive == true)
        #expect(await eventWaitUntil { await service.counters().alertsForwarded == 30 })
        await service.stopAll()
    }

    /// The device's heartbeat never becomes a row, even though it travels the same stream.
    @Test func eventMonitorServiceDropsHeartbeatsFromTheWire() async {
        let h = EventServiceHarness()
        let camera = eventTestCamera()
        let requests = EventScriptedRequests(script: [
            .bytes([EventMultipartFixture.part(eventType: "videoloss", channel: 1,
                                               state: "inactive", count: 0),
                    EventMultipartFixture.part(eventType: "videoloss", channel: 1,
                                               state: "inactive", count: 0),
                    EventMultipartFixture.closing()]),
        ])
        let monitor = h.monitor(requests)
        let service = h.service(policy: EventServiceHarness.fastPolicy()) { _ in monitor }

        await service.reconcile(cameras: [camera])
        #expect(await eventWaitUntil { await service.counters().terminalUnsupported == 1 })
        #expect(await h.store.totalRecordCount() == 0)
        // Suppressed by the monitor before the service ever sees them.
        #expect(await service.counters().alertsForwarded == 0)
        await service.stopAll()
    }
}

#endif
