//
//  AACDepacketizer.swift
//  VigilRTP
//
//  RFC 3640 depacketization in `mode=AAC-hbr`: the AU-header section, multi-AU packets and the
//  fragmented-AU path. AAC stays compressed — one raw access unit per `EncodedFrame`, with the
//  `AudioSpecificConfig` travelling in `AudioFormatInfo.magicCookie`.
//  See docs/spec-rtp.md §8 and docs/API_CONTRACT.md §4.4, §2 R-54.
//

import Foundation

import VigilProtocols

// MARK: - AACDepacketizer

/// Reassembles AAC access units from RTP.
///
/// Every AAC access unit is independently decodable, so there is no keyframe gate and no boundary
/// problem here — the only real work is the bit-packed AU-header section and the arithmetic that
/// turns an AU index into a presentation timestamp.
public struct AACDepacketizer: Depacketizer {

    // MARK: - Nested Types

    /// The RFC 3640 mode parameters, all of which come from the SDP `a=fmtp` line.
    struct Layout: Sendable, Hashable {
        var sizeLength = 13
        var indexLength = 3
        var indexDeltaLength = 3
        var ctsDeltaLength = 0
        var dtsDeltaLength = 0
        var randomAccessIndication = false
        var streamStateIndication = 0
        var auxiliaryDataSizeLength = 0
        /// When set, AU sizes are implicit and there is no size field.
        var constantSize: Int?
    }

    /// One AU that arrived split across packets.
    private struct PendingAU {
        var expectedBytes: Int
        var bytes: Data
        var timestamp: UInt32
        var extendedTimestamp: Int64
        var index: Int
        var isRandomAccess: Bool
    }

    // MARK: - Stored Properties

    /// Always `.audio(.aac)`. AAC is never decoded in the pure layer.
    public let codec: MediaCodec = .audio(.aac)

    /// RTP clock rate, which for AAC is the sample rate from `a=rtpmap`.
    public let clockRate: Int32

    /// The format handed to the decoder, including the magic cookie.
    public private(set) var format: AudioFormatInfo

    private let layout: Layout
    private var timestamps = RTPTimestampExtender()
    private var pending: PendingAU?
    private var limiter = EventRateLimiter()
    private var announcedFormat = false

    // MARK: - Initialisation

    /// Creates a depacketizer for one AAC track.
    ///
    /// - Parameters:
    ///   - clockRate: from `a=rtpmap`. Must be positive.
    ///   - channels: the channel count from `a=rtpmap`, used when the config says a program config
    ///     element follows.
    ///   - fmtp: the `a=fmtp` parameters with keys already lower-cased by `VigilRTSP`. Values are
    ///     compared case-insensitively here (docs/spec-rtp.md §8.7).
    /// - Throws: `RTPError.invalidClockRate` for a non-positive rate,
    ///   `RTPError.unsupportedAACMode` for anything but `AAC-hbr`,
    ///   `RTPError.missingRequiredFmtp` when `config=` is absent, and
    ///   `RTPError.malformedAudioConfig` when it does not parse.
    public init(clockRate: Int32, channels: Int32 = 1, fmtp: [String: String]) throws(RTPError) {
        guard clockRate > 0 else { throw .invalidClockRate(clockRate) }
        let mode = fmtp["mode"]?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard mode == "aac-hbr" else { throw .unsupportedAACMode(mode.isEmpty ? "absent" : mode) }
        guard let configHex = fmtp["config"] else { throw .missingRequiredFmtp("config") }

        var layout = Layout()
        layout.sizeLength = Self.integer(fmtp, "sizelength") ?? 13
        layout.indexLength = Self.integer(fmtp, "indexlength") ?? 3
        layout.indexDeltaLength = Self.integer(fmtp, "indexdeltalength") ?? 3
        layout.ctsDeltaLength = Self.integer(fmtp, "ctsdeltalength") ?? 0
        layout.dtsDeltaLength = Self.integer(fmtp, "dtsdeltalength") ?? 0
        layout.randomAccessIndication = (Self.integer(fmtp, "randomaccessindication") ?? 0) == 1
        layout.streamStateIndication = Self.integer(fmtp, "streamstateindication") ?? 0
        layout.auxiliaryDataSizeLength = Self.integer(fmtp, "auxiliarydatasizelength") ?? 0
        layout.constantSize = Self.integer(fmtp, "constantsize")
        guard layout.sizeLength >= 0, layout.sizeLength <= 32,
              layout.indexLength >= 0, layout.indexLength <= 32,
              layout.indexDeltaLength >= 0, layout.indexDeltaLength <= 32,
              layout.ctsDeltaLength >= 0, layout.ctsDeltaLength <= 32,
              layout.dtsDeltaLength >= 0, layout.dtsDeltaLength <= 32,
              layout.streamStateIndication >= 0, layout.streamStateIndication <= 32,
              layout.auxiliaryDataSizeLength >= 0, layout.auxiliaryDataSizeLength <= 32 else {
            throw .missingRequiredFmtp("an AU-header field length outside 0…32")
        }
        self.layout = layout
        self.clockRate = clockRate

        var parsed = try AudioSpecificConfig.parse(hex: configHex)
        if parsed.channels <= 1, channels > 1 { parsed.channels = channels }
        self.format = parsed
    }

