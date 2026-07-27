//
//  VInspectorView.swift
//  VigilUI
//
//  The right panel: the camera's name and status line, the six-tab bar, and whichever tab is
//  showing. The tabs themselves are the sibling `VInspector*Tab.swift` files.
//  macOS-only. Implements design/mockups/01-main-window.html (the right panel), docs/UX.md §6 and
//  docs/DESIGN.md §2.2 (the layer), §9.2 (the tab bar) and §4.4.
//
//  ## What this view does not do
//
//  It does not fetch, subscribe, debounce, or spawn a `Task`. It is handed a ``VInspectorState`` and
//  a ``VInspectorActions`` and draws exactly that. UX.md §6.2 makes the reason a hard number — the
//  inspector must cost under 0.4 ms per frame — and the only way to hold that while sixteen decoders
//  run is for the panel to have no clock of its own. The app samples telemetry at 1 Hz and hands
//  down a snapshot; every relative reading in the panel is measured against the `now` in that
//  snapshot, so nothing here can disagree with anything else here.
//
//  ## The background
//
//  DESIGN.md §2.3's table gives the inspector column the `.sidebar` material. This view draws the
//  mockup's solid `layer.surface` instead, for a structural reason: UX.md §2.2 hosts the panel in
//  macOS 14's `.inspector(isPresented:)`, which already supplies that material behind whatever it
//  is given. A second `NSVisualEffectView` inside the first would blur the first's output rather
//  than the window's, which is not what either specification is asking for. The leading hairline is
//  the mockup's `border-left`. Reported.
//

#if os(macOS)

import SwiftUI

// MARK: - VInspectorView

