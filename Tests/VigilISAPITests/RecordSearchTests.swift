//
//  RecordSearchTests.swift
//  VigilISAPITests
//
//  `POST /ISAPI/ContentMgmt/search`: the request body's mandatory element order and its real
//  misspelling, paging across two pages under one `searchID`, the `playbackURI` rewrite, the track
//  list, and the day index's merge and minute bins.
//  Covers docs/spec-isapi.md §15.1–§15.5.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilISAPI

// MARK: - Fixtures

enum SearchFixtures {

    static let searchID = "{6F9619FF-8B86-D011-B42D-00CF4FC964FF}"

    /// The `playbackURI` values docs/spec-isapi.md §15.2 prints, assembled by concatenation so the
    /// emitted text is byte-faithful: a `\`-continuation inside a multiline literal would fold the
    /// fixture's indentation into the URI.
    static let uriOne = "rtsp://192.168.1.64/Streaming/tracks/101"
        + "?starttime=20240501T080000Z&amp;endtime=20240501T081459Z"
        + "&amp;name=ch01_00000000019000000&amp;size=536870912"
    static let uriTwo = "rtsp://192.168.1.64/Streaming/tracks/101"
        + "?starttime=20240501T081500Z&amp;endtime=20240501T083000Z"
    static let uriThree = "rtsp://192.168.1.64/Streaming/tracks/101"
        + "?starttime=20240501T090000Z&amp;endtime=20240501T090500Z"

    /// docs/spec-isapi.md §15.2's response, page 1 of 2 (`MORE`).
    static let pageOne = """
        <?xml version="1.0" encoding="UTF-8"?>
        <CMSearchResult version="1.0" xmlns="http://www.hikvision.com/ver10/XMLSchema">
          <searchID>\(searchID)</searchID>
          <responseStatus>true</responseStatus>
          <responseStatusStrip>MORE</responseStatusStrip>
          <numOfMatches>2</numOfMatches>
          <matchList>
            <searchMatchItem>
              <sourceID>{A1B2C3D4-0000-0000-0000-000000000000}</sourceID>
              <trackID>101</trackID>
              <timeSpan>
                <startTime>2024-05-01T08:00:00Z</startTime>
                <endTime>2024-05-01T08:14:59Z</endTime>
              </timeSpan>
              <mediaSegmentDescriptor>
                <contentType>video</contentType>
                <codecType>H.264-BP</codecType>
                <playbackURI>\(uriOne)</playbackURI>
              </mediaSegmentDescriptor>
              <metadataMatches>
                <metadataDescriptor>recordType.meta.std-cgi.com/timing</metadataDescriptor>
              </metadataMatches>
            </searchMatchItem>
            <searchMatchItem>
              <trackID>101</trackID>
              <timeSpan>
                <startTime>2024-05-01T08:15:00Z</startTime>
                <endTime>2024-05-01T08:30:00Z</endTime>
              </timeSpan>
              <mediaSegmentDescriptor>
                <contentType>video</contentType>
                <codecType>H.264-BP</codecType>
                <playbackURI>\(uriTwo)</playbackURI>
              </mediaSegmentDescriptor>
              <metadataMatches>
                <metadataDescriptor>recordType.meta.std-cgi.com/motion</metadataDescriptor>
              </metadataMatches>
            </searchMatchItem>
          </matchList>
        </CMSearchResult>
        """

    /// Page 2 of 2 (`OK` — the last page).
    static let pageTwo = """
        <?xml version="1.0" encoding="UTF-8"?>
        <CMSearchResult version="1.0" xmlns="http://www.hikvision.com/ver10/XMLSchema">
          <searchID>\(searchID)</searchID>
          <responseStatus>true</responseStatus>
          <responseStatusStrip>OK</responseStatusStrip>
          <numOfMatches>1</numOfMatches>
          <matchList>
            <searchMatchItem>
              <trackID>101</trackID>
              <timeSpan>
                <startTime>2024-05-01T09:00:00Z</startTime>
                <endTime>2024-05-01T09:05:00Z</endTime>
              </timeSpan>
              <mediaSegmentDescriptor>
                <contentType>video</contentType>
                <codecType>H.265</codecType>
                <playbackURI>\(uriThree)</playbackURI>
              </mediaSegmentDescriptor>
              <metadataMatches>
                <metadataDescriptor>recordType.meta.std-cgi.com/alarm</metadataDescriptor>
              </metadataMatches>
            </searchMatchItem>
          </matchList>
        </CMSearchResult>
        """

    /// The empty result set. A success with zero segments, never an error.
    static let noMatches = """
        <?xml version="1.0" encoding="UTF-8"?>
        <CMSearchResult version="1.0" xmlns="http://www.hikvision.com/ver10/XMLSchema">
          <searchID>\(searchID)</searchID>
          <responseStatus>true</responseStatus>
          <responseStatusStrip>NO MATCHES</responseStatusStrip>
          <numOfMatches>0</numOfMatches>
          <matchList/>
        </CMSearchResult>
        """

