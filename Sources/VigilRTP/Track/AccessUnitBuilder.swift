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

    /// True when the open access unit already carries a recovery-point SEI.
    ///
    /// The H.264 front end reads it before deciding whether a slice's `slice_type` is worth the
    /// unescaping pass: outside an access unit that announced a recovery point, the answer never
    /// changes anything, and the read is the only allocation on the per-NAL path.
    var openAccessUnitSawRecoveryPoint: Bool { pending?.sawRecoveryPoint ?? false }

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

        if let open = pending {
            let timestampChanged = open.rtpTimestamp != packet.timestamp
            let prefixAfterSlices = descriptor.isPrefix && open.sawVCL
            let newPicture = descriptor.isVCL && open.sawVCL && descriptor.isFirstSliceOfPicture
            if timestampChanged || prefixAfterSlices || newPicture {
                closeAccessUnit(early: false, into: &out)
                startAccessUnit(packet: packet, into: &out)
            } else {
                noteContribution(packet)
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

    /// Records this packet against the open access unit and applies the close rules that depend on
    /// the packet rather than the NAL: the trusted marker bit (C2) and the learned single-slice
    /// shortcut (C3). Call once per packet, after every NAL it carried has been committed.
    ///
    /// The bookkeeping has to happen here rather than in `beginNAL`, because the continuation
    /// fragments of a NAL never begin one: without this a well-behaved camera that marks the last
    /// fragment of each picture would look like a camera that never marks anything.
    mutating func endOfPacket(_ packet: PacketContext, into out: inout DepacketizerOutput) {
        noteContribution(packet)
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

    /// Marks the open access unit as damaged without discarding it. Used when a fragment arrived
    /// that cannot be placed — the picture is incomplete even though we never announced its NAL.
    mutating func markAccessUnitCorrupt() {
        pending?.isCorrupt = true
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

    /// Records that `packet` belongs to the open access unit.
    ///
    /// Idempotent per packet: a packet that carried several NAL units, and a packet that both began
    /// and ended one, are counted once. A packet whose timestamp does not match the open access
    /// unit is ignored, so a malformed stray cannot corrupt the marker accounting.
    ///
    /// The marker rule this maintains is the whole point: `markerOnNonFinalPacket` becomes true as
    /// soon as a packet that had the marker set turns out not to have been the last one.
    private mutating func noteContribution(_ packet: PacketContext) {
        guard var open = pending,
              open.rtpTimestamp == packet.timestamp,
              open.contributingSequence != packet.extendedSequence else { return }
        if open.lastPacketHadMarker { open.markerOnNonFinalPacket = true }
        open.contributingSequence = packet.extendedSequence
        open.lastPacketHadMarker = packet.marker
        open.lastSequence = max(open.lastSequence, packet.extendedSequence)
        open.lastArrival = packet.arrival
        pending = open
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
