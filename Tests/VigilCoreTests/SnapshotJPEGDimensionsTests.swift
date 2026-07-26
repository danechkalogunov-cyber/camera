//
//  SnapshotJPEGDimensionsTests.swift
//  VigilCoreTests
//
//  The JPEG `SOFn` walk, including the hostile inputs a camera on the LAN can send: truncated
//  bodies, lying length fields, and the three `0xC?` markers that are not frame headers.
//  Covers Sources/VigilCore/Recording/SnapshotJPEGDimensions.swift.
//
//  Pure byte arithmetic; runs identically on macOS and in the Linux shadow harness under
//  scratchpad/shadow-recording, which is where these were executed.
//
//  Every fixture here is **synthesised in this file** from the JPEG marker structure — none of it came
//  from real hardware.
//

#if os(macOS)

import Foundation
import Testing
import VigilCore

// MARK: - Support

/// A minimal JPEG: SOI, an optional preamble of segments, then a frame header of `marker` declaring
/// `width` × `height`.
private func snapshotJPEG(marker: UInt8 = 0xC0, width: Int = 1_920, height: Int = 1_080,
                          preamble: [UInt8] = []) -> Data {
    var bytes: [UInt8] = [0xFF, 0xD8]
    bytes += preamble
    bytes += [0xFF, marker, 0x00, 0x11, 0x08]                  // length 17, 8-bit precision
    bytes += [UInt8(height >> 8), UInt8(height & 0xFF)]
    bytes += [UInt8(width >> 8), UInt8(width & 0xFF)]
    bytes += [0x03]                                            // 3 components
    bytes += [0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]
    return Data(bytes)
}

/// An APP0/JFIF segment, the usual first thing in a camera's JPEG.
private let snapshotJFIF: [UInt8] = [0xFF, 0xE0, 0x00, 0x10,
                                     0x4A, 0x46, 0x49, 0x46, 0x00,
                                     0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]

// MARK: - Well-formed

@Test func snapshotJPEGDimensionsReadsABaselineFrameHeader() throws {
    let size = try #require(SnapshotJPEGDimensions.size(of: snapshotJPEG()))
    #expect(size.width == 1_920)
    #expect(size.height == 1_080)
}

@Test func snapshotJPEGDimensionsWalksPastAJFIFSegment() throws {
    let size = try #require(SnapshotJPEGDimensions.size(of: snapshotJPEG(preamble: snapshotJFIF)))
    #expect(size.width == 1_920)
    #expect(size.height == 1_080)
}

@Test func snapshotJPEGDimensionsReadsProgressiveAndExtendedFrameHeaders() throws {
    for marker: UInt8 in [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB,
                          0xCD, 0xCE, 0xCF] {
        let size = try #require(SnapshotJPEGDimensions.size(of: snapshotJPEG(marker: marker,
                                                                            width: 640,
                                                                            height: 360)),
                                "marker \(String(marker, radix: 16)) is a frame header")
        #expect(size.width == 640)
        #expect(size.height == 360)
    }
}

@Test func snapshotJPEGDimensionsReadsAFourKFrameHeader() throws {
    let size = try #require(SnapshotJPEGDimensions.size(of: snapshotJPEG(width: 3_840,
                                                                        height: 2_160)))
    #expect(size.width == 3_840)
    #expect(size.height == 2_160)
}

@Test func snapshotJPEGDimensionsToleratesFillBytesBeforeAMarker() throws {
    // FF padding before a marker is legal and some encoders emit it.
    let size = try #require(SnapshotJPEGDimensions.size(of: snapshotJPEG(preamble: [0xFF, 0xFF])))
    #expect(size.width == 1_920)
}

@Test func snapshotJPEGDimensionsSkipsRestartAndTEMMarkers() throws {
    // `D0`–`D7` and `01` are standalone: they carry no length field, and treating them as though
    // they did would consume the two bytes after them and desynchronise the whole walk.
    let size = try #require(SnapshotJPEGDimensions.size(of:
        snapshotJPEG(preamble: [0xFF, 0x01, 0xFF, 0xD0, 0xFF, 0xD7])))
    #expect(size.width == 1_920)
}

@Test func snapshotJPEGDimensionsSkipsTheThreeNonFrameMarkersInTheC0Range() throws {
    // `C4` (DHT), `C8` (JPG) and `CC` (DAC) sit inside `0xC0...0xCF` but are **not** frame headers.
    // A naive range test reads a Huffman table as a picture size.
    let dht: [UInt8] = [0xFF, 0xC4, 0x00, 0x06, 0x00, 0x11, 0x22, 0x33]
    let jpg: [UInt8] = [0xFF, 0xC8, 0x00, 0x04, 0xAA, 0xBB]
    let dac: [UInt8] = [0xFF, 0xCC, 0x00, 0x04, 0xCC, 0xDD]
    let size = try #require(SnapshotJPEGDimensions.size(of:
        snapshotJPEG(width: 704, height: 576, preamble: dht + jpg + dac)))
    #expect(size.width == 704)
    #expect(size.height == 576)
}

