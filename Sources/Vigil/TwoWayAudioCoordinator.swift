//
//  TwoWayAudioCoordinator.swift
//  Vigil
//
//  App lifecycle for hold-to-talk: lazy permission, capability-selected ISAPI channel, microphone
//  capture, steady upload cadence, feedback ducking, and unconditional close.
//

#if os(macOS)

import AVFoundation
import Foundation
import Observation

import VigilCore
import VigilISAPI
import VigilProtocols
import VigilVideo

@MainActor
@Observable
final class TwoWayAudioCoordinator {
    enum State: Equatable { case idle, opening, talking, failed(String) }

    private(set) var state: State = .idle
    private(set) var inputLevel: Float = 0
    private(set) var supportedCameraIDs: Set<CameraID> = []
    private(set) var activeCameraID: CameraID?

    private let capture = TalkAudioCapture()
    private var channelByCamera: [CameraID: Int] = [:]
    private var operation: Task<Void, Never>?
    private var pump: Task<Void, Never>?
    private var drain: Task<Void, Never>?
    private var talkSession: TwoWayAudioSession?
    private weak var appSession: AppSessionModel?

    var isTalking: Bool { if case .talking = state { return true }; return false }

    func probe(camera: Camera, deviceSession: ISAPIDeviceSession?) async {
        guard let deviceSession else {
            supportedCameraIDs.remove(camera.id)
            channelByCamera[camera.id] = nil
            return
        }
        do {
            let channels = try await deviceSession.twoWayAudioChannels()
            let match = channels.first { $0.associatedVideoChannels.contains(camera.channel) }
                ?? channels.first(where: { $0.id == camera.channel.value })
                ?? channels.first
            guard let match, match.enabled, match.negotiatedSendCodec() != nil else {
                supportedCameraIDs.remove(camera.id)
                channelByCamera[camera.id] = nil
                return
            }
            supportedCameraIDs.insert(camera.id)
            channelByCamera[camera.id] = match.id
        } catch {
            supportedCameraIDs.remove(camera.id)
            channelByCamera[camera.id] = nil
        }
    }

    func begin(camera: Camera, deviceInfo: DeviceInfoService, appSession: AppSessionModel) {
        guard operation == nil, supportedCameraIDs.contains(camera.id),
              let channel = channelByCamera[camera.id],
              let deviceSession = deviceInfo.session, let client = deviceInfo.client else { return }
        state = .opening
        activeCameraID = camera.id
        self.appSession = appSession
        operation = Task { [weak self] in
            guard let self else { return }
            let allowed = await Self.microphoneAllowed()
            guard allowed, !Task.isCancelled else {
                self.state = .failed("microphonePermission")
                self.operation = nil
                return
            }
            do {
                let talk = try await deviceSession.openTwoWayAudio(channel: channel)
                self.talkSession = talk
                try Task.checkCancellation()
                let upload = try await client.chunkedUpload(
                    ISAPIResource.twoWayAudioData(channel), contentType: "application/octet-stream")
                await talk.attach(upload)
                try Task.checkCancellation()
                let frames = try await self.capture.start(codec: await talk.codec,
                                                          sampleRateHz: await talk.sampleRateHz)
                try Task.checkCancellation()
                let key = StreamKey(camera: camera.id, quality: .main)
                await appSession.audioPlayback.setDucked(true, for: key)
                self.state = .talking
                self.drain = Task { [weak self] in
                    for await frame in frames {
                        guard !Task.isCancelled else { break }
                        await talk.enqueue(frame.data)
                        self?.inputLevel = frame.rmsLevel
                    }
                }
                self.pump = Task {
                    while !Task.isCancelled {
                        await talk.pump()
                        try? await Task.sleep(for: .milliseconds(40))
                    }
                }
            } catch {
                self.state = .failed(String(describing: error))
                await self.finishSession(cameraID: camera.id)
            }
            self.operation = nil
        }
    }

    func end() {
        operation?.cancel()
        operation = nil
        let cameraID = activeCameraID
        Task { [weak self] in await self?.finishSession(cameraID: cameraID) }
    }

    private func finishSession(cameraID: CameraID?) async {
        pump?.cancel(); pump = nil
        drain?.cancel(); drain = nil
        await capture.stop()
        await talkSession?.close()
        talkSession = nil
        if let cameraID, let appSession {
            await appSession.audioPlayback.setDucked(
                false, for: StreamKey(camera: cameraID, quality: .main))
        }
        inputLevel = 0
        activeCameraID = nil
        appSession = nil
        if case .failed = state {} else { state = .idle }
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

#endif
