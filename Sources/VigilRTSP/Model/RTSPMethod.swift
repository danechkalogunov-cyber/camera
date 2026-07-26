//
//  RTSPMethod.swift
//  VigilRTSP
//
//  The RTSP 1.0 method vocabulary and the status-code value type, including the thirty codes
//  RFC 2326 §7.1.1 defines and the handful Hikvision firmware actually returns.
//  Implements docs/spec-rtsp.md §2.1 and docs/API_CONTRACT.md §4.3.
//

// MARK: - Method

/// The eleven RTSP 1.0 methods. Vigil sends seven of them and receives the other four from
/// server-initiated requests (`ANNOUNCE`, `OPTIONS`, `REDIRECT`, `SET_PARAMETER`).
///
/// The raw value is the exact wire spelling; parsing a start line compares against it verbatim, so
/// a lowercase or mixed-case method from a broken device is *not* accepted — RFC 2326 §12 makes
/// methods case-sensitive and accepting `describe` would mask a genuinely corrupt stream.
public enum RTSPMethod: String, Sendable, Hashable, CaseIterable {
    case options       = "OPTIONS"
    case describe      = "DESCRIBE"
    case setup         = "SETUP"
    case play          = "PLAY"
    case pause         = "PAUSE"
    case teardown      = "TEARDOWN"
    case getParameter  = "GET_PARAMETER"
    case setParameter  = "SET_PARAMETER"
    case announce      = "ANNOUNCE"
    case record        = "RECORD"
    case redirect      = "REDIRECT"

    /// Methods that carry a `Session` header once a session exists.
    ///
    /// `SETUP` is excluded because the first `SETUP` establishes the session; the second and later
    /// `SETUP`s of an aggregate *do* carry it, which is the session machine's business, not the
    /// method's (docs/spec-rtsp.md §3.2 row 2).
    public var requiresSession: Bool {
        switch self {
        case .play, .pause, .teardown, .getParameter, .setParameter, .record: true
        case .options, .describe, .setup, .announce, .redirect: false
        }
    }

    /// Methods Vigil may send with a body. Everything else is serialised without one, and without
    /// a `Content-Length`.
    public var allowsRequestBody: Bool { self == .setParameter || self == .announce }
}

// MARK: - Status

/// An RTSP status code, kept as an open `Int` rather than an enum: firmware invents codes, and a
/// client that cannot represent `RTSP/1.0 466 Whatever` cannot log it either.
///
/// The classification properties follow RFC 2326 §7.1.1. `isSuccess` deliberately covers the whole
/// `2xx` range, so `250 Low on Storage Space` — which Hikvision NVRs send while recording to a
/// nearly full disk — is treated as the success it is.
public struct RTSPStatus: RawRepresentable, Hashable, Sendable, CustomStringConvertible {

    public let rawValue: Int

    /// Wraps any integer, including one no specification defines.
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// `2xx`.
    public var isSuccess: Bool { (200...299).contains(rawValue) }
    /// `301`, `302`, `303`. `305 Use Proxy` is not followed and is not counted here.
    public var isRedirect: Bool { rawValue == 301 || rawValue == 302 || rawValue == 303 }
    /// `4xx`.
    public var isClientError: Bool { (400...499).contains(rawValue) }
    /// `5xx`.
    public var isServerError: Bool { (500...599).contains(rawValue) }
    /// `401` or `407`: the two codes that carry an authentication challenge.
    public var isAuthenticationChallenge: Bool { rawValue == 401 || rawValue == 407 }

    /// The status and its canonical reason phrase, for logs: `401 Unauthorized`.
    public var description: String { "\(rawValue) \(canonicalReason)" }

    // MARK: Named codes

    public static let ok                      = RTSPStatus(rawValue: 200)
    public static let created                 = RTSPStatus(rawValue: 201)
    public static let lowOnStorage            = RTSPStatus(rawValue: 250)
    public static let movedPermanently        = RTSPStatus(rawValue: 301)
    public static let movedTemporarily        = RTSPStatus(rawValue: 302)
    public static let seeOther                = RTSPStatus(rawValue: 303)
    public static let badRequest              = RTSPStatus(rawValue: 400)
    public static let unauthorized            = RTSPStatus(rawValue: 401)
    public static let forbidden               = RTSPStatus(rawValue: 403)
    public static let notFound                = RTSPStatus(rawValue: 404)
    public static let methodNotAllowed        = RTSPStatus(rawValue: 405)
    public static let notAcceptable           = RTSPStatus(rawValue: 406)
    public static let proxyAuthRequired       = RTSPStatus(rawValue: 407)
    public static let requestTimeout          = RTSPStatus(rawValue: 408)
    public static let unsupportedMediaType    = RTSPStatus(rawValue: 415)
    public static let parameterNotUnderstood  = RTSPStatus(rawValue: 451)
    public static let conferenceNotFound      = RTSPStatus(rawValue: 452)
    public static let notEnoughBandwidth      = RTSPStatus(rawValue: 453)
    public static let sessionNotFound         = RTSPStatus(rawValue: 454)
    public static let methodNotValidInState   = RTSPStatus(rawValue: 455)
    public static let headerFieldNotValid     = RTSPStatus(rawValue: 456)
    public static let invalidRange            = RTSPStatus(rawValue: 457)
    public static let parameterIsReadOnly     = RTSPStatus(rawValue: 458)
    public static let aggregateNotAllowed     = RTSPStatus(rawValue: 459)
    public static let onlyAggregateAllowed    = RTSPStatus(rawValue: 460)
    public static let unsupportedTransport    = RTSPStatus(rawValue: 461)
    public static let destinationUnreachable  = RTSPStatus(rawValue: 462)
    public static let internalServerError     = RTSPStatus(rawValue: 500)
    public static let notImplemented          = RTSPStatus(rawValue: 501)
    public static let serviceUnavailable      = RTSPStatus(rawValue: 503)
    public static let rtspVersionNotSupported = RTSPStatus(rawValue: 505)
    public static let optionNotSupported      = RTSPStatus(rawValue: 551)

    // MARK: Reason phrases

    /// The RFC 2326 reason phrase for a known code, or `"Unknown"`.
    ///
    /// Used only when a device omits the phrase (`RTSP/1.0 401` with nothing after the code is
    /// documented on DS-2CD1xxx firmware) and when Vigil answers a server-initiated request. The
    /// phrase is never compared against: RFC 2326 §7.1.1 makes it free text.
    public var canonicalReason: String {
        switch rawValue {
        case 200: "OK"
        case 201: "Created"
        case 250: "Low on Storage Space"
        case 301: "Moved Permanently"
        case 302: "Moved Temporarily"
        case 303: "See Other"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 407: "Proxy Authentication Required"
        case 408: "Request Timeout"
        case 415: "Unsupported Media Type"
        case 451: "Parameter Not Understood"
        case 452: "Conference Not Found"
        case 453: "Not Enough Bandwidth"
        case 454: "Session Not Found"
        case 455: "Method Not Valid in This State"
        case 456: "Header Field Not Valid for Resource"
        case 457: "Invalid Range"
        case 458: "Parameter Is Read-Only"
        case 459: "Aggregate Operation Not Allowed"
        case 460: "Only Aggregate Operation Allowed"
        case 461: "Unsupported Transport"
        case 462: "Destination Unreachable"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        case 505: "RTSP Version Not Supported"
        case 551: "Option Not Supported"
        default: "Unknown"
        }
    }
}
