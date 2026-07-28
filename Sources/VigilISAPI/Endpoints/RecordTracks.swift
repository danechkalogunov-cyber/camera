//
//  RecordTracks.swift
//  VigilISAPI
//
//  `GET /ISAPI/ContentMgmt/record/tracks`, the day index the playback timeline is painted from, and
//  the month-calendar accelerator. Implements docs/spec-isapi.md §15.1 and §15.5.
//
//  The `ContentMgmt` family is older than `/Streaming` and uses different casing —  `<Channel>`,
//  `<Enable>`, the `ver10` namespace. Reads are case-insensitive so that costs nothing; what does
//  matter is that a track is **not** a streaming channel even when the numbers coincide, which is
//  why `TrackID` is its own type and the mapping is discovered here rather than assumed.
//

import Foundation
import VigilProtocols

// MARK: - RecordTrack

/// One recording stream.
public struct RecordTrack: Sendable, Hashable, Codable, Identifiable {
    public let id: TrackID
    public let channel: ChannelID
    /// Only tracks with `Enable == true` are offered in the playback UI.
    public let enabled: Bool
    public let sourceName: String?
    /// `CMR` continuous, `EMR` event, `MMR` manual, `OMR` command.
    public let recordingMode: String?
    /// Retention in seconds, parsed from the ISO 8601 `<Duration>`.
    public let retention: Double?
    /// From `StreamHint`: tells the UI whether playback will have audio before it starts.
    public let hasAudio: Bool
    public let loopRecording: Bool

    public init(id: TrackID, channel: ChannelID, enabled: Bool, sourceName: String?,
                recordingMode: String?, retention: Double?, hasAudio: Bool,
                loopRecording: Bool) {
        self.id = id
        self.channel = channel
        self.enabled = enabled
        self.sourceName = sourceName
        self.recordingMode = recordingMode
        self.retention = retention
        self.hasAudio = hasAudio
        self.loopRecording = loopRecording
    }

    /// Decodes every `<Track>` in a `<TrackList>`.
    public static func list(document: ISAPIDocument) -> [RecordTrack] {
        document.nodes("Track[]").compactMap { node in
            guard let id = node["id"].int else { return nil }
            let hint = node["SrcDescriptor/StreamHint"].string ?? ""
            return RecordTrack(
                id: TrackID(id),
                channel: ChannelID(node["Channel"].int ?? id / 100),
                enabled: node["Enable"].bool ?? true,
                sourceName: node["SrcDescriptor/SrcName"].string,
                recordingMode: node["DefaultRecordingMode"].string,
                retention: ISO8601Duration.seconds(node["Duration"].string),
                hasAudio: hint.lowercased().contains("audio"),
                loopRecording: node["Loop"].bool ?? false)
        }
    }
}

// MARK: - ISO8601Duration

/// The `<Duration>` parser for retention periods.
///
/// A year is treated as 365 days and a month as 30 days. That approximation is fine because the
/// value is only ever displayed — the UI says "about 30 days" — and it is documented as such.
public enum ISO8601Duration {

    /// Parses `P<n>Y<n>M<n>DT<n>H<n>M<n>S` with any subset present. Returns `nil` for anything that
    /// is not a duration, including the empty string.
    public static func seconds(_ raw: String?) -> Double? {
        guard let raw, raw.hasPrefix("P") || raw.hasPrefix("p") else { return nil }
        var total: Double = 0
        var number: Double?
        var inTimePart = false
        var digits = ""
        var sawAnyComponent = false
        for character in raw.dropFirst() {
            if character.isNumber || character == "." {
                digits.append(character)
                continue
            }
            number = Double(digits)
            digits = ""
            switch character {
            case "T", "t":
                inTimePart = true
                number = nil
                continue
            default:
                break
            }
            guard let value = number else { continue }
            switch character {
            case "Y", "y": total += value * 365 * 86400
            case "W", "w": total += value * 7 * 86400
            case "D", "d": total += value * 86400
            case "H", "h": total += value * 3600
            case "S", "s": total += value
            case "M", "m": total += inTimePart ? value * 60 : value * 30 * 86400
            default: return nil
            }
            sawAnyComponent = true
            number = nil
        }
        return sawAnyComponent ? total : nil
    }
}

