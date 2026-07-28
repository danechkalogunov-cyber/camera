//
//  LivePreviewSource.swift
//  Vigil
//
//  A small, infrequently refreshed still of the live picture, for the sidebar's camera row.
//  macOS-only. See docs/DESIGN.md §7.9 and docs/UX.md §4.2.
//

#if os(macOS)

import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Observation
import os

import VigilProtocols

// MARK: - LivePreviewSource

/// The most recent frame, downscaled, for anything that wants a thumbnail of the live picture.
///
/// **Why a still and not a second video view.** `FrameStreamHandle` holds one weak sink, so
/// attaching a second `VideoTile` to the same stream would displace the first — the sidebar's
/// thumbnail would steal the main picture. Fanning the render path out to several surfaces is a real
/// change to `VigilRender`, and a 40 pt row does not justify it.
///
/// **Why it is throttled hard.** This runs on the decode path. Converting a pixel buffer costs real
/// work, and doing it per frame would put a scaling pass between the decoder and the screen at 25 Hz
/// for a picture the size of a postage stamp — precisely the kind of per-frame tax DESIGN.md §7.9
/// exists to forbid. One frame every two seconds is enough for a thumbnail to look alive, and skips
/// 49 out of every 50.
///
/// The `CIContext` is built once and reused: constructing one per frame is the expensive mistake in
/// this API, and it would undo the throttling.
@Observable
final class LivePreviewSource: @unchecked Sendable {

    // MARK: - Observable State

    /// The latest thumbnail, or `nil` before the first frame has been sampled.
    ///
    /// Written from the decode path and read on the main actor. `@unchecked Sendable` is justified
    /// by the lock below: the image itself is immutable once created, and the only mutable state is
    /// the timestamp of the last sample.
    private(set) var image: CGImage?

    // MARK: - Stored Properties

    /// When a frame was last converted, on the monotonic clock.
    private let lastSampled = OSAllocatedUnfairLock<Double>(initialState: -.infinity)

    /// Reused across conversions. Building one per frame is what makes this API slow.
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Seconds between samples.
    private let interval: Double

    /// The thumbnail's width in pixels. Height follows the frame's aspect ratio.
    private let width: CGFloat

    // MARK: - Initialisation

    /// Creates a preview source.
    ///
    /// - Parameters:
    ///   - interval: seconds between samples. Two by default, which is slow enough to be free and
    ///     fast enough that the thumbnail does not look frozen.
    ///   - width: the thumbnail's width in pixels. Small on purpose — this is a sidebar row.
    init(interval: Double = 2, width: CGFloat = 96) {
        self.interval = interval
        self.width = width
    }

    // MARK: - API

    /// Offers a decoded frame, which is usually declined.
    ///
    /// Safe to call from the decode path: the common case is one lock acquisition, one comparison
    /// and a return. Only when the interval has elapsed does any conversion happen.
    ///
    /// - Parameters:
    ///   - sampleBuffer: the frame on its way to the screen. Not retained.
    ///   - now: seconds on a monotonic clock.
    nonisolated func offer(_ sampleBuffer: CMSampleBuffer, now: Double) {
        let shouldSample = lastSampled.withLock { last in
            guard now - last >= interval else { return false }
            last = now
            return true
        }
        guard shouldSample else { return }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let scaled = downscale(pixels) else { return }
        Task { @MainActor in self.image = scaled }
    }

    /// Forgets the picture, for a disconnect.
    @MainActor
    func clear() {
        image = nil
        lastSampled.withLock { $0 = -.infinity }
    }

    // MARK: - Private Helpers

    /// Scales one pixel buffer down to `width`, preserving its aspect ratio.
    private nonisolated func downscale(_ pixels: CVPixelBuffer) -> CGImage? {
        let source = CIImage(cvPixelBuffer: pixels)
        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = width / extent.width
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent)
    }
}

#endif  // os(macOS)
