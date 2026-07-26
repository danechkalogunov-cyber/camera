//
//  ConnectFormView.swift
//  VigilUI
//
//  The first screen: address, user name, password, Connect — and, when it fails, a named cause
//  with a button that does something about it.
//  macOS-only. Implements docs/UX.md §8.3, §12.7, §14, docs/REQUIREMENTS-CUSTOMER.md §R1.4–R1.5,
//  and DESIGN.md §9.18 (hero), §9.5 (fields), §7.4 #45 (the error shake).
//

#if os(macOS)

import SwiftUI

// MARK: - ConnectFormView

/// The connect form.
///
/// The R1.7 acceptance test is "launch the app and reach a visible moving picture within ten
/// seconds, having typed only the password", so this screen is shaped around a single keystroke
/// path: `admin` is already there, the address takes focus first and hands over to the password,
/// and `Return` connects from any field.
///
/// State lives in the caller so the app can prefill an address from discovery and can drive the
/// in-flight and failure states from `VigilCore`.
@MainActor
package struct ConnectFormView: View {

    /// The form's width. UX.md §8.3 fixes the manual-add form at 420 pt, and Russian strings run
    /// 20–35 % longer, which this width was chosen to survive (§14.2).
    package static let formWidth: CGFloat = 420

    /// The hero glyph's container: a 48 pt circle around the 32 pt mark (§9.18).
    package static let heroSize: CGFloat = 48

    // MARK: - Stored Properties

    /// The form's fields, validation and last failure.
    @Binding package var state: ConnectFormState

    /// Called when the user submits a form that validates.
    package let onConnect: (ConnectRequest) -> Void

    /// Called when the user chooses one of a diagnosis's remedies. The two remedies that only move
    /// the cursor — ``ConnectRemedy/checkAddress`` and ``ConnectRemedy/updatePassword`` — are
    /// handled here and are **also** forwarded, so the app can log or extend them.
    package let onRemedy: (ConnectRemedy) -> Void

    @FocusState private var focus: ConnectField?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var pulsesFailureBorder = false
    @State private var shakeCount = 0

    // MARK: - Initialisation

    /// Creates the form.
    package init(state: Binding<ConnectFormState>,
                 onConnect: @escaping (ConnectRequest) -> Void,
                 onRemedy: @escaping (ConnectRemedy) -> Void = { _ in }) {
        self._state = state
        self.onConnect = onConnect
        self.onRemedy = onRemedy
    }

    // MARK: - View

    package var body: some View {
        ZStack {
            background
            ScrollView(.vertical) {
                content
                    .frame(width: Self.formWidth)
                    .padding(.vertical, VTheme.Space.huge)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .vMotionEnabled(!reduceMotion)
        .task { focus = state.host.isEmpty ? .host : .password }
        .onChange(of: state.host) { _, _ in state.absorbPastedURL() }
        .onChange(of: state.request) { _, _ in state.clearDiagnosis() }
        .onChange(of: state.diagnosis) { _, diagnosis in
            guard let diagnosis else { return }
            if let field = diagnosis.fieldToFocus { focus = field }
            // A monotonic counter, so clearing the diagnosis can never fire a second shake.
            if diagnosis.fieldToFocus == .password { shakeCount += 1 }
        }
        .task(id: state.failureCount) { await pulseBorderIfMotionReduced() }
    }

    // MARK: - Background

    /// §2.3: a window with no video in it takes `.underWindowBackground`, behind the window, and
    /// follows the window's active state — so an inactive Vigil recedes the way a Mac app should.
    @ViewBuilder
    private var background: some View {
        if reduceTransparency {
            VTheme.Color.Layer.underWindowFallback
        } else {
            VVisualEffect(material: .underWindowBackground,
                          blending: .behindWindow,
                          state: .followsWindowActiveState)
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            Spacer().frame(height: VTheme.Space.xl)
            Text("Connect to a camera", bundle: .vigilUI)
                .vType(VTheme.Typography.title1)
                .foregroundStyle(VTheme.Color.Text.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer().frame(height: VTheme.Space.sm)
            Text("""
                Vigil needs the camera's address and the password it was set up with. \
                Nothing leaves your network.
                """, bundle: .vigilUI)
                .vType(VTheme.Typography.body)
                .foregroundStyle(VTheme.Color.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer().frame(height: VTheme.Space.xxl)
            fieldsCard
            Spacer().frame(height: VTheme.Space.lg)
            actions
            diagnosisSection
        }
    }

    /// The hero glyph.
    ///
    /// `VTheme.Symbol.camera` and not ``VTheme/Symbol/brandMark``: the brand mark is the custom
    /// `vigil.aperture` symbol, and `VigilUI/Resources/Symbols.xcassets` does not exist yet. An
    /// unresolved `Image(systemName:)` renders as nothing, and a blank hero is the first thing the
    /// customer would see. Swap it back when the asset catalogue ships (DESIGN.md §8.5, §9.18).
    private var hero: some View {
        VTheme.Symbol.camera.image()
            .vIcon(size: VTheme.Icon.hero, weight: VTheme.Icon.Weight.hero)
            .foregroundStyle(VTheme.Color.Semantic.accent)
            .frame(width: Self.heroSize, height: Self.heroSize)
            .background(SwiftUI.Color.white.opacity(0.05), in: Circle())
            .overlay {
                Circle().strokeBorder(VTheme.Color.Stroke.default, lineWidth: VTheme.Border.thin)
            }
            .accessibilityHidden(true)
    }

    // MARK: - Fields

    /// The three fields, in a flat `layer.surface` card (§9.10: static cards carry no shadow).
    ///
    /// The card is what shakes on a credential failure, which is the classic macOS sign-in gesture
    /// and is the one place §7.4 #45's keyframe shake belongs.
    private var fieldsCard: some View {
        VStack(alignment: .leading, spacing: VTheme.Space.sm) {
            VTextField("Address",
                       placeholder: "192.168.1.64",
                       text: $state.host,
                       kind: .monospaced,
                       validation: validation(for: .host),
                       focus: $focus,
                       focusValue: ConnectField.host,
                       onValidate: { _ in state.validate(.host) },
                       onSubmit: { submit() })
            VTextField("User name",
                       placeholder: "admin",
                       text: $state.username,
                       validation: validation(for: .username),
                       focus: $focus,
                       focusValue: ConnectField.username,
                       onValidate: { _ in state.validate(.username) },
                       onSubmit: { submit() })
            VTextField("Password",
                       placeholder: "The camera's password",
                       text: $state.password,
                       kind: .secure,
                       validation: validation(for: .password),
                       focus: $focus,
                       focusValue: ConnectField.password,
                       onValidate: { _ in state.validate(.password) },
                       onSubmit: { submit() })
        }
        .padding(VTheme.Space.lg)
        .background(VTheme.Color.Layer.surface, in: VTheme.Radius.shape(VTheme.Radius.lg))
        .overlay {
            VTheme.Radius.shape(VTheme.Radius.lg)
                .strokeBorder(cardStroke, lineWidth: VTheme.Border.thin)
                .allowsHitTesting(false)
        }
        .modifier(ConnectShake(trigger: shakeCount, isEnabled: !reduceMotion))
    }

    /// The card's hairline. Under reduced motion a failure pulses it `danger` instead of shaking
    /// the card, because §7.10 rule 5 forbids substituting one motion for another (§7.4 #45).
    private var cardStroke: SwiftUI.Color {
        pulsesFailureBorder ? VTheme.Color.Semantic.danger : VTheme.Color.Stroke.default
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: VTheme.Space.sm) {
            Spacer(minLength: 0)
            connectButton
        }
    }

    /// `Return` submits from any field: `.defaultAction` is declared on the button rather than on
    /// the form, so the menu bar can mirror it later without a second source of truth (§9.1).
    private var connectButton: some View {
        VButton("Connect", style: .primary, size: .lg, isLoading: state.isConnecting) {
            submit()
        }
        .disabled(!state.canSubmit)
        .keyboardShortcut(.defaultAction)
    }

    /// The failure card. The animation lives on the **container** so that the card's `.transition`
    /// has a transaction to run in when `diagnosis` becomes non-nil.
    private var diagnosisSection: some View {
        VStack(spacing: 0) {
            if let diagnosis = state.diagnosis {
                ConnectDiagnosisCard(diagnosis: diagnosis) { handle($0) }
                    .padding(.top, VTheme.Space.lg)
                    .transition(.opacity)
            }
        }
        .animation(VTheme.Motion.resolved(VTheme.Motion.standard, reduced: reduceMotion),
                   value: state.diagnosis)
    }

    // MARK: - Behaviour

    private func validation(for field: ConnectField) -> VFieldValidation {
        let problem: ConnectFieldProblem?
        switch field {
        case .host: problem = state.hostProblem
        case .username: problem = state.usernameProblem
        case .password: problem = state.passwordProblem
        }
        guard let problem else { return .idle }
        return .invalid(problem.message)
    }

    private func submit() {
        guard !state.isConnecting else { return }
        guard state.validateAll() else {
            focus = firstInvalidField()
            return
        }
        state.clearDiagnosis()
        state.isConnecting = true
        onConnect(state.request)
    }

    private func firstInvalidField() -> ConnectField? {
        if state.hostProblem != nil { return .host }
        if state.usernameProblem != nil { return .username }
        if state.passwordProblem != nil { return .password }
        return nil
    }

    /// Handles the two cursor-moving remedies here, where the focus state lives, and forwards
    /// every remedy to the app.
    private func handle(_ remedy: ConnectRemedy) {
        switch remedy {
        case .checkAddress:
            focus = .host
        case .updatePassword:
            focus = .password
        case .retry:
            submit()
        case .activateCamera, .tryAlternateRTSPPort, .switchToTCP, .useONVIF,
             .openCameraWebPage, .runStreamDoctor:
            break
        }
        onRemedy(remedy)
    }

    /// The reduced-motion form of the error shake: a 300 ms `danger` border pulse and no offset
    /// (§7.4 #45, RM column).
    private func pulseBorderIfMotionReduced() async {
        guard reduceMotion, state.failureCount > 0 else { return }
        pulsesFailureBorder = true
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        pulsesFailureBorder = false
    }
}

// MARK: - ConnectShake

/// §7.4 #45's error shake: `offset(x:)` through 0 → −6 → 5 → −3 → 1.5 → 0 over 380 ms.
///
/// A one-shot `KeyframeAnimator`, which is what §7.3 specifies for multi-track one-shot
/// choreography. ⛔ Never for a loop: it rebuilds its timeline on every `trigger` change and would
/// leak CPU if the trigger were a live value. `failureCount` changes once per failed attempt.
///
/// From the SwiftUI headers (macOS 14.0+):
///
///     init(initialValue: Value, trigger: some Equatable,
///          @ViewBuilder content: @escaping (Value) -> Content,
///          @KeyframesBuilder<Value> keyframes: @escaping (Value) -> Keyframes)
///     init(_ to: Value, duration: TimeInterval)   // CubicKeyframe
@MainActor
package struct ConnectShake: ViewModifier {

    /// Changing this fires one shake.
    package let trigger: Int

    /// `false` under reduced motion, where the caller pulses a border instead.
    package let isEnabled: Bool

    @ViewBuilder
    package func body(content: Content) -> some View {
        if isEnabled {
            KeyframeAnimator(initialValue: CGFloat.zero, trigger: trigger) { offset in
                content.offset(x: offset)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(-6, duration: 0.08)
                    CubicKeyframe(5, duration: 0.09)
                    CubicKeyframe(-3, duration: 0.08)
                    CubicKeyframe(1.5, duration: 0.07)
                    CubicKeyframe(0, duration: 0.08)
                }
            }
        } else {
            content
        }
    }
}

// MARK: - Previews

#if DEBUG

/// Preview host: `@State` cannot live directly in a `#Preview` body on the macOS 14 SDK.
@MainActor
private struct ConnectFormPreview: View {
    @State private var state: ConnectFormState

    init(diagnosis: ConnectDiagnosis? = nil, isConnecting: Bool = false) {
        var initial = ConnectFormState()
        initial.host = "192.168.1.64"
        initial.password = diagnosis == nil ? "" : "a-password"
        initial.isConnecting = isConnecting
        initial.diagnosis = diagnosis
        initial.failureCount = diagnosis == nil ? 0 : 1
        self._state = State(initialValue: initial)
    }

    var body: some View {
        ConnectFormView(state: $state, onConnect: { _ in })
            .frame(width: 900, height: 700)
    }
}

#Preview("Connect — empty") {
    ConnectFormPreview()
}

#Preview("Connect — wrong password") {
    ConnectFormPreview(diagnosis: .wrongPassword(host: "192.168.1.64"))
}

#Preview("Connect — connecting") {
    ConnectFormPreview(isConnecting: true)
}
#endif

#endif  // os(macOS)
