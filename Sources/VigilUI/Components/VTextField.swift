//
//  VTextField.swift
//  VigilUI
//
//  The text field: an E0 well with a label above it, a reserved message row below it, and the
//  validation timing that stops the form from shouting at the user mid-word.
//  macOS-only. Implements docs/DESIGN.md §9.5, §6.1 (E0), §9.28, and UX.md §8.3.
//

#if os(macOS)

import SwiftUI

// MARK: - VFieldValidation

/// What a field currently knows about its own contents.
///
/// The field renders this; the form computes it. Copy is specific and actionable — "Port must be
/// between 1 and 65535", never "Invalid input" (DESIGN.md §9.5).
///
/// `Equatable` and nothing more, deliberately: it carries a `LocalizedStringKey`, whose `Hashable`
/// and `Sendable` conformances are not something this container can verify. `Equatable` is all
/// `.task(id:)` and `.animation(_:value:)` require, and the type never leaves the main actor —
/// the *reason* for a problem crosses actors as ``ConnectFieldProblem``, which is a plain enum.
package enum VFieldValidation: Equatable {

    /// Nothing to say. The message row is still reserved, so nothing below the field moves when
    /// this becomes ``invalid(_:)``.
    case idle

    /// A check is in flight; a small ring appears at the trailing edge.
    case validating

    /// Confirmed good. A `checkmark.circle.fill` appears and auto-hides after 2 s.
    case valid

    /// Bad, with the reason. The reason is shown below the field and read by VoiceOver.
    case invalid(LocalizedStringKey)

    /// Whether this state should paint the field's border `danger`.
    package var isInvalid: Bool {
        if case .invalid = self { return true }
        return false
    }
}

// MARK: - VFieldTrigger

/// Why a field is asking to be validated.
///
/// ⛔ Validation never runs on every keystroke: a host that is invalid until its last octet is
/// typed would flash an error four times on the way in. It runs on submit, on focus loss, and
/// 400 ms after typing stops (DESIGN.md §9.5).
package enum VFieldTrigger: Sendable, Hashable {

    /// 400 ms have passed since the last keystroke.
    case typingStopped

    /// The field lost keyboard focus.
    case focusLost

    /// The user pressed `Return` in the field.
    case submitted
}

// MARK: - VTextFieldMetrics

/// `VTextField`'s fixed geometry and timings (§9.5).
///
/// A separate, **non-generic** namespace on purpose. These began as `static let`s inside
/// `VTextField`, which does not compile: Swift does not allow static *stored* properties in a generic
/// type, and `VTextField` is generic over `FocusValue`. The error is invisible on Linux, where this
/// whole file preprocesses away, so it surfaced on the first real Mac build.
///
/// Two other spellings were considered and rejected. Computed `static var`s inside the generic type
/// do compile, but they make every reference read `VTextField<Focus>.messageRowHeight` from outside,
/// which forces callers to name a generic argument that has nothing to do with a 16-point row. A
/// `VTheme` token is wrong too — these are one component's internals, not design tokens shared
/// across the app, and §9.5 owns them.
package enum VTextFieldMetrics {

    /// The reserved height of the message row beneath the field.
    ///
    /// Reserved whether occupied or not — an error appearing must not push the rest of the form down.
    package static let messageRowHeight: CGFloat = 16

    /// How long typing must have stopped before validation runs: 400 ms.
    package static let validationDebounce: Double = 0.400

    /// How long a confirmed-valid checkmark stays before it fades.
    package static let validDwell: Double = 2.0
}

// MARK: - VTextField

