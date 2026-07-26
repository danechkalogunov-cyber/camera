//
//  RTPStreamGenerator.swift
//  VigilTestKit
//
//  Packetizes synthetic access units into RTP exactly as RFC 6184 (H.264) and RFC 7798 (H.265)
//  specify — single-NAL, STAP-A/AP aggregation and FU fragmentation at a configurable MTU — then
//  applies the seeded network faults: loss, reordering, duplication and marker-bit misbehaviour.
//  The bytes are what a camera would put on the wire, because the real depacketizer consumes them.
//  Implements docs/ARCHITECTURE.md §10.2 (`RTPStreamGenerator`).
//

import VigilProtocols

// MARK: - Packet

/// One RTP packet as bytes, with the fields a test needs to assert on kept alongside.
public struct RTPPacketBytes: Sendable, Hashable {

    /// The sequence number in the header. Assigned before loss shaping, so a dropped packet leaves
    /// a real gap and a reordered one keeps its original number.
    public var sequenceNumber: UInt16

    /// The 32-bit RTP timestamp in the header.
    public var timestamp: UInt32

    /// The marker bit as actually written, after any marker quirk.
    public var marker: Bool

    /// The complete packet: 12-byte header followed by payload.
    public var bytes: [UInt8]

    /// Index of the access unit this packet belongs to, for ground-truth bookkeeping.
    public var accessUnitIndex: Int
}

// MARK: - Generator

/// Turns access units into a shaped RTP packet stream.
public struct RTPStreamGenerator: Sendable {

    private let profile: SyntheticCameraProfile
    private let ssrc: UInt32
    private var sequenceNumber: UInt16
    private var random: SplitMix64RandomSource

    /// Packets held back to produce out-of-order arrival, when ``Quirk/reorder(windowPackets:)``
    /// is in force. Empty otherwise.
    private var holdback: [RTPPacketBytes] = []

    /// Total packets actually emitted, duplicates included.
    public private(set) var emittedPacketCount: Int = 0

    /// Total payload octets emitted, for the RTCP sender report.
    public private(set) var emittedOctetCount: UInt32 = 0

    /// Sequence numbers the loss injector discarded, in the order they were dropped.
    public private(set) var droppedSequenceNumbers: [UInt16] = []

    /// The MTU used when deciding between a single-NAL packet, an aggregate and a fragment.
    public var mtu: Int

    /// Creates a generator.
    ///
    /// - Parameters:
    ///   - profile: the camera being simulated; supplies MTU, codec and the quirk set.
    ///   - ssrc: the synchronisation source written into every packet.
    ///   - startSequence: the first sequence number. ``Quirk/sequenceWrapSoon`` overrides it.
    public init(profile: SyntheticCameraProfile, ssrc: UInt32, startSequence: UInt16) {
        self.profile = profile
        self.ssrc = ssrc
        mtu = profile.mtu
        sequenceNumber = profile.quirks.contains(.sequenceWrapSoon) ? 65_500 : startSequence
        random = SplitMix64RandomSource(seed: profile.seed ^ 0x5DEE_CE66_D3E5_1AB3)
    }

    // MARK: Public entry point

    /// Packetizes one access unit and returns the packets that leave the camera *now*, in wire
    /// order. Reordering may hold some packets back and release earlier ones instead, so the
    /// returned count is not the packet count of this access unit.
    public mutating func packetize(_ unit: SyntheticAccessUnit) -> [RTPPacketBytes] {
        let raw = buildPackets(for: unit)
        var out: [RTPPacketBytes] = []
        out.reserveCapacity(raw.count)
        for packet in raw {
            out.append(contentsOf: shape(packet))
        }
        return out
    }

    /// Releases every packet still in the reorder holdback, in the order they were buffered.
    /// Call at end of stream so no packet is silently lost by the fixture itself.
    public mutating func drain() -> [RTPPacketBytes] {
        let remaining = holdback
        holdback.removeAll(keepingCapacity: false)
        for packet in remaining { account(packet) }
        return remaining
    }

    // MARK: Packetization

