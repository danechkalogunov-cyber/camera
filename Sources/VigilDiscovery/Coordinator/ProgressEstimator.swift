//
//  ProgressEstimator.swift
//  VigilDiscovery
//
//  The arithmetic behind the progress bar, the ETA and the run deadline. Pure and time-injected: it
//  is told what the elapsed time is and never asks a clock, so every number reproduces exactly.
//  Implements docs/spec-discovery.md §8.2 and §8.3.
//

import VigilProtocols

// MARK: - Deadlines

/// How long a run is allowed to take.
///
/// A `/24` finishes in a couple of seconds; a `/16` cannot, and pretending otherwise means a user
/// staring at a bar that never fills. The rule is 12 s for up to 254 hosts and 8 s more per doubling,
/// capped at 3 minutes — after which the run stops with results and offers to keep scanning.
public enum DiscoveryDeadline {

    /// Base allowance, for a `/24` or smaller.
    public static let base = Duration.seconds(12)
    /// Added per doubling of the host count.
    public static let perDoubling = Duration.seconds(8)
    /// Hard ceiling. No configuration lifts it.
    public static let ceiling = Duration.seconds(180)
    /// A unicast sweep is inherently slower than a multicast round trip (§9.5).
    public static let degradedMultiplier = 1.4

    /// The deadline for a plan of `hostsPlanned` addresses.
    ///
    /// `hostsPlanned` at or below 254 yields the base allowance; zero and negative values are
    /// treated as zero rather than trapping, so an empty plan still has a sane deadline.
    public static func overall(hostsPlanned: Int) -> Duration {
        let hosts = max(hostsPlanned, 0)
        guard hosts > 254 else { return base }
        var doublings = 0
        var threshold = 254
        while threshold * 2 <= hosts, doublings < 32 {
            threshold *= 2
            doublings += 1
        }
        let seconds = 12.0 + 8.0 * Double(doublings)
        return .seconds(min(180.0, seconds))
    }

    /// The deadline when multicast is unavailable and the run degraded to a unicast sweep.
    public static func degraded(hostsPlanned: Int) -> Duration {
        let seconds = overall(hostsPlanned: hostsPlanned).asSeconds * degradedMultiplier
        return .seconds(min(180.0, seconds))
    }
}

// MARK: - Progress estimation

/// Accumulates a run's counters and turns them into a `DiscoveryProgress`.
///
/// Three rules exist purely so the UI stays believable, and each is enforced here rather than left
/// to the view:
///
/// * `fraction` never decreases. Tier B work grows the denominator mid-run; when that happens the
///   bar slows down instead of jumping backwards.
/// * the ETA is suppressed for the first 750 ms and whenever throughput is too low to extrapolate
///   from — no number at all beats a wrong one.
/// * a displayed ETA may never grow by more than 20 % between emissions. A jittery ETA reads as a
///   broken app even when the underlying arithmetic is correct.
public struct DiscoveryProgressEstimator: Sendable {

    /// Weight of the sweep in the overall fraction (§8.2).
    public static let sweepWeight = 0.75
    /// Weight of the multicast window.
    public static let multicastWeight = 0.25
    /// EWMA smoothing factor for throughput.
    public static let throughputAlpha = 0.2
    /// Below this many hosts per second, no ETA is shown.
    public static let minimumThroughput = 0.5
    /// The bar is indeterminate for this long.
    public static let indeterminateWindow = Duration.milliseconds(300)
    /// The ETA is suppressed for this long.
    public static let etaSuppressionWindow = Duration.milliseconds(750)
    /// Maximum progress emissions per second (§8.1).
    public static let maximumEmissionRate = 20.0

    // MARK: Counters

    public private(set) var hostsPlanned: Int
    public private(set) var hostsProbed = 0
    public private(set) var hostsAlive = 0
    public private(set) var portProbesCompleted = 0
    public private(set) var portProbesPlanned: Int
    public private(set) var devicesFound = 0
    public private(set) var candidatesFound = 0
    /// The full multicast listening window, used as the denominator of its fraction.
    public private(set) var multicastWindow: Duration
    /// True once `cancel()` has been called: the bar freezes and the ETA disappears.
    public private(set) var isCancelled = false

