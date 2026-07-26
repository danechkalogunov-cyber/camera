//
//  DecodePipeline.swift
//  VigilVideo
//
//  The actor that owns one stream's format description, detects a format change, turns each
//  `EncodedFrame` into a `CMSampleBuffer` and hands it to a `VideoSink`.
//  Implements docs/API_CONTRACT.md §4.9 and docs/spec-video-pipeline.md §6 and §9, reduced to the
//  "first light" slice.
//
//  **This code has never been compiled.** There is no CoreMedia on Linux.
//
//  SLICE SCOPE (.vigil/SLICE.md). This is the `AVSampleBufferDisplayLayer` + `DisplayImmediately`
//  path and nothing else. Absent, and landing with their own manifest rows later: the
//  `VTDecompressionSession` strategy, `DecodeBudget` admission, the frame queue and its drop
//  policy, the latency ladder, audio, snapshots, statistics reservoirs, `PipelineEvent`. The
//  pipeline does **not** create or own an `AVSampleBufferDisplayLayer`: in the slice the layer
//  belongs to `VigilRender`'s tile view, which is the `VideoSink`.
//

#if os(macOS)

import CoreMedia
import VigilBitstream
import VigilProtocols

// MARK: - DecodePipeline

/// One stream's decode pipeline.
///
/// An actor because it owns mutable per-stream state — the parameter-set store, the current format
/// description, the generation counter — that the transport task, the UI and the render layer all
/// reach for. Everything it hands the sink is handed synchronously, on the actor's own executor, so
/// no non-`Sendable` CoreMedia object ever crosses an isolation boundary.
public actor DecodePipeline {

    // MARK: - Counters

    /// What the pipeline has done with the frames it was given. The slice's stand-in for the
    /// contract's `DecodeStatistics`, which carries latency reservoirs this build has no clock for.
    public struct Counters: Sendable, Hashable {

        /// Sample buffers handed to the sink.
        public var framesEnqueued: UInt64 = 0

        /// Dropped because no parameter sets had arrived, so there was no format description.
        public var framesDroppedNoFormat: UInt64 = 0

        /// Dropped while waiting for the IDR/IRAP that makes decoding restartable.
        public var framesDroppedAwaitingKeyframe: UInt64 = 0

        /// Dropped because the access unit was corrupt, malformed, or rejected by CoreMedia.
        public var framesDroppedBadData: UInt64 = 0

        /// Dropped because the frame was not video, or was MJPEG, which this path does not decode.
        public var framesDroppedPolicy: UInt64 = 0

        /// Format descriptions built. Includes the first one.
        public var formatDescriptionsBuilt: UInt64 = 0

        /// The last error reported to `onError`, kept so a diagnostics panel can show it without
        /// having to have been listening at the time.
        public var lastError: VigilError?

        /// Builds an all-zero set of counters.
        public init() {}
    }

    // MARK: - Stored Properties

    /// Where sample buffers go. Held strongly: the pipeline outlives no sink it does not own, and
    /// `VigilCore` tears the pipeline down when the tile goes away.
    private let sink: any VideoSink

    /// `.live` for the slice: every sample carries `DisplayImmediately` and there is no timebase.
    private let pacing: PacingMode

    /// Asks the camera for an IDR. Called when decoding cannot proceed without one.
    ///
    /// - Important: **not** rate-limited here. The contract's
    ///   `maximumKeyframeRequestsPerMinute = 10` is enforced by whoever supplies this closure,
    ///   because it is a per-device budget and this type only knows about one stream.
    private let requestKeyframe: @Sendable () -> Void

    /// Every error the pipeline meets. `submit` never throws — a per-frame failure must not unwind
    /// a caller on the frame path — so this is the only way a failure leaves the pipeline, and it
    /// is required at init for exactly that reason.
    private let onError: @Sendable (VigilError) -> Void

    /// Merges parameter sets and classifies each change. Lives in `VigilBitstream` because the
    /// comparison is a bitstream question, not a CoreMedia one.
    private var store = ParameterSetStore()

    /// The format description every sample buffer is built against. `nil` until the first complete
    /// parameter set arrives, and again after a set that CoreMedia rejected.
    private var formatDescription: CMVideoFormatDescription?

    /// The neutral description of `formatDescription`, for the sink. Never `nil` while
    /// `formatDescription` is non-`nil`: when our own SPS parse failed we fall back to CoreMedia's
    /// dimensions rather than blocking the picture.
    private var formatInfo: VideoFormatInfo?

    /// Bumps on every parameter-set change, compatible or not. Taken from the store so the two can
    /// never disagree.
    private var generation: UInt32 = 0

    /// The §3.3 duration chain.
    private var estimator = DurationEstimator()

    /// True until an IDR/IRAP has been seen. Set at start, after a format change, and after any
    /// frame the decoder cannot be trusted to have survived.
    private var awaitingKeyframe = true

    /// True once a keyframe has been asked for and not yet arrived. Without it a stream that sends
    /// corrupt access units continuously would ask the camera for an IDR **once per frame**, which
    /// is a denial of service against the camera dressed up as error handling.
    private var keyframeRequested = false

    /// True once `stop()` has run. A late `submit` after teardown is ignored rather than reviving
    /// the stream.
    private var isStopped = false

    private var counters = Counters()

    // MARK: - Initialisation

    /// Builds a pipeline for one stream.
    ///
    /// - Parameters:
    ///   - sink: Where sample buffers go.
    ///   - pacing: `.live` for the live path. `.paced` omits `DisplayImmediately` and is for
    ///     recorded playback, which the slice does not build.
    ///   - requestKeyframe: Asks the camera for an IDR. See the property's note on rate limiting.
    ///   - onError: Receives every failure. Required, not defaulted: a swallowed decode error is
    ///     "no video, no error" on the customer's machine.
    public init(sink: any VideoSink,
                pacing: PacingMode = .live,
                requestKeyframe: @escaping @Sendable () -> Void,
                onError: @escaping @Sendable (VigilError) -> Void) {
        self.sink = sink
        self.pacing = pacing
        self.requestKeyframe = requestKeyframe
        self.onError = onError
    }

    // MARK: - Public API

    /// Takes one access unit.
    ///
    /// Never throws and never blocks. A frame it cannot use is counted, reported to the sink with a
    /// `FrameDropReason`, and — where the failure means the decoder has lost its footing — followed
    /// by a keyframe request.
    ///
    /// Order matters: parameter sets are ingested **before** the keyframe gate, because they arrive
    /// attached to the very keyframe the gate is waiting for.
    public func submit(_ frame: EncodedFrame) {
        guard !isStopped else { return }

        // MJPEG has no parameter sets and is decoded by the ImageIO path; audio does not belong
        // here at all.
        guard let codec = frame.videoCodec, codec.isNALBased else {
            drop(reason: .policy)
            return
        }

        if let sets = frame.parameterSets {
            adopt(sets, codec: codec)
        }

        guard let description = formatDescription, let info = formatInfo else {
            drop(reason: .noFormat)
            return
        }

        if awaitingKeyframe {
            guard frame.isKeyframe else {
                drop(reason: .awaitingKeyframe)
                return
            }
            awaitingKeyframe = false
        }

        // A frame with a lost or truncated NAL decodes into visible corruption that persists until
        // the next IDR, so it costs less to drop it and ask for one.
        guard !frame.isCorrupt else {
            drop(reason: .badData)
            waitForKeyframe()
            return
        }

        let duration = estimator.duration(for: frame)

        do {
            let sample = try SampleBufferBuilder.make(frame, format: description,
                                                      duration: duration, pacing: pacing)
            // Synchronous, on this actor's executor: `CMSampleBuffer` crosses no isolation
            // boundary. The sink must return in under 2 ms.
            sink.enqueue(sample, format: info, generation: generation)
            counters.framesEnqueued &+= 1
        } catch {
            report(error)
            drop(reason: .badData)
            waitForKeyframe()
        }
    }

    /// The current format, or `nil` before the first parameter set.
    public func currentFormat() -> VideoFormatInfo? {
        formatInfo
    }

    /// The current generation. Bumps on every parameter-set change.
    public func currentGeneration() -> UInt32 {
        generation
    }

    /// A snapshot of the counters.
    public func statistics() -> Counters {
        counters
    }

    /// Forgets everything about the stream: parameter sets, format description, generation and the
    /// duration history. Counters are kept, because they are cumulative for the session.
    ///
    /// Call on reconnect. The sink is told, so it can show its "reconnecting" state **over** the
    /// frozen last frame — it must not clear to black (API_CONTRACT §4.9, the no-black-flash rule).
    public func reset() {
        store.reset()
        formatDescription = nil
        formatInfo = nil
        generation = 0
        estimator.reset()
        estimator.nominalFrameRate = nil
        awaitingKeyframe = true
        sink.streamDidReset()
    }

    /// Stops the pipeline. Later `submit` calls are ignored.
    public func stop(reason: StreamEndReason = .stopped) {
        guard !isStopped else { return }
        isStopped = true
        sink.streamDidEnd(reason: reason)
    }

    // MARK: - Private: format changes

    /// Merges new parameter sets and rebuilds the format description if they actually changed.
    ///
    /// The byte-for-byte re-send Hikvision performs before every IDR lands on `.unchanged` and
    /// costs one comparison. Rebuilding on every GOP instead is the single most common performance
    /// bug in players of this kind (spec §4.5).
    private func adopt(_ sets: ParameterSets, codec: VideoCodec) {
        switch store.ingest(sets) {
        case .unchanged:
            return
        case .firstSet:
            // No decode session exists yet, so nothing can be "kept": treat it as incompatible and
            // wait for a keyframe, which the frame carrying these sets almost certainly is.
            rebuild(codec: codec, incompatible: true)
        case .compatible:
            // Crop, SAR, colour, frame rate, level, a new PPS: rebuild the format description,
            // bump the generation, keep everything else (API_CONTRACT §4.9 / `VideoFormatInfo`).
            rebuild(codec: codec, incompatible: false)
        case .incompatible:
            // Codec, coded width, coded height, chroma format or luma bit depth. This is the only
            // thing that counts as a format change.
            rebuild(codec: codec, incompatible: true)
        }
    }

    /// Builds a format description from the stored sets and announces the change.
    ///
    /// `willChangeFormat` and `didChangeFormat` are always called as a pair, for a compatible
    /// change as much as an incompatible one, so a sink that pins its last image on the first can
    /// rely on the second arriving. Between them the sink must keep showing what it has: no black
    /// frame, no `flush(removingDisplayedImage:)`, no resize of the hosting view (spec §9.2).
    ///
    /// On failure the stored sets are **discarded** so the next in-band copy is treated as new
    /// rather than as an `.unchanged` re-send — otherwise one rejected SPS would wedge the stream
    /// forever. The RTSP session is left alone: a bad parameter set is not a reason to reconnect.
    private func rebuild(codec: VideoCodec, incompatible: Bool) {
        guard let sets = store.sets else { return }

        let parsed = store.format
        let nextGeneration = store.generation

        do {
            let description = try FormatDescriptionFactory.make(codec: codec,
                                                                parameterSets: sets,
                                                                info: parsed)
            // Our SPS parse is metadata; VideoToolbox's is authoritative and more permissive. When
            // ours failed we describe the format from CoreMedia's dimensions rather than refusing
            // to show a picture (spec-bitstream.md §21.1).
            let info = parsed ?? FormatDescriptionFactory.fallbackFormatInfo(for: description,
                                                                             codec: codec)

            sink.willChangeFormat(from: formatInfo, to: info, generation: nextGeneration)

            formatDescription = description
            formatInfo = info
            generation = nextGeneration
            estimator.nominalFrameRate = info.frameRate
            counters.formatDescriptionsBuilt &+= 1

            if incompatible {
                waitForKeyframe()
            }

            sink.didChangeFormat(to: info, generation: nextGeneration)
        } catch {
            store.reset()
            formatDescription = nil
            formatInfo = nil
            report(error)
            waitForKeyframe()
        }
    }

    // MARK: - Private: bookkeeping

    /// Stops decoding until an IDR/IRAP arrives, and asks for one.
    private func waitForKeyframe() {
        awaitingKeyframe = true
        requestKeyframe()
    }

    /// Counts one dropped frame and tells the sink why.
    private func drop(reason: FrameDropReason) {
        switch reason {
        case .noFormat:
            counters.framesDroppedNoFormat &+= 1
        case .awaitingKeyframe:
            counters.framesDroppedAwaitingKeyframe &+= 1
        case .badData:
            counters.framesDroppedBadData &+= 1
        case .policy, .queueFull, .decoderDropped, .formatChange:
            counters.framesDroppedPolicy &+= 1
        }
        sink.didDropFrames(1, reason: reason)
    }

    /// Records a decode failure and hands it to the error sink. Never swallowed, never logged with
    /// its numeric status stripped: `DecodeError`'s `logMetadata` carries the `OSStatus`.
    private func report(_ error: DecodeError) {
        let wrapped = VigilError.decode(error)
        counters.lastError = wrapped
        onError(wrapped)
    }
}

#endif
