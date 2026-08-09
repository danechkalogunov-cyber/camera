//
//  MainWindowState.swift
//  Vigil
//
//  The main window's own state — what is shown, not what is streaming. Chrome visibility, the
//  chosen layout, the search box and the inspector's tab live here; nothing about a connection does.
//  macOS-only. See docs/UX.md and docs/DESIGN.md §9.
//

#if os(macOS)

import CoreGraphics
import Foundation
import Observation
import SwiftUI

import VigilCore
import VigilProtocols
import VigilUI

// MARK: - MainWindowState

/// View state for the main window.
///
/// **Why this is separate from `AppSessionModel`.** That object owns the `StreamController` and
/// everything that can fail; this one owns nothing that can fail. Collapsing the sidebar must not be
/// able to disturb a stream, and a reconnect must not be able to move the inspector's tab, so the two
/// are not allowed to share a type. It also means every property here is safe to write from a view
/// body's callback without thinking about the actor the controller lives on.
///
@Observable
final class MainWindowState {

    /// Work requested from a surface that can outlive the main window, such as `MenuBarExtra`.
    /// The value is consumed with `initial: true` when a new main window appears, so an action is
    /// not lost merely because no window existed when the user chose it.
    enum DeferredRequest: Equatable {
        case snapshotAll, recordToggle, discover
    }

    enum KeyboardRegion: Int, CaseIterable {
        case sidebar, stage, inspector
    }

    private static let layoutKey = "Vigil.workspace.layout"
    private static let selectedCameraKey = "Vigil.workspace.selectedCamera"

    // MARK: - Chrome

    /// Whether the user wants the camera list shown. The toolbar's leading toggle writes this.
    ///
    /// ⚠️ The user's *intent*, not what is drawn — read ``showsSidebar`` for that. Keeping the two
    /// apart is what lets a narrow window put the panel away without forgetting that the user had
    /// asked for it: widen the window again and it comes back, rather than needing a second click.
    var isSidebarVisible = true

    /// Whether the user has asked for the icon rail rather than the full list — ⌥⌘L, UX.md §2.3.
    ///
    /// A second flag rather than a third case on ``isSidebarVisible``, because the two questions are
    /// independent and the user answers them separately: ⌘L is "is the list there at all", ⌥⌘L is
    /// "how wide". Folding them into one enum would make ⌘L from the rail state ambiguous — hide,
    /// or go back to full? — and would lose the rail preference across a hide/show cycle.
    ///
    /// The rail also appears *without* this, when the window is too narrow for the full list
    /// (DESIGN.md §11.2). That is why ``showsSidebarRail`` is a computed answer over both facts and
    /// nothing reads this flag directly.
    var prefersSidebarRail = false

    /// Whether the user wants the inspector shown. The toolbar's trailing toggle writes this.
    var isInspectorVisible = true

    /// The camera-list filter behind ⌥⌘F (UX.md §11.1, `Find ▸ Filter…`).
    ///
    /// ⛔ `VSidebarFilter` has been complete since the sidebar landed — five cases, an `accepts`
    /// rule per case, a documented 24-hour motion window and its own tests — and every call site in
    /// the app built `VSidebarSearch(query:)` with the default `.all`. The list could be filtered
    /// by nothing but text, and the menu item that UX.md draws was not there to say otherwise.
    var sidebarFilter: VSidebarFilter = .all

    /// Which pieces of tile chrome are drawn — ⌥N, ⌥S, ⌥T, ⌥B (UX.md §11.1).
    ///
    /// Separate from ``showsVideoOverlay``, which is the camera's own remembered "chrome on this
    /// picture at all" and is persisted with the connection. These four are a view preference about
    /// *which* parts, they apply to every tile, and they start with everything on — a window that
    /// opened with the camera names hidden would look broken rather than tidy.
    var tileOverlays: VTileOverlays = .all

    /// ⌃⌘H: keep the selected tile's controls up without the pointer (UX.md §6.2).
    ///
    /// Off by default, because chrome over every picture is the thing §6.2 spends a paragraph
    /// forbidding. On, it is the only way a keyboard-only user reaches snapshot, record, fit/fill
    /// and close — those live in the hover row, and a hover row is not a keyboard affordance.
    var pinsTileControls = false

