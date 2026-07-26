//
//  ChannelInventory.swift
//  VigilISAPI
//
//  One flat list of streamable channels whether the device is a one-channel camera or a 64-channel
//  NVR with half its inputs offline: `/ContentMgmt/InputProxy/channels`,
//  `/System/Video/inputs/channels` and `/Streaming/channels`, merged.
//  Implements docs/spec-isapi.md §11.1–§11.4.
//
//  This is what stops the user having to guess channel numbers. The merge is deliberately ordered:
//  `/Streaming/channels` is authoritative for stream facts because it is the endpoint that
//  actually describes the encoders, while names come from `InputProxy` first — on an NVR that is
//  the name the operator typed into the NVR, and it is what they expect to see in Vigil.
//

import Foundation
import VigilProtocols

// MARK: - UpstreamSource

/// Where an NVR's proxied channel gets its video from. Absent for a camera's local inputs.
public struct UpstreamSource: Sendable, Hashable, Codable {
    /// `ISAPI`, `ONVIF`, `HIKVISION`, `PSIA` or `RTSP`, verbatim.
    public let protocolName: String
    public let ipAddress: String?
    public let managePort: Int?
    /// The channel number **on the upstream camera**, which is 1 for a single-sensor camera even
    /// when the NVR calls the channel 7.
    public let sourceInputPort: Int?
    public let userName: String?
    public let deviceID: String?

    public init(protocolName: String, ipAddress: String?, managePort: Int?,
                sourceInputPort: Int?, userName: String?, deviceID: String?) {
        self.protocolName = protocolName
        self.ipAddress = ipAddress
        self.managePort = managePort
        self.sourceInputPort = sourceInputPort
        self.userName = userName
        self.deviceID = deviceID
    }

    /// Decodes a `<sourceInputPortDescriptor>` element.
    public init(node: XMLNode) {
        self.init(protocolName: node["proxyProtocol"].string ?? "unknown",
                  ipAddress: node["ipAddress"].string,
                  managePort: node["managePortNo"].int,
                  sourceInputPort: node["srcInputPort"].int,
                  userName: node["userName"].string,
                  deviceID: node["deviceID"].string)
    }
}

// MARK: - InputProxyChannel

/// One `<InputProxyChannel>`: an NVR's record of a camera it proxies.
public struct InputProxyChannel: Sendable, Hashable, Codable {
    public let channel: ChannelID
    public let name: String?
    public let upstream: UpstreamSource?

    public init(channel: ChannelID, name: String?, upstream: UpstreamSource?) {
        self.channel = channel
        self.name = name
        self.upstream = upstream
    }

    /// Decodes every entry of an `<InputProxyChannelList>`.
    public static func list(document: ISAPIDocument) -> [InputProxyChannel] {
        document.nodes("InputProxyChannel[]").compactMap { node in
            guard let id = node["id"].int else { return nil }
            return InputProxyChannel(
                channel: ChannelID(id),
                name: node["name"].string,
                upstream: node.node("sourceInputPortDescriptor").map(UpstreamSource.init(node:)))
        }
    }
}

// MARK: - InputProxyChannelStatus

/// One `<InputProxyChannelStatus>`: whether the NVR can currently reach that camera.
public struct InputProxyChannelStatus: Sendable, Hashable, Codable {
    public let channel: ChannelID
    public let online: Bool
    /// `online`, `offline`, `notSupport`, `networkAbnormal`, `userOrPasswordError`,
    /// `notActivated` — surfaced verbatim, because "wrong password on channel 7" is exactly what
    /// the user needs to be told.
    public let detectResult: String?

    public init(channel: ChannelID, online: Bool, detectResult: String?) {
        self.channel = channel
        self.online = online
        self.detectResult = detectResult
    }

    /// Decodes one status element.
    public init?(node: XMLNode) {
        guard let id = node["id"].int else { return nil }
        // `online` is the primary signal; `chanDetectResult` is the explanation. A firmware that
        // omits `online` but says `chanDetectResult` is `online` still counts as online.
        let detect = node["chanDetectResult"].string
        let online = node["online"].bool
            ?? (detect.map { ISAPIVocabulary.normalize($0) == "online" } ?? false)
        self.init(channel: ChannelID(id), online: online, detectResult: detect)
    }

