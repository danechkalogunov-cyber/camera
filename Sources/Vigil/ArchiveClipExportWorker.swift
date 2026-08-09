//
//  ArchiveClipExportWorker.swift
//  Vigil
//
//  A decoder-free playback RTSP session feeding the existing passthrough recorder at 8x.
//

#if os(macOS)

import Foundation

import VigilCore
import VigilISAPI
import VigilProtocols
import VigilUI
import VigilVideo

actor ArchiveClipExportWorker {
    struct Output: Sendable {
        let record: RecordingSegmentRecord
        let codec: VideoCodec
        let resolution: Resolution?
    }

    enum Failure: Error, LocalizedError {
        case noVideo
        case multipleSegments(Int)
        case incomplete(expected: Double, actual: Double)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noVideo:
                vigilUIString("The camera returned no video for the selected range.")
            case .multipleSegments:
                vigilUIString("The camera changed video format during export.")
            case .incomplete:
                vigilUIString("The camera ended the export before the selected range was complete.")
            case .cancelled:
                vigilUIString("Export cancelled.")
            }
        }
    }

    private let camera: Camera
    private let range: Range<Date>
    private let dependencies: CoreDependencies
    private let credentials: CredentialStore
    private let fileSystem: any RecordingFileSystem

    private var controller: StreamController?
    private var recorder: ClipRecorder?
    private var continuation: AsyncStream<EncodedFrame>.Continuation?
    private(set) var mediaSeconds: Double = 0
    private(set) var codec: VideoCodec?
    private(set) var resolution: Resolution?
    private var parameterSets: ParameterSets?
    private var wasCancelled = false

    init(camera: Camera, range: Range<Date>, dependencies: CoreDependencies,
         credentials: CredentialStore,
         fileSystem: any RecordingFileSystem = SystemRecordingFileSystem()) {
        self.camera = camera
        self.range = range
        self.dependencies = dependencies
        self.credentials = credentials
        self.fileSystem = fileSystem
    }

    func run() async throws -> Output {
        let destination = try RecordingDestinationResolver.resolve(
            RecordingDestinationRequest(kind: .clips, folderName: "Vigil/Exports"),
            fileSystem: fileSystem)
        let info = RecordingCameraInfo(id: camera.id, slug: Self.slug(camera.displayName),
                                       name: camera.displayName)
        let options = ClipRecorder.Options(
            trigger: "export",
            nameTemplate: "{camera}_{date}_{time}",
            limits: RecordingSegmentPlanner.Limits(maximumSeconds: 0, maximumBytes: 0),
            fragmentIntervalSeconds: 2,
            preservesSourceGaps: true,
            expectsMediaDataInRealTime: false)
        let recorder = ClipRecorder(camera: info, options: options, destination: destination,
                                    fileSystem: fileSystem, clock: dependencies.clock,
                                    wallClock: SystemWallClock(), logger: dependencies.logger,
                                    requestKeyframe: {})
        self.recorder = recorder

        var target = camera
        let locator = PlaybackLocator(track: try await playbackTrack(), start: range.lowerBound,
                                      end: range.upperBound)
        let query = locator.rawQuery
        target.rtspPathOverride = query.isEmpty ? locator.path : locator.path + "?" + query

        let (frames, continuation) = AsyncStream<EncodedFrame>.makeStream(
            of: EncodedFrame.self, bufferingPolicy: .bufferingNewest(512))
        self.continuation = continuation
        let store = credentials
        let ref = camera.credentialRef
        let controller = StreamController(
            camera: target,
            credentialProvider: { try await store.credential(for: ref) },
            initialQuality: .main,
            initialPriority: .background,
            dependencies: dependencies,
            frameSink: { continuation.yield($0) },
            playbackScale: 8)
        self.controller = controller
        await controller.start()

        let events = controller.events()
        let eventTask = Task {
            for await event in events {
                switch event {
                case .formatResolved(let format):
                    await self.remember(format)
                case .error(_, isFatal: true), .ended:
                    continuation.finish()
                    return
                default:
                    break
                }
            }
        }
        let budget = max(30, range.upperBound.timeIntervalSince(range.lowerBound) / 8 + 30)
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(budget))
            continuation.finish()
        }

        var started = false
        for await frame in frames {
            if wasCancelled || Task.isCancelled { break }
            guard let frameCodec = frame.videoCodec else { continue }
            if !started {
                try await recorder.start(codec: frameCodec,
                                         parameterSets: frame.parameterSets ?? parameterSets,
                                         resolution: resolution)
                codec = frameCodec
                started = true
            }
            await recorder.append(frame)
            let progress = await recorder.progress()
            mediaSeconds = progress.totalSeconds
            if mediaSeconds >= range.upperBound.timeIntervalSince(range.lowerBound) { break }
        }

        watchdog.cancel()
        eventTask.cancel()
        continuation.finish()
        await controller.stop(reason: .userRequested)
        self.controller = nil
        self.continuation = nil

        guard !wasCancelled, !Task.isCancelled else {
            await recorder.cancelAndDelete()
            throw Failure.cancelled
        }
        guard started, let codec else {
            await recorder.cancelAndDelete()
            throw Failure.noVideo
        }
        let records = await recorder.finish(reason: .userStopped)
        guard records.count == 1 else {
            await recorder.cancelAndDelete()
            throw Failure.multipleSegments(records.count)
        }
        let record = records[0]
        let expected = range.upperBound.timeIntervalSince(range.lowerBound)
        guard record.mediaSeconds + 0.5 >= expected else {
            await recorder.cancelAndDelete()
            throw Failure.incomplete(expected: expected, actual: record.mediaSeconds)
        }
        return Output(record: record, codec: codec, resolution: resolution)
    }

    func cancel() async {
        wasCancelled = true
        continuation?.finish()
        await recorder?.cancelAndDelete()
        await controller?.stop(reason: .userRequested)
        controller = nil
    }

    private func remember(_ format: StreamFormat) {
        codec = format.videoCodec
        resolution = format.resolution
        parameterSets = format.parameterSets
    }

    /// Finds the camera's track containing the requested in point. The UI index is deliberately
    /// not reused here: export is background work and must remain correct if the selected camera or
    /// day changes while it runs.
    private func playbackTrack() async throws -> TrackID {
        guard let credential = try await credentials.credential(for: camera) else {
            throw Failure.noVideo
        }
        var configuration = ISAPIClient.Configuration()
        configuration.connectTimeout = .seconds(4)
        configuration.controlTimeout = .seconds(6)
        let endpoint = ISAPIEndpoint(host: camera.host, port: camera.httpPort,
                                     useTLS: camera.useTLS)
        let session = ISAPIDeviceSession(
            endpoint: endpoint, credential: credential, configuration: configuration,
            transport: URLSessionHTTPTransport(configuration: configuration,
                                               logger: dependencies.logger),
            clock: dependencies.clock, logger: dependencies.logger)
        defer { Task { await session.shutdown() } }
        let tracks = try await session.recordTracks().filter(\.enabled)
        let channel = tracks.filter { $0.channel == camera.channel }
        let candidates = channel.isEmpty ? tracks : channel
        for track in candidates {
            let index = try await session.dayIndex(track: track.id,
                                                   dayStartUTC: range.lowerBound)
            if index.segments.contains(where: {
                $0.start <= range.lowerBound && range.lowerBound < $0.end
            }) { return track.id }
        }
        throw Failure.noVideo
    }

    private static func slug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "camera" : collapsed
    }
}

#endif
