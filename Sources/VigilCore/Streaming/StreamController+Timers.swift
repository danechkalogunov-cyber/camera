//
//  StreamController+Timers.swift
//  VigilCore
//
//  The deadlines the controller keeps for itself.
//  Implements the subset of docs/spec-core.md §7.4 the first-light slice needs.
//
//  The session machine's own timers — request timeout, keepalive, data-idle, session expiry,
//  teardown grace — are armed and fired inside `VigilTransport.RTSPConnection`, which owns the
//  machine. What is left here is what only this layer can decide.
//
//  Deferred from §7.4's twenty rows, deliberately, because nothing in this slice can act on them:
//  `credentialLoad`, `tlsHandshake`, `setupPerTrack`, `setupTotal`, `mediaStallWarn`,
//  `mediaStallFail`, `recovery` and `degradedGiveUp` — the last four need the health monitor, so
//  `.degraded` is never entered in this slice and no stall is distinguished from a silence. Each is
//  a named row that lands with `HealthMonitor` in W4.
//

#if os(macOS)

import Foundation
import VigilProtocols

// MARK: - ControllerTimer

/// The deadlines the controller owns.
enum ControllerTimer: Hashable, Sendable {
    /// The whole connect sequence. Treated as the current state's timeout when it fires.
    case connectWatchdog
    /// First RTP packet after a successful `PLAY`.
    case firstRTP
    /// First complete access unit. Nudges once, then gives up.
    case firstFrame
    /// Continuous healthy playback before the attempt counter returns to zero.
    case healthyReset
    /// The 1 Hz telemetry tick.
    case statistics
}

// MARK: - Budgets

extension StreamController {

    /// TCP connect budget (spec-core §7.4). Handed to the session so **it** owns the deadline.
    static let connectTimeout: Duration = .seconds(4)

    /// The controller's own backstop around `connect()`: one second longer than the budget the
    /// session was given, and **derived from it** so the two cannot drift apart.
    ///
    /// `RTSPConnection.connect()` awaits a bare `CheckedContinuation` — cancelling the task that
    /// awaits it does **not** resume it, and `withDeadline`'s task group cannot return until every
    /// child has, so only the connection's own watchdog ever ends a hung connect. A backstop
    /// shorter than that watchdog would therefore not save any time; it would only make this side
    /// wait for the other side's timer with the cancellation already delivered. One second of grace
    /// keeps the backstop meaningful for a session factory whose implementation never times out at
    /// all. Writing it as `connectTimeout + 1 s` rather than as a second literal is the point:
    /// changing the factory budget alone used to leave a deadline that silently did nothing.
    static let connectDeadline: Duration = connectTimeout + .seconds(1)

    /// The whole connect sequence, from `resolving` to `playing`.
    static let overallWatchdog: Duration = .seconds(20)

    /// First RTP packet after `PLAY`.
    static let firstRTPTimeout: Duration = .seconds(4)

    /// When to ask for a keyframe if none has arrived.
    static let firstKeyframeNudge: Duration = .seconds(6)

    /// How much longer to wait after the nudge before giving up on the attempt.
    static let firstKeyframeGiveUp: Duration = .seconds(4)
}

// MARK: - Arming

extension StreamController {

    /// Arms one of the controller's deadlines, replacing any previous one with the same key.
    func armControllerTimer(_ key: ControllerTimer, after duration: Duration) {
        controllerTimers[key]?.cancel()
        let deadline = clock.now() + duration
        controllerTimers[key] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(until: deadline)
            } catch {
                return
            }
            await self.controllerTimerFired(key)
        }
    }

    /// Disarms one deadline. Disarming one that is not armed is not an error.
    func cancelControllerTimer(_ key: ControllerTimer) {
        controllerTimers[key]?.cancel()
        controllerTimers.removeValue(forKey: key)
    }

    /// Disarms everything. Called by `teardown()`, so no timer survives an attempt.
    func cancelAllTimers() {
        for task in controllerTimers.values { task.cancel() }
        controllerTimers.removeAll()
    }

    /// Acts on one deadline.
    func controllerTimerFired(_ key: ControllerTimer) async {
        controllerTimers.removeValue(forKey: key)
        switch key {
        case .connectWatchdog:
            guard !currentState.isActive else { return }
            await finish(with: StreamError(code: .connectTimeout,
                                           context: ["timer": "overallWatchdog",
                                                     "state": currentState.rawValue]))

        case .firstRTP:
            guard !sawFirstPacket else { return }
            // The slice is TCP-interleaved only, so there is no UDP-to-TCP fallback to try first
            // (spec-core §7.8's ladder); silence here means the session is not delivering.
            await finish(with: StreamError(code: .noMediaReceived))

        case .firstFrame:
            guard !sawFirstFrame else { return }
            if firstFrameNudges == 0 {
                firstFrameNudges = 1
                await requestKeyframe(now: clock.now())
                armControllerTimer(.firstFrame, after: Self.firstKeyframeGiveUp)
                return
            }
            await finish(with: StreamError(code: .noKeyframe))

        case .healthyReset:
            // A minute of continuous playback, so the ladder starts from 0.5 s next time. This is
            // the only thing that clears the counter (spec-core §7.6 rule 2) — and note that it
            // clears the *backoff*, never the authentication counter, which only a new password
            // clears.
            guard currentState.isActive else { return }
            attempt = 0
            logger.debug(.core, "backoff reset after healthy playback", ["camera": id.short])

        case .statistics:
            guard currentState.isActive else { return }
            var sample = latestStatistics
            sample.uptimeSeconds = (clock.now() - attemptStart).seconds
            sample.reconnectCount = UInt32(clamping: attempt)
            latestStatistics = sample
            emit(.statistics(sample))
            armControllerTimer(.statistics, after: .seconds(1))
        }
    }
}

#endif