    /// Decodes the list form (`/InputProxy/channels/status`) and, as a fallback, the single-channel
    /// form — both roots produce the same shape, so one reader serves both.
    public static func list(document: ISAPIDocument) -> [InputProxyChannelStatus] {
        let nodes = document.nodes("InputProxyChannelStatus[]")
        if !nodes.isEmpty { return nodes.compactMap(InputProxyChannelStatus.init(node:)) }
        // Single-channel form: the fields live directly on the root.
        return [InputProxyChannelStatus(node: document.root)].compactMap { $0 }
    }
}

// MARK: - VideoInputChannel

/// One `<VideoInputChannel>`: a local sensor or analog input, and the source of the `{ch}` index
/// used by `/Image/channels/{ch}` and motion detection.
public struct VideoInputChannel: Sendable, Hashable, Codable {
    public let channel: ChannelID
    public let name: String?
    /// `PAL` or `NTSC` on analog inputs; absent on IP cameras.
    public let videoFormat: String?
    public let resolutionDescription: String?

    public init(channel: ChannelID, name: String?, videoFormat: String?,
                resolutionDescription: String?) {
        self.channel = channel
        self.name = name
        self.videoFormat = videoFormat
        self.resolutionDescription = resolutionDescription
    }

    /// Decodes every entry of a `<VideoInputChannelList>`.
    public static func list(document: ISAPIDocument) -> [VideoInputChannel] {
        document.nodes("VideoInputChannel[]").compactMap { node in
            guard let id = node["id"].int else { return nil }
            return VideoInputChannel(channel: ChannelID(id),
                                     name: node["name"].string,
                                     videoFormat: node["videoFormat"].string,
                                     resolutionDescription: node["resDesc"].string)
        }
    }
}

// MARK: - DeviceChannel

/// The merged, user-facing channel: one row in Vigil's camera list.
public struct DeviceChannel: Sendable, Hashable, Codable, Identifiable {
    public var id: ChannelID { channel }

    /// The **video input** channel — the index `/PTZCtrl`, `/Image` and motion detection use.
    public let channel: ChannelID
    /// Best available of the InputProxy name, the video-input name, the streaming channel name,
    /// and finally `Channel N`.
    public var displayName: String
    public var isEnabled: Bool
    /// True for local inputs; for an NVR's proxied channels this is the NVR's own verdict.
    public var isOnline: Bool
    /// `chanDetectResult` when the channel is offline.
    public var offlineReason: String?
    /// Present only for an NVR's proxied channels.
    public var upstream: UpstreamSource?
    /// The encoder outputs for this channel, keyed by quality.
    public var streams: [StreamQuality: StreamingChannelConfig]

    public init(channel: ChannelID, displayName: String, isEnabled: Bool, isOnline: Bool,
                offlineReason: String?, upstream: UpstreamSource?,
                streams: [StreamQuality: StreamingChannelConfig]) {
        self.channel = channel
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.isOnline = isOnline
        self.offlineReason = offlineReason
        self.upstream = upstream
        self.streams = streams
    }

    /// The stream Vigil should open for a given quality, falling back to whatever the channel has.
    ///
    /// A channel with only a main stream must still be openable at `.sub`: refusing would leave an
    /// NVR channel blank in the grid for no user-visible reason.
    public func stream(preferring quality: StreamQuality) -> StreamingChannelConfig? {
        if let exact = streams[quality] { return exact }
        for candidate in StreamQuality.allCases.sorted() where streams[candidate] != nil {
            return streams[candidate]
        }
        return nil
    }

    /// The identifier for one of this channel's streams, whether or not the device advertised it.
    ///
    /// `channel * 100 + quality` is the whole mapping; it is arithmetic, not a lookup, and the
    /// `{ch}0{stream}` form from old Hikvision documents is wrong for `ch >= 10`.
    public func streamingChannelID(_ quality: StreamQuality) -> StreamingChannelID {
        StreamingChannelID(channel: channel, quality: quality)
    }
}

