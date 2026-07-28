//
//  MainWindowView+Adapters.swift
//  Vigil
//
//  The adapters: one live session presented as the collections the VigilUI screens expect, plus
//  the polls that keep them current.
//  macOS-only. Split from MainWindowView.swift, which docs/DESIGN.md §7.2 caps at 600 lines.
//

#if os(macOS)

import Foundation
import SwiftUI

import VigilCore
import VigilProtocols
import VigilUI

// MARK: - Session → panel adapters

/// This is the seam the file's own header describes: when the multi-camera model lands, these are
/// the properties that change, and none of the screens do.
///
/// ⚠️ `internal` rather than `private`, for the reason given in `MainWindowView+Library.swift`:
/// `private` reaches a type's extensions only within one file.
extension MainWindowView {

    /// The library as the sidebar sees it: one camera, and whatever groups the user has made.
    var sidebarTree: VSidebarTree {
        VSidebarTree(cameras: [sidebarCamera],
                     groups: groups.groups.map {
                         VSidebarGroup(id: $0.id, name: $0.name, identityIndex: $0.identityIndex)
                     },
                     search: VSidebarSearch(query: window.searchText),
                     collapsed: window.collapsedRows,
                     eventBadge: eventFeed.unreadCount > 0 ? eventFeed.unreadCount : nil,
                     recordingCount: window.clips.isEmpty ? nil : window.clips.count,
                     bookmarkCount: bookmarks.bookmarks.isEmpty ? nil : bookmarks.bookmarks.count,
                     now: Date())
    }

    /// The session camera as a sidebar row.
    var sidebarCamera: VSidebarCamera {
        VSidebarCamera(id: cameraID,
                       name: identity.name,
                       host: identity.host,
                       // Derived from the group store rather than stored on the camera: `Camera` is
                       // rebuilt from the remembered host on every launch, so a `groupID` on it
                       // would be gone by the next start.
                       groupID: groups.group(for: cameraID),
                       status: Self.sidebarStatus(for: session.liveState),
                       serial: deviceInfo.identity.serialNumber)
    }

    /// One cell, holding the one camera — unless a group is selected that it is not in.
    ///
    /// Selecting a group opens it into the stage (UX.md §1.3), and this build has one camera, so
    /// there are exactly two honest outcomes: the camera is in the group and the stage shows it, or
    /// it is not and the stage shows an empty cell. Showing the camera regardless would make the
    /// GROUPS section decorative.
    var stageAssignment: VStageAssignment {
        if case .group(let group) = window.sidebarSelection.focus,
           groups.group(for: cameraID) != group {
            return VStageAssignment(layout: window.layout, cameras: [])
        }
        return VStageAssignment(layout: window.layout, cameras: [cameraID])
    }

    /// The session camera as a stage tile.
    var stageCameras: [VStageCamera] {
        [VStageCamera(camera: identity,
                      state: session.liveState,
                      attemptStartedAt: session.attemptStartedAt,
                      isRecording: recording.isRecording,
                      recordingElapsed: recording.elapsed(now: recordingTick),
                      stats: tileStats)]
    }

    /// What the Stream tab's header describes.
    var streamDescription: InspectorStreamDescription {
        guard let format = session.format else { return InspectorStreamDescription() }
        return InspectorStreamDescription(
            codec: format.videoCodec.rawValue.uppercased(),
            pixelWidth: format.resolution?.width ?? 0,
            pixelHeight: format.resolution?.height ?? 0,
            streamInUse: Self.qualityLabel(format.quality),
            transport: format.transport.rawValue,
            targetFramesPerSecond: format.declaredFPS ?? 0)
    }

    /// The stream's name as the panel shows it.
    ///
    /// `StreamQuality` is `Int`-backed — `main = 1` — so its raw value is a channel-arithmetic
    /// number, not a label. Spelling it out here keeps the panel from printing "1".
    static func qualityLabel(_ quality: StreamQuality) -> String {
        switch quality {
        case .main:  return "Main"
        case .sub:   return "Sub"
        case .third: return "Third"
        }
    }

    /// The tile's telemetry pill.
    ///
    /// Only the codec and the geometry, which the negotiated format already answers — bitrate and
    /// frame rate need `StreamStatisticsCollector`, which is written but not yet fed. `nil` before
    /// the DESCRIBE lands, which also hides the pill's REC badge, so the badge is not the only
    /// signal that a clip is running: the elapsed counter at the bottom of the tile is unconditional.
    var tileStats: VTileStats? {
        guard let format = session.format else { return nil }
        let dimensions = format.resolution.map {
            FrameDimensions(width: $0.width, height: $0.height)
        }
        // Measured values win where they exist; the negotiated format fills the rest. A declared
        // frame rate is what the camera promised, a measured one is what arrived, and the tile
        // should show the second whenever it has been observed.
        return VTileStats(codec: format.videoCodec.rawValue.uppercased(),
                          dimensions: telemetry.resolution ?? dimensions,
                          framesPerSecond: telemetry.framesPerSecond ?? format.declaredFPS,
                          isHardwareDecode: true)
    }

    /// Reads the collector once a second for as long as the window is on screen.
    func pollTelemetry() async {
        while !Task.isCancelled {
            let now = session.dependencies.clock.now()
            // The deepest the frame backlog got in the last second, not its depth at this instant —
            // see `FrameBacklog.takePeak()` for why the instantaneous value is always zero.
            session.telemetry.noteDecodeQueueDepth(session.backlog.takePeak())
            session.telemetry.tick(at: now)
            telemetry = session.telemetry.telemetry(at: now)
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
        }
    }

    /// Refreshes the sidebar's thumbnail from the camera every few seconds.
    ///
    /// Five seconds, not one: this is an HTTP round trip to the device for a picture 40 pt wide, and
    /// asking faster would put load on the camera in exchange for nothing a viewer would notice.
    func pollPoster() async {
        guard let channel = session.camera?.channel else { return }
        while !Task.isCancelled {
            await deviceInfo.refreshPoster(channel: channel)
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
        }
    }

    /// Redraws once a second for as long as a clip is being written.
    func tickWhileRecording() async {
        while !Task.isCancelled, recording.isRecording {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            recordingTick = Date()
        }
    }

    /// The status bar's counters.
    var chromeStatus: VChromeStatus {
        VChromeStatus(liveCount: session.liveState.isShowingVideo ? 1 : 0,
                      degradedCount: Self.isDegraded(session.liveState) ? 1 : 0,
                      throughput: telemetry.throughput)
    }
}

#endif  // os(macOS)
