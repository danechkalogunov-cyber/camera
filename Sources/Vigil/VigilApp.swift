//
//  VigilApp.swift
//  Vigil
//
//  The `App` type: one window, the app-level model, and the window chrome of DESIGN §11.2.
//  Deliberately carries no `@main` — `main.swift` calls `.main()` (R-41).
//  macOS-only. See docs/API_CONTRACT.md §4.12, docs/DESIGN.md §11.2 and docs/UX.md §2.1.
//

#if os(macOS)

import AppKit
import SwiftUI

import VigilProtocols
import VigilRender
import VigilUI

// MARK: - SceneID

/// Stable scene identifiers.
///
/// The slice opens exactly one of these; the other four are declared because `docs/UX.md` §2.1 and
/// `docs/API_CONTRACT.md` §4.12 fix the strings, and a scene id that changes later invalidates the
/// window frames macOS has saved under it.
public enum SceneID {

    /// The live-video window. The only scene the slice creates.
    public static let main = "main"

    /// Playback window (`WindowGroup(for: PlaybackRequest.self)`). W6.
    public static let playback = "playback"

    /// Discovery window. W6.
    public static let discovery = "discovery"

    /// Video wall, on a second display. W6.
    public static let wall = "wall"

    /// About panel. W6.
    public static let about = "about"

    /// Application preferences.
    public static let settings = "settings"
}

// MARK: - VigilApp

/// The application.
///
/// **No `@main`.** `Sources/Vigil/main.swift` is top-level code and calls `VigilApp.main()`
/// explicitly; the two cannot coexist, and the executable has to link on Linux where every line of
/// this file is preprocessed away (docs/ARCHITECTURE.md §4.2 Rule 3).
///
/// **One scene.** The manifest's seven scenes — playback, discovery, wall, about, settings and the
/// menu-bar extra — are W6. The slice ships the window that shows video and nothing else, because
/// every additional scene is another surface that has never been run.
struct VigilApp: App {

    // MARK: - Stored Properties

    /// AppKit lifecycle behaviours SwiftUI has no modifier for.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The app-level model, created once for the process.
    ///
    /// `@State` on an `App` is the documented way to own an object for the application's lifetime;
    /// the value is created in `init()` and never replaced.
    @State private var session: AppSessionModel

    /// Shared camera library. The main window and the wall must observe the same records.
    @State private var library: AppLibraryModel

    /// The main window's own state.
    ///
    /// ⚠️ Owned here rather than by `RootView`, which is where it started. The menu bar is built at
    /// this level and acts on it — layout, sidebar, inspector, cycle, palette — and a `Commands`
    /// builder cannot reach state a view owns. Moving it up is the smaller of the two changes; the
    /// other is threading a dozen closures from the window back into the app.
    @State private var window = MainWindowState()
    @AppStorage(GeneralPreferenceKey.showsMenuBarExtra) private var showsMenuBarExtra = true

    // MARK: - Initialisation

    // Explicit, though `App` is a `@MainActor` protocol and `VigilApp` therefore infers that
    // isolation for every member: the annotation is what makes it obvious that building a
    // `@MainActor` model here is legal, without the reader having to recall the inference rule.
    @MainActor
    init() {
        VideoSignposts.emit(.launch)
        // `App.init()` runs on the main actor, which is what lets a `@MainActor` model be built
        // here. Bootstrapping in the initialiser rather than in a `.task` means the Keychain read
        // that resumes the last camera starts in the same run loop turn as the first frame of UI —
        // it is the difference between R1's ten seconds starting now and starting after the window
        // has drawn.
        let dependencies = AppEnvironment.bootstrap()
        _session = State(initialValue: AppSessionModel(dependencies: dependencies))
        _library = State(initialValue: AppLibraryModel(logger: dependencies.logger))
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup("Vigil", id: SceneID.main) {
            RootView(session: session, window: window, library: library)
                .frame(minWidth: Self.minWidth, minHeight: Self.minHeight)
        }
        // docs/DESIGN.md §11.2: the toolbar merges into the title bar and no title is drawn. The
        // slice has no toolbar items yet; the style is set now so the window's metrics do not
        // change when they arrive.
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentMinSize)
        .defaultSize(width: Self.defaultWidth, height: Self.defaultHeight)
        .defaultPosition(.center)
        .commands { VigilCommands(session: session, window: window) }