// MARK: - Hostile and malformed

@Test func snapshotJPEGDimensionsRejectsEmptyAndTinyBuffers() {
    #expect(SnapshotJPEGDimensions.size(of: Data()) == nil)
    #expect(SnapshotJPEGDimensions.size(of: Data([0xFF])) == nil)
    #expect(SnapshotJPEGDimensions.size(of: Data([0xFF, 0xD8])) == nil)
    #expect(SnapshotJPEGDimensions.size(of: Data([0xFF, 0xD8, 0xFF])) == nil)
}

@Test func snapshotJPEGDimensionsRejectsSomethingThatIsNotAJPEG() {
    // An HTML error page, which is what several firmwares answer with under load — labelled
    // `image/jpeg`.
    let html = Data("<html><body>Device busy</body></html>".utf8)
    #expect(SnapshotJPEGDimensions.size(of: html) == nil)
    #expect(SnapshotJPEGDimensions.size(of: Data([0x89, 0x50, 0x4E, 0x47])) == nil)
}

@Test func snapshotJPEGDimensionsRejectsATruncatedFrameHeader() {
    var bytes = Array(snapshotJPEG())
    bytes = Array(bytes.prefix(8))            // SOI, marker, length, precision, one byte of height
    #expect(SnapshotJPEGDimensions.size(of: Data(bytes)) == nil)
}

@Test func snapshotJPEGDimensionsRejectsASegmentLengthThatRunsPastTheBuffer() {
    // A length field is network data. Trusting it is how a parser reads off the end.
    let liar: [UInt8] = [0xFF, 0xE1, 0x7F, 0xFF]
    #expect(SnapshotJPEGDimensions.size(of: Data([0xFF, 0xD8] + liar)) == nil)
}

@Test func snapshotJPEGDimensionsRejectsASegmentLengthBelowTwo() {
    // A length under 2 does not even cover its own field; advancing by it would loop forever.
    let zeroLength: [UInt8] = [0xFF, 0xE1, 0x00, 0x00, 0x00, 0x00]
    #expect(SnapshotJPEGDimensions.size(of: Data([0xFF, 0xD8] + zeroLength)) == nil)
    let oneLength: [UInt8] = [0xFF, 0xE1, 0x00, 0x01, 0x00, 0x00]
    #expect(SnapshotJPEGDimensions.size(of: Data([0xFF, 0xD8] + oneLength)) == nil)
}

@Test func snapshotJPEGDimensionsRejectsAZeroDimension() {
    // A zero height is legal in the spec — it means "defined later by a DNL marker" — and useless
    // here, so it reads as unknown rather than as 0×W.
    #expect(SnapshotJPEGDimensions.size(of: snapshotJPEG(width: 1_920, height: 0)) == nil)
    #expect(SnapshotJPEGDimensions.size(of: snapshotJPEG(width: 0, height: 1_080)) == nil)
}

@Test func snapshotJPEGDimensionsRejectsAnEndOfImageBeforeAnyFrameHeader() {
    #expect(SnapshotJPEGDimensions.size(of: Data([0xFF, 0xD8, 0xFF, 0xD9, 0x00, 0x00])) == nil)
}

@Test func snapshotJPEGDimensionsReadsFromASliceThatDoesNotStartAtZero() throws {
    // A snapshot body is very often a slice of a larger HTTP buffer. Indexing from 0 instead of from
    // `startIndex` reads the wrong bytes, or traps.
    let padded = Data([0xAA, 0xBB, 0xCC]) + snapshotJPEG(width: 320, height: 240)
    let slice = padded[padded.index(padded.startIndex, offsetBy: 3)...]
    let size = try #require(SnapshotJPEGDimensions.size(of: slice))
    #expect(size.width == 320)
    #expect(size.height == 240)
}

@Test func snapshotJPEGDimensionsTerminatesOnEveryPrefixOfAValidImage() {
    // Fuzz the truncation point: no prefix may hang, trap or read out of bounds.
    let full = snapshotJPEG(preamble: snapshotJFIF)
    for length in 0...full.count {
        _ = SnapshotJPEGDimensions.size(of: full.prefix(length))
    }
}

@Test func snapshotJPEGDimensionsTerminatesOnRunsOfMarkerBytes() {
    for count in 1...64 {
        _ = SnapshotJPEGDimensions.size(of: Data([0xFF, 0xD8] + Array(repeating: 0xFF, count: count)))
    }
    _ = SnapshotJPEGDimensions.size(of: Data(repeating: 0xFF, count: 4_096))
    _ = SnapshotJPEGDimensions.size(of: Data(repeating: 0x00, count: 4_096))
}

#endif
