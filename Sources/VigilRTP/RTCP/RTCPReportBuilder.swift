//
//  RTCPReportBuilder.swift
//  VigilRTP
//
//  Outbound RTCP: the compound RR + SDES a receive-only client must send, BYE, FIR, and the
//  RFC 3550 §6.2 transmission interval.
//  Implements docs/spec-rtp.md §12.8 / §12.9 and docs/API_CONTRACT.md §5.5
//  (`RTCP/RTCPReportBuilder.swift`).
//

import Foundation
import VigilProtocols

/// Builds the RTCP packets Vigil sends.
///
/// Vigil never sends RTP, so it never sends a Sender Report. A compound packet must begin with SR or
/// RR and must carry an SDES CNAME (RFC 3550 §6.1), so every report is `RR + SDES`.
///
/// **This is not a keepalive.** The session keepalive is `GET_PARAMETER`, owned by `VigilRTSP`:
/// several Hikvision builds ignore RTCP entirely when deciding whether a session is still alive.
public struct RTCPReportBuilder: Sendable {

    // MARK: - Stored Properties

    /// Our own synchronisation source. Non-zero, stable for the whole session.
    public private(set) var ourSSRC: UInt32

    /// The canonical name. Must be stable for the session and unique per host and process.
    /// Truncated to 255 bytes of UTF-8, the most the one-byte SDES length field can express.
    public var cname: String

    /// The optional `TOOL` SDES item. `nil` omits the item entirely.
    public var tool: String?

    /// Sequence number of the next Full Intra Request, which RFC 5104 requires to increment.
    private var firSequenceNumber: UInt8 = 0

    // MARK: - Initialisation

    /// Creates a builder with an explicit SSRC. Used by tests and by fixtures that pin the bytes.
    public init(ourSSRC: UInt32, cname: String, tool: String? = "Vigil/1.0") {
        self.ourSSRC = ourSSRC == 0 ? 1 : ourSSRC
        self.cname = cname
        self.tool = tool
    }

    /// Creates a builder whose SSRC is drawn from an injected source.
    ///
    /// Never zero: RFC 3550 reserves it in practice, and a camera that sees a zero SSRC in a report
    /// block cannot match it to anything.
    public init(cname: String, tool: String? = "Vigil/1.0", random: inout any RandomSource) {
        let drawn = UInt32(truncatingIfNeeded: random.next())
        self.ourSSRC = drawn == 0 ? 1 : drawn
        self.cname = cname
        self.tool = tool
    }

    // MARK: - SSRC collision

    /// Adopts a new SSRC after a collision (an inbound packet carrying our own SSRC), per
    /// RFC 3550 §8.2.
    public mutating func regenerateSSRC(random: inout any RandomSource) {
        var drawn = UInt32(truncatingIfNeeded: random.next())
        if drawn == 0 { drawn = 1 }
        ourSSRC = drawn
    }

    // MARK: - Compound report

    /// Builds the `RR + SDES` compound packet for one source, rolling that source's report interval.
    ///
    /// The returned bytes are the RTCP payload only: `VigilRTSP` adds the `$` interleave framing on
    /// channel 1 for the first track, channel 3 for the second, and so on.
    public mutating func makeCompoundReport(source: inout RTPSourceState,
                                            at now: MediaInstant) -> Data {
        let block = source.makeReportBlock(at: now)
        var writer = ByteWriter(capacity: 96)
        appendReceiverReport(&writer, blocks: [block])
        appendSourceDescription(&writer)
        return writer.data
    }

    /// Builds an empty Receiver Report plus SDES, for the case where no source has been validated
    /// yet but the interval has come around.
    public func makeEmptyReport() -> Data {
        var writer = ByteWriter(capacity: 64)
        appendReceiverReport(&writer, blocks: [])
        appendSourceDescription(&writer)
        return writer.data
    }

    /// Builds a BYE for our own SSRC, sent on TEARDOWN.
    ///
    /// - Parameter reason: an optional reason string, truncated to 255 bytes of UTF-8.
    public func makeBye(reason: String?) -> Data {
        var writer = ByteWriter(capacity: 32)
        var body = ByteWriter(capacity: 24)
        body.appendU32BE(ourSSRC)
        if let reason, !reason.isEmpty {
            let bytes = Array(reason.utf8.prefix(255))
            body.append(UInt8(bytes.count))
            body.append(contentsOf: bytes)
            while body.count % 4 != 0 { body.append(0) }
        }
        appendHeader(&writer, itemCount: 1, payloadType: .goodbye, bodyCount: body.count)
        writer.append(contentsOf: body.bytes)
        return writer.data
    }

    /// Builds an RFC 5104 Full Intra Request (PT 206, FMT 4).
    ///
    /// Sent alongside the ISAPI key-frame request because it costs one datagram; most Hikvision
    /// firmware ignores it, which is why ISAPI is the primary mechanism.
    public mutating func makeFullIntraRequest(target: UInt32) -> Data {
        firSequenceNumber &+= 1
        var writer = ByteWriter(capacity: 24)
        var body = ByteWriter(capacity: 16)
        body.appendU32BE(ourSSRC)
        body.appendU32BE(0)                    // media source SSRC is 0 for PSFB per RFC 5104
        body.appendU32BE(target)               // FCI: the source we want an IRAP from
        body.append(firSequenceNumber)
        body.append(contentsOf: [0, 0, 0])     // FCI reserved
        appendHeader(&writer, itemCount: 4, payloadType: .payloadFeedback, bodyCount: body.count)
        writer.append(contentsOf: body.bytes)
        return writer.data
    }