    /// docs/spec-isapi.md §15.1, verbatim (note the `ver10` namespace and capitalised elements).
    static let trackList = """
        <TrackList version="1.0" xmlns="http://www.hikvision.com/ver10/XMLSchema">
          <Track>
            <id>101</id>
            <Channel>1</Channel>
            <Enable>true</Enable>
            <Description>Track</Description>
            <TrackGUID>{B4D0F1C2-0000-0000-0000-000000000000}</TrackGUID>
            <DefaultRecordingMode>CMR</DefaultRecordingMode>
            <Duration>P30DT0H0M0S</Duration>
            <Loop>true</Loop>
            <SrcDescriptor>
              <SrcGUID>{A1B2C3D4-0000-0000-0000-000000000000}</SrcGUID>
              <SrcType>camera</SrcType>
              <SrcName>Driveway</SrcName>
              <SrcIndex>1</SrcIndex>
              <SrcLocation>local</SrcLocation>
              <StreamHint>video, audio</StreamHint>
            </SrcDescriptor>
          </Track>
          <Track>
            <id>102</id>
            <Channel>1</Channel>
            <Enable>false</Enable>
            <DefaultRecordingMode>EMR</DefaultRecordingMode>
            <Duration>P7DT0H0M0S</Duration>
            <Loop>false</Loop>
            <SrcDescriptor><SrcName>Driveway</SrcName><StreamHint>video</StreamHint></SrcDescriptor>
          </Track>
        </TrackList>
        """

    /// docs/spec-isapi.md §15.5's month distribution.
    static let dailyDistribution = """
        <trackDailyDistribution version="1.0" xmlns="http://www.hikvision.com/ver10/XMLSchema">
          <dayList>
            <day>
              <id>1</id>
              <dayOfMonth>1</dayOfMonth>
              <record>true</record>
              <recordType>timing,motion</recordType>
            </day>
            <day>
              <id>2</id>
              <dayOfMonth>2</dayOfMonth>
              <record>false</record>
            </day>
          </dayList>
        </trackDailyDistribution>
        """

    static func document(_ xml: String) throws -> ISAPIDocument {
        try ISAPIDocument(parsing: Data(xml.utf8))
    }

    static func query(pageSize: Int = 40, hardCap: Int = 2000,
                     types: Set<RecordType> = []) -> RecordSearchQuery {
        RecordSearchQuery(track: TrackID(101),
                          start: Date(timeIntervalSince1970: 1_714_521_600),   // 2024-05-01Z
                          end: Date(timeIntervalSince1970: 1_714_607_999),
                          recordTypes: types, pageSize: pageSize, hardSegmentCap: hardCap)
    }
}

// MARK: - SearchBodySuite

@Suite struct SearchBodySuite {

    @Test func searchBodyUsesTheMisspelledPagingKey() {
        let body = CMSearchDescription.body(SearchFixtures.query(),
                                            searchID: SearchFixtures.searchID,
                                            position: 40).stringValue
        // The device's own spelling. The correctly-spelled element is silently ignored, so paging
        // would appear to work while every page returned the first forty segments.
        #expect(body.contains("<searchResultPostion>40</searchResultPostion>"))
        #expect(!body.contains("searchResultPosition"))
    }

    @Test func searchBodyKeepsTheMandatoryElementOrder() {
        let body = CMSearchDescription.body(SearchFixtures.query(),
                                            searchID: SearchFixtures.searchID,
                                            position: 0).stringValue
        let order = ["<searchID>", "<trackIDList>", "<timeSpanList>", "<contentTypeList>",
                     "<maxResults>", "<searchResultPostion>", "<metadataList>"]
        var cursor = body.startIndex
        for element in order {
            let found = body.range(of: element, range: cursor..<body.endIndex)
            #expect(found != nil, "\(element) missing or out of order")
            cursor = found?.upperBound ?? cursor
        }
        // No namespace and no version attribute on this body.
        #expect(!body.contains("xmlns"))
        #expect(body.contains("<CMSearchDescription>"))
    }

    @Test func searchBodySendsUTCTimesWithAZ() {
        let body = CMSearchDescription.body(SearchFixtures.query(),
                                            searchID: SearchFixtures.searchID,
                                            position: 0).stringValue
        // A naive local time is interpreted in device time and produces "playback is an hour out".
        #expect(body.contains("<startTime>2024-05-01T00:00:00Z</startTime>"))
        #expect(body.contains("<endTime>2024-05-01T23:59:59Z</endTime>"))
    }

