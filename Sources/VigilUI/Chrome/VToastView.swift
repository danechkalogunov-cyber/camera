//
//  VToastView.swift
//  VigilUI
//
//  The floating toast: a semantic edge bar, a glyph, one or two lines of copy, an inline action and
//  a close button — on E2 glass, with the dwell timer that hovering pauses.
//  macOS-only. Implements docs/DESIGN.md §9.17 (anatomy, variants, dwell), §6.5 (the glass recipe,
//  applied through `vElevation(.e2,…)`), §7.4 #18–19 (entrance and exit), §7.10 (reduced motion),
//  §2.3 (why a toast is glass and a tile chip is not) and docs/UX.md §16.1.
//

#if os(macOS)

import SwiftUI

// MARK: - VToastMetrics

/// `VToastView`'s own geometry, from §9.17's anatomy line.
///
/// A separate namespace for the reason `VTextFieldMetrics` gives: these are one component's
/// internals rather than tokens shared across the app. Everything the token layer already names —
/// the 320 pt width, the 20 pt window inset, the 8 pt stack gap, `radius.xl`, the E2 level, the
/// spacing ladder — comes from `VTheme` and is not restated.
///
/// `@MainActor` to match `VTheme`'s own geometry namespaces, so a value derived from a token can be
/// added here later without the namespace having to change isolation.
@MainActor
package enum VToastMetrics {

    /// 44 pt. §9.17's minimum card height; the card grows for a second line.
    package static let minHeight: CGFloat = 44

    /// 10 pt between the glyph and the text column (§9.17's anatomy line).
    package static let iconGap: CGFloat = 10

    /// 3 pt. The leading semantic edge bar.
    package static let edgeBarWidth: CGFloat = 3

    /// 1.5 pt. The edge bar's radius.
    package static let edgeBarRadius: CGFloat = 1.5

    /// The entrance offset of §7.4 #18: the card rises 24 pt into place.
    package static let entryOffset: CGFloat = 24

    /// The entrance scale of §7.4 #18.
    package static let entryScale: CGFloat = 0.96

    /// The exit slide of §7.4 #19: the card leaves 12 pt to the trailing edge as it fades.
    package static let exitOffset: CGFloat = 12

    /// At most three lines of message in the 320 pt card, so one long sentence cannot grow a toast
    /// into a panel.
    package static let messageLineLimit: Int = 3
}

// MARK: - VToastView

