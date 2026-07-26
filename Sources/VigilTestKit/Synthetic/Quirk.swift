//
//  Quirk.swift
//  VigilTestKit
//
//  The fault-injection vocabulary: one case per misbehaviour a real Hikvision device or a real
//  network actually exhibits. Tests name the quirk, so a failure report reads like a bug report and
//  every quirk found on real hardware becomes a permanent regression test.
//  Implements docs/ARCHITECTURE.md §10.2 ("Quirks — the fault-injection vocabulary").
//
//  No `import Foundation`: this file is a plain enumeration.
//

// MARK: - Quirk

/// A named, reproducible misbehaviour, individually switchable on a ``SyntheticCameraProfile``.
///
/// Every quirk that involves chance (loss, duplication, reordering, marker-bit noise) draws from the
/// profile's seeded generator, so a run is byte-identical for a given `profile.seed`. A failing test
/// prints the seed and the quirk set; replaying those two values reproduces the failure exactly.
public enum Quirk: Hashable, Sendable {

    // MARK: RTSP and transport shape

    /// The wire hands the client `bytesPerRead` bytes at a time, so no parser may assume a response
    /// arrives whole. A value below 1 is treated as 1.
    case slowDrip(bytesPerRead: Int)

    /// Every server write is split at offsets chosen to straddle the worst places: inside the
    /// `RTSP/1.0` status line, across the blank line that ends the header block, and across the
    /// four-byte `$` interleave header.
    case splitAtHostileOffsets

    /// The SDP carries a literal `$` (0x24) inside a session-name attribute. A decoder that scans
    /// for interleaved framing without respecting `Content-Length` will desynchronise here.
    case dollarInResponseBody

    /// The SDP carries Hikvision's proprietary `a=Media_header`, `a=appversion` and other unknown
    /// attribute lines. A strict parser rejects the whole document; a correct one ignores them.
    case extraSDPAttributes

    /// The DESCRIBE response omits `Content-Base`, so track control URLs must be resolved against
    /// the request URI instead.
    case noContentBase

    /// `a=control:` carries an absolute `rtsp://` URL rather than a relative `trackID=` fragment.
    case absoluteControlURL

    // MARK: Auth

    /// After `afterRequests` authenticated requests the camera answers `401` with `stale=TRUE` and a
    /// fresh nonce. The client must re-authenticate without counting a credential failure.
    case digestStaleNonce(afterRequests: Int)

    /// Every credentialed request is rejected. Asserts the client gives up at two attempts.
    case wrongPasswordAlways

    // MARK: RTP shape

    /// The marker bit is never set on any packet. Access-unit boundaries must come from the RTP
    /// timestamp change plus the slice-header first-slice predicate.
    case markerNeverSet

    /// The marker bit is set on packets in the middle of a picture and cleared on the real last
    /// packet — worse than never setting it, because a marker-trusting depacketizer splits pictures.
    case markerMidPicture

    /// `sprop-parameter-sets` / `sprop-vps` values are base64 with the trailing `=` padding stripped.
    case unpaddedSpropBase64

    /// No `sprop-*` attribute at all: parameter sets appear only in band, ahead of each IRAP.
    case parameterSetsOnlyInBand

    /// Parameter sets appear only in the SDP and are never repeated in band.
    case parameterSetsOnlyInSDP

    /// The first sequence number is 65 500, so the 16-bit counter wraps a few packets into the run.
    case sequenceWrapSoon

    /// The first RTP timestamp is `0xFFFF_F000`, so the 32-bit clock wraps during the run.
    case timestampWrapSoon

    /// Packets are dropped at `rate` (0…1), chosen by the seeded generator. Dropped sequence
    /// numbers are recorded in ``GroundTruth/injectedPacketLosses``.
    case packetLoss(rate: Double)

    /// Packets are held back and re-emitted up to `windowPackets` later, so they arrive out of order.
    case reorder(windowPackets: Int)

    /// Packets are re-sent at `rate` (0…1). A correct receiver emits no duplicate access unit.
    case duplicate(rate: Double)

    /// Parameter sets and consecutive small NALs are sent as STAP-A (H.264) / AP (H.265) aggregates
    /// rather than one packet per NAL.
    case aggregationPackets

    /// The stream begins in the middle of a GOP: the first `seconds` of virtual time carry only
    /// non-IRAP slices, so the client must drop everything until the first real IRAP arrives.
    case startMidGOP(seconds: Double)

