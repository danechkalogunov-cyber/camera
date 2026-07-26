//
//  FormatDescriptionFactory.swift
//  VigilVideo
//
//  The single conversion site from `ParameterSets` to `CMVideoFormatDescription`, for H.264 and
//  H.265, and the nested pointer plumbing the two CoreMedia constructors require.
//  Implements docs/spec-video-pipeline.md §4.1–§4.3 and docs/API_CONTRACT.md §4.9.
//
//  **This code has never been compiled.** There is no CoreMedia on Linux. Every call below carries
//  the framework signature it was written against so a reviewer can check it without a compiler
//  (.vigil/STEP3.md, "rules for code no compiler will check").
//

#if os(macOS)

import CoreMedia
import Foundation
import VigilProtocols

// MARK: - FormatDescriptionFactory

/// Builds `CMVideoFormatDescription`s from parameter sets. **The only place in Vigil that calls
/// `CMVideoFormatDescriptionCreateFrom*ParameterSets`** (API_CONTRACT §4.9).
///
/// Order is `[SPS, PPS]` for H.264 and `[VPS, SPS, PPS]` for H.265; `nalUnitHeaderLength` is
/// always 4, because every buffer in Vigil is 4-byte big-endian length-prefixed and never Annex-B
/// (spec-video-pipeline.md D1).
public enum FormatDescriptionFactory {

    // MARK: - Constants

    /// Hard cap on parameter sets in one call. A stream that sends more is malformed or hostile;
    /// the recursion in `withParameterSetPointers` is bounded by this and nothing else.
    public static let maximumParameterSetCount = 8

    /// The fewest bytes `trimmedTrailingZeros` will leave. Every real NAL is longer; the floor
    /// only stops a pathological all-zero set from being trimmed to nothing.
    private static let minimumParameterSetBytes = 4

    /// `paramErr`. Written as a literal so this file does not depend on the Carbon `MacTypes.h`
    /// constant being visible in Swift. Reported when the parameter sets could not be pinned, which
    /// cannot happen for a non-empty `Data` — but a log line with a number beats one without.
    private static let pinningFailedStatus: OSStatus = -50

    // MARK: - Public API

    /// Builds a format description from one stream's parameter sets.
    ///
    /// - Parameters:
    ///   - codec: Decides which CoreMedia constructor is called and the set order. `.mjpeg` throws:
    ///     it has no parameter sets and is decoded by the ImageIO path instead (spec §12.6).
    ///   - parameterSets: Canonical form — with the NAL header, no start code, no length prefix,
    ///     still escaped. Trailing `0x00` padding (some Hikvision firmware pads
    ///     `sprop-parameter-sets`) is trimmed here.
    ///   - info: What our own SPS parser made of the same bytes, or `nil` when it could not parse
    ///     them. Diagnostic only in the slice — it enriches the `unsupportedFormat` detail. The
    ///     `avcC`/`hvcC` override path that will consume it in earnest is spec §4.4, a later row.
    /// - Returns: A format description CoreMedia derived from the sets. Its dimensions, cropping,
    ///   pixel aspect ratio and colorimetry come from VideoToolbox's own SPS parse, which is more
    ///   permissive than ours and wins where the two disagree (spec §4.3).
    /// - Throws: `.unsupportedFormat` for MJPEG or a codec/sets mismatch, `.missingParameterSets`
    ///   when SPS or PPS is absent, `.emptyParameterSet(index:)` for a zero-length set,
    ///   `.tooManyParameterSets(count:)` above the cap, and `.formatDescriptionFailed(status:)`
    ///   carrying the numeric `OSStatus` for every CoreMedia failure.
    public static func make(codec: VideoCodec, parameterSets: ParameterSets,
                            info: VideoFormatInfo? = nil) throws(DecodeError)
        -> CMVideoFormatDescription {

        guard codec != .mjpeg else {
            throw DecodeError.unsupportedFormat(
                codec: .mjpeg,
                detail: "MJPEG has no parameter sets and is not decoded through CoreMedia")
        }
        guard parameterSets.codec == codec else {
            throw DecodeError.unsupportedFormat(
                codec: codec,
                detail: "sets are \(parameterSets.codec.rawValue), caller asked for "
                    + "\(codec.rawValue); parsed=\(info?.profileName ?? "none")")
        }
        // CoreMedia needs at least one SPS and one PPS for both codecs. VPS is strongly recommended
        // for H.265 but not required: firmware that omits it from SDP sends it in band, and refusing
        // to decode until it arrives would show a black tile on cameras that work elsewhere.
        guard !parameterSets.sps.isEmpty, !parameterSets.pps.isEmpty else {
            throw DecodeError.missingParameterSets
        }

        // Order is normative (spec §4.1) and is written out rather than taken from
        // `ParameterSets.orderedForCoreMedia`, so that a reviewer sees the order at the call site.
        let ordered: [Data]
        switch codec {
        case .h264:
            ordered = parameterSets.sps + parameterSets.pps
        case .h265:
            ordered = parameterSets.vps + parameterSets.sps + parameterSets.pps
        case .mjpeg:
            // Unreachable: rejected above. Kept so the switch stays exhaustive without a `default`,
            // which would silently swallow a codec added later.
            ordered = []
        }

        guard ordered.count <= maximumParameterSetCount else {
            throw DecodeError.tooManyParameterSets(count: ordered.count)
        }

        let sets = ordered.map(trimmedTrailingZeros)
        for (index, set) in sets.enumerated() where set.isEmpty {
            throw DecodeError.emptyParameterSet(index: index)
        }

        switch codec {
        case .h264:
            return try makeH264(sets: sets)
        case .h265:
            return try makeHEVC(sets: sets)
        case .mjpeg:
            throw DecodeError.unsupportedFormat(codec: .mjpeg, detail: "unreachable")
        }
    }