/// One toast.
///
/// ## Glass, over video, on purpose
///
/// §2.3 bans a material on anything that sits *on a tile* — `NSVisualEffectView` samples the
/// window's backing store and `AVSampleBufferDisplayLayer` composites above it, so a material over
/// a picture frosts the empty canvas behind it. A toast is not tile chrome: it is a detached
/// window-level surface, and §2.3's own table puts toasts in the `.hudWindow` + §6.5 row alongside
/// popovers and the palette, which §9.17 restates as "E2 glass". So this passes
/// ``VTheme/Backdrop/chrome`` explicitly rather than forwarding `\.vOnVideo` — the flag belongs to
/// the tile subtree, and a toast is never inside one.
///
/// `vElevation(.e2,…)` is what applies §6.5: the `.hudWindow` material, the 28 % tint that stops
/// the glass going white over a bright frame, the 8 % inner highlight, the hairline edge and the
/// two stacked shadows. Under `reduceTransparency` — and under `increaseContrast` — ``VGlass``
/// resolves the whole thing to the solid `layer.overlay` with no highlight, so nothing here has to
/// branch on it.
///
/// ## Placement is the window's job
///
/// The toast does not position itself. §9.17 stacks toasts bottom-trailing at a 20 pt window inset;
/// the approved mockup floats a single one bottom-centre over the stage. Both are the same card, so
/// the owner places it and — for the mockup's single-line banner — passes `width: nil` to let it
/// size to its content instead of taking the fixed 320 pt.
///
/// ## Timing
///
/// The dwell rules live in ``VToastPolicy`` and are unit-tested; this view only applies them. It
/// accumulates the time it has actually spent counting down, so hovering **pauses** the timer as
/// §9.17 requires rather than restarting it — a reader who moves the pointer onto a toast twice does
/// not get an extra eight seconds.
@MainActor
package struct VToastView: View {

    // MARK: - Stored Properties

    /// Which variant, which sets the glyph, the tint, the dwell and the announcement priority.
    package let kind: VToastKind

    /// The `Headline` first line, or `nil` for a single-line banner.
    ///
    /// A `Text` rather than a `LocalizedStringKey` so the caller can hand over a camera name with
    /// `Text(verbatim:)` and a sentence with `Text(_:bundle:)` — the two cases §9.17 mixes on one
    /// line — without this view guessing which it received.
    package let title: Text?

    /// The `Caption1` message. Set in `text.primary` when there is no title, because then it is the
    /// toast's only line and demoting it to secondary would make the whole card recede.
    package let message: Text

    /// The inline action's label, or `nil` for a toast with nothing to do. Its presence is what
    /// lengthens the dwell from 4 s to 6 s (§9.17).
    package let actionTitle: LocalizedStringKey?

    /// The card's width. `VTheme.Metrics.toastWidth` 320 pt by default; `nil` hugs the content.
    package let width: CGFloat?

    /// Performs the inline action.
    package let onAction: () -> Void

    /// Removes the toast. Called by the close button and by the dwell timer.
    ///
    /// The view never removes itself: the owner holds the queue, and letting a card delete its own
    /// model is how a stack ends up out of step with what is on screen. Animate the removal with
    /// ``removalTransition(reduced:)``.
    package let onDismiss: () -> Void

    @Environment(\.vMotionEnabled) private var motionEnabled

    @State private var isPresented = false
    @State private var isHovering = false
    @State private var elapsed: Duration = .zero
    @State private var countdownStartedAt: Date?

    // MARK: - Initialisation

    /// Creates a toast.
    ///
    /// - Parameters:
    ///   - kind: the variant. `.error` never auto-dismisses, whatever the other arguments say.
    ///   - title: the first line, or `nil` for a single-line banner.
    ///   - message: the body.
    ///   - actionTitle: the inline action's label, if the app can offer one.
    ///   - width: `nil` to size to the content, for a banner that must not wrap.
    ///   - onAction: performed when the inline action is chosen.
    ///   - onDismiss: performed when the dwell expires or the close button is pressed.
    package init(kind: VToastKind,
                 title: Text? = nil,
                 message: Text,
                 actionTitle: LocalizedStringKey? = nil,
                 width: CGFloat? = VTheme.Metrics.toastWidth,
                 onAction: @escaping () -> Void = {},
                 onDismiss: @escaping () -> Void = {}) {
        self.kind = kind
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.width = width
        self.onAction = onAction
        self.onDismiss = onDismiss
    }

    // MARK: - Policy

    /// The dwell and priority this toast resolves to.
    package var policy: VToastPolicy {
        VToastPolicy.resolved(for: kind, hasAction: actionTitle != nil)
    }

    /// §7.4 #19's exit, for the owner to attach where it removes the toast from its stack.
    ///
    /// Under reduced motion the slide is dropped and only the opacity remains, which is §7.10
    /// rule 2. Pass `!vMotionEnabled`.
    package static func removalTransition(reduced: Bool) -> AnyTransition {
        reduced
            ? AnyTransition.opacity
            : AnyTransition.opacity.combined(with: .offset(x: VToastMetrics.exitOffset))
    }

    // MARK: - View

    package var body: some View {
        HStack(spacing: 0) {
            icon
            textColumn
            Spacer(minLength: VTheme.Space.sm)
            actionButton
            closeButton
        }
        .frame(width: width)
        .frame(minHeight: VToastMetrics.minHeight)
        .vElevation(VTheme.Elevation.e2, radius: VTheme.Radius.xl, over: .chrome)
        .overlay(alignment: .leading) { edgeBar }
        .opacity(isPresented ? 1 : 0)
        .scaleEffect(isPresented ? 1 : restingScale)
        .offset(y: isPresented ? 0 : restingOffset)
        .onHover { isHovering = $0 }
        .onAppear { present() }
        .onChange(of: isHovering) { _, hovering in pauseCountdown(hovering) }
        .task(id: isHovering) { await runCountdown() }
        .accessibilityElement(children: .contain)
        // §9.17: a toast is an announcement, not a control, even though it contains two.
        .accessibilityAddTraits(.isStaticText)
    }

    // MARK: - Parts

    /// `[16][icon 15 pt][10]` — §9.17's leading run.
    private var icon: some View {
        kind.image
            .symbolRenderingMode(.monochrome)
            .vIcon(size: VTheme.Icon.lg, weight: VTheme.Icon.Weight.lg)
            .foregroundStyle(kind.tint)
            .accessibilityHidden(true)
            .padding(.leading, VTheme.Space.lg)
            .padding(.trailing, VToastMetrics.iconGap)
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: VTheme.Space.hair) {
            if let title {
                title
                    .vType(VTheme.Typography.headline)
                    .foregroundStyle(VTheme.Color.Text.primary)
                    .lineLimit(1)
            }
            message
                .vType(VTheme.Typography.caption1)
                .foregroundStyle(messageInk)
                .lineLimit(messageLineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actionButton: some View {
        if let actionTitle {
            VButton(actionTitle, style: .ghost, size: .sm, action: onAction)
        }
    }

    /// `[8][xmark 11 pt][12]` — §9.17's trailing run.
    ///
    /// §9.17 reveals the close button on hover. It is faded rather than removed so the card does not
    /// change width under the pointer, and it stays visible for a toast that has no dwell at all: an
    /// `.error` must be dismissed by hand, and a keyboard user never hovers.
    private var closeButton: some View {
        Button(action: onDismiss) {
            VTheme.Symbol.close.image()
                .vIcon(size: VTheme.Icon.xs, weight: VTheme.Symbol.close.weight)
                .foregroundStyle(VTheme.Color.Text.tertiary)
                .frame(width: VTheme.Metrics.minHitTarget, height: VTheme.Metrics.minHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Dismiss", bundle: .vigilUI))
        .opacity(showsCloseButton ? 1 : 0)
        .allowsHitTesting(showsCloseButton)
        .padding(.leading, VTheme.Space.sm)
        .padding(.trailing, VTheme.Space.md)
        .animation(VTheme.Motion.resolved(VTheme.Motion.micro, reduced: !motionEnabled),
                   value: showsCloseButton)
    }

    /// The 3 pt semantic bar down the leading edge, inset 8 pt top and bottom (§9.17).
    private var edgeBar: some View {
        VTheme.Radius.shape(VToastMetrics.edgeBarRadius)
            .fill(kind.tint)
            .frame(width: VToastMetrics.edgeBarWidth)
            .padding(.vertical, VTheme.Space.sm)
            .padding(.leading, VTheme.Space.sm)
            .allowsHitTesting(false)
    }

    // MARK: - Appearance

    private var messageInk: SwiftUI.Color {
        title == nil ? VTheme.Color.Text.primary : VTheme.Color.Text.secondary
    }

    /// A banner that hugs its content must not wrap; a 320 pt card may take three lines.
    private var messageLineLimit: Int {
        width == nil ? 1 : VToastMetrics.messageLineLimit
    }

    private var showsCloseButton: Bool {
        isHovering || !policy.dismissesAutomatically
    }

    /// §7.4 #18's entrance is `offset` + `scale` + `opacity`; its reduced-motion fallback is
    /// opacity **only**, so under reduced motion the card starts at its resting geometry and merely
    /// fades in (§7.10 rule 2).
    private var restingOffset: CGFloat {
        motionEnabled ? VToastMetrics.entryOffset : 0
    }

    /// See ``restingOffset``.
    private var restingScale: CGFloat {
        motionEnabled ? VToastMetrics.entryScale : 1
    }

    // MARK: - Timing

    /// Runs the entrance on the `emphasized` 280 ms curve §7.4 #18 names.
    ///
    /// §7.3 prefers a `KeyframeAnimator` where several properties move on different timelines. All
    /// three of this entrance's tracks share one 280 ms curve, so one animated state flag reaches
    /// the same picture with one driver and no keyframe timeline to re-create.
    private func present() {
        withAnimation(VTheme.Motion.resolved(VTheme.Motion.emphasized, reduced: !motionEnabled)) {
            isPresented = true
        }
    }

    /// Counts the dwell down, then hands the toast back to its owner.
    ///
    /// Driven by `.task(id: isHovering)`, so moving the pointer onto the card cancels the sleep and
    /// moving it off starts a fresh one for whatever time is left. An indefinite policy — every
    /// `.error` — returns immediately and no timer ever exists.
    private func runCountdown() async {
        guard !isHovering, let remaining = policy.remaining(after: elapsed) else { return }
        countdownStartedAt = Date.now
        if remaining > .zero {
            try? await Task.sleep(for: remaining)
        }
        guard !Task.isCancelled else { return }
        countdownStartedAt = nil
        onDismiss()
    }

    /// Banks the time already counted down when the pointer arrives, which is what makes hovering a
    /// pause rather than a restart (§9.17).
    private func pauseCountdown(_ hovering: Bool) {
        guard hovering, let startedAt = countdownStartedAt else { return }
        elapsed += Duration.seconds(Date.now.timeIntervalSince(startedAt))
        countdownStartedAt = nil
    }
}

// MARK: - Previews

#if DEBUG
#Preview("VToastView — warning") {
    // The approved mockup's stage banner: one line, sized to its content, with one inline action.
    // The camera name is verbatim and the measured figure is verbatim; only the sentence around
    // them is translated, which is what keeps a name out of a localisation key (UX.md §14.2).
    VStack(spacing: VTheme.Space.md) {
        VToastView(kind: .warning,
                   title: Text(verbatim: "Side Gate"),
                   message: Text("Switched to TCP for stability.", bundle: .vigilUI),
                   actionTitle: "Run Stream Doctor",
                   width: nil)
        VToastView(kind: .warning,
                   message: Text("Switched to TCP for stability.", bundle: .vigilUI),
                   actionTitle: "Run Stream Doctor",
                   width: nil)
    }
    .padding(VTheme.Space.xl)
    .background(VTheme.Color.Layer.videoWell)
}

#Preview("VToastView — error") {
    VStack(spacing: VTheme.Space.md) {
        VToastView(kind: .error,
                   title: Text("Recording stopped — disk is full.", bundle: .vigilUI),
                   message: Text(verbatim: "Less than 2 GB is free on Macintosh HD."),
                   actionTitle: "Manage Recordings")
        VToastView(kind: .error,
                   title: Text("Recording stopped — disk is full.", bundle: .vigilUI),
                   message: Text(verbatim: "Less than 2 GB is free on Macintosh HD."))
    }
    .padding(VTheme.Space.xl)
    .background(VTheme.Color.Layer.canvas)
}
#endif

#endif  // os(macOS)