/// A labelled text field with inline validation.
///
/// The message row below the field is **always** 16 pt tall, occupied or not, so that an error
/// appearing cannot push the rest of the form down — the single most common layout jump in a form
/// and one UX.md §15.4 bans outright.
///
/// Focus is owned by the **form**, not by the field: a diagnosis that says "check the password"
/// has to be able to put the cursor there (UX.md §8.4), which a private `@FocusState` inside the
/// field could not do. `FocusValue` is therefore the form's own field enum.
@MainActor
package struct VTextField<FocusValue: Hashable>: View {

    // MARK: - Kind

    /// How the value is entered and set.
    package enum Kind: Sendable, Hashable {

        /// Ordinary text, set in `Body`.
        case plain

        /// A host, IP, port or URL: set in `Mono` 11 with autocorrection off, because a proportional
        /// `1` and `l` in an address are a support call waiting to happen (§9.5).
        case monospaced

        /// A password. Concealed by default, with a reveal control at the trailing edge.
        case secure
    }

    // MARK: - Stored Properties

    /// The label above the field, in `Callout` `text.secondary` at a 4 pt gap.
    package let label: LocalizedStringKey

    /// The placeholder, in `text.tertiary`. It names the shape of the value, never repeats
    /// the label.
    package let placeholder: LocalizedStringKey

    /// How the value is entered.
    package let kind: Kind

    /// The current validation state, owned by the form.
    package let validation: VFieldValidation

    /// The value.
    @Binding package var text: String

    /// The form's focus state.
    package let focus: FocusState<FocusValue?>.Binding

    /// The value ``focus`` takes while this field has the cursor.
    package let focusValue: FocusValue

    /// Called when the field wants its contents checked. See ``VFieldTrigger``.
    package let onValidate: (VFieldTrigger) -> Void

    /// Called when the user presses `Return`.
    package let onSubmit: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.vMotionEnabled) private var motionEnabled
    @State private var isHovering = false
    @State private var isRevealed = false
    @State private var showsValidTick = false

    // MARK: - Initialisation

    /// Creates a field.
    ///
    /// - Parameters:
    ///   - label: the label above the field.
    ///   - placeholder: the placeholder inside it.
    ///   - text: the bound value.
    ///   - kind: plain, monospaced or secure.
    ///   - validation: the state to render; the form owns the rules.
    ///   - focus: the form's focus state.
    ///   - focusValue: the value ``focus`` takes while this field has the cursor.
    ///   - onValidate: called on the three triggers of §9.5 — never per keystroke.
    ///   - onSubmit: called on `Return`.
    package init(_ label: LocalizedStringKey,
                 placeholder: LocalizedStringKey,
                 text: Binding<String>,
                 kind: Kind = .plain,
                 validation: VFieldValidation = .idle,
                 focus: FocusState<FocusValue?>.Binding,
                 focusValue: FocusValue,
                 onValidate: @escaping (VFieldTrigger) -> Void = { _ in },
                 onSubmit: @escaping () -> Void = {}) {
        self.label = label
        self.placeholder = placeholder
        self._text = text
        self.kind = kind
        self.validation = validation
        self.focus = focus
        self.focusValue = focusValue
        self.onValidate = onValidate
        self.onSubmit = onSubmit
    }

    // MARK: - View

    package var body: some View {
        VStack(alignment: .leading, spacing: VTheme.Space.xxs) {
            Text(label, bundle: .vigilUI)
                .vType(VTheme.Typography.callout)
                .foregroundStyle(VTheme.Color.Text.secondary)
            well
            message
        }
        .onChange(of: focus.wrappedValue) { previous, _ in
            if previous == focusValue { onValidate(.focusLost) }
        }
        .task(id: text) { await debounceValidation() }
        .task(id: validation) { await holdValidTick() }
    }

    /// Whether this field currently has the cursor.
    private var isFocused: Bool {
        focus.wrappedValue == focusValue
    }

    // MARK: - The well

    private var well: some View {
        HStack(spacing: VTheme.Space.sm) {
            field
            accessory
        }
        .padding(.horizontal, VTheme.Metrics.controlMD.horizontalPadding)
        .frame(height: VTheme.Metrics.md)
        .background(VTheme.Color.Layer.inset, in: VTheme.Radius.shape(VTheme.Radius.md))
        // E0's inverted highlight: a 1 pt top inner shadow is what makes a field read as recessed
        // rather than raised (§6.1).
        .overlay {
            VInnerHighlight(radius: VTheme.Radius.md,
                            opacity: VTheme.Elevation.e0.innerShadow,
                            fadeStop: VTheme.Elevation.e0.highlightFade,
                            inverted: true)
        }
        .overlay {
            VTheme.Radius.shape(VTheme.Radius.md)
                .strokeBorder(borderColour, lineWidth: VTheme.Border.thin)
                .allowsHitTesting(false)
        }
        .overlay { focusGlow }
        .onHover { isHovering = $0 }
        .animation(VTheme.Motion.resolved(VTheme.Motion.micro, reduced: !motionEnabled),
                   value: isHovering)
        .animation(VTheme.Motion.resolved(VTheme.Motion.micro, reduced: !motionEnabled),
                   value: isFocused)
    }

    @ViewBuilder
    private var field: some View {
        Group {
            if kind == .secure, !isRevealed {
                SecureField(text: $text, prompt: prompt) {
                    Text(label, bundle: .vigilUI)
                }
            } else {
                TextField(text: $text, prompt: prompt) {
                    Text(label, bundle: .vigilUI)
                }
            }
        }
        // The label is carried for VoiceOver and hidden visually: §9.5 draws it above the well,
        // and a second copy beside the field is what `.labelsHidden()` exists to prevent.
        .labelsHidden()
        .textFieldStyle(.plain)
        .focused(focus, equals: focusValue)
        .focusEffectDisabled()
        .vType(typeStep)
        .foregroundStyle(isEnabled ? VTheme.Color.Text.primary : VTheme.Color.Text.disabled)
        // `.tint` is what colours the insertion point and the selection on macOS (§9.5).
        .tint(VTheme.Color.Semantic.accent)
        .autocorrectionDisabled(kind != .plain)
        .onSubmit {
            onValidate(.submitted)
            onSubmit()
        }
    }

    /// The placeholder, in `text.tertiary`: it names the *shape* of the value and never repeats
    /// the label (§9.5).
    private var prompt: Text {
        Text(placeholder, bundle: .vigilUI)
            .foregroundStyle(VTheme.Color.Text.tertiary)
    }

    @ViewBuilder
    private var accessory: some View {
        switch validation {
        case .validating:
            VProgressRing(progress: nil, size: .small)
        case .valid where showsValidTick:
            VTheme.Symbol.success.image()
                .vIcon(size: VTheme.Icon.md, weight: VTheme.Icon.Weight.md)
                .foregroundStyle(VTheme.Color.Semantic.ok)
                .transition(.opacity)
        default:
            if kind == .secure {
                revealToggle
            }
        }
    }

    /// The reveal control. It is a real button with a spoken label rather than a tappable glyph,
    /// because "show the password" is an action a Voice Control user must be able to name (§10.7).
    private var revealToggle: some View {
        Button {
            isRevealed.toggle()
        } label: {
            VTheme.Symbol.revealSecret.image(alternate: isRevealed)
                .vIcon(size: VTheme.Icon.md, weight: VTheme.Icon.Weight.md)
                .foregroundStyle(VTheme.Color.Text.tertiary)
                .frame(width: VTheme.Metrics.minHitTarget, height: VTheme.Metrics.minHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRevealed
            ? Text("Hide password", bundle: .vigilUI)
            : Text("Show password", bundle: .vigilUI))
    }

    // MARK: - The message row

    /// Always present, always 16 pt: the row is reserved so that an error appearing cannot move
    /// anything below it (§9.5).
    private var message: some View {
        HStack(spacing: VTheme.Icon.Gap.xs) {
            if case .invalid(let reason) = validation {
                VTheme.Symbol.warning.image()
                    .vIcon(size: VTheme.Icon.xs, weight: VTheme.Icon.Weight.xs)
                Text(reason, bundle: .vigilUI)
                    .vType(VTheme.Typography.caption1)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(VTheme.Color.Semantic.danger)
        .frame(height: VTextFieldMetrics.messageRowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(y: validation.isInvalid ? 0 : -VTheme.Space.xxs)
        .opacity(validation.isInvalid ? 1 : 0)
        .animation(VTheme.Motion.resolved(VTheme.Motion.micro, reduced: !motionEnabled),
                   value: validation)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Private Helpers

    private var typeStep: VTheme.Typography.Step {
        kind == .monospaced ? VTheme.Typography.mono : VTheme.Typography.body
    }

    private var borderColour: SwiftUI.Color {
        if !isEnabled { return VTheme.Color.Stroke.subtle }
        if validation.isInvalid { return VTheme.Color.Semantic.danger }
        if isFocused { return VTheme.Color.Semantic.accent }
        return isHovering ? VTheme.Color.Stroke.strong : VTheme.Color.Stroke.default
    }

    /// §9.5's focused row: the 1 pt `accent` border above, plus a 2 pt `focusRing α 0.35` glow at
    /// a 3 pt outset. Softer than §9.28's ring on purpose — a field already signals focus with its
    /// caret, and a full-strength ring on every form row is visual noise.
    @ViewBuilder
    private var focusGlow: some View {
        if isFocused, !validation.isInvalid {
            VTheme.Radius.shape(VTheme.Radius.md + VFocusRing.outsetChrome)
                .strokeBorder(VTheme.Color.Semantic.focusRing.opacity(0.35),
                              lineWidth: VTheme.Border.focus)
                .padding(-VFocusRing.outsetChrome)
                .allowsHitTesting(false)
        }
    }

    /// 400 ms after the last keystroke. `.task(id: text)` restarts on every change, so a fast
    /// typist never sees the check fire (§9.5).
    private func debounceValidation() async {
        guard !text.isEmpty else { return }
        try? await Task.sleep(for: .seconds(VTextFieldMetrics.validationDebounce))
        guard !Task.isCancelled else { return }
        onValidate(.typingStopped)
    }

    /// Shows the confirmed-valid tick, then retires it after 2 s (§9.5).
    private func holdValidTick() async {
        guard validation == .valid else {
            showsValidTick = false
            return
        }
        showsValidTick = true
        try? await Task.sleep(for: .seconds(VTextFieldMetrics.validDwell))
        guard !Task.isCancelled else { return }
        showsValidTick = false
    }
}

// MARK: - Previews

#if DEBUG && !VIGIL_NO_PREVIEWS

/// A preview host. `@State` cannot live in a `#Preview` body on the macOS 14 SDK, so the states
/// are held by a small view rather than by the `@Previewable` macro, which is newer.
@MainActor
private struct VTextFieldPreview: View {
    @State private var host = "192.168.1.64"
    @State private var user = "admin"
    @State private var password = ""
    @FocusState private var focus: ConnectField?

    var body: some View {
        VStack(alignment: .leading, spacing: VTheme.Space.md) {
            VTextField("Address", placeholder: "192.168.1.64", text: $host,
                       kind: .monospaced, focus: $focus, focusValue: ConnectField.host)
            VTextField("User name", placeholder: "admin", text: $user,
                       focus: $focus, focusValue: ConnectField.username)
            VTextField("Password", placeholder: "Required", text: $password, kind: .secure,
                       validation: .invalid("Enter the camera's password."),
                       focus: $focus, focusValue: ConnectField.password)
        }
        .frame(width: 320)
        .padding(VTheme.Space.xl)
        .background(VTheme.Color.Layer.canvas)
    }
}

#Preview("VTextField") {
    VTextFieldPreview()
}
#endif

#endif  // os(macOS)