    /// The format description's own idea of the coded size, as a `VideoFormatInfo`.
    ///
    /// Used when our SPS parser rejected a set CoreMedia accepted. Everything except the coded size
    /// is a default — 8-bit, 4:2:0, square pixels, BT.709, progressive — because none of it is
    /// known and none of it gates decoding. `format == nil` must never block a picture
    /// (spec-bitstream.md §21.1).
    ///
    /// Signature this is written against:
    /// ```
    /// func CMVideoFormatDescriptionGetDimensions(
    ///     _ videoDesc: CMVideoFormatDescription) -> CMVideoDimensions
    /// // struct CMVideoDimensions { var width: Int32; var height: Int32 }
    /// ```
    package static func fallbackFormatInfo(for description: CMVideoFormatDescription,
                                           codec: VideoCodec) -> VideoFormatInfo {
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let width = Int(dimensions.width)
        let height = Int(dimensions.height)
        let geometry = FrameGeometry(codedWidth: width, codedHeight: height,
                                     cropWidth: width, cropHeight: height)
        return VideoFormatInfo(codec: codec, geometry: geometry)
    }

    /// Drops trailing `0x00` bytes, never going below `minimumParameterSetBytes`.
    ///
    /// A no-op on a well-formed NAL: an RBSP cannot end in `0x00` because of the
    /// `rbsp_stop_one_bit`. It exists for firmware that pads the base64 in `sprop-parameter-sets`,
    /// which CoreMedia rejects with `-12712`.
    package static func trimmedTrailingZeros(_ set: Data) -> Data {
        var length = set.count
        while length > minimumParameterSetBytes {
            let last = set.index(set.startIndex, offsetBy: length - 1)
            guard set[last] == 0 else { break }
            length -= 1
        }
        guard length < set.count else { return set }
        return set.prefix(length)
    }

    // MARK: - Pointer plumbing

