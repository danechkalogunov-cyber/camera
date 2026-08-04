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
