//
//  Snapshots.swift
//  VigilISAPI
//
//  `GET /ISAPI/Streaming/channels/{id}/picture`: the thumbnail fast path, its resolution query,
//  and the content sniffing that makes it work on firmware that lies about `Content-Type`.
//  Implements docs/spec-isapi.md §12.5.
//
//  A snapshot costs the device real time — 300–700 ms for 4K, competing with the encoder — so the
//  policy encoded here is as much a part of the endpoint as the URL: always ask the substream,
//  never ask for main-stream resolution, and treat an empty 200 as the NVR saying the channel is
//  offline rather than as a zero-byte image.
//

import Foundation
import VigilProtocols

// MARK: - SnapshotWireRequest

/// One JPEG snapshot request.
public struct SnapshotWireRequest: Sendable, Hashable {
    /// Which stream to snapshot. Use the **substream** for thumbnails: it is 5–10× faster because
    /// the device does not have to scale.
    public var channel: StreamingChannelID
    /// 64…7680. Must be set together with `height`.
    public var width: Int?
    /// 64…4320.
    public var height: Int?
    /// Set when the device has already refused a query-bearing snapshot with `403 notSupport`;
    /// the retry, and every later request, omits the query entirely.
    public var omitResolutionQuery: Bool

    public init(channel: StreamingChannelID, width: Int? = nil, height: Int? = nil,
                omitResolutionQuery: Bool = false) {
        self.channel = channel
        self.width = width
        self.height = height
        self.omitResolutionQuery = omitResolutionQuery
    }

    /// A sidebar-row thumbnail: 160×90 from the substream.
    public static func thumbnail(channel: ChannelID) -> SnapshotWireRequest {
        SnapshotWireRequest(channel: StreamingChannelID(channel: channel, quality: .sub),
                            width: 160, height: 90)
    }

    /// The resource path for this request.
    public var resource: String { ISAPIResource.picture(channel) }

    /// The query items to send.
    ///
    /// Both dimensions or neither: a device given only a width answers `badParameters` on some
    /// firmware and silently ignores it on others, and neither is worth the round trip. Values are
    /// clamped into the documented range rather than rejected, because a caller asking for a
    /// 20-pixel thumbnail wants the smallest picture available, not an error.
    public var query: [URLQueryItem] {
        guard !omitResolutionQuery, let width, let height else { return [] }
        let clampedWidth = min(7680, max(64, width))
        let clampedHeight = min(4320, max(64, height))
        return [URLQueryItem(name: "videoResolutionWidth", value: String(clampedWidth)),
                URLQueryItem(name: "videoResolutionHeight", value: String(clampedHeight))]
    }

    /// The same request with the resolution query dropped, for the one documented retry.
    public var withoutResolutionQuery: SnapshotWireRequest {
        var copy = self
        copy.omitResolutionQuery = true
        return copy
    }
}

// MARK: - Snapshot validation

/// Content checks for a snapshot response body.
public enum SnapshotPayload {

    /// The JPEG start-of-image marker. Some 5.2.x devices label a JPEG as `text/html`, so the
    /// bytes are the only trustworthy evidence of what arrived.
    public static let soiMarker: [UInt8] = [0xFF, 0xD8, 0xFF]

    /// Validates a snapshot body.
    ///
    /// - An empty body with HTTP 200 is an NVR reporting the channel as offline, not an image;
    ///   it becomes `.device(statusCode: 4, sub: "ipcOffline")` so the UI shows the offline reason
    ///   instead of a broken-image placeholder.
    /// - A non-empty body that does not begin with `FF D8 FF` is whatever the device sent instead
    ///   of an image — usually an HTML error page — and becomes `.unexpectedContentType`.
    ///
    /// - Parameters:
    ///   - body: the raw response body.
    ///   - contentType: the header value, used only for the error message.
    public static func validate(_ body: Data, contentType: String?) throws(ISAPIError) -> Data {
        guard !body.isEmpty else {
            throw ISAPIError.device(statusCode: 4, sub: "ipcOffline")
        }
        guard hasJPEGMarker(body) else {
            throw ISAPIError.unexpectedContentType(expected: "image/jpeg", got: contentType)
        }
        return body
    }

    /// True when `body` begins with the JPEG SOI marker.
    public static func hasJPEGMarker(_ body: Data) -> Bool {
        guard body.count >= soiMarker.count else { return false }
        return body.withUnsafeBytes { raw -> Bool in
            for (offset, expected) in soiMarker.enumerated() where raw[offset] != expected {
                return false
            }
            return true
        }
    }
}