    @Test func searchBodyAlwaysCarriesAMetadataDescriptor() {
        // Omitting `metadataList` returns nothing at all on some DVRs.
        let unfiltered = CMSearchDescription.body(SearchFixtures.query(),
                                                  searchID: SearchFixtures.searchID,
                                                  position: 0).stringValue
        #expect(unfiltered.contains(
            "<metadataDescriptor>//recordType.meta.std-cgi.com</metadataDescriptor>"))

        let filtered = CMSearchDescription.body(
            SearchFixtures.query(types: [.motion, .alarm]),
            searchID: SearchFixtures.searchID, position: 0).stringValue
        // Deterministic order, because a `Set` has none and these bytes are asserted.
        #expect(filtered.contains(
            "<metadataDescriptor>//recordType.meta.std-cgi.com/alarm</metadataDescriptor>"
            + "<metadataDescriptor>//recordType.meta.std-cgi.com/motion</metadataDescriptor>"))

        // The unfiltered retry for the firmwares that reject a filtered descriptor.
        let retry = CMSearchDescription.body(SearchFixtures.query(types: [.motion]),
                                             searchID: SearchFixtures.searchID,
                                             position: 0, filtered: false).stringValue
        #expect(retry.contains(
            "<metadataDescriptor>//recordType.meta.std-cgi.com</metadataDescriptor>"))
    }

    @Test func searchBodyClampsThePageSize() {
        // Values above 50 draw `badParameters` on several firmwares.
        #expect(SearchFixtures.query(pageSize: 500).pageSize == 50)
        #expect(SearchFixtures.query(pageSize: 0).pageSize == 1)
        #expect(SearchFixtures.query().pageSize == 40)
    }

    @Test func searchIDIsABracedUpperCaseGUID() {
        var random = SplitMix64RandomSource(seed: 0xC0FFEE)
        let identifier = CMSearchDescription.searchID(from: &random)
        #expect(identifier.hasPrefix("{"))
        #expect(identifier.hasSuffix("}"))
        let inner = identifier.dropFirst().dropLast()
        #expect(inner.split(separator: "-").map(\.count) == [8, 4, 4, 4, 12])
        #expect(inner.allSatisfy { $0 == "-" || ("0"..."9").contains($0) || ("A"..."F").contains($0) })
        // Deterministic from the seed, which is what makes the paging assertions possible.
        var again = SplitMix64RandomSource(seed: 0xC0FFEE)
        #expect(CMSearchDescription.searchID(from: &again) == identifier)
    }
}

// MARK: - SearchResultSuite

@Suite struct SearchResultSuite {

    @Test func searchResultDecodesPageOne() throws {
        let page = CMSearchResult(document: try SearchFixtures.document(SearchFixtures.pageOne),
                                  track: TrackID(101))
        #expect(page.searchID == SearchFixtures.searchID)
        #expect(page.strip == .more)
        #expect(page.numberOfMatches == 2)
        #expect(page.segments.count == 2)

        let first = page.segments[0]
        #expect(first.track == TrackID(101))
        // The query survives the XML unescaping byte for byte: `&amp;` becomes `&` and nothing
        // else changes.
        #expect(first.locator.rawQuery == "starttime=20240501T080000Z"
                + "&endtime=20240501T081459Z&name=ch01_00000000019000000&size=536870912")
        #expect(first.locator.fileName == "ch01_00000000019000000")
        #expect(first.recordType == .timing)
        #expect(first.codec.codec == .h264)
        #expect(first.codec.profile == "Baseline")
        #expect(first.contentType == "video")
        #expect(abs(first.duration - 899) < 0.001)
        #expect(page.segments[1].recordType == .motion)
    }

    @Test func searchResultReadsTheStripVocabulary() {
        #expect(CMSearchResult.Strip(raw: "OK") == .ok)
        #expect(CMSearchResult.Strip(raw: "MORE") == .more)
        #expect(CMSearchResult.Strip(raw: "NO MATCHES") == .noMatches)
        #expect(CMSearchResult.Strip(raw: nil) == .ok)
        #expect(CMSearchResult.Strip(raw: "SOMETHING NEW") == .unknown("SOMETHING NEW"))
    }

    @Test func searchResultNoMatchesIsASuccessWithZeroSegments() throws {
        let page = CMSearchResult(document: try SearchFixtures.document(SearchFixtures.noMatches),
                                  track: TrackID(101))
        #expect(page.strip == .noMatches)
        #expect(page.segments.isEmpty)
        #expect(page.numberOfMatches == 0)
    }

    @Test func searchResultSkipsAnItemWithNoPlayableAddress() throws {
        let xml = """
            <CMSearchResult><responseStatusStrip>OK</responseStatusStrip><numOfMatches>2</numOfMatches>
            <matchList>
            <searchMatchItem><trackID>101</trackID>
            <timeSpan><startTime>2024-05-01T08:00:00Z</startTime>
            <endTime>2024-05-01T08:01:00Z</endTime></timeSpan>
            <mediaSegmentDescriptor><playbackURI></playbackURI></mediaSegmentDescriptor>
            </searchMatchItem>
            <searchMatchItem><trackID>101</trackID>
            <timeSpan><startTime>2024-05-01T09:00:00Z</startTime>
            <endTime>2024-05-01T09:01:00Z</endTime></timeSpan>
            <mediaSegmentDescriptor>
            <playbackURI>rtsp://h/Streaming/tracks/101?starttime=20240501T090000Z</playbackURI>
            </mediaSegmentDescriptor></searchMatchItem>
            </matchList></CMSearchResult>
            """
        let page = CMSearchResult(document: try SearchFixtures.document(xml), track: TrackID(101))
        // One unplayable segment must not blank a day's timeline; the cursor still advances by the
        // device's own count.
        #expect(page.segments.count == 1)
        #expect(page.numberOfMatches == 2)
    }
}

