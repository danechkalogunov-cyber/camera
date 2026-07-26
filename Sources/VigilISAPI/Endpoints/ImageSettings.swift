//
//  ImageSettings.swift
//  VigilISAPI
//
//  `/ISAPI/Image/channels/{ch}/…`: colour, sharpness, WDR, IR-cut and the rest, read per
//  sub-resource and written read-modify-write. Implements docs/spec-isapi.md §17.1 and §17.2.
//
//  Every write here is read-modify-write on the sub-element, echoing the device's own `version` and
//  `xmlns` attributes: some 5.4.x builds reject a `<Color>` body without them. Writes go to the
//  sub-resources rather than to `<ImageChannel>` as a whole, because a whole-channel PUT is rejected
//  by most firmware.
//
//  Which controls exist is discovered, not assumed: each sub-resource is fetched, a 403 or 404 means
//  "this camera does not have that control", and the UI shows only what came back. That is why
//  `ImageSettings.available` exists and why a missing control is not an error.
//

import Foundation
import VigilProtocols

// MARK: - ImageControl

/// One image sub-resource.
public enum ImageControl: String, Sendable, Hashable, Codable, CaseIterable {
    case color, sharpness, wdr, blc, hlc, ircut, noiseReduce, whiteBalance
    case exposure, shutter, gamma, flip, powerLine

    /// The last path component of the sub-resource. Note the capitalisation: `WDR`, `BLC` and `HLC`
    /// are upper-case on the wire and `ircutFilter` is not the same string as the case name.
    public var resourceName: String {
        switch self {
        case .color: "color"
        case .sharpness: "sharpness"
        case .wdr: "WDR"
        case .blc: "BLC"
        case .hlc: "HLC"
        case .ircut: "ircutFilter"
        case .noiseReduce: "noiseReduce"
        case .whiteBalance: "whiteBalance"
        case .exposure: "exposure"
        case .shutter: "shutter"
        case .gamma: "gamma"
        case .flip: "imageFlip"
        case .powerLine: "powerLineFrequency"
        }
    }

    /// The root element the device answers with, used when a body has to be built from nothing.
    public var rootElement: String {
        switch self {
        case .color: "Color"
        case .sharpness: "Sharpness"
        case .wdr: "WDR"
        case .blc: "BLC"
        case .hlc: "HLC"
        case .ircut: "IrcutFilter"
        case .noiseReduce: "NoiseReduce"
        case .whiteBalance: "WhiteBalance"
        case .exposure: "Exposure"
        case .shutter: "Shutter"
        case .gamma: "Gamma"
        case .flip: "ImageFlip"
        case .powerLine: "PowerLineFrequency"
        }
    }
}

// MARK: - WDRSetting

/// Wide dynamic range.
public struct WDRSetting: Sendable, Hashable, Codable {

    /// `open`, `close` or `auto`.
    public enum Mode: String, Sendable, Hashable, Codable {
        case open, close, auto

        init(raw: String?) {
            switch ISAPIVocabulary.normalize(raw ?? "") {
            case "open", "on", "true", "enable", "enabled": self = .open
            case "auto": self = .auto
            default: self = .close
            }
        }
    }

    public var mode: Mode
    /// 0…100, meaningful when `mode == .open`.
    public var level: Int?

    public init(mode: Mode, level: Int?) {
        self.mode = mode
        self.level = level
    }

    /// Decodes a `<WDR>` document.
    public init(document: ISAPIDocument) {
        self.init(mode: Mode(raw: document["mode|WDRMode|enabled"].string),
                  level: document["WDRLevel|wdrLevel|level"].int)
    }
}

// MARK: - IRCutSetting

/// The IR-cut filter, i.e. day/night switching.
public struct IRCutSetting: Sendable, Hashable, Codable {

    /// The filter modes. `schedule` and `triggeredByAlarmIn` are read and displayed but Vigil never
    /// writes them: they carry configuration Vigil does not model, and a partial write would drop it.
    public enum Mode: String, Sendable, Hashable, Codable {
        case auto, day, night, schedule, triggeredByAlarmIn

        init(raw: String?) {
            switch ISAPIVocabulary.normalize(raw ?? "") {
            case "day": self = .day
            case "night": self = .night
            case "schedule": self = .schedule
            case "triggeredbyalarmin": self = .triggeredByAlarmIn
            default: self = .auto
            }
        }

        /// The exact wire spelling, which is not always the case name.
        var wireValue: String {
            switch self {
            case .auto: "auto"
            case .day: "day"
            case .night: "night"
            case .schedule: "schedule"
            case .triggeredByAlarmIn: "triggeredByAlarmIn"
            }
        }

        /// False for the two modes Vigil refuses to write.
        var isWritable: Bool { self == .auto || self == .day || self == .night }
    }

    public var mode: Mode
    /// 0…7 switching threshold.
    public var nightToDayLevel: Int?
    /// 3…10 seconds of hysteresis.
    public var nightToDaySeconds: Int?

    public init(mode: Mode, nightToDayLevel: Int?, nightToDaySeconds: Int?) {
        self.mode = mode
        self.nightToDayLevel = nightToDayLevel
        self.nightToDaySeconds = nightToDaySeconds
    }

    /// Decodes an `<IrcutFilter>` document.
    public init(document: ISAPIDocument) {
        self.init(mode: Mode(raw: document["IrcutFilterType|ircutFilterType|mode"].string),
                  nightToDayLevel: document["nightToDayFilterLevel"].int,
                  nightToDaySeconds: document["nightToDayFilterTime"].int)
    }
}

// MARK: - ImageSettings

