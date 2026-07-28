//
//  DeviceIdentity.swift
//  VigilISAPI
//
//  Who the device is and how it is doing: `/System/deviceInfo`, `/Security/userCheck`,
//  `/System/status`, `/System/time`, `/System/Network/interfaces` and `/Security/users`.
//  Implements docs/spec-isapi.md §10.1–§10.6 and §17.4.
//
//  This is the "interrogate a stranger" half of the module. Everything here must survive a device
//  that answers with a subset of the elements the spec lists, because that is the normal case
//  across nine years of Hikvision firmware — so only the fields Vigil genuinely cannot work
//  without are required, and every one of those names itself in the thrown error.
//

import Foundation
import VigilProtocols

// MARK: - DeviceFamily

/// What kind of box answered. Drives channel enumeration, whether playback is offered at all, and
/// the conservative defaults in `DeviceCapabilitiesWire`.
public enum DeviceFamily: String, Sendable, Hashable, Codable, CaseIterable {
    case ipCamera, nvr, dvr, hybridDVR, encoder, decoder, doorbell, unknown

    /// True for the recorder families, which are the ones with proxied channels and storage.
    public var isRecorder: Bool { self == .nvr || self == .dvr || self == .hybridDVR }

    /// Derives the family from `deviceType` and `model`, first match winning, exactly in the order
    /// of docs/spec-isapi.md §10.1.
    ///
    /// `.unknown` is returned rather than guessed at, and is treated as `.ipCamera` for behaviour;
    /// the distinction is kept so diagnostics can say the device did not identify itself.
    public static func infer(deviceType: String, model: String) -> DeviceFamily {
        let type = deviceType.lowercased()
        let modelUpper = model.uppercased()
        if type.contains("nvr") { return .nvr }
        if type.contains("hybrid") { return .hybridDVR }
        if type.contains("dvr") { return .dvr }
        for prefix in ["DS-76", "DS-77", "DS-78", "DS-96", "DS-KH"] where modelUpper.hasPrefix(prefix) {
            return .nvr
        }
        for prefix in ["DS-KV", "DS-KD"] where modelUpper.hasPrefix(prefix) {
            return .doorbell
        }
        if type.contains("ipcamera") || type.contains("ipdome") || type.contains("ipzoom") {
            return .ipCamera
        }
        if type.contains("encoder") { return .encoder }
        if type.contains("decoder") { return .decoder }
        return .unknown
    }
}

// MARK: - FirmwareVersion

/// A comparable Hikvision firmware version.
///
/// Accepts `V5.6.3`, `V5.5.82 build 190220`, `V4.30.005` and a bare `5.6`. Missing components read
/// as zero, so `V5.6` sorts below `V5.6.3`. The raw string is retained because the capability
/// cache is keyed on it and because a version Vigil failed to parse must still appear in
/// diagnostics verbatim.
public struct FirmwareVersion: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// The `build NNNNNN` suffix, when present.
    public let build: Int?
    /// The unparsed string, exactly as the device sent it.
    public let raw: String

    public init(major: Int, minor: Int, patch: Int, build: Int?, raw: String) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.build = build
        self.raw = raw
    }

    /// Parses a firmware string. Never fails: an unrecognisable string becomes `0.0.0` with the
    /// original text in `raw`, because refusing to represent a device's firmware would lose the
    /// only clue a support ticket has.
    public init(parsing raw: String) {
        self.raw = raw
        // Split at the `build` keyword first. Without that split, `V5.6 build 190923` would read
        // the build number as the patch component and sort above every 5.6.x release.
        var versionText = Substring(raw)
        var build: Int?
        if let keyword = raw.range(of: "build", options: [.caseInsensitive]) {
            versionText = raw[raw.startIndex..<keyword.lowerBound]
            let tail = raw[keyword.upperBound...]
            build = Int(tail.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber }))
        }
        var numbers: [Int] = []
        for token in versionText.split(whereSeparator: { !$0.isNumber && $0 != "." }) {
            for component in token.split(separator: ".") {
                guard let value = Int(component) else { continue }
                if numbers.count < 3 { numbers.append(value) } else if build == nil { build = value }
            }
        }
        major = numbers.count > 0 ? numbers[0] : 0
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0
        self.build = build
    }

    public var description: String { raw }

    public static func < (l: Self, r: Self) -> Bool {
        if l.major != r.major { return l.major < r.major }
        if l.minor != r.minor { return l.minor < r.minor }
        if l.patch != r.patch { return l.patch < r.patch }
        return (l.build ?? 0) < (r.build ?? 0)
    }
}

