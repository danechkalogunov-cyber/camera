//
//  MainWindowView+Inspector.swift
//  Vigil
//
//  The window's right-hand panel: what it shows, and every action it offers — snapshot, PTZ,
//  stream quality, picture settings, diagnostics.
//  macOS-only. Split from MainWindowView.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

#if os(macOS)

import AVFoundation
import AppKit
import CoreMedia
import Foundation
import SwiftUI

import VigilCore
import VigilProtocols
import VigilRender
import VigilUI

// MARK: - The inspector

/// ⚠️ `internal` rather than `private`, for the reason given in `MainWindowView+Library.swift`:
/// `private` reaches a type's extensions only within one file.
extension MainWindowView {

    func updateCameraTransport(_ transport: RTSPTransportKind) {
        guard var camera = selectedStream.camera else { return }
        guard camera.transport != transport else { return }
        camera.transport = transport
        camera.lastWorkingTransport = nil
        selectedStream.camera = camera
        let id = camera.id
        let controller = selectedStream.controller
        Task {
            await library.setTransport(transport, for: id)
            await controller?.setCamera(camera)
        }
    }

    /// Begins the selected camera's capability-vetted half-duplex talk session.
    func beginPushToTalk() {
        guard let camera = selectedCamera else { return }
        session.twoWayAudio.begin(camera: camera, deviceInfo: deviceInfo, appSession: session)
    }

    /// What the inspector shows.
    ///
    /// Only the fields the slice can actually answer are set. The rest keep their defaults, so a
    /// panel renders its own "not available" treatment rather than a fabricated number — the same
    /// reason `stats:` is left off the stage tile above.
    var inspectorState: VInspectorState {
        VInspectorState(camera: selectedIdentity,
                        connection: selectedStream.liveState,
                        now: Date(),
                        identity: deviceIdentity,
                        storage: deviceInfo.storage,
                        isDeviceLoading: deviceInfo.isLoading,
                        isDeviceUnavailable: deviceInfo.isUnavailable,
                        stream: streamDescription,
                        statistics: selectedTelemetry.statistics,
                        recentStatistics: selectedTelemetry.recentStatistics,
                        ptz: ptz.capability,
                        presets: ptz.presets,
                        patrols: ptz.patrols,
                        runningPatrol: ptz.runningPatrol,
                        image: selectedCamera.flatMap { localImageAdjustments.settings(for: $0.id) }
                            ?? deviceInfo.image ?? InspectorImageSettings(),
                        events: inspectorEvents,
                        recording: recordingState)
    }

    /// The camera's alerts, as the Events tab reads them.
    ///
    /// ⛔ This argument was simply never passed. `VInspectorEventsTab` is written, `InspectorEvent`
    /// is written, `EventCoordinator` has been filling the sidebar's badge and the Events *screen*
    /// from the same feed the whole time — and the tab defaulted to `[]`, so the panel rendered its
    /// empty state on a camera that was reporting motion.
    ///
    /// Capped, because this is a side panel and not the Events screen: the tab is a glance at what
    /// just happened, the screen is the record. Reading the whole feed into a 320 pt column would
    /// also rebuild the array on every body evaluation, which is once a second while telemetry ticks.
    var inspectorEvents: [InspectorEvent] {
        eventFeed.events.prefix(Self.inspectorEventLimit).map { event in
            InspectorEvent(id: event.id,
                           instant: event.occurredAt,
                           kind: event.kind,
                           label: event.label,
                           duration: event.durationSeconds)
        }
    }

    /// How many alerts the inspector's Events tab shows. UX.md §6.2 calls it a recent list.
    static let inspectorEventLimit = 50

    /// The address half of the Info tab.
    ///
    /// Only the fields the app already holds: host, ports, channel and TLS come from the `Camera`
    /// record, or from the typed request before that record exists. Model, firmware, serial, MAC and
    /// uptime stay empty and render as `—`, because they arrive from the ISAPI device-info endpoint
    /// and the single-camera slice never calls it. An empty identity was why the Info tab showed a
    /// bare `:554` — the port with no host in front of it.
    var deviceIdentity: InspectorDeviceIdentity {
        // Whatever the device answered. `DeviceInfoService.load` publishes the address half
        // immediately and fills in model, firmware, serial, MAC and uptime when the reply lands, so
        // this is correct before the request completes and richer after it.
        deviceInfo.identity
    }

