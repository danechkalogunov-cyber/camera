//
//  CameraNotificationCenter.swift
//  Vigil
//
//  User notification delivery and per-camera watch/quiet-hours policy.
//

#if os(macOS)

import Foundation
import UserNotifications
import AppKit

import VigilCore
import VigilProtocols

/// User-controlled notification policy. Quiet hours may cross midnight.
struct CameraWatchPolicy: Sendable, Equatable {
    var watchedCameraIDs: Set<CameraID> = []
    var quietStartHour: Int?
    var quietEndHour: Int?
    var enabledEventTypes: Set<String> = []
    var suppressesVisibleWhenFrontmost = true
    var perCameraInterval: TimeInterval = 60
    var globalPerMinuteLimit = 10

    func permits(cameraID: CameraID, at date: Date, calendar: Calendar = .current) -> Bool {
        guard watchedCameraIDs.contains(cameraID) else { return false }
        guard let start = quietStartHour, let end = quietEndHour, start != end else { return true }
        let hour = calendar.component(.hour, from: date)
        let quiet = start < end ? (start..<end).contains(hour) : hour >= start || hour < end
        return !quiet
    }

    func permits(eventType: String) -> Bool {
        enabledEventTypes.isEmpty || enabledEventTypes.contains(eventType.lowercased())
    }
}

struct CameraNotificationRateLimiter: Sendable {
    private(set) var lastPostedByCamera: [CameraID: Date] = [:]
    private(set) var globallyPosted: [Date] = []

    mutating func permits(cameraID: CameraID, at now: Date,
                          policy: CameraWatchPolicy) -> Bool {
        if let previous = lastPostedByCamera[cameraID],
           now.timeIntervalSince(previous) < policy.perCameraInterval { return false }
        globallyPosted.removeAll { now.timeIntervalSince($0) >= 60 }
        guard globallyPosted.count < policy.globalPerMinuteLimit else { return false }
        lastPostedByCamera[cameraID] = now
        globallyPosted.append(now)
        return true
    }
}

/// The single gateway for macOS alerts, keeping notification text and attachment handling testable.
@MainActor
final class CameraNotificationCenter {
    static let eventCategory = "VIGIL_CAMERA_EVENT"
    static let cameraLostCategory = "VIGIL_CAMERA_LOST"
    static let viewLiveAction = "VIGIL_VIEW_LIVE"
    static let playBackAction = "VIGIL_PLAY_BACK"

    var policy = CameraWatchPolicy()
    private let center: UNUserNotificationCenter
    private var rateLimiter = CameraNotificationRateLimiter()
    var visibleCameraIDs: Set<CameraID> = []

    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func post(event: EventRecord, camera: Camera, thumbnailURL: URL? = nil) async {
        let now = Date()
        guard policy.permits(cameraID: camera.id, at: now),
              policy.permits(eventType: event.rawEventType),
              !(policy.suppressesVisibleWhenFrontmost && NSApp.isActive
                && visibleCameraIDs.contains(camera.id)),
              consumeRateLimit(for: camera.id, at: now) else { return }
        let content = UNMutableNotificationContent()
        content.title = camera.displayName
        content.body = event.rawEventType.isEmpty ? "Camera event" : event.rawEventType
        content.sound = .default
        content.categoryIdentifier = Self.eventCategory
        content.userInfo = ["cameraID": camera.id.rawValue.uuidString,
                            "occurredAt": event.lastAt.timeIntervalSince1970]
        if let thumbnailURL,
           let attachment = try? UNNotificationAttachment(identifier: "thumbnail",
                                                           url: thumbnailURL) {
            content.attachments = [attachment]
        }
        try? await center.add(UNNotificationRequest(identifier: "event-\(event.id.rawValue)",
                                                    content: content, trigger: nil))
    }

    /// A separate category and stable identifier make loss alerts distinguishable and replaceable.
    func postCameraLost(_ camera: Camera) async {
        let now = Date()
        guard policy.permits(cameraID: camera.id, at: now),
              consumeRateLimit(for: camera.id, at: now) else { return }
        let content = UNMutableNotificationContent()
        content.title = camera.displayName
        content.body = "Camera lost"
        content.categoryIdentifier = Self.cameraLostCategory
        content.userInfo = ["cameraID": camera.id.rawValue.uuidString]
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: "camera-lost-\(camera.id.rawValue)",
                                                    content: content, trigger: nil))
    }

    private func consumeRateLimit(for cameraID: CameraID, at now: Date) -> Bool {
        rateLimiter.permits(cameraID: cameraID, at: now, policy: policy)
    }
}

#endif
