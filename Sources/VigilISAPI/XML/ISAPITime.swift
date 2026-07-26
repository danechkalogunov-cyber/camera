//
//  ISAPITime.swift
//  VigilISAPI
//
//  Every time format ISAPI emits, parsed by hand over ASCII bytes, plus the two forms Vigil emits
//  and Hikvision's POSIX-inverted timezone string.
//  Implements docs/spec-isapi.md §7.5.
//
//  Not `DateFormatter` (locale-sensitive and ~40× slower) and not `ISO8601DateFormatter` (rejects
//  both the compact and the naive form, which are the two Hikvision uses in playback queries). The
//  arithmetic is Howard Hinnant's days-from-civil, which is exact, branch-light and needs no
//  `Calendar`, no `TimeZone` and therefore no locale data on Linux.
//

import Foundation

// MARK: - ISAPITime

/// Parsing and emission of the device's time formats.
public enum ISAPITime {

    /// A parsed time and what the wire form actually said about its zone.
    ///
    /// `hasExplicitZone == false` means the device sent a naive local time; the caller converts it
    /// with the cached `/System/time` offset and flags the model `dateAssumedUTC` when it has
    /// none. Losing that distinction is how a timeline lands eight hours off.
    public struct Reading: Sendable, Hashable {
        /// The instant, interpreted as UTC when the wire form carried no zone.
        public var date: Date
        /// Whether the wire form carried `Z` or a `±hh:mm` offset.
        public var hasExplicitZone: Bool
        /// The offset in seconds east of UTC, when one was written.
        public var offsetSeconds: Int?

        /// Builds a reading.
        public init(date: Date, hasExplicitZone: Bool, offsetSeconds: Int?) {
            self.date = date
            self.hasExplicitZone = hasExplicitZone
            self.offsetSeconds = offsetSeconds
        }
    }

    // MARK: Parsing

    /// Parses any of the six forms in §7.5, or returns `nil`.
    ///
    /// Accepted: `2024-05-01T12:34:56+08:00`, `…Z`, naive `2024-05-01T12:34:56`, compact
    /// `20240501T043456Z`, compact naive, and any of those with fractional seconds. Surrounding
    /// whitespace is ignored, a lowercase `t`/`z` is accepted, and an offset may be written
    /// `+0800` or `+08:00`. A date that does not exist — 30 February, 29 February in a common
    /// year — is rejected rather than rolled forward, because a rolled date is a wrong search
    /// result no one can see is wrong.
    public static func parse(_ raw: String) -> Reading? {
        let bytes = Array(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard bytes.count >= 15 else { return nil }

        var index = 0
        guard let year = digits(bytes, &index, 4) else { return nil }
        let extended = index < bytes.count && bytes[index] == UInt8(ascii: "-")
        if extended { index += 1 }
        guard let month = digits(bytes, &index, 2) else { return nil }
        if extended {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "-") else { return nil }
            index += 1
        }
        guard let day = digits(bytes, &index, 2) else { return nil }

        guard index < bytes.count,
              bytes[index] == UInt8(ascii: "T") || bytes[index] == UInt8(ascii: "t")
                || bytes[index] == UInt8(ascii: " ") else { return nil }
        index += 1

        guard let hour = digits(bytes, &index, 2) else { return nil }
        if extended {
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
            index += 1
        }
        guard let minute = digits(bytes, &index, 2) else { return nil }
        if extended {
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
            index += 1
        }
        guard let second = digits(bytes, &index, 2) else { return nil }

        var fraction = 0.0
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") || bytes[index] == UInt8(ascii: ",") {
            index += 1
            var scale = 0.1
            while index < bytes.count, isDigit(bytes[index]) {
                fraction += Double(bytes[index] - UInt8(ascii: "0")) * scale
                scale /= 10
                index += 1
            }
        }

