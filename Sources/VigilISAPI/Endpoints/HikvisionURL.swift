//
//  HikvisionURL.swift
//  VigilISAPI
//
//  The single Hikvision path builder: live RTSP paths, the R1.2 probe ladder, playback track paths
//  and the JPEG snapshot resource.
//  Implements docs/spec-isapi.md §12.4, docs/REQUIREMENTS-CUSTOMER.md R1.2 and
//  docs/API_CONTRACT.md §2 R-23 and R-69.
//
//  **Paths, never URLs** (R-69): `VigilCore` composes an `RTSPURL` from what this returns, because
//  `VigilRTSP` has no dependency edge to `VigilISAPI` and must not gain one. Credentials are never
//  embedded in an RTSP URL — `rtsp://user:pass@host/…` leaks into logs and crash reports, and
//  `VigilRTSP` authenticates with Digest instead.
//

import Foundation
import VigilProtocols

// MARK: - Candidate

/// One rung of the R1.2 probe ladder: which firmware generation's form it is, the path it rendered,
/// and where it sits in the order.
public struct RTSPPathCandidate: Sendable, Hashable, Codable {

    /// The firmware generation a path form belongs to.
    public enum Family: String, Sendable, Hashable, Codable, CaseIterable {
        /// `/Streaming/Channels/101` — current firmware, cameras and NVRs. Rung 1.
        case channelsCompact
        /// `/Streaming/Channels/1` — some 5.x firmware. Rung 2.
        case channelsBare
        /// `/Streaming/tracks/101` — NVR playback-capable paths. Rung 3.
        case tracks
        /// `/h264/ch1/main/av_stream` — legacy 4.x. Rung 4.
        case legacyH264
        /// `/mpeg4/ch1/sub/av_stream` — legacy 4.x MPEG-4. Rung 5.
        case legacyMPEG4
        /// Ask ONVIF `GetStreamUri`. Rung 6, and **not a path**: a different protocol, carried in
        /// the ladder so the caller knows the ladder is exhausted rather than empty.
        case onvifGetStreamURI
    }

    /// Which form this candidate is.
    public var family: Family

    /// The absolute path, ready to become an `RTSPURL`. Empty for `.onvifGetStreamURI`.
    public var path: String

    /// Position in the ladder, from zero. Lower wins when two candidates answer in the same
    /// in-flight window, because the order encodes which form is most likely canonical.
    public var order: Int

    /// Builds a candidate.
    public init(family: Family, path: String, order: Int) {
        self.family = family
        self.path = path
        self.order = order
    }

    /// True for the ONVIF rung, which carries no path and is answered by a different protocol.
    public var isProtocolFallback: Bool { family == .onvifGetStreamURI }
}

// MARK: - HikvisionURL

/// Every Hikvision path Vigil builds, in one place.
///
/// One implementation, by ruling R-23: `spec-rtsp.md` §10's table is documentation of the wire
/// formats, and `VigilDiscovery`'s vendor map is for fingerprinting only and must never build a
/// stream path.
public enum HikvisionURL {

    // MARK: Live

    /// The canonical live path for a streaming channel: `/Streaming/Channels/101`.
    ///
    /// Capitalised deliberately: `/streaming/channels/101` works on 5.5+ and 404s on 5.2.x, so the
    /// capitalised spelling is the only one Vigil emits.
    public static func livePath(_ id: StreamingChannelID) -> String {
        "/Streaming/Channels/\(id.value)"
    }

    /// The bare-channel live path some 5.x firmware requires: `/Streaming/Channels/1`.
    ///
    /// Rung 2 of the ladder, and the form `DeviceQuirks.streamingChannelIDIsSingleDigit` selects
    /// once a device has been observed to need it.
    public static func bareLivePath(channel: ChannelID) -> String {
        "/Streaming/Channels/\(channel.value)"
    }

    // MARK: Playback

    /// The playback path for a track: `/Streaming/tracks/101`.
    public static func playbackPath(_ track: TrackID) -> String {
        "/Streaming/tracks/\(track.value)"
    }

