//
//  SnapshotImageSource.swift
//  VigilVideo
//
//  The seam the "as displayed" snapshot route goes through, and the `CVPixelBuffer` → `CGImage`
//  conversion behind it.
//  Implements docs/ARCHITECTURE.md §6.2 (`SnapshotSource`) and docs/spec-core.md §10.2, reduced to
//  the two routes the capture wave needs: the frame already on screen, and the device's own JPEG.
//
//  **This code has never been compiled against a real VideoToolbox.** The
//  `VTCreateCGImageFromCVPixelBuffer` spelling below is the one docs/spec-core.md §10.2 uses; see the
//  uncertainty list in the wave report.
//
//  Why the protocol lives in `VigilVideo` and not in `VigilCore`: `VigilCore` must not depend on
//  `VigilRender` (ARCHITECTURE.md §4's layering table), so the displayed-frame capture has to be
//  declared where both can see it. `VigilRender`'s tile view implements it; `VigilCore`'s
//  `SnapshotService` calls it.
//

#if os(macOS)

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import VigilProtocols

// MARK: - SnapshotCapturedImage

/// One still image, with the facts a snapshot file's metadata needs about it.
///
/// `@unchecked Sendable`, justified: the only reference type in it is `CGImage`, which is
/// **immutable** — there is no API that mutates one after creation, and Core Graphics documents
/// images as safe to use from multiple threads. The whole point of this type is to carry a frame off
/// the main actor so the encode and the file write do not happen there, and an immutable image is
/// exactly what may cross that boundary. It is not a licence for anything else: no `CVPixelBuffer`,
/// no `CMSampleBuffer` and no layer is allowed in here.
///
/// - Note: docs/ARCHITECTURE.md §5.9's `Sendable` boundary table calls `DecodedFrame` "exception #2
///   of 2". This is a third, and the table needs a row for it — flagged for the supervisor rather
///   than edited, because `docs/**` is not this wave's to change.
public struct SnapshotCapturedImage: @unchecked Sendable {

    // MARK: - Stored Properties

    /// The pixels. Immutable; never handed to anything that would draw into it.
    public let image: CGImage

    /// Pixel width and height of `image`, cached so a consumer need not touch the image to size a
    /// file name or a metadata field.
    public let pixelWidth: Int
    public let pixelHeight: Int

    /// The instant the *frame* was captured, on the injected monotonic clock — not the instant the
    /// file was written. EXIF `DateTimeOriginal` must be the former (F-CAP-01 acceptance 3).
    public let capturedAt: MediaInstant

    /// Where the pixels came from, for the "Saved from the camera's own snapshot" note the UI shows
    /// when the fast route was unavailable.
    public let origin: SnapshotOrigin

    // MARK: - Initialisation

    /// Wraps a `CGImage`.
    ///
    /// Signatures: `var width: Int { get }` and `var height: Int { get }` on `CGImage`, both of which
    /// report pixels, not points.
    public init(image: CGImage, capturedAt: MediaInstant, origin: SnapshotOrigin) {
        self.image = image
        self.pixelWidth = image.width
        self.pixelHeight = image.height
        self.capturedAt = capturedAt
        self.origin = origin
    }
}

// MARK: - SnapshotOrigin

/// Which route produced a snapshot. Recorded in the file's metadata and in the result, because "why
/// is this image 640×360 when my camera is 4K" is otherwise unanswerable.
public enum SnapshotOrigin: String, Sendable, Hashable, Codable {

    /// The decoded frame that was on screen. Instant, and exactly what the user was looking at —
    /// including the stream they were watching, so a sub-stream tile yields a sub-stream image.
    case displayedFrame

    /// The camera's own JPEG encoder, at full sensor resolution, over ISAPI. Slower (60–400 ms on a
    /// LAN) and without any client-side adjustment.
    case deviceJPEG
}

// MARK: - SnapshotImageProviding

/// Hands over the frame currently on screen.
///
/// Implemented by `VigilRender`'s tile view, which is `@MainActor`. The requirement is `async` for
/// exactly that reason: an `async` requirement can be satisfied by an actor-isolated method, so the
/// view reads its own state on its own actor and returns a value, and no caller ever reads
/// `@MainActor` state from inside a `@Sendable` closure — which does not compile, and which cost this
/// project a build cycle already.
public protocol SnapshotImageProviding: Sendable {

    /// The frame on screen right now, or a named failure.
    ///
    /// - Throws: `RenderError.captureFailed` when there is no frame to capture — a paused tile, a
    ///   stream that has not produced its first frame, or a decode session that has gone away. The
    ///   caller falls back to the device JPEG route; a snapshot must never produce a 0-byte file
    ///   (F-CAP-01 acceptance 8).
    func captureDisplayedImage() async throws(RenderError) -> SnapshotCapturedImage
}

// MARK: - SnapshotPixelBufferConverter

/// `CVPixelBuffer` → `CGImage`, for an implementer of `SnapshotImageProviding` that has a decoded
/// frame rather than an image.
///
/// VideoToolbox's converter is used rather than a hand-rolled `CGContext`: it handles biplanar 8-
/// and 10-bit `420YpCbCr` layouts and applies the correct YCbCr→RGB matrix from the buffer's own
/// attachments. Doing that by hand is where snapshot code goes green-and-purple.
public enum SnapshotPixelBufferConverter {

    /// Converts one pixel buffer.
    ///
    /// Signature this is written against — **and the one signature in this wave I am least sure of**:
    /// ```
    /// func VTCreateCGImageFromCVPixelBuffer(
    ///     _ pixelBuffer: CVPixelBuffer,
    ///     options: CFDictionary?,
    ///     imageOut: UnsafeMutablePointer<CGImage?>) -> OSStatus
    /// ```
    /// The header annotates `imageOut` with `CM_RETURNS_RETAINED_PARAMETER`, so Swift may import it
    /// as `UnsafeMutablePointer<Unmanaged<CGImage>?>` instead. The spelling above is the one
    /// docs/spec-core.md §10.2 uses, so this file follows the project's own documentation; if the
    /// compiler disagrees the fix is one line and the `Unmanaged` form needs `takeRetainedValue()`.
    ///
    /// - Parameters:
    ///   - pixelBuffer: A decoded frame. Not retained beyond the call.
    ///   - capturedAt: The frame's capture instant, from the caller's injected clock.
    /// - Returns: The image, at the buffer's own pixel dimensions.
    /// - Throws: `RenderError.captureFailed` carrying the numeric `OSStatus`, because a swallowed
    ///   `-12902` here is a snapshot that silently never appears.
    public static func image(from pixelBuffer: CVPixelBuffer,
                            capturedAt: MediaInstant) throws(RenderError) -> SnapshotCapturedImage {
        var created: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &created)

        guard status == noErr, let image = created else {
            // `CVPixelBufferGetWidth`/`GetHeight` are in the message because the usual cause is a
            // pixel format the converter does not know, and the dimensions identify the stream.
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
            throw RenderError.captureFailed(
                "VTCreateCGImageFromCVPixelBuffer returned \(status) for \(width)×\(height) "
                + "pixelFormat=\(format)")
        }
        return SnapshotCapturedImage(image: image, capturedAt: capturedAt,
                                     origin: .displayedFrame)
    }
}

#endif
