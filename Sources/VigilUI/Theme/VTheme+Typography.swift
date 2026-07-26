//
//  VTheme+Typography.swift
//  VigilUI
//
//  The nine-step display scale, the Mono track, the monospaced-digit variants, the reserved
//  telemetry widths, and the vType(_:) modifier that bundles font + tracking + leading + case.
//  macOS-only. See docs/DESIGN.md §4 and docs/API_CONTRACT.md §4.11.
//

#if os(macOS)

import SwiftUI

// MARK: - Step

extension VTheme.Typography {

    /// One row of the type scale: everything a call site needs, so that no call site repeats any
    /// of it.
    ///
    /// A `Font` cannot carry tracking, leading or case, which is why those live here and are
    /// applied together by ``SwiftUI/View/vType(_:)``. `lineHeight` is the designed total box
    /// height; `lineSpacing` is the number SwiftUI actually needs, because `.lineSpacing` **adds
    /// to** the font's natural line height rather than setting it (§4.2).
    ///
    /// Deliberately conforms to nothing: the type is only ever read on the main actor, and adding
    /// `Sendable`/`Equatable` would make the module depend on conformances of `Font.Weight`,
    /// `Font.Design` and `Text.Case` that cannot be verified from this container.
    @MainActor
    public struct Step {

        // MARK: - Stored Properties

        /// Point size at `textScale == 1.0`.
        public let size: CGFloat

        /// SF weight. Never heavier than the icon beside it (§8.1).
        public let weight: Font.Weight

        /// `.default` for the Text and Display tracks, `.monospaced` for the Mono track.
        public let design: Font.Design

        /// The designed total line box, in points. Documentation only — SwiftUI takes `lineSpacing`.
        public let lineHeight: CGFloat

        /// The value to pass to `.lineSpacing(_:)` to reach ``lineHeight``.
        public let lineSpacing: CGFloat

        /// Letter spacing in points, passed to `.tracking(_:)`. Negative tightens.
        public let tracking: CGFloat

        /// `.uppercase` for `Caption2` eyebrows; `nil` (sentence case) everywhere else.
        public let textCase: SwiftUI.Text.Case?

        /// Whether the resolved `Font` carries `.monospacedDigit()`.
        public let usesMonospacedDigits: Bool

        // MARK: - Computed Properties

        /// The resolved SwiftUI font.
        ///
        /// Built with `Font.system(size:weight:design:)` and never `Font.custom(_:size:)`: naming
        /// the face breaks optical sizing, tracking defaults and the `monospacedDigit` variant
        /// selector (§4.1). SF Pro Display is selected automatically at ≥ 20 pt.
        ///
        ///     static func system(size: CGFloat, weight: Font.Weight = .regular,
        ///                        design: Font.Design = .default) -> Font
        public var font: Font {
            let base = Font.system(size: size, weight: weight, design: design)
            return usesMonospacedDigits ? base.monospacedDigit() : base
        }

        // MARK: - Initialisation

        init(size: CGFloat,
             weight: Font.Weight,
             design: Font.Design = .default,
             lineHeight: CGFloat,
             lineSpacing: CGFloat,
             tracking: CGFloat,
             textCase: SwiftUI.Text.Case? = nil,
             usesMonospacedDigits: Bool = false) {
            self.size = size
            self.weight = weight
            self.design = design
            self.lineHeight = lineHeight
            self.lineSpacing = lineSpacing
            self.tracking = tracking
            self.textCase = textCase
            self.usesMonospacedDigits = usesMonospacedDigits
        }

        // MARK: - Public API

        /// The same step with `monospacedDigit()` applied.
        ///
        /// ⛔ Every number that can change while on screen uses this — fps, bitrate, loss, jitter,
        /// latency, queue depth, dropped frames, uptime, timecode, clip duration, counts, storage,
        /// zoom, PTZ speed, preset numbers, timeline labels and any percentage (§4.4). Pair it with
        /// a reserved width from ``VTheme/Typography/Reserved`` so the neighbours do not reflow.
        public var numeric: Step {
            Step(size: size, weight: weight, design: design, lineHeight: lineHeight,
                 lineSpacing: lineSpacing, tracking: tracking, textCase: textCase,
                 usesMonospacedDigits: true)
        }

