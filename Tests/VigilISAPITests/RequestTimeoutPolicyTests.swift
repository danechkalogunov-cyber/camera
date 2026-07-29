//
//  RequestTimeoutPolicyTests.swift
//  VigilISAPITests
//
//  The per-request budget table of docs/spec-isapi.md §4.5, read off the request the transport
//  actually received. Every one of these is a number a camera can be slower than, so each is
//  asserted rather than assumed.
//

import Foundation
import Testing

import VigilProtocols
@testable import VigilISAPI

// MARK: - RequestTimeoutPolicySuite

/// The budget is chosen per request, not per lane, and the difference matters in both directions:
/// too short refuses an operation the camera would have completed, too long leaves the user staring
/// at a control that has already failed.
@Suite("Request timeout policy") struct RequestTimeoutPolicySuite {

    private static func client(_ device: ScriptedDevice) -> ISAPIClient {
        TestClientFactory.scriptedClient(device: device)
    }

    /// ⚠️ The one this suite exists for. `PUT …/ircutFilter` swings the infrared filter across the
    /// sensor and the camera answers only once it has moved and the exposure has settled; a field
    /// log showed one refused at the 8 s control budget. A picture *write* gets its own budget.
    @Test func imageWriteGetsTheLongerHardwareBudget() async throws {
        let device = ScriptedDevice(replies: [.xml("<IrcutFilter/>")])
        var builder = XMLBuilder("IrcutFilter")
        builder.add("IrcutFilterType", "night")
        _ = try? await Self.client(device).put("/Image/channels/1/ircutFilter",
                                               body: builder.data())
        let recorded = await device.recorded
        #expect(recorded.first?.method == "PUT")
        #expect(recorded.first?.timeout == .seconds(20))
    }

    /// Reading one is an ordinary configuration read: nothing moves, so nothing waits. This is the
    /// other half of the rule — widening the budget for the whole `/Image/` path would have made
    /// every read of the panel hang for twenty seconds against an unreachable camera.
    @Test func imageReadKeepsTheOrdinaryControlBudget() async throws {
        let device = ScriptedDevice(replies: [.xml("<IrcutFilter/>")])
        _ = try? await Self.client(device).get("/Image/channels/1/ircutFilter")
        let recorded = await device.recorded
        #expect(recorded.first?.method == "GET")
        #expect(recorded.first?.timeout == .seconds(8))
    }

    /// A PTZ command keeps its 2 s: a stop that arrives later than that is worse than useless.
    @Test func ptzKeepsItsShortBudget() async throws {
        let device = ScriptedDevice(replies: [.xml("<PTZData/>")])
        var builder = XMLBuilder("PTZData")
        builder.add("elevation", 10)
        _ = try? await Self.client(device).put("/PTZCtrl/channels/1/absolute", body: builder.data())
        #expect(await device.recorded.first?.timeout == .seconds(2))
    }

    /// A recording search is slow on a full NVR and keeps its 15 s — the budget that decides how
    /// much of a day's footage the timeline can page through.
    @Test func recordingSearchKeepsItsLongBudget() async throws {
        let device = ScriptedDevice(replies: [.xml("<CMSearchResult/>")])
        var builder = XMLBuilder("CMSearchDescription")
        builder.add("searchID", "1")
        _ = try? await Self.client(device).post("/ContentMgmt/search", body: builder.data())
        #expect(await device.recorded.first?.timeout == .seconds(15))
    }

    /// Everything else on the control lane gets the plain 8 s.
    @Test func ordinaryControlRequestsGetTheControlBudget() async throws {
        let device = ScriptedDevice(replies: [.xml("<DeviceInfo/>")])
        _ = try? await Self.client(device).get("/System/deviceInfo")
        #expect(await device.recorded.first?.timeout == .seconds(8))
    }
}
