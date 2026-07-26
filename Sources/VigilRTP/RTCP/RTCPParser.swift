//
//  RTCPParser.swift
//  VigilRTP
//
//  Compound RTCP parsing with strict length validation. Never throws: a malformed control packet
//  must not disturb the media path.
//  Implements docs/spec-rtp.md §12.2 – §12.4 and docs/API_CONTRACT.md §5.5
//  (`RTCP/RTCPParser.swift`).
//

import Foundation

/// Parses compound RTCP packets.
///
/// Interleaved channel 1 carries RTCP for the first track, channel 3 for the second, and so on.
/// `VigilRTSP` owns the `$` framing; this parser only ever sees the payload bytes.
///
/// **RTCP is not a keepalive.** `GET_PARAMETER` is (docs/spec-rtp.md §12.9). Several Hikvision
/// builds ignore RTCP entirely for session-timeout purposes.
public enum RTCPParser {

    /// The full result of a parse, including what was wrong with the buffer.
    public struct Result: Sendable {
        /// The sub-packets that parsed, in wire order.
        public var packets: [RTCPPacket] = []
        /// True when the buffer length was not a multiple of four. What fits is still parsed.
        public var isMisaligned = false
        /// True when a sub-packet's declared length ran past the end of the buffer.
        public var isTruncated = false

        /// Creates an empty result.
        public init() {}
    }

    /// Size of the common RTCP header: flags, packet type, length.
    private static let headerSize = 4

    /// Parses a compound packet, returning only the sub-packets.
    ///
    /// Unknown packet types are skipped by their declared length and never fail the parse; a
    /// sub-packet whose length overruns the buffer stops parsing and leaves everything before it
    /// intact.
    public static func parseCompound(_ bytes: Data) -> [RTCPPacket] {
        parse(bytes).packets
    }

    /// Parses a compound packet and reports how well-formed the buffer was.
    ///
    /// The caller counts `MalformedReason.rtcpMisaligned` when `isMisaligned` is set. Nothing here
    /// throws and nothing traps: every offset is bounds-checked against the buffer first.
    public static func parse(_ bytes: Data) -> Result {
        var result = Result()
        let b = RTPBytes(bytes)
        if b.count % 4 != 0 { result.isMisaligned = true }

        var offset = 0
        while offset + headerSize <= b.count {
            let flags = b[offset]
            guard (flags & 0xC0) >> 6 == 2 else { break }        // not RTCP version 2: stop
            let itemCount = Int(flags & 0x1F)
            let payloadType = b[offset + 1]
            let length = (Int(b.u16(offset + 2)) + 1) * 4
            guard offset + length <= b.count else {
                result.isTruncated = true
                break
            }
            let bodyStart = offset + headerSize
            let bodyEnd = offset + length
            let body = bodyStart < bodyEnd ? b.slice(bodyStart..<bodyEnd) : Data()

            if let packet = decode(payloadType: payloadType, itemCount: itemCount, body: body) {
                result.packets.append(packet)
            }
            offset = bodyEnd
        }
        return result
    }

    // MARK: - Private

    /// Decodes one sub-packet body. Returns `.unhandled` for types Vigil does not model, and `nil`
    /// only when a modelled type's body is too short to be meaningful.
    private static func decode(payloadType: UInt8, itemCount: Int, body: Data) -> RTCPPacket? {
        switch RTCPPacketType(rawValue: payloadType) {
        case .senderReport:
            guard let report = parseSenderReport(body, reportCount: itemCount) else { return nil }
            return .senderReport(report)
        case .receiverReport:
            guard let report = parseReceiverReport(body, reportCount: itemCount) else { return nil }
            return .receiverReport(report)
        case .sourceDescription:
            return .sourceDescription(parseSourceDescription(body, chunkCount: itemCount))
        case .goodbye:
            return .goodbye(parseGoodbye(body, sourceCount: itemCount))
        default:
            return .unhandled(payloadType: payloadType, body: body)
        }
    }

    /// Sender Report body: 24 fixed bytes then `reportCount` 24-byte blocks.
    private static func parseSenderReport(_ body: Data, reportCount: Int) -> SenderReport? {
        let b = RTPBytes(body)
        guard b.count >= 24 else { return nil }
        return SenderReport(
            ssrc: b.u32(0),
            ntpMostSignificantWord: b.u32(4),
            ntpLeastSignificantWord: b.u32(8),
            rtpTimestamp: b.u32(12),
            packetCount: b.u32(16),
            octetCount: b.u32(20),
            reports: parseReportBlocks(b, from: 24, count: reportCount)
        )
    }

