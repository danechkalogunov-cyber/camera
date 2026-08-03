//
//  VigilApp.swift
//  Vigil
//
//  The `App` type: one window, the app-level model, and the window chrome of DESIGN §11.2.
//  Deliberately carries no `@main` — `main.swift` calls `.main()` (R-41).
//  macOS-only. See docs/API_CONTRACT.md §4.12, docs/DESIGN.md §11.2 and docs/UX.md §2.1.
//

#if os(macOS)

import SwiftUI

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

    /// The main window's own state.
    ///
    /// ⚠️ Owned here rather than by `RootView`, which is where it started. The menu bar is built at
    /// this level and acts on it — layout, sidebar, inspector, cycle, palette — and a `Commands`
    /// builder cannot reach state a view owns. Moving it up is the smaller of the two changes; the
    /// other is threading a dozen closures from the window back into the app.
    @State private var window = MainWindowState()

    // MARK: - Initialisation

    // Explicit, though `App` is a `@MainActor` protocol and `VigilApp` therefore infers that
    // isolation for every member: the annotation is what makes it obvious that building a
    // `@MainActor` model here is legal, without the reader having to recall the inference rule.
    @MainActor
    init() {
        // `App.init()` runs on the main actor, which is what lets a `@MainActor` model be built
        // here. Bootstrapping in the initialiser rather than in a `.task` means the Keychain read
        // that resumes the last camera starts in the same run loop turn as the first frame of UI —
        // it is the difference between R1's ten seconds starting now and starting after the window
        // has drawn.
        _session = State(initialValue: AppSessionModel(dependencies: AppEnvironment.bootstrap()))
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup("Vigil", id: SceneID.main) {
            RootView(session: session, window: window)
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
    }

    // MARK: - Private Helpers

    /// Below this the connect form starts clipping (docs/DESIGN.md §11.2 gives 900 × 600 for the
    /// full three-column window; the slice has neither sidebar nor inspector, so it is smaller).
    private static let minWidth: CGFloat = 640
    private static let minHeight: CGFloat = 420

    /// docs/DESIGN.md §11.2. `docs/UX.md` §2.1 says 1440 × 900 for the full window; the contract's
    /// R-34 gives `DESIGN.md`'s structural numbers precedence, and 1280 × 800 fits a 13-inch
    /// display's usable area without the window opening partly offscreen.
    private static let defaultWidth: CGFloat = 1280
    private static let defaultHeight: CGFloat = 800
}

#endif  // os(macOS)
