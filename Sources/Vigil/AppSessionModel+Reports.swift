//
//  AppSessionModel+Reports.swift
//  Vigil
//
//  What the app does with what the display path and the connect path report: decode failures,
//  dropped frames, and the named causes shown on the connect form.
//  macOS-only. Split out of `AppSessionModel+Session.swift` at the 600-line ceiling
//  (API_CONTRACT.md §7.2); the boundary is the one that was already marked in that file.
//
//  ⚠️ Every handler here comes in two forms: a no-argument one that means `live`, and one that
//  takes the `CameraStream` that reported. The tile that reports a decode failure knows which
//  camera it is drawing, and with more than one on screen the counters, the recovery rate limit and
//  the log line all have to belong to that camera rather than to "the session".
//

#if os(macOS)

import AppKit
import Foundation

import VigilCore
import VigilISAPI
import VigilProtocols
import VigilRender
import VigilUI
import VigilVideo

// MARK: - Display-path reports

extension AppSessionModel {

    /// Toggles one camera's live audio. Unmuting solos it so a wall never erupts into many feeds.
    func toggleAudio(for cameraID: CameraID) {
        guard let stream = cameras.stream(for: cameraID), let camera = stream.camera else { return }
        stream.isAudioMuted.toggle()
        let muted = stream.isAudioMuted
        defaults.set(muted, forKey: "Vigil.audio.muted.\(cameraID.rawValue.uuidString)")
        if !muted {
            for other in cameras.streams.values where other !== stream {
                other.isAudioMuted = true
                if let otherID = other.camera?.id {
                    defaults.set(true,
                                 forKey: "Vigil.audio.muted.\(otherID.rawValue.uuidString)")
                }
            }
        }
        let key = StreamKey(camera: camera.id, quality: .main)
        Task {
            if muted {
                await audioPlayback.setMuted(true, for: key)
            } else {
                await audioPlayback.solo(key)
            }
        }
    }

    /// Silences every camera and persists the state. Bound to ⇧⌘M and the menu-bar extra.
    func muteAllAudio() {
        for stream in cameras.streams.values {
            stream.isAudioMuted = true
            if let id = stream.camera?.id {
                defaults.set(true, forKey: "Vigil.audio.muted.\(id.rawValue.uuidString)")
            }
        }
        Task { await audioPlayback.muteAll() }
    }

    /// A sample the video renderer refused to decode.
    ///
    /// `VigilRender` hands over a diagnostic string rather than an error, because `any Error` is not
    /// `Sendable` and the report crosses a thread boundary from whatever queue AVFoundation posts on.
    /// The decision about what to *do* is here rather than there, which is why the tile only reports.
    ///
    /// One failure is not a fault: a truncated access unit after packet loss produces exactly this
    /// and the next keyframe fixes it. A run of them means the decoder cannot make progress from the
    /// parameter sets it has, and the only escape is a fresh keyframe — which is what
    /// ``AppSessionModel/recoverStalledPicture()`` asks for, rate-limited so a decoder that keeps
    /// failing cannot put the session into a restart loop.
    func handleDecodeFailure(_ diagnostic: String) {
        handleDecodeFailure(diagnostic, on: live)
    }

    /// The same, for whichever tile refused the sample.
    func handleDecodeFailure(_ diagnostic: String, on stream: CameraStream) {
        stream.decodeFailures += 1
        dependencies.logger.error(.video, "renderer failed to decode: \(diagnostic)")
        guard stream.decodeFailures >= Self.decodeFailuresBeforeRecovery else { return }
        stream.decodeFailures = 0
        recoverStalledPicture(on: stream)
    }