    /// Pins every element of `sets` at once and hands `body` the two C arrays CoreMedia wants.
    ///
    /// **The pointers must not escape `body`.** `Data.withUnsafeBytes` guarantees its pointer only
    /// for the duration of its own closure, and `Data` may be discontiguous, so *n* sets need *n*
    /// nested closures — all still open when `body` runs. Recursion depth is `sets.count`, capped
    /// at `maximumParameterSetCount`.
    ///
    /// **Do not** replace this with
    /// `sets.map { $0.withUnsafeBytes { $0.baseAddress } }`. That array is dangling by the time it
    /// is used — every closure has already returned — and it "works" until a `Data` is a slice of a
    /// larger RTP reassembly buffer or ARC releases it. It is the single most common crash in
    /// hand-rolled players of this kind.
    ///
    /// - Returns: whatever `body` returned, or `nil` if a buffer could not be pinned. `nil` is
    ///   unreachable for non-empty sets — a non-empty `Data` always has a base address — but it is
    ///   an `Optional` rather than a force-unwrap because this file must not be able to crash.
    package static func withParameterSetPointers<R>(
        _ sets: [Data],
        _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>, Int) -> R
    ) -> R? {
        guard !sets.isEmpty else { return nil }
        return pinning(sets, from: 0, pointers: [], sizes: [], body)
    }

    /// One level of the descent: opens `sets[index]`'s buffer, appends its pointer and size to the
    /// accumulators, and opens the next level **inside** that closure, so every buffer is still
    /// pinned when the bottom of the recursion calls `body`.
    ///
    /// The accumulators travel **by value** rather than as `inout` with a `defer` that pops them.
    /// The spec sketches the `inout` form; passing them down instead costs one small array copy per
    /// level — at most eight, once per format change, never per frame — and in exchange nothing in
    /// this function mutates anything, which is the property a reviewer without a compiler can
    /// actually check.
    private static func pinning<R>(
        _ sets: [Data],
        from index: Int,
        pointers: [UnsafePointer<UInt8>],
        sizes: [Int],
        _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>, Int) -> R
    ) -> R? {
        guard index < sets.count else {
            // Bottom of the recursion: every `withUnsafeBytes` frame above is still open, so every
            // pointer in `pointers` is still valid. One `withUnsafeBufferPointer` per C array.
            return pointers.withUnsafeBufferPointer { pointerBuffer -> R? in
                sizes.withUnsafeBufferPointer { sizeBuffer -> R? in
                    guard let pointerBase = pointerBuffer.baseAddress else { return nil }
                    guard let sizeBase = sizeBuffer.baseAddress else { return nil }
                    return body(pointerBase, sizeBase, sets.count)
                }
            }
        }

        return sets[index].withUnsafeBytes { raw -> R? in
            guard let rawBase = raw.baseAddress else { return nil }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            return pinning(sets,
                           from: index + 1,
                           pointers: pointers + [base],
                           sizes: sizes + [raw.count],
                           body)
        }
    }

    // MARK: - The two constructors

    /// Signature this is written against (CoreMedia, macOS 10.9+):
    /// ```
    /// func CMVideoFormatDescriptionCreateFromH264ParameterSets(
    ///     allocator: CFAllocator?,
    ///     parameterSetCount: Int,
    ///     parameterSetPointers: UnsafePointer<UnsafePointer<UInt8>>,
    ///     parameterSetSizes: UnsafePointer<Int>,
    ///     nalUnitHeaderLength: Int32,
    ///     formatDescriptionOut: UnsafeMutablePointer<CMFormatDescription?>
    /// ) -> OSStatus
    /// ```
    private static func makeH264(sets: [Data]) throws(DecodeError) -> CMVideoFormatDescription {
        var created: CMFormatDescription?

        let status: OSStatus? = withParameterSetPointers(sets) {
            (pointers: UnsafePointer<UnsafePointer<UInt8>>,
             sizes: UnsafePointer<Int>,
             count: Int) -> OSStatus in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &created)
        }

        guard let status else {
            throw DecodeError.formatDescriptionFailed(status: pinningFailedStatus)
        }
        // A status of 0 in this error means CoreMedia reported success and produced nothing, which
        // is worth telling apart from a real failure code in the log.
        guard status == noErr, let created else {
            throw DecodeError.formatDescriptionFailed(status: status)
        }
        return created
    }

    /// Signature this is written against (CoreMedia, macOS 10.13+):
    /// ```
    /// func CMVideoFormatDescriptionCreateFromHEVCParameterSets(
    ///     allocator: CFAllocator?,
    ///     parameterSetCount: Int,
    ///     parameterSetPointers: UnsafePointer<UnsafePointer<UInt8>>,
    ///     parameterSetSizes: UnsafePointer<Int>,
    ///     nalUnitHeaderLength: Int32,
    ///     extensions: CFDictionary?,
    ///     formatDescriptionOut: UnsafeMutablePointer<CMFormatDescription?>
    /// ) -> OSStatus
    /// ```
    /// `extensions` is `nil`: the colour-override dictionary is spec §4.4, a later row. The one
    /// difference from the H.264 form is that extra argument, which is why the two are written out
    /// separately rather than folded into one call site with a flag.
    private static func makeHEVC(sets: [Data]) throws(DecodeError) -> CMVideoFormatDescription {
        var created: CMFormatDescription?

        let status: OSStatus? = withParameterSetPointers(sets) {
            (pointers: UnsafePointer<UnsafePointer<UInt8>>,
             sizes: UnsafePointer<Int>,
             count: Int) -> OSStatus in
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &created)
        }

        guard let status else {
            throw DecodeError.formatDescriptionFailed(status: pinningFailedStatus)
        }
        guard status == noErr, let created else {
            throw DecodeError.formatDescriptionFailed(status: status)
        }
        return created
    }
}

#endif