    /// Full Keyboard Access is a system preference and may change while Vigil is running.
    var isFullKeyboardAccessEnabled = false

    /// The major window region reached by Tab/Shift-Tab when Full Keyboard Access is enabled.
    var keyboardRegion: KeyboardRegion = .stage

    /// Cinema mode leaves the video and a compact transport panel visible.
    var isCinemaMode = false

    /// The window's content width, measured once per resize.
    ///
    /// `0` means "not measured yet", which is the first frame only. Both panels are shown in that
    /// state rather than hidden: a window that opens with its chrome missing for one frame reads as
    /// a flash of breakage, and the default window is 1280 pt wide — well over both thresholds.
    var contentWidth: CGFloat = 0

    /// Whether the camera list is actually drawn.
    ///
    /// ⛔ DESIGN.md §11.2 requires this and it was missing. The window's minimum is 640 pt wide; the
    /// sidebar is 264 and the inspector 320, so at the minimum the two panels claimed 584 pt and the
    /// video was left a 56 pt strip between them. §11.2's rule — "below 900 the inspector auto-hides;
    /// below 700 wide the sidebar collapses" — exists precisely to stop that, and nothing implemented
    /// it.
    ///
    /// The rail takes over below §11.2's threshold, and now also whenever the user asks for it with
    /// ⌥⌘L — the two reasons are independent and either one is enough.
    var showsSidebar: Bool {
        guard !prefersSidebarRail else { return false }
        guard contentWidth > 0 else { return isSidebarVisible }
        return isSidebarVisible && contentWidth >= Self.sidebarMinimumWidth
    }

    /// Whether the icon rail is drawn in place of the full list.
    ///
    /// Two independent reasons, either sufficient: the user asked (⌥⌘L, UX.md §2.3), or the window
    /// is too narrow for the full list (DESIGN.md §11.2). Both are gated on the list being wanted at
    /// all, so ⌘L still puts everything away — a rail the user cannot dismiss would be a worse
    /// answer to "hide the camera list" than the hiding it replaced.
    ///
    /// ⚠️ `contentWidth > 0` guards only the *narrow-window* reason. The first frame has no
    /// measurement, and treating "not measured yet" as narrow would open every window with the rail
    /// up for one frame; an explicit preference has no such excuse and applies immediately.
    var showsSidebarRail: Bool {
        guard isSidebarVisible else { return false }
        if prefersSidebarRail { return true }
        return contentWidth > 0 && contentWidth < Self.sidebarMinimumWidth
    }

    /// Whether the inspector is actually drawn. See ``showsSidebar``.
    var showsInspector: Bool {
        guard contentWidth > 0 else { return isInspectorVisible }
        return isInspectorVisible && contentWidth >= Self.inspectorMinimumWidth
    }

    /// Below this the inspector auto-hides (DESIGN.md §11.2).
    static let inspectorMinimumWidth: CGFloat = 900

    /// Below this the camera list goes too (DESIGN.md §11.2).
    static let sidebarMinimumWidth: CGFloat = 700

    // MARK: - Stage

