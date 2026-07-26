//
//  ParameterSetStore.swift
//  VigilBitstream
//
//  The per-stream parameter-set store. It **merges** — a camera that sends its SPS and its PPS in
//  separate packets must end up with both, and a store that replaced on each arrival would hand the
//  decoder a set that is never complete. It also separates a genuine format change, which costs a
//  decode session, from a cosmetic one, which costs a format description.
//  Implements docs/spec-bitstream.md §21 and API_CONTRACT §4.2.
//

import Foundation
import VigilProtocols

// MARK: - ParameterSetChange

/// What an `ingest` did to the store.
public enum ParameterSetChange: Sendable, Hashable {

    /// The incoming bytes were already held, byte for byte. The common case: Hikvision re-sends the
    /// parameter sets before every IDR. `generation` does not move.
    case unchanged

    /// The store was empty and now holds something.
    case firstSet

    /// The bytes changed but the decoder can be reused: rebuild the format description only, and
    /// note the new `generation`. A new SAR, frame rate, colour description or PPS lands here.
    case compatible(previous: VideoFormatInfo?)

    /// Codec, coded width, coded height, chroma format or luma bit depth changed. The decode
    /// session must be drained and recreated.
    case incompatible(previous: VideoFormatInfo?)
}

// MARK: - ParameterSetStore

/// Holds the parameter sets for one stream and tracks how they change.
///
/// A `struct` with no isolation of its own, owned by whichever actor drives the stream
/// (API_CONTRACT §2 R-32). Copying it is cheap: the sets are `Data`, which is copy-on-write.
///
/// **The parse-failure policy is the important one (§21.1): a parameter set we cannot parse is
/// still stored and still forwarded to the decoder.** VideoToolbox has its own, more permissive
/// parser and routinely decodes streams ours rejects. Our parse exists for metadata — window
/// sizing, the HUD, the decode budget, the `hvcC` fields — none of which are prerequisites for
/// showing a picture. So `isComplete` is about *bytes*, and `format == nil` must never block
/// decoding.
public struct ParameterSetStore: Sendable {

    // MARK: - Stored Properties

    /// The stored sets, or `nil` until the first ingest. Always in canonical form (§2.1): with the
    /// NAL header, without a start code or length prefix, still escaped, byte-identical to the wire.
    public private(set) var sets: ParameterSets?

    /// The format derived from the stored sets, or `nil` when no SPS has parsed successfully.
    /// `sets` may be complete and usable while this is `nil`.
    public private(set) var format: VideoFormatInfo?

    /// Increments whenever the stored bytes change. `VigilVideo` compares it against the generation
    /// its current format description was built from.
    public private(set) var generation: UInt32

    /// The parsed H.264 SPS, when one parsed.
    public private(set) var h264SPS: H264SPS?

    /// Parsed H.264 PPSs, keyed by `pic_parameter_set_id`.
    public private(set) var h264PPS: [UInt32: H264PPS]

    /// The parsed H.265 VPS, when one parsed.
    public private(set) var h265VPS: H265VPS?

    /// The parsed H.265 SPS, when one parsed.
    public private(set) var h265SPS: H265SPS?

    /// Parsed H.265 PPSs, keyed by `pps_pic_parameter_set_id`.
    public private(set) var h265PPS: [UInt32: H265PPS]

    /// The §4 cap: at most eight sets of one type. Beyond it the oldest are dropped rather than
    /// letting a stream that re-sends a slightly different SPS forever grow the store without bound.
    private static let maxSetsPerType = 8

    // MARK: - Initialisation

    /// Builds an empty store. The codec is adopted from the first ingest.
    public init() {
        self.sets = nil
        self.format = nil
        self.generation = 0
        self.h264SPS = nil
        self.h264PPS = [:]
        self.h265VPS = nil
        self.h265SPS = nil
        self.h265PPS = [:]
    }

    // MARK: - Public API

    /// True when there are enough **bytes** to build a format description: SPS and PPS for H.264,
    /// and additionally VPS for H.265. Never about parse success.
    public var isComplete: Bool {
        guard let sets else { return false }
        switch sets.codec {
        case .h264: return !sets.sps.isEmpty && !sets.pps.isEmpty
        case .h265: return !sets.vps.isEmpty && !sets.sps.isEmpty && !sets.pps.isEmpty
        case .mjpeg: return true
        }
    }

    /// Empties the store. Call on reconnect and on a codec change.
    public mutating func reset() {
        self = ParameterSetStore()
    }

