//
//  SidebarTree.swift
//  VigilUI
//
//  Flattens sections, user groups, NVR devices and cameras into the one ordered row list the view
//  renders and the keyboard walks. Pure, so "which rows are visible" is a testable question.
//  macOS-only. Implements docs/UX.md §4.1 (fixed section order, empty rows never disappear), §4.2,
//  §4.4 (results keep the section structure) and §8.2 (NVR channels).
//

#if os(macOS)

import Foundation

import VigilProtocols

// MARK: - VSidebarSection

/// The sidebar's fixed sections, in their fixed order.
///
/// ⛔ The order never changes and a section with no content never disappears — it collapses to a
/// single muted row instead (UX.md §4.1). An information architecture that rearranges itself cannot
/// be learned, and a section that vanishes teaches the user that the app lost their data.
package enum VSidebarSection: String, Sendable, Hashable, CaseIterable, Identifiable {

    /// The current layout row.
    case live

    /// User-created groups.
    case groups

    /// Every camera.
    case cameras

    /// Recordings, events and bookmarks.
    case library

    /// Stable identity.
    package var id: String { rawValue }

    /// Whether this section can be collapsed by the user. `live` is a single row and has nothing to
    /// collapse.
    package var isCollapsible: Bool {
        self != .live
    }
}

// MARK: - VSidebarLibraryLink

/// The three rows in the LIBRARY section, which replace the stage's content when selected.
package enum VSidebarLibraryLink: String, Sendable, Hashable, CaseIterable, Identifiable {

    /// Saved clips.
    case recordings

    /// The event feed.
    case events

    /// Saved bookmarks.
    case bookmarks

    /// Stable identity.
    package var id: String { rawValue }

    /// The selection this row produces.
    package var selection: VSidebarSelection {
        switch self {
        case .recordings: return .recordings
        case .events: return .events
        case .bookmarks: return .bookmarks
        }
    }
}

// MARK: - VSidebarRowKind

/// What one row of the sidebar is.
package enum VSidebarRowKind: Sendable, Hashable {

    /// An uppercase section eyebrow, 22 pt.
    case sectionHeader(VSidebarSection)

    /// The "Current Layout" row.
    case layout

    /// A user-created group, with how many cameras are in it.
    case group(VSidebarGroup, memberCount: Int)

    /// An NVR or DVR that contributes several channels, with how many.
    case device(key: String, name: String, channelCount: Int)

    /// A camera, with the match that put it here when a search is active.
    case camera(VSidebarCamera, match: VSidebarMatch?)

    /// A library link.
    case libraryLink(VSidebarLibraryLink, badge: Int?)

    /// The muted row a section shows instead of disappearing.
    case emptyNotice(VSidebarSection)
}

// MARK: - VSidebarRow

/// One row, ready to render.
package struct VSidebarRow: Sendable, Hashable, Identifiable {

    /// A stable identity across rebuilds, so SwiftUI diffs rather than recreating — which for a
    /// camera row means its micro-thumbnail is not thrown away on every keystroke.
    package let id: String

    /// What the row is.
    package let kind: VSidebarRowKind

    /// Nesting depth: 0 for a section's direct children, 1 for a camera under a device or group.
    package let indent: Int

    /// The selection this row produces when clicked, or `nil` for a row that is not selectable
    /// (a section header, an empty notice).
    package let selection: VSidebarSelection?

    /// Creates a row.
    package init(id: String,
                 kind: VSidebarRowKind,
                 indent: Int = 0,
                 selection: VSidebarSelection? = nil) {
        self.id = id
        self.kind = kind
        self.indent = indent
        self.selection = selection
    }

    /// The camera this row shows, if it is a camera row.
    package var camera: VSidebarCamera? {
        if case .camera(let camera, _) = kind { return camera }
        return nil
    }

    /// Whether the row can be dragged. Only camera rows reorder.
    package var isDraggable: Bool {
        camera != nil
    }
}

// MARK: - VSidebarTree

