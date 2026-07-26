//
//  InspectorHealth.swift
//  VigilUI
//
//  Turning `StreamStatistics` into what the inspector shows: the health thresholds, and the formatted
//  value/unit pairs with their reserved widths.
//  macOS-only. Implements docs/DESIGN.md §9.20/§4.4 and docs/UX.md §6.2.
//
//  ⚠️ docs/DESIGN.md §12 specifies `VLevel` and `VTheme.Health.level(loss:)` in `Theme/`. Neither
//  exists in the code yet, and `Theme/` is not this slice's to write. So the level type and the three
//  thresholds are declared here, prefixed `Inspector` so they cannot collide with the `VLevel` that
//  will arrive later, and every one of them carries the DESIGN.md number it came from. When
//  `VTheme.Health` lands, this type should become a thin forwarder — one `switch`, deleted here — and
//  the tests below move with it. Flagged in the report.
//
//  Formatting is a pure function of the statistics, in its own type rather than inline in the views,
//  because "0.5 % is a warning and 2 % is a failure" is a product rule that deserves a test, and
//  because a threshold buried in a view body is a threshold nobody can find.
//

#if os(macOS)

import Foundation

import VigilProtocols

// MARK: - InspectorHealthLevel

/// How worried to be about a telemetry value.
///
/// Three levels, not a continuous score, because the design applies them as three discrete colours
/// plus three discrete glyphs (DESIGN.md §9.20 and the `differentiateWithoutColor` row of §11.4).
package enum InspectorHealthLevel: Int, Sendable, Hashable, Comparable, CaseIterable {

    /// Nothing to see.
    case ok

    /// Worth noticing. Amber stroke plus `exclamationmark.triangle.fill`.
    case warn

    /// Broken. Red stroke plus `xmark.octagon.fill`.
    case danger

    package static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The worse of two levels, for a row that summarises several values.
    package func worse(than other: InspectorHealthLevel) -> InspectorHealthLevel {
        self > other ? self : other
    }
}

// MARK: - InspectorHealth

/// The thresholds, straight from docs/DESIGN.md §9.20.
///
/// Each bound is `>=` for the level it opens, so the table's "0.5–2 %" reads as
/// `0.5 <= loss < 2`, and a value exactly on a boundary takes the *worse* level. That direction is
/// deliberate: a stream sitting exactly on 2 % loss is not healthy, and rounding a boundary in the
/// user's favour is how a fault gets reported as fine.
package enum InspectorHealth {

    /// Packet loss, as a fraction 0…1. DESIGN.md §9.20: ok < 0.5 %, warn 0.5–2 %, danger > 2 %.
    ///
    /// Takes a *fraction* because that is what ``StreamStatistics/lossFraction`` holds; the ×100 for
    /// display happens once, in ``InspectorStat/loss(_:)``. Two representations of the same number in
    /// one file is how a threshold ends up compared against a percentage.
    package static let lossWarnFraction = 0.005
    package static let lossDangerFraction = 0.02

    /// RFC 3550 interarrival jitter, in milliseconds. ok < 20, warn 20–60, danger > 60.
    package static let jitterWarnMilliseconds = 20.0
    package static let jitterDangerMilliseconds = 60.0

    /// Glass-to-glass latency estimate, in milliseconds. ok < 250, warn 250–600, danger > 600.
    package static let latencyWarnMilliseconds = 250.0
    package static let latencyDangerMilliseconds = 600.0

    /// Decode queue depth, in frames. ok ≤ 2, warn 3–5, danger > 5.
    ///
    /// ⚠️ DESIGN.md §9.20 says ≤2 / 3–5 / >5; UX.md §6.2 says "> 8 frames = warn". No `R-` ruling
    /// exists. DESIGN.md's is used because it is the table the shared `VHealthThresholds` is defined
    /// from, and because it is the stricter of the two — a queue of six frames at 25 fps is already a
    /// quarter-second behind, which the user can see. Reported.
    package static let queueWarnFrames = 3
    package static let queueDangerFrames = 6

    /// Tolerated deviation of measured fps from the stream's target. ok < 10 %, warn 10–25 %,
    /// danger > 25 %.
    package static let fpsDeviationWarn = 0.10
    package static let fpsDeviationDanger = 0.25

    /// The level for a packet-loss fraction.
    package static func level(lossFraction: Double) -> InspectorHealthLevel {
        guard lossFraction.isFinite else { return .ok }
        if lossFraction >= lossDangerFraction { return .danger }
        if lossFraction >= lossWarnFraction { return .warn }
        return .ok
    }

    /// The level for a jitter reading in milliseconds.
    package static func level(jitterMilliseconds value: Double) -> InspectorHealthLevel {
        guard value.isFinite else { return .ok }
        if value >= jitterDangerMilliseconds { return .danger }
        if value >= jitterWarnMilliseconds { return .warn }
        return .ok
    }

    /// The level for a latency estimate in milliseconds.
    ///
    /// A latency of exactly zero means "not yet measured", not "instantaneous", and reports `.ok`
    /// rather than a suspiciously perfect green: the RTCP anchor takes a few seconds to arrive and a
    /// zero here would otherwise read as a working measurement.
    package static func level(latencyMilliseconds value: Double) -> InspectorHealthLevel {
        guard value.isFinite, value > 0 else { return .ok }
        if value >= latencyDangerMilliseconds { return .danger }
        if value >= latencyWarnMilliseconds { return .warn }
        return .ok
    }

    /// The level for a decode-queue depth.
    package static func level(queueFrames value: Int) -> InspectorHealthLevel {
        if value >= queueDangerFrames { return .danger }
        if value >= queueWarnFrames { return .warn }
        return .ok
    }

    /// The level for measured fps against a target.
    ///
    /// A target of zero or an unmeasured rate reports `.ok`: we do not know the target for every
    /// stream, and inventing a fault from a missing denominator is worse than saying nothing.
    package static func level(framesPerSecond measured: Double,
                              target: Double) -> InspectorHealthLevel {
        guard measured.isFinite, target.isFinite, target > 0, measured > 0 else { return .ok }
        let deviation = abs(measured - target) / target
        if deviation >= fpsDeviationDanger { return .danger }
        if deviation >= fpsDeviationWarn { return .warn }
        return .ok
    }

    /// The worst level across the whole sample — what the inspector header's status dot shows.
    package static func overall(_ stats: StreamStatistics,
                                targetFramesPerSecond: Double = 0) -> InspectorHealthLevel {
        [
            level(lossFraction: stats.lossFraction),
            level(jitterMilliseconds: stats.jitterMilliseconds),
            level(latencyMilliseconds: stats.estimatedLatencyMilliseconds),
            level(queueFrames: stats.decodeQueueDepth),
            level(framesPerSecond: stats.framesPerSecond, target: targetFramesPerSecond),
        ].reduce(.ok) { $0.worse(than: $1) }
    }
}

