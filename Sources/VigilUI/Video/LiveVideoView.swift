//
//  LiveVideoView.swift
//  VigilUI
//
//  The video screen: one camera's picture filling the window on true black, with a name chip, a
//  status line, and the four connection states.
//  macOS-only. Implements docs/UX.md §12.4–§12.7, §15.1, §15.2, and DESIGN.md §3.6, §9.13, §7.9.
//

#if os(macOS)

import Foundation

import SwiftUI

// MARK: - LiveVideoView

/// One camera, filling its container.
///
/// The renderer is injected rather than imported: this view takes any `View` for the picture, so
/// `VigilRender`'s `AVSampleBufferDisplayLayer` host slots in at the app layer and the screen can
/// be previewed, reasoned about and reviewed without it.
///
/// Three rules govern everything below, and all three come from the frame being the hero (P1):
///
/// 1. **The well is `#000000` in both appearances**, always, and takes no tint, material, gradient
///    or opacity of its own (DESIGN.md §3.6).
/// 2. **The video view is never animated.** A `.transaction` strips any ambient animation an
///    ancestor might impose, because animating a video layer's geometry forces an IOSurface
///    re-allocation per frame and visibly stutters (§7.9 rule 3).
/// 3. **The picture stays mounted in every state.** Offline dims the last frame with a sibling
///    scrim rather than by fading the layer, which §3.6 rule 6 forbids outright.
@MainActor
package struct LiveVideoView<Video: View>: View {

    // MARK: - Stored Properties

    /// The camera being shown.
    package let camera: LiveCameraIdentity

    /// What to draw.
    package let state: LiveConnectionState

    /// When the current connect attempt began. Pass the value `StreamController` recorded, so the
    /// elapsed counter measures the connection and not the moment this view happened to appear.
    package let attemptStartedAt: Date?

    /// Retries now, cancelling any backoff wait.
    package let onRetry: () -> Void

    /// Performs a remedy chosen from an overlay or a banner.
    package let onRemedy: (ConnectRemedy) -> Void

    private let video: () -> Video

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether the name and status chips are drawn. Set by the app from the camera's own
    /// settings; the failure overlays deliberately ignore it.
    @Environment(\.vShowsVideoOverlay) private var showsOverlay

    @State private var showsNarration = false
    @State private var showsElapsed = false
    @State private var isSlow = false
    @State private var localStart = Date.now
    @State private var showsDegradedBanner = false
    @State private var isHovering = false

    // MARK: - Initialisation

    /// Creates the screen.
    ///
    /// - Parameters:
    ///   - camera: name, address and identity colour.
    ///   - state: what to draw.
    ///   - attemptStartedAt: when the current connect attempt began; `nil` starts the clock now.
    ///   - onRetry: retries immediately.
    ///   - onRemedy: performs a remedy from an overlay or banner.
    ///   - video: the renderer's view. It is mounted in **every** state so that the last frame is
    ///     still there to dim when the connection drops.
    package init(camera: LiveCameraIdentity,
                 state: LiveConnectionState,
                 attemptStartedAt: Date? = nil,
                 onRetry: @escaping () -> Void = {},
                 onRemedy: @escaping (ConnectRemedy) -> Void = { _ in },
                 @ViewBuilder video: @escaping () -> Video) {
        self.camera = camera
        self.state = state
        self.attemptStartedAt = attemptStartedAt
        self.onRetry = onRetry
        self.onRemedy = onRemedy
        self.video = video
    }

    // MARK: - View

    package var body: some View {
        ZStack {
            VTheme.Color.Layer.videoWell
            picture
            overlay
            chrome
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VTheme.Color.Layer.videoWell)
        // Everything inside this subtree is chrome over video: solid scrims, `Stroke.onVideo`
        // hairlines, and no materials or shadows anywhere (§2.3, §6.3).
        .vOnVideo()
        .vMotionEnabled(!reduceMotion)
        // §10.7 asks that inverted colours never reach footage — an inverted street at night is
        // unreadable. There is deliberately no code for it: `accessibilityIgnoresInvertColors` is
        // the UIKit-only opt-out (`UIView.accessibilityIgnoresInvertColors`), and AppKit has no
        // equivalent because macOS applies Invert Colors as a display-wide WindowServer filter
        // rather than per view. Nothing an app can do exempts a layer from it, so the rule is
        // unimplementable here rather than unimplemented.
        .onHover { isHovering = $0 }
        .task(id: state.isConnecting) { await runChoreography() }
        .task(id: isDegraded) { await debounceDegradedBanner() }
    }

    // MARK: - Picture

    private var picture: some View {
        video()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // ⛔ §7.9 rule 3. No ambient `withAnimation` from an ancestor may ever reach the
            // renderer's layer.
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .accessibilityHidden(true)
    }

    // MARK: - Overlays

    @ViewBuilder
    private var overlay: some View {
        Group {
            switch state {
            case .connecting(let phase):
                ConnectingOverlay(camera: camera,
                                  phase: phase,
                                  startedAt: effectiveStart,
                                  showsNarration: showsNarration,
                                  showsElapsed: showsElapsed,
                                  isSlow: isSlow,
                                  onRunDoctor: { onRemedy(.runStreamDoctor) })
            case .offline(let detail):
                OfflineOverlay(camera: camera,
                               detail: detail,
                               onRetryNow: { onRetry() },
                               onRemedy: { onRemedy($0) })
            case .live, .degraded:
                SwiftUI.Color.clear
            }
        }
        .animation(revealAnimation, value: overlayKind)
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ⛔ Outside the overlay switch. The degraded banner is the app telling the user *why*
            // a flowing picture looks wrong, and someone who hid the name chip has not asked to
            // stop being told that — hiding it would leave a bad picture with no account of itself.
            degradedBanner
            Spacer(minLength: 0)
            if showsOverlay {
                HStack(alignment: .bottom, spacing: VTheme.Space.xs) {
                    CameraNameChip(camera: camera, isHovered: isHovering)
                    ConnectionStatusChip(state: state)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(VTheme.Metrics.tileChromeInset)
    }

    @ViewBuilder
    private var degradedBanner: some View {
        if showsDegradedBanner, case .degraded(let cause) = state {
            DegradedBanner(cause: cause) { onRemedy($0) }
                .transition(.asymmetric(
                    insertion: .offset(y: DegradedBanner.entryOffset).combined(with: .opacity),
                    removal: .opacity))
                .padding(.bottom, VTheme.Space.sm)
        }
    }

    // MARK: - Choreography

    /// The connect choreography of UX.md §15.1: silence, then narration, then a number, then an
    /// admission that it is slow.
    ///
    /// `.task(id:)` cancels the whole ladder the moment the state leaves `connecting`, which is
    /// what guarantees that a connection completing at 180 ms shows no spinner and no text — the
    /// flags never get set, so there is nothing to fade out and nothing to reflow.
    private func runChoreography() async {
        guard state.isConnecting else {
            showsNarration = false
            showsElapsed = false
            isSlow = false
            return
        }
        localStart = Date.now
        showsNarration = false
        showsElapsed = false
        isSlow = false

        await sleep(until: ConnectingChoreography.narrationDelay, from: 0)
        guard !Task.isCancelled else { return }
        showsNarration = true

        await sleep(until: ConnectingChoreography.elapsedDelay,
                    from: ConnectingChoreography.narrationDelay)
        guard !Task.isCancelled else { return }
        showsElapsed = true

        await sleep(until: ConnectingChoreography.slowDelay,
                    from: ConnectingChoreography.elapsedDelay)
        guard !Task.isCancelled else { return }
        withAnimation(VTheme.Motion.resolved(VTheme.Motion.fadeIn, reduced: reduceMotion)) {
            isSlow = true
        }
    }

    /// Sleeps for the gap between two absolute thresholds. Written as a gap rather than as an
    /// absolute deadline so the three thresholds in ``ConnectingChoreography`` stay the only
    /// numbers in play.
    private func sleep(until threshold: Double, from previous: Double) async {
        let interval = threshold - previous
        guard interval > 0 else { return }
        try? await Task.sleep(for: .seconds(interval))
    }

    /// A degradation must be sustained for 1.5 s before it earns a banner; an informational
    /// "switched to TCP" retires itself after 4 s (UX.md §12.5, §7.4 #39).
    private func debounceDegradedBanner() async {
        guard case .degraded(let cause) = state else {
            showsDegradedBanner = false
            return
        }
        try? await Task.sleep(for: .seconds(VTheme.Motion.Delay.degradedDebounce))
        guard !Task.isCancelled else { return }
        withAnimation(VTheme.Motion.resolved(VTheme.Motion.emphasized, reduced: reduceMotion)) {
            showsDegradedBanner = true
        }
        guard cause.isTransient else { return }
        try? await Task.sleep(for: .seconds(VTheme.Motion.Delay.toastDwell))
        guard !Task.isCancelled else { return }
        withAnimation(VTheme.Motion.resolved(VTheme.Motion.fadeOut, reduced: reduceMotion)) {
            showsDegradedBanner = false
        }
    }

    // MARK: - Private Helpers

    private var effectiveStart: Date {
        attemptStartedAt ?? localStart
    }

    private var isDegraded: Bool {
        if case .degraded = state { return true }
        return false
    }

    /// Which overlay is on screen, as a value the reveal animation can key on. Deliberately
    /// coarser than ``LiveConnectionState``: a narration phase changing must not re-run the
    /// first-frame cross-fade.
    private enum OverlayKind: Hashable {
        case none, connecting, offline
    }

    private var overlayKind: OverlayKind {
        switch state {
        case .connecting: return .connecting
        case .offline: return .offline
        case .live, .degraded: return .none
        }
    }

    /// The first-frame handoff (UX.md §15.2).
    ///
    /// The overlay fades **out** over the picture, which is already mounted at full opacity
    /// underneath — so the video layer's own opacity is never touched (§3.6 rule 6) and the frame
    /// rect never changes, making the transition a pure cross-fade.
    ///
    /// A connection that beat the 250 ms narration threshold takes the fast 120 ms exit instead of
    /// the 240 ms cross-fade, so it looks like it was already on. Under reduced motion the handoff
    /// is a hard cut, as §15.2 step 3 specifies.
    private var revealAnimation: Animation? {
        let token = showsNarration ? VTheme.Motion.crossfade : VTheme.Motion.fadeOut
        return VTheme.Motion.resolved(token, reduced: reduceMotion, fallback: nil)
    }
}

// MARK: - Previews

#if DEBUG && !VIGIL_NO_PREVIEWS

/// A stand-in for the renderer: a still, so previews show the chrome against something that reads
/// as a frame rather than against flat black.
@MainActor
private struct PreviewPicture: View {
    var body: some View {
        LinearGradient(colors: [SwiftUI.Color(white: 0.10), SwiftUI.Color(white: 0.28)],
                       startPoint: .top,
                       endPoint: .bottom)
    }
}

private let previewCamera = LiveCameraIdentity(id: UUID(),
                                               name: "Front Door",
                                               host: "192.168.1.64")

#Preview("Live") {
    LiveVideoView(camera: previewCamera, state: .live) { PreviewPicture() }
        .frame(width: 960, height: 540)
}

#Preview("Connecting") {
    LiveVideoView(camera: previewCamera,
                  state: .connecting(.authenticating),
                  attemptStartedAt: Date.now) { PreviewPicture() }
        .frame(width: 960, height: 540)
}

#Preview("Degraded") {
    LiveVideoView(camera: previewCamera,
                  state: .degraded(.packetLoss(fraction: 0.031))) { PreviewPicture() }
        .frame(width: 960, height: 540)
}

#Preview("Offline") {
    LiveVideoView(camera: previewCamera,
                  state: .offline(OfflineDetail(attempt: 3,
                                                retryInSeconds: 4,
                                                lastSeen: Date.now.addingTimeInterval(-120)))) {
        PreviewPicture()
    }
    .frame(width: 960, height: 540)
}
#endif

#endif  // os(macOS)
