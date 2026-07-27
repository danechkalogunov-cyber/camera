//
//  ChromeModel.swift
//  VigilUI
//
//  The window chrome's pure values: the aggregate throughput readout, the toast dwell and
//  announcement policy, the toast stack limit, and the toolbar layout switcher's ordering. Nothing
//  here draws — every type is a value a test can drive without a renderer.
//  macOS-only. Implements docs/DESIGN.md §7.2 and §9.17 (toast dwell and priority), §8.3 (symbols),
//  §3.2 (semantic tints), and docs/UX.md §3.2, §3.3 and §5.1.
//

#if os(macOS)

import SwiftUI

// MARK: - VThroughput

/// An aggregate ingest rate, formatted the way the status bar prints it: `1.8 Gb/s`.
///
/// ## Bits, not bytes
///
/// Network rates in this product are **bits per second** and the units are SI decimal — `Mb/s` is
/// 10⁶ bit/s, not 2²⁰ — because that is what the camera's own web page, `HealthMonitor` and every
/// datasheet report. ``bytesPerSecond(_:)`` exists for the one caller that measures the socket
/// rather than the stream, and multiplies by eight exactly once, here, so no call site has to
/// remember which side of the conversion it is on.
///
/// ## Malformed input
///
/// A rate arrives from a division by a measured interval, so it can be `nan`, `inf`, negative or
/// absurd. All four resolve to "unmeasured", which prints an em dash rather than a confident zero;
/// a finite but implausible value is clamped to ``maximum``. Nothing here can trap.
package struct VThroughput: Sendable, Hashable {

    // MARK: - Units

    /// The three units the readout can print. Raw values are the **English** suffixes, which are
    /// also the localisation keys: `VStatusBarView` renders `"%@ Gb/s"` and friends through
    /// `Bundle.vigilUI`, so a Russian footer reads `Гбит/с`. The raw value is what a diagnostic
    /// paste or a screenshot comparison sees, and ``label`` keeps that form deliberately.
    package enum Unit: String, Sendable, Hashable, CaseIterable {

        /// Below 1 Mb/s, printed with no decimals — `380 kb/s`.
        case kilobits = "kb/s"

        /// Below 1 Gb/s, printed with one decimal — `4.1 Mb/s`.
        case megabits = "Mb/s"

        /// 1 Gb/s and above, printed with one decimal — `1.8 Gb/s`.
        case gigabits = "Gb/s"
    }

    // MARK: - Constants

    /// The largest rate this type represents: 1 Pb/s.
    ///
    /// A clamp rather than a precondition. The number is a quotient computed somewhere else, and a
    /// zero denominator there must not be able to take the interface down with it.
    package static let maximum: Double = 1e15

    /// SI decimal steps. Not design tokens — the definitions of the units themselves.
    private static let kilobit: Double = 1_000

    /// See ``kilobit``.
    private static let megabit: Double = 1_000_000

    /// See ``kilobit``.
    private static let gigabit: Double = 1_000_000_000

    /// Promotion thresholds, set half a printed digit below the round number.
    ///
    /// Without them the boundary prints `1000 kb/s` and `1000.0 Mb/s` — a four-digit value in a
    /// field sized for three, and a unit the reader has to convert in their head. At `999.5 kb/s`
    /// the zero-decimal form would already read `1000`, and at `999.95 Mb/s` the one-decimal form
    /// would read `1000.0`, so those are exactly where the next unit takes over.
    private static let megabitFloor: Double = kilobit * 999.5

    /// See ``megabitFloor``.
    private static let gigabitFloor: Double = megabit * 999.95

    // MARK: - Stored Properties

    /// The rate in bits per second. Always finite and in `0...maximum`.
    package let bitsPerSecond: Double

    // MARK: - Initialisation

    /// Creates a rate from bits per second.
    ///
    /// - Parameter bitsPerSecond: the measured rate. `nan`, `inf` and any value ≤ 0 become
    ///   "unmeasured" (``isMeasured`` is `false` and ``value`` is an em dash); a larger finite value
    ///   is clamped to ``maximum``.
    package init(bitsPerSecond: Double) {
        guard bitsPerSecond.isFinite, bitsPerSecond > 0 else {
            self.bitsPerSecond = 0
            return
        }
        self.bitsPerSecond = Swift.min(bitsPerSecond, Self.maximum)
    }

    /// Creates a rate from **bytes** per second, converting once.
    ///
    /// - Parameter bytesPerSecond: the measured rate. Non-finite and negative values become
    ///   "unmeasured", exactly as in ``init(bitsPerSecond:)``.
    package static func bytesPerSecond(_ bytesPerSecond: Double) -> VThroughput {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else {
            return VThroughput(bitsPerSecond: 0)
        }
        return VThroughput(bitsPerSecond: bytesPerSecond * 8)
    }

    /// The zero rate, which prints as an em dash.
    package static let unmeasured = VThroughput(bitsPerSecond: 0)

    // MARK: - Presentation

    /// Whether a rate was actually measured. `false` prints an em dash rather than `0.0 Mb/s`,
    /// which would be a claim the app cannot support.
    package var isMeasured: Bool {
        bitsPerSecond > 0
    }

    /// The unit the rate prints in. An unmeasured rate keeps `Mb/s`, so the unit beside the em dash
    /// does not change when the first measurement lands.
    package var unit: Unit {
        guard isMeasured else { return .megabits }
        if bitsPerSecond >= Self.gigabitFloor { return .gigabits }
        if bitsPerSecond >= Self.megabitFloor { return .megabits }
        return .kilobits
    }

    /// The numeric part alone — `1.8`, or `—` when unmeasured.
    ///
    /// Formatted through `InspectorStat.fixed(_:places:)`, which is the module's existing
    /// locale-independent fixed-point printer, so the decimal separator in a Vigil telemetry
    /// readout is a full stop on every machine.
    package var value: String {
        guard isMeasured else { return "—" }
        switch unit {
        case .kilobits:
            return InspectorStat.fixed(bitsPerSecond / Self.kilobit, places: 0)
        case .megabits:
            return InspectorStat.fixed(bitsPerSecond / Self.megabit, places: 1)
        case .gigabits:
            return InspectorStat.fixed(bitsPerSecond / Self.gigabit, places: 1)
        }
    }

    /// Value and unit in English — `1.8 Gb/s`.
    ///
    /// The **diagnostic** form, for a tooltip, a log line or a pasted bug report, and the form the
    /// tests assert on. The status bar composes the same two parts through a localised unit key so
    /// the visible footer is translated; this one deliberately is not, so two screenshots of the
    /// same fault taken in two locales still read the same.
    package var label: String {
        value + " " + unit.rawValue
    }
}

