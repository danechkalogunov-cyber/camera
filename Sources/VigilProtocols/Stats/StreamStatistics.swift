//
//  StreamStatistics.swift
//  VigilProtocols
//
//  Per-stream telemetry: the 1 Hz sample that feeds the inspector, the Stream Doctor
//  and the diagnostics bundle, plus the smoothing algebra that maintains it.
//
//  Implements docs/API_CONTRACT.md §3.8 (ruling R-19).
//

/// Per-stream telemetry. **Shape is fixed here; `VigilRTP` owns the update algebra**
/// (fps EWMA α 0.10, kbps EWMA α 0.25 over a 500 ms window, keyframe-interval EWMA α 0.20, loss
/// fraction over 2 s, jitter per RFC 3550 A.8 converted from timescale units to milliseconds).
/// `VigilVideo` writes the four decode fields through `RTPTrackReceiver`'s setters.
///
/// Sampled at 1 Hz by `HealthMonitor` into a fixed 600-slot ring per camera.
public struct StreamStatistics: Sendable, Hashable, Codable {
    // Throughput
    public var framesDecoded: UInt64 = 0
    public var framesPerSecond: Double = 0
    public var bitsPerSecond: Double = 0
    public var keyframeIntervalSeconds: Double = 0
    // Loss and order
    public var packetsReceived: UInt64 = 0
    public var packetsLost: UInt64 = 0
    public var packetsOutOfOrder: UInt64 = 0
    public var packetsDuplicated: UInt64 = 0
    /// Over the last 2 s window, 0...1.
    public var lossFraction: Double = 0
    public var gapCount: UInt32 = 0
    // Timing
    public var jitterMilliseconds: Double = 0
    public var jitterBufferDepthPackets: Int = 0
    public var jitterBufferDepthMilliseconds: Double = 0
    /// Capture→display estimate, RTCP-anchored. Must land within ±25 ms of the physical rig.
    public var estimatedLatencyMilliseconds: Double = 0
    // Decode — written by VigilVideo
    public var decodeQueueDepth: Int = 0
    public var framesDroppedPreDecode: UInt64 = 0
    public var framesDroppedPreDisplay: UInt64 = 0
    public var decodeMillisecondsP50: Double = 0
    public var decodeMillisecondsP99: Double = 0
    /// **Measured**, from `kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder` —
    /// never the requested value. Honesty is a shipping requirement.
    public var isHardwareAccelerated: Bool = false
    // Session
    public var uptimeSeconds: Double = 0
    public var reconnectCount: UInt32 = 0
    /// A `diagnosticCode` such as `VG-RTSP-0401`, never a message.
    public var lastErrorCode: String?

    public init() {}
}

// MARK: - Smoothing

public extension StreamStatistics {

    /// EWMA smoothing factor for `framesPerSecond`. Slow, because a frame rate that visibly
    /// oscillates in the inspector reads as a bug even when the stream is fine.
    static let framesPerSecondAlpha = 0.10
    /// EWMA smoothing factor for `bitsPerSecond`, sampled over a 500 ms window.
    static let bitsPerSecondAlpha = 0.25
    /// EWMA smoothing factor for `keyframeIntervalSeconds`.
    static let keyframeIntervalAlpha = 0.20

    /// One exponentially weighted moving-average step: `α × sample + (1 − α) × previous`.
    ///
    /// A `previous` of exactly zero means "unseeded" and the sample is adopted whole, so the first
    /// reading is the truth rather than a tenth of it. Non-finite samples — which a division by a
    /// zero-length window produces — leave the average untouched. `alpha` is clamped to `0...1`.
    ///
    /// Declared here, on the type that owns the fields, so there is exactly one implementation and
    /// it is testable on Linux; `VigilRTP` drives it (API_CONTRACT §2 R-19).
    static func ewma(previous: Double, sample: Double, alpha: Double) -> Double {
        guard sample.isFinite else { return previous }
        guard previous != 0, previous.isFinite else { return sample }
        let a = Swift.min(1, Swift.max(0, alpha))
        return a * sample + (1 - a) * previous
    }

    /// Folds a new frame-rate measurement into `framesPerSecond` with `framesPerSecondAlpha`.
    mutating func updateFramesPerSecond(sample: Double) {
        framesPerSecond = Self.ewma(previous: framesPerSecond, sample: sample,
                                    alpha: Self.framesPerSecondAlpha)
    }

    /// Folds a new throughput measurement into `bitsPerSecond` with `bitsPerSecondAlpha`.
    mutating func updateBitsPerSecond(sample: Double) {
        bitsPerSecond = Self.ewma(previous: bitsPerSecond, sample: sample,
                                  alpha: Self.bitsPerSecondAlpha)
    }

    /// Folds a new keyframe spacing into `keyframeIntervalSeconds` with `keyframeIntervalAlpha`.
    mutating func updateKeyframeInterval(sample: Double) {
        keyframeIntervalSeconds = Self.ewma(previous: keyframeIntervalSeconds, sample: sample,
                                            alpha: Self.keyframeIntervalAlpha)
    }

    /// Sets `lossFraction` from one window's counts, clamped to `0...1`.
    ///
    /// `lost` is the number of packets the sequence numbers say never arrived; `received` is what
    /// did arrive in the same window. An empty window (both zero) leaves the fraction at zero
    /// rather than producing a NaN that would propagate into the health ring and the UI.
    mutating func updateLossFraction(received: UInt64, lost: UInt64) {
        let total = received &+ lost
        guard total > 0 else {
            lossFraction = 0
            return
        }
        lossFraction = Swift.min(1, Double(lost) / Double(total))
    }
}
