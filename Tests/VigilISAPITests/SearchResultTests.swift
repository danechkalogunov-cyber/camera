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
