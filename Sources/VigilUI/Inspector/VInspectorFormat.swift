//
//  VInspectorFormat.swift
//  VigilUI
//
//  The inspector's pure helpers: the value strings the panel prints that `InspectorStat` does not
//  already produce, the health-level → tint mapping, and the sparkline's y-scale.
//  macOS-only. Implements docs/DESIGN.md §4.4 (monospaced digits, reserved widths), §9.20
//  (threshold tinting) and §9.21 (sparkline scale), and docs/UX.md §6.1, §6.2.
//
//  Everything in this file is a function of its arguments — no clock, no device, no view. A format
//  that can only be exercised through a rendered view is a format nobody can test, and the inspector
//  is wall-to-wall formatted numbers.
//
//  Numbers are deliberately **not** localised, for the reason `InspectorStat.fixed(_:places:)`
//  already gives: a telemetry readout is a diagnostic value that gets pasted into a bug report and
//  compared with a colleague's, so a comma decimal separator would make two screenshots of the same
//  fault look like different faults. The units used here (`TB`, `GB`, `MB`, `d`, `h`, `m`, `%`) are
//  the symbols both shipping locales use. The one place a *sentence* is built — "74 % of 4.0 TB" —
//  goes through the localisation table, because the joining word is prose.
//

#if os(macOS)

import CoreGraphics
import Foundation

// MARK: - VInspectorFormat

/// The value strings the inspector prints beyond ``InspectorStat``'s.
package enum VInspectorFormat {

    /// The em dash that every "not known yet" cell shows.
    ///
    /// One constant rather than a literal per call site, so an unknown value looks identical in
    /// every row — which is what makes a half-populated panel readable rather than ragged.
    package static let placeholder = "\u{2014}"

    /// Device uptime as **two** units: `"6 d 04 h"`, `"4 h 12 m"`, `"37 m"`.
    ///
    /// ⚠️ UX.md §6.1 writes three units (`"6 d 4 h 12 m"`); design/mockups/01-main-window.html
    /// renders two (`"6 d 04 h"`). Two is implemented, because the third unit is noise next to a
    /// figure measured in days and because the mockup's fixed column is what the reserved-width
    /// rule (§4.4) is protecting. The second unit is zero-padded so the string cannot change width
    /// as it counts. Reported.
    ///
    /// - Parameter seconds: seconds since boot. A non-finite or non-positive value — which is what
    ///   ``InspectorDeviceIdentity`` holds before `/System/status` has answered — returns
    ///   ``placeholder`` rather than a confident `"0 m"`.
    package static func uptime(seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return placeholder }
        let total = Int(seconds.rounded(.down))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days) d \(padded(hours)) h" }
        if hours > 0 { return "\(hours) h \(padded(minutes)) m" }
        return "\(minutes) m"
    }

    /// Storage capacity from Hikvision's **decimal** megabytes: `"4.0 TB"`, `"512 GB"`, `"930 MB"`.
    ///
    /// Decimal throughout, because `VigilISAPI/StorageInfo.swift` documents the device's own
    /// accounting as decimal (1 MB = 1 000 000 bytes). Using binary units here would make every
    /// figure disagree with the camera's web UI by 5 % and every support call harder.
    ///
    /// - Parameter megabytes: the device's figure. Zero or negative returns ``placeholder``: a
    ///   volume that reports no capacity has not been read yet, and `"0 MB"` would read as a fault.
    package static func capacity(megabytes: Int) -> String {
        guard megabytes > 0 else { return placeholder }
        if megabytes >= 1_000_000 {
            return InspectorStat.fixed(Double(megabytes) / 1_000_000, places: 1) + " TB"
        }
        if megabytes >= 1_000 {
            return InspectorStat.fixed(Double(megabytes) / 1_000, places: 0) + " GB"
        }
        return "\(megabytes) MB"
    }

    /// A whole-number percentage with its sign and the space before it: `"74 %"`.
    ///
    /// The space is not decoration: Russian typography requires it (GOST 8.417, the same rule that
    /// gives `с` for seconds elsewhere in this module), and English tolerates it. One spelling for
    /// both locales keeps the reserved width identical in both.
    ///
    /// - Parameter fraction: 0…1. Values outside the range are clamped rather than rejected, so a
    ///   device reporting 1.02 of its disk used prints `"100 %"` instead of an over-full bar.
    package static func percent(fraction: Double) -> String {
        guard fraction.isFinite else { return placeholder }
        let clamped = Swift.min(1, Swift.max(0, fraction))
        return InspectorStat.fixed(clamped * 100, places: 0) + " %"
    }

    /// An elapsed or clip length as `m:ss`, growing to `h:mm:ss` past an hour.
    ///
    /// Not `HH:mm:ss`: a four-second event reading `00:00:04` buries the digit that matters. The
    /// leading unit is unpadded and the ones after it are, which keeps the width stable within each
    /// magnitude — the property §4.4 actually needs.
    package static func duration(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return placeholder }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if hours > 0 { return "\(hours):\(padded(minutes)):\(padded(remainder))" }
        return "\(minutes):\(padded(remainder))"
    }

    /// The PTZ speed as `"4 / 7"` (UX.md §6.3's discrete range).
    ///
    /// Clamped to ``InspectorPTZVector/speedRange`` so the label can never disagree with the vector
    /// the same value produces.
    package static func speed(_ value: Int) -> String {
        let range = InspectorPTZVector.speedRange
        let clamped = Swift.min(range.upperBound, Swift.max(range.lowerBound, value))
        return "\(clamped) / \(range.upperBound)"
    }

    /// A plain count — reordered packets, reconnects, clips.
    ///
    /// Exists so the call sites cannot disagree about whether an unknown count is `"0"` or a dash:
    /// a counter genuinely at zero is information, so zero prints as zero.
    package static func count(_ value: Int) -> String {
        String(Swift.max(0, value))
    }

    /// The unsigned overload — `StreamStatistics`' wire counters are `UInt64`.
    package static func count(_ value: UInt64) -> String {
        String(value)
    }

    /// Two digits, so a second unit cannot change the string's width as it counts down.
    static func padded(_ value: Int) -> String {
        value >= 0 && value < 10 ? "0\(value)" : String(value)
    }
}

