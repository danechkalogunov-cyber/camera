//
//  MainWindowView+Sidebar.swift
//  Vigil
//
//  The camera list's behaviour: selection and its modifiers, keyboard navigation, the row and
//  group context menus, and the tile HUD's actions.
//  macOS-only. Split from MainWindowView.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

#if os(macOS)

import AppKit
import Foundation
import SwiftUI

import VigilCore
import VigilProtocols
import VigilUI

// MARK: - The camera list

/// ⚠️ `internal` rather than `private`, for the reason given in `MainWindowView+Library.swift`:
/// `private` reaches a type's extensions only within one file.
extension MainWindowView {

    /// Applies a sidebar click, honouring the modifier that was held.
    ///
    /// `VSidebarSelectionState` has carried ranges, an anchor and toggling since it was written; the
    /// window discarded the modifier and always plain-selected, so ⌘-click and ⇧-click did the same
    /// thing as an ordinary click. Only camera rows take a modifier — extending a range from a
    /// library link is not a meaningful gesture, and treating it as one would clear the selection.
    func selectInSidebar(_ selection: VSidebarSelection, _ click: VSidebarClick) {
        let order = sidebarTree.visibleCameras
        switch (selection, click) {
        case (.camera(let id), .toggle):
            window.sidebarSelection.toggle(id, in: order)
        case (.camera(let id), .extend):
            window.sidebarSelection.extend(to: id, in: order)
        default:
            window.sidebarSelection.select(selection)
        }
    }

    /// Brings the scrubber up on the day an instant falls in, with the playhead on it.
    ///
    /// What "open this event" and "open this bookmark" both mean. UX.md §9.1 gives the event feed a
    /// five-second lead-in — you want to see what happened *before* the camera decided something
    /// had — and that is applied here rather than in the timeline, because the timeline's own
    /// lead-in is three seconds and the two surfaces are allowed to differ.
    func openArchive(at instant: Date) {
        let clock = libraryClock
        let lead = instant.addingTimeInterval(-Self.eventLeadInSeconds)
        focusCamera(cameraID)
        window.showsTimeline = true
        window.timelineRevealRequests += 1
        archive.load(
            day: clock.day(containing: lead),
            clock: clock,
            localClips: timelineLocalClips,
            markers: timelineMarkers)
        archive.movePlayhead(to: lead, isScrubbing: false)
        playArchive(from: lead)
    }

    /// UX.md §9.1: the event feed opens five seconds early.
    static let eventLeadInSeconds: TimeInterval = 5

    /// The moment ⌘D marks: the playhead when the scrubber is up, otherwise now.
    ///
    /// Marking "now" while looking at yesterday's footage would file the note against a moment the
    /// user never saw, and they would find it in the wrong place tomorrow.
    var markableInstant: Date {
        guard window.showsTimeline, let playhead = archive.archive?.playhead else { return Date() }
        return playhead
    }

    /// Opens a row: a double-click, or a click on the row that is already selected.
    ///
    /// For a camera that means the review surface — UX.md §4.3 calls it "open the row", and it is
    /// the gesture that means *look at this one* rather than *select this one*. Everything else
    /// simply selects, which is what activating a library link or a group already did.
    func activateInSidebar(_ selection: VSidebarSelection) {
        window.sidebarSelection.select(selection)
        guard case .camera(let id) = selection else { return }
        focusCamera(id)
        // A row that is not the camera on screen means "show me that one". Before the library
        // existed there was only ever one row, so focusing was the whole of it; now focusing a
        // different camera without connecting to it would leave the stage on the old picture with
        // the new name selected, which is the worst of both.
        guard id != cameraID, let target = library.cameras.first(where: { $0.id == id }) else {
            return
        }
        Task { await session.switchTo(target) }
    }

    /// Brings the window to one camera.
    ///
    /// **A layout change, not a different screen.** The stage already knows how to show a single
    /// camera — that is `.single` — so opening one selects it, switches the grid, and puts the
    /// inspector away to give the picture the width. The camera list stays: it is how you get to
    /// the next camera, and hiding it would make the gesture feel like leaving the app rather than
    /// looking closer. An earlier attempt built a separate full-bleed surface for this and it read
    /// as a second window opening, which is the opposite of what was wanted.
    func focusCamera(_ id: CameraID) {
        window.sidebarSelection.select(.camera(id))
        selectLayout(.single)
        window.isInspectorVisible = false
    }

