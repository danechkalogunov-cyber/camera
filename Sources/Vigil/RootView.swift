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
                            onRemedy: { session.perform($0) })
        case .live:
            liveVideo
        }
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
    private static let pendingCameraID = CameraID()
}

#endif  // os(macOS)
