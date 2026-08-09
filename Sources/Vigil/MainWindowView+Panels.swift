//
//  MainWindowView+Panels.swift
//  Vigil
//
//  Sidebar, routed stage, thumbnails, and toast surfaces split from MainWindowView.
//

#if os(macOS)

import AppKit
import SwiftUI
import VigilUI

extension MainWindowView {

    /// A visible half-duplex state and live microphone level while the key/button is held.
    @ViewBuilder
    var talkingOverlay: some View {
        if session.twoWayAudio.isTalking {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Talking", bundle: .vigilUI).font(.caption.weight(.semibold))
                GeometryReader { proxy in
                    Capsule().fill(.white.opacity(0.22))
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white).frame(
                                width: proxy.size.width
                                    * CGFloat(min(1, session.twoWayAudio.inputLevel * 5)))
                        }
                }
                .frame(width: 56, height: 4)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.red.opacity(0.88), in: Capsule())
            .padding(.top, 10)
            .allowsHitTesting(false)
        }
    }
    // MARK: - Panels

    /// The camera list, presenting the single session camera as a one-element library.
    var sidebar: some View {
        VSidebarView(tree: sidebarTree,
                     selection: window.sidebarSelection,
                     search: VSidebarSearch(query: window.searchText, filter: window.sidebarFilter),
                     collapsed: window.collapsedRows,
                     layout: window.layout,
                     aggregateBitsPerSecond: telemetry.bitsPerSecond,
                     onSelect: { selection, click in selectInSidebar(selection, click) },
                     onActivate: { selection in activateInSidebar(selection) },
                     onToggleCollapse: { rowID in
                         if window.collapsedRows.contains(rowID) {
                             window.collapsedRows.remove(rowID)
                         } else {
                             window.collapsedRows.insert(rowID)
                         }
                     },
                     onAddGroup: { window.sheet = .newGroup },
                     onAddCamera: { addCamera() },
                     // The gear in the sidebar footer drew itself and answered to nothing.
                     onOpenSettings: { window.sheet = .cameraSettings },
                     onClearSearch: { window.searchText = "" },
                     onMoveCamera: { id, target in
                         let destination = target.flatMap { target in
                             library.cameras.firstIndex(where: { $0.id == target })
                         } ?? library.cameras.count
                         Task { await library.move(id, before: destination) }
                     },
                     onMoveGroup: { id, destination in groups.move(id, to: destination) },
                     onAssignCameraToGroup: { camera, group in
                         groups.setGroup(group, for: camera)
                     },
                     cameraMenu: { camera in cameraMenu(camera) },
                     groupMenu: { group in groupMenu(group) },
                     thumbnail: { _ in cameraThumbnail })
    }

    /// The sidebar row's miniature of what the camera sees.
    ///
    /// The camera's own JPEG, not a scaled-down video frame: this app's decode path is passthrough
    /// and never produces a pixel buffer to scale — see `DeviceInfoService.poster`. Falls back to
    /// the video-well colour before the first snapshot lands and while a camera is offline.
    @ViewBuilder
    var cameraThumbnail: some View {
        if let poster = deviceInfo.poster {
            Image(decorative: poster, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            VTheme.Color.Layer.videoWell
        }
    }

    /// What the centre of the window shows.
    ///
    /// The stage is a router (UX.md §5.9): selecting Recordings, Events or Bookmarks in the sidebar
    /// replaces the tiles *inside this window* rather than opening anything. `VLibrarySection`'s
    /// failable initialiser is the whole decision — it answers `nil` for the live selections, which
    /// is exactly the "stay on the tiles" case.
    ///
    /// Without this, the three LIBRARY rows changed the selection and nothing else, which is what
    /// made the screens behind them look absent.
    @ViewBuilder
    var stageRoute: some View {
        if let section = VLibrarySection(window.sidebarSelection.focus) {
            VLibraryScreen(section: section, state: libraryState, actions: libraryActions)
        } else {
            stage
        }
    }

    /// Whether what is under the toolbar scrolls, which is the only case DESIGN.md §11.2 draws the
    /// toolbar's hairline in. The three library screens scroll; the tile stage does not.
    var stageScrolls: Bool {
        VLibrarySection(window.sidebarSelection.focus) != nil
    }

    /// The advisory banner, when there is one.
    @ViewBuilder
    var toastOverlay: some View {
        if let toast = window.toast {
            VToastView(kind: toast.kind,
                       message: Text(verbatim: toast.message),
                       actionTitle: toast.actionTitle,
                       width: nil,
                       onAction: { toast.action?() },
                       // The library's notice is cleared with the toast, not left behind: it is
                       // `Equatable` state on an `@Observable`, so an identical message arriving
                       // later would not read as a change and the second recovery would be silent.
                       onDismiss: {
                           window.toast = nil
                           library.dismissNotice()
                       })
                .padding(.bottom, VTheme.Space.xl)
        }
    }

    /// A short, non-modal look at the camera that just raised an alert.
    ///
    /// If its stream is already running this is a second presentation of the same frame source —
    /// not a second decoder. Cameras without a live stream use the JPEG paired with the alert, so
    /// the preview is still useful without silently starting a network session. The renderer itself
    /// is never clipped, faded or shadowed; those effects would force the display layer off its
    /// direct composition path.
    @ViewBuilder
    var eventPreviewOverlay: some View {
        if let preview = eventFeed.preview {
            VStack(alignment: .leading, spacing: VTheme.Space.sm) {
                Group {
                    if session.cameras.stream(for: preview.cameraID)?.isActive == true
                        || (preview.cameraID == cameraID && session.live.isActive) {
                        stageVideo(for: preview.cameraID)
                    } else if let url = preview.thumbnailURL,
                              let image = NSImage(contentsOf: url) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .clipped()
                    } else {
                        VTheme.Color.Layer.videoWell
                    }
                }
                .frame(width: 280, height: 158)

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preview.cameraName).font(.callout.weight(.semibold))
                        Text(preview.eventLabel)
                            .font(.caption)
                            .foregroundStyle(VTheme.Color.Text.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: VTheme.Space.md)
                    Text("View Live", bundle: .vigilUI)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(VTheme.Color.Semantic.accent)
                }
            }
            .padding(VTheme.Space.sm)
            .background(VTheme.Color.Layer.surfaceRaised)
            .contentShape(Rectangle())
            .onTapGesture {
                window.sidebarSelection.select(.camera(preview.cameraID))
                eventFeed.dismissPreview()
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .padding(.top, VTheme.Space.lg)
            .padding(.trailing, VTheme.Space.lg)
        }
    }


}

#endif  // os(macOS)
