//
//  VSidebarView.swift
//  VigilUI
//
//  The main window's left panel: LIVE, GROUPS, CAMERAS and LIBRARY over a status footer. Every row
//  comes from ``VSidebarTree``, every highlight from ``VSidebarSelectionState``, and every string
//  from the module's own bundle — the view itself owns no state but hover.
//  The rows live in VSidebarRowView.swift and VSidebarChrome.swift, and everything they are drawn
//  from in SidebarPresentation.swift; the four files are one component split only for length.
//  macOS-only. Implements docs/UX.md §4.1 (fixed sections), §4.2, §4.3, §4.4 and §3.3 (footer),
//  with docs/DESIGN.md §9.12 (rows), §2.4 (the sidebar material) and §5.4 (hairlines).
//

#if os(macOS)

import Foundation

import SwiftUI

import VigilProtocols

// MARK: - VSidebarView

/// The sidebar.
///
/// ## Everything arrives; nothing is fetched
///
/// The view takes a built ``VSidebarTree``, a ``VSidebarSelectionState``, the active
/// ``VSidebarSearch`` and a set of collapsed row identifiers, and reports back through closures. It
/// starts no `Task`, reads no singleton and holds no reference to a library — which is what lets the
/// whole panel be rendered from a literal in a preview, including the states no test rig can
/// produce on demand (offline, connecting, packet loss).
///
/// ## Why this is a `ScrollView` and not a `List(selection:)`
///
/// UX.md §4.1 describes the sidebar as a `List` in `.sidebar` style. DESIGN.md §9.12 then specifies
/// a row surface a stock sidebar `List` will not give up: a 6 pt-radius accent-tinted fill inset
/// from the panel's edges, a 1 pt accent hairline, a distinct *inactive-window* fill, and a hover
/// fill on rows that are not selected. Producing that inside `List` means suppressing the system
/// selection highlight and its row insets and its separators, and fighting each of them
/// individually. A `ScrollView` over a `LazyVStack` renders §9.12 directly, keeps the lazy row
/// construction that matters at sixty cameras, and leaves selection where it already lives — in
/// ``VSidebarSelectionState``, which is tested. The one thing given up is the system's own
/// sidebar-list keyboard handling, which the window has to own anyway because ⌘-click, ⇧-click and
/// ⌥⌘↑/↓ are all outside a `List`'s repertoire.
@MainActor
package struct VSidebarView<Thumbnail: View>: View {

    // MARK: - Stored Properties

    /// Every row to draw, in order, already filtered and already counted.
    package let tree: VSidebarTree

    /// What is selected and where the keyboard is.
    package let selection: VSidebarSelectionState

    /// The active query and filter. Read only to choose between the two empty states — "you have
    /// no cameras" and "nothing matched" need different offers (UX.md §12.2, §4.4).
    package let search: VSidebarSearch

    /// Identifiers of collapsed sections, groups and devices. The same strings the tree uses as
    /// header row identifiers.
    package let collapsed: Set<String>

    /// The stage's current layout, which the LIVE row's glyph shows. `nil` draws the generic
    /// layout-picker glyph.
    package let layout: VGridLayout?

    /// Aggregate ingest across every camera, in bits per second, sampled at 1 Hz by whatever owns
    /// the streams (UX.md §3.3). `nil` omits the rate from the footer.
    package let aggregateBitsPerSecond: Double?

    /// Where an in-flight drag is proposing to land, or `nil` when nothing is being dragged.
    ///
    /// ``VSidebarDropPosition/between(index:)`` is read as an index into
    /// ``VSidebarTree/visibleCameras`` — `count` meaning "after the last one" — and
    /// ``VSidebarDropPosition/onGroup(index:)`` as the position of a group among the group rows.
    /// The arithmetic that produces either lives in ``VSidebarReorder``; this view only draws them.
    package let dropPosition: VSidebarDropPosition?

    /// A click on a row, with the modifiers that were held. Forward `.plain` to
    /// `VSidebarSelectionState.select`, `.toggle` to `toggle`, `.extend` to `extend`.
    package let onSelect: (VSidebarSelection, VSidebarClick) -> Void

    /// A double-click: open the row (UX.md §4.3 — assign the camera to the focused stage cell).
    package let onActivate: (VSidebarSelection) -> Void

    /// Collapses or expands the section, group or device with this row identifier.
    package let onToggleCollapse: (String) -> Void

    /// The GROUPS header's `＋`.
    package let onAddGroup: () -> Void

    /// The CAMERAS header's `＋`, which opens the add menu.
    package let onAddCamera: () -> Void

    /// The footer's gear.
    package let onOpenSettings: () -> Void

    /// *Clear Filters* in the no-results empty state.
    package let onClearSearch: () -> Void

    /// Commits a camera/group drag before the indicated item in its pre-move ordering.
    package let onMoveCamera: (CameraID, CameraID?) -> Void
    package let onMoveGroup: (GroupID, Int) -> Void
    package let onAssignCameraToGroup: (CameraID, GroupID) -> Void

    /// The right-click menu for one camera row, or an empty array for no menu.
    ///
    /// Data rather than a view builder — see ``VSidebarMenuItem``. An empty array attaches **no**
    /// context menu at all: an empty grey rectangle on right-click is worse than the system's own
    /// default, because it looks like the app tried and failed.
    package let cameraMenu: (VSidebarCamera) -> [VSidebarMenuItem]

    /// The right-click menu for one group row. Same contract.
    package let groupMenu: (VSidebarGroup) -> [VSidebarMenuItem]

    let motionSamples: (CameraID) -> [Double]
    let thumbnail: (VSidebarCamera) -> Thumbnail

    @Environment(\.displayScale) var displayScale
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency

    // MARK: - Initialisation

    /// Creates the sidebar.
    ///
    /// - Parameters:
    ///   - motionSamples: motion intensity per 15 s bucket for a camera, oldest first, `0…1`.
    ///     Defaults to silence, which draws the 1 pt baseline UX.md §4.2 requires rather than a gap.
    ///   - cameraMenu: the right-click menu for a camera row. Empty for none.
    ///   - groupMenu: the right-click menu for a group row. Empty for none.
    ///   - thumbnail: the micro-thumbnail's picture for one camera. Mounted in every state,
    ///     including offline, so the last known frame is there to dim (DESIGN.md §3.6 clause 6).
    package init(tree: VSidebarTree,
                 selection: VSidebarSelectionState,
                 search: VSidebarSearch = VSidebarSearch(),
                 collapsed: Set<String> = [],
                 layout: VGridLayout? = nil,
                 aggregateBitsPerSecond: Double? = nil,
                 dropPosition: VSidebarDropPosition? = nil,
                 onSelect: @escaping (VSidebarSelection, VSidebarClick) -> Void = { _, _ in },
                 onActivate: @escaping (VSidebarSelection) -> Void = { _ in },
                 onToggleCollapse: @escaping (String) -> Void = { _ in },
                 onAddGroup: @escaping () -> Void = {},
                 onAddCamera: @escaping () -> Void = {},
                 onOpenSettings: @escaping () -> Void = {},
                 onClearSearch: @escaping () -> Void = {},
                 onMoveCamera: @escaping (CameraID, CameraID?) -> Void = { _, _ in },
                 onMoveGroup: @escaping (GroupID, Int) -> Void = { _, _ in },
                 onAssignCameraToGroup: @escaping (CameraID, GroupID) -> Void = { _, _ in },
                 cameraMenu: @escaping (VSidebarCamera) -> [VSidebarMenuItem] = { _ in [] },
                 groupMenu: @escaping (VSidebarGroup) -> [VSidebarMenuItem] = { _ in [] },
                 motionSamples: @escaping (CameraID) -> [Double] = { _ in [] },
                 @ViewBuilder thumbnail: @escaping (VSidebarCamera) -> Thumbnail) {
        self.tree = tree
        self.selection = selection
        self.search = search
        self.collapsed = collapsed
        self.layout = layout
        self.aggregateBitsPerSecond = aggregateBitsPerSecond
        self.dropPosition = dropPosition
        self.onSelect = onSelect
        self.onActivate = onActivate
        self.onToggleCollapse = onToggleCollapse
        self.onAddGroup = onAddGroup
        self.onAddCamera = onAddCamera
        self.onOpenSettings = onOpenSettings
        self.onClearSearch = onClearSearch
        self.onMoveCamera = onMoveCamera
        self.onMoveGroup = onMoveGroup
        self.onAssignCameraToGroup = onAssignCameraToGroup
        self.cameraMenu = cameraMenu
        self.groupMenu = groupMenu
        self.motionSamples = motionSamples
        self.thumbnail = thumbnail
    }

    // MARK: - View

    package var body: some View {
        // Computed once per structural update rather than per row: resolving
        // `onGroup(index:)` inside the row builder would make it quadratic.
        let ordinals = VSidebarDrop.groupOrdinals(tree.rows)
        VStack(spacing: 0) {
            scroller(ordinals: ordinals)
            hairline(VTheme.Color.Stroke.subtle)
            VSidebarFooterView(liveCount: tree.liveCount,
                               degradedCount: tree.degradedCount,
                               bitsPerSecond: aggregateBitsPerSecond,
                               onOpenSettings: onOpenSettings)
        }
        .background { panelBackground }
        .overlay(alignment: .trailing) { trailingEdge }
        .frame(minWidth: VTheme.Metrics.sidebarMin,
               idealWidth: VTheme.Metrics.sidebarWidth,
               maxWidth: VTheme.Metrics.sidebarMax,
               maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Rows

    private func scroller(ordinals: [GroupID: Int]) -> some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(tree.rows) { row in
                    rowView(row, ordinals: ordinals)
                }
                Color.clear
                    .frame(height: VTheme.Space.sm)
                    .onDrop(of: [.text], delegate: VSidebarRowDropDelegate { value in
                        if let camera = VSidebarDraggedID.camera(from: value) {
                            onMoveCamera(camera, nil)
                        } else if let group = VSidebarDraggedID.group(from: value) {
                            onMoveGroup(group, (ordinals.values.max() ?? -1) + 1)
                        }
                    })
            }
            .padding(.horizontal, VTheme.Space.sm)
            .padding(.vertical, VTheme.Space.sm)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func rowView(_ row: VSidebarRow, ordinals: [GroupID: Int]) -> some View {
        switch row.kind {
        case .sectionHeader(let section):
            sectionHeader(section, rowID: row.id)
        case .layout:
            layoutRow()
        case .group(let group, let memberCount):
            groupRow(group, memberCount: memberCount, ordinal: ordinals[group.id])
                .onDrag { NSItemProvider(object: "group:\(group.id)" as NSString) }
                .onDrop(of: [.text], delegate: VSidebarRowDropDelegate {
                    if let camera = VSidebarDraggedID.camera(from: $0) {
                        onAssignCameraToGroup(camera, group.id)
                    } else if let source = VSidebarDraggedID.group(from: $0),
                              let index = ordinals[group.id] {
                        onMoveGroup(source, index)
                    }
                })
        case .device(let key, let name, let channelCount):
            deviceRow(key: key, name: name, channelCount: channelCount, indent: row.indent)
        case .camera(let camera, let match):
            cameraRow(camera, match: match, indent: row.indent)
                .onDrag { NSItemProvider(object: "camera:\(camera.id)" as NSString) }
                .onDrop(of: [.text], delegate: VSidebarRowDropDelegate {
                    guard let source = VSidebarDraggedID.camera(from: $0) else { return }
                    onMoveCamera(source, camera.id)
                })
        case .libraryLink(let link, let badge):
            libraryRow(link, badge: badge)
        case .emptyNotice(let section):
            emptyNotice(section)
        }
    }
}

private enum VSidebarDraggedID {
    static func camera(from value: String) -> CameraID? {
        parse(value, prefix: "camera:").map(CameraID.init)
    }

    static func group(from value: String) -> GroupID? {
        parse(value, prefix: "group:").map(GroupID.init)
    }

    private static func parse(_ value: String, prefix: String) -> UUID? {
        guard value.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(value.dropFirst(prefix.count)))
    }
}

