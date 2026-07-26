//
//  PresentationClock.swift
//  VigilRTP
//
//  The drift-correcting media→host clock: a min-filter feeding a first-order PLL.
//  Implements docs/spec-rtp.md §11.4 and docs/API_CONTRACT.md §4.4 / §5.5
//  (`Clock/PresentationClock.swift`).
//

import Foundation
import VigilProtocols

/// Estimates `host ≈ offset + rate × media` for one track.
///
/// The camera's 90 kHz oscillator and the Mac's clock differ by tens to hundreds of parts per
/// million. Left uncorrected, an hour of viewing accumulates hundreds of milliseconds of apparent
/// latency that ends in a buffer flush and a visible hiccup.
///
/// **A min-filter, then a PLL — not an EWMA.** Arrival times are delayed asymmetrically by network
/// and OS queueing, so the observed offset distribution is right-skewed: its mean drifts upward with
/// congestion while its *minimum* stays an unbiased estimate of the true offset. An EWMA of that
/// distribution slowly inflates the latency estimate for no physical reason.
///
/// **Not a pacing mechanism.** Live display is `AVSampleBufferDisplayLayer` with
/// `DisplayImmediately` and no timebase, so nothing here decides when a frame is shown
/// (API_CONTRACT §2 R-26). This clock exists for the latency estimate, for A/V offset reporting and
/// for the recorded-playback timebase. Anything that starts sleeping until `hostTime(forMedia:)` has
/// misread its purpose.
public struct PresentationClock: Sendable {

    // MARK: - Nested Types

    /// The loop constants. Fixed by docs/spec-rtp.md §11.4; exposed so playback can widen them.
    public struct Tuning: Sendable, Hashable {
        /// Seconds of history the min-filter keeps.
        public var minFilterWindow: Double
        /// Proportional gain `Kp`, correcting the offset. ~0.8 s time constant at 25 fps.
        public var proportionalGain: Double
        /// Integral gain `Ki`, correcting the rate. ~50 s time constant.
        public var integralGain: Double
        /// Hard clamp on `|rateRatio - 1|`, i.e. ±5000 ppm at the live default.
        public var maxRateDeviation: Double
        /// A step error larger than this, in seconds, is a discontinuity and forces a hard reset.
        public var resetThreshold: Double
        /// Samples required before `isLocked` becomes true. 50 is 2 s at 25 fps.
        public var lockAfterSamples: Int

        /// Creates a tuning. The defaults are the live constants.
        public init(minFilterWindow: Double = 2.0,
                    proportionalGain: Double = 0.05,
                    integralGain: Double = 0.0008,
                    maxRateDeviation: Double = 0.005,
                    resetThreshold: Double = 0.5,
                    lockAfterSamples: Int = 50) {
            self.minFilterWindow = minFilterWindow
            self.proportionalGain = proportionalGain
            self.integralGain = integralGain
            self.maxRateDeviation = maxRateDeviation
            self.resetThreshold = resetThreshold
            self.lockAfterSamples = lockAfterSamples
        }

        /// Live viewing.
        public static let live = Tuning()

        /// Recorded playback: a longer window and softer gains, because a file's timestamps are
        /// exact and only the host clock drifts.
        public static let playback = Tuning(minFilterWindow: 5.0,
                                            proportionalGain: 0.02,
                                            integralGain: 0.0002,
                                            maxRateDeviation: 0.02,
                                            resetThreshold: 1.0,
                                            lockAfterSamples: 100)
    }

    /// One min-filter observation.
    private struct Sample {
        var hostSeconds: Double
        var raw: Double
    }

    // MARK: - Stored Properties

    /// The loop constants in force.
    public let tuning: Tuning

    /// Host seconds at media time zero: the `offset` of `host = offset + rate × media`.
    public private(set) var offsetSeconds: Double = 0

    /// Host seconds per media second. 1.0 means the two clocks agree.
    public private(set) var rateRatio: Double = 1.0

    /// True once `lockAfterSamples` observations have been folded in.
    public private(set) var isLocked = false

    /// How many observations have been folded in since the last reset.
    public private(set) var sampleCount = 0

    /// The min-filter window, oldest first.
    private var samples: [Sample] = []

    /// Index of the oldest live entry in `samples`; entries below it are dead but not yet compacted.
    private var head = 0

    /// Media seconds of the previous observation, for the rate term's denominator.
    private var lastMediaSeconds: Double?

    /// Compact `samples` once this many dead entries have accumulated, so dropping the front of the
    /// window is amortised O(1) rather than O(n) per frame.
    private static let compactionThreshold = 64

    // MARK: - Initialisation

    /// Creates an unlocked clock.
    public init(tuning: Tuning = .live) {
        self.tuning = tuning
        samples.reserveCapacity(128)
    }

