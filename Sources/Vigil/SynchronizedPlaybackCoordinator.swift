//
//  SynchronizedPlaybackCoordinator.swift
//  Vigil
//
//  One UTC playhead driving up to four independent camera-side archive sessions.
//  Implements the software-verifiable part of docs/FEATURES.md F-PLB-05.
//

#if os(macOS)

import Foundation
import Observation

import VigilCore
import VigilISAPI
import VigilProtocols
import VigilTransport
import VigilUI

@MainActor
@Observable
final class SynchronizedPlaybackCoordinator {

    enum LaneState: Sendable, Hashable {
        case indexing
        case ready
        case noRecording
        case failed(String)
    }

    private(set) var isEnabled = false
    private(set) var playhead: SyncedPlayhead?
    private(set) var laneStates: [CameraID: LaneState] = [:]
    private(set) var skew: TimeInterval?

    private var cameras: [Camera] = []
    private var segments: [CameraID: [RecordSegment]] = [:]
    private var generation: UInt64 = 0
    private var clockTask: Task<Void, Never>?

    private struct IndexDeviceKey: Sendable, Hashable {
        let host: String
        let port: Int
        let useTLS: Bool
        let credential: CredentialRef
    }

    private struct IndexWork: Sendable {
        let camera: Camera
        let credential: Credential
    }

    private struct IndexAnswer: Sendable {
        let camera: CameraID
        let segments: [RecordSegment]?
        let failure: String?
    }

    var readyCount: Int {
        laneStates.values.reduce(into: 0) { count, state in
            if state == .ready { count += 1 }
        }
    }

    var laneCount: Int { cameras.count }

    var label: String? {
        guard isEnabled else { return nil }
        return vigilUIString("Synchronized playback")
    }

    /// Reads each camera's own archive index. A track id is never borrowed from another camera:
    /// 101 on one NVR is unrelated to 101 on the next one.
    func enable(cameras requested: [Camera], day: TimelineDay,
                appSession: AppSessionModel) async {
        generation &+= 1
        let requestGeneration = generation
        let admitted = Array(requested.prefix(SyncedPlaybackPolicy.maximumCameras))
        guard admitted.count > 1 else {
            disable()
            return
        }

        isEnabled = true
        cameras = admitted
        segments = [:]
        laneStates = Dictionary(uniqueKeysWithValues: admitted.map { ($0.id, .indexing) })
        skew = nil

        let credentials = appSession.credentials
        let dependencies = appSession.dependencies
        var devices: [IndexDeviceKey: [IndexWork]] = [:]
        for camera in admitted {
            do {
                guard let credential = try await credentials.credential(for: camera) else {
                    throw SyncIndexError.missingCredential
                }
                let key = IndexDeviceKey(host: camera.host, port: camera.httpPort,
                                         useTLS: camera.useTLS,
                                         credential: credential.ref)
                devices[key, default: []].append(IndexWork(camera: camera,
                                                            credential: credential))
            } catch {
                laneStates[camera.id] = .failed(String(describing: error))
            }
        }

        let configuration = DeviceInfoService.defaultConfiguration
        await withTaskGroup(of: [IndexAnswer].self) { group in
            for work in devices.values {
                group.addTask {
                    await Self.index(work: work, day: day, dependencies: dependencies,
                                     configuration: configuration)
                }
            }
            for await answers in group {
                guard requestGeneration == generation else { continue }
                for answer in answers {
                    if let found = answer.segments {
                        segments[answer.camera] = found
                        laneStates[answer.camera] = found.isEmpty ? .noRecording : .ready
                    } else {
                        laneStates[answer.camera] = .failed(
                            answer.failure ?? vigilUIString("Archive unavailable"))
                    }
                }
            }
        }
    }

    func disable() {
        generation &+= 1
        clockTask?.cancel()
        clockTask = nil
        isEnabled = false
        playhead = nil
        cameras = []
        segments = [:]
        laneStates = [:]
        skew = nil
    }

    /// Applies one seek to all lanes as one task group. Cameras with a gap wait; the next seek or
    /// clock correction automatically admits them when their coverage resumes.
    func seek(to instant: Date, rate: TimelinePlaybackRate,
              appSession: AppSessionModel) async {
        guard isEnabled else { return }
        playhead = SyncedPlayhead(instant: instant, rate: rate.scale, isPaused: false)
        let commands = cameras.compactMap { camera -> (CameraStream, PlaybackLocator)? in
            guard let segment = segment(for: camera.id, at: instant) else {
                laneStates[camera.id] = .noRecording
                if let stream = appSession.cameras.stream(for: camera.id) {
                    stream.hasPlaybackCoverage = false
                    appSession.stop(stream)
                }
                return nil
            }
            laneStates[camera.id] = .ready
            let stream = appSession.cameras.stream(for: camera)
            stream.hasPlaybackCoverage = true
            return (stream, PlaybackLocator(track: segment.track, start: instant, end: nil))
        }
        await withTaskGroup(of: Void.self) { group in
            for (stream, locator) in commands {
                group.addTask { await appSession.playArchive(locator, on: stream) }
            }
        }
        startClock(appSession: appSession)
    }

    func setPaused(_ paused: Bool, appSession: AppSessionModel) async {
        guard var current = playhead else { return }
        current.isPaused = paused
        playhead = current
        let streams = cameras.compactMap { appSession.cameras.stream(for: $0.id) }
        if paused {
            await withTaskGroup(of: Void.self) { group in
                for stream in streams {
                    group.addTask { await appSession.setPlaybackPaused(true, on: stream) }
                }
            }
            return
        }
        // Resume at the held UTC, not at each stream's original locator. Reopening the old locator
        // would rewind every camera by however long it played before the pause.
        await seek(to: current.instant,
                   rate: playbackRate(nearest: current.rate),
                   appSession: appSession)
    }

