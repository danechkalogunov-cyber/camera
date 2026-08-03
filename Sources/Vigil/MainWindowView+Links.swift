//
//  MainWindowView+Links.swift
//  Vigil
//
//  Performing a `vigil://` link the window has been handed.
//  macOS-only. Implements docs/FEATURES.md §F-AUT-03 acceptance 3–5; the grammar and its parser are
//  `VigilCore.DeepLink`, and split from MainWindowView.swift, which docs/API_CONTRACT.md §7.2 caps
//  at 600 lines.
//
//  ⛔ THE PARSER SAYS WHAT WAS ASKED FOR; THIS DECIDES WHETHER TO DO IT. Acceptance 4: a link from
//  another app may never silently start a recording or take a picture. That check needs to know
//  whether Vigil is frontmost, which is an app fact rather than a grammar one, so it lives here.
//
//  ⚠️ THE CONFIRMATION DIALOGUE IS OWED. §F-AUT-03 asks for a confirmation with an "Allow links to
//  record and capture without asking" preference; this build **refuses** instead, with a sentence
//  saying why. Refusing keeps the security property — nothing records without the user — and loses
//  only the convenience. It is written down rather than left looking finished: ЧТО-НЕ-СДЕЛАНО.md
//  carries it as an open item.
//

#if os(macOS)

import AppKit
import Foundation
import SwiftUI

import VigilCore
import VigilProtocols
import VigilUI

// MARK: - Deep links

/// ⚠️ `internal` rather than `private`, for the reason given in `MainWindowView+Library.swift`:
/// `private` reaches a type's extensions only within one file.
extension MainWindowView {

    /// Performs whatever link is waiting, and clears it.
    ///
    /// Clearing unconditionally is the point: a link that cannot be honoured must not sit in the
    /// state and fire again on the next unrelated change.
    func performPendingDeepLink() {
        guard let target = window.pendingDeepLink else { return }
        window.pendingDeepLink = nil
        switch target {
        case let .camera(reference, action, stream):
            openCamera(reference, action: action, stream: stream)
        case let .group(reference):
            openGroup(reference)
        case let .layout(name):
            guard let layout = VGridLayout(rawValue: name) else {
                unsupportedLink(MainWindowView.localized("No layout is called that."))
                return
            }
            selectLayout(layout)
        case let .palette(query):
            window.paletteQuery = query ?? ""
            window.paletteSelection = nil
            window.isPaletteOpen = true
        case let .playback(reference, instant, _):
            // The speed is parsed and not applied: a rate belongs to a session that is already
            // playing, and `openArchive` opens a new one. Applying it here would mean a second
            // reconnect a moment after the first.
            guard resolveLinkedCamera(reference) != nil else { return }
            openArchive(at: instant)
        case let .preset(reference, number):
            guard resolveLinkedCamera(reference) != nil else { return }
            ptz.goToPreset(number)
        case .snapshotAll:
            // Honest: this build streams one camera, so "all" is one, and pretending otherwise
            // would make the link mean something different from what it says.
            unsupportedLink(MainWindowView.localized("This build shows one camera at a time."))
        case .event, .settings:
            unsupportedLink(MainWindowView.localized("This build cannot open that yet."))
        }
    }

    // MARK: - Private Helpers

    /// Brings a camera up and performs the link's action on it.
    private func openCamera(_ reference: DeepLinkReference,
                            action: DeepLinkAction?,
                            stream: StreamQuality?) {
        guard let camera = resolveLinkedCamera(reference) else { return }
        if camera.id != cameraID {
            window.sidebarSelection.select(.camera(camera.id))
            Task { await session.switchTo(camera) }
        }
        guard let action else { return }
        // ⛔ Acceptance 4. `NSApp.isActive` is the whole test: a link the user clicked inside Vigil
        // is the user acting, and one that arrived from Mail while Vigil sat in the background is
        // not. Checked at the moment of the act rather than at parse time, because the app may have
        // come forward in between — which is exactly what happens when a link launches it.
        if action.needsConfirmationFromAnotherApp, !NSApp.isActive {
            unsupportedLink(MainWindowView.localized(
                "A link cannot start recording or take a snapshot while Vigil is in the background."))
            return
        }
        // Set, not toggled: `cycleStreamQuality()` flips between the two and a link names one. The
        // camera record is what the next connect reads, so writing it is the whole change.
        if let stream, session.camera?.preferredQuality != stream {
            session.camera?.preferredQuality = stream
        }
        switch action {
        case .live:
            Task { await session.returnToLive() }
        case .fullscreen:
            focusCamera(camera.id)
        case .snapshot:
            takeSnapshot()
        case .record:
            if !recording.isRecording { toggleRecording() }
        case .stop:
            if recording.isRecording { toggleRecording() }
        case .diagnose:
            window.isInspectorVisible = true
            window.inspectorTab = .info
        }
    }

    /// Selects a group by identifier or by name.
    private func openGroup(_ reference: DeepLinkReference) {
        let match: CameraGroupRecord?
        switch reference {
        case let .identifier(identifier):
            match = groups.groups.first { $0.id.rawValue == identifier }
        case let .slug(slug):
            match = groups.groups.first { DeepLink.slug($0.name) == slug }
        }
        guard let group = match else {
            unsupportedLink(MainWindowView.localized("No group is called that."))
            return
        }
        window.sidebarSelection.select(.group(group.id))
    }

    /// Finds the camera a link names.
    ///
    /// ⚠️ Ambiguity opens the palette rather than guessing — acceptance 3 says so, and it is the
    /// right instinct: two cameras called "Front Door" mean the link's author did not know which,
    /// and picking one would send the user to the wrong picture with nothing to show it was a coin
    /// toss.
    private func resolveLinkedCamera(_ reference: DeepLinkReference) -> Camera? {
        switch reference {
        case let .identifier(identifier):
            guard let camera = library.cameras.first(where: { $0.id.rawValue == identifier }) else {
                unsupportedLink(MainWindowView.localized("That camera is not in your list."))
                return nil
            }
            return camera
        case let .slug(slug):
            let matches = library.cameras.filter { DeepLink.slug($0.displayName) == slug }
            if matches.count == 1 { return matches[0] }
            window.paletteQuery = slug
            window.paletteSelection = nil
            window.isPaletteOpen = true
            return nil
        }
    }

    /// Says a link could not be honoured. Never silent — acceptance 2 forbids the no-op.
    private func unsupportedLink(_ message: String) {
        window.toast = MainWindowToast(kind: .warning, message: message)
    }
}

#endif  // os(macOS)