    /// Puts the connect form up for a camera that is not in the library yet.
    ///
    /// **It disconnects, and it says so by doing it.** This build streams one camera at a time, so
    /// there is no honest way to add a second while the first is on screen — a form floating over
    /// live video would imply the video survives, and it will not. Going back to the form is the
    /// truthful version of the same action, and the camera being left is already in the library, so
    /// one click in the sidebar brings it back.
    ///
    /// The address is cleared and the account is not: a second camera on the same site almost
    /// always shares its account, and `admin` is the answer often enough that pre-filling it is
    /// worth more than the rare correction.
    func addCamera() {
        // ⛔ THE PICTURE STAYS UP BEHIND THE FORM. This used to call `disconnect()`, which stopped
        // the stream and left the user on a form with no way back to what they had been watching —
        // the only exit was to connect *something*. Nothing about adding a camera requires
        // stopping the one already running: `connect(_:)` stops the old session itself when the
        // user submits, so the two paths end in the same place, and pressing Back is now free.
        session.phase = .connect
        session.form.host = ""
        session.form.password = ""
        session.form.clearDiagnosis()
    }

    /// Leaves the connect form for the picture that is still running behind it.
    ///
    /// Offered only when there is something to go back to — see `RootView`, which passes this in
    /// only while a stream is live.
    func leaveConnectForm() {
        session.form.isConnecting = false
        session.form.clearDiagnosis()
        session.phase = .live
    }

    /// Clears the stage's cell: the stream stops and the window goes back to the connect form.
    ///
    /// **Honest now, and it was not before.** Close has been drawn dimmed since the tile was
    /// written, for the reason ``tileActions`` still records: the session resumed exactly one
    /// remembered connection, so closing the only cell left the user with nothing on screen and no
    /// way back but retyping the address. The library changed that fact — the camera is a row in the
    /// list, and one click on it reconnects — so the button now does what its glyph says.
    ///
    /// Focus goes with the tile. Leaving `stageFocusIndex` pointing at a cell that no longer holds a
    /// camera would draw the ring around an "Add camera" placeholder the user never navigated to.
    func closeStageCell() {
        window.stageFocusIndex = nil
        session.disconnect()
    }

    /// Closes **one** cell: that camera's stream stops and the others keep playing.
    ///
    /// ⛔ The note above used to end "it will stop being the same one the moment a second stream
    /// exists", and this is that moment. Closing camera three with `disconnect()` would stop all
    /// four pictures and put the window back on the connect form — for a button whose glyph says it
    /// closes a tile.
    ///
    /// The bound camera still takes the whole-session path, because closing it is what returns the
    /// user to the form: it is the camera the form, the remembered connection and the inspector are
    /// about, and leaving the window on a stage whose bound camera is gone would be a state with no
    /// name.
    func closeStageCell(_ index: Int) {
        window.stageFocusIndex = nil
        let cells = stageAssignment.cells
        guard cells.indices.contains(index), let id = cells[index], id != cameraID else {
            session.disconnect()
            return
        }
        session.disconnect(id)
    }

    /// Shows the cameras the current layout could not fit.
    ///
    /// ⚠️ The sidebar, not a popover, and UX.md §5.1 asks for the popover. The list is where every
    /// camera is already named, addressed and clickable, and building a second surface that lists
    /// the same rows would be a duplicate to keep in step for no gain until the stage runs more than
    /// one stream. The search box is cleared on the way, because an overflow the user cannot see in
    /// the list they were just sent to is not an answer.
    ///
    /// ⚠️ This became a live path and the note here has been corrected rather than left. It was
    /// written when `stageAssignment` held exactly one camera, so `VStagePlan.overflowCount` was
    /// always zero and the `+3` chip never drew — wired against the day it would. That day was two
    /// commits later: the stage now takes the whole library, so five cameras in the `.single`
    /// layout put four in overflow and the chip appears.
    func showOverflowCameras() {
        window.isSidebarVisible = true
        window.searchText = ""
        // ⛔ AND IT BRINGS THEM ON. Revealing the list was all this could do while the stage held one
        // camera; it named the cameras that did not fit and left the user to click each one. With N
        // streams and a decode budget there is a principled answer to "show me those as well", and
        // `showOnStage` is it — the same call the patrol makes when it turns a page.
        //
        // ⚠️ The layout's worth, not the whole overflow. Putting nine cameras on a four-cell stage
        // would refuse five of them on the budget and leave the user with the same chip and no
        // explanation; one page is what the cells can actually hold.
        let count = stageOrder.count
        guard window.cycle.pageCount(cameraCount: count, layout: window.layout) > 1 else { return }
        let nextPage =
            (window.cycle.page + 1)
            % window.cycle.pageCount(cameraCount: count, layout: window.layout)
        window.cycle = window.cycle.selectingPage(
            nextPage,
            cameraCount: count,
            layout: window.layout)
        let page =
            stagePageOrder
            .compactMap { id in library.cameras.first { $0.id == id } }
        guard !page.isEmpty else { return }
        Task { await session.showOnStage(page) }
    }

