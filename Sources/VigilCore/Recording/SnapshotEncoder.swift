//
//  SnapshotEncoder.swift
//  VigilCore
//
//  `CGImage` → PNG or JPEG bytes, through ImageIO, with the EXIF/TIFF metadata that makes a saved
//  still usable as evidence.
//  Implements docs/spec-core.md §10.4 and docs/FEATURES.md F-CAP-01 acceptance 2 / 3.
//
//  **No compiler in this container has ImageIO.** Every call carries the signature it was written
//  against; the shadow harness under scratchpad/shadow-recording type-checks the file against stubs
//  of those signatures and runs the EXIF date formatting, which is pure arithmetic, for real.
//

#if os(macOS)

import CoreGraphics
import Foundation
import ImageIO
import VigilProtocols
import VigilVideo

// MARK: - SnapshotFormat

/// The still formats this wave writes.
///
/// HEIC is deliberately absent. It needs a run-time availability probe
/// (`CGImageDestinationCopyTypeIdentifiers()` must contain `public.heic`) and a 10-bit colour policy,
/// and offering a format that silently falls back to JPEG is worse than not offering it
/// (spec-core §10.4). PNG and JPEG are the two the acceptance criteria require.
public enum SnapshotFormat: String, Sendable, Hashable, Codable, CaseIterable {

    /// Lossless. The default, because a snapshot is often evidence.
    case png

    /// Lossy, at `SnapshotEncodeOptions.quality`.
    case jpeg

    /// File extension, without the dot.
    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        }
    }

    /// The Uniform Type Identifier ImageIO selects the encoder from.
    ///
    /// Written as a literal rather than reached for through `UTType.png.identifier` /
    /// `UTType.jpeg.identifier`: these two UTIs are documented constants that have not changed since
    /// Mac OS X 10.4, and the literal keeps `UniformTypeIdentifiers` out of this module's imports for
    /// two strings.
    package var typeIdentifier: CFString {
        switch self {
        case .png: "public.png" as CFString
        case .jpeg: "public.jpeg" as CFString
        }
    }

    /// True when the encoder honours a compression quality.
    package var isLossy: Bool { self == .jpeg }
}

// MARK: - SnapshotMetadata

/// What gets stamped into the file.
///
/// **No GPS, ever, and no serial number.** Camera locations are sensitive and Vigil does not have
/// them; a serial number is redacted everywhere else in this project and a file that leaves the Mac
/// is the last place to start leaking one (spec-core §10.4).
public struct SnapshotMetadata: Sendable, Hashable {

    /// The camera's display name. Goes into `TIFF:ImageDescription` and `TIFF:Artist`.
    public var cameraName: String

    /// Wall-clock capture time of the **frame**, not of the write. EXIF `DateTimeOriginal`.
    public var capturedAt: Date

    /// The zone `capturedAt` is rendered in, and the value of EXIF `OffsetTimeOriginal`, so the
    /// instant is unambiguous rather than merely local.
    public var timeZone: TimeZone

    /// `TIFF:Make`, e.g. `Hikvision`, or `Unknown` when the device did not say.
    public var make: String

    /// `TIFF:Model`, e.g. `DS-2CD2143G0-I`.
    public var model: String

    /// `TIFF:Software`, e.g. `Vigil 1.0 (412)`.
    public var software: String

    /// Which route produced the image, for the `UserComment`.
    public var origin: SnapshotOrigin

    public init(cameraName: String, capturedAt: Date, timeZone: TimeZone = .current,
                make: String = "Unknown", model: String = "Unknown",
                software: String = "Vigil", origin: SnapshotOrigin) {
        self.cameraName = cameraName
        self.capturedAt = capturedAt
        self.timeZone = timeZone
        self.make = make
        self.model = model
        self.software = software
        self.origin = origin
    }
}

// MARK: - SnapshotEncodeOptions

/// Encoder settings.
public struct SnapshotEncodeOptions: Sendable, Hashable {

    public var format: SnapshotFormat

    /// JPEG quality, clamped to 0.5…1.0. Below 0.5 a security still stops being usable as evidence,
    /// which is the only reason anyone saves one.
    public var quality: Double