private struct VSidebarRowDropDelegate: DropDelegate {
    let commit: (String) -> Void

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let value = object as? String else { return }
            Task { @MainActor in commit(value) }
        }
        return true
    }
}

#if DEBUG

/// A stand-in picture, so the previews read as camera frames rather than as black boxes.
@MainActor
private func vSidebarPreviewPicture(_ camera: VSidebarCamera) -> some View {
    LinearGradient(colors: [VSidebarIdentity.colour(for: camera).opacity(0.55),
                            VTheme.Color.Layer.videoWell],
                   startPoint: .top,
                   endPoint: .bottom)
}

/// A repeatable motion trace: derived from the identifier's characters rather than from
/// `hashValue`, which is seeded per process and would redraw differently on every launch.
private func vSidebarPreviewMotion(_ id: CameraID, buckets: Int) -> [Double] {
    let seed = id.short.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
    return (0..<Swift.max(0, buckets)).map { index in
        Double((index &* 7 &+ seed) % 11) / 10.0
    }
}

/// The cameras of the approved mockup, plus the two states it has no room for — a camera the
/// user switched off, and one whose password was rejected.
private func vSidebarPreviewCameras() -> [VSidebarCamera] {
    [
        VSidebarCamera(id: CameraID(), name: "Front Door", host: "192.168.1.64",
                       identityIndex: 0, status: .live, codec: "H.265",
                       resolutionLabel: "1080p", isRecording: true),
        VSidebarCamera(id: CameraID(), name: "Garage", host: "192.168.1.65",
                       identityIndex: 1, status: .live, codec: "H.264",
                       resolutionLabel: "720p"),
        VSidebarCamera(id: CameraID(), name: "Lobby", host: "192.168.1.66",
                       identityIndex: 2, status: .connecting(progress: 0.62)),
        VSidebarCamera(id: CameraID(), name: "Back Yard", host: "192.168.1.67",
                       identityIndex: 3, status: .live, codec: "H.265",
                       resolutionLabel: "1080p", isSubStream: true),
        VSidebarCamera(id: CameraID(), name: "Side Gate", host: "192.168.1.68",
                       identityIndex: 5,
                       status: .degraded(.packetLoss(fraction: 0.031))),
        VSidebarCamera(id: CameraID(), name: "Hallway", host: "192.168.1.69",
                       identityIndex: 4, status: .offline(retryInSeconds: 8)),
        VSidebarCamera(id: CameraID(), name: "Store Room", host: "192.168.1.70",
                       identityIndex: 1, isEnabled: false, status: .disabled),
        VSidebarCamera(id: CameraID(), name: "Server Rack", host: "192.168.1.71",
                       identityIndex: 3, status: .authFailed),
    ]
}

