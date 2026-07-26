//
//  EventTriggers.swift
//  VigilISAPI
//
//  `GET /ISAPI/Event/triggers` and `GET /ISAPI/Event/schedules/{triggerID}`: which events the
//  device has configured, and when it is armed. Implements docs/spec-isapi.md §14.7 and §14.8.
//
//  Both are **read-only** in Vigil. Reconfiguring a customer's alarm actions is out of scope and
//  dangerous, so the `PUT` forms are deliberately not implemented; what these give us is the hint
//  "motion detection is off for this channel", which is the difference between a silent event feed
//  the user blames on Vigil and one they can fix.
//

import Foundation
import VigilProtocols

// MARK: - EventTrigger

/// One configured event source. `id` is `{eventType}-{channel}`, or
/// `{eventType}-{channel}-{index}` for an IO port.
public struct EventTrigger: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let kind: EventKind
    /// The device's own `eventType` string.
    public let rawType: String
    public let channel: ChannelID
    /// `email`, `record`, `beep`, `HTTP`, … verbatim.
    public let notificationMethods: [String]

    public init(id: String, kind: EventKind, rawType: String, channel: ChannelID,
                notificationMethods: [String]) {
        self.id = id
        self.kind = kind
        self.rawType = rawType
        self.channel = channel
        self.notificationMethods = notificationMethods
    }

    /// True when the device will actually do something when this event fires. An empty method list
    /// is what "motion detection is enabled but wired to nothing" looks like on the wire.
    public var isConfigured: Bool { !notificationMethods.isEmpty }

    /// Decodes every `<EventTrigger>` in an `<EventTriggerList>`.
    ///
    /// `dynVideoInputChannelID` wins over `videoInputChannelID` for the same reason
    /// `dynChannelID` does in an alert: on an NVR it is the channel the user sees.
    public static func list(document: ISAPIDocument) -> [EventTrigger] {
        let nodes = document.nodes("EventTrigger[]")
        let source = nodes.isEmpty ? [document.root] : nodes
        return source.compactMap { node in
            guard let rawType = node["eventType"].string else { return nil }
            let channel = node["dynVideoInputChannelID"].int ?? node["videoInputChannelID"].int ?? 0
            let methods = node
                .nodes("EventTriggerNotificationList/EventTriggerNotification[]")
                .compactMap { $0["notificationMethod"].string }
            return EventTrigger(id: node["id"].string ?? "\(rawType)-\(channel)",
                                kind: EventKind(raw: rawType),
                                rawType: rawType,
                                channel: ChannelID(channel),
                                notificationMethods: methods)
        }
    }
}

// MARK: - EventSchedule

/// A trigger's arming schedule. Best-effort: a 403 or 404 means "unknown", and the UI shows
/// nothing rather than an error.
public struct EventSchedule: Sendable, Hashable, Codable {

    /// One armed window.
    public struct Block: Sendable, Hashable, Codable {
        /// 1 = Monday … 7 = Sunday.
        public let weekday: Int
        /// Seconds from midnight, 0…86400.
        public let startSeconds: Int
        /// Seconds from midnight. `24:00:00` is legal and means end-of-day, i.e. 86400.
        public let endSeconds: Int

        public init(weekday: Int, startSeconds: Int, endSeconds: Int) {
            self.weekday = weekday
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
        }
    }

    public let triggerID: String
    public let blocks: [Block]

    public init(triggerID: String, blocks: [Block]) {
        self.triggerID = triggerID
        self.blocks = blocks
    }

    /// True when all seven days are covered end to end — the common case, and the one where the UI
    /// says nothing at all rather than drawing a schedule.
    public var isAlwaysArmed: Bool {
        let covered = Set(blocks.filter { $0.startSeconds <= 0 && $0.endSeconds >= 86400 }
            .map(\.weekday))
        return covered.count >= 7
    }

    /// Decodes an `<EventSchedule>` document.
    public init(document: ISAPIDocument) {
        let blocks = document.nodes("TimeBlockList/TimeBlock[]").compactMap { block -> Block? in
            guard let weekday = Self.weekday(block["dayOfWeek"].string) else { return nil }
            guard let begin = Self.seconds(block["TimeRange/beginTime"].string),
                  let end = Self.seconds(block["TimeRange/endTime"].string) else { return nil }
            return Block(weekday: weekday, startSeconds: begin, endSeconds: end)
        }
        self.init(triggerID: document["id"].string ?? "", blocks: blocks)
    }

    /// Maps a day name, accepting the numeric form some firmware sends instead.
    static func weekday(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        if let numeric = Int(raw), (1...7).contains(numeric) { return numeric }
        let names = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        guard let index = names.firstIndex(of: raw.lowercased()) else { return nil }
        return index + 1
    }

    /// Parses `HH:mm:ss` into seconds from midnight. `24:00:00` maps to 86400.
    static func seconds(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        let hours = parts[0]
        let minutes = parts[1]
        let secondsPart = parts.count > 2 ? parts[2] : 0
        guard (0...24).contains(hours), (0...59).contains(minutes),
              (0...59).contains(secondsPart) else { return nil }
        return min(86400, hours * 3600 + minutes * 60 + secondsPart)
    }
}
