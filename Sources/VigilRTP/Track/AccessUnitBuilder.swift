//
//  AccessUnitBuilder.swift
//  VigilRTP
//
//  Access-unit assembly: the codec-independent half of depacketization. Applies the open and close
//  rules of docs/spec-rtp.md §7, materialises `EncodedFrame.data` as 4-byte big-endian
//  length-prefixed NAL units, and owns the keyframe gate and the in-band parameter-set store.
//  See docs/spec-rtp.md §5.7, §7 and docs/API_CONTRACT.md §3.5, §4.4.
//

import Foundation

import VigilBitstream
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

// MARK: - PendingAccessUnit

/// One access unit under construction. NAL payloads are held as `Data` slices and only concatenated
/// in `materialize`, so a packet is copied exactly once on its way to the decoder.
struct PendingAccessUnit: Sendable {
    var nals: [Data] = []
    var payloadBytes = 0
    var rtpTimestamp: UInt32
    var extendedTimestamp: Int64
    var firstArrival: MediaInstant
    var lastArrival: MediaInstant
    var firstSequence: UInt32
    var lastSequence: UInt32
    var contributingSequence: UInt32
    var vclCount = 0
    var sawVCL = false
    var lastCommittedWasVCL = false
    var containsIRAP = false
    var firstVCLIsRASL = false
    var startsWithCRAOrBLA = false
    var sawRecoveryPoint = false
    var sawISlice = false
    var allVCLNonReference = true
    var isCorrupt = false
    var isOversized = false
    var endsStream = false
    var lastPacketHadMarker = false
    var markerOnNonFinalPacket = false
    var vps: [Data] = []
    var sps: [Data] = []
    var pps: [Data] = []

    /// Total bytes `EncodedFrame.data` will occupy: every NAL plus its 4-byte length prefix.
    var materializedByteCount: Int { payloadBytes + 4 * nals.count }
}

// MARK: - AccessUnitAssembler

/// Assembles NAL units into access units and decides when one is complete.
///
/// The boundary rules are, in order of authority: the RTP timestamp changed, or a VCL NAL declared
/// itself the first slice of a picture. The marker bit participates only through `BoundaryPolicy`,
/// and only after it has earned it. Nothing here trusts a bit that Hikvision firmware is known to
/// set on every packet, on no packet, or one packet early.
struct AccessUnitAssembler: Sendable {

    // MARK: - Stored Properties

    /// The codec being assembled. Fixed for the lifetime of the track.
    let codec: VideoCodec

    /// Limits and policy switches.
    var configuration: DepacketizerConfiguration

    /// The learned boundary policy. Exposed so the depacketizer can report transitions.
    private(set) var boundary: BoundaryPolicy

    /// Parameter sets currently in force: the SDP's, overlaid by everything seen in band.
    private(set) var parameterSets: ParameterSets

    /// Monotonic access-unit counter. Dropped access units still consume an index so a consumer
    /// comparing consecutive values sees the gap (docs/API_CONTRACT.md §3.5).
    private(set) var accessUnitIndex: UInt64 = 0

    /// Parameter sets as they arrived from the SDP. Survives `reset()`.
    private let initialParameterSets: ParameterSets

    private var pending: PendingAccessUnit?
    private var pendingDescriptor: NALDescriptor?
    private var extender = RTPTimestampExtender()
    private var awaitingKeyframe: Bool
    private var droppedWhileAwaiting = 0
    private var parameterSetsDirty: Bool
    private var lastClosedTimestamp: UInt32?
    private var lastCloseWasEarly = false
    private var raslGateClosed = false
    private var clockRate: Int32

    // MARK: - Initialisation

    /// Creates an assembler for one video track.
    ///
    /// - Parameters:
    ///   - codec: H.264 or H.265. `.mjpeg` is not NAL-based and never reaches here.
    ///   - clockRate: RTP ticks per second, used as the `MediaTimestamp` timescale.
    ///   - configuration: limits and policy switches.
    ///   - initialParameterSets: parameter sets decoded from the SDP, or `nil`.
    init(codec: VideoCodec, clockRate: Int32, configuration: DepacketizerConfiguration,
         initialParameterSets: ParameterSets?) {
        self.codec = codec
        self.clockRate = clockRate
        self.configuration = configuration
        self.boundary = BoundaryPolicy(policy: configuration.trustMarkerBit)
        let seed = initialParameterSets ?? ParameterSets(codec: codec)
        self.initialParameterSets = seed
        self.parameterSets = seed
        self.parameterSetsDirty = !seed.vps.isEmpty || !seed.sps.isEmpty || !seed.pps.isEmpty
        self.awaitingKeyframe = configuration.waitForKeyframeOnStart
    }

    // MARK: - Package API

