//
//  LibraryChannelInventory.swift
//  VigilCore
//
//  The persisted projection of a device's channel list: what `/ISAPI/…/channels` (or the DESCRIBE
//  fallback) told us, in the smallest shape worth keeping on disk.
//  Implements docs/REQUIREMENTS-CUSTOMER.md §R1.3 and docs/spec-core.md §5.2.
//
//  Why this is not `VigilISAPI.DeviceChannel` written straight to the file:
//
//  * `DeviceChannel.streams` is a `[StreamQuality: StreamingChannelConfig]`. A Swift dictionary
//    whose key is neither `String` nor `Int` encodes as a flat alternating array, in whatever order
//    the hash seed of *that process* produced — so the same library would serialise to different
//    bytes on every launch, defeating both the deterministic-file rule (docs/spec-core.md §5.3) and
//    `LibraryStore`'s skip-the-write-when-unchanged check.
//  * The persisted form must be stable for years; `DeviceChannel` belongs to the ISAPI layer and is
//    free to change with the endpoints it models. Coupling the file format to it would turn an
//    endpoint refactor into a migration.
//
//  So this is a cache record with a stable schema, built from `DeviceChannel` by the initialiser
//  below, and the ISAPI type stays the live, authoritative shape.
//

#if os(macOS)

import Foundation
import VigilISAPI
import VigilProtocols

// MARK: - ChannelInventorySource

/// Where a channel list came from, so a stale or partial one can be recognised later.
///
/// The raw values are persistence keys: renaming a case must not change the file.
public enum ChannelInventorySource: String, Sendable, Hashable, Codable, CaseIterable {

    /// Merged from the ISAPI endpoints of R1.3 — `InputProxy/channels`, `Video/inputs/channels`
    /// and `Streaming/channels`. The complete answer.
    case isapi

    /// ISAPI was unavailable, so channels were found by short-timeout `DESCRIBE` probes (R1.3
    /// fallback). Trustworthy for existence, silent about names and about anything above the
    /// highest channel probed.
    case describeProbe

    /// The user typed the channel list. Never overwritten by a probe.
    case manual
}

// MARK: - LibraryChannel

/// One channel of one device, as persisted.
public struct LibraryChannel: Sendable, Hashable, Codable, Identifiable {

    /// The video-input channel. `Identifiable` on it, because it is unique within an inventory.
    public var id: ChannelID { channel }

    /// 1-based device video input — the index `/PTZCtrl`, `/Image` and motion configuration use.
    public var channel: ChannelID

    /// Best name the device gave, or `Channel N`. Shown in the "add channels" list.
    public var name: String

    /// The device's own verdict on whether the channel has a signal. An NVR reports its proxied
    /// cameras' state here; a camera's local input is always online.
    public var isOnline: Bool

    /// Whether the channel is enabled on the *device*. Unrelated to `Camera.isEnabled`, which is
    /// Vigil's own setting.
    public var isEnabled: Bool

    /// The device's explanation when the channel is offline, verbatim, for the diagnostics bundle.
    public var offlineReason: String?

    /// The encoders the device advertised for this channel, ascending (`main` before `sub`).
    ///
    /// Sorted on construction and on `normalized()` so the file is deterministic.
    public var qualities: [StreamQuality]

    enum CodingKeys: String, CodingKey {
        case channel, name, isOnline, isEnabled, offlineReason, qualities
    }

    /// Builds a channel record. `qualities` is sorted, so callers need not.
    public init(channel: ChannelID,
                name: String,
                isOnline: Bool = true,
                isEnabled: Bool = true,
                offlineReason: String? = nil,
                qualities: [StreamQuality] = []) {
        self.channel = channel
        self.name = name
        self.isOnline = isOnline
        self.isEnabled = isEnabled
        self.offlineReason = offlineReason
        self.qualities = qualities.sorted()
    }

    /// Forgiving decode: only `channel` is required; a missing name becomes `Channel N`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let channel = try container.decode(ChannelID.self, forKey: .channel)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
        self.init(channel: channel,
                  name: name?.isEmpty == false ? (name ?? "") : "Channel \(channel.value)",
                  isOnline: try container.decodeIfPresent(Bool.self, forKey: .isOnline) ?? true,
                  isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
                  offlineReason: try container.decodeIfPresent(String.self, forKey: .offlineReason),
                  qualities: try container.decodeIfPresent([StreamQuality].self,
                                                           forKey: .qualities) ?? [])
    }

    /// Exact encode, except that `offlineReason` is omitted when absent — an explicit `null` on
    /// every online channel would triple the size of a 64-channel NVR's inventory for nothing.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(channel, forKey: .channel)
        try container.encode(name, forKey: .name)
        try container.encode(isOnline, forKey: .isOnline)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(offlineReason, forKey: .offlineReason)
        try container.encode(qualities, forKey: .qualities)
    }
}

// MARK: - CameraChannelInventory

/// Every channel a device reported, filed under the camera record it was enumerated through.
///
/// Keyed by camera **and** by device address: the camera id is the identity, and `host`/`httpPort`
/// let a second channel of the same NVR reuse the list instead of enumerating it again (R1.3).
public struct CameraChannelInventory: Sendable, Hashable, Codable, Identifiable {

    /// The camera whose connection performed the enumeration.
    public var id: CameraID { cameraID }