// MARK: - SearchPagingSuite

@Suite struct SearchPagingSuite {

    @Test func searchPagerFollowsMOREAndStopsOnOK() throws {
        var pager = RecordSearchPager(query: SearchFixtures.query(),
                                      searchID: SearchFixtures.searchID)
        #expect(pager.position == 0)

        let first = CMSearchResult(document: try SearchFixtures.document(SearchFixtures.pageOne),
                                   track: TrackID(101))
        pager.accept(first)
        #expect(!pager.isFinished)
        // The cursor advances by the device's own count, not by the page size.
        #expect(pager.position == 2)

        let second = CMSearchResult(document: try SearchFixtures.document(SearchFixtures.pageTwo),
                                    track: TrackID(101))
        pager.accept(second)
        #expect(pager.isFinished)
        #expect(pager.pageCount == 2)
        #expect(pager.segments.count == 3)
        #expect(!pager.truncated)
        #expect(pager.segments.map(\.recordType) == [.timing, .motion, .alarm])
    }

    @Test func searchPagerSendsTheSameSearchIDOnEveryPage() throws {
        // The device keys its result cursor by `searchID`: a fresh id per page breaks paging,
        // reusing a finished search's id returns stale results.
        var pager = RecordSearchPager(query: SearchFixtures.query(),
                                      searchID: SearchFixtures.searchID)
        let firstBody = pager.nextBody().stringValue
        pager.accept(CMSearchResult(document: try SearchFixtures.document(SearchFixtures.pageOne),
                                    track: TrackID(101)))
        let secondBody = pager.nextBody().stringValue
        #expect(firstBody.contains("<searchID>\(SearchFixtures.searchID)</searchID>"))
        #expect(secondBody.contains("<searchID>\(SearchFixtures.searchID)</searchID>"))
        #expect(firstBody.contains("<searchResultPostion>0</searchResultPostion>"))
        #expect(secondBody.contains("<searchResultPostion>2</searchResultPostion>"))
    }

    @Test func searchResultReadsTheDevicesMisspellingOfTheStatusStrip() throws {
        // The schema — and docs/spec-isapi.md §15.2 — say `responseStatusStrip`. A great many
        // shipping firmwares emit `responseStatusStrp`, without the second `i`. Reading only the
        // documented spelling yields nil, which resolves to `.ok`, which ends paging after page
        // one: a whole day of footage collapses to the first forty segments.
        let misspelled = """
            <?xml version="1.0" encoding="UTF-8"?>
            <CMSearchResult version="1.0" xmlns="http://www.hikvision.com/ver10/XMLSchema">
              <searchID>\(SearchFixtures.searchID)</searchID>
              <responseStatusStrp>MORE</responseStatusStrp>
              <numOfMatches>2</numOfMatches>
              <matchList/>
            </CMSearchResult>
            """
        let page = CMSearchResult(document: try SearchFixtures.document(misspelled),
                                  track: TrackID(101))
        #expect(page.strip == .more, "the device's own spelling must be read")

        // The documented spelling still works, and wins when a device somehow sends both.
        let correct = CMSearchResult(document: try SearchFixtures.document(SearchFixtures.pageOne),
                                     track: TrackID(101))
        #expect(correct.strip == .more)
    }

    @Test func searchPagerKeepsGoingWhenAFullPageClaimsToBeTheLast() throws {
        // The failure this pins: a firmware that answers `OK` on every page. Trusting it alone
        // produced a one-page day — forty segments and nothing else, on every day, which reads as
        // a camera that hardly records rather than as a search that stopped asking.
        var pager = RecordSearchPager(query: SearchFixtures.query(pageSize: 2),
                                      searchID: SearchFixtures.searchID)
        let full = CMSearchResult(searchID: SearchFixtures.searchID, strip: .ok,
                                  numberOfMatches: 2, segments: [])
        pager.accept(full)
        #expect(!pager.isFinished, "a full page is not to be trusted as the last one")
        #expect(pager.position == 2)

        // A short page genuinely is the last one, and still stops.
        let short = CMSearchResult(searchID: SearchFixtures.searchID, strip: .ok,
                                   numberOfMatches: 1, segments: [])
        pager.accept(short)
        #expect(pager.isFinished)
        #expect(pager.pageCount == 2)

        // The same applies to a status value we do not recognise at all.
        var other = RecordSearchPager(query: SearchFixtures.query(pageSize: 2),
                                      searchID: SearchFixtures.searchID)
        other.accept(CMSearchResult(searchID: nil, strip: .unknown("WHATEVER"),
                                    numberOfMatches: 2, segments: []))
        #expect(!other.isFinished)

        // ⛔ And it must still terminate. A page of zero matches ends it whatever the strip says,
        // because advancing the cursor by zero asks the same question for ever.
        var zero = RecordSearchPager(query: SearchFixtures.query(pageSize: 2),
                                     searchID: SearchFixtures.searchID)
        zero.accept(CMSearchResult(searchID: nil, strip: .ok, numberOfMatches: 0, segments: []))
        #expect(zero.isFinished)
    }

