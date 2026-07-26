//
//  RTSPConnection+Timers.swift
//  VigilTransport
//
//  `RTSPAction.setTimer` / `.cancelTimer` turned into cancellable `Task`s on the injected monotonic
//  clock: one timer per `RTSPTimerID`, re-arming replaces rather than stacks, and a fire that loses
//  a race with its own replacement is discarded.
//  Implements docs/API_CONTRACT.md §5.9 (`RTSPConnection+Timers.swift`) and docs/spec-rtsp.md §14.3.
//
//  Not compiled in this container — see the header of RTSPConnection.swift. Nothing here touches a
//  framework, though: the only unverifiable part of this file is the code it is attached to.
//

#if os(macOS)

import Foundation
import VigilProtocols
import VigilRTSP

// MARK: - Timers

extension RTSPConnection {

    /// Arms or re-arms one timer.
    ///
    /// `.setTimer` with an id that is already armed **replaces** it and does not stack
    /// (docs/spec-rtsp.md §14.3), which matters most for `.dataIdle`: the machine re-arms it lazily
    /// rather than on every packet, and a stacking implementation would end the session on the
    /// first stale deadline.
    ///
    /// The deadline is an instant on the injected clock, so a session driven by a virtual clock
    /// times out at exactly the same point every run.
    func arm(_ id: RTSPTimerID, deadline: MediaInstant) {
        guard isRunning else { return }

        let generation = nextTimerGeneration
        nextTimerGeneration &+= 1

        // Cancel before replacing: the old task may already be past its sleep and on its way in,
        // and the generation check in `timerFired` is what stops it being honoured if so.
        timers[id]?.task.cancel()

        let task = Task { [weak self, clock] in
            do {
                // `MonotonicClock.sleep(until:)` returns immediately when the deadline has already
                // passed — without a cancellation check, per its documentation — so the explicit
                // check below is not redundant.
                try await clock.sleep(until: deadline)
            } catch {
                return                              // cancelled: the timer was disarmed or replaced
            }
            guard !Task.isCancelled else { return }
            await self?.timerFired(id, generation: generation)
        }

        timers[id] = TimerSlot(generation: generation, task: task)
    }

    /// Disarms one timer. Disarming one that is not armed is not an error (docs/spec-rtsp.md §14.3).
    func disarm(_ id: RTSPTimerID) {
        guard let slot = timers.removeValue(forKey: id) else { return }
        slot.task.cancel()
    }

    /// Disarms every timer. Called once, when the connection starts closing.
    func disarmAllTimers() {
        for slot in timers.values {
            slot.task.cancel()
        }
        timers.removeAll()
    }

    /// One timer's deadline arrived, already hopped onto the actor.
    ///
    /// Three things can have happened while the fire was in flight, and all three end here quietly:
    /// the connection closed, the timer was disarmed, or the timer was re-armed with a later
    /// deadline. The last is what the generation number is for — the id would still be present in
    /// the table, so an id-only check would let a superseded deadline expire the session early.
    private func timerFired(_ id: RTSPTimerID, generation: UInt64) {
        guard isRunning else { return }
        guard let slot = timers[id], slot.generation == generation else { return }
        timers[id] = nil

        let now = clock.now()
        let fired = machine.timerFired(id, now: now)
        execute(fired)
        let stepped = machine.step(now: now)
        execute(stepped)
    }
}

#endif