    /// The tile arrangement.
    ///
    /// `.single` while the slice drives one camera: every other case would draw empty cells for
    /// cameras that cannot exist yet, which reads as breakage rather than as capacity. The switcher
    /// still offers them, because the assignment and geometry types behind it are complete and this
    /// is the cheapest way to exercise them against a real window.
    var layout: VGridLayout = .single {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: Self.layoutKey) }
    }

    /// The layout ⌘F replaced, or `nil` when no tile is soloed.
    ///
    /// ⛔ SOLO IS A ROUND TRIP OR IT IS A TRAP. UX.md §5.8 says exit restores what was there —
    /// `Esc`, ⌘F or a double-click, "reverse transition". Without somewhere to put the previous
    /// layout, ⌘F is a one-way switch to `.single` and the user's 2 × 2 is gone for good: they have
    /// to remember which of eight arrangements they were in and pick it again, having pressed a key
    /// that promised a zoom.
    ///
    /// `nil` is the whole of the "not soloed" state, so the two facts cannot disagree.
    private(set) var layoutBeforeSolo: VGridLayout?

    /// Whether one tile is currently filling the stage.
    var isSoloed: Bool { layoutBeforeSolo != nil }

    /// Fills the stage with the selected tile, or puts the previous layout back.
    ///
    /// Idempotent in both directions and safe to call when already in `.single`: soloing from
    /// `.single` records `.single` and restores it, which does nothing visible — the right outcome
    /// for a key the user may press twice.
    func toggleSolo() {
        if let previous = layoutBeforeSolo {
            layoutBeforeSolo = nil
            layout = previous
            return
        }
        layoutBeforeSolo = layout
        layout = .single
    }

    /// Applies a layout the user picked by name — and that is also what leaves solo behind.
    ///
    /// ⚠️ Every user-facing layout change goes through here, so that the memory ⌘F keeps cannot go
    /// stale. Soloing from 2 × 2 and then picking 4 × 4 from the toolbar leaves nothing to restore:
    /// the user has chosen a layout, so ⌘F must offer to solo *that*, not to snap back to an
    /// arrangement they have since replaced.
    func chooseLayout(_ next: VGridLayout) {
        layoutBeforeSolo = nil
        layout = next
    }

    /// Leaves solo without toggling into it. What `Esc` is bound to.
    func exitSolo() {
        guard let previous = layoutBeforeSolo else { return }
        layoutBeforeSolo = nil
        layout = previous
    }

    /// The stage cell keyboard focus is on, or `nil` before the stage has been used.
    ///
    /// ⛔ The stage has always *had* this — `VGridStageView.focusedIndex` and the whole ⌥-arrow
    /// navigator in `GridNavigation.swift` were written and tested against it — and the window never
    /// supplied one. Held at `nil` forever, the focus ring never drew, `⌫` and `⏎` acted on
    /// `plan.firstIndex` whatever the user had arrowed to, and every ⌥-arrow took the "focus becomes
    /// visible" branch and then had nowhere to put it. UX.md §5.7 is explicit that focus is always
    /// visible once the stage has been used; this is the value that makes it so.
    var stageFocusIndex: Int?

    /// How far the stage is displaced by a bump, and in which direction.
    ///
    /// ⌥-arrow at the edge of the grid does not wrap (UX.md §5.7 gives the reason: an operator
    /// scanning a row expects it to stop). What it does instead is a 3 pt nudge, and this is it.
    ///
    /// ⚠️ An **offset**, deliberately, and not a change to any tile's frame. DESIGN.md §7.9 forbids
    /// animating a video well's geometry because a bounds change re-allocates the layer's IOSurface
    /// every display frame; a translation is a compositor transform and does neither. It is also why
    /// the nudge is applied to the stage as a whole rather than to the tile that could not move.
    var stageBumpOffset: CGSize = .zero

    /// Free-text filter over the camera list, bound to the toolbar's search field.
    var searchText = ""

    /// Bumped to put the cursor in the toolbar's search field.
    ///
    /// A counter and not a `Bool`, because the request is an *event*: pressing `/` twice has to move
    /// focus twice, and a flag that is already `true` the second time would not. The value itself
    /// means nothing — `VToolbarView` watches it for a change.
    var focusSearchRequests = 0

    /// Bumped to take the cursor *out* of the search field.
    ///
    /// ⛔ Clicking the picture has to end a search, and until this existed nothing could make it.
    /// macOS keeps a text field first responder until something else claims it, and nothing on the
    /// stage is focusable — so after typing a filter the only way to get the caret out was to click
    /// a sidebar row, which also selected a camera. An AppKit `makeFirstResponder(nil)` was tried
    /// first and is the wrong tool: SwiftUI owns this focus, and the two disagree about who has it.
    var blurSearchRequests = 0

    // MARK: - Menu requests

    /// Counters the menu bar bumps and the window acts on.
    ///
    /// ⛔ WHY A COUNTER AND NOT A CLOSURE. `VigilCommands` is built by `VigilApp`, above the window,
    /// and the four actions below live on `MainWindowView` — they need its `snapshots`, `recording`
    /// and `archive` coordinators, which are `@State` on the view and cannot be reached from a
    /// `Commands` builder. Handing the menu a closure would mean hoisting those coordinators to the
    /// app, which is a much larger change than a menu deserves and would make them outlive the
    /// window they belong to.
    ///
    /// The counter is the same idiom `focusSearchRequests` already uses here: the menu records that
    /// something was asked for, the window notices the change and does it. Menu items that need
    /// nothing but `session` or this state call those directly and take no counter.
    var snapshotRequests = 0

    /// See ``snapshotRequests``.
    var recordToggleRequests = 0

    /// See ``snapshotRequests``.
    var findCamerasRequests = 0

    /// See ``snapshotRequests``.
    var openRecordingsFolderRequests = 0

    /// A request that must survive the main window being closed.
    var deferredRequest: DeferredRequest?

    /// Mirrored from the window-owned event coordinator for the window-independent menu badge.
    var unreadEventCount = 0

    /// A `vigil://` link that has been parsed and not yet acted on.
    ///
    /// ⛔ Held rather than performed on arrival, and that is acceptance 5 of §F-AUT-03: "a link
    /// received while the app is not running launches it, restores state, **then** performs the
    /// action". `RootView` parses the URL the moment macOS delivers it — which may be before there
    /// is a window at all, while the connect form is still up — and `MainWindowView` performs it
    /// when it can and clears this. A link that arrives during launch therefore waits for the
    /// camera rather than being dropped.
    ///
    /// One property rather than a counter per action, unlike the menu's requests above: a link
    /// carries a payload — an instant, a preset number, a query — so there is something to hold,
    /// and holding it is the whole mechanism.
    var pendingDeepLink: DeepLinkTarget?

    /// Whether a clip is being written, mirrored here from `RecordingCoordinator`.
    ///
    /// ⚠️ A mirror, with exactly one writer — `MainWindowView` on every change to the coordinator.
    /// The menu needs it to say *Start* or *Stop*, and it cannot read the coordinator: that lives in
    /// the view's `@State`, and `RecordingTap` — the one piece the app *can* reach — is a plain
    /// `Sendable` box behind a lock, not `@Observable`, so a menu title read from it would never
    /// update. Duplicated state is a smell; a menu that says "Start Recording" while recording is a
    /// worse one.
    var isRecording = false

    /// Sidebar focus and selection.
    var sidebarSelection = VSidebarSelectionState() {
        didSet {
            if case .camera(let id) = sidebarSelection.focus {
                UserDefaults.standard.set(id.rawValue.uuidString, forKey: Self.selectedCameraKey)
            }
        }
    }

    /// Rows the user has collapsed, by row id.
    var collapsedRows: Set<String> = []

    // MARK: - Inspector

    /// The visible inspector tab.
    ///
    /// `.stream` rather than `.info`, because the question a single-camera build is actually asked is
    /// "is the picture healthy", and that is the Stream tab. `docs/UX.md` picks `.info` for a
    /// populated library, which is the right default once there is more than one camera to identify.
    var inspectorTab: VInspectorTab = .stream

    // MARK: - Palette and menus

    /// Whether the ⌘K command palette is up.
    var isPaletteOpen = false

    /// The palette's query. Cleared on open, not on close, so a mistyped query is still there to
    /// correct rather than retyped from scratch.
    var paletteQuery = ""

    /// The palette's highlighted command id, or `nil` before the first result exists.
    var paletteSelection: String?

    /// Whether the overflow menu is up.
    var isOverflowMenuOpen = false

    /// Where the toolbar's "…" button is, in the window's own coordinate space.
    ///
    /// Reported by `VToolbarView` through `VToolbarAnchorKey` and read by the overlay that draws the
    /// menu. Measured rather than derived: the menu used to be placed by adding up the toolbar's
    /// padding tokens, which was both wrong and fragile — every change to that row's contents would
    /// have moved the panel again.
    var overflowAnchor: CGRect = .zero

    /// Where the toolbar's search field is, in the same space.
    ///
    /// The one exception to "a click anywhere dismisses the caret": a click *on* the field is how
    /// the caret gets there. See `MainWindowView.dismissTransientChrome(at:)`.
    var searchFieldAnchor: CGRect = .zero

    // MARK: - Cycle

    /// Automatic page advance. A value type — every mutator returns a new one — so the window's
    /// timer can only ever replace it, never mutate it half-way through a render.
    var cycle = VCycleModel()

    /// Named layouts are encoded alongside the workspace by the library owner.
    var layoutPresets = VLayoutPresetCollection()

    /// File ▸ Export Diagnostics is app-scene state, while the evidence lives in MainWindowView.
    /// The monotonically increasing request bridges those two owners without a global singleton.
    var exportDiagnosticsRequests: UInt64 = 0

    /// Custom 12×12 mosaic edit state; non-nil while the eight resize handles are active.
    var mosaicEditor: VMosaicEditor?

    /// Renderer-independent zoom transform for the selected live tile.
    var digitalViewport = VDigitalViewport()

    /// The second-display workspace is intentionally independent from the main stage.
    var videoWall = VVideoWallConfiguration()

    // MARK: - Library

    /// Clips found in the recordings folder, newest-first ordering applied by the screen.
    var clips: [VLibraryClip] = []

    /// Poster frames already extracted, by file URL. Cached so re-reading the folder or scrolling
    /// the list never decodes the same frame twice.
    var posters: [URL: CGImage] = [:]

    /// Clip durations already read, by file URL. Same reason.
    var durations: [URL: Double] = [:]

    // MARK: - Sheets

    /// Which modal sheet is up, or `nil` for none.
    ///
    /// One property rather than a `Bool` per sheet: two `Bool`s can both be true, and SwiftUI's
    /// answer to that is to present one and silently drop the other. An enumeration makes "two
    /// sheets at once" unrepresentable instead of merely unlikely.
    var sheet: MainWindowSheet?

    /// Parsed CSV rows waiting for explicit review. Kept separate from the sheet enum because the
    /// rows are editable state, not presentation identity.
    var csvImportPreview: CameraCSVImporter.Preview?

    /// Whether the archive scrubber is laid over the bottom of the stage.
    ///
    /// Opening a camera is a layout change — `.single` with the inspector away — and this is the
    /// separate question of whether that camera's recordings are being reviewed. They are separate
    /// because looking closely at a live picture and scrubbing yesterday are different intents, and
    /// one gesture should not commit the user to the other.
    var showsTimeline = false

    /// Bumped every time the user asks for the timeline, including when it is already open.
    ///
    /// ⛔ `showsTimeline` is a flag and "show me the timeline" is an **event**. Once the flag was
    /// true, asking again set it true again — no change, nothing observed, nothing on screen if the
    /// panel had since hidden itself. Every entry point bumps this, and the overlay re-pins on any
    /// change.
    var timelineRevealRequests = 0

    /// Whether the picture fills its tile rather than fitting inside it.
    ///
    /// Fitting is the default and stays it: surveillance video is evidence, and cropping the top
    /// and bottom of a 16:9 frame to fill a 4:3 cell throws away the part of the scene that is
    /// usually the reason the camera is pointed there. Filling is offered because a user watching
    /// one camera on one screen often prefers no letterbox.
    var fillsTile = false

    /// Whether the chrome drawn over the picture is shown.
    ///
    /// Mirrored here from the stored preference rather than read from `UserDefaults` in a body: the
    /// stage re-evaluates on every state change the stream produces, and a synchronous defaults
    /// lookup on that path is file-backed work nobody asked for.
    var showsVideoOverlay = true

    /// Whether the user has already been told why there is no archive scrubber.
    ///
    /// One explanation per window, not one per visit to the Recordings screen: the answer is a fact
    /// about the camera and does not change between two clicks.
    var hasExplainedArchive = false

    // MARK: - Transient

    /// The most recent advisory to show over the stage, or `nil` when there is nothing to say.
    ///
    /// Held here rather than in the session model because a toast is a piece of window furniture: it
    /// outlives the event that raised it, it is dismissed by the user, and dismissing it must not
    /// change anything about the stream it describes.
    var toast: MainWindowToast?

    // MARK: - Initialisation

    /// Builds the window state and restores the last layout and selected camera.
    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.layoutKey),
           let restored = VGridLayout(rawValue: raw) {
            layout = restored
        }
        if let raw = UserDefaults.standard.string(forKey: Self.selectedCameraKey),
           let uuid = UUID(uuidString: raw) {
            sidebarSelection.select(.camera(CameraID(uuid)))
        }
    }
}

