//
//  SnapshotCoordinator.swift
//  Vigil
//
//  Captures one still from the camera and writes it to the user's Pictures folder.
//  macOS-only. See docs/FEATURES.md F-CAP-01 and `VigilCore/Recording/SnapshotService.swift`.
//

#if os(macOS)

import Foundation
import Observation

import VigilCore
import VigilISAPI
import VigilProtocols

// MARK: - SnapshotOutcome

/// What pressing Snapshot achieved.
enum SnapshotOutcome: Sendable {

    /// Written, with the file it landed in.
    case saved(URL)

    /// It could not be taken or could not be written, with the reason named.
    case failed(String)
}

// MARK: - SnapshotCoordinator

/// Takes a still of the live camera.
///
/// **Why the device route and not the picture on screen.** `SnapshotService` prefers a frame from
/// the renderer and falls back to the camera's own JPEG endpoint. Vigil has no frame to offer: the
/// decode path is passthrough, straight from the network into `AVSampleBufferDisplayLayer`, and it
/// never produces a `CVPixelBuffer` anything could read. So the device route is passed and the
/// display provider is `nil` — which is the case `SnapshotSourcePreference.deviceJPEG` names,
/// and passing `.automatic` with no provider would only make the service rediscover that.
///
/// The consequence is worth being plain about: the still is what the *camera* renders at that
/// instant, not the frame the user is looking at. On a stream a second behind the sensor those
/// differ, and no arrangement of this file can close that gap — only a real decoder can.
@MainActor
@Observable
final class SnapshotCoordinator {

    // MARK: - Observable State

    /// Where the last still went, for a Reveal in Finder that follows the toast.
    private(set) var lastSaved: URL?

    // MARK: - Stored Properties

    private let logger: any LoggerProtocol
    private let clock: any MonotonicClock
    private let fileSystem: any RecordingFileSystem

    // MARK: - Initialisation

    /// Creates a coordinator.
    ///
    /// - Parameters:
    ///   - logger: the app's log sink.
    ///   - clock: monotonic time, stamped onto the captured image.
    ///   - fileSystem: the disk surface. Injectable so a test can present a full or read-only volume.
    init(logger: any LoggerProtocol,
         clock: any MonotonicClock,
         fileSystem: any RecordingFileSystem = SystemRecordingFileSystem()) {
        self.logger = logger
        self.clock = clock
        self.fileSystem = fileSystem
    }

    // MARK: - API

    /// Captures one still and writes it.
    ///
    /// - Parameters:
    ///   - camera: the camera being captured, for the file name and the metadata.
    ///   - client: the device's ISAPI client. `nil` before a control-plane session exists, which is
    ///     a refusal rather than a crash — there is no other route to an image.
    ///   - model: the device's model name, written into the file's metadata. Empty leaves the
    ///     service's own `Unknown`, which is more truthful than an empty EXIF field.
    /// - Returns: the named outcome. Never throws: a snapshot that fails has to say why on screen,
    ///   and an error propagated out of here would only be caught and rendered by the caller anyway.
    func capture(camera: Camera,
                 client: ISAPIClient?,
                 model: String) async -> SnapshotOutcome {
        guard let client else {
            return .failed("no control-plane session for this camera yet")
        }
        let destination: RecordingDestination
        do {
            // The same resolver the recorder uses, with `.snapshots` instead of `.clips`. It is what
            // checks the folder exists, that the sandbox will allow a write there and that the
            // volume is not below its reserve — each a named error, so a refusal says which.
            destination = try RecordingDestinationResolver.resolve(
                RecordingDestinationRequest(kind: .snapshots), fileSystem: fileSystem)
        } catch {
            let reason = String(describing: error)
            logger.error(.storage, "snapshot destination unusable: \(reason)")
            return .failed(reason)
        }

        let service = SnapshotService(destination: destination,
                                      fileSystem: fileSystem,
                                      clock: clock,
                                      wallClock: SystemWallClock(),
                                      logger: logger)
        let info = RecordingCameraInfo(id: camera.id,
                                       slug: camera.slug,
                                       name: camera.displayName)
        var options = SnapshotCaptureOptions()
        options.source = .deviceJPEG
        options.deviceMake = "Hikvision"
        if !model.isEmpty { options.deviceModel = model }
        do {
            let result = try await service.capture(
                camera: info,
                channel: camera.channel,
                // No displayed-frame provider exists, and there is no honest way to invent one —
                // see the type's doc comment.
                imageProvider: nil,
                deviceRoute: SnapshotDeviceRoute(requester: client, clock: clock),
                options: options)
            guard let url = result.url else {
                // `writesFile` defaults true, so bytes with no URL means the write was skipped
                // somewhere the service did not treat as an error. Report it rather than claiming a
                // file the user would then not find.
                return .failed("the image was captured but no file was written")
            }
            lastSaved = url
            logger.info(.storage, "snapshot written: \(result.pixelWidth)×\(result.pixelHeight)")
            return .saved(url)
        } catch {
            let reason = String(describing: error)
            logger.error(.storage, "snapshot refused: \(reason)")
            return .failed(reason)
        }
    }
}

#endif  // os(macOS)
