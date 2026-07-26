//
//  NALDescriptor.swift
//  VigilRTP
//
//  The small value types access-unit assembly is built from: payload-relative byte access, the
//  16-bit sequence and 32-bit timestamp extenders, the SEI recovery-point scanner, and the
//  per-NAL classification the codec front ends produce.
//  See docs/spec-rtp.md §5.6, §7.3 and docs/API_CONTRACT.md §4.4.
//

import Foundation

import VigilProtocols

// MARK: - RTPTimestampExtender

/// Widens the 32-bit RTP timestamp into a monotonic `Int64` before it becomes a `MediaTimestamp`.
///
/// A 90 kHz video clock wraps every 13.25 hours; a `MediaTimestamp` that wrapped with it would send
/// presentation time backwards in the middle of a night recording. Deltas are taken in signed
/// 32-bit space, so a wrap forwards and a small reorder backwards are both handled without a
/// special case.
struct RTPTimestampExtender: Sendable, Equatable {

    /// The most recent raw timestamp, or `nil` before the first packet.
    private var lastRaw: UInt32?

    /// The running widened value.
    private var extended: Int64 = 0

    /// Widens `raw`, returning the monotonic value and the signed tick delta from the previous
    /// call. The delta is `0` for the first call.
    mutating func extend(_ raw: UInt32) -> (value: Int64, delta: Int32) {
        guard let last = lastRaw else {
            lastRaw = raw
            extended = Int64(raw)
            return (extended, 0)
        }
        let delta = Int32(bitPattern: raw &- last)
        extended &+= Int64(delta)
        lastRaw = raw
        return (extended, delta)
    }

    /// Forgets all history, so the next call restarts from the raw value.
    mutating func reset() {
        lastRaw = nil
        extended = 0
    }
}

// MARK: - Payload Byte Access

/// Offset-relative reads over a `Data` that is usually a slice of a receive buffer.
///
/// `Data` slices keep their parent's indices, so `payload[0]` traps on a slice that does not start
/// at zero. Every offset in RFC 6184 and RFC 7798 is relative to the payload, so these three
/// helpers exist to keep that arithmetic in one place rather than in every bounds check.
extension Data {

    /// The byte `offset` bytes into this payload. The caller must have bounds-checked `offset`.
    @inlinable func byte(at offset: Int) -> UInt8 { self[startIndex + offset] }

    /// The big-endian 16-bit value at `offset`. The caller must have checked `offset + 2 <= count`.
    @inlinable func u16BE(at offset: Int) -> UInt16 {
        let index = startIndex + offset
        return UInt16(self[index]) << 8 | UInt16(self[index + 1])
    }

    /// The sub-slice covering `range`, whose bounds are relative to this payload's start.
    @inlinable func slice(_ range: Range<Int>) -> Data {
        self[(startIndex + range.lowerBound)..<(startIndex + range.upperBound)]
    }
}

// MARK: - SEIScanner

/// Reads the `payloadType` of the SEI messages at the front of an SEI NAL unit.
///
/// Only enough to answer one question: does this SEI open with a recovery point? Several Hikvision
/// H.264 builds signal open-GOP random access with a recovery-point SEI and an I-slice, sending a
/// true IDR only every few minutes; without this the keyframe gate can stall a stream for minutes
/// after any loss (docs/spec-rtp.md §5.6).
enum SEIScanner {

    /// True when the first SEI message in `nal` is a recovery point (payload type 6).
    ///
    /// - Parameters:
    ///   - nal: the SEI NAL unit, header included. May be a prefix of one: a truncated buffer
    ///     simply returns false.
    ///   - codec: selects the NAL header length, 1 byte for H.264 and 2 for H.265.
    static func hasRecoveryPoint(_ nal: Data, codec: VideoCodec) -> Bool {
        var index = codec.nalHeaderLength
        var payloadType = 0
        while index < nal.count, nal.byte(at: index) == 0xFF {
            payloadType += 255
            index += 1
        }
        guard index < nal.count else { return false }
        payloadType += Int(nal.byte(at: index))
        return payloadType == 6
    }
}

// MARK: - SequenceExtender

/// Widens the 16-bit RTP sequence number into a monotonic `UInt32` for `EncodedFrame.sequenceRange`.
///
/// Same signed-delta trick as `RTPTimestampExtender`: a wrap from 65535 to 0 is a delta of +1, and a
/// reordered packet arriving late is a small negative delta, not a 65535-packet jump.
struct SequenceExtender: Sendable, Equatable {

    private var last: UInt16?
    private var extended: UInt32 = 0