    /// The inspector buttons the slice can actually honour.
    ///
    /// Three of the six. `onRunStreamDoctor` and `onRetryDevice` need the diagnosis sequence and the
    /// ISAPI reboot endpoint respectively, and `onCopySerial` needs a serial to copy — none of which
    /// the single-camera slice has. They keep their no-op defaults rather than being given something
    /// approximate, because a button that does *nearly* the right thing is worse than one that
    /// visibly does nothing.
    var inspectorActions: VInspectorActions {
        var actions = VInspectorActions()
        actions.onOpenWebPage = { openDeviceWebPage() }
        actions.onRequestKeyframe = { session.recoverStalledPicture() }
        actions.onReconnect = { session.perform(.retry) }
        actions.onRetryDevice = { deviceInfo.retry() }
        actions.onToggleRecording = { toggleRecording() }
        actions.onCopySerial = { copySerial() }
        actions.onImageSettings = { settings in writeImage(settings) }
        actions.onResetImage = { resetImage() }
        actions.onPTZ = { action in performPTZ(action) }
        actions.onPTZNudge = { vector in ptz.nudge(vector) }
        actions.onPTZHome = { ptz.home() }
        actions.onPTZFocus = { velocity in ptz.focus(velocity) }
        actions.onPTZIris = { velocity in ptz.iris(velocity) }
        actions.onPTZGoToPreset = { number in ptz.goToPreset(number) }
        actions.onPTZSavePreset = { number in ptz.savePreset(number) }
        actions.onPTZDeletePreset = { number in ptz.deletePreset(number) }
        actions.onPTZStartPatrol = { number in ptz.startPatrol(number) }
        actions.onPTZStopPatrol = { number in ptz.stopPatrol(number) }
        actions.onRevealRecordings = { openRecordingsFolder() }
        actions.onCopyDiagnostics = { copyDiagnostics() }
        actions.onCycleStream = { cycleStreamQuality() }
        // The same act as clicking the row on the Events screen: bring the scrubber up on that day
        // with the playhead five seconds early (UX.md §9.1). Routed through the one function so the
        // two surfaces cannot drift apart about what "open this event" means.
        actions.onOpenEvent = { event in openArchive(at: event.instant) }
        actions.onSwapTransport = {
            let current = selectedStream.format?.transport
                ?? selectedCamera?.lastWorkingTransport
                ?? selectedCamera?.transport
                ?? .tcpInterleaved
            let next: RTSPTransportKind = current.isUDP ? .tcpInterleaved : .udpUnicast
            updateCameraTransport(next)
            window.toast = MainWindowToast(kind: .info,
                                           message: Self.localized(next.isUDP
                                               ? "Switching this camera to UDP…"
                                               : "Switching this camera to TCP…"))
        }
        actions.onRunStreamDoctor = { runStreamDoctor() }
        return actions
    }

    /// Takes a still of the **selected** camera and says where it went.
    ///
    /// Safe to point at any camera, unlike recording: a snapshot is one ISAPI request for a JPEG and
    /// needs no session of its own. Recording does, which is why the Rec tab is still the bound
    /// camera's — see `recordingState`.
    func takeSnapshot(intentRequestID: UUID? = nil) {
        guard let camera = selectedCamera else {
            if let intentRequestID {
                IntentSnapshotBridge.fail(intentRequestID, reason: "No camera is selected.")
            }
            window.toast = MainWindowToast(kind: .warning,
                                           message: Self.localized("Connect a camera first"))
            return
        }
        Task {
            switch await snapshots.capture(camera: camera,
                                           client: deviceInfo.client,
                                           model: deviceInfo.identity.model) {
            case .saved(let url):
                if let intentRequestID { IntentSnapshotBridge.complete(intentRequestID, url: url) }
                window.toast = MainWindowToast(
                    kind: .success,
                    message: Self.localized("Snapshot saved"),
                    actionTitle: "Reveal in Finder",
                    action: { NSWorkspace.shared.activateFileViewerSelecting([url]) })
            case .failed(let reason):
                if let intentRequestID { IntentSnapshotBridge.fail(intentRequestID, reason: reason) }
                window.toast = MainWindowToast(
                    kind: .error,
                    message: String(format: Self.localized("The snapshot could not be taken: %@"),
                                    reason))
            }
        }
    }

