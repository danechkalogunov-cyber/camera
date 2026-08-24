//
//  AlertStreamMonitorTests.swift
//  VigilISAPITests
//

import Foundation
import Testing
import VigilProtocols

@testable import VigilISAPI

// MARK: - AlertStreamMonitorSuite

@Suite struct AlertStreamMonitorSuite {

    private func monitor(
        _ double: RequestDouble, gate: SleepGate,
        policy: AlertStreamMonitor.Policy = .init()
    ) -> AlertStreamMonitor {
        AlertStreamMonitor(
            requests: double, policy: policy, clock: GateClock(gate: gate),
            wallClock: FixedWallClock(),
            random: SplitMix64RandomSource(seed: 0x5EED))
    }

    @Test func monitorEmitsEventsAndSuppressesHeartbeats() async throws {
        let token = "<boundary>"
        let double = RequestDouble()
        await double.setStream(
            contentType: "multipart/mixed; boundary=\(token)",
            chunks: [MultipartFixtures.realisticStream(boundary: token)])
        let gate = SleepGate()
        let subject = AlertStreamMonitor(
            requests: double, clock: GateClock(gate: gate),
            wallClock: FixedWallClock(),
            random: SplitMix64RandomSource(seed: 42))
        let events = subject.notifications()
        await settle(until: { await subject.eventConsumerCount() == 1 })
        await subject.start()

        var received: [EventNotificationAlert] = []
        for await event in events {
            received.append(event)
            if received.count == 1 { break }
        }
        #expect(received.count == 1)
        #expect(received[0].kind == .motion)
        // The image arrived as its own part and was attached to the event before delivery.
        #expect(received[0].snapshot == MultipartFixtures.jpeg(containing: token))
        #expect(await subject.suppressedHeartbeats == 1)
        #expect(await subject.emittedEvents == 1)
        await subject.stop()
    }

    @Test func monitorTreatsA403AsUnsupportedAndStopsPermanently() async throws {
        // docs/API_CONTRACT.md §2 R-28: no synthetic polling fallback. A fake event stream is
        // worse than an honestly absent one.
        let double = RequestDouble()
        await double.route(
            "/alertStream",
            failing: .notSupported(resource: "/Event/notification/alertStream"))
        let gate = SleepGate()
        let subject = monitor(double, gate: gate)
        await subject.start()
        await double.waitForRequests(atLeast: 1)
        // Give the run loop a moment to record the terminal state.
        await settle(until: { await subject.state == .notSupported })
        #expect(await subject.state == .notSupported)
        // A second `start()` must not reconnect.
        await subject.start()
        for _ in 0..<16 { await Task.yield() }
        #expect(await double.requestCount == 1)
    }

    @Test func monitorTreatsAuthenticationFailureAsTerminal() async throws {
        let double = RequestDouble()
        await double.route("/alertStream", failing: .authenticationFailed(username: "admin"))
        let gate = SleepGate()
        let subject = monitor(double, gate: gate)
        await subject.start()
        await double.waitForRequests(atLeast: 1)
        await settle(until: { await subject.state == .authFailed })
        #expect(await subject.state == .authFailed)
        #expect(await double.requestCount == 1)
    }

    @Test func monitorResetClearsATerminalState() async throws {
        let double = RequestDouble()
        await double.route("/alertStream", failing: .notFound(resource: "/x"))
        let gate = SleepGate()
        let subject = monitor(double, gate: gate)
        await subject.start()
        await double.waitForRequests(atLeast: 1)
        await settle(until: { await subject.state == .notSupported })
        await subject.stop()
        await subject.reset()
        #expect(await subject.state == .idle)
    }

