//
//  MJPEGImageIODecoder.swift
//  VigilVideo
//
//  Bounded ImageIO decoder for legacy MJPEG camera frames.
//

#if os(macOS)

import CoreGraphics
import Foundation
import ImageIO

public enum MJPEGImageIODecoder {
    public static let maximumFrameBytes = 32 * 1_024 * 1_024

    public static func decode(_ data: Data) -> CGImage? {
        guard !data.isEmpty, data.count <= maximumFrameBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false,
        ] as CFDictionary)
    }
}

#endif  // os(macOS)
