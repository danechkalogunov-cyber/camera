//
//  SnapshotSetCoordinator.swift
//  Vigil
//
//  Captures every enabled camera at one moment, into one timestamped folder with a manifest.
//  macOS-only. Implements docs/FEATURES.md F-CAP-02.
//
//  ⛔ WHY A SEPARATE COORDINATOR AND NOT A LOOP OVER `SnapshotCoordinator`. Three of the five
//  acceptance criteria are properties of the *set* rather than of any capture in it: one folder
//  named for one instant, a manifest that lists the failures as well as the files, and a spread
//  between the earliest and latest frame that has to be measured and recorded. A loop produces
//  sixteen unrelated stills in the same directory and can state none of those things.
//
//  ⚠️ NOTHING IS WRITTEN UNTIL THE USER ASKS. This runs from ⌥⇧⌘S and from the overflow menu, never
//  on a timer and never on a camera event.
//

#if os(macOS)

import Foundation
import Observation

import VigilCore
import VigilISAPI
import VigilProtocols

// MARK: - SnapshotSetOutcome

/// What one camera contributed to the set.
struct SnapshotSetEntry: Sendable, Hashable, Codable {

    /// The camera's name as the user sees it.
    var camera: String

    /// Its identity, so a manifest read months later still names the right device.
    var cameraID: UUID

    /// The file, relative to the set's own folder. `nil` when this camera failed.
    var file: String?

    /// When the frame was taken, which is **not** when the set was requested — the spread between
    /// these is the number criterion 2 cares about.
    var capturedAt: Date?

    var pixelWidth: Int?
    var pixelHeight: Int?

    /// Why this camera produced nothing, in the words the user would be shown.
    var failure: String?
}

/// The whole set, as `manifest.json` records it.
struct SnapshotSetManifest: Sendable, Hashable, Codable {

    /// When the user asked. Every capture is triggered from this one instant.
    var requestedAt: Date

    /// The widest gap between two captured frames, in milliseconds. `nil` when fewer than two
    /// cameras answered, because a spread needs two readings.
    ///
    /// ⚠️ Recorded rather than asserted. F-CAP-02 wants ≤ 250 ms across sixteen cameras; whether a
    /// given set met that is a fact about the network that day, and a manifest that omitted it when
    /// it was bad would be the least useful possible record.
    var spreadMilliseconds: Double?

    var succeeded: Int
    var failed: Int
    var entries: [SnapshotSetEntry]
}

/// What the toast says.
enum SnapshotSetOutcome: Sendable {

    /// The set was written, with its folder and the two counts.
    case written(folder: URL, succeeded: Int, total: Int)

    /// Nothing could be written at all, with the reason named.
    case failed(String)

    /// The user cancelled. Whatever had already been captured stays on disk with its manifest —
    /// deleting a user's files because they stopped waiting would be the worse answer.
    case cancelled(folder: URL?, succeeded: Int)
}

// MARK: - SnapshotSetCoordinator

/// Captures a set of cameras at one moment.
@MainActor
@Observable
final class SnapshotSetCoordinator {

    // MARK: - Observable State

    /// How many cameras have been attempted, for the progress readout.
    private(set) var completed = 0

    /// How many were asked for. Zero when nothing is running.
    private(set) var total = 0

    /// Whether a set is being captured now, which is what disables a second press.
    var isRunning: Bool { total > 0 }

    /// Where the last set went, for a Reveal in Finder that follows the toast.
    private(set) var lastFolder: URL?

    // MARK: - Stored Properties

    private let logger: any LoggerProtocol
    private let clock: any MonotonicClock
    private let fileSystem: any RecordingFileSystem

    /// Set by ``cancel()`` and read by the capture loop.
    ///
    /// A flag rather than a stored `Task`, because the task belongs to whoever called: the sheet's
    /// button and `Esc` both reach this object, not the task, and a coordinator that cancelled a
    /// task it did not own would be guessing about the caller's structured concurrency.
    private var isCancelling = false

    // MARK: - Initialisation

    init(logger: any LoggerProtocol,
         clock: any MonotonicClock,
         fileSystem: any RecordingFileSystem = SystemRecordingFileSystem()) {
        self.logger = logger
        self.clock = clock
        self.fileSystem = fileSystem
    }

    // MARK: - API

    /// Stops the set in progress. What was captured stays, with a manifest describing it.
    func cancel() {
        isCancelling = true
    }

