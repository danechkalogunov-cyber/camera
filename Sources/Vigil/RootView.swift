//
//  RootView.swift
//  Vigil
//
//  The window's content: the connect form, then live video. The single place in the app target
//  that names a `VigilUI` screen.
//  macOS-only. See docs/API_CONTRACT.md §4.12, .vigil/STEP3.md §3.5–§3.6 and REQUIREMENTS §R1.
//

#if os(macOS)

import SwiftUI

import VigilCore
import VigilUI

// MARK: - RootView

/// Two screens and nothing between them.
///
/// The whole R1 flow is here: a form that asks for an address and a password, and a video surface
/// that narrates its own progress. There is no wizard, no discovery list, no channel picker and no
/// transport choice, because every one of those is a question R1 forbids us to ask.
///
/// **Why the screens come from `VigilUI` and the state lives here.** `VigilUI` cannot see the app
/// target, so its views take plain values and closures; the model that owns the `StreamController`
/// has to live above them, which is this module. Keeping every reference to those two views in one
/// file is deliberate: when their signatures settle, exactly one file changes.
struct RootView: View {

    // MARK: - Stored Properties

    /// The app-level model. `@Bindable` because the form writes back into `host`, `account` and
    /// `password`.
    @Bindable var session: AppSessionModel

    // MARK: - Body

    var body: some View {
        ZStack {
            // The window's own background is `layer.canvas` too (WindowChrome), so a live resize
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
            connectForm
        case .live:
            liveVideo
        }
    }

    /// The connect form.
    ///
    /// ASSUMED SIGNATURE — `VigilUI` had not landed its screens when this was written. What this
    /// call assumes exists:
    ///
    ///     @MainActor public struct ConnectFormView: View {
    ///         public init(host: Binding<String>, account: Binding<String>,
    ///                     password: Binding<String>, isConnecting: Bool, message: String?,
    ///                     onSubmit: @escaping () -> Void)
    ///     }
    ///
    /// The bindings are what make "the password is the only thing typed" measurable: the form owns
    /// no state of its own, so nothing it collects can be lost on the way here.
    private var connectForm: some View {
        ConnectFormView(host: $session.host,
                        account: $session.account,
                        password: $session.password,
                        isConnecting: session.isConnecting,
                        message: session.failureBanner,
                        onSubmit: { session.connect() })
    }

    /// The video surface and its status line.
    ///
    /// ASSUMED SIGNATURE — as above:
    ///
    ///     @MainActor public struct LiveVideoView: View {
    ///         public init(controller: StreamController?, status: String, message: String?,
    ///                     isReceivingMedia: Bool, onDisconnect: @escaping () -> Void)
    ///     }
    ///
    /// The controller is passed rather than a frame handle because `VigilUI` is the only module
    /// that can see both `VigilCore` and `VigilRender`, so attaching the display layer to the
    /// stream belongs there (docs/API_CONTRACT.md §4.10, `FrameStreamHandle`). `controller` is
    /// optional so the view can render its own empty state during the gap between pressing Return
    /// and the actor existing — a gap of one `await`, but a real one.
    private var liveVideo: some View {
        LiveVideoView(controller: session.controller,
                      status: session.statusLine,
                      message: session.failureBanner,
                      isReceivingMedia: session.isReceivingMedia,
                      onDisconnect: { session.disconnect() })
    }
}

#endif  // os(macOS)