        var offsetSeconds: Int?
        var hasZone = false
        if index < bytes.count {
            let marker = bytes[index]
            if marker == UInt8(ascii: "Z") || marker == UInt8(ascii: "z") {
                hasZone = true
                offsetSeconds = 0
                index += 1
            } else if marker == UInt8(ascii: "+") || marker == UInt8(ascii: "-") {
                let sign = marker == UInt8(ascii: "-") ? -1 : 1
                index += 1
                guard let offsetHours = digits(bytes, &index, 2) else { return nil }
                if index < bytes.count, bytes[index] == UInt8(ascii: ":") { index += 1 }
                let offsetMinutes = digits(bytes, &index, 2) ?? 0
                hasZone = true
                offsetSeconds = sign * (offsetHours * 3600 + offsetMinutes * 60)
            }
        }
        guard index == bytes.count else { return nil }
        guard let epoch = epochSeconds(year: year, month: month, day: day,
                                       hour: hour, minute: minute, second: second) else {
            return nil
        }
        let shifted = Double(epoch - (offsetSeconds ?? 0)) + fraction
        return Reading(date: Date(timeIntervalSince1970: shifted),
                       hasExplicitZone: hasZone, offsetSeconds: offsetSeconds)
    }

    /// Seconds since the epoch for a UTC civil time, or `nil` when the date does not exist.
    static func epochSeconds(year: Int, month: Int, day: Int,
                             hour: Int, minute: Int, second: Int) -> Int? {
        guard (1...12).contains(month), day >= 1, day <= daysInMonth(year: year, month: month),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else {
            return nil
        }
        let days = daysFromCivil(year: year, month: month, day: day)
        return days * 86_400 + hour * 3_600 + minute * 60 + second
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Hinnant's `days_from_civil`).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The civil date for a day count since 1970-01-01 (Hinnant's `civil_from_days`).
    static func civilFromDays(_ dayCount: Int) -> (year: Int, month: Int, day: Int) {
        let z = dayCount + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime + (monthPrime < 10 ? 3 : -9)
        return (year + (month <= 2 ? 1 : 0), month, day)
    }

    /// Length of a month, leap years included.
    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeapYear(year) ? 29 : 28
        default: return 0
        }
    }

    /// Proleptic Gregorian leap rule.
    static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    // MARK: Emission

    /// `2024-05-01T04:34:56Z` — the form `CMSearchDescription` bodies use.
    ///
    /// Fractional seconds are truncated, not rounded: a search window that rounds *up* past a
    /// segment boundary silently drops the first clip of the day.
    public static func iso8601UTC(_ date: Date) -> String {
        let parts = components(date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
                      parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second)
    }

    /// `20240501T043456Z` — the form RTSP playback query strings use.
    public static func compactUTC(_ date: Date) -> String {
        let parts = components(date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ",
                      parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second)
    }

    /// UTC civil components of `date`, seconds truncated toward the past.
    static func components(_ date: Date) -> (year: Int, month: Int, day: Int,
                                             hour: Int, minute: Int, second: Int) {
        let total = Int(date.timeIntervalSince1970.rounded(.down))
        var days = total / 86_400
        var remainder = total % 86_400
        if remainder < 0 {
            remainder += 86_400
            days -= 1
        }
        let civil = civilFromDays(days)
        return (civil.year, civil.month, civil.day,
                remainder / 3_600, (remainder % 3_600) / 60, remainder % 60)
    }

    // MARK: Timezone strings

    /// Parses Hikvision's POSIX-inverted zone string, e.g. `CST-8:00:00` ⇒ `+28800`.
    ///
    /// The sign is inverted relative to how a human reads it: POSIX writes the offset that must be
    /// *added to local time to get UTC*, so `-8` means UTC+8. Getting this backwards puts a
    /// Shanghai camera's recordings sixteen hours from where they are. Hours may be one or two
    /// digits; minutes and seconds are optional. Returns `nil` for anything else.
    public static func parseTimeZone(_ raw: String) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signIndex = text.firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        let posixSign = text[signIndex] == "-" ? -1 : 1
        let numbers = text[text.index(after: signIndex)...].split(separator: ":")
        guard let hoursText = numbers.first, let hours = Int(hoursText),
              (0...14).contains(hours) else { return nil }
        var seconds = hours * 3_600
        if numbers.count > 1 {
            guard let minutes = Int(numbers[1]), (0...59).contains(minutes) else { return nil }
            seconds += minutes * 60
        }
        if numbers.count > 2 {
            guard let trailing = Int(numbers[2]), (0...59).contains(trailing) else { return nil }
            seconds += trailing
        }
        // POSIX writes west-positive; the offset east of UTC is its negation.
        return -posixSign * seconds
    }

    // MARK: Scanning helpers

    /// Reads exactly `count` ASCII digits, advancing `index`. `nil` when they are not all digits.
    private static func digits(_ bytes: [UInt8], _ index: inout Int, _ count: Int) -> Int? {
        guard index + count <= bytes.count else { return nil }
        var value = 0
        for offset in 0..<count {
            let byte = bytes[index + offset]
            guard isDigit(byte) else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        index += count
        return value
    }

    /// ASCII digit test.
    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
}
