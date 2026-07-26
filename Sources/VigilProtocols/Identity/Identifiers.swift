//
//  Identifiers.swift
//  VigilProtocols
//
//  The UUID-backed domain identifiers. Every one encodes as a bare JSON string so
//  `library.json` stays readable and diffable by hand.
//
//  Implements docs/API_CONTRACT.md §3.14.
//

import Foundation

// Each identifier is written out in full rather than generated from a shared protocol: the
// contract names exactly these types (API_CONTRACT §2 R-66 forbids inventing a shared supertype),
// and keeping them distinct is the point — a `LayoutID` must never satisfy a `CameraID` parameter.

// MARK: - Camera

/// Identifies one camera (one device *channel*, not one device) in the library.
///
/// Every Vigil identifier encodes as a **bare JSON string**, never as `{"rawValue": …}`.
public struct CameraID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }

    public var description: String { rawValue.uuidString }

    /// First 8 characters. The form that appears in log lines and queue names.
    public var short: String { String(description.prefix(8)) }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// MARK: - Library structure

/// Identifies a user-created group of cameras in the sidebar.
public struct GroupID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }

    public var description: String { rawValue.uuidString }

    /// First 8 characters, for log lines.
    public var short: String { String(description.prefix(8)) }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// Identifies a saved layout (a grid arrangement plus its cell assignments).
public struct LayoutID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }

    public var description: String { rawValue.uuidString }

    /// First 8 characters, for log lines.
    public var short: String { String(description.prefix(8)) }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// MARK: - Timeline

/// Identifies one entry in the event ring. Synthesised by Vigil, never sent by a device — device
/// events are deduplicated onto a single `EventID` by `EventCenter`.
public struct EventID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }

    public var description: String { rawValue.uuidString }

    /// First 8 characters, for log lines.
    public var short: String { String(description.prefix(8)) }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// Identifies one recorded clip written by `ClipRecorder`.
public struct ClipID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }

    public var description: String { rawValue.uuidString }

    /// First 8 characters, for log lines.
    public var short: String { String(description.prefix(8)) }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// Identifies a user bookmark on the playback timeline.
public struct BookmarkID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }

    public var description: String { rawValue.uuidString }

    /// First 8 characters, for log lines.
    public var short: String { String(description.prefix(8)) }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// MARK: - Windows

/// `NSWindow.windowNumber`, wrapped so `VigilCore` can reason about occlusion without AppKit.
///
/// Runtime-only: window numbers are not stable across launches and are never persisted.
public struct WindowID: Hashable, Sendable, Codable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }
}
