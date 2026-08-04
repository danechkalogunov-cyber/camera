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
