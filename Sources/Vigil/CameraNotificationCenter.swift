//
//  CameraNotificationCenter.swift
//  Vigil
//
//  User notification delivery and per-camera watch/quiet-hours policy.
//

#if os(macOS)

import Foundation
import UserNotifications

import VigilCore
import VigilProtocols

/// User-controlled notification policy. Quiet hours may cross midnight.
struct CameraWatchPolicy: Sendable, Equatable {
    var watchedCameraIDs: Set<CameraID> = []
    var quietStartHour: Int?
    var quietEndHour: Int?

    func permits(cameraID: CameraID, at date: Date, calendar: Calendar = .current) -> Bool {
        guard watchedCameraIDs.contains(cameraID) else { return false }
        guard let start = quietStartHour, let end = quietEndHour, start != end else { return true }
        let hour = calendar.component(.hour, from: date)
        let quiet = start < end ? (start..<end).contains(hour) : hour >= start || hour < end
        return !quiet
    }
}

/// The single gateway for macOS alerts, keeping notification text and attachment handling testable.
@MainActor
final class CameraNotificationCenter {
    var policy = CameraWatchPolicy()
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func post(event: EventRecord, camera: Camera, thumbnailURL: URL? = nil) async {
        guard policy.permits(cameraID: camera.id, at: Date()) else { return }
        let content = UNMutableNotificationContent()
        content.title = camera.displayName
        content.body = event.rawEventType.isEmpty ? "Camera event" : event.rawEventType
        content.sound = .default
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
        guard policy.permits(cameraID: camera.id, at: Date()) else { return }
        let content = UNMutableNotificationContent()
        content.title = camera.displayName
        content.body = "Camera lost"
        content.categoryIdentifier = "VIGIL_CAMERA_LOST"
        content.sound = .defaultCritical
        try? await center.add(UNNotificationRequest(identifier: "camera-lost-\(camera.id.rawValue)",
                                                    content: content, trigger: nil))
    }
}

#endif