/// Everything Vigil reads and shows from `/Image/channels/{ch}`.
public struct ImageSettings: Sendable, Hashable, Codable {
    /// 0…100, default 50.
    public var brightness: Int?
    public var contrast: Int?
    public var saturation: Int?
    public var sharpness: Int?
    public var wdr: WDRSetting?
    public var irCut: IRCutSetting?
    /// 0…100 general-mode noise reduction level.
    public var noiseReduction: Int?
    public var whiteBalanceStyle: String?
    /// `CENTER`, `LEFTRIGHT`, `UPDOWN`.
    public var flip: String?
    /// `50hz` or `60hz`.
    public var powerLineFrequency: String?
    /// Which sub-resources actually answered. Drives which controls the UI shows at all.
    public var available: Set<ImageControl>

    public init(brightness: Int? = nil, contrast: Int? = nil, saturation: Int? = nil,
                sharpness: Int? = nil, wdr: WDRSetting? = nil, irCut: IRCutSetting? = nil,
                noiseReduction: Int? = nil, whiteBalanceStyle: String? = nil,
                flip: String? = nil, powerLineFrequency: String? = nil,
                available: Set<ImageControl> = []) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.sharpness = sharpness
        self.wdr = wdr
        self.irCut = irCut
        self.noiseReduction = noiseReduction
        self.whiteBalanceStyle = whiteBalanceStyle
        self.flip = flip
        self.powerLineFrequency = powerLineFrequency
        self.available = available
    }

    /// Folds one sub-resource's document in, and records that the control exists.
    ///
    /// A control whose document arrives but carries no value Vigil models is still marked available:
    /// the device has it, and hiding the slider because a field was named differently would be worse
    /// than showing it with the device's own default.
    public mutating func absorb(_ control: ImageControl, document: ISAPIDocument) {
        available.insert(control)
        switch control {
        case .color:
            brightness = document["brightnessLevel|brightness"].int ?? brightness
            contrast = document["contrastLevel|contrast"].int ?? contrast
            saturation = document["saturationLevel|saturation"].int ?? saturation
        case .sharpness:
            // Both casings occur; reads use alternation so the quirk flag only decides what a
            // read-modify-write body echoes back.
            sharpness = document["SharpnessLevel|sharpnessLevel"].int ?? sharpness
        case .wdr:
            wdr = WDRSetting(document: document)
        case .ircut:
            irCut = IRCutSetting(document: document)
        case .noiseReduce:
            noiseReduction = document["GeneralMode/generalLevel|generalLevel"].int ?? noiseReduction
        case .whiteBalance:
            whiteBalanceStyle = document["whiteBalanceStyle"].string ?? whiteBalanceStyle
        case .flip:
            flip = document["ImageFlipStyle|imageFlipStyle"].string ?? flip
        case .powerLine:
            powerLineFrequency =
                document["powerLineFrequencyMode|powerLineFrequency"].string ?? powerLineFrequency
        case .blc, .hlc, .exposure, .shutter, .gamma:
            break   // present and displayed, but Vigil does not model their values yet
        }
    }
}

// MARK: - Image write bodies

/// The read-modify-write patches for the image sub-resources Vigil writes.
///
/// Each takes the node the device sent and returns the same node with only the intended elements
/// changed, so every element Vigil does not model — and every element a future firmware adds —
/// round-trips untouched, `version` and `xmlns` attributes included.
public enum ImageWrite {

    /// Brightness, contrast, saturation and hue, each 0…100 and each optional.
    ///
    /// Values are clamped rather than rejected: a slider that computes 101 from a drag must still
    /// produce a legal body, and the device's own clamped answer is what the UI then shows.
    public static func color(_ node: XMLNode, brightness: Int?, contrast: Int?,
                            saturation: Int?, hue: Int? = nil) -> XMLNode {
        var result = node
        func level(_ value: Int) -> String { String(min(100, max(0, value))) }
        if let brightness {
            result = result.setting("brightnessLevel|brightness", to: level(brightness))
        }
        if let contrast { result = result.setting("contrastLevel|contrast", to: level(contrast)) }
        if let saturation {
            result = result.setting("saturationLevel|saturation", to: level(saturation))
        }
        if let hue { result = result.setting("hueLevel|hue", to: level(hue)) }
        return result
    }

    /// Sharpness, 0…100.
    public static func sharpness(_ node: XMLNode, level: Int) -> XMLNode {
        node.setting("SharpnessLevel|sharpnessLevel", to: String(min(100, max(0, level))))
    }

    /// WDR mode and level.
    public static func wdr(_ node: XMLNode, _ setting: WDRSetting) -> XMLNode {
        var result = node.setting("mode|WDRMode", to: setting.mode.rawValue)
        if let level = setting.level {
            result = result.setting("WDRLevel|wdrLevel", to: String(min(100, max(0, level))))
        }
        return result
    }

    /// IR-cut mode and its two thresholds.
    ///
    /// Returns `nil` for `schedule` and `triggeredByAlarmIn`: those modes carry schedule or alarm
    /// configuration Vigil does not model, and writing the mode alone would silently discard it.
    public static func irCut(_ node: XMLNode, _ setting: IRCutSetting) -> XMLNode? {
        guard setting.mode.isWritable else { return nil }
        var result = node.setting("IrcutFilterType|ircutFilterType", to: setting.mode.wireValue)
        if let level = setting.nightToDayLevel {
            result = result.setting("nightToDayFilterLevel", to: String(min(7, max(0, level))))
        }
        if let seconds = setting.nightToDaySeconds {
            result = result.setting("nightToDayFilterTime", to: String(min(10, max(3, seconds))))
        }
        return result
    }
}
