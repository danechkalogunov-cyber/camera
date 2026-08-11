//
//  VTheme+Health.swift
//  VigilUI
//
//  The single health-severity vocabulary and threshold table from DESIGN.md §9.20.
//

#if os(macOS)

import VigilProtocols

/// Discrete health severity used by telemetry values and their colour/glyph presentation.
public enum VLevel: Int, Sendable, Hashable, Comparable, CaseIterable {
    case ok, warn, danger

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public func worse(than other: VLevel) -> VLevel { self > other ? self : other }
}

public extension VTheme {

    /// Canonical thresholds for stream telemetry. Boundaries open the worse level with `>=`.
    enum Health {
        nonisolated public static let lossWarnFraction = 0.005
        nonisolated public static let lossDangerFraction = 0.02
        nonisolated public static let jitterWarnMilliseconds = 20.0
        nonisolated public static let jitterDangerMilliseconds = 60.0
        nonisolated public static let latencyWarnMilliseconds = 250.0
        nonisolated public static let latencyDangerMilliseconds = 600.0
        nonisolated public static let queueWarnFrames = 3
        nonisolated public static let queueDangerFrames = 6
        nonisolated public static let fpsDeviationWarn = 0.10
        nonisolated public static let fpsDeviationDanger = 0.25

        nonisolated public static func level(lossFraction: Double) -> VLevel {
            guard lossFraction.isFinite else { return .ok }
            if lossFraction >= lossDangerFraction { return .danger }
            if lossFraction >= lossWarnFraction { return .warn }
            return .ok
        }

        /// Contract spelling for callers whose value is already a loss fraction.
        nonisolated public static func level(loss: Double) -> VLevel {
            level(lossFraction: loss)
        }

        nonisolated public static func level(jitterMilliseconds value: Double) -> VLevel {
            guard value.isFinite else { return .ok }
            if value >= jitterDangerMilliseconds { return .danger }
            if value >= jitterWarnMilliseconds { return .warn }
            return .ok
        }

        nonisolated public static func level(jitterMS value: Double) -> VLevel {
            level(jitterMilliseconds: value)
        }

        nonisolated public static func level(latencyMilliseconds value: Double) -> VLevel {
            guard value.isFinite, value > 0 else { return .ok }
            if value >= latencyDangerMilliseconds { return .danger }
            if value >= latencyWarnMilliseconds { return .warn }
            return .ok
        }

        nonisolated public static func level(latencyMS value: Double) -> VLevel {
            level(latencyMilliseconds: value)
        }

        nonisolated public static func level(queueFrames value: Int) -> VLevel {
            if value >= queueDangerFrames { return .danger }
            if value >= queueWarnFrames { return .warn }
            return .ok
        }

        nonisolated public static func level(framesPerSecond measured: Double,
                                             target: Double) -> VLevel {
            guard measured.isFinite, target.isFinite, target > 0, measured > 0 else { return .ok }
            let deviation = abs(measured - target) / target
            if deviation >= fpsDeviationDanger { return .danger }
            if deviation >= fpsDeviationWarn { return .warn }
            return .ok
        }

        nonisolated public static func overall(
            _ stats: StreamStatistics,
            targetFramesPerSecond: Double = 0
        ) -> VLevel {
            [
                level(lossFraction: stats.lossFraction),
                level(jitterMilliseconds: stats.jitterMilliseconds),
                level(latencyMilliseconds: stats.estimatedLatencyMilliseconds),
                level(queueFrames: stats.decodeQueueDepth),
                level(framesPerSecond: stats.framesPerSecond, target: targetFramesPerSecond),
            ].reduce(.ok) { $0.worse(than: $1) }
        }
    }
}

#endif  // os(macOS)
