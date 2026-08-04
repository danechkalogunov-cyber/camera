//
//  VInspectorPTZTab.swift
//  VigilUI
//
//  The PTZ tab: the eight-direction pad with Home at its centre, the discrete speed, the zoom,
//  focus and iris rockers, the preset grid and the patrol rows.
//  macOS-only. Implements docs/UX.md §6.3 and §15.3 (optimistic PTZ), docs/DESIGN.md §9.15 (the
//  pad), §7.1 (`snap`, `rubber`) and §10.6 (hit targets).
//
//  ⛔ THE TIMING IS NOT REIMPLEMENTED HERE. `InspectorPTZHold` already owns what a press means, what
//  a release means, whether a gesture was short enough to be a tap, and the 8 s safety deadline that
//  stops a camera nobody is holding any more. This view does exactly three things with it:
//
//   1. calls ``InspectorPTZHold/begin(_:at:direction:)`` when a press starts,
//   2. calls ``InspectorPTZHold/end(at:)`` from **every** exit it has — release, disappear, and a
//      change of camera — because the hold's first guard is that every begin is paired,
//   3. calls ``InspectorPTZHold/tick(at:)`` whenever the panel's injected `now` advances, which is
//      what makes the safety deadline fire without this view owning a timer.
//
//  Whatever the state machine returns is handed to ``VInspectorActions/onPTZ`` unchanged. The view
//  never invents a `.stop`, never decides a duration, and never sends anything the machine did not
//  ask for — which is the only way the tested transitions and the wire can stay in agreement.
//
//  ⚠️ The pad is UX.md §6.3's **discrete** eight-sector control, not DESIGN.md §9.16's analogue
//  joystick. `InspectorPTZHold.swift` already documents that conflict and picks UX.md's; picking
//  differently here would make the tested vectors unreachable from the only control that produces
//  them. Reported.
//

#if os(macOS)

import SwiftUI

import VigilISAPI

// MARK: - VInspectorPTZTab