        /// The step scaled by the user's interface-text-size preference (§4.5).
        ///
        /// Sizes are multiplied and rounded to the nearest 0.5 pt; leading scales with them so the
        /// designed line box is preserved. Tracking is **not** scaled — it is an optical correction
        /// for the shape of the face, not a proportion of the size.
        public func scaled(by scale: CGFloat) -> Step {
            Step(size: VTheme.Typography.Scale.rounded(size * scale),
                 weight: weight,
                 design: design,
                 lineHeight: VTheme.Typography.Scale.rounded(lineHeight * scale),
                 lineSpacing: VTheme.Typography.Scale.rounded(lineSpacing * scale),
                 tracking: tracking,
                 textCase: textCase,
                 usesMonospacedDigits: usesMonospacedDigits)
        }
    }
}

// MARK: - The scale

extension VTheme.Typography {

    /// 28 / 34, bold, tracking −0.40. Empty-state hero, onboarding headline, About.
    public static let display = Step(size: 28, weight: .bold, lineHeight: 34,
                                     lineSpacing: 0, tracking: -0.40)

    /// 22 / 28, semibold, tracking −0.30. Sheet titles, Settings pane titles, Discovery header.
    public static let title1 = Step(size: 22, weight: .semibold, lineHeight: 28,
                                    lineSpacing: 1, tracking: -0.30)

    /// 17 / 22, semibold, tracking −0.20. Inspector title, card group headers, palette sections.
    public static let title2 = Step(size: 17, weight: .semibold, lineHeight: 22,
                                    lineSpacing: 1, tracking: -0.20)

    /// 15 / 20, semibold, tracking −0.10. Card titles, tile name chip, playback camera name.
    public static let title3 = Step(size: 15, weight: .semibold, lineHeight: 20,
                                    lineSpacing: 2, tracking: -0.10)

    /// 13 / 18, semibold. Sidebar row title, button labels, table headers.
    public static let headline = Step(size: 13, weight: .semibold, lineHeight: 18,
                                      lineSpacing: 2, tracking: 0)

    /// 13 / 18, regular. **The default.** Field values, menu items, descriptions.
    public static let body = Step(size: 13, weight: .regular, lineHeight: 18,
                                  lineSpacing: 2, tracking: 0)

    /// 12 / 16, medium. Secondary labels, tab titles, inspector field labels.
    public static let callout = Step(size: 12, weight: .medium, lineHeight: 16,
                                     lineSpacing: 1, tracking: 0)

    /// 11 / 14, medium, tracking +0.10. Badges, HUD labels, sidebar subtitle, timestamps.
    public static let caption1 = Step(size: 11, weight: .medium, lineHeight: 14,
                                      lineSpacing: 1, tracking: 0.10)

    /// 10 / 13, semibold, tracking +0.50, **uppercase**. Section eyebrows, `REC`, `LIVE`, `H.265`.
    public static let caption2 = Step(size: 10, weight: .semibold, lineHeight: 13,
                                      lineSpacing: 1, tracking: 0.50, textCase: .uppercase)

    /// 11 / 16, medium, SF Mono. All telemetry: IP/MAC, RTSP URLs, log lines, hex, byte counts.
    public static let mono = Step(size: 11, weight: .medium, design: .monospaced,
                                  lineHeight: 16, lineSpacing: 2, tracking: 0)

    /// 10 / 13, medium, SF Mono. The tile stats HUD and timeline ruler labels.
    public static let monoSmall = Step(size: 10, weight: .medium, design: .monospaced,
                                       lineHeight: 13, lineSpacing: 1, tracking: 0)

    /// 13 / 18, semibold, SF Mono. The playback timecode and the cinema clock.
    public static let monoLarge = Step(size: 13, weight: .semibold, design: .monospaced,
                                       lineHeight: 18, lineSpacing: 2, tracking: 0)

    // MARK: Numeric variants

    /// `body` with monospaced digits — the default for a live value in running text.
    public static let bodyNumeric = body.numeric

    /// `headline` with monospaced digits.
    public static let headlineNumeric = headline.numeric

    /// `caption1` with monospaced digits — the sidebar subtitle and HUD labels.
    public static let caption1Numeric = caption1.numeric

    /// `title2` with monospaced digits — heading-position counts ("4 of 16 live").
    public static let title2Numeric = title2.numeric

    /// The monospaced-digit form of any step. Equivalent to `step.numeric`; provided because
    /// DESIGN.md §12.1 names it as a function.
    public static func numeric(_ step: Step) -> Step {
        step.numeric
    }

    /// Every step, in scale order, for the token gallery.
    public static let allSteps: [Step] = [
        display, title1, title2, title3, headline, body, callout, caption1, caption2,
        mono, monoSmall, monoLarge,
    ]
}

