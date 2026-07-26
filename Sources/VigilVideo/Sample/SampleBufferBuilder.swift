//
//  SampleBufferBuilder.swift
//  VigilVideo
//
//  `EncodedFrame` → `CMBlockBuffer` → `CMSampleBuffer`, with timing and attachments.
//  Implements docs/spec-video-pipeline.md §5.1–§5.3 and docs/API_CONTRACT.md §4.9.
//
//  **This code has never been compiled.** There is no CoreMedia on Linux. Every call carries the
//  framework signature it was written against.
//

#if os(macOS)

import CoreMedia
import Foundation
import VigilBitstream
import VigilProtocols

// MARK: - SampleBufferBuilder

/// Wraps one access unit in the `CMSampleBuffer` the display layer consumes.
///
/// One access unit per sample buffer, always. Batching would defeat `DisplayImmediately` and make
/// per-frame latency accounting impossible (spec §5.2).
public enum SampleBufferBuilder {

    // MARK: - Public API

    /// Builds a live sample buffer for `frame`, taking the duration from the frame itself.
    ///
    /// The contract's two-argument form (API_CONTRACT §4.9). A pipeline that estimates durations
    /// across frames calls `make(_:format:duration:pacing:)` instead; this one falls back to 30 fps
    /// when the frame carries no duration, which is only right for a one-shot conversion.
    public static func make(_ frame: EncodedFrame,
                            format: CMVideoFormatDescription) throws(DecodeError) -> CMSampleBuffer {
        var estimator = DurationEstimator()
        let duration = estimator.duration(for: frame)
        return try make(frame, format: format, duration: duration, pacing: .live)
    }

    /// Builds a sample buffer for `frame` with a caller-supplied duration.
    ///
    /// - Parameters:
    ///   - frame: One access unit: 4-byte big-endian length-prefixed NAL units, never Annex-B. The
    ///     prefix walk is validated before anything is allocated — a length that runs past the end
    ///     of the buffer is a corrupt frame, and handing it to CoreMedia produces garbled pictures
    ///     rather than an error.
    ///   - format: The format description the sets for this GOP produced.
    ///   - duration: Must be valid and strictly positive, or the layer will not pace the sample.
    ///   - pacing: `.live` sets `DisplayImmediately`; `.paced` does not.
    /// - Throws: `.badData` for an empty, non-video or malformed access unit;
    ///   `.blockBufferFailed(status:)` and `.sampleBufferFailed(status:)` carrying the numeric
    ///   `OSStatus` for every CoreMedia failure.
    public static func make(_ frame: EncodedFrame, format: CMVideoFormatDescription,
                            duration: CMTime,
                            pacing: PacingMode) throws(DecodeError) -> CMSampleBuffer {

        guard let codec = frame.videoCodec, codec.isNALBased else {
            throw DecodeError.badData
        }
        guard !frame.data.isEmpty else {
            throw DecodeError.badData
        }
        // Cheap, allocation-free, never reads out of bounds. `validate` calls an empty buffer
        // well-formed, which is why the emptiness guard above is separate.
        let wellFormed = frame.data.withUnsafeBytes { raw in
            LengthPrefixed.validate(raw)
        }
        guard wellFormed else {
            throw DecodeError.badData
        }

        let block = try makeBlockBuffer(frame.data)
        return try makeSampleBuffer(
            block: block,
            format: format,
            pts: TimestampConversion.cmTime(frame.pts),
            // `.invalid` tells CoreMedia "decode order equals presentation order", which is the
            // normal live case: Hikvision live profiles have no B-frames, so `dts` is nil. Never
            // synthesise a DTS here (API_CONTRACT §2 R-06).
            dts: frame.dts.map(TimestampConversion.cmTime) ?? CMTime.invalid,
            duration: duration,
            isKeyframe: frame.isKeyframe,
            displayImmediately: pacing == .live)
    }

    // MARK: - Block buffer

