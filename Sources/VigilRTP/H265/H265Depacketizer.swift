//
//  H265Depacketizer.swift
//  VigilRTP
//
//  RFC 7798 depacketization: single NAL unit packets, AP aggregation and FU fragmentation, with the
//  optional DONL field that `sprop-max-don-diff > 0` turns on. PACI is rejected rather than
//  half-implemented, and non-base-layer NAL units are dropped.
//  See docs/spec-rtp.md §6 and docs/API_CONTRACT.md §4.4.
//

import Foundation

import VigilBitstream
import VigilProtocols

// MARK: - H265Depacketizer

/// Reassembles H.265 access units from RTP.
///
/// Boundaries come from the RTP timestamp and `first_slice_segment_in_pic_flag`; the marker bit is
/// only ever a learned optimisation. Hikvision ships H.265 by default on current firmware, so this
/// is the path most cameras actually take.
public struct H265Depacketizer: Depacketizer {

    // MARK: - Nested Types

    /// RFC 7798 §4.2 packet types that are not themselves NAL units.
    private enum PacketType {
        static let aggregation: UInt8 = 48
        static let fragmentation: UInt8 = 49
        static let paci: UInt8 = 50
    }

    /// A FU reassembly in progress.
    private struct FragmentState {
        /// The reconstructed original two-byte NAL header.
        var header: (UInt8, UInt8)
        var typeCode: UInt8
        var pieces: [Data]
        var byteCount: Int
        var timestamp: UInt32
        var expectedSequence: UInt16
        var fragmentCount: Int
        var announced: Bool
    }

    // MARK: - Stored Properties

    /// Always `.video(.h265)`.
    public let codec: MediaCodec = .video(.h265)

    /// RTP clock rate; 90 000 for every Hikvision video profile.
    public let clockRate: Int32

    /// True when the SDP declared `sprop-max-don-diff > 0`, which inserts a DONL into AP packets
    /// and into FU start fragments and shifts every offset after it.
    public let usesDONL: Bool

    private var assembler: AccessUnitAssembler
    private var fragment: FragmentState?
    private var limiter = EventRateLimiter()
    private var sequences = SequenceExtender()
    private let configuration: DepacketizerConfiguration

    // MARK: - Initialisation

    /// Creates a depacketizer for one H.265 track.
    ///
    /// - Parameters:
    ///   - clockRate: from `a=rtpmap`. Non-positive values are replaced by 90 000.
    ///   - configuration: limits and policy switches.
    ///   - initialParameterSets: `sprop-vps` / `sprop-sps` / `sprop-pps`, already base64-decoded.
    ///   - usesDONL: from `sprop-max-don-diff`. Getting this wrong shifts every payload offset by
    ///     two bytes and corrupts every packet silently, so it is an explicit argument rather than
    ///     something guessed from the bytes.
    public init(clockRate: Int32 = 90_000,
                configuration: DepacketizerConfiguration = .liveDefault,
                initialParameterSets: ParameterSets? = nil,
                usesDONL: Bool = false) {
        let rate = clockRate > 0 ? clockRate : 90_000
        self.clockRate = rate
        self.configuration = configuration
        self.usesDONL = usesDONL
        self.assembler = AccessUnitAssembler(codec: .h265, clockRate: rate,
                                             configuration: configuration,
                                             initialParameterSets: initialParameterSets)
    }

    /// Reads `sprop-max-don-diff` out of an fmtp dictionary whose keys are already lower-cased.
    ///
    /// - Returns: true when the value parses as an integer greater than zero. A missing, empty or
    ///   unparsable value means no DONL, which is what every Hikvision camera sends.
    public static func usesDONL(fmtp: [String: String]) -> Bool {
        guard let raw = fmtp["sprop-max-don-diff"],
              let value = Int(raw.trimmingCharacters(in: .whitespaces)) else { return false }
        return value > 0
    }

    // MARK: - Public API

    /// Parameter sets currently in force: the SDP's, overlaid by everything seen in band.
    public var parameterSets: ParameterSets { assembler.parameterSets }

    /// What has been learned about slice structure and the marker bit.
    public var boundaryPolicy: BoundaryPolicy { assembler.boundary }

    /// The instant at which the open access unit must be force-closed, or `nil` when none is open.
    public var accessUnitDeadline: MediaInstant? { assembler.timeoutDeadline }