    /// True when a fragmented NAL has been announced but not yet completed.
    var hasUncommittedNAL: Bool { pendingDescriptor != nil }

    /// The instant at which the open access unit must be force-closed, or `nil` when none is open.
    var timeoutDeadline: MediaInstant? {
        pending.map { $0.lastArrival + configuration.accessUnitTimeout }
    }

    /// Applies the open rules to one NAL, closing and emitting the current access unit if this NAL
    /// starts a new one.
    ///
    /// Call this before the NAL's bytes are available: for a fragmented NAL, call it on the first
    /// fragment, so a multi-slice picture opens its new access unit at the right NAL rather than
    /// one NAL late (docs/spec-rtp.md §7.3).
    ///
    /// - Returns: false when the NAL must be discarded — the only case is a suffix NAL arriving for
    ///   an access unit that has already been emitted.
    mutating func beginNAL(_ descriptor: NALDescriptor, packet: PacketContext,
                           into out: inout DepacketizerOutput) -> Bool {
        if pending == nil, lastCloseWasEarly, lastClosedTimestamp == packet.timestamp {
            if descriptor.isSuffix {
                out.events.append(.malformed(.suffixNALAfterClose))
                return false
            }
            if descriptor.isVCL, !descriptor.isFirstSliceOfPicture {
                // We split a multi-slice picture. Stop using both shortcuts, and tell the caller the
                // stream needs a clean restart point.
                if boundary.notePrematureClose() {
                    out.events.append(.boundaryPolicyChanged(slice: boundary.sliceProfile,
                                                             marker: boundary.markerTrust))
                }
                out.events.append(.malformed(.prematureAccessUnitClose))
                out.events.append(.keyframeNeeded(reason: .corruptAccessUnit))
                if configuration.waitForKeyframeAfterLoss { awaitingKeyframe = true }
            }
        }

        if var open = pending {
            let timestampChanged = open.rtpTimestamp != packet.timestamp
            let prefixAfterSlices = descriptor.isPrefix && open.sawVCL
            let newPicture = descriptor.isVCL && open.sawVCL && descriptor.isFirstSliceOfPicture
            if timestampChanged || prefixAfterSlices || newPicture {
                closeAccessUnit(early: false, into: &out)
                startAccessUnit(packet: packet, into: &out)
            } else {
                noteContribution(&open, packet: packet)
                pending = open
            }
        } else {
            startAccessUnit(packet: packet, into: &out)
        }
        pendingDescriptor = descriptor
        return true
    }

    /// Appends the bytes of a NAL previously announced by `beginNAL`, then applies the close rules
    /// that depend on the NAL itself (C5 size, C6 end of sequence).
    ///
    /// - Parameter nal: the complete NAL unit, its header included, with no start code and no
    ///   length prefix, still emulation-escaped exactly as it arrived.
    mutating func commitNAL(_ nal: Data, into out: inout DepacketizerOutput) {
        guard let descriptor = pendingDescriptor, var open = pending else { return }
        pendingDescriptor = nil

        open.nals.append(nal)
        open.payloadBytes += nal.count
        if descriptor.isVCL {
            if !open.sawVCL {
                open.firstVCLIsRASL = descriptor.isRASL
                open.startsWithCRAOrBLA = descriptor.isCRAOrBLA
            }
            open.sawVCL = true
            open.vclCount += 1
            open.containsIRAP = open.containsIRAP || descriptor.isIRAP
            open.allVCLNonReference = open.allVCLNonReference && !descriptor.isReference
            open.sawISlice = open.sawISlice || descriptor.isISlice
        }
        open.sawRecoveryPoint = open.sawRecoveryPoint || descriptor.isRecoveryPoint
        open.endsStream = open.endsStream || descriptor.isEndOfStream
        open.lastCommittedWasVCL = descriptor.isVCL
        switch descriptor.parameterSetKind {
        case .vps: open.vps.append(nal)
        case .sps: open.sps.append(nal)
        case .pps: open.pps.append(nal)
        case nil: break
        }
        if open.materializedByteCount > configuration.maxAccessUnitBytes { open.isOversized = true }
        pending = open

        if descriptor.endsSequence { closeAccessUnit(early: false, into: &out) }
    }

    /// Abandons a NAL announced by `beginNAL` whose bytes will never arrive. The access unit is
    /// marked corrupt so a picture missing a slice is never handed to the decoder intact-looking.
    mutating func abandonNAL(_ reason: MalformedReason, into out: inout DepacketizerOutput) {
        pendingDescriptor = nil
        pending?.isCorrupt = true
        out.events.append(.malformed(reason))
    }