    @Test func searchPagerStopsOnNoMatches() throws {
        var pager = RecordSearchPager(query: SearchFixtures.query(),
                                      searchID: SearchFixtures.searchID)
        pager.accept(CMSearchResult(document: try SearchFixtures.document(SearchFixtures.noMatches),
                                    track: TrackID(101)))
        #expect(pager.isFinished)
        #expect(pager.segments.isEmpty)
        #expect(!pager.truncated)
    }

    @Test func searchPagerStopsWhenMOREReportsNoMatches() throws {
        // Advancing the cursor by zero would ask the same question forever.
        let xml = """
            <CMSearchResult><responseStatusStrip>MORE</responseStatusStrip>
            <numOfMatches>0</numOfMatches><matchList/></CMSearchResult>
            """
        var pager = RecordSearchPager(query: SearchFixtures.query(),
                                      searchID: SearchFixtures.searchID)
        pager.accept(CMSearchResult(document: try SearchFixtures.document(xml),
                                    track: TrackID(101)))
        #expect(pager.isFinished)
        #expect(pager.position == 0)
    }

    @Test func searchPagerRespectsTheHardCap() throws {
        var pager = RecordSearchPager(query: SearchFixtures.query(hardCap: 2),
                                      searchID: SearchFixtures.searchID)
        pager.accept(CMSearchResult(document: try SearchFixtures.document(SearchFixtures.pageOne),
                                    track: TrackID(101)))
        #expect(pager.isFinished)
        #expect(pager.truncated)
        #expect(pager.segments.count == 2)
    }

    @Test func searchPagerDrivenThroughTheRequestDouble() async throws {
        let double = RequestDouble()
        await double.route("/ContentMgmt/search",
                           pages: [SearchFixtures.pageOne, SearchFixtures.pageTwo])
        var pager = RecordSearchPager(query: SearchFixtures.query(),
                                      searchID: SearchFixtures.searchID)
        while !pager.isFinished {
            let document = try await double.postDocument(
                ISAPIResource.contentSearch, body: pager.nextBody().data(),
                query: [], lane: .control)
            pager.accept(CMSearchResult(document: document, track: SearchFixtures.query().track))
        }
        let bodies = await double.requests(to: "/ContentMgmt/search").compactMap(\.bodyText)
        #expect(bodies.count == 2)
        // Both pages carried the same id and the documented cursor positions.
        #expect(bodies.allSatisfy { $0.contains("<searchID>\(SearchFixtures.searchID)</searchID>") })
        #expect(bodies[0].contains("<searchResultPostion>0</searchResultPostion>"))
        #expect(bodies[1].contains("<searchResultPostion>2</searchResultPostion>"))
        #expect(pager.segments.count == 3)
    }

    @Test func recordTypeSeverityOrdersTheTimelineColours() {
        // `alarm > motion > manual > command > timing`, and `other` never masks a real alarm.
        #expect(RecordType.alarm.severity > RecordType.motion.severity)
        #expect(RecordType.motion.severity > RecordType.manual.severity)
        #expect(RecordType.manual.severity > RecordType.command.severity)
        #expect(RecordType.command.severity > RecordType.timing.severity)
        #expect(RecordType.timing.severity > RecordType.other.severity)
    }

    @Test func recordTypeReadsTheResponseDescriptorWithoutItsLeadingSlashes() {
        // The response omits the `//` the request carries.
        #expect(RecordType(descriptor: "recordType.meta.std-cgi.com/timing") == .timing)
        #expect(RecordType(descriptor: "//recordType.meta.std-cgi.com/motion") == .motion)
        #expect(RecordType(descriptor: "recordType.meta.std-cgi.com/alarm") == .alarm)
        #expect(RecordType(descriptor: "recordType.meta.std-cgi.com") == .other)
        #expect(RecordType(descriptor: "something/new") == .other)
    }
}

// MARK: - PlaybackLocatorSuite

@Suite struct PlaybackLocatorSuite {

    private let uri = "rtsp://192.168.1.64/Streaming/tracks/101"
        + "?starttime=20240501T080000Z&endtime=20240501T081459Z"
        + "&name=ch01_00000000019000000&size=536870912"

    @Test func playbackLocatorParsesTheDocumentedURI() throws {
        let locator = try #require(PlaybackLocator(playbackURI: uri))
        #expect(locator.path == "/Streaming/tracks/101")
        #expect(locator.fileName == "ch01_00000000019000000")
        #expect(locator.sizeBytes == 536_870_912)
        #expect(abs(locator.start.timeIntervalSince1970 - 1_714_550_400) < 0.001)
        #expect(abs(locator.end.timeIntervalSince1970 - 1_714_551_299) < 0.001)
    }