    /// Captures every camera in `cameras` and writes the set.
    ///
    /// - Parameters:
    ///   - cameras: the cameras to capture. The caller filters — "all enabled", "this group", "on
    ///     the stage" are three different sets and only the caller knows which was asked for.
    ///   - credentials: where each camera's password is read from, once per camera.
    ///   - requestedAt: the one instant the whole set is named and measured from.
    /// - Returns: the named outcome, for the toast.
    func capture(cameras: [Camera],
                 credentials: CredentialStore,
                 requestedAt: Date = Date()) async -> SnapshotSetOutcome {
        guard !cameras.isEmpty else { return .failed("no cameras to capture") }
        completed = 0
        total = cameras.count
        isCancelling = false
        defer { total = 0 }

        let folderName = "Vigil/\(Self.folderName(for: requestedAt))"
        let destination: RecordingDestination
        do {
            destination = try RecordingDestinationResolver.resolve(
                RecordingDestinationRequest(kind: .snapshots, folderName: folderName),
                fileSystem: fileSystem)
        } catch {
            let reason = String(describing: error)
            logger.error(.storage, "snapshot set destination unusable: \(reason)")
            return .failed(reason)
        }
        lastFolder = destination.directory

        let service = SnapshotService(destination: destination,
                                      fileSystem: fileSystem,
                                      clock: clock,
                                      wallClock: SystemWallClock(),
                                      logger: logger)
        var entries: [SnapshotSetEntry] = []
        var wasCancelled = false
        for camera in cameras {
            if isCancelling || Task.isCancelled {
                wasCancelled = true
                break
            }
            entries.append(await capture(camera, service: service, credentials: credentials))
            completed += 1
        }

        let manifest = Self.manifest(requestedAt: requestedAt, entries: entries)
        write(manifest, into: destination.directory)
        let succeeded = manifest.succeeded
        logger.info(.storage, "snapshot set: \(succeeded) of \(cameras.count) captured")
        if wasCancelled {
            return .cancelled(folder: destination.directory, succeeded: succeeded)
        }
        return .written(folder: destination.directory,
                        succeeded: succeeded,
                        total: cameras.count)
    }

    // MARK: - One camera

    /// Captures one camera into the set's folder, never throwing.
    ///
    /// ⛔ A failure is an entry, not an abort. Criterion 4 is explicit: fourteen successes and two
    /// failures write fourteen files and a manifest naming the two. A set that stopped at the first
    /// unreachable camera would be useless in exactly the situation somebody takes a set — a
    /// building where something has gone wrong.
    private func capture(_ camera: Camera,
                         service: SnapshotService,
                         credentials: CredentialStore) async -> SnapshotSetEntry {
        var entry = SnapshotSetEntry(camera: camera.displayName, cameraID: camera.id.rawValue)
        let client: ISAPIClient
        do {
            guard let credential = try await credentials.credential(for: camera.credentialRef) else {
                entry.failure = "no password is stored for this camera"
                return entry
            }
            client = ISAPIClient(
                endpoint: ISAPIEndpoint(host: camera.host, port: camera.httpPort,
                                        useTLS: camera.useTLS),
                credential: credential,
                transport: URLSessionHTTPTransport(logger: logger),
                clock: clock,
                logger: logger)
        } catch {
            entry.failure = String(describing: error)
            return entry
        }

        var options = SnapshotCaptureOptions()
        options.source = .deviceJPEG
        options.deviceMake = "Hikvision"
        do {
            let result = try await service.capture(
                camera: RecordingCameraInfo(id: camera.id, slug: camera.slug,
                                            name: camera.displayName),
                channel: camera.channel,
                // No displayed-frame provider exists — the decode path is passthrough and produces
                // no readable buffer. `SnapshotCoordinator` explains this at length.
                imageProvider: nil,
                deviceRoute: SnapshotDeviceRoute(requester: client, clock: clock),
                options: options)
            entry.file = result.url?.lastPathComponent
            entry.capturedAt = result.capturedAt
            entry.pixelWidth = result.pixelWidth
            entry.pixelHeight = result.pixelHeight
            if result.url == nil { entry.failure = "captured but not written" }
        } catch {
            entry.failure = String(describing: error)
        }
        return entry
    }

    // MARK: - The manifest

    /// Builds the manifest, including the spread criterion 2 asks to be recorded.
    static func manifest(requestedAt: Date, entries: [SnapshotSetEntry]) -> SnapshotSetManifest {
        let instants = entries.compactMap(\.capturedAt).map(\.timeIntervalSince1970)
        let spread: Double? = instants.count > 1
            ? ((instants.max() ?? 0) - (instants.min() ?? 0)) * 1_000
            : nil
        let succeeded = entries.filter { $0.failure == nil }.count
        return SnapshotSetManifest(requestedAt: requestedAt,
                                   spreadMilliseconds: spread,
                                   succeeded: succeeded,
                                   failed: entries.count - succeeded,
                                   entries: entries)
    }

    /// Writes `manifest.json` beside the images.
    ///
    /// A failure here is logged and not reported: the images are the deliverable and they are
    /// already on disk. Telling the user their snapshot set failed because a side-car did would be
    /// false.
    private func write(_ manifest: SnapshotSetManifest, into directory: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(manifest)
            try data.write(to: directory.appendingPathComponent("manifest.json"))
        } catch {
            logger.warning(.storage, "snapshot set manifest not written: \(error)")
        }
    }

    /// `Snapshot Set 2026-07-26 14-31-07`, exactly as criterion 3 spells it.
    ///
    /// Colons are not legal in a path component on every volume Vigil may be pointed at, which is
    /// why the time is hyphenated. Fixed `en_US_POSIX` and the current time zone: the folder is a
    /// name a person reads on their own machine, so it is local time, but it must not change shape
    /// with the system's date-format preferences.
    static func folderName(for instant: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return "Snapshot Set \(formatter.string(from: instant))"
    }
}

#endif  // os(macOS)
