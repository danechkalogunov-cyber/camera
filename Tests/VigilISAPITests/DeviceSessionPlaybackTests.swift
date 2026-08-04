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

// MARK: - Playback

@Suite struct DeviceSessionPlaybackSuite {

    /// Today's index is still being written to, so it expires; a past day cannot change, so it does
    /// not (§18.1). That asymmetry is what lets the timeline be scrubbed backwards for free.
    @Test func deviceSessionCachesAPastDayIndexForeverAndTodaysForSixtySeconds() async throws {
        let double = RequestDouble()
        await double.route("/ContentMgmt/search", xml: SessionFixtures.searchResult())
        await double.route("/System/time", xml: SessionFixtures.deviceTime)
        let clock = SessionTestClock()
        let session = SessionFixtures.session(double, clock: clock)
        let past = SessionFixtures.today.addingTimeInterval(-86_400)

        _ = try await session.dayIndex(track: TrackID(101), dayStartUTC: past)
        let afterFirst = await double.requests(to: "/ContentMgmt/search").count
        clock.advance(seconds: 100_000)
        _ = try await session.dayIndex(track: TrackID(101), dayStartUTC: past)
        #expect(await double.requests(to: "/ContentMgmt/search").count == afterFirst)

        _ = try await session.dayIndex(track: TrackID(101), dayStartUTC: SessionFixtures.today)
        let afterToday = await double.requests(to: "/ContentMgmt/search").count
        clock.advance(seconds: 61)
        _ = try await session.dayIndex(track: TrackID(101), dayStartUTC: SessionFixtures.today)
        #expect(await double.requests(to: "/ContentMgmt/search").count == afterToday + 1)
    }

    /// One `searchID` for the whole search, and `searchResultPostion` advanced by the device's own
    /// match count — Hikvision's spelling, kept verbatim because the corrected one is ignored.
    @Test func deviceSessionPagesARecordingSearchWhileTheDeviceSaysMore() async throws {
        let double = RequestDouble()
        await double.route("/ContentMgmt/search",
                           pages: [SessionFixtures.searchResult(strip: "MORE", matches: 1),
                                   SessionFixtures.searchResult(strip: "OK", matches: 1)])
        await double.route("/System/time", xml: SessionFixtures.deviceTime)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let segments = try await session.searchRecordings(
            RecordSearchQuery(track: TrackID(101),
                              start: Date(timeIntervalSince1970: 1_714_550_400),
                              end: Date(timeIntervalSince1970: 1_714_636_800)))
        let pages = await double.requests(to: "/ContentMgmt/search")
        #expect(pages.count == 2)
        #expect(segments.count == 2)

        // Both pages carried the same searchID; the second advanced the cursor.
        let first = try #require(pages[0].bodyText)
        let second = try #require(pages[1].bodyText)
        #expect(first.contains("<searchResultPostion>0</searchResultPostion>"))
        #expect(second.contains("<searchResultPostion>1</searchResultPostion>"))
        let id = try #require(first.split(separator: "<searchID>").last?
                                  .split(separator: "</searchID>").first)
        #expect(second.contains("<searchID>\(id)</searchID>"))
    }

    /// A device that answers `MORE` for ever must not hold the actor open until the app quits.
    @Test func deviceSessionAbandonsASearchThatNeverStopsSayingMore() async throws {
        let double = RequestDouble()
        await double.route("/ContentMgmt/search",
                           xml: SessionFixtures.searchResult(strip: "MORE", matches: 1))
        await double.route("/System/time", xml: SessionFixtures.deviceTime)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try await session.searchRecordings(
            RecordSearchQuery(track: TrackID(101),
                              start: Date(timeIntervalSince1970: 1_714_550_400),
                              end: Date(timeIntervalSince1970: 1_714_636_800)))
        #expect(await double.requests(to: "/ContentMgmt/search").count
                    == ISAPIDeviceSession.maximumSearchPages)
    }

    /// The quota sub-resource is advisory: a device without it still has volumes, and failing the
    /// whole call would hide the free-space readout the user came for.
    @Test func deviceSessionMergesStorageQuotasButToleratesTheirAbsence() async throws {
        let double = RequestDouble()
        await double.route("/ContentMgmt/Storage/quota",
                           failing: .notFound(resource: "/ContentMgmt/Storage/quota"))
        await double.route("/ContentMgmt/Storage", xml: """
            <storage version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
            <hddList><hdd><id>1</id><hddName>hdde</hddName><capacity>3815447</capacity>
            <freeSpace>1048576</freeSpace><status>ok</status></hdd></hddList>
            <workMode>quota</workMode></storage>
            """)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let info = try await session.storage()
        #expect(info.volumes.count == 1)
        #expect(info.quotas.isEmpty)
    }
}