// MARK: - VChromeStatus

/// What the status bar reports: how many cameras are live, how many are degraded, and the
/// aggregate ingest rate (UX.md §3.3).
///
/// Sampled at 1 Hz by whatever owns `HealthMonitor` and handed down as a snapshot. The view never
/// observes a stream — a status footer that re-rendered per packet would put a SwiftUI invalidation
/// on the ingest path.
package struct VChromeStatus: Sendable, Hashable {

    /// How many cameras are delivering media. Negative inputs clamp to zero.
    package let liveCount: Int

    /// How many of those are below the health threshold. Negative inputs clamp to zero.
    package let degradedCount: Int

    /// The aggregate ingest rate across every live camera.
    package let throughput: VThroughput

    /// Creates a snapshot.
    package init(liveCount: Int,
                 degradedCount: Int = 0,
                 throughput: VThroughput = .unmeasured) {
        self.liveCount = Swift.max(0, liveCount)
        self.degradedCount = Swift.max(0, degradedCount)
        self.throughput = throughput
    }

    /// Whether the footer switches to its amber "n live · m degraded" form (UX.md §3.3).
    package var isDegraded: Bool {
        degradedCount > 0
    }

    /// The live count as printed digits.
    package var liveText: String {
        String(liveCount)
    }

    /// The degraded count as printed digits.
    package var degradedText: String {
        String(degradedCount)
    }
}

// MARK: - VToastKind

