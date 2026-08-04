//
//  MainWindowView+Adapters.swift
//  Vigil
//
//  The adapters: one live session presented as the collections the VigilUI screens expect, plus
//  the polls that keep them current.
//  macOS-only. Split from MainWindowView.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
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

    /// The library as the sidebar sees it: every camera the user has added, and their groups.
    ///
    /// ⚠️ The live one is *substituted*, not appended. It carries the status, the codec, the frame
    /// rate and the recording flag, none of which exist on a stored record — so the row for the
    /// camera currently on screen has to be the session's row, and every other row is the stored
    /// one at rest. Appending instead would show the same camera twice, once live and once idle,
    /// which is exactly the confusion this list exists to remove.
    ///
    /// Before the library has loaded, or when it is empty, this is the single session row it always
    /// was. A window that flashed an empty sidebar at a user who has cameras would be worse than
    /// one that shows the camera it is already streaming.
    var sidebarTree: VSidebarTree {
        VSidebarTree(cameras: sidebarCameras,
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

    /// Every row: the live camera as itself, the rest as stored.
    var sidebarCameras: [VSidebarCamera] {
        let stored = library.cameras
        guard !stored.isEmpty else { return [sidebarCamera] }
        var rows = stored.map { camera -> VSidebarCamera in
            guard camera.id != cameraID else { return sidebarCamera }
            return VSidebarCamera(id: camera.id,
                                  name: camera.displayName,
                                  host: camera.host,
                                  groupID: groups.group(for: camera.id),
                                  identityIndex: camera.colorTag.paletteIndex,
                                  isEnabled: camera.isEnabled,
                                  // ⚠️ `.disabled` for every stored row, including enabled ones.
                                  // `.offline` claims a connection was tried and lost, and
                                  // `.connecting` claims one is in flight; neither is true — this
                                  // build runs one stream, so a camera that is not it has had
                                  // nothing attempted. Saying "not running" is the only honest
                                  // option until a second stream exists to say otherwise.
                                  status: .disabled)
        }
        // The live camera may not be in the library yet — it is not, until the legacy import lands
        // or the user adds it — and it must still appear.
        if !stored.contains(where: { $0.id == cameraID }) {
            rows.insert(sidebarCamera, at: 0)
        }
        return rows
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

    /// The layout, filled from ``stageOrder``.
    ///
    /// ⚠️ The doc that used to sit here described a stage of exactly one cell holding exactly one
    /// camera, and it survived the change that made this the whole library — a stale comment on a
    /// rewritten body, which is worse than none, because it reads as a decision rather than as an
    /// oversight. ``stageOrder`` now carries the reasoning, including what a selected group does.
    var stageAssignment: VStageAssignment {
        VStageAssignment(layout: window.layout, cameras: stageOrder)
    }

    /// Which cameras belong on the stage, in the order the cells take them.
    ///
    /// ⛔ The whole library, not just the one that is streaming. The stage used to hold exactly one
    /// camera, so a user with four cameras and a 2 × 2 layout saw one picture beside three *Add
    /// camera* placeholders — offering to add cameras they had already added. The sidebar listed all
    /// four the entire time, which is what made it read as breakage rather than as capacity.
    ///
    /// The streaming camera leads, because it is the one with a picture and the eye should not have
    /// to hunt for it. The rest follow in library order.
    ///
    /// A selected group narrows this to its members (UX.md §1.3): selecting a group opens it into
    /// the stage, and a group that showed every camera would make the GROUPS section decorative.
    /// ⚠️ The rule itself lives in `VigilUI.VStageOrder`, not here. It was written inline in this
    /// file and shipped with a latent crash — a sort comparator that is not a strict weak ordering —
    /// which reading caught and no test could have, because the app target has no test bundle. This
    /// property is now the seam that supplies the group store; the ordering is tested next door.
    var stageOrder: [CameraID] {
        var selectedGroup: GroupID?
        if case .group(let group) = window.sidebarSelection.focus { selectedGroup = group }
        return VStageOrder.resolve(library: library.cameras.map { $0.id },
                                   live: cameraID,
                                   isInSelectedGroup: selectedGroup.map { group in
                                       { camera in groups.group(for: camera) == group }
                                   })
    }

    /// One tile payload per camera on the stage.
    ///
    /// ⚠️ Exactly one of them carries a session. `isStreaming` is false for every other camera, so
    /// the stage draws `VGridIdleCell` rather than a tile whose `LiveConnectionState` would have to
    /// lie — `.offline` claims an attempt was made and failed, and nothing has been attempted for a
    /// camera this build has not dialled. Clicking one switches the session to it, which is the
    /// honest meaning of "show me this camera" while there is one decode pipeline.
    var stageCameras: [VStageCamera] {
        stageOrder.map { id in
            guard id == cameraID else {
                let stored = library.cameras.first { $0.id == id }
                return VStageCamera(camera: LiveCameraIdentity(id: id.rawValue,
                                                               name: stored?.displayName ?? "",
                                                               host: stored?.host ?? ""),
                                    state: .offline(OfflineDetail()),
                                    isStreaming: false)
            }
            return VStageCamera(camera: identity,
                                state: session.liveState,
                                attemptStartedAt: session.attemptStartedAt,
                                isRecording: recording.isRecording,
                                recordingElapsed: recording.elapsed(now: recordingTick),
                                stats: tileStats)
        }
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
            sampleProcessResources()
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
        }
    }

    /// Reads this process's CPU and memory, and logs them once a minute.
    ///
    /// **Once a minute, not once a second.** The sample is taken every second because CPU is a
    /// difference and needs a short interval to mean anything; the *log line* is rare because sixty
    /// of them a minute would push everything else out of a field capture, and the whole reason
    /// this exists is to be readable in a log somebody sends back.
    ///
    /// Logged at `.info` on the `perf` category so `Scripts/run.sh --category perf` shows the
    /// resource trace and nothing else.
    private func sampleProcessResources() {
        guard let sample = resources.sampler.sample() else { return }
        resources.latest = sample
        resources.ticks &+= 1
        guard resources.ticks % 60 == 0 else { return }
        session.dependencies.logger.info(.perf, "process: \(sample.label)")
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
