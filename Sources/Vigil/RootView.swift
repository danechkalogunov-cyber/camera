//
//  RootView.swift
//  Vigil
//
//  The window's content: the connect form, then live video. The one place the app names a
//  `VigilUI` screen or a `VigilRender` surface.
//  macOS-only. See docs/API_CONTRACT.md §4.12, .vigil/STEP3.md §3.5–§3.6 and REQUIREMENTS §R1.
//

#if os(macOS)

import SwiftUI

import VigilCore
import VigilProtocols
import VigilRender
import VigilUI

// MARK: - RootView

/// Two screens and nothing between them.
///
/// The whole R1 flow is here: a form that asks for an address and a password, and a video surface
/// that narrates its own progress. There is no wizard, no discovery list, no channel picker and no
/// transport choice, because every one of those is a question R1 forbids us to ask.
///
/// **Why the screens come from `VigilUI` and the state lives above them.** `VigilUI` cannot see the
/// app target, so its views take values and closures; the object that owns the `StreamController`
/// has to live here. `LiveVideoView` goes further and takes the picture itself as a `ViewBuilder`,
/// so that `VigilRender`'s display layer is injected at the app layer and the screen stays
/// previewable — which is why this file is where `VideoTile` is named.
struct RootView: View {

    // MARK: - Stored Properties

    /// The app-level model. `@Bindable` because `ConnectFormView` writes back into `form`.
    @Bindable var session: AppSessionModel

    /// The window's own state: which panels are shown, the layout, the search box.
    ///
    /// Created here rather than injected because it is per-window and has no dependencies. It
    /// outlives a reconnect, which is the point — losing the sidebar every time a camera blinks
    /// would be worse than not having one.
    @State private var window = MainWindowState()

    /// The network scan, created only when the user asks for one.
    ///
    /// `nil` until then, and set back to `nil` on dismissal, so the sockets and the coordinator are
    /// released with the sheet rather than living for the window's lifetime. A scan is a burst of
    /// several hundred connect attempts; nothing about it should outlive its own sheet.
    @State private var scan: DiscoveryScanModel?

    // MARK: - Body

    var body: some View {
        ZStack {
            // The window's own background is `layer.canvas` too (`WindowChrome`), so a live resize
            // never shows white behind either screen.
            VTheme.Color.Layer.canvas
                .ignoresSafeArea()

            content
        }
        .background(WindowChromeInstaller())
        .task {
            // One attempt, at window appearance: if a previous run reached a picture, this goes
            // straight back to video with nothing typed (R1.4).
            session.resumeOrPrompt()
        }
    }

    // MARK: - Private Helpers

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .connect:
            ConnectFormView(state: $session.form,
                            onConnect: { session.connect($0) },
                            onRemedy: { session.perform($0) },
                            onScan: { beginScan() })
                .sheet(item: $scan) { model in
                    discoverySheet(model)
                }
        case .live:
            // The full window — toolbar, camera list, stage, inspector, status bar — around the
            // same tile `liveVideo` mounts. To fall back to the bare picture, substitute
            // `liveVideo` here; that property is kept for exactly that reason, and because it is
            // still the honest minimum if the chrome turns out to cost frames.
            MainWindowView(session: session, window: window)
        }
    }

    // MARK: - Discovery

    /// Opens the scan sheet and starts a run.
    ///
    /// The model is built here rather than held for the window's lifetime, so a user who never
    /// presses *Find Cameras* never constructs a coordinator, never reads the code signature and
    /// never opens a socket.
    private func beginScan() {
        // The one camera this slice holds, so its row says "Added" instead of offering a duplicate.
        // A multi-camera library will pass its whole address set here; the sheet already takes one.
        let known = Set([session.camera?.host].compactMap { $0 }.filter { !$0.isEmpty })
        let model = DiscoveryScanModel(logger: session.dependencies.logger, knownAddresses: known)
        scan = model
        model.start()
    }

    /// The scan sheet, bound to one run.
    private func discoverySheet(_ model: DiscoveryScanModel) -> some View {
        VDiscoverySheet(cameras: model.cameras,
                        progress: model.progress,
                        phase: model.phase,
                        isScanning: model.isScanning,
                        notice: model.notice,
                        onChoose: { chose($0, from: model) },
                        onToggleScan: { model.toggle() },
                        onClose: { endScan(model) })
    }

    /// A device was picked: put its address in the form and leave the password to the user.
    ///
    /// ⛔ It does **not** connect. Discovery never authenticates — that rule is the whole shape of
    /// `VigilDiscovery`, which has no credential parameter anywhere in it — and a scan result is a
    /// suggestion about an address, not a claim that Vigil may log in. The user still types the
    /// password, which is also the only way they learn that this camera needs one.
    private func chose(_ camera: VDiscoveredCamera, from model: DiscoveryScanModel) {
        session.form.host = camera.address
        session.form.validate(.host)
        endScan(model)
    }

    /// Dismisses the sheet and releases the run.
    private func endScan(_ model: DiscoveryScanModel) {
        model.stop()
        scan = nil
    }

    /// The video screen, with the renderer injected.
    ///
    /// The tile is mounted in **every** connection state, which is what lets the offline overlay dim
    /// a held last frame instead of fading the layer — the black-flash rule (DESIGN.md §3.6 rule 6).
    /// `frames` is the app's single `FrameStreamHandle`: `VideoTile.makeNSView` attaches the view it
    /// creates to it, so the decode pipeline never learns that SwiftUI rebuilt anything.
    private var liveVideo: some View {
        LiveVideoView(camera: identity,
                      state: session.liveState,
                      attemptStartedAt: session.attemptStartedAt,
                      onRetry: { session.perform(.retry) },
                      onRemedy: { session.perform($0) },
                      video: {
                          // Every callback is passed, and the logger with them. Each one defaults to
                          // something that compiles and says nothing: `logger` to `NullLogger`, so a
                          // tile built without it reports its layer lifecycle into a void, and both
                          // report closures to `nil`, so a decode failure or a drop storm would
                          // reach neither the screen nor the log. That is the "no video, no error"
                          // shape this project is built to refuse, and the fix is naming them here.
                          VideoTile(cameraID: cameraID,
                                    frames: session.frames,
                                    logger: session.dependencies.logger,
                                    onKeyframeNeeded: { session.recoverStalledPicture() },
                                    onDecodeFailure: { session.handleDecodeFailure($0) },
                                    onFramesDropped: { session.handleFramesDropped($0, reason: $1) })
                      })
    }

    /// Name, address and identity colour for the chip over the video.
    private var identity: LiveCameraIdentity {
        let camera = session.camera
        return LiveCameraIdentity(id: cameraID.rawValue,
                                  name: camera?.displayName ?? session.form.request.host,
                                  host: camera?.host ?? session.form.request.host)
    }

    /// The camera's identifier, or a stable placeholder for the moment between pressing Return and
    /// the record existing. `VideoTile` uses it only for its identity colour and its log lines.
    private var cameraID: CameraID {
        session.camera?.id ?? Self.pendingCameraID
    }

    /// One placeholder id for the life of the process, so the tile does not change identity — and
    /// therefore does not get rebuilt — between the connect press and the camera record.
    ///
    /// Not `private`: `MainWindowView` derives the same identity for the stage tile, and two
    /// placeholders would make the tile change identity when the window chrome appeared.
    static let pendingCameraID = CameraID()
}

#endif  // os(macOS)
