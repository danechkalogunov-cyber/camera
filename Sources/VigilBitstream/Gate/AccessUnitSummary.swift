//
//  AccessUnitSummary.swift
//  VigilBitstream
//
//  What one access unit contains, and the gate that decides whether it may be handed to a decoder.
//  The gate starts closed on every PLAY, reconnect and decoder reset, and drops RASL pictures that
//  follow a CRA start — feeding a decoder pictures that reference frames it never saw produces
//  visible corruption, not a graceful failure.
//  Implements docs/spec-bitstream.md §20.2–§20.5.
//

import VigilProtocols

// MARK: - AccessUnitSummary

/// A classification of the NAL units in one access unit.
///
/// Built incrementally by the depacketizer as NAL units arrive — `observe` is called once per NAL
/// and does no parsing beyond reading the type code — then handed to `IRAPGate` once the access
/// unit is complete.
public struct AccessUnitSummary: Sendable, Hashable {

    // MARK: - Stored Properties

    /// The codec, which decides how a type code is read and what the IRAP ranges mean.
    public var codec: VideoCodec

    /// H.264: a type-5 NAL. H.265: any of types 16…23.
    public var containsIRAP: Bool

    /// H.265 only: BLA (16…18) or CRA (21). These are the IRAP kinds that can be followed by RASL
    /// pictures referencing frames before them.
    public var containsCRAOrBLA: Bool

    /// H.264: type 5. H.265: types 19 and 20. An IDR resets the decoded picture buffer outright.
    public var containsIDR: Bool

    /// H.265 only: a RASL NAL (types 8 or 9).
    public var containsRASL: Bool

    /// True when the access unit contains at least one VCL NAL. An access unit of parameter sets
    /// and SEI alone has nothing to decode.
    public var containsVCL: Bool

    /// The `recovery_point` SEI message found in this access unit, if any.
    public var recoveryPoint: RecoveryPoint?

    /// True when the parameter-set store holds a complete set of bytes. **About bytes, never about
    /// parse success**: a parameter set we could not parse is still forwarded to the decoder.
    public var parameterSetsAvailable: Bool

    /// True when a VCL NAL with `first_mb_in_slice == 0` / `first_slice_segment_in_pic_flag == 1`
    /// was seen. A picture whose first slice was lost is incomplete and decodes to garbage.
    public var firstSliceSeen: Bool

    // MARK: - Initialisation

    /// Builds an empty summary that `observe` then fills in.
    public init(codec: VideoCodec, parameterSetsAvailable: Bool = false) {
        self.codec = codec
        self.containsIRAP = false
        self.containsCRAOrBLA = false
        self.containsIDR = false
        self.containsRASL = false
        self.containsVCL = false
        self.recoveryPoint = nil
        self.parameterSetsAvailable = parameterSetsAvailable
        self.firstSliceSeen = false
    }

    /// Builds a fully specified summary, for tests and for a caller that classified elsewhere.
    public init(codec: VideoCodec, containsIRAP: Bool = false, containsCRAOrBLA: Bool = false,
                containsIDR: Bool = false, containsRASL: Bool = false, containsVCL: Bool = false,
                recoveryPoint: RecoveryPoint? = nil, parameterSetsAvailable: Bool = false,
                firstSliceSeen: Bool = false) {
        self.codec = codec
        self.containsIRAP = containsIRAP
        self.containsCRAOrBLA = containsCRAOrBLA
        self.containsIDR = containsIDR
        self.containsRASL = containsRASL
        self.containsVCL = containsVCL
        self.recoveryPoint = recoveryPoint
        self.parameterSetsAvailable = parameterSetsAvailable
        self.firstSliceSeen = firstSliceSeen
    }

    // MARK: - Accumulation

