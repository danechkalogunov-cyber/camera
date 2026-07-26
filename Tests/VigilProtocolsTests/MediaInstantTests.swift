//
//  MediaInstantTests.swift
//  VigilProtocolsTests
//
//  The monotonic instant type, the `Duration` conversion helpers, and the `MonotonicClock` default
//  `sleep(until:)`. Covers docs/API_CONTRACT.md §3.2.
//
//  Nothing here reads a real clock: `StubMonotonicClock` returns a fixed instant and records the
//  durations it was asked to sleep for, so the suite is independent of wall-clock time.
//

import Foundation
import Testing
import VigilProtocols

@Suite struct MediaInstantTests {

    // MARK: - Construction and ordering

    @Test func mediaInstantZeroIsTheNanosecondOrigin() {
        #expect(MediaInstant.zero.nanoseconds == 0)
        #expect(MediaInstant.zero.seconds == 0)
        #expect(MediaInstant.zero.description == "0.0s")
    }

    @Test func mediaInstantOrdersByNanoseconds() {
        #expect(MediaInstant(nanoseconds: 1) < MediaInstant(nanoseconds: 2))
        #expect(MediaInstant(nanoseconds: -1) < MediaInstant.zero)
        #expect(!(MediaInstant(nanoseconds: 5) < MediaInstant(nanoseconds: 5)))
    }

    @Test func mediaInstantConvertsToSecondsAndMilliseconds() {
        let origin = MediaInstant.zero
        let later = MediaInstant(nanoseconds: 1_500_000_000)
        #expect(later.seconds(since: origin) == 1.5)
        #expect(later.milliseconds(since: origin) == 1_500)
        #expect(origin.milliseconds(since: later) == -1_500)
    }

    @Test func mediaInstantRoundTripsThroughCodable() throws {
        let original = MediaInstant(nanoseconds: 123_456_789)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MediaInstant.self, from: encoded)
        #expect(decoded == original)
    }

    // MARK: - Arithmetic with Duration

    @Test func mediaInstantAddsAndSubtractsDurations() {
        let base = MediaInstant(nanoseconds: 1_000_000_000)
        #expect((base + .milliseconds(400)).nanoseconds == 1_400_000_000)
        #expect((base - .milliseconds(400)).nanoseconds == 600_000_000)
        #expect((base + .seconds(-1)).nanoseconds == 0)
    }

    @Test func mediaInstantDifferenceIsADuration() {
        let start = MediaInstant(nanoseconds: 1_000_000_000)
        let end = MediaInstant(nanoseconds: 1_250_000_000)
        #expect(end - start == Duration.milliseconds(250))
        #expect(start - end == Duration.milliseconds(-250))
        #expect((end - start).milliseconds == 250)
    }

    @Test func mediaInstantSurvivesALongUptimeWithoutLosingPrecision() {
        // 100 days of uptime in nanoseconds is well inside Int64 and still exact as an integer.
        let hundredDays = MediaInstant(nanoseconds: 100 * 24 * 60 * 60 * 1_000_000_000)
        let oneTickLater = hundredDays + .nanoseconds(1)
        #expect(oneTickLater.nanoseconds - hundredDays.nanoseconds == 1)
        #expect(hundredDays < oneTickLater)
    }
}

@Suite struct DurationConversionTests {

    @Test func durationWholeNanosecondsConvertsSecondsAndSubsecondParts() {
        #expect(Duration.seconds(1).wholeNanoseconds == 1_000_000_000)
        #expect(Duration.milliseconds(400).wholeNanoseconds == 400_000_000)
        #expect(Duration.microseconds(1).wholeNanoseconds == 1_000)
        #expect(Duration.nanoseconds(7).wholeNanoseconds == 7)
        #expect(Duration.zero.wholeNanoseconds == 0)
    }

    @Test func durationWholeNanosecondsTruncatesTowardZeroBelowOneNanosecond() {
        // Attoseconds below 1 ns are dropped, in both directions.
        #expect((Duration.nanoseconds(1) + Duration(secondsComponent: 0,
                                                    attosecondsComponent: 900_000_000))
                    .wholeNanoseconds == 1)
        #expect(Duration(secondsComponent: 0, attosecondsComponent: 999_999_999)
                    .wholeNanoseconds == 0)
    }

    @Test func durationWholeNanosecondsIsNegativeForNegativeDurations() {
        #expect(Duration.seconds(-1).wholeNanoseconds == -1_000_000_000)
        #expect(Duration.milliseconds(-250).wholeNanoseconds == -250_000_000)
    }

    @Test func durationWholeNanosecondsSaturatesInsteadOfWrapping() {
        // 300 years of nanoseconds does not fit in Int64; it must clamp, never flip sign.
        let tooLarge = Duration.seconds(400 * 365 * 24 * 60 * 60)
        #expect(tooLarge.wholeNanoseconds == Int64.max)
        #expect(Duration.seconds(-400 * 365 * 24 * 60 * 60).wholeNanoseconds == Int64.min)
        // The exact boundary: Int64.max ns is 9 223 372 036.854775807 s.
        let justOver = Duration.seconds(9_223_372_036) + Duration.nanoseconds(999_999_999)
        #expect(justOver.wholeNanoseconds == Int64.max)
    }

    @Test func durationMillisecondsAndSecondsAreDoubles() {
        #expect(Duration.milliseconds(1_500).seconds == 1.5)
        #expect(Duration.seconds(2).milliseconds == 2_000)
        #expect(Duration.microseconds(500).milliseconds == 0.5)
    }
}

// MARK: - Clock stubs

/// Records what it was asked to sleep for; never actually suspends for a measurable time.
private actor SleepRecorder {

    private(set) var requests: [Duration] = []

    func record(_ duration: Duration) { requests.append(duration) }
}

/// A clock frozen at a fixed instant. `sleep(for:)` records and returns immediately.
private struct StubMonotonicClock: MonotonicClock {

    let instant: MediaInstant
    let recorder: SleepRecorder

    func now() -> MediaInstant { instant }

    func sleep(for duration: Duration) async throws { await recorder.record(duration) }
}

@Suite struct MonotonicClockDefaultsTests {

    @Test func monotonicClockSleepUntilFutureDeadlineSleepsForTheRemainder() async throws {
        let recorder = SleepRecorder()
        let clock = StubMonotonicClock(instant: MediaInstant(nanoseconds: 1_000_000_000),
                                       recorder: recorder)
        try await clock.sleep(until: MediaInstant(nanoseconds: 1_400_000_000))
        let requests = await recorder.requests
        #expect(requests == [.milliseconds(400)])
    }

    @Test func monotonicClockSleepUntilPastDeadlineDoesNotSleep() async throws {
        let recorder = SleepRecorder()
        let clock = StubMonotonicClock(instant: MediaInstant(nanoseconds: 2_000_000_000),
                                       recorder: recorder)
        try await clock.sleep(until: MediaInstant(nanoseconds: 1_000_000_000))
        try await clock.sleep(until: MediaInstant(nanoseconds: 2_000_000_000))  // exactly now
        let requests = await recorder.requests
        #expect(requests.isEmpty)
    }

    @Test func systemMonotonicClockNeverGoesBackwards() {
        let clock = SystemMonotonicClock()
        let first = clock.now()
        let second = clock.now()
        #expect(second >= first)
        #expect(first.nanoseconds >= 0, "readings are measured from a process epoch")
    }
}
