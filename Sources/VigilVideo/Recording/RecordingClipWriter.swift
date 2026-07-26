//
//  RecordingClipWriter.swift
//  VigilVideo
//
//  One `AVAssetWriter` in **passthrough** mode: the compressed samples the camera already produced,
//  muxed into MP4/MOV with no decode and no encode.
//  Implements docs/spec-core.md §9.1–§9.2, §9.8 and docs/FEATURES.md F-REC-01.
//
//  **No compiler in this container has AVFoundation.** Every call below carries the signature it was
//  written against, and the shadow harness under scratchpad/shadow-recording type-checks the file
//  against stubs of exactly those signatures on Linux.
//
//  Deliberately **not** an actor and deliberately not `Sendable`. `CMSampleBuffer` must never cross
//  an isolation boundary (docs/ARCHITECTURE.md §5.9), so an actor here would be unusable: every
//  `append` would be a `Sendable` violation. Instead this is a plain reference type that is confined
//  to whatever actor owns it — `VigilCore`'s `ClipRecorder` — which builds its sample buffers on its
//  own executor and never lets one escape.
//

#if os(macOS)

import AVFoundation
import CoreMedia
import Foundation
import VigilProtocols

// MARK: - RecordingContainer

/// The two containers Vigil writes.
public enum RecordingContainer: String, Sendable, Hashable, Codable, CaseIterable {

    /// MP4. The default: every player and every browser reads it.
    case mp4

    /// QuickTime movie. Required when the audio track is G.711, which MP4 cannot legally carry
    /// (spec-core §9.10). Video passthrough is identical in both.
    case mov

    /// The file extension, without the dot.
    public var fileExtension: String { rawValue }

    /// The `AVFileType` for this container.
    ///
    /// Signature: `struct AVFileType: RawRepresentable` with `static let mp4: AVFileType` and
    /// `static let mov: AVFileType`. Their raw values are the UTIs `"public.mpeg-4"` and
    /// `"com.apple.quicktime-movie"`.
    package var fileType: AVFileType {
        switch self {
        case .mp4: AVFileType.mp4
        case .mov: AVFileType.mov
        }
    }
}

// MARK: - RecordingClipWriter