// MARK: - DeviceInfo

/// `GET /ISAPI/System/deviceInfo`. Cache TTL 24 h, invalidated on reboot or credential change.
public struct DeviceInfo: Sendable, Hashable, Codable {
    public let deviceName: String
    public let deviceID: String?
    public let model: String
    /// Redact in logs: a serial number identifies a customer's camera.
    public let serialNumber: String
    public let macAddress: String?
    public let firmwareVersion: FirmwareVersion
    public let firmwareReleasedDate: String?
    public let hardwareVersion: String?
    /// The device's own `deviceType` text, kept raw for diagnostics.
    public let deviceType: String
    /// Derived from `deviceType` and `model`.
    public let family: DeviceFamily
    public let supportsBeep: Bool
    public let supportsVideoLoss: Bool

    public init(deviceName: String, deviceID: String?, model: String, serialNumber: String,
                macAddress: String?, firmwareVersion: FirmwareVersion,
                firmwareReleasedDate: String?, hardwareVersion: String?, deviceType: String,
                family: DeviceFamily, supportsBeep: Bool, supportsVideoLoss: Bool) {
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.model = model
        self.serialNumber = serialNumber
        self.macAddress = macAddress
        self.firmwareVersion = firmwareVersion
        self.firmwareReleasedDate = firmwareReleasedDate
        self.hardwareVersion = hardwareVersion
        self.deviceType = deviceType
        self.family = family
        self.supportsBeep = supportsBeep
        self.supportsVideoLoss = supportsVideoLoss
    }

    /// Decodes a `<DeviceInfo>` document.
    ///
    /// `model` is the only hard requirement — without it Vigil cannot match a quirk row or show a
    /// useful camera name — so a document missing it throws `.malformedResponse`. Everything else
    /// degrades: a missing `deviceName` falls back to the model, a missing serial to the empty
    /// string, and an unparsable firmware string to `0.0.0` with the raw text preserved.
    public init(document: ISAPIDocument) throws(ISAPIError) {
        let context = "DeviceInfo"
        let model = try document["model|modelName"].requireString(context)
        let deviceType = document["deviceType"].string ?? ""
        self.init(
            deviceName: document["deviceName"].string ?? model,
            deviceID: document["deviceID"].string,
            model: model,
            serialNumber: document["serialNumber"].string ?? "",
            macAddress: document["macAddress"].string,
            firmwareVersion: FirmwareVersion(parsing: document["firmwareVersion"].string ?? ""),
            firmwareReleasedDate: document["firmwareReleasedDate"].string,
            hardwareVersion: document["hardwareVersion"].string,
            deviceType: deviceType,
            family: DeviceFamily.infer(deviceType: deviceType, model: model),
            supportsBeep: document["supportBeep"].bool ?? false,
            supportsVideoLoss: document["supportVideoLoss"].bool ?? false)
    }
}

// MARK: - UserCheckResult

/// `GET /ISAPI/Security/userCheck`. The cheapest authenticated call and the only one that reports
/// lock-out state, which is why it is the liveness probe and the credential probe both.
public struct UserCheckResult: Sendable, Hashable, Codable {
    /// True when the credential was accepted.
    public let ok: Bool
    /// Attempts **remaining** before the device locks the account, when it reports them.
    public let remainingAttempts: Int?
    public let isLocked: Bool
    /// Seconds of lock remaining. The device default lock is 1800 s.
    public let unlockAfter: Double?
    /// True when the device has never been activated and has no admin password yet.
    public let notActivated: Bool

    public init(ok: Bool, remainingAttempts: Int?, isLocked: Bool,
                unlockAfter: Double?, notActivated: Bool) {
        self.ok = ok
        self.remainingAttempts = remainingAttempts
        self.isLocked = isLocked
        self.unlockAfter = unlockAfter
        self.notActivated = notActivated
    }