    // MARK: - Public API

    /// Consume one RTP packet. See `Depacketizer.push(_:at:)`.
    public mutating func push(_ packet: RTPPacket, at now: MediaInstant) -> DepacketizerOutput {
        var out = DepacketizerOutput()
        if !announcedFormat {
            announcedFormat = true
            out.events.append(.audioConfigChanged(format))
        }
        let payload = packet.payload
        guard payload.count >= 2 else {
            report(.emptyPayload, at: now, into: &out)
            return out
        }
        let headerBits = Int(payload.u16BE(at: 0))
        let headerBytes = (headerBits + 7) / 8
        var offset = 2 + headerBytes
        guard offset <= payload.count else {
            report(.auSizeMismatch, at: now, into: &out)
            return out
        }
        guard let auxSkipped = skipAuxiliaryData(payload, from: offset) else {
            report(.auSizeMismatch, at: now, into: &out)
            return out
        }
        offset = auxSkipped

        let (value, _) = timestamps.extend(packet.timestamp)
        guard headerBits > 0 else {
            emitWithoutHeaders(payload.slice(offset..<payload.count), packet: packet,
                               extended: value, at: now, into: &out)
            return out
        }
        guard let headers = parseHeaders(payload.slice(2..<(2 + headerBytes)), bits: headerBits) else {
            report(.auSizeMismatch, at: now, into: &out)
            return out
        }
        emit(headers, body: payload.slice(offset..<payload.count), packet: packet,
             extended: value, at: now, into: &out)
        return out
    }

    /// Drops any partially received access unit. AAC has nothing else pending.
    public mutating func flush(at now: MediaInstant) -> [EncodedFrame] {
        pending = nil
        return []
    }

    /// Full state reset. See `Depacketizer.reset()`.
    public mutating func reset() {
        pending = nil
        timestamps.reset()
        limiter.reset()
        announcedFormat = false
    }

    // MARK: - Private Helpers

    /// One decoded AU header.
    private struct AUHeader {
        var size: Int
        var index: Int
        var isRandomAccess: Bool
    }

    /// Decodes the AU-header section into one header per access unit in the packet.
    ///
    /// - Returns: `nil` when the section is shorter than the fields it promises, or when it would
    ///   describe more access units than the payload could hold.
    private func parseHeaders(_ section: Data, bits: Int) -> [AUHeader]? {
        var reader = BitReader([UInt8](section))
        var headers: [AUHeader] = []
        var previousIndex = 0
        // Each header is at least one bit, so the section's own length bounds the loop.
        while reader.bitOffset < bits, headers.count < 256 {
            let isFirst = headers.isEmpty
            var size = layout.constantSize ?? 0
            if layout.constantSize == nil, layout.sizeLength > 0 {
                guard let value = read(&reader, layout.sizeLength) else { return nil }
                size = value
            }
            let indexBits = isFirst ? layout.indexLength : layout.indexDeltaLength
            var index = previousIndex
            if indexBits > 0 {
                guard let value = read(&reader, indexBits) else { return nil }
                index = isFirst ? value : previousIndex + value + 1
            } else if !isFirst {
                index = previousIndex + 1
            }
            if layout.ctsDeltaLength > 0 {
                guard let flag = read(&reader, 1) else { return nil }
                if flag == 1, read(&reader, layout.ctsDeltaLength) == nil { return nil }
            }
            if layout.dtsDeltaLength > 0 {
                guard let flag = read(&reader, 1) else { return nil }
                if flag == 1, read(&reader, layout.dtsDeltaLength) == nil { return nil }
            }
            var randomAccess = true
            if layout.randomAccessIndication {
                guard let flag = read(&reader, 1) else { return nil }
                randomAccess = flag == 1
            }
            if layout.streamStateIndication > 0, read(&reader, layout.streamStateIndication) == nil {
                return nil
            }
            headers.append(AUHeader(size: size, index: index, isRandomAccess: randomAccess))
            previousIndex = index
            // A constant-size stream with no other fields would loop forever otherwise.
            if layout.constantSize != nil, indexBits == 0, layout.ctsDeltaLength == 0,
               layout.dtsDeltaLength == 0, !layout.randomAccessIndication,
               layout.streamStateIndication == 0 {
                break
            }
        }
        return headers.isEmpty ? nil : headers
    }

    /// Turns AU headers plus the data section into frames, or into one pending fragment.
    private mutating func emit(_ headers: [AUHeader], body: Data, packet: RTPPacket,
                               extended: Int64, at now: MediaInstant,
                               into out: inout DepacketizerOutput) {
        if let first = headers.first, headers.count == 1, first.size > body.count {
            accumulateFragment(first, body: body, packet: packet, extended: extended, at: now,
                               into: &out)
            return
        }
        if pending != nil {
            // A self-contained packet arrived while an access unit was still incomplete.
            pending = nil
            report(.truncatedAudioAU, at: now, into: &out)
        }
        var total = 0
        for header in headers { total += header.size }
        guard total == body.count else {
            report(.auSizeMismatch, at: now, into: &out)
            return
        }
        var offset = 0
        for header in headers {
            let slice = body.slice(offset..<(offset + header.size))
            offset += header.size
            out.frames.append(makeFrame(slice,
                                        pts: extended + Int64(header.index)
                                            * Int64(format.framesPerPacket),
                                        isKeyframe: header.isRandomAccess,
                                        at: now))
        }
    }

