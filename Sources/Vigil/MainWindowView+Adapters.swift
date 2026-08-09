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

    // MARK: - The selected camera
    //
    // ⛔ THE PANELS DESCRIBE WHAT THE USER SELECTED, NOT WHAT `live` HAPPENS TO BE. Before
    // F-LIV-01 those were the same camera by construction and every panel simply read `session`.
    // With a wall of tiles they are routinely different, and an inspector that reported camera one's
    // codec, bitrate and packet loss under a heading naming camera nine is worse than an empty
    // panel: it is a confident wrong answer, and nothing on screen says so.
    //
    // ⚠️ The **bound** camera is still what the connect form, the remembered connection and the
    // sidebar's live row mean, so `identity`, `cameraID` and `tileStats` are untouched. Only the
    // panels move.

    /// The stream the panels describe: the sidebar's focused camera, or the bound one when the
    /// focus is on a row that is not a camera — "Current Layout", Events, Recordings.
    ///
    /// Falls back to ``AppSessionModel/live`` rather than to nothing, because the inspector is
    /// always showing *something* and an empty panel while a camera is plainly streaming reads as a
    /// fault.
    var selectedStream: CameraStream {
        guard let id = window.sidebarSelection.focus.selectedCamera,
              let stream = session.cameras.stream(for: id)
        else { return session.live }
        return stream
    }

    /// The record behind ``selectedStream``, or the library's row for a camera that has never
    /// streamed — selecting a camera that has never been connected must still fill the Info tab.
    var selectedCamera: Camera? {
        if let camera = selectedStream.camera { return camera }
        guard let id = window.sidebarSelection.focus.selectedCamera else { return session.camera }
        return library.cameras.first { $0.id == id } ?? session.camera
    }

    /// ``selectedCamera`` in the vocabulary the panels and the toolbar title take.
    var selectedIdentity: LiveCameraIdentity {
        let camera = selectedCamera
        return LiveCameraIdentity(id: camera?.id.rawValue ?? cameraID.rawValue,
                                  name: camera?.displayName ?? session.form.request.host,
                                  host: camera?.host ?? session.form.request.host,
                                  identityIndex: camera?.colorTag.paletteIndex)
    }

    /// The selected camera's telemetry.
    ///
    /// ``measuredTelemetry`` is sampled once a second for **every** filed stream, so this is a
    /// lookup rather than a second measurement. The bound camera's own snapshot is the fallback,
    /// which is what a selection on a non-camera row should show.
    var selectedTelemetry: StreamTelemetrySnapshot {
        guard let id = selectedCamera?.id, let sample = measuredTelemetry[id] else { return telemetry }
        return sample
    }

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
                     search: VSidebarSearch(query: window.searchText, filter: window.sidebarFilter),
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
                                  // ⚠️ `.disabled` means "not running", and it is the honest answer
                                  // only for a camera nothing has dialled — `.offline` claims a
                                  // connection was tried and lost, `.connecting` claims one is in
                                  // flight. A second stream can now say otherwise, so the row reads
                                  // that camera's own stream and falls back to "not running" when
                                  // there is none.
                                  status: storedRowStatus(of: camera))
        }
        // The live camera may not be in the library yet — it is not, until the legacy import lands
        // or the user adds it — and it must still appear.
        if !stored.contains(where: { $0.id == cameraID }) {
            rows.insert(sidebarCamera, at: 0)
        }
        return rows
    }

    /// What one stored row says about itself: its own stream's status, or "not running".
    ///
    /// ⚠️ Disabled wins over everything. A camera the user switched off is not offline and not
    /// connecting — it is a camera Vigil has been told to leave alone, and a row that showed it
    /// reconnecting would be reporting on a session that must not exist.
    private func storedRowStatus(of camera: Camera) -> VSidebarStatus {
        guard camera.isEnabled else { return .disabled }
        guard let stream = session.cameras.stream(for: camera.id), stream.isActive else {
            return .disabled
        }
        return Self.sidebarStatus(for: stream.liveState)
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
        if let preset = window.presetCameraOrder {
            let available = Set(library.cameras.map(\.id))
            let ordered = preset.filter { available.contains($0) }
            let remainder = library.cameras.map(\.id).filter { !ordered.contains($0) }
            return ordered + remainder
        }
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
    /// ⚠️ A camera with no stream is not `.offline`, and the distinction is the whole of this
    /// method's care. `.offline` claims an attempt was made and failed; a camera nobody has dialled
    /// has had nothing attempted, so it is drawn as `VGridIdleCell` — name, address, and a click
    /// that connects it — rather than as a tile wearing a failure it never had. `isStreaming` is
    /// what the stage keys that on, and it answers from the camera's **own** stream now rather than
    /// from "is this the one camera the app is driving".
    var stageCameras: [VStageCamera] {
        stageOrder.map { id in stageCamera(id) }
    }

    /// One camera's tile payload, read from its own stream.
    ///
    /// ⚠️ The bound camera is looked up as ``AppSessionModel/live`` rather than through the map, and
    /// that is not a shortcut — it is the connecting window. A first connect writes `resolving` on
    /// the stream *before* it has a camera record to file it under, so between the Return key and
    /// the record there is no map entry to find, and a tile drawn from the map alone would show
    /// *Not connected* over a session that is connecting. `cameraID` is the placeholder identity the
    /// tile already uses for exactly that gap.
    private func stageCamera(_ id: CameraID) -> VStageCamera {
        let stored = library.cameras.first { $0.id == id }
        let isBound = id == cameraID
        let stream = isBound ? session.live : session.cameras.stream(for: id)
        guard let stream, stream.isActive else {
            return VStageCamera(camera: LiveCameraIdentity(id: id.rawValue,
                                                           name: stored?.displayName ?? "",
                                                           host: stored?.host ?? "",
                                                           identityIndex: stored?.colorTag
                                                               .paletteIndex),
                                state: .offline(OfflineDetail()),
                                isStreaming: false)
        }
        // Recording is still the window's one recorder, so the badge belongs to the bound camera
        // and to no other — `F-CAP-03` is what makes it per camera.
        return VStageCamera(camera: isBound ? identity : streamIdentity(stream, stored: stored),
                            state: stream.liveState,
                            attemptStartedAt: stream.attemptStartedAt,
                            isRecording: isBound && recording.isRecording,
                            recordingElapsed: isBound ? recording.elapsed(now: recordingTick) : nil,
                            stats: tileStats(of: stream))
    }

    /// The name and colour a non-bound camera's tile carries.
    private func streamIdentity(_ stream: CameraStream, stored: Camera?) -> LiveCameraIdentity {
        let camera = stream.camera ?? stored
        return LiveCameraIdentity(id: (camera?.id ?? CameraID()).rawValue,
                                  name: camera?.displayName ?? "",
                                  host: camera?.host ?? "",
                                  identityIndex: camera?.colorTag.paletteIndex)
    }

    /// What the Stream tab's header describes — for the **selected** camera.
    var streamDescription: InspectorStreamDescription {
        guard let format = selectedStream.format else { return InspectorStreamDescription() }
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
    var tileStats: VTileStats? { tileStats(of: session.live) }

    /// The same pill, for whichever camera's tile is asking.
    func tileStats(of stream: CameraStream) -> VTileStats? {
        guard let format = stream.format else { return nil }
        let dimensions = format.resolution.map {
            FrameDimensions(width: $0.width, height: $0.height)
        }
        // Measured values win where they exist; the negotiated format fills the rest. A declared
        // frame rate is what the camera promised, a measured one is what arrived, and the tile
        // should show the second whenever it has been observed.
        let measured = stream.camera.flatMap { measuredTelemetry[$0.id] }
        return VTileStats(codec: format.videoCodec.rawValue.uppercased(),
                          dimensions: measured?.resolution ?? dimensions,
                          framesPerSecond: measured?.framesPerSecond ?? format.declaredFPS,
                          isHardwareDecode: true)
    }

    /// Reads every stream's collector once a second for as long as the window is on screen.
    ///
    /// ⚠️ Every stream, not the bound one. A tile's stats pill is a claim about the camera it is
    /// drawn over, and with a wall of them the pill on tile nine reporting tile one's frame rate
    /// would be worse than showing nothing.
    func pollTelemetry() async {
        while !Task.isCancelled {
            let now = session.dependencies.clock.now()
            // The deepest the frame backlog got in the last second, not its depth at this instant —
            // see `FrameBacklog.takePeak()` for why the instantaneous value is always zero.
            session.telemetry.noteDecodeQueueDepth(session.backlog.takePeak())
            session.telemetry.tick(at: now)
            telemetry = session.telemetry.telemetry(at: now)
            measuredTelemetry = sampleStreamTelemetry(at: now)
            IntentCameraIndex.update(library.cameras, streams: session.cameras,
                                     telemetry: measuredTelemetry)
            sampleProcessResources()
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
        }
    }

    /// One snapshot per camera with a stream, keyed by identity.
    ///
    /// The bound camera's collector has already been ticked by ``pollTelemetry()`` — it is the one
    /// the status bar reads — so it is sampled here but not ticked twice, which would halve every
    /// per-second rate it reports.
    private func sampleStreamTelemetry(at now: MediaInstant) -> [CameraID: StreamTelemetrySnapshot] {
        var snapshots: [CameraID: StreamTelemetrySnapshot] = [:]
        for stream in session.cameras.all {
            guard let id = stream.camera?.id else { continue }
            if stream !== session.live {
                stream.telemetry.noteDecodeQueueDepth(stream.backlog.takePeak())
                stream.telemetry.tick(at: now)
            }
            snapshots[id] = stream.telemetry.telemetry(at: now)
        }
        return snapshots
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
        guard let channel = selectedCamera?.channel else { return }
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

    /// The status bar's counters, over every camera Vigil is driving.
    ///
    /// ⚠️ The throughput is the **sum**, because the footer answers "what is this app pulling off
    /// the network" — a wall of four cameras at 4 Mb/s each is 16 Mb/s of traffic, and reporting one
    /// of them would make the number useless for the thing anyone reads it for.
    ///
    /// A stream that has not been filed yet is still connecting, so it shows no video and adds no
    /// bits: it cannot change either count, and needs no special case here.
    var chromeStatus: VChromeStatus {
        var live = 0
        var degraded = 0
        var bitsPerSecond: Double = 0
        for stream in session.cameras.all where stream.isActive {
            let state = stream.liveState
            if state.isShowingVideo { live += 1 }
            if Self.isDegraded(state) { degraded += 1 }
            if let id = stream.camera?.id, let measured = measuredTelemetry[id]?.bitsPerSecond {
                bitsPerSecond += measured
            }
        }
        return VChromeStatus(liveCount: live,
                             degradedCount: degraded,
                             throughput: VThroughput(bitsPerSecond: bitsPerSecond))
    }
}

#endif  // os(macOS)
