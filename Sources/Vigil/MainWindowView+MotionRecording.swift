//
//  MainWindowView+MotionRecording.swift
//  Vigil
//
//  Per-camera arming and device-event-to-recorder wiring for F-REC-03.
//

#if os(macOS)

import Foundation

import VigilCore
import VigilProtocols

extension MainWindowView {
    private func motionArmKey(_ id: CameraID) -> String {
        "Vigil.recording.motionArmed.\(id.rawValue.uuidString)"
    }

    private func motionConfigurationKey(_ id: CameraID) -> String {
        "Vigil.recording.motionConfiguration.\(id.rawValue.uuidString)"
    }

    func motionRecordingConfiguration(_ id: CameraID) -> MotionRecordingConfiguration {
        guard let data = UserDefaults.standard.data(forKey: motionConfigurationKey(id)),
              let value = try? JSONDecoder().decode(MotionRecordingConfiguration.self,
                                                    from: data) else { return .init() }
        return value
    }

    func saveMotionRecordingConfiguration(_ configuration: MotionRecordingConfiguration,
                                          for id: CameraID) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: motionConfigurationKey(id))
    }

    func isMotionRecordingArmed(_ id: CameraID) -> Bool {
        UserDefaults.standard.bool(forKey: motionArmKey(id))
    }

    var motionMonitoredCameras: [Camera] {
        var cameras = library.cameras.filter { isMotionRecordingArmed($0.id) }
        if let selectedCamera, !cameras.contains(where: { $0.id == selectedCamera.id }) {
            cameras.append(selectedCamera)
        }
        return cameras
    }

    var motionMonitorKey: String {
        let ids = motionMonitoredCameras.map { $0.id.rawValue.uuidString }
            .sorted().joined(separator: ",")
        return "\(motionArmRevision):\(selectedCamera?.id.rawValue.uuidString ?? "none"):\(ids)"
    }

    func toggleMotionRecordingArmed(_ id: CameraID) {
        let armed = !isMotionRecordingArmed(id)
        UserDefaults.standard.set(armed, forKey: motionArmKey(id))
        motionArmRevision &+= 1
        guard let camera = library.cameras.first(where: { $0.id == id }) else { return }
        if !armed {
            if case .stop = motionRecordingPolicy.disarm(id),
               motionOwnedRecordings.remove(id) != nil,
               let stream = session.cameras.stream(for: id) {
                stream.recordingCoordinator?.stop()
            }
            motionRecordingDeadlines.removeValue(forKey: id)?.cancel()
        }
        let configuration = motionRecordingConfiguration(id)
        Task {
            await session.setMotionRecordingArmed(
                armed, for: camera, preRollSeconds: configuration.preRollSeconds)
        }
    }

    func handleMotionRecordingTrigger(_ trigger: MotionRecordingTrigger) {
        guard isMotionRecordingArmed(trigger.cameraID),
              let camera = library.cameras.first(where: { $0.id == trigger.cameraID }) else { return }
        Task { @MainActor in
            let configuration = motionRecordingConfiguration(trigger.cameraID)
            await session.setMotionRecordingArmed(
                true, for: camera, preRollSeconds: configuration.preRollSeconds)
            guard let stream = session.cameras.stream(for: camera.id),
                  let format = await session.recordingFormat(for: stream) else { return }
            applyMotionRecordingAction(
                motionRecordingPolicy.receive(
                    trigger, isArmed: true, configuration: configuration),
                camera: camera, stream: stream, format: format)
        }
    }

    private func applyMotionRecordingAction(_ action: MotionRecordingAction,
                                            camera: Camera,
                                            stream: CameraStream,
                                            format: StreamFormat) {
        let coordinator = session.recordingCoordinator(for: stream)
        switch action {
        case let .start(trigger, preRollSeconds, stopAt):
            if !coordinator.ownsClipFiles {
                motionOwnedRecordings.insert(camera.id)
                coordinator.start(
                    camera: camera, codec: format.videoCodec,
                    parameterSets: format.parameterSets, resolution: format.resolution,
                    preRollSeconds: preRollSeconds,
                    requestKeyframe: { Task { @MainActor in
                        session.recoverStalledPicture(on: stream)
                    } })
            }
            scheduleMotionRecordingStop(at: stopAt, cameraID: trigger.cameraID)
        case let .extend(trigger, stopAt):
            scheduleMotionRecordingStop(at: stopAt, cameraID: trigger.cameraID)
        case .stop, .ignore:
            break
        }
    }

    private func scheduleMotionRecordingStop(at deadline: Date, cameraID: CameraID) {
        motionRecordingDeadlines.removeValue(forKey: cameraID)?.cancel()
        motionRecordingDeadlines[cameraID] = Task { @MainActor in
            let delay = max(0, deadline.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            let actions = motionRecordingPolicy.advance(to: Date())
            guard actions.contains(.stop(cameraID: cameraID)),
                  motionOwnedRecordings.remove(cameraID) != nil,
                  let stream = session.cameras.stream(for: cameraID) else { return }
            stream.recordingCoordinator?.stop()
            motionRecordingDeadlines[cameraID] = nil
        }
    }
}

#endif  // os(macOS)
