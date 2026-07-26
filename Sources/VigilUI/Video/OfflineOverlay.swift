//
//  OfflineOverlay.swift
//  VigilUI
//
//  The card shown over a held last frame when there is no picture: what happened, when we will
//  try again, and what the user can do now.
//  macOS-only. Implements docs/UX.md §12.6, §12.7, DESIGN.md §9.13 (offline row) and §2.3.
//

#if os(macOS)

import Foundation

import SwiftUI

// MARK: - OfflineOverlay

/// The offline / reconnecting / sign-in-failed overlay.
///
/// This is the **one** place a full-tile scrim is legal (DESIGN.md §2.3): `Scrim.strong` at α 0.82
/// over the last known frame, which is also how the frame is dimmed. ⛔ The dimming is never an
/// `.opacity()` on the video layer — fading a live layer is forbidden, and a sibling scrim is the
/// sanctioned way to do it (§3.6 rule 6).
///
/// The tile is never blank and never removed, however long this lasts (UX.md §12.6).
@MainActor
package struct OfflineOverlay: View {

    /// Cards and empty states are centred and capped at 380 pt, so that a wide window does not
    /// stretch one sentence across it (DESIGN.md §9.18).
    package static let cardMaxWidth: CGFloat = 380

    /// The camera, for the accessibility label.
    package let camera: LiveCameraIdentity

    /// Why there is no picture and when we try again.
    package let detail: OfflineDetail

    /// Retries immediately, cancelling the wait.
    package let onRetryNow: () -> Void

    /// Performs a remedy from the diagnosis, when there is one.
    package let onRemedy: (ConnectRemedy) -> Void

    /// Creates the overlay.
    package init(camera: LiveCameraIdentity,
                 detail: OfflineDetail,
                 onRetryNow: @escaping () -> Void,
                 onRemedy: @escaping (ConnectRemedy) -> Void) {
        self.camera = camera
        self.detail = detail
        self.onRetryNow = onRetryNow
        self.onRemedy = onRemedy
    }

    // MARK: - View

    package var body: some View {
        ZStack {
            VTheme.Color.Scrim.strong
            card
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Card

    private var card: some View {
        VStack(spacing: VTheme.Space.xs) {
            glyph
            title
                .vType(VTheme.Typography.headline)
                .foregroundStyle(VTheme.Color.Text.primary)
                .multilineTextAlignment(.center)
            subtitle
                .vType(VTheme.Typography.caption1Numeric)
                .foregroundStyle(VTheme.Color.Text.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions
                .padding(.top, VTheme.Space.xxs)
            if let lastSeen = detail.lastSeen {
                lastSeenLine(lastSeen)
            }
        }
        .padding(VTheme.Space.lg)
        .frame(maxWidth: Self.cardMaxWidth)
    }

    private var glyph: some View {
        (detail.diagnosis?.symbol ?? VTheme.Symbol.cameraOffline).image()
            .symbolRenderingMode((detail.diagnosis?.symbol ?? VTheme.Symbol.cameraOffline).rendering)
            .vIcon(size: VTheme.Icon.hero, weight: VTheme.Icon.Weight.hero)
            .foregroundStyle(detail.diagnosis?.tint ?? VTheme.Color.Text.tertiary)
            .accessibilityHidden(true)
    }

    private var title: Text {
        if let diagnosis = detail.diagnosis {
            return diagnosis.title
        }
        if detail.isPersistent {
            return Text("Still can't reach this camera.", bundle: .vigilUI)
        }
        return Text("Connection lost.", bundle: .vigilUI)
    }

    /// The countdown, or the diagnosis's own sentence.
    ///
    /// ⛔ Whole seconds at 1 Hz, never a spinner: "Reconnecting in 4 s (attempt 3)" answers the
    /// question a spinner refuses to (UX.md §12.6). The line is `monospacedDigit` so the digits do
    /// not jitter as they count down (§4.4).
    private var subtitle: Text {
        if let diagnosis = detail.diagnosis {
            return diagnosis.message
        }
        guard let seconds = detail.retryInSeconds else {
            return Text("Waiting for the network.", bundle: .vigilUI)
        }
        // The unit is inside the key rather than produced by `Measurement`: its `.abbreviated` width
        // spells seconds `sec` and its `.narrow` width drops the space, and UX.md §12.6 specifies
        // "Reconnecting in 4 s (attempt 3)." One key with both arguments, so a translator can
        // reorder the whole sentence — which a `Measurement` interpolated into it could not be
        // (§14.2, "Never concatenate").
        return Text("Reconnecting in \(seconds) s (attempt \(detail.attempt)).", bundle: .vigilUI)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: VTheme.Space.sm) {
            if let diagnosis = detail.diagnosis {
                ForEach(diagnosis.remedies, id: \.self) { remedy in
                    VButton(remedy.title, style: .ghost, size: .sm) {
                        onRemedy(remedy)
                    }
                }
            } else {
                VButton("Retry Now", style: .ghost, size: .sm) {
                    onRetryNow()
                }
                VButton(ConnectRemedy.runStreamDoctor.title, style: .ghost, size: .sm) {
                    onRemedy(.runStreamDoctor)
                }
            }
        }
    }

    /// "Last seen 10:14" — relative under an hour, absolute after, always through
    /// `Date.FormatStyle` so it follows the user's locale and 12/24-hour preference
    /// (UX.md §14.1 rule 12).
    private func lastSeenLine(_ lastSeen: Date) -> some View {
        let elapsed = Date.now.timeIntervalSince(lastSeen)
        let oneHour: TimeInterval = 3600
        let stamp = elapsed < oneHour
            ? lastSeen.formatted(.relative(presentation: .named))
            : lastSeen.formatted(date: .omitted, time: .shortened)
        return Text("Last seen \(stamp)", bundle: .vigilUI)
            .vType(VTheme.Typography.caption2)
            .foregroundStyle(VTheme.Color.Text.tertiary)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("OfflineOverlay — reconnecting") {
    OfflineOverlay(camera: LiveCameraIdentity(id: UUID(), name: "Front Door",
                                              host: "192.168.1.64"),
                   detail: OfflineDetail(attempt: 3,
                                         retryInSeconds: 4,
                                         lastSeen: Date.now.addingTimeInterval(-90)),
                   onRetryNow: {},
                   onRemedy: { _ in })
        .frame(width: 720, height: 405)
        .background(VTheme.Color.Layer.videoWell)
        .vOnVideo()
}

#Preview("OfflineOverlay — wrong password") {
    OfflineOverlay(camera: LiveCameraIdentity(id: UUID(), name: "Front Door",
                                              host: "192.168.1.64"),
                   detail: OfflineDetail(attempt: 1,
                                         diagnosis: .wrongPassword(host: "192.168.1.64")),
                   onRetryNow: {},
                   onRemedy: { _ in })
        .frame(width: 720, height: 405)
        .background(VTheme.Color.Layer.videoWell)
        .vOnVideo()
}
#endif

#endif  // os(macOS)
