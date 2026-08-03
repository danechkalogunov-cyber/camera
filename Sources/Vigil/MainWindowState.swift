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
/// Persistence is deliberately absent for now: the slice restores a *connection*
/// (`AppSessionModel.resumeOrPrompt()`), not a workspace. Layout and chrome restoration belongs with
/// the layout store in `VigilCore`, which the single-camera slice does not yet drive.
@Observable
final class MainWindowState {

    // MARK: - Chrome

    /// Whether the user wants the camera list shown. The toolbar's leading toggle writes this.
    ///
    /// ⚠️ The user's *intent*, not what is drawn — read ``showsSidebar`` for that. Keeping the two
    /// apart is what lets a narrow window put the panel away without forgetting that the user had
    /// asked for it: widen the window again and it comes back, rather than needing a second click.
    var isSidebarVisible = true

    /// Whether the user wants the inspector shown. The toolbar's trailing toggle writes this.
    var isInspectorVisible = true

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
    /// ⚠️ §11.2 says the sidebar *collapses to the rail*, and there is no rail: `VSidebarView` has no
    /// icon-only mode. Hiding it is the honest approximation until that mode exists — it loses the
    /// camera list at 640 pt, where the alternative was losing the picture.
    var showsSidebar: Bool {
        guard contentWidth > 0 else { return isSidebarVisible }
        return isSidebarVisible && contentWidth >= Self.sidebarMinimumWidth
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
    var layout: VGridLayout = .single

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
    var sidebarSelection = VSidebarSelectionState()

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

    // MARK: - Cycle

    /// Automatic page advance. A value type — every mutator returns a new one — so the window's
    /// timer can only ever replace it, never mutate it half-way through a render.
    var cycle = VCycleModel()

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

    /// Whether the archive scrubber is laid over the bottom of the stage.
    ///
    /// Opening a camera is a layout change — `.single` with the inspector away — and this is the
    /// separate question of whether that camera's recordings are being reviewed. They are separate
    /// because looking closely at a live picture and scrubbing yesterday are different intents, and
    /// one gesture should not commit the user to the other.
    var showsTimeline = false

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

    /// Builds the default window state: both panels shown, one tile, nothing searched.
    init() {}
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

    /// Distinguishes one presentation from the next, which is what `sheet(item:)` keys on.
    var id: String {
        switch self {
        case .cameraSettings:           return "cameraSettings"
        case .newGroup:                 return "newGroup"
        case .renameGroup(let group):   return "renameGroup.\(group)"
        case .newBookmark(let instant): return "newBookmark.\(instant.timeIntervalSince1970)"
        case .editBookmark(let mark):   return "editBookmark.\(mark)"
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
