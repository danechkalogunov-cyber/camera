#if os(macOS)

import Foundation
import Testing
import VigilISAPI
import VigilProtocols
@testable import VigilCore

@Suite struct MotionRecordingPolicyTests {
    private let camera = CameraID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)

    @Test func armedTriggerStartsWithPreAndPostRoll() {
        var policy = MotionRecordingPolicy()
        let now = Date(timeIntervalSince1970: 1_000)
        let trigger = makeTrigger(at: now)
        #expect(policy.receive(trigger, isArmed: true)
            == .start(trigger, preRollSeconds: 10, stopAt: now.addingTimeInterval(15)))
    }

    @Test func repeatedTriggerExtendsInsteadOfStartingSecondClip() {
        var policy = MotionRecordingPolicy()
        let first = makeTrigger(at: Date(timeIntervalSince1970: 1_000))
        let second = makeTrigger(at: Date(timeIntervalSince1970: 1_010))
        _ = policy.receive(first, isArmed: true)
        #expect(policy.receive(second, isArmed: true)
            == .extend(second, stopAt: Date(timeIntervalSince1970: 1_025)))
        #expect(policy.advance(to: Date(timeIntervalSince1970: 1_016)).isEmpty)
    }

    @Test func cooldownRejectsSameKindThenExpires() {
        var policy = MotionRecordingPolicy()
        let first = makeTrigger(at: Date(timeIntervalSince1970: 1_000))
        _ = policy.receive(first, isArmed: true)
        #expect(policy.advance(to: Date(timeIntervalSince1970: 1_015)) == [.stop(cameraID: camera)])
        #expect(policy.receive(makeTrigger(at: Date(timeIntervalSince1970: 1_020)), isArmed: true)
            == .ignore)
        let later = makeTrigger(at: Date(timeIntervalSince1970: 1_036))
        guard case .start = policy.receive(later, isArmed: true) else {
            Issue.record("expected a new recording after cooldown")
            return
        }
    }

    @Test func unarmedAndUnselectedKindsAreIgnored() {
        var policy = MotionRecordingPolicy(
            configuration: MotionRecordingConfiguration(triggerKinds: [.motion]))
        #expect(policy.receive(makeTrigger(at: .now), isArmed: false) == .ignore)
        var tamper = makeTrigger(at: .now)
        tamper.kind = .tamper
        #expect(policy.receive(tamper, isArmed: true) == .ignore)
    }

    @Test func everyKindMergedIntoAClipReceivesCooldown() {
        var policy = MotionRecordingPolicy()
        let now = Date(timeIntervalSince1970: 1_000)
        _ = policy.receive(makeTrigger(at: now), isArmed: true)
        var intrusion = makeTrigger(at: now.addingTimeInterval(1))
        intrusion.kind = .intrusion
        _ = policy.receive(intrusion, isArmed: true)
        _ = policy.advance(to: now.addingTimeInterval(16))

        var retry = makeTrigger(at: now.addingTimeInterval(17))
        retry.kind = .intrusion
        #expect(policy.receive(retry, isArmed: true) == .ignore)
    }

    @Test func perCameraScheduleRejectsOutsideItsQuarterHourRange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let monday = Date(timeIntervalSince1970: 345_600)  // 1970-01-05 00:00 UTC.
        let schedule = MotionRecordingSchedule(
            weekdays: [2], ranges: [.init(startMinute: 9 * 60, endMinute: 17 * 60)])
        let configuration = MotionRecordingConfiguration(schedule: schedule)
        var policy = MotionRecordingPolicy()
        let outside = makeTrigger(at: monday.addingTimeInterval(8 * 3_600))
        let inside = makeTrigger(at: monday.addingTimeInterval(10 * 3_600))

        #expect(!schedule.allows(outside.occurredAt, calendar: calendar))
        #expect(schedule.allows(inside.occurredAt, calendar: calendar))
        #expect(policy.receive(outside, isArmed: true, configuration: configuration) == .ignore)
        guard case .start = policy.receive(inside, isArmed: true,
                                           configuration: configuration) else {
            Issue.record("expected the scheduled trigger to start")
            return
        }
    }

    private func makeTrigger(at date: Date) -> MotionRecordingTrigger {
        MotionRecordingTrigger(cameraID: camera, eventID: EventID(), kind: .motion,
                               occurredAt: date)
    }
}

#endif