    /// Builds the unshaped packet list for one access unit, marker bit included.
    private mutating func buildPackets(for unit: SyntheticAccessUnit) -> [RTPPacketBytes] {
        var payloads: [[UInt8]] = []
        let groups = profile.quirks.contains(.aggregationPackets)
            ? aggregate(unit.nals)
            : unit.nals.map { [$0] }
        for group in groups {
            if group.count > 1 {
                payloads.append(aggregationPayload(group))
            } else if let nal = group.first {
                if nal.count <= payloadBudget {
                    payloads.append(nal)
                } else {
                    payloads.append(contentsOf: fragmentPayloads(nal))
                }
            }
        }
        guard !payloads.isEmpty else { return [] }

        // Marker policy. RFC 3550 puts it on the last packet of an access unit; the quirks are the
        // two ways real firmware gets this wrong.
        let lastIndex = payloads.count - 1
        let midIndex = payloads.count > 2 ? payloads.count / 2 : 0
        var packets: [RTPPacketBytes] = []
        packets.reserveCapacity(payloads.count)
        for (index, payload) in payloads.enumerated() {
            let marker: Bool
            if profile.quirks.contains(.markerNeverSet) {
                marker = false
            } else if profile.quirks.contains(.markerMidPicture) {
                marker = index == midIndex && index != lastIndex
            } else {
                marker = index == lastIndex
            }
            packets.append(RTPPacketBytes(sequenceNumber: sequenceNumber,
                                          timestamp: unit.rtpTimestamp,
                                          marker: marker,
                                          bytes: header(marker: marker,
                                                        timestamp: unit.rtpTimestamp) + payload,
                                          accessUnitIndex: unit.index))
            sequenceNumber = sequenceNumber &+ 1
        }
        return packets
    }

    /// Payload bytes available after the 12-byte RTP header.
    private var payloadBudget: Int { Swift.max(64, mtu - 12) }

    /// Groups consecutive NALs that fit together into one aggregation packet.
    ///
    /// Real cameras that aggregate do it for the small NALs — the parameter sets ahead of an IRAP —
    /// and send the slice on its own, which is exactly what this produces.
    private func aggregate(_ nals: [[UInt8]]) -> [[[UInt8]]] {
        let aggregationHeaderBytes = profile.videoCodec == .h265 ? 2 : 1
        var groups: [[[UInt8]]] = []
        var current: [[UInt8]] = []
        var currentSize = aggregationHeaderBytes
        for nal in nals {
            let cost = 2 + nal.count
            if !current.isEmpty && currentSize + cost <= payloadBudget {
                current.append(nal)
                currentSize += cost
            } else {
                if !current.isEmpty { groups.append(current) }
                if aggregationHeaderBytes + cost <= payloadBudget {
                    current = [nal]
                    currentSize = aggregationHeaderBytes + cost
                } else {
                    // Too big to aggregate at all: emit alone so it takes the fragmenting path.
                    groups.append([nal])
                    current = []
                    currentSize = aggregationHeaderBytes
                }
            }
        }
        if !current.isEmpty { groups.append(current) }
        // A group of one that is under the budget stays a single-NAL packet, which is what the
        // RFCs prefer; only genuinely aggregated groups keep more than one member.
        return groups
    }

    /// STAP-A (RFC 6184 §5.7.1) or AP (RFC 7798 §4.4.2) payload for `group`.
    private func aggregationPayload(_ group: [[UInt8]]) -> [UInt8] {
        var payload: [UInt8] = []
        if profile.videoCodec == .h265 {
            // PayloadHdr with type 48 (AP), layer 0, TID 1.
            payload.append(contentsOf: [48 << 1, 0x01])
        } else {
            // STAP-A indicator: F 0, NRI the maximum of the aggregated units, type 24.
            let nri = group.compactMap(\.first).map { ($0 >> 5) & 0x03 }.max() ?? 3
            payload.append((nri << 5) | 24)
        }
        for nal in group {
            let size = UInt16(clamping: nal.count)
            payload.append(UInt8(truncatingIfNeeded: size >> 8))
            payload.append(UInt8(truncatingIfNeeded: size))
            payload.append(contentsOf: nal)
        }
        return payload
    }

    /// FU-A (RFC 6184 §5.8) or FU (RFC 7798 §4.4.3) fragment payloads for one oversized NAL.
    private func fragmentPayloads(_ nal: [UInt8]) -> [[UInt8]] {
        let isHEVC = profile.videoCodec == .h265
        let nalHeaderBytes = isHEVC ? 2 : 1
        let fuOverhead = isHEVC ? 3 : 2
        guard nal.count > nalHeaderBytes else { return [nal] }
        let body = Array(nal[nalHeaderBytes...])
        let chunk = Swift.max(1, payloadBudget - fuOverhead)

        // Fields carried over from the original NAL header.
        let indicatorFirst: UInt8
        let indicatorSecond: UInt8
        let typeCode: UInt8
        if isHEVC {
            typeCode = (nal[0] >> 1) & 0x3F
            indicatorFirst = (nal[0] & 0x81) | (49 << 1)   // keep F and the layer-id high bit
            indicatorSecond = nal[1]
        } else {
            typeCode = nal[0] & 0x1F
            indicatorFirst = (nal[0] & 0xE0) | 28          // keep F and NRI, type 28 = FU-A
            indicatorSecond = 0
        }

        var out: [[UInt8]] = []
        var offset = 0
        while offset < body.count {
            let end = Swift.min(offset + chunk, body.count)
            let isFirst = offset == 0
            let isLast = end == body.count
            var payload: [UInt8] = []
            payload.reserveCapacity(fuOverhead + (end - offset))
            if isHEVC {
                payload.append(indicatorFirst)
                payload.append(indicatorSecond)
                payload.append((isFirst ? 0x80 : 0) | (isLast ? 0x40 : 0) | (typeCode & 0x3F))
            } else {
                payload.append(indicatorFirst)
                payload.append((isFirst ? 0x80 : 0) | (isLast ? 0x40 : 0) | (typeCode & 0x1F))
            }
            payload.append(contentsOf: body[offset..<end])
            out.append(payload)
            offset = end
        }
        return out
    }