    /// Applies the close rules that depend on the packet rather than the NAL: the trusted marker
    /// bit (C2) and the learned single-slice shortcut (C3). Call once per packet, after every NAL
    /// it carried has been committed.
    mutating func endOfPacket(_ packet: PacketContext, into out: inout DepacketizerOutput) {
        guard pendingDescriptor == nil, let open = pending else { return }
        let markerClose = packet.marker && boundary.allowsMarkerFastPath
        let sliceClose = open.lastCommittedWasVCL && boundary.allowsSingleSliceFastPath
        guard markerClose || sliceClose else { return }
        closeAccessUnit(early: true, into: &out)
    }

    /// Force-closes an access unit that has been idle past `accessUnitTimeout` (close rule C4).
    mutating func tick(at now: MediaInstant, into out: inout DepacketizerOutput) {
        guard let open = pending, now >= open.lastArrival + configuration.accessUnitTimeout else { return }
        if pendingDescriptor != nil {
            pendingDescriptor = nil
            pending?.isCorrupt = true
            out.events.append(.malformed(.incompleteFragmentAtAUEnd))
        }
        closeAccessUnit(early: false, into: &out)
    }

    /// Closes and emits any open access unit. Called on flush, PAUSE and TEARDOWN.
    mutating func finish(into out: inout DepacketizerOutput) {
        guard pending != nil else { return }
        closeAccessUnit(early: false, into: &out)
    }

    /// Discards the open access unit without emitting it, and re-arms the keyframe gate. Used when
    /// the caller has detected loss that makes the picture unusable.
    mutating func discardOpenAccessUnit(_ reason: DropReason, into out: inout DepacketizerOutput) {
        guard pending != nil else { return }
        pending = nil
        pendingDescriptor = nil
        out.events.append(.accessUnitDropped(reason: reason))
        if configuration.waitForKeyframeAfterLoss {
            awaitingKeyframe = true
            out.events.append(.keyframeNeeded(reason: .packetLoss))
        }
    }

    /// Re-arms the keyframe gate, so nothing is emitted until the next IRAP.
    mutating func armKeyframeGate() {
        awaitingKeyframe = true
    }

    /// Full reset. Parameter sets from the SDP survive; everything learned in band does not.
    mutating func reset() {
        pending = nil
        pendingDescriptor = nil
        extender.reset()
        boundary.reset()
        parameterSets = initialParameterSets
        parameterSetsDirty = !initialParameterSets.sps.isEmpty || !initialParameterSets.pps.isEmpty
            || !initialParameterSets.vps.isEmpty
        accessUnitIndex = 0
        awaitingKeyframe = configuration.waitForKeyframeOnStart
        droppedWhileAwaiting = 0
        lastClosedTimestamp = nil
        lastCloseWasEarly = false
        raslGateClosed = false
    }

    // MARK: - Private Helpers

    /// Opens a new access unit for `packet`, widening its timestamp and reporting a discontinuity.
    private mutating func startAccessUnit(packet: PacketContext, into out: inout DepacketizerOutput) {
        let (value, delta) = extender.extend(packet.timestamp)
        if clockRate > 0, abs(Int64(delta)) > Int64(clockRate) * 10 {
            out.events.append(.timestampDiscontinuity(seconds: Double(delta) / Double(clockRate)))
        }
        pending = PendingAccessUnit(rtpTimestamp: packet.timestamp,
                                    extendedTimestamp: value,
                                    firstArrival: packet.arrival,
                                    lastArrival: packet.arrival,
                                    firstSequence: packet.extendedSequence,
                                    lastSequence: packet.extendedSequence,
                                    contributingSequence: packet.extendedSequence,
                                    lastPacketHadMarker: packet.marker)
    }

    /// Records that `packet` contributed a NAL to the open access unit, tracking whether the marker
    /// bit landed anywhere other than the final packet.
    private func noteContribution(_ open: inout PendingAccessUnit, packet: PacketContext) {
        guard open.contributingSequence != packet.extendedSequence else { return }
        if open.lastPacketHadMarker { open.markerOnNonFinalPacket = true }
        open.contributingSequence = packet.extendedSequence
        open.lastPacketHadMarker = packet.marker
        open.lastSequence = max(open.lastSequence, packet.extendedSequence)
        open.lastArrival = packet.arrival
    }

    /// Closes the open access unit: folds it into the learned policy, merges its parameter sets,
    /// then either emits a frame or reports why it did not.
    private mutating func closeAccessUnit(early: Bool, into out: inout DepacketizerOutput) {
        guard var closing = pending else { return }
        pending = nil
        if pendingDescriptor != nil {
            pendingDescriptor = nil
            closing.isCorrupt = true
            out.events.append(.malformed(.incompleteFragmentAtAUEnd))
        }
        lastClosedTimestamp = closing.rtpTimestamp
        lastCloseWasEarly = early

        let markerClean = closing.lastPacketHadMarker && !closing.markerOnNonFinalPacket
        if boundary.noteClosedAccessUnit(vclCount: closing.vclCount, markerWasClean: markerClean) {
            out.events.append(.boundaryPolicyChanged(slice: boundary.sliceProfile,
                                                     marker: boundary.markerTrust))
        }
        mergeParameterSets(from: closing, into: &out)
        if closing.endsStream { out.events.append(.endOfStream) }
        emit(closing, into: &out)
    }

