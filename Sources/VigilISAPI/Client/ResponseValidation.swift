//
//  ResponseValidation.swift
//  VigilISAPI
//
//  The four-step response check, the authoritative HTTP/sub-status → error mapping, and the
//  user-facing message key each failure carries.
//  Implements docs/spec-isapi.md §9.3 and §9.4.
//
//  Every mapping decision lives here rather than at call sites, because the same `403 notSupport`
//  must produce the same error, the same message and the same negative-capability cache entry
//  whether it came from a PTZ command or an image setting.
//

import Foundation
import VigilProtocols

// MARK: - Advice

/// What the client does automatically after a failure. The *user-facing* consequence is the
/// message key; this is the machine-facing one.
public enum ISAPIRetryAdvice: Sendable, Hashable {

    /// Never retry. The overwhelming majority of 4xx answers.
    case never

    /// Retry the request up to `attempts` more times with the given delays, in order.
    case transient(attempts: Int, delays: [Duration])

    /// Retry once after re-authenticating. Does not count as an authentication failure.
    case reauthenticateOnce

    /// Stop polling this device for `pause`, then resume. Firmware upgrades take minutes.
    case pausePolling(Duration)

    /// Nothing may retry on any schedule until the user supplies a new credential (R-25).
    case afterUserAction
}

/// A failure, fully classified: the typed error, the string key `VigilUI` localises, whether the
/// client retries, and whether the resource should be remembered as unsupported.
public struct ISAPIFailure: Sendable, Hashable {

    /// The error the caller throws.
    public var error: ISAPIError

    /// `Localizable.strings` key. `VigilUI` owns the text; this module owns the mapping.
    public var messageKey: String

    /// What the client does next.
    public var retry: ISAPIRetryAdvice

    /// True when the resource template should be cached as unsupported for 24 h, so the next call
    /// throws with no network round trip at all.
    public var cachesNegativeCapability: Bool

    /// Builds a failure.
    public init(error: ISAPIError, messageKey: String, retry: ISAPIRetryAdvice = .never,
                cachesNegativeCapability: Bool = false) {
        self.error = error
        self.messageKey = messageKey
        self.retry = retry
        self.cachesNegativeCapability = cachesNegativeCapability
    }
}

// MARK: - Mapping

/// The §9.3 table, as code.
public enum ISAPIErrorMapping {