    @Test func playbackLocatorKeepsTheQueryVerbatim() throws {
        let locator = try #require(PlaybackLocator(playbackURI: uri))
        // Byte-identical: `name` is a device-internal file name and re-encoding it, or reordering
        // the items, breaks playback on the firmwares that matter.
        #expect(locator.rawQuery == "starttime=20240501T080000Z&endtime=20240501T081459Z"
                + "&name=ch01_00000000019000000&size=536870912")
    }

    @Test func playbackLocatorRewritesOnlyTheAddress() throws {
        let locator = try #require(PlaybackLocator(playbackURI: uri))
        // The device filled in the address it thinks it has; on a multi-homed NVR or behind NAT
        // that is not the address Vigil reached it on.
        #expect(locator.requestURI(host: "10.0.0.5", port: 8554)
                == "rtsp://10.0.0.5:8554/Streaming/tracks/101"
                + "?starttime=20240501T080000Z&endtime=20240501T081459Z"
                + "&name=ch01_00000000019000000&size=536870912")
        #expect(locator.requestURI(host: "10.0.0.5", port: 322, useTLS: true).hasPrefix("rtsps://"))
        // No credentials, ever.
        #expect(!locator.requestURI(host: "h", port: 554).contains("@"))
    }

    @Test func playbackLocatorBracketsAnIPv6HostExactlyOnce() throws {
        let locator = try #require(PlaybackLocator(playbackURI: uri))
        #expect(locator.requestURI(host: "fe80::1", port: 554)
                    .hasPrefix("rtsp://[fe80::1]:554/"))
        #expect(locator.requestURI(host: "[fe80::1]", port: 554)
                    .hasPrefix("rtsp://[fe80::1]:554/"))
    }

    @Test func playbackLocatorTrimsATrailingSlash() throws {
        let locator = try #require(PlaybackLocator(
            playbackURI: "rtsp://h/Streaming/tracks/101/?starttime=20240501T080000Z"))
        #expect(locator.path == "/Streaming/tracks/101")
    }

    @Test func playbackLocatorToleratesAMissingNameAndSize() throws {
        let locator = try #require(PlaybackLocator(
            playbackURI: "rtsp://h/Streaming/tracks/101"
                + "?starttime=20240501T080000Z&endtime=20240501T081459Z"))
        #expect(locator.fileName == nil)
        #expect(locator.sizeBytes == nil)
    }

    @Test func playbackLocatorFallsBackToTheSearchResultTimes() throws {
        let start = Date(timeIntervalSince1970: 1_714_550_400)
        let end = Date(timeIntervalSince1970: 1_714_551_299)
        let locator = try #require(PlaybackLocator(playbackURI: "rtsp://h/Streaming/tracks/101",
                                                   fallbackStart: start, fallbackEnd: end))
        #expect(locator.start == start)
        #expect(locator.end == end)
        #expect(locator.rawQuery.isEmpty)
    }

    @Test func playbackLocatorRejectsAURIWithNoUsableAddress() {
        #expect(PlaybackLocator(playbackURI: "") == nil)
        #expect(PlaybackLocator(playbackURI: "rtsp://192.168.1.64") == nil)
        // No time at all, from any source.
        #expect(PlaybackLocator(playbackURI: "rtsp://h/Streaming/tracks/101") == nil)
    }

    @Test func playbackLocatorSynthesisesADirectSeek() {
        let start = Date(timeIntervalSince1970: 1_714_551_000)
        let open = PlaybackLocator(track: TrackID(101), start: start, end: nil)
        // No `endtime` means "play to the end of available footage".
        #expect(open.rawQuery == "starttime=20240501T081000Z")
        #expect(open.path == "/Streaming/tracks/101")
        let bounded = PlaybackLocator(track: TrackID(101), start: start,
                                      end: start.addingTimeInterval(60))
        #expect(bounded.rawQuery == "starttime=20240501T081000Z&endtime=20240501T081100Z")
    }

    @Test func playbackLocatorFormatsTheClockRange() throws {
        let locator = try #require(PlaybackLocator(playbackURI: uri))
        #expect(locator.clockRange == "clock=20240501T080000Z-20240501T081459Z")
    }

    @Test func playbackLocatorShiftsForDeviceLocalFirmware() throws {
        // `playbackTimesAreDeviceLocal`: the times move, `name` and `size` keep their positions.
        let locator = try #require(PlaybackLocator(playbackURI: uri))
        let shifted = locator.shiftedForDeviceLocalTimes(utcOffsetSeconds: 28_800)
        #expect(shifted.rawQuery == "starttime=20240501T160000Z&endtime=20240501T161459Z"
                + "&name=ch01_00000000019000000&size=536870912")
        #expect(shifted.start == locator.start)     // the absolute instant is unchanged
        #expect(locator.shiftedForDeviceLocalTimes(utcOffsetSeconds: 0) == locator)
    }
}

// MARK: - RecordTrackSuite

@Suite struct RecordTrackSuite {