    /// Vigil must never be the reason a customer's camera locks out, so one remaining attempt is
    /// already too few: at this point the client stops sending credentials for this device until
    /// `VigilCore` supplies a different one (docs/spec-isapi.md §10.2).
    public var shouldBlockFurtherAttempts: Bool {
        isLocked || (remainingAttempts.map { $0 <= 1 } ?? false)
    }

    /// Decodes `<userCheck>`, and also the `<ResponseStatus>` some 5.4.x devices answer with.
    ///
    /// `httpStatus` disambiguates the firmwares that return HTTP 200 with a `statusValue` of 401
    /// from those that set the HTTP status properly; the credential is treated as good only when
    /// both agree.
    public init(document: ISAPIDocument, httpStatus: Int) {
        let statusValue = document["statusValue"].int
        let subStatus = (document["subStatusCode"].string ?? "").lowercased()
        let statusCode = document["statusCode"].int
        let notActivated = subStatus == "notactivated"
        let lockText = (document["lockStatus"].string ?? "").lowercased()
        let illegal = document["isIllegalLogin"].bool ?? false
        let httpOK = (200...299).contains(httpStatus)
        // `statusValue` mirrors an HTTP status; `statusCode` is the ResponseStatus vocabulary
        // where 1 is success. Absent both, fall back to the HTTP status alone.
        let bodySaysOK: Bool
        if let statusValue { bodySaysOK = statusValue == 200 }
        else if let statusCode { bodySaysOK = statusCode == 1 }
        else { bodySaysOK = true }
        self.init(ok: httpOK && bodySaysOK && !illegal && !notActivated,
                  remainingAttempts: document["retryLoginTime"].int,
                  isLocked: lockText == "lock" || lockText == "locked",
                  unlockAfter: document["unlockTime"].int.map(Double.init),
                  notActivated: notActivated)
    }
}

// MARK: - DeviceStatus

/// `GET /ISAPI/System/status`. Cache TTL 5 s; this is the health poll.
public struct DeviceStatus: Sendable, Hashable, Codable {
    public let currentDeviceTime: Date?
    /// Seconds since boot. A decrease between two polls is Vigil's reboot detector.
    public let uptime: Double
    /// `ok`, `badStatus`, … kept raw.
    public let status: String
    /// Percent, one entry per reported CPU.
    public let cpuUtilization: [Int]
    public let memoryUsedMB: Double?
    public let memoryAvailableMB: Double?
    public let temperaturesCelsius: [Double]
    public let openFileHandles: Int?

    public init(currentDeviceTime: Date?, uptime: Double, status: String, cpuUtilization: [Int],
                memoryUsedMB: Double?, memoryAvailableMB: Double?,
                temperaturesCelsius: [Double], openFileHandles: Int?) {
        self.currentDeviceTime = currentDeviceTime
        self.uptime = uptime
        self.status = status
        self.cpuUtilization = cpuUtilization
        self.memoryUsedMB = memoryUsedMB
        self.memoryAvailableMB = memoryAvailableMB
        self.temperaturesCelsius = temperaturesCelsius
        self.openFileHandles = openFileHandles
    }

    /// Decodes `<DeviceStatus>`. Nothing is required: a device that answers this endpoint at all
    /// is alive, which is most of what the health poll wanted to know.
    public init(document: ISAPIDocument) {
        let cpus = document.nodes("CPUList/CPU[]").compactMap { $0["cpuUtilization"].int }
        let memory = document.node("MemoryList/Memory")
        let temperatures = document.nodes("TemperatureList/Temperature[]")
            .compactMap { $0["temperature"].double }
        self.init(currentDeviceTime: document["currentDeviceTime"].date,
                  uptime: document["deviceUpTime"].double ?? 0,
                  status: document["deviceStatus"].string ?? "unknown",
                  cpuUtilization: cpus,
                  memoryUsedMB: memory?["memoryUsage"].double,
                  memoryAvailableMB: memory?["memoryAvailable"].double,
                  temperaturesCelsius: temperatures,
                  openFileHandles: document["openFileHandles"].int)
    }