    /// Consume one RTP packet. See `Depacketizer.push(_:at:)`.
    public mutating func push(_ packet: RTPPacket, at now: MediaInstant) -> DepacketizerOutput {
        var out = DepacketizerOutput()
        let context = PacketContext(timestamp: packet.timestamp,
                                    marker: packet.marker,
                                    extendedSequence: sequences.extend(packet.sequenceNumber),
                                    arrival: now)
        let payload = packet.payload
        guard payload.count >= 2 else {
            report(.emptyPayload, at: now, into: &out)
            return out
        }
        let b0 = payload.byte(at: 0)
        guard b0 & 0x80 == 0 else {
            report(.forbiddenBitSet, at: now, into: &out)
            return out
        }
        let type = (b0 >> 1) & 0x3F
        // A fragment run cannot span a timestamp change (RFC 7798 §4.4.3). Clearing it here rather
        // than waiting for the next fragment stops a stray continuation splicing itself into the
        // following picture when the intervening packets were not fragments at all.
        if let open = fragment, open.timestamp != packet.timestamp {
            abandonFragment(.incompleteFragmentAtAUEnd, at: now, into: &out)
        }

        switch type {
        case PacketType.aggregation:
            unpackAggregate(payload, context: context, at: now, into: &out)
        case PacketType.fragmentation:
            unpackFragment(payload, packet: packet, context: context, at: now, into: &out)
        case PacketType.paci, 51...63:
            reportUnsupported(.packetizationType(type), at: now, into: &out)
        default:
            append(nal: payload, context: context, at: now, into: &out)
        }
        assembler.endOfPacket(context, into: &out)
        return out
    }

    /// Emit any complete pending access unit. See `Depacketizer.flush(at:)`.
    public mutating func flush(at now: MediaInstant) -> [EncodedFrame] {
        var out = DepacketizerOutput()
        if fragment != nil {
            fragment = nil
            assembler.abandonNAL(.incompleteFragmentAtAUEnd, into: &out)
        }
        assembler.finish(into: &out)
        return out.frames
    }

    /// Timer-driven close of an access unit that has been idle past the configured timeout.
    public mutating func tick(at now: MediaInstant) -> DepacketizerOutput {
        var out = DepacketizerOutput()
        assembler.tick(at: now, into: &out)
        return out
    }

    /// Full state reset. See `Depacketizer.reset()`.
    public mutating func reset() {
        fragment = nil
        limiter.reset()
        sequences.reset()
        assembler.reset()
    }

    // MARK: - Private Helpers — packet forms

    /// AP, RFC 7798 §4.4.2. A DONL precedes the first aggregation unit and an 8-bit DOND precedes
    /// every unit after it, but only when `sprop-max-don-diff > 0`.
    private mutating func unpackAggregate(_ payload: Data, context: PacketContext,
                                          at now: MediaInstant, into out: inout DepacketizerOutput) {
        var index = usesDONL ? 4 : 2
        guard payload.count >= index else {
            report(.truncatedAggregate, at: now, into: &out)
            return
        }
        var first = true
        var unpacked = 0
        while index < payload.count {
            guard unpacked < configuration.maxAggregatedNALs else {
                report(.truncatedAggregate, at: now, into: &out)
                assembler.markAccessUnitCorrupt()
                return
            }
            if !first, usesDONL {
                guard index + 1 <= payload.count else {
                    report(.truncatedAggregate, at: now, into: &out)
                    assembler.markAccessUnitCorrupt()
                    return
                }
                index += 1
            }
            guard index + 2 <= payload.count else {
                report(.truncatedAggregate, at: now, into: &out)
                assembler.markAccessUnitCorrupt()
                return
            }
            let size = Int(payload.u16BE(at: index))
            index += 2
            // An H.265 NAL always has a 2-byte header, so anything shorter cannot be one.
            guard size >= 2 else {
                report(.zeroLengthAggregate, at: now, into: &out)
                assembler.markAccessUnitCorrupt()
                return
            }
            guard index + size <= payload.count else {
                report(.truncatedAggregate, at: now, into: &out)
                assembler.markAccessUnitCorrupt()
                return
            }
            append(nal: payload.slice(index..<(index + size)), context: context, at: now, into: &out)
            index += size
            first = false
            unpacked += 1
        }
    }