/// A single output file.
///
/// The four traps this type is built around, each of which produces a **broken file rather than an
/// error**, and none of which any status code will tell you about:
///
/// 1. **`outputSettings: nil` is passthrough.** Anything non-`nil` silently switches
///    `AVAssetWriterInput` into transcoding, which is a hardware encoder per recording — sixteen
///    cameras would be sixteen encoders. The `sourceFormatHint` is what makes `nil` legal.
/// 2. **The first sample must be a keyframe.** `append` accepts a P-frame and writes a well-formed
///    file that decodes to garbage. `RecordingKeyframeGate` is the primary defence; the check in
///    `append` below is the second one, at the only place the damage can be done.
/// 3. **`startSession(atSourceTime:)` takes the first sample's presentation timestamp**, which is
///    why it is called from the first `append` rather than from `init`. A hardcoded `CMTime.zero`
///    against samples that begin at an arbitrary RTP timestamp yields a file whose media starts
///    hours in: playable, empty, no error.
/// 4. **`finishWriting` is asynchronous.** Until its completion handler runs, the `moov` atom has
///    not been written and the file is unusable. `finish(completion:)` is the only correct way out;
///    `movieFragmentInterval` is the safety net for the case where the process dies anyway.
package final class RecordingClipWriter {

    // MARK: - Nested Types

    /// Writer options that are set before `startWriting()` and cannot be changed afterwards.
    package struct Configuration: Sendable, Hashable {

        /// Container.
        package var container: RecordingContainer

        /// Seconds between movie fragments, or 0 to disable fragmentation.
        ///
        /// Two seconds by default. This is the crash-resilience mechanism: with fragmentation on,
        /// everything up to the last completed fragment is playable even if the `moov` atom is never
        /// written, so a killed process loses at most two seconds instead of the whole file.
        package var fragmentIntervalSeconds: Double

        /// `true` for live capture. It tells the writer not to wait for a full pipeline before
        /// writing, at the cost of slightly larger files.
        package var expectsMediaDataInRealTime: Bool

        package init(container: RecordingContainer = .mp4,
                     fragmentIntervalSeconds: Double = 2,
                     expectsMediaDataInRealTime: Bool = true) {
            self.container = container
            self.fragmentIntervalSeconds = fragmentIntervalSeconds
            self.expectsMediaDataInRealTime = expectsMediaDataInRealTime
        }
    }

    /// The result of one `append`.
    package enum Appended: Sendable, Hashable {

        /// The sample is in the file.
        case written

        /// `isReadyForMoreMediaData` was false, so the sample was dropped rather than queued. The
        /// alternative — buffering — turns a transient disk stall into unbounded memory growth on
        /// sixteen simultaneous recordings.
        case droppedInputNotReady
    }

    /// The result of finishing.
    package enum FinishOutcome: Sendable, Hashable {

        /// `finishWriting` completed and the `moov` atom is on disk. The file at `outputURL` is
        /// final and playable.
        case completed

        /// The writer failed. The file may still be partially playable when fragmentation was on,
        /// which is why the caller keeps it rather than deleting it.
        case failed(RecordingError)

        /// Nothing was ever written, so there is no file worth keeping.
        case nothingWritten
    }

    // MARK: - Stored Properties

    /// Where the file is being written. The caller uses a `.partial` suffix and renames on
    /// `.completed`, so a file found with that suffix at launch is known to have been interrupted.
    package let outputURL: URL

    package let configuration: Configuration

    /// The writer. Not `Sendable`; confined to this object, which is confined to its owning actor.
    private let writer: AVAssetWriter

    /// The one video input. Passthrough, so it holds no encoder.
    private let videoInput: AVAssetWriterInput

    /// True once `startSession(atSourceTime:)` has been called.
    private var didStartSession = false

    /// Presentation time handed to `startSession(atSourceTime:)`.
    package private(set) var sessionStart: CMTime?

    /// Presentation time plus duration of the last written sample — the argument for
    /// `endSession(atSourceTime:)`.
    private var sessionEnd: CMTime?

    /// Samples written and samples dropped for an unready input.
    package private(set) var samplesWritten: Int = 0
    package private(set) var samplesDropped: Int = 0

    /// Sum of the appended sample sizes. An estimate of the media payload, not of the file size:
    /// the container adds its own atoms, so the caller asks the file system for the real number.
    package private(set) var appendedByteCount: Int64 = 0

    /// True once `finish` or `cancel` has run, so a late `append` cannot resurrect the file.
    package private(set) var isClosed = false

    // MARK: - Initialisation

    /// Creates the writer, adds one passthrough video input, and calls `startWriting()`.
    ///
    /// Signatures this is written against:
    /// ```
    /// init(outputURL: URL, fileType outputFileType: AVFileType) throws
    /// var movieFragmentInterval: CMTime { get set }          // must be set BEFORE startWriting()
    /// var shouldOptimizeForNetworkUse: Bool { get set }
    /// init(mediaType: AVMediaType, outputSettings: [String: Any]?,
    ///      sourceFormatHint: CMFormatDescription?)
    /// var expectsMediaDataInRealTime: Bool { get set }
    /// func canAdd(_ input: AVAssetWriterInput) -> Bool
    /// func add(_ input: AVAssetWriterInput)
    /// func startWriting() -> Bool
    /// var error: (any Error)? { get }
    /// ```
    ///
    /// - Parameters:
    ///   - outputURL: The file to create. Must not already exist — `AVAssetWriter` fails rather than
    ///     truncating, which is the behaviour we want, so the caller resolves collisions first.
    ///   - formatDescription: The `sourceFormatHint`. Built from the stream's parameter sets by
    ///     `FormatDescriptionFactory`; it is what makes `outputSettings: nil` legal, and it carries
    ///     the pixel-aspect and clean-aperture extensions, so no `transform` is needed here (the
    ///     input's default `transform` is already the identity).
    ///   - configuration: Container and fragmentation.
    /// - Throws: `RecordingError.writerFailed` carrying the framework's own domain, numeric code and
    ///   message for every failure — including the `Bool`-returning ones, which have no error object
    ///   of their own and are the ones most often ignored.
    package init(outputURL: URL, formatDescription: CMVideoFormatDescription,
                 configuration: Configuration = Configuration()) throws(RecordingError) {
        self.outputURL = outputURL
        self.configuration = configuration

        let created: AVAssetWriter
        do {
            created = try AVAssetWriter(outputURL: outputURL,
                                        fileType: configuration.container.fileType)
        } catch {
            throw RecordingError.writerFailed(
                RecordingWriterDiagnostics.describe(error, operation: "AVAssetWriter.init"))
        }
        self.writer = created

        // Set BEFORE startWriting(); afterwards it is ignored without complaint, and the crash
        // resilience it buys silently disappears.
        if configuration.fragmentIntervalSeconds > 0 {
            // `CMTime.init(seconds: Double, preferredTimescale: CMTimeScale)`. 600 is the classic
            // QuickTime timescale and divides 2 s exactly.
            created.movieFragmentInterval = CMTime(seconds: configuration.fragmentIntervalSeconds,
                                                  preferredTimescale: 600)
        }
        // Mutually exclusive with fragmentation in practice: `shouldOptimizeForNetworkUse` rewrites
        // the `moov` atom to the front at the end of writing, which is exactly the step we are
        // refusing to depend on.
        created.shouldOptimizeForNetworkUse = false

        // ***THE PASSTHROUGH LINE.*** `outputSettings: nil` means "write the samples as they are".
        // Any dictionary here — even one that names the same codec — creates a compression session.
        let input = AVAssetWriterInput(mediaType: AVMediaType.video,
                                       outputSettings: nil,
                                       sourceFormatHint: formatDescription)
        input.expectsMediaDataInRealTime = configuration.expectsMediaDataInRealTime
        self.videoInput = input

        guard created.canAdd(input) else {
            // The usual cause is a format description the container cannot carry — HEVC into a
            // container that was told MP4 on an OS that will not write `hvc1`, for example. There is
            // no error object for a `false` here, so the message says what was refused.
            throw RecordingError.writerFailed(
                "AVAssetWriter.canAdd returned false for a passthrough video input "
                + "(container=\(configuration.container.rawValue)); "
                + RecordingWriterDiagnostics.describe(created.error, operation: "canAdd"))
        }
        created.add(input)

        guard created.startWriting() else {
            throw RecordingError.writerFailed(
                "AVAssetWriter.startWriting returned false; "
                + RecordingWriterDiagnostics.describe(created.error, operation: "startWriting"))
        }
    }

    // MARK: - Package API

    /// Appends one sample.
    ///
    /// Signatures this is written against:
    /// ```
    /// func startSession(atSourceTime startTime: CMTime)
    /// var isReadyForMoreMediaData: Bool { get }
    /// func append(_ sampleBuffer: CMSampleBuffer) -> Bool
    /// var status: AVAssetWriter.Status { get }     // .unknown .writing .completed .failed .cancelled
    /// ```
    ///
    /// - Parameters:
    ///   - sample: One access unit, already carrying its rebased timing and its `NotSync`
    ///     attachment. Built by `RecordingSampleFactory` on the caller's own executor.
    ///   - presentation: The sample's presentation time. Passed separately because reading it back
    ///     out of the buffer would be a second source of truth for the value that
    ///     `startSession(atSourceTime:)` depends on.
    ///   - duration: The sample's duration, for the `endSession(atSourceTime:)` argument.
    ///   - isKeyframe: True for an IDR/IRAP.
    /// - Throws: `.firstSampleNotKeyframe` when the very first sample is not a keyframe;
    ///   `.writerFailed` when `append` returns false or the writer has already failed.
    @discardableResult
    package func append(_ sample: CMSampleBuffer, presentation: CMTime, duration: CMTime,
                        isKeyframe: Bool) throws(RecordingError) -> Appended {
        guard !isClosed else {
            throw RecordingError.writerFailed("append after the writer was closed")
        }

        if !didStartSession {
            // Trap 2, checked at the only point where it can do harm. The gate upstream should have
            // made this unreachable; if it ever is reached, no file is better than a broken one.
            guard isKeyframe else { throw RecordingError.firstSampleNotKeyframe }

            // Trap 3. The argument is the first sample's *own* presentation time, taken from the
            // sample in hand. Never `CMTime.zero` written as a literal — that is only correct when
            // the timeline has already rebased to zero, and if it has, this value *is* zero.
            writer.startSession(atSourceTime: presentation)
            didStartSession = true
            sessionStart = presentation
        }

        guard videoInput.isReadyForMoreMediaData else {
            samplesDropped += 1
            return .droppedInputNotReady
        }

        guard videoInput.append(sample) else {
            // `append` returning false always means the writer has failed; its `error` carries the
            // reason and the numeric code, and this is the single most commonly swallowed `Bool` in
            // AVFoundation. Swallowing it gives the customer a truncated file and no message.
            throw RecordingError.writerFailed(
                "AVAssetWriterInput.append returned false at pts="
                + RecordingWriterDiagnostics.describe(presentation)
                + " after \(samplesWritten) sample(s); status="
                + RecordingWriterDiagnostics.describe(writer.status) + "; "
                + RecordingWriterDiagnostics.describe(writer.error, operation: "append"))
        }

        samplesWritten += 1
        appendedByteCount += Int64(CMSampleBufferGetTotalSampleSize(sample))
        sessionEnd = CMTimeAdd(presentation, duration)
        return .written
    }

    /// Marks the inputs finished, ends the session at the end of the last written sample, and waits
    /// for `finishWriting` to write the `moov` atom.
    ///
    /// Signatures this is written against:
    /// ```
    /// func markAsFinished()
    /// func endSession(atSourceTime endTime: CMTime)
    /// func finishWriting(completionHandler handler: @escaping () -> Void)
    /// ```
    ///
    /// **`finishWriting` is asynchronous and the file is not valid until its handler runs.** The
    /// handler is invoked on an AVFoundation-internal queue, so `completion` is `@Sendable` and the
    /// caller hops back to its own isolation itself. Nothing in the closure below captures `self`.
    ///
    /// - Parameter completion: Called exactly once, with the outcome. `.completed` is the only value
    ///   after which the file may be renamed out of its `.partial` name.
    package func finish(completion: @escaping @Sendable (FinishOutcome) -> Void) {
        guard !isClosed else {
            completion(.failed(RecordingError.writerFailed("finish called twice")))
            return
        }
        isClosed = true

        guard didStartSession, let end = sessionEnd else {
            // No sample ever reached the file. `cancelWriting` removes the zero-length output rather
            // than leaving a 0-byte `.partial` for the recovery scan to puzzle over.
            writer.cancelWriting()
            completion(.nothingWritten)
            return
        }

        videoInput.markAsFinished()

        // The *end* of the last sample, not its start: ending at the start truncates the final
        // frame's duration to zero, which `AVAssetReader` reports as a short track.
        writer.endSession(atSourceTime: end)

        // Capture only what is `Sendable`: the writer itself must not escape into the handler's
        // queue, so its status and error are read through a box created for the purpose.
        let statusReader = RecordingWriterStatusReader(writer: writer)
        writer.finishWriting {
            completion(statusReader.outcome())
        }
    }

    /// Abandons the file without waiting for `finishWriting`.
    ///
    /// The emergency path for termination: it leaves the fragmented `.partial` file on disk, which is
    /// playable up to the last completed fragment (spec-core §9.9). Use it only when the budget for
    /// a clean finish has already been spent — a clean `finish` is always better.
    package func abandon() {
        guard !isClosed else { return }
        isClosed = true
        videoInput.markAsFinished()
    }

    /// Cancels writing and deletes the output.
    ///
    /// Signature: `func cancelWriting()`.
    package func cancel() {
        guard !isClosed else { return }
        isClosed = true
        writer.cancelWriting()
    }
}