    /// A 12-byte RTP fixed header: version 2, no padding, no extension, no CSRCs.
    private func header(marker: Bool, timestamp: UInt32) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(12)
        bytes.append(0x80)
        bytes.append((marker ? 0x80 : 0) | (profile.payloadType & 0x7F))
        bytes.append(UInt8(truncatingIfNeeded: sequenceNumber >> 8))
        bytes.append(UInt8(truncatingIfNeeded: sequenceNumber))
        bytes.append(contentsOf: bigEndian(timestamp))
        bytes.append(contentsOf: bigEndian(ssrc))
        return bytes
    }

    // MARK: Network shaping

    /// Applies loss, reordering and duplication to one packet, returning what actually goes out.
    private mutating func shape(_ packet: RTPPacketBytes) -> [RTPPacketBytes] {
        if let rate = profile.quirks.packetLossRate, rate > 0, draw() < rate {
            droppedSequenceNumbers.append(packet.sequenceNumber)
            return []
        }

        var released: [RTPPacketBytes] = []
        if let window = profile.quirks.reorderWindow {
            holdback.append(packet)
            if holdback.count >= window {
                // Release a packet chosen from the window rather than the oldest, which is what a
                // path with variable per-packet queueing delay looks like from the receiver.
                let index = Int(random.next(upperBound: UInt64(holdback.count)))
                released.append(holdback.remove(at: index))
            }
        } else {
            released.append(packet)
        }

        var out: [RTPPacketBytes] = []
        for item in released {
            account(item)
            out.append(item)
            if let rate = profile.quirks.duplicateRate, rate > 0, draw() < rate {
                account(item)
                out.append(item)
            }
        }
        return out
    }

    /// Counts a packet against the sender-report totals.
    private mutating func account(_ packet: RTPPacketBytes) {
        emittedPacketCount += 1
        emittedOctetCount = emittedOctetCount &+ UInt32(clamping: packet.bytes.count - 12)
    }

    /// A uniform draw in `[0, 1)` from the seeded generator.
    private mutating func draw() -> Double {
        Double(random.next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    // MARK: RTCP

    /// A compound RTCP packet: a sender report (RFC 3550 §6.4.1) followed by an SDES CNAME item.
    ///
    /// - Parameters:
    ///   - ntpSeconds: NTP-epoch seconds for the report's wall-clock field.
    ///   - rtpTimestamp: the RTP timestamp corresponding to `ntpSeconds`.
    public func senderReport(ntpSeconds: UInt32, ntpFraction: UInt32, rtpTimestamp: UInt32,
                             cname: String) -> [UInt8] {
        var sr: [UInt8] = [0x80, 200, 0x00, 0x06]
        sr.append(contentsOf: bigEndian(ssrc))
        sr.append(contentsOf: bigEndian(ntpSeconds))
        sr.append(contentsOf: bigEndian(ntpFraction))
        sr.append(contentsOf: bigEndian(rtpTimestamp))
        sr.append(contentsOf: bigEndian(UInt32(clamping: emittedPacketCount)))
        sr.append(contentsOf: bigEndian(emittedOctetCount))

        var items: [UInt8] = []
        items.append(contentsOf: bigEndian(ssrc))
        let text = Array(cname.utf8.prefix(255))
        items.append(1)                                   // SDES item type 1 = CNAME
        items.append(UInt8(clamping: text.count))
        items.append(contentsOf: text)
        items.append(0)                                   // item list terminator
        while items.count % 4 != 0 { items.append(0) }
        var sdes: [UInt8] = [0x81, 202]
        let words = UInt16(clamping: items.count / 4)
        sdes.append(UInt8(truncatingIfNeeded: words >> 8))
        sdes.append(UInt8(truncatingIfNeeded: words))
        sdes.append(contentsOf: items)

        return sr + sdes
    }

    // MARK: Byte helpers

    private func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }
}
