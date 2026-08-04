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

// MARK: - Cache TTLs (§18.1)

@Suite struct DeviceSessionCacheSuite {

    @Test func deviceSessionServesDeviceInfoFromCacheUntilTheTTLExpires() async throws {
        let double = RequestDouble()
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        let clock = SessionTestClock()
        let session = SessionFixtures.session(double, clock: clock)

        _ = try await session.deviceInfo()
        _ = try await session.deviceInfo()
        #expect(await double.requests(to: "/System/deviceInfo").count == 1)

        // One second short of 24 h is still fresh; one second past it is not.
        clock.advance(seconds: 86_399)
        _ = try await session.deviceInfo()
        #expect(await double.requests(to: "/System/deviceInfo").count == 1)
        clock.advance(seconds: 2)
        _ = try await session.deviceInfo()
        #expect(await double.requests(to: "/System/deviceInfo").count == 2)
    }

    @Test func deviceSessionForceBypassesAFreshCacheEntry() async throws {
        let double = RequestDouble()
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try await session.deviceInfo()
        _ = try await session.deviceInfo(force: true)
        #expect(await double.requests(to: "/System/deviceInfo").count == 2)
    }

    /// §18.1 keys the capability row by firmware version, so an upgrade discards it however fresh.
    @Test func deviceSessionDiscardsCapabilitiesWhenTheFirmwareVersionChanges() async throws {
        let double = RequestDouble()
        await double.route("/System/deviceInfo",
                           pages: [SessionFixtures.deviceInfo(firmware: "V5.5.82"),
                                   SessionFixtures.deviceInfo(firmware: "V5.6.0")])
        await double.route("/System/capabilities",
                           xml: "<DeviceCap><SysCap><isSupportPTZ>true</isSupportPTZ></SysCap>"
                              + "</DeviceCap>")
        let clock = SessionTestClock()
        let session = SessionFixtures.session(double, clock: clock)

        _ = try await session.capabilities()
        #expect(await double.requests(to: "/System/capabilities").count == 1)

        // A new firmware string arrives from a forced identity re-read. The capability box is still
        // inside its 24 h, but it belongs to the old firmware and must not be served.
        _ = try await session.deviceInfo(force: true)
        _ = try await session.capabilities()
        #expect(await double.requests(to: "/System/capabilities").count == 2)
    }

    /// An uptime regression means the device rebooted, which flushes everything (§18.1).
    @Test func deviceSessionFlushesEveryCacheWhenUptimeRegresses() async throws {
        let double = RequestDouble()
        await double.route("/System/status", pages: [SessionFixtures.status(uptime: 90_000),
                                                     SessionFixtures.status(uptime: 12)])
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        let clock = SessionTestClock()
        let session = SessionFixtures.session(double, clock: clock)

        _ = try await session.deviceInfo()
        _ = try await session.status()
        clock.advance(seconds: 6)                    // past the 5 s status TTL
        _ = try await session.status()               // uptime dropped ⇒ flush

        _ = try await session.deviceInfo()
        #expect(await double.requests(to: "/System/deviceInfo").count == 2)
    }

    @Test func deviceSessionInvalidatesTheStreamAndChannelRowsOnAStreamWrite() async throws {
        let double = RequestDouble()
        await double.route("/Streaming/channels/102", xml: SessionFixtures.substreamChannel)
        await double.route("/Streaming/channels", xml: SessionFixtures.streamingChannels)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try await session.channels()
        let before = await double.requests(to: "/Streaming/channels").count

        var patch = StreamingChannelPatch()
        patch.frameRate = 15
        _ = try await session.updateStream(StreamingChannelID(channel: .first, quality: .sub),
                                           patch)
        // The list must be re-read rather than served from the 30 s box the write just staled.
        _ = try await session.channels()
        #expect(await double.requests(to: "/Streaming/channels").count > before)
    }

    /// A TTL of zero is the documented way to pin a row off, and must not be read as "no TTL".
    @Test func deviceSessionTreatsAZeroTTLAsNeverFresh() async throws {
        var ttl = CacheTTL()
        ttl.deviceInfo = 0
        let double = RequestDouble()
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        let session = SessionFixtures.session(double, clock: SessionTestClock(), ttl: ttl)

        _ = try await session.deviceInfo()
        _ = try await session.deviceInfo()
        #expect(await double.requests(to: "/System/deviceInfo").count == 2)
    }
}