    /// Folds one NAL unit's type code into the summary.
    ///
    /// The classification is written as raw type-code ranges from H.264 Table 7-1 and H.265
    /// Table 7-1 rather than by constructing a `H264NALType`/`H265NALType`, because this runs once
    /// per NAL on the receive path and an enum construction with a failable initialiser is a
    /// branch and a memory access this does not need.
    ///
    /// - Parameters:
    ///   - typeCode: `nal_unit_type`, already extracted from the header.
    ///   - isFirstSlice: the result of `SliceHeader.isFirstSliceOfPicture` for this NAL, which the
    ///     caller has usually computed already; ignored for non-VCL NAL units.
    public mutating func observe(typeCode: UInt8, isFirstSlice: Bool = false) {
        switch codec {
        case .h264:
            let isVCL = (1 ... 5).contains(typeCode)
            if isVCL {
                containsVCL = true
                if isFirstSlice { firstSliceSeen = true }
            }
            if typeCode == 5 {
                containsIRAP = true
                containsIDR = true
            }
        case .h265:
            let isVCL = typeCode <= 31
            if isVCL {
                containsVCL = true
                if isFirstSlice { firstSliceSeen = true }
            }
            if (16 ... 23).contains(typeCode) { containsIRAP = true }
            if (16 ... 18).contains(typeCode) || typeCode == 21 { containsCRAOrBLA = true }
            if typeCode == 19 || typeCode == 20 { containsIDR = true }
            if typeCode == 8 || typeCode == 9 { containsRASL = true }
        case .mjpeg:
            containsVCL = true
            containsIRAP = true
            containsIDR = true
            firstSliceSeen = true
        }
    }

    /// Folds one NAL unit into the summary, reading its type code and first-slice bit directly.
    ///
    /// `nalUnit` includes its NAL header and carries no start code or length prefix. A NAL shorter
    /// than its header is ignored rather than throwing: a truncated NAL means a lost packet, which
    /// is a normal event, and the access unit is still classified from whatever else arrived.
    public mutating func observe(nalUnit: UnsafeRawBufferPointer) {
        let header = codec.nalHeaderLength
        guard nalUnit.count > header, header > 0 else { return }
        let typeCode: UInt8 = codec == .h264 ? (nalUnit[0] & 0x1F) : ((nalUnit[0] >> 1) & 0x3F)
        observe(typeCode: typeCode,
                isFirstSlice: SliceHeader.isFirstSliceOfPicture(nalUnit: nalUnit, codec: codec))
    }

    // MARK: - Computed Properties

    /// What `EncodedFrame.isKeyframe` means (§20.5): an IDR for H.264, any IRAP for H.265.
    ///
    /// An H.264 I-slice of type 1 is deliberately **not** a keyframe. Without an IDR the decoded
    /// picture buffer is not reset and a decoder cannot start there, and `AVAssetWriter` would
    /// write an unseekable recording if we claimed otherwise.
    @inlinable public var isKeyframe: Bool {
        codec == .h264 ? containsIDR : containsIRAP
    }
}

// MARK: - IRAPGate

/// Decides whether an access unit may be handed to a decoder.
///
/// **Starts closed**, on every PLAY, every reconnect and every decoder reset. A Hikvision camera
/// starts sending at the next packet after PLAY, which is almost never an IRAP boundary; with the
/// default I-frame interval of 50 at 25 fps the expected wait is about a second. Handing a decoder
/// those first pictures produces the green-and-smeared frames users report as "the camera is
/// broken", so we drop them and `VigilUI` shows the connecting state — never black.
///
/// A value type with no clock of its own: `evaluate(_:at:)` takes the instant so the whole thing
/// is deterministic and reproducible from a test fixture.
public struct IRAPGate: Sendable {

    // MARK: - Nested Types

    /// What to do with an access unit.
    public enum Decision: Sendable, Equatable {
        case pass
        case drop(DropReason)
    }

    /// Why an access unit was dropped. The raw values are stable and appear in log lines.
    public enum DropReason: String, Sendable, Equatable {