    /// Puts a quick plain-text summary on the pasteboard. The complete, redacted support archive is
    /// the separate File ▸ Export Diagnostics command; keeping this instant copy action is useful
    /// for chat while avoiding an unexpected save panel from an inspector button named “Copy”.
    func copyDiagnostics() {
        let device = deviceInfo.identity
        let stats = telemetry.statistics
        let lines = [
            "Vigil diagnostics",
            "camera:     \(selectedIdentity.name)",
            "address:    \(device.host):\(device.httpPort) (RTSP \(device.rtspPort))",
            "model:      \(device.model.isEmpty ? "—" : device.model)",
            "firmware:   \(device.firmwareVersion.isEmpty ? "—" : device.firmwareVersion)",
            "serial:     \(device.serialNumber.isEmpty ? "—" : device.serialNumber)",
            "state:      \(String(describing: session.liveState))",
            "codec:      \(session.format.map { String(describing: $0.videoCodec) } ?? "—")",
            "bitrate:    \(Int(stats.bitsPerSecond)) bit/s",
            "fps:        \(stats.framesPerSecond)",
            "loss:       \(stats.lossFraction * 100)%",
            "jitter:     \(stats.jitterMilliseconds) ms",
            "decode q:   \(stats.decodeQueueDepth)",
        ]
        copyToPasteboard(lines.joined(separator: "\n"))
        window.toast = MainWindowToast(kind: .success,
                                       message: Self.localized("Diagnostics copied"))
    }

    /// Switches the live stream between the main and the sub stream.
    ///
    /// A reconnect, not a negotiation: `StreamController` resolves the quality when the session
    /// starts, so the only way to change it is to build a new session. The picture drops for as long
    /// as a normal reconnect takes, which is why this says so rather than appearing to stall.
    func cycleStreamQuality() {
        guard var camera = selectedCamera else { return }
        let next: StreamQuality = camera.preferredQuality == .sub ? .main : .sub
        camera.preferredQuality = next
        // ⚠️ Written onto the stream that is actually showing this camera, which is `live` only when
        // the selection is the bound camera. Writing `session.camera` unconditionally would have
        // changed the quality of a different camera than the panel names, and then restarted that
        // one — a control that visibly does the wrong thing to the wrong tile.
        let stream = selectedStream
        stream.camera = camera
        session.cameras.file(stream)
        window.toast = MainWindowToast(
            kind: .info,
            message: next == .sub
                ? Self.localized("Switching to the sub-stream — the picture will reconnect")
                : Self.localized("Switching to the main stream — the picture will reconnect"))
        session.retryCamera(camera.id)
    }

    /// Turns the pad's hold state into a movement command.
    ///
    /// Both stop cases go to the same call. `InspectorPTZHold` distinguishes a release from the
    /// eight-second safety expiry so the *panel* can say which happened; the camera is stopped the
    /// same way either way, and routing them differently would be two paths to one outcome.
    func performPTZ(_ action: InspectorPTZHoldAction) {
        switch action {
        case .none:                 break
        case .start(let vector):    ptz.move(vector)
        case .stop, .stopExpired:   ptz.stop()
        }
    }

    /// Points the PTZ coordinator at the device once there is a session to ask.
    ///
    /// Keyed on ``deviceInfoReady`` rather than on the camera: the ISAPI session is built by
    /// `DeviceInfoService.load`, so following the camera id would run this before there was
    /// anything to follow and the PTZ tab would stay empty until something else invalidated it.
    ///
    /// ⚠️ The **selected** camera's channel. The PTZ tab is part of the inspector, so it describes
    /// and drives whatever the inspector is describing; pointing a pan command at the bound camera
    /// while the panel above it names another one is the worst kind of wrong — it moves a real
    /// motor on the wrong device.
    func followPTZ() {
        ptz.follow(session: deviceInfo.session, channel: selectedCamera?.channel)
    }

    /// What decides the PTZ probe is worth running: a session exists, and for which camera.
    var deviceInfoReady: String {
        "\(selectedCamera?.id.rawValue.uuidString ?? "-")/\(deviceInfo.session == nil ? 0 : 1)"
    }

    /// Puts the device's serial on the pasteboard.
    ///
    /// The full value, not the masked one the row shows: masking exists so a serial does not end up
    /// in a screenshot, and someone who pressed Copy is asking for the number itself.
    func copySerial() {
        let serial = deviceInfo.identity.serialNumber
        guard !serial.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(serial, forType: .string)
    }

