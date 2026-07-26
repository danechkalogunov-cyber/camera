//
//  Depacketizer.swift
//  VigilRTP
//
//  The depacketizer contract: the protocol every payload format conforms to, the output and event
//  vocabulary it reports through, the tuning knobs, and the `AnyDepacketizer` enum used on the hot
//  path so a per-packet call never boxes an existential.
//  See docs/spec-rtp.md §4.2, §4.3, §14.1, §14.4 and docs/API_CONTRACT.md §4.4.
//

import Foundation

import VigilProtocols

// MARK: - Depacketizer

/// Turns RTP payloads of one track back into complete access units.
///
/// Conformers are **structs**, so `mutating` and `Sendable` compose under Swift 6 strict
/// concurrency and an owning actor can hold one without `nonisolated(unsafe)`.
///
/// Nothing here throws. A depacketizer that gave up on malformed input would let one corrupt packet
/// tear down a stream, so every failure is counted and reported through `DepacketizerOutput.events`
/// instead.
public protocol Depacketizer: Sendable {

    /// The codec of the frames this depacketizer emits. For G.711 and G.726 this is
    /// `.audio(.pcmS16LE)`, not the wire codec, because those are decoded in the pure layer.
    var codec: MediaCodec { get }

    /// RTP clock rate in ticks per second, as advertised by `a=rtpmap`. Every `MediaTimestamp`
    /// this depacketizer produces uses it as the timescale.
    var clockRate: Int32 { get }

    /// Consume one in-order RTP packet that has already passed payload-type binding.
    ///
    /// - Parameters:
    ///   - packet: the packet, with `payload` still a slice of the receive buffer.
    ///   - now: arrival instant of this packet, injected so the pure layer never reads a clock.
    /// - Returns: any access units completed by this packet plus the events it produced. Returns
    ///   `.none` for the great majority of packets, which are mid-frame fragments.
    mutating func push(_ packet: RTPPacket, at now: MediaInstant) -> DepacketizerOutput

    /// Emit any complete pending access unit. Called on PAUSE, TEARDOWN and the AU timeout.
    /// A pending access unit with an unfinished fragment is discarded, never truncated.
    mutating func flush(at now: MediaInstant) -> [EncodedFrame]

    /// Full state reset for an SSRC change, a seek or a reconnect. Parameter sets learned from the
    /// SDP survive; parameter sets learned in-band do not.
    mutating func reset()
}

// MARK: - DepacketizerOutput

/// What one `push` produced. Both arrays are usually empty.
public struct DepacketizerOutput: Sendable {

    /// Access units completed by this packet, in presentation order.
    public var frames: [EncodedFrame]

    /// Diagnostics, loss reports and policy changes produced by this packet.
    public var events: [DepacketizerEvent]

    /// Creates an output. Both arguments default to empty so `.none` costs nothing.
    public init(frames: [EncodedFrame] = [], events: [DepacketizerEvent] = []) {
        self.frames = frames
        self.events = events
    }

    /// True when the packet produced neither a frame nor an event.
    @inlinable public var isEmpty: Bool { frames.isEmpty && events.isEmpty }

    /// The shared empty output. A `static let`, so the ~97 % of packets that are mid-frame
    /// fragments allocate nothing at all (docs/spec-rtp.md §16).
    public static let none = DepacketizerOutput()
}

// MARK: - DepacketizerConfiguration

/// Tuning knobs shared by every video depacketizer. Every limit exists to bound work on hostile
/// input; none of them is a quality setting.
public struct DepacketizerConfiguration: Sendable, Hashable {

    // MARK: - Nested Types

    /// How much the RTP marker bit is allowed to influence access-unit boundaries.
    ///
    /// `.adaptive` is the only value used in production: the marker starts untrusted and is
    /// promoted only after it has been observed to agree with the slice header for long enough
    /// (docs/spec-rtp.md §7.4). `.always` exists for bench comparisons and `.never` pins the
    /// conservative path.
    public enum MarkerBitTrust: Sendable, Hashable {
        case never, adaptive, always
    }

    // MARK: - Stored Properties

    /// Reject a reassembled NAL unit larger than this many bytes.
    public var maxNALBytes: Int

    /// Reject an access unit larger than this many bytes.
    public var maxAccessUnitBytes: Int

    /// Cap on the number of fragments one NAL may be split into.
    public var maxFragmentsPerNAL: Int