        Window("Playback", id: SceneID.playback) {
            AuxiliarySceneView(title: "Playback", symbol: "play.rectangle")
        }
        Window("Discovery", id: SceneID.discovery) {
            AuxiliarySceneView(title: "Discovery", symbol: "dot.radiowaves.left.and.right")
        }
        Window("Video Wall", id: SceneID.wall) {
            VideoWallScene(session: session, library: library, window: window,
                           configuration: $window.videoWall)
        }
        Window("About Vigil", id: SceneID.about) {
            AuxiliarySceneView(title: "About Vigil", symbol: "info.circle")
        }
        Window("Settings", id: SceneID.settings) {
            GeneralSettingsView()
        }

        MenuBarExtra(isInserted: $showsMenuBarExtra) {
            MenuBarExtraContent(session: session, window: window)
        } label: {
            MenuBarExtraLabel(session: session, isRecording: window.isRecording, window: window)
        }
        .menuBarExtraStyle(.window)
    }

    // MARK: - Private Helpers

    /// The full three-column minimum required by docs/DESIGN.md §11.2.
    private static let minWidth: CGFloat = 900
    private static let minHeight: CGFloat = 600

    /// docs/DESIGN.md §11.2. `docs/UX.md` §2.1 says 1440 × 900 for the full window; the contract's
    /// R-34 gives `DESIGN.md`'s structural numbers precedence, and 1280 × 800 fits a 13-inch
    /// display's usable area without the window opening partly offscreen.
    private static let defaultWidth: CGFloat = 1280
    private static let defaultHeight: CGFloat = 800
}

private struct VideoWallScene: View {
    @Bindable var session: AppSessionModel
    @Bindable var library: AppLibraryModel
    @Bindable var window: MainWindowState
    @Binding var configuration: VVideoWallConfiguration

    @Environment(\.dismissWindow) private var dismissWindow
    @State private var page = 0
    @State private var wallStreamIDs: Set<CameraID> = []
    @State private var ownedStreamIDs: Set<CameraID> = []
    @State private var refusedCameraIDs: Set<CameraID> = []
    @State private var screenMissing = false

    private var screens: [(String, String)] {
        NSScreen.screens.enumerated().map { index, screen in
            let id = Self.screenID(screen, fallback: index)
            return (id, screen.localizedName)
        }
    }

    private var pageCount: Int {
        max(1, Int(ceil(Double(library.cameras.count) / Double(configuration.layout.tileCount))))
    }

    private var pageCameras: [Camera] {
        let safePage = min(page, pageCount - 1)
        let start = safePage * configuration.layout.tileCount
        guard start < library.cameras.count else { return [] }
        return Array(library.cameras[start..<min(library.cameras.count,
                                                  start + configuration.layout.tileCount)])
    }

    private var assignment: VStageAssignment {
        VStageAssignment(layout: configuration.layout, cameras: pageCameras.map(\.id))
    }

    private var stageCameras: [VStageCamera] { pageCameras.map(stageCamera) }

    private var streamTrigger: String {
        pageCameras.map { $0.id.rawValue.uuidString }.joined(separator: ",")
    }

