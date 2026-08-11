//
//  RTSPAction.swift
//  VigilRTSP
//
//  The outputs of the session machine — every I/O intent it can express — plus the value types
//  those actions carry: the negotiated track, its presentation-time seed, the session description
//  and the structured log events.
//  Implements docs/spec-rtsp.md §8.10, §9.2, §14.3, §14.8 and docs/API_CONTRACT.md §4.3.
//

import Foundation
import VigilProtocols

// MARK: - RTSPTrack

/// One negotiated media track, as it crosses into `VigilRTP` and `VigilVideo`.
///
/// Contains no CoreMedia types and no timestamps: this is a description of *what* will arrive, not
/// of *when*. Timing arrives separately, as `RTSPTrackTiming`, after `PLAY`.
public struct RTSPTrack: Sendable, Hashable, Identifiable {

    /// The SDP media index, from zero. Stable for the life of the session.
    public var id: Int

    /// Video, audio or application.
    public var kind: SDPMediaDescription.Kind

    /// The codec Vigil will decode, or `nil` when the encoding is one we cannot handle. A `nil`
    /// video codec makes the track unusable; a `nil` audio codec merely makes it silent.
    public var codec: MediaCodec?

    /// The SDP encoding name verbatim, so a log can say `MP4V-ES` rather than "unsupported".
    public var encodingName: String

    /// The RTP payload type this track's packets carry.
    public var payloadType: UInt8

    /// RTP clock rate in Hz — 90 000 for video, the sample rate for audio.
    public var clockRate: UInt32

    /// Audio channel count; `nil` for video.
    public var channelCount: Int?

    /// The fully resolved absolute URI used for this track's `SETUP`.
    public var controlURI: String

    /// Parameter sets from `sprop-*`. **May legitimately be empty**: Hikvision repeats SPS/PPS in
    /// band before every IDR, so `VigilBitstream` must be able to start without these.
    public var parameterSets: ParameterSets?

    /// Every `a=fmtp` parameter, lower-cased keys, verbatim values.
    public var fmtpParameters: [String: String]

    /// H.264 `packetization-mode`. Mode 2 is refused; mode 1 is what Hikvision sends.
    public var packetizationMode: Int?

    /// H.265 `sprop-max-don-diff`; non-zero means the depacketizer must read DONL fields.
    public var spropMaxDONDiff: Int

    /// AAC `AudioSpecificConfig`, decoded from the hex `config=` parameter.
    public var aacConfig: [UInt8]?

    /// AAC AU-header field widths, defaulting to RFC 3640's 13/3/3 when the SDP omits them.
    public var aacSizeLength: Int?

    /// See `aacSizeLength`.
    public var aacIndexLength: Int?

    /// See `aacSizeLength`.
    public var aacIndexDeltaLength: Int?

    /// `a=x-dimensions` hint, letting the UI size a view before the SPS arrives. Never
    /// authoritative — the bitstream is.
    public var hintedDimensions: Resolution?

    /// `a=framerate` / `a=x-framerate` hint.
    public var hintedFramerate: Double?

    /// `b=AS:` for this track.
    public var bandwidthKbps: Int?

    /// The interleaved channel pair the server assigned: RTP even, RTCP odd. Filled in from the
    /// `SETUP` response, or from what we requested when the response omits it.
    public var interleavedChannels: ClosedRange<UInt8>?

    /// Local UDP ports reserved for this track (RTP first, RTCP second).
    public var clientPorts: RTSPUDPPortPair?

    /// Peer UDP ports returned by the server in `server_port`, when present.
    public var serverPorts: RTSPUDPPortPair?

    /// The synchronisation source the server announced, when it announced one.
    public var ssrc: UInt32?

    /// Multicast group, port pair and hop limit selected by the server.
    public var multicastEndpoint: RTSPMulticastEndpoint?

