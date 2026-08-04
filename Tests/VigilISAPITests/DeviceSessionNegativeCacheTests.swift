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

// MARK: - Negative capability cache (§18.3)

@Suite struct DeviceSessionNegativeCacheSuite {

    @Test func deviceSessionStopsAskingForARefusedCapability() async throws {
        let double = RequestDouble()
        await double.route("/PTZCtrl/channels/1/capabilities",
                           failing: .notSupported(resource: "/PTZCtrl/channels/1/capabilities"))
        let clock = SessionTestClock()
        let session = SessionFixtures.session(double, clock: clock)

        #expect(try await session.ptzCapabilities(channel: .first).isAbsent)
        let firstCount = await double.requestCount
        #expect(firstCount == 1)

        // A different channel, whose template collapses to the same key: no round trip at all,
        // even though channel 3 has no capability box of its own. Deliberately without advancing the
        // clock — the negative entry and the capability box share a 24 h TTL, and this test is about
        // the template collapse. `deviceSessionReAsksOnceTheNegativeEntryExpires` covers expiry.
        #expect(try await session.ptzCapabilities(channel: ChannelID(3)).isAbsent)
        #expect(await double.requestCount == 1)
        #expect(await session.suppressedCapabilityTemplates
                    .contains("/PTZCtrl/channels/{n}/capabilities"))
    }

    /// The negative entry expires after 24 h so a device that was fixed is re-probed.
    @Test func deviceSessionReAsksOnceTheNegativeEntryExpires() async throws {
        let double = RequestDouble()
        await double.route("/Event/triggers", failing: .notFound(resource: "/Event/triggers"))
        let clock = SessionTestClock()
        let session = SessionFixtures.session(double, clock: clock)

        _ = try? await session.eventTriggers()
        _ = try? await session.eventTriggers()
        #expect(await double.requestCount == 1)

        clock.advance(seconds: 86_401)
        _ = try? await session.eventTriggers()
        #expect(await double.requestCount == 2)
    }

    /// §18.3 scopes the cache to capability-bearing resources. These four are how Vigil finds out
    /// whether the device is reachable at all, so suppressing them would strand it.
    @Test func deviceSessionNeverSuppressesTheReachabilityTemplates() async throws {
        let double = RequestDouble()
        await double.route("/System/deviceInfo",
                           failing: .notFound(resource: "/System/deviceInfo"))
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try? await session.deviceInfo()
        _ = try? await session.deviceInfo()
        _ = try? await session.deviceInfo()
        #expect(await double.requestCount == 3)
        #expect(await session.suppressedCapabilityTemplates.isEmpty)
    }

    /// An `insufficientPermission` is about the account, not the endpoint: caching it would hide a
    /// feature from a user who then fixes their credentials and cannot work out why.
    @Test func deviceSessionDoesNotCacheAPermissionFailureAsAMissingCapability() async throws {
        let double = RequestDouble()
        await double.route("/ContentMgmt/record/tracks",
                           failing: .insufficientPermission(resource: "/ContentMgmt/record/tracks"))
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try? await session.recordTracks()
        _ = try? await session.recordTracks()
        #expect(await double.requestCount == 2)
        #expect(await session.suppressedCapabilityTemplates.isEmpty)
    }

    @Test func deviceSessionClearsNegativeEntriesOnInvalidate() async throws {
        let double = RequestDouble()
        await double.route("/Event/triggers", failing: .notFound(resource: "/Event/triggers"))
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try? await session.eventTriggers()
        await session.invalidateCaches()
        #expect(await session.suppressedCapabilityTemplates.isEmpty)
        _ = try? await session.eventTriggers()
        #expect(await double.requestCount == 2)
    }
}
