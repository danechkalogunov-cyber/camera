//
//  RecordSearch.swift
//  VigilISAPI
//
//  `POST /ISAPI/ContentMgmt/search`: the only source of the playback timeline. The
//  `CMSearchDescription` body in its mandatory element order, the `CMSearchResult` reader, and the
//  paging cursor with the misspelling the wire really uses.
//  Implements docs/spec-isapi.md §15.2 and docs/API_CONTRACT.md §2 R-29.
//
//  Three details are load-bearing:
//
//  * **`searchResultPostion`** — not `Position`. That is the device's spelling and it is the paging
//    cursor; the correctly-spelled element is silently ignored, so paging appears to work and every
//    page returns the first forty segments.
//  * **One `searchID` across all pages.** The device keys its result cursor by it. A fresh id per
//    page breaks paging; reusing a finished search's id returns stale results.
//  * **Element order is mandatory** — 5.4.x DVRs answer `invalidXMLContent` to a reordered
//    document, and no namespace may be added to this body.
//

import Foundation
import VigilProtocols

// MARK: - RecordType

/// Why a recorded segment exists. Drives the timeline's colours.
public enum RecordType: String, Sendable, Hashable, Codable, CaseIterable {
    case timing, motion, alarm, manual, command, other

    /// The `metadataDescriptor` suffix that filters for this type, or `nil` for `other`.
    var descriptorSuffix: String? {
        switch self {
        case .timing: "timing"
        case .motion: "motion"
        case .alarm: "alarm"
        case .manual: "manual"
        case .command: "command"
        case .other: nil
        }
    }

    /// Which type wins when two share a timeline minute: `alarm > motion > manual > command >
    /// timing`. `other` sorts lowest so an unrecognised type never masks a real alarm.
    public var severity: Int {
        switch self {
        case .alarm: 5
        case .motion: 4
        case .manual: 3
        case .command: 2
        case .timing: 1
        case .other: 0
        }
    }

    /// Reads a `metadataMatches/metadataDescriptor`. The response omits the leading `//` that the
    /// request carries, so matching is on the trailing path component.
    public init(descriptor raw: String) {
        let tail = raw.split(separator: "/").last.map(String.init) ?? raw
        self = RecordType(rawValue: tail.lowercased()) ?? .other
    }
}

// MARK: - RecordSearchQuery

/// One logical search: one track, one time span, paged internally.
public struct RecordSearchQuery: Sendable, Hashable {
    public var track: TrackID
    public var start: Date
    public var end: Date
    /// Empty means all types. A filtered search that answers `badParameters` is retried unfiltered
    /// and filtered client-side (`DeviceQuirks.recordTypeFilterUnsupported`).
    public var recordTypes: Set<RecordType>
    /// The device maximum is nominally 50; 40 is used because values above 50 draw
    /// `badParameters` on several firmwares and 50 itself is unreliable on 5.4.x DVRs.
    public var pageSize: Int
    /// Safety valve. A query that would return more than this stops and reports itself truncated.
    ///
    /// ⚠️ Raised from 2 000 to 20 000. Two thousand sounds generous and is not: a camera recording
    /// continuously writes one file every few seconds to a minute, and record types do not merge
    /// across a type change — so a single day of mixed timing-plus-motion recording passes 2 000
    /// segments before lunchtime. The day then arrived truncated, showing footage up to some
    /// arbitrary morning hour and nothing after it, which reads as "the camera stopped recording"
    /// rather than "Vigil stopped asking".
    ///
    /// Raising it costs nothing on a quiet camera: the pager stops as soon as the device says it
    /// has no more matches, so the cap is only ever reached by days that genuinely hold that much.
    public var hardSegmentCap: Int

    public init(track: TrackID, start: Date, end: Date, recordTypes: Set<RecordType> = [],
                pageSize: Int = 40, hardSegmentCap: Int = 20_000) {
        self.track = track
        self.start = start
        self.end = end
        self.recordTypes = recordTypes
        self.pageSize = min(50, max(1, pageSize))
        self.hardSegmentCap = max(1, hardSegmentCap)
    }
}

// MARK: - RecordSegment

/// One recorded segment.
public struct RecordSegment: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(track.value)-\(Int(start.timeIntervalSince1970))" }

    public let track: TrackID
    public let start: Date
    public let end: Date
    public let codec: VideoCodecWire
    /// `video`, `audio` or `metadata`.
    public let contentType: String
    public let recordType: RecordType
    public let locator: PlaybackLocator

    public init(track: TrackID, start: Date, end: Date, codec: VideoCodecWire,
                contentType: String, recordType: RecordType, locator: PlaybackLocator) {
        self.track = track
        self.start = start
        self.end = end
        self.codec = codec
        self.contentType = contentType
        self.recordType = recordType
        self.locator = locator
    }

    public var duration: Double { end.timeIntervalSince(start) }
}

