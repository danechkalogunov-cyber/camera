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
        case stream(StreamError)
        case multipleSegments(Int)
        case incomplete(expected: Double, actual: Double)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noVideo:
                return vigilUIString("The camera returned no video for the selected range.")
            case .stream(let error):
                let status = error.rtspStatus.map { " (RTSP \($0))" } ?? ""
                return vigilUIString("The camera could not start video: \(error.message)\(status)")
            case .multipleSegments:
                return vigilUIString("The camera changed video format during export.")
            case .incomplete:
                return vigilUIString("The camera ended the export before the selected range was complete.")
            case .cancelled:
                return vigilUIString("Export cancelled.")
            }
        }
    }

    private let camera: Camera
    private let range: Range<Date>
    private let playback: PlaybackLocator
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
    private var terminalError: StreamError?
    private var wasCancelled = false

    init(camera: Camera, range: Range<Date>, playback: PlaybackLocator,
         dependencies: CoreDependencies,
         credentials: CredentialStore,
         fileSystem: any RecordingFileSystem = SystemRecordingFileSystem()) {
        self.camera = camera
        self.range = range
        self.playback = playback
        self.dependencies = dependencies
        self.credentials = credentials
        self.fileSystem = fileSystem
    }

    func run(frames suppliedFrames: AsyncStream<EncodedFrame>? = nil) async throws -> Output {
        terminalError = nil
        let destination = try RecordingDestinationResolver.resolve(
            RecordingDestinationRequest(kind: .clips, folderName: "Vigil/Exports"),
            fileSystem: fileSystem)
        let info = RecordingCameraInfo(id: camera.id, slug: Self.slug(camera.displayName),
                                       name: camera.displayName)
        let options = ClipRecorder.Options(
            trigger: "export",
            nameTemplate: "{camera}_{date}_{time}",
            limits: RecordingSegmentPlanner.Limits(maximumSeconds: 0, maximumBytes: 0),
            fragmentIntervalSeconds: 0,
            preservesSourceGaps: true,
            expectsMediaDataInRealTime: false)
        let recorder = ClipRecorder(camera: info, options: options, destination: destination,
                                    fileSystem: fileSystem, clock: dependencies.clock,
                                    wallClock: SystemWallClock(), logger: dependencies.logger,
                                    requestKeyframe: {})
        self.recorder = recorder

        let (frames, continuation) = AsyncStream<EncodedFrame>.makeStream(
            of: EncodedFrame.self, bufferingPolicy: .bufferingNewest(512))
        self.continuation = continuation
        var sourceTask: Task<Void, Never>?
        var eventTask: Task<Void, Never>?
        var activeController: StreamController?
        if let suppliedFrames {
            sourceTask = Task {
                for await frame in suppliedFrames {
                    guard !Task.isCancelled else { break }
                    continuation.yield(frame)
                }
                continuation.finish()
            }
        } else {
            var target = camera
            let locator = exportLocator()
            let query = locator.rawQuery
            target.rtspPathOverride = query.isEmpty ? locator.path : locator.path + "?" + query
            let store = credentials
            let ref = camera.credentialRef
            let controller = StreamController(
                camera: target,
                credentialProvider: { try await store.credential(for: ref) },
                initialQuality: .main,
                initialPriority: .background,
                dependencies: dependencies,
                frameSink: { continuation.yield($0) },
                playbackScale: nil)
            self.controller = controller
            activeController = controller
            await controller.start()
            let events = controller.events()
            eventTask = Task {
                for await event in events {
                    switch event {
                    case .formatResolved(let format):
                        self.remember(format)
                    case .error(let error, isFatal: true):
                        self.remember(error)
                        continuation.finish()
                        return
                    case .ended:
                        continuation.finish()
                        return
                    default:
                        break
                    }
                }
            }
        }
        // Export deliberately requests normal-speed playback: several camera firmwares end an
        // archive RTSP session as soon as `Scale:` is present. The old /8 budget therefore cut a
        // 71-second clip off after roughly 39 seconds, leaving the UI looking permanently busy.
        let expectedSeconds = range.upperBound.timeIntervalSince(range.lowerBound)
        let budget = max(45, expectedSeconds + 30)
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(budget))
            continuation.finish()
        }
        // A camera can keep the RTSP socket open after it has stopped delivering usable video.
        // Watch `mediaSeconds`, not frame arrival: repeated timestamps must not keep the export UI
        // spinning forever. Three quiet five-second checks leave normal keyframe spacing ample room.
        let stallWatchdog = Task { [weak self] in
            var previous = -1.0
            var unchangedChecks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                let current = await self.mediaSeconds
                if current > previous + 0.05 {
                    previous = current
                    unchangedChecks = 0
                } else {
                    unchangedChecks += 1
                    if unchangedChecks >= 3 {
                        continuation.finish()
                        return
                    }
                }
            }
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
        stallWatchdog.cancel()
        sourceTask?.cancel()
        eventTask?.cancel()
        continuation.finish()
        await activeController?.stop(reason: .userRequested)
        self.controller = nil
        self.continuation = nil

        guard !wasCancelled, !Task.isCancelled else {
            await recorder.cancelAndDelete()
            throw Failure.cancelled
        }
        guard started, let codec else {
            await recorder.cancelAndDelete()
            if let terminalError {
                throw Failure.stream(terminalError)
            }
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

    private func remember(_ error: StreamError) {
        terminalError = error
    }

    /// Uses the path chosen by the timeline's real segment index. A camera can split one channel
    /// across tracks (for example 101 and 103); re-discovering a track here can select the wrong
    /// one and make an otherwise visible range look empty to RTSP.
    private func exportLocator() -> PlaybackLocator {
        var queryItems: [Substring] = []
        for item in playback.rawQuery.split(separator: "&", omittingEmptySubsequences: true) {
            let name = String(item.prefix { $0 != "=" })
            if name.caseInsensitiveCompare("starttime") != .orderedSame
                && name.caseInsensitiveCompare("endtime") != .orderedSame {
                queryItems.append(item)
            }
        }
        // Match the locator that already works for visible playback: this firmware rejects the
        // same path when `endtime` is present. The worker owns the end boundary and stops after the
        // requested amount of media, so the camera only needs to be told where to start.
        let timeRange = ["starttime=\(ISAPITime.compactUTC(range.lowerBound))"]
        return PlaybackLocator(path: playback.path,
                               rawQuery: (queryItems.map(String.init) + timeRange).joined(separator: "&"),
                               start: range.lowerBound,
                               end: range.upperBound,
                               fileName: playback.fileName,
                               sizeBytes: playback.sizeBytes)
    }

    private static func slug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "camera" : collapsed
    }
}

#endif
