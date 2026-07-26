//
//  SnapshotEncoderMetadataTests.swift
//  VigilCoreTests
//
//  The EXIF date and offset arithmetic, and the clamping of the JPEG quality — the parts of the
//  encoder that are arithmetic rather than ImageIO.
//  Covers Sources/VigilCore/Recording/SnapshotEncoder.swift.
//
//  Runs identically on macOS and in the Linux shadow harness under scratchpad/shadow-recording, which
//  is where these were executed. The ImageIO calls themselves are not asserted here: their stubs
//  cannot tell a right call from a wrong one, and claiming otherwise would be worse than saying so.
//

#if os(macOS)

import Foundation
import Testing
import VigilCore
import VigilVideo

// MARK: - Support

/// 2026-07-26 14:31:07 UTC.
private let snapshotEncoderDate = Date(timeIntervalSince1970: 1_785_076_267)

private let snapshotEncoderUTC = TimeZone(secondsFromGMT: 0) ?? .gmt

// MARK: - EXIF dates

@Test func snapshotEncoderWritesEXIFDatesWithColonsInTheDatePart() {
    // **`yyyy:MM:dd HH:mm:ss`.** The colons in the date are the classic mistake: `2026-07-26 …` is
    // accepted by many writers and then read back as no date at all by Preview, Photos and every
    // forensic tool — the difference between a still that is evidence and one that is a picture.
    let stamp = SnapshotEncoder.exifDate(snapshotEncoderDate, timeZone: snapshotEncoderUTC)
    #expect(stamp == "2026:07:26 14:31:07")
    #expect(!stamp.contains("-"))
}

@Test func snapshotEncoderWritesEXIFDatesInTheCamerasZone() {
    let moscow = TimeZone(secondsFromGMT: 3 * 3_600) ?? .gmt
    #expect(SnapshotEncoder.exifDate(snapshotEncoderDate, timeZone: moscow)
            == "2026:07:26 17:31:07")
}

@Test func snapshotEncoderZeroPadsEveryEXIFDateField() {
    // 2026-01-02 03:04:05 UTC.
    let early = Date(timeIntervalSince1970: 1_767_323_045)
    #expect(SnapshotEncoder.exifDate(early, timeZone: snapshotEncoderUTC)
            == "2026:01:02 03:04:05")
}

// MARK: - EXIF offsets

@Test func snapshotEncoderWritesAPositiveOffsetWithASignAndColon() {
    let moscow = TimeZone(secondsFromGMT: 3 * 3_600) ?? .gmt
    #expect(SnapshotEncoder.exifOffset(moscow, at: snapshotEncoderDate) == "+03:00")
}

@Test func snapshotEncoderWritesANegativeOffset() {
    let pacific = TimeZone(secondsFromGMT: -8 * 3_600) ?? .gmt
    #expect(SnapshotEncoder.exifOffset(pacific, at: snapshotEncoderDate) == "-08:00")
}

@Test func snapshotEncoderWritesUTCAsPlusZero() {
    #expect(SnapshotEncoder.exifOffset(snapshotEncoderUTC, at: snapshotEncoderDate) == "+00:00")
}

@Test func snapshotEncoderWritesAHalfHourOffset() {
    // India is +05:30 and Nepal is +05:45; an offset formatter that assumes whole hours is wrong for
    // about a fifth of the planet.
    let india = TimeZone(secondsFromGMT: 5 * 3_600 + 1_800) ?? .gmt
    #expect(SnapshotEncoder.exifOffset(india, at: snapshotEncoderDate) == "+05:30")
    let nepal = TimeZone(secondsFromGMT: 5 * 3_600 + 2_700) ?? .gmt
    #expect(SnapshotEncoder.exifOffset(nepal, at: snapshotEncoderDate) == "+05:45")
}

@Test func snapshotEncoderWritesANegativeHalfHourOffset() {
    let marquesas = TimeZone(secondsFromGMT: -(9 * 3_600 + 1_800)) ?? .gmt
    #expect(SnapshotEncoder.exifOffset(marquesas, at: snapshotEncoderDate) == "-09:30")
}

// MARK: - Quality clamping

@Test func snapshotEncodeOptionsClampsQualityIntoTheUsableBand() {
    // Below 0.5 a security still stops being usable as evidence, which is the only reason anyone
    // saves one.
    #expect(SnapshotEncodeOptions(format: .jpeg, quality: 0.1).quality == 0.5)
    #expect(SnapshotEncodeOptions(format: .jpeg, quality: -5).quality == 0.5)
    #expect(SnapshotEncodeOptions(format: .jpeg, quality: 2).quality == 1.0)
    #expect(SnapshotEncodeOptions(format: .jpeg, quality: 0.9).quality == 0.9)
}

@Test func snapshotEncodeOptionsDefaultsToLosslessPNG() {
    let options = SnapshotEncodeOptions()
    #expect(options.format == .png)
    #expect(options.includeMetadata)
}

// MARK: - Formats

@Test func snapshotFormatUsesTheConventionalExtensions() {
    #expect(SnapshotFormat.png.fileExtension == "png")
    // `jpg`, not `jpeg`: it is what every other application on the Mac writes.
    #expect(SnapshotFormat.jpeg.fileExtension == "jpg")
}

@Test func snapshotFormatMarksOnlyJPEGAsLossy() {
    #expect(!SnapshotFormat.png.isLossy)
    #expect(SnapshotFormat.jpeg.isLossy)
}

// MARK: - User comment

@Test func snapshotEncoderUserCommentNamesTheCameraTheTimeTheSizeAndTheRoute() {
    let metadata = SnapshotMetadata(cameraName: "Front Door",
                                    capturedAt: snapshotEncoderDate,
                                    timeZone: snapshotEncoderUTC,
                                    make: "Hikvision",
                                    model: "DS-2CD2143G0-I",
                                    software: "Vigil 1.0",
                                    origin: .deviceJPEG)
    let comment = SnapshotEncoder.userComment(pixelWidth: 2_688, pixelHeight: 1_520,
                                              metadata: metadata)
    #expect(comment == "Front Door — 2026:07:26 14:31:07 +00:00 — 2688×1520 — camera JPEG — Vigil 1.0")
    // The serial number is never written into metadata, on the same redaction rule as the logs.
    #expect(!comment.contains("DS-2CD2143G0-I"))
}

@Test func snapshotEncoderUserCommentNamesTheDisplayedFrameRoute() {
    let metadata = SnapshotMetadata(cameraName: "Lobby", capturedAt: snapshotEncoderDate,
                                    timeZone: snapshotEncoderUTC, software: "Vigil 1.0",
                                    origin: .displayedFrame)
    let comment = SnapshotEncoder.userComment(pixelWidth: 640, pixelHeight: 360,
                                              metadata: metadata)
    #expect(comment.contains("displayed frame"))
    #expect(comment.contains("640×360"))
}

#endif
