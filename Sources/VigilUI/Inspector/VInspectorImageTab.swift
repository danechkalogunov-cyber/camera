//
//  VInspectorImageTab.swift
//  VigilUI
//
//  The Image tab: the four colour sliders, the three segmented modes and their levels, the flip,
//  and the "adjust my view only" switch that keeps a shared camera safe.
//  macOS-only. Implements docs/UX.md §6.4 and §15.4 (the 250 ms trailing debounce, which lives in
//  the app), and docs/DESIGN.md §9.2, §9.3.
//
//  ⛔ NO LOCAL COPY OF THE SETTINGS. Every control writes the whole ``InspectorImageSettings``
//  straight back through ``VInspectorActions/onImageSettings``, and reads its value from the state
//  it was handed. A `@State` mirror here would be a second source of truth that disagrees with the
//  device the moment a write fails — and UX.md §15.4 is explicit that a failed write reverts the
//  control, which only works if the control has nothing of its own to revert.
//
//  ⚠️ UX.md §6.4 lists five more controls than this tab shows: backlight compensation, noise
//  reduction, deinterlace, night boost, and the "Copy Settings / Paste to…" footer.
//  ``InspectorImageSettings`` has no field for any of them, so they are absent rather than faked.
//  Reported.
//

#if os(macOS)

import SwiftUI

// MARK: - VInspectorImageTab

