//
//  MainWindowView.swift
//  Vigil
//
//  The assembled main window: toolbar, camera list, tile stage, inspector, status bar. The one place
//  the single-camera session model is adapted into the shapes the `VigilUI` screens expect.
//  macOS-only. See design/mockups/01-main-window.html and docs/UX.md.
//

#if os(macOS)

import AppKit
import Foundation
import SwiftUI

import VigilCore
import VigilProtocols
import VigilRender
import VigilUI

// MARK: - MainWindowView

/// The window around the picture.
///
/// **What this file is and is not.** Every screen here was written against a multi-camera library;
/// the session model beneath it drives exactly one camera, because that is what `.vigil/SLICE.md`
/// scoped. So this view is an *adapter*: it presents the one live camera as a one-element library, and
/// the panels neither know nor care. Nothing here fakes a second camera — an empty cell is drawn as an
/// empty cell.
///
/// That shape is deliberate. When the multi-camera model lands, the change is to the four computed
/// properties below that build `VSidebarTree`, `VStageAssignment`, `VInspectorState` and
/// `VChromeStatus` — not to any of the screens, which already take collections.
struct MainWindowView: View {

    // MARK: - Stored Properties

    /// The streaming session. Owns the controller and everything that can fail.
    @Bindable var session: AppSessionModel

    /// Window furniture: what is shown, what is selected, what is being searched.
    @Bindable var window: MainWindowState

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            VToolbarView(isSidebarVisible: window.isSidebarVisible,
                         isInspectorVisible: window.isInspectorVisible,
                         layout: window.layout,
                         searchText: $window.searchText,
                         showsSeparator: true,
                         onToggleSidebar: { window.isSidebarVisible.toggle() },
                         onToggleInspector: { window.isInspectorVisible.toggle() },
                         onSelectLayout: { window.layout = $0 })

            HStack(spacing: 0) {
                if window.isSidebarVisible {
                    sidebar
                        .frame(width: VTheme.Metrics.sidebarWidth)
                }

                stage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if window.isInspectorVisible {
                    VInspectorView(tab: $window.inspectorTab,
                                   state: inspectorState,
                                   actions: inspectorActions)
                        .frame(width: VTheme.Metrics.inspectorWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Only when the list is hidden. `VSidebarView` draws its own footer carrying the same
            // counters (UX.md §3.3), and the mockup puts the status inside the sidebar column rather
            // than across the window — so showing both stacked two status lines on top of each other.
            // The bar is kept for the collapsed case, where the sidebar's footer goes with it.
            if !window.isSidebarVisible {
                VStatusBarView(status: chromeStatus)
            }
        }
        .background(VTheme.Color.Layer.canvas)
        .overlay(alignment: .bottom) { toastOverlay }
    }

    // MARK: - Panels

    /// The camera list, presenting the single session camera as a one-element library.
    private var sidebar: some View {
        VSidebarView(tree: sidebarTree,
                     selection: window.sidebarSelection,
                     search: VSidebarSearch(query: window.searchText),
                     collapsed: window.collapsedRows,
                     layout: window.layout,
                     aggregateBitsPerSecond: nil,
                     onSelect: { selection, _ in window.sidebarSelection.select(selection) },
                     onToggleCollapse: { rowID in
                         if window.collapsedRows.contains(rowID) {
                             window.collapsedRows.remove(rowID)
                         } else {
                             window.collapsedRows.insert(rowID)
                         }
                     },
                     onClearSearch: { window.searchText = "" },
                     thumbnail: { _ in Color.clear })
    }

    /// The tile stage.
    ///
    /// The video closure is where `VigilRender` enters, exactly as it did in the pre-window build:
    /// every callback and the logger are named explicitly, because each one has a default that
    /// compiles and reports nothing, which is the "no video, no error" shape this project refuses.
    private var stage: some View {
        VGridStageView(assignment: stageAssignment,
                       cameras: stageCameras,
                       selection: cameraID,
                       onRetry: { _ in session.perform(.retry) },
                       onRemedy: { _, remedy in session.perform(remedy) },
                       video: { _ in
                           VideoTile(cameraID: cameraID,
                                     frames: session.frames,
                                     logger: session.dependencies.logger,
                                     onKeyframeNeeded: { session.recoverStalledPicture() },
                                     onDecodeFailure: { session.handleDecodeFailure($0) },
                                     onFramesDropped: { session.handleFramesDropped($0, reason: $1) })
                       })
    }

    /// The advisory banner, when there is one.
    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = window.toast {
            VToastView(kind: toast.kind,
                       message: Text(verbatim: toast.message),
                       actionTitle: toast.actionTitle,
                       width: nil,
                       onAction: { toast.action?() },
                       onDismiss: { window.toast = nil })
                .padding(.bottom, VTheme.Space.xl)
        }
    }

    // MARK: - Session → panel adapters

    /// The library as the sidebar sees it: one camera, no groups.
    private var sidebarTree: VSidebarTree {
        VSidebarTree(cameras: [sidebarCamera],
                     search: VSidebarSearch(query: window.searchText),
                     collapsed: window.collapsedRows,
                     now: Date())
    }

    /// The session camera as a sidebar row.
    private var sidebarCamera: VSidebarCamera {
        VSidebarCamera(id: cameraID,
                       name: identity.name,
                       host: identity.host,
                       status: Self.sidebarStatus(for: session.liveState))
    }