// MARK: - InspectorStat

/// One formatted telemetry readout: its value, its unit, its health and the width to reserve for it.
///
/// The value and unit are separate strings because DESIGN.md §4.4 styles them differently — value
/// `text.primary`, unit `text.tertiary` — and because the reserved width applies to the value alone.
package struct InspectorStat: Sendable, Hashable {

    /// The number, already formatted and ready to render with `monospacedDigit()`.
    package let value: String

    /// The unit, or an empty string when there is none.
    package let unit: String

    /// How worried to be.
    package let level: InspectorHealthLevel

    /// The width to reserve, from `VTheme.Typography.Reserved`. Passed through as a `Double` so this
    /// type stays free of the theme and therefore of SwiftUI.
    package let reservedWidth: Double

    package init(value: String, unit: String, level: InspectorHealthLevel,
                 reservedWidth: Double) {
        self.value = value
        self.unit = unit
        self.level = level
        self.reservedWidth = reservedWidth
    }

    /// Value and unit joined, for VoiceOver and for a tooltip.
    package var spoken: String { unit.isEmpty ? value : "\(value) \(unit)" }
}

// MARK: - Formatters

extension InspectorStat {

    /// `VTheme.Typography.Reserved` widths, restated as plain numbers.
    ///
    /// Duplicated rather than imported so this file needs no SwiftUI. The values are asserted equal to
    /// the tokens by a test, so the copy cannot drift silently — which is the only defensible way to
    /// duplicate a constant.
    package enum Reserved {
        package static let fps: Double = 46
        package static let bitrate: Double = 62
        package static let latency: Double = 46
        package static let loss: Double = 46
        package static let jitter: Double = 46
        package static let timecode: Double = 92
        package static let resolution: Double = 74
    }

    /// Frames per second — `"25"` + `"fps"`.
    ///
    /// Zero decimals per DESIGN.md §4.4's table. ⚠️ UX.md §6.1's wireframe shows `25.0`; the table is
    /// followed because it is the one that also fixes the 46 pt reserved width, and `25.0 fps` does not
    /// fit it. Reported.
    package static func framesPerSecond(_ value: Double,
                                        target: Double = 0) -> InspectorStat {
        InspectorStat(value: Self.fixed(value, places: 0),
                      unit: "fps",
                      level: InspectorHealth.level(framesPerSecond: value, target: target),
                      reservedWidth: Reserved.fps)
    }

    /// Bitrate — `"4.1"` + `"Mb/s"`, switching to `"kb/s"` below 1 Mb/s.
    ///
    /// The unit switch matters: a sub-stream at 380 kb/s reads `"0.4 Mb/s"` otherwise, which throws
    /// away the digit the user is looking at. One decimal per DESIGN.md §4.4.
    package static func bitrate(bitsPerSecond: Double) -> InspectorStat {
        guard bitsPerSecond.isFinite, bitsPerSecond > 0 else {
            return InspectorStat(value: "—", unit: "Mb/s", level: .ok,
                                 reservedWidth: Reserved.bitrate)
        }
        let megabits = bitsPerSecond / 1_000_000
        if megabits < 1 {
            return InspectorStat(value: Self.fixed(bitsPerSecond / 1_000, places: 0),
                                 unit: "kb/s", level: .ok, reservedWidth: Reserved.bitrate)
        }
        return InspectorStat(value: Self.fixed(megabits, places: 1), unit: "Mb/s", level: .ok,
                             reservedWidth: Reserved.bitrate)
    }