// MARK: - ChannelInventory

/// The merge of the three inventory endpoints into one list.
public enum ChannelInventory {

    /// Merges the streaming inventory with whatever naming and status information was available.
    ///
    /// Order of precedence, from docs/spec-isapi.md §11:
    ///
    /// * **Existence** — a channel exists if any source mentions it. A proxied NVR channel that is
    ///   currently offline has no `<StreamingChannel>` element on some firmware, and dropping it
    ///   would make the channel vanish from the UI exactly when the user needs to see why.
    /// * **Stream facts** — always from `/Streaming/channels`.
    /// * **Name** — InputProxy, then video input, then the streaming channel's own name, then
    ///   `Channel N`.
    /// * **Online** — proxied status when present; local inputs are always online.
    ///
    /// - Parameters:
    ///   - streaming: every `<StreamingChannel>` the device reported.
    ///   - inputProxy: proxied channels, empty on a camera.
    ///   - proxyStatus: proxied channel status, empty when unsupported.
    ///   - videoInputs: local video inputs, empty when the endpoint 404s.
    public static func merge(streaming: [StreamingChannelConfig],
                             inputProxy: [InputProxyChannel] = [],
                             proxyStatus: [InputProxyChannelStatus] = [],
                             videoInputs: [VideoInputChannel] = []) -> [DeviceChannel] {
        var streamsByChannel: [ChannelID: [StreamQuality: StreamingChannelConfig]] = [:]
        var namesFromStreaming: [ChannelID: String] = [:]
        for config in streaming {
            let channel = config.id.channel
            streamsByChannel[channel, default: [:]][config.id.quality] = config
            if namesFromStreaming[channel] == nil, let name = config.channelName, !name.isEmpty {
                namesFromStreaming[channel] = name
            }
        }
        let proxyByChannel = Dictionary(inputProxy.map { ($0.channel, $0) },
                                        uniquingKeysWith: { first, _ in first })
        let statusByChannel = Dictionary(proxyStatus.map { ($0.channel, $0) },
                                         uniquingKeysWith: { first, _ in first })
        let inputsByChannel = Dictionary(videoInputs.map { ($0.channel, $0) },
                                         uniquingKeysWith: { first, _ in first })

        var known = Set(streamsByChannel.keys)
        known.formUnion(proxyByChannel.keys)
        known.formUnion(inputsByChannel.keys)

        return known.sorted().map { channel in
            let proxy = proxyByChannel[channel]
            let status = statusByChannel[channel]
            let input = inputsByChannel[channel]
            let streams = streamsByChannel[channel] ?? [:]
            let name = [proxy?.name, input?.name, namesFromStreaming[channel]]
                .compactMap { $0 }
                .first(where: { !$0.isEmpty })
                ?? "Channel \(channel.value)"
            // A proxied channel with no status document is assumed reachable: the status endpoint
            // is the part that 404s on DS-76xx/77xx, and defaulting to "offline" there would grey
            // out every channel on those NVRs.
            let online = status?.online ?? true
            return DeviceChannel(channel: channel,
                                 displayName: name,
                                 isEnabled: streams.values.contains { $0.enabled } || streams.isEmpty,
                                 isOnline: online,
                                 offlineReason: online ? nil : status?.detectResult,
                                 upstream: proxy?.upstream,
                                 streams: streams)
        }
    }

    /// The inventory to use when `/Streaming/channels` itself failed.
    ///
    /// Synthesising channel 1 main and sub is the documented fallback: it is what every Hikvision
    /// device has, and an empty camera list is a worse answer than an optimistic one that either
    /// works or fails visibly at the RTSP layer.
    public static func fallbackSingleChannel() -> [DeviceChannel] {
        [DeviceChannel(channel: .first, displayName: "Channel 1", isEnabled: true, isOnline: true,
                       offlineReason: nil, upstream: nil, streams: [:])]
    }
}
