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

    // MARK: - Observable State

    /// The most recent events, newest first, ready for `VLibraryState.events`.
    private(set) var events: [VLibraryEvent] = []

    /// How many have not been looked at. Feeds the sidebar's badge.
    private(set) var unreadCount = 0

    // MARK: - Stored Properties

    private let store: EventStore
    private let service: EventMonitorService
    private let credentials: CredentialStore
    private let dependencies: CoreDependencies
    private var drain: Task<Void, Never>?

    /// The camera the factory builds credentials for. `CredentialStore` looks a password up by
    /// `Camera`, while `EventMonitorFactory` is handed only a device key, so the current camera has
    /// to be reachable from inside the closure.
    private let followed = OSAllocatedUnfairLock<Camera?>(initialState: nil)

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
            makeMonitor: { [credentials, followed] key in
                guard let camera = followed.withLock({ $0 }),
                      EventDeviceKey(camera: camera) == key,
                      let credential = try? credentials.credential(for: camera) else {
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
        followed.withLock { $0 = camera }
        guard let camera else {
            await service.stopAll()
            events = []
            unreadCount = 0
            return
        }
        await service.reconcile(cameras: [camera])
        startDraining(camera: camera)
    }

    /// Stops the feed and releases the subscription.
    func stop() async {
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
    private func startDraining(camera: Camera) {
        drain?.cancel()
        let service = service
        drain = Task { [weak self] in
            await self?.refresh(camera: camera)
            for await _ in service.events() {
                guard let self else { return }
                await self.refresh(camera: camera)
            }
        }
    }

    /// Reads the store into the screen's shape.
    private func refresh(camera: Camera) async {
        let records = await store.recent(cameraID: camera.id, limit: 200)
        let unread = await store.unreadCount()
        let source = VLibraryCamera(id: camera.id, name: camera.displayName)
        events = records.map { record in
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
        unreadCount = unread
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