    /// Cap on the number of NAL units one aggregation packet may carry.
    public var maxAggregatedNALs: Int

    /// Force-close an access unit that has been open, idle, for longer than this.
    public var accessUnitTimeout: Duration

    /// Drop access units until the first IRAP arrives.
    public var waitForKeyframeOnStart: Bool

    /// Re-arm the keyframe gate after a gap or a corrupt access unit.
    public var waitForKeyframeAfterLoss: Bool

    /// Emit damaged access units with `EncodedFrame.isCorrupt` set instead of dropping them.
    public var emitCorruptFrames: Bool

    /// Marker-bit policy. See `MarkerBitTrust`.
    public var trustMarkerBit: MarkerBitTrust

    /// H.265 only: drop RASL pictures that follow a CRA we started on.
    public var dropRASLAfterCRA: Bool

    /// H.264 only: treat a recovery-point SEI plus an I-slice as a keyframe.
    public var treatRecoveryPointAsKeyframe: Bool

    // MARK: - Initialisation

    /// Creates a configuration. Defaults match `.liveDefault`.
    public init(maxNALBytes: Int = 8 << 20,
                maxAccessUnitBytes: Int = 16 << 20,
                maxFragmentsPerNAL: Int = 4096,
                maxAggregatedNALs: Int = 64,
                accessUnitTimeout: Duration = .milliseconds(200),
                waitForKeyframeOnStart: Bool = true,
                waitForKeyframeAfterLoss: Bool = true,
                emitCorruptFrames: Bool = false,
                trustMarkerBit: MarkerBitTrust = .adaptive,
                dropRASLAfterCRA: Bool = true,
                treatRecoveryPointAsKeyframe: Bool = true) {
        self.maxNALBytes = maxNALBytes
        self.maxAccessUnitBytes = maxAccessUnitBytes
        self.maxFragmentsPerNAL = maxFragmentsPerNAL
        self.maxAggregatedNALs = maxAggregatedNALs
        self.accessUnitTimeout = accessUnitTimeout
        self.waitForKeyframeOnStart = waitForKeyframeOnStart
        self.waitForKeyframeAfterLoss = waitForKeyframeAfterLoss
        self.emitCorruptFrames = emitCorruptFrames
        self.trustMarkerBit = trustMarkerBit
        self.dropRASLAfterCRA = dropRASLAfterCRA
        self.treatRecoveryPointAsKeyframe = treatRecoveryPointAsKeyframe
    }

    // MARK: - Public API

    /// Live viewing: a 200 ms access-unit timeout and a keyframe gate that re-arms after loss.
    public static let liveDefault = DepacketizerConfiguration()

    /// Recorded playback: a longer timeout, and loss does not re-arm the keyframe gate because a
    /// seek already positioned us on one.
    public static let playbackDefault = DepacketizerConfiguration(
        accessUnitTimeout: .milliseconds(1000),
        waitForKeyframeAfterLoss: false
    )
}

// MARK: - DepacketizerEvent

/// Everything a depacketizer reports that is not a frame. Cases carry enums, never strings, so the
/// per-packet path never formats text (docs/spec-rtp.md §16).
public enum DepacketizerEvent: Sendable, Equatable {

    /// Sequence numbers `range` never arrived. `count` is the number of missing packets.
    case packetLoss(range: ClosedRange<UInt16>, count: Int)

    /// The decoder cannot make progress until an IRAP arrives; ask the camera for one.
    case keyframeNeeded(reason: KeyframeReason)

    /// The keyframe gate is closed and has dropped this many access units so far.
    case awaitingKeyframe(droppedAccessUnits: Int)

    /// A complete access unit was assembled but deliberately not emitted.
    case accessUnitDropped(reason: DropReason)

    /// Codec configuration changed, or arrived for the first time.
    case parameterSetsChanged(ParameterSets)

    /// Audio configuration changed, or arrived for the first time.
    case audioConfigChanged(AudioFormatInfo)

    /// The synchronisation source changed; every stateful component was reset.
    case ssrcChanged(old: UInt32, new: UInt32)

    /// The RTP timestamp jumped by more than a plausible frame interval.
    case timestampDiscontinuity(seconds: Double)

    /// An RTCP sender report was parsed. Emitted by the receiver, carried here so one event stream
    /// covers the whole track.
    case senderReport(SenderReport)