    /// Packet loss — `"0.02"` + `"%"`. Two decimals, and the fraction is scaled here, once.
    package static func loss(fraction: Double) -> InspectorStat {
        InspectorStat(value: Self.fixed(max(0, fraction) * 100, places: 2),
                      unit: "%",
                      level: InspectorHealth.level(lossFraction: fraction),
                      reservedWidth: Reserved.loss)
    }

    /// Jitter — `"2.4"` + `"ms"`. One decimal per DESIGN.md §4.4.
    package static func jitter(milliseconds: Double) -> InspectorStat {
        InspectorStat(value: Self.fixed(milliseconds, places: 1),
                      unit: "ms",
                      level: InspectorHealth.level(jitterMilliseconds: milliseconds),
                      reservedWidth: Reserved.jitter)
    }

    /// Latency — `"184"` + `"ms"`. Zero decimals; an unmeasured estimate shows an em dash rather than
    /// a confident `0 ms`.
    package static func latency(milliseconds: Double) -> InspectorStat {
        guard milliseconds.isFinite, milliseconds > 0 else {
            return InspectorStat(value: "—", unit: "ms", level: .ok,
                                 reservedWidth: Reserved.latency)
        }
        return InspectorStat(value: Self.fixed(milliseconds, places: 0),
                             unit: "ms",
                             level: InspectorHealth.level(latencyMilliseconds: milliseconds),
                             reservedWidth: Reserved.latency)
    }

    /// Decode queue depth — `"2"` + `"frames"`.
    package static func decodeQueue(frames: Int) -> InspectorStat {
        InspectorStat(value: String(frames),
                      unit: frames == 1 ? "frame" : "frames",
                      level: InspectorHealth.level(queueFrames: frames),
                      reservedWidth: Reserved.fps)
    }

    /// Keyframe interval — `"2.0"` + `"s"`, with the measured GOP length when the fps is known.
    ///
    /// "Measured, not reported" (UX.md §6.2): the device's configured GOP and its actual one differ,
    /// and the actual one is what explains a slow start.
    package static func keyframeInterval(seconds: Double, framesPerSecond: Double) -> InspectorStat {
        guard seconds.isFinite, seconds > 0 else {
            return InspectorStat(value: "—", unit: "s", level: .ok, reservedWidth: Reserved.fps)
        }
        let unit: String
        if framesPerSecond.isFinite, framesPerSecond > 0 {
            unit = "s (GOP \(Int((seconds * framesPerSecond).rounded())))"
        } else {
            unit = "s"
        }
        return InspectorStat(value: Self.fixed(seconds, places: 1), unit: unit, level: .ok,
                             reservedWidth: Reserved.fps)
    }

    /// Resolution — `"1920×1080"`, with no unit.
    package static func resolution(width: Int, height: Int) -> InspectorStat {
        guard width > 0, height > 0 else {
            return InspectorStat(value: "—", unit: "", level: .ok,
                                 reservedWidth: Reserved.resolution)
        }
        // A true multiplication sign, not the letter x: it is what DESIGN.md §4.4's table shows and it
        // aligns with digits in the monospaced face.
        return InspectorStat(value: "\(width)\u{00D7}\(height)", unit: "", level: .ok,
                             reservedWidth: Reserved.resolution)
    }

    /// Fixed-point formatting without `String(format:)`, which is locale-sensitive on the decimal
    /// separator in ways that would make these tests depend on the host.
    ///
    /// ⚠️ Deliberately NOT localised. A telemetry readout is a diagnostic value that gets pasted into
    /// a bug report and compared with a colleague's, so a comma decimal separator would make two
    /// screenshots of the same fault look like different faults. `Scripts/check-localizations.py` sees
    /// no key here because there is none to see; the *units* beside these numbers are ASCII symbols
    /// (`%`, `ms`, `Mb/s`, `fps`) that are unchanged in every locale this product ships. Raised in the
    /// report as the one place I chose not to localise, so the decision is reviewable rather than
    /// accidental.
    static func fixed(_ value: Double, places: Int) -> String {
        guard value.isFinite else { return "—" }
        let scale = pow(10.0, Double(places))
        let rounded = (value * scale).rounded() / scale
        guard places > 0 else { return String(Int(rounded)) }
        let whole = rounded < 0 ? Int(-rounded) : Int(rounded)
        let fractionScale = Int(scale)
        let fraction = Int((abs(rounded) * scale).rounded()) % fractionScale
        var digits = String(fraction)
        while digits.count < places { digits = "0" + digits }
        return (rounded < 0 ? "-" : "") + String(whole) + "." + digits
    }
}

#endif  // os(macOS)