    /// FU, RFC 7798 §4.4.3.
    private mutating func unpackFragment(_ payload: Data, packet: RTPPacket,
                                         context: PacketContext, at now: MediaInstant,
                                         into out: inout DepacketizerOutput) {
        guard let fuOffset = fuHeaderOffset(payload, sequence: packet.sequenceNumber),
              payload.count > fuOffset else {
            report(.truncatedFragment, at: now, into: &out)
            return
        }
        let fuHeader = payload.byte(at: fuOffset)
        let isStart = fuHeader & 0x80 != 0
        let isEnd = fuHeader & 0x40 != 0
        let typeCode = fuHeader & 0x3F
        let dataStart = fuOffset + 1
        guard payload.count > dataStart else {
            report(.truncatedFragment, at: now, into: &out)
            return
        }
        let body = payload.slice(dataStart..<payload.count)

        if isStart {
            startFragment(payload: payload, typeCode: typeCode, body: body, packet: packet,
                          context: context, at: now, into: &out)
        } else {
            continueFragment(body: body, packet: packet, isEnd: isEnd, at: now, into: &out)
        }
    }

    /// Resolves where the FU header sits.
    ///
    /// With no DONL it is always at offset 2. With a DONL it is at offset 4 on the start fragment
    /// and at offset 2 on every continuation, and those two cases cannot be told apart from the
    /// bytes alone — a DONL of `0x8000` looks exactly like an FU header with `S` set. The
    /// reassembly state resolves it: a fragment that continues the open run at the expected
    /// sequence number is, by construction, not a start fragment.
    ///
    /// - Returns: the offset, or `nil` when the payload is too short to hold what it claims.
    private func fuHeaderOffset(_ payload: Data, sequence: UInt16) -> Int? {
        guard usesDONL else { return payload.count >= 3 ? 2 : nil }
        guard payload.count >= 5 else { return nil }
        if let open = fragment, open.expectedSequence == sequence, payload.byte(at: 2) & 0x80 == 0 {
            return 2
        }
        return 4
    }

    /// Begins a fragment run.
    private mutating func startFragment(payload: Data, typeCode: UInt8, body: Data,
                                        packet: RTPPacket, context: PacketContext,
                                        at now: MediaInstant, into out: inout DepacketizerOutput) {
        if let open = fragment {
            fragment = nil
            if open.announced {
                assembler.abandonNAL(.lostLastFragment, into: &out)
            } else {
                report(.lostLastFragment, at: now, into: &out)
            }
        }
        guard typeCode < 48 else {
            // A FU cannot fragment an AP, another FU or a PACI.
            report(.nestedPacketization, at: now, into: &out)
            return
        }
        // 0x81 is load-bearing: bit 7 is F and bit 0 is the top bit of nuh_layer_id. Masking with
        // 0x80 alone zeroes that layer-id bit; masking with 0x01 alone drops F.
        let header = ((payload.byte(at: 0) & 0x81) | (typeCode << 1), payload.byte(at: 1))
        guard layerID(header.0, header.1) == 0 else {
            reportUnsupported(.nonBaseLayer(layerID(header.0, header.1)), at: now, into: &out)
            return
        }
        var probe = Data(capacity: 6)
        probe.append(header.0)
        probe.append(header.1)
        probe.append(body.prefix(4))
        let descriptor = describe(header: header, probe: probe)
        let announced = assembler.beginNAL(descriptor, packet: context, into: &out)
        fragment = FragmentState(header: header, typeCode: typeCode, pieces: [body],
                                 byteCount: body.count, timestamp: packet.timestamp,
                                 expectedSequence: packet.sequenceNumber &+ 1,
                                 fragmentCount: 1, announced: announced)
    }

    /// Continues or completes a fragment run.
    private mutating func continueFragment(body: Data, packet: RTPPacket, isEnd: Bool,
                                           at now: MediaInstant,
                                           into out: inout DepacketizerOutput) {
        guard var open = fragment else {
            report(.lostFirstFragment, at: now, into: &out)
            assembler.markAccessUnitCorrupt()
            if configuration.waitForKeyframeAfterLoss { assembler.armKeyframeGate() }
            return
        }
        guard packet.sequenceNumber == open.expectedSequence else {
            abandonFragment(.fragmentGap, at: now, into: &out)
            return
        }
        guard packet.timestamp == open.timestamp else {
            abandonFragment(.fragmentTimestampChange, at: now, into: &out)
            return
        }
        open.pieces.append(body)
        open.byteCount += body.count
        open.fragmentCount += 1
        open.expectedSequence = packet.sequenceNumber &+ 1
        guard open.fragmentCount <= configuration.maxFragmentsPerNAL,
              open.byteCount + 2 <= configuration.maxNALBytes else {
            fragment = open
            abandonFragment(.nalTooLarge, at: now, into: &out)
            return
        }
        fragment = open
        guard isEnd else { return }
        completeFragment(into: &out)
    }

