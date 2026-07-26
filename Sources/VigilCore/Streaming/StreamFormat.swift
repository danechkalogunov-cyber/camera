//
//  StreamFormat.swift
//  VigilCore
//
//  What the negotiated stream turned out to be: the answer the UI shows and the decode pipeline is
//  configured from.
//  Implements docs/spec-core.md §7.1 and docs/API_CONTRACT.md §4.8 (`StreamFormat`).
//
//  Deviation from spec-core §7.1, deliberate: `resolution` and `declaredFPS` are **optional** here.
//  A Hikvision SDP frequently carries neither `a=x-dimensions` nor `a=framerate`, and the truth
//  only arrives with the first SPS. Publishing `1920×1080` or `0 fps` as a placeholder would put a
//  number on screen that the UI cannot distinguish from a measured one. The audio fields of the
//  contract's shape are absent because the slice never sets up an audio track (.vigil/SLICE.md).
//

#if os(macOS)

import Foundation
import VigilProtocols
import VigilRTSP

/// The negotiated shape of one live stream.
public struct StreamFormat: Sendable, Hashable {

    /// The video codec the SDP offered and Vigil accepted.
    public var videoCodec: VideoCodec

    /// Picture size, when the SDP hinted it. `nil` until the bitstream says otherwise — the SPS is
    /// authoritative and `VigilVideo` publishes it.
    public var resolution: Resolution?

    /// The frame rate the SDP declared, when it declared one. Never a measurement.
    public var declaredFPS: Double?

    /// Parameter sets from `sprop-*`, when the SDP carried them. Legitimately `nil`: Hikvision
    /// repeats SPS/PPS in band before every IDR, so decoding starts fine without these.
    public var parameterSets: ParameterSets?

    /// Which encoder this came from.
    public var quality: StreamQuality

    /// The transport actually negotiated, which may differ from the one that was requested.
    public var transport: RTSPTransportKind

    /// The RTSP path that won, so the diagnostics bundle records what actually worked.
    public var path: String

    /// The RTP clock rate in Hz, from the SDP. 90 000 for every video profile seen in the field.
    public var clockRate: UInt32

    /// Builds a format.
    public init(videoCodec: VideoCodec,
                resolution: Resolution? = nil,
                declaredFPS: Double? = nil,
                parameterSets: ParameterSets? = nil,
                quality: StreamQuality,
                transport: RTSPTransportKind,
                path: String,
                clockRate: UInt32) {
        self.videoCodec = videoCodec
        self.resolution = resolution
        self.declaredFPS = declaredFPS
        self.parameterSets = parameterSets
        self.quality = quality
        self.transport = transport
        self.path = path
        self.clockRate = clockRate
    }

    /// Builds a format from a negotiated video track, or returns `nil` when the track carries a
    /// codec that is not video — which the session machine has already refused, so this is a
    /// belt-and-braces guard rather than a path we expect to take.
    public init?(track: RTSPTrack,
                 quality: StreamQuality,
                 transport: RTSPTransportKind,
                 path: String) {
        guard let codec = track.codec?.video else { return nil }
        self.init(videoCodec: codec,
                  resolution: track.hintedDimensions,
                  declaredFPS: track.hintedFramerate,
                  parameterSets: track.parameterSets,
                  quality: quality,
                  transport: transport,
                  path: path,
                  clockRate: track.clockRate)
    }

    /// A one-line description for the status line: `H.265 · 1920×1080 · main`.
    public var summary: String {
        let codecLabel = switch videoCodec {
        case .h264: "H.264"
        case .h265: "H.265"
        case .mjpeg: "MJPEG"
        }
        var parts: [String] = [codecLabel]
        if let resolution { parts.append(resolution.description) }
        if let declaredFPS, declaredFPS > 0 {
            parts.append("\(Int(declaredFPS.rounded())) fps")
        }
        parts.append(quality.stringValue)
        return parts.joined(separator: " · ")
    }
}

#endif