    /// RTCP BYE, with the optional reason string the sender supplied.
    case bye(reason: String?)

    /// End of sequence or end of stream NAL seen in the bitstream.
    case endOfStream

    /// The learned access-unit boundary policy changed. Purely diagnostic, but it is the answer to
    /// "why is this camera laggy" (docs/spec-rtp.md §7.4).
    case boundaryPolicyChanged(slice: SliceProfile, marker: MarkerTrust)

    /// The reorder buffer escalated its depth in response to loss.
    case jitterPolicyEscalated(ReorderBuffer.Mode)

    /// A packet did not conform to its payload format. Rate limited; counters keep incrementing.
    case malformed(MalformedReason)

    /// A payload format feature Vigil deliberately does not implement. Rate limited.
    case unsupported(UnsupportedFeature)
}

/// Why a keyframe is being requested.
public enum KeyframeReason: String, Sendable, Equatable, Codable {
    case streamStart, packetLoss, corruptAccessUnit, decoderReset, formatChange
    case recordingStart, snapshotRequest, qualitySwitch, userRequest
}

/// Why a fully assembled access unit was not emitted.
public enum DropReason: Sendable, Equatable {
    /// The keyframe gate is still closed.
    case awaitingKeyframe
    /// A fragmented NAL never completed.
    case incompleteFragment
    /// At least one NAL was lost or truncated and `emitCorruptFrames` is off.
    case corrupt
    /// `maxAccessUnitBytes` was exceeded.
    case tooLarge
    /// An H.265 RASL picture that follows the CRA the stream started on.
    case raslAfterCRA
    /// The access unit was closed early by a marker bit that turned out to be wrong.
    case prematureClose
    /// The access unit sat open longer than `accessUnitTimeout`.
    case timeout
    /// An H.265 NAL with `nuh_layer_id != 0`.
    case nonBaseLayer
}

/// The ways a payload can fail to conform to its RFC.
public enum MalformedReason: Sendable, Equatable {
    case emptyPayload
    case truncatedAggregate
    case zeroLengthAggregate
    case truncatedFragment
    case lostFirstFragment
    case lostLastFragment
    case fragmentGap
    case fragmentTimestampChange
    case forbiddenBitSet
    case nestedPacketization
    case auSizeMismatch
    case truncatedAudioAU
    case rtcpMisaligned
    case malformedExtension
    case unexpectedPayloadType
    /// A fragmented NAL was still open when its access unit closed.
    case incompleteFragmentAtAUEnd
    /// A reassembled NAL exceeded `maxNALBytes`, or its fragment count exceeded the cap.
    case nalTooLarge
    /// A suffix NAL arrived for an access unit that had already been emitted.
    case suffixNALAfterClose
    /// A slice arrived for an access unit that had already been emitted: the close was wrong.
    case prematureAccessUnitClose
}

/// Payload-format features Vigil does not implement. Each is dropped and counted, never guessed at.
public enum UnsupportedFeature: Sendable, Equatable {
    /// H.264 MTAP16 (26) or MTAP24 (27).
    case aggregationType(UInt8)
    /// H.265 PACI (50), or a reserved packet type.
    case packetizationType(UInt8)
    /// `packetization-mode=2`, or a STAP-B / FU-B packet.
    case interleavedMode
    /// An H.265 NAL with a non-zero `nuh_layer_id`.
    case nonBaseLayer(UInt16)
    case redundantEncoding
    case forwardErrorCorrection
}

// MARK: - AnyDepacketizer

/// The enum the per-packet path dispatches through.
///
/// An existential would box on every call and defeat the `mutating` requirement; the
/// `case .h264(var d)` / reassign pattern below keeps a single reference to the payload so it moves
/// rather than copies, and no copy-on-write allocation occurs (docs/spec-rtp.md §4.2).
public enum AnyDepacketizer: Sendable {
    case h264(H264Depacketizer)
    case h265(H265Depacketizer)
    case aac(AACDepacketizer)
    case pcm(PCMDepacketizer)

    /// The codec of the frames this depacketizer emits.
    public var codec: MediaCodec {
        switch self {
        case .h264(let d): d.codec
        case .h265(let d): d.codec
        case .aac(let d): d.codec
        case .pcm(let d): d.codec
        }
    }

    /// RTP clock rate in ticks per second.
    public var clockRate: Int32 {
        switch self {
        case .h264(let d): d.clockRate
        case .h265(let d): d.clockRate
        case .aac(let d): d.clockRate
        case .pcm(let d): d.clockRate
        }
    }

