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

// MARK: - Connect sequence (§18.2)

@Suite struct DeviceSessionConnectSuite {

    /// A route table for a healthy single-channel camera. Everything not listed is refused by the
    /// last route, which is how a real camera answers most of the optional steps.
    static func healthyCamera() async -> RequestDouble {
        let double = RequestDouble()
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        await double.route("/Security/userCheck", xml: SessionFixtures.userCheckOK)
        await double.route("/System/time", xml: SessionFixtures.deviceTime)
        await double.route("/System/capabilities", xml: """
            <DeviceCap version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
            <SysCap><isSupportPTZ>true</isSupportPTZ><isSupportTwoWayAudio>true\
            </isSupportTwoWayAudio></SysCap>
            <RacmCap><isSupportSearch>true</isSupportSearch></RacmCap>
            </DeviceCap>
            """)
        await double.route("/Streaming/channels", xml: SessionFixtures.streamingChannels)
        await double.route("/PTZCtrl/channels/1/capabilities", xml: SessionFixtures.ptzCapabilities)
        return double
    }

    @Test func connectSequenceEstablishesIdentityChannelsAndPTZ() async throws {
        let double = await Self.healthyCamera()
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let outcome = try await session.connect(startingAlertStream: false)
        #expect(outcome.identity.model == "DS-2CD2385FWD-I")
        #expect(outcome.credentials.ok)
        #expect(outcome.channels.count == 1)
        #expect(outcome.canStream)
        #expect(outcome.time?.utcOffsetSeconds == 28_800)
        #expect(outcome.ptzChannels == [.first])
        #expect(!outcome.degradations.contains(.ptzUnavailable))
        #expect(!outcome.exceededBudget)
    }

    /// Step 1 is the "is this even an ISAPI device" test, and its failure aborts the sequence
    /// before a single credential is sent anywhere else.
    @Test func connectSequenceAbortsWhenTheIdentityEndpointIsAbsent() async throws {
        let double = RequestDouble()
        await double.route("/System/deviceInfo",
                           failing: .notFound(resource: "/System/deviceInfo"))
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        await #expect(throws: ISAPIError.self) { _ = try await session.connect() }
        #expect(await double.requests(to: "/Security/userCheck").isEmpty)
    }