    /// One cell, holding the one camera.
    private var stageAssignment: VStageAssignment {
        VStageAssignment(layout: window.layout, cameras: [cameraID])
    }

    /// The session camera as a stage tile.
    private var stageCameras: [VStageCamera] {
        [VStageCamera(camera: identity,
                      state: session.liveState,
                      attemptStartedAt: session.attemptStartedAt)]
    }

    /// What the inspector shows.
    ///
    /// Only the fields the slice can actually answer are set. The rest keep their defaults, so a
    /// panel renders its own "not available" treatment rather than a fabricated number — the same
    /// reason `stats:` is left off the stage tile above.
    private var inspectorState: VInspectorState {
        VInspectorState(camera: identity,
                        connection: session.liveState,
                        now: Date(),
                        identity: deviceIdentity)
    }

    /// The address half of the Info tab.
    ///
    /// Only the fields the app already holds: host, ports, channel and TLS come from the `Camera`
    /// record, or from the typed request before that record exists. Model, firmware, serial, MAC and
    /// uptime stay empty and render as `—`, because they arrive from the ISAPI device-info endpoint
    /// and the single-camera slice never calls it. An empty identity was why the Info tab showed a
    /// bare `:554` — the port with no host in front of it.
    private var deviceIdentity: InspectorDeviceIdentity {
        let camera = session.camera
        return InspectorDeviceIdentity(channel: camera?.channel ?? .first,
                                       host: camera?.host ?? session.form.request.host,
                                       rtspPort: camera?.rtspPort ?? 554,
                                       httpPort: camera?.httpPort ?? 80,
                                       usesTLS: camera?.useTLS ?? false)
    }

    /// The inspector buttons the slice can actually honour.
    ///
    /// Three of the six. `onRunStreamDoctor` and `onRetryDevice` need the diagnosis sequence and the
    /// ISAPI reboot endpoint respectively, and `onCopySerial` needs a serial to copy — none of which
    /// the single-camera slice has. They keep their no-op defaults rather than being given something
    /// approximate, because a button that does *nearly* the right thing is worse than one that
    /// visibly does nothing.
    private var inspectorActions: VInspectorActions {
        var actions = VInspectorActions()
        actions.onOpenWebPage = { openDeviceWebPage() }
        actions.onRequestKeyframe = { session.recoverStalledPicture() }
        actions.onReconnect = { session.perform(.retry) }
        return actions
    }

    /// Opens the camera's own web interface in the default browser.
    ///
    /// Built from the same host and HTTP port the inspector shows, so the two cannot disagree. A host
    /// that will not form a URL — empty, before a connection — simply does nothing rather than
    /// force-unwrapping into a crash.
    private func openDeviceWebPage() {
        let identity = deviceIdentity
        guard !identity.host.isEmpty else { return }
        var components = URLComponents()
        components.scheme = identity.usesTLS ? "https" : "http"
        components.host = identity.host
        components.port = identity.httpPort
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// The status bar's counters.
    private var chromeStatus: VChromeStatus {
        VChromeStatus(liveCount: session.liveState.isShowingVideo ? 1 : 0,
                      degradedCount: Self.isDegraded(session.liveState) ? 1 : 0,
                      throughput: .unmeasured)
    }

    // MARK: - Identity

    /// Name, address and identity colour for the one camera.
    private var identity: LiveCameraIdentity {
        let camera = session.camera
        return LiveCameraIdentity(id: cameraID.rawValue,
                                  name: camera?.displayName ?? session.form.request.host,
                                  host: camera?.host ?? session.form.request.host)
    }

    /// The camera's identifier, or the stable placeholder the tile keeps before the record exists.
    private var cameraID: CameraID {
        session.camera?.id ?? RootView.pendingCameraID
    }

    // MARK: - Mapping

    /// Whether the stream is impaired but still showing a picture.
    ///
    /// `LiveConnectionState` offers `isConnecting` and `isShowingVideo` but no "degraded" question,
    /// because every screen that needed one so far pattern-matched the cause to say *what* is wrong.
    /// The status bar only needs the count, so it asks here rather than growing the shared type.
    private static func isDegraded(_ state: LiveConnectionState) -> Bool {
        if case .degraded = state { return true }
        return false
    }

    /// Restates a connection state in the sidebar's vocabulary.
    ///
    /// The two enumerations were written independently and their impairment cases line up one for
    /// one, which is not a coincidence — both come from `docs/DESIGN.md` §9. The mapping is spelled
    /// out rather than bridged automatically so that a case added to one and not the other fails to
    /// compile here, at the seam, instead of silently picking a wrong badge.
    private static func sidebarStatus(for state: LiveConnectionState) -> VSidebarStatus {
        switch state {
        case .connecting:
            return .connecting(progress: nil)
        case .live:
            return .live
        case .degraded(let cause):
            switch cause {
            case .packetLoss(let fraction):
                return .degraded(.packetLoss(fraction: fraction))
            case .jitter(let milliseconds):
                return .degraded(.jitter(milliseconds: milliseconds))
            case .decodeQueue(let frames):
                return .degraded(.decodeQueue(frames: frames))
            case .lowFrameRate(let fps, _):
                return .degraded(.lowFrameRate(fps: fps))
            case .switchedToTCP:
                return .degraded(.switchedToTCP)
            }
        case .offline:
            return .offline(retryInSeconds: nil)
        }
    }
}

#endif  // os(macOS)