    /// Builds a track. Everything but the identity and control URI is defaulted, because the SDP
    /// legitimately omits most of it.
    public init(id: Int,
                kind: SDPMediaDescription.Kind,
                codec: MediaCodec?,
                encodingName: String,
                payloadType: UInt8,
                clockRate: UInt32,
                channelCount: Int? = nil,
                controlURI: String,
                parameterSets: ParameterSets? = nil,
                fmtpParameters: [String: String] = [:],
                packetizationMode: Int? = nil,
                spropMaxDONDiff: Int = 0,
                aacConfig: [UInt8]? = nil,
                aacSizeLength: Int? = nil,
                aacIndexLength: Int? = nil,
                aacIndexDeltaLength: Int? = nil,
                hintedDimensions: Resolution? = nil,
                hintedFramerate: Double? = nil,
                bandwidthKbps: Int? = nil,
                interleavedChannels: ClosedRange<UInt8>? = nil,
                clientPorts: RTSPUDPPortPair? = nil,
                serverPorts: RTSPUDPPortPair? = nil,
                ssrc: UInt32? = nil,
                multicastEndpoint: RTSPMulticastEndpoint? = nil) {
        self.id = id
        self.kind = kind
        self.codec = codec
        self.encodingName = encodingName
        self.payloadType = payloadType
        self.clockRate = clockRate
        self.channelCount = channelCount
        self.controlURI = controlURI
        self.parameterSets = parameterSets
        self.fmtpParameters = fmtpParameters
        self.packetizationMode = packetizationMode
        self.spropMaxDONDiff = spropMaxDONDiff
        self.aacConfig = aacConfig
        self.aacSizeLength = aacSizeLength
        self.aacIndexLength = aacIndexLength
        self.aacIndexDeltaLength = aacIndexDeltaLength
        self.hintedDimensions = hintedDimensions
        self.hintedFramerate = hintedFramerate
        self.bandwidthKbps = bandwidthKbps
        self.interleavedChannels = interleavedChannels
        self.clientPorts = clientPorts
        self.serverPorts = serverPorts
        self.ssrc = ssrc
        self.multicastEndpoint = multicastEndpoint
    }
}

/// Consecutive RTP/RTCP UDP ports. RTP is always even as recommended by RFC 3550.
public struct RTSPUDPPortPair: Sendable, Hashable {
    public var rtp: UInt16
    public var rtcp: UInt16

    public init?(rtp: UInt16, rtcp: UInt16) {
        guard rtp.isMultiple(of: 2), rtcp == rtp &+ 1 else { return nil }
        self.rtp = rtp
        self.rtcp = rtcp
    }
}

/// The destination negotiated by `RTP/AVP;multicast`.
public struct RTSPMulticastEndpoint: Sendable, Hashable {
    public var destination: String
    public var ports: RTSPUDPPortPair
    public var timeToLive: UInt8

    public init?(destination: String, ports: RTSPUDPPortPair, timeToLive: UInt8) {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, timeToLive > 0 else { return nil }
        self.destination = trimmed
        self.ports = ports
        self.timeToLive = timeToLive
    }
}

// MARK: - RTSPTrackTiming

/// The presentation-time **seed** for one track: raw values from `RTP-Info`, nothing computed.
///
/// `VigilRTSP` performs no modular arithmetic on RTP timestamps and never compares `rtptime`
/// across tracks — two tracks carry unrelated random offsets, and pairing them is a class of bug
/// that produces audio drift nobody can explain. All of that belongs to `VigilRTP`
/// (API_CONTRACT §2 R-26).
public struct RTSPTrackTiming: Sendable, Hashable {

    /// The `RTSPTrack.id` this seed belongs to.
    public var trackID: Int

    /// The track's RTP clock rate in Hz, repeated here so the consumer needs no lookup.
    public var clockRate: UInt32

    /// `RTP-Info` `seq`, or `nil` when the header was absent — which is legal and common on
    /// Hikvision live streams. The consumer then takes the first packet it receives as the origin.
    public var initialSequence: UInt16?

    /// `RTP-Info` `rtptime`, raw and un-unwrapped, or `nil` when absent.
    public var initialRTPTimestamp: UInt32?

    /// Wall-clock time of `initialRTPTimestamp`, for **recorded playback only**; `nil` for live.
    public var absoluteStart: Date?

    /// The `Scale` in force, 1.0 for live.
    public var scale: Double

    /// True when `Rate-Control: no` was negotiated, so the peer will push as fast as TCP allows
    /// and the consumer must pace by RTP timestamps rather than by arrival time.
    public var isRateControlDisabled: Bool

    /// The monotonic instant at which the `PLAY` response was processed: the anchor for the
    /// glass-to-glass latency measurement.
    public var playResponseInstant: MediaInstant

    /// Builds a seed. Absent `RTP-Info` fields stay `nil` rather than defaulting to zero, because
    /// "no seed" and "a seed of zero" mean different things to the presentation clock.
    public init(trackID: Int,
                clockRate: UInt32,
                initialSequence: UInt16? = nil,
                initialRTPTimestamp: UInt32? = nil,
                absoluteStart: Date? = nil,
                scale: Double = 1.0,
                isRateControlDisabled: Bool = false,
                playResponseInstant: MediaInstant) {
        self.trackID = trackID
        self.clockRate = clockRate
        self.initialSequence = initialSequence
        self.initialRTPTimestamp = initialRTPTimestamp
        self.absoluteStart = absoluteStart
        self.scale = scale
        self.isRateControlDisabled = isRateControlDisabled
        self.playResponseInstant = playResponseInstant
    }
}