// MARK: - RecordDayIndex

/// One day's recording coverage for one track: the merged segments and a per-minute bin array.
public struct RecordDayIndex: Sendable, Hashable, Codable {
    public let track: TrackID
    /// Device-local midnight, expressed as an absolute instant.
    public let dayStartUTC: Date
    /// Adjacent segments of the same record type, merged.
    public let segments: [RecordSegment]
    /// 1440 entries, one per minute. `nil` means no footage in that minute.
    public let minuteBins: [RecordType?]
    /// True when the query hit its hard cap, so the day is incomplete.
    public let truncated: Bool

    public init(track: TrackID, dayStartUTC: Date, segments: [RecordSegment],
                minuteBins: [RecordType?], truncated: Bool) {
        self.track = track
        self.dayStartUTC = dayStartUTC
        self.segments = segments
        self.minuteBins = minuteBins
        self.truncated = truncated
    }

    /// Total recorded seconds across the merged segments.
    public var totalRecordedSeconds: Double { segments.reduce(0) { $0 + $1.duration } }

    /// 0…1, for the "12 h 04 m recorded" label.
    public var coverageFraction: Double {
        min(1, max(0, totalRecordedSeconds / 86400))
    }

    /// Builds the index from raw search results.
    ///
    /// Segments of the **same** record type separated by less than `mergeGapSeconds` are joined:
    /// devices split continuous recording into files and a timeline drawn from the raw segments is
    /// a picket fence. Segments of different types are never merged — the type is what the colour
    /// encodes.
    ///
    /// - Parameter mergeGapSeconds: 2.0 is the documented value; a 1.5 s gap merges and a 3 s gap
    ///   does not.
    public static func build(track: TrackID, dayStartUTC: Date, segments raw: [RecordSegment],
                             truncated: Bool, mergeGapSeconds: Double = 2.0) -> RecordDayIndex {
        let merged = merge(raw.sorted { $0.start < $1.start }, gap: mergeGapSeconds)
        var bins = [RecordType?](repeating: nil, count: 1440)
        for segment in merged {
            let startMinute = Int((segment.start.timeIntervalSince(dayStartUTC) / 60).rounded(.down))
            let endMinute = Int((segment.end.timeIntervalSince(dayStartUTC) / 60).rounded(.up))
            guard endMinute >= 0, startMinute < 1440 else { continue }
            for minute in max(0, startMinute)..<min(1440, max(endMinute, startMinute + 1)) {
                if let existing = bins[minute], existing.severity >= segment.recordType.severity {
                    continue
                }
                bins[minute] = segment.recordType
            }
        }
        return RecordDayIndex(track: track, dayStartUTC: dayStartUTC, segments: merged,
                              minuteBins: bins, truncated: truncated)
    }

    /// Merges adjacent same-type segments whose gap is under `gap`.
    static func merge(_ sorted: [RecordSegment], gap: Double) -> [RecordSegment] {
        var out: [RecordSegment] = []
        for segment in sorted {
            guard let previous = out.last,
                  previous.recordType == segment.recordType,
                  segment.start.timeIntervalSince(previous.end) < gap else {
                out.append(segment)
                continue
            }
            // The merged segment keeps the **first** locator: playback starts at the beginning of
            // the run, and the device plays through its own file boundaries without help.
            out[out.count - 1] = RecordSegment(track: previous.track,
                                               start: previous.start,
                                               end: max(previous.end, segment.end),
                                               codec: previous.codec,
                                               contentType: previous.contentType,
                                               recordType: previous.recordType,
                                               locator: previous.locator)
        }
        return out
    }
}

// MARK: - MonthRecordCalendar

/// Which days of a month have footage, for the month picker's dots.
public struct MonthRecordCalendar: Sendable, Hashable, Codable {

    /// What is known about one day.
    ///
    /// docs/API_CONTRACT.md §4.5 spells these `none` and `some`, which cannot be used inside the
    /// `[DayState?]` this type stores: `DayState.none` and `Optional.none` collide at every use
    /// site. Renamed, and reported as a defect in the contract.
    public enum DayState: Sendable, Hashable, Codable {
        /// Definitely no footage.
        case empty
        /// Footage, of these types.
        case recorded(Set<RecordType>)
    }