    /// Copies `data` into a CoreMedia-owned contiguous block.
    ///
    /// Signatures this is written against:
    /// ```
    /// func CMBlockBufferCreateWithMemoryBlock(
    ///     allocator structureAllocator: CFAllocator?,
    ///     memoryBlock: UnsafeMutableRawPointer?,
    ///     blockLength: Int,
    ///     blockAllocator: CFAllocator?,
    ///     customBlockSource: UnsafePointer<CMBlockBufferCustomBlockSource>?,
    ///     offsetToData: Int,
    ///     dataLength: Int,
    ///     flags: CMBlockBufferFlags,
    ///     blockBufferOut: UnsafeMutablePointer<CMBlockBuffer?>) -> OSStatus
    ///
    /// func CMBlockBufferReplaceDataBytes(
    ///     with sourceBytes: UnsafeRawPointer,
    ///     blockBuffer destinationBuffer: CMBlockBuffer,
    ///     offsetIntoDestination: Int,
    ///     dataLength: Int) -> OSStatus
    /// ```
    ///
    /// **Why this copies instead of pointing at the `Data`.** The zero-copy form passes a
    /// `customBlockSource` holding a retained box and a free callback that CoreMedia invokes from
    /// its own thread. Get that lifetime wrong — and it is easy to, because `frame.data` is often a
    /// slice of a larger RTP reassembly buffer — and the block buffer points at freed memory. That
    /// shows up as **garbled frames, not a crash**, and reads exactly like a codec bug. The spec
    /// measured the copy at ≈1.5 µs for a P-frame and ≈12 µs for an I-frame, under 0.4 % of one
    /// core at 16×1080p30, and chose the copy (spec §5.1). So do we.
    ///
    /// `kCMBlockBufferAssureMemoryNowFlag` is required: without it the allocation is deferred and
    /// the `ReplaceDataBytes` below fails with `kCMBlockBufferBlockAllocationFailedErr`.
    package static func makeBlockBuffer(_ data: Data) throws(DecodeError) -> CMBlockBuffer {
        guard !data.isEmpty else {
            throw DecodeError.blockBufferFailed(status: emptyPayloadStatus)
        }

        var created: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,                    // nil ⇒ CoreMedia allocates blockLength bytes
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &created)

        guard createStatus == kCMBlockBufferNoErr, let block = created else {
            throw DecodeError.blockBufferFailed(status: createStatus)
        }

        let copyStatus: OSStatus = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return emptyPayloadStatus }
            return CMBlockBufferReplaceDataBytes(with: base,
                                                 blockBuffer: block,
                                                 offsetIntoDestination: 0,
                                                 dataLength: data.count)
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw DecodeError.blockBufferFailed(status: copyStatus)
        }
        return block
    }

    // MARK: - Sample buffer

    /// Wraps a block buffer, its format description and its timing in a ready sample buffer.
    ///
    /// Signature this is written against:
    /// ```
    /// func CMSampleBufferCreateReady(
    ///     allocator: CFAllocator?,
    ///     dataBuffer: CMBlockBuffer?,
    ///     formatDescription: CMFormatDescription?,
    ///     sampleCount numSamples: CMItemCount,
    ///     sampleTimingEntryCount numSampleTimingEntries: CMItemCount,
    ///     sampleTimingArray: UnsafePointer<CMSampleTimingInfo>?,
    ///     sampleSizeEntryCount numSampleSizeEntries: CMItemCount,
    ///     sampleSizeArray: UnsafePointer<Int>?,
    ///     sampleBufferOut: UnsafeMutablePointer<CMSampleBuffer?>) -> OSStatus
    /// ```
    package static func makeSampleBuffer(block: CMBlockBuffer,
                                         format: CMVideoFormatDescription,
                                         pts: CMTime, dts: CMTime, duration: CMTime,
                                         isKeyframe: Bool,
                                         displayImmediately: Bool) throws(DecodeError)
        -> CMSampleBuffer {

        var timing = CMSampleTimingInfo(duration: duration,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: dts)

        // **SIZES, not offsets.** `sampleSizeArray` is the length of each sample, and with one
        // sample that is the whole block. Passing an offset here — 0 — makes CoreMedia believe the
        // sample is empty, and the layer shows nothing while reporting no error at all.
        var sampleSize = CMBlockBufferGetDataLength(block)

        var created: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &created)

        guard status == noErr, let sample = created else {
            throw DecodeError.sampleBufferFailed(status: status)
        }

        try SampleAttachments.apply(to: sample,
                                    isKeyframe: isKeyframe,
                                    displayImmediately: displayImmediately)
        return sample
    }

    // MARK: - Constants

    /// `kCMBlockBufferBadLengthParameterErr`, written as a literal so this file does not depend on
    /// that symbol's exact spelling in the SDK. Used for the two zero-length paths, which the
    /// callers above have already excluded.
    private static let emptyPayloadStatus: OSStatus = -12_704
}

#endif