// MARK: - CMSearchDescription

/// The search request body.
public enum CMSearchDescription {

    /// The generic descriptor: every record type. Vigil's default.
    public static let allRecordTypes = "//recordType.meta.std-cgi.com"

    /// Builds the `<CMSearchDescription>` body.
    ///
    /// Element order is exactly the order in docs/spec-isapi.md §15.2 and must not change. No
    /// namespace and no `version` attribute: verified accepted on 5.2.x through 6.x, and a
    /// namespace on this particular body has been observed to draw `invalidXMLFormat`.
    ///
    /// - Parameters:
    ///   - searchID: the same id for every page of one logical search.
    ///   - position: the zero-based offset of the first result wanted — the paging cursor, spelled
    ///     `searchResultPostion` on the wire.
    ///   - filtered: `false` to send the generic descriptor even when the query names record
    ///     types, for the firmwares that reject a filtered one.
    public static func body(_ query: RecordSearchQuery, searchID: String, position: Int,
                            filtered: Bool = true) -> XMLBuilder {
        var builder = XMLBuilder("CMSearchDescription")
        builder.add("searchID", searchID)
        builder.addChild("trackIDList") { list in
            // One track per request. Multi-track search works but interleaves results, which makes
            // paging and the timeline arithmetic much harder for no user-visible gain.
            list.add("trackID", query.track.value)
        }
        builder.addChild("timeSpanList") { list in
            list.addChild("timeSpan") { span in
                // UTC with a `Z`. A naive local time is interpreted in device time and is a
                // reliable source of "playback is an hour out" reports.
                span.add("startTime", ISAPITime.iso8601UTC(query.start))
                span.add("endTime", ISAPITime.iso8601UTC(query.end))
            }
        }
        builder.addChild("contentTypeList") { list in
            list.add("contentType", "video")
        }
        builder.add("maxResults", query.pageSize)
        builder.add("searchResultPostion", position)
        builder.addChild("metadataList") { list in
            for descriptor in descriptors(for: query, filtered: filtered) {
                list.add("metadataDescriptor", descriptor)
            }
        }
        return builder
    }

    /// The descriptors to send. Always at least one: omitting `metadataList` returns nothing at all
    /// on some DVRs.
    static func descriptors(for query: RecordSearchQuery, filtered: Bool) -> [String] {
        guard filtered, !query.recordTypes.isEmpty else { return [allRecordTypes] }
        let suffixes = query.recordTypes
            .compactMap(\.descriptorSuffix)
            .sorted()   // deterministic body bytes: a `Set` has no order and the tests assert bytes
        guard !suffixes.isEmpty else { return [allRecordTypes] }
        return suffixes.map { "\(allRecordTypes)/\($0)" }
    }

    /// A fresh search id: an upper-case braced GUID, `{8-4-4-4-12}`.
    ///
    /// Randomness is injected so the emitted body is reproducible from a seed — the paging tests
    /// assert that every page carried the *same* id, which needs the id to be predictable.
    public static func searchID(from random: inout some RandomSource) -> String {
        let hex = random.hexString(count: 32).uppercased()
        let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
        let characters = Array(hex)
        let parts = groups.map { String(characters[$0]) }
        return "{\(parts.joined(separator: "-"))}"
    }
}

// MARK: - CMSearchResult

/// One page of search results.
public struct CMSearchResult: Sendable, Hashable {

    /// The paging signal from `responseStatusStrip`.
    public enum Strip: Sendable, Hashable {
        /// This is the last page.
        case ok
        /// Call again with `position + numOfMatches`.
        case more
        /// The result set is empty. A success, never an error.
        case noMatches
        /// Anything else, kept verbatim so a new firmware value reaches diagnostics.
        case unknown(String)

        init(raw: String?) {
            switch ISAPIVocabulary.normalize(raw ?? "") {
            case "ok": self = .ok
            case "more": self = .more
            case "nomatches", "nomatch": self = .noMatches
            case "": self = .ok
            default: self = .unknown(raw ?? "")
            }
        }
    }

    public let searchID: String?
    public let strip: Strip
    /// The number of items **in this page**.
    public let numberOfMatches: Int
    public let segments: [RecordSegment]

    public init(searchID: String?, strip: Strip, numberOfMatches: Int,
                segments: [RecordSegment]) {
        self.searchID = searchID
        self.strip = strip
        self.numberOfMatches = numberOfMatches
        self.segments = segments
    }

