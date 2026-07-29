//
//  ClipRecorder+Segments.swift
//  VigilCore
//
//  Acting on the planner's verdict, then writing the segments that follow from it —
//  format, disk and the helpers around them.
//  Split from ClipRecorder.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

#if os(macOS)

import CoreMedia
import Foundation
import VigilBitstream
import VigilProtocols
import VigilVideo

// MARK: - The planner's verdict, and segments

/// ⚠️ Members are `internal`, not `private`: Swift scopes `private` to one file.
/// `Scripts/lint.py`'s `split-access` rule fails the build on any left behind.
extension ClipRecorder {

    // MARK: - Private: the planner's verdict

    /// Carries out one planner decision.
    ///
    /// - Parameter timing: The rebased timing for `frame`, or `nil` when the caller has already
    ///   decided the frame is not going into the current file.
    func performPlannerDecision(_ decision: RecordingSegmentPlanner.Decision,
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
    func write(_ frame: EncodedFrame, format: CMVideoFormatDescription,
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
                    // ⚠️ Losing this race is not a failure, and reporting it as one is worse than
                    // the race. `MainWindowView.recoverOrphanedClips` renames every `.partial` it
                    // finds to the same name this recorder was about to use, and it can run while
                    // this segment is still closing — `finishWriting` is asynchronous, so the file
                    // is finished and still named `.partial` for as long as its handler takes. The
                    // move then fails with NSFileNoSuchFileError because the file is *already where
                    // it was going*. Reporting the `.partial` path in that case hands the manifest
                    // a URL nothing occupies, which is the actual damage: the clip vanishes from
                    // the library even though the recording is on disk and intact.
                    let verdict = RecordingRenameVerdict.after(
                        partialExists: fileSystem.itemExists(at: writer.outputURL),
                        finalExists: fileSystem.itemExists(at: intended))
                    if verdict == .alreadyThere {
                        finalURL = intended
                        logger.notice(.core, "recording was renamed by the recovery scan first",
                                      ["camera": camera.id.short,
                                       "path": Redact.path(intended.path)])
                    } else {
                        // The media is safe; only the name is wrong. Keeping the `.partial` name
                        // and saying so is better than pretending the rename happened.
                        logger.error(.core, "recording finished but could not be renamed",
                                     metadataFor(error))
                    }
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
    func stop(reason: RecordingEndReason, error: (any Error)? = nil) async {
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
    func adopt(_ sets: ParameterSets, codec frameCodec: VideoCodec) {
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
    func currentSegmentBytes() -> Int64 {
        guard let writer else { return 0 }
        return fileSystem.fileSize(at: writer.outputURL) ?? writer.appendedByteCount
    }

    /// Builds the record for a finished file.
    func record(for writer: RecordingClipWriter, startedAt: Date, url: URL,
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

// MARK: - RecordingRenameVerdict

/// What a failed `.partial` → final rename actually achieved, read from what is on disk afterwards.
///
/// A rename can fail for two reasons that look identical to `FileManager` and mean opposite things
/// to the user. Either nothing moved — the file is still `.partial` and the recording is fine but
/// misnamed — or the file is *already at its destination*, because
/// `MainWindowView.recoverOrphanedClips` swept the folder while `finishWriting` was still running
/// and renamed it first. Both throw; only one is a problem.
///
/// Extracted from the `catch` so the rule can be asserted. Getting it wrong is invisible at the
/// call site — the recording plays either way — and shows up only as a clip missing from the
/// library, because the segment record points at a `.partial` path nothing occupies.
package enum RecordingRenameVerdict: Sendable, Hashable {

    /// The `.partial` is gone and the final name exists: the move happened, by whichever hand.
    case alreadyThere

    /// The `.partial` is still there: nothing moved, and the clip keeps its provisional name.
    case stillPartial

    /// Neither exists. The file was deleted out from under the recorder, which no amount of
    /// renaming will fix and which must never be reported as a successful clip.
    case vanished

    /// Reads the verdict from the two existence checks.
    package static func after(partialExists: Bool, finalExists: Bool) -> RecordingRenameVerdict {
        switch (partialExists, finalExists) {
        // Both present is `stillPartial` on purpose: something else owns the final name and this
        // recording is not it, so claiming that name would attribute another clip's file to this
        // segment.
        case (true, _): .stillPartial
        case (false, true): .alreadyThere
        case (false, false): .vanished
        }
    }
}

#endif
