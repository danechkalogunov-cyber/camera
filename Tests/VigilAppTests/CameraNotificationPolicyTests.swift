#if os(macOS)

import Foundation
import Testing

@testable import Vigil
import VigilProtocols

@Suite("Camera notification policy")
struct CameraNotificationPolicyTests {
    @Test func quietHoursMayCrossMidnight() {
        let camera = CameraID()
        var policy = CameraWatchPolicy(watchedCameraIDs: [camera], quietStartHour: 22,
                                       quietEndHour: 7)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        func date(hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: hour)) ?? Date()
        }
        let duringEveningQuiet = policy.permits(cameraID: camera, at: date(hour: 23),
                                                calendar: calendar)
        let duringMorningQuiet = policy.permits(cameraID: camera, at: date(hour: 6),
                                                calendar: calendar)
        let duringDay = policy.permits(cameraID: camera, at: date(hour: 12), calendar: calendar)
        #expect(!duringEveningQuiet)
        #expect(!duringMorningQuiet)
        #expect(duringDay)

        policy.quietStartHour = 7
        policy.quietEndHour = 7
        let equalBoundsDisableQuietHours = policy.permits(cameraID: camera,
                                                         at: date(hour: 7), calendar: calendar)
        #expect(equalBoundsDisableQuietHours)

        policy.enabledEventTypes = ["vmd"]
        let motionAllowed = policy.permits(eventType: "VMD")
        let diskFullAllowed = policy.permits(eventType: "diskfull")
        #expect(motionAllowed)
        #expect(!diskFullAllowed)
    }

    @Test func rateLimitsPerCameraAndGlobally() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var policy = CameraWatchPolicy()
        policy.perCameraInterval = 60
        policy.globalPerMinuteLimit = 2
        var limiter = CameraNotificationRateLimiter()
        let first = CameraID(), second = CameraID(), third = CameraID()

        let firstPost = limiter.permits(cameraID: first, at: start, policy: policy)
        let repeatedTooSoon = limiter.permits(cameraID: first,
                                              at: start.addingTimeInterval(59), policy: policy)
        let secondPost = limiter.permits(cameraID: second, at: start, policy: policy)
        let beyondGlobalLimit = limiter.permits(cameraID: third, at: start, policy: policy)
        let afterWindow = limiter.permits(cameraID: first,
                                          at: start.addingTimeInterval(60), policy: policy)
        #expect(firstPost)
        #expect(!repeatedTooSoon)
        #expect(secondPost)
        #expect(!beyondGlobalLimit)
        #expect(afterWindow)
    }
}

#endif