    /// The camera record this inventory was learned through.
    public var cameraID: CameraID

    /// The device address at the time of enumeration. Compared against a camera's `host` to decide
    /// whether a new record can reuse this list.
    public var host: String

    /// The ISAPI control port at the time of enumeration. Part of the device's identity, because
    /// two cameras behind one NAT can share a host and differ only here.
    public var httpPort: Int

    /// The channels, ascending by channel number.
    public var channels: [LibraryChannel]

    /// How the list was obtained. `.describeProbe` means "existence only" — see
    /// ``ChannelInventorySource``.
    public var source: ChannelInventorySource

    /// When the device was enumerated, for the "re-scan channels" affordance's staleness label.
    public var enumeratedAt: Date

    enum CodingKeys: String, CodingKey {
        case cameraID, host, httpPort, channels, source, enumeratedAt
    }

    /// Builds an inventory. `channels` is sorted by channel number, so callers need not.
    public init(cameraID: CameraID,
                host: String,
                httpPort: Int,
                channels: [LibraryChannel],
                source: ChannelInventorySource,
                enumeratedAt: Date) {
        self.cameraID = cameraID
        self.host = host
        self.httpPort = httpPort
        self.channels = channels.sorted { $0.channel < $1.channel }
        self.source = source
        self.enumeratedAt = enumeratedAt
    }

    /// Builds an inventory from the ISAPI layer's merged channel list.
    ///
    /// The one conversion site between `VigilISAPI.DeviceChannel` and what Vigil stores. `qualities`
    /// keeps only which encoders exist; the rest of `StreamingChannelConfig` — resolution, bitrate,
    /// GOP — is a live device setting that would be wrong the moment a user changed it in the
    /// camera's own web UI, so it is deliberately not persisted.
    public init(cameraID: CameraID,
                host: String,
                httpPort: Int,
                deviceChannels: [DeviceChannel],
                source: ChannelInventorySource = .isapi,
                enumeratedAt: Date) {
        self.init(cameraID: cameraID,
                  host: host,
                  httpPort: httpPort,
                  channels: deviceChannels.map { channel in
                      LibraryChannel(channel: channel.channel,
                                     name: channel.displayName,
                                     isOnline: channel.isOnline,
                                     isEnabled: channel.isEnabled,
                                     offlineReason: channel.offlineReason,
                                     qualities: Array(channel.streams.keys))
                  },
                  source: source,
                  enumeratedAt: enumeratedAt)
    }

    /// Forgiving decode: an unknown `source` string becomes `.describeProbe` rather than failing the
    /// whole document, because the pessimistic reading of an inventory we cannot classify is
    /// "existence only".
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawSource = try container.decodeIfPresent(String.self, forKey: .source)
        self.init(cameraID: try container.decode(CameraID.self, forKey: .cameraID),
                  host: try container.decodeIfPresent(String.self, forKey: .host) ?? "",
                  httpPort: try container.decodeIfPresent(Int.self, forKey: .httpPort) ?? 80,
                  channels: try container.decodeIfPresent([LibraryChannel].self,
                                                          forKey: .channels) ?? [],
                  source: rawSource.flatMap(ChannelInventorySource.init(rawValue:))
                      ?? .describeProbe,
                  enumeratedAt: try container.decodeIfPresent(Date.self, forKey: .enumeratedAt)
                      ?? Date(timeIntervalSince1970: 0))
    }

    /// Exact encode. `source` is written as its raw string so the enum can gain cases without
    /// changing the file.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cameraID, forKey: .cameraID)
        try container.encode(host, forKey: .host)
        try container.encode(httpPort, forKey: .httpPort)
        try container.encode(channels, forKey: .channels)
        try container.encode(source.rawValue, forKey: .source)
        try container.encode(enumeratedAt, forKey: .enumeratedAt)
    }
}

// MARK: - Derived values

public extension CameraChannelInventory {

    /// A copy with channels sorted, de-duplicated by channel number, and each channel's qualities
    /// sorted. Called by `LibraryDocument.normalize()`.
    ///
    /// The first record for a channel wins, because a merge that already ran put the better-known
    /// one first.
    func normalized() -> CameraChannelInventory {
        var seen = Set<ChannelID>()
        var unique: [LibraryChannel] = []
        for channel in channels.sorted(by: { $0.channel < $1.channel }) {
            guard seen.insert(channel.channel).inserted else { continue }
            unique.append(LibraryChannel(channel: channel.channel,
                                         name: channel.name,
                                         isOnline: channel.isOnline,
                                         isEnabled: channel.isEnabled,
                                         offlineReason: channel.offlineReason,
                                         qualities: channel.qualities))
        }
        var copy = self
        copy.channels = unique
        return copy
    }

    /// The channels worth offering the user: enabled on the device, and either online or unknown.
    ///
    /// R1.3 requires every populated channel to be offered pre-checked; an NVR input with nothing
    /// plugged into it is not populated and must not be.
    var populatedChannels: [LibraryChannel] {
        channels.filter { $0.isEnabled && $0.isOnline }
    }

    /// True when the list is worth trusting as complete. A `.describeProbe` inventory never is:
    /// it only ever saw the channels it happened to probe.
    var isAuthoritative: Bool {
        source != .describeProbe
    }
}

#endif