    public let year: Int
    public let month: Int
    public let track: TrackID
    /// Index 0 is day 1. `nil` means "not yet known" and renders as a hairline outline — never as
    /// "empty", because an unresolved day and an empty day are different facts.
    public let days: [DayState?]

    public init(year: Int, month: Int, track: TrackID, days: [DayState?]) {
        self.year = year
        self.month = month
        self.track = track
        self.days = days
    }

    /// Combines this month with another track's answer for the same month.
    ///
    /// **Why a camera needs this.** One camera routinely records to more than one track — 101 and
    /// 103 on the same channel, with the day split between them, is ordinary Hikvision behaviour.
    /// `dailyDistribution` answers per *track*, so asking only the first reports one track's month
    /// as the camera's month and greys out every day whose footage lives on the other.
    ///
    /// The rules follow from what each state means, not from convenience:
    ///
    /// - `recorded` beats everything, and the record types are **unioned** — footage on either
    ///   track is footage on that day, and a day that is motion on one and alarm on the other is
    ///   honestly both.
    /// - `empty` and `empty` is `empty`.
    /// - `nil` (the device did not mention the day) loses to any real answer, but `nil` combined
    ///   with `empty` stays `empty`: one track saying "nothing here" is a real fact about that
    ///   track, and a day is only genuinely unknown when no track answered for it.
    ///
    /// ⚠️ `track` and the year and month are taken from `self`. The result no longer describes a
    /// single track, which is exactly the point; the field is kept for the caller's diagnostics.
    /// Merging two different months would be a caller error, so it is refused rather than guessed
    /// at — mismatched inputs return `self` unchanged.
    ///
    /// - Parameter other: another track's answer, for the same year and month.
    /// - Returns: the combined month, as long as one day array.
    public func merging(_ other: MonthRecordCalendar) -> MonthRecordCalendar {
        guard year == other.year, month == other.month else { return self }
        let count = Swift.max(days.count, other.days.count)
        var combined: [DayState?] = []
        combined.reserveCapacity(count)
        for index in 0..<count {
            let mine = index < days.count ? days[index] : nil
            let theirs = index < other.days.count ? other.days[index] : nil
            combined.append(Self.merging(mine, theirs))
        }
        return MonthRecordCalendar(year: year, month: month, track: track, days: combined)
    }

    /// One day's rule. See ``merging(_:)``.
    static func merging(_ a: DayState?, _ b: DayState?) -> DayState? {
        switch (a, b) {
        case let (.recorded(mine), .recorded(theirs)): return .recorded(mine.union(theirs))
        case (.recorded, _):                           return a
        case (_, .recorded):                           return b
        case (.empty, _), (_, .empty):                 return .empty
        default:                                       return nil
        }
    }

    /// The `<trackDailyParam>` request body.
    public static func requestBody(track: TrackID, year: Int, month: Int) -> XMLBuilder {
        var builder = XMLBuilder("trackDailyParam")
        builder.add("year", year)
        builder.add("monthOfYear", month)
        builder.add("trackID", track.value)
        return builder
    }

    /// Decodes a `<trackDailyDistribution>` document.
    ///
    /// A day the device did not mention stays `nil`, which is the honest answer: the accelerator is
    /// allowed to be partial and the lazy per-day fallback fills the gaps in.
    public init(document: ISAPIDocument, track: TrackID, year: Int, month: Int) {
        var days = [DayState?](repeating: nil, count: 31)
        for node in document.nodes("dayList/day[]") {
            guard let day = node["dayOfMonth"].int ?? node["id"].int,
                  (1...31).contains(day) else { continue }
            guard node["record"].bool ?? false else {
                days[day - 1] = .empty
                continue
            }
            let types = (node["recordType"].string ?? "")
                .split(separator: ",")
                .map { RecordType(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased())
                        ?? .other }
            days[day - 1] = .recorded(types.isEmpty ? [.timing] : Set(types))
        }
        self.init(year: year, month: month, track: track, days: days)
    }
}
