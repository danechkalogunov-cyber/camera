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
