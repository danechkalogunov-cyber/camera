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
    private struct State: Sendable {
        var recorder: ClipRecorder?
        var preRoll = PreRollBuffer()
        /// Non-nil while a writer is opening. Frames arriving in that interval are held here so
        /// the pre-roll/live join has neither a gap nor an ordering inversion.
        var pending: [EncodedFrame]?
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    /// Creates an empty tap.
    init() {}

    /// Routes one live frame and keeps the bounded history warm even while recording.
    func route(_ frame: EncodedFrame) -> ClipRecorder? {
        state.withLock { state in
            state.preRoll.append(frame)
            if state.pending != nil {
                state.pending?.append(frame)
                return nil
            }
            return state.recorder
        }
    }

    /// The recorder to feed, if any.
    func recorder() -> ClipRecorder? {
        state.withLock { $0.recorder }
    }

    /// Freezes a pre-roll snapshot and starts collecting the frames that follow it.
    func prepareStart(seconds: Double) -> [EncodedFrame] {
        state.withLock { state in
            state.preRoll.targetSeconds = seconds
            state.pending = []
            return state.preRoll.drain(seconds: seconds)
        }
    }

    /// Drains frames that arrived while older pre-roll was appended. Returns `nil` only after the
    /// recorder has been installed atomically, at which point new frames route straight to it.
    func handOffPending(to recorder: ClipRecorder) -> [EncodedFrame]? {
        state.withLock { state in
            guard let pending = state.pending else {
                state.recorder = recorder
                return nil
            }
            if pending.isEmpty {
                state.pending = nil
                state.recorder = recorder
                return nil
            }
            state.pending = []
            return pending
        }
    }

    func cancelStart() {
        state.withLock { state in
            state.pending = nil
            state.recorder = nil
        }
    }

    func detach() {
        state.withLock { $0.recorder = nil }
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
    ///
    /// ⛔ Drives the UI, and **nothing else may use it to decide who owns a file on disk** — see
    /// ``ownsClipFiles``, which is the flag for that and is deliberately wider.
    private(set) var isRecording = false

    /// True from the first moment a clip's file could exist until the last moment it could still be
    /// renamed.
    ///
    /// ⚠️ Wider than ``isRecording`` at both ends, and that gap is a real bug rather than a
    /// hypothetical. `start()` opens the writer inside a `Task`, so a `.partial` file exists before
    /// `isRecording` goes true; `stop()` sets `isRecording` false *synchronously* and only then
    /// spawns the `Task` that awaits `finishWriting` and renames the file. Anything that sweeps the
    /// clips folder while this is true is walking over a file the recorder still owns —
    /// `MainWindowView.recoverOrphanedClips` did exactly that, renamed the live `.partial` out from
    /// under the recorder, and left the finished clip recorded against a path nothing occupied.
    var ownsClipFiles: Bool { isRecording || isSettlingClip }

    /// True while a clip is opening or closing but not streaming — the half of ``ownsClipFiles``
    /// that `isRecording` does not cover.
    private var isSettlingClip = false

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

    /// Starts writing a clip from the oldest retained pre-roll keyframe.
    ///
    /// Returns immediately. The recorder opens asynchronously, receives a keyframe-aligned history,
    /// catches up with frames accumulated during opening, then switches atomically to the live path.
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
               preRollSeconds: Double = 10,
               requestKeyframe: @escaping @Sendable () -> Void) {
        guard !isRecording, !isSettlingClip else { return }

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
        let buffered = tap.prepareStart(seconds: preRollSeconds)
        // Set before the `Task`, not inside it: `recorder.start` opens the writer, so the
        // `.partial` file can exist before any state this method sets asynchronously is visible.
        isSettlingClip = true

        Task {
            do {
                try await recorder.start(codec: codec,
                                         parameterSets: parameterSets,
                                         resolution: resolution)
                // Oldest to newest. Once the frozen snapshot is written, repeatedly take the frames
                // that arrived during the write. The final empty handoff installs the live recorder
                // under the same lock the frame path reads, so no boundary frame can disappear.
                for frame in buffered { await recorder.append(frame) }
                while let pending = tap.handOffPending(to: recorder) {
                    for frame in pending { await recorder.append(frame) }
                }
                isRecording = true
                startedAt = Date()
                lastFailure = nil
                logger.info(.storage, "recording started")
                // `isRecording` carries ownership from here; a clip that opened is no longer
                // settling. On the failure path there is nothing left to own.
                isSettlingClip = false
            } catch {
                tap.cancelStart()
                self.recorder = nil
                isSettlingClip = false
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
        tap.detach()
        isRecording = false
        startedAt = nil
        self.recorder = nil
        // The file outlives `isRecording` by the length of `finishWriting` plus a rename, and that
        // is precisely the window the folder sweep used to walk into.
        isSettlingClip = true

        Task {
            let finished = await recorder.finish(reason: .userStopped)
            completed.append(contentsOf: finished)
            lastFinished = finished
            // Released only after the records are published, so a sweep that starts the instant
            // this flips sees the finished names rather than the `.partial` ones.
            isSettlingClip = false
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