// MARK: - Interface text size

extension VTheme.Typography {

    /// The user's Settings ▸ General ▸ Interface text size preference (§4.5).
    ///
    /// macOS has no app-wide Dynamic Type, so Vigil ships its own. The chosen factor is stored in
    /// `@AppStorage("ui.textScale")` and published as `\.vTextScale` by `Theme/Environment.swift`;
    /// this namespace holds the factors themselves and the two rounding rules that keep the result
    /// on Vigil's grids.
    @MainActor
    public enum Scale {

        /// Small.
        public static let small: CGFloat = 0.92

        /// Default.
        public static let standard: CGFloat = 1.00

        /// Large.
        public static let large: CGFloat = 1.15

        /// All three, small to large.
        public static let all: [CGFloat] = [small, standard, large]

        /// Rounds a scaled point size to the nearest 0.5 pt, so glyphs stay on half-pixel
        /// boundaries at 2× and text does not shimmer during a live resize.
        public static func rounded(_ value: CGFloat) -> CGFloat {
            (value * 2).rounded() / 2
        }

        /// Scales a control height and keeps it on the 2 pt grid: `ceil(h × scale / 2) × 2` (§4.5).
        public static func controlHeight(_ height: CGFloat, scale: CGFloat) -> CGFloat {
            (height * scale / 2).rounded(.up) * 2
        }

        /// Scales an icon size the same way a type size is scaled, so glyph and label stay paired.
        public static func iconSize(_ size: CGFloat, scale: CGFloat) -> CGFloat {
            rounded(size * scale)
        }
    }
}

// MARK: - Reserved telemetry widths

extension VTheme.Typography {

    /// Fixed widths for the readouts that change while on screen (§4.4).
    ///
    /// Applied with `.frame(width:alignment:)` on the `Text` — **never** with padding, which does
    /// not reserve space when the string shrinks. Units are `text.tertiary`; values are
    /// `text.primary`, or `text.secondary` in the tile HUD.
    @MainActor
    public enum Reserved {

        /// `25 fps` — `%.0f` + ` fps`.
        public static let fps: CGFloat = 46

        /// `4.2 Mb/s` — `%.1f` + ` Mb/s`.
        public static let bitrate: CGFloat = 62

        /// `184 ms` — `%.0f` + ` ms`.
        public static let latency: CGFloat = 46

        /// `0.04%` — `%.2f` + `%`.
        public static let loss: CGFloat = 46

        /// `2.4 ms` — `%.1f` + ` ms`.
        public static let jitter: CGFloat = 46

        /// `14:22:07.48` — `HH:mm:ss.SS`, set in ``VTheme/Typography/monoLarge``.
        public static let timecode: CGFloat = 92

        /// `1920×1080` — `%d×%d`.
        public static let resolution: CGFloat = 74
    }
}

// MARK: - View modifiers

extension View {

    /// Applies a complete type step: font, tracking, line spacing and case, in one call.
    ///
    /// This exists so that no call site ever repeats the four modifiers — and so that a reviewer
    /// grepping for `.font(.system(size:` finds nothing outside this file (§4.3, §12.4).
    ///
    /// `@MainActor` because `Step` is main-actor isolated along with the rest of `VTheme`; every
    /// call site is a `View.body`, which is already main-actor isolated.
    ///
    /// - Parameter step: the step to apply. Pass `step.numeric` (or one of the `…Numeric`
    ///   constants) for anything whose digits change while it is on screen.
    @MainActor
    package func vType(_ step: VTheme.Typography.Step) -> some View {
        self.font(step.font)
            .tracking(step.tracking)
            .lineSpacing(step.lineSpacing)
            .textCase(step.textCase)
    }

    /// Applies a type step scaled by the user's interface-text-size factor.
    ///
    /// Read `\.vTextScale` at the call site and pass it here; the environment key itself is
    /// published by `Theme/Environment.swift`, which keeps this file free of environment plumbing.
    @MainActor
    package func vType(_ step: VTheme.Typography.Step, scale: CGFloat) -> some View {
        vType(step.scaled(by: scale))
    }

    /// Reserves a fixed width for a telemetry readout so a changing value cannot reflow its
    /// neighbours (§4.4). Trailing-aligned by default, which is how numbers are read.
    @MainActor
    package func vReserved(_ width: CGFloat, alignment: Alignment = .trailing) -> some View {
        self.frame(width: width, alignment: alignment)
    }
}

#endif  // os(macOS)
