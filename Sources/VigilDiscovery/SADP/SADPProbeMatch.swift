//
//  SADPProbeMatch.swift
//  VigilDiscovery
//
//  The Hikvision SADP `ProbeMatch` wire record: every documented element typed, every element at all
//  preserved, plus the serial-to-model split and the classification hints derived from it.
//  See docs/spec-discovery.md §4.3, §4.5 and docs/API_CONTRACT.md §4.6.
//

import Foundation
import VigilProtocols

// MARK: - Payload encoding

/// How a SADP datagram's bytes were turned into text.
///
/// Hikvision firmware sold in China emits GB18030 in `DeviceDescription`. GB18030 is not available
/// in Linux Foundation, so a payload that is not valid UTF-8 is reinterpreted byte-for-scalar as
/// ISO-8859-1: the Chinese description becomes mojibake but the model, serial, MAC and every port —
/// all ASCII — survive intact, which is what actually decides whether the camera is usable (§4.5.2).
public enum SADPPayloadEncoding: String, Sendable, Hashable, Codable {
    /// The payload was valid UTF-8.
    case utf8
    /// The payload was not valid UTF-8 and was reinterpreted as ISO-8859-1. The caller emits
    /// `DiscoveryDiagnostic.nonUTF8SADPPayload`.
    case isoLatin1Fallback
}

// MARK: - ProbeMatch

/// One decoded SADP `ProbeMatch` datagram.
///
/// Every field is optional because element presence varies by firmware generation — a 5.7.x camera
/// omits `RtspPort`, a factory-fresh one omits `HttpsPort`, an NVR adds `DiskNumber`. Absent means
/// "the device did not say", never "zero". `raw` keeps the complete element set, including elements
/// this type does not model, because a future firmware's new field is worth more in a support log
/// than in a parser rewrite.
public struct SADPProbeMatch: Sendable, Hashable, Codable {

    // MARK: Correlation

    /// The `Uuid` echoed from a probe. Used to tell our own run's answers from another SADP client's.
    public let uuid: String?

    // MARK: Identity and description

    /// `DeviceType`: 0 camera, 1 DVR, 2 NVR, 3 encoder/decoder. Opaque across firmware — a hint that
    /// only breaks a tie, never the primary class signal (§4.3).
    public let deviceType: Int?
    /// `DeviceDescription`, e.g. `IPCamera`, `NVR`, `IP Dome`. The primary class signal.
    public let deviceDescription: String?
    /// `DeviceSN` verbatim, e.g. `DS-2CD2143G0-I20200114AAWRD12345678`. This is what is printed on
    /// the label and what ISAPI returns, so it is stored whole; `model` extracts the leading part.
    public let deviceSN: String?

    // MARK: Ports

    /// `CommandPort` — the Hikvision SDK/private-protocol port, normally 8000.
    public let commandPort: UInt16?
    /// `HttpPort` — the ISAPI base port.
    public let httpPort: UInt16?
    /// `HttpsPort`, present on firmware 5.5.x and later.
    public let httpsPort: UInt16?
    /// `RtspPort`. Absent on many models, where 554 is the default.
    public let rtspPort: UInt16?

    // MARK: Addressing

    /// `MAC`, accepted in every separator style firmware emits.
    public let mac: MACAddress?
    /// `IPv4Address`. `0.0.0.0` decodes to `nil`, because "unconfigured" is not an address.
    public let ipv4Address: IPv4Address?
    /// `IPv4SubnetMask`.
    public let ipv4SubnetMask: IPv4Address?
    /// `IPv4Gateway`. `0.0.0.0` decodes to `nil`.
    public let ipv4Gateway: IPv4Address?
    /// `IPv6Address`, display only. `::` and the empty string decode to `nil`.
    public let ipv6Address: String?
    /// `DHCP`.
    public let dhcp: Bool?

    // MARK: Firmware

    /// `SoftwareVersion` verbatim, e.g. `V5.5.82build 190910`. See `normalizedFirmwareVersion`.
    public let softwareVersion: String?
    /// `DSPVersion`, e.g. `V7.3 build 190430`.
    public let dspVersion: String?
    /// `BootTime` exactly as sent: `yyyy-MM-dd HH:mm:ss` in the **device's** local time with no zone
    /// (§4.5.4). Never interpreted as UTC — use `bootTime(in:)` with an explicit zone for display.
    public let bootTimeLocalString: String?

    // MARK: State

    /// `Activated`. `false` means the device has no password at all and nothing will connect until
    /// it is activated — the single most important thing this datagram can tell a user (§4.6).
    public let activated: Bool?
    /// `PasswordResetAbility` — whether the device supports SADP password reset.
    public let passwordResetAbility: Bool?
    /// `SupportHCPlatform` — Hik-Connect capability.
    public let supportHCPlatform: Bool?
    /// `AnalogChannelNum`; greater than zero implies a DVR or hybrid.
    public let analogChannelNum: Int?
    /// `DigitalChannelNum`; greater than zero implies an NVR.
    public let digitalChannelNum: Int?
    /// `DiskNumber`; greater than zero implies a recorder.
    public let diskNumber: Int?
    /// `OEMinfo`, e.g. `HiLook`. Present and non-empty on rebranded firmware.
    public let oemInfo: String?
    /// `DeviceLock` — the device is currently in authentication lockout. Diagnostic only, and a
    /// standing reminder of why discovery never sends credentials (§6.10).
    public let deviceLock: Bool?