    /// False to write no EXIF/TIFF at all — for a thumbnail, where the metadata would outweigh the
    /// pixels.
    public var includeMetadata: Bool

    public init(format: SnapshotFormat = .png, quality: Double = 0.9,
                includeMetadata: Bool = true) {
        self.format = format
        self.quality = min(1.0, max(0.5, quality))
        self.includeMetadata = includeMetadata
    }
}

// MARK: - SnapshotEncoder

/// Encodes one image.
public enum SnapshotEncoder {

    // MARK: - Public API

    /// Encodes `image` into `options.format`.
    ///
    /// Signatures this is written against:
    /// ```
    /// func CGImageDestinationCreateWithData(
    ///     _ data: CFMutableData, _ type: CFString, _ count: Int,
    ///     _ options: CFDictionary?) -> CGImageDestination?
    /// func CGImageDestinationAddImage(
    ///     _ idst: CGImageDestination, _ image: CGImage, _ properties: CFDictionary?)
    /// func CGImageDestinationFinalize(_ idst: CGImageDestination) -> Bool
    /// ```
    ///
    /// - Returns: The encoded bytes.
    /// - Throws: `RenderError.captureFailed` naming the format when ImageIO has no encoder for it, and
    ///   naming `CGImageDestinationFinalize` when it returns `false` — a `Bool` with no error object
    ///   behind it, and the one that turns a snapshot into a zero-byte file if it is ignored.
    public static func encode(_ image: CGImage, options: SnapshotEncodeOptions,
                              metadata: SnapshotMetadata) throws(RenderError) -> Data {
        // `NSMutableData` and `CFMutableData` are a toll-free bridged pair; the `as` cast is a
        // representation change, not a downcast, so it cannot fail.
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer as CFMutableData, options.format.typeIdentifier, 1, nil) else {
            throw RenderError.captureFailed(
                "CGImageDestinationCreateWithData returned nil for "
                + "\(options.format.typeIdentifier); no ImageIO encoder for this type")
        }

