//
//  ConfigurationMergePlan.swift
//  Vigil
//
//  Pure, deterministic merge preview for a full configuration document.
//

#if os(macOS)

import Foundation

import VigilCore
import VigilUI

/// The exact changes a JSON restore would make in merge mode, plus the resolved document.
struct ConfigurationMergePlan: Sendable, Equatable {
    let archive: VigilConfigurationArchive
    let addedCameras: [String]
    let updatedCameras: [String]
    let retainedCameraCount: Int
    let addedGroups: [String]
    let updatedGroups: [String]
    let addedBookmarks: [String]
    let updatedBookmarks: [String]
    let addedPresets: [String]
    let updatedPresets: [String]
    let replacesWorkspaceSettings: Bool
    let replacesVideoWall: Bool

    var changeCount: Int {
        addedCameras.count + updatedCameras.count
            + addedGroups.count + updatedGroups.count
            + addedBookmarks.count + updatedBookmarks.count
            + addedPresets.count + updatedPresets.count
            + (replacesWorkspaceSettings ? 1 : 0) + (replacesVideoWall ? 1 : 0)
    }

    static func make(current: VigilConfigurationArchive,
                     imported: VigilConfigurationArchive) -> ConfigurationMergePlan {
        let cameras = merge(current.cameras, imported.cameras, id: \.id)
        let groups = merge(current.groups, imported.groups, id: \.id)

        let bookmarkMerge = imported.bookmarks.map {
            merge(current.bookmarks ?? [], $0, id: \.id)
        }
        let presetMerge = imported.layoutPresets.map {
            merge(current.layoutPresets?.presets ?? [], $0.presets, id: \.id)
        }
        let settingsChanged = imported.settings.map { $0 != current.settings } ?? false
        let wallChanged = imported.videoWall.map { $0 != current.videoWall } ?? false

        let merged = VigilConfigurationArchive(
            exportedAt: imported.exportedAt,
            cameras: cameras.values,
            groups: groups.values,
            bookmarks: bookmarkMerge?.values ?? current.bookmarks,
            layoutPresets: presetMerge.map { VLayoutPresetCollection($0.values) }
                ?? current.layoutPresets,
            videoWall: imported.videoWall ?? current.videoWall,
            settings: imported.settings ?? current.settings)

        return ConfigurationMergePlan(
            archive: merged,
            addedCameras: cameras.added.map(\.displayName),
            updatedCameras: cameras.updated.map(\.displayName),
            retainedCameraCount: cameras.retainedCount,
            addedGroups: groups.added.map(\.name),
            updatedGroups: groups.updated.map(\.name),
            addedBookmarks: bookmarkMerge?.added.map(bookmarkName) ?? [],
            updatedBookmarks: bookmarkMerge?.updated.map(bookmarkName) ?? [],
            addedPresets: presetMerge?.added.map(\.name) ?? [],
            updatedPresets: presetMerge?.updated.map(\.name) ?? [],
            replacesWorkspaceSettings: settingsChanged,
            replacesVideoWall: wallChanged)
    }

    private static func bookmarkName(_ bookmark: BookmarkRecord) -> String {
        bookmark.title.isEmpty ? bookmark.id.uuidString : bookmark.title
    }

    private struct MergeResult<Value> {
        var values: [Value]
        var added: [Value]
        var updated: [Value]
        var retainedCount: Int
    }

    /// Imported values replace matching identities in place; new identities append in import order,
    /// and local-only values remain. This keeps the user's existing visual order stable.
    private static func merge<Value: Equatable, ID: Hashable>(
        _ current: [Value], _ imported: [Value], id: KeyPath<Value, ID>
    ) -> MergeResult<Value> {
        let importedByID = Dictionary(uniqueKeysWithValues: imported.map { ($0[keyPath: id], $0) })
        let currentIDs = Set(current.map { $0[keyPath: id] })
        var added: [Value] = []
        var updated: [Value] = []
        var values = current.map { old -> Value in
            guard let replacement = importedByID[old[keyPath: id]] else { return old }
            if replacement != old { updated.append(replacement) }
            return replacement
        }
        for value in imported where !currentIDs.contains(value[keyPath: id]) {
            values.append(value)
            added.append(value)
        }
        return MergeResult(values: values, added: added, updated: updated,
                           retainedCount: current.count - updated.count)
    }
}

#endif  // os(macOS)
