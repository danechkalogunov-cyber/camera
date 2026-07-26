//
//  RecordingSampleFactory.swift
//  VigilVideo
//
//  One access unit plus a rebased timeline position, turned into the `CMSampleBuffer` a passthrough
//  `AVAssetWriterInput` accepts.
//  Implements docs/spec-core.md §9.2 ("Appending a frame") on top of `Sample/SampleBufferBuilder`.
//
//  **This code has never been compiled against a real CoreMedia.** See the shadow harness under
//  scratchpad/shadow-recording.
//
//  There is no second sample-buffer implementation here on purpose. The display path and the
//  recording path must agree bit-for-bit about the `NotSync` / `DependsOnOthers` attachments,
//  because those are what `AVAssetWriter` builds the `stss` sync-sample table from: get them wrong
//  and the file plays but seeks to the wrong frames. So this file only supplies the two things the
//  recording path needs that the display path does not — a caller-chosen presentation time, and
//  `pacing: .paced` so `DisplayImmediately` is never set on a sample that is going into a file.
//

#if os(macOS)

import CoreMedia
import VigilProtocols

// MARK: - RecordingSampleFactory

/// Builds sample buffers for the recorder.
package enum RecordingSampleFactory {

    /// Wraps `frame` for the writer, at the timeline position `timing` gives it.
    ///
    /// - Parameters:
    ///   - frame: One access unit: 4-byte big-endian length-prefixed NAL units, never Annex-B. The
    ///     prefix walk is validated inside `SampleBufferBuilder` before anything is allocated.
    ///   - format: The `sourceFormatHint` the writer was created with. It **must** be the same
    ///     description, or the samples describe a format the file does not declare — which is why a
    ///     parameter-set change forces a new segment rather than a new format description.
    ///   - timing: The rebased position from `RecordingTimeline`.
    /// - Returns: A ready sample buffer, with `NotSync` set on non-keyframes and
    ///   `DisplayImmediately` set on nothing.
    /// - Throws: `DecodeError.badData` for an empty, non-video or malformed access unit, and
    ///   `.blockBufferFailed(status:)` / `.sampleBufferFailed(status:)` carrying the numeric
    ///   `OSStatus` for every CoreMedia failure.
    package static func make(_ frame: EncodedFrame, format: CMVideoFormatDescription,
                             timing: RecordingSampleTiming) throws(DecodeError) -> CMSampleBuffer {
        guard let codec = frame.videoCodec, codec.isNALBased else {
            throw DecodeError.badData
        }
        let block = try SampleBufferBuilder.makeBlockBuffer(frame.data)
        return try SampleBufferBuilder.makeSampleBuffer(
            block: block,
            format: format,
            pts: timing.presentation,
            dts: timing.decode,
            duration: timing.duration,
            isKeyframe: frame.isKeyframe,
            // **Never true here.** `kCMSampleAttachmentKey_DisplayImmediately` is the live
            // low-latency switch; on a sample that is going into a file it tells a later player to
            // ignore the timebase, which breaks rate control, seeking and reverse playback
            // (docs/spec-video-pipeline.md §5.3).
            displayImmediately: false)
    }
}

#endif
