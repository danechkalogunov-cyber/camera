//
//  PlaybackLocator.swift
//  VigilISAPI
//
//  The address of one recorded segment: the `playbackURI` a search returned, with its scheme, host
//  and port replaced and its **path and query kept verbatim**.
//  Implements docs/spec-isapi.md §15.3 and docs/API_CONTRACT.md §2 R-29.
//
//  The verbatim rule is not fussiness. The device fills in the address it believes it has, which on
//  a multi-homed NVR or behind NAT is not the address Vigil reached it on — so scheme, host and port
//  must be rewritten. Everything after the path must not be touched: `name=ch01_00000000019000000`
//  is a device-internal file name that has to survive byte for byte, and running the query through
//  `URLComponents` has been observed to reorder items on some Foundation versions. So the raw query
//  string is stored and concatenated, never re-encoded.
//

import Foundation
import VigilProtocols

// MARK: - PlaybackLocator

/// A ready-to-play recorded-segment address, consumed by `VigilRTSP`.
public struct PlaybackLocator: Sendable, Hashable, Codable {
    /// `"/Streaming/tracks/101"`, with any trailing slash trimmed.
    public let path: String
    /// `"starttime=…&endtime=…&name=…&size=…"`, exactly as the device wrote it after XML
    /// unescaping. Empty when the device sent no query.
    public let rawQuery: String
    public let start: Date
    public let end: Date
    /// The device-internal file name, when the device supplied one. Passed through, never
    /// synthesised.
    public let fileName: String?
    public let sizeBytes: Int64?

    public init(path: String, rawQuery: String, start: Date, end: Date,
                fileName: String?, sizeBytes: Int64?) {
        self.path = path
        self.rawQuery = rawQuery
        self.start = start
        self.end = end
        self.fileName = fileName
        self.sizeBytes = sizeBytes
    }

    /// Builds a locator for direct seeking, with no search round trip.
    ///
    /// Hikvision accepts a synthesised URI, and Vigil uses it for scrubbing **inside a segment it
    /// already knows about**. It is never used to discover footage: an arbitrary time with no
    /// recording yields an RTSP 404 or a stream that ends immediately.
    ///
    /// Omitting `end` means "play to the end of available footage".
    public init(track: TrackID, start: Date, end: Date?) {
        var query = "starttime=\(ISAPITime.compactUTC(start))"
        if let end { query += "&endtime=\(ISAPITime.compactUTC(end))" }
        self.init(path: "/Streaming/tracks/\(track.value)",
                  rawQuery: query,
                  start: start,
                  end: end ?? start,
                  fileName: nil,
                  sizeBytes: nil)
    }

    /// Parses a `playbackURI` as the device wrote it.
    ///
    /// Returns `nil` only when there is no path to play. A missing `name` or `size` is fine — some
    /// firmware omits both, and `starttime`/`endtime` are sufficient. The times are read from the
    /// query when present; `fallbackStart`/`fallbackEnd` come from the search result's own
    /// `<timeSpan>`, which every firmware does send.
    public init?(playbackURI raw: String, fallbackStart: Date? = nil, fallbackEnd: Date? = nil) {
        // Deliberately hand-parsed. `URL` would percent-decode the query, and re-encoding it is
        // exactly what breaks playback on the firmwares that matter.
        var remainder = Substring(raw)
        if let schemeEnd = remainder.range(of: "://") {
            remainder = remainder[schemeEnd.upperBound...]
            guard let slash = remainder.firstIndex(of: "/") else { return nil }
            remainder = remainder[slash...]
        }
        let query: String
        let pathPart: Substring
        if let mark = remainder.firstIndex(of: "?") {
            pathPart = remainder[remainder.startIndex..<mark]
            query = String(remainder[remainder.index(after: mark)...])
        } else {
            pathPart = remainder
            query = ""
        }
        var path = String(pathPart)
        // Some firmware emits a trailing slash; RTSP servers differ on whether they tolerate it.
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix("/") else { return nil }
        let items = Self.queryItems(query)
        let start = items["starttime"].flatMap { ISAPITime.parse($0)?.date } ?? fallbackStart
        let end = items["endtime"].flatMap { ISAPITime.parse($0)?.date } ?? fallbackEnd
        guard let start else { return nil }
        self.init(path: path,
                  rawQuery: query,
                  start: start,
                  end: end ?? start,
                  fileName: items["name"],
                  sizeBytes: items["size"].flatMap { Int64($0) })
    }

    /// The request URI `VigilRTSP` puts on the request line, with the address rewritten and the
    /// query untouched.
    ///
    /// Credentials are **never** embedded: `rtsp://user:pass@host/...` leaks into logs and crash
    /// reports, and `VigilRTSP` authenticates with Digest instead.
    public func requestURI(host: String, port: Int, useTLS: Bool = false) -> String {
        let scheme = useTLS ? "rtsps" : "rtsp"
        // An IPv6 literal is bracketed exactly once; the host is stored unbracketed everywhere.
        let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let base = "\(scheme)://\(authority):\(port)\(path)"
        return rawQuery.isEmpty ? base : "\(base)?\(rawQuery)"
    }

    /// The `Range` header value for `PLAY`:
    /// `"clock=20240501T080000Z-20240501T081459Z"`.
    public var clockRange: String {
        "clock=\(ISAPITime.compactUTC(start))-\(ISAPITime.compactUTC(end))"
    }

    /// The same locator with device-local compact times, for the firmwares that interpret
    /// `starttime` as local despite the `Z` (`DeviceQuirks.playbackTimesAreDeviceLocal`).
    ///
    /// Only the two time items are rewritten; `name` and `size` keep their positions and values.
    public func shiftedForDeviceLocalTimes(utcOffsetSeconds: Int) -> PlaybackLocator {
        guard utcOffsetSeconds != 0 else { return self }
        let shift = Double(utcOffsetSeconds)
        let items = Self.orderedQueryItems(rawQuery).map { item -> String in
            switch item.name {
            case "starttime":
                "starttime=" + ISAPITime.compactUTC(start.addingTimeInterval(shift))
            case "endtime":
                "endtime=" + ISAPITime.compactUTC(end.addingTimeInterval(shift))
            default:
                item.value.isEmpty ? item.name : "\(item.name)=\(item.value)"
            }
        }
        return PlaybackLocator(path: path, rawQuery: items.joined(separator: "&"),
                               start: start, end: end, fileName: fileName, sizeBytes: sizeBytes)
    }

    // MARK: Query splitting

    /// Splits a raw query into a lookup table. No percent-decoding: Hikvision does not
    /// percent-encode these values and decoding them would corrupt nothing but risk everything.
    static func queryItems(_ query: String) -> [String: String] {
        var out: [String: String] = [:]
        for item in orderedQueryItems(query) where !item.name.isEmpty {
            out[item.name.lowercased()] = item.value
        }
        return out
    }

    /// The same split, order preserved.
    static func orderedQueryItems(_ query: String) -> [(name: String, value: String)] {
        query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            guard let equals = pair.firstIndex(of: "=") else { return (String(pair), "") }
            return (String(pair[pair.startIndex..<equals]),
                    String(pair[pair.index(after: equals)...]))
        }
    }
}