    private var throughput = 0.0
    private var hasThroughputSample = false
    private var lastTickElapsed = Duration.zero
    private var hostsAtLastTick = 0
    private var lastFraction = 0.0
    private var lastReportedETASeconds: Double?
    private var lastEmissionElapsed: Duration?

    /// Creates an estimator for a plan.
    ///
    /// - Parameters:
    ///   - hostsPlanned: addresses in `DiscoveryPlan.hostOrder`. Zero is legal — a multicast-only
    ///     run plans no hosts — and makes the sweep half of the fraction complete from the start.
    ///   - portsPerHost: tier A ports, the initial multiplier for `portProbesPlanned`.
    ///   - multicastWindow: how long multicast will listen. Zero when multicast is not running.
    public init(hostsPlanned: Int, portsPerHost: Int = 2, multicastWindow: Duration = .zero) {
        let hosts = max(hostsPlanned, 0)
        self.hostsPlanned = hosts
        self.portProbesPlanned = hosts * max(portsPerHost, 0)
        self.multicastWindow = multicastWindow
    }

    // MARK: Updates

    /// Adds port probes to the denominator, as tier B and C work is scheduled.
    public mutating func schedulePortProbes(_ count: Int) {
        portProbesPlanned += max(count, 0)
    }

    /// Records completed port probes.
    public mutating func completePortProbes(_ count: Int = 1) {
        portProbesCompleted += max(count, 0)
    }

    /// Records that a host finished its tier A probes.
    public mutating func completeHost(alive: Bool) {
        hostsProbed += 1
        if alive { hostsAlive += 1 }
    }

    /// Updates the device counters from the merge engine.
    public mutating func setDeviceCounts(found: Int, candidates: Int) {
        devicesFound = max(found, 0)
        candidatesFound = max(candidates, 0)
    }

    /// Folds a throughput sample. Call once per 100 ms tick with the run's elapsed time.
    ///
    /// The first sample seeds the average rather than being smoothed against zero, so an ETA appears
    /// as soon as it is meaningful instead of creeping up from nothing. A tick with no elapsed time
    /// since the last one is ignored: dividing by zero would produce an infinite throughput and an
    /// ETA of zero.
    public mutating func tick(at elapsed: Duration) {
        let interval = (elapsed - lastTickElapsed).asSeconds
        guard interval > 0 else { return }
        let completed = Double(hostsProbed - hostsAtLastTick)
        let instant = completed / interval
        if hasThroughputSample {
            throughput = Self.throughputAlpha * instant + (1 - Self.throughputAlpha) * throughput
        } else {
            throughput = instant
            hasThroughputSample = true
        }
        lastTickElapsed = elapsed
        hostsAtLastTick = hostsProbed
    }

    /// Freezes the estimator: the fraction stops where it is and the ETA disappears. Called when the
    /// user cancels, because an ETA for work that will never happen is a lie.
    public mutating func cancel() {
        isCancelled = true
    }

    // MARK: Emission throttle

    /// Whether a progress event should be emitted now (§8.1).
    ///
    /// Throttled to 20 Hz, except that `force` — set by any device event — always emits, so the
    /// counter never lags a row the user can already see.
    public mutating func shouldEmit(at elapsed: Duration, force: Bool = false) -> Bool {
        guard !force else {
            lastEmissionElapsed = elapsed
            return true
        }
        guard let last = lastEmissionElapsed else {
            lastEmissionElapsed = elapsed
            return true
        }
        guard (elapsed - last).asSeconds >= 1.0 / Self.maximumEmissionRate else { return false }
        lastEmissionElapsed = elapsed
        return true
    }

    // MARK: Snapshot