    @Test func monitorClassifiesTerminalErrorsFromTheMappingTable() {
        #expect(
            AlertStreamMonitor.terminalState(for: .notSupported(resource: "x"))
                == .notSupported)
        #expect(AlertStreamMonitor.terminalState(for: .notFound(resource: "x")) == .notSupported)
        #expect(
            AlertStreamMonitor.terminalState(for: .insufficientPermission(resource: "x"))
                == .notSupported)
        #expect(
            AlertStreamMonitor.terminalState(for: .authenticationFailed(username: "a"))
                == .authFailed)
        #expect(
            AlertStreamMonitor.terminalState(for: .authBlockedLocally(failures: 2))
                == .authFailed)
        #expect(
            AlertStreamMonitor.terminalState(for: .accountLocked(retryAfter: 1800))
                == .authFailed)
        // Everything else is retried with backoff.
        #expect(AlertStreamMonitor.terminalState(for: .deviceBusy) == nil)
        #expect(AlertStreamMonitor.terminalState(for: .streamEnded(afterBytes: 10)) == nil)
        #expect(AlertStreamMonitor.terminalState(for: .timedOut(resource: "x", seconds: 8)) == nil)
    }

    @Test func monitorBackoffFollowsTheLadderWithBoundedJitter() {
        let policy = AlertStreamMonitor.Policy()
        var random = SplitMix64RandomSource(seed: 7)
        let history = (0..<8).map { attempt in
            let base = AlertStreamMonitor.backoffBase(attempt: attempt, policy: policy)
            return AlertStreamMonitor.jittered(
                base, fraction: policy.jitterFraction, draw: random.next())
        }
        let ladder = policy.backoffSeconds
        for (index, delay) in history.prefix(8).enumerated() {
            let base = ladder[min(index, ladder.count - 1)]
            #expect(
                delay >= base * (1 - policy.jitterFraction) - 0.0001,
                "step \(index) delay \(delay) base \(base)")
            #expect(
                delay <= base * (1 + policy.jitterFraction) + 0.0001,
                "step \(index) delay \(delay) base \(base)")
        }
        // The ladder saturates: the eighth step still uses the last rung, 60 s.
        #expect(history[7] >= 60 * (1 - policy.jitterFraction) - 0.0001)
    }

    @Test func monitorPublishesStateChangesToEveryConsumer() async throws {
        let double = RequestDouble()
        await double.route("/alertStream", failing: .notSupported(resource: "x"))
        let gate = SleepGate()
        let subject = monitor(double, gate: gate)
        // A factory, not a property: two consumers each get their own stream (R-65).
        let first = subject.stateChanges()
        let second = subject.stateChanges()
        await settle(until: { await subject.stateConsumerCount() == 2 })
        await subject.start()
        var firstStates: [AlertStreamState] = []
        for await state in first {
            firstStates.append(state)
            if state == .notSupported { break }
        }
        var secondStates: [AlertStreamState] = []
        for await state in second {
            secondStates.append(state)
            if state == .notSupported { break }
        }
        #expect(firstStates.contains(.notSupported))
        #expect(secondStates.contains(.notSupported))
    }

    @Test func monitorThrowsWhenNoBoundaryCanBeFound() async throws {
        // No boundary in the header and none in the body: unparseable, and reported as such rather
        // than silently delivering nothing.
        let double = RequestDouble()
        await double.setStream(
            contentType: "multipart/mixed",
            chunks: [Data(repeating: 0x41, count: 1024)])
        let gate = SleepGate()
        let subject = monitor(double, gate: gate)
        await subject.start()
        await double.waitForRequests(atLeast: 1)
        // ⛔ DRIVE THE GATE UNTIL THE RECONNECT ACTUALLY HAPPENS, rather than releasing it once and
        // hoping. Releasing the instant the open request lands is a race: the idle watchdog's probe
        // sleep may be the gate's waiter at that moment, so a single release wakes that — firing a
        // `userCheck`, not the back-off that drives the reconnect — and `connectionAttempts` stays
        // at 1. That is exactly how this test hung under two workers, then failed intermittently
        // (green on Linux, red on macOS) once the wait was bounded. Feeding the gate one release per
        // hop is timing-independent: whichever sleep it wakes, the next release reaches the next,
        // and the loop stops the moment the reconnect lands. `settle` is bounded, so a reconnect
        // that never comes is a fast failure, not a hang.
        await settle(until: {
            await gate.release(1)
            return await subject.connectionAttempts >= 2
        })
        // It retried rather than treating the failure as terminal.
        #expect(await subject.emittedEvents == 0)
        #expect(await subject.connectionAttempts >= 2)
        await subject.stop()
    }

    @Test func monitorSniffsABoundaryOutOfTheBodyWhenTheHeaderLacksOne() async throws {
        let token = "MIME_boundary"
        let double = RequestDouble()
        await double.setStream(
            contentType: "multipart/mixed",
            chunks: [MultipartFixtures.realisticStream(boundary: token)])
        let gate = SleepGate()
        let subject = monitor(double, gate: gate)
        let events = subject.notifications()
        await settle(until: { await subject.eventConsumerCount() == 1 })
        await subject.start()
        var received: [EventNotificationAlert] = []
        for await event in events {
            received.append(event)
            break
        }
        #expect(received.first?.kind == .motion)
        await subject.stop()
    }

    @Test func monitorStopMovesToStopped() async throws {
        let double = RequestDouble()
        await double.route("/alertStream", failing: .deviceBusy)
        let gate = SleepGate()
        let subject = monitor(double, gate: gate)
        await subject.start()
        await double.waitForRequests(atLeast: 1)
        await subject.stop()
        #expect(await subject.state == .stopped)
    }

}