    /// The playback path with a time window: `/Streaming/tracks/101?starttime=…&endtime=…`.
    ///
    /// Times are emitted in the compact UTC form (`20240501T043456Z`) because that is the only form
    /// every firmware's playback parser accepts. A device known to read them as local time
    /// (`DeviceQuirks.playbackTimesAreDeviceLocal`) is corrected by the caller before it gets here:
    /// this function formats, it does not decide what instant to ask for.
    public static func playbackPath(_ track: TrackID, from start: Date, to end: Date?) -> String {
        var query = "?starttime=\(ISAPITime.compactUTC(start))"
        if let end { query += "&endtime=\(ISAPITime.compactUTC(end))" }
        return playbackPath(track) + query
    }

    // MARK: ISAPI resources

    /// The JPEG snapshot resource, written **without** the `/ISAPI` prefix:
    /// `/Streaming/channels/102/picture`.
    ///
    /// Lower-case `channels` here, unlike the RTSP path: the ISAPI tree and the RTSP tree spell it
    /// differently and both spellings are load-bearing on some firmware.
    public static func snapshotPath(_ id: StreamingChannelID) -> String {
        "/Streaming/channels/\(id.value)/picture"
    }

    /// The streaming-channel configuration resource: `/Streaming/channels/101`.
    public static func streamingChannelPath(_ id: StreamingChannelID) -> String {
        "/Streaming/channels/\(id.value)"
    }

    // MARK: The ladder

    /// The R1.2 probe ladder for one channel and quality, in the required order.
    ///
    /// The app **never asks the user for a stream path**: it probes these itself, keeps the winner
    /// on the camera record, and never shows a path field. Duplicate renderings are removed so the
    /// ladder never spends an in-flight probe slot on a path it already tried.
    ///
    /// - Parameters:
    ///   - channel: the device video input, 1-based.
    ///   - quality: which encoder to ask for. Selects the stream digit on the forms that carry one
    ///     and `main`/`sub` on the legacy H.264 form.
    ///   - preferring: a family already known to work for this device — the record's learned value.
    ///     Hoisted to the front rather than added, so a re-probe confirms the known answer in one
    ///     round trip instead of six.
    /// - Returns: the candidates in probe order, each with a distinct path, ending with the ONVIF
    ///   marker. `DESCRIBE` answering 401 means the *path* is right and the credential needs
    ///   applying — the caller must not advance the ladder on 401 (R1.2).
    public static func candidates(channel: ChannelID, quality: StreamQuality,
                                  preferring: RTSPPathCandidate.Family? = nil)
        -> [RTSPPathCandidate] {
        var families: [RTSPPathCandidate.Family] = [
            .channelsCompact, .channelsBare, .tracks, .legacyH264, .legacyMPEG4, .onvifGetStreamURI,
        ]
        if let preferring, let index = families.firstIndex(of: preferring), preferring != .onvifGetStreamURI {
            families.remove(at: index)
            families.insert(preferring, at: 0)
        }

        var seen: Set<String> = []
        var out: [RTSPPathCandidate] = []
        for family in families {
            let path = path(family: family, channel: channel, quality: quality)
            if !path.isEmpty, !seen.insert(path).inserted { continue }
            out.append(RTSPPathCandidate(family: family, path: path, order: out.count))
        }
        return out
    }

    /// The path one family renders for a channel and quality; empty for the ONVIF rung.
    ///
    /// `.legacyMPEG4` ignores `quality`: the firmware that shipped it only ever exposed the
    /// sub-stream on that form, so rendering a `main` variant would probe a path that has never
    /// existed.
    public static func path(family: RTSPPathCandidate.Family,
                            channel: ChannelID, quality: StreamQuality) -> String {
        switch family {
        case .channelsCompact:
            return livePath(StreamingChannelID(channel: channel, quality: quality))
        case .channelsBare:
            return bareLivePath(channel: channel)
        case .tracks:
            return "/Streaming/tracks/\(channel.value)01"
        case .legacyH264:
            return "/h264/ch\(channel.value)/\(quality == .main ? "main" : "sub")/av_stream"
        case .legacyMPEG4:
            return "/mpeg4/ch\(channel.value)/sub/av_stream"
        case .onvifGetStreamURI:
            return ""
        }
    }
}