    /// Handles the `AU-headers-length == 0` case, which is only legal with `constantsize`.
    private mutating func emitWithoutHeaders(_ body: Data, packet: RTPPacket, extended: Int64,
                                             at now: MediaInstant,
                                             into out: inout DepacketizerOutput) {
        guard let size = layout.constantSize, size > 0 else {
            report(.auSizeMismatch, at: now, into: &out)
            return
        }
        guard body.count % size == 0, !body.isEmpty else {
            report(.auSizeMismatch, at: now, into: &out)
            return
        }
        var offset = 0
        var index = 0
        while offset + size <= body.count {
            out.frames.append(makeFrame(body.slice(offset..<(offset + size)),
                                        pts: extended + Int64(index) * Int64(format.framesPerPacket),
                                        isKeyframe: true,
                                        at: now))
            offset += size
            index += 1
        }
    }

    /// Starts, continues or completes an access unit split across packets.
    ///
    /// In `AAC-hbr` a fragmented access unit repeats the same AU header, carrying the size of the
    /// whole access unit, in every packet; the receiver concatenates until it has that many bytes.
    /// A packet with a different RTP timestamp arriving while one is open discards the partial
    /// access unit rather than splicing two of them together.
    private mutating func accumulateFragment(_ header: AUHeader, body: Data, packet: RTPPacket,
                                             extended: Int64, at now: MediaInstant,
                                             into out: inout DepacketizerOutput) {
        if var open = pending {
            guard open.timestamp == packet.timestamp else {
                pending = nil
                report(.truncatedAudioAU, at: now, into: &out)
                return
            }
            open.bytes.append(body)
            guard open.bytes.count >= open.expectedBytes else {
                pending = open
                return
            }
            pending = nil
            let pts = open.extendedTimestamp + Int64(open.index) * Int64(format.framesPerPacket)
            out.frames.append(makeFrame(open.bytes.prefix(open.expectedBytes),
                                        pts: pts,
                                        isKeyframe: open.isRandomAccess,
                                        at: now))
            return
        }
        guard header.size <= 1 << 20 else {
            report(.truncatedAudioAU, at: now, into: &out)
            return
        }
        var bytes = Data(capacity: header.size)
        bytes.append(body)
        pending = PendingAU(expectedBytes: header.size, bytes: bytes, timestamp: packet.timestamp,
                            extendedTimestamp: extended, index: header.index,
                            isRandomAccess: header.isRandomAccess)
    }

    /// Wraps one raw AAC access unit in an `EncodedFrame`.
    private func makeFrame(_ bytes: Data, pts: Int64, isKeyframe: Bool,
                           at now: MediaInstant) -> EncodedFrame {
        EncodedFrame(data: Data(bytes),
                     codec: .audio(.aac),
                     pts: MediaTimestamp(value: pts, timescale: clockRate),
                     duration: MediaTimestamp(value: Int64(format.framesPerPacket),
                                              timescale: clockRate),
                     receivedAt: now,
                     isKeyframe: isKeyframe,
                     audioFormat: format)
    }

    /// Skips the optional auxiliary-data section, returning the offset of the AU data.
    private func skipAuxiliaryData(_ payload: Data, from offset: Int) -> Int? {
        guard layout.auxiliaryDataSizeLength > 0 else { return offset }
        let sizeBytes = (layout.auxiliaryDataSizeLength + 7) / 8
        guard offset + sizeBytes <= payload.count else { return nil }
        var reader = BitReader([UInt8](payload.slice(offset..<(offset + sizeBytes))))
        guard let size = read(&reader, layout.auxiliaryDataSizeLength) else { return nil }
        let next = offset + sizeBytes + size
        return next <= payload.count ? next : nil
    }

    /// Reads `bits` bits, or returns `nil` when the section ran out.
    private func read(_ reader: inout BitReader, _ bits: Int) -> Int? {
        guard bits > 0, let value = try? reader.u(bits) else { return bits == 0 ? 0 : nil }
        return Int(value)
    }

    /// Parses a decimal fmtp value, tolerating surrounding whitespace.
    private static func integer(_ fmtp: [String: String], _ key: String) -> Int? {
        guard let raw = fmtp[key]?.trimmingCharacters(in: .whitespaces) else { return nil }
        return Int(raw)
    }

    /// Emits a malformed-input event, rate limited to once per five seconds per reason.
    private mutating func report(_ reason: MalformedReason, at now: MediaInstant,
                                 into out: inout DepacketizerOutput) {
        if limiter.admit(reason.limiterKey, at: now) { out.events.append(.malformed(reason)) }
    }
}