    /// Hands the panel's picture controls to the writer.
    ///
    /// Deliberately not a `Task`. `DeviceInfoService.writeImage` returns immediately — it publishes
    /// the value so the control follows the pointer, and schedules the write for once the control
    /// has stopped moving. Wrapping it here would only add a hop before that.
    func writeImage(_ settings: InspectorImageSettings) {
        guard let camera = selectedCamera else { return }
        if settings.isLocalPreviewOnly {
            let local: InspectorImageSettings
            if localImageAdjustments.settings(for: camera.id) == nil,
               deviceInfo.image?.isLocalPreviewOnly != true {
                local = localImageAdjustments.reset(camera.id)
            } else {
                local = settings
                localImageAdjustments.save(local, for: camera.id)
            }
            deviceInfo.publishLocalImagePreview(local)
            return
        }
        if localImageAdjustments.settings(for: camera.id) != nil {
            localImageAdjustments.remove(camera.id)
            deviceInfo.endLocalImagePreview()
            return
        }
        let channel = camera.channel
        deviceInfo.writeImage(channel: channel, settings)
    }

    func localTileAdjustments(for cameraID: CameraID) -> TileColorAdjustments {
        localImageAdjustments.adjustments(for: cameraID)
    }

    /// Puts the camera's picture back to its factory settings, and says what happened.
    ///
    /// The reset is a `PUT` to the camera, so it can be refused — by a firmware without the
    /// endpoint, by an account without the permission, or by a device that is simply not reachable
    /// at that moment. Every one of those used to be a log line and nothing else, which is why the
    /// button read as broken: the press produced no picture change and no explanation.
    func resetImage() {
        guard let camera = selectedCamera else {
            window.toast = MainWindowToast(kind: .warning,
                                           message: Self.localized("Connect a camera first"))
            return
        }
        if localImageAdjustments.settings(for: camera.id) != nil {
            let neutral = localImageAdjustments.reset(camera.id)
            deviceInfo.publishLocalImagePreview(neutral)
            window.toast = MainWindowToast(kind: .success,
                                           message: Self.localized("Picture settings reset"))
            return
        }
        let channel = camera.channel
        Task {
            switch await deviceInfo.resetImage(channel: channel) {
            case .reset:
                window.toast = MainWindowToast(
                    kind: .success,
                    message: Self.localized("Picture settings reset"))
            case .documentedDefaults:
                window.toast = MainWindowToast(
                    kind: .info,
                    message: Self.localized("This camera has no reset command, so Vigil wrote the "
                                            + "standard picture values instead."))
            case .unchanged:
                window.toast = MainWindowToast(
                    kind: .info,
                    message: Self.localized("The camera accepted the reset and reported the same "
                                            + "settings — its picture was already at the defaults."))
            case .refused(let reason):
                window.toast = MainWindowToast(
                    kind: .error,
                    message: String(format: Self.localized("The camera refused to reset its "
                                                           + "picture settings: %@"),
                                    reason))
            case .unavailable:
                window.toast = MainWindowToast(
                    kind: .warning,
                    message: Self.localized("Connect a camera first"))
            }
        }
    }

    /// Opens the camera's own web interface in the default browser.
    ///
    /// Built from the same host and HTTP port the inspector shows, so the two cannot disagree. A host
    /// that will not form a URL — empty, before a connection — simply does nothing rather than
    /// force-unwrapping into a crash.
    func openDeviceWebPage() {
        let identity = deviceIdentity
        guard !identity.host.isEmpty else { return }
        var components = URLComponents()
        components.scheme = identity.usesTLS ? "https" : "http"
        components.host = identity.host
        components.port = identity.httpPort
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// What the Rec tab shows.
    var recordingState: VInspectorRecordingState {
        VInspectorRecordingState(
            isRecording: recording.isRecording,
            elapsedSeconds: recording.elapsed(now: recordingTick)
                .map { Double($0.components.seconds) } ?? 0,
            destination: recordingsFolderLabel,
            // ⚠️ Every clip in the folder, not today's. There is no per-day filter yet and
            // labelling the total as "today" would be a wrong number wearing a confident label —
            // the row is renamed in the tab instead once the filter exists.
            clipsToday: window.clips.count,
            storedClips: window.clips.isEmpty ? nil : window.clips.count,
            storedBytes: storedClipBytes,
            oldestClipAt: window.clips.map(\.startedAt).min())
    }

    /// What Vigil's own clips weigh on this Mac.
    ///
    /// Summed from the listing rather than re-walking the folder: `reloadClips` already read every
    /// file's size, and a second traversal on every inspector render would be disk work for a number
    /// that cannot have changed since.
    var storedClipBytes: Int64? {
        let sizes = window.clips.compactMap(\.byteCount)
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }
}

#endif  // os(macOS)
