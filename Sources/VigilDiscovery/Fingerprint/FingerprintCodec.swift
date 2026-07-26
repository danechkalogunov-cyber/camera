//
//  FingerprintCodec.swift
//  VigilDiscovery
//
//  The two credential-free fingerprints — RTSP `OPTIONS` and HTTP `GET /ISAPI/System/deviceInfo` —
//  as bytes to send and as classifications of what came back.
//  Implements docs/spec-discovery.md §6.6 and §6.7. No request built here ever carries an
//  `Authorization` header: Hikvision locks an account after a handful of failed attempts (§6.10).
//

import Foundation
import VigilProtocols

// MARK: - Results

/// What an RTSP `OPTIONS` exchange revealed.
public struct RTSPFingerprint: Sendable, Hashable {

    /// True when the first token was `RTSP/…`. False means port 554 is something else entirely.
    public let isRTSP: Bool
    public let statusCode: Int?
    /// The `WWW-Authenticate` realm. On Hikvision this is the single best cheap fingerprint there
    /// is: `IP Camera(52799)` is unmistakable and costs one round trip.
    public let realm: String?
    /// The methods from a `Public:` header, uppercased, in order.
    public let publicMethods: [String]
    public let serverHeader: String?
    /// The MAC embedded in an `AXIS_<12 hex>` realm. A hint: never an identity.
    public let macHint: MACAddress?
    /// The vendor this response alone implies.
    public let vendor: DeviceVendor

    public init(isRTSP: Bool, statusCode: Int? = nil, realm: String? = nil,
                publicMethods: [String] = [], serverHeader: String? = nil,
                macHint: MACAddress? = nil, vendor: DeviceVendor = .unknown) {
        self.isRTSP = isRTSP
        self.statusCode = statusCode
        self.realm = realm
        self.publicMethods = publicMethods
        self.serverHeader = serverHeader
        self.macHint = macHint
        self.vendor = vendor
    }

    /// The response of a host where nothing RTSP-shaped answered.
    public static let notRTSP = RTSPFingerprint(isRTSP: false)
}

/// What an HTTP fingerprint revealed.
public struct HTTPFingerprint: Sendable, Hashable {

    public let statusCode: Int?
    public let serverHeader: String?
    public let realm: String?
    /// True when `/ISAPI/…` exists on this device: a 401, 403 or 200 answered it. A 404 means the
    /// path is absent, which is the clearest evidence there is that a device is **not** in the
    /// Hikvision family.
    public let isapiPathPresent: Bool
    /// True when a 403 body carried `notActivated`: the device has no password yet.
    public let notActivated: Bool
    /// Metadata from a 200 body that carried `<DeviceInfo>` — rare, but free when it happens.
    public let inlineDeviceInfo: InlineDeviceInfo?
    public let vendor: DeviceVendor

    public init(statusCode: Int? = nil, serverHeader: String? = nil, realm: String? = nil,
                isapiPathPresent: Bool = false, notActivated: Bool = false,
                inlineDeviceInfo: InlineDeviceInfo? = nil, vendor: DeviceVendor = .unknown) {
        self.statusCode = statusCode
        self.serverHeader = serverHeader
        self.realm = realm
        self.isapiPathPresent = isapiPathPresent
        self.notActivated = notActivated
        self.inlineDeviceInfo = inlineDeviceInfo
        self.vendor = vendor
    }

    /// The handful of fields worth lifting out of an unauthenticated `<DeviceInfo>` body.
    public struct InlineDeviceInfo: Sendable, Hashable {
        public let model: String?
        public let serialNumber: String?
        public let macAddress: MACAddress?
        public let firmwareVersion: String?

        public init(model: String? = nil, serialNumber: String? = nil,
                    macAddress: MACAddress? = nil, firmwareVersion: String? = nil) {
            self.model = model
            self.serialNumber = serialNumber
            self.macAddress = macAddress
            self.firmwareVersion = firmwareVersion
        }

        /// True when nothing was extracted, so the caller can drop it rather than store an empty box.
        public var isEmpty: Bool {
            model == nil && serialNumber == nil && macAddress == nil && firmwareVersion == nil
        }
    }
}

// MARK: - FingerprintCodec

/// Builds the fingerprint requests and classifies the answers.
///
/// Everything is pure and total: a response of random bytes classifies as "not RTSP" or "unknown
/// vendor" rather than throwing, because the input is an unknown device on someone's LAN.
public enum FingerprintCodec {

    /// The User-Agent every discovery request carries. Naming ourselves is the polite half of not
    /// sending credentials: an administrator reading a device log can see exactly who probed it.
    public static let userAgent = "Vigil/1.0 (macOS; discovery)"

