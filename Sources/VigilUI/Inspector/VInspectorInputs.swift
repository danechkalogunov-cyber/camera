//
//  VInspectorInputs.swift
//  VigilUI
//
//  The two controls the Image and PTZ tabs need that `Components/` does not ship yet: a segmented
//  picker and a labelled slider row.
//  macOS-only. Implements docs/DESIGN.md §9.2 (segmented control), §5.5 (control heights), §9.28
//  (focus) and docs/UX.md §6.3, §6.4.
//
//  ⚠️ WHY THESE ARE HERE AND NOT IN `Components/`. DESIGN.md §12 lists `VSegmentedControl` and
//  `VSlider` among the shared components, and neither exists in `Sources/VigilUI/Components/` yet.
//  Rather than claim a file another slice owns — and risk two agents declaring the same type — both
//  are declared here under the `VInspector` prefix, sized and coloured from `VTheme` so that
//  replacing them later is a rename rather than a redesign. Reported.
//

#if os(macOS)

import SwiftUI

// MARK: - VInspectorSegmented

/// A segmented picker: `Off · On · Auto`, `Auto · Day · Night · Schedule`.
///
/// §9.2's geometry: a `layer.canvas` (E0) track with a `stroke.default` hairline, `radius.sm` 6 and
/// 2 pt inner padding; the thumb is `surfaceRaised` with a `stroke.strong` edge at `radius.xs` 4.
///
/// ⚠️ §9.2 animates the thumb with `matchedGeometryEffect(id:in:)` against the window's `selection`
/// namespace. That namespace is published by `Window/MainWindowView.swift`, which does not exist,
/// and a `@Namespace` of this control's own would be a different effect wearing the same name. The
/// thumb therefore cross-fades with ``VTheme/Motion/snap`` — the animation §9.2 asks for, applied
/// to opacity instead of to a frame. Reported.
@MainActor
package struct VInspectorSegmented<Value: Hashable>: View {

    /// The options, in the order they are shown.
    package let options: [Value]

    /// The label for one option.
    package let title: (Value) -> LocalizedStringKey

    /// The current selection. Writing it is what tells the caller a segment was chosen.
    @Binding package var selection: Value

    @Environment(\.vMotionEnabled) private var motionEnabled

    /// Creates a segmented picker.
    ///
    /// - Parameters:
    ///   - options: every choice, in display order. An empty array renders nothing.
    ///   - selection: the current value. A selection outside `options` simply shows no thumb,
    ///     which is the honest rendering of a device reporting a mode we do not offer.
    ///   - title: the localised label for an option.
    package init(options: [Value],
                 selection: Binding<Value>,
                 title: @escaping (Value) -> LocalizedStringKey) {
        self.options = options
        self._selection = selection
        self.title = title
    }

    package var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(VTheme.Space.hair)
        .background(VTheme.Color.Layer.inset, in: VTheme.Radius.shape(VTheme.Radius.sm))
        .overlay {
            VTheme.Radius.shape(VTheme.Radius.sm)
                .strokeBorder(VTheme.Color.Stroke.default, lineWidth: VTheme.Border.thin)
                .allowsHitTesting(false)
        }
        .animation(VTheme.Motion.resolved(VTheme.Motion.snap, reduced: !motionEnabled),
                   value: selection)
    }

    // MARK: - Private Helpers

    @ViewBuilder
    private func segment(_ option: Value) -> some View {
        let isSelected = option == selection
        Button {
            selection = option
        } label: {
            Text(title(option), bundle: .vigilUI)
                .vType(isSelected ? VTheme.Typography.headline : VTheme.Typography.body)
                .foregroundStyle(isSelected
                                    ? VTheme.Color.Text.primary
                                    : VTheme.Color.Text.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: VTheme.Metrics.sm - VTheme.Space.xxs)
                .background {
                    if isSelected {
                        VTheme.Radius.shape(VTheme.Radius.xs)
                            .fill(VTheme.Color.Layer.surfaceRaised)
                            .overlay {
                                VTheme.Radius.shape(VTheme.Radius.xs)
                                    .strokeBorder(VTheme.Color.Stroke.strong,
                                                  lineWidth: VTheme.Border.thin)
                            }
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - VInspectorSliderRow

/// A labelled 0…100 slider with its value printed in monospaced digits.
///
/// The readout is `mono.numeric` at ``VTheme/Typography/Reserved/fps``' 46 pt, so dragging from 9
/// to 100 does not shove the slider sideways — §4.4's whole point, applied to the one control in
/// the inspector whose number changes continuously.
@MainActor
package struct VInspectorSliderRow: View {

    /// The control's label.
    package let label: LocalizedStringKey

    /// The value, normally bridged from ``InspectorImageSettings`` by the caller.
    @Binding package var value: Double

    /// The permitted range. `InspectorImageSettings.range` is 0…100 throughout.
    package let range: ClosedRange<Double>

    /// Whether the control is live. A device that does not support the feature shows it disabled
    /// rather than hiding it, so the panel's shape does not change per model.
    package let isEnabled: Bool

    /// Creates a slider row.
    package init(_ label: LocalizedStringKey,
                 value: Binding<Double>,
                 range: ClosedRange<Double> = 0...100,
                 isEnabled: Bool = true) {
        self.label = label
        self._value = value
        self.range = range
        self.isEnabled = isEnabled
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: VTheme.Space.xxs) {
            HStack(spacing: VTheme.Space.sm) {
                Text(label, bundle: .vigilUI)
                    .vType(VTheme.Typography.callout)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
                    .lineLimit(1)
                Spacer(minLength: VTheme.Space.xs)
                Text(verbatim: InspectorStat.fixed(value, places: 0))
                    .vType(VTheme.Typography.mono.numeric)
                    .foregroundStyle(VTheme.Color.Text.primary)
                    .vReserved(VTheme.Typography.Reserved.fps)
            }
            //     init(value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1,
            //          onEditingChanged: @escaping (Bool) -> Void = { _ in })
            Slider(value: $value, in: range, step: 1)
                .tint(VTheme.Color.Semantic.accent)
                .disabled(!isEnabled)
        }
        .padding(.vertical, VTheme.Space.xxs)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - VInspectorToggleRow

/// A labelled switch.
///
/// `Toggle` with `.switch` rather than a hand-drawn track: DESIGN.md §9.3 specifies a 32 × 18 pt
/// track that the system control already matches closely, and a custom one would be a second focus
/// ring and a second keyboard behaviour to keep correct for no visible gain.
@MainActor
package struct VInspectorToggleRow: View {

    /// The label.
    package let label: LocalizedStringKey

    /// The state.
    @Binding package var isOn: Bool

    /// Creates a switch row.
    package init(_ label: LocalizedStringKey, isOn: Binding<Bool>) {
        self.label = label
        self._isOn = isOn
    }

    package var body: some View {
        Toggle(isOn: $isOn) {
            Text(label, bundle: .vigilUI)
                .vType(VTheme.Typography.callout)
                .foregroundStyle(VTheme.Color.Text.secondary)
        }
        .toggleStyle(.switch)
        .tint(VTheme.Color.Semantic.accentFill)
        .frame(minHeight: VInspectorMetrics.rowHeight)
    }
}

// MARK: - Previews

#if DEBUG && !VIGIL_NO_PREVIEWS

/// Preview host: `@State` cannot live directly in a `#Preview` body on the macOS 14 SDK.
@MainActor
private struct VInspectorInputsPreview: View {

    @State private var mode: InspectorTriState = .auto
    @State private var brightness: Double = 62
    @State private var localOnly = true

    var body: some View {
        VStack(alignment: .leading, spacing: VTheme.Space.md) {
            VInspectorSegmented(options: InspectorTriState.allCases, selection: $mode) { option in
                switch option {
                case .off: return "Off"
                case .on: return "On"
                case .auto: return "Auto"
                }
            }
            VInspectorSliderRow("Brightness", value: $brightness)
            VInspectorToggleRow("Adjust my view only", isOn: $localOnly)
        }
        .padding(VTheme.Space.lg)
        .frame(width: VTheme.Metrics.inspectorWidth)
        .background(VTheme.Color.Layer.surface)
    }
}

#Preview("Inspector inputs") {
    VInspectorInputsPreview()
}
#endif

#endif  // os(macOS)
