//
//  H264Depacketizer.swift
//  VigilRTP
//
//  RFC 6184 depacketization: single NAL unit packets, STAP-A aggregation and FU-A fragmentation.
//  MTAP16/MTAP24 are rejected rather than half-implemented; STAP-B and FU-B are accepted with their
//  DON fields parsed for alignment and discarded.
//  See docs/spec-rtp.md §5 and docs/API_CONTRACT.md §4.4.
//

import Foundation

import VigilBitstream
import VigilProtocols

// MARK: - H264Depacketizer

/// Reassembles H.264 access units from RTP.
///
/// Access-unit boundaries come from the RTP timestamp and from `first_mb_in_slice`, never from the
/// marker bit — see `AccessUnitAssembler` and `BoundaryPolicy`. Every malformed input is counted
/// and reported; nothing here throws, and a truncated slice is discarded rather than handed on.
public struct H264Depacketizer: Depacketizer {

    // MARK: - Nested Types

    /// RFC 6184 §5.1 packet types that are not themselves NAL units.
    private enum PacketType {
        static let stapA: UInt8 = 24
        static let stapB: UInt8 = 25
        static let mtap16: UInt8 = 26
        static let mtap24: UInt8 = 27
        static let fuA: UInt8 = 28
        static let fuB: UInt8 = 29
    }

    /// An FU-A/FU-B reassembly in progress.
    private struct FragmentState {
        /// The reconstructed original NAL header byte.
        var header: UInt8
        var typeCode: UInt8
        var pieces: [Data]
        var byteCount: Int
        var timestamp: UInt32
        /// The sequence number the next fragment must carry.
        var expectedSequence: UInt16
        var fragmentCount: Int
        /// False when `beginNAL` refused the NAL, so no `abandonNAL` is owed.
        var announced: Bool
    }

    // MARK: - Stored Properties

    /// Always `.video(.h264)`.
    public let codec: MediaCodec = .video(.h264)

    /// RTP clock rate; 90 000 for every Hikvision video profile.
    public let clockRate: Int32

    private var assembler: AccessUnitAssembler
    private var fragment: FragmentState?
    private var limiter = EventRateLimiter()
    private var sequences = SequenceExtender()
    private let configuration: DepacketizerConfiguration

    // MARK: - Initialisation

