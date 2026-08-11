//
//  AppSessionModel+Recording.swift
//  Vigil
//
//  Per-camera recorder ownership and background stream lifetime for F-REC-03.
//

#if os(macOS)

import Foundation

import VigilCore
import VigilProtocols

extension AppSessionModel {
    /// One coordinator per stream. Manual and event-driven starts therefore cannot write through
    /// competing actors into the same tap or create two files for one trigger.
    func recordingCoordinator(for stream: CameraStream) -> RecordingCoordinator {
        if let existing = stream.recordingCoordinator { return existing }
        let made = RecordingCoordinator(tap: stream.recordingTap,
                                        logger: dependencies.logger,
                                        clock: dependencies.clock)
        stream.recordingCoordinator = made
        return made
    }

    /// Arms or disarms the compressed background path used by device-triggered recording.
    /// An armed off-screen stream asks for `.paused` decode mode: RTP and pre-roll remain alive,
    /// while no VideoToolbox session is spent on pixels nobody is viewing.
    func setMotionRecordingArmed(_ armed: Bool, for camera: Camera,
                                 preRollSeconds: Double = 10) async {
        let stream = cameras.stream(for: camera)
        stream.isMotionRecordingArmed = armed
        recordingCoordinator(for: stream).configurePreRoll(seconds: armed ? preRollSeconds : 10)
        if armed, !stream.isActive {
            stream.resolvedPath = camera.capabilities?.resolvedRTSPPath
            stream.beginConnecting()
            await start(stream, camera: camera, ref: camera.credentialRef)
        } else if !armed, stream.renderState == nil {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(4))
            while stream.recordingCoordinator?.ownsClipFiles == true, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if stream.recordingCoordinator?.ownsClipFiles != true { stop(stream) }
        }
        rebalanceDecodeBudget()
    }

    /// Waits for SDP/format negotiation without blocking the main actor. A trigger that arrives
    /// during reconnect is retained for up to the same ten-second startup budget as live view.
    func recordingFormat(for stream: CameraStream,
                         timeout: Duration = .seconds(10)) async -> StreamFormat? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while stream.format == nil, stream.isActive, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return nil }
        }
        return stream.format
    }
}

#endif  // os(macOS)