    /// Overlays the parameter sets carried inside one access unit onto the running set.
    ///
    /// Replace-per-kind rather than append: Hikvision resends the whole set before every IDR, so an
    /// access unit that carried an SPS carried *the* SPS. A kind absent from the access unit keeps
    /// whatever was in force. Unchanged bytes raise no event (docs/API_CONTRACT.md §2 R-53).
    private mutating func mergeParameterSets(from closing: PendingAccessUnit,
                                             into out: inout DepacketizerOutput) {
        guard !closing.vps.isEmpty || !closing.sps.isEmpty || !closing.pps.isEmpty else { return }
        var merged = parameterSets
        if !closing.vps.isEmpty { merged.vps = closing.vps }
        if !closing.sps.isEmpty { merged.sps = closing.sps }
        if !closing.pps.isEmpty { merged.pps = closing.pps }
        guard merged != parameterSets else { return }
        parameterSets = merged
        parameterSetsDirty = true
        out.events.append(.parameterSetsChanged(merged))
    }

    /// Applies the gates in order and either appends a frame or explains the drop.
    private mutating func emit(_ closing: PendingAccessUnit, into out: inout DepacketizerOutput) {
        // A parameter-set-only access unit is configuration, not a picture. It was already surfaced
        // by `mergeParameterSets`; emitting an empty frame would only confuse the decoder.
        guard closing.vclCount > 0 else { return }
        accessUnitIndex += 1

        let isKeyframe = closing.containsIRAP
            || (configuration.treatRecoveryPointAsKeyframe && closing.sawRecoveryPoint
                && closing.sawISlice)

        if configuration.dropRASLAfterCRA, raslGateClosed {
            if closing.firstVCLIsRASL {
                out.events.append(.accessUnitDropped(reason: .raslAfterCRA))
                return
            }
            raslGateClosed = false
        }
        if closing.isOversized {
            out.events.append(.accessUnitDropped(reason: .tooLarge))
            out.events.append(.keyframeNeeded(reason: .corruptAccessUnit))
            awaitingKeyframe = true
            return
        }
        if awaitingKeyframe {
            guard isKeyframe else {
                droppedWhileAwaiting += 1
                out.events.append(.awaitingKeyframe(droppedAccessUnits: droppedWhileAwaiting))
                return
            }
            awaitingKeyframe = false
            droppedWhileAwaiting = 0
        }
        if closing.isCorrupt, !configuration.emitCorruptFrames {
            out.events.append(.accessUnitDropped(reason: .corrupt))
            out.events.append(.keyframeNeeded(reason: .corruptAccessUnit))
            if configuration.waitForKeyframeAfterLoss { awaitingKeyframe = true }
            return
        }
        if isKeyframe, closing.startsWithCRAOrBLA { raslGateClosed = true }

        out.frames.append(makeFrame(closing, isKeyframe: isKeyframe))
    }

    /// Materialises `EncodedFrame.data` and fills in the accounting fields.
    private mutating func makeFrame(_ closing: PendingAccessUnit, isKeyframe: Bool) -> EncodedFrame {
        var writer = ByteWriter(capacity: closing.materializedByteCount)
        for nal in closing.nals {
            nal.withUnsafeBytes { raw in
                LengthPrefixed.append(nal: raw, to: &writer)
            }
        }
        let attached: ParameterSets? = parameterSetsDirty ? parameterSets : nil
        parameterSetsDirty = false
        // H.265 sub-layer droppability needs `sps_temporal_id_nesting_flag`, which the depacketizer
        // does not parse; classifying conservatively is the only safe choice there.
        let dropClass: FrameDropClass = codec == .h264 && closing.allVCLNonReference
            ? .droppableNonReference : .required
        let low = min(closing.firstSequence, closing.lastSequence)
        let high = max(closing.firstSequence, closing.lastSequence)
        return EncodedFrame(data: writer.data,
                            codec: .video(codec),
                            pts: MediaTimestamp(value: closing.extendedTimestamp,
                                                timescale: clockRate),
                            receivedAt: closing.lastArrival,
                            isKeyframe: isKeyframe,
                            dropClass: dropClass,
                            isCorrupt: closing.isCorrupt,
                            parameterSets: attached,
                            sequenceRange: low...high,
                            accessUnitIndex: accessUnitIndex - 1,
                            nalCount: closing.nals.count)
    }
}
