//
//  ClipRecorder.swift
//  VigilCore
//
//  One camera's recording: passthrough muxing of the compressed access units into MP4/MOV, keyframe
//  gating, timestamp rebasing, segment rotation, disk reserve, and the asynchronous finish that has
//  to complete before the process exits.
//  Implements docs/spec-core.md §9 and docs/FEATURES.md F-REC-01.
//
//  **No compiler in this container has AVFoundation.** The framework calls all live one level down in
//  `VigilVideo/Recording/RecordingClipWriter.swift`, which carries their signatures; this file is the
//  policy around them and is type-checked on Linux by the shadow harness under
//  scratchpad/shadow-recording.
//
//  Why `EncodedFrame` and not `CMSampleBuffer` at the boundary: recording must work with **no decode
//  session at all** (spec-core §9.1 — an occluded tile records at full quality while decoding
//  nothing), and `CMSampleBuffer` must never cross an isolation boundary (ARCHITECTURE.md §5.9). The
//  recorder therefore takes the same pure `EncodedFrame` the depacketizer produces and builds its own
//  sample buffers on its own executor, sharing the attachment logic with the display path through
//  `RecordingSampleFactory`.
//

#if os(macOS)

import CoreMedia
import Foundation
import VigilBitstream
import VigilProtocols
import VigilVideo

// MARK: - ClipRecorder

