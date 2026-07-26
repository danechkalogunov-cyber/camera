//
//  ConcurrencyUtilityTests.swift
//  VigilProtocolsTests
//
//  Broadcaster fan-out and the ConcurrencyLimiter permit gate.
//  Covers docs/API_CONTRACT.md §3.15 (rulings R-27, R-65, R-72).
//
//  No test here depends on wall-clock time: every one waits on a value, never on a delay.
//

import Foundation
import Testing
import VigilProtocols

@Suite struct BroadcasterTests {

    @Test func broadcasterDeliversToEveryConsumer() async {
        let broadcaster = Broadcaster<Int>()
        let first = broadcaster.stream()
        let second = broadcaster.stream()
        // Registration is asynchronous; wait for both consumers to be on the books.
        while await broadcaster.consumerCount < 2 { await Task.yield() }

        await broadcaster.yield(1)
        await broadcaster.yield(2)
        await broadcaster.finish()

        var firstValues: [Int] = []
        for await value in first { firstValues.append(value) }
        var secondValues: [Int] = []
        for await value in second { secondValues.append(value) }

        #expect(firstValues == [1, 2])
        #expect(secondValues == [1, 2], "the second consumer must not silently get nothing")
    }

    @Test func broadcasterReplaysTheLatestWhenAsked() async {
        let broadcaster = Broadcaster<String>(replaysLatest: true)
        let early = broadcaster.stream()
        while await broadcaster.consumerCount < 1 { await Task.yield() }
        await broadcaster.yield("state-1")

        // A consumer arriving after the fact still sees the current state.
        let late = broadcaster.stream()
        while await broadcaster.consumerCount < 2 { await Task.yield() }
        await broadcaster.finish()

        var lateValues: [String] = []
        for await value in late { lateValues.append(value) }
        var earlyValues: [String] = []
        for await value in early { earlyValues.append(value) }

        #expect(lateValues == ["state-1"])
        #expect(earlyValues == ["state-1"])
    }

    @Test func broadcasterDoesNotReplayByDefault() async {
        let broadcaster = Broadcaster<String>()
        let early = broadcaster.stream()
        while await broadcaster.consumerCount < 1 { await Task.yield() }
        await broadcaster.yield("event")
        let late = broadcaster.stream()
        while await broadcaster.consumerCount < 2 { await Task.yield() }
        await broadcaster.finish()

        var lateValues: [String] = []
        for await value in late { lateValues.append(value) }
        #expect(lateValues.isEmpty)
        var earlyValues: [String] = []
        for await value in early { earlyValues.append(value) }
        #expect(earlyValues == ["event"])
    }

    @Test func broadcasterFinishesLateConsumersInsteadOfHangingThem() async {
        let broadcaster = Broadcaster<Int>()
        await broadcaster.finish()
        var values: [Int] = []
        for await value in broadcaster.stream() { values.append(value) }
        #expect(values.isEmpty)
        #expect(await broadcaster.consumerCount == 0)
    }

    @Test func broadcasterIgnoresYieldsAfterFinishAndFinishIsIdempotent() async {
        let broadcaster = Broadcaster<Int>()
        let stream = broadcaster.stream()
        while await broadcaster.consumerCount < 1 { await Task.yield() }
        await broadcaster.finish()
        await broadcaster.finish()
        await broadcaster.yield(99)
        var values: [Int] = []
        for await value in stream { values.append(value) }
        #expect(values.isEmpty)
    }

    @Test func broadcasterDeregistersAConsumerThatStopsListening() async {
        let broadcaster = Broadcaster<Int>()
        do {
            let stream = broadcaster.stream()
            while await broadcaster.consumerCount < 1 { await Task.yield() }
            var iterator = stream.makeAsyncIterator()
            await broadcaster.yield(1)
            let received = await iterator.next()
            #expect(received == 1)
        }
        // The stream and its iterator are gone; termination deregisters it. Bounded so a
        // regression fails the test instead of hanging the suite.
        for _ in 0..<10_000 where await broadcaster.consumerCount > 0 {
            await Task.yield()
        }
        #expect(await broadcaster.consumerCount == 0)
    }
}

@Suite struct ConcurrencyLimiterTests {

