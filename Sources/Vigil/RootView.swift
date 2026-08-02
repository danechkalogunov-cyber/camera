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

    /// Every camera the user has added.
    ///
    /// ⛔ Owned here and not by `MainWindowView`, which is where it started. The library is an
    /// *app* fact, not a window fact, and two things outside the main window need it: the scan, so
    /// a device already in the list is offered as "Added" rather than as a find, and the connect
    /// form, which is on screen precisely when the window is not. Built here it also loads once at
    /// launch instead of on the first frame of video.
    @State private var library: AppLibraryModel

    /// The network scan, created only when the user asks for one.
    ///
    /// `nil` until then, and set back to `nil` on dismissal, so the sockets and the coordinator are
    /// released with the sheet rather than living for the window's lifetime. A scan is a burst of
    /// several hundred connect attempts; nothing about it should outlive its own sheet.
    @State private var scan: DiscoveryScanModel?

    /// The silent scan that runs when there is no address to start from.
    ///
    /// Separate from `scan` because it is a different thing with a different lifetime: no sheet, no
    /// list, no choosing. It exists to answer one question — "what is the address?" — and it stops
    /// the moment it has an answer.
    @State private var autoScan: DiscoveryScanModel?

    /// The system's *Reduce motion* switch.
    ///
    /// ⚠️ The only half of DESIGN.md §7.10's rule that macOS offers. `\.accessibilityPrefers`
    /// `CrossFadeTransitions` is iOS, tvOS and watchOS only — SwiftUI does not declare it for macOS,
    /// and asking for it does not fail to resolve, it fails to *compile*: the key path cannot be
    /// typed, so `@Environment` falls through to its `Observable` object overload and the error
    /// arrives as "no exact matches in call to initializer". Written here because the omission looks
    /// like an oversight otherwise, and the next reader would add it back.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Initialisation

    /// Builds the root over the app's session.
    ///
    /// Explicit because ``library`` needs the session's logger, which a property initialiser cannot
    /// reach: `@State private var library = AppLibraryModel(logger: session…)` would be reading one
    /// stored property from another's default value, which Swift does not allow.
    init(session: AppSessionModel) {
        self.session = session
        _library = State(initialValue: AppLibraryModel(logger: session.dependencies.logger))
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // The window's own background is `layer.canvas` too (`WindowChrome`), so a live resize
            // never shows white behind either screen.
            VTheme.Color.Layer.canvas
                .ignoresSafeArea()

            content
        }
        // ⛔ On the `ZStack` and not on the connect form. It used to hang off `ConnectFormView`,
        // which meant the scan sheet could be presented only from the form — so *Find Cameras* was
        // unreachable the moment a picture existed, which is exactly when a user goes looking for a
        // second camera. `MainWindowView` now asks for it too, and both phases present the same
        // sheet over the same one run.
        .sheet(item: $scan) { model in discoverySheet(model) }
        // ⛔ Twenty-one views read `\.vMotionEnabled` and, until this line, exactly one published
        // it — `VInspectorView`, for its own subtree. Everywhere else the key fell back to its
        // default of `true`, so the stage's staggered entrance, the tile hover, the sidebar rows,
        // the timeline and the skeleton shimmer all animated with *Reduce motion* switched on.
        // Every one of those call sites was already written correctly, passing `!motionEnabled` to
        // `VTheme.Motion.resolved`; the value they were reading was simply never connected to the
        // system setting. Published at the root so the connect form is covered too.
        //
        // ⚠️ Not the whole of §7.10: the motion governor's T3 tier also has to be able to force
        // this off under thermal or dropped-frame pressure, and `VMotionGovernor` is unwritten. When
        // it lands it ANDs into this expression rather than replacing it.
        .vMotionEnabled(!reduceMotion)
        .background(WindowChromeInstaller())
        .task {
            // Opens `library.json` and, on a first run, adopts the camera the prototype remembered
            // — carrying its `CredentialRef` through, which is the difference between "the camera
            // still works" and "type your password again". Before the resume, so a scan started
            // moments later already knows which addresses are not finds.
            await library.load(importingLegacyFrom: session.defaults)
        }
        .task {
            // One attempt, at window appearance: if a previous run reached a picture, this goes
            // straight back to video with nothing typed (R1.4).
            session.resumeOrPrompt()
            beginAutoScanIfNoAddress()
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
        case .live:
            // The full window — toolbar, camera list, stage, inspector, status bar — around the
            // same tile `liveVideo` mounts. To fall back to the bare picture, substitute
            // `liveVideo` here; that property is kept for exactly that reason, and because it is
            // still the honest minimum if the chrome turns out to cost frames.
            MainWindowView(session: session,
                           window: window,
                           library: library,
                           onFindCameras: { beginScan() })
        }
    }

    // MARK: - Discovery

    /// Looks for a camera when there is no address to start from — the whole of R1.
    ///
    /// **Why this runs without being asked.** R1 is "launch it, type the password, see a picture",
    /// and there is no room in that sentence for choosing an address from a list. `resumeOrPrompt`
    /// has just filled the host in if a previous run reached a picture, so an empty host here means
    /// Vigil genuinely does not know where the camera is — and asking the user to tell it is the
    /// one thing the requirement forbids.
    ///
    /// It is deliberately silent. No sheet, no list, no progress: on a first launch the user is
    /// looking at a password field, and a modal appearing over it uninvited would be worse than the
    /// click it saves. If the scan finds nothing, they type an address exactly as before and never
    /// learn this happened.
    ///
    /// ⚠️ THIS IS WHAT TRIGGERS THE LOCAL NETWORK PERMISSION PROMPT, at first launch, before the
    /// user has done anything. That is correct for this app and is why `Info.plist` carries
    /// `NSLocalNetworkUsageDescription` — the sentence macOS shows in that alert is Vigil's only
    /// chance to explain itself, and it is written for exactly this moment.
    ///
    /// The run stops itself: at the first confident answer, or when the scan reaches its own
    /// deadline. Nothing here keeps a socket open waiting for a user who may never come back.
    private func beginAutoScanIfNoAddress() {
        guard session.form.host.isEmpty, autoScan == nil, scan == nil else { return }
        let model = DiscoveryScanModel(logger: session.dependencies.logger)
        model.onFirstConfidentCamera = { camera in
            // ⛔ Checked again here, not only above. Seconds pass between starting the scan and an
            // answer, and the user spends them typing. Overwriting an address somebody is halfway
            // through entering would be the single most annoying thing this feature could do.
            guard self.session.form.host.isEmpty else {
                self.endAutoScan()
                return
            }
            self.session.form.host = camera.address
            self.session.form.validate(.host)
            self.endAutoScan()
        }
        autoScan = model
        model.start()
    }

    /// Releases the silent scan, closing its sockets with it.
    private func endAutoScan() {
        autoScan?.stop()
        autoScan = nil
    }

    /// Opens the scan sheet and starts a run.
    ///
    /// The model is built here rather than held for the window's lifetime, so a user who never
    /// presses *Find Cameras* never constructs a coordinator, never reads the code signature and
    /// never opens a socket.
    private func beginScan() {
        // A silent scan may still be sweeping; two coordinators would mean two sets of sockets and
        // two floods of the same subnet. The one the user asked for wins.
        endAutoScan()
        // Every address the user already has, so those rows say "Added" instead of being offered as
        // finds. This used to be the single streaming camera, with a note that a multi-camera
        // library would pass its whole set — the library exists now, so it does. The streaming
        // camera is unioned in because it may not be filed yet: it is added on its first frame.
        var known = Set(library.cameras.map { $0.host })
        if let host = session.camera?.host { known.insert(host) }
        known = known.filter { !$0.isEmpty }
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
        // Choosing from the main window has to leave the user somewhere the password can be typed,
        // and the form is the only such place — writing the address into a form nobody can see would
        // look exactly like the sheet closing and nothing happening. The password is cleared with
        // it: the one that is in the field belongs to the camera being left, and offering it to a
        // different device is how an account gets locked out.
        if session.phase == .live {
            session.disconnect()
            session.form.password = ""
            session.form.clearDiagnosis()
        }
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
