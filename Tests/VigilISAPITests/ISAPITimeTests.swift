//
//  ISAPITimeTests.swift
//  VigilISAPITests
//
//  Every time form §7.5 lists, the two Vigil emits, and Hikvision's POSIX-inverted zone string —
//  the one whose sign, read the human way, puts a Shanghai camera's recordings sixteen hours out.
//  Covers docs/spec-isapi.md §7.5.
//

import Foundation
import Testing
@testable import VigilISAPI

@Suite struct ISAPITimeTests {

    /// The six forms in §7.5's table. Expected epochs are from the civil dates by hand:
    /// 2024-05-01T00:00:00Z is 1 714 521 600.
    @Test func isapiTimeParsesEveryFormInTheSpecTable() throws {
        let midnight = 1_714_521_600.0                       // 2024-05-01T00:00:00Z

        let offset = try #require(ISAPITime.parse("2024-05-01T12:34:56+08:00"))
        #expect(offset.date.timeIntervalSince1970 == midnight + 4 * 3600 + 34 * 60 + 56)
        #expect(offset.hasExplicitZone)
        #expect(offset.offsetSeconds == 28_800)

        let utc = try #require(ISAPITime.parse("2024-05-01T04:34:56Z"))
        #expect(utc.date.timeIntervalSince1970 == midnight + 4 * 3600 + 34 * 60 + 56)
        #expect(utc.hasExplicitZone)

        let naive = try #require(ISAPITime.parse("2024-05-01T12:34:56"))
        #expect(naive.date.timeIntervalSince1970 == midnight + 12 * 3600 + 34 * 60 + 56)
        #expect(naive.hasExplicitZone == false)              // caller applies the device offset

        let compact = try #require(ISAPITime.parse("20240501T043456Z"))
        #expect(compact.date == utc.date)

        let compactNaive = try #require(ISAPITime.parse("20240501T123456"))
        #expect(compactNaive.date == naive.date)
        #expect(compactNaive.hasExplicitZone == false)

        let fractional = try #require(ISAPITime.parse("2024-05-01T12:34:56.789+08:00"))
        #expect(abs(fractional.date.timeIntervalSince1970
                    - (offset.date.timeIntervalSince1970 + 0.789)) < 0.0005)
    }

    /// A `+05:30` offset and the `+0530` spelling both parse, and both mean the same instant.
    @Test func isapiTimeParsesHalfHourOffsetsInBothSpellings() throws {
        let colon = try #require(ISAPITime.parse("2024-05-01T12:00:00+05:30"))
        let bare = try #require(ISAPITime.parse("2024-05-01T12:00:00+0530"))
        #expect(colon.date == bare.date)
        #expect(colon.offsetSeconds == 19_800)
        let west = try #require(ISAPITime.parse("2024-05-01T12:00:00-07:00"))
        #expect(west.date.timeIntervalSince1970
                == colon.date.timeIntervalSince1970 + 19_800 + 25_200)
    }

    /// A leap day exists in 2024 and does not in 2023, and the reader says so rather than rolling
    /// the date forward into a silently wrong search window.
    @Test func isapiTimeAcceptsALeapDayAndRejectsAnImpossibleOne() throws {
        let leap = try #require(ISAPITime.parse("2024-02-29T00:00:00Z"))
        #expect(leap.date.timeIntervalSince1970 == 1_709_164_800)
        #expect(ISAPITime.parse("2023-02-29T00:00:00Z") == nil)
        #expect(ISAPITime.parse("2024-02-30T00:00:00Z") == nil)
        #expect(ISAPITime.parse("2024-13-01T00:00:00Z") == nil)
        #expect(ISAPITime.parse("2024-05-01T25:00:00Z") == nil)
        #expect(ISAPITime.parse("2100-02-29T00:00:00Z") == nil)     // century, not a leap year
        #expect(ISAPITime.parse("2000-02-29T00:00:00Z") != nil)     // 400-year rule
    }

    /// Junk, truncation and trailing rubbish are refused rather than half-read.
    @Test func isapiTimeRejectsMalformedInput() {
        #expect(ISAPITime.parse("") == nil)
        #expect(ISAPITime.parse("not a time") == nil)
        #expect(ISAPITime.parse("2024-05-01") == nil)
        #expect(ISAPITime.parse("2024-05-01T12:34") == nil)
        #expect(ISAPITime.parse("2024-05-01T12:34:56Zjunk") == nil)
        #expect(ISAPITime.parse("20240501T04345") == nil)
    }

    /// The two emitters, and the fact that they round toward the past: a search window that rounds
    /// up past a segment boundary drops the first clip of the day.
    @Test func isapiTimeEmitsTheTwoWireForms() {
        let date = Date(timeIntervalSince1970: 1_714_538_096.789)   // 2024-05-01T04:34:56.789Z
        #expect(ISAPITime.iso8601UTC(date) == "2024-05-01T04:34:56Z")
        #expect(ISAPITime.compactUTC(date) == "20240501T043456Z")
        let epoch = Date(timeIntervalSince1970: 0)
        #expect(ISAPITime.iso8601UTC(epoch) == "1970-01-01T00:00:00Z")
        #expect(ISAPITime.compactUTC(epoch) == "19700101T000000Z")
    }

    /// Emission and parsing are inverses across a spread of dates including leap days and a
    /// pre-epoch instant.
    @Test func isapiTimeRoundTripsThroughBothForms() throws {
        let samples: [Double] = [0, 1, 951_782_400, 1_709_164_800, 1_714_538_096, 2_147_483_647,
                                 -86_400]
        for seconds in samples {
            let date = Date(timeIntervalSince1970: seconds)
            let iso = try #require(ISAPITime.parse(ISAPITime.iso8601UTC(date)))
            let compact = try #require(ISAPITime.parse(ISAPITime.compactUTC(date)))
            #expect(iso.date.timeIntervalSince1970 == seconds)
            #expect(compact.date.timeIntervalSince1970 == seconds)
        }
    }

    /// `CST-8:00:00` is **UTC+8**. POSIX writes the offset that turns local time into UTC, so the
    /// sign is inverted relative to how a person reads it.
    @Test func isapiTimeParsesPOSIXInvertedZoneStrings() {
        #expect(ISAPITime.parseTimeZone("CST-8:00:00") == 28_800)
        #expect(ISAPITime.parseTimeZone("CST-08:00:00") == 28_800)
        #expect(ISAPITime.parseTimeZone("EST+5:00:00") == -18_000)
        #expect(ISAPITime.parseTimeZone("IST-5:30:00") == 19_800)
        #expect(ISAPITime.parseTimeZone("GMT+0:00:00") == 0)
        #expect(ISAPITime.parseTimeZone("CST-8") == 28_800)
        #expect(ISAPITime.parseTimeZone("") == nil)
        #expect(ISAPITime.parseTimeZone("CST") == nil)
        #expect(ISAPITime.parseTimeZone("CST-99:00:00") == nil)
    }

    /// The date accessor on a value reads a device timestamp out of a real body shape.
    @Test func isapiTimeReadsThroughXMLValue() throws {
        let document = try ISAPIDocument(parsing: Data("""
            <Time><localTime>2024-05-01T12:34:56+08:00</localTime>
            <timeZone>CST-8:00:00</timeZone></Time>
            """.utf8))
        let reading = try #require(document["localTime"].dateReading)
        #expect(reading.offsetSeconds == 28_800)
        #expect(document["localTime"].date == reading.date)
        #expect(ISAPITime.parseTimeZone(document["timeZone"].string(or: "")) == 28_800)
    }
}
