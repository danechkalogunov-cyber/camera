//
//  SnapshotJPEGDimensions.swift
//  VigilCore
//
//  The pixel size of a JPEG, read from its own markers.
//  Supports docs/spec-core.md §10.3's verbatim path, where the camera's bytes are written unchanged.
//
//  Pure byte arithmetic over hostile input — no framework, no decode — so it is exercised for real on
//  Linux by the shadow harness under scratchpad/shadow-recording.
//
//  **Why not ImageIO.** The verbatim path writes the camera's own JPEG bytes without touching them, and
//  the only thing it needs from the image is two integers for the file name and the result. Handing
//  the buffer to `CGImageSourceCreateWithData` to read them costs a full decode of a 4 K frame — about
//  25 ms and 25 MB — for eight bytes of header, and it drags a `CFDictionary` bridge into a path that
//  otherwise has none. Reading the `SOFn` marker is a dozen lines and cannot fail on a truncated
//  buffer.
//

#if os(macOS)

import Foundation

// MARK: - SnapshotJPEGDimensions

/// Reads a JPEG's frame header.
public enum SnapshotJPEGDimensions {

    // MARK: - Constants

    /// Every marker that introduces a frame header carrying dimensions: baseline (`C0`), extended
    /// sequential (`C1`), progressive (`C2`), lossless (`C3`) and their arithmetic-coded and
    /// hierarchical variants. `C4` (DHT), `C8` (JPG), `CC` (DAC) are **not** frame headers and are the
    /// three values a naive `0xC0...0xCF` range gets wrong.
    static let frameMarkers: Set<UInt8> = [0xC0, 0xC1, 0xC2, 0xC3,
                                           0xC5, 0xC6, 0xC7,
                                           0xC9, 0xCA, 0xCB,
                                           0xCD, 0xCE, 0xCF]

    // MARK: - Public API

    /// The image's pixel size, or `nil` when the bytes are not a JPEG or are truncated before the
    /// frame header.
    ///
    /// `nil` is a normal answer, not a failure: the caller still writes the bytes the camera sent, and
    /// renders the size as `unknown` rather than inventing one. Nothing here trusts a length field —
    /// a segment length that runs past the end of the buffer ends the walk.
    ///
    /// - Parameter data: A complete or partial JPEG, starting at the SOI marker.
    /// - Returns: `(width, height)` in pixels, or `nil`.
    public static func size(of data: Data) -> (width: Int, height: Int)? {
        // Indexed through the collection's own indices throughout: a `Data` that came out of an HTTP
        // body is very often a slice whose `startIndex` is not zero, and indexing from 0 would read
        // the wrong bytes or trap.
        var index = data.startIndex
        let end = data.endIndex

        // SOI: FF D8.
        guard data.distance(from: index, to: end) >= 4 else { return nil }
        guard data[index] == 0xFF, data[data.index(after: index)] == 0xD8 else { return nil }
        index = data.index(index, offsetBy: 2)

        while true {
            // Markers may be preceded by any number of FF fill bytes.
            while index < end, data[index] != 0xFF {
                index = data.index(after: index)
            }
            while index < end, data[index] == 0xFF {
                index = data.index(after: index)
            }
            guard index < end else { return nil }

            let marker = data[index]
            index = data.index(after: index)

            // Standalone markers: no length, no payload. `D0`–`D7` are the restart markers, `01` is
            // TEM. Anything else has a two-byte big-endian length that includes those two bytes.
            if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) { continue }
            if marker == 0xD9 { return nil }                  // EOI before any frame header.

            guard data.distance(from: index, to: end) >= 2 else { return nil }
            let high = Int(data[index])
            let low = Int(data[data.index(after: index)])
            let segmentLength = high << 8 | low
            // A length below 2 would not even cover its own field, and would make the walk loop
            // forever on a malformed file.
            guard segmentLength >= 2 else { return nil }

            if frameMarkers.contains(marker) {
                // SOFn payload: precision(1) height(2) width(2) components(1) …
                guard segmentLength >= 8,
                      data.distance(from: index, to: end) >= 7 else { return nil }
                let heightHigh = Int(data[data.index(index, offsetBy: 3)])
                let heightLow = Int(data[data.index(index, offsetBy: 4)])
                let widthHigh = Int(data[data.index(index, offsetBy: 5)])
                let widthLow = Int(data[data.index(index, offsetBy: 6)])
                let height = heightHigh << 8 | heightLow
                let width = widthHigh << 8 | widthLow
                // A zero height is legal in the JPEG spec — it means "defined later by a DNL
                // marker" — and is useless to us, so it reads as unknown rather than as 0×W.
                guard width > 0, height > 0 else { return nil }
                return (width, height)
            }

            guard data.distance(from: index, to: end) >= segmentLength else { return nil }
            index = data.index(index, offsetBy: segmentLength)
        }
    }
}

#endif