    private var mainVisibleIDs: Set<CameraID> {
        var ids = Set(library.cameras.prefix(window.layout.tileCount).map(\.id))
        if let bound = session.camera?.id { ids.insert(bound) }
        return ids
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            VGridStageView(
                assignment: assignment,
                cameras: stageCameras,
                inset: 0,
                gutter: 0,
                canvas: .black,
                onRetry: { session.retryCamera($0) },
                onConnectCamera: { id in
                    guard let camera = library.cameras.first(where: { $0.id == id }) else { return }
                    Task { _ = await session.connectForVideoWall(camera) }
                },
                video: wallVideo)

            wallControls

            if screenMissing {
                Text("That display is gone — the wall opened on this Mac instead.", bundle: .vigilUI)
                    .padding(10)
                    .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(24)
            }
        }
        .background(VideoWallWindowInstaller(screenID: configuration.screenID,
                                             automaticExternal: !screenMissing))
        .onExitCommand { dismissWindow(id: SceneID.wall) }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification)) { _ in
                guard let selected = configuration.screenID,
                      !screens.contains(where: { $0.0 == selected }) else { return }
                configuration.screenID = nil
                screenMissing = true
            }
        .task {
            if let selected = configuration.screenID,
               !screens.contains(where: { $0.0 == selected }) {
                configuration.screenID = nil
                screenMissing = true
            }
            await library.load(importingLegacyFrom: session.defaults)
        }
        .task(id: streamTrigger) { await synchronizeWallStreams() }
        .task(id: "\(configuration.isPatrolling)-\(configuration.patrolInterval)-\(pageCount)") {
            guard configuration.isPatrolling, pageCount > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(configuration.patrolInterval))
                guard !Task.isCancelled else { return }
                page = (page + 1) % pageCount
            }
        }
        .onChange(of: configuration.layout) { _, _ in page = 0 }
        .onChange(of: library.cameras.count) { _, _ in page = min(page, pageCount - 1) }
        .onDisappear { releaseWallStreams() }
        .frame(minWidth: 640, minHeight: 360)
    }

    private var wallControls: some View {
        HStack(spacing: 10) {
            Picker(selection: Binding(
                get: { configuration.screenID },
                set: { configuration.screenID = $0; screenMissing = false })) {
                Text("Automatic", bundle: .vigilUI).tag(String?.none)
                ForEach(screens, id: \.0) { screen in Text(screen.1).tag(Optional(screen.0)) }
            } label: {
                Text("Display", bundle: .vigilUI)
            }
            .frame(maxWidth: 180)

            Picker(selection: $configuration.layout) {
                ForEach(VGridLayout.allCases) { layout in Text(layout.rawValue).tag(layout) }
            } label: {
                Text("Layout", bundle: .vigilUI)
            }
            .frame(maxWidth: 100)

            Toggle(isOn: $configuration.isPatrolling) {
                Text("Patrol", bundle: .vigilUI)
            }
                .toggleStyle(.switch)

            if pageCount > 1 {
                Button { page = (page - 1 + pageCount) % pageCount } label: {
                    Image(systemName: "chevron.left")
                }
                Text("\(page + 1)/\(pageCount)").monospacedDigit()
                Button { page = (page + 1) % pageCount } label: {
                    Image(systemName: "chevron.right")
                }
            }

            if !refusedCameraIDs.isEmpty {
                Label {
                    Text("Decode limit", bundle: .vigilUI)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                    .foregroundStyle(.yellow)
            }

            Button {
                dismissWindow(id: SceneID.wall)
            } label: {
                Label {
                    Text("Exit (Esc)", bundle: .vigilUI)
                } icon: {
                    Image(systemName: "xmark")
                }
            }
        }
        .controlSize(.small)
        .padding(8)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 9))
        .foregroundStyle(.white)
        .padding(12)
    }

    private func stageCamera(_ camera: Camera) -> VStageCamera {
        let stream = session.cameras.stream(for: camera.id)
        return VStageCamera(
            camera: LiveCameraIdentity(id: camera.id.rawValue, name: camera.displayName,
                                       host: camera.host,
                                       identityIndex: camera.colorTag.paletteIndex),
            state: stream?.liveState ?? .offline(OfflineDetail()),
            attemptStartedAt: stream?.attemptStartedAt,
            isStreaming: stream?.isActive == true)
    }

    private func wallVideo(_ id: CameraID) -> VideoTile {
        let stream = session.cameras.stream(for: id) ?? session.live
        return VideoTile(cameraID: id, frames: stream.frames,
                         logger: session.dependencies.logger,
                         onKeyframeNeeded: { session.recoverStalledPicture(on: stream) },
                         onDecodeFailure: { session.handleDecodeFailure($0, on: stream) },
                         onFramesDropped: {
                             session.handleFramesDropped($0, reason: $1, on: stream)
                         })
    }

    private func synchronizeWallStreams() async {
        let current = Set(pageCameras.map(\.id))
        let departed = wallStreamIDs.subtracting(current)
        session.releaseVideoWall(departed)
        for id in departed where ownedStreamIDs.contains(id) && !mainVisibleIDs.contains(id) {
            session.disconnect(id)
            ownedStreamIDs.remove(id)
        }

        refusedCameraIDs.removeAll()
        for camera in pageCameras {
            let wasActive = session.cameras.stream(for: camera.id)?.isActive == true
            if await session.connectForVideoWall(camera) {
                if !wasActive { ownedStreamIDs.insert(camera.id) }
            } else {
                refusedCameraIDs.insert(camera.id)
            }
        }
        wallStreamIDs = current
    }

    private func releaseWallStreams() {
        session.releaseVideoWall(wallStreamIDs)
        for id in ownedStreamIDs where !mainVisibleIDs.contains(id) { session.disconnect(id) }
        wallStreamIDs.removeAll()
        ownedStreamIDs.removeAll()
    }

    fileprivate static func screenID(_ screen: NSScreen, fallback: Int) -> String {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            .map(String.init(describing:)) ?? "screen-\(fallback)"
    }
}