    /// The bytes of `OPTIONS rtsp://host:port/ RTSP/1.0` with `CSeq: 1`. No `Authorization`, ever.
    public static func rtspOptionsRequest(host: IPv4Address, port: UInt16 = 554) -> Data {
        let request = "OPTIONS rtsp://\(host):\(port)/ RTSP/1.0\r\n"
            + "CSeq: 1\r\n"
            + "User-Agent: \(userAgent)\r\n"
            + "\r\n"
        return Data(request.utf8)
    }

    /// The bytes of `GET /ISAPI/System/deviceInfo HTTP/1.1`. This is *the* Hikvision test: a 401
    /// from this path with a Hik `Server` header is the highest-value signal in discovery.
    public static func isapiDeviceInfoRequest(host: IPv4Address) -> Data {
        httpGET(path: "/ISAPI/System/deviceInfo", host: host, accept: "application/xml")
    }

    /// The bytes of `GET /`, the one follow-up request we allow when the ISAPI path was
    /// inconclusive. Three short requests per host is the hard ceiling (§6.10).
    public static func rootRequest(host: IPv4Address) -> Data {
        httpGET(path: "/", host: host, accept: "*/*")
    }

    private static func httpGET(path: String, host: IPv4Address, accept: String) -> Data {
        let request = "GET \(path) HTTP/1.1\r\n"
            + "Host: \(host)\r\n"
            + "User-Agent: \(userAgent)\r\n"
            + "Accept: \(accept)\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        return Data(request.utf8)
    }

    // MARK: RTSP

    /// Classifies an RTSP `OPTIONS` response.
    ///
    /// A first token that does not start with `RTSP/` means the port is not RTSP at all and the
    /// result is `.notRTSP` — worth knowing, since plenty of things listen on 554. Otherwise the
    /// realm decides the vendor, and any status at all (200, 401, even 500) proves an RTSP server.
    public static func classifyRTSP(_ response: Data) -> RTSPFingerprint {
        guard let scan = StartLineHeaderScanner.scan(response) else { return .notRTSP }
        guard scan.protocolToken.uppercased().hasPrefix("RTSP/") else { return .notRTSP }

        let challenge = scan.header("www-authenticate").flatMap(StartLineHeaderScanner.authChallenge)
        let realm = challenge?.params["realm"]
        let methods = (scan.header("public") ?? "")
            .split(separator: ",")
            .map { $0.trimmedASCII().uppercased() }
            .filter { !$0.isEmpty }
        let vendorFromRealm = realm.map(vendorForRealm) ?? .unknown
        let server = scan.header("server")
        let vendorFromServer = server.map(vendorForServerHeader) ?? .unknown
        let vendor = vendorFromRealm.isSpecific ? vendorFromRealm
            : (vendorFromServer.isSpecific ? vendorFromServer : .genericRTSP)

        return RTSPFingerprint(isRTSP: true, statusCode: scan.statusCode, realm: realm,
                               publicMethods: methods, serverHeader: server,
                               macHint: realm.flatMap(macFromAxisRealm), vendor: vendor)
    }

    /// Maps an authentication realm to a vendor (§6.6). Matching is case-insensitive and anchored,
    /// so `IP Camera(52799)` matches but a realm that merely mentions a camera does not.
    public static func vendorForRealm(_ realm: String) -> DeviceVendor {
        let trimmed = realm.trimmedASCII()
        let upper = trimmed.uppercased()
        if upper.hasPrefix("IP CAMERA(") { return .hikvision }
        if upper.contains("HIKVISION") { return .hikvision }
        if upper.hasPrefix("DS-"), trimmed.count > 3 { return .hikvision }
        if upper.hasPrefix("AXIS_") { return .axis }
        if upper.contains("REOLINK") { return .reolink }
        if upper == "IPC" || upper.hasPrefix("LOGIN TO ") { return .dahua }
        if upper.contains("DAHUA") { return .dahua }
        return .unknown
    }

    /// Maps an HTTP/RTSP `Server` header to a vendor. Hikvision's own web stacks are unmistakable;
    /// `Boa/0.94` and `DahuaRtsp` are Dahua's.
    public static func vendorForServerHeader(_ server: String) -> DeviceVendor {
        let upper = server.uppercased()
        for token in ["APP-WEBS", "DVRDVS-WEBS", "DNVRS-WEBS", "HIKVISION-WEBS", "HIKVISION"]
        where upper.contains(token) {
            return .hikvision
        }
        if upper.contains("DAHUARTSP") || upper.contains("BOA/0.9") || upper.contains("DAHUA") {
            return .dahua
        }
        if upper.contains("AXIS") { return .axis }
        return .unknown
    }

