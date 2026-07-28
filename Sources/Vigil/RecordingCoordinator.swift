//
//  RecordingCoordinator.swift
//  Vigil
//
//  Drives `ClipRecorder` from the window: start, stop, and the tap that feeds it encoded frames.
//  macOS-only. See docs/spec-core.md §9 and `Sources/VigilCore/Recording/ClipRecorder.swift`.
//

#if os(macOS)

import Foundation
import Observation
import os

import VigilCore
import VigilProtocols

// MARK: - RecordingTap

/// The handle the detached frame loop uses to reach the recorder.
///
/// **Why a separate object.** The frame loop is created once, when the session starts, and recording
/// begins later — so the loop cannot capture a recorder that does not exist yet, and it must not
/// capture `AppSessionModel`, which is `@MainActor`. This box is `Sendable`, holds the recorder
/// behind one uncontended lock, and is the only thing the loop closes over.
///
/// Reading it costs one lock acquisition per frame and nothing else. When no recording is running the
/// read answers `nil` and the loop moves on, so the cost on the common path is a lock and a branch.
final class RecordingTap: Sendable {

    /// The recorder, or `nil` when nothing is being written.
    private let current = OSAllocatedUnfairLock<ClipRecorder?>(initialState: nil)

    /// Creates an empty tap.
    init() {}

    /// Installs a recorder, replacing any previous one.
    func attach(_ recorder: ClipRecorder?) {
        current.withLock { $0 = recorder }
    }

    /// The recorder to feed, if any.
    func recorder() -> ClipRecorder? {
        current.withLock { $0 }
    }
}

// MARK: - RecordingCoordinator

/// Starts and stops clip recording for the live camera.
///
/// **What this owns and what it does not.** It owns the `ClipRecorder` actor's lifetime and the
/// observable flags the toolbar reads. It does not own the frame path: frames reach the recorder
/// through ``RecordingTap``, which `AppSessionModel`'s detached decode loop already holds.
///
/// Every failure becomes a logged, named outcome in ``lastFailure``. A Record button that does
/// nothing and says nothing is the exact shape this project refuses.
@MainActor
@Observable
final class RecordingCoordinator {

    // MARK: - Observable State

    /// Whether a clip is being written right now.
    private(set) var isRecording = false

    /// When the current clip started, for the elapsed counter. `nil` when not recording.
    private(set) var startedAt: Date?

    /// The clips finished in this session, newest last.
    private(set) var completed: [RecordingSegmentRecord] = []

    /// The segments the last `stop()` produced, for the manifest to vouch for.
    private(set) var lastFinished: [RecordingSegmentRecord] = []

    /// Why the last attempt failed, or `nil` when the last attempt succeeded or none has been made.
    private(set) var lastFailure: String?

    // MARK: - Stored Properties

    /// The frame loop's inlet, owned by `AppSessionModel` because the loop is created there.
    private let tap: RecordingTap

    private let logger: any LoggerProtocol
    private let clock: any MonotonicClock
    private let fileSystem: any RecordingFileSystem
    private var recorder: ClipRecorder?

    // MARK: - Initialisation

    /// Creates a coordinator.
    ///
    /// - Parameters:
    ///   - tap: the frame path's inlet, from `AppSessionModel`.
    ///   - logger: the app's log sink; every outcome here goes through it.
    ///   - clock: monotonic source, shared with the rest of the app so durations agree.
    ///   - fileSystem: the disk surface. Injectable so a test can present a full or read-only volume.
    init(tap: RecordingTap,
         logger: any LoggerProtocol,
         clock: any MonotonicClock,
         fileSystem: any RecordingFileSystem = SystemRecordingFileSystem()) {
        self.tap = tap
        self.logger = logger
        self.clock = clock
        self.fileSystem = fileSystem
    }

    // MARK: - API

