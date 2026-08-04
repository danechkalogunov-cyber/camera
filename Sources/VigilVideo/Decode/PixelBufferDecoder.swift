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

final class PixelBufferDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private weak var sink: (any VideoSink)?
    private var session: VTDecompressionSession?
    private var generation: UInt32 = 0

    init(sink: any VideoSink) { self.sink = sink }
    deinit { invalidate() }

    func configure(format: CMVideoFormatDescription, generation: UInt32) throws {
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
        guard status == noErr, let created else { throw PixelBufferDecoderError.create(status) }
        lock.withLock { session = created }
    }

    func decode(_ sample: CMSampleBuffer) throws {
        let status = lock.withLock { session.map {
            VTDecompressionSessionDecodeFrame(
                $0, sampleBuffer: sample, flags: [.enableAsynchronousDecompression],
                frameRefcon: nil, infoFlagsOut: nil
            )
        } }
        guard let status else { throw PixelBufferDecoderError.notConfigured }
        guard status == noErr else { throw PixelBufferDecoderError.decode(status) }
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

private enum PixelBufferDecoderError: Error {
    case create(OSStatus)
    case decode(OSStatus)
    case notConfigured
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