    /// At access unit `atFrame` the camera re-encodes at a new size and emits new parameter sets.
    case midStreamResolutionChange(atFrame: Int, newWidth: Int, newHeight: Int)
}

// MARK: - Classification

public extension Quirk {

    /// A short stable identifier, used in test names and failure messages. Associated values are
    /// deliberately excluded so the tag groups every parameterisation of the same fault.
    var tag: String {
        switch self {
        case .slowDrip: "slowDrip"
        case .splitAtHostileOffsets: "splitAtHostileOffsets"
        case .dollarInResponseBody: "dollarInResponseBody"
        case .extraSDPAttributes: "extraSDPAttributes"
        case .noContentBase: "noContentBase"
        case .absoluteControlURL: "absoluteControlURL"
        case .digestStaleNonce: "digestStaleNonce"
        case .wrongPasswordAlways: "wrongPasswordAlways"
        case .markerNeverSet: "markerNeverSet"
        case .markerMidPicture: "markerMidPicture"
        case .unpaddedSpropBase64: "unpaddedSpropBase64"
        case .parameterSetsOnlyInBand: "parameterSetsOnlyInBand"
        case .parameterSetsOnlyInSDP: "parameterSetsOnlyInSDP"
        case .sequenceWrapSoon: "sequenceWrapSoon"
        case .timestampWrapSoon: "timestampWrapSoon"
        case .packetLoss: "packetLoss"
        case .reorder: "reorder"
        case .duplicate: "duplicate"
        case .aggregationPackets: "aggregationPackets"
        case .startMidGOP: "startMidGOP"
        case .midStreamResolutionChange: "midStreamResolutionChange"
        }
    }

    /// `true` when the quirk is expected to make the connection fail rather than degrade.
    ///
    /// Exactly one quirk is in this class today: a permanently wrong password is not survivable and
    /// the correct behaviour is a specific, diagnosable authentication error after two attempts.
    var isTerminal: Bool {
        if case .wrongPasswordAlways = self { return true }
        return false
    }
}

// MARK: - Convenience lookup over a set

public extension Set<Quirk> {

    /// `true` when a quirk with the same ``Quirk/tag`` is present, ignoring associated values.
    func contains(tag: String) -> Bool {
        contains { $0.tag == tag }
    }

    /// The packet-loss rate, clamped to `0...1`, or `nil` when the quirk is absent.
    var packetLossRate: Double? {
        for quirk in self {
            if case let .packetLoss(rate) = quirk { return Swift.min(Swift.max(rate, 0), 1) }
        }
        return nil
    }

    /// The duplication rate, clamped to `0...1`, or `nil` when the quirk is absent.
    var duplicateRate: Double? {
        for quirk in self {
            if case let .duplicate(rate) = quirk { return Swift.min(Swift.max(rate, 0), 1) }
        }
        return nil
    }

    /// The reorder window in packets, at least 2, or `nil` when the quirk is absent.
    var reorderWindow: Int? {
        for quirk in self {
            if case let .reorder(window) = quirk { return Swift.max(window, 2) }
        }
        return nil
    }

    /// The read size in bytes, at least 1, or `nil` when ``Quirk/slowDrip(bytesPerRead:)`` is absent.
    var slowDripBytes: Int? {
        for quirk in self {
            if case let .slowDrip(bytes) = quirk { return Swift.max(bytes, 1) }
        }
        return nil
    }

    /// Number of authenticated requests before the stale-nonce challenge, or `nil`.
    var staleNonceAfterRequests: Int? {
        for quirk in self {
            if case let .digestStaleNonce(after) = quirk { return Swift.max(after, 1) }
        }
        return nil
    }

    /// How long the stream stays inside a GOP with no IRAP, in seconds, or `nil`.
    var startMidGOPSeconds: Double? {
        for quirk in self {
            if case let .startMidGOP(seconds) = quirk { return Swift.max(seconds, 0) }
        }
        return nil
    }

    /// The mid-stream resolution change, or `nil` when the quirk is absent.
    var resolutionChange: (atFrame: Int, width: Int, height: Int)? {
        for quirk in self {
            if case let .midStreamResolutionChange(frame, width, height) = quirk {
                return (Swift.max(frame, 1), width, height)
            }
        }
        return nil
    }
}