// MARK: - RecordingWriterStatusReader

/// Reads an `AVAssetWriter`'s terminal status from the `finishWriting` completion handler.
///
/// It exists for one reason: `AVAssetWriter` is not `Sendable`, so capturing it in the escaping
/// handler would be a strict-concurrency error at the point where getting the outcome wrong is
/// invisible. The box is `@unchecked Sendable` because it touches the writer only *after*
/// `finishWriting` has completed, at which point `status` and `error` are final and AVFoundation
/// documents them as safe to read from the handler — the exact moment this type is used, and the
/// only one.
private final class RecordingWriterStatusReader: @unchecked Sendable {

    private let writer: AVAssetWriter

    init(writer: AVAssetWriter) {
        self.writer = writer
    }

    /// The outcome, read once the handler has fired.
    func outcome() -> RecordingClipWriter.FinishOutcome {
        // `AVAssetWriter.Status` is an `Int`-backed enum: .unknown, .writing, .completed, .failed,
        // .cancelled. A new case cannot be handled by `@unknown default` here because that produces
        // a warning the moment the SDK gains one; the `default` below is deliberate and terminal.
        switch writer.status {
        case .completed:
            return .completed
        default:
            return .failed(RecordingError.writerFailed(
                "finishWriting ended with status="
                + RecordingWriterDiagnostics.describe(writer.status) + "; "
                + RecordingWriterDiagnostics.describe(writer.error, operation: "finishWriting")))
        }
    }
}

