//
//  PCMDepacketizer.swift
//  VigilRTP
//
//  G.711 (PCMA / PCMU) and G.726-32 depacketization. Every packet is one complete, independently
//  decodable buffer, so there is no reassembly here — only companding, which happens in the pure
//  layer so `VigilVideo` never receives a compressed G.711 payload.
//  See docs/spec-rtp.md §9 and docs/API_CONTRACT.md §4.4.
//

import Foundation

import VigilProtocols

// MARK: - PCMDepacketizer

/// Turns a G.711 or G.726 payload into linear PCM.
///
/// The marker bit is ignored outright: there are no access units to delimit, and talk-back streams
/// set it on the first packet after silence, which means nothing to a receiver.
public struct PCMDepacketizer: Depacketizer {

    // MARK: - Nested Types

    /// The wire format this track carries.
    public enum Source: Sendable, Hashable {
        /// A-law, `PCMA`, static payload type 8.
        case g711A
        /// µ-law, `PCMU`, static payload type 0.
        case g711U
        /// G.726 at 32 kbit/s, in one of its two in-octet codeword orders.
        case g726_32(packing: G726.Packing)

        /// The wire codec, for `AudioFormatInfo` reporting.
        var wireCodec: AudioCodec {
            switch self {
            case .g711A: .g711A
            case .g711U: .g711U
            case .g726_32: .g726
            }
        }

        /// Linear samples produced per payload byte.
        var samplesPerByte: Int {
            if case .g726_32 = self { 2 } else { 1 }
        }
    }

    // MARK: - Stored Properties

    /// Always `.audio(.pcmS16LE)`: this depacketizer emits decoded linear PCM, never the wire form.
    public let codec: MediaCodec = .audio(.pcmS16LE)

    /// RTP clock rate, 8 000 for every G.711 and G.726 profile Hikvision offers.
    public let clockRate: Int32

    /// The format handed to the audio output.
    public private(set) var format: AudioFormatInfo

    /// The wire format being decoded.
    public let source: Source

    private var g726 = G726.DecoderState()
    private var timestamps = RTPTimestampExtender()
    private var limiter = EventRateLimiter()
    private var announcedFormat = false

    // MARK: - Initialisation

    /// Creates a depacketizer for one G.711 or G.726 track.
    ///
    /// - Parameters:
    ///   - source: the wire format, resolved from the SDP encoding name.
    ///   - clockRate: from `a=rtpmap`, or 8 000 for the static payload types.
    ///   - channels: from `a=rtpmap`; these codecs are mono in every Hikvision profile.
    /// - Throws: `RTPError.invalidClockRate` for a non-positive rate.
    public init(source: Source, clockRate: Int32 = 8000, channels: Int32 = 1) throws(RTPError) {
        guard clockRate > 0 else { throw .invalidClockRate(clockRate) }
        self.source = source
        self.clockRate = clockRate
        self.format = AudioFormatInfo(codec: .pcmS16LE,
                                      sampleRate: clockRate,
                                      channels: max(1, channels),
                                      framesPerPacket: 1)
    }

    /// Resolves an SDP encoding name to a source, case-insensitively.
    ///
    /// - Returns: `nil` for an encoding this depacketizer does not handle.
    public static func source(forEncodingName name: String) -> Source? {
        switch name.lowercased() {
        case "pcma": .g711A
        case "pcmu": .g711U
        case "g726-32", "g726": .g726_32(packing: .rfc3551)
        case "aal2-g726-32": .g726_32(packing: .aal2)
        default: nil
        }
    }

    // MARK: - Public API

    /// The wire codec, before pure-layer decoding. Diagnostic only.
    public var wireCodec: AudioCodec { source.wireCodec }

    /// Consume one RTP packet. See `Depacketizer.push(_:at:)`.
    public mutating func push(_ packet: RTPPacket, at now: MediaInstant) -> DepacketizerOutput {
        var out = DepacketizerOutput()
        if !announcedFormat {
            announcedFormat = true
            out.events.append(.audioConfigChanged(format))
        }
        guard !packet.payload.isEmpty else {
            if limiter.admit(MalformedReason.emptyPayload.limiterKey, at: now) {
                out.events.append(.malformed(.emptyPayload))
            }
            return out
        }
        let pcm: Data = switch source {
        case .g711A: G711.decode(packet.payload, law: .aLaw)
        case .g711U: G711.decode(packet.payload, law: .muLaw)
        case .g726_32(let packing): G726.decode32k(packet.payload, state: &g726, packing: packing)
        }
        let frames = packet.payload.count * source.samplesPerByte
        let (value, _) = timestamps.extend(packet.timestamp)
        out.frames.append(EncodedFrame(data: pcm,
                                       codec: .audio(.pcmS16LE),
                                       pts: MediaTimestamp(value: value, timescale: clockRate),
                                       duration: MediaTimestamp(value: Int64(frames),
                                                                timescale: clockRate),
                                       receivedAt: now,
                                       isKeyframe: true,
                                       audioFormat: format))
        return out
    }

    /// Nothing is ever held back, so there is nothing to flush.
    public mutating func flush(at now: MediaInstant) -> [EncodedFrame] { [] }

    /// Full state reset. Resetting the G.726 predictor mid-stream is audible, so this is only for
    /// an SSRC change or a reconnect.
    public mutating func reset() {
        g726 = G726.DecoderState()
        timestamps.reset()
        limiter.reset()
        announcedFormat = false
    }
}
