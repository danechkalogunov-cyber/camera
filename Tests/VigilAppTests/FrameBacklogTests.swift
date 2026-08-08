//
//  FrameBacklogTests.swift
//  VigilAppTests
//
//  The decode-queue depth the inspector prints, and the two rules that stop it being a lie.
//
//  ⛔ THIS TYPE EXISTS BECAUSE THE FIELD USED TO BE A HARD ZERO. Nothing filled `decodeQueueDepth`,
//  so it travelled to the panel as `0` — and `InspectorHealth` grades zero as a perfectly healthy
//  queue. A fabricated zero is worse than a dash, because it looks like an answer. Everything below
//  is about the number meaning what it says.
//

#if os(macOS)

import Testing

@testable import Vigil

@Suite("Frame backlog")
struct FrameBacklogTests {

    // MARK: - Counting

    /// Arrivals against departures: the depth is what is waiting in the stream between the
    /// controller and the detached decode loop.
    @Test func theDepthIsArrivalsMinusDepartures() {
        let backlog = FrameBacklog()

        for _ in 0..<5 { backlog.arrived() }
        backlog.departed()
        backlog.departed()

        #expect(backlog.depth() == 3)
    }

    /// ⛔ Departures can legitimately outnumber arrivals: the frame stream is
    /// `.bufferingNewest(64)` and drops its oldest when full, so the loop can drain frames the
    /// counter never saw. Clamped at zero rather than allowed to underflow — a negative depth read
    /// back through an unsigned field is an enormous queue, and the panel would report a decoder
    /// four billion frames behind.
    @Test func theDepthNeverGoesNegative() {
        let backlog = FrameBacklog()

        backlog.departed()
        backlog.departed()

        #expect(backlog.depth() == 0)

        backlog.arrived()
        #expect(backlog.depth() == 1, "and it counts up correctly again afterwards")
    }

    // MARK: - The peak

    /// ⛔ THE PANEL READS THE PEAK, NOT THE DEPTH, AND THAT IS THE WHOLE MEASUREMENT. At 25 fps a
    /// frame arrives every 40 ms and the loop drains it in far less, so the queue is empty almost
    /// all the time; a 1 Hz sample of the instantaneous depth is a coin flip that lands on zero.
    /// The peak answers what the panel is actually asking — did the decoder fall behind at any
    /// point in the last second.
    @Test func thePeakRemembersWhatTheInstantWouldHaveMissed() {
        let backlog = FrameBacklog()

        for _ in 0..<12 { backlog.arrived() }
        for _ in 0..<12 { backlog.departed() }

        #expect(backlog.depth() == 0, "an instantaneous read would report a healthy queue")
        #expect(backlog.takePeak() == 12, "the peak reports the second the decoder fell behind")
    }

    /// Reading the peak starts the next window at the **current** depth rather than at zero: frames
    /// still waiting are still waiting, and resetting to zero would under-report a queue that never
    /// drained.
    @Test func theNextWindowStartsFromWhatIsStillWaiting() {
        let backlog = FrameBacklog()
        for _ in 0..<10 { backlog.arrived() }
        for _ in 0..<6 { backlog.departed() }

        #expect(backlog.takePeak() == 10)
        #expect(backlog.takePeak() == 4, "four frames are still in the stream")
    }

    /// A quiet second reads zero, which is the one case where zero is the truth.
    @Test func aQuietSecondReadsZero() {
        let backlog = FrameBacklog()
        backlog.arrived()
        backlog.departed()

        #expect(backlog.takePeak() == 1)
        #expect(backlog.takePeak() == 0)
    }

    // MARK: - Reconnects

    /// A reconnect forgets everything. The frames counted belonged to a session that no longer
    /// exists, and carrying their peak into the new one would report a backlog the new decoder
    /// never had.
    @Test func aReconnectForgetsTheCount() {
        let backlog = FrameBacklog()
        for _ in 0..<20 { backlog.arrived() }

        backlog.reset()

        #expect(backlog.depth() == 0)
        #expect(backlog.takePeak() == 0)
    }
}

#endif  // os(macOS)