/// UX.md §6.3.
@MainActor
package struct VInspectorPTZTab: View {

    // MARK: - Geometry

    /// 44 pt per pad cell — a 132 pt three-by-three pad, comfortably past §10.6's 24 pt minimum
    /// and close to §9.15's 148 pt circle without the analogue behaviour it implies.
    package static let padCell: CGFloat = 44

    /// 64 × 36 pt preset thumbnails, three to a row (UX.md §6.3).
    package static let presetWidth: CGFloat = 64

    /// See ``presetWidth``.
    package static let presetHeight: CGFloat = 36

    // MARK: - Stored Properties

    /// The panel's snapshot.
    package let state: VInspectorState

    /// The panel's handlers.
    package let actions: VInspectorActions

    /// The press-and-hold state machine. `@State` supplies the isolation the value deliberately
    /// does not carry itself.
    @State private var hold = InspectorPTZHold()

    @Environment(\.vMotionEnabled) private var motionEnabled

    /// Creates the tab.
    package init(state: VInspectorState, actions: VInspectorActions) {
        self.state = state
        self.actions = actions
    }

    // MARK: - View

    package var body: some View {
        Group {
            if state.ptz.isPresent {
                controls
            } else {
                VInspectorEmptyState(symbol: VInspectorTab.ptz.symbol,
                                     title: "This camera has no PTZ.",
                                     message: "It is a fixed camera. You can still zoom digitally.")
            }
        }
        // The safety deadline, driven by the panel's clock rather than by a timer of this view's.
        .onChange(of: state.now) { _, instant in
            dispatch(hold.tick(at: instant))
        }
        // Every exit path calls `end`. A window closed mid-press, a camera switched under the
        // cursor, a tab changed — all of them land here, and `end` is harmless when nothing is held.
        .onChange(of: state.camera) { _, _ in
            dispatch(hold.end(at: Date.now))
        }
        .onDisappear {
            dispatch(hold.end(at: Date.now))
        }
    }

    @ViewBuilder
    private var controls: some View {
        VInspectorSectionHeader("Move")
        pad
        speedRow
        expiryNotice
        lensSection
        presetsSection
        patrolsSection
    }

    // MARK: - The pad

    /// Eight directions around a Home button.
    ///
    /// Laid out as three `HStack`s rather than a `Grid` so the cells' hit areas are unambiguous and
    /// so the whole thing degrades to a legible column at the 288 pt minimum panel width.
    private var pad: some View {
        VStack(spacing: VTheme.Space.hair) {
            HStack(spacing: VTheme.Space.hair) {
                padButton(.upLeft, symbol: "\u{2196}", label: "Up and left")
                padButton(.up, symbol: "\u{2191}", label: "Up")
                padButton(.upRight, symbol: "\u{2197}", label: "Up and right")
            }
            HStack(spacing: VTheme.Space.hair) {
                padButton(.left, symbol: "\u{2190}", label: "Left")
                homeButton
                padButton(.right, symbol: "\u{2192}", label: "Right")
            }
            HStack(spacing: VTheme.Space.hair) {
                padButton(.downLeft, symbol: "\u{2199}", label: "Down and left")
                padButton(.down, symbol: "\u{2193}", label: "Down")
                padButton(.downRight, symbol: "\u{2198}", label: "Down and right")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, VTheme.Space.sm)
        .disabled(!state.ptz.supportsContinuous && !state.ptz.supportsMomentary)
    }

    /// One sector.
    ///
    /// A `DragGesture` with `minimumDistance: 0` rather than a `Button`, because a button fires on
    /// *release* and this control has to act on press and keep acting until release. `onChanged`
    /// fires repeatedly while the pointer is down; ``InspectorPTZHold/begin(_:at:direction:)``
    /// already returns `.none` for a repeat of the same vector, so the repeats cost nothing and
    /// cannot extend the safety window.
    private func padButton(_ direction: InspectorPTZDirection,
                           symbol: String,
                           label: LocalizedStringKey) -> some View {
        let isActive = hold.direction == direction
        return Text(verbatim: symbol)
            .vType(VTheme.Typography.title3)
            .foregroundStyle(isActive
                                ? VTheme.Color.Text.inverse
                                : VTheme.Color.Text.secondary)
            .frame(width: Self.padCell, height: Self.padCell)
            .background(isActive
                            ? VTheme.Color.Semantic.accentFill
                            : VTheme.Color.Layer.surfaceRaised,
                        in: VTheme.Radius.shape(VTheme.Radius.md))
            .overlay {
                VTheme.Radius.shape(VTheme.Radius.md)
                    .strokeBorder(VTheme.Color.Stroke.default, lineWidth: VTheme.Border.thin)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in press(direction) }
                    .onEnded { _ in release(direction) })
            .animation(VTheme.Motion.resolved(VTheme.Motion.snap, reduced: !motionEnabled),
                       value: isActive)
            .accessibilityLabel(Text(label, bundle: .vigilUI))
            .accessibilityAddTraits(.isButton)
    }

    /// Home is a tap, not a hold: the device drives itself back and there is nothing to release.
    private var homeButton: some View {
        Button(action: actions.onPTZHome) {
            VTheme.Symbol.homePosition.image()
                .vIcon(size: VTheme.Icon.lg, weight: VTheme.Icon.Weight.lg)
                .foregroundStyle(VTheme.Color.Text.secondary)
                .frame(width: Self.padCell, height: Self.padCell)
                .background(VTheme.Color.Layer.surfaceRaised,
                            in: VTheme.Radius.shape(VTheme.Radius.md))
                .overlay {
                    VTheme.Radius.shape(VTheme.Radius.md)
                        .strokeBorder(VTheme.Color.Stroke.default, lineWidth: VTheme.Border.thin)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(Text("Home", bundle: .vigilUI))
    }

    // MARK: - Speed

    /// The discrete 1…7 of UX.md §6.3, printed as `4 / 7`.
    private var speedRow: some View {
        let range = InspectorPTZVector.speedRange
        let bounds = Double(range.lowerBound)...Double(range.upperBound)
        return VInspectorSliderRow("Speed", value: speedBinding, range: bounds)
    }

    /// The speed as a `Double` the slider can drive, rounded back to the wire's integer on write.
    private var speedBinding: Binding<Double> {
        Binding(get: { Double(hold.speed) },
                set: { hold.speed = Int($0.rounded()) })
    }

    /// The line that appears when the 8 s deadline stopped the camera on its own.
    ///
    /// ⛔ Named rather than silent: a camera that stopped while the user was still holding the key
    /// looks like a fault unless something says otherwise (``InspectorPTZHoldAction/stopExpired``).
    @ViewBuilder
    private var expiryNotice: some View {
        if hold.didExpire {
            HStack(spacing: VTheme.Space.xxs) {
                VTheme.Symbol.info.image()
                    .vIcon(size: VTheme.Icon.xs, weight: VTheme.Icon.Weight.xs)
                Text("Movement stopped automatically.", bundle: .vigilUI)
                    .vType(VTheme.Typography.caption1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(VTheme.Color.Text.tertiary)
            .padding(.bottom, VTheme.Space.xxs)
            .transition(.opacity)
        }
    }

    // MARK: - Lens

    /// Zoom, focus and iris, each a pair of press-and-hold rockers.
    ///
    /// Focus and iris go through their own service calls rather than through the hold machine:
    /// `InspectorPTZService` gives them a velocity setter with an explicit zero-stop, and running
    /// them through a state machine built for a pan/tilt vector would mean inventing a vector they
    /// do not have.
    @ViewBuilder
    private var lensSection: some View {
        VInspectorSectionHeader("Lens")
        VStack(alignment: .leading, spacing: VTheme.Space.xs) {
            rockerRow("Zoom", symbols: ("\u{2212}", "+"),
                      labels: ("Zoom out", "Zoom in"),
                      isEnabled: true,
                      onPress: { inward in zoom(inward: inward) },
                      onRelease: { _ in dispatch(hold.end(at: Date.now)) })
            rockerRow("Focus", symbols: ("\u{25D0}", "\u{25D1}"),
                      labels: ("Focus near", "Focus far"),
                      isEnabled: state.ptz.supportsFocus,
                      onPress: { far in
                          actions.onPTZFocus(lensVelocity(positive: far))
                      },
                      onRelease: { _ in actions.onPTZFocus(0) })
            rockerRow("Iris", symbols: ("\u{2296}", "\u{2295}"),
                      labels: ("Iris close", "Iris open"),
                      isEnabled: state.ptz.supportsIris,
                      onPress: { open in
                          actions.onPTZIris(lensVelocity(positive: open))
                      },
                      onRelease: { _ in actions.onPTZIris(0) })
        }
    }

    /// A label and two press-and-hold buttons.
    ///
    /// - Parameters:
    ///   - label: the row's name.
    ///   - symbols: the glyphs for the negative and positive directions, in that order.
    ///   - labels: their VoiceOver names, in the same order.
    ///   - isEnabled: whether the device reports the capability.
    ///   - onPress: called with `false` for the leading button and `true` for the trailing one.
    ///   - onRelease: called with the same flag when the press ends.
    private func rockerRow(_ label: LocalizedStringKey,
                           symbols: (String, String),
                           labels: (LocalizedStringKey, LocalizedStringKey),
                           isEnabled: Bool,
                           onPress: @escaping (Bool) -> Void,
                           onRelease: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: VTheme.Space.sm) {
            Text(label, bundle: .vigilUI)
                .vType(VTheme.Typography.callout)
                .foregroundStyle(VTheme.Color.Text.tertiary)
            Spacer(minLength: VTheme.Space.xs)
            rocker(symbols.0, label: labels.0, isPositive: false,
                   onPress: onPress, onRelease: onRelease)
            rocker(symbols.1, label: labels.1, isPositive: true,
                   onPress: onPress, onRelease: onRelease)
        }
        .frame(minHeight: VInspectorMetrics.rowHeight)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private func rocker(_ symbol: String,
                        label: LocalizedStringKey,
                        isPositive: Bool,
                        onPress: @escaping (Bool) -> Void,
                        onRelease: @escaping (Bool) -> Void) -> some View {
        Text(verbatim: symbol)
            .vType(VTheme.Typography.headline)
            .foregroundStyle(VTheme.Color.Text.secondary)
            .frame(width: VTheme.Metrics.md, height: VTheme.Metrics.md)
            .background(VTheme.Color.Layer.surfaceRaised,
                        in: VTheme.Radius.shape(VTheme.Radius.md))
            .overlay {
                VTheme.Radius.shape(VTheme.Radius.md)
                    .strokeBorder(VTheme.Color.Stroke.default, lineWidth: VTheme.Border.thin)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in onPress(isPositive) }
                    .onEnded { _ in onRelease(isPositive) })
            .accessibilityLabel(Text(label, bundle: .vigilUI))
            .accessibilityAddTraits(.isButton)
    }

    // MARK: - Presets

    /// The preset grid. Only the user slots — 33…105 are device commands, not storage, and
    /// `PTZPreset.isReservedCommand` is what says so.
    @ViewBuilder
    private var presetsSection: some View {
        let userPresets = state.presets.filter { !$0.isReservedCommand }
        VInspectorSectionHeader("Presets")
        if state.ptz.supportsPresets {
            if userPresets.isEmpty {
                Text("No presets saved yet.", bundle: .vigilUI)
                    .vType(VTheme.Typography.caption1)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
            } else {
                LazyVGrid(columns: presetColumns, alignment: .leading, spacing: VTheme.Space.xs) {
                    ForEach(userPresets) { preset in
                        presetCell(preset)
                    }
                }
            }
        } else {
            Text("This camera does not store presets.", bundle: .vigilUI)
                .vType(VTheme.Typography.caption1)
                .foregroundStyle(VTheme.Color.Text.tertiary)
        }
    }

    /// Three flexible columns, which is UX.md §6.3's layout at every panel width.
    private var presetColumns: [GridItem] {
        [GridItem(.flexible(), spacing: VTheme.Space.xs),
         GridItem(.flexible(), spacing: VTheme.Space.xs),
         GridItem(.flexible(), spacing: VTheme.Space.xs)]
    }

    /// One preset.
    ///
    /// ⚠️ UX.md §6.3 puts a cached 64 × 36 JPEG in this box. Nothing in this package loads or caches
    /// those thumbnails, so the cell shows the preset's **number** in the same box instead. The
    /// geometry is the specification's, so dropping an image in later is a change of contents rather
    /// than of layout. Reported.
    private func presetCell(_ preset: PTZPreset) -> some View {
        Button {
            actions.onPTZGoToPreset(preset.id)
        } label: {
            VStack(alignment: .leading, spacing: VTheme.Space.hair) {
                Text(verbatim: String(preset.id))
                    .vType(VTheme.Typography.monoLarge.numeric)
                    .foregroundStyle(VTheme.Color.Text.secondary)
                    .frame(width: Self.presetWidth, height: Self.presetHeight)
                    .background(VTheme.Color.Layer.inset,
                                in: VTheme.Radius.shape(VTheme.Radius.lg))
                    .overlay {
                        VTheme.Radius.shape(VTheme.Radius.lg)
                            .strokeBorder(VTheme.Color.Stroke.default,
                                          lineWidth: VTheme.Border.thin)
                    }
                Text(verbatim: preset.displayName)
                    .vType(VTheme.Typography.caption2)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
                    .lineLimit(1)
                    .frame(width: Self.presetWidth, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(Text(verbatim: preset.displayName))
        .contextMenu {
            Button { actions.onPTZGoToPreset(preset.id) } label: {
                Text("Go to preset", bundle: .vigilUI)
            }
            Button { actions.onPTZSavePreset(preset.id) } label: {
                Text("Set to Current", bundle: .vigilUI)
            }
            Button(role: .destructive) { actions.onPTZDeletePreset(preset.id) } label: {
                Text("Delete preset", bundle: .vigilUI)
            }
        }
    }

    // MARK: - Patrols

    @ViewBuilder
    private var patrolsSection: some View {
        if state.ptz.supportsPatrols, !state.patrols.isEmpty {
            VInspectorSectionHeader("Patrols")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(state.patrols) { patrol in
                    patrolRow(patrol)
                }
            }
        }
    }

    private func patrolRow(_ patrol: PTZPatrol) -> some View {
        let isRunning = state.runningPatrol == patrol.id
        return HStack(spacing: VTheme.Space.sm) {
            Button {
                if isRunning {
                    actions.onPTZStopPatrol(patrol.id)
                } else {
                    actions.onPTZStartPatrol(patrol.id)
                }
            } label: {
                (isRunning ? VTheme.Symbol.stop : VTheme.Symbol.play).image()
                    .vIcon(size: VTheme.Icon.sm, weight: VTheme.Icon.Weight.sm)
                    .foregroundStyle(isRunning
                                        ? VTheme.Color.Semantic.accent
                                        : VTheme.Color.Text.secondary)
                    .frame(width: VTheme.Metrics.minHitTarget,
                           height: VTheme.Metrics.minHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel(isRunning
                                    ? Text("Stop patrol", bundle: .vigilUI)
                                    : Text("Start patrol", bundle: .vigilUI))
            Text(verbatim: patrol.name)
                .vType(VTheme.Typography.body)
                .foregroundStyle(VTheme.Color.Text.primary)
                .lineLimit(1)
            Spacer(minLength: VTheme.Space.xs)
            stopsLabel(patrol.stops.count)
        }
        .frame(minHeight: VInspectorMetrics.rowHeight)
    }

    /// `Stops: 8`.
    ///
    /// Phrased as a label and a number rather than as "8 stops" on purpose: Russian agrees the noun
    /// with the count (`8 остановок`, `2 остановки`, `1 остановка`), which needs a `.stringsdict`
    /// entry. A colon-and-number reads correctly in both languages with one flat key.
    private func stopsLabel(_ count: Int) -> some View {
        let value = VInspectorFormat.count(count)
        return Text("Stops: \(value)", bundle: .vigilUI)
            .vType(VTheme.Typography.caption1Numeric)
            .foregroundStyle(VTheme.Color.Text.tertiary)
    }

    // MARK: - Behaviour

    /// Starts or redirects a hold on the pad.
    ///
    /// `Date.now` rather than the panel's `now`: a tap is under 300 ms and the injected clock ticks
    /// at 1 Hz, so tap detection needs the real instant. Both are absolute dates on the same
    /// timeline, which is why the deadline can still be driven from the injected one.
    private func press(_ direction: InspectorPTZDirection) {
        let vector = InspectorPTZVector.pad(direction, speed: hold.speed)
        dispatch(hold.begin(vector, at: Date.now, direction: direction))
    }

    /// Ends a hold, sending a self-terminating pulse instead when the gesture was a tap.
    ///
    /// ``InspectorPTZHold/isTap(endingAt:)`` must be asked **before** `end`, which clears the start
    /// time. UX.md §6.3: "tap = 300 ms pulse" — a pulse needs no stop at all, which is why the
    /// order matters rather than being tidiness.
    private func release(_ direction: InspectorPTZDirection) {
        let instant = Date.now
        let wasTap = hold.isTap(endingAt: instant)
        // The stop goes out either way: the press already started a continuous move, and leaving
        // it running because the gesture turned out to be short is the exact failure the hold's
        // header warns about.
        dispatch(hold.end(at: instant))
        guard wasTap else { return }
        actions.onPTZNudge(InspectorPTZVector.pad(direction, speed: hold.speed))
    }

    /// A zoom hold, which shares the pad's state machine but has no direction to light.
    private func zoom(inward: Bool) {
        let vector = InspectorPTZVector.zoom(inward: inward, speed: hold.speed)
        dispatch(hold.begin(vector, at: Date.now))
    }

    /// −100…100 for the lens rockers, at the pad's own speed so one control governs the whole tab.
    private func lensVelocity(positive: Bool) -> Int {
        let magnitude = InspectorPTZVector.wireSpeed(hold.speed)
        return positive ? magnitude : -magnitude
    }

    /// Hands the machine's decision to the app. ``InspectorPTZHoldAction/none`` is dropped here so
    /// no call site has to remember to.
    private func dispatch(_ action: InspectorPTZHoldAction) {
        guard action != .none else { return }
        actions.onPTZ(action)
    }
}

// MARK: - Previews

#if DEBUG && !VIGIL_NO_PREVIEWS
#Preview("PTZ — full capability") {
    ScrollView {
        VInspectorPTZTab(state: .previewHealthy, actions: VInspectorActions())
            .padding(VTheme.Space.lg)
    }
    .frame(width: VTheme.Metrics.inspectorWidth, height: 720)
    .background(VTheme.Color.Layer.surface)
}

#Preview("PTZ — fixed camera") {
    ScrollView {
        VInspectorPTZTab(state: .previewDegraded, actions: VInspectorActions())
            .padding(VTheme.Space.lg)
    }
    .frame(width: VTheme.Metrics.inspectorWidth, height: 360)
    .background(VTheme.Color.Layer.surface)
}
#endif

#endif  // os(macOS)
