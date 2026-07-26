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

// MARK: - RecordingEndReason

/// Why a recording stopped. Reaches the clip record and the log line.
public enum RecordingEndReason: String, Sendable, Hashable, Codable {
    case userStopped
    case durationLimit
    case sizeLimit
    case diskFull
    case formatChanged
    case timestampDiscontinuity
    case streamLost
    case appQuitting
    case noKeyframe
    case writeError
}

// MARK: - RecordingCameraInfo

/// The little the recorder needs to know about the camera: enough to name a file and a log line.
///
/// Deliberately not `Camera`. The recorder has no business with hosts, ports or credentials, and
/// taking the full record would make every recorder test construct one.
public struct RecordingCameraInfo: Sendable, Hashable {

    /// Identity, for log lines and for the clip record.
    public var id: CameraID

    /// Slug for `{camera}`.
    public var slug: String

    /// Display name for `{cameraName}`.
    public var name: String

    /// The zone file names are rendered in — the user's, so `..._231500` is the time on the clock in
    /// the room rather than in UTC.
    public var timeZone: TimeZone

    public init(id: CameraID, slug: String, name: String, timeZone: TimeZone = .current) {
        self.id = id
        self.slug = slug
        self.name = name
        self.timeZone = timeZone
    }
}

// MARK: - RecordingSegmentRecord

/// One finished file.
public struct RecordingSegmentRecord: Sendable, Hashable {

    /// Zero-based index within the recording. Rendered one-based as `{seq}`.
    public var index: Int

    /// Where the file ended up. For an interrupted recording this still carries the `.partial`
    /// suffix, and `isPartial` is true.
    public var url: URL

    /// Wall-clock time of the first written sample.
    public var startedAt: Date

    /// Wall-clock time of the last written sample.
    public var endedAt: Date

    /// Media seconds in the file — the number `AVAsset.duration` will report, not wall-clock elapsed.
    public var mediaSeconds: Double

    /// Size on disk after the finish, from the file system rather than from a sum of sample sizes, so
    /// container overhead is included.
    public var byteCount: Int64

    public var samplesWritten: Int
    public var samplesDropped: Int

    /// True when `finishWriting` did not complete, so the `moov` atom was never written. The file is
    /// still playable up to its last completed fragment and is kept, named `.partial`, for the
    /// recovery scan to adopt.
    public var isPartial: Bool

    public var endReason: RecordingEndReason
}

// MARK: - RecordingProgress

/// What the tile's REC badge shows.
public struct RecordingProgress: Sendable, Hashable {

    /// Media seconds in the current file.
    public var currentSegmentSeconds: Double

    /// Media seconds across every file of this recording, finished ones included.
    public var totalSeconds: Double

    /// Bytes appended to the current file, as a payload estimate.
    public var currentSegmentBytes: Int64

    public var samplesWritten: Int
    public var samplesDropped: Int

    /// Frames discarded because the clip has not opened yet. A non-zero value with a zero
    /// `samplesWritten` is the honest description of "recording, waiting for a keyframe".
    public var heldAwaitingKeyframe: Int

    /// True while the gate is shut.
    public var isAwaitingFirstKeyframe: Bool

    /// True when a limit has been reached and the recorder is waiting for a keyframe to roll over.
    public var isAwaitingKeyframeToRotate: Bool

    /// Files already closed.
    public var completedSegments: Int