    /// Merges `incoming` into the store and reports what changed.
    ///
    /// **Merge, not replace.** Only the groups `incoming` actually carries are touched: ingesting
    /// an SPS-only value leaves a previously stored PPS in place. Cameras that split their
    /// parameter sets across packets, and SDP `sprop-*` attributes that arrive one attribute at a
    /// time, both depend on this.
    ///
    /// Within a group, an incoming set replaces the stored set with the same parameter-set id when
    /// that id can be recovered by parsing, replaces a byte-identical set in place, and is appended
    /// otherwise. When the id cannot be recovered — a set our parser rejects — the set is appended
    /// rather than dropped, because the decoder still needs the bytes; the store is capped at eight
    /// sets per type so a pathological stream cannot grow it without bound.
    ///
    /// A different codec discards everything first: a stream's codec cannot change without the
    /// track being torn down, so this is a caller error, and holding H.264 sets alongside H.265
    /// ones would be worse than starting over.
    ///
    /// - Returns: `.unchanged` when nothing moved (a byte-for-byte re-send, which is the path taken
    ///   twice per GOP and does nothing but compare bytes), `.firstSet` when the store was empty,
    ///   `.incompatible` when codec, coded size, chroma format or luma bit depth changed, and
    ///   `.compatible` for every other change.
    @discardableResult
    public mutating func ingest(_ incoming: ParameterSets) -> ParameterSetChange {
        let previousFormat = format
        guard let existing = sets else {
            adopt(ParameterSetStore.capped(incoming))
            return .firstSet
        }
        guard existing.codec == incoming.codec else {
            self = ParameterSetStore()
            adopt(ParameterSetStore.capped(incoming))
            return .incompatible(previous: previousFormat)
        }

        // Fast path: a byte-for-byte re-send. Nothing but a comparison, no parsing, no allocation
        // beyond what `Data`'s equality needs. This is the path taken on every IDR.
        if unchanged(existing, incoming) { return .unchanged }

        var merged = existing
        merged.vps = mergeGroup(existing.vps, incoming.vps, codec: incoming.codec, kind: .vps)
        merged.sps = mergeGroup(existing.sps, incoming.sps, codec: incoming.codec, kind: .sps)
        merged.pps = mergeGroup(existing.pps, incoming.pps, codec: incoming.codec, kind: .pps)
        if merged == existing { return .unchanged }

        adopt(merged)
        if let previousFormat, let current = format {
            return previousFormat.isDecoderCompatible(with: current)
                ? .compatible(previous: previousFormat)
                : .incompatible(previous: previousFormat)
        }
        // One side or the other has no format: a parse failed, or this is the first SPS to parse.
        // Neither is a reason to tear down a decode session that is already running.
        return .compatible(previous: previousFormat)
    }

    // MARK: - Private: storage

    private enum SetKind { case vps, sps, pps }

    /// True when every group `incoming` carries is already held byte for byte.
    private func unchanged(_ existing: ParameterSets, _ incoming: ParameterSets) -> Bool {
        if !incoming.vps.isEmpty, incoming.vps != existing.vps { return false }
        if !incoming.sps.isEmpty, incoming.sps != existing.sps { return false }
        if !incoming.pps.isEmpty, incoming.pps != existing.pps { return false }
        return true
    }

    private static func capped(_ sets: ParameterSets) -> ParameterSets {
        var out = sets
        out.vps = Array(sets.vps.suffix(maxSetsPerType))
        out.sps = Array(sets.sps.suffix(maxSetsPerType))
        out.pps = Array(sets.pps.suffix(maxSetsPerType))
        return out
    }

    /// Stores `newSets`, bumps the generation and re-derives everything parsed.
    private mutating func adopt(_ newSets: ParameterSets) {
        sets = newSets
        generation &+= 1
        reparse(newSets)
    }

    private func mergeGroup(_ existing: [Data], _ incoming: [Data],
                            codec: VideoCodec, kind: SetKind) -> [Data] {
        guard !incoming.isEmpty else { return existing }
        var out = existing
        for candidate in incoming {
            if let index = out.firstIndex(of: candidate) {
                out[index] = candidate                      // byte-identical: nothing to do
                continue
            }
            let candidateID = ParameterSetStore.identifier(of: candidate, codec: codec, kind: kind)
            if let candidateID, let index = out.firstIndex(where: {
                ParameterSetStore.identifier(of: $0, codec: codec, kind: kind) == candidateID
            }) {
                out[index] = candidate                      // same id, new bytes: replace in place
            } else if out.count == 1, incoming.count == 1, candidateID == nil
                        || ParameterSetStore.identifier(of: out[0], codec: codec,
                                                        kind: kind) == nil {
                // One set replacing one set, with at least one id unrecoverable. A stream with two
                // simultaneous sets of a type is vanishingly rare, and a camera whose re-sent SPS
                // our parser rejects must not leave a stale set behind for the decoder to choke on.
                out[0] = candidate
            } else {
                out.append(candidate)
            }
        }
        return Array(out.suffix(ParameterSetStore.maxSetsPerType))
    }

