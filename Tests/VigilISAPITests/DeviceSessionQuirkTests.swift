//
//  DeviceSessionTests.swift
//  VigilISAPITests
//
//  The device session: the TTL table, the negative-capability cache, the read-modify-write-then-
//  re-GET discipline, the four quirk consultation points, and the ten-step connect sequence.
//  Covers docs/spec-isapi.md §17.1, §18.1, §18.2, §18.3 and §19.
//
//  Every test drives a `RequestDouble`, so what is asserted is the exact traffic the session would
//  have put on the wire and the exact bytes of every body — not a mock's expectation of them.
//  Nothing here waits: freshness is driven by `SessionTestClock.advance(by:)` and the wall clock is
//  frozen, so a TTL boundary is asserted at the boundary rather than near it.
//
//  Fixtures are hand-written from the samples in docs/spec-isapi.md §10, §11, §15 and §17.2. Where a
//  value is not in the spec it is synthesised and says so — none of it came from real hardware.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilISAPI

// MARK: - The four quirk consultation points (§19)

@Suite struct DeviceSessionQuirkSuite {

    /// Point 1, path builder: the list form of proxied-channel status 404s on DS-76xx/77xx, and the
    /// first refusal switches the session to the per-channel form for good.
    @Test func deviceSessionFallsBackToPerChannelProxyStatusAfterTheListForm404s() async throws {
        let double = RequestDouble()
        await double.route("/InputProxy/channels/status",
                           failing: .notFound(resource: "/InputProxy/channels/status"))
        await double.route("/InputProxy/channels", xml: """
            <InputProxyChannelList><InputProxyChannel><id>1</id>
            <sourceInputPortDescriptor><ipAddress>10.0.0.65</ipAddress>
            </sourceInputPortDescriptor></InputProxyChannel></InputProxyChannelList>
            """)
        await double.route("/Streaming/channels", xml: SessionFixtures.streamingChannels)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try await session.channels(force: true)
        #expect(await session.observedQuirks.inputProxyStatusListUnsupported)

        // The second inventory read must not try the list form again.
        let listCallsBefore = await double.requests(to: "/InputProxy/channels/status").count
        _ = try await session.channels(force: true)
        #expect(await double.requests(to: "/InputProxy/channels/status").count == listCallsBefore)
    }

    /// Point 1, path builder: the daily-distribution resource moved between firmwares, and the one
    /// that answered is remembered so the month view costs one request rather than two.
    @Test func deviceSessionRemembersWhichDailyDistributionResourceAnswered() async throws {
        let double = RequestDouble()
        await double.route("/record/tracks/dailyDistribution",
                           failing: .notFound(resource: "/record/tracks/dailyDistribution"))
        await double.route("/search/dailyDistribution", xml: SessionFixtures.dailyDistribution)
        let clock = SessionTestClock()
        let session = SessionFixtures.session(double, clock: clock)

        let first = try await session.monthCalendar(track: TrackID(101), year: 2024, month: 5)
        #expect(first.days[0] != nil)
        #expect(await session.observedQuirks.dailyDistributionPath == "/ContentMgmt/search/dailyDistribution")

        clock.advance(seconds: 601)   // past the 10 min month-calendar TTL
        _ = try await session.monthCalendar(track: TrackID(101), year: 2024, month: 5)
        // The refused spelling was tried exactly once, ever.
        #expect(await double.requests(to: "/record/tracks/dailyDistribution").count == 1)
    }

    /// A device with no accelerator at all yields an all-`nil` calendar and no error: `nil` means
    /// "unknown", the date picker fills days in lazily, and an error would banner a working view.
    @Test func deviceSessionReturnsAnUnknownMonthRatherThanFailingWithoutTheAccelerator() async throws {
        let double = RequestDouble()
        await double.route("/dailyDistribution",
                           failing: .notSupported(resource: "/dailyDistribution"))
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let calendar = try await session.monthCalendar(track: TrackID(101), year: 2024, month: 5)
        #expect(calendar.days.allSatisfy { $0 == nil })
    }

    /// Point 1, path builder: the event-schedule resource has two spellings too.
    @Test func deviceSessionRemembersWhichEventScheduleResourceAnswered() async throws {
        let double = RequestDouble()
        await double.route("/Event/schedules/VMD-1", failing: .notFound(resource: "/Event/schedules/VMD-1"))
        await double.route("/Event/schedules", xml: """
            <EventSchedule><TimeBlockList><TimeBlock><dayOfWeek>1</dayOfWeek>
            <TimeRange><beginTime>00:00:00</beginTime><endTime>24:00:00</endTime></TimeRange>
            </TimeBlock></TimeBlockList></EventSchedule>
            """)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        #expect(try await session.eventSchedule(triggerID: "VMD-1") != nil)
        #expect(await session.observedQuirks.eventSchedulePath == "/Event/schedules")
    }