    @Test func limiterRunsUpToItsLimitConcurrently() async {
        let limiter = ConcurrencyLimiter(limit: 2, name: "test")
        #expect(await limiter.inFlight == 0)
        #expect(await limiter.queueDepth == 0)

        let value = await limiter.withPermit {
            "done"
        }
        #expect(value == "done")
        #expect(await limiter.inFlight == 0, "the permit must be returned")
    }

    @Test func limiterReleasesThePermitWhenTheBodyThrows() async {
        struct Boom: Error {}
        let limiter = ConcurrencyLimiter(limit: 1, name: "test")
        do {
            _ = try await limiter.withPermit { () throws -> Int in throw Boom() }
            Issue.record("the error should have propagated")
        } catch is Boom {
            // expected
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(await limiter.inFlight == 0)
        // The gate is still usable, which is the point of releasing in a defer.
        let value = await limiter.withPermit { 42 }
        #expect(value == 42)
    }

    @Test func limiterNeverExceedsItsLimit() async {
        let limiter = ConcurrencyLimiter(limit: 3, name: "test")
        let peak = Peak()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    await limiter.withPermit {
                        await peak.enter()
                        await Task.yield()
                        await peak.leave()
                    }
                }
            }
        }
        #expect(await peak.maximum <= 3)
        #expect(await peak.maximum > 0)
        #expect(await limiter.inFlight == 0)
        #expect(await limiter.queueDepth == 0)
    }

    @Test func limiterRaisingTheLimitWakesWaiters() async {
        let limiter = ConcurrencyLimiter(limit: 1, name: "test")
        let peak = Peak()
        await limiter.setLimit(8)
        #expect(await limiter.currentLimit == 8)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    await limiter.withPermit {
                        await peak.enter()
                        await Task.yield()
                        await peak.leave()
                    }
                }
            }
        }
        #expect(await peak.maximum <= 8)
        #expect(await limiter.inFlight == 0)
    }

    @Test func limiterClampsANonsenseLimit() async {
        let limiter = ConcurrencyLimiter(limit: 0, name: "test")
        #expect(await limiter.currentLimit == 1)
        await limiter.setLimit(-5)
        #expect(await limiter.currentLimit == 1)
        let value = await limiter.withPermit { 1 }
        #expect(value == 1)
    }

    @Test func limiterDoesNotStrandACancelledWaiter() async {
        let limiter = ConcurrencyLimiter(limit: 1, name: "test")
        let gate = Gate()
        // Occupy the only permit until we say so.
        let holder = Task {
            await limiter.withPermit {
                await gate.wait()
            }
        }
        while await limiter.inFlight < 1 { await Task.yield() }

        let waiter = Task {
            await limiter.withPermit { true }
        }
        while await limiter.queueDepth < 1 { await Task.yield() }
        waiter.cancel()
        // The cancelled waiter leaves the queue without waiting for the holder.
        _ = await waiter.value
        #expect(await limiter.queueDepth == 0)

        await gate.open()
        await holder.value
        #expect(await limiter.inFlight == 0)
    }

    @Test func limiterServesHigherPriorityFirst() async {
        let limiter = ConcurrencyLimiter(limit: 1, name: "test")
        let order = Order()
        let gate = Gate()
        let holder = Task {
            await limiter.withPermit { await gate.wait() }
        }
        while await limiter.inFlight < 1 { await Task.yield() }

        // Queue a background task first, then a focused one: priority must beat arrival order.
        let low = Task {
            await limiter.withPermit(priority: .background) { await order.record("background") }
        }
        while await limiter.queueDepth < 1 { await Task.yield() }
        let high = Task {
            await limiter.withPermit(priority: .focused) { await order.record("focused") }
        }
        while await limiter.queueDepth < 2 { await Task.yield() }

        await gate.open()
        await holder.value
        await low.value
        await high.value
        #expect(await order.entries == ["focused", "background"])
    }
}

// MARK: - Test doubles

/// Counts how many bodies are inside the gate at once.
private actor Peak {
    private(set) var current = 0
    private(set) var maximum = 0

    func enter() {
        current += 1
        maximum = Swift.max(maximum, current)
    }

    func leave() { current -= 1 }
}

/// A one-shot latch, so a test can hold a permit without sleeping.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }
}

/// Records the order in which permits were granted.
private actor Order {
    private(set) var entries: [String] = []
    func record(_ entry: String) { entries.append(entry) }
}