/// The inspector panel.
///
/// The whole panel is one `ScrollView` under a fixed header and tab bar, which is what keeps the
/// camera's name and its status on screen while a long tab scrolls — the two facts an operator
/// needs in order to trust everything below them.
@MainActor
package struct VInspectorView: View {

    // MARK: - Stored Properties

    /// The selected tab. A binding because UX.md §1.3 persists it in `@SceneStorage` and §16 lets
    /// ⌃1…⌃6 and the menu bar change it from outside this view.
    @Binding package var tab: VInspectorTab

    /// Everything the panel prints.
    package let state: VInspectorState

    /// Everything the panel can ask for.
    package let actions: VInspectorActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    // MARK: - Initialisation

    /// Creates the panel.
    ///
    /// - Parameters:
    ///   - tab: the selected tab.
    ///   - state: the snapshot to draw.
    ///   - actions: the handlers. Defaults to a bag in which nothing is wired, which is what a
    ///     preview wants and what a read-only host can legitimately pass.
    package init(tab: Binding<VInspectorTab>,
                 state: VInspectorState,
                 actions: VInspectorActions = VInspectorActions()) {
        self._tab = tab
        self.state = state
        self.actions = actions
    }

    // MARK: - View

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VInspectorHairline()
            tabBar
            VInspectorHairline()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VTheme.Color.Layer.surface)
        .overlay(alignment: .leading) { leadingEdge }
        .vMotionEnabled(!reduceMotion)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Inspector", bundle: .vigilUI))
    }

    // MARK: - Header

    /// Name, identity mark and the `● Live · H.265 · TCP (interleaved)` status line.
    ///
    /// The identity mark leads the name rather than the status line, so the colour sits beside the
    /// thing it identifies; the status dot leads the status line, so the state sits beside the
    /// words that say it. ⛔ Identity colour is never state (DESIGN.md §3.4) and this is where the
    /// two are most easily confused.
    private var header: some View {
        VStack(alignment: .leading, spacing: VTheme.Space.xxs) {
            HStack(spacing: VTheme.Space.xs) {
                if let camera = state.camera {
                    VIdentityMark(colour: camera.colour, initial: camera.initial)
                    Text(verbatim: camera.name)
                        .vType(VTheme.Typography.title2)
                        .foregroundStyle(VTheme.Color.Text.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("Inspector", bundle: .vigilUI)
                        .vType(VTheme.Typography.title2)
                        .foregroundStyle(VTheme.Color.Text.primary)
                }
            }
            .accessibilityAddTraits(.isHeader)
            statusLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, VTheme.Space.lg)
        .padding(.top, VTheme.Space.md)
        .padding(.bottom, VTheme.Space.md)
    }

    /// The one-line summary under the name.
    ///
    /// Codec and transport are `Text(verbatim:)` because the device spelled them — `H.265`,
    /// `TCP (interleaved)` — and translating a device's own vocabulary is how a support call stops
    /// matching the camera's web UI.
    private var statusLine: some View {
        HStack(spacing: VTheme.Space.xxs) {
            VLiveDot(state.connection.dot)
            Text(state.connection.statusWord, bundle: .vigilUI)
                .vType(VTheme.Typography.caption1)
                .foregroundStyle(VTheme.Color.Text.tertiary)
            if !state.stream.codec.isEmpty {
                separator
                Text(verbatim: state.stream.codec)
                    .vType(VTheme.Typography.caption1)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
            }
            if !state.stream.transport.isEmpty {
                separator
                Text(verbatim: state.stream.transport)
                    .vType(VTheme.Typography.caption1)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// The interpunct between the status line's facts.
    private var separator: some View {
        Text(verbatim: "\u{00B7}")
            .vType(VTheme.Typography.caption1)
            .foregroundStyle(VTheme.Color.Text.disabled)
            .accessibilityHidden(true)
    }

    // MARK: - Tab bar

    /// Six text tabs with a 2 pt `accent` underline under the selected one.
    ///
    /// The mockup's bar is text-only rather than §9.2's thumb-in-a-track: an underline is the
    /// `.hugging` variant §9.2 itself names for "inspector tabs", and six thumbs across 320 pt
    /// would leave no room for `Keyframe int.` below them.
    ///
    /// ⚠️ No `.keyboardShortcut` is attached here. UX.md §16 gives ⌃1…⌃6 to the menu bar, and two
    /// owners of one shortcut is a bug waiting for a second window; ``VInspectorTab/shortcutNumber``
    /// is exposed so the menu can build them. The buttons stay reachable by ⇥ under Full Keyboard
    /// Access, which is the P6 requirement. Reported.
    private var tabBar: some View {
        HStack(spacing: VTheme.Space.hair) {
            ForEach(VInspectorTab.allCases) { candidate in
                tabButton(candidate)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VTheme.Space.sm)
        .padding(.top, VTheme.Space.sm)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func tabButton(_ candidate: VInspectorTab) -> some View {
        let isSelected = candidate == tab
        Button {
            withAnimation(VTheme.Motion.resolved(VTheme.Motion.standard, reduced: reduceMotion)) {
                tab = candidate
            }
        } label: {
            Text(candidate.title, bundle: .vigilUI)
                .vType(VTheme.Typography.callout)
                .foregroundStyle(isSelected
                                    ? VTheme.Color.Text.primary
                                    : VTheme.Color.Text.tertiary)
                .lineLimit(1)
                .padding(.horizontal, VTheme.Space.sm)
                .padding(.top, VTheme.Space.xs)
                .padding(.bottom, VTheme.Space.sm)
                .overlay(alignment: .bottom) { underline(isSelected) }
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func underline(_ isSelected: Bool) -> some View {
        if isSelected {
            Capsule(style: .continuous)
                .fill(VTheme.Color.Semantic.accent)
                .frame(height: VInspectorMetrics.tabUnderline)
                .padding(.horizontal, VTheme.Space.xs)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Content

    /// The selected tab, scrolled.
    ///
    /// `.scrollBounceBehavior(.basedOnSize)` so a short tab — the PTZ empty state, say — does not
    /// rubber-band against a panel that has nothing to scroll.
    private var content: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                tabContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, VTheme.Space.lg)
            .padding(.vertical, VTheme.Space.md)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private var tabContent: some View {
        if state.camera == nil {
            // UX.md §6 asks for an aggregate "System" view here — live/degraded/offline counts, an
            // aggregate bitrate sparkline and a decode-budget gauge. None of those has a value type
            // in this package, so the panel says what it knows instead of inventing three. Reported.
            VInspectorEmptyState(symbol: .camera,
                                 title: "No camera selected.",
                                 message: "Choose a camera in the sidebar to inspect it.")
        } else {
            switch tab {
            case .info:
                VInspectorInfoTab(state: state, actions: actions)
            case .stream:
                VInspectorStreamTab(state: state, actions: actions)
            case .ptz:
                VInspectorPTZTab(state: state, actions: actions)
            case .image:
                VInspectorImageTab(state: state, actions: actions)
            case .events:
                VInspectorEventsTab(state: state, actions: actions)
            case .recording:
                VInspectorRecordingTab(state: state, actions: actions)
            }
        }
    }

    // MARK: - Chrome

    /// The mockup's `border-left`, drawn as a hairline rather than a `.border`.
    private var leadingEdge: some View {
        Rectangle()
            .fill(VTheme.Color.Stroke.default)
            .frame(width: VTheme.Border.hairline(displayScale))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Previews

#if DEBUG

/// Preview host: `@State` cannot live directly in a `#Preview` body on the macOS 14 SDK, and the
/// panel needs a `Binding` for its tab.
@MainActor
private struct VInspectorPreview: View {

    @State private var tab: VInspectorTab
    private let state: VInspectorState

    init(tab: VInspectorTab, state: VInspectorState) {
        self._tab = State(initialValue: tab)
        self.state = state
    }

    var body: some View {
        VPulseClock {
            VInspectorView(tab: $tab, state: state)
        }
        .frame(width: VTheme.Metrics.inspectorWidth, height: 720)
        .background(VTheme.Color.Layer.canvas)
    }
}

#Preview("Inspector — Stream, healthy") {
    VInspectorPreview(tab: .stream, state: .previewHealthy)
}

#Preview("Inspector — Stream, degraded") {
    VInspectorPreview(tab: .stream, state: .previewDegraded)
}

#Preview("Inspector — Info") {
    VInspectorPreview(tab: .info, state: .previewHealthy)
}

#Preview("Inspector — no camera") {
    VInspectorPreview(tab: .stream, state: VInspectorState())
}
#endif

#endif  // os(macOS)
