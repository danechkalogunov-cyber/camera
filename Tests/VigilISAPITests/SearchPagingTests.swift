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
