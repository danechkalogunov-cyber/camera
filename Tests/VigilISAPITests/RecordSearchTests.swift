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