        /// The stream started mid-GOP and no recovery point has arrived yet. The common case.
        case awaitingIRAP

        /// An IRAP arrived before any parameter set did. Rare, and self-correcting.
        case missingParameterSets

        /// H.265 RASL pictures associated with a CRA or BLA we started at. They reference frames
        /// before that CRA, which the decoder never saw (§20.3).
        case raslAfterCRAStart

        /// A `recovery_point` with `broken_link_flag == 1`: the stream was spliced.
        case brokenLink

        /// The access unit contained no VCL NAL at all. Parameter sets and SEI in it have already
        /// been ingested by the store by the time the gate sees it.
        case nonVCLOnly
    }

    /// How eager the gate is to open.
    public struct Policy: Sendable, Hashable {

        /// Accept a non-IRAP access unit carrying a `recovery_point` SEI.
        public var acceptRecoveryPointSEI: Bool

        /// Accept a `recovery_point` even when `exact_match_flag == 0`, i.e. when the recovered
        /// picture may differ slightly from a clean decode.
        public var acceptInexactRecoveryPoint: Bool

        /// After this long with no IRAP, open on any access unit and accept the artefacts, so the
        /// user sees *something* rather than a permanently connecting tile on broken firmware.
        /// Only takes effect when the caller supplies an instant to `evaluate(_:at:)`.
        public var desperationTimeout: Duration?

        /// How many access units may be dropped before `shouldRequestKeyframe` is raised. Twenty
        /// five is about one second at 25 fps — long enough not to fire on a normal mid-GOP start
        /// that is about to resolve itself, short enough to save most of a GOP.
        public var keyframeRequestAfterDrops: Int

        /// Builds a policy.
        public init(acceptRecoveryPointSEI: Bool = true, acceptInexactRecoveryPoint: Bool = false,
                    desperationTimeout: Duration? = .seconds(12),
                    keyframeRequestAfterDrops: Int = 25) {
            self.acceptRecoveryPointSEI = acceptRecoveryPointSEI
            self.acceptInexactRecoveryPoint = acceptInexactRecoveryPoint
            self.desperationTimeout = desperationTimeout
            self.keyframeRequestAfterDrops = keyframeRequestAfterDrops
        }

        /// The live-streaming default.
        public static let strict = Policy()

        /// Recorded playback: no SEI shortcut and no desperation opening, because a seek always
        /// lands on an IRAP and accepting anything else would show corruption the user did not
        /// ask for.
        public static let recordedPlayback = Policy(acceptRecoveryPointSEI: false,
                                                    acceptInexactRecoveryPoint: false,
                                                    desperationTimeout: nil)
    }

    // MARK: - Stored Properties

    /// The codec, which decides whether the RASL rule applies at all.
    public let codec: VideoCodec

    /// How eager this gate is to open.
    public let policy: Policy

    /// True once an access unit has been passed to the decoder. Starts false and returns to false
    /// on `reset()`.
    public private(set) var isOpen: Bool

    /// True while the gate is closed and has been closed for longer than the policy tolerates.
    /// `VigilCore` polls this and issues a keyframe request; it clears the moment the gate opens.
    public private(set) var shouldRequestKeyframe: Bool

    /// How many access units have been dropped since the last `reset()`. `VigilUI` shows the
    /// connecting state while this is climbing and the gate is closed.
    public private(set) var droppedAccessUnits: Int

    /// `NoRaslOutputFlag` for the current CVS: set when decoding began at a CRA or BLA, cleared by
    /// the first access unit that carries no RASL NAL, and by `reset()`.
    private var noRaslOutput: Bool

    /// The instant of the first access unit seen, for the desperation timeout. `nil` until an
    /// access unit is evaluated with a time.
    private var firstAccessUnit: MediaInstant?

    // MARK: - Initialisation