    // MARK: - Computed Properties

    /// The smallest raw offset in the window: the unbiased estimate of the true offset, before the
    /// loop smooths it. `nil` before the first observation.
    public var minimumObservedOffsetSeconds: Double? {
        guard head < samples.count else { return nil }
        var minimum = samples[head].raw
        for index in (head + 1)..<samples.count {
            minimum = Swift.min(minimum, samples[index].raw)
        }
        return minimum
    }

    // MARK: - Public API

    /// Folds one frame's (media time, arrival instant) pair into the estimate.
    ///
    /// A step error larger than `resetThreshold` is treated as a discontinuity: the loop is reset
    /// and re-seeded on the new offset rather than dragged across the step over several seconds.
    public mutating func observe(mediaSeconds: Double, at hostTime: MediaInstant) {
        guard mediaSeconds.isFinite else { return }
        let hostSeconds = hostTime.seconds
        let raw = hostSeconds - mediaSeconds
        append(Sample(hostSeconds: hostSeconds, raw: raw))
        dropSamples(olderThan: hostSeconds - tuning.minFilterWindow)
        guard let filtered = minimumObservedOffsetSeconds else { return }

        guard sampleCount > 0 else {
            offsetSeconds = filtered
            rateRatio = 1.0
            lastMediaSeconds = mediaSeconds
            sampleCount = 1
            return
        }

        let predicted = offsetSeconds + (rateRatio - 1) * mediaSeconds
        let error = filtered - predicted

        if abs(error) > tuning.resetThreshold {
            let carried = Sample(hostSeconds: hostSeconds, raw: raw)
            reset()
            append(carried)
            offsetSeconds = filtered
            lastMediaSeconds = mediaSeconds
            sampleCount = 1
            return
        }

        offsetSeconds += tuning.proportionalGain * error
        let step = Swift.max(mediaSeconds - (lastMediaSeconds ?? mediaSeconds), 1e-3)
        rateRatio += tuning.integralGain * error / step
        rateRatio = Swift.min(Swift.max(rateRatio, 1 - tuning.maxRateDeviation),
                              1 + tuning.maxRateDeviation)
        lastMediaSeconds = mediaSeconds
        sampleCount += 1
        isLocked = sampleCount >= tuning.lockAfterSamples
    }

    /// The host instant at which media time `mediaSeconds` is due.
    public func hostTime(forMedia mediaSeconds: Double) -> MediaInstant {
        let seconds = offsetSeconds + rateRatio * mediaSeconds
        guard seconds.isFinite else { return MediaInstant(nanoseconds: 0) }
        return MediaInstant(nanoseconds: Int64(clampedNanoseconds(seconds)))
    }

    /// The media time corresponding to a host instant. The inverse of `hostTime(forMedia:)`.
    public func mediaSeconds(forHost hostTime: MediaInstant) -> Double {
        guard rateRatio != 0 else { return 0 }
        return (hostTime.seconds - offsetSeconds) / rateRatio
    }

    /// How long ago the frame at `mediaSeconds` was captured, in seconds.
    ///
    /// Positive when the frame is late relative to the estimated capture-to-arrival baseline, which
    /// is what the latency readout wants. Meaningful once `isLocked`; before that it is dominated by
    /// whatever the first few arrivals looked like.
    public func latencySeconds(forMedia mediaSeconds: Double, at now: MediaInstant) -> Double {
        now.seconds - (offsetSeconds + rateRatio * mediaSeconds)
    }

    /// Forgets the loop state and the window. Called on an SSRC change, a timestamp discontinuity,
    /// PAUSE/PLAY, a seek, or a step error above `resetThreshold`.
    public mutating func reset() {
        offsetSeconds = 0
        rateRatio = 1.0
        isLocked = false
        sampleCount = 0
        samples.removeAll(keepingCapacity: true)
        head = 0
        lastMediaSeconds = nil
    }

    // MARK: - Private

    /// Appends one sample, compacting the dead prefix when it has grown large enough.
    private mutating func append(_ sample: Sample) {
        if head >= Self.compactionThreshold {
            samples.removeFirst(head)
            head = 0
        }
        samples.append(sample)
    }

    /// Advances `head` past every sample older than `cutoff`, always leaving at least one.
    private mutating func dropSamples(olderThan cutoff: Double) {
        while head + 1 < samples.count, samples[head].hostSeconds < cutoff {
            head += 1
        }
    }

    /// Converts seconds to nanoseconds, saturating rather than trapping on a nonsensical estimate.
    private func clampedNanoseconds(_ seconds: Double) -> Double {
        let nanoseconds = seconds * 1e9
        return Swift.min(Swift.max(nanoseconds, -9.2e18), 9.2e18)
    }
}
