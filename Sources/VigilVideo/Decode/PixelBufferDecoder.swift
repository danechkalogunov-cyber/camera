//
//  PixelBufferDecoder.swift
//  VigilVideo
//
//  VideoToolbox decoder that exposes BGRA pixel buffers to Metal-capable video sinks.
//

#if os(macOS)

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import VigilProtocols

final class PixelBufferDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private weak var sink: (any VideoSink)?
    private var session: VTDecompressionSession?
    private var generation: UInt32 = 0

    init(sink: any VideoSink) { self.sink = sink }
    deinit { invalidate() }

    /// ⚠️ `throws(DecodeError)`, like every other throwing entry point in this module.
    ///
    /// An untyped `throws` here is not a style question: `DecodePipeline` calls this and
    /// `SampleBufferBuilder.make` inside one `do`, and `report(_:)` takes a `DecodeError`. One
    /// untyped thrower widens the whole `catch` to `any Error` and the pipeline stops compiling —
    /// which is exactly how this file first arrived.
    func configure(format: CMVideoFormatDescription,
                   generation: UInt32) throws(DecodeError) {
        // Ordering matters and is the reason `generation` needs no lock. `invalidate()` drains the
        // old session's callbacks first, so nothing can be reading `generation` while it is
        // written, and the new session that will read it does not exist yet.
        invalidate()
        self.generation = generation
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: pixelBufferDecoderCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback, decompressionSessionOut: &created
        )
        guard status == noErr, let created else { throw Self.decodeError(status) }
        lock.withLock { session = created }
    }

    func decode(_ sample: CMSampleBuffer) throws(DecodeError) {
        // ⚠️ `._EnableAsynchronousDecompression`, with the leading underscore, is the real Swift
        // spelling. `VTDecodeFrameFlags` also carries `kVTDecodeFrame_1xRealTimePlayback`, and a
        // case that would begin with a digit makes the importer abandon prefix stripping for the
        // whole option set — so every case keeps the `_` the prefix left behind.
        let status = lock.withLock { session.map {
            VTDecompressionSessionDecodeFrame(
                $0, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression],
                frameRefcon: nil, infoFlagsOut: nil
            )
        } }
        // No session is `.invalidSession` rather than a case of its own: to the pipeline the two
        // are the same instruction — rebuild and wait for an IDR.
        guard let status else { throw DecodeError.invalidSession }
        guard status == noErr else { throw Self.decodeError(status) }
    }

    /// Maps VideoToolbox's status onto the shared taxonomy, so a caller can act on the three
    /// outcomes that have different recoveries and lump the rest together.
    private static func decodeError(_ status: OSStatus) -> DecodeError {
        switch status {
        case kVTInvalidSessionErr: .invalidSession
        case kVTVideoDecoderBadDataErr: .badData
        case kVTVideoDecoderMalfunctionErr: .malfunction
        default: .vt(status: status)
        }
    }

    func invalidate() {
        let old = lock.withLock { () -> VTDecompressionSession? in
            defer { session = nil }
            return session
        }
        if let old {
            VTDecompressionSessionWaitForAsynchronousFrames(old)
            VTDecompressionSessionInvalidate(old)
        }
    }

    fileprivate func emit(_ image: CVImageBuffer?) {
        guard let image else { return }
        sink?.enqueuePixelBuffer(image, generation: generation)
    }
}

private func pixelBufferDecoderCallback(
    refcon: UnsafeMutableRawPointer?, frameRefcon: UnsafeMutableRawPointer?, status: OSStatus,
    infoFlags: VTDecodeInfoFlags, imageBuffer: CVImageBuffer?, presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    guard status == noErr, !infoFlags.contains(.frameDropped), let refcon else { return }
    Unmanaged<PixelBufferDecoder>.fromOpaque(refcon).takeUnretainedValue().emit(imageBuffer)
}

#endif
