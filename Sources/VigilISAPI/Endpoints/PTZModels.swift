//
//  PTZModels.swift
//  VigilISAPI
//
//  Presets, patrols, status and per-channel PTZ capability: the read side of `/PTZCtrl`.
//  Implements docs/spec-isapi.md §13.6, §13.7, §13.8 and §13.9.
//
//  Two device facts shape this file. Presets 33–105 are **built-in commands**, not storage slots —
//  preset 94 reboots the camera — so writing one is refused here rather than at the UI. And the
//  capability document's root element is spelled `PTZChanelCap` on most firmware and
//  `PTZChannelCap` on the rest, which is why every read goes through path alternation.
//

import Foundation
import VigilProtocols

// MARK: - PTZPreset

/// One preset slot.
public struct PTZPreset: Sendable, Hashable, Codable, Identifiable {
    public let id: Int
    public var name: String
    public var enabled: Bool

    public init(id: Int, name: String, enabled: Bool) {
        self.id = id
        self.name = name
        self.enabled = enabled
    }

    /// The inclusive range Hikvision reserves for built-in commands.
    ///
    /// These are not storage slots: 33 is auto-flip, 94 is remote reboot, 95 opens the OSD menu.
    /// They are listed read-only in a "Special commands" section and never written.
    public static let reservedCommands = 33...105

    /// True when this id is a device command rather than a user preset.
    public var isReservedCommand: Bool { Self.reservedCommands.contains(id) }

    /// The slots Vigil offers in the ordinary preset UI.
    public static let userSlots = 1...32

    /// The name Vigil shows: the device's, or `Preset N` when the device stored an empty one.
    public var displayName: String { name.isEmpty ? "Preset \(id)" : name }

    /// Decodes every `<PTZPreset>` in a `<PTZPresetList>` (or a single-preset document).
    public static func list(document: ISAPIDocument) -> [PTZPreset] {
        let nodes = document.nodes("PTZPreset[]")
        let source = nodes.isEmpty ? [document.root] : nodes
        return source.compactMap { node in
            guard let id = node["id"].int else { return nil }
            return PTZPreset(id: id,
                             name: node["presetName"].string ?? "",
                             enabled: node["enabled"].bool ?? true)
        }
    }

    /// `<PTZPreset><id>…</id><presetName>…</presetName></PTZPreset>`.
    ///
    /// The name is truncated to 30 UTF-8 bytes on a **character** boundary: most firmware caps
    /// `presetName` at 32 bytes, and cutting a multi-byte character in half produces
    /// `invalidXMLContent` rather than a shorter name.
    public static func writeBody(id: Int, name: String) -> XMLBuilder {
        var builder = XMLBuilder("PTZPreset")
        builder.add("id", id)
        builder.add("presetName", truncate(name, toUTF8Bytes: 30))
        return builder
    }

    /// Truncates to at most `limit` UTF-8 bytes without splitting a character.
    static func truncate(_ name: String, toUTF8Bytes limit: Int) -> String {
        guard name.utf8.count > limit else { return name }
        var out = String()
        var used = 0
        for character in name {
            let size = String(character).utf8.count
            if used + size > limit { break }
            out.append(character)
            used += size
        }
        return out
    }
}

// MARK: - PTZPatrol

/// One patrol and its ordered stops.
public struct PTZPatrol: Sendable, Hashable, Codable, Identifiable {

    /// One stop on a patrol.
    public struct Stop: Sendable, Hashable, Codable {
        public let presetID: Int
        /// Seconds to dwell, 0…255.
        public let dwellSeconds: Int
        /// A device speed index, 1…40 — **not** the −100…100 continuous scale.
        public let speed: Int

        public init(presetID: Int, dwellSeconds: Int, speed: Int) {
            self.presetID = presetID
            self.dwellSeconds = dwellSeconds
            self.speed = speed
        }
    }

    /// 1…8.
    public let id: Int
    public var name: String
    public var enabled: Bool
    public var stops: [Stop]

