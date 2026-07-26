//
//  RTCPPacket.swift
//  VigilRTP
//
//  The RTCP wire model: Sender Report, Receiver Report, SDES, BYE and the opaque fallback.
//  Implements docs/spec-rtp.md §12.2 – §12.4 and docs/API_CONTRACT.md §4.4 / §5.5
//  (`RTCP/RTCPPacket.swift`).
//

import Foundation

// MARK: - Packet types

/// The RTCP packet types Vigil recognises. Anything else is skipped by its declared length.
public enum RTCPPacketType: UInt8, Sendable, Hashable {
    /// Sender Report.
    case senderReport = 200
    /// Receiver Report.
    case receiverReport = 201
    /// Source Description.
    case sourceDescription = 202
    /// Goodbye.
    case goodbye = 203
    /// Application-defined.
    case applicationDefined = 204
    /// Transport-layer feedback (RFC 4585).
    case transportFeedback = 205
    /// Payload-specific feedback (RFC 4585 / RFC 5104), which carries FIR.
    case payloadFeedback = 206
}

// MARK: - Reception report block

/// One 24-byte reception report block, identical in SR and RR (RFC 3550 §6.4.1).
public struct ReceptionReportBlock: Sendable, Hashable {

    /// The source being reported on.
    public var ssrc: UInt32
    /// Fraction of packets lost since the previous report, as 8-bit fixed point (`lost/expected`
    /// scaled by 256). Never negative: duplicates make it 0, not a wrapped byte.
    public var fractionLost: UInt8
    /// Cumulative packets lost, a 24-bit **signed** field. Negative when duplicates outnumber loss.
    public var cumulativeLost: Int32
    /// The extended (cycle-corrected) highest sequence number received.
    public var extendedHighestSequence: UInt32
    /// Interarrival jitter in RTP timestamp units, **unscaled** — `RTPSourceState` keeps the ×16
    /// form internally and divides on the way out.
    public var jitter: UInt32
    /// Middle 32 bits of the NTP timestamp of the last Sender Report received, or 0 if none.
    public var lastSenderReportTimestamp: UInt32
    /// Delay since that Sender Report, in units of 1/65536 s, or 0 if none.
    public var delaySinceLastSenderReport: UInt32

    /// Creates a report block. Every field is on the wire exactly as given.
    public init(ssrc: UInt32,
                fractionLost: UInt8,
                cumulativeLost: Int32,
                extendedHighestSequence: UInt32,
                jitter: UInt32,
                lastSenderReportTimestamp: UInt32,
                delaySinceLastSenderReport: UInt32) {
        self.ssrc = ssrc
        self.fractionLost = fractionLost
        self.cumulativeLost = cumulativeLost
        self.extendedHighestSequence = extendedHighestSequence
        self.jitter = jitter
        self.lastSenderReportTimestamp = lastSenderReportTimestamp
        self.delaySinceLastSenderReport = delaySinceLastSenderReport
    }

    /// Jitter converted to milliseconds at a given RTP clock rate. 0 for a non-positive rate.
    public func jitterMilliseconds(clockRate: Int32) -> Double {
        guard clockRate > 0 else { return 0 }
        return Double(jitter) * 1000 / Double(clockRate)
    }
}

// MARK: - Sender Report

/// An RTCP Sender Report (PT 200): the camera's simultaneous NTP and RTP clock reading.
public struct SenderReport: Sendable, Hashable {

    /// Seconds between the NTP epoch (1900-01-01) and the Unix epoch (1970-01-01).
    public static let ntpToUnixEpochSeconds = 2_208_988_800.0

    /// The sending source.
    public var ssrc: UInt32
    /// Most significant word of the NTP timestamp: seconds since 1900.
    public var ntpMostSignificantWord: UInt32
    /// Least significant word of the NTP timestamp: binary fraction of a second.
    public var ntpLeastSignificantWord: UInt32
    /// The RTP timestamp corresponding to that NTP instant, in the media clock.
    public var rtpTimestamp: UInt32
    /// Packets the sender has sent since it started.
    public var packetCount: UInt32
    /// Payload octets the sender has sent since it started.
    public var octetCount: UInt32
    /// Reception reports the sender attached, if it is also receiving. Usually empty from a camera.
    public var reports: [ReceptionReportBlock]

    /// Creates a Sender Report.
    public init(ssrc: UInt32,
                ntpMostSignificantWord: UInt32,
                ntpLeastSignificantWord: UInt32,
                rtpTimestamp: UInt32,
                packetCount: UInt32,
                octetCount: UInt32,
                reports: [ReceptionReportBlock] = []) {
        self.ssrc = ssrc
        self.ntpMostSignificantWord = ntpMostSignificantWord
        self.ntpLeastSignificantWord = ntpLeastSignificantWord
        self.rtpTimestamp = rtpTimestamp
        self.packetCount = packetCount
        self.octetCount = octetCount
        self.reports = reports
    }

