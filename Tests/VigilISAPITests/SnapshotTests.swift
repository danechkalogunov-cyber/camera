//
//  SettingsAndStorageTests.swift
//  VigilISAPITests
//
//  The motion grid's `gridMap` encoding, the image sub-resources and their read-modify-write
//  patches, JPEG snapshot policy and sniffing, storage volumes in decimal MB, two-way audio codec
//  negotiation, and the event-trigger and schedule readers.
//  Covers docs/spec-isapi.md §12.5, §14.7–§14.9, §15.4, §16 and §17.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilISAPI

// MARK: - SnapshotSuite

@Suite struct SnapshotSuite {

    @Test func snapshotRequestAsksTheSubstreamForAThumbnail() {
        let request = SnapshotWireRequest.thumbnail(channel: ChannelID(7))
        // The substream is 5–10× faster because the device does not have to scale.
        #expect(request.channel.value == 702)
        #expect(request.resource == "/Streaming/channels/702/picture")
        #expect(request.query.map(\.name) == ["videoResolutionWidth", "videoResolutionHeight"])
        #expect(request.query.map(\.value) == ["160", "90"])
    }

    @Test func snapshotRequestClampsAndPairsItsDimensions() {
        var request = SnapshotWireRequest(channel: StreamingChannelID(channel: .first,
                                                                     quality: .sub),
                                          width: 10, height: 99_999)
        #expect(request.query.map(\.value) == ["64", "4320"])
        // Both dimensions or neither: a device given only a width answers `badParameters` on some
        // firmware and ignores it on others.
        request.height = nil
        #expect(request.query.isEmpty)
    }

    @Test func snapshotRequestDropsTheQueryAfterA403() {
        // `snapshotIgnoresResolutionQuery`: retry once with no query, then remember.
        let request = SnapshotWireRequest.thumbnail(channel: .first)
        #expect(!request.query.isEmpty)
        #expect(request.withoutResolutionQuery.query.isEmpty)
        #expect(request.withoutResolutionQuery.resource == request.resource)
    }

    @Test func snapshotSniffsTheSOIMarkerRatherThanTrustingTheHeader() throws {
        // Some 5.2.x devices answer `Content-Type: text/html` with a JPEG body, so the bytes are
        // the only trustworthy evidence.
        var jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        jpeg.append(Data(repeating: 0x41, count: 32))
        #expect(SnapshotPayload.hasJPEGMarker(jpeg))
        #expect(try SnapshotPayload.validate(jpeg, contentType: "text/html") == jpeg)

        let html = Data("<html><body>login</body></html>".utf8)
        #expect(!SnapshotPayload.hasJPEGMarker(html))
        #expect(throws: ISAPIError.unexpectedContentType(expected: "image/jpeg",
                                                        got: "image/jpeg")) {
            _ = try SnapshotPayload.validate(html, contentType: "image/jpeg")
        }
    }

    @Test func snapshotTreatsAnEmptyBodyAsAnOfflineChannel() {
        // An empty 200 is an NVR reporting the channel offline, not a zero-byte image.
        #expect(throws: ISAPIError.device(statusCode: 4, sub: "ipcOffline")) {
            _ = try SnapshotPayload.validate(Data(), contentType: "image/jpeg")
        }
    }

    @Test func snapshotMarkerCheckHandlesShortAndSlicedBodies() {
        #expect(!SnapshotPayload.hasJPEGMarker(Data([0xFF, 0xD8])))
        #expect(!SnapshotPayload.hasJPEGMarker(Data()))
        // A `Data` slice does not start at index zero; the check must still work.
        let padded = Data([0x00, 0x00, 0xFF, 0xD8, 0xFF, 0xE0])
        #expect(SnapshotPayload.hasJPEGMarker(padded.dropFirst(2)))
        #expect(!SnapshotPayload.hasJPEGMarker(padded.dropFirst(1)))
    }
}