// MARK: - RTSPSessionDescription

/// What a successful `PLAY` produced, delivered once with `.ready`.
public struct RTSPSessionDescription: Sendable, Hashable {

    /// Every negotiated track, in SDP order.
    public var tracks: [RTSPTrack]

    /// The opaque `Session` id. Never parsed as a number: cameras send large decimals, NVRs short
    /// ones, and one build sends hex.
    public var sessionID: String

    /// The session timeout in force, already clamped to 10…600 s.
    public var sessionTimeout: Duration

    /// The transport actually negotiated.
    public var transport: RTSPTransportKind

    /// The `Range` the peer echoed on the `PLAY` response, **verbatim** (e.g. `npt=0.000-`).
    /// Kept as text so the session layer has no dependency on the range parser; `VigilCore`
    /// interprets it when it needs a playback position.
    public var rangeText: String?

    /// The `Scale` in force.
    public var scale: Double

    /// Whether `Rate-Control: no` was negotiated.
    public var isRateControlDisabled: Bool

    /// The methods the peer advertised in `Public`, empty when it never answered `OPTIONS`.
    public var serverPublicMethods: Set<RTSPMethod>

    /// The parsed SDP, for diagnostics and for anything that needs an attribute we did not model.
    public var sdp: SDPDocument

    /// Builds a description. Every field is filled by the machine at `PLAY` time.
    public init(tracks: [RTSPTrack],
                sessionID: String,
                sessionTimeout: Duration,
                transport: RTSPTransportKind,
                rangeText: String? = nil,
                scale: Double = 1.0,
                isRateControlDisabled: Bool = false,
                serverPublicMethods: Set<RTSPMethod> = [],
                sdp: SDPDocument) {
        self.tracks = tracks
        self.sessionID = sessionID
        self.sessionTimeout = sessionTimeout
        self.transport = transport
        self.rangeText = rangeText
        self.scale = scale
        self.isRateControlDisabled = isRateControlDisabled
        self.serverPublicMethods = serverPublicMethods
        self.sdp = sdp
    }
}

// MARK: - RTSPSessionStatistics

/// Counters for the diagnostics pane and for the bug reports that arrive without them.
///
/// `Equatable` rather than `Hashable`, because the decoder's counters are: nothing hashes a
/// statistics snapshot, and tests only ever compare them.
public struct RTSPSessionStatistics: Sendable, Equatable {

    /// Requests written, including retries after `401`.
    public var requestsSent = 0

    /// Responses matched to a request.
    public var responsesReceived = 0

    /// `401`s received.
    public var authChallenges = 0

    /// Requests re-sent carrying an `Authorization` header.
    public var authRetries = 0

    /// Redirects followed.
    public var redirectsFollowed = 0

    /// Keepalives written.
    public var keepalivesSent = 0

    /// Interleaved frames forwarded to the media pipeline.
    public var interleavedFrames = 0

    /// Interleaved payload bytes forwarded.
    public var interleavedBytes: UInt64 = 0

    /// Payload bytes per interleaved channel.
    public var mediaBytesByChannel: [UInt8: UInt64] = [:]

    /// Framing resynchronisations observed.
    public var framingResyncs = 0

    /// Round-trip time of the most recent request, in milliseconds.
    public var lastRoundTripMilliseconds: Int64?

    /// Server-initiated requests answered.
    public var serverRequestsReceived = 0

    /// Media frames dropped because they arrived before `PLAY` completed and the buffer was full.
    public var preplayFramesDropped = 0

    /// The framing decoder's own counters.
    public var decoder = DecoderStatistics()

    /// Builds an all-zero counter set.
    public init() {}
}

// MARK: - RTSPLogEvent