/// The five toast variants of DESIGN.md §9.17.
///
/// The glyph and the tint are `@MainActor` members of a **nonisolated** enum, the same shape
/// `VLiveDot.Status` uses: a nested type does not inherit its parent's global actor, so isolating
/// the members rather than the enum keeps the case itself nameable from any context.
package enum VToastKind: String, Sendable, Hashable, CaseIterable {

    /// Neutral news. `info.circle.fill` in `accent`, 4 s dwell.
    case info

    /// A completed action. `checkmark.circle.fill` in `ok`, 4 s dwell.
    case success

    /// Something is wrong but the app carried on. `exclamationmark.triangle.fill` in `warn`.
    case warning

    /// Something failed. `xmark.octagon.fill` in `danger`, and it **never** auto-dismisses.
    case error

    /// A motion event on a camera. `figure.walk` in `motion`.
    ///
    /// ⚠️ §9.17 also gives this variant a leading 64 × 36 event thumbnail that jumps to playback
    /// when clicked. ``VToastView`` does not draw it: the thumbnail comes from the events slice,
    /// which owns the frame store. The case is here so the vocabulary is complete and the tint and
    /// glyph are already right when that slice adds the accessory.
    case motion

    /// The symbol from §8.3's status rows.
    @MainActor
    package var symbol: VTheme.Symbol {
        switch self {
        case .info: return .info
        case .success: return .success
        case .warning: return .warning
        case .error: return .error
        case .motion: return .motionDetection
        }
    }

    /// The glyph, already resolved to the filled variant where §9.17 asks for one.
    ///
    /// Only `.info` needs the switch: `info.circle` is the base glyph and `info.circle.fill` is what
    /// a toast shows, which is exactly what §8.3's *Variant* column says (`.fill` in toasts). The
    /// other four are filled in their base name already.
    @MainActor
    package var image: Image {
        symbol.image(filled: self == .info)
    }

    /// The icon colour and the colour of the leading edge bar (§9.17's table).
    @MainActor
    package var tint: SwiftUI.Color {
        switch self {
        case .info: return VTheme.Color.Semantic.accent
        case .success: return VTheme.Color.Semantic.ok
        case .warning: return VTheme.Color.Semantic.warn
        case .error: return VTheme.Color.Semantic.danger
        case .motion: return VTheme.Color.Semantic.motion
        }
    }

    /// Whether this variant must be dismissed by the user rather than by a timer.
    ///
    /// Only `.error`. §9.17: "**indefinite** for `.error` (must be dismissed)" — an error that
    /// vanishes on its own is an error the operator never read.
    package var blocksAutomaticDismissal: Bool {
        self == .error
    }

    /// The VoiceOver announcement priority §9.17 assigns this variant.
    package var priority: VToastPriority {
        blocksAutomaticDismissal ? .high : .medium
    }
}

// MARK: - VToastPriority

