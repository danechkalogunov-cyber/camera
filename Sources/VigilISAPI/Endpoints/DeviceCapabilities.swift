//
//  DeviceCapabilities.swift
//  VigilISAPI
//
//  `GET /ISAPI/System/capabilities`, resolved as an ordered list of candidate paths per capability
//  rather than as a schema, plus the conservative defaults and the list of rows that still need a
//  functional probe. Implements docs/spec-isapi.md §10.5.
//
//  `<DeviceCap>` is 20–90 KiB of wildly firmware-dependent XML; modelling it as a type would mean
//  a new struct every firmware. What Vigil actually needs is eighteen answers, so each answer names
//  the paths that have carried it, in order, and says what to assume when none of them are there.
//  A row that is neither present nor defaulted lands in `unresolved`, which is exactly the set of
//  cheap GETs the session runs once per device.
//

import Foundation
import VigilProtocols

// MARK: - DeviceCapability

/// One resolvable capability row. The raw value is the key used in the negative-capability cache
/// and in the diagnostics bundle.
public enum DeviceCapability: String, Sendable, Hashable, Codable, CaseIterable {
    case videoInputChannels, audioInputChannels, streamsPerChannel
    case supportsPTZ, supportsPatrols, supportsTwoWayAudio, supportsAlertStream
    case supportsSmartEvents, supportsHTTPS, supportsJPEGSnapshot, supportsRecordSearch
    case supportsInputProxy, supportsImageColor, supportsWDR, supportsIRCutFilter
    case alarmInputs, alarmOutputs
}

// MARK: - DeviceCapabilitiesWire

/// What the device says it can do, merged with what Vigil assumes when it says nothing.
///
/// `GET /ISAPI/System/capabilities` is allowed to fail entirely — some 5.1.x devices 404 it — and
/// that is not an error: every row then falls through to its probe or its default.
public struct DeviceCapabilitiesWire: Sendable, Hashable, Codable {
    public var videoInputChannels: Int
    public var audioInputChannels: Int
    /// 1…3. Two is the safe assumption: every Hikvision device since 5.1 has a substream.
    public var streamsPerChannel: Int
    public var supportsPTZ: Bool
    public var supportsPatrols: Bool
    public var supportsTwoWayAudio: Bool
    /// Defaults to **true**: the alert stream is near-universal, and assuming otherwise would hide
    /// events on devices that simply do not advertise the capability.
    public var supportsAlertStream: Bool
    public var supportsSmartEvents: Bool
    public var supportsHTTPS: Bool
    public var supportsJPEGSnapshot: Bool
    public var supportsRecordSearch: Bool
    /// NVR IP-channel management.
    public var supportsInputProxy: Bool
    public var supportsImageColor: Bool
    public var supportsWDR: Bool
    public var supportsIRCutFilter: Bool
    public var alarmInputs: Int
    public var alarmOutputs: Int
    /// Rows no path answered. The session probes exactly these, at most once per device.
    public var unresolved: Set<DeviceCapability>
    /// When this snapshot was taken. Injected, never read from the clock here.
    public var probedAt: Date
    /// Bumped when the meaning of a field changes, so a persisted snapshot can be discarded.
    public var schemaVersion: Int

    /// The defaults from docs/spec-isapi.md §10.5, before any document is consulted.
    ///
    /// `family` matters for two rows: a recorder is assumed to support record search and proxied
    /// channels, a camera is not.
    public init(family: DeviceFamily, probedAt: Date) {
        videoInputChannels = 1
        audioInputChannels = 0
        streamsPerChannel = 2
        supportsPTZ = false
        supportsPatrols = false
        supportsTwoWayAudio = false
        supportsAlertStream = true
        supportsSmartEvents = false
        supportsHTTPS = false
        supportsJPEGSnapshot = true
        supportsRecordSearch = family.isRecorder
        supportsInputProxy = family.isRecorder
        supportsImageColor = true
        supportsWDR = false
        supportsIRCutFilter = false
        alarmInputs = 0
        alarmOutputs = 0
        unresolved = Set(DeviceCapability.allCases)
        self.probedAt = probedAt
        schemaVersion = 1
    }