    /// Builds the progress value for `elapsed`.
    ///
    /// Mutating because the monotonic fraction guard and the ETA clamp both carry state from one
    /// snapshot to the next — that state is the whole point.
    public mutating func snapshot(at elapsed: Duration, phase: DiscoveryPhase = .planning,
                                  activePhases: Set<DiscoveryPhase> = []) -> DiscoveryProgress {
        let multicastRemaining = remainingMulticast(at: elapsed)
        let fraction = updatedFraction(at: elapsed, multicastRemaining: multicastRemaining)
        let eta = updatedETA(at: elapsed, multicastRemaining: multicastRemaining)
        return DiscoveryProgress(
            phase: phase,
            activePhases: activePhases,
            devicesFound: devicesFound,
            candidatesFound: candidatesFound,
            hostsPlanned: hostsPlanned,
            hostsProbed: hostsProbed,
            hostsAlive: hostsAlive,
            portProbesCompleted: portProbesCompleted,
            portProbesPlanned: portProbesPlanned,
            multicastWindowRemaining: multicastRemaining,
            elapsed: elapsed,
            estimatedRemaining: eta,
            throughputHostsPerSecond: throughput,
            fraction: fraction)
    }

    /// How much of the multicast listening window is left.
    private func remainingMulticast(at elapsed: Duration) -> Duration {
        guard multicastWindow > .zero, !isCancelled else { return .zero }
        let remaining = multicastWindow.asSeconds - elapsed.asSeconds
        return remaining > 0 ? .seconds(remaining) : .zero
    }

    /// The weighted, monotonic fraction. `nil` for the indeterminate opening window.
    private mutating func updatedFraction(at elapsed: Duration,
                                          multicastRemaining: Duration) -> Double? {
        // A cancelled run's bar stops where it was. Recomputing would let it jump forward — the
        // multicast window is "over", after all — which reads as the scan finishing, not stopping.
        guard !isCancelled else {
            return elapsed >= Self.indeterminateWindow ? lastFraction : nil
        }
        let sweepFraction = portProbesPlanned == 0
            ? 1.0
            : min(1.0, Double(portProbesCompleted) / Double(portProbesPlanned))
        let multicastFraction = multicastWindow > .zero
            ? min(1.0, max(0.0, 1.0 - multicastRemaining.asSeconds / multicastWindow.asSeconds))
            : 1.0
        let combined = Self.sweepWeight * sweepFraction + Self.multicastWeight * multicastFraction
        // Monotonic: a denominator that grew must slow the bar, never reverse it.
        lastFraction = max(lastFraction, min(1.0, max(0.0, combined)))
        guard elapsed >= Self.indeterminateWindow else { return nil }
        return lastFraction
    }

    /// The ETA, with every suppression and clamping rule applied.
    private mutating func updatedETA(at elapsed: Duration,
                                     multicastRemaining: Duration) -> Duration? {
        guard !isCancelled else {
            lastReportedETASeconds = nil
            return nil
        }
        guard elapsed >= Self.etaSuppressionWindow else { return nil }
        guard throughput >= Self.minimumThroughput else {
            // No sweep estimate. If multicast is still listening, that window is a real, known wait
            // and is worth reporting on its own.
            if multicastRemaining > .zero {
                return clampUpwardDrift(multicastRemaining.asSeconds)
            }
            lastReportedETASeconds = nil
            return nil
        }
        let remainingHosts = Double(max(0, hostsPlanned - hostsProbed))
        let sweepSeconds = remainingHosts / throughput
        return clampUpwardDrift(max(sweepSeconds, multicastRemaining.asSeconds))
    }

    /// Allows an ETA to fall freely but to rise by at most 20 % per emission.
    private mutating func clampUpwardDrift(_ seconds: Double) -> Duration {
        var value = max(0, seconds)
        if let previous = lastReportedETASeconds, value > previous * 1.2 {
            value = previous * 1.2
        }
        lastReportedETASeconds = value
        return .seconds(value)
    }
}

// MARK: - Duration helpers

extension Duration {
    /// The duration in seconds as a `Double`. Convenience for the ratio arithmetic above; precision
    /// far beyond a millisecond is irrelevant to a progress bar.
    var asSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
