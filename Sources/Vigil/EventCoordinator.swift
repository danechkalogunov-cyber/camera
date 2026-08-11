//
//  EventCoordinator.swift
//  Vigil
//
//  Subscribes to the camera's ISAPI alert stream and publishes what it reports.
//  macOS-only. See docs/spec-isapi.md and docs/UX.md §9.1.
//

#if os(macOS)

import Foundation
import Observation
import os

import VigilCore
import VigilISAPI
import VigilProtocols
import VigilUI

// MARK: - EventCoordinator

/// Keeps the event feed alive for the live camera.
///
/// **What this connects.** `AlertStreamMonitor` (ISAPI), `EventMonitorService`, `EventStore` and
/// `EventCoalescer` were all written and none of them was ever called: nothing built a monitor,
/// nothing reconciled a subscription, and the Events screen therefore had no source at all. This is
/// the missing link — the app layer is the only place that knows how to build an `ISAPIRequesting`,
/// which is exactly why `EventMonitorFactory` is a closure rather than a protocol.
///
/// **Why it does not own the stream's reliability.** Reconnection, backoff, the unsupported-device
/// ladder and duplicate suppression all live in `EventMonitorService` and are already tested. This
/// type supplies a monitor when asked for one, points the service at the current camera, and drains
/// the store into the shape the screen reads.
@MainActor
@Observable
final class EventCoordinator {

    struct Preview: Identifiable, Sendable, Hashable {
        let id: UUID
        let cameraID: CameraID
        let cameraName: String
        let eventLabel: String
        let thumbnailURL: URL?
    }

    // MARK: - Observable State

    /// The most recent events, newest first, ready for `VLibraryState.events`.
    private(set) var events: [VLibraryEvent] = []

    /// How many have not been looked at. Feeds the sidebar's badge.
    private(set) var unreadCount = 0

    /// Changes whenever one or more device events are queued for recording. The queue prevents
    /// SwiftUI observation coalescing several alerts into only the final property value.
    private(set) var recordingTriggerRevision: UInt64 = 0

    /// Four-second in-app preview for the newest event.
    private(set) var preview: Preview?

    // MARK: - Stored Properties

    private let store: EventStore
    private let service: EventMonitorService
    private let credentials: CredentialStore
    private let dependencies: CoreDependencies
    private let notifications = CameraNotificationCenter()
    private let thumbnails: EventThumbnailStore
    private var drain: Task<Void, Never>?
    private var publishedEventIDs: Set<EventID> = []
    private var recordingEventLastAt: [EventID: Date] = [:]
    private var hasNotificationBaseline = false
    private var monitoredCameras: [Camera] = []
    private var displayedCameraID: CameraID?
    private var pendingRecordingTriggers: [MotionRecordingTrigger] = []
    private var previewTask: Task<Void, Never>?

    /// The camera the factory builds credentials for. `CredentialStore` looks a password up by
    /// `Camera`, while `EventMonitorFactory` is handed only a device key, so the current camera has
    /// to be reachable from inside the closure.
    private let followed = OSAllocatedUnfairLock<[EventDeviceKey: Camera]>(initialState: [:])

    // MARK: - Initialisation

    /// Creates a coordinator over the app's dependencies.
    ///
    /// - Parameters:
    ///   - dependencies: clock, logger and the rest of the app's shared services.
    ///   - credentials: the Keychain actor, read per monitor and never captured with its secret.
    init(dependencies: CoreDependencies, credentials: CredentialStore) {
        self.dependencies = dependencies
        self.credentials = credentials
        let store = EventStore(clock: dependencies.clock,
                               wallClock: SystemWallClock(),
                               logger: dependencies.logger)
        self.store = store
        let thumbnails = EventThumbnailStore(logger: dependencies.logger)
        self.thumbnails = thumbnails

        let clock = dependencies.clock
        let logger = dependencies.logger
        let random = dependencies.random
        // The factory answers `nil` when it cannot build a monitor — no password yet, most often —
        // and `EventMonitorService` treats that as "try again later" rather than as a failure.
        self.service = EventMonitorService(
            store: store,
            clock: clock,
            random: random,
            logger: logger,
            snapshotSink: { eventID, _, data in
                _ = await thumbnails.save(data, eventID: eventID)
            },
            makeMonitor: { [credentials, followed] key in
                guard let camera = followed.withLock({ $0[key] }),
                      let credential = try? await credentials.credential(for: camera) else {
                    // No password yet, or the key is for a camera we are no longer following.
                    // `EventMonitorService` reads `nil` as "not buildable yet" and retries.
                    return nil
                }
                let endpoint = ISAPIEndpoint(host: key.host, port: key.port, useTLS: key.useTLS)
                let configuration = ISAPIClient.Configuration()
                let client = ISAPIClient(
                    endpoint: endpoint,
                    credential: credential,
                    configuration: configuration,
                    transport: URLSessionHTTPTransport(configuration: configuration, logger: logger),
                    clock: clock,
                    logger: logger)
                return AlertStreamMonitor(requests: client,
                                          clock: clock,
                                          wallClock: SystemWallClock(),
                                          random: random,
                                          logger: logger)
            })
    }