    /// Plays the 3 pt nudge when an ⌥-arrow runs out of grid (UX.md §5.7).
    ///
    /// Movement does not wrap — `VGridNavigator` returns `nil` at the edge and deliberately leaves
    /// the key event unconsumed, so focus can still travel on to the sidebar or the inspector. The
    /// nudge is the only feedback that the *stage* saw the press and had nowhere to go, and without
    /// it `⌥→` on the trailing column is indistinguishable from a key that did not register.
    ///
    /// Nothing at all when motion is reduced. §7.10 rule 2 replaces decorative motion with a
    /// cross-fade, and there is nothing here to cross-fade: a displacement *is* the whole effect.
    func bumpStage(_ direction: VGridDirection) {
        guard motionEnabled else { return }
        let distance = CGFloat(direction.sign) * Self.stageBumpDistance
        let offset =
            direction.isHorizontal
            ? CGSize(width: distance, height: 0)
            : CGSize(width: 0, height: distance)
        withAnimation(VTheme.Motion.micro) { window.stageBumpOffset = offset }
        Task {
            // The dwell at full displacement, not the animation's duration: `Motion.micro` is a
            // spring and settles on its own. Sleeping for less would start the return before the
            // stage had visibly moved, which reads as a flicker rather than as a bump.
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(VTheme.Motion.micro) { window.stageBumpOffset = .zero }
        }
    }

    /// How far the stage travels on a bump. UX.md §5.7 fixes it at 3 pt.
    static let stageBumpDistance: CGFloat = 3

    /// Moves the focused camera one row up or down the *visible* list.
    ///
    /// Visible and not library order: a search or a collapsed device changes what ↓ should reach,
    /// and walking the library instead would step onto rows the user cannot see.
    func stepSidebar(_ delta: Int) {
        let tree = sidebarTree
        guard let current = window.sidebarSelection.focus.selectedCamera else {
            guard let first = tree.visibleCameras.first else { return }
            window.sidebarSelection.select(.camera(first))
            return
        }
        let next = delta < 0 ? tree.camera(before: current) : tree.camera(after: current)
        guard let next else { return }
        window.sidebarSelection.select(.camera(next))
    }

    /// What the tile's seven hover buttons do (UX.md §5.3).
    ///
    /// Audio starts muted and is enabled only after that camera has produced an audio buffer.
    ///
    /// Close joined the enabled set once the camera library existed; ``closeStageCell()`` records
    /// why it could not before.
    var tileActions: VTileActions {
        var actions = VTileActions()
        actions.enabled = [.snapshot, .record, .ptz, .quality, .fit, .timeline, .close]
        if session.cameras.stream(for: cameraID)?.hasAudio == true {
            actions.enabled.insert(.mute)
        }
        if session.twoWayAudio.supportedCameraIDs.contains(cameraID) {
            actions.enabled.insert(.talk)
        }
        actions.isMuted = session.cameras.stream(for: cameraID)?.isAudioMuted ?? true
        actions.audioLevel = session.cameras.stream(for: cameraID)?.audioLevel ?? 0
        actions.isFilled = window.fillsTile
        actions.isTalking =
            session.twoWayAudio.activeCameraID == cameraID
            && session.twoWayAudio.isTalking
        actions.beginTalk = { beginPushToTalk() }
        actions.endTalk = { session.twoWayAudio.end() }
        actions.perform = { action in
            switch action {
            case .snapshot: takeSnapshot()
            case .record: toggleRecording()
            case .ptz:
                window.isInspectorVisible = true
                window.inspectorTab = .ptz
            case .quality: cycleStreamQuality()
            case .fit: window.fillsTile.toggle()
            case .timeline:
                // Brings the window to the same one-camera shape first: a scrubber over a 4 × 4
                // grid would be a control for a camera the user has not said they are looking at.
                focusCamera(cameraID)
                window.showsTimeline = true
                window.timelineRevealRequests += 1
            case .close:
                // ⚠️ Reached only if a tile is drawn without going through `VGridStageView` — the
                // stage rebinds this case to its own per-cell `onClose` (see `GridTileView`'s
                // `barActions`), because the stage-wide bag cannot say *which* cell was pressed.
                // Not the same destination any more: the stage's per-cell close stops that
                // camera's stream, while this fallback — reached only by a tile drawn outside the
                // stage — has no cell to name and therefore means the whole session.
                closeStageCell()
            case .mute:
                session.toggleAudio(for: cameraID)
            case .talk:
                break
            }
        }
        return actions
    }