    /// Classifies an answer.
    ///
    /// - Parameters:
    ///   - httpStatus: the HTTP status line code.
    ///   - status: the device's own `<ResponseStatus>`, when the body carried one. It **wins** over
    ///     the HTTP status: several firmwares answer `200 OK` with `statusCode 4`.
    ///   - resource: the resource path, for the error's context and the negative cache key.
    ///   - username: the account, for `.authenticationFailed`. Never the password.
    /// - Returns: the classified failure. An unrecognised sub-status maps to `.device` with
    ///   `err.device.unknown` and the raw string preserved — never discarded.
    public static func classify(httpStatus: Int, status: ResponseStatus?, resource: String,
                                username: String = "") -> ISAPIFailure {
        let sub = status?.subStatusCode
        let deviceCode = status?.statusCode ?? 0

        // Sub-status first: it is the same string whatever HTTP status carried it, and a device
        // that answers `200` with `ipcOffline` means exactly what one answering `500` means.
        switch sub {
        case ResponseStatus.SubStatus.userLocked:
            return ISAPIFailure(error: .accountLocked(retryAfter: nil),
                                messageKey: "err.auth.locked", retry: .afterUserAction)
        case ResponseStatus.SubStatus.notActivated:
            return ISAPIFailure(error: .deviceNotActivated, messageKey: "err.device.notActivated",
                                retry: .afterUserAction)
        case ResponseStatus.SubStatus.incorrectUserNameOrPassword:
            return ISAPIFailure(error: .authenticationFailed(username: username),
                                messageKey: "err.auth.failed", retry: .afterUserAction)
        case ResponseStatus.SubStatus.insufficientPermission:
            return ISAPIFailure(error: .insufficientPermission(resource: resource),
                                messageKey: "err.auth.permission")
        case ResponseStatus.SubStatus.notSupport:
            return ISAPIFailure(error: .notSupported(resource: resource),
                                messageKey: "err.cap.unsupported", cachesNegativeCapability: true)
        case ResponseStatus.SubStatus.methodNotAllowed:
            return ISAPIFailure(error: .notSupported(resource: resource),
                                messageKey: "err.cap.unsupported", cachesNegativeCapability: true)
        case ResponseStatus.SubStatus.notFound:
            return ISAPIFailure(error: .notFound(resource: resource),
                                messageKey: "err.cap.unsupported", cachesNegativeCapability: true)
        case ResponseStatus.SubStatus.riskPassword:
            return ISAPIFailure(error: .device(statusCode: deviceCode, sub: sub),
                                messageKey: "err.auth.riskPassword")
        case ResponseStatus.SubStatus.badParameters,
             ResponseStatus.SubStatus.invalidXMLContent:
            return ISAPIFailure(error: .device(statusCode: deviceCode, sub: sub),
                                messageKey: "err.req.badParameters")
        case ResponseStatus.SubStatus.invalidXMLFormat, ResponseStatus.SubStatus.badXmlFormat:
            return ISAPIFailure(error: .device(statusCode: deviceCode, sub: sub),
                                messageKey: "err.internal")
        case ResponseStatus.SubStatus.invalidOperation:
            return ISAPIFailure(error: .device(statusCode: deviceCode, sub: sub),
                                messageKey: "err.req.invalidOperation")
        case ResponseStatus.SubStatus.deviceError, ResponseStatus.SubStatus.dataAbnormal:
            return ISAPIFailure(error: .device(statusCode: deviceCode, sub: sub),
                                messageKey: "err.device.error")
        case ResponseStatus.SubStatus.deviceBusy:
            return ISAPIFailure(error: .deviceBusy, messageKey: "err.device.busy",
                                retry: .transient(attempts: 2,
                                                  delays: [.milliseconds(400), .milliseconds(1200)]))
        case ResponseStatus.SubStatus.serviceUnavailable, ResponseStatus.SubStatus.upgrading:
            return ISAPIFailure(error: .device(statusCode: deviceCode, sub: sub),
                                messageKey: "err.device.upgrading",
                                retry: .pausePolling(.seconds(300)))
        case ResponseStatus.SubStatus.noMemory:
            return ISAPIFailure(error: .device(statusCode: deviceCode, sub: sub),
                                messageKey: "err.device.busy",
                                retry: .transient(attempts: 1, delays: [.seconds(2)]))
        case ResponseStatus.SubStatus.rebootRequired:
            return ISAPIFailure(error: .rebootRequired, messageKey: "warn.rebootRequired")
        case ResponseStatus.SubStatus.ipcOffline:
            return ISAPIFailure(error: .device(statusCode: deviceCode, sub: sub),
                                messageKey: "err.nvr.channelOffline")
        default:
            break
        }

        // No sub-status Vigil knows: fall back to the HTTP status.
        switch httpStatus {
        case 401:
            return ISAPIFailure(error: .authenticationFailed(username: username),
                                messageKey: "err.auth.failed", retry: .reauthenticateOnce)
        case 403:
            return ISAPIFailure(error: .insufficientPermission(resource: resource),
                                messageKey: "err.auth.permission")
        case 404:
            return ISAPIFailure(error: .notFound(resource: resource),
                                messageKey: "err.cap.unsupported", cachesNegativeCapability: true)
        case 405:
            return ISAPIFailure(error: .notSupported(resource: resource),
                                messageKey: "err.cap.unsupported", cachesNegativeCapability: true)
        case 503:
            return ISAPIFailure(error: .deviceBusy, messageKey: "err.device.busy",
                                retry: .transient(attempts: 2,
                                                  delays: [.milliseconds(400), .milliseconds(1200)]))
        default:
            break
        }
        if let status, !status.isOK {
            // A device status Vigil does not know. Kept verbatim; the raw code reaches the user.
            let key = status.code == .rebootRequired ? "warn.rebootRequired" : "err.device.unknown"
            let error: ISAPIError = status.code == .rebootRequired
                ? .rebootRequired
                : .device(statusCode: status.statusCode, sub: status.subStatusCode)
            let busy = status.code == .deviceBusy
            return ISAPIFailure(error: busy ? .deviceBusy : error,
                                messageKey: busy ? "err.device.busy" : key,
                                retry: busy
                                    ? .transient(attempts: 2,
                                                 delays: [.milliseconds(400), .milliseconds(1200)])
                                    : .never)
        }
        return ISAPIFailure(error: .http(status: httpStatus, resource: resource),
                            messageKey: "err.device.unknown")
    }
}

// MARK: - Message keys

public extension ISAPIError {