/// UX.md §6.4.
@MainActor
package struct VInspectorImageTab: View {

    /// The panel's snapshot.
    package let state: VInspectorState

    /// The panel's handlers.
    package let actions: VInspectorActions

    /// Creates the tab.
    package init(state: VInspectorState, actions: VInspectorActions) {
        self.state = state
        self.actions = actions
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            adjustmentsSection
            exposureSection
            orientationSection
            footer
        }
    }

    // MARK: - Adjustments

    @ViewBuilder
    private var adjustmentsSection: some View {
        VInspectorSectionHeader("Adjustments")
        VInspectorSliderRow("Brightness", value: level(\.brightness))
        VInspectorSliderRow("Contrast", value: level(\.contrast))
        VInspectorSliderRow("Saturation", value: level(\.saturation))
        VInspectorSliderRow("Sharpness", value: level(\.sharpness))
        VInspectorToggleRow("Adjust my view only", isOn: localPreviewBinding)
        Text("""
            Local changes stay in Vigil's own render path and are never written to the camera, \
            so they cannot affect anyone else watching it.
            """, bundle: .vigilUI)
            .vType(VTheme.Typography.caption1)
            .foregroundStyle(VTheme.Color.Text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Exposure

    /// Wide dynamic range, day/night and the infrared supplement light.
    ///
    /// Each level slider is disabled rather than hidden when its mode is off, so the panel does not
    /// change height as a segment is chosen — a layout that jumps under the cursor is a layout that
    /// gets mis-clicked.
    @ViewBuilder
    private var exposureSection: some View {
        VInspectorSectionHeader("Exposure")
        labelled("Wide dynamic range") {
            VInspectorSegmented(options: InspectorTriState.allCases,
                                selection: triStateBinding(\.wdrMode),
                                title: Self.triStateTitle)
        }
        VInspectorSliderRow("Level", value: level(\.wdrLevel),
                            isEnabled: state.image.wdrMode != .off)
        labelled("Day / night") {
            VInspectorSegmented(options: InspectorDayNightMode.allCases,
                                selection: dayNightBinding,
                                title: Self.dayNightTitle)
        }
        labelled("Infrared light") {
            VInspectorSegmented(options: InspectorTriState.allCases,
                                selection: triStateBinding(\.irMode),
                                title: Self.triStateTitle)
        }
        VInspectorSliderRow("Level", value: level(\.irLevel),
                            isEnabled: state.image.irMode != .off)
    }

    // MARK: - Orientation

    @ViewBuilder
    private var orientationSection: some View {
        VInspectorSectionHeader("Orientation")
        labelled("Flip") {
            VInspectorSegmented(options: InspectorFlipMode.allCases,
                                selection: flipBinding,
                                title: Self.flipTitle)
        }
    }

    // MARK: - Footer

    /// ⚠️ `Reset to Defaults` is destructive on the device, and UX.md §6.4 asks for a confirmation.
    /// The confirmation belongs to the app, which owns the sheet stack; this view only reports the
    /// press. Reported.
    @ViewBuilder
    private var footer: some View {
        VInspectorSectionHeader("Actions")
        VButton("Reset to Defaults", symbol: .reset, style: .secondary, size: .sm,
                action: actions.onResetImage)
            .padding(.top, VTheme.Space.xxs)
    }

    // MARK: - Layout helper

    /// A caption above a full-width control, which is how a four-segment picker fits a 288 pt panel.
    private func labelled<Content: View>(_ title: LocalizedStringKey,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: VTheme.Space.xxs) {
            Text(title, bundle: .vigilUI)
                .vType(VTheme.Typography.callout)
                .foregroundStyle(VTheme.Color.Text.tertiary)
            content()
        }
        .padding(.vertical, VTheme.Space.xxs)
    }

    // MARK: - Bindings

    /// Bridges one 0…100 level to the slider and back through the callback.
    ///
    /// A computed `Binding` rather than `@State`: the getter reads the injected value, so a device
    /// that rejects a write simply keeps its old number and the slider follows it back.
    private func level(_ keyPath: WritableKeyPath<InspectorImageSettings, Int>) -> Binding<Double> {
        Binding(get: { Double(state.image[keyPath: keyPath]) },
                set: { newValue in
                    var next = state.image
                    next[keyPath: keyPath] = Int(newValue.rounded())
                    actions.onImageSettings(next)
                })
    }

    private func triStateBinding(
        _ keyPath: WritableKeyPath<InspectorImageSettings, InspectorTriState>
    ) -> Binding<InspectorTriState> {
        Binding(get: { state.image[keyPath: keyPath] },
                set: { newValue in
                    var next = state.image
                    next[keyPath: keyPath] = newValue
                    actions.onImageSettings(next)
                })
    }

    private var dayNightBinding: Binding<InspectorDayNightMode> {
        Binding(get: { state.image.dayNightMode },
                set: { newValue in
                    var next = state.image
                    next.dayNightMode = newValue
                    actions.onImageSettings(next)
                })
    }

    private var flipBinding: Binding<InspectorFlipMode> {
        Binding(get: { state.image.flip },
                set: { newValue in
                    var next = state.image
                    next.flip = newValue
                    actions.onImageSettings(next)
                })
    }

    private var localPreviewBinding: Binding<Bool> {
        Binding(get: { state.image.isLocalPreviewOnly },
                set: { newValue in
                    var next = state.image
                    next.isLocalPreviewOnly = newValue
                    actions.onImageSettings(next)
                })
    }

    // MARK: - Segment titles

    /// `Off · On · Auto`.
    nonisolated static func triStateTitle(_ value: InspectorTriState) -> LocalizedStringKey {
        switch value {
        case .off: return "Off"
        case .on: return "On"
        case .auto: return "Auto"
        }
    }

    /// `Auto · Day · Night · Schedule`.
    nonisolated static func dayNightTitle(_ value: InspectorDayNightMode) -> LocalizedStringKey {
        switch value {
        case .auto: return "Auto"
        case .day: return "Day"
        case .night: return "Night"
        case .schedule: return "Schedule"
        }
    }

    /// `Off · Centre · Horizontal · Vertical`. British spelling, as the rest of this module uses.
    nonisolated static func flipTitle(_ value: InspectorFlipMode) -> LocalizedStringKey {
        switch value {
        case .off: return "Off"
        case .centre: return "Centre"
        case .horizontal: return "Horizontal"
        case .vertical: return "Vertical"
        }
    }
}

// MARK: - Previews

#if DEBUG && !VIGIL_NO_PREVIEWS
#Preview("Image — defaults") {
    ScrollView {
        VInspectorImageTab(state: .previewHealthy, actions: VInspectorActions())
            .padding(VTheme.Space.lg)
    }
    .frame(width: VTheme.Metrics.inspectorWidth, height: 720)
    .background(VTheme.Color.Layer.surface)
}

#Preview("Image — pushed hard, local preview only") {
    ScrollView {
        VInspectorImageTab(state: .previewDegraded, actions: VInspectorActions())
            .padding(VTheme.Space.lg)
    }
    .frame(width: VTheme.Metrics.inspectorWidth, height: 720)
    .background(VTheme.Color.Layer.surface)
}
#endif

#endif  // os(macOS)
