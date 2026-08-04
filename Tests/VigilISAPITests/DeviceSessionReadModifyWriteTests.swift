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

// MARK: - Read-modify-write and the confirming re-GET (§17.1)

@Suite struct DeviceSessionReadModifyWriteSuite {

    /// The whole discipline in one assertion set: GET, PUT the *whole* element with the device's own
    /// `version` and `xmlns` echoed back, then re-GET to confirm.
    @Test func deviceSessionImageWriteIsGetThenWholeElementPutThenReGet() async throws {
        let double = RequestDouble()
        await double.route("/Image/channels/1/color", xml: SessionFixtures.color)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try await session.setImageColor(channel: .first, brightness: 62, contrast: nil,
                                            saturation: nil)
        let traffic = await double.requests(to: "/Image/channels/1/color")
        // The setter re-reads the whole panel afterwards, so assert the first three requests:
        // the read, the whole-element write, and the confirming read.
        #expect(traffic.prefix(3).map(\.method) == ["GET", "PUT", "GET"])

        let body = try #require(traffic[1].bodyText)
        #expect(body.contains("<brightnessLevel>62</brightnessLevel>"))
        // Untouched siblings survive: a "minimal" body is what the validator rejects.
        #expect(body.contains("<contrastLevel>50</contrastLevel>"))
        #expect(body.contains("<saturationLevel>55</saturationLevel>"))
        // The echoed attributes some 5.4.x builds reject a `<Color>` without (§8, §17.2).
        #expect(body.contains("version=\"2.0\""))
        #expect(body.contains("xmlns=\"http://www.hikvision.com/ver20/XMLSchema\""))
        #expect(body.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
    }

    /// The re-GET is what makes the returned value the device's, not the caller's.
    @Test func deviceSessionImageWriteReturnsTheDevicesClampedValueNotTheRequestedOne() async throws {
        let double = RequestDouble()
        // The device answers 60 to a request for 62 — several firmwares quantise to steps of two.
        await double.route("/Image/channels/1/color",
                           pages: [SessionFixtures.color,
                                   SessionFixtures.color
                                       .replacingOccurrences(of: "<brightnessLevel>50",
                                                             with: "<brightnessLevel>60")])
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        let confirmed = try await session.setImageColor(channel: .first, brightness: 62,
                                                        contrast: nil, saturation: nil)
        #expect(confirmed.brightness == 60)
    }

    /// A write must drop its cache *before* the confirming read, or the read is served from the
    /// entry the write just invalidated and the user is shown their own request back.
    @Test func deviceSessionImageWriteDoesNotServeTheConfirmationFromTheStaleCache() async throws {
        let double = RequestDouble()
        await double.route("/Image/channels/1/color", xml: SessionFixtures.color)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try await session.imageSettings(channel: .first)
        let beforeWrite = await double.requests(to: "/Image/channels/1/color").count
        _ = try await session.setImageColor(channel: .first, brightness: 10, contrast: nil,
                                            saturation: nil)
        #expect(await double.requests(to: "/Image/channels/1/color").count > beforeWrite + 2)
    }

    /// `schedule` carries configuration Vigil does not model, so the mode is refused rather than
    /// written on its own — writing it alone would silently discard the user's schedule.
    @Test func deviceSessionRefusesAnIRCutModeItCannotExpressWithoutInventingABody() async throws {
        let double = RequestDouble()
        await double.route("/Image/channels/1/ircutFilter", xml: SessionFixtures.ircut)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        await #expect(throws: ISAPIError.self) {
            _ = try await session.setIRCut(channel: .first,
                                           IRCutSetting(mode: .schedule, nightToDayLevel: nil,
                                                        nightToDaySeconds: nil))
        }
        // Nothing was written: the refusal happens before the PUT.
        #expect(await double.requests(to: "/Image/channels/1/ircutFilter")
                    .allSatisfy { $0.method == "GET" })
    }

    /// A patch that renames the root would reach the device as a body it answers
    /// `invalidXMLContent` to, hours later, in the field. It is refused here instead.
    @Test func deviceSessionRefusesAPatchThatChangesTheRootElementName() async throws {
        let double = RequestDouble()
        await double.route("/Image/channels/1/color", xml: SessionFixtures.color)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        await #expect(throws: ISAPIError.self) {
            _ = try await session.readModifyWrite("/Image/channels/1/color") { _ in
                XMLNode(name: "Colour", text: "wrong")
            }
        }
        #expect(await double.requests(to: "/Image/channels/1/color")
                    .allSatisfy { $0.method == "GET" })
    }

    @Test func deviceSessionMotionWriteEchoesTheElementsVigilDoesNotModel() async throws {
        let double = RequestDouble()
        await double.route("/motionDetection", xml: """
            <?xml version="1.0" encoding="UTF-8"?>
            <MotionDetection version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
            <enabled>true</enabled><enableHighlight>true</enableHighlight>
            <samplingInterval>2</samplingInterval><startTriggerTime>500</startTriggerTime>
            <endTriggerTime>500</endTriggerTime>
            <regionType>grid</regionType>
            <Grid><rowGranularity>18</rowGranularity><columnGranularity>22</columnGranularity></Grid>
            <MotionDetectionLayout version="2.0"><sensitivityLevel>40</sensitivityLevel>
            <layout><gridMap>\(String(repeating: "000000", count: 18))</gridMap></layout>
            </MotionDetectionLayout>
            </MotionDetection>
            """)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try await session.setMotionDetection(channel: .first, enabled: false,
                                                 sensitivity: 80, grid: nil)
        let traffic = await double.requests(to: "/motionDetection")
        #expect(traffic.map(\.method) == ["GET", "PUT", "GET"])
        let body = try #require(traffic[1].bodyText)
        #expect(body.contains("<enabled>false</enabled>"))
        #expect(body.contains("<sensitivityLevel>80</sensitivityLevel>"))
        #expect(body.contains("<enableHighlight>true</enableHighlight>"))
        #expect(body.contains("<startTriggerTime>500</startTriggerTime>"))
        #expect(body.contains("<rowGranularity>18</rowGranularity>"))
    }

    @Test func deviceSessionResetImageDefaultsSendsNoBodyAndDropsTheCache() async throws {
        let double = RequestDouble()
        await double.route("/Image/channels/1/color", xml: SessionFixtures.color)
        let session = SessionFixtures.session(double, clock: SessionTestClock())

        _ = try await session.imageSettings(channel: .first)
        try await session.resetImageDefaults(channel: .first)
        let reset = await double.requests(to: "/defaultConfiguration")
        #expect(reset.count == 1)
        #expect(reset[0].method == "PUT")
        #expect(reset[0].body == nil)

        let beforeReRead = await double.requests(to: "/Image/channels/1/color").count
        _ = try await session.imageSettings(channel: .first)
        #expect(await double.requests(to: "/Image/channels/1/color").count > beforeReRead)
    }
}