    /// Step 2 aborts on a lock, and the one thing the caller must not do is retry — each retry
    /// extends the lock-out. Throwing rather than returning is what makes that hard to get wrong.
    @Test func connectSequenceAbortsOnALockedAccountWithoutProbingAnything() async throws {
        let double = RequestDouble()
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        await double.route("/Security/userCheck", xml: SessionFixtures.userCheckLocked)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        await #expect(throws: ISAPIError.accountLocked(retryAfter: 300)) {
            _ = try await session.connect()
        }
        #expect(await double.requests(to: "/System/capabilities").isEmpty)
        #expect(await double.requests(to: "/Streaming/channels").isEmpty)
    }

    /// Step 4's failure is fatal for streaming but not for the connection: channel 1 is synthesised,
    /// because an empty camera list is a worse answer than an optimistic one that fails visibly.
    @Test func connectSequenceSynthesisesChannelOneWhenTheStreamListFails() async throws {
        let double = RequestDouble()
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        await double.route("/Security/userCheck", xml: SessionFixtures.userCheckOK)
        await double.route("/Streaming/channels",
                           failing: .notFound(resource: "/Streaming/channels"))
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let outcome = try await session.connect(startingAlertStream: false)
        #expect(outcome.channels.count == 1)
        #expect(outcome.channels[0].channel == .first)
        #expect(outcome.degradations.contains(.channelListSynthesised))
        #expect(outcome.canStream)
    }

    /// Step 3's failure is not an error: the family defaults stand in and step 7 settles the rest.
    @Test func connectSequenceFallsBackToFamilyDefaultsWhenCapabilitiesAreAbsent() async throws {
        let double = RequestDouble()
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        await double.route("/Security/userCheck", xml: SessionFixtures.userCheckOK)
        await double.route("/System/capabilities",
                           failing: .notFound(resource: "/System/capabilities"))
        await double.route("/Streaming/channels", xml: SessionFixtures.streamingChannels)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let outcome = try await session.connect(startingAlertStream: false)
        #expect(outcome.capabilities.videoInputChannels >= 1)
        // `capabilities()` absorbs its own failure into the family defaults, so the sequence sees a
        // usable record and the degradation that matters is the one the probes could not settle.
        #expect(!outcome.degradations.contains(.budgetExceeded))
    }

    /// Step 7 probes only the rows `/System/capabilities` left unresolved — probing a row the device
    /// already answered is a wasted round trip on hardware whose ceiling is three of them.
    @Test func connectSequenceProbesOnlyTheUnresolvedCapabilityRows() async throws {
        let double = await Self.healthyCamera()
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let outcome = try await session.connect(startingAlertStream: false)
        // `isSupportPTZ` was in the document, so no functional probe was needed for it beyond the
        // per-channel capability read step 8 does anyway.
        #expect(outcome.capabilities.supportsPTZ)
        #expect(!outcome.capabilities.unresolved.contains(.supportsPTZ))
        // A row the document did not mention and that has a probe is now resolved either way.
        #expect(!outcome.capabilities.unresolved.contains(.supportsImageColor))
        // A row that cannot be probed at all stays honest about not being known.
        #expect(outcome.capabilities.unresolved.contains(.supportsHTTPS))
    }

    /// A refusal during a probe resolves the row `false` *and* lands in the negative cache, so the
    /// feature behind it costs no round trip for the next 24 h.
    @Test func connectSequenceRecordsProbeRefusalsInTheNegativeCache() async throws {
        let double = await Self.healthyCamera()
        await double.route("/Image/channels/1/color",
                           failing: .notSupported(resource: "/Image/channels/1/color"))
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let outcome = try await session.connect(startingAlertStream: false)
        #expect(outcome.capabilities.supportsImageColor == false)
        #expect(await session.suppressedCapabilityTemplates.contains("/Image/channels/{n}/color"))
    }

    @Test func connectSequenceReportsPTZUnavailableWhenNoChannelHasIt() async throws {
        let double = RequestDouble()
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        await double.route("/Security/userCheck", xml: SessionFixtures.userCheckOK)
        await double.route("/Streaming/channels", xml: SessionFixtures.streamingChannels)
        await double.route("/PTZCtrl/channels/1/capabilities",
                           failing: .notSupported(resource: "/PTZCtrl/channels/1/capabilities"))
        await double.route("/PTZCtrl/channels",
                           failing: .notSupported(resource: "/PTZCtrl/channels"))
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let outcome = try await session.connect(startingAlertStream: false)
        #expect(outcome.ptzChannels.isEmpty)
        #expect(outcome.degradations.contains(.ptzUnavailable))
        // The connection itself is fine — a fixed camera is still a camera.
        #expect(outcome.canStream)
    }

    @Test func connectSequenceReportsPlaybackUnavailableWithNoTracksOrStorage() async throws {
        let double = RequestDouble()
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        await double.route("/Security/userCheck", xml: SessionFixtures.userCheckOK)
        await double.route("/Streaming/channels", xml: SessionFixtures.streamingChannels)
        await double.route("/ContentMgmt/record/tracks",
                           failing: .notFound(resource: "/ContentMgmt/record/tracks"))
        await double.route("/ContentMgmt/Storage",
                           failing: .notFound(resource: "/ContentMgmt/Storage"))
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let outcome = try await session.connect(startingAlertStream: false)
        #expect(outcome.recordTracks.isEmpty)
        #expect(outcome.storage == nil)
        #expect(outcome.degradations.contains(.playbackUnavailable))
    }

    /// The budget is checked between steps, so a device that has already burned it gets steps 1–6
    /// and nothing optional. What did not run is re-probed lazily on first use.
    @Test func connectSequenceSkipsTheOptionalStepsOnceTheBudgetIsSpent() async throws {
        let double = await Self.healthyCamera()
        let session = ISAPIDeviceSession(
            requests: double, clock: SessionBurningClock(perReadingSeconds: 13),
            wallClock: FixedWallClock(SessionFixtures.frozenNow),
            random: SplitMix64RandomSource(seed: 1))

        let outcome = try await session.connect(startingAlertStream: false)
        #expect(outcome.exceededBudget)
        // The elapsed reading is the injected clock's, so a clock that moves reports movement while
        // the frozen one reports zero — see `connectSequenceMeasuresElapsedTimeOnTheInjectedClock`.
        #expect(outcome.elapsedSeconds > 0)
        #expect(outcome.degradations.contains(.budgetExceeded))
        // Steps 1–4 still landed, which is what the first tile needs.
        #expect(outcome.canStream)
        #expect(outcome.ptzChannels.isEmpty)
    }

    /// The elapsed reading comes off the injected clock, so this measures the sequence rather than
    /// the machine it runs on.
    @Test func connectSequenceMeasuresElapsedTimeOnTheInjectedClock() async throws {
        let double = await Self.healthyCamera()
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let outcome = try await session.connect(startingAlertStream: false)
        #expect(outcome.elapsedSeconds == 0)
    }

    /// Step 10 is skipped, and the degradation recorded, when the device says it has no alert
    /// stream — starting a monitor that will only ever 403 would put a red banner on a healthy
    /// camera.
    @Test func connectSequenceSkipsTheAlertStreamWhenTheDeviceHasNone() async throws {
        let double = RequestDouble()
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        await double.route("/Security/userCheck", xml: SessionFixtures.userCheckOK)
        await double.route("/Streaming/channels", xml: SessionFixtures.streamingChannels)
        await double.route("/System/capabilities", xml: """
            <DeviceCap version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
            <EventCap><isSupportAlertStream>false</isSupportAlertStream></EventCap></DeviceCap>
            """)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        // `startingAlertStream: true` — the documented sequence. The device's own answer is what
        // suppresses step 10, not the caller.
        let outcome = try await session.connect()
        #expect(outcome.capabilities.supportsAlertStream == false)
        #expect(outcome.degradations.contains(.alertStreamUnavailable))
        #expect(await double.requests(to: "/alertStream").isEmpty)
    }

    /// The quirk record the sequence hands back is what `VigilCore` persists on the camera row.
    @Test func connectSequenceReturnsTheQuirkRecordItLearned() async throws {
        let double = await Self.healthyCamera()
        await double.route("/InputProxy/channels/status",
                           failing: .notFound(resource: "/InputProxy/channels/status"))
        await double.route("/InputProxy/channels", xml: """
            <InputProxyChannelList><InputProxyChannel><id>1</id></InputProxyChannel>
            </InputProxyChannelList>
            """)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let outcome = try await session.connect(startingAlertStream: false)
        #expect(outcome.quirks.inputProxyStatusListUnsupported)
        // Seeded from the firmware, not observed: 5.5.x sends the declaration in every body.
        #expect(outcome.quirks.requiresXMLDeclarationInBody)
    }
}