    // MARK: - Private: parsing

    /// The parameter-set id of one NAL unit, or `nil` when it cannot be recovered.
    ///
    /// Used only to decide whether an incoming set replaces a stored one, so a `nil` costs an extra
    /// stored set and never a wrong picture.
    private static func identifier(of nal: Data, codec: VideoCodec, kind: SetKind) -> UInt32? {
        let bytes = [UInt8](nal)
        return try? withNALPointer(bytes) { (raw) throws(BitstreamError) -> UInt32 in
            switch (codec, kind) {
            case (.h264, .sps): return try H264Parser.parseSPS(raw).seqParameterSetID
            case (.h264, .pps): return try H264Parser.parsePPS(raw).picParameterSetID
            case (.h265, .vps): return UInt32(try H265Parser.parseVPS(raw).vpsID)
            case (.h265, .sps): return try H265Parser.parseSPS(raw).spsID
            case (.h265, .pps): return try H265Parser.parsePPS(raw).ppsID
            default: throw BitstreamError.unsupportedSyntax("no parameter-set id for this codec")
            }
        }
    }

    /// Re-derives every parsed model and `format` from the stored bytes.
    ///
    /// A parse failure leaves the corresponding model `nil` and, for the SPS, leaves `format` at
    /// its previous value rather than clearing it: the last good geometry is a better answer for
    /// the window and the HUD than no answer, and the bytes reach the decoder either way.
    private mutating func reparse(_ sets: ParameterSets) {
        switch sets.codec {
        case .h264:
            h264SPS = sets.sps.first.flatMap { ParameterSetStore.parse($0, H264Parser.parseSPS) }
            let parsedPPS = sets.pps.compactMap { ParameterSetStore.parse($0, H264Parser.parsePPS) }
            h264PPS = Dictionary(parsedPPS.map { ($0.picParameterSetID, $0) },
                                 uniquingKeysWith: { _, latest in latest })
            if let sps = h264SPS { format = VideoFormatInfo(sps) }

        case .h265:
            h265VPS = sets.vps.first.flatMap { ParameterSetStore.parse($0, H265Parser.parseVPS) }
            h265SPS = sets.sps.first.flatMap { ParameterSetStore.parse($0, H265Parser.parseSPS) }
            let parsedPPS = sets.pps.compactMap { ParameterSetStore.parse($0, H265Parser.parsePPS) }
            h265PPS = Dictionary(parsedPPS.map { ($0.ppsID, $0) },
                                 uniquingKeysWith: { _, latest in latest })
            if let sps = h265SPS {
                // Bitstream order, not dictionary order, so the choice is deterministic.
                let matching = parsedPPS.first { $0.spsID == sps.spsID } ?? parsedPPS.first
                format = VideoFormatInfo(sps, vps: h265VPS, pps: matching)
            }

        case .mjpeg:
            format = nil
        }
    }

    /// Runs one pointer-taking parser over a `Data`, swallowing the error into `nil`.
    private static func parse<T>(
        _ nal: Data, _ parser: (UnsafeRawBufferPointer) throws(BitstreamError) -> T
    ) -> T? {
        let bytes = [UInt8](nal)
        return try? withNALPointer(bytes) { (raw) throws(BitstreamError) -> T in
            try parser(raw)
        }
    }
}

// MARK: - Typed-throws pointer bridge

/// Runs `body` over `bytes` as a raw buffer while preserving typed throws. `withUnsafeBytes` is
/// `rethrows`, which would erase `BitstreamError` to `any Error`.
private func withNALPointer<T>(
    _ bytes: [UInt8],
    _ body: (UnsafeRawBufferPointer) throws(BitstreamError) -> T
) throws(BitstreamError) -> T {
    var outcome: Result<T, BitstreamError>?
    bytes.withUnsafeBytes { raw in
        do {
            outcome = .success(try body(raw))
        } catch let error as BitstreamError {
            outcome = .failure(error)
        } catch {
            // Unreachable: `body` is typed `throws(BitstreamError)`. The clause exists only because
            // `withUnsafeBytes` is `rethrows`, which erases the closure's thrown type to `any Error`.
            outcome = .failure(.unsupportedSyntax("unexpected error from a typed-throws closure"))
        }
    }
    switch outcome {
    case .success(let value): return value
    case .failure(let error): throw error
    case nil: throw BitstreamError.emptyNALUnit   // unreachable: the closure always runs
    }
}