    /// Receiver Report body: 4 fixed bytes then `reportCount` 24-byte blocks.
    private static func parseReceiverReport(_ body: Data, reportCount: Int) -> ReceiverReport? {
        let b = RTPBytes(body)
        guard b.count >= 4 else { return nil }
        return ReceiverReport(ssrc: b.u32(0),
                              reports: parseReportBlocks(b, from: 4, count: reportCount))
    }

    /// Reads as many whole 24-byte report blocks as both `count` and the buffer allow.
    private static func parseReportBlocks(_ b: RTPBytes, from start: Int,
                                          count: Int) -> [ReceptionReportBlock] {
        guard count > 0 else { return [] }
        var blocks: [ReceptionReportBlock] = []
        blocks.reserveCapacity(count)
        var offset = start
        for _ in 0..<count {
            guard offset + 24 <= b.count else { break }
            // Cumulative lost is 24-bit signed: sign-extend bit 23 into a full Int32.
            let raw = (UInt32(b[offset + 5]) << 16) | (UInt32(b[offset + 6]) << 8)
                | UInt32(b[offset + 7])
            let cumulative = raw & 0x80_0000 != 0
                ? Int32(bitPattern: raw | 0xFF00_0000)
                : Int32(raw)
            blocks.append(ReceptionReportBlock(
                ssrc: b.u32(offset),
                fractionLost: b[offset + 4],
                cumulativeLost: cumulative,
                extendedHighestSequence: b.u32(offset + 8),
                jitter: b.u32(offset + 12),
                lastSenderReportTimestamp: b.u32(offset + 16),
                delaySinceLastSenderReport: b.u32(offset + 20)
            ))
            offset += 24
        }
        return blocks
    }

    /// SDES body: `chunkCount` chunks of an SSRC then `type, length, text` items, terminated by a
    /// zero type byte and padded to the next 32-bit boundary.
    private static func parseSourceDescription(_ body: Data, chunkCount: Int) -> SourceDescription {
        let b = RTPBytes(body)
        var chunks: [SourceDescription.Chunk] = []
        var offset = 0
        var remaining = chunkCount
        while remaining > 0, offset + 4 <= b.count {
            let ssrc = b.u32(offset)
            offset += 4
            var items: [SourceDescription.Item] = []
            while offset < b.count {
                let type = b[offset]
                if type == 0 {
                    offset += 1
                    break
                }
                guard offset + 2 <= b.count else {
                    offset = b.count
                    break
                }
                let length = Int(b[offset + 1])
                guard offset + 2 + length <= b.count else {
                    offset = b.count
                    break
                }
                let text = decodeText(b.slice((offset + 2)..<(offset + 2 + length)))
                items.append(SourceDescription.Item(
                    type: SourceDescription.ItemType(rawValue: type), text: text))
                offset += 2 + length
            }
            // Chunks are padded with nulls to the next 32-bit boundary.
            while offset % 4 != 0, offset < b.count { offset += 1 }
            chunks.append(SourceDescription.Chunk(ssrc: ssrc, items: items))
            remaining -= 1
        }
        return SourceDescription(chunks: chunks)
    }

    /// BYE body: `sourceCount` SSRCs, then optionally a length-prefixed reason string.
    private static func parseGoodbye(_ body: Data, sourceCount: Int) -> Goodbye {
        let b = RTPBytes(body)
        var sources: [UInt32] = []
        sources.reserveCapacity(sourceCount)
        var offset = 0
        for _ in 0..<Swift.max(0, sourceCount) {
            guard offset + 4 <= b.count else { break }
            sources.append(b.u32(offset))
            offset += 4
        }
        var reason: String?
        if offset < b.count {
            let length = Int(b[offset])
            if length > 0, offset + 1 + length <= b.count {
                reason = decodeText(b.slice((offset + 1)..<(offset + 1 + length)))
            }
        }
        return Goodbye(sources: sources, reason: reason)
    }

    /// Decodes SDES/BYE text as UTF-8, falling back to Latin-1 rather than dropping the chunk.
    private static func decodeText(_ bytes: Data) -> String {
        if let text = String(data: bytes, encoding: .utf8) { return text }
        return String(data: bytes, encoding: .isoLatin1) ?? ""
    }
}