// MARK: - MainWindowSheet

/// The modal sheets the main window can put up.
///
/// Carries the subject with the case, so a sheet cannot be presented for a camera that has since
/// been deselected — the alternative is a second `@State` holding the subject, which goes stale
/// exactly when the sheet is dismissed and re-presented quickly.
enum MainWindowSheet: Identifiable, Hashable {

    /// Basic settings for one camera: its name, and what it belongs to.
    case cameraSettings

    // ⛔ There is deliberately no `clipPlayer` case. One was added and removed: playing a recording
    // belongs to `VRecordingsView`, which mounts `VClipPlayerView` inline above its scrubber, and a
    // sheet doing the same thing meant a click played the clip twice — once in the screen and once
    // in a small window on top of it. See `MainWindowView+Library.swift`'s note on `onPlayClip`.

    /// Naming a new group.
    case newGroup

    /// Renaming an existing one.
    case renameGroup(GroupID)

    /// Marking a moment, with a title and a note.
    ///
    /// Carries the instant rather than reading "now" when the sheet saves. The two differ whenever
    /// the timeline is up: marking what you are looking at on the scrubber and marking the moment
    /// you happened to press Save are different acts, and only the first is useful.
    case newBookmark(Date)

    /// Editing a bookmark that already exists.
    case editBookmark(UUID)