    /// Widens `sequence` and returns the monotonic value.
    mutating func extend(_ sequence: UInt16) -> UInt32 {
        guard let last else {
            self.last = sequence
            extended = UInt32(sequence)
            return extended
        }
        let delta = Int32(Int16(bitPattern: sequence &- last))
        extended = extended &+ UInt32(bitPattern: delta)
        self.last = sequence
        return extended
    }

    /// Forgets all history.
    mutating func reset() {
        last = nil
        extended = 0
    }
}

// MARK: - PacketContext

/// The per-packet facts access-unit assembly needs, extracted once so the assembler never touches
/// `RTPPacket` and stays usable from a file-replay fixture.
struct PacketContext: Sendable {
    /// Raw 32-bit RTP timestamp, as it appeared on the wire.
    var timestamp: UInt32
    /// The marker bit. Recorded, learned from, and never trusted on its own.
    var marker: Bool
    /// Unwrapped sequence number, for `EncodedFrame.sequenceRange`.
    var extendedSequence: UInt32
    /// Arrival instant, injected by the caller.
    var arrival: MediaInstant
}

// MARK: - NALDescriptor

/// Which parameter-set array a NAL belongs in.
enum ParameterSetKind: Sendable, Equatable {
    case vps, sps, pps
}

/// Everything the assembler needs to know about one NAL unit, classified by the codec-specific
/// depacketizer that decoded it.
///
/// `isFirstSliceOfPicture` is the only field with a hard external dependency: it comes from
/// `VigilBitstream.SliceHeader`, which owns the single implementation of `first_mb_in_slice` and
/// `first_slice_segment_in_pic_flag` (docs/API_CONTRACT.md §2 R-01).
struct NALDescriptor: Sendable {
    /// `nal_unit_type`, 5 bits for H.264 and 6 bits for H.265.
    var typeCode: UInt8
    /// True for a slice NAL of any kind.
    var isVCL: Bool
    /// True for a NAL that must start a new access unit when one is already carrying slices:
    /// SEI, parameter sets, access-unit delimiters. This is open rule O3.
    var isPrefix: Bool
    /// Non-`nil` when this NAL is a parameter set that should be captured.
    var parameterSetKind: ParameterSetKind?
    /// True for H.264 IDR and H.265 IRAP (types 16…23).
    var isIRAP: Bool
    /// H.265 CRA or BLA specifically: the IRAP kinds that make following RASL pictures undecodable.
    var isCRAOrBLA: Bool
    /// H.265 RASL_N or RASL_R.
    var isRASL: Bool
    /// From `VigilBitstream.SliceHeader.isFirstSliceOfPicture`. Meaningless unless `isVCL`.
    var isFirstSliceOfPicture: Bool
    /// H.264 `nal_ref_idc != 0`. Always true for H.265, where the equivalent needs the SPS.
    var isReference: Bool
    /// True for a slice header that decodes as I or SI, when that was cheap to determine.
    var isISlice: Bool
    /// True for an SEI NAL whose first message is a recovery point.
    var isRecoveryPoint: Bool
    /// End of sequence or end of stream: close the access unit (close rule C6).
    var endsSequence: Bool
    /// End of stream specifically, which also raises `DepacketizerEvent.endOfStream`.
    var isEndOfStream: Bool
    /// A suffix SEI, or an H.264 SEI arriving after the picture: discardable after an early close.
    var isSuffix: Bool

    /// Creates a descriptor. Every flag defaults to the conservative value, so a codec front end
    /// only sets what it has actually determined.
    init(typeCode: UInt8, isVCL: Bool = false, isPrefix: Bool = false,
         parameterSetKind: ParameterSetKind? = nil, isIRAP: Bool = false, isCRAOrBLA: Bool = false,
         isRASL: Bool = false, isFirstSliceOfPicture: Bool = false, isReference: Bool = true,
         isISlice: Bool = false, isRecoveryPoint: Bool = false, endsSequence: Bool = false,
         isEndOfStream: Bool = false, isSuffix: Bool = false) {
        self.typeCode = typeCode
        self.isVCL = isVCL
        self.isPrefix = isPrefix
        self.parameterSetKind = parameterSetKind
        self.isIRAP = isIRAP
        self.isCRAOrBLA = isCRAOrBLA
        self.isRASL = isRASL
        self.isFirstSliceOfPicture = isFirstSliceOfPicture
        self.isReference = isReference
        self.isISlice = isISlice
        self.isRecoveryPoint = isRecoveryPoint
        self.endsSequence = endsSequence
        self.isEndOfStream = isEndOfStream
        self.isSuffix = isSuffix
    }
}
