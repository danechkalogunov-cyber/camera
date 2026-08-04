//
//  CameraGroupStore.swift
//  Vigil
//
//  The user's groups, and which camera is in which one. Kept where the app can find it again.
//  macOS-only. See docs/UX.md §1.1 (a camera belongs to 0…1 group; groups do not nest) and §4.1.
//

#if os(macOS)

import Foundation
import Observation

import VigilCore
import VigilProtocols

// MARK: - CameraGroupRecord

/// One group, as it is written to disk.
///
/// Membership lives on the group rather than on the camera because the camera record is rebuilt
/// from scratch on every launch — `AppSessionModel.makeCamera` constructs it from the remembered
/// host, so a `groupID` stored on it would be gone by the next start. The group owns the list, the
/// group is what persists, and the sidebar's `VSidebarCamera.groupID` is derived from it.
struct CameraGroupRecord: Codable, Sendable, Hashable, Identifiable {

    /// Stable identity, minted once and never reused.
    let id: GroupID

    /// What the user called it. Not unique — two groups named "Outside" is their business, and
    /// forcing uniqueness would rename a group behind their back.
    var name: String

    /// An explicit index into `VTheme.Color.Ident.all`, or `nil` to derive one from ``id``.
    var identityIndex: Int?

    /// The cameras in this group, in the order the user put them.
    ///
    /// An array and not a `Set`: the order is the user's, it is visible when the group is opened
    /// into the stage, and a `Set` would reshuffle it on every save.
    var members: [CameraID]
}

// MARK: - CameraGroupStore

/// Creates, names and populates the user's groups.
///
/// **Why this exists.** `VSidebarTree` has rendered a GROUPS section from `[VSidebarGroup]` since
/// the sidebar was written, and `VCameraLibrarySource` declares `createGroup(named:cameras:)` and
/// `setGroup(_:for:)` — but nothing ever implemented that protocol, so the section was permanently
/// empty and the `＋` in its header had nothing behind it. This is the missing store.
///
/// **Where it lives.** `~/Library/Containers/com.vigil.app/Data/Library/Application Support/
/// Vigil/groups.json`, beside `clips.json`, for the same reason: it is the app's own bookkeeping and
/// it belongs where the sandbox owns it rather than anywhere the user might tidy it away.
///
/// **The one invariant.** A camera is in at most one group (UX.md §1.1). It is enforced on every
/// write *and* on load, because a hand-edited `groups.json` that puts one camera in two groups would
/// otherwise make `group(for:)` answer differently depending on iteration order — the kind of bug
/// that looks like a redraw glitch for a week.
@MainActor
@Observable
final class CameraGroupStore {

    // MARK: - Observable State

    /// Every group, in display order.
    private(set) var groups: [CameraGroupRecord] = []

    /// Group audio policy, ready for the audio renderer and already exposed in group actions.
    private(set) var mutedGroups: Set<GroupID> = []

    // MARK: - Stored Properties

    private let logger: any LoggerProtocol

    /// The longest name that will be stored, matching `Camera.validated()`. A sidebar row is one
    /// line tall and a 4 000-character name pasted in by accident should not be kept.
    private static let nameLimit = 64

    // MARK: - Initialisation

    /// Loads the groups from disk, or starts empty when there are none.
    ///
    /// An unreadable document is treated as empty rather than as a failure — the same call this
    /// target's other stores make. Losing the grouping is a small annoyance; refusing to open the
    /// sidebar because a bookkeeping file is corrupt is a large one.
    init(logger: any LoggerProtocol) {
        self.logger = logger
        guard let url = Self.storeURL, let data = try? Data(contentsOf: url) else { return }
        do {
            groups = Self.repaired(try JSONDecoder().decode([CameraGroupRecord].self, from: data))
            logger.debug(.storage, "camera groups: \(groups.count) loaded")
        } catch {
            logger.error(.storage, "camera groups unreadable, starting empty: \(error)")
        }
    }

    // MARK: - API

    /// Creates a group and returns its identifier, or `nil` when the name is unusable.
    ///
    /// Refuses rather than substitutes. A group called "Untitled" that the user never asked for is
    /// worse than a `＋` that visibly did nothing, because the first one has to be found and deleted.
    @discardableResult
    func create(named name: String, cameras: [CameraID] = []) -> GroupID? {
        guard let trimmed = Self.usableName(name) else {
            logger.debug(.storage, "camera group not created: the name was empty")
            return nil
        }
        let group = CameraGroupRecord(id: GroupID(),
                                      name: trimmed,
                                      identityIndex: nil,
                                      members: [])
        groups.append(group)
        for camera in cameras { assign(camera, to: group.id) }
        save()
        logger.info(.storage, "camera group created with \(cameras.count) camera(s)")
        return group.id
    }

    /// Renames a group. An empty name leaves the old one, which is what UX.md §4.3 requires of the
    /// camera row's inline rename and is the same expectation here.
    func rename(_ id: GroupID, to name: String) {
        guard let trimmed = Self.usableName(name),
              let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = trimmed
        save()
    }