    /// Extracts the MAC from an `AXIS_ACCC8E123456` realm. Axis puts the device's MAC in its realm;
    /// it is a genuine MAC but arrives as a **hint** because a realm is trivially spoofable.
    public static func macFromAxisRealm(_ realm: String) -> MACAddress? {
        let trimmed = realm.trimmedASCII()
        guard trimmed.uppercased().hasPrefix("AXIS_") else { return nil }
        let hex = trimmed.dropFirst(5)
        guard hex.count == 12, hex.allSatisfy(\.isHexDigit) else { return nil }
        var text = ""
        for (offset, character) in hex.enumerated() {
            if offset > 0, offset % 2 == 0 { text.append(":") }
            text.append(character)
        }
        return MACAddress(text)
    }

    // MARK: HTTP

    /// Classifies an HTTP fingerprint response.
    ///
    /// - Parameters:
    ///   - response: the bytes read, capped by the caller at 4 096.
    ///   - isISAPIPath: whether the request went to `/ISAPI/…`. The `/` follow-up must not be able
    ///     to claim `isapiPathPresent`, or a device with a login page would look like a Hikvision.
    ///
    /// A `404` or `400` clears `isapiPathPresent` and leaves the vendor `.unknown`: that is the
    /// evidence for "found, but not Hikvision", and stating it is far kinder than a failed
    /// connection ten minutes later. A malformed or empty response is inconclusive and never
    /// downgrades a vendor.
    public static func classifyHTTP(_ response: Data, isISAPIPath: Bool = true) -> HTTPFingerprint {
        guard let scan = StartLineHeaderScanner.scan(response) else { return HTTPFingerprint() }
        let server = scan.header("server")
        let challenge = scan.header("www-authenticate").flatMap(StartLineHeaderScanner.authChallenge)
        let realm = challenge?.params["realm"]
        let body = String(decoding: scan.bodyPrefix, as: UTF8.self)
        let status = scan.statusCode

        let serverVendor = server.map(vendorForServerHeader) ?? .unknown
        let realmVendor = realm.map(vendorForRealm) ?? .unknown
        var vendor = serverVendor.isSpecific ? serverVendor : realmVendor
        var pathPresent = false
        var notActivated = false
        var inline: HTTPFingerprint.InlineDeviceInfo?

        switch status {
        case 401:
            pathPresent = isISAPIPath
            if isISAPIPath, !vendor.isSpecific {
                // The ISAPI path exists and is protected, but nothing named the vendor. Every
                // Hikvision OEM keeps `/ISAPI/`, so this is the OEM signature.
                vendor = .hikvisionOEM
            }
        case 403:
            pathPresent = isISAPIPath
            if body.contains("notActivated") {
                notActivated = true
                if !vendor.isSpecific { vendor = .hikvision }
            }
        case 200:
            if isISAPIPath, body.contains("<DeviceInfo") {
                pathPresent = true
                let parsed = parseInlineDeviceInfo(body)
                if !parsed.isEmpty { inline = parsed }
                if !vendor.isSpecific { vendor = .hikvision }
            }
        case 404, 400:
            pathPresent = false
        default:
            break
        }
        return HTTPFingerprint(statusCode: status, serverHeader: server, realm: realm,
                               isapiPathPresent: pathPresent, notActivated: notActivated,
                               inlineDeviceInfo: inline, vendor: vendor)
    }

    /// Pulls the four fields worth having out of an unauthenticated `<DeviceInfo>` body.
    ///
    /// Substring extraction, not XML parsing: this runs on at most 512 bytes of an untrusted body
    /// and full ISAPI decoding is `VigilISAPI`'s job once credentials exist. Missing or malformed
    /// elements simply yield `nil` fields.
    static func parseInlineDeviceInfo(_ body: String) -> HTTPFingerprint.InlineDeviceInfo {
        HTTPFingerprint.InlineDeviceInfo(
            model: element("model", in: body),
            serialNumber: element("serialNumber", in: body),
            macAddress: element("macAddress", in: body).flatMap { MACAddress($0) },
            firmwareVersion: element("firmwareVersion", in: body))
    }

    /// Returns the text between `<name>` and `</name>`, or `nil`. Namespace prefixes are tolerated
    /// by matching on the closing angle bracket rather than requiring an exact opening tag.
    static func element(_ name: String, in body: String) -> String? {
        guard let openRange = body.range(of: "<\(name)") else { return nil }
        guard let contentStart = body[openRange.upperBound...].firstIndex(of: ">") else { return nil }
        let afterOpen = body.index(after: contentStart)
        guard let closeRange = body.range(of: "</\(name)>", range: afterOpen..<body.endIndex) else {
            return nil
        }
        let text = String(body[afterOpen..<closeRange.lowerBound]).trimmedASCII()
        return text.isEmpty ? nil : text
    }
}
