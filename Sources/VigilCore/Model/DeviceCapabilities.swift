//
//  DeviceCapabilities.swift
//  VigilCore
//
//  What Vigil has learned about a device, and the one piece of it the first-light slice needs: the
//  RTSP path template that won the R1.2 probe ladder, persisted so the ladder never runs twice.
//  Implements docs/REQUIREMENTS-CUSTOMER.md §R1.2, docs/spec-core.md §4.3 and
//  docs/API_CONTRACT.md §5.12 (`Model/DeviceCapabilities.swift`).
//
//  Slice scope: `DeviceCapabilities` here carries only the fields the connect path reads. The full
//  type of spec-core §4.3 — channel descriptors, PTZ, storage volumes, codec matrices, quirks — is
//  additive on top of this declaration and lands with W4; every field below is decoded with a
//  default so adding the rest needs no migration.
//

#if os(macOS)

import Foundation
import VigilProtocols

// MARK: - RTSPPathTemplate

/// One firmware generation's RTSP path form.
///
/// The cases are exactly the ladder of customer requirement R1.2, in its order, and the raw values
/// are stable persistence keys — a template that has been learned for a device is written into
/// `library.json` and must survive a rename of the Swift case.
///
/// - Note: API_CONTRACT §2 R-23 makes `VigilISAPI.HikvisionURL` the single RTSP path builder and
///   requires it to expose `candidates(channel:quality:)`. `VigilISAPI` is a placeholder in this
///   slice, so the table lives here, in the module that composes the URL. When `HikvisionURL`
///   lands, this enum's `path(channel:quality:)` becomes a call into it and the strings move —
///   there must never be two implementations of this table.
public enum RTSPPathTemplate: String, Sendable, Hashable, Codable, CaseIterable {

    /// `/Streaming/Channels/{ch}0{q}` — current firmware, cameras and NVRs. Rung 1.
    case streamingChannelsWithQuality

    /// `/Streaming/Channels/{ch}` — some 5.x firmware. Rung 2.
    case streamingChannelsBare

    /// `/Streaming/tracks/{ch}01` — NVR playback-capable paths. Rung 3.
    case streamingTracks

    /// `/h264/ch{ch}/main|sub/av_stream` — legacy 4.x. Rung 4.
    case legacyH264

    /// `/mpeg4/ch{ch}/sub/av_stream` — legacy 4.x MPEG-4. Rung 5.
    case legacyMPEG4

    /// The stream URL came from ONVIF `GetStreamUri` rather than from a template. Rung 6.
    ///
    /// Renders no path of its own: the resolved absolute path is stored in
    /// `DeviceCapabilities.resolvedRTSPPath` instead, because ONVIF answers with a complete URL
    /// that need not follow any Hikvision form.
    case onvifStreamURI

    /// The path this template produces, or `nil` for `.onvifStreamURI`, which has no formula.
    ///
    /// `quality` selects the stream digit for the templates that carry one; `.legacyMPEG4` only
    /// ever addressed the sub-stream on the firmware that shipped it, so it ignores `quality` and
    /// always renders `sub`.
    public func path(channel: ChannelID, quality: StreamQuality) -> String? {
        let ch = channel.value
        switch self {
        case .streamingChannelsWithQuality:
            return "/Streaming/Channels/\(StreamingChannelID(channel: channel, quality: quality))"
        case .streamingChannelsBare:
            return "/Streaming/Channels/\(ch)"
        case .streamingTracks:
            return "/Streaming/tracks/\(ch)01"
        case .legacyH264:
            return "/h264/ch\(ch)/\(quality == .main ? "main" : "sub")/av_stream"
        case .legacyMPEG4:
            return "/mpeg4/ch\(ch)/sub/av_stream"
        case .onvifStreamURI:
            return nil
        }
    }
}

// MARK: - DeviceCapabilities

/// What a successful probe taught us about a device. `nil` on a `Camera` means "never probed".
///
/// Everything here is a cache of something the device told us, so it is always safe to discard: a
/// deleted capabilities record costs one probe, never a wrong answer.
public struct DeviceCapabilities: Sendable, Hashable, Codable {

    /// The path form that answered `DESCRIBE` with a usable SDP. Persisted so the R1.2 ladder runs
    /// **once per device, ever** — this field is the whole reason the type exists in this slice.
    public var rtspPathTemplate: RTSPPathTemplate?

    /// The absolute path the winning rung produced, verbatim.
    ///
    /// Kept alongside the template for two reasons: `.onvifStreamURI` has no formula, and a device
    /// whose channel numbering surprises us is still reachable by replaying the exact path that
    /// worked. The template is authoritative when both are present and agree.
    public var resolvedRTSPPath: String?

    /// The video codec the winning SDP offered, when it named one Vigil can decode.
    public var videoCodec: VideoCodec?

    /// When these capabilities were learned. Used by "Re-probe device" to show staleness.
    public var probedAt: Date?

    /// Firmware version string as the device reported it, for the diagnostics bundle. Never parsed
    /// to gate behaviour — firmware workarounds go through `DeviceQuirks` and nowhere else
    /// (API_CONTRACT §2 R-27a).
    public var firmwareVersion: String?

    enum CodingKeys: String, CodingKey {
        case rtspPathTemplate, resolvedRTSPPath, videoCodec, probedAt, firmwareVersion
    }

    /// Builds a capabilities record. Every field is optional: a probe that learned only the path
    /// still produces a useful record.
    public init(rtspPathTemplate: RTSPPathTemplate? = nil,
                resolvedRTSPPath: String? = nil,
                videoCodec: VideoCodec? = nil,
                probedAt: Date? = nil,
                firmwareVersion: String? = nil) {
        self.rtspPathTemplate = rtspPathTemplate
        self.resolvedRTSPPath = resolvedRTSPPath
        self.videoCodec = videoCodec
        self.probedAt = probedAt
        self.firmwareVersion = firmwareVersion
    }

    /// Forgiving decode: an unknown template string decodes as "no template learned" rather than
    /// failing the whole document, because a library written by a newer build must still open.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawTemplate = try container.decodeIfPresent(String.self, forKey: .rtspPathTemplate)
        rtspPathTemplate = rawTemplate.flatMap(RTSPPathTemplate.init(rawValue:))
        resolvedRTSPPath = try container.decodeIfPresent(String.self, forKey: .resolvedRTSPPath)
        videoCodec = try container.decodeIfPresent(VideoCodec.self, forKey: .videoCodec)
        probedAt = try container.decodeIfPresent(Date.self, forKey: .probedAt)
        firmwareVersion = try container.decodeIfPresent(String.self, forKey: .firmwareVersion)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(rtspPathTemplate?.rawValue, forKey: .rtspPathTemplate)
        try container.encodeIfPresent(resolvedRTSPPath, forKey: .resolvedRTSPPath)
        try container.encodeIfPresent(videoCodec, forKey: .videoCodec)
        try container.encodeIfPresent(probedAt, forKey: .probedAt)
        try container.encodeIfPresent(firmwareVersion, forKey: .firmwareVersion)
    }
}

#endif