    @Test func recordTracksDecodeTheCapitalisedContentMgmtElements() throws {
        let tracks = RecordTrack.list(document: try SearchFixtures.document(
            SearchFixtures.trackList))
        #expect(tracks.count == 2)
        let main = tracks[0]
        #expect(main.id == TrackID(101))
        #expect(main.channel == ChannelID(1))
        #expect(main.enabled)
        #expect(main.sourceName == "Driveway")
        #expect(main.recordingMode == "CMR")
        #expect(main.hasAudio)
        #expect(main.loopRecording)
        // `P30DT0H0M0S` is 30 days.
        #expect(main.retention == 2_592_000)

        let sub = tracks[1]
        #expect(!sub.enabled)
        #expect(!sub.hasAudio)
        #expect(sub.retention == 604_800)
    }

    @Test func recordTrackDerivesTheChannelWhenTheDeviceOmitsIt() throws {
        let xml = "<TrackList><Track><id>702</id><Enable>true</Enable></Track></TrackList>"
        let tracks = RecordTrack.list(document: try SearchFixtures.document(xml))
        #expect(tracks.first?.channel == ChannelID(7))
    }

    @Test func iso8601DurationParsesEveryDocumentedShape() {
        #expect(ISO8601Duration.seconds("P30DT0H0M0S") == 2_592_000)
        #expect(ISO8601Duration.seconds("P7D") == 604_800)
        #expect(ISO8601Duration.seconds("PT1H30M") == 5400)
        #expect(ISO8601Duration.seconds("PT45S") == 45)
        // A month is 30 days and a year 365 — display only, and documented as "about".
        #expect(ISO8601Duration.seconds("P1M") == 2_592_000)
        #expect(ISO8601Duration.seconds("P1Y") == 31_536_000)
        // The `M` before `T` is months; after `T` it is minutes. That is the whole trap.
        let monthAndMinute = ISO8601Duration.seconds("P1MT1M")
        #expect(monthAndMinute == 2_592_060.0)
        #expect(ISO8601Duration.seconds(nil) == nil)
        #expect(ISO8601Duration.seconds("") == nil)
        #expect(ISO8601Duration.seconds("30 days") == nil)
        #expect(ISO8601Duration.seconds("P") == nil)
    }

    @Test func monthCalendarDecodesTheDistribution() throws {
        let calendar = MonthRecordCalendar(
            document: try SearchFixtures.document(SearchFixtures.dailyDistribution),
            track: TrackID(101), year: 2024, month: 5)
        #expect(calendar.days.count == 31)
        #expect(calendar.days[0] == .recorded([.timing, .motion]))
        #expect(calendar.days[1] == .empty)
        // A day the device did not mention stays unknown, and renders as an outline rather than as
        // "empty".
        #expect(calendar.days[2] == nil)
    }

    @Test func monthCalendarMergesTracksWithoutInventingEmptyDays() {
        // A camera that files its month across tracks 101 and 103 — the case that made half a
        // month grey out when only the first track was asked.
        var first = [MonthRecordCalendar.DayState?](repeating: nil, count: 31)
        first[0] = .recorded([.timing])       // day 1: footage on 101 only
        first[1] = .empty                     // day 2: 101 says nothing here
        first[2] = .empty                     // day 3: 101 says nothing here
        first[3] = .recorded([.motion])       // day 4: motion on 101

        var second = [MonthRecordCalendar.DayState?](repeating: nil, count: 31)
        second[0] = .empty                    // day 1: nothing on 103
        second[1] = .recorded([.alarm])       // day 2: footage on 103 only
        second[2] = nil                       // day 3: 103 did not answer
        second[3] = .recorded([.alarm])       // day 4: alarm on 103

        let merged = MonthRecordCalendar(year: 2024, month: 5, track: TrackID(101), days: first)
            .merging(MonthRecordCalendar(year: 2024, month: 5, track: TrackID(103), days: second))

        // Footage on either track is footage on that day — this is the whole bug.
        #expect(merged.days[0] == .recorded([.timing]))
        #expect(merged.days[1] == .recorded([.alarm]))
        // One track answering "empty" while the other stays silent is still a real "empty": the
        // day is only unknown when nobody answered for it.
        #expect(merged.days[2] == .empty)
        // Both recorded: the types union rather than one winning.
        #expect(merged.days[3] == .recorded([.motion, .alarm]))
        // A day neither track mentioned stays unknown, and must NOT become empty.
        #expect(merged.days[4] == nil)
        #expect(merged.days.count == 31)

        // Order does not matter.
        let reversed = MonthRecordCalendar(year: 2024, month: 5, track: TrackID(103), days: second)
            .merging(MonthRecordCalendar(year: 2024, month: 5, track: TrackID(101), days: first))
        #expect(reversed.days == merged.days)

        // A different month is a caller error and is refused rather than silently blended.
        let other = MonthRecordCalendar(year: 2024, month: 6, track: TrackID(103), days: second)
        #expect(MonthRecordCalendar(year: 2024, month: 5, track: TrackID(101), days: first)
                    .merging(other).days == first)
    }

    @Test func monthCalendarRequestBodyMatchesTheSpec() {
        #expect(MonthRecordCalendar.requestBody(track: TrackID(101), year: 2024, month: 5)
                    .stringValue == "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                + "<trackDailyParam><year>2024</year><monthOfYear>5</monthOfYear>"
                + "<trackID>101</trackID></trackDailyParam>")
    }
}

