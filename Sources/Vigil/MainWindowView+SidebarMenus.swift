//
//  MainWindowView+SidebarMenus.swift
//  Vigil
//
//  The sidebar's right-click menus — the camera row menu, the group row menu, and the "Add to
//  Group" submenu — together with the two library actions those menus fire (duplicate, remove).
//  Split from MainWindowView+Sidebar.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//  macOS-only.
//

#if os(macOS)

import Foundation
import SwiftUI

import VigilCore
import VigilProtocols
import VigilUI

// MARK: - The sidebar context menus

/// ⚠️ `internal` rather than `private`, for the reason given in `MainWindowView+Library.swift`:
/// `private` reaches a type's extensions only within one file.
extension MainWindowView {

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
            VSidebarMenuItem(
                id: "camera.rename",
                title: Self.localized("Rename…"),
                symbol: .rename,
                isEnabled: !library.isReadOnly,
                action: { window.sheet = .cameraSettings }),
            VSidebarMenuItem(
                id: "camera.duplicate",
                title: Self.localized("Duplicate for Another Channel…"),
                symbol: .copy,
                isEnabled: !library.isReadOnly,
                action: { duplicateCamera(camera.id) }),
            .submenu(
                id: "camera.group",
                title: Self.localized("Add to Group"),
                symbol: .group,
                groupMembershipItems(for: camera.id)),
            VSidebarMenuItem(
                id: "camera.bookmark",
                title: Self.localized("Bookmark This Moment…"),
                symbol: .bookmark,
                action: { window.sheet = .newBookmark(markableInstant) }),
            VSidebarMenuItem(
                id: "camera.motionRecording",
                title: Self.localized(
                    isMotionRecordingArmed(camera.id)
                        ? "Disarm Motion Recording" : "Arm Motion Recording"),
                symbol: .recording,
                isOn: isMotionRecordingArmed(camera.id),
                action: { toggleMotionRecordingArmed(camera.id) }),
            .separator(id: "camera.rule1"),
            VSidebarMenuItem(
                id: "camera.copyAddress",
                title: Self.localized("Copy Address"),
                symbol: .copy,
                action: { copyToPasteboard(camera.host) }),
        ]
        let serial = deviceInfo.identity.serialNumber
        items.append(
            VSidebarMenuItem(
                id: "camera.copySerial",
                title: Self.localized("Copy Serial Number"),
                symbol: .copy,
                isEnabled: !serial.isEmpty,
                action: { copySerial() }))
        items.append(
            VSidebarMenuItem(
                id: "camera.web",
                title: Self.localized("Open in Browser"),
                symbol: .info,
                isEnabled: !camera.host.isEmpty,
                action: { openDeviceWebPage() }))
        items.append(.separator(id: "camera.rule2"))
        items.append(
            VSidebarMenuItem(
                id: "camera.settings",
                title: Self.localized("Camera Settings…"),
                symbol: .settings,
                action: { window.sheet = .cameraSettings }))
        items.append(.separator(id: "camera.rule3"))
        items.append(
            VSidebarMenuItem(
                id: "camera.remove",
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
            items.append(
                VSidebarMenuItem(
                    id: "camera.group.none",
                    title: Self.localized("None"),
                    isEnabled: current != nil,
                    action: clear))
        }
        items.append(
            VSidebarMenuItem(
                id: "camera.group.new",
                title: Self.localized("New Group…"),
                symbol: .newGroup,
                action: { window.sheet = .newGroup }))
        return items
    }

    /// One group's row in the membership submenu.
    ///
    /// Split out of ``groupMembershipItems(for:)`` for the type checker's sake, not for tidiness.
    private func membershipRow(
        _ group: CameraGroupRecord,
        camera: CameraID,
        current: GroupID?
    ) -> VSidebarMenuItem {
        // Choosing the group a camera is already in takes it out again, which is what a ticked
        // menu item means everywhere else.
        let target: GroupID? = group.id == current ? nil : group.id
        let toggle: () -> Void = { groups.setGroup(target, for: camera) }
        return VSidebarMenuItem(
            id: "camera.group.\(group.id)",
            title: group.name,
            isOn: group.id == current,
            action: toggle)
    }

    /// The right-click menu on a group row.
    func groupMenu(_ group: VSidebarGroup) -> [VSidebarMenuItem] {
        let isMuted = groups.mutedGroups.contains(group.id)
        let muteKey = isMuted ? "Unmute Group" : "Mute Group"
        return [
            VSidebarMenuItem(
                id: "group.snapshot",
                title: Self.localized("Snapshot Group"),
                symbol: .snapshotAll,
                action: { snapshotGroup(group.id) }),
            VSidebarMenuItem(
                id: "group.mute",
                title: Self.localized(muteKey),
                symbol: .mute,
                isOn: isMuted,
                action: { toggleGroupAudio(group.id) }),
            .separator(id: "group.actions.rule"),
            VSidebarMenuItem(
                id: "group.rename",
                title: Self.localized("Rename…"),
                symbol: .rename,
                action: { window.sheet = .renameGroup(group.id) }),
            .separator(id: "group.rule"),
            VSidebarMenuItem(
                id: "group.delete",
                title: Self.localized("Delete Group"),
                symbol: .delete,
                role: .destructive,
                action: { deleteGroup(group.id) }),
        ]
    }
}

#endif  // os(macOS)