private func vSidebarPreviewGroups() -> [VSidebarGroup] {
    [
        VSidebarGroup(id: GroupID(), name: "Perimeter", identityIndex: 0),
        VSidebarGroup(id: GroupID(), name: "Indoors", identityIndex: 1),
        VSidebarGroup(id: GroupID(), name: "Gate", identityIndex: 5),
    ]
}

/// The shape of a camera row's menu, so right-clicking one in a preview shows the real thing.
///
/// Every action is a no-op here: the panel reports gestures and owns none of them, and a preview
/// that renamed something would need a store the module deliberately does not have.
private func vSidebarPreviewCameraMenu(_ camera: VSidebarCamera,
                                       groups: [VSidebarGroup]) -> [VSidebarMenuItem] {
    var memberships = groups.map { group in
        VSidebarMenuItem(id: "group.\(group.id)",
                         title: group.name,
                         isOn: camera.groupID == group.id,
                         action: {})
    }
    memberships.append(.separator(id: "group.rule"))
    memberships.append(VSidebarMenuItem(id: "group.none", title: "None", action: {}))
    return [
        VSidebarMenuItem(id: "rename", title: "Rename…", symbol: .rename, action: {}),
        .submenu(id: "assign", title: "Add to Group", symbol: .group, memberships),
        VSidebarMenuItem(id: "bookmark", title: "Bookmark This Moment…",
                         symbol: .bookmark, action: {}),
        .separator(id: "rule"),
        VSidebarMenuItem(id: "copy", title: "Copy Address", symbol: .copy, action: {}),
        VSidebarMenuItem(id: "remove", title: "Remove Camera",
                         symbol: .delete, role: .destructive, action: {}),
    ]
}