    /// The keyboard cheat sheet — ⌘/, UX.md §11.1.
    case shortcuts

    /// Editable, per-row camera import review.
    case csvImport

    /// Distinguishes one presentation from the next, which is what `sheet(item:)` keys on.
    var id: String {
        switch self {
        case .cameraSettings:           return "cameraSettings"
        case .newGroup:                 return "newGroup"
        case .renameGroup(let group):   return "renameGroup.\(group)"
        case .newBookmark(let instant): return "newBookmark.\(instant.timeIntervalSince1970)"
        case .editBookmark(let mark):   return "editBookmark.\(mark)"
        case .shortcuts:                return "shortcuts"
        case .csvImport:                return "csvImport"
        }
    }
}

// MARK: - MainWindowToast

/// An advisory shown over the stage, with the one action it offers.
///
/// `kind` chooses the semantic colour and the dwell policy through `VToastPolicy.resolved(for:…)`;
/// the view layer owns both, so this type carries only what the window decides.
///
/// **Not `Sendable`, deliberately.** It holds a `LocalizedStringKey`, which SwiftUI does not declare
/// `Sendable`, so the conformance does not compile. Dropping it costs nothing: this value is created
/// in a view callback, stored in `MainWindowState` and read in a view body — all on the main actor,
/// never across an isolation boundary. Reaching for `@unchecked Sendable` to keep a conformance
/// nothing needs would be asserting a guarantee in exchange for no benefit.
struct MainWindowToast: Identifiable {