    public init(id: Int, name: String, enabled: Bool, stops: [Stop]) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.stops = stops
    }

    /// Decodes every `<PTZPatrol>` in a `<PTZPatrolList>`.
    ///
    /// Element casing varies across firmware — `<PresetID>`, `<presetID>` and `<presetId>` all
    /// occur, as do `<dwellTime>` and `<DwellTime>` — so every read uses alternation. Path
    /// matching is case-insensitive anyway; the alternation is what absorbs the *spelling*
    /// differences the case rules do not cover.
    public static func list(document: ISAPIDocument) -> [PTZPatrol] {
        let nodes = document.nodes("PTZPatrol[]")
        let source = nodes.isEmpty ? [document.root] : nodes
        return source.compactMap { node in
            guard let id = node["id"].int else { return nil }
            let stops = node.nodes("PatrolSequenceList/PatrolSequence[]").compactMap { stop -> Stop? in
                guard let preset = stop["PresetID|presetID|presetId"].int else { return nil }
                return Stop(presetID: preset,
                            dwellSeconds: stop["dwellTime|DwellTime"].int ?? 0,
                            speed: stop["speed|Speed"].int ?? 1)
            }
            return PTZPatrol(id: id,
                             name: node["patrolName"].string ?? "",
                             enabled: node["enabled"].bool ?? true,
                             stops: stops)
        }
    }
}

// MARK: - PTZStatus

/// `GET /PTZCtrl/channels/{ch}/status`. Never cached, and polled at 2 Hz only while the PTZ panel
/// is visible — it is a surprisingly expensive call on some domes and can stutter the encoder.
public struct PTZStatus: Sendable, Hashable, Codable {
    public let position: PTZAbsolutePosition

    public init(position: PTZAbsolutePosition) {
        self.position = position
    }

    /// Decodes `<PTZStatus><AbsoluteHigh>`. The block is required: a status document without a
    /// position tells the caller nothing, and returning a zeroed position would make the
    /// `position3D` Y-axis calibration silently conclude "not inverted".
    public init(document: ISAPIDocument) throws(ISAPIError) {
        let context = "PTZStatus"
        guard let high = document.node("AbsoluteHigh") else {
            throw ISAPIError.malformedResponse("\(context): no <AbsoluteHigh> element")
        }
        self.init(position: PTZAbsolutePosition(
            wireAzimuth: try high["azimuth"].requireInt(context),
            wireElevation: try high["elevation"].requireInt(context),
            wireZoom: high["absoluteZoom"].int ?? 0))
    }
}

// MARK: - PTZCapabilitiesWire

/// What one channel's PTZ subsystem can do.
public struct PTZCapabilitiesWire: Sendable, Hashable, Codable {
    public var supportsContinuous: Bool
    /// Rarely advertised; resolved by probe, then remembered.
    public var supportsMomentary: Bool
    public var supportsAbsolute: Bool
    public var supportsRelative: Bool
    public var supportsPosition3D: Bool
    public var supportsPresets: Bool
    public var maxPresets: Int
    public var supportsPatrols: Bool
    public var maxPatrols: Int
    public var supportsFocus: Bool
    public var supportsIris: Bool
    public var auxiliaries: [PTZAuxiliary]
    /// Wire units: tenths of a degree.
    public var azimuthRange: ClosedRange<Int>
    public var elevationRange: ClosedRange<Int>
    /// Wire zoom steps.
    public var zoomRange: ClosedRange<Int>
    /// True when the whole PTZ subsystem answered 403/404 — hide every PTZ affordance.
    public var isAbsent: Bool

    public init(supportsContinuous: Bool, supportsMomentary: Bool, supportsAbsolute: Bool,
                supportsRelative: Bool, supportsPosition3D: Bool, supportsPresets: Bool,
                maxPresets: Int, supportsPatrols: Bool, maxPatrols: Int, supportsFocus: Bool,
                supportsIris: Bool, auxiliaries: [PTZAuxiliary], azimuthRange: ClosedRange<Int>,
                elevationRange: ClosedRange<Int>, zoomRange: ClosedRange<Int>, isAbsent: Bool) {
        self.supportsContinuous = supportsContinuous
        self.supportsMomentary = supportsMomentary
        self.supportsAbsolute = supportsAbsolute
        self.supportsRelative = supportsRelative
        self.supportsPosition3D = supportsPosition3D
        self.supportsPresets = supportsPresets
        self.maxPresets = maxPresets
        self.supportsPatrols = supportsPatrols
        self.maxPatrols = maxPatrols
        self.supportsFocus = supportsFocus
        self.supportsIris = supportsIris
        self.auxiliaries = auxiliaries
        self.azimuthRange = azimuthRange
        self.elevationRange = elevationRange
        self.zoomRange = zoomRange
        self.isAbsent = isAbsent
    }

