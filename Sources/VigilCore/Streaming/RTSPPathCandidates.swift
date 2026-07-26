//
//  RTSPPathCandidates.swift
//  VigilCore
//
//  The R1.2 ladder as data: every RTSP path a Hikvision device might answer on, in the order the
//  customer requirement fixes.
//  Implements docs/REQUIREMENTS-CUSTOMER.md §R1.2 and docs/API_CONTRACT.md §2 R-23.
//
//  **The user is never asked for a stream URL.** That is the whole point of this file: the app
//  probes these itself, keeps the winner on the camera record, and never shows a path field.
//
//  Ownership note: R-23 assigns this table to `VigilISAPI.HikvisionURL.candidates(channel:quality:)`
//  and makes `VigilCore` compose the URL from the returned path strings. `VigilISAPI` is a
//  placeholder in this slice, so the table lives here — in the module that already composes the
//  URL — and moves wholesale when `HikvisionURL` lands. There must never be two copies of it.
//

#if os(macOS)

import Foundation
import VigilProtocols

// MARK: - RTSPPathCandidate

/// One rung of the ladder: a template, the absolute path it rendered, and where it sits in the
/// order.
public struct RTSPPathCandidate: Sendable, Hashable {

    /// The firmware generation this path belongs to.
    public var template: RTSPPathTemplate

    /// The absolute path, ready to go into an `RTSPURL`.
    public var path: String

    /// Position in the ladder, from zero. Lower wins: when two candidates in the same in-flight
    /// window both answer, the earlier rung is the one that gets persisted, because the ladder's
    /// order encodes which form is most likely to be the device's canonical one.
    public var order: Int

    /// Builds a candidate.
    public init(template: RTSPPathTemplate, path: String, order: Int) {
        self.template = template
        self.path = path
        self.order = order
    }

    /// The capabilities record this candidate becomes once it wins, so the ladder never runs for
    /// this device again (R1.2: "the probe happens exactly once per device, ever").
    public func capabilities(videoCodec: VideoCodec?, probedAt: Date) -> DeviceCapabilities {
        DeviceCapabilities(rtspPathTemplate: template,
                           resolvedRTSPPath: path,
                           videoCodec: videoCodec,
                           probedAt: probedAt)
    }
}

// MARK: - The ladder

public extension RTSPPathCandidate {

    /// The candidates to try, in R1.2's order.
    ///
    /// Rung 6 of the requirement — ONVIF `GetStreamUri` — is **not** here: it is not a path
    /// template but a different protocol, and it belongs to the ONVIF fallback rather than to the
    /// `DESCRIBE` ladder. A device that exhausts this list is the one that gets offered that path.
    ///
    /// - Parameters:
    ///   - channel: the device video input, 1-based.
    ///   - quality: which encoder to ask for. Selects the stream digit on the templates that carry
    ///     one and `main`/`sub` on the legacy H.264 form.
    ///   - preferring: a template that is already known to work for this device — the record's
    ///     learned value, or the one the user re-probed from. Hoisted to the front rather than
    ///     added, so a re-probe confirms the known answer in one round trip instead of six.
    /// - Returns: candidates in probe order, each with a distinct path. Duplicate renderings
    ///   (channel 1 sub renders `/Streaming/Channels/102` and nothing else does) are removed, so
    ///   the ladder never spends an in-flight slot on a path it has already tried.
    static func ladder(channel: ChannelID,
                       quality: StreamQuality,
                       preferring known: RTSPPathTemplate? = nil) -> [RTSPPathCandidate] {
        var templates: [RTSPPathTemplate] = [
            .streamingChannelsWithQuality,
            .streamingChannelsBare,
            .streamingTracks,
            .legacyH264,
            .legacyMPEG4,
        ]
        if let known, let index = templates.firstIndex(of: known) {
            templates.remove(at: index)
            templates.insert(known, at: 0)
        }

        var seen: Set<String> = []
        var out: [RTSPPathCandidate] = []
        for template in templates {
            guard let path = template.path(channel: channel, quality: quality) else { continue }
            guard seen.insert(path).inserted else { continue }
            out.append(RTSPPathCandidate(template: template, path: path, order: out.count))
        }
        return out
    }

    /// The candidate for a path the user typed into `Camera.rtspPathOverride`.
    ///
    /// It is not part of the ladder — an override is honoured, not probed against alternatives —
    /// but it is carried in the same shape so the connect path has one type to reason about.
    static func override(_ path: String) -> RTSPPathCandidate {
        let absolute = path.hasPrefix("/") ? path : "/" + path
        return RTSPPathCandidate(template: .streamingChannelsWithQuality, path: absolute, order: 0)
    }
}

#endif
