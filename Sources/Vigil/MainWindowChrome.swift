//
//  MainWindowChrome.swift
//  Vigil
//
//  Two small value types the main window's chrome is described in: which modal sheet is up, and the
//  advisory toast shown over the stage. Split from MainWindowState.swift, which docs/API_CONTRACT.md
//  §7.2 caps at 600 lines — these are the two top-level types that trailed the state class.
//  macOS-only. See docs/UX.md §4.3 and §11.1.
//

#if os(macOS)

import Foundation
import SwiftUI

import VigilProtocols
import VigilUI

// MARK: - MainWindowSheet

/// The modal sheets the main window can put up, including their stable presentation identity.
enum MainWindowSheet: Identifiable, Hashable {

    /// Basic settings for one camera: its name, and what it belongs to.
    case cameraSettings

    /// Naming a new group.
    case newGroup

    /// Renaming an existing one.
    case renameGroup(GroupID)

    /// Marking a moment, carrying the timeline instant rather than reading `Date()` on save.
    case newBookmark(Date)

    /// Editing a bookmark that already exists.
    case editBookmark(UUID)

    /// The keyboard cheat sheet — ⌘/, UX.md §11.1.
    case shortcuts

    case csvImport

    case streamDoctor

    case saveLayoutPreset

    case manageLayoutPresets

    /// Distinguishes one presentation from the next, which is what `sheet(item:)` keys on.
    var id: String {
        switch self {
        case .cameraSettings: return "cameraSettings"
        case .newGroup: return "newGroup"
        case .renameGroup(let group): return "renameGroup.\(group)"
        case .newBookmark(let instant): return "newBookmark.\(instant.timeIntervalSince1970)"
        case .editBookmark(let mark): return "editBookmark.\(mark)"
        case .shortcuts: return "shortcuts"
        case .csvImport: return "csvImport"
        case .streamDoctor: return "streamDoctor"
        case .saveLayoutPreset: return "saveLayoutPreset"
        case .manageLayoutPresets: return "manageLayoutPresets"
        }
    }
}

// MARK: - MainWindowToast

/// A main-actor-only advisory shown over the stage, optionally with one action.
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

    init(
        kind: VToastKind,
        message: String,
        actionTitle: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }
}

#endif  // os(macOS)
