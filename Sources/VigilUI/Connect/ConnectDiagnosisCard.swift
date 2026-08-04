//
//  ConnectDiagnosisCard.swift
//  VigilUI
//
//  The card that turns a failed connection into a named cause and a button that does something
//  about it. Inline, never a modal — a recoverable stream error must not interrupt the user.
//  macOS-only. Implements docs/UX.md §8.4, §12.7, §14.1 rules 10 and 11, and DESIGN.md §9.10.
//

#if os(macOS)

import SwiftUI

// MARK: - ConnectDiagnosisCard

/// Presents one ``ConnectDiagnosis``: glyph, headline, cause, remedies, and — only when the doctor
/// could not classify the failure — a `Details` disclosure holding the device's own reply.
///
/// The raw status line lives **behind** the disclosure on purpose. "DESCRIBE returned 451" is not
/// a sentence a user can act on, but it is exactly what support needs, so it is present and
/// copyable rather than absent (UX.md §14.1 rule 3, §8.4).
@MainActor
package struct ConnectDiagnosisCard: View {

    /// The failure to explain.
    package let diagnosis: ConnectDiagnosis

    /// Performed when the user chooses one of the diagnosis's remedies.
    package let onRemedy: (ConnectRemedy) -> Void

    @Environment(\.vMotionEnabled) private var motionEnabled
    @State private var showsDetails = false

    /// Creates a card.
    package init(diagnosis: ConnectDiagnosis, onRemedy: @escaping (ConnectRemedy) -> Void) {
        self.diagnosis = diagnosis
        self.onRemedy = onRemedy
    }

    // MARK: - View

    package var body: some View {
        HStack(alignment: .top, spacing: VTheme.Space.md) {
            diagnosis.symbol.image()
                .symbolRenderingMode(diagnosis.symbol.rendering)
                .vIcon(size: VTheme.Icon.lg, weight: VTheme.Icon.Weight.lg)
                .foregroundStyle(diagnosis.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: VTheme.Space.xxs) {
                diagnosis.title
                    .vType(VTheme.Typography.headline)
                    .foregroundStyle(VTheme.Color.Text.primary)
                diagnosis.message
                    .vType(VTheme.Typography.body)
                    .foregroundStyle(VTheme.Color.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if diagnosis.details != nil {
                    detailsSection
                }
                remedyRow
            }
        }
        .padding(VTheme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        // §9.10: a static content card is flat — `layer.surface` and a hairline, no shadow.
        // Shadowed cards read as objects you could pick up; this one is structure.
        .background(VTheme.Color.Layer.surface, in: VTheme.Radius.shape(VTheme.Radius.lg))
        .overlay {
            VTheme.Radius.shape(VTheme.Radius.lg)
                .strokeBorder(diagnosis.tint.opacity(0.35), lineWidth: VTheme.Border.thin)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Private Helpers

    private var remedyRow: some View {
        // Indexed by position rather than by `enumerated()`, because a key path cannot address a
        // tuple element and `id: \.element` on an `EnumeratedSequence` does not compile.
        HStack(spacing: VTheme.Space.sm) {
            ForEach(diagnosis.remedies.indices, id: \.self) { index in
                // The form's Connect button is the one primary on screen, so the first remedy is
                // `secondary` rather than `primary` (§9.1: one primary per container).
                VButton(diagnosis.remedies[index].title,
                        style: index == 0 ? .secondary : .ghost,
                        size: .sm) {
                    onRemedy(diagnosis.remedies[index])
                }
            }
        }
        .padding(.top, VTheme.Space.xxs)
    }

    @ViewBuilder
    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: VTheme.Space.xxs) {
            Button {
                withAnimation(VTheme.Motion.resolved(VTheme.Motion.standard,
                                                     reduced: !motionEnabled)) {
                    showsDetails.toggle()
                }
            } label: {
                HStack(spacing: VTheme.Icon.Gap.xs) {
                    VTheme.Symbol.disclosureCollapsed.image()
                        .vIcon(size: VTheme.Icon.xs, weight: VTheme.Icon.Weight.xs)
                        // §8.3: the disclosure chevron **rotates**, it is never swapped.
                        .rotationEffect(.degrees(showsDetails ? 90 : 0))
                    Text("Details", bundle: .vigilUI)
                        .vType(VTheme.Typography.caption1)
                }
                .foregroundStyle(VTheme.Color.Text.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(VTheme.Motion.resolved(VTheme.Motion.snap, reduced: !motionEnabled),
                       value: showsDetails)

            if showsDetails, let details = diagnosis.details {
                Text(verbatim: details)
                    .vType(VTheme.Typography.mono)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(VTheme.Space.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(VTheme.Color.Layer.inset,
                                in: VTheme.Radius.shape(VTheme.Radius.sm))
            }
        }
        .padding(.top, VTheme.Space.xxs)
    }
}

// MARK: - Previews

#if DEBUG && !VIGIL_NO_PREVIEWS
#Preview("ConnectDiagnosisCard") {
    VStack(spacing: VTheme.Space.md) {
        ConnectDiagnosisCard(diagnosis: .wrongPassword(host: "192.168.1.64")) { _ in }
        ConnectDiagnosisCard(diagnosis: .cameraNotActivated(host: "192.168.1.64")) { _ in }
        ConnectDiagnosisCard(diagnosis: .rtspPortClosed(host: "192.168.1.64",
                                                        httpPort: 80,
                                                        rtspPort: 554)) { _ in }
        ConnectDiagnosisCard(diagnosis: .undiagnosed(host: "192.168.1.64",
                                                     detail: "RTSP/1.0 451 Parameter Not "
                                                             + "Understood")) { _ in }
    }
    .frame(width: 420)
    .padding(VTheme.Space.xl)
    .background(VTheme.Color.Layer.canvas)
}
#endif

#endif  // os(macOS)