/// Records one camera's live stream to disk without re-encoding it.
///
/// An actor: it owns a writer, a timeline, a gate and a planner, and it performs file I/O — which is
/// exactly why it must not be the same actor as the decode pipeline (ARCHITECTURE.md §6.3).
public actor ClipRecorder {

    // MARK: - Options

    /// Everything the caller can choose.
    public struct Options: Sendable, Hashable {

        /// Container. MP4 unless audio forces MOV, which this wave does not write.
        public var container: RecordingContainer

        /// `{trigger}` in the name template.
        public var trigger: String

        /// Name template. See `RecordingNaming`.
        public var nameTemplate: String

        /// Rotation budgets.
        public var limits: RecordingSegmentPlanner.Limits

        /// Delay before the camera is asked for an IDR while the gate is shut.
        public var keyframeRequestAfter: Duration

        /// Delay before a recording that has seen no keyframe fails.
        public var keyframeGiveUpAfter: Duration

        /// Seconds between movie fragments. 0 disables fragmentation and gives up crash resilience.
        public var fragmentIntervalSeconds: Double

        /// Stop cleanly when free space falls below this. 512 MiB — the point at which continuing
        /// risks taking the whole volume down with us (spec-core §9.6).
        public var stopBelowFreeBytes: Int64

        /// How much media must be written between two free-space checks. Byte-based rather than
        /// time-based so a 4 K stream is checked more often than a CIF one, which is what the risk
        /// actually scales with. 64 MiB, per spec-core §9.6.
        public var freeSpaceCheckEveryBytes: Int64

        /// Preserve source timestamp gaps in one file. Archive export sets this: a ten-second hole
        /// on the camera's card must remain ten seconds of empty time, not be collapsed or split.
        public var preservesSourceGaps: Bool

        public init(container: RecordingContainer = .mp4,
                    trigger: String = "manual",
                    nameTemplate: String = RecordingNaming.defaultClipTemplate,
                    limits: RecordingSegmentPlanner.Limits = RecordingSegmentPlanner.Limits(),
                    keyframeRequestAfter: Duration = .seconds(5),
                    keyframeGiveUpAfter: Duration = .seconds(15),
                    fragmentIntervalSeconds: Double = 2,
                    stopBelowFreeBytes: Int64 = 512 << 20,
                    freeSpaceCheckEveryBytes: Int64 = 64 << 20,
                    preservesSourceGaps: Bool = false) {
            self.container = container
            self.trigger = trigger
            self.nameTemplate = nameTemplate
            self.limits = limits
            self.keyframeRequestAfter = keyframeRequestAfter
            self.keyframeGiveUpAfter = keyframeGiveUpAfter
            self.fragmentIntervalSeconds = fragmentIntervalSeconds
            self.stopBelowFreeBytes = stopBelowFreeBytes
            self.freeSpaceCheckEveryBytes = freeSpaceCheckEveryBytes
            self.preservesSourceGaps = preservesSourceGaps
        }
    }

    // MARK: - Dependencies

    let camera: RecordingCameraInfo
    let options: Options
    let destination: RecordingDestination
    let fileSystem: any RecordingFileSystem
    let clock: any MonotonicClock
    let wallClock: any WallClock
    let logger: any LoggerProtocol

    /// Asks the camera for an IDR. Rate limiting is the supplier's job — this type knows about one
    /// stream and cannot see the per-device budget.
    private let requestKeyframe: @Sendable () -> Void

    // MARK: - State

    /// Parameter sets, so an in-band change can be classified rather than guessed at.
    var store = ParameterSetStore()

    /// The format description every sample and the writer's `sourceFormatHint` are built from.
    /// Not `Sendable`, and never leaves this actor.
    var formatDescription: CMVideoFormatDescription?

    /// The codec the recording was started for. A codec change is an incompatible format change.
    var codec: VideoCodec?

    /// Picture size, for `{res}`. Best effort: `nil` renders as `unknown`.
    var resolution: Resolution?

    var writer: RecordingClipWriter?
    var timeline = RecordingTimeline()
    var planner: RecordingSegmentPlanner
    var gate: RecordingKeyframeGate

    /// Files already closed.
    var completed: [RecordingSegmentRecord] = []

    /// Wall-clock time of the current file's first sample, for the clip record.
    var currentSegmentStartedAt: Date?

    /// Final URL the current `.partial` file is renamed to on a clean finish.
    var currentFinalURL: URL?

    /// Media seconds across finished files, so `totalSeconds` survives a rotation.
    var finishedMediaSeconds: Double = 0

    var samplesDropped = 0
    var freeBytes: Int64
    var bytesSinceFreeSpaceCheck: Int64 = 0

    /// True between `start()` and `finish()`.
    var isRunning = false

    /// True while a rotation is in flight. `append` is an `async` actor method, so another frame can
    /// arrive during the `await` on `finishWriting`; without this flag it would be appended to a
    /// writer that has already been closed.
    var isRotating = false

    /// Set once, so `finish()` is idempotent and a second call returns the same records.
    var finishedReason: RecordingEndReason?

    // MARK: - Initialisation

    /// Builds a recorder. No file is created and no directory is touched until `start`.
    ///
    /// - Parameters:
    ///   - camera: Naming and log identity.
    ///   - options: See `Options`.
    ///   - destination: An already-resolved, verified destination. Resolving it is a separate step so
    ///     a sandbox refusal is reported before a recording appears to start
    ///     (`RecordingDestinationResolver`).
    ///   - fileSystem: The file-system seam.
    ///   - clock: Monotonic time, for the keyframe wait. Injected; nothing here reads a clock
    ///     directly.
    ///   - wallClock: Wall time, for names and for the clip record's `startedAt`. Never for control
    ///     flow — wall time steps when NTP corrects it.
    ///   - logger: Structured logging.
    ///   - requestKeyframe: Asks the camera for an IDR.
    public init(camera: RecordingCameraInfo,
                options: Options = Options(),
                destination: RecordingDestination,
                fileSystem: any RecordingFileSystem,
                clock: any MonotonicClock,
                wallClock: any WallClock,
                logger: any LoggerProtocol,
                requestKeyframe: @escaping @Sendable () -> Void) {
        self.camera = camera
        self.options = options
        self.destination = destination
        self.fileSystem = fileSystem
        self.clock = clock
        self.wallClock = wallClock
        self.logger = logger
        self.requestKeyframe = requestKeyframe
        self.planner = RecordingSegmentPlanner(limits: options.limits)
        self.gate = RecordingKeyframeGate(now: clock.now(),
                                          requestAfter: options.keyframeRequestAfter,
                                          giveUpAfter: options.keyframeGiveUpAfter)
        self.freeBytes = destination.freeBytesAtResolution
        if options.preservesSourceGaps {
            timeline.maximumPreservedGapSeconds = .infinity
            timeline.newSegmentGapSeconds = .infinity
        }
    }

    // MARK: - Public API

    /// Arms the recording.
    ///
    /// **No file is created here.** The writer is opened by the first keyframe, because a writer
    /// created before one leaves a zero-length `.partial` file behind on every stream that never
    /// sends an IDR — and the recovery scan would then have to distinguish those from real
    /// interruptions. The sets from the SDP are adopted when present so the format description is
    /// ready the instant the keyframe arrives.
    ///
    /// - Parameters:
    ///   - codec: The negotiated video codec. `.mjpeg` is refused: it has no parameter sets and
    ///     passthrough muxing of Motion JPEG is not this wave's job.
    ///   - parameterSets: `sprop-*` sets from the SDP, when the camera sent them. Legitimately `nil`
    ///     — Hikvision repeats them in band before every IDR.
    ///   - resolution: For `{res}`.
    /// - Throws: `RecordingError.writerFailed` for an unusable codec, and whatever
    ///   `FormatDescriptionFactory` reports if the SDP's sets are malformed — in which case the
    ///   in-band sets are still given their chance, so this only throws for a hard refusal.
    public func start(codec: VideoCodec, parameterSets: ParameterSets?,
                      resolution: Resolution?) throws(RecordingError) {
        guard !isRunning, finishedReason == nil else {
            throw RecordingError.writerFailed("start called on a recorder that has already run")
        }
        guard codec.isNALBased else {
            throw RecordingError.writerFailed(
                "passthrough recording needs a NAL-based codec; got \(codec.rawValue)")
        }
        self.codec = codec
        self.resolution = resolution
        isRunning = true
        gate.reset(now: clock.now())

        if let parameterSets {
            // A failure here is not fatal: the in-band copy arrives with the next IDR and is tried
            // again. It is logged, not thrown, so a camera with an odd SDP still records.
            adopt(parameterSets, codec: codec)
        }
        logger.info(.core, "recording armed", ["camera": camera.id.short,
                                               "codec": codec.rawValue,
                                               "container": options.container.rawValue])
    }

    /// Takes one access unit.
    ///
    /// Never throws: a per-frame failure must not unwind the caller on the frame path. A failure that
    /// ends the recording sets `finishedReason` and is visible through `progress()` and the log.
    public func append(_ frame: EncodedFrame) async {
        guard isRunning, finishedReason == nil else { return }
        guard !isRotating else {
            samplesDropped += 1
            return
        }
        guard let frameCodec = frame.videoCodec, frameCodec.isNALBased else {
            // Audio, or MJPEG. Not an error; this wave records video only.
            return
        }

        // Parameter sets first: they arrive attached to the very keyframe the gate is waiting for.
        if let sets = frame.parameterSets {
            adopt(sets, codec: frameCodec)
        }
        guard let format = formatDescription else {
            samplesDropped += 1
            return
        }

        // A corrupt access unit written into a file is permanent: unlike the display path there is no
        // next IDR to recover to, because the corruption is now in the customer's evidence.
        guard !frame.isCorrupt else {
            samplesDropped += 1
            return
        }

        switch gate.admit(isKeyframe: frame.isKeyframe, now: clock.now()) {
        case .write:
            break
        case .holdAwaitingKeyframe:
            return
        case .holdAndRequestKeyframe:
            logger.notice(.core, "recording waiting for a keyframe", ["camera": camera.id.short])
            requestKeyframe()
            return
        case .giveUp(let waited):
            logger.error(.core, "recording gave up waiting for a keyframe",
                         ["camera": camera.id.short, "waitedSeconds": String(format: "%.1f", waited)])
            await stop(reason: .noKeyframe)
            return
        }

        let timing: RecordingSampleTiming
        switch timeline.admit(presentation: TimestampConversion.cmTime(frame.pts),
                              decode: frame.dts.map(TimestampConversion.cmTime) ?? CMTime.invalid,
                              duration: frame.duration.map(TimestampConversion.cmTime)
                                  ?? CMTime.invalid) {
        case .write(let value, let discontinuity):
            timing = value
            if let discontinuity {
                logger.warning(.core, "recording corrected a timing discontinuity",
                               ["camera": camera.id.short, "kind": String(describing: discontinuity)])
            }
        case .rejectInvalidTimestamp:
            samplesDropped += 1
            return
        case .requiresNewSegment(let gapSeconds):
            logger.notice(.core, "recording splitting on a timestamp jump",
                          ["camera": camera.id.short,
                           "gapSeconds": String(format: "%.1f", gapSeconds)])
            planner.requireImmediateClose(.timestampDiscontinuity)
            await performPlannerDecision(planner.evaluate(isKeyframe: frame.isKeyframe,
                                                          writtenSeconds: timeline.writtenSeconds,
                                                          writtenBytes: currentSegmentBytes()),
                                         frame: frame, format: format, timing: nil)
            return
        }

        let decision = planner.evaluate(isKeyframe: frame.isKeyframe,
                                        writtenSeconds: timeline.writtenSeconds,
                                        writtenBytes: currentSegmentBytes())
        await performPlannerDecision(decision, frame: frame, format: format, timing: timing)
    }

    /// Tells the recorder the stream's format changed underneath it.
    ///
    /// Passthrough cannot span a format change: the file carries exactly one `sourceFormatHint`. The
    /// current file is closed at once — not at the next keyframe — because the samples after the
    /// change do not belong in it at all.
    public func noteFormatChange() {
        planner.requireImmediateClose(.formatChanged)
    }

    /// Finishes the recording, waiting for `finishWriting` to write the `moov` atom.
    ///
    /// Idempotent: a second call returns the same records without touching the file again.
    ///
    /// - Returns: One record per file written, oldest first. Empty when no keyframe ever arrived, in
    ///   which case no file was created either.
    @discardableResult
    public func finish(reason: RecordingEndReason = .userStopped) async
        -> [RecordingSegmentRecord] {
        await stop(reason: reason)
        return completed
    }

    /// Abandons the recording **without** waiting for `finishWriting`.
    ///
    /// The last-resort path for termination, once the budget for a clean finish is spent. The
    /// fragmented `.partial` file is left on disk: it is playable up to its last completed fragment,
    /// which is the entire reason `fragmentIntervalSeconds` defaults to 2 (spec-core §9.9). A clean
    /// `finish` is always better; this is what makes the difference between losing two seconds and
    /// losing the whole file.
    @discardableResult
    public func abandon(reason: RecordingEndReason = .appQuitting) -> [RecordingSegmentRecord] {
        guard finishedReason == nil else { return completed }
        finishedReason = reason
        isRunning = false

        guard let writer, let startedAt = currentSegmentStartedAt else { return completed }
        writer.abandon()
        completed.append(record(for: writer, startedAt: startedAt, url: writer.outputURL,
                                isPartial: true, reason: reason))
        self.writer = nil
        logger.warning(.core, "recording abandoned; a fragmented partial file was left in place",
                       ["camera": camera.id.short, "path": Redact.path(writer.outputURL.path)])
        return completed
    }

    /// A snapshot of the counters.
    public func progress() -> RecordingProgress {
        RecordingProgress(
            currentSegmentSeconds: timeline.writtenSeconds,
            totalSeconds: finishedMediaSeconds + timeline.writtenSeconds,
            currentSegmentBytes: writer?.appendedByteCount ?? 0,
            samplesWritten: writer?.samplesWritten ?? 0,
            samplesDropped: samplesDropped + (writer?.samplesDropped ?? 0),
            heldAwaitingKeyframe: gate.heldCount,
            isAwaitingFirstKeyframe: !gate.isOpen,
            isAwaitingKeyframeToRotate: planner.isAwaitingKeyframeToRotate,
            completedSegments: completed.count,
            freeBytes: freeBytes)
    }

    /// The records for the files finished so far.
    public func segments() -> [RecordingSegmentRecord] { completed }

    /// Cancels an export and removes every partial or finished segment it produced.
    ///
    /// This is intentionally stronger than ``abandon``: cancellation is a user request to leave no
    /// artifact, while abandonment is the crash-resilience path that keeps a fragmented partial.
    public func cancelAndDelete() {
        guard finishedReason == nil else {
            for segment in completed { try? fileSystem.removeItem(at: segment.url) }
            completed = []
            return
        }
        finishedReason = .cancelled
        isRunning = false
        writer?.cancel()
        if let writer { try? fileSystem.removeItem(at: writer.outputURL) }
        if let currentFinalURL { try? fileSystem.removeItem(at: currentFinalURL) }
        for segment in completed { try? fileSystem.removeItem(at: segment.url) }
        writer = nil
        currentFinalURL = nil
        completed = []
    }
}

#endif
