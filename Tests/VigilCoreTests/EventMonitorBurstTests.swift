//
//  EventMonitorBurstTests.swift
//  VigilCoreTests
//
//  The two burst-delivery event tests, on a monitor driven by EventBlockingClock. See §0.4.
//
//  ⛔ WHY THESE LIVE HERE rather than in EventMonitorServiceTests. The originals
//  (eventMonitorServiceCollapsesARepeatedWireAlarmIntoOneRow and
//  eventMonitorServiceDemultiplexesChannelsOnOneSubscription) stalled ~470-517 s and lost every alert
//  after the first, because the shared EventTestClock advances every sleep instantly — which collapses
//  the alert monitor's 60 s idle watchdog to zero, so on a multi-part connection the watchdog wins the
//  race against the read loop during the first alert's delivery and cancels the stream. A real 60 s
//  watchdog cannot fire inside a sub-second burst, so hardware never loses them: it was a harness
//  artifact. The fix is to give the *monitor* a clock whose sleep suspends until cancelled, so the
//  watchdog never fires. The originals stay in place but skipped (macos.yml, coverage.sh); moving the
//  fixed versions here rather than editing them in place avoids reformatting that whole legacy file
//  under the current swift-format config.
//

#if os(macOS)

import Foundation
import Testing
import VigilCore
import VigilISAPI
import VigilProtocols

// MARK: - EventBurstHarness

/// Clocks, a store, and a service wired to a scripted device — a sibling of `EventServiceHarness`,
/// except the monitor runs on `EventBlockingClock`.
private struct EventBurstHarness {
    let clock = EventTestClock()
    let wall = EventTestWallClock()
    let ids = EventIDSequence()
    let store: EventStore

    init(bounds: EventBounds = EventBounds()) {
        let sequence = ids
        store = EventStore(
            bounds: bounds, clock: clock, wallClock: wall,
            makeID: { sequence.next() })
    }

    /// The monitor runs on `EventBlockingClock`, not the store/service's auto-advancing
    /// `EventTestClock`, so its idle watchdog cannot fire on an instant sleep and cancel a multi-part
    /// connection mid-burst (§0.4). Coalescing windows and backoff assertions keep the real clock.
    func monitor(_ requests: EventScriptedRequests) -> AlertStreamMonitor {
        AlertStreamMonitor(
            requests: requests, clock: EventBlockingClock(), wallClock: wall,
            random: SplitMix64RandomSource(seed: 7))
    }

    func service(
        policy: EventMonitorService.Policy = EventMonitorService.Policy(),
        snapshotSink: @escaping EventMonitorService.SnapshotSink = { _, _, _ in },
        makeMonitor: @escaping EventMonitorFactory
    ) -> EventMonitorService {
        EventMonitorService(
            store: store, policy: policy, clock: clock,
            random: SplitMix64RandomSource(seed: 11),
            snapshotSink: snapshotSink, makeMonitor: makeMonitor)
    }

    static func fastPolicy(maxDevices: Int = 32, reprobes: Int = 2) -> EventMonitorService.Policy {
        var policy = EventMonitorService.Policy()
        policy.maxDevices = maxDevices
        policy.maxUnsupportedReprobes = reprobes
        policy.restartBackoffSeconds = [0.001]
        return policy
    }
}

// MARK: - Tests

@Suite("EventMonitorService bursts")
struct EventMonitorBurstTests {

    /// One device, two cameras: ONE subscription, and each channel's events land on its own camera.
    /// A device-wide fault (channel 0) is filed against the lowest channel rather than dropped, and
    /// an unclaimed channel is counted, not guessed at. Supersedes the skipped
    /// `eventMonitorServiceDemultiplexesChannelsOnOneSubscription`.
    @Test func eventBurstDemultiplexesChannelsOnOneSubscription() async {
        let h = EventBurstHarness()
        let first = eventTestCamera(channel: 1)
        let second = eventTestCamera(channel: 2)
        let requests = EventScriptedRequests(script: [
            .bytes([
                EventMultipartFixture.part(
                    eventType: "VMD", channel: 1,
                    state: "active", count: 1),
                EventMultipartFixture.part(
                    eventType: "linedetection", channel: 2,
                    state: "active", count: 1),
                EventMultipartFixture.part(
                    eventType: "diskfull", channel: 0,
                    state: "active", count: 1),
                EventMultipartFixture.part(
                    eventType: "tamperdetection", channel: 9,
                    state: "active", count: 1),
                EventMultipartFixture.closing(),
            ])
        ])
        let monitor = h.monitor(requests)
        let service = h.service(policy: EventBurstHarness.fastPolicy()) { _ in monitor }

        await service.reconcile(cameras: [first, second])
        #expect(await service.subscriptionCount() == 1)
        let done = await eventWaitUntil { await service.counters().unattributedAlerts == 1 }
        #expect(done)
        _ = await eventWaitUntil { await h.store.recordCount(cameraID: first.id) == 2 }

        let firstRecords = await h.store.recent(cameraID: first.id)
        let secondRecords = await h.store.recent(cameraID: second.id)
        #expect(firstRecords.count == 2)  // channel 1 plus the device-wide fault
        #expect(firstRecords.contains { $0.kind == .diskFull && $0.isDeviceWide })
        #expect(secondRecords.count == 1)
        #expect(secondRecords.first?.kind == .lineCrossing)
        #expect(await service.counters().alertsForwarded == 3)
        await service.stopAll()
    }

    /// Repeated announcements arriving over the wire — the real reason this subsystem exists —
    /// collapse into one row with a duration, not thirty. Supersedes the skipped
    /// `eventMonitorServiceCollapsesARepeatedWireAlarmIntoOneRow`.
    @Test func eventBurstCollapsesThirtyRepeatsIntoOneRow() async {
        let h = EventBurstHarness()
        let camera = eventTestCamera()
        var parts: [Data] = []
        for tick in 1...30 {
            // The device re-announces every second with a climbing count, exactly as §14.3 describes.
            let second = String(format: "%02d", tick % 60)
            parts.append(
                EventMultipartFixture.part(
                    eventType: "VMD", channel: 1, state: "active", count: tick,
                    dateTime: "2024-05-01T12:35:\(second)+08:00"))
        }
        parts.append(EventMultipartFixture.closing())
        let requests = EventScriptedRequests(script: [.bytes(parts)])
        let monitor = h.monitor(requests)
        let service = h.service(policy: EventBurstHarness.fastPolicy()) { _ in monitor }

        await service.reconcile(cameras: [camera])
        // Waits on the ROW, not on `alertsForwarded`: the counter is incremented before the store
        // write, so every other test in this suite waits on the store and this one is consistent.
        #expect(await eventWaitUntil { await h.store.recent(cameraID: camera.id).first?.count == 30 })
        #expect(await h.store.recordCount(cameraID: camera.id) == 1)
        let record = await h.store.recent(cameraID: camera.id).first
        #expect(record?.count == 30)
        #expect(record?.isActive == true)
        #expect(await eventWaitUntil { await service.counters().alertsForwarded == 30 })
        await service.stopAll()
    }
}

#endif  // os(macOS)
