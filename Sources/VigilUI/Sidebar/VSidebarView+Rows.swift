//
//  VSidebarView+Rows.swift
//  VigilUI
//
//  Each section of the list — live, groups, cameras, library — and the drop indicators between them.
//  Split from VSidebarView.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

#if os(macOS)

import Foundation
import SwiftUI
import VigilProtocols

// MARK: - The sections

/// ⚠️ Members are `internal`, not `private`: Swift scopes `private` to one file.
/// `Scripts/lint.py`'s `split-access` rule fails the build on any left behind.
extension VSidebarView {

    // MARK: Section headers

    func sectionHeader(_ section: VSidebarSection, rowID: String) -> some View {
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

    func layoutRow() -> some View {
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

    func groupRow(_ group: VSidebarGroup, memberCount: Int, ordinal: Int?) -> some View {
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

    func deviceRow(key: String,
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

    func cameraRow(_ camera: VSidebarCamera,
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

    func libraryRow(_ link: VSidebarLibraryLink, badge: Int?) -> some View {
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
    func emptyNotice(_ section: VSidebarSection) -> some View {
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
    var panelBackground: some View {
        if reduceTransparency {
            VTheme.Color.Layer.sidebarFallback
        } else {
            VVisualEffect(material: .sidebar,
                          blending: .behindWindow,
                          state: .followsWindowActiveState)
        }
    }

    /// A true one-pixel rule, never `Divider()` — its colour and inset are not ours (§5.4).
    func hairline(_ colour: SwiftUI.Color) -> some View {
        Rectangle()
            .fill(colour)
            .frame(height: VTheme.Border.hairline(displayScale))
    }

    var trailingEdge: some View {
        Rectangle()
            .fill(VTheme.Color.Stroke.default)
            .frame(width: VTheme.Border.hairline(displayScale))
            .allowsHitTesting(false)
    }
}

// MARK: - Previews

#endif  // os(macOS)