/// Builds the sidebar's row list.
///
/// ## Devices, and when a device header appears
///
/// An NVR contributes one `VSidebarCamera` per channel, and eight rows all called
/// "Front Entrance CH1…CH8" is the listing a user cannot scan. So cameras that share a
/// ``VSidebarCamera/deviceKey`` are gathered under a collapsible device header — but **only when two
/// or more of them are present**. A single-channel device would otherwise get a header with one child,
/// which is a disclosure triangle the user has to open to see one thing. Standalone cameras stay at
/// the top level.
///
/// Grouping by device is applied *within* the CAMERAS section and is orthogonal to user groups: a
/// group is a thing the user made and a device is a fact about the hardware.
///
/// ## Search keeps the structure
///
/// UX.md §4.4: results "keep the section structure but hide non-matching rows". A device or group
/// header therefore survives if any of its children matched, and disappears if none did — so a search
/// narrows the list without reshaping it, and the row a user is looking for does not jump to a
/// different indent level as they type.
package struct VSidebarTree: Sendable {

    // MARK: - Stored Properties

    /// Every row, in display order.
    package let rows: [VSidebarRow]

    /// The cameras that are visible, in display order.
    ///
    /// This is the list every keyboard and selection operation works against — ⇧-click ranges, ↑/↓
    /// movement, `⌘A`. Using the library order there instead would select rows the user cannot see
    /// whenever a search or a filter is active.
    package let visibleCameras: [CameraID]

    /// How many cameras matched, for the CAMERAS header's count badge.
    package let matchedCount: Int

    /// How many of those are showing a picture, for the footer's "*n* live".
    package let liveCount: Int

    /// How many are degraded, for the footer's warning form.
    package let degradedCount: Int

    // MARK: - Initialisation

    /// Builds the tree.
    ///
    /// - Parameters:
    ///   - cameras: the library's cameras, in library order.
    ///   - groups: the library's groups.
    ///   - search: the active query and filter.
    ///   - collapsed: identifiers of collapsed sections, groups and devices. Keys are the same
    ///     strings used as row ``VSidebarRow/id``s for headers.
    ///   - eventBadge: unread event count for the Events row, or `nil` for none.
    ///   - recordingCount: clip count for the Recordings row.
    ///   - bookmarkCount: count for the Bookmarks row.
    ///   - now: the instant the motion filter measures against.
    package init(cameras: [VSidebarCamera],
                 groups: [VSidebarGroup] = [],
                 search: VSidebarSearch = VSidebarSearch(),
                 collapsed: Set<String> = [],
                 eventBadge: Int? = nil,
                 recordingCount: Int? = nil,
                 bookmarkCount: Int? = nil,
                 now: Date = Date()) {
        // Counts are over the whole library, not the filtered list: the footer reports the state of
        // the system, and a filter is a view of it. A footer that changed when you typed would be
        // reporting on the search box rather than on the cameras.
        var live = 0
        var degraded = 0
        for camera in cameras {
            if camera.status.countsAsLive { live += 1 }
            if camera.status.countsAsDegraded { degraded += 1 }
        }
        self.liveCount = live
        self.degradedCount = degraded

        let groupNames = Dictionary(groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in
            first
        })
        // Match once per camera; the result is carried into the row so the view can highlight
        // without re-running the scorer during layout.
        var matches: [CameraID: VSidebarMatch] = [:]
        var matched: [VSidebarCamera] = []
        for camera in cameras {
            let groupName = camera.groupID.flatMap { groupNames[$0] }
            guard let match = search.match(camera, groupName: groupName, now: now) else { continue }
            matches[camera.id] = match
            matched.append(camera)
        }
        self.matchedCount = matched.count

        var rows: [VSidebarRow] = []
        var visible: [CameraID] = []

        // MARK: LIVE
        rows.append(VSidebarRow(id: "section.live",
                                kind: .sectionHeader(.live)))
        rows.append(VSidebarRow(id: "row.layout", kind: .layout, selection: .live))

        // MARK: GROUPS
        let groupsHeaderID = "section.groups"
        rows.append(VSidebarRow(id: groupsHeaderID, kind: .sectionHeader(.groups)))
        if !collapsed.contains(groupsHeaderID) {
            if groups.isEmpty {
                rows.append(VSidebarRow(id: "empty.groups", kind: .emptyNotice(.groups)))
            } else {
                for group in groups {
                    let count = cameras.reduce(into: 0) { total, camera in
                        if camera.groupID == group.id { total += 1 }
                    }
                    rows.append(VSidebarRow(id: "group.\(group.id)",
                                            kind: .group(group, memberCount: count),
                                            selection: .group(group.id)))
                }
            }
        }

        // MARK: CAMERAS
        let camerasHeaderID = "section.cameras"
        rows.append(VSidebarRow(id: camerasHeaderID, kind: .sectionHeader(.cameras)))
        if !collapsed.contains(camerasHeaderID) {
            if cameras.isEmpty || matched.isEmpty {
                rows.append(VSidebarRow(id: "empty.cameras", kind: .emptyNotice(.cameras)))
            } else {
                let multiChannel = Self.multiChannelDeviceKeys(cameras)
                var emittedDevices: Set<String> = []
                for camera in matched {
                    guard let key = camera.deviceKey, multiChannel.contains(key) else {
                        rows.append(Self.cameraRow(camera, match: matches[camera.id], indent: 0))
                        visible.append(camera.id)
                        continue
                    }
                    let deviceID = "device.\(key)"
                    if emittedDevices.insert(key).inserted {
                        // The channel count is over the whole library rather than the matched
                        // subset, so the header keeps telling the truth about the device while a
                        // search narrows which of its channels are listed.
                        let channels = cameras.reduce(into: 0) { total, other in
                            if other.deviceKey == key { total += 1 }
                        }
                        rows.append(VSidebarRow(id: deviceID,
                                                kind: .device(key: key,
                                                              name: camera.deviceName ?? camera.host,
                                                              channelCount: channels)))
                    }
                    guard !collapsed.contains(deviceID) else { continue }
                    rows.append(Self.cameraRow(camera, match: matches[camera.id], indent: 1))
                    visible.append(camera.id)
                }
            }
        }

        // MARK: LIBRARY
        let libraryHeaderID = "section.library"
        rows.append(VSidebarRow(id: libraryHeaderID, kind: .sectionHeader(.library)))
        if !collapsed.contains(libraryHeaderID) {
            let badges: [VSidebarLibraryLink: Int?] = [
                .recordings: recordingCount,
                .events: eventBadge,
                .bookmarks: bookmarkCount,
            ]
            for link in VSidebarLibraryLink.allCases {
                rows.append(VSidebarRow(id: "library.\(link.rawValue)",
                                        kind: .libraryLink(link, badge: badges[link] ?? nil),
                                        selection: link.selection))
            }
        }

        self.rows = rows
        self.visibleCameras = visible
    }

    // MARK: - Private Helpers

    /// A camera row.
    private static func cameraRow(_ camera: VSidebarCamera,
                                  match: VSidebarMatch?,
                                  indent: Int) -> VSidebarRow {
        VSidebarRow(id: "camera.\(camera.id)",
                    kind: .camera(camera, match: match),
                    indent: indent,
                    selection: .camera(camera.id))
    }

    /// Device keys that two or more cameras share.
    ///
    /// A single-channel device gets no header: a disclosure triangle hiding one row is worse than no
    /// triangle at all.
    private static func multiChannelDeviceKeys(_ cameras: [VSidebarCamera]) -> Set<String> {
        var counts: [String: Int] = [:]
        for camera in cameras {
            guard let key = camera.deviceKey else { continue }
            counts[key, default: 0] += 1
        }
        return Set(counts.filter { $0.value >= 2 }.keys)
    }

    // MARK: - Navigation

    /// The camera after `camera` in display order, for `↓`.
    package func camera(after camera: CameraID) -> CameraID? {
        guard let index = visibleCameras.firstIndex(of: camera),
              index + 1 < visibleCameras.count else { return nil }
        return visibleCameras[index + 1]
    }

    /// The camera before `camera` in display order, for `↑`.
    package func camera(before camera: CameraID) -> CameraID? {
        guard let index = visibleCameras.firstIndex(of: camera), index > 0 else { return nil }
        return visibleCameras[index - 1]
    }

    /// Whether the tree is showing no cameras because the library is empty, as opposed to because a
    /// search excluded them all.
    ///
    /// The two need different empty states: an empty library invites discovery, a fruitless search
    /// offers to clear itself (UX.md §12.2, §4.4).
    package var isLibraryEmpty: Bool {
        visibleCameras.isEmpty && matchedCount == 0 && liveCount == 0 && degradedCount == 0
    }
}

#endif  // os(macOS)