    /// Point 2, body builder: the record-type filter is dropped for good once refused, and the same
    /// search is retried unfiltered so the user still gets their timeline.
    @Test func deviceSessionRetriesARecordingSearchWithoutTheTypeFilterOnceRefused() async throws {
        let double = RequestDouble()
        await double.route("/ContentMgmt/search",
                           pages: [SessionFixtures.searchResult()])
        await double.route("/System/time", xml: SessionFixtures.deviceTime)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        // First: prove the filter *is* sent when nothing has refused it.
        var query = RecordSearchQuery(track: TrackID(101),
                                      start: Date(timeIntervalSince1970: 1_714_550_400),
                                      end: Date(timeIntervalSince1970: 1_714_636_800))
        query.recordTypes = [.motion]
        _ = try await session.searchRecordings(query)
        let filteredBody = try #require(await double.requests(to: "/ContentMgmt/search").first?.bodyText)
        #expect(filteredBody.contains("\(CMSearchDescription.allRecordTypes)/motion"))

        // Now teach it the refusal and prove the retry drops the filter.
        await session.learn(.recordTypeFilterRejected)
        #expect(await session.observedQuirks.recordTypeFilterUnsupported)
        let before = await double.requests(to: "/ContentMgmt/search").count
        _ = try await session.searchRecordings(query)
        let retried = await double.requests(to: "/ContentMgmt/search")
        #expect(retried.count == before + 1)
        let unfiltered = try #require(retried.last?.bodyText)
        #expect(!unfiltered.contains("\(CMSearchDescription.allRecordTypes)/motion"))
        #expect(unfiltered.contains(
            "<metadataDescriptor>\(CMSearchDescription.allRecordTypes)</metadataDescriptor>"))
    }

    /// Point 2, body builder: a `<Sharpness>` with no level element is the one case where the casing
    /// has to come from the quirk row rather than from the device's own document.
    @Test func deviceSessionWritesTheQuirkSharpnessCasingWhenTheElementIsAbsent() async throws {
        for capitalized in [true, false] {
            let double = RequestDouble()
            await double.route("/sharpness", xml: SessionFixtures.sharpnessWithoutLevel)
            var quirks = DeviceQuirks()
            quirks.sharpnessElementIsCapitalized = capitalized
            let session = SessionFixtures.session(double, clock: SessionTestClock(), quirks: quirks)

            _ = try await session.setSharpness(channel: .first, 80)
            let put = try #require(await double.requests(to: "/sharpness")
                                        .first { $0.method == "PUT" }?.bodyText)
            let expected = capitalized ? "<SharpnessLevel>80</SharpnessLevel>"
                                       : "<sharpnessLevel>80</sharpnessLevel>"
            #expect(put.contains(expected))
            // The element the device did send survives either way.
            #expect(put.contains("<enabled>true</enabled>"))
        }
    }

    /// Point 3, response interpretation: several DVRs read `starttime` as device-local despite the
    /// `Z`, so the window goes out shifted and the answers come back shifted the other way.
    @Test func deviceSessionShiftsThePlaybackWindowForDeviceLocalFirmware() async throws {
        let double = RequestDouble()
        await double.route("/ContentMgmt/search", xml: SessionFixtures.searchResult())
        await double.route("/System/time", xml: SessionFixtures.deviceTime)   // UTC+8
        var quirks = DeviceQuirks()
        quirks.playbackTimesAreDeviceLocal = true
        let session = SessionFixtures.session(double, clock: SessionTestClock(), quirks: quirks)

        let start = Date(timeIntervalSince1970: 1_714_550_400)   // 2024-05-01T08:00:00Z
        let segments = try await session.searchRecordings(
            RecordSearchQuery(track: TrackID(101), start: start,
                              end: start.addingTimeInterval(3_600)))
        // Out: the request carries the window shifted forward by the device's +8 h offset, so the
        // device's own local reading lands on the instant the user asked for.
        let body = try #require(await double.requests(to: "/ContentMgmt/search").first?.bodyText)
        #expect(body.contains("2024-05-01T16:00:00Z"))
        // Back: the echoed device-local times are shifted back before anything compares them.
        let segment = try #require(segments.first)
        #expect(segment.start == Date(timeIntervalSince1970: 1_714_525_200))   // 09:00Z −8 h = 01:00Z
    }

    /// Point 4, the request gate: three `deviceBusy` answers inside ten seconds drop the device to
    /// two concurrent control requests, and the gate is told immediately.
    @Test func deviceSessionPushesTheConcurrencyOverrideAtTheGateAfterThreeBusyAnswers() async throws {
        let double = RequestDouble()
        await double.route("/System/status", failing: .deviceBusy)
        let gate = SessionGateDouble()
        let clock = SessionTestClock()
        let session = SessionFixtures.session(double, clock: clock, gate: gate)

        for _ in 0..<3 {
            _ = try? await session.status()
            clock.advance(seconds: 1)
        }
        #expect(await session.observedQuirks.maxConcurrentRequestsOverride == 2)
        let applied = await gate.applied
        #expect(applied.last?.maxConcurrentRequestsOverride == 2)
        // One push, not three: `observe` reports "changed" only for the observation that changed it.
        #expect(applied.count == 1)
    }

    /// The record describes the firmware, not the session, so a cache flush must not discard it —
    /// re-learning it costs the user real round trips.
    @Test func deviceSessionKeepsTheQuirkRecordAcrossACacheInvalidation() async throws {
        let double = RequestDouble()
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        await session.learn(.streamingChannelIDRejected)
        await session.invalidateCaches()
        #expect(await session.observedQuirks.streamingChannelIDIsSingleDigit)
    }

    /// The `position3D` Y origin cannot be read or seeded; the §13.5 calibration is its only source.
    @Test func deviceSessionLearnsThePosition3DOriginFromACalibration() async throws {
        let session = SessionFixtures.session(RequestDouble(), clock: SessionTestClock())

        #expect(await session.position3DOriginIsTopLeft == false)
        await session.calibratePosition3DOrigin(topLeft: true)
        #expect(await session.position3DOriginIsTopLeft)
        #expect(await session.observedQuirks.ptz3DOriginIsTopLeft == true)
    }
}
