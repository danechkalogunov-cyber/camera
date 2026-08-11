import Testing
import VigilProtocols
@testable import VigilISAPI

@Suite struct AlertStreamWatchdogSuite {

    private func monitor(_ double: RequestDouble, gate: SleepGate,
                         policy: AlertStreamMonitor.Policy = .init()) -> AlertStreamMonitor {
        AlertStreamMonitor(requests: double, policy: policy, clock: GateClock(gate: gate),
                           wallClock: FixedWallClock(),
                           random: SplitMix64RandomSource(seed: 0x5EED))
    }

    @Test func silentStreamProbesUserCheckThenReconnectsAtTheWatchdog() async throws {
        let double = RequestDouble()
        await double.setStream(contentType: "multipart/mixed; boundary=b",
                               chunks: [], finishes: false)
        let gate = SleepGate()
        var policy = AlertStreamMonitor.Policy()
        policy.jitterFraction = 0
        let subject = monitor(double, gate: gate, policy: policy)

        await subject.start()
        await double.waitForRequests(atLeast: 1)       // alertStream
        await gate.release()                           // 60-second probe deadline
        await double.waitForRequests(atLeast: 2)       // userCheck
        #expect(await double.requests(to: "/Security/userCheck").count == 1)
        #expect(await subject.livenessProbes == 1)

        await gate.release()                           // 90-second reconnect deadline
        await settle(until: { await !subject.backoffHistory.isEmpty })
        await gate.release()                           // reconnect backoff
        await double.waitForRequests(atLeast: 3)
        #expect(await double.requests(to: "/Event/notification/alertStream").count == 2)
        await subject.stop()
    }

    @Test func failedSilentStreamProbeUsesTheTerminalAuthenticationPolicy() async throws {
        let double = RequestDouble()
        await double.setStream(contentType: "multipart/mixed; boundary=b",
                               chunks: [], finishes: false)
        await double.route("/Security/userCheck",
                           failing: .authenticationFailed(username: "admin"))
        let gate = SleepGate()
        let subject = monitor(double, gate: gate)

        await subject.start()
        await double.waitForRequests(atLeast: 1)
        await gate.release()
        await double.waitForRequests(atLeast: 2)
        await settle(until: { await subject.state == .authFailed })

        #expect(await subject.state == .authFailed)
        #expect(await double.requests(to: "/Event/notification/alertStream").count == 1)
        #expect(await subject.backoffHistory.isEmpty)
        await subject.stop()
    }
}