    /// The NTP reading as Unix seconds.
    public var unixSeconds: Double {
        Double(ntpMostSignificantWord) - Self.ntpToUnixEpochSeconds
            + Double(ntpLeastSignificantWord) / 4_294_967_296
    }

    /// True when the reading is late enough to be a real clock rather than a camera that has never
    /// reached an NTP server. Hikvision devices with NTP disabled report a time near 1970 or near
    /// their own boot time; the cutoff is 2001-09-09.
    public var isPlausibleWallClock: Bool { unixSeconds >= 1_000_000_000 }

    /// The middle 32 bits of the NTP timestamp — exactly what a report block's LSR field carries.
    public var compactNTP: UInt32 {
        (ntpMostSignificantWord << 16) | (ntpLeastSignificantWord >> 16)
    }
}

// MARK: - Receiver Report

/// An RTCP Receiver Report (PT 201). An empty report list is legal.
public struct ReceiverReport: Sendable, Hashable {

    /// The reporting receiver.
    public var ssrc: UInt32
    /// One block per source being reported on.
    public var reports: [ReceptionReportBlock]

    /// Creates a Receiver Report.
    public init(ssrc: UInt32, reports: [ReceptionReportBlock]) {
        self.ssrc = ssrc
        self.reports = reports
    }
}

// MARK: - SDES

/// An RTCP Source Description (PT 202).
public struct SourceDescription: Sendable, Hashable {

    /// The SDES item types Vigil names. Anything else is kept as `.other`.
    public enum ItemType: Sendable, Hashable {
        /// Canonical name, item type 1. The only mandatory item.
        case cname
        /// Free-form user name, item type 2.
        case name
        /// Tool name, item type 6. Some Hikvision models send `Hikvision` here.
        case tool
        /// Any other item type, kept verbatim.
        case other(UInt8)

        /// The wire value of this item type.
        public var rawValue: UInt8 {
            switch self {
            case .cname: 1
            case .name: 2
            case .tool: 6
            case .other(let value): value
            }
        }

        /// Maps a wire value onto a case.
        public init(rawValue: UInt8) {
            switch rawValue {
            case 1: self = .cname
            case 2: self = .name
            case 6: self = .tool
            default: self = .other(rawValue)
            }
        }
    }

    /// One `type: text` item inside a chunk.
    public struct Item: Sendable, Hashable {
        /// The item type.
        public var type: ItemType
        /// The item text, decoded as UTF-8 and falling back to Latin-1 rather than being dropped.
        public var text: String

        /// Creates an item.
        public init(type: ItemType, text: String) {
            self.type = type
            self.text = text
        }
    }

    /// One SSRC and the items describing it.
    public struct Chunk: Sendable, Hashable {
        /// The source being described.
        public var ssrc: UInt32
        /// The items, in wire order.
        public var items: [Item]

        /// Creates a chunk.
        public init(ssrc: UInt32, items: [Item]) {
            self.ssrc = ssrc
            self.items = items
        }

        /// The CNAME item's text, if the chunk carries one.
        public var cname: String? {
            items.first { $0.type == .cname }?.text
        }
    }

    /// The chunks, in wire order.
    public var chunks: [Chunk]

    /// Creates a source description.
    public init(chunks: [Chunk]) {
        self.chunks = chunks
    }
}

// MARK: - BYE

/// An RTCP Goodbye (PT 203). For a live stream this means the camera is closing the session; for a
/// recorded stream it is the only reliable end-of-file signal Hikvision gives.
public struct Goodbye: Sendable, Hashable {

    /// The sources leaving.
    public var sources: [UInt32]
    /// The optional human-readable reason.
    public var reason: String?

    /// Creates a goodbye.
    public init(sources: [UInt32], reason: String? = nil) {
        self.sources = sources
        self.reason = reason
    }
}

// MARK: - RTCPPacket

/// One sub-packet of an RTCP compound packet.
public enum RTCPPacket: Sendable, Hashable {
    /// PT 200.
    case senderReport(SenderReport)
    /// PT 201.
    case receiverReport(ReceiverReport)
    /// PT 202.
    case sourceDescription(SourceDescription)
    /// PT 203.
    case goodbye(Goodbye)
    /// Any packet type Vigil does not model, kept verbatim so a diagnostics dump can show it.
    case unhandled(payloadType: UInt8, body: Data)

    /// The wire payload type of this packet.
    public var payloadType: UInt8 {
        switch self {
        case .senderReport: RTCPPacketType.senderReport.rawValue
        case .receiverReport: RTCPPacketType.receiverReport.rawValue
        case .sourceDescription: RTCPPacketType.sourceDescription.rawValue
        case .goodbye: RTCPPacketType.goodbye.rawValue
        case .unhandled(let payloadType, _): payloadType
        }
    }
}