/// The shape of a group row's menu.
private func vSidebarPreviewGroupMenu(_ group: VSidebarGroup) -> [VSidebarMenuItem] {
    [
        VSidebarMenuItem(id: "rename", title: "Rename…", symbol: .rename, action: {}),
        .separator(id: "rule"),
        VSidebarMenuItem(id: "delete", title: "Delete “\(group.name)”",
                         symbol: .delete, role: .destructive, action: {}),
    ]
}

/// A host for the previews.
///
/// It exists so each `#Preview` body stays a **single expression**: the macro's closure is a
/// `@ViewBuilder`, which accepts local `let`s but not an explicit `return`, and keeping the body
/// to one expression is correct either way. It also holds the cameras in stored properties, so the
/// identifiers — and therefore the identity colours and the motion traces — are stable across the
/// body evaluations a preview performs.
@MainActor
private struct VSidebarPreviewHost: View {

    var cameras: [VSidebarCamera] = vSidebarPreviewCameras()
    var groups: [VSidebarGroup] = vSidebarPreviewGroups()
    var search = VSidebarSearch()
    var layout: VGridLayout? = .mosaic4x3
    var bitrate: Double? = 1_800_000_000
    var drop: VSidebarDropPosition? = nil
    var selectsFirst = true
    var height: CGFloat = 760