    /// Consume one packet. See `Depacketizer.push(_:at:)`.
    public mutating func push(_ packet: RTPPacket, at now: MediaInstant) -> DepacketizerOutput {
        switch self {
        case .h264(var d): let o = d.push(packet, at: now); self = .h264(d); return o
        case .h265(var d): let o = d.push(packet, at: now); self = .h265(d); return o
        case .aac(var d): let o = d.push(packet, at: now); self = .aac(d); return o
        case .pcm(var d): let o = d.push(packet, at: now); self = .pcm(d); return o
        }
    }

    /// Emit any complete pending access unit. See `Depacketizer.flush(at:)`.
    public mutating func flush(at now: MediaInstant) -> [EncodedFrame] {
        switch self {
        case .h264(var d): let f = d.flush(at: now); self = .h264(d); return f
        case .h265(var d): let f = d.flush(at: now); self = .h265(d); return f
        case .aac(var d): let f = d.flush(at: now); self = .aac(d); return f
        case .pcm(var d): let f = d.flush(at: now); self = .pcm(d); return f
        }
    }

    /// Full state reset. See `Depacketizer.reset()`.
    public mutating func reset() {
        switch self {
        case .h264(var d): d.reset(); self = .h264(d)
        case .h265(var d): d.reset(); self = .h265(d)
        case .aac(var d): d.reset(); self = .aac(d)
        case .pcm(var d): d.reset(); self = .pcm(d)
        }
    }
}

// MARK: - EventRateLimiter

/// Suppresses repeats of `malformed` and `unsupported` events.
///
/// A stream that is broken at the packet level produces thousands of identical events per second,
/// and the logging subsystem then becomes the bottleneck. Each distinct reason is admitted at most
/// once per `interval`; the caller's counters keep incrementing regardless
/// (docs/spec-rtp.md §14.4).
///
/// Keyed by a small integer discriminant rather than the payload, so `.aggregationType(26)` and
/// `.aggregationType(27)` share one budget — the point is to bound the rate, not to enumerate.
struct EventRateLimiter: Sendable {

    /// Minimum spacing between two admissions of the same key.
    private let interval: Duration

    /// Last admission instant per key. Bounded by the number of enum cases, so no eviction is
    /// needed and no unbounded growth is possible.
    private var lastEmitted: [UInt8: MediaInstant] = [:]

    /// Creates a limiter. The default matches docs/spec-rtp.md §14.4.
    init(interval: Duration = .seconds(5)) {
        self.interval = interval
    }

    /// Returns true when an event with this key may be emitted now, and records the admission.
    mutating func admit(_ key: UInt8, at now: MediaInstant) -> Bool {
        if let last = lastEmitted[key], now < last + interval { return false }
        lastEmitted[key] = now
        return true
    }

    /// Forgets every admission, so the next event of each kind is emitted immediately.
    mutating func reset() {
        lastEmitted.removeAll(keepingCapacity: true)
    }
}

extension MalformedReason {

    /// Rate-limiter key. Distinct per case; associated values are deliberately ignored.
    var limiterKey: UInt8 {
        switch self {
        case .emptyPayload: 0
        case .truncatedAggregate: 1
        case .zeroLengthAggregate: 2
        case .truncatedFragment: 3
        case .lostFirstFragment: 4
        case .lostLastFragment: 5
        case .fragmentGap: 6
        case .fragmentTimestampChange: 7
        case .forbiddenBitSet: 8
        case .nestedPacketization: 9
        case .auSizeMismatch: 10
        case .truncatedAudioAU: 11
        case .rtcpMisaligned: 12
        case .malformedExtension: 13
        case .unexpectedPayloadType: 14
        case .incompleteFragmentAtAUEnd: 15
        case .nalTooLarge: 16
        case .suffixNALAfterClose: 17
        case .prematureAccessUnitClose: 18
        }
    }
}

extension UnsupportedFeature {

    /// Rate-limiter key, offset past `MalformedReason`'s range so the two share one dictionary.
    var limiterKey: UInt8 {
        switch self {
        case .aggregationType: 32
        case .packetizationType: 33
        case .interleavedMode: 34
        case .nonBaseLayer: 35
        case .redundantEncoding: 36
        case .forwardErrorCorrection: 37
        }
    }
}