    /// Concatenates a completed fragment run into one NAL unit and hands it to the assembler.
    private mutating func completeFragment(into out: inout DepacketizerOutput) {
        guard let open = fragment else { return }
        fragment = nil
        guard open.announced else { return }
        var nal = Data(capacity: open.byteCount + 2)
        nal.append(open.header.0)
        nal.append(open.header.1)
        for piece in open.pieces { nal.append(piece) }
        assembler.commitNAL(nal, into: &out)
    }

    /// Drops an in-progress fragment run, marking the access unit corrupt.
    private mutating func abandonFragment(_ reason: MalformedReason, at now: MediaInstant,
                                          into out: inout DepacketizerOutput) {
        guard let open = fragment else { return }
        fragment = nil
        if open.announced {
            assembler.abandonNAL(reason, into: &out)
        } else {
            report(reason, at: now, into: &out)
            assembler.markAccessUnitCorrupt()
        }
        if configuration.waitForKeyframeAfterLoss { assembler.armKeyframeGate() }
    }

    // MARK: - Private Helpers — classification

    /// Classifies and appends one complete NAL unit.
    private mutating func append(nal: Data, context: PacketContext, at now: MediaInstant,
                                 into out: inout DepacketizerOutput) {
        guard nal.count >= 2 else {
            report(.emptyPayload, at: now, into: &out)
            return
        }
        let b0 = nal.byte(at: 0)
        let b1 = nal.byte(at: 1)
        guard b0 & 0x80 == 0 else {
            report(.forbiddenBitSet, at: now, into: &out)
            return
        }
        guard layerID(b0, b1) == 0 else {
            reportUnsupported(.nonBaseLayer(layerID(b0, b1)), at: now, into: &out)
            return
        }
        // Filler data wastes decode bandwidth and carries nothing.
        guard (b0 >> 1) & 0x3F != 38 else { return }
        let descriptor = describe(header: (b0, b1), probe: nal)
        guard assembler.beginNAL(descriptor, packet: context, into: &out) else { return }
        assembler.commitNAL(nal, into: &out)
    }

    /// `nuh_layer_id`, which spans both header bytes.
    private func layerID(_ b0: UInt8, _ b1: UInt8) -> UInt16 {
        (UInt16(b0 & 0x01) << 5) | UInt16(b1 >> 3)
    }

    /// Turns a two-byte NAL header plus its leading bytes into a `NALDescriptor`.
    ///
    /// The slice-header bit comes from `VigilBitstream.SliceHeader`, which owns the only
    /// implementation of `first_slice_segment_in_pic_flag` (docs/API_CONTRACT.md §2 R-01).
    private func describe(header: (UInt8, UInt8), probe: Data) -> NALDescriptor {
        let type = (header.0 >> 1) & 0x3F
        let isVCL = type <= 31
        let isPrefix = (32...35).contains(type) || type == 39
        let isIRAP = (16...23).contains(type)
        var firstSlice = false
        if isVCL {
            firstSlice = probe.withUnsafeBytes { raw in
                SliceHeader.isFirstSliceOfPicture(nalUnit: raw, codec: .h265)
            }
        }
        let kind: ParameterSetKind? = switch type {
        case 32: .vps
        case 33: .sps
        case 34: .pps
        default: nil
        }
        return NALDescriptor(typeCode: type,
                             isVCL: isVCL,
                             isPrefix: isPrefix,
                             parameterSetKind: kind,
                             isIRAP: isIRAP,
                             isCRAOrBLA: (16...18).contains(type) || type == 21,
                             isRASL: type == 8 || type == 9,
                             isFirstSliceOfPicture: firstSlice,
                             isReference: true,
                             isISlice: isIRAP,
                             isRecoveryPoint: type == 39
                                 && SEIScanner.hasRecoveryPoint(probe, codec: .h265),
                             endsSequence: type == 36 || type == 37,
                             isEndOfStream: type == 37,
                             isSuffix: type == 40)
    }

    // MARK: - Private Helpers — events

    /// Emits a malformed-input event, rate limited to once per five seconds per reason.
    private mutating func report(_ reason: MalformedReason, at now: MediaInstant,
                                 into out: inout DepacketizerOutput) {
        if limiter.admit(reason.limiterKey, at: now) { out.events.append(.malformed(reason)) }
    }

    /// Emits an unsupported-feature event, rate limited to once per five seconds per feature.
    private mutating func reportUnsupported(_ feature: UnsupportedFeature, at now: MediaInstant,
                                            into out: inout DepacketizerOutput) {
        if limiter.admit(feature.limiterKey, at: now) { out.events.append(.unsupported(feature)) }
    }
}
