//
//  SnapshotService.swift
//  VigilCore
//
//  One still, from whichever of the two routes can produce it, encoded and written to
//  `Pictures/Vigil` without ever touching the main actor.
//  Implements docs/spec-core.md §10.1 / §10.6 and docs/FEATURES.md F-CAP-01.
//
//  **No compiler in this container has ImageIO or CoreGraphics.** The framework calls are in
//  `SnapshotEncoder` and in `decodeJPEG` below, each with its signature quoted; the shadow harness
//  under scratchpad/shadow-recording type-checks them against stubs.
//
//  The two routes, and why both are needed:
//
//  * **The displayed frame** is instant (8–30 ms) and is *exactly what the user is looking at* —
//    the stream they chose, the zoom they set. It is what ⇧⌘S must feel like.
//  * **The device's JPEG** is the camera's own encode at full sensor resolution (60–400 ms on a LAN).
//    It is the only route when nothing is decoding — a paused tile, a JPEG-polled camera, a camera
//    that is up but whose tile was never opened — and the only one that beats a sub-stream tile's
//    resolution.
//
//  A snapshot that cannot be taken must say so. `RenderError.captureFailed`'s user message is "The
//  snapshot could not be taken", and F-CAP-01 acceptance 8 requires that an offline camera produces
//  that rather than a zero-byte file.
//

#if os(macOS)

import CoreGraphics
import Foundation
import ImageIO
import VigilISAPI
import VigilProtocols
import VigilVideo

// MARK: - SnapshotSourcePreference

/// Which route to use.
public enum SnapshotSourcePreference: String, Sendable, Hashable, Codable {

    /// Displayed frame, falling back to the device's JPEG. The default, and the only value that never
    /// simply fails when one route is unavailable.
    case automatic

    /// The displayed frame only. Fails when nothing is decoding.
    case displayedFrame

    /// The device's JPEG only. What "Full resolution" in the UI means for a sub-stream tile.
    case deviceJPEG
}

// MARK: - SnapshotCaptureOptions

/// Everything the caller can choose about one capture.
public struct SnapshotCaptureOptions: Sendable, Hashable {

    public var source: SnapshotSourcePreference

    /// Output format and quality.
    public var encoding: SnapshotEncodeOptions

    /// Name template. See `RecordingNaming`.
    public var nameTemplate: String

    /// False to return the bytes without writing a file — for the clipboard, for an event thumbnail,
    /// or for an App Intent.
    public var writesFile: Bool

    /// `TIFF:Make`, from the device's own report, or `Unknown`.
    public var deviceMake: String

    /// `TIFF:Model`.
    public var deviceModel: String

    /// `TIFF:Software`, e.g. `Vigil 1.0 (412)`.
    public var software: String

    public init(source: SnapshotSourcePreference = .automatic,
                encoding: SnapshotEncodeOptions = SnapshotEncodeOptions(),
                nameTemplate: String = RecordingNaming.defaultSnapshotTemplate,
                writesFile: Bool = true,
                deviceMake: String = "Unknown",
                deviceModel: String = "Unknown",
                software: String = "Vigil") {
        self.source = source
        self.encoding = encoding
        self.nameTemplate = nameTemplate
        self.writesFile = writesFile
        self.deviceMake = deviceMake
        self.deviceModel = deviceModel
        self.software = software
    }
}

// MARK: - SnapshotResult

/// One captured still.
public struct SnapshotResult: Sendable, Hashable {

    /// Where it was written, or `nil` when `writesFile` was false.
    public var url: URL?

    /// The encoded bytes. Always present, so the clipboard and Quick Look need no second capture.
    public var data: Data

    public var format: SnapshotFormat
    public var pixelWidth: Int
    public var pixelHeight: Int

    /// Which route produced it. The UI shows "Saved from the camera's own snapshot (full resolution)"
    /// when this is `.deviceJPEG` but `.displayedFrame` was asked for.
    public var origin: SnapshotOrigin

    /// Wall-clock capture time of the frame.
    public var capturedAt: Date