    /// The `Localizable.strings` key that describes this failure to a person.
    ///
    /// Every case has one: an error that reaches the user as a raw enum description is a defect,
    /// and the mapping being total is what makes that checkable in a test.
    var userMessageKey: String {
        switch self {
        case .notConnected: "err.net.unreachable"
        case .timedOut: "err.net.timeout"
        case .cancelled: "err.net.cancelled"
        case .responseTooLarge: "err.device.unknown"
        case .authenticationFailed: "err.auth.failed"
        case .accountLocked: "err.auth.locked"
        case .authBlockedLocally: "err.auth.blocked"
        case .unsupportedAuthentication: "err.auth.unsupportedScheme"
        case .insufficientPermission: "err.auth.permission"
        case .deviceNotActivated: "err.device.notActivated"
        case .http: "err.device.unknown"
        case let .device(_, sub):
            switch sub {
            case ResponseStatus.SubStatus.riskPassword: "err.auth.riskPassword"
            case ResponseStatus.SubStatus.badParameters,
                 ResponseStatus.SubStatus.invalidXMLContent: "err.req.badParameters"
            case ResponseStatus.SubStatus.invalidXMLFormat,
                 ResponseStatus.SubStatus.badXmlFormat: "err.internal"
            case ResponseStatus.SubStatus.invalidOperation: "err.req.invalidOperation"
            case ResponseStatus.SubStatus.deviceError,
                 ResponseStatus.SubStatus.dataAbnormal: "err.device.error"
            case ResponseStatus.SubStatus.serviceUnavailable,
                 ResponseStatus.SubStatus.upgrading: "err.device.upgrading"
            case ResponseStatus.SubStatus.noMemory: "err.device.busy"
            case ResponseStatus.SubStatus.ipcOffline: "err.nvr.channelOffline"
            default: "err.device.unknown"
            }
        case .notSupported, .notFound: "err.cap.unsupported"
        case .deviceBusy: "err.device.busy"
        case .rebootRequired: "warn.rebootRequired"
        case .malformedResponse: "err.device.badResponse"
        case .unexpectedContentType: "err.device.badResponse"
        case .multipartProtocolError: "err.device.badResponse"
        case .streamEnded: "err.net.streamEnded"
        case .partTooLarge: "err.device.badResponse"
        case .tlsUnavailableOnThisPlatform: "err.net.tlsUnavailable"
        }
    }
}

// MARK: - Validation

/// The four-step check applied to every response before any typed decode.
public enum ISAPIResponseValidator {

    /// Validates `response`.
    ///
    /// Rules, in order (§9.4):
    /// 1. `text/html` body ⇒ `.malformedResponse`, because a device with web-auth misconfigured
    ///    answers a login page with HTTP 200 and "missing element" would be a lie.
    /// 2. 2xx with an empty or non-XML body ⇒ `nil`; a JPEG snapshot takes this path.
    /// 3. The body parses ⇒ read `<ResponseStatus>`; a status that is not OK is mapped per §9.3
    ///    **even when the HTTP status was 200**.
    /// 4. Outside 2xx with no parsable status ⇒ `.http`.
    ///
    /// - Returns: the parsed document, or `nil` when the response legitimately carried no XML.
    /// - Throws: the mapped `ISAPIError`.
    public static func validate(_ response: HTTPResponse, resource: String,
                                username: String = "") throws(ISAPIError) -> ISAPIDocument? {
        let contentType = (response.contentType ?? "").lowercased()
        let isSuccess = (200...299).contains(response.statusCode)

        if contentType.contains("text/html"), !response.body.isEmpty {
            throw ISAPIError.malformedResponse(
                "not XML: \(resource) returned an HTML page (HTTP \(response.statusCode))")
        }
        guard !response.body.isEmpty, ISAPIDocument.looksLikeXML(response.body) else {
            if isSuccess { return nil }
            throw ISAPIErrorMapping.classify(httpStatus: response.statusCode, status: nil,
                                             resource: resource, username: username).error
        }

        let document: ISAPIDocument
        do {
            document = try ISAPIDocument(parsing: response.body)
        } catch {
            if isSuccess { throw error }
            throw ISAPIErrorMapping.classify(httpStatus: response.statusCode, status: nil,
                                             resource: resource, username: username).error
        }

        let status = ResponseStatus(document: document)
        if let status, !status.isOK {
            throw ISAPIErrorMapping.classify(httpStatus: response.statusCode, status: status,
                                             resource: resource, username: username).error
        }
        guard isSuccess else {
            throw ISAPIErrorMapping.classify(httpStatus: response.statusCode, status: status,
                                             resource: resource, username: username).error
        }
        return document
    }
}