    /// Frames that never reached the screen, from either end of the display path.
    ///
    /// Two origins arrive here through one callback: `VigilVideo`'s pipeline dropping an access unit
    /// before it became a sample buffer, and the tile's own renderer refusing one it was handed. The
    /// reason string keeps them apart, and the tile's ``VigilRender/TileRenderState`` already carries
    /// the running counts for the status line, so this method's job is the part no view can do —
    /// putting the fact in the log, and acting on the one reason that never resolves by itself.
    ///
    /// **`noFormat` is the case this exists for.** It means no parameter sets have arrived, so every
    /// frame is being discarded and the tile is black with nothing wrong anywhere else. Left alone it
    /// stays that way forever. Hikvision re-sends SPS/PPS immediately before every IDR, so asking
    /// for a keyframe is precisely the right remedy — the recovery that looks like it is about a
    /// stalled picture is really about getting the format.
    ///
    /// Logging is thresholded, not per frame: at 25 fps an unresolved `noFormat` would otherwise
    /// write 1,500 lines a minute and bury the line that matters.
    func handleFramesDropped(_ count: Int, reason: String) {
        handleFramesDropped(count, reason: reason, on: live)
    }

    /// The same, for whichever tile dropped them.
    func handleFramesDropped(_ count: Int, reason: String, on stream: CameraStream) {
        stream.droppedByReason[reason, default: 0] += count
        let total = stream.droppedByReason[reason] ?? count
        if total.isMultiple(of: Self.dropLogInterval) || total == count {
            dependencies.logger.notice(.video, "dropped \(total) frame(s), reason: \(reason)")
        }
        guard reason == FrameDropReason.noFormat.rawValue,
              total >= Self.noFormatDropsBeforeRecovery
        else { return }
        stream.droppedByReason[reason] = 0
        dependencies.logger.notice(.video, "no parameter sets after \(total) frames; asking for a "
            + "keyframe so the camera re-sends them")
        recoverStalledPicture(on: stream)
    }

    /// A failure before the controller existed: a bad address, or a Keychain that would not answer.
    func fail(with error: any Error, host: String) {
        present(Self.diagnosis(for: error, host: host))
        dependencies.logger.error(.app, "connect failed: \(error)")
    }

    /// Shows a named cause on the connect form.
    ///
    /// `ConnectFormState.fail` also clears the in-flight flag and bumps the failure counter that
    /// drives the form's one-per-failure shake, so this is the only way a diagnosis reaches it.
    func present(_ named: ConnectDiagnosis) {
        diagnosis = named
        phase = .connect
        form.fail(named)
    }

    /// Turns an error raised on the app's own half of the connect path into a named cause.
    ///
    /// `StreamError` never reaches here — the controller reports those through its event stream —
    /// so this covers exactly two sources: the address the user typed, and the Keychain.
    static func diagnosis(for error: any Error, host: String) -> ConnectDiagnosis {
        switch error {
        case is CameraValidationError:
            // `CameraValidationError.description` is a redacted log line, not a sentence for a
            // person, so the user-facing copy is written here.
            return .undiagnosed(host: host,
                                detail: "That is not an address Vigil can use. Type just the "
                                    + "address — no rtsp://, no user name and no path.")
        case let failure as any VigilFailure:
            return .undiagnosed(host: host,
                                detail: [failure.userMessage, failure.userRemedy]
                                    .compactMap { $0 }.joined(separator: " "))
        default:
            return .undiagnosed(host: host, detail: "Vigil could not start the connection.")
        }
    }

    /// What we already know about this host and account: its Keychain handle, and the RTSP path
    /// that worked last time.
    ///
    /// Reusing the handle matters because `save` updates an item in place, whereas a fresh
    /// `CredentialRef` would leave the old item behind as an orphan on every retry. Reusing the
    /// path is R1.2's "the probe happens exactly once per device, ever".
    func knownHandle(for request: ConnectRequest) -> (ref: CredentialRef, rtspPath: String?) {
        guard let remembered = LastConnection.load(from: defaults),
              remembered.host.caseInsensitiveCompare(request.host) == .orderedSame,
              remembered.account == request.username
        else {
            return (CredentialRef(), nil)
        }
        return (remembered.credentialRef, remembered.rtspPath)
    }

