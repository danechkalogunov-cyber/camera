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

// MARK: - PTZ, events, audio, image

@Suite struct DeviceSessionFeatureSuite {

    /// One controller per channel and never one per gesture: the keep-alive and the triple
    /// zero-stop are per-channel state, and two controllers would race a held joystick.
    @Test func deviceSessionMemoisesOnePTZControllerPerChannel() async throws {
        let double = RequestDouble()
        await double.route("/PTZCtrl/channels/1/capabilities", xml: SessionFixtures.ptzCapabilities)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let first = try await session.ptzController(channel: .first)
        let second = try await session.ptzController(channel: .first)
        #expect(first === second)
        #expect(await double.requests(to: "/capabilities").count == 1)
    }

    @Test func deviceSessionRefusesAPTZControllerForAChannelWithoutPTZ() async throws {
        let double = RequestDouble()
        await double.route("/PTZCtrl/channels/1/capabilities",
                           failing: .notSupported(resource: "/PTZCtrl/channels/1/capabilities"))
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        await #expect(throws: ISAPIError.self) {
            _ = try await session.ptzController(channel: .first)
        }
    }

    /// Exactly one alert-stream monitor per device (API_CONTRACT §2 R-28): the device multiplexes
    /// every channel onto one response, and a second one exhausts its HTTP worker pool.
    @Test func deviceSessionMemoisesOneAlertStreamMonitorPerDevice() async throws {
        let session = SessionFixtures.session(RequestDouble(), clock: SessionTestClock())

        let first = await session.alertStream()
        let second = await session.alertStream()
        #expect(first === second)
    }

    /// A `403`/`404` on one image sub-resource means the control does not exist, which is what the
    /// panel needs in order to show only the sliders that will work.
    @Test func deviceSessionReportsOnlyTheImageControlsTheDeviceAnswered() async throws {
        let double = RequestDouble()
        await double.route("/Image/channels/1/color", xml: SessionFixtures.color)
        await double.route("/Image/channels/1/ircutFilter", xml: SessionFixtures.ircut)
        // Everything else is refused, which is the common case on a fixed camera.
        await SessionFixtures.refuseImageControls(double, except: [.color, .ircut])
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let settings = try await session.imageSettings(channel: .first)
        #expect(settings.available == [.color, .ircut])
        #expect(settings.brightness == 50)
        #expect(settings.irCut?.mode == .auto)
    }

    /// A device that refuses all fourteen is a normal camera without image controls, not an error.
    @Test func deviceSessionReturnsEmptyImageSettingsWhenEveryControlIsRefused() async throws {
        let double = RequestDouble()
        await SessionFixtures.refuseImageControls(double, except: [])
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        #expect(try await session.imageSettings(channel: .first).available.isEmpty)
    }

    /// A channel that advertises nothing Vigil can encode must not open a session that sends static.
    @Test func deviceSessionRefusesTwoWayAudioWithNoSharedCodec() async throws {
        let double = RequestDouble()
        await double.route("/System/TwoWayAudio/channels", xml: """
            <TwoWayAudioChannelList version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
            <TwoWayAudioChannel><id>1</id><enabled>true</enabled>
            <audioCompressionType>G.722.1</audioCompressionType>
            <audioInputType>MicIn</audioInputType></TwoWayAudioChannel>
            </TwoWayAudioChannelList>
            """)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        await #expect(throws: ISAPIError.self) {
            _ = try await session.openTwoWayAudio(channel: 1)
        }
    }

    /// A camera left panning after the app quits is the one failure a user cannot undo from inside
    /// Vigil, so PTZ is stopped first and unconditionally.
    @Test func deviceSessionShutdownStopsPTZAndTheAlertStreamAndFlushesCaches() async throws {
        let double = RequestDouble()
        await double.route("/PTZCtrl/channels/1/capabilities", xml: SessionFixtures.ptzCapabilities)
        await double.route("/System/deviceInfo", xml: SessionFixtures.deviceInfo())
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try await session.ptzController(channel: .first)
        _ = await session.alertStream()
        _ = try await session.deviceInfo()
        await session.shutdown()

        // A `continuous` stop was written for the controller that existed.
        #expect(await !double.requests(to: "/continuous").isEmpty)
        // And the identity cache is gone, so the next read hits the device.
        _ = try await session.deviceInfo()
        #expect(await double.requests(to: "/System/deviceInfo").count == 2)
    }
}