    // MARK: Provenance

    /// Every element seen, lowercased local name to trimmed text, including unmodelled ones.
    public let raw: [String: String]
    /// The datagram's UDP source address, supplied by the caller — it is not in the XML.
    public let observedFrom: IPv4Address
    /// When the datagram arrived, on the injected clock.
    public let receivedAt: Date
    /// How the bytes were decoded to text. Not part of the wire format; recorded so the caller can
    /// raise `DiscoveryDiagnostic.nonUTF8SADPPayload` without decoding twice.
    public let payloadEncoding: SADPPayloadEncoding
    /// True when the XML was truncated or unbalanced and this record was salvaged under the §4.5.1
    /// recovery rule. The fields present are still trustworthy; absent ones may simply be missing.
    public let isRecoveredFromMalformedXML: Bool

    // MARK: Construction

    /// Builds a record from a parsed element dictionary.
    ///
    /// Keys are lowercased local names. Values that fail to parse — a port above 65 535, a MAC with
    /// eleven nibbles, `not-a-date` — leave their field `nil` rather than failing the record: a
    /// device that got one element wrong is still a device, and `raw` keeps the offending text.
    init(elements: [String: String],
         observedFrom: IPv4Address,
         receivedAt: Date,
         payloadEncoding: SADPPayloadEncoding = .utf8,
         isRecoveredFromMalformedXML: Bool = false) {
        self.uuid = Self.nonEmpty(elements["uuid"])
        self.deviceType = Self.integer(elements["devicetype"])
        self.deviceDescription = Self.nonEmpty(elements["devicedescription"])
        self.deviceSN = Self.nonEmpty(elements["devicesn"])
        self.commandPort = Self.port(elements["commandport"])
        self.httpPort = Self.port(elements["httpport"])
        self.httpsPort = Self.port(elements["httpsport"])
        self.rtspPort = Self.port(elements["rtspport"])
        self.mac = Self.nonEmpty(elements["mac"]).flatMap(MACAddress.init)
        self.ipv4Address = Self.address(elements["ipv4address"])
        self.ipv4SubnetMask = Self.address(elements["ipv4subnetmask"])
        self.ipv4Gateway = Self.address(elements["ipv4gateway"])
        self.ipv6Address = Self.ipv6(elements["ipv6address"])
        self.dhcp = Self.boolean(elements["dhcp"])
        self.softwareVersion = Self.nonEmpty(elements["softwareversion"])
        self.dspVersion = Self.nonEmpty(elements["dspversion"])
        self.bootTimeLocalString = Self.nonEmpty(elements["boottime"])
        self.activated = Self.boolean(elements["activated"])
        self.passwordResetAbility = Self.boolean(elements["passwordresetability"])
        self.supportHCPlatform = Self.boolean(elements["supporthcplatform"])
        self.analogChannelNum = Self.integer(elements["analogchannelnum"])
        self.digitalChannelNum = Self.integer(elements["digitalchannelnum"])
        self.diskNumber = Self.integer(elements["disknumber"])
        self.oemInfo = Self.nonEmpty(elements["oeminfo"])
        self.deviceLock = Self.boolean(elements["devicelock"])
        self.raw = elements
        self.observedFrom = observedFrom
        self.receivedAt = receivedAt
        self.payloadEncoding = payloadEncoding
        self.isRecoveredFromMalformedXML = isRecoveredFromMalformedXML
    }

    // MARK: Derived

    /// The model extracted from `DeviceSN`, e.g. `DS-2CD2143G0-I`, or `nil` when the serial carries
    /// no recognisable manufacturing date to split on (§4.5.3).
    public var model: String? {
        guard let deviceSN else { return nil }
        return SADPCodec.splitSerial(deviceSN).model
    }

    /// Activation as the state the UI renders. `nil` in the datagram means the firmware predates the
    /// element, which is `.unknown` — never `.activated`, because guessing "fine" here would hide
    /// the one condition the user must act on.
    public var activationState: ActivationState {
        switch activated {
        case .some(true): .activated
        case .some(false): .notActivated
        case .none: .unknown
        }
    }

    /// The vendor this datagram implies. Only Hikvision-family devices answer on port 37020 at all;
    /// a non-empty `OEMinfo` means a rebrand, which keeps ISAPI but not the branding.
    public var vendor: DeviceVendor {
        if let oemInfo, !oemInfo.isEmpty { return .hikvisionOEM }
        return .hikvision
    }

