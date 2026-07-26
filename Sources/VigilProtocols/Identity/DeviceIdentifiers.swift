//
//  DeviceIdentifiers.swift
//  VigilProtocols
//
//  The three Hikvision addressing spaces: video input channel, streaming channel and
//  playback track. They are deliberately distinct types and never implicitly convert.
//
//  Implements docs/API_CONTRACT.md §3.14 (ruling R-13).
//

// A Hikvision device addresses the same physical camera through three different numeric spaces,
// and mixing them is the classic integration defect: `/PTZCtrl/channels/101` silently does nothing
// on an NVR (there is no input 101), while `/Streaming/channels/1` returns the wrong stream on
// firmware that requires the three-digit form. Encoding the distinction in the type system is the
// only defence that survives a refactor, so:
//
//   * none of the three shares a protocol, a raw-value conformance or an initialiser with another;
//   * only `ChannelID` is `ExpressibleByIntegerLiteral`, so `let s: StreamingChannelID = 302` and
//     `let t: TrackID = 101` do not compile;
//   * the only conversions are the named, explicit `StreamingChannelID(channel:quality:)` and its
//     `channel` / `quality` accessors — every crossing of the boundary is visible at the call site.

// MARK: - Video input channel

/// 1-based **video input** channel. Cameras are always 1; an NVR has one per input.
///
/// Used by `/Image/channels/{ch}`, `/PTZCtrl/channels/{ch}`,
/// `/System/Video/inputs/channels/{ch}`, motion configuration and `EventNotificationAlert`.
///
/// **Not** a streaming channel: see `StreamingChannelID`. The initialiser does not validate,
/// because a device is entitled to report a channel we did not expect and refusing to represent
/// it would lose the diagnostic; use `isPlausible` at the point where a request is built.
public struct ChannelID: Sendable, Hashable, Codable, ExpressibleByIntegerLiteral,
                         CustomStringConvertible, Comparable {
    public let value: Int

    public init(_ value: Int) { self.value = value }

    public init(integerLiteral value: Int) { self.value = value }

    /// The device's first (or only) video input. Every camera, and channel 1 of every NVR.
    public static let first = ChannelID(1)

    /// True for `1...64`, the range a Hikvision NVR can address. Values outside it are almost
    /// always a `StreamingChannelID` that was assigned to the wrong type.
    @inlinable public var isPlausible: Bool { value >= 1 && value <= 64 }

    public var description: String { String(value) }

    public static func < (a: Self, b: Self) -> Bool { a.value < b.value }

    /// Encodes as a bare JSON integer, matching the identifier style of §3.14.
    public init(from decoder: any Decoder) throws {
        value = try decoder.singleValueContainer().decode(Int.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}

// MARK: - Streaming channel

/// `channel * 100 + quality.rawValue`. Used by `/Streaming/channels/{id}`,
/// `/Streaming/channels/{id}/picture` and the RTSP path. **Not interchangeable with `ChannelID`.**
///
/// Channel 1 main is 101; on an NVR, channel 3 sub is 302. Constructing one requires naming both
/// halves, and reading either half back out requires naming which half you want.
public struct StreamingChannelID: Sendable, Hashable, Codable, CustomStringConvertible, Comparable {
    public let value: Int

    /// The only unconditional way to build one: from the two things it is made of.
    public init(channel: ChannelID, quality: StreamQuality) {
        value = channel.value * 100 + quality.rawValue
    }

    /// Parses the composite integer as it appears in ISAPI XML or an RTSP path.
    ///
    /// Rejects values below 101 and quality digits outside `1...3` — that is, anything that is not
    /// a well-formed `channel * 100 + stream`. A device that reports `1` (single-digit firmware)
    /// or `0` therefore yields `nil` rather than a plausible-looking identifier addressing
    /// channel 0; the caller applies `DeviceQuirks.streamingChannelIDIsSingleDigit` instead.
    public init?(rawValue: Int) {
        guard rawValue >= 101 else { return nil }
        guard StreamQuality(rawValue: rawValue % 100) != nil else { return nil }
        value = rawValue
    }

    /// The video input this stream belongs to. The explicit way back to the PTZ/image space.
    public var channel: ChannelID { ChannelID(value / 100) }

    /// Which encoder this stream comes from. Falls back to `.main` for a value that did not come
    /// through `init?(rawValue:)`, which cannot happen for a validated identifier.
    public var quality: StreamQuality { StreamQuality(rawValue: value % 100) ?? .main }

    public var description: String { String(value) }

    public static func < (a: Self, b: Self) -> Bool { a.value < b.value }

    /// Encodes as a bare JSON integer, and **validates on decode**: a persisted `99` throws rather
    /// than becoming a request to channel 0.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(Int.self)
        guard let parsed = StreamingChannelID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "\(raw) is not channel * 100 + stream with stream in 1...3")
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}

// MARK: - Playback track

/// The same numeric space as `StreamingChannelID`, but a **distinct type**: tracks are a recording
/// concept and the two are not interchangeable across firmware. Used by
/// `/ContentMgmt/record/tracks`, `CMSearchDescription.trackIDList` and `/Streaming/tracks/{id}`.
///
/// Some NVRs number tracks `101, 201, …` in parallel with the streaming channels and some do not;
/// the mapping is discovered from `/ContentMgmt/record/tracks`, never assumed. That is exactly why
/// this is its own type with no initialiser taking a `StreamingChannelID`.
public struct TrackID: Sendable, Hashable, Codable, CustomStringConvertible, Comparable {
    public let value: Int

    public init(_ value: Int) { self.value = value }

    public var description: String { String(value) }

    public static func < (a: Self, b: Self) -> Bool { a.value < b.value }

    /// Encodes as a bare JSON integer, matching the identifier style of §3.14.
    public init(from decoder: any Decoder) throws {
        value = try decoder.singleValueContainer().decode(Int.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}
