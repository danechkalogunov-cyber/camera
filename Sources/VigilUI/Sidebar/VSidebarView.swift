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

    /// The right-click menu for one camera row, or an empty array for no menu.
    ///
    /// Data rather than a view builder — see ``VSidebarMenuItem``. An empty array attaches **no**
    /// context menu at all: an empty grey rectangle on right-click is worse than the system's own
    /// default, because it looks like the app tried and failed.
    package let cameraMenu: (VSidebarCamera) -> [VSidebarMenuItem]

    /// The right-click menu for one group row. Same contract.
    package let groupMenu: (VSidebarGroup) -> [VSidebarMenuItem]

    private let motionSamples: (CameraID) -> [Double]
    private let thumbnail: (VSidebarCamera) -> Thumbnail

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
        case .device(let key, let name, let channelCount):
            deviceRow(key: key, name: name, channelCount: channelCount, indent: row.indent)
        case .camera(let camera, let match):
            cameraRow(camera, match: match, indent: row.indent)
        case .libraryLink(let link, let badge):
            libraryRow(link, badge: badge)
        case .emptyNotice(let section):
            emptyNotice(section)
        }
    }

    // MARK: Section headers

    private func sectionHeader(_ section: VSidebarSection, rowID: String) -> some View {
        VSidebarSectionHeader(title: sectionTitle(section),
                              isCollapsible: section.isCollapsible,
                              isCollapsed: collapsed.contains(rowID),
                              addSymbol: addSymbol(for: section),
                              addLabel: addLabel(for: section),
                              badge: sectionBadge(for: section),
                              onToggle: { onToggleCollapse(rowID) },
                              onAdd: { addAction(for: section) })
            .padding(.top, section == .live ? VTheme.Space.hair : VTheme.Space.sm)
    }

    private func sectionTitle(_ section: VSidebarSection) -> Text {
        switch section {
        case .live: return Text("Live", bundle: .vigilUI)
        case .groups: return Text("Groups", bundle: .vigilUI)
        case .cameras: return Text("Cameras", bundle: .vigilUI)
        case .library: return Text("Library", bundle: .vigilUI)
        }
    }

    private func addSymbol(for section: VSidebarSection) -> VTheme.Symbol? {
        switch section {
        case .groups: return .newGroup
        case .cameras: return .addCamera
        case .live, .library: return nil
        }
    }

    private func addLabel(for section: VSidebarSection) -> LocalizedStringKey {
        section == .groups ? "New Group" : "Add Camera"
    }

    private func addAction(for section: VSidebarSection) {
        switch section {
        case .groups: onAddGroup()
        case .cameras: onAddCamera()
        case .live, .library: break
        }
    }

    /// Only CAMERAS carries a count, and only while a search is narrowing the list — that is the
    /// moment "how many of my cameras am I looking at" is a question (UX.md §4.4). At rest the
    /// header is bare, as the approved mockup draws it.
    private func sectionBadge(for section: VSidebarSection) -> String? {
        guard section == .cameras, search.isActive else { return nil }
        return tree.matchedCount.formatted(.number)
    }

    // MARK: LIVE

    private func layoutRow() -> some View {
        VSidebarLinkRow(title: Text("Current Layout", bundle: .vigilUI),
                        symbol: layoutSymbol,
                        symbolTint: VTheme.Color.Semantic.accent,
                        isSelected: selection.isFocused(.live),
                        isFocused: selection.isFocused(.live),
                        onSelect: { click in onSelect(.live, click) },
                        onActivate: { onActivate(.live) })
    }

    /// The layout glyph.
    ///
    /// An SF Symbol rather than DESIGN.md §8.3's drawn `VLayoutGlyph` miniature, because that type
    /// belongs to the toolbar's layout picker and does not exist in this slice. §8.3 sanctions the
    /// symbol cases for exactly this situation — a place where the drawn glyph is unavailable.
    private var layoutSymbol: VTheme.Symbol {
        guard let mode = layout else { return .layoutPicker }
        switch mode {
        case .single: return .layoutSingle
        case .grid2x2: return .layout2x2
        case .grid3x3: return .layout3x3
        case .grid4x4: return .layout4x4
        case .hero1p5, .hero1p7, .dual2p8, .mosaic4x3: return .layoutPicker
        }
    }

    // MARK: GROUPS

    private func groupRow(_ group: VSidebarGroup, memberCount: Int, ordinal: Int?) -> some View {
        VSidebarLinkRow(title: Text(verbatim: group.name),
                        tagColour: VSidebarIdentity.colour(for: group),
                        tagInitial: VSidebarIdentity.initial(of: group.name),
                        badge: memberCount.formatted(.number),
                        isSelected: selection.isFocused(.group(group.id)),
                        isFocused: selection.isFocused(.group(group.id)),
                        isDropTarget: VSidebarDrop.targetsGroup(dropPosition,
                                                               ordinal: ordinal),
                        onSelect: { click in onSelect(.group(group.id), click) },
                        onActivate: { onActivate(.group(group.id)) })
            .modifier(VSidebarRowMenu(items: groupMenu(group)))
    }

    // MARK: CAMERAS

    private func deviceRow(key: String,
                           name: String,
                           channelCount: Int,
                           indent: Int) -> some View {
        let rowID = "device.\(key)"
        return VSidebarLinkRow(title: Text(verbatim: name),
                               symbol: .device,
                               badge: channelCount.formatted(.number),
                               indent: indent,
                               onSelect: { _ in onToggleCollapse(rowID) },
                               onActivate: { onToggleCollapse(rowID) })
    }

    private func cameraRow(_ camera: VSidebarCamera,
                           match: VSidebarMatch?,
                           indent: Int) -> some View {
        VSidebarRowView(camera: camera,
                        match: match,
                        isSelected: selection.isSelected(camera.id),
                        isFocused: selection.isFocused(.camera(camera.id)),
                        indent: indent,
                        motionSamples: motionSamples(camera.id),
                        onSelect: { click in onSelect(.camera(camera.id), click) },
                        onActivate: { onActivate(.camera(camera.id)) },
                        thumbnail: { thumbnail(camera) })
            .overlay(alignment: .top) {
                insertionLine(visible: dropEdge(camera) == .above)
            }
            .overlay(alignment: .bottom) {
                insertionLine(visible: dropEdge(camera) == .below)
            }
            .modifier(VSidebarRowMenu(items: cameraMenu(camera)))
    }

    // MARK: LIBRARY

    private func libraryRow(_ link: VSidebarLibraryLink, badge: Int?) -> some View {
        VSidebarLinkRow(title: libraryTitle(link),
                        badge: badge.map { $0.formatted(.number) },
                        badgeTint: link == .events
                            ? VTheme.Color.Semantic.motion
                            : VTheme.Color.Text.tertiary,
                        isSelected: selection.isFocused(link.selection),
                        isFocused: selection.isFocused(link.selection),
                        onSelect: { click in onSelect(link.selection, click) },
                        onActivate: { onActivate(link.selection) })
    }

    private func libraryTitle(_ link: VSidebarLibraryLink) -> Text {
        switch link {
        case .recordings: return Text("Recordings", bundle: .vigilUI)
        case .events: return Text("Events", bundle: .vigilUI)
        case .bookmarks: return Text("Bookmarks", bundle: .vigilUI)
        }
    }

    // MARK: Empty notices

    /// The muted row a section shows instead of disappearing (UX.md §4.1).
    ///
    /// CAMERAS has two of them and they are not interchangeable: an empty library invites the user
    /// to add a camera, while a fruitless search offers to undo itself (UX.md §12.2).
    private func emptyNotice(_ section: VSidebarSection) -> some View {
        VStack(alignment: .leading, spacing: VTheme.Space.xs) {
            emptyText(section)
                .vType(VTheme.Typography.caption1)
                .foregroundStyle(VTheme.Color.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            clearFiltersButton(section)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, VTheme.Space.xs)
        .padding(.vertical, VTheme.Space.xxs)
        .frame(minHeight: VTheme.Metrics.Row.settings, alignment: .leading)
    }

    private func emptyText(_ section: VSidebarSection) -> Text {
        switch section {
        case .groups:
            return Text("No groups — drag cameras together to make one", bundle: .vigilUI)
        case .live, .cameras, .library:
            return search.isActive
                ? Text("No cameras match your search", bundle: .vigilUI)
                : Text("No cameras yet", bundle: .vigilUI)
        }
    }

    @ViewBuilder
    private func clearFiltersButton(_ section: VSidebarSection) -> some View {
        if section == .cameras, search.isActive {
            VButton("Clear Filters", style: .secondary, size: .sm, action: onClearSearch)
        }
    }

    // MARK: - Drop indicators

    /// Which edge of `camera`'s row the insertion line goes on, if either. The reading of a
    /// ``VSidebarDropPosition`` is in ``VSidebarDrop``, where it is tested.
    private func dropEdge(_ camera: VSidebarCamera) -> VSidebarDrop.Edge? {
        VSidebarDrop.edge(for: dropPosition, camera: camera.id, in: tree.visibleCameras)
    }

    /// A 2 pt accent line with round caps, inset 12 pt (DESIGN.md §9.12).
    @ViewBuilder
    private func insertionLine(visible: Bool) -> some View {
        if visible {
            Capsule()
                .fill(VTheme.Color.Semantic.accent)
                .frame(height: VTheme.Border.selected)
                .padding(.horizontal, VSidebarMetrics.dropLineInset)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Chrome

    /// `.sidebar`, behind the window, following its active state — the placement DESIGN.md §2.4
    /// sanctions, with the solid fallback under `reduceTransparency`.
    @ViewBuilder
    private var panelBackground: some View {
        if reduceTransparency {
            VTheme.Color.Layer.sidebarFallback
        } else {
            VVisualEffect(material: .sidebar,
                          blending: .behindWindow,
                          state: .followsWindowActiveState)
        }
    }

    /// A true one-pixel rule, never `Divider()` — its colour and inset are not ours (§5.4).
    private func hairline(_ colour: SwiftUI.Color) -> some View {
        Rectangle()
            .fill(colour)
            .frame(height: VTheme.Border.hairline(displayScale))
    }

    private var trailingEdge: some View {
        Rectangle()
            .fill(VTheme.Color.Stroke.default)
            .frame(width: VTheme.Border.hairline(displayScale))
            .allowsHitTesting(false)
    }
}

// MARK: - Previews

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

    private var tree: VSidebarTree {
        VSidebarTree(cameras: cameras,
                     groups: groups,
                     search: search,
                     eventBadge: 12,
                     recordingCount: 41,
                     bookmarkCount: 3)
    }

    private var selection: VSidebarSelectionState {
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