    /// Group mute is a real audio action, not only a checked menu row. Clearing it restores at most
    /// one route — the selected member, or the first active member — because live audio deliberately
    /// enforces one audible camera at a time.
    func toggleGroupAudio(_ id: GroupID) {
        let members = groups.members(of: id)
        if groups.toggleMuted(id) {
            for cameraID in members { session.setAudioMuted(true, for: cameraID) }
            return
        }
        let selectedID = selectedCamera?.id
        let selected = selectedID.flatMap { members.contains($0) ? $0 : nil }
        let candidate =
            selected
            ?? members.first {
                session.cameras.stream(for: $0)?.hasAudio == true
            }
        if let candidate { session.setAudioMuted(false, for: candidate) }
    }

    /// Captures each member in group order, switching the single-session build as needed.
    func snapshotGroup(_ id: GroupID) {
        let cameras = groups.members(of: id).compactMap { member in
            library.cameras.first { $0.id == member }
        }
        snapshotCameras(cameras)
    }

    /// Captures a set of cameras at one moment, into one folder with a manifest (`F-CAP-02`).
    ///
    /// ⛔ THIS USED TO SWITCH THE LIVE STREAM TO EACH CAMERA IN TURN, sleep half a second and press
    /// the single-camera snapshot button — sixteen full RTSP teardowns and rebuilds to take sixteen
    /// JPEGs that the camera would have handed over without any of it. It also stopped being correct
    /// the moment the panels moved onto the selection, because the button it pressed then captured
    /// whatever was *selected* rather than what the loop had switched to.
    ///
    /// A second press while a set is running is ignored rather than queued: the first set is already
    /// the answer to "capture everything now", and a second one would write a folder whose timestamp
    /// says the same thing.
    func snapshotCameras(_ cameras: [Camera]) {
        guard !cameras.isEmpty, !snapshotSets.isRunning else { return }
        let credentials = session.credentials
        Task {
            switch await snapshotSets.capture(cameras: cameras, credentials: credentials) {
            case let .written(_, succeeded, total):
                let template = Self.localized("Cameras captured: %lld of %lld")
                window.toast = MainWindowToast(
                    kind: succeeded == total ? .success : .warning,
                    message: String(format: template, succeeded, total),
                    actionTitle: "Show in Finder",
                    action: { revealLastSnapshotSet() })
            case let .cancelled(_, succeeded):
                let template = Self.localized("Stopped — cameras captured: %lld")
                let message = String(format: template, succeeded)
                window.toast = MainWindowToast(kind: .info, message: message)
            case let .failed(reason):
                session.dependencies.logger.error(.storage, "snapshot set failed: \(reason)")
                window.toast = MainWindowToast(
                    kind: .error,
                    message: Self.localized("The snapshot set could not be written"))
            }
        }
    }

    /// Opens the last set's folder in Finder.
    func revealLastSnapshotSet() {
        guard let folder = snapshotSets.lastFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Removes a group and steps the selection off it.
    ///
    /// Without the second half the sidebar would keep a selection pointing at a row that no longer
    /// exists, and the stage would show an empty grid with no way to explain itself.
    func deleteGroup(_ id: GroupID) {
        if window.sidebarSelection.focus == .group(id) {
            window.sidebarSelection.select(.live)
        }
        groups.delete(id)
    }

    /// Puts a string on the pasteboard.
    func copyToPasteboard(_ value: String) {
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

#endif  // os(macOS)