    /// The capability set for a channel whose PTZ endpoints answered 403 or 404: everything false,
    /// so every PTZ affordance disappears instead of failing on use.
    public static let absent = PTZCapabilitiesWire(
        supportsContinuous: false, supportsMomentary: false, supportsAbsolute: false,
        supportsRelative: false, supportsPosition3D: false, supportsPresets: false,
        maxPresets: 0, supportsPatrols: false, maxPatrols: 0, supportsFocus: false,
        supportsIris: false, auxiliaries: [], azimuthRange: 0...3600,
        elevationRange: -900...2700, zoomRange: 1...1000, isAbsent: true)

    /// Decodes `<PTZChanelCap>` — or `<PTZChannelCap>`, on the firmware that spelled it correctly.
    ///
    /// Never throws: a PTZ camera that omits half the document is still a PTZ camera. Absent flags
    /// read **false** rather than being guessed at, because a rejected `position3D` looks to the
    /// user like a broken drag gesture rather than an unsupported feature.
    ///
    /// The range blocks live under a wrapper whose name also varies, so each is looked up by its
    /// distinctive inner element via a descendant search.
    public init(document: ISAPIDocument) {
        let presence = document["isSupportPreset"].bool ?? false
        let auxiliaries: [PTZAuxiliary] = (document["isSupportAux"].bool ?? false)
            ? [.light, .wiper] : []
        self.init(
            supportsContinuous: document["ContinuousPanTiltSpace"].exists
                || document["isSupportContinuous"].bool ?? true,
            supportsMomentary: document["isSupportMomentary"].bool ?? false,
            supportsAbsolute: document["AbsolutePanTiltPositionSpace"].exists,
            supportsRelative: document["RelativePanTiltSpace"].exists,
            supportsPosition3D: document["isSupportPosition3D"].bool ?? false,
            supportsPresets: presence,
            maxPresets: document["maxPresetNum|maxPresetNums"].int ?? (presence ? 255 : 0),
            supportsPatrols: document["isSupportPatrol"].bool ?? false,
            maxPatrols: document["maxPatrolNum|maxPatrolNums"].int ?? 0,
            supportsFocus: document["isSupportFocus"].bool ?? false,
            supportsIris: document["isSupportIris"].bool ?? false,
            auxiliaries: auxiliaries,
            azimuthRange: Self.range(document, "AbsolutePanTiltPositionSpace/XRange",
                                     fallback: 0...3600),
            elevationRange: Self.range(document, "AbsolutePanTiltPositionSpace/YRange",
                                       fallback: -900...2700),
            zoomRange: Self.range(document, "AbsoluteZoomPositionSpace/ZRange", fallback: 1...1000),
            isAbsent: false)
    }

    /// Reads a `<min>`/`<max>` pair, falling back when either is missing or inverted.
    private static func range(_ document: ISAPIDocument, _ path: String,
                              fallback: ClosedRange<Int>) -> ClosedRange<Int> {
        guard let node = document.node(path),
              let low = node["min"].int, let high = node["max"].int, low <= high else {
            return fallback
        }
        return low...high
    }
}

// MARK: - PTZ channel list

/// `GET /PTZCtrl/channels`: which channels of an NVR are PTZ-capable, so per-channel capability
/// probing is not needed for the other sixty. Often 404 on a camera, which is not an error.
public enum PTZChannelList {

    /// Decodes `<PTZChannelList><PTZChannel><id>`.
    public static func channels(document: ISAPIDocument) -> [ChannelID] {
        document.nodes("PTZChannel[]").compactMap { node in
            node["id"].int.map(ChannelID.init)
        }
    }
}
