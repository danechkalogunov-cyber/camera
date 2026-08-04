//
//  ReconnectPolicy.swift
//  VigilCore
//
//  The backoff ladder, its jitter, and the rule that decides when an attempt counter goes back to
//  zero.
//  Implements docs/spec-core.md §7.6 and docs/API_CONTRACT.md §4.8 / §5.12
//  (`Streaming/ReconnectPolicy.swift`).
//

#if os(macOS)

import Foundation
import VigilProtocols

/// How a controller waits between connect attempts.
///
/// Three rules are load-bearing and none of them are decoration:
///
/// 1. **Jitter is mandatory.** After a switch reboot, sixteen cameras would otherwise reconnect in
///    lockstep and collide on every attempt. ±20 % decorrelates them.
/// 2. **The counter resets after health, not after connect.** A camera that connects and dies three
///    seconds later must not reset its backoff, or the ladder degenerates into an endless 0.5 s
///    reconnect loop. `healthyResetInterval` of continuous playback is the only thing that clears
///    it.
/// 3. **The ladder is for transient failures only.** Authentication, a closed port, an unsupported
///    codec and a missing password never enter it — see `StreamError.Code.isUserFixable`.
public struct ReconnectPolicy: Sendable, Equatable {

    /// The ladder. Beyond the last entry, the last value repeats forever.
    public var delays: [Duration]

    /// Uniform jitter as a fraction of the base delay. ±20 %.
    public var jitterFraction: Double

    /// Continuous healthy playback required before the attempt counter returns to zero.
    public var healthyResetInterval: Duration

    /// Attempts before the controller gives up on the fast ladder and switches to cold retry.
    public var maxAttemptsBeforeCold: Int

    /// The cold-retry interval. Fixed, unjittered, and never used for an auth failure.
    public var coldRetryInterval: Duration

    /// Probe cadence while a previously reachable camera is rebooting. The probe performs no
    /// authentication; two seconds leaves the remaining half of L18's four-second budget for RTSP.
    public var rebootProbeInterval: Duration

    /// Builds a policy. The defaults are the contract's table.
    public init(delays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4),
                                      .seconds(8), .seconds(15), .seconds(30)],
                jitterFraction: Double = 0.20,
                healthyResetInterval: Duration = .seconds(60),
                maxAttemptsBeforeCold: Int = 20,
                coldRetryInterval: Duration = .seconds(300),
                rebootProbeInterval: Duration = .seconds(2)) {
        self.delays = delays
        self.jitterFraction = jitterFraction
        self.healthyResetInterval = healthyResetInterval
        self.maxAttemptsBeforeCold = maxAttemptsBeforeCold
        self.coldRetryInterval = coldRetryInterval
        self.rebootProbeInterval = rebootProbeInterval
    }

    /// The contract's policy: 0.5 / 1 / 2 / 4 / 8 / 15 / 30 s, ±20 %, reset after 60 s healthy.
    public static let `default` = ReconnectPolicy()

    /// The delay before attempt `attempt`, jittered.
    ///
    /// - Parameters:
    ///   - attempt: zero-based. Values past the end of the table take the last entry, so the
    ///     steady-state retry is 30 s ± 20 %. Negative values are treated as zero.
    ///   - random: the injected source, advanced by exactly one draw when `jitterFraction > 0` and
    ///     not at all when it is zero — so a seeded run is reproducible either way.
    /// - Returns: `.zero` only if the table is empty, which a caller cannot produce through the
    ///   public initialiser's default and which is treated as "retry immediately" rather than as a
    ///   reason to trap.
    public func delay(forAttempt attempt: Int, random: inout any RandomSource) -> Duration {
        guard !delays.isEmpty else { return .zero }
        let index = min(max(attempt, 0), delays.count - 1)
        let base = delays[index]
        let factor = random.jitterFactor(jitterFraction)
        let nanoseconds = Double(base.wholeNanoseconds) * factor
        return .nanoseconds(Int64(nanoseconds))
    }

    /// True when `attempt` has exhausted the fast ladder and the controller should fail over to the
    /// five-minute cold retry.
    public func hasExhaustedLadder(attempt: Int) -> Bool { attempt >= maxAttemptsBeforeCold }

    /// Reboot-shaped failures use a fast, credential-free reconnect probe instead of cold retry.
    public func offlineDelay(for code: StreamError.Code) -> Duration {
        switch code {
        case .connectionClosed, .sessionLost, .connectTimeout, .hostResolutionFailed,
             .transportError, .portClosed:
            rebootProbeInterval
        default:
            coldRetryInterval
        }
    }
}

#endif