    // MARK: - API

    /// Points the feed at a camera, or stops it when there is none.
    ///
    /// Idempotent: `reconcile` refreshes an existing subscription's channel map rather than building
    /// a second one, which is what stops every event arriving twice.
    func follow(camera: Camera?) async {
        await follow(cameras: camera.map { [$0] } ?? [], displaying: camera?.id)
    }

    /// Keeps event monitors alive for the displayed camera and every motion-armed background
    /// camera. The feed still renders only `displaying`; recording triggers are published for all.
    func follow(cameras: [Camera], displaying cameraID: CameraID?) async {
        var unique: [CameraID: Camera] = [:]
        for camera in cameras { unique[camera.id] = camera }
        monitoredCameras = unique.values.sorted {
            $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
        displayedCameraID = cameraID
        notifications.visibleCameraIDs = Set(cameraID.map { [$0] } ?? [])
        let monitored = monitoredCameras
        followed.withLock { state in
            state.removeAll(keepingCapacity: true)
            for camera in monitored where state[EventDeviceKey(camera: camera)] == nil {
                state[EventDeviceKey(camera: camera)] = camera
            }
        }
        publishedEventIDs.removeAll()
        recordingEventLastAt.removeAll()
        hasNotificationBaseline = false
        guard !monitoredCameras.isEmpty else {
            await service.stopAll()
            events = []
            unreadCount = 0
            return
        }
        await service.reconcile(cameras: monitoredCameras)
        startDraining()
    }

    /// Enables/disables the explicit “watch this camera” mode and applies optional quiet hours.
    func setWatching(_ enabled: Bool, camera: Camera,
                     quietHours: (start: Int, end: Int)? = nil) async {
        if enabled {
            notifications.policy.watchedCameraIDs.insert(camera.id)
            notifications.policy.quietStartHour = quietHours?.start
            notifications.policy.quietEndHour = quietHours?.end
            await notifications.requestAuthorization()
        } else {
            notifications.policy.watchedCameraIDs.remove(camera.id)
        }
    }

    /// Restores persisted choices without prompting at launch. Authorization was requested at the
    /// moment each camera was originally enabled; restoring a preference must not raise a prompt.
    func restoreWatching(_ cameraIDs: Set<CameraID>) {
        notifications.policy.watchedCameraIDs = cameraIDs
    }

    func cameraLost(_ camera: Camera?) async {
        guard let camera else { return }
        await notifications.postCameraLost(camera)
    }

    func takeRecordingTriggers() -> [MotionRecordingTrigger] {
        defer { pendingRecordingTriggers.removeAll(keepingCapacity: true) }
        return pendingRecordingTriggers
    }

    /// Dismisses the transient preview without touching the event or its notification.
    func dismissPreview() {
        previewTask?.cancel()
        previewTask = nil
        preview = nil
    }

    /// Forgets one event.
    ///
    /// **Local only.** UX.md §9.1 is explicit that deleting an event never touches the device — the
    /// camera's own log is the camera's, and an app that could quietly erase it would be the wrong
    /// tool to hand a security operator. This removes Vigil's copy and nothing else.
    func delete(_ id: UUID, camera: Camera?) async {
        await store.delete([EventID(id)])
        await thumbnails.remove(EventID(id))
        guard let camera else { return }
        await refresh(camera: camera)
    }

    /// Marks everything currently shown as read, which is what clears the sidebar's badge.
    func markAllRead(camera: Camera?) async {
        await store.markRead(Set(events.map { EventID($0.id) }))
        guard let camera else { return }
        await refresh(camera: camera)
    }

    /// Stops the feed and releases the subscription.
    func stop() async {
        previewTask?.cancel()
        previewTask = nil
        preview = nil
        drain?.cancel()
        drain = nil
        await service.stopAll()
    }

    // MARK: - Private Helpers

    /// Republishes the store whenever the service reports something.
    ///
    /// Driven by the service's own event stream rather than a timer: the store only changes when an
    /// alert lands, and polling it once a second would burn a hop for nothing on a camera that is
    /// quiet — which is most cameras, most of the time.
    private func startDraining() {
        drain?.cancel()
        let service = service
        drain = Task { [weak self] in
            await self?.refreshMonitoredCameras()
            for await _ in service.events() {
                guard let self else { return }
                await self.refreshMonitoredCameras()
            }
        }
    }

    private func refreshMonitoredCameras() async {
        var rows: [CameraID: [EventRecord]] = [:]
        for camera in monitoredCameras {
            rows[camera.id] = await store.recent(cameraID: camera.id, limit: 200)
        }
        if !hasNotificationBaseline {
            let baseline = rows.values.flatMap { $0 }
            publishedEventIDs.formUnion(baseline.map(\.id))
            for record in baseline { recordingEventLastAt[record.id] = record.lastAt }
            hasNotificationBaseline = true
        } else {
            for camera in monitoredCameras {
                for record in rows[camera.id, default: []] {
                    if publishedEventIDs.insert(record.id).inserted {
                        let thumbnail = await thumbnails.existingURL(for: record.id)
                        await notifications.post(event: record, camera: camera,
                                                 thumbnailURL: thumbnail)
                        showPreview(event: record, camera: camera, thumbnailURL: thumbnail)
                    }
                    if recordingEventLastAt[record.id].map({ record.lastAt > $0 }) ?? true {
                        recordingEventLastAt[record.id] = record.lastAt
                        enqueueRecordingTrigger(MotionRecordingTrigger(
                            cameraID: camera.id, eventID: record.id, kind: record.kind,
                            occurredAt: record.lastAt))
                    }
                }
            }
        }
        unreadCount = await store.unreadCount()
        guard let displayedCameraID,
              let camera = monitoredCameras.first(where: { $0.id == displayedCameraID }) else {
            events = []
            return
        }
        events = Self.present(rows[camera.id, default: []], camera: camera)
    }

    private func showPreview(event: EventRecord, camera: Camera, thumbnailURL: URL?) {
        previewTask?.cancel()
        preview = Preview(id: event.id.rawValue, cameraID: camera.id,
                          cameraName: camera.displayName,
                          eventLabel: event.rawEventType.isEmpty ? "Camera event" : event.rawEventType,
                          thumbnailURL: thumbnailURL)
        let previewID = event.id.rawValue
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, self?.preview?.id == previewID else { return }
            self?.preview = nil
        }
    }