// MARK: - VInspectorHealthTint

/// How a telemetry value is coloured, as a value rather than as a `Color`.
///
/// The indirection is deliberate. `SwiftUI.Color` is main-actor material in this module and its
/// equality is not something a test should lean on, so the *decision* — which of four treatments a
/// reading earns — is a plain enum that can be asserted, and the lookup from treatment to token is
/// the one-line `switch` in `VInspectorControls.swift`.
package enum VInspectorHealthTint: String, Sendable, Hashable, CaseIterable {

    /// `text.primary`. The resting appearance of every value: healthy readings are *quiet*.
    case neutral

    /// `ok`. Reserved for the handful of metrics whose healthy reading is worth stating — the
    /// mockup prints packet loss green at 0.02 %, because "no loss" is the answer the operator came
    /// for.
    case ok

    /// `warn`.
    case warn

    /// `danger`.
    case danger

    /// The tint for a computed level.
    ///
    /// - Parameters:
    ///   - level: whatever ``InspectorHealth`` decided. ⛔ Thresholds are never re-derived here.
    ///   - emphasisesHealth: `true` for a metric that earns a green when it is fine. Off by
    ///     default, because a panel where every row is green is a panel where nothing stands out.
    package init(_ level: InspectorHealthLevel, emphasisesHealth: Bool = false) {
        switch level {
        case .ok: self = emphasisesHealth ? .ok : .neutral
        case .warn: self = .warn
        case .danger: self = .danger
        }
    }

    /// The glyph that carries the level when colour cannot (DESIGN.md §9.20, §10.5).
    ///
    /// `nil` for the two non-alarming tints: a checkmark beside every healthy row is noise, and
    /// §10.5 only requires the *problem* states to have a non-colour partner.
    package var symbol: VTheme.Symbol? {
        switch self {
        case .neutral, .ok: return nil
        case .warn: return .warning
        case .danger: return .error
        }
    }

    /// Whether this tint is one the panel should also announce to VoiceOver.
    package var isAlarming: Bool {
        self == .warn || self == .danger
    }
}

// MARK: - VInspectorSparklineScale

/// The sparkline's arithmetic, separated from its drawing.
///
/// DESIGN.md §9.21 fixes the y range at `[0, max(observedMax × 1.15, floor)]`. Keeping it here
/// rather than inside the `Canvas` closure means the scale can be asserted, and means a spike does
/// not silently change how the whole series reads.
package enum VInspectorSparklineScale {

    /// The 15 % headroom of §9.21, so the peak never touches the top edge of the well.
    package static let headroom = 1.15

    /// The top of the y range.
    ///
    /// - Parameters:
    ///   - values: the samples, oldest first. Non-finite samples are ignored rather than poisoning
    ///     the maximum — a single NaN from a zero-length measurement window would otherwise flatten
    ///     the whole series to the baseline.
    ///   - floor: the smallest upper bound worth drawing, in the series' own units. It stops a
    ///     genuinely idle stream from magnifying its own rounding noise into a mountain range.
    /// - Returns: a strictly positive bound, so a caller can divide by it without a guard.
    package static func upperBound(_ values: [Double], floor: Double) -> Double {
        let observed = values.filter { $0.isFinite }.max() ?? 0
        let bound = Swift.max(observed * headroom, floor)
        return bound > 0 ? bound : 1
    }

    /// The polyline for a series, in the sparkline's own coordinate space.
    ///
    /// The oldest sample is at `x = 0` and the newest at `x = size.width`, which is the direction
    /// UX.md §6.2's "last 60 s" reads in. Values above ``upperBound(_:floor:)`` clamp to the top
    /// edge instead of escaping the well.
    ///
    /// - Returns: an empty array for an empty series or a degenerate box — the caller then draws
    ///   §9.21's empty state (a flat baseline and "No data yet") rather than a broken path. A
    ///   single sample returns one point, pinned to the trailing edge where the newest sample lives.
    package static func points(_ values: [Double], in size: CGSize,
                               upperBound: Double) -> [CGPoint] {
        guard !values.isEmpty, size.width > 0, size.height > 0, upperBound > 0 else { return [] }
        guard values.count > 1 else {
            return [CGPoint(x: size.width, y: offset(values[0], size: size, bound: upperBound))]
        }
        let step = size.width / CGFloat(values.count - 1)
        var points: [CGPoint] = []
        points.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            points.append(CGPoint(x: CGFloat(index) * step,
                                  y: offset(value, size: size, bound: upperBound)))
        }
        return points
    }

    /// The y offset for one sample. Zero is the bottom of the box, as a chart reads.
    static func offset(_ value: Double, size: CGSize, bound: Double) -> CGFloat {
        guard value.isFinite, bound > 0 else { return size.height }
        let fraction = Swift.min(1, Swift.max(0, value / bound))
        return size.height * CGFloat(1 - fraction)
    }
}

#endif  // os(macOS)