    /// Removes a group.
    ///
    /// Its cameras are **not** removed from the library — they simply become ungrouped. A delete
    /// that took the contents with it would be a destructive action wearing a tidy-up's label.
    func delete(_ id: GroupID) {
        guard groups.contains(where: { $0.id == id }) else { return }
        groups.removeAll { $0.id == id }
        save()
        logger.info(.storage, "camera group deleted")
    }

    /// Sets a group's identity colour, or clears it back to the derived one.
    func setIdentityIndex(_ index: Int?, for id: GroupID) {
        guard let position = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[position].identityIndex = index
        save()
    }

    /// Puts a camera in one group, or in none when `group` is `nil`.
    ///
    /// Removes it from every other group first. Without that step the "at most one group" invariant
    /// would hold only for cameras that had never been moved.
    func setGroup(_ group: GroupID?, for camera: CameraID) {
        guard let group else {
            let had = groups.contains { $0.members.contains(camera) }
            detach(camera)
            if had { save() }
            return
        }
        guard groups.contains(where: { $0.id == group }) else { return }
        assign(camera, to: group)
        save()
    }

    /// The group a camera belongs to, or `nil` when it is ungrouped.
    func group(for camera: CameraID) -> GroupID? {
        groups.first { $0.members.contains(camera) }?.id
    }

    /// How many cameras are in a group.
    func memberCount(_ id: GroupID) -> Int {
        groups.first { $0.id == id }?.members.count ?? 0
    }

    /// Cameras in one group, preserving the group's explicit order.
    func members(of id: GroupID) -> [CameraID] {
        groups.first { $0.id == id }?.members ?? []
    }

    func toggleMuted(_ id: GroupID) {
        if !mutedGroups.insert(id).inserted { mutedGroups.remove(id) }
    }

    /// Replaces groups after a validated configuration import and persists them atomically.
    func replaceForImport(with imported: [CameraGroupRecord], validCameras: Set<CameraID>) {
        let filtered = imported.map { record in
            var record = record
            record.members.removeAll { !validCameras.contains($0) }
            return record
        }
        groups = Self.repaired(filtered)
        save()
    }

    /// Moves a group to a new position in the list.
    ///
    /// `index` is read against the **pre-move** array — the convention `SwiftUI.onMove` and
    /// `DropDelegate` both report, and the one `VSidebarReorder` already converts for. Removing
    /// first and then inserting at the raw index would land one place too early for every downward
    /// move, which is precisely the off-by-one that makes a drag appear to snap back.
    func move(_ id: GroupID, to index: Int) {
        let reordered = Self.moving(groups, id: id, before: index)
        guard reordered != groups else { return }
        groups = reordered
        save()
    }

    /// Pure pre-removal-index permutation used by drag/drop and its off-by-one tests.
    static func moving(_ records: [CameraGroupRecord],
                       id: GroupID,
                       before index: Int) -> [CameraGroupRecord] {
        guard let from = records.firstIndex(where: { $0.id == id }) else { return records }
        let clamped = min(max(0, index), records.count)
        guard clamped != from, clamped != from + 1 else { return records }
        var result = records
        let record = result.remove(at: from)
        result.insert(record, at: clamped > from ? clamped - 1 : clamped)
        return result
    }

    // MARK: - Private Helpers

    /// Puts a camera in exactly one group, leaving the order of the others untouched.
    private func assign(_ camera: CameraID, to group: GroupID) {
        detach(camera)
        guard let index = groups.firstIndex(where: { $0.id == group }) else { return }
        groups[index].members.append(camera)
    }

    /// Removes a camera from every group.
    private func detach(_ camera: CameraID) {
        for index in groups.indices {
            groups[index].members.removeAll { $0 == camera }
        }
    }

    /// A name that may be stored, or `nil` when there is nothing usable in it.
    ///
    /// Newlines become spaces rather than being rejected: a name pasted from a text editor arrives
    /// with a trailing one, and refusing it would be surprising. The same repair `Camera.validated()`
    /// performs, for the same reason.
    private static func usableName(_ raw: String) -> String? {
        var name = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if name.count > nameLimit { name = String(name.prefix(nameLimit)) }
        return name
    }

    /// Enforces the one-group rule over a freshly decoded document.
    ///
    /// The first group listed keeps a camera that appears in several; later claims are dropped. A
    /// document that has been hand-edited is repaired rather than refused, so a typo costs a
    /// grouping rather than the whole file.
    private static func repaired(_ decoded: [CameraGroupRecord]) -> [CameraGroupRecord] {
        var seen: Set<CameraID> = []
        return decoded.map { record in
            var copy = record
            copy.members = record.members.filter { seen.insert($0).inserted }
            return copy
        }
    }

    /// Writes the document out.
    ///
    /// Atomic, so a crash mid-write leaves the previous groups rather than a truncated file — the
    /// same guarantee `ClipManifest.save()` gives its own document.
    private func save() {
        guard let url = Self.storeURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(groups).write(to: url, options: [.atomic])
        } catch {
            logger.error(.storage, "camera groups could not be written: \(error)")
        }
    }

    /// Where the document is kept.
    static var storeURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appending(path: "Vigil/groups.json")
    }
}

#endif  // os(macOS)
