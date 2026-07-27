//
//  VStatusBarView.swift
//  VigilUI
//
//  The 32 pt status footer at the window's bottom-leading corner: the Settings gear, how many
//  cameras are live, and the aggregate ingest rate — or, when anything is degraded, how many.
//  macOS-only. Implements docs/UX.md §3.3 (the footer's contents and its amber degraded form) with
//  docs/DESIGN.md §4.4 (monospaced digits), §5.4 (hairline, never `Divider()`), §8.3 (symbols) and
//  §10.5 (a state is never carried by hue alone).
//

#if os(macOS)

import SwiftUI

// MARK: - VStatusBarView

/// The window's status footer.
///
/// ## Why the readout is several `Text` runs and not one sentence
///
/// UX.md §14.2 forbids assembling a *sentence* from fragments, because word order does not survive
/// translation. `6 live · 1.8 Gb/s` is not a sentence: it is the `[value][label]` telemetry pattern
/// DESIGN.md §9.20 already specifies for `VStatPill`, and the mockup renders it the same way — the
/// digits in the mono face, the word beside them. Splitting it here means the numbers get
/// `monospacedDigit()` (§4.4 makes that mandatory for anything that changes on screen) while the
/// words stay translatable, and it keeps the units out of the localisation tables, which is the
/// decision `InspectorStat` already took and documented for exactly the same reason.
///
/// ## Degraded
///
/// When any camera is below threshold the footer switches to `n live · m degraded` in `warn`
/// (UX.md §3.3). The colour is never the only cue: a `exclamationmark.triangle.fill` appears in
/// front of the count and the word "degraded" is written out, so the state survives
/// `differentiateWithoutColor` and a monochrome display (§10.5). In that state the readout becomes
/// a button, because §3.3 promises a way through to the degraded cameras and a coloured label with
/// no affordance is a dead end.
@MainActor
package struct VStatusBarView: View {

    // MARK: - Stored Properties

    /// The 1 Hz snapshot to print.
    package let status: VChromeStatus

    /// Opens Settings. UX.md §3.3 gives the gear this job.
    package let onOpenSettings: () -> Void

    /// Reveals the degraded cameras — §3.3's popover with its "Run Stream Doctor" button. Only
    /// reachable while ``VChromeStatus/isDegraded`` is `true`.
    package let onShowDegraded: () -> Void

    @Environment(\.displayScale) private var displayScale

    // MARK: - Initialisation

    /// Creates the footer.
    package init(status: VChromeStatus,
                 onOpenSettings: @escaping () -> Void = {},
                 onShowDegraded: @escaping () -> Void = {}) {
        self.status = status
        self.onOpenSettings = onOpenSettings
        self.onShowDegraded = onShowDegraded
    }

    // MARK: - View

    package var body: some View {
        HStack(spacing: VTheme.Space.xs) {
            settingsButton
            readoutControl
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VTheme.Space.md)
        .frame(height: VTheme.Metrics.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { hairline }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Items

    /// The gear. A real button with a spoken label rather than a decorative glyph, because "open
    /// Settings" is an action a Voice Control user has to be able to name (§10.7).
    private var settingsButton: some View {
        VButton(symbol: .settings,
                size: .xs,
                accessibilityLabel: "Settings",
                action: onOpenSettings)
            .help(Text("Settings", bundle: .vigilUI))
    }

    /// The readout, wrapped in a button only when there is somewhere to go.
    @ViewBuilder
    private var readoutControl: some View {
        if status.isDegraded {
            Button(action: onShowDegraded) {
                readout
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Show degraded cameras", bundle: .vigilUI))
            .help(Text("Show degraded cameras", bundle: .vigilUI))
        } else {
            readout
                .accessibilityElement(children: .combine)
        }
    }

    private var readout: some View {
        HStack(spacing: VTheme.Space.xxs) {
            warningGlyph
            count(status.liveText)
            word("live")
            separatorDot
            if status.isDegraded {
                count(status.degradedText)
                word("degraded")
            } else {
                rate
            }
        }
    }

    /// The aggregate rate, with the unit taken from the module's `"%@ <unit>" ` keys so that a
    /// Russian footer reads `1,8 Гбит/с`.
    ///
    /// The digits stay `Text(verbatim:)` inside the interpolation — ``VThroughput`` formats them
    /// locale-independently on purpose (a telemetry figure is a diagnostic, and a comma decimal
    /// separator in one screenshot makes one fault look like two), while the *unit* is a word and
    /// is translated. The local is named `value` because that is the interpolation name
    /// `Scripts/check-localizations.py` resolves to `%@`.
    private var rate: some View {
        let value = status.throughput.value
        return unitText(value)
            .vType(VTheme.Typography.mono.numeric)
            .foregroundStyle(tint)
    }

    private func unitText(_ value: String) -> Text {
        switch status.throughput.unit {
        case .kilobits:
            return Text("\(value) kb/s", bundle: .vigilUI)
        case .megabits:
            return Text("\(value) Mb/s", bundle: .vigilUI)
        case .gigabits:
            return Text("\(value) Gb/s", bundle: .vigilUI)
        }
    }

    @ViewBuilder
    private var warningGlyph: some View {
        if status.isDegraded {
            VTheme.Symbol.warning.image()
                .symbolRenderingMode(VTheme.Symbol.warning.rendering)
                .vIcon(size: VTheme.Icon.xs, weight: VTheme.Icon.Weight.xs)
                .foregroundStyle(VTheme.Color.Semantic.warn)
                .accessibilityHidden(true)
        }
    }

    /// A number, or a number-with-unit, in the mono face with tabular digits (§4.4).
    private func count(_ text: String) -> some View {
        Text(verbatim: text)
            .vType(VTheme.Typography.mono.numeric)
            .foregroundStyle(tint)
    }

    /// A translatable word beside a number.
    private func word(_ key: LocalizedStringKey) -> some View {
        Text(key, bundle: .vigilUI)
            .vType(VTheme.Typography.caption1)
            .foregroundStyle(tint)
    }

    /// The middle dot. Hidden from VoiceOver, which would otherwise read it aloud between two
    /// perfectly clear readouts.
    private var separatorDot: some View {
        Text(verbatim: "·")
            .vType(VTheme.Typography.caption1)
            .foregroundStyle(VTheme.Color.Text.tertiary)
            .accessibilityHidden(true)
    }

    /// Amber the moment anything is degraded, `text.secondary` otherwise.
    ///
    /// The mockup sets the words in `text.tertiary` and the numbers in `text.secondary`; one ink for
    /// the whole line is used here because the footer is read as a unit and the two-tone version put
    /// the least legible token on the word that carries the meaning.
    private var tint: SwiftUI.Color {
        status.isDegraded ? VTheme.Color.Semantic.warn : VTheme.Color.Text.secondary
    }

    /// The top hairline. ⛔ Never `Divider()` — its colour and inset are not ours (§5.4).
    private var hairline: some View {
        Rectangle()
            .fill(VTheme.Color.Stroke.subtle)
            .frame(height: VTheme.Border.hairline(displayScale))
            .allowsHitTesting(false)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("VStatusBarView") {
    VStack(spacing: 0) {
        VStatusBarView(status: VChromeStatus(
            liveCount: 6,
            throughput: VThroughput(bitsPerSecond: 1_800_000_000)))
        VStatusBarView(status: VChromeStatus(
            liveCount: 5,
            degradedCount: 1,
            throughput: VThroughput(bitsPerSecond: 1_240_000_000)))
        VStatusBarView(status: VChromeStatus(
            liveCount: 1,
            throughput: VThroughput(bitsPerSecond: 380_000)))
        VStatusBarView(status: VChromeStatus(liveCount: 0))
    }
    .frame(width: 264)
    .background(VTheme.Color.Layer.surface)
}
#endif

#endif  // os(macOS)