/// Applies the AppKit-only full-screen placement and display-sleep policy to the SwiftUI window.
private struct VideoWallWindowInstaller: NSViewRepresentable {
    let screenID: String?
    let automaticExternal: Bool

    final class Coordinator {
        weak var window: NSWindow?
        var originalStyle: NSWindow.StyleMask?
        var originalFrame: NSRect?
        var originalPresentation: NSApplication.PresentationOptions?
        var activity: NSObjectProtocol?
        var isWallMode = false

        @MainActor
        func install(from view: NSView, screenID: String?, automaticExternal: Bool) {
            guard let window = view.window else {
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.install(from: view, screenID: screenID,
                                 automaticExternal: automaticExternal)
                }
                return
            }
            self.window = window
            if originalStyle == nil {
                originalStyle = window.styleMask
                originalFrame = window.frame
                originalPresentation = NSApp.presentationOptions
            }
            let indexed = NSScreen.screens.enumerated().map { index, screen in
                (VideoWallScene.screenID(screen, fallback: index), screen)
            }
            let explicit = screenID.flatMap { id in indexed.first { $0.0 == id }?.1 }
            let mainScreen = NSScreen.main
            let automatic = automaticExternal ? indexed.map(\.1).first { screen in
                mainScreen.map { screen !== $0 } ?? true
            } : nil
            guard let target = explicit ?? automatic else {
                if isWallMode { restore(normalWindow: true) }
                return
            }

            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
                    reason: "Video Wall")
            }
            window.styleMask = [.borderless]
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.titleVisibility = .hidden
            window.isMovable = false
            window.setFrame(target.frame, display: true)
            NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
            isWallMode = true
        }

        @MainActor
        func restore(normalWindow: Bool = false) {
            if let activity {
                ProcessInfo.processInfo.endActivity(activity)
                self.activity = nil
            }
            if let originalPresentation { NSApp.presentationOptions = originalPresentation }
            guard normalWindow, let window else { return }
            isWallMode = false
            if let originalStyle { window.styleMask = originalStyle }
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.titleVisibility = .visible
            window.isMovable = true
            if let originalFrame { window.setFrame(originalFrame, display: true) }
            window.center()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(from: view, screenID: screenID,
                                    automaticExternal: automaticExternal)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.install(from: view, screenID: screenID,
                                    automaticExternal: automaticExternal)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.restore()
    }
}

private struct AuxiliarySceneView: View {
    let title: LocalizedStringKey
    let symbol: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 36))
            Text(title).font(.title2.weight(.semibold))
            Text("This workspace is available in its own window.", bundle: .vigilUI)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 420, minHeight: 260)
        .padding(32)
    }
}

#endif  // os(macOS)