    /// Starts writing a clip from the next keyframe.
    ///
    /// Returns immediately. `ClipRecorder` holds its own keyframe gate, so the file does not open
    /// until a decodable starting point arrives — which is why ``isRecording`` goes true here while
    /// bytes may not land for another moment.
    ///
    /// - Parameters:
    ///   - camera: the camera being recorded, for the file name and the metadata.
    ///   - codec: the stream's codec. A non-NAL codec is refused by the recorder, not here.
    ///   - parameterSets: SPS/PPS from the SDP when known. `nil` is fine — Hikvision repeats them
    ///     in band before every IDR, and the recorder tries the in-band copy.
    ///   - resolution: for the file name's `{res}` token.
    ///   - requestKeyframe: asks the stream for an IDR, so recording does not wait out a long GOP.
    func start(camera: Camera,
               codec: VideoCodec,
               parameterSets: ParameterSets?,
               resolution: Resolution?,
               requestKeyframe: @escaping @Sendable () -> Void) {
        guard !isRecording else { return }

        let info = RecordingCameraInfo(id: camera.id,
                                       slug: Self.slug(for: camera),
                                       name: camera.displayName)
        // `RecordingDestination` is the *resolved* location — its initialiser is internal on
        // purpose. The public path is a request through the resolver, which is also what checks the
        // folder exists, that the sandbox will allow a write there, and that the volume is not
        // already below its reserve. Every one of those is a named `RecordingError`, so a refusal
        // says which of the three it was instead of failing later with an empty file.
        let request = RecordingDestinationRequest(kind: .clips)
        let destination: RecordingDestination
        do {
            destination = try RecordingDestinationResolver.resolve(request, fileSystem: fileSystem)
        } catch {
            lastFailure = String(describing: error)
            logger.error(.storage, "recording destination unusable: \(String(describing: error))")
            return
        }
        let recorder = ClipRecorder(camera: info,
                                    destination: destination,
                                    fileSystem: fileSystem,
                                    clock: clock,
                                    wallClock: SystemWallClock(),
                                    logger: logger,
                                    requestKeyframe: requestKeyframe)
        self.recorder = recorder

        Task {
            do {
                try await recorder.start(codec: codec,
                                         parameterSets: parameterSets,
                                         resolution: resolution)
                // Only now does the tap see it. Attaching before `start` would let the frame loop
                // append into a recorder that had not opened its writer.
                tap.attach(recorder)
                isRecording = true
                startedAt = Date()
                lastFailure = nil
                logger.info(.storage, "recording started")
            } catch {
                self.recorder = nil
                lastFailure = String(describing: error)
                logger.error(.storage, "recording refused to start: \(String(describing: error))")
            }
        }
    }

    /// Closes the current clip.
    ///
    /// Detaches the tap first, so no frame can arrive between the decision to stop and the writer
    /// finishing. Safe to call when nothing is recording.
    func stop() {
        guard let recorder, isRecording else { return }
        tap.attach(nil)
        isRecording = false
        startedAt = nil
        self.recorder = nil

        Task {
            let finished = await recorder.finish(reason: .userStopped)
            completed.append(contentsOf: finished)
            lastFinished = finished
            if finished.isEmpty {
                lastFailure = "the clip closed without producing a file"
                logger.error(.storage, "recording stopped but wrote no file")
            } else {
                logger.info(.storage, "recording finished: \(finished.count) file(s)")
            }
        }
    }

    /// Where clips are actually written.
    ///
    /// Resolved through the same request the recorder uses, so the list and the writer can never
    /// disagree about which folder to look in — guessing `~/Movies/Vigil` here worked only as long
    /// as nothing changed the destination, and a listing that looks in the wrong place reports "no
    /// recordings" for a folder full of them.
    ///
    /// Answers `nil` when the destination is unusable, which is the same condition that stops a
    /// recording starting.
    func clipsDirectory() -> URL? {
        let request = RecordingDestinationRequest(kind: .clips)
        return try? RecordingDestinationResolver.resolve(request, fileSystem: fileSystem).directory
    }

    /// How long the current clip has been running, or `nil` when not recording.
    func elapsed(now: Date = Date()) -> Duration? {
        guard let startedAt else { return nil }
        return .seconds(max(0, now.timeIntervalSince(startedAt)))
    }

    // MARK: - Private Helpers

    /// A file-name-safe stem for the camera.
    ///
    /// Built from the display name, not the host: a user who renamed a camera expects the files to
    /// follow. Falls back to the id when the name has nothing usable in it, so a camera called `"///"`
    /// still produces a distinguishable file rather than an empty stem.
    private static func slug(for camera: Camera) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = camera.displayName.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? camera.id.rawValue.uuidString : collapsed
    }
}

#endif  // os(macOS)