    // MARK: - Private

    /// Writes the 4-byte common header. `bodyCount` must already be a multiple of four.
    private func appendHeader(_ writer: inout ByteWriter, itemCount: Int,
                              payloadType: RTCPPacketType, bodyCount: Int) {
        writer.append(0x80 | UInt8(Swift.min(31, Swift.max(0, itemCount))))
        writer.append(payloadType.rawValue)
        // The length field counts 32-bit words of the whole packet, minus one.
        writer.appendU16BE(UInt16(truncatingIfNeeded: (bodyCount + 4) / 4 - 1))
    }

    /// Writes a Receiver Report with the given blocks.
    private func appendReceiverReport(_ writer: inout ByteWriter, blocks: [ReceptionReportBlock]) {
        var body = ByteWriter(capacity: 4 + blocks.count * 24)
        body.appendU32BE(ourSSRC)
        for block in blocks {
            body.appendU32BE(block.ssrc)
            body.append(block.fractionLost)
            body.appendU24BE(UInt32(bitPattern: block.cumulativeLost) & 0x00FF_FFFF)
            body.appendU32BE(block.extendedHighestSequence)
            body.appendU32BE(block.jitter)
            body.appendU32BE(block.lastSenderReportTimestamp)
            body.appendU32BE(block.delaySinceLastSenderReport)
        }
        appendHeader(&writer, itemCount: blocks.count, payloadType: .receiverReport,
                     bodyCount: body.count)
        writer.append(contentsOf: body.bytes)
    }

    /// Writes a one-chunk SDES carrying CNAME and, when configured, TOOL.
    private func appendSourceDescription(_ writer: inout ByteWriter) {
        var body = ByteWriter(capacity: 48)
        body.appendU32BE(ourSSRC)
        appendItem(&body, type: .cname, text: cname)
        if let tool, !tool.isEmpty { appendItem(&body, type: .tool, text: tool) }
        body.append(0)                                    // end-of-items marker
        while body.count % 4 != 0 { body.append(0) }      // null padding to a 32-bit boundary
        appendHeader(&writer, itemCount: 1, payloadType: .sourceDescription, bodyCount: body.count)
        writer.append(contentsOf: body.bytes)
    }

    /// Writes one `type, length, text` SDES item, truncating text to the 255-byte field limit.
    private func appendItem(_ writer: inout ByteWriter, type: SourceDescription.ItemType,
                            text: String) {
        let bytes = Array(text.utf8.prefix(255))
        writer.append(type.rawValue)
        writer.append(UInt8(bytes.count))
        writer.append(contentsOf: bytes)
    }
}

// MARK: - RTCPSchedule

/// When the next RTCP report is due.
///
/// RFC 3550 §6.2's bandwidth-derived interval collapses, for a unicast receive-only client, to a
/// 5 s base randomised over `0.5...1.5` — the randomisation is what stops sixteen cameras' reports
/// from synchronising into a burst. The first report after PLAY uses half the interval, floored at
/// 1.5 s, which RFC 3550 explicitly permits.
public struct RTCPSchedule: Sendable {

    /// The steady-state base interval before randomisation.
    public var baseInterval: Duration

    /// Floor applied to the halved first interval.
    public var minimumInitialInterval: Duration

    /// When the next report is due, or `nil` before the first `schedule` call.
    public private(set) var nextDeadline: MediaInstant?

    /// True until the first report has been produced.
    private var isInitial = true

    /// Creates a schedule. `baseInterval` is clamped to `1...30` s, the range a server-supplied
    /// `RTCP-Interval` may take.
    public init(baseInterval: Duration = .seconds(5),
                minimumInitialInterval: Duration = .milliseconds(1500)) {
        let seconds = Swift.min(30, Swift.max(1, baseInterval.seconds))
        self.baseInterval = .milliseconds(Int(seconds * 1000))
        self.minimumInitialInterval = minimumInitialInterval
    }

    /// Arms the next deadline from `now`, drawing the RFC 3550 randomisation from `random`.
    public mutating func schedule(after now: MediaInstant, random: inout any RandomSource) {
        let base = isInitial
            ? Swift.max(minimumInitialInterval.milliseconds, baseInterval.milliseconds / 2)
            : baseInterval.milliseconds
        isInitial = false
        // `jitterFactor(0.5)` is uniform on 0.5...1.5, exactly RFC 3550 §6.3.1's multiplier.
        let milliseconds = base * random.jitterFactor(0.5)
        nextDeadline = now + .milliseconds(Int(milliseconds.rounded()))
    }

    /// True when a report is due at `now`.
    public func isDue(at now: MediaInstant) -> Bool {
        guard let nextDeadline else { return true }
        return now >= nextDeadline
    }

    /// Forces the next report to be due immediately, for the extra report a loss burst earns.
    public mutating func expedite() {
        nextDeadline = nil
    }

    /// Returns to the initial-interval behaviour, for a reconnect.
    public mutating func reset() {
        nextDeadline = nil
        isInitial = true
    }
}