/// Structured log records. The pure layer never imports a logging framework; the driver maps these
/// onto `LoggerProtocol` categories.
public enum RTSPLogEvent: Sendable, Hashable {
    /// A complete redacted request or response for the bounded diagnostics transcript.
    case transcript(String)
    /// A request went out. `uri` is already in credential-free form.
    case requestSent(method: RTSPMethod, cseq: UInt32, uri: String)
    /// A response came back, with its round-trip time when the request was ours.
    case responseReceived(status: Int, cseq: UInt32?, rttMilliseconds: Int64?)
    /// A `401` carrying a challenge we can answer.
    case authChallenged(realm: String, qop: String?, stale: Bool)
    /// A request is being re-sent with credentials. `attempt` counts credentialed tries.
    case authRetried(attempt: Int)
    /// The SDP parsed, with the codecs it offered.
    case sdpParsed(trackCount: Int, codecs: [String])
    /// One `a=control` resolved, naming the base it was resolved against.
    case trackControlResolved(index: Int, uri: String, viaBase: String)
    /// The `SETUP` response omitted `interleaved`, so we assumed the channels we asked for.
    case assumedInterleavedChannels(ClosedRange<UInt8>)
    /// A track was skipped, with the reason a user could act on.
    case trackSkipped(index: Int, reason: String)
    /// The framing decoder resynchronised.
    case framingResync(discarded: Int, reason: String)
    /// A `$` frame was accepted inside a header block.
    case midHeaderInterleavedFrame(channel: UInt8, length: Int)
    /// A header line without a colon was ignored.
    case malformedHeaderIgnored(String)
    /// A `sprop-*` value did not decode; the stream continues on in-band parameter sets.
    case malformedParameterSet(codec: String)
    /// A response arrived that matched no outstanding request.
    case unsolicitedResponse(cseq: UInt32?)
    /// A server-initiated request was answered.
    case serverRequest(method: RTSPMethod, notice: String?)
    /// A `Notice` header was parsed.
    case noticeReceived(code: Int, text: String)
    /// Media arrived before `PLAY` completed and the buffer overflowed.
    case preplayMediaDropped(count: Int)
    /// The keepalive went out, naming the method chosen for this device.
    case keepaliveSent(method: RTSPMethod)
    /// The session id and timeout the device assigned.
    case sessionEstablished(id: String, timeoutSeconds: Int)
    /// A `Transport` header we could not honour.
    case transportRejected(String)
    /// A `301`/`302` is being followed.
    case redirected(to: String)
    /// A status we mapped to a failure, kept as text so a log line diagnoses it.
    case statusRejected(status: Int, method: RTSPMethod, reason: String)
}

// MARK: - RTSPAction

/// Every I/O intent the machine can express. The machine performs no I/O itself; the driver
/// executes these in the order given, and that order is normative (docs/spec-rtsp.md §14.6).
public enum RTSPAction: Sendable, Hashable {
    /// Write these bytes as **one** atomic write. Concatenating every `.send` payload in emission
    /// order reproduces the client's byte stream exactly.
    case send(Data)
    /// Frame and write one interleaved packet (an RTCP receiver report). One atomic write.
    case sendInterleaved(channel: UInt8, payload: Data)
    /// Bind a UDP RTP/RTCP pair before sending this track's SETUP request.
    case prepareUDP(trackID: Int, ports: RTSPUDPPortPair)
    /// Join both RTP and RTCP ports of a server-selected multicast group.
    case joinMulticast(trackID: Int, endpoint: RTSPMulticastEndpoint)
    /// Send an RTCP datagram from the reserved local RTCP port.
    case sendUDP(localPort: UInt16, payload: Data)
    /// Arm or re-arm a timer; an existing timer with the same id is **replaced**, not stacked.
    case setTimer(RTSPTimerID, deadline: MediaInstant)
    /// Disarm a timer. Disarming one that is not armed is not an error.
    case cancelTimer(RTSPTimerID)
    /// A track is fully negotiated. Emitted once per track, in SDP order, after its `SETUP`.
    case emitTrack(RTSPTrack)
    /// Presentation-time seeds, emitted after `PLAY` and **before** any media for that track.
    case emitTiming(RTSPTrackTiming)
    /// One complete RTP or RTCP packet; `payload` excludes the 4-byte framing header.
    case emitMedia(channel: UInt8, payload: Data)
    /// The session is playing. Emitted exactly once per successful `PLAY`.
    case ready(RTSPSessionDescription)
    /// A state transition, for observability. Always precedes the actions the new state causes.
    case stateChanged(RTSPSessionState)
    /// A structured log record.
    case log(RTSPLogEvent)
    /// Ask the transport to stop or resume reading (`Rate-Control: no` backpressure).
    case setReadBackpressure(Bool)
    /// Terminal failure. **No further action is ever produced.**
    case fail(RTSPError)
    /// Close the connection.
    case closeTransport(reason: RTSPCloseReason)
    /// Reconnect to a new endpoint and re-drive a fresh machine.
    case reconnect(to: RTSPURL, resetAuthState: Bool)
}
