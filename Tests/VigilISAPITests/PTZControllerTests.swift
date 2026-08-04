//
//  PTZTests.swift
//  VigilISAPITests
//
//  The PTZ bodies asserted byte-for-byte against docs/spec-isapi.md §13, the 0…255 lower-left
//  `position3D` mapping including the Y flip, the capability documents under both spellings of the
//  root element, and the controller's keep-alive and triple zero-stop.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilISAPI

// MARK: - PTZControllerSuite

@Suite struct PTZControllerSuite {

    private func makeController(_ double: RequestDouble, gate: SleepGate,
                               capabilities: PTZCapabilitiesWire) -> PTZController {
        PTZController(requests: double, channel: ChannelID(1), capabilities: capabilities,
                      clock: GateClock(gate: gate))
    }

    private func fullCapabilities() throws -> PTZCapabilitiesWire {
        PTZCapabilitiesWire(document: try PTZFixtures.document(PTZFixtures.capabilities))
    }

    @Test func ptzControllerSendsTheContinuousBodyToTheRightResource() async throws {
        let double = RequestDouble()
        let gate = SleepGate()
        let controller = makeController(double, gate: gate, capabilities: try fullCapabilities())
        try await controller.continuous(pan: 60, tilt: -40, zoom: 0)

        // Exactly one write so far: the keep-alive is parked on the closed gate.
        let requests = await double.requests(to: "/PTZCtrl/channels/1/continuous")
        #expect(requests.count == 1)
        #expect(requests[0].method == "PUT")
        #expect(requests[0].bodyText == PTZFixtures.declaration
                + "<PTZData><pan>60</pan><tilt>-40</tilt><zoom>0</zoom></PTZData>")
    }

    @Test func ptzControllerStopSendsThreeZeroBodies() async throws {
        let double = RequestDouble()
        let gate = SleepGate()
        // Two credits for the two inter-stop spacings.
        await gate.release(2)
        let controller = makeController(double, gate: gate, capabilities: try fullCapabilities())
        await controller.stop()

        let requests = await double.requests(to: "/continuous")
        #expect(requests.count == PTZController.stopRepeatCount)
        let zero = PTZFixtures.declaration
            + "<PTZData><pan>0</pan><tilt>0</tilt><zoom>0</zoom></PTZData>"
        for request in requests { #expect(request.bodyText == zero) }
    }

    @Test func ptzControllerStopIgnoresIndividualFailures() async throws {
        // Two of three writes may fail and the camera still stops; propagating the first would
        // skip the other two, which is the runaway this design prevents.
        let double = RequestDouble()
        await double.route("/continuous", failing: .deviceBusy)
        let gate = SleepGate()
        await gate.release(2)
        let controller = makeController(double, gate: gate, capabilities: try fullCapabilities())
        await controller.stop()
        #expect(await double.requests(to: "/continuous").count == 3)
    }

    @Test func ptzControllerZeroTripleRoutesToStop() async throws {
        let double = RequestDouble()
        let gate = SleepGate()
        await gate.release(2)
        let controller = makeController(double, gate: gate, capabilities: try fullCapabilities())
        try await controller.continuous(pan: 0, tilt: 0, zoom: 0)
        // A joystick returning to centre must produce the full stop discipline, not one write.
        #expect(await double.requests(to: "/continuous").count == 3)
    }

    @Test func ptzControllerKeepAliveResendsTheIdenticalBody() async throws {
        let double = RequestDouble()
        let gate = SleepGate()
        let controller = makeController(double, gate: gate, capabilities: try fullCapabilities())
        try await controller.continuous(pan: 30, tilt: 0, zoom: 0)
        await double.waitForRequests(atLeast: 1)

        // Two keep-alive intervals, released one at a time so the cadence is exact.
        await gate.release(1)
        await double.waitForRequests(atLeast: 2)
        await gate.release(1)
        await double.waitForRequests(atLeast: 3)

        let requests = await double.requests(to: "/continuous")
        #expect(requests.count == 3)
        let expected = PTZFixtures.declaration
            + "<PTZData><pan>30</pan><tilt>0</tilt><zoom>0</zoom></PTZData>"
        for request in requests { #expect(request.bodyText == expected) }
        #expect(await controller.keepAliveSendCount == 2)
    }

    @Test func ptzControllerKeepAliveIntervalsAreTheDocumentedNumbers() {
        #expect(PTZController.keepAliveInterval == .milliseconds(400))
        #expect(PTZController.stopRepeatCount == 3)
        #expect(PTZController.stopRepeatSpacing == .milliseconds(80))
    }

    @Test func ptzControllerStopEndsTheKeepAlive() async throws {
        let double = RequestDouble()
        let gate = SleepGate()
        let controller = makeController(double, gate: gate, capabilities: try fullCapabilities())
        try await controller.continuous(pan: 30, tilt: 0, zoom: 0)
        await gate.release(1)
        await double.waitForRequests(atLeast: 2)

        // `stop()` cancels the keep-alive before its own first write, so the credits released here
        // reach the stop path and not another re-send.
        async let stopped: Void = controller.stop()
        await gate.release(8)
        await stopped

        let settled = await double.requestCount
        // More sleeps must not produce another keep-alive write: `activeVelocity` is now nil.
        await gate.release(8)
        await Task.yield()
        #expect(await double.requestCount == settled)
        let zero = PTZFixtures.declaration
            + "<PTZData><pan>0</pan><tilt>0</tilt><zoom>0</zoom></PTZData>"
        #expect(await double.recorded.suffix(3).allSatisfy { $0.bodyText == zero })
    }

    @Test func ptzControllerRefusesWritingAReservedPreset() async throws {
        let double = RequestDouble()
        let gate = SleepGate()
        let controller = makeController(double, gate: gate, capabilities: try fullCapabilities())
        // Preset 94 is remote reboot. Writing it would reboot the camera the user was bookmarking.
        await #expect(throws: ISAPIError.device(statusCode: 4, sub: "reservedPreset")) {
            try await controller.setPreset(94, name: "Nope")
        }
        await #expect(throws: ISAPIError.device(statusCode: 4, sub: "reservedPreset")) {
            try await controller.deletePreset(33)
        }
        // Not one byte went to the device.
        #expect(await double.requestCount == 0)
        // The user range is writable.
        try await controller.setPreset(3, name: "Back gate")
        let requests = await double.requests(to: "/PTZCtrl/channels/1/presets/3")
        #expect(requests.count == 1)
        #expect(requests[0].bodyText == PTZFixtures.declaration
                + "<PTZPreset><id>3</id><presetName>Back gate</presetName></PTZPreset>")
    }

    @Test func ptzControllerRecallsAReservedPresetWithAnEmptyBody() async throws {
        let double = RequestDouble()
        let gate = SleepGate()
        let controller = makeController(double, gate: gate, capabilities: try fullCapabilities())
        // Recall is allowed — the UI confirms first — and must send `Content-Length: 0`.
        try await controller.gotoPreset(94)
        let requests = await double.requests(to: "/presets/94/goto")
        #expect(requests.count == 1)
        #expect(requests[0].body == nil)
    }

    @Test func ptzControllerRefusesPosition3DWhenUnsupported() async throws {
        let double = RequestDouble()
        let gate = SleepGate()
        let controller = makeController(double, gate: gate, capabilities: .absent)
        await #expect(throws: ISAPIError.self) {
            try await controller.position3D(PTZ3D(startX: 0, startY: 0, endX: 10, endY: 10))
        }
        await #expect(throws: ISAPIError.self) {
            try await controller.continuous(pan: 10, tilt: 0, zoom: 0)
        }
        #expect(await double.requestCount == 0)
    }

    @Test func ptzControllerStartingAPatrolStopsFirst() async throws {
        // Starting a patrol while a continuous move is active returns `invalidOperation`, so the
        // controller always stops first.
        let double = RequestDouble()
        let gate = SleepGate()
        await gate.release(2)
        let controller = makeController(double, gate: gate, capabilities: try fullCapabilities())
        try await controller.startPatrol(1)
        let all = await double.recorded
        #expect(all.count == 4)
        #expect(all.prefix(3).allSatisfy { $0.resource.hasSuffix("/continuous") })
        #expect(all[3].resource.hasSuffix("/patrols/1/start"))
        #expect(all[3].body == nil)
    }

    @Test func ptzControllerReadsPresetsAndPatrols() async throws {
        let double = RequestDouble()
        await double.route("/presets", xml: PTZFixtures.presets)
        await double.route("/patrols", xml: PTZFixtures.patrols)
        let gate = SleepGate()
        let controller = makeController(double, gate: gate, capabilities: try fullCapabilities())
        let presets = try await controller.presets()
        let patrols = try await controller.patrols()
        #expect(presets.count == 3)
        #expect(patrols.first?.stops.count == 2)
    }

    @Test func ptzControllerStopDetachedStillSendsTheTripleStop() async throws {
        // The quit path: the caller cannot await, so the stop runs detached. It must survive the
        // caller going away, which is why it is detached rather than a child task.
        let double = RequestDouble()
        let gate = SleepGate()
        await gate.release(2)
        let controller = makeController(double, gate: gate, capabilities: try fullCapabilities())
        await controller.stopDetached().value
        let requests = await double.requests(to: "/continuous")
        #expect(requests.count == 3)
        let zero = PTZFixtures.declaration
            + "<PTZData><pan>0</pan><tilt>0</tilt><zoom>0</zoom></PTZData>"
        for request in requests { #expect(request.bodyText == zero) }
    }

    @Test func ptzControllerSendsFocusAndIrisToTheVideoInputPath() async throws {
        // Focus and iris live under `/System/Video/inputs/channels/{ch}`, not under `/PTZCtrl` —
        // the wrong path is a silent 404.
        let double = RequestDouble()
        let gate = SleepGate()
        let controller = makeController(double, gate: gate, capabilities: try fullCapabilities())
        try await controller.setFocus(50)
        try await controller.setIris(-50)
        let recorded = await double.recorded
        #expect(recorded[0].resource == "/System/Video/inputs/channels/1/focus")
        #expect(recorded[1].resource == "/System/Video/inputs/channels/1/iris")
        #expect(recorded[1].bodyText?.contains("<iris>-50</iris>") == true)
    }
}