    /// Free bytes at the last check.
    public var freeBytes: Int64
}

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

        public init(container: RecordingContainer = .mp4,
                    trigger: String = "manual",
                    nameTemplate: String = RecordingNaming.defaultClipTemplate,
                    limits: RecordingSegmentPlanner.Limits = RecordingSegmentPlanner.Limits(),
                    keyframeRequestAfter: Duration = .seconds(5),
                    keyframeGiveUpAfter: Duration = .seconds(15),
                    fragmentIntervalSeconds: Double = 2,
                    stopBelowFreeBytes: Int64 = 512 << 20,
                    freeSpaceCheckEveryBytes: Int64 = 64 << 20) {
            self.container = container
            self.trigger = trigger
            self.nameTemplate = nameTemplate
            self.limits = limits
            self.keyframeRequestAfter = keyframeRequestAfter
            self.keyframeGiveUpAfter = keyframeGiveUpAfter
            self.fragmentIntervalSeconds = fragmentIntervalSeconds
            self.stopBelowFreeBytes = stopBelowFreeBytes
            self.freeSpaceCheckEveryBytes = freeSpaceCheckEveryBytes
        }
    }

    // MARK: - Dependencies

    private let camera: RecordingCameraInfo
    private let options: Options
    private let destination: RecordingDestination
    private let fileSystem: any RecordingFileSystem
    private let clock: any MonotonicClock
    private let wallClock: any WallClock
    private let logger: any LoggerProtocol

    /// Asks the camera for an IDR. Rate limiting is the supplier's job — this type knows about one
    /// stream and cannot see the per-device budget.
    private let requestKeyframe: @Sendable () -> Void

    // MARK: - State

    /// Parameter sets, so an in-band change can be classified rather than guessed at.
    private var store = ParameterSetStore()

    /// The format description every sample and the writer's `sourceFormatHint` are built from.
    /// Not `Sendable`, and never leaves this actor.
    private var formatDescription: CMVideoFormatDescription?

    /// The codec the recording was started for. A codec change is an incompatible format change.
    private var codec: VideoCodec?

    /// Picture size, for `{res}`. Best effort: `nil` renders as `unknown`.
    private var resolution: Resolution?

    private var writer: RecordingClipWriter?
    private var timeline = RecordingTimeline()
    private var planner: RecordingSegmentPlanner
    private var gate: RecordingKeyframeGate

    /// Files already closed.
    private var completed: [RecordingSegmentRecord] = []

    /// Wall-clock time of the current file's first sample, for the clip record.
    private var currentSegmentStartedAt: Date?

    /// Final URL the current `.partial` file is renamed to on a clean finish.
    private var currentFinalURL: URL?

    /// Media seconds across finished files, so `totalSeconds` survives a rotation.
    private var finishedMediaSeconds: Double = 0

    private var samplesDropped = 0
    private var freeBytes: Int64
    private var bytesSinceFreeSpaceCheck: Int64 = 0

    /// True between `start()` and `finish()`.
    private var isRunning = false

    /// True while a rotation is in flight. `append` is an `async` actor method, so another frame can
    /// arrive during the `await` on `finishWriting`; without this flag it would be appended to a
    /// writer that has already been closed.
    private var isRotating = false

    /// Set once, so `finish()` is idempotent and a second call returns the same records.
    private var finishedReason: RecordingEndReason?

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

    // MARK: - Private: the planner's verdict

    /// Carries out one planner decision.
    ///
    /// - Parameter timing: The rebased timing for `frame`, or `nil` when the caller has already
    ///   decided the frame is not going into the current file.
    private func performPlannerDecision(_ decision: RecordingSegmentPlanner.Decision,
                                        frame: EncodedFrame,
                                        format: CMVideoFormatDescription,
                                        timing: RecordingSampleTiming?) async {
        switch decision {
        case .write:
            guard let timing else { return }
            await write(frame, format: format, timing: timing)

        case .rotate(let reason):
            await rotate(reason: reason)
            // The keyframe that triggered the rotation is the new file's first sample. Its timing is
            // re-derived, because the new file's timeline starts again at its own zero.
            await appendAsFirstSampleOfNewSegment(frame, format: format)

        case .closeBeforeWriting(let reason):
            await rotate(reason: reason)
            // A format change means `formatDescription` has already been replaced, so the new
            // segment's writer is built from the new hint and this frame — if it is a keyframe — opens
            // it. If it is not, the gate holds until one arrives.
            if let current = formatDescription {
                await appendAsFirstSampleOfNewSegment(frame, format: current)
            }

        case .stop(let reason):
            await stop(reason: reason == .diskPressure ? .diskFull : .userStopped)
        }
    }

    /// Opens a segment if needed and writes one sample into it.
    private func write(_ frame: EncodedFrame, format: CMVideoFormatDescription,
                       timing: RecordingSampleTiming) async {
        if writer == nil {
            guard await openSegment(format: format) else { return }
            currentSegmentStartedAt = wallClock.now
        }
        guard let writer else { return }

        do {
            let sample = try RecordingSampleFactory.make(frame, format: format, timing: timing)
            let outcome = try writer.append(sample, presentation: timing.presentation,
                                            duration: timing.duration,
                                            isKeyframe: frame.isKeyframe)
            if outcome == .droppedInputNotReady {
                // Not fatal and not silent: a run of these is a disk that cannot keep up, and the
                // count is what tells the difference between that and a camera that stopped sending.
                logger.debug(.core, "recording dropped a sample: input not ready",
                             ["camera": camera.id.short])
            }
            bytesSinceFreeSpaceCheck += Int64(frame.byteCount)
            if bytesSinceFreeSpaceCheck >= options.freeSpaceCheckEveryBytes {
                bytesSinceFreeSpaceCheck = 0
                checkFreeSpace()
            }
        } catch let error as RecordingError {
            logger.error(.core, "recording write failed", metadataFor(error))
            await stop(reason: error == .firstSampleNotKeyframe ? .noKeyframe : .writeError)
        } catch {
            // `RecordingSampleFactory` throws `DecodeError`. A frame CoreMedia refuses is dropped;
            // it is not a reason to end a recording that is otherwise healthy.
            samplesDropped += 1
            logger.warning(.core, "recording could not build a sample buffer",
                           ["camera": camera.id.short, "detail": String(describing: error)])
        }
    }

    /// Writes `frame` as the first sample of a freshly opened segment.
    private func appendAsFirstSampleOfNewSegment(_ frame: EncodedFrame,
                                                 format: CMVideoFormatDescription) async {
        switch gate.admit(isKeyframe: frame.isKeyframe, now: clock.now()) {
        case .write:
            break
        case .holdAwaitingKeyframe, .holdAndRequestKeyframe:
            return
        case .giveUp:
            await stop(reason: .noKeyframe)
            return
        }
        switch timeline.admit(presentation: TimestampConversion.cmTime(frame.pts),
                              decode: frame.dts.map(TimestampConversion.cmTime) ?? CMTime.invalid,
                              duration: frame.duration.map(TimestampConversion.cmTime)
                                  ?? CMTime.invalid) {
        case .write(let timing, _):
            await write(frame, format: format, timing: timing)
        case .rejectInvalidTimestamp, .requiresNewSegment:
            samplesDropped += 1
        }
    }

    // MARK: - Private: segments

    /// Creates the writer for the next file. Returns false when it could not be created, in which
    /// case the recording has already been stopped with a named reason.
    private func openSegment(format: CMVideoFormatDescription) async -> Bool {
        let context = RecordingNameContext(cameraSlug: camera.slug,
                                           cameraName: camera.name,
                                           date: wallClock.now,
                                           timeZone: camera.timeZone,
                                           segmentIndex: planner.segmentIndex,
                                           resolution: resolution,
                                           codec: codec,
                                           trigger: options.trigger)
        let relative = RecordingNaming.render(options.nameTemplate, context: context)
        let fileExtension = options.container.fileExtension
        let partialExtension = fileExtension + ".partial"

        // Split by hand rather than through `NSString.lastPathComponent`: `render` already guarantees
        // a `/`-separated relative path with no empty components, and staying in Swift keeps this
        // testable in the shadow harness, where the Objective-C bridge is not what the customer will
        // run.
        let parts = relative.split(separator: "/").map(String.init)
        let baseName = parts.last ?? "clip"
        let parentComponents = parts.dropLast()
        let parent = parentComponents.reduce(destination.directory) { url, component in
            url.appendingPathComponent(component, isDirectory: true)
        }

        do {
            try fileSystem.createDirectory(at: parent)
        } catch {
            await stop(reason: .writeError, error: error)
            return false
        }

        // A name is only free when neither the final nor the `.partial` spelling is taken, so a
        // recorder cannot claim the name another recorder is still writing.
        let unique = RecordingNaming.uniqueBaseName(
            baseName,
            extensions: [fileExtension, partialExtension],
            uniqueSuffix: camera.id.short) { candidate, suffix in
                fileSystem.itemExists(at: parent.appendingPathComponent("\(candidate).\(suffix)"))
            }

        let partialURL = parent.appendingPathComponent("\(unique).\(partialExtension)")
        currentFinalURL = parent.appendingPathComponent("\(unique).\(fileExtension)")

        let configuration = RecordingClipWriter.Configuration(
            container: options.container,
            fragmentIntervalSeconds: options.fragmentIntervalSeconds,
            expectsMediaDataInRealTime: true)
        do {
            writer = try RecordingClipWriter(outputURL: partialURL, formatDescription: format,
                                            configuration: configuration)
        } catch {
            await stop(reason: .writeError, error: error)
            return false
        }
        logger.info(.core, "recording segment opened",
                    ["camera": camera.id.short,
                     "segment": String(planner.segmentIndex),
                     "path": Redact.path(partialURL.path)])
        return true
    }

    /// Closes the current file and prepares the next one.
    private func rotate(reason: RecordingSegmentReason) async {
        isRotating = true
        await closeCurrentSegment(reason: endReason(for: reason))
        timeline.reset()
        gate.reset(now: clock.now())
        currentSegmentStartedAt = nil
        isRotating = false
    }

    /// Finishes the current writer and records the result.
    private func closeCurrentSegment(reason: RecordingEndReason) async {
        guard let writer else { return }
        self.writer = nil

        let startedAt = currentSegmentStartedAt ?? wallClock.now
        let mediaSeconds = timeline.writtenSeconds

        // **This is the await that must not be skipped.** Until `finishWriting`'s handler runs, the
        // `moov` atom is not on disk and the file is unusable; skipping it is `abandon()`, which is a
        // deliberate, named, logged fallback rather than something to do by accident.
        let outcome = await withCheckedContinuation {
            (continuation: CheckedContinuation<RecordingClipWriter.FinishOutcome, Never>) in
            writer.finish { outcome in
                continuation.resume(returning: outcome)
            }
        }

        switch outcome {
        case .completed:
            var finalURL = writer.outputURL
            if let intended = currentFinalURL {
                do {
                    try fileSystem.moveItem(at: writer.outputURL, to: intended)
                    finalURL = intended
                } catch {
                    // The media is safe; only the name is wrong. Keeping the `.partial` name and
                    // saying so is better than pretending the rename happened.
                    logger.error(.core, "recording finished but could not be renamed",
                                 metadataFor(error))
                }
            }
            let isPartial = finalURL == writer.outputURL
            completed.append(record(for: writer, startedAt: startedAt, url: finalURL,
                                    isPartial: isPartial, reason: reason,
                                    mediaSeconds: mediaSeconds))
            finishedMediaSeconds += mediaSeconds
            logger.info(.core, "recording segment finished",
                        ["camera": camera.id.short,
                         "path": Redact.path(finalURL.path),
                         "seconds": String(format: "%.2f", mediaSeconds),
                         "samples": String(writer.samplesWritten)])

        case .failed(let error):
            logger.error(.core, "recording segment failed to finish", metadataFor(error))
            completed.append(record(for: writer, startedAt: startedAt, url: writer.outputURL,
                                    isPartial: true, reason: .writeError,
                                    mediaSeconds: mediaSeconds))
            finishedMediaSeconds += mediaSeconds

        case .nothingWritten:
            // `cancelWriting` already removed the empty output, so there is nothing to record and
            // nothing to clean up.
            logger.notice(.core, "recording segment closed with no samples",
                          ["camera": camera.id.short])
        }
        currentFinalURL = nil
    }

    /// Stops the recording for good.
    private func stop(reason: RecordingEndReason, error: (any Error)? = nil) async {
        guard finishedReason == nil else { return }
        finishedReason = reason
        isRunning = false
        if let error {
            logger.error(.core, "recording stopping after a failure", metadataFor(error))
        }
        await closeCurrentSegment(reason: reason)
    }

    // MARK: - Private: format

    /// Adopts parameter sets, rebuilding the format description when they actually changed.
    ///
    /// Only an **incompatible** change forces a new file. A compatible one — a new PPS id, a
    /// different SAR or crop — leaves the current file alone on purpose: Hikvision sends the
    /// parameter sets *in band, inside the access units*, so a decoder reading the file gets them
    /// from the bitstream whatever the container's `avcC`/`hvcC` says. Splitting on every PPS tweak
    /// would shred a recording into dozens of files for no gain.
    private func adopt(_ sets: ParameterSets, codec frameCodec: VideoCodec) {
        let change = store.ingest(sets)
        switch change {
        case .unchanged:
            return
        case .firstSet, .compatible:
            rebuildFormatDescription(codec: frameCodec, forcesNewSegment: false)
        case .incompatible:
            rebuildFormatDescription(codec: frameCodec, forcesNewSegment: writer != nil)
        }
    }

    /// Builds the format description from the stored sets.
    private func rebuildFormatDescription(codec frameCodec: VideoCodec, forcesNewSegment: Bool) {
        guard let sets = store.sets else { return }
        do {
            formatDescription = try FormatDescriptionFactory.make(codec: frameCodec,
                                                                  parameterSets: sets,
                                                                  info: store.format)
            codec = frameCodec
            if let parsed = store.format {
                resolution = Resolution(width: parsed.displayWidth, height: parsed.displayHeight)
            }
            if forcesNewSegment {
                planner.requireImmediateClose(.formatChanged)
            }
        } catch {
            // Discard the sets so the next in-band copy is treated as new rather than as an
            // `.unchanged` re-send; otherwise one bad SPS wedges the recording forever.
            store.reset()
            logger.error(.core, "recording could not build a format description",
                         metadataFor(error))
        }
    }

    // MARK: - Private: disk

    /// Re-reads free space and stops cleanly if the reserve is gone.
    private func checkFreeSpace() {
        guard let measured = fileSystem.availableCapacity(at: destination.directory) else { return }
        freeBytes = measured
        guard measured < options.stopBelowFreeBytes else { return }
        logger.warning(.core, "recording stopping: free space below the reserve",
                       ["camera": camera.id.short, "freeBytes": String(measured)])
        planner.requireImmediateClose(.diskPressure)
    }

    // MARK: - Private: helpers

    /// Bytes in the current file, from the file system when it can answer and from the appended
    /// payload otherwise. The file system's number includes container overhead, which is what the
    /// size limit is actually about.
    private func currentSegmentBytes() -> Int64 {
        guard let writer else { return 0 }
        return fileSystem.fileSize(at: writer.outputURL) ?? writer.appendedByteCount
    }

    /// Builds the record for a finished file.
    private func record(for writer: RecordingClipWriter, startedAt: Date, url: URL,
                        isPartial: Bool, reason: RecordingEndReason,
                        mediaSeconds: Double? = nil) -> RecordingSegmentRecord {
        RecordingSegmentRecord(
            index: completed.count,
            url: url,
            startedAt: startedAt,
            endedAt: wallClock.now,
            mediaSeconds: mediaSeconds ?? timeline.writtenSeconds,
            byteCount: fileSystem.fileSize(at: url) ?? writer.appendedByteCount,
            samplesWritten: writer.samplesWritten,
            samplesDropped: writer.samplesDropped,
            isPartial: isPartial,
            endReason: reason)
    }

    /// The end reason a segment reason implies.
    private func endReason(for reason: RecordingSegmentReason) -> RecordingEndReason {
        switch reason {
        case .durationLimit: .durationLimit
        case .sizeLimit: .sizeLimit
        case .formatChanged: .formatChanged
        case .timestampDiscontinuity: .timestampDiscontinuity
        case .diskPressure: .diskFull
        case .requestedByOwner: .userStopped
        }
    }

    /// Log metadata for an error, redacted, with the camera on it.
    ///
    /// A `VigilFailure` contributes its own already-redacted metadata; anything else contributes its
    /// description through `Redact.secrets`, because a framework message can carry a path.
    private func metadataFor(_ error: any Error) -> [String: String] {
        var metadata = ["camera": camera.id.short]
        if let failure = error as? any VigilFailure {
            metadata["code"] = failure.diagnosticCode
            for (key, value) in failure.logMetadata { metadata[key] = value }
        } else {
            metadata["detail"] = Redact.secrets(in: String(describing: error))
        }
        return metadata
    }
}

#endif