    /// Reads the store into the screen's shape.
    private func refresh(camera: Camera) async {
        let records = await store.recent(cameraID: camera.id, limit: 200)
        let incoming = hasNotificationBaseline ? records.filter { !publishedEventIDs.contains($0.id) } : []
        let recordingUpdates = hasNotificationBaseline ? records.filter { record in
            recordingEventLastAt[record.id].map { record.lastAt > $0 } ?? true
        } : []
        publishedEventIDs.formUnion(records.map(\.id))
        for record in records { recordingEventLastAt[record.id] = record.lastAt }
        hasNotificationBaseline = true
        for record in incoming {
            let thumbnail = await thumbnails.existingURL(for: record.id)
            await notifications.post(event: record, camera: camera, thumbnailURL: thumbnail)
            showPreview(event: record, camera: camera, thumbnailURL: thumbnail)
        }
        for record in recordingUpdates {
            enqueueRecordingTrigger(MotionRecordingTrigger(cameraID: camera.id,
                                                            eventID: record.id,
                                                            kind: record.kind,
                                                            occurredAt: record.lastAt))
        }
        let unread = await store.unreadCount()
        events = Self.present(records, camera: camera)
        unreadCount = unread
    }

    private static func present(_ records: [EventRecord], camera: Camera) -> [VLibraryEvent] {
        let source = VLibraryCamera(id: camera.id, name: camera.displayName)
        return records.map { record in
            VLibraryEvent(id: record.id.rawValue,
                          camera: source,
                          // The device's own instant, not when Vigil heard about it: the two differ
                          // by the stream's latency, and grouping on the wrong one puts an event on
                          // the wrong day.
                          occurredAt: record.deviceTime,
                          kind: Self.kind(for: record.kind),
                          label: Self.label(for: record),
                          durationSeconds: record.lastAt > record.firstAt
                              ? record.lastAt.timeIntervalSince(record.firstAt) : nil,
                          isUnread: !record.isRead)
        }
    }

    private func enqueueRecordingTrigger(_ trigger: MotionRecordingTrigger) {
        pendingRecordingTriggers.append(trigger)
        recordingTriggerRevision &+= 1
    }

    /// Maps a device event onto the shared marker vocabulary the timeline and inspector already use.
    ///
    /// Hikvision reports twenty-odd kinds and the marker set has six. Anything that is not one of the
    /// five recognised shapes becomes `.alarm`, which is the honest answer — the row still names the
    /// device's own word for it.
    private static func kind(for kind: EventKind) -> TimelineMarkerKind {
        switch kind {
        case .motion, .pir:                                  return .motion
        case .lineCrossing:                                  return .lineCrossing
        case .intrusion, .regionEntrance, .regionExit:       return .intrusion
        case .tamper, .illegalAccess:                        return .tamper
        case .videoLoss, .badVideo:                          return .videoLoss
        default:                                             return .alarm
        }
    }

    /// What the row calls the event: the device's raw type, which is the only name it gives.
    ///
    /// Deliberately not a translated enum name — `rawEventType` is what the camera's own web
    /// interface shows, so a user comparing the two sees the same word.
    private static func label(for record: EventRecord) -> String {
        record.rawEventType.isEmpty ? String(describing: record.kind) : record.rawEventType
    }
}

#endif  // os(macOS)