    var tree: VSidebarTree {
        VSidebarTree(cameras: cameras,
                     groups: groups,
                     search: search,
                     eventBadge: 12,
                     recordingCount: 41,
                     bookmarkCount: 3)
    }

    var selection: VSidebarSelectionState {
        guard selectsFirst, let first = cameras.first else { return VSidebarSelectionState() }
        return VSidebarSelectionState(focus: .camera(first.id),
                                      cameras: [first.id],
                                      anchor: first.id)
    }

    var body: some View {
        VPulseClock {
            VSidebarView(tree: tree,
                         selection: selection,
                         search: search,
                         layout: layout,
                         aggregateBitsPerSecond: bitrate,
                         dropPosition: drop,
                         cameraMenu: { camera in vSidebarPreviewCameraMenu(camera, groups: groups) },
                         groupMenu: { group in vSidebarPreviewGroupMenu(group) },
                         motionSamples: { id in
                             vSidebarPreviewMotion(id, buckets: VSidebarMetrics.sparkBuckets)
                         },
                         thumbnail: { camera in vSidebarPreviewPicture(camera) })
        }
        .frame(width: VTheme.Metrics.sidebarWidth, height: height)
        .background(VTheme.Color.Layer.canvas)
    }
}

#Preview("Sidebar — populated") {
    VSidebarPreviewHost()
}

#Preview("Sidebar — empty library") {
    VSidebarPreviewHost(cameras: [],
                        groups: [],
                        layout: .grid2x2,
                        bitrate: nil,
                        selectsFirst: false,
                        height: 420)
}

#Preview("Sidebar — no search results") {
    VSidebarPreviewHost(search: VSidebarSearch(query: "zzz"),
                        layout: .grid3x3,
                        bitrate: 4_200_000,
                        selectsFirst: false,
                        height: 460)
}

#Preview("Sidebar — drop between rows") {
    VSidebarPreviewHost(layout: .single,
                        bitrate: 820_000,
                        drop: .between(index: 2),
                        selectsFirst: false)
}

#endif
#endif  // os(macOS)
