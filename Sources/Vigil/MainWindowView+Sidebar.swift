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
        archive.load(day: clock.day(containing: lead),
                     clock: clock,
                     localClips: timelineLocalClips,
                     markers: timelineMarkers)
        archive.movePlayhead(to: lead, isScrubbing: false)
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
        session.disconnect()
        session.form.host = ""
        session.form.password = ""
        session.form.clearDiagnosis()
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
        let offset = direction.isHorizontal
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
    /// Only the six this build can honour are enabled. Mute is the one that stays dimmed: there is
    /// no audio path at all — `VigilVideo`'s whole `Audio/` directory is unwritten — so the button
    /// would be lying about a stream that has no sound to mute. It stays in the row rather than
    /// being removed, because §5.3 fixes the order and a row that changes shape between cameras is a
    /// row nobody can learn.
    ///
    /// Close joined the enabled set once the camera library existed; ``closeStageCell()`` records
    /// why it could not before.
    var tileActions: VTileActions {
        var actions = VTileActions()
        actions.enabled = [.snapshot, .record, .ptz, .quality, .fit, .timeline, .close]
        actions.isFilled = window.fillsTile
        actions.perform = { action in
            switch action {
            case .snapshot: takeSnapshot()
            case .record:   toggleRecording()
            case .ptz:
                window.isInspectorVisible = true
                window.inspectorTab = .ptz
            case .quality:  cycleStreamQuality()
            case .fit:      window.fillsTile.toggle()
            case .timeline:
                // Brings the window to the same one-camera shape first: a scrubber over a 4 × 4
                // grid would be a control for a camera the user has not said they are looking at.
                focusCamera(cameraID)
                window.showsTimeline = true
            case .close:
                // ⚠️ Reached only if a tile is drawn without going through `VGridStageView` — the
                // stage rebinds this case to its own per-cell `onClose` (see `GridTileView`'s
                // `barActions`), because the stage-wide bag cannot say *which* cell was pressed.
                // Not the same destination any more: the stage's per-cell close stops that
                // camera's stream, while this fallback — reached only by a tile drawn outside the
                // stage — has no cell to name and therefore means the whole session.
                closeStageCell()
            case .mute:
                break
            }
        }
        return actions
    }

    /// The right-click menu on the camera row.
    ///
    /// ⚠️ *Remove Camera* used to be absent, and the note said why: the session resumed exactly one
    /// remembered connection, so removing it left the window with nothing and no way back but
    /// retyping the address. The library ended that — the other cameras are still listed, and the
    /// removed one's Keychain item is deliberately left alone, so re-adding it costs an address and
    /// not a password. It is last, destructive, and disabled on a read-only library, where the store
    /// would refuse the write in silence.
    func cameraMenu(_ camera: VSidebarCamera) -> [VSidebarMenuItem] {
        var items: [VSidebarMenuItem] = [
            VSidebarMenuItem(id: "camera.rename",
                             title: Self.localized("Rename…"),
                             symbol: .rename,
                             isEnabled: !library.isReadOnly,
                             action: { window.sheet = .cameraSettings }),
            VSidebarMenuItem(id: "camera.duplicate",
                             title: Self.localized("Duplicate for Another Channel…"),
                             symbol: .copy,
                             isEnabled: !library.isReadOnly,
                             action: { duplicateCamera(camera.id) }),
            .submenu(id: "camera.group",
                     title: Self.localized("Add to Group"),
                     symbol: .group,
                     groupMembershipItems(for: camera.id)),
            VSidebarMenuItem(id: "camera.bookmark",
                             title: Self.localized("Bookmark This Moment…"),
                             symbol: .bookmark,
                             action: { window.sheet = .newBookmark(markableInstant) }),
            .separator(id: "camera.rule1"),
            VSidebarMenuItem(id: "camera.copyAddress",
                             title: Self.localized("Copy Address"),
                             symbol: .copy,
                             action: { copyToPasteboard(camera.host) }),
        ]
        let serial = deviceInfo.identity.serialNumber
        items.append(VSidebarMenuItem(id: "camera.copySerial",
                                      title: Self.localized("Copy Serial Number"),
                                      symbol: .copy,
                                      isEnabled: !serial.isEmpty,
                                      action: { copySerial() }))
        items.append(VSidebarMenuItem(id: "camera.web",
                                      title: Self.localized("Open in Browser"),
                                      symbol: .info,
                                      isEnabled: !camera.host.isEmpty,
                                      action: { openDeviceWebPage() }))
        items.append(.separator(id: "camera.rule2"))
        items.append(VSidebarMenuItem(id: "camera.settings",
                                      title: Self.localized("Camera Settings…"),
                                      symbol: .settings,
                                      action: { window.sheet = .cameraSettings }))
        items.append(.separator(id: "camera.rule3"))
        items.append(VSidebarMenuItem(id: "camera.remove",
                                      title: Self.localized("Remove Camera"),
                                      symbol: .delete,
                                      role: .destructive,
                                      isEnabled: !library.isReadOnly,
                                      action: { removeCamera(camera.id) }))
        return items
    }

    /// Copies a row, selects it, then opens settings so its channel can be changed immediately.
    func duplicateCamera(_ id: CameraID) {
        Task {
            guard let copy = await library.duplicate(id) else { return }
            window.sidebarSelection.select(.camera(copy.id))
            window.sheet = .cameraSettings
        }
    }

    /// Takes a camera out of the library, and moves the window off it if it was the one playing.
    ///
    /// ⛔ The Keychain item stays. `AppLibraryModel.remove` says why and it is worth repeating here,
    /// because this is the call site where it would be tempting to "tidy up": deleting a password
    /// because a row disappeared costs the user access to a device they still own, and the two acts
    /// are not the same act.
    ///
    /// Landing somewhere sensible afterwards is half the feature. Removing the camera that is
    /// streaming leaves the stage pointing at a record the library no longer has, so the session
    /// moves to the first camera that remains — and to the connect form when none do, which is the
    /// honest end state rather than an empty grid with no way out.
    func removeCamera(_ id: CameraID) {
        Task {
            await library.remove(id)
            // The media path goes with the record. An entry kept here would outlive the camera it
            // is keyed by, and the *next* camera to be given that identity — an import, an undo —
            // would inherit a stream showing something else.
            session.cameras.forget(id)
            guard id == cameraID else { return }
            guard let next = library.cameras.first else {
                session.disconnect()
                return
            }
            window.sidebarSelection.select(.camera(next.id))
            await session.switchTo(next)
        }
    }

    /// The *Add to Group ▸* submenu: every group, with a tick beside the one this camera is in, and
    /// a way out at the bottom.
    ///
    /// `New Group…` is listed even when there are groups, because the moment a user wants a group is
    /// usually the moment they are looking at the camera that needs one.
    ///
    /// ⚠️ Every intermediate is annotated and the row is built by a named helper rather than inline
    /// in a `map`. Swift's type checker gave up on the one-expression version — "unable to
    /// type-check this expression in reasonable time" — because a closure returning a struct with
    /// several defaulted arguments, one of which is another closure containing a ternary over an
    /// `Optional`, is a large inference problem. Naming the types collapses it.
    func groupMembershipItems(for camera: CameraID) -> [VSidebarMenuItem] {
        let current: GroupID? = groups.group(for: camera)
        var items: [VSidebarMenuItem] = []
        for group in groups.groups {
            items.append(membershipRow(group, camera: camera, current: current))
        }
        if !items.isEmpty {
            items.append(VSidebarMenuItem.separator(id: "camera.group.rule"))
            let clear: () -> Void = { groups.setGroup(nil, for: camera) }
            items.append(VSidebarMenuItem(id: "camera.group.none",
                                          title: Self.localized("None"),
                                          isEnabled: current != nil,
                                          action: clear))
        }
        items.append(VSidebarMenuItem(id: "camera.group.new",
                                      title: Self.localized("New Group…"),
                                      symbol: .newGroup,
                                      action: { window.sheet = .newGroup }))
        return items
    }

    /// One group's row in the membership submenu.
    ///
    /// Split out of ``groupMembershipItems(for:)`` for the type checker's sake, not for tidiness.
    private func membershipRow(_ group: CameraGroupRecord,
                               camera: CameraID,
                               current: GroupID?) -> VSidebarMenuItem {
        // Choosing the group a camera is already in takes it out again, which is what a ticked
        // menu item means everywhere else.
        let target: GroupID? = group.id == current ? nil : group.id
        let toggle: () -> Void = { groups.setGroup(target, for: camera) }
        return VSidebarMenuItem(id: "camera.group.\(group.id)",
                                title: group.name,
                                isOn: group.id == current,
                                action: toggle)
    }

    /// The right-click menu on a group row.
    func groupMenu(_ group: VSidebarGroup) -> [VSidebarMenuItem] {
        [
            VSidebarMenuItem(id: "group.snapshot",
                             title: Self.localized("Snapshot Group"),
                             symbol: .snapshotAll,
                             action: { snapshotGroup(group.id) }),
            VSidebarMenuItem(id: "group.mute",
                             title: Self.localized(groups.mutedGroups.contains(group.id)
                                 ? "Unmute Group" : "Mute Group"),
                             symbol: .mute,
                             isOn: groups.mutedGroups.contains(group.id),
                             action: { groups.toggleMuted(group.id) }),
            .separator(id: "group.actions.rule"),
            VSidebarMenuItem(id: "group.rename",
                             title: Self.localized("Rename…"),
                             symbol: .rename,
                             action: { window.sheet = .renameGroup(group.id) }),
            .separator(id: "group.rule"),
            VSidebarMenuItem(id: "group.delete",
                             title: Self.localized("Delete Group"),
                             symbol: .delete,
                             role: .destructive,
                             action: { deleteGroup(group.id) }),
        ]
    }

    /// Captures each member in group order, switching the single-session build as needed.
    func snapshotGroup(_ id: GroupID) {
        let cameras = groups.members(of: id).compactMap { member in
            library.cameras.first { $0.id == member }
        }
        snapshotCameras(cameras)
    }

    /// Captures cameras sequentially so the single-session transport never overlaps credentials.
    func snapshotCameras(_ cameras: [Camera]) {
        guard !cameras.isEmpty else { return }
        Task {
            for camera in cameras {
                if session.camera?.id != camera.id {
                    await session.switchTo(camera)
                    try? await Task.sleep(for: .milliseconds(500))
                }
                takeSnapshot()
            }
        }
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