    /// Builds a closed gate.
    public init(codec: VideoCodec, policy: Policy = .strict) {
        self.codec = codec
        self.policy = policy
        self.isOpen = false
        self.shouldRequestKeyframe = false
        self.droppedAccessUnits = 0
        self.noRaslOutput = false
        self.firstAccessUnit = nil
    }

    // MARK: - Public API

    /// Closes the gate and forgets everything. Call after any decoder reset, seek, reconnect or
    /// `kVTInvalidSessionErr`, and on every PLAY.
    public mutating func reset() {
        isOpen = false
        shouldRequestKeyframe = false
        droppedAccessUnits = 0
        noRaslOutput = false
        firstAccessUnit = nil
    }

    /// Time-free form of `evaluate(_:at:)`: `true` when the access unit may be decoded.
    ///
    /// The desperation timeout cannot fire without a clock, so a caller that wants it must use
    /// `evaluate(_:at:)`. Everything else — the IRAP rule, the recovery-point rule, the RASL rule
    /// and `shouldRequestKeyframe` — behaves identically.
    @discardableResult
    public mutating func admit(_ summary: AccessUnitSummary) -> Bool {
        evaluate(summary, at: nil) == .pass
    }

    /// Decides what to do with one complete access unit, and updates the gate's state.
    ///
    /// The order of the rules is load-bearing:
    ///
    /// 1. An access unit with no VCL NAL has nothing to decode.
    /// 2. While closed, parameter sets must be available before anything is admitted, because a
    ///    decoder handed a picture with no format description fails the whole session.
    /// 3. An IRAP opens the gate — unless it carries a broken link, where the pictures that follow
    ///    reference frames that do not exist.
    /// 4. Otherwise a `recovery_point` may open it, subject to policy.
    /// 5. Otherwise the desperation timeout may open it, if the caller supplied a time.
    /// 6. Once open, RASL pictures after a CRA/BLA start are dropped until the first access unit
    ///    with no RASL NAL clears the flag.
    ///
    /// - Parameter now: a monotonic instant, or `nil` to disable the desperation timeout.
    @discardableResult
    public mutating func evaluate(_ au: AccessUnitSummary, at now: MediaInstant?) -> Decision {
        if let now, firstAccessUnit == nil { firstAccessUnit = now }

        guard au.containsVCL else { return drop(.nonVCLOnly) }

        if !isOpen {
            guard au.parameterSetsAvailable else { return drop(.missingParameterSets) }

            if au.containsIRAP {
                if let recovery = au.recoveryPoint, recovery.brokenLink { return drop(.brokenLink) }
                open()
                // Decoding starts here, so RASL pictures associated with this CRA or BLA reference
                // frames that were never decoded. IDR does not set the flag: it has no such RASLs.
                if codec == .h265, au.containsCRAOrBLA { noRaslOutput = true }
                return .pass
            }

            if policy.acceptRecoveryPointSEI, let recovery = au.recoveryPoint, !recovery.brokenLink,
               recovery.exactMatch || policy.acceptInexactRecoveryPoint {
                open()
                return .pass
            }

            if let timeout = policy.desperationTimeout, let now, let first = firstAccessUnit,
               now - first > timeout {
                // Deliberate: a visibly imperfect picture beats a permanently blank tile on
                // firmware that never emits an IRAP. `VigilCore` logs a warning when this happens.
                open()
                return .pass
            }

            return drop(.awaitingIRAP)
        }

        if noRaslOutput, au.containsRASL { return drop(.raslAfterCRAStart) }
        if !au.containsRASL { noRaslOutput = false }
        return .pass
    }

    // MARK: - Private

    private mutating func open() {
        isOpen = true
        shouldRequestKeyframe = false
    }

    private mutating func drop(_ reason: DropReason) -> Decision {
        droppedAccessUnits += 1
        if !isOpen, droppedAccessUnits >= policy.keyframeRequestAfterDrops {
            shouldRequestKeyframe = true
        }
        return .drop(reason)
    }
}