    /// Distinguishes one advisory from the next so SwiftUI animates a replacement rather than
    /// mutating the visible one in place.
    let id = UUID()

    /// Severity, which selects the colour and the auto-dismiss policy.
    let kind: VToastKind

    /// The sentence shown to the user. Already localised by the caller.
    let message: String

    /// Title for the inline action button, or `nil` for an advisory with nothing to do.
    ///
    /// `LocalizedStringKey` rather than a `String`, because that is what `VToastView` takes and a
    /// conversion here would strip the localisation the view is about to perform.
    let actionTitle: LocalizedStringKey?

    /// What the action button performs.
    ///
    /// Plain rather than `@Sendable`: the toast is main-actor-only, and requiring `@Sendable` here
    /// would stop a caller closing over the window state the action almost always needs to touch.
    let action: (() -> Void)?

    /// Builds an advisory.
    ///
    /// - Parameters:
    ///   - kind: severity; drives colour and dwell.
    ///   - message: the localised sentence to show.
    ///   - actionTitle: label for the inline action, or `nil` for no action.
    ///   - action: what the inline action does. Ignored when `actionTitle` is `nil`.
    init(kind: VToastKind,
         message: String,
         actionTitle: LocalizedStringKey? = nil,
         action: (() -> Void)? = nil) {
        self.kind = kind
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }
}

#endif  // os(macOS)