    /// Creates a depacketizer for one H.264 track.
    ///
    /// - Parameters:
    ///   - clockRate: from `a=rtpmap`. Values of zero or less are replaced by 90 000, because every
    ///     timestamp computed from a non-positive timescale would be meaningless.
    ///   - configuration: limits and policy switches.
    ///   - initialParameterSets: `sprop-parameter-sets` from the SDP, already base64-decoded.
    public init(clockRate: Int32 = 90_000,
                configuration: DepacketizerConfiguration = .liveDefault,
                initialParameterSets: ParameterSets? = nil) {
        let rate = clockRate > 0 ? clockRate : 90_000
        self.clockRate = rate
        self.configuration = configuration
        self.assembler = AccessUnitAssembler(codec: .h264, clockRate: rate,
                                             configuration: configuration,
                                             initialParameterSets: initialParameterSets)
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
        guard let first = payload.first else {
            report(.emptyPayload, at: now, into: &out)
            return out
        }
        guard first & 0x80 == 0 else {
            report(.forbiddenBitSet, at: now, into: &out)
            return out
        }

        switch first & 0x1F {
        case PacketType.stapA:
            unpackAggregate(payload, donBytes: 0, context: context, at: now, into: &out)
        case PacketType.stapB:
            reportUnsupported(.interleavedMode, at: now, into: &out)
            unpackAggregate(payload, donBytes: 2, context: context, at: now, into: &out)
        case PacketType.mtap16, PacketType.mtap24:
            reportUnsupported(.aggregationType(first & 0x1F), at: now, into: &out)
        case PacketType.fuA:
            unpackFragment(payload, packet: packet, context: context, donCapable: false,
                           at: now, into: &out)
        case PacketType.fuB:
            reportUnsupported(.interleavedMode, at: now, into: &out)
            unpackFragment(payload, packet: packet, context: context, donCapable: true,
                           at: now, into: &out)
        case 0, 30, 31:
            reportUnsupported(.packetizationType(first & 0x1F), at: now, into: &out)
        default:
            appendSingleNAL(payload, context: context, into: &out)
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

    /// A single NAL unit packet: the whole payload is one NAL, header included (RFC 6184 §5.6).
    private mutating func appendSingleNAL(_ payload: Data, context: PacketContext,
                                          into out: inout DepacketizerOutput) {
        append(nal: payload, context: context, into: &out)
    }

    /// STAP-A (and STAP-B, whose only difference is a leading DON) per RFC 6184 §5.7.1.
    ///
    /// A zero size, or a size that overruns the payload, discards the remainder of the packet but
    /// keeps the NAL units already extracted and marks the access unit corrupt.
    private mutating func unpackAggregate(_ payload: Data, donBytes: Int, context: PacketContext,
                                          at now: MediaInstant, into out: inout DepacketizerOutput) {
        var index = 1 + donBytes
        guard payload.count >= index else {
            report(.truncatedAggregate, at: now, into: &out)
            return
        }
        var unpacked = 0
        while index < payload.count {
            guard unpacked < configuration.maxAggregatedNALs else {
                report(.truncatedAggregate, at: now, into: &out)
                assembler.markAccessUnitCorrupt()
                return
            }
            guard index + 2 <= payload.count else {
                report(.truncatedAggregate, at: now, into: &out)
                assembler.markAccessUnitCorrupt()
                return
            }
            let size = Int(payload.u16BE(at: index))
            index += 2
            guard size > 0 else {
                report(.zeroLengthAggregate, at: now, into: &out)
                assembler.markAccessUnitCorrupt()
                return
            }
            guard index + size <= payload.count else {
                report(.truncatedAggregate, at: now, into: &out)
                assembler.markAccessUnitCorrupt()
                return
            }
            append(nal: payload.slice(index..<(index + size)), context: context, into: &out)
            index += size
            unpacked += 1
        }
    }

    /// FU-A (and FU-B, which carries a DON on its start fragment) per RFC 6184 §5.8.
    private mutating func unpackFragment(_ payload: Data, packet: RTPPacket,
                                         context: PacketContext, donCapable: Bool,
                                         at now: MediaInstant, into out: inout DepacketizerOutput) {
        guard payload.count >= 2 else {
            report(.truncatedFragment, at: now, into: &out)
            return
        }
        let indicator = payload[payload.startIndex]
        let fuHeader = payload[payload.startIndex + 1]
        let isStart = fuHeader & 0x80 != 0
        let isEnd = fuHeader & 0x40 != 0
        let typeCode = fuHeader & 0x1F
        // FU-B carries a 16-bit DON after the FU header, but only on the start fragment.
        let dataStart = 2 + (donCapable && isStart ? 2 : 0)
        guard payload.count > dataStart else {
            report(.truncatedFragment, at: now, into: &out)
            return
        }
        let body = payload.slice(dataStart..<payload.count)

        if isStart {
            startFragment(indicator: indicator, typeCode: typeCode, body: body, packet: packet,
                          context: context, at: now, into: &out)
        } else {
            continueFragment(body: body, packet: packet, isEnd: isEnd, at: now, into: &out)
        }
    }

    /// Begins a fragment run. `S` while a run is already open means its last fragment was lost.
    private mutating func startFragment(indicator: UInt8, typeCode: UInt8, body: Data,
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
        // F and NRI come from the FU indicator, the type from the FU header. 0xE0 keeps the
        // forbidden bit as well as NRI; the reserved bit of the FU header is deliberately dropped.
        let header = (indicator & 0xE0) | typeCode
        guard typeCode >= 1, typeCode <= 23 else {
            // A FU cannot fragment an aggregation or another FU.
            report(.nestedPacketization, at: now, into: &out)
            return
        }
        let descriptor = describe(header: header, probe: probeBytes(header: header, body: body))
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
            // The start fragment was lost. Emitting what remains would hand the decoder a NAL with
            // no header and half a slice, so the whole run is dropped.
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
              open.byteCount + 1 <= configuration.maxNALBytes else {
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
        var nal = Data(capacity: open.byteCount + 1)
        nal.append(open.header)
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
    private mutating func append(nal: Data, context: PacketContext,
                                 into out: inout DepacketizerOutput) {
        guard let header = nal.first else { return }
        guard header & 0x80 == 0 else { return }
        // Filler data wastes decode bandwidth and carries nothing.
        guard header & 0x1F != 12 else { return }
        let descriptor = describe(header: header, probe: nal)
        guard assembler.beginNAL(descriptor, packet: context, into: &out) else { return }
        assembler.commitNAL(nal, into: &out)
    }

    /// Builds the few leading bytes of a NAL that the slice-header predicate needs, so a fragmented
    /// slice can be classified from its first fragment without waiting for reassembly.
    private func probeBytes(header: UInt8, body: Data) -> Data {
        var probe = Data(capacity: 5)
        probe.append(header)
        probe.append(body.prefix(4))
        return probe
    }

    /// Turns a NAL header plus its leading bytes into a `NALDescriptor`.
    ///
    /// The slice-header bit comes from `VigilBitstream.SliceHeader`, which owns the only
    /// implementation of `first_mb_in_slice` in the repository (docs/API_CONTRACT.md §2 R-01).
    private func describe(header: UInt8, probe: Data) -> NALDescriptor {
        let type = header & 0x1F
        let isVCL = (1...5).contains(type) || type == 19 || type == 20
        let isPrefix = type == 6 || (7...9).contains(type) || (13...15).contains(type)
        var firstSlice = false
        var isISlice = false
        if isVCL {
            firstSlice = probe.withUnsafeBytes { raw in
                SliceHeader.isFirstSliceOfPicture(nalUnit: raw, codec: .h264)
            }
            if configuration.treatRecoveryPointAsKeyframe {
                let sliceType = probe.withUnsafeBytes { raw in
                    SliceHeader.sliceType(nalUnit: raw, codec: .h264)
                }
                isISlice = sliceType.map { [2, 4, 7, 9].contains($0) } ?? false
            }
        }
        let kind: ParameterSetKind? = type == 7 ? .sps : (type == 8 ? .pps : nil)
        return NALDescriptor(typeCode: type,
                             isVCL: isVCL,
                             isPrefix: isPrefix,
                             parameterSetKind: kind,
                             isIRAP: type == 5,
                             isFirstSliceOfPicture: firstSlice,
                             isReference: header & 0x60 != 0,
                             isISlice: isISlice,
                             isRecoveryPoint: type == 6 && SEIScanner.hasRecoveryPoint(probe,
                                                                                       codec: .h264),
                             endsSequence: type == 10 || type == 11,
                             isEndOfStream: type == 11,
                             isSuffix: type == 6)
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