    /// Resolves every row against a `<DeviceCap>` document, leaving the defaults in place for rows
    /// the device did not answer and recording those rows in `unresolved`.
    ///
    /// Candidate paths are tried in the documented order and the **first** one that yields a value
    /// wins; `**` descends, which is how the `ImageCap` and `PTZCap` rows survive the several
    /// nesting depths firmware uses for them.
    public init(document: ISAPIDocument, family: DeviceFamily, probedAt: Date) {
        self.init(family: family, probedAt: probedAt)

        resolve(document, .videoInputChannels, \.videoInputChannels, clampedTo: 1...1024,
                ["VideoCap/videoInputChannelNums", "SysCap/videoInNo",
                 "RacmCap/videoInputChannelNums"])
        resolve(document, .audioInputChannels, \.audioInputChannels, clampedTo: 0...1024,
                ["AudioCap/audioInputChannelNums", "SysCap/audioInNo"])
        resolve(document, .streamsPerChannel, \.streamsPerChannel, clampedTo: 1...3,
                ["SysCap/SupportStreamingChannelNums", "RacmCap/SupportStreamingChannelNums"])
        resolve(document, .alarmInputs, \.alarmInputs, clampedTo: 0...1024,
                ["SysCap/alarmInNo", "SysCap/IOCap/IOInputPortNums"])
        resolve(document, .alarmOutputs, \.alarmOutputs, clampedTo: 0...1024,
                ["SysCap/alarmOutNo", "SysCap/IOCap/IOOutputPortNums"])

        resolve(document, .supportsPTZ, \.supportsPTZ,
                ["SysCap/isSupportPTZ", "SysCap/isSupportPtz", "PTZCap/**/isSupportPTZ"])
        resolve(document, .supportsPatrols, \.supportsPatrols,
                ["PTZChanelCap/isSupportPatrol", "PTZChannelCap/isSupportPatrol"])
        resolve(document, .supportsTwoWayAudio, \.supportsTwoWayAudio,
                ["SysCap/isSupportTwoWayAudio"])
        resolve(document, .supportsAlertStream, \.supportsAlertStream,
                ["EventCap/isSupportAlertStream"])
        resolve(document, .supportsHTTPS, \.supportsHTTPS, ["SysCap/isSupportHttps"])
        resolve(document, .supportsJPEGSnapshot, \.supportsJPEGSnapshot,
                ["VideoCap/isSupportSnapshot", "SysCap/isSupportSnapshot"])
        resolve(document, .supportsRecordSearch, \.supportsRecordSearch,
                ["RacmCap/isSupportSearch", "ContentMgmtCap/**/isSupportSearch"])
        resolve(document, .supportsInputProxy, \.supportsInputProxy,
                ["RacmCap/isSupportInputProxy"])
        resolve(document, .supportsImageColor, \.supportsImageColor, ["ImageCap/**/isSupportColor"])
        resolve(document, .supportsWDR, \.supportsWDR, ["ImageCap/**/isSupportWDR"])
        resolve(document, .supportsIRCutFilter, \.supportsIRCutFilter,
                ["ImageCap/**/isSupportIrcutFilter"])

        // Smart events are a disjunction: any one of the three analytics flags counts, and the row
        // is resolved as soon as any of them is present, even when all three read false.
        let smartValues = ["EventCap/isSupportLineDetection", "EventCap/isSupportFieldDetection",
                           "EventCap/isSupportRegionEntrance"].compactMap { document[$0].bool }
        if !smartValues.isEmpty {
            supportsSmartEvents = smartValues.contains(true)
            unresolved.remove(.supportsSmartEvents)
        }
    }

    /// Applies the outcome of a functional probe: a 200 means yes, a 403/404/405 means no, and in
    /// both cases the row stops being unresolved so it is never probed twice.
    public mutating func applyProbe(_ capability: DeviceCapability, supported: Bool) {
        unresolved.remove(capability)
        switch capability {
        case .supportsPTZ: supportsPTZ = supported
        case .supportsPatrols: supportsPatrols = supported
        case .supportsTwoWayAudio: supportsTwoWayAudio = supported
        case .supportsAlertStream: supportsAlertStream = supported
        case .supportsJPEGSnapshot: supportsJPEGSnapshot = supported
        case .supportsRecordSearch: supportsRecordSearch = supported
        case .supportsInputProxy: supportsInputProxy = supported
        case .supportsImageColor: supportsImageColor = supported
        case .supportsWDR: supportsWDR = supported
        case .supportsIRCutFilter: supportsIRCutFilter = supported
        case .supportsHTTPS: supportsHTTPS = supported
        case .supportsSmartEvents: supportsSmartEvents = supported
        case .videoInputChannels, .audioInputChannels, .streamsPerChannel,
             .alarmInputs, .alarmOutputs:
            break   // counted rows are resolved by `applyCount`, not by a yes/no probe
        }
    }

    /// Applies a counted probe result — the size of `/System/Video/inputs/channels`, or the size
    /// of `/Streaming/channels` divided by the channel count.
    public mutating func applyCount(_ capability: DeviceCapability, _ count: Int) {
        unresolved.remove(capability)
        switch capability {
        case .videoInputChannels: videoInputChannels = max(1, count)
        case .audioInputChannels: audioInputChannels = max(0, count)
        case .streamsPerChannel: streamsPerChannel = min(3, max(1, count))
        case .alarmInputs: alarmInputs = max(0, count)
        case .alarmOutputs: alarmOutputs = max(0, count)
        default: break
        }
    }

    // MARK: Resolution helpers

    /// Writes the first integer any candidate path yields, clamped: firmware has been seen to
    /// report `videoInNo` as `-1`, and a negative channel count would produce an empty inventory
    /// with no explanation.
    private mutating func resolve(_ document: ISAPIDocument, _ row: DeviceCapability,
                                  _ field: WritableKeyPath<Self, Int>,
                                  clampedTo range: ClosedRange<Int>, _ paths: [String]) {
        for path in paths {
            guard let value = document[path].int else { continue }
            self[keyPath: field] = min(range.upperBound, max(range.lowerBound, value))
            unresolved.remove(row)
            return
        }
    }

    /// Writes the first boolean any candidate path yields.
    private mutating func resolve(_ document: ISAPIDocument, _ row: DeviceCapability,
                                  _ field: WritableKeyPath<Self, Bool>, _ paths: [String]) {
        for path in paths {
            guard let value = document[path].bool else { continue }
            self[keyPath: field] = value
            unresolved.remove(row)
            return
        }
    }
}