    /// Decodes a `<CMSearchResult>` document.
    ///
    /// An item without a usable `<timeSpan>` or `playbackURI` is skipped rather than failing the
    /// page: one unplayable segment must not blank a day's timeline.
    public init(document: ISAPIDocument, track: TrackID) {
        let items = document.nodes("matchList/searchMatchItem[]")
        let segments = items.compactMap { item -> RecordSegment? in
            guard let start = item["timeSpan/startTime"].date,
                  let end = item["timeSpan/endTime"].date else { return nil }
            let descriptor = item.node("mediaSegmentDescriptor")
            let uri = descriptor?["playbackURI"].string ?? ""
            guard let locator = PlaybackLocator(playbackURI: uri,
                                                fallbackStart: start,
                                                fallbackEnd: end) else { return nil }
            let itemTrack = item["trackID"].int.map { TrackID($0) } ?? track
            let recordType = item["metadataMatches/metadataDescriptor"].string
                .map { RecordType(descriptor: $0) } ?? .other
            return RecordSegment(track: itemTrack,
                                 start: start,
                                 end: end,
                                 codec: VideoCodecWire(raw: descriptor?["codecType"].string ?? ""),
                                 contentType: descriptor?["contentType"].string ?? "video",
                                 recordType: recordType,
                                 locator: locator)
        }
        // ⛔ BOTH spellings. Hikvision's own schema says `responseStatusStrip`, and that is what
        // docs/spec-isapi.md §15.2 documents — but a great many shipping firmwares emit
        // `responseStatusStrp`, without the second `i`. Reading only the documented spelling gets
        // `nil` from those devices, which `Strip(raw:)` resolves to `.ok`, which ends paging after
        // the very first page. The result is a timeline holding one page of segments and nothing
        // else, on every day, which is indistinguishable from a camera that barely records.
        let strip = document["responseStatusStrip"].string ?? document["responseStatusStrp"].string
        self.init(searchID: document["searchID"].string,
                  strip: Strip(raw: strip),
                  // `numOfMatches` is the count in this page and is what the cursor advances by.
                  // Falling back to the decoded count would silently stall paging on a firmware
                  // that omits it, so the *item* count is used, not the segment count.
                  numberOfMatches: document["numOfMatches"].int ?? items.count,
                  segments: segments)
    }
}

// MARK: - Paging

/// The paging cursor. A plain struct so the loop is testable without a network.
public struct RecordSearchPager: Sendable {
    public let query: RecordSearchQuery
    public let searchID: String
    /// The next `searchResultPostion` to send.
    public private(set) var position: Int = 0
    public private(set) var segments: [RecordSegment] = []
    /// True when the hard cap stopped the search before the device ran out of results.
    public private(set) var truncated = false
    public private(set) var isFinished = false
    /// How many pages were requested. Asserted by the paging tests.
    public private(set) var pageCount = 0

    public init(query: RecordSearchQuery, searchID: String) {
        self.query = query
        self.searchID = searchID
    }

    /// The body for the next page.
    public func nextBody(filtered: Bool = true) -> XMLBuilder {
        CMSearchDescription.body(query, searchID: searchID, position: position, filtered: filtered)
    }

    /// Absorbs one page and decides whether to ask for another.
    ///
    /// `MORE` continues, `NO MATCHES` stops, and a page reporting zero matches always stops —
    /// advancing the cursor by zero would ask the same question for ever.
    ///
    /// ⛔ **A full page continues too, whatever the status element said.** This is the belt to the
    /// spelling fix's braces in ``CMSearchResult/init(document:track:)``, and it is what makes the
    /// pager robust rather than merely fixed for one typo: a device that returns exactly
    /// `maxResults` items has, in every firmware anyone has observed, got more to give. Trusting
    /// the status element alone meant that any device which omitted it, misspelled it, or wrote a
    /// value we do not recognise silently produced a one-page day — a timeline holding forty
    /// segments and nothing else, which reads as a camera that hardly records rather than as a
    /// search that stopped asking.
    ///
    /// It cannot spin: `position` only ever advances by a positive count, and the page and segment
    /// caps bound the loop from above regardless.
    public mutating func accept(_ page: CMSearchResult) {
        pageCount += 1
        segments.append(contentsOf: page.segments)
        if segments.count >= query.hardSegmentCap {
            segments = Array(segments.prefix(query.hardSegmentCap))
            truncated = true
            isFinished = true
            return
        }
        guard page.numberOfMatches > 0 else {
            isFinished = true
            return
        }
        switch page.strip {
        case .more:
            position += page.numberOfMatches
        case .ok, .unknown:
            // A short page is genuinely the last one; a full one is not to be trusted as such.
            if page.numberOfMatches >= query.pageSize {
                position += page.numberOfMatches
            } else {
                isFinished = true
            }
        case .noMatches:
            isFinished = true
        }
    }
}
