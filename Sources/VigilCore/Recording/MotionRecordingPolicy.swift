//
//  MotionRecordingPolicy.swift
//  VigilCore
//
//  Pure hysteresis/cooldown policy for device-triggered recording.
//

#if os(macOS)

import Foundation
import VigilISAPI
import VigilProtocols

/// Configuration for one armed camera.
public struct MotionRecordingSchedule: Sendable, Hashable, Codable {
    public struct Range: Sendable, Hashable, Codable {
        public var startMinute: Int
        public var endMinute: Int

        public init(startMinute: Int, endMinute: Int) {
            self.startMinute = min(max(startMinute, 0), 1_439)
            self.endMinute = min(max(endMinute, 0), 1_440)
        }

        fileprivate func contains(_ minute: Int) -> Bool {
            if startMinute < endMinute { return startMinute <= minute && minute < endMinute }
            if startMinute > endMinute { return minute >= startMinute || minute < endMinute }
            return false
        }
    }

    /// Calendar weekday values, Sunday = 1 through Saturday = 7.
    public var weekdays: Set<Int>
    public var ranges: [Range]

    public init(weekdays: Set<Int> = Set(1...7), ranges: [Range] = [Range(startMinute: 0,
                                                                           endMinute: 1_440)]) {
        self.weekdays = Set(weekdays.filter { (1...7).contains($0) })
        self.ranges = ranges
    }

    public func allows(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, weekdays.contains(weekday),
              let hour = parts.hour, let minute = parts.minute else { return false }
        return ranges.contains { $0.contains(hour * 60 + minute) }
    }
}

public struct MotionRecordingConfiguration: Sendable, Hashable, Codable {
    public var triggerKinds: Set<EventKind>
    public var preRollSeconds: Double
    public var postRollSeconds: Double
    public var cooldownSeconds: Double
    public var schedule: MotionRecordingSchedule?

    public init(triggerKinds: Set<EventKind> = [.motion, .pir, .lineCrossing, .intrusion,
                                                .regionEntrance, .regionExit, .tamper, .videoLoss],
                preRollSeconds: Double = 10,
                postRollSeconds: Double = 15,
                cooldownSeconds: Double = 20,
                schedule: MotionRecordingSchedule? = nil) {
        self.triggerKinds = triggerKinds
        self.preRollSeconds = min(max(preRollSeconds, 0), 30)
        self.postRollSeconds = min(max(postRollSeconds, 0), 120)
        self.cooldownSeconds = min(max(cooldownSeconds, 0), 300)
        self.schedule = schedule
    }
}

public struct MotionRecordingTrigger: Sendable, Hashable {
    public var cameraID: CameraID
    public var eventID: EventID
    public var kind: EventKind
    public var occurredAt: Date

    public init(cameraID: CameraID, eventID: EventID, kind: EventKind, occurredAt: Date) {
        self.cameraID = cameraID
        self.eventID = eventID
        self.kind = kind
        self.occurredAt = occurredAt
    }
}

public enum MotionRecordingAction: Sendable, Hashable {
    case start(MotionRecordingTrigger, preRollSeconds: Double, stopAt: Date)
    case extend(MotionRecordingTrigger, stopAt: Date)
    case stop(cameraID: CameraID)
    case ignore
}

/// Stateful but deterministic policy. File writing remains outside this type.
public struct MotionRecordingPolicy: Sendable {
    private struct Active: Sendable {
        var kinds: Set<EventKind>
        var stopAt: Date
        var cooldownSeconds: Double
    }

    public var configuration: MotionRecordingConfiguration
    private var active: [CameraID: Active] = [:]
    private var cooldownUntil: [CameraID: [EventKind: Date]] = [:]

    public init(configuration: MotionRecordingConfiguration = .init()) {
        self.configuration = configuration
    }

    public mutating func receive(_ trigger: MotionRecordingTrigger,
                                 isArmed: Bool,
                                 configuration override: MotionRecordingConfiguration? = nil)
        -> MotionRecordingAction {
        let configuration = override ?? self.configuration
        guard isArmed, configuration.triggerKinds.contains(trigger.kind),
              configuration.schedule?.allows(trigger.occurredAt) != false else { return .ignore }
        let stopAt = trigger.occurredAt.addingTimeInterval(configuration.postRollSeconds)
        if var current = active[trigger.cameraID] {
            current.kinds.insert(trigger.kind)
            current.stopAt = max(current.stopAt, stopAt)
            active[trigger.cameraID] = current
            return .extend(trigger, stopAt: current.stopAt)
        }
        if let until = cooldownUntil[trigger.cameraID]?[trigger.kind], trigger.occurredAt < until {
            return .ignore
        }
        active[trigger.cameraID] = Active(kinds: [trigger.kind], stopAt: stopAt,
                                          cooldownSeconds: configuration.cooldownSeconds)
        return .start(trigger, preRollSeconds: configuration.preRollSeconds, stopAt: stopAt)
    }

    /// Emits stops that became due. Calling repeatedly at the same instant is idempotent.
    public mutating func advance(to now: Date) -> [MotionRecordingAction] {
        let due = active.filter { $0.value.stopAt <= now }.sorted {
            $0.key.rawValue.uuidString < $1.key.rawValue.uuidString
        }
        var actions: [MotionRecordingAction] = []
        for (cameraID, current) in due {
            active.removeValue(forKey: cameraID)
            let until = now.addingTimeInterval(current.cooldownSeconds)
            for kind in current.kinds {
                cooldownUntil[cameraID, default: [:]][kind] = until
            }
            actions.append(.stop(cameraID: cameraID))
        }
        return actions
    }

    public mutating func disarm(_ cameraID: CameraID) -> MotionRecordingAction {
        guard active.removeValue(forKey: cameraID) != nil else { return .ignore }
        return .stop(cameraID: cameraID)
    }
}

#endif