    /// Removes a password the camera has rejected.
    ///
    /// Fire-and-forget on purpose: the user is already looking at the form, and a Keychain that
    /// refuses the delete changes nothing they can act on. The failure is logged, not shown.
    func deleteRejectedCredential(_ ref: CredentialRef) {
        let store = credentials
        let logger = dependencies.logger
        Task {
            do {
                try await store.delete(ref)
            } catch {
                logger.warning(.app, "could not remove the rejected credential: \(error)")
            }
        }
    }

    /// Opens the camera's own web page, where every device-side setting the diagnoses point at
    /// lives — including activation for a factory-fresh camera.
    func openCameraWebPage() {
        let host = camera?.host ?? form.request.host
        let port = camera?.httpPort ?? 80
        let authority = host.contains(":") ? "[\(host)]" : host   // bare IPv6 needs brackets
        guard !host.isEmpty, let url = URL(string: "http://\(authority):\(port)/") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Reports a remedy the slice cannot perform, in place of doing nothing.
    func unavailable(_ sentence: String) {
        let host = camera?.host ?? form.request.host
        present(.undiagnosed(host: host, detail: sentence))
        dependencies.logger.notice(.ui, sentence)
    }

    /// Whole seconds from now until `date`, or `nil` when there is no countdown.
    static func seconds(until date: Date?) -> Int? {
        guard let date else { return nil }
        return max(0, Int(date.timeIntervalSinceNow.rounded()))
    }

    /// The port Hikvision devices use when 554 is taken or disabled (R1.5 "RTSP port closed").
    static let alternateRTSPPort = 8554

    /// The shortest gap between two forced keyframe recoveries.
    static let recoveryInterval: TimeInterval = 10

    /// How many renderer decode failures in a row before forcing a keyframe.
    ///
    /// Three, because one is packet loss and two can be the same GOP; three means the parameter sets
    /// the decoder is working from cannot decode what the camera is sending.
    static let decodeFailuresBeforeRecovery = 3

    /// How many frames may be dropped for want of parameter sets before asking for a keyframe.
    ///
    /// Fifty is about two seconds at 25 fps — long enough that a normal startup, where the first
    /// access units precede the first SPS by a few frames, resolves on its own without a restart.
    static let noFormatDropsBeforeRecovery = 50

    /// One log line per this many dropped frames of the same reason.
    static let dropLogInterval = 100

    /// What this Mac will decode at once (`F-DEC-06`).
    ///
    /// ⛔ THIS REPLACED `maxConcurrentStreams = 4`, which was labelled a placeholder in its own doc
    /// comment. Four is the wrong shape of answer twice over: four 4K cameras are sixteen times the
    /// work of four D1 cameras, and a machine that could carry ten small streams was told it may
    /// have four. Cost is what varies, so cost is what is counted.
    ///
    /// Computed on each ask rather than cached, because the override can change under a running
    /// process. It reads `defaults` — this model's own suite — so a test gets the budget it chose
    /// rather than the one belonging to whoever is running the tests.
    var decodeBudget: DecodeCost { MachineDecodeBudget.detected(defaults: defaults) }

    /// What one camera is assumed to cost before anything has measured it.
    ///
    /// ⚠️ AN ASSUMPTION, AND IT HAS TO BE ONE. Admission happens *before* the first frame, so there
    /// is no resolved format to price. 1080p25 H.264 is what a Hikvision main stream almost always
    /// is, and the real cost takes over the moment `formatResolved` arrives.
    static var assumedCost: DecodeCost {
        DecodeCost.estimate(geometry: assumedGeometry, codec: .h264, fps: 25, mode: .full)
    }

    /// The geometry assumed for an unmeasured stream: 1080p, coded to the 1088 lines a real SPS
    /// allocates, because the estimator charges coded pixels and pretending otherwise would
    /// under-count every camera by a quarter unit.
    static var assumedGeometry: FrameGeometry {
        FrameGeometry(codedWidth: 1920, codedHeight: 1088, cropWidth: 1920, cropHeight: 1080)
    }

    /// What every stream currently being driven is asking of the budget.
    ///
    /// The bound camera is the focused tile — it is the one the window's panels describe — and every
    /// other running stream is a visible tile. A stream being recorded is not preemptible, which is
    /// what actually protects the file (`F-DEC-06` acceptance 5).
    func decodeDemands() -> [DecodeDemand] {
        cameras.all.filter(\.isActive).compactMap { stream in
            guard let camera = stream.camera else { return nil }
            let isRecording = stream.recordingCoordinator?.ownsClipFiles == true
            let compressedOnly = stream.isMotionRecordingArmed && stream.renderState == nil
            return DecodeDemand(
                id: StreamKey(camera: camera.id, quality: .main),
                priority: isRecording || stream.isMotionRecordingArmed
                    ? .recording : (stream === live ? .focused : .visibleLarge),
                mode: compressedOnly ? .paused : .full,
                cost: compressedOnly ? .zero : Self.cost(of: stream),
                isPreemptible: !isRecording)
        }
    }

    /// Recomputes and applies the one global decode plan.
    ///
    /// This is intentionally idempotent and may be called after any fact that changes cost or
    /// priority. The actor hop to each pipeline preserves ordering per stream and never moves frame
    /// work onto the main actor.
    func rebalanceDecodeBudget() {
        let plan = DecodeAdmissionPlanner.plan(
            for: decodeDemands(), budget: decodeBudget,
            maxSessions: MachineDecodeBudget.maximumSessions)
        for stream in cameras.all {
            guard let camera = stream.camera else { continue }
            let key = StreamKey(camera: camera.id, quality: .main)
            let mode = plan.mode(for: key) ?? .full
            stream.decodeMode = mode
            if let pipeline = stream.pipeline {
                Task { await pipeline.setMode(mode) }
            }
        }
        dependencies.logger.info(
            .video, "decode plan applied",
            ["committed": plan.committed.description,
             "budget": decodeBudget.description,
             "demoted": "\(plan.demoted.count)",
             "pressure": plan.pressure.rawValue])
    }

    /// Whether the budget has room for one more camera at a mode that actually decodes.
    ///
    /// ⚠️ The candidate is asked for **last** and at the lowest priority, and that is the policy
    /// rather than an accident: a camera the user has just clicked must not slow down a camera they
    /// are already watching. It joins at the back of the queue and pays its own way in.
    func canAdmit(_ target: Camera) -> Bool {
        var demands = decodeDemands()
        demands.append(DecodeDemand(
            id: StreamKey(camera: target.id, quality: .main),
            priority: .offscreen,
            orderIndex: demands.count,
            mode: .full,
            cost: Self.assumedCost))
        let plan = DecodeAdmissionPlanner.plan(
            for: demands, budget: decodeBudget, maxSessions: MachineDecodeBudget.maximumSessions)
        return plan.mode(for: StreamKey(camera: target.id, quality: .main))?
            .opensDecodeSession ?? false
    }

    /// What one running stream costs, measured where possible and assumed where not.
    ///
    /// ⚠️ The two halves come from different places and only one is usually there. The picture size
    /// is authoritative once the SPS has been parsed; the frame rate is whatever the SDP declared,
    /// which on Hikvision is frequently nothing at all — `StreamFormat.declaredFPS` is documented as
    /// "never a measurement". A resolved stream with no declared rate is therefore costed at
    /// ``assumedFPS`` rather than treated as free, which is the same direction of caution the rest
    /// of the policy takes.
    static func cost(of stream: CameraStream) -> DecodeCost {
        guard let format = stream.format, let resolution = format.resolution else {
            return assumedCost
        }
        let geometry = FrameGeometry(codedWidth: resolution.width,
                                     codedHeight: resolution.height,
                                     cropWidth: resolution.width,
                                     cropHeight: resolution.height)
        return DecodeCost.estimate(geometry: geometry,
                                   codec: format.videoCodec,
                                   fps: format.declaredFPS ?? assumedFPS,
                                   mode: .full)
    }

    /// The frame rate assumed for a stream that never declared one. PAL, which is what these devices
    /// run at in the regions this app was built for.
    static let assumedFPS = 25.0
}

#endif  // os(macOS)