    /// True when `previous` reports a longer uptime than this reading — the device rebooted, and
    /// every cache for it must be flushed.
    public func indicatesRebootSince(_ previous: DeviceStatus) -> Bool {
        uptime < previous.uptime
    }
}

// MARK: - DeviceTime

/// `GET /ISAPI/System/time`. Cache TTL 5 min. Vigil never writes device time.
public struct DeviceTime: Sendable, Hashable, Codable {
    /// `NTP` or `manual`.
    public let mode: String
    public let localTime: Date
    /// Seconds east of UTC, after undoing Hikvision's POSIX sign inversion.
    public let utcOffsetSeconds: Int
    /// The device's own zone string, e.g. `CST-8:00:00`.
    public let rawTimeZone: String

    public init(mode: String, localTime: Date, utcOffsetSeconds: Int, rawTimeZone: String) {
        self.mode = mode
        self.localTime = localTime
        self.utcOffsetSeconds = utcOffsetSeconds
        self.rawTimeZone = rawTimeZone
    }

    /// Decodes `<Time>`. `localTime` is required — without it there is no clock to compare and the
    /// caller would silently show a skew of zero.
    public init(document: ISAPIDocument) throws(ISAPIError) {
        let raw = document["timeZone"].string ?? ""
        self.init(mode: document["timeMode"].string ?? "unknown",
                  localTime: try document["localTime"].requireDate("DeviceTime"),
                  utcOffsetSeconds: ISAPITime.parseTimeZone(raw) ?? 0,
                  rawTimeZone: raw)
    }

    /// Signed seconds by which the device's clock leads `reference`.
    ///
    /// Beyond ±60 s the UI warns, because playback search and event timestamps will look wrong in
    /// a way the user would otherwise blame on Vigil.
    public func skew(against reference: Date) -> Double {
        localTime.timeIntervalSince(reference)
    }

    /// Whether this device stamps **local** wall-clock time with a UTC marker.
    ///
    /// This is the detector for `DeviceQuirks.playbackTimesAreDeviceLocal`, and the reason it can
    /// live here rather than in the RTSP layer. spec-isapi.md §15.3 proposes comparing the `Range`
    /// echo after `PLAY`, which needs a signal carried from `VigilRTSP` back into this actor
    /// through two modules. `/System/time` answers the same question in one request, on the
    /// connect path, before any playback is attempted:
    ///
    /// A device whose date formatter writes local time and appends `Z` — which is exactly the
    /// defect that makes `starttime=…Z` mean device-local — gives itself away here. Parsed as UTC,
    /// its `localTime` runs **ahead of real UTC by its own declared offset**. A device that
    /// formats correctly (either a real `Z` in UTC, or an explicit `+03:00`) parses to the true
    /// instant and shows no such gap.
    ///
    /// ⚠️ **Not the same as a wrong clock**, and the discriminator is that the gap matches
    /// ``utcOffsetSeconds`` almost exactly. A camera whose clock is genuinely three hours fast in a
    /// UTC+3 zone is indistinguishable from this and will be treated as quirky — which is the safe
    /// way round: on such a device every archive time is off by the offset either way, and this
    /// makes the timeline agree with the footage rather than with the wrong clock.
    ///
    /// ⛔ Returns `false` for a device in UTC. There, local and UTC are the same and there is
    /// nothing to detect, nothing to correct, and no way to tell the two apart.
    ///
    /// - Parameters:
    ///   - reference: real "now", from a trusted clock.
    ///   - toleranceSeconds: how far from the declared offset still counts as a match. Generous
    ///     because a camera's clock drifts and NTP may be off; the alternative reading is hours
    ///     away, so a wide window costs nothing.
    /// - Returns: whether local times from this device arrive labelled as UTC.
    public func stampsLocalTimeAsUTC(reference: Date, toleranceSeconds: Double = 300) -> Bool {
        guard utcOffsetSeconds != 0 else { return false }
        return abs(skew(against: reference) - Double(utcOffsetSeconds)) <= toleranceSeconds
    }
}

// MARK: - NetworkInterfaceWire