    func setRate(_ rate: TimelinePlaybackRate, appSession: AppSessionModel) async {
        guard var current = playhead else { return }
        current.rate = rate.scale
        playhead = current
        let streams = cameras.compactMap { appSession.cameras.stream(for: $0.id) }
        for stream in streams { stream.playbackRate = rate }
        guard !current.isPaused else { return }
        // A speed change is a new RTSP session on the reference firmware. Seed it at the current
        // shared UTC; rebuilding from the previous locator would make the whole wall jump back.
        await seek(to: current.instant, rate: rate, appSession: appSession)
    }

    private func playbackRate(nearest scale: Double) -> TimelinePlaybackRate {
        TimelinePlaybackRate.allCases.min {
            abs($0.scale - scale) < abs($1.scale - scale)
        } ?? .normal
    }

    func returnToLive(appSession: AppSessionModel) async {
        let streams = cameras.compactMap { appSession.cameras.stream(for: $0.id) }
        clockTask?.cancel()
        clockTask = nil
        await withTaskGroup(of: Void.self) { group in
            for stream in streams {
                group.addTask { await appSession.returnToLive(stream) }
            }
        }
        disable()
    }

    private func startClock(appSession: AppSessionModel) {
        clockTask?.cancel()
        clockTask = Task { [weak self, weak appSession] in
            let clock = ContinuousClock()
            var sampled = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let appSession, var current = self.playhead else { return }
                let now = clock.now
                let elapsed = sampled.duration(to: now)
                sampled = now
                let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                current = current.advanced(byWallSeconds: seconds)
                self.playhead = current

                // There is no absolute timestamp report in Hikvision RTSP. The observable position
                // is therefore the requested UTC plus elapsed wall time. A lane that died is nil;
                // policy immediately reopens it, while healthy lanes retain the anti-thrash 500 ms
                // hysteresis for devices on which a future timestamp source becomes available.
                for camera in self.cameras {
                    let stream = appSession.cameras.stream(for: camera.id)
                    let position = stream?.playback != nil
                        && (stream?.isActive == true || current.isPaused)
                        ? current.instant : nil
                    let hasCoverage = self.segment(for: camera.id, at: current.instant) != nil
                    switch SyncedPlaybackPolicy.correction(
                        position: position, playhead: current, hasCoverage: hasCoverage) {
                    case .hold:
                        break
                    case .awaitCoverage:
                        self.laneStates[camera.id] = .noRecording
                        if let stream {
                            stream.hasPlaybackCoverage = false
                            if stream.isActive { appSession.stop(stream) }
                        }
                    case .seek(let target):
                        guard let segment = self.segment(for: camera.id, at: target) else { continue }
                        self.laneStates[camera.id] = .ready
                        let stream = appSession.cameras.stream(for: camera)
                        stream.hasPlaybackCoverage = true
                        let locator = PlaybackLocator(track: segment.track, start: target, end: nil)
                        await appSession.playArchive(locator, on: stream)
                    }
                }
                // Do not publish a fabricated zero. These positions are commanded UTC estimates;
                // actual inter-camera skew needs the synchronized-clock hardware scene named in
                // the acceptance criterion, which this process cannot observe from RTSP metadata.
                self.skew = nil
            }
        }
    }

    private func segment(for id: CameraID, at instant: Date) -> RecordSegment? {
        segments[id]?.first { $0.start <= instant && instant < $0.end }
    }

    /// One HTTP session per physical device/account. Four NVR channels frequently share a host;
    /// opening four clients would give that one device four independent concurrency gates and can
    /// exceed its three-worker limit before playback even begins.
    private nonisolated static func index(
        work: [IndexWork], day: TimelineDay, dependencies: CoreDependencies,
        configuration: ISAPIClient.Configuration
    ) async -> [IndexAnswer] {
        guard let first = work.first else { return [] }
        let camera = first.camera
        let endpoint = ISAPIEndpoint(host: camera.host, port: camera.httpPort,
                                     useTLS: camera.useTLS)
        let device = ISAPIDeviceSession(
            endpoint: endpoint,
            credential: first.credential,
            configuration: configuration,
            transport: URLSessionHTTPTransport(configuration: configuration,
                                               logger: dependencies.logger),
            clock: dependencies.clock,
            logger: dependencies.logger)
        let answers: [IndexAnswer]
        do {
            let tracks = try await device.recordTracks().filter(\.enabled)
            var built: [IndexAnswer] = []
            for item in work {
                do {
                    let channelTracks = tracks.filter { $0.channel == item.camera.channel }
                    // The one-camera fallback in ArchiveCoordinator may use every enabled track
                    // when old firmware reports an unusable channel number. Never do that for two
                    // channels on the same NVR: it would give both lanes the union of every input
                    // and seek the wrong camera with a perfectly valid-looking track id.
                    let chosen = channelTracks.isEmpty && work.count == 1
                        ? tracks : channelTracks
                    var all: [RecordSegment] = []
                    for track in chosen {
                        let index = try await device.dayIndex(
                            track: track.id, dayStartUTC: day.start)
                        all.append(contentsOf: index.segments)
                    }
                    built.append(IndexAnswer(camera: item.camera.id,
                                             segments: all.sorted { $0.start < $1.start },
                                             failure: nil))
                } catch {
                    built.append(IndexAnswer(camera: item.camera.id, segments: nil,
                                             failure: String(describing: error)))
                }
            }
            answers = built
        } catch {
            answers = work.map {
                IndexAnswer(camera: $0.camera.id, segments: nil,
                            failure: String(describing: error))
            }
        }
        await device.shutdown()
        return answers
    }

    private enum SyncIndexError: Error {
        case missingCredential
    }
}

#endif