// MARK: - DayIndexSuite

@Suite struct DayIndexSuite {

    private let dayStart = Date(timeIntervalSince1970: 1_714_521_600)   // 2024-05-01T00:00:00Z

    private func segment(_ startMinute: Double, _ endMinute: Double,
                        _ type: RecordType) -> RecordSegment {
        let start = dayStart.addingTimeInterval(startMinute * 60)
        let end = dayStart.addingTimeInterval(endMinute * 60)
        return RecordSegment(track: TrackID(101), start: start, end: end,
                             codec: VideoCodecWire(raw: "H.264"), contentType: "video",
                             recordType: type,
                             locator: PlaybackLocator(track: TrackID(101), start: start, end: end))
    }

    @Test func dayIndexMergesASmallGapAndKeepsALargeOne() {
        // 1.5 s merges, 3 s does not. The default gap is 2.0 s.
        let a = segment(0, 10, .timing)
        let b = RecordSegment(track: TrackID(101),
                              start: a.end.addingTimeInterval(1.5),
                              end: a.end.addingTimeInterval(600),
                              codec: a.codec, contentType: "video", recordType: .timing,
                              locator: a.locator)
        let merged = RecordDayIndex.build(track: TrackID(101), dayStartUTC: dayStart,
                                          segments: [a, b], truncated: false)
        #expect(merged.segments.count == 1)

        let c = RecordSegment(track: TrackID(101),
                              start: a.end.addingTimeInterval(3),
                              end: a.end.addingTimeInterval(600),
                              codec: a.codec, contentType: "video", recordType: .timing,
                              locator: a.locator)
        let split = RecordDayIndex.build(track: TrackID(101), dayStartUTC: dayStart,
                                         segments: [a, c], truncated: false)
        #expect(split.segments.count == 2)
    }

    @Test func dayIndexNeverMergesAcrossRecordTypes() {
        // The record type is what the timeline colour encodes, so merging would lose the alarm.
        let a = segment(0, 10, .timing)
        let b = RecordSegment(track: TrackID(101), start: a.end, end: a.end.addingTimeInterval(60),
                              codec: a.codec, contentType: "video", recordType: .alarm,
                              locator: a.locator)
        let index = RecordDayIndex.build(track: TrackID(101), dayStartUTC: dayStart,
                                         segments: [a, b], truncated: false)
        #expect(index.segments.count == 2)
    }

    @Test func dayIndexBinsByMinuteWithSeverityWinning() {
        let index = RecordDayIndex.build(
            track: TrackID(101), dayStartUTC: dayStart,
            segments: [segment(0, 60, .timing), segment(30, 40, .alarm),
                       segment(35, 45, .motion)],
            truncated: false)
        #expect(index.minuteBins.count == 1440)
        #expect(index.minuteBins[0] == .timing)
        #expect(index.minuteBins[29] == .timing)
        // Alarm beats motion beats timing where they overlap.
        #expect(index.minuteBins[31] == .alarm)
        #expect(index.minuteBins[36] == .alarm)
        #expect(index.minuteBins[42] == .motion)
        #expect(index.minuteBins[59] == .timing)
        #expect(index.minuteBins[61] == nil)
    }

    @Test func dayIndexIgnoresSegmentsOutsideTheDay() {
        let index = RecordDayIndex.build(
            track: TrackID(101), dayStartUTC: dayStart,
            segments: [segment(-120, -60, .timing), segment(1500, 1600, .timing)],
            truncated: false)
        #expect(index.minuteBins.allSatisfy { $0 == nil })
    }

    @Test func dayIndexReportsCoverage() {
        let index = RecordDayIndex.build(track: TrackID(101), dayStartUTC: dayStart,
                                         segments: [segment(0, 720, .timing)], truncated: false)
        #expect(index.totalRecordedSeconds == 43_200)
        #expect(abs(index.coverageFraction - 0.5) < 0.0001)
        #expect(!index.truncated)
    }

    @Test func dayIndexKeepsTheFirstLocatorWhenMerging() {
        // Playback starts at the beginning of the run; the device plays through its own file
        // boundaries without help.
        let a = segment(0, 10, .timing)
        let b = RecordSegment(track: TrackID(101), start: a.end, end: a.end.addingTimeInterval(600),
                              codec: a.codec, contentType: "video", recordType: .timing,
                              locator: PlaybackLocator(track: TrackID(101), start: a.end,
                                                        end: nil))
        let index = RecordDayIndex.build(track: TrackID(101), dayStartUTC: dayStart,
                                         segments: [a, b], truncated: false)
        #expect(index.segments.count == 1)
        #expect(index.segments[0].locator.rawQuery == a.locator.rawQuery)
        #expect(index.segments[0].end == b.end)
    }
}