        let properties = properties(pixelWidth: image.width, pixelHeight: image.height,
                                    options: options, metadata: metadata)
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            // No error object exists for this `false`. Everything useful about the attempt therefore
            // goes into the message, because it is all a bug report will ever have.
            throw RenderError.captureFailed(
                "CGImageDestinationFinalize returned false for \(options.format.rawValue) "
                + "\(image.width)×\(image.height), \(buffer.length) byte(s) written")
        }
        // `Data(referencing:)` rather than `buffer as Data`: it is explicit about the copy and does
        // not depend on the bridge being available.
        return Data(referencing: buffer)
    }

    // MARK: - Metadata

    /// The ImageIO property dictionary.
    ///
    /// Keys used, all `CFString` constants from `ImageIO/CGImageProperties.h`:
    /// `kCGImageDestinationLossyCompressionQuality`, `kCGImagePropertyExifDictionary`,
    /// `kCGImagePropertyExifDateTimeOriginal`, `kCGImagePropertyExifOffsetTimeOriginal`,
    /// `kCGImagePropertyExifUserComment`, `kCGImagePropertyExifPixelXDimension`,
    /// `kCGImagePropertyExifPixelYDimension`, `kCGImagePropertyTIFFDictionary`,
    /// `kCGImagePropertyTIFFMake`, `kCGImagePropertyTIFFModel`, `kCGImagePropertyTIFFSoftware`,
    /// `kCGImagePropertyTIFFDateTime`, `kCGImagePropertyTIFFImageDescription`,
    /// `kCGImagePropertyTIFFArtist`, `kCGImagePropertyPNGDictionary`,
    /// `kCGImagePropertyPNGDescription`, `kCGImagePropertyPNGSoftware`,
    /// `kCGImagePropertyPNGCreationTime`.
    ///
    /// PNG gets its own dictionary in addition to EXIF, because a great many PNG viewers ignore EXIF
    /// entirely and would show a file with no provenance at all.
    /// Takes the dimensions rather than the `CGImage` so the whole function is arithmetic over
    /// values: it is the part of the encoder a test can actually assert, and a test that had to
    /// manufacture a `CGImage` first would be testing Core Graphics instead.
    package static func properties(pixelWidth: Int, pixelHeight: Int,
                                   options: SnapshotEncodeOptions,
                                   metadata: SnapshotMetadata) -> [CFString: Any] {
        var properties: [CFString: Any] = [:]
        if options.format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] = options.quality
        }
        guard options.includeMetadata else { return properties }

        let stamp = exifDate(metadata.capturedAt, timeZone: metadata.timeZone)
        let offset = exifOffset(metadata.timeZone, at: metadata.capturedAt)
        let comment = userComment(pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                  metadata: metadata)

        properties[kCGImagePropertyExifDictionary] = [
            kCGImagePropertyExifDateTimeOriginal: stamp,
            kCGImagePropertyExifOffsetTimeOriginal: offset,
            kCGImagePropertyExifUserComment: comment,
            kCGImagePropertyExifPixelXDimension: pixelWidth,
            kCGImagePropertyExifPixelYDimension: pixelHeight,
        ] as [CFString: Any]

        properties[kCGImagePropertyTIFFDictionary] = [
            kCGImagePropertyTIFFMake: metadata.make,
            kCGImagePropertyTIFFModel: metadata.model,
            kCGImagePropertyTIFFSoftware: metadata.software,
            kCGImagePropertyTIFFDateTime: stamp,
            kCGImagePropertyTIFFImageDescription: metadata.cameraName,
            kCGImagePropertyTIFFArtist: metadata.cameraName,
        ] as [CFString: Any]

        if options.format == .png {
            properties[kCGImagePropertyPNGDictionary] = [
                kCGImagePropertyPNGDescription: comment,
                kCGImagePropertyPNGSoftware: metadata.software,
                kCGImagePropertyPNGCreationTime: stamp,
            ] as [CFString: Any]
        }
        return properties
    }

    /// The one-line human summary that goes into `UserComment` and the PNG `Description`.
    package static func userComment(pixelWidth: Int, pixelHeight: Int,
                                    metadata: SnapshotMetadata) -> String {
        let stamp = exifDate(metadata.capturedAt, timeZone: metadata.timeZone)
        let offset = exifOffset(metadata.timeZone, at: metadata.capturedAt)
        let source = metadata.origin == .deviceJPEG ? "camera JPEG" : "displayed frame"
        return "\(metadata.cameraName) — \(stamp) \(offset) — \(pixelWidth)×\(pixelHeight)"
            + " — \(source) — \(metadata.software)"
    }

    // MARK: - EXIF date arithmetic

    /// EXIF's date format: **`yyyy:MM:dd HH:mm:ss`**, with colons in the *date* part.
    ///
    /// The colons are the classic mistake — `2026-07-26 14:31:07` is silently accepted by many
    /// writers and then read back as no date at all by Preview, Photos and every forensic tool, which
    /// is the difference between a still that is evidence and one that is a picture. Built from
    /// calendar components rather than a `DateFormatter`: no locale can intervene, no format string
    /// can be mis-typed at run time, and the result is testable without a time zone database.
    package static func exifDate(_ date: Date, timeZone: TimeZone) -> String {
        let parts = DateComponentsCache.components(for: date, timeZone: timeZone)
        let year = pad(parts.year ?? 0, width: 4)
        let month = pad(parts.month ?? 0, width: 2)
        let day = pad(parts.day ?? 0, width: 2)
        let hour = pad(parts.hour ?? 0, width: 2)
        let minute = pad(parts.minute ?? 0, width: 2)
        let second = pad(parts.second ?? 0, width: 2)
        return "\(year):\(month):\(day) \(hour):\(minute):\(second)"
    }

    /// EXIF `OffsetTimeOriginal`: `+HH:MM` or `-HH:MM`.
    ///
    /// Taken at `date`, not "now", because a snapshot of a frame captured before a daylight-saving
    /// transition must carry the offset that was in force then.
    package static func exifOffset(_ timeZone: TimeZone, at date: Date) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        return "\(sign)\(pad(magnitude / 3_600, width: 2)):\(pad((magnitude % 3_600) / 60, width: 2))"
    }

    /// Zero-padded decimal.
    private static func pad(_ value: Int, width: Int) -> String {
        let digits = String(abs(value))
        guard digits.count < width else { return digits }
        return String(repeating: "0", count: width - digits.count) + digits
    }
}

#endif