// MARK: - RecordingWriterDiagnostics

/// Turns AVFoundation's failure reporting into a log line that names a number.
///
/// `AVAssetWriter` does not report an `OSStatus`: it reports an `NSError`, very often the generic
/// `AVFoundationErrorDomain -11800 "The operation could not be completed"`, whose actual cause is in
/// `NSUnderlyingErrorKey` as an `OSStatus`-carrying error. A message that omits the underlying code
/// is the difference between a diagnosable bug report and a shrug, so both levels are always
/// included.
package enum RecordingWriterDiagnostics {

    /// A one-line description of an error, with its domain and numeric code, and its underlying
    /// error's domain and numeric code when there is one.
    ///
    /// `error as NSError` is a bridging conversion, not a downcast: every Swift `Error` has an
    /// `NSError` representation, so it cannot fail and needs no `as!`.
    package static func describe(_ error: (any Error)?, operation: String) -> String {
        guard let error else { return "\(operation): no error reported by the framework" }
        let bridged = error as NSError
        var text = "\(operation): \(bridged.domain) \(bridged.code) — \(bridged.localizedDescription)"
        if let underlying = bridged.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " [underlying: \(underlying.domain) \(underlying.code) — "
                + "\(underlying.localizedDescription)]"
        }
        return text
    }

    /// A writer status as a word plus its raw value, so a log line survives an SDK gaining a case.
    package static func describe(_ status: AVAssetWriter.Status) -> String {
        let name: String
        switch status {
        case .unknown: name = "unknown"
        case .writing: name = "writing"
        case .completed: name = "completed"
        case .failed: name = "failed"
        case .cancelled: name = "cancelled"
        default: name = "unrecognised"
        }
        return "\(name)(\(status.rawValue))"
    }

    /// A `CMTime` as `value/timescale`, which is what a reviewer needs; `seconds` hides a bad
    /// timescale behind a plausible-looking number.
    package static func describe(_ time: CMTime) -> String {
        time.isNumeric ? "\(time.value)/\(time.timescale)" : "non-numeric"
    }
}

#endif