    /// The device class, by the §4.3 precedence: `DeviceDescription` text, then channel counts, then
    /// disk count, then the opaque `DeviceType` integer.
    public var deviceClass: DeviceClass {
        if let described = Self.classFromDescription(deviceDescription) { return described }
        if let digital = digitalChannelNum, digital > 0 { return .nvr }
        if let analog = analogChannelNum, analog > 0 { return .dvr }
        if let disks = diskNumber, disks > 0 { return .nvr }
        switch deviceType {
        case .some(0): return .camera
        case .some(1): return .dvr
        case .some(2): return .nvr
        case .some(3): return .encoder
        default: return .unknown
        }
    }

    /// `SoftwareVersion` with the missing space restored: `V5.5.82build 190910` becomes
    /// `V5.5.82 build 190910`. Returns the original text when there is nothing to fix.
    public var normalizedFirmwareVersion: String? {
        guard let softwareVersion else { return nil }
        guard let range = softwareVersion.range(of: "build"), range.lowerBound != softwareVersion.startIndex
        else { return softwareVersion }
        let before = softwareVersion[softwareVersion.index(before: range.lowerBound)]
        guard before != " " else { return softwareVersion }
        return softwareVersion.replacingCharacters(in: range.lowerBound..<range.lowerBound, with: " ")
    }

    /// `BootTime` interpreted in an **explicitly supplied** zone.
    ///
    /// The device sends wall-clock digits with no zone, so there is no correct answer — only a
    /// chosen one. The pure layer refuses to read `TimeZone.current` itself (that would make the
    /// result depend on the machine running the tests); callers pass the zone they will render in
    /// and must present the result as approximate, "about 7 days", never to the second (§4.5.4).
    ///
    /// - Returns: `nil` when the string is absent or is not `yyyy-MM-dd HH:mm:ss` with in-range
    ///   components.
    public func bootTime(in timeZone: TimeZone) -> Date? {
        guard let text = bootTimeLocalString else { return nil }
        let digits = Array(text.utf8)
        guard digits.count >= 19 else { return nil }
        func number(_ start: Int, _ count: Int) -> Int? {
            var value = 0
            for offset in start..<(start + count) {
                let byte = digits[offset]
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        guard digits[4] == UInt8(ascii: "-"), digits[7] == UInt8(ascii: "-"),
              digits[13] == UInt8(ascii: ":"), digits[16] == UInt8(ascii: ":"),
              let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
              (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second < 61 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components)
    }

    // MARK: Element value parsing

    /// Maps a `DeviceDescription` string to a class. Matched case-insensitively on substrings
    /// because firmware writes `IPCamera`, `IP Camera`, `IP Dome` and `Network Video Recorder`.
    private static func classFromDescription(_ text: String?) -> DeviceClass? {
        guard let text, !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.contains("nvr") || lower.contains("network video recorder") { return .nvr }
        if lower.contains("dvr") || lower.contains("digital video recorder") { return .dvr }
        if lower.contains("decoder") { return .decoder }
        if lower.contains("encoder") { return .encoder }
        if lower.contains("doorbell") || lower.contains("door station")
            || lower.contains("video intercom") { return .doorbell }
        if lower.contains("access control") { return .accessControl }
        if lower.contains("camera") || lower.contains("ipc") || lower.contains("dome")
            || lower.contains("bullet") { return .camera }
        return nil
    }

    /// Trims and drops the empty string, so `<OEMinfo></OEMinfo>` reads as "absent" rather than "".
    static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = LenientXMLScanner.trimmingASCIIWhitespace(text)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Parses `true`/`false`/`1`/`0`/`yes`/`no`, case-insensitively (§4.3). Anything else is `nil`.
    static func boolean(_ text: String?) -> Bool? {
        switch nonEmpty(text)?.lowercased() {
        case "true", "1", "yes": true
        case "false", "0", "no": false
        default: nil
        }
    }

    /// Parses a decimal integer. Rejects anything with a stray character, so `8 ports` is `nil`.
    static func integer(_ text: String?) -> Int? {
        guard let text = nonEmpty(text) else { return nil }
        return Int(text)
    }

    /// Parses a TCP/UDP port. Rejects 0 and anything above 65 535 — a device claiming port 0 is
    /// telling us the service is off, not where to connect.
    static func port(_ text: String?) -> UInt16? {
        guard let value = integer(text), value > 0, value <= Int(UInt16.max) else { return nil }
        return UInt16(value)
    }

    /// Parses a dotted quad, mapping `0.0.0.0` to `nil`.
    static func address(_ text: String?) -> IPv4Address? {
        guard let text = nonEmpty(text), let address = IPv4Address(text),
              !address.isUnspecified else { return nil }
        return address
    }

    /// Keeps an IPv6 literal for display, dropping the unspecified address `::`.
    static func ipv6(_ text: String?) -> String? {
        guard let text = nonEmpty(text), text != "::", text != "0:0:0:0:0:0:0:0" else { return nil }
        return text
    }
}
