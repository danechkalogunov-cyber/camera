//
//  TimestampConversion.swift
//  VigilVideo
//
//  `MediaTimestamp` ↔ `CMTime`, and the duration-estimation chain a sample buffer needs before the
//  display layer will pace it.
//  Implements docs/spec-video-pipeline.md §3.1 and §3.3.
//
//  **This code has never been compiled.** There is no CoreMedia on Linux.
//

#if os(macOS)

import CoreMedia
import VigilProtocols

// MARK: - TimestampConversion

/// The boundary between Vigil's `MediaTimestamp` and CoreMedia's `CMTime`.
///
/// `CMTime` never appears in a pure target (spec-video-pipeline.md D3), so this is the only place
/// the two meet. Both types are `value / timescale` seconds with the same semantics, so the
/// conversion is a field copy — except for the invalid sentinel, which each spells differently.
package enum TimestampConversion {

    /// `MediaTimestamp` → `CMTime`. `MediaTimestamp.invalid` becomes `CMTime.invalid`, so a missing
    /// DTS stays missing rather than becoming a time near `Int64.min`.
    ///
    /// Signature this is written against: `CMTime.init(value: CMTimeValue, timescale: CMTimeScale)`,
    /// where `CMTimeValue == Int64` and `CMTimeScale == Int32`.
    package static func cmTime(_ time: MediaTimestamp) -> CMTime {
        guard time.isValid else { return CMTime.invalid }
        return CMTime(value: time.value, timescale: time.timescale)
    }

    /// `CMTime` → `MediaTimestamp`. An invalid or indefinite `CMTime` becomes `.invalid`.
    ///
    /// `CMTime.isValid` is false when the `kCMTimeFlags_Valid` bit is clear; `isNumeric` is false
    /// additionally for the infinities and for indefinite, none of which `MediaTimestamp` can
    /// represent.
    package static func mediaTimestamp(_ time: CMTime) -> MediaTimestamp {
        guard time.isNumeric else { return MediaTimestamp.invalid }
        return MediaTimestamp(value: time.value, timescale: time.timescale)
    }
}

// MARK: - DurationEstimator

/// Produces the `duration` field of `CMSampleTimingInfo`.
///
/// The display layer needs a valid, positive duration to pace correctly, and `EncodedFrame.duration`
/// is `nil` for every live Hikvision profile. The chain is spec §3.3, in order:
///
/// 1. `EncodedFrame.duration`, when the depacketizer knew it.
/// 2. `pts − previousPTS`, when that lies in `(0, 2 s]`. The normal live case; being one frame
///    behind is irrelevant because live samples carry `DisplayImmediately` anyway.
/// 3. `1 / frameRate` from the SPS VUI, when the rate is a sane 1…240 fps.
/// 4. 30 fps — `3000 / 90000` — as the last resort.
///
/// - Note: the spec also smooths the layer path with an EWMA over the last 30 durations. That is
///   **not** implemented here: it is a stutter refinement for the paced path, and with
///   `DisplayImmediately` set on every live sample the layer does not pace from this number at all.
package struct DurationEstimator {

    // MARK: - Stored Properties

    /// The VUI frame rate, when an SPS parsed. Step 3 of the chain; `nil` skips to step 4.
    package var nominalFrameRate: Double?

    /// The previous frame's PTS, for step 2. `nil` before the first frame and after a reset.
    private var previousPTS: MediaTimestamp?

    // MARK: - Constants

    /// The RTP video timescale, and the timescale of the fallback duration.
    private static let videoTimescale: Int32 = 90_000

    /// 30 fps at 90 kHz. Step 4.
    private static let fallbackDuration = CMTime(value: 3_000, timescale: 90_000)

    /// Longest inter-frame gap that still counts as a frame duration. A larger gap means a stall,
    /// a seek or a stream restart, and using it would freeze the layer for that long.
    private static let maximumMeasuredSeconds = 2.0

    /// The band a VUI frame rate must lie in to be believed. Outside it the SPS is either
    /// unparsed or lying, and `90_000 / rate` would be absurd.
    private static let plausibleFrameRates = 1.0...240.0

    // MARK: - Initialisation

    /// Builds an estimator. `nominalFrameRate` may be set later, when the first SPS parses.
    package init(nominalFrameRate: Double? = nil) {
        self.nominalFrameRate = nominalFrameRate
        self.previousPTS = nil
    }

    // MARK: - Public API

    /// Forgets the previous PTS. Call on a stream reset or a seek, so the gap across the
    /// discontinuity is never mistaken for a frame duration.
    package mutating func reset() {
        previousPTS = nil
    }

    /// The duration to stamp on `frame`, and the point at which the previous PTS is remembered.
    ///
    /// Always returns a valid, strictly positive `CMTime`: a zero or negative duration makes the
    /// display layer drop the sample, which reads as "video connected but frozen".
    package mutating func duration(for frame: EncodedFrame) -> CMTime {
        let measured = measuredDuration(pts: frame.pts)
        if frame.pts.isValid {
            previousPTS = frame.pts
        }

        // 1. What the depacketizer knew.
        if let declared = frame.duration, declared.isValid, declared.value > 0 {
            return CMTime(value: declared.value, timescale: declared.timescale)
        }
        // 2. The gap since the previous frame.
        if let measured {
            return measured
        }
        // 3. The VUI frame rate.
        if let rate = nominalFrameRate, DurationEstimator.plausibleFrameRates.contains(rate) {
            let ticks = (Double(DurationEstimator.videoTimescale) / rate).rounded()
            return CMTime(value: Int64(ticks), timescale: DurationEstimator.videoTimescale)
        }
        // 4. 30 fps.
        return DurationEstimator.fallbackDuration
    }

    // MARK: - Private Helpers

    /// `pts − previousPTS`, when both are valid and the gap is in `(0, 2 s]`.
    ///
    /// A non-monotonic PTS in live mode is a bug in the RTP layer, not something to paper over with
    /// an absolute value: it returns `nil` here and the chain falls through to the frame rate.
    private func measuredDuration(pts: MediaTimestamp) -> CMTime? {
        guard pts.isValid, let previous = previousPTS, previous.isValid else { return nil }
        let delta = pts - previous
        guard delta.isValid, delta.value > 0 else { return nil }
        guard delta.seconds <= DurationEstimator.maximumMeasuredSeconds else { return nil }
        return CMTime(value: delta.value, timescale: delta.timescale)
    }
}

#endif