/// One entry of `<NetworkInterfaceList>`. Read-only: Vigil never writes network configuration.
public struct NetworkInterfaceWire: Sendable, Hashable, Codable {
    public let id: Int
    /// `static` or `dynamic`.
    public let addressingType: String
    public let ipv4: String?
    public let subnetMask: String?
    public let ipv6: [String]
    public let gateway: String?
    public let dns: [String]
    public let macAddress: String?
    /// 10, 100 or 1000. A 10 Mbit half-duplex link explains a stuttering 4K stream better than
    /// any other single diagnostic.
    public let linkSpeedMbps: Int?
    public let duplex: String?
    public let mtu: Int?

    public init(id: Int, addressingType: String, ipv4: String?, subnetMask: String?,
                ipv6: [String], gateway: String?, dns: [String], macAddress: String?,
                linkSpeedMbps: Int?, duplex: String?, mtu: Int?) {
        self.id = id
        self.addressingType = addressingType
        self.ipv4 = ipv4
        self.subnetMask = subnetMask
        self.ipv6 = ipv6
        self.gateway = gateway
        self.dns = dns
        self.macAddress = macAddress
        self.linkSpeedMbps = linkSpeedMbps
        self.duplex = duplex
        self.mtu = mtu
    }

    /// Decodes one `<NetworkInterface>` element.
    public init(node: XMLNode) {
        let address = node.node("IPAddress")
        let unspecifiedV6 = ["::", "0000:0000:0000:0000:0000:0000:0000:0000"]
        let v6 = [address?["ipv6Address"].string]
            .compactMap { $0 }
            .filter { !unspecifiedV6.contains($0) }
        let dns = [address?["PrimaryDNS/ipAddress"].string,
                   address?["SecondaryDNS/ipAddress"].string].compactMap { $0 }
        let link = node.node("Link")
        self.init(id: node["id"].int ?? 0,
                  addressingType: address?["addressingType"].string ?? "unknown",
                  ipv4: address?["ipAddress"].string,
                  subnetMask: address?["subnetMask"].string,
                  ipv6: v6,
                  gateway: address?["DefaultGateway/ipAddress"].string,
                  dns: dns,
                  macAddress: link?["MACAddress"].string,
                  linkSpeedMbps: link?["speed"].int,
                  duplex: link?["duplex"].string,
                  mtu: link?["MTU"].int)
    }

    /// Decodes every interface in a `<NetworkInterfaceList>` document.
    public static func list(document: ISAPIDocument) -> [NetworkInterfaceWire] {
        document.nodes("NetworkInterface[]").map(NetworkInterfaceWire.init(node:))
    }
}

// MARK: - DeviceUser

/// One entry of `<UserList>`. Vigil reads users for exactly one purpose: to explain an
/// `insufficientPermission` failure. It never creates, deletes or modifies device users.
public struct DeviceUser: Sendable, Hashable, Codable, Identifiable {

    /// The three levels Hikvision defines, plus a passthrough for anything newer.
    public enum Level: Sendable, Hashable, Codable {
        case administrator, operatorLevel, viewer, other(String)

        /// Matches case-insensitively; an unknown level is preserved rather than downgraded,
        /// because guessing "viewer" would produce a wrong diagnostic message.
        public init(raw: String) {
            switch raw.lowercased() {
            case "administrator", "admin": self = .administrator
            case "operator": self = .operatorLevel
            case "viewer", "user": self = .viewer
            default: self = .other(raw)
            }
        }

        /// The device's own spelling, for the diagnostics string.
        public var displayName: String {
            switch self {
            case .administrator: "Administrator"
            case .operatorLevel: "Operator"
            case .viewer: "Viewer"
            case .other(let raw): raw
            }
        }
    }

    public let id: Int
    public let userName: String
    public let level: Level

    public init(id: Int, userName: String, level: Level) {
        self.id = id
        self.userName = userName
        self.level = level
    }

    /// Decodes every `<User>` in a `<UserList>` document. Entries without a name are skipped:
    /// they carry no diagnostic value and have been seen on partially-initialised devices.
    public static func list(document: ISAPIDocument) -> [DeviceUser] {
        document.nodes("User[]").compactMap { node in
            guard let name = node["userName"].string else { return nil }
            return DeviceUser(id: node["id"].int ?? 0,
                              userName: name,
                              level: Level(raw: node["userLevel"].string ?? ""))
        }
    }
}