    /// True when the preferred route failed and the fallback was used, so the UI can say so once
    /// rather than leaving the user to wonder why the image looks different.
    public var usedFallback: Bool
}

// MARK: - SnapshotService

/// Captures, encodes and writes stills.
///
/// An actor, and that is the load-bearing design decision: **encoding a 4 K PNG takes 30–80 ms and
/// writing it takes as long as the disk takes.** Doing either on the main actor drops frames in every
/// tile in the window, and doing it in a `@Sendable` closure that reads the view's state does not
/// compile. So the frame crosses the boundary once, as an immutable `CGImage` inside
/// `SnapshotCapturedImage`, and everything after that happens here.
public actor SnapshotService {

    // MARK: - Stored Properties

    private let destination: RecordingDestination
    private let fileSystem: any RecordingFileSystem
    private let clock: any MonotonicClock
    private let wallClock: any WallClock
    private let logger: any LoggerProtocol

    // MARK: - Initialisation

    /// Builds a service.
    ///
    /// - Parameters:
    ///   - destination: An already-resolved `Pictures/Vigil` (or user-chosen) directory. Resolved by
    ///     `RecordingDestinationResolver` with `kind: .snapshots`, so a sandbox refusal is a named
    ///     error before any capture is attempted.
    ///   - fileSystem: The file-system seam.
    ///   - clock: Monotonic time, stamped onto the captured image.
    ///   - wallClock: Wall time, for the file name and the EXIF date.
    ///   - logger: Structured logging.
    public init(destination: RecordingDestination,
                fileSystem: any RecordingFileSystem,
                clock: any MonotonicClock,
                wallClock: any WallClock,
                logger: any LoggerProtocol) {
        self.destination = destination
        self.fileSystem = fileSystem
        self.clock = clock
        self.wallClock = wallClock
        self.logger = logger
    }

    // MARK: - Public API

    /// Captures one still.
    ///
    /// - Parameters:
    ///   - camera: Naming and log identity.
    ///   - channel: The video input, for the device route.
    ///   - imageProvider: The displayed-frame route, or `nil` when nothing is decoding.
    ///   - deviceRoute: The ISAPI route, or `nil` when the camera has no HTTP session.
    ///   - options: See `SnapshotCaptureOptions`.
    /// - Returns: The result, with the bytes always populated.
    /// - Throws: `VigilError.render(.captureFailed)` when neither route could produce an image, with
    ///   both routes' reasons in the message; `VigilError.isapi` when the device route was the only
    ///   one and it failed; `VigilError.storage` when the bytes could not be written.
    public func capture(camera: RecordingCameraInfo,
                        channel: ChannelID,
                        imageProvider: (any SnapshotImageProviding)?,
                        deviceRoute: SnapshotDeviceRoute?,
                        options: SnapshotCaptureOptions = SnapshotCaptureOptions())
        async throws(VigilError) -> SnapshotResult {

        let capturedAt = wallClock.now
        let source = try resolveSource(options.source, imageProvider: imageProvider,
                                       deviceRoute: deviceRoute)

        switch source {
        case .displayed(let provider):
            // The capture and the encode are separate `do` blocks on purpose: the capture's failure
            // has a fallback, the encode's does not, and a single block would have to catch both
            // `RenderError` and `VigilError` — which widens the thrown type to `any Error` and stops
            // this typed-throws function compiling at all.
            let image: SnapshotCapturedImage
            do {
                image = try await provider.captureDisplayedImage()
            } catch {
                // `error` is a `RenderError`: `captureDisplayedImage` declares `throws(RenderError)`
                // and Swift narrows the binding, so no `as` test is needed or wanted here.
                guard options.source == .automatic, let deviceRoute else {
                    throw VigilError.render(error)
                }
                // The documented fallback. Logged at notice, not swallowed: a tile that silently
                // stops producing snapshots-as-displayed is a decode bug we want to see.
                logger.notice(.core, "snapshot falling back to the camera's own JPEG",
                              ["camera": camera.id.short, "reason": error.diagnosticCode])
                return try await captureFromDevice(deviceRoute, camera: camera, channel: channel,
                                                   capturedAt: capturedAt, options: options,
                                                   usedFallback: true)
            }
            return try await finish(image: image, camera: camera, capturedAt: capturedAt,
                                    options: options, usedFallback: false)

        case .device(let route):
            return try await captureFromDevice(route, camera: camera, channel: channel,
                                               capturedAt: capturedAt, options: options,
                                               usedFallback: options.source == .automatic
                                                   && imageProvider == nil)
        }
    }

    // MARK: - Private: routes

    /// Which route this capture will use.
    private enum ResolvedSource {
        case displayed(any SnapshotImageProviding)
        case device(SnapshotDeviceRoute)
    }

    /// Picks the route, or explains why there is none.
    private func resolveSource(_ preference: SnapshotSourcePreference,
                               imageProvider: (any SnapshotImageProviding)?,
                               deviceRoute: SnapshotDeviceRoute?)
        throws(VigilError) -> ResolvedSource {
        switch preference {
        case .displayedFrame:
            guard let imageProvider else {
                throw VigilError.render(.captureFailed(
                    "no video to capture: this camera is not decoding, and \"as displayed\" was "
                    + "required. Choose \"Full resolution\" to ask the camera for a JPEG instead."))
            }
            return .displayed(imageProvider)

        case .deviceJPEG:
            guard let deviceRoute else {
                throw VigilError.render(.captureFailed(
                    "no HTTP session for this camera, so its own JPEG endpoint cannot be reached"))
            }
            return .device(deviceRoute)

        case .automatic:
            if let imageProvider { return .displayed(imageProvider) }
            if let deviceRoute { return .device(deviceRoute) }
            throw VigilError.render(.captureFailed(
                "no video to capture: nothing is decoding and the camera has no HTTP session"))
        }
    }

    /// Fetches, and where necessary re-encodes, the device's JPEG.
    private func captureFromDevice(_ route: SnapshotDeviceRoute, camera: RecordingCameraInfo,
                                   channel: ChannelID, capturedAt: Date,
                                   options: SnapshotCaptureOptions,
                                   usedFallback: Bool) async throws(VigilError) -> SnapshotResult {
        let jpeg: Data
        do {
            jpeg = try await route.fetchJPEG(channel: channel)
        } catch {
            throw VigilError.isapi(error)
        }

        // **The verbatim path.** JPEG in, JPEG out, no overlay, no resize: the bytes the camera
        // produced are what gets written. A decode/re-encode round trip here would lose quality for
        // nothing and would be the single most pointless CPU cost in the app.
        if options.encoding.format == .jpeg {
            // Size from the JPEG's own `SOFn` marker, not from a decode: the bytes are not being
            // decoded on this path at all, and two integers are not worth 25 ms of one.
            let size = SnapshotJPEGDimensions.size(of: jpeg)
            return try await write(data: jpeg, camera: camera, capturedAt: capturedAt,
                                   options: options, pixelWidth: size?.width ?? 0,
                                   pixelHeight: size?.height ?? 0, origin: .deviceJPEG,
                                   usedFallback: usedFallback)
        }

        let image = try decodeJPEG(jpeg)
        return try await finish(image: SnapshotCapturedImage(image: image,
                                                             capturedAt: clock.now(),
                                                             origin: .deviceJPEG),
                                camera: camera, capturedAt: capturedAt,
                                options: options, usedFallback: usedFallback)
    }

    // MARK: - Private: encode and write

    /// Encodes an image and writes it.
    private func finish(image: SnapshotCapturedImage,
                        camera: RecordingCameraInfo, capturedAt: Date,
                        options: SnapshotCaptureOptions,
                        usedFallback: Bool) async throws(VigilError) -> SnapshotResult {
        let metadata = SnapshotMetadata(cameraName: camera.name,
                                        capturedAt: capturedAt,
                                        timeZone: camera.timeZone,
                                        make: options.deviceMake,
                                        model: options.deviceModel,
                                        software: options.software,
                                        origin: image.origin)
        let encoded: Data
        do {
            encoded = try SnapshotEncoder.encode(image.image, options: options.encoding,
                                                 metadata: metadata)
        } catch {
            throw VigilError.render(error)
        }
        return try await write(data: encoded, camera: camera, capturedAt: capturedAt,
                               options: options, pixelWidth: image.pixelWidth,
                               pixelHeight: image.pixelHeight, origin: image.origin,
                               usedFallback: usedFallback)
    }

    /// Writes the bytes, resolving a name collision first.
    ///
    /// Runs on this actor, which is the point: `Data.write(to:options: .atomic)` is a synchronous
    /// call that blocks for as long as the volume takes, and on the main actor that is a dropped
    /// frame in every tile.
    private func write(data: Data, camera: RecordingCameraInfo, capturedAt: Date,
                       options: SnapshotCaptureOptions, pixelWidth: Int, pixelHeight: Int,
                       origin: SnapshotOrigin,
                       usedFallback: Bool) async throws(VigilError) -> SnapshotResult {
        guard options.writesFile else {
            return SnapshotResult(url: nil, data: data, format: options.encoding.format,
                                  pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                  origin: origin, capturedAt: capturedAt,
                                  usedFallback: usedFallback)
        }

        let context = RecordingNameContext(cameraSlug: camera.slug,
                                           cameraName: camera.name,
                                           date: capturedAt,
                                           timeZone: camera.timeZone,
                                           resolution: Resolution(width: pixelWidth,
                                                                  height: pixelHeight),
                                           trigger: "snapshot")
        let relative = RecordingNaming.render(options.nameTemplate, context: context)
        let parts = relative.split(separator: "/").map(String.init)
        let baseName = parts.last ?? "snapshot"
        let parent = parts.dropLast().reduce(destination.directory) { url, component in
            url.appendingPathComponent(component, isDirectory: true)
        }
        let fileExtension = options.encoding.format.fileExtension

        do {
            try fileSystem.createDirectory(at: parent)
        } catch {
            throw VigilError.recording(error)
        }

        let unique = RecordingNaming.uniqueBaseName(
            baseName, extensions: [fileExtension],
            uniqueSuffix: camera.id.short) { candidate, suffix in
                fileSystem.itemExists(at: parent.appendingPathComponent("\(candidate).\(suffix)"))
            }
        let url = parent.appendingPathComponent("\(unique).\(fileExtension)")

        do {
            try fileSystem.writeDurably(data, to: url)
        } catch {
            throw VigilError.storage(error)
        }
        logger.info(.core, "snapshot written",
                    ["camera": camera.id.short,
                     "path": Redact.path(url.path),
                     "bytes": String(data.count),
                     "origin": origin.rawValue])
        return SnapshotResult(url: url, data: data, format: options.encoding.format,
                              pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                              origin: origin, capturedAt: capturedAt, usedFallback: usedFallback)
    }

    // MARK: - Private: JPEG inspection

    /// Decodes a JPEG so it can be re-encoded as PNG.
    ///
    /// Signatures this is written against:
    /// ```
    /// func CGImageSourceCreateWithData(_ data: CFData, _ options: CFDictionary?) -> CGImageSource?
    /// func CGImageSourceCreateImageAtIndex(
    ///     _ isrc: CGImageSource, _ index: Int, _ options: CFDictionary?) -> CGImage?
    /// ```
    /// `data as CFData` is a toll-free bridge, not a downcast.
    private func decodeJPEG(_ data: Data) throws(VigilError) -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw VigilError.render(.captureFailed(
                "CGImageSourceCreateWithData returned nil for \(data.count) JPEG byte(s)"))
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw VigilError.render(.captureFailed(
                "CGImageSourceCreateImageAtIndex returned nil for the camera's JPEG "
                + "(\(data.count) byte(s))"))
        }
        return image
    }
}

#endif