/// How loudly a toast interrupts VoiceOver.
///
/// §9.17 says `.high` for errors and `.medium` otherwise; UX.md §16.1 spells the quieter one
/// "default". They are the same decision, and this enum uses DESIGN's names because DESIGN owns the
/// component.
///
/// A Vigil enum rather than AppKit's `NSAccessibilityPriorityLevel` so the policy stays a plain
/// value that a test can compare. The announcement itself is posted by the window layer, which owns
/// the toast queue — a view that is about to be removed is the wrong place to post from.
package enum VToastPriority: Int, Sendable, Hashable, Comparable, CaseIterable {

    /// Everything that is not an error.
    case medium = 0

    /// Errors, which the operator must act on.
    case high = 1

    /// Orders by urgency, so a queue can sort without restating the ranking.
    package static func < (lhs: VToastPriority, rhs: VToastPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - VToastPolicy

/// How long a toast stays and how loudly it announces itself.
///
/// A value type, and deliberately separate from the view, so the two rules that are easy to get
/// wrong — "6 s when it carries an action" and "an error never leaves on its own" — are provable
/// without a renderer. ``VToastView`` only applies what this decides.
///
/// The type is nonisolated so it stays `Hashable` and `Sendable`; only the factory that reads the
/// `VTheme.Motion.Delay` tokens is `@MainActor`, because those tokens are.
package struct VToastPolicy: Sendable, Hashable {

    /// How long the toast dwells before dismissing itself, or `nil` when it never does.
    package let dwell: Duration?

    /// The announcement priority.
    package let priority: VToastPriority

    /// Creates a policy directly. Prefer ``resolved(for:hasAction:)``, which reads the tokens.
    package init(dwell: Duration?, priority: VToastPriority) {
        self.dwell = dwell
        self.priority = priority
    }

    /// Whether a timer will dismiss this toast.
    package var dismissesAutomatically: Bool {
        dwell != nil
    }

    /// How much dwell is left after `elapsed` of un-paused time.
    ///
    /// Hovering pauses the timer (§9.17), so the view accumulates the time it has actually spent
    /// counting down and asks again. Returns `nil` for an indefinite toast — the caller must not
    /// treat that as "no time left" — and never a negative duration.
    package func remaining(after elapsed: Duration) -> Duration? {
        guard let dwell else { return nil }
        let left = dwell - elapsed
        return left > Duration.zero ? left : Duration.zero
    }

    /// Whether the dwell has run out. Always `false` for an indefinite toast.
    package func hasExpired(after elapsed: Duration) -> Bool {
        guard let dwell else { return false }
        return elapsed >= dwell
    }

    /// The policy for a variant, from the §7.2 timing constants.
    ///
    /// - Parameters:
    ///   - kind: the variant. `.error` never auto-dismisses, whatever else is passed.
    ///   - hasAction: whether the toast carries an inline action button, which buys the reader the
    ///     longer 6 s dwell because they now have something to read *and* something to decide.
    @MainActor
    package static func resolved(for kind: VToastKind, hasAction: Bool) -> VToastPolicy {
        VToastPolicy(dwell: dwellSeconds(for: kind, hasAction: hasAction),
                     priority: kind.priority)
    }

    /// `Delay.toastDwell` 4 s, `Delay.toastDwellWithAction` 6 s, or nothing at all.
    @MainActor
    private static func dwellSeconds(for kind: VToastKind, hasAction: Bool) -> Duration? {
        guard !kind.blocksAutomaticDismissal else { return nil }
        let seconds = hasAction ? VTheme.Motion.Delay.toastDwellWithAction
                                : VTheme.Motion.Delay.toastDwell
        // Spelled `Duration.seconds` rather than `.seconds`: the return type is `Duration?`, and an
        // implicit member expression against an Optional is exactly the kind of inference this
        // container cannot check.
        return Duration.seconds(seconds)
    }
}

// MARK: - VToastStack

/// How many toasts are drawn at once (§9.17).
package enum VToastStack {

    /// Three. Older ones collapse into a "+N more" row rather than covering the stage.
    package static let maxVisible: Int = 3

    /// Splits a queue depth into what is drawn and what the "+N more" row reports.
    ///
    /// - Parameter depth: how many toasts are queued. Negative values are treated as none.
    /// - Returns: the number to draw and the number to summarise. The two always sum to the
    ///   clamped depth, so a "+0 more" row can never be produced.
    package static func split(depth: Int) -> (visible: Int, collapsed: Int) {
        let clamped = Swift.max(0, depth)
        let visible = Swift.min(clamped, maxVisible)
        return (visible: visible, collapsed: clamped - visible)
    }
}

// MARK: - VChromeLayoutSwitcher

/// The toolbar's segmented layout switcher: which layouts it offers, in which order, and which one
/// it paints as selected.
///
/// Separated from the view because the ordering is the part that a reviewer can check against the
/// mockup and a test can pin. The cases themselves come from ``VGridLayout`` — this type never
/// declares a layout of its own.
package enum VChromeLayoutSwitcher {

    /// The four segments, in the order `design/mockups/01-main-window.html` renders them: one, four,
    /// the 1 + 5 hero, then nine.
    ///
    /// This is `VGridLayout.pickerSteps` and nothing else. The stage can be on any of the eight
    /// layouts — `⌘5`…`⌘8` reach the rest — and when it is on one the switcher does not offer, no
    /// segment is selected rather than a wrong one.
    package static var options: [VGridLayout] {
        VGridLayout.pickerSteps
    }

    /// Where `layout` sits among ``options``, or `nil` when the switcher does not offer it.
    package static func selectedIndex(of layout: VGridLayout) -> Int? {
        options.firstIndex(of: layout)
    }

    /// Whether the switcher paints `option` as the active segment.
    package static func isSelected(_ option: VGridLayout, current: VGridLayout) -> Bool {
        option == current && selectedIndex(of: current) != nil
    }

    /// The spoken name of a layout, for the segment's accessibility label.
    ///
    /// Spelled out rather than abbreviated — VoiceOver reads "3 × 3" as "three multiplication sign
    /// three", and a Voice Control user has to be able to *say* the segment's name (§10.7).
    package static func label(for layout: VGridLayout) -> LocalizedStringKey {
        switch layout {
        case .single: return "Single view"
        case .grid2x2: return "Two by two"
        case .hero1p5: return "Hero and five"
        case .grid3x3: return "Three by three"
        case .grid4x4: return "Four by four"
        case .hero1p7: return "Hero and seven"
        case .dual2p8: return "Two heroes and eight"
        case .mosaic4x3: return "Mosaic"
        }
    }
}

#endif  // os(macOS)
