//
//  StreamStatisticsCollector+Minutes.swift
//  Vigil
//
//  One-minute aggregation for the bounded 24-hour diagnostics history.
//

#if os(macOS)

import VigilProtocols

/// Averages gauges while retaining the newest cumulative counters and diagnostic state.
struct MinuteStatisticsAccumulator: Sendable {
    private var latest: StreamStatistics?
    private var count = 0
    private var fps = 0.0
    private var bits = 0.0
    private var keyframe = 0.0
    private var loss = 0.0
    private var jitter = 0.0
    private var jitterDepth = 0.0
    private var latency = 0.0
    private var decodeDepth = 0.0
    private var decodeP50 = 0.0
    private var decodeP99 = 0.0

    mutating func add(_ sample: StreamStatistics) {
        latest = sample
        count += 1
        fps += sample.framesPerSecond
        bits += sample.bitsPerSecond
        keyframe += sample.keyframeIntervalSeconds
        loss += sample.lossFraction
        jitter += sample.jitterMilliseconds
        jitterDepth += sample.jitterBufferDepthMilliseconds
        latency += sample.estimatedLatencyMilliseconds
        decodeDepth += Double(sample.decodeQueueDepth)
        decodeP50 += sample.decodeMillisecondsP50
        decodeP99 += sample.decodeMillisecondsP99
    }

    var aggregate: StreamStatistics? {
        guard var result = latest, count > 0 else { return nil }
        let divisor = Double(count)
        result.framesPerSecond = fps / divisor
        result.bitsPerSecond = bits / divisor
        result.keyframeIntervalSeconds = keyframe / divisor
        result.lossFraction = loss / divisor
        result.jitterMilliseconds = jitter / divisor
        result.jitterBufferDepthMilliseconds = jitterDepth / divisor
        result.estimatedLatencyMilliseconds = latency / divisor
        result.decodeQueueDepth = Int((decodeDepth / divisor).rounded())
        result.decodeMillisecondsP50 = decodeP50 / divisor
        result.decodeMillisecondsP99 = decodeP99 / divisor
        return result
    }
}

#endif  // os(macOS)
