//
//  ResponseStatus.swift
//  VigilISAPI
//
//  The `<ResponseStatus>` document every non-GET answers with, its seven status codes, and the
//  sub-status vocabulary the error mapping keys off.
//  Implements docs/spec-isapi.md §9.1 and docs/API_CONTRACT.md §4.5.
//
//  The load-bearing fact: HTTP status and device status disagree. Several firmwares answer
//  `HTTP/1.1 200 OK` with `<statusCode>4</statusCode>`, so the body is inspected on **every**
//  response, success included, and the body wins.
//

import Foundation
import VigilProtocols

// MARK: - ResponseStatus

/// The device's own view of what happened.
public struct ResponseStatus: Sendable, Hashable {

    /// The resource the device thinks it answered. Echoed back verbatim; occasionally absent.
    public let requestURL: String?

    /// 1 is success. See `Code` for the rest.
    public let statusCode: Int

    /// The human-readable form of `statusCode`, as the device spells it.
    public let statusString: String?

    /// The machine-readable cause, **lowercased on read** so a comparison never depends on
    /// whether this firmware writes `notSupport` or `notsupport`.
    public let subStatusCode: String?

    /// Hikvision's internal 32-bit code. Meaningless outside their support tools, so it is carried
    /// verbatim into the diagnostics bundle and never interpreted.
    public let errorCode: Int?

    /// The device's error text, when it differs from `statusString`.
    public let errorMsg: String?

    /// Builds a status. Used by the parser and by the few call sites that synthesise one — an
    /// empty snapshot body on an NVR becomes `statusCode 4 / ipcOffline`, for instance.
    public init(requestURL: String? = nil, statusCode: Int, statusString: String? = nil,
                subStatusCode: String? = nil, errorCode: Int? = nil, errorMsg: String? = nil) {
        self.requestURL = requestURL
        self.statusCode = statusCode
        self.statusString = statusString
        self.subStatusCode = subStatusCode?.lowercased()
        self.errorCode = errorCode
        self.errorMsg = errorMsg
    }

    /// True when the device reports success.
    public var isOK: Bool { statusCode == Code.ok.rawValue }

    /// The named status code, or `nil` for a value outside the documented seven — which is kept,
    /// not discarded, because an unknown code in a diagnostics bundle is how the eighth gets found.
    public var code: Code? { Code(rawValue: statusCode) }

    // MARK: Parsing

    /// Reads a status document.
    ///
    /// Tolerates the three roots that carry one: `<ResponseStatus>`, `<userCheck>` (which answers
    /// the credential probe with the same fields), and a bare `<statusCode>` root emitted by at
    /// least one 5.1.x firmware. Returns `nil` when the document carries no `statusCode` at all,
    /// which is the normal case for a `GET` that returned real data.
    public init?(document: ISAPIDocument) {
        self.init(root: document.root)
    }

    /// Reads a status document from an arbitrary element, for a status nested in a larger body.
    public init?(root: XMLNode) {
        let direct = root["statusCode"]
        let bare = root.key == "statuscode" ? root : nil
        guard let value = direct.int ?? XMLValue(node: bare, path: "statusCode",
                                                 parent: root).int else {
            return nil
        }
        self.init(requestURL: root["requestURL"].string,
                  statusCode: value,
                  statusString: root["statusString"].string,
                  subStatusCode: root["subStatusCode|subStatus"].string,
                  errorCode: root["errorCode"].int,
                  errorMsg: root["errorMsg"].string)
    }

    // MARK: Codes

    /// The seven documented `statusCode` values.
    public enum Code: Int, Sendable, Hashable, CaseIterable {
        /// The request succeeded.
        case ok = 1
        /// The device is busy; the same request may work shortly.
        case deviceBusy = 2
        /// An internal device failure.
        case deviceError = 3
        /// Not permitted, or not supported in the device's current state.
        case invalidOperation = 4
        /// Our request body is syntactically wrong — a Vigil bug, never device data.
        case invalidXMLFormat = 5
        /// Our request body parsed but carries values the device rejects.
        case invalidXMLContent = 6
        /// The change was accepted and needs a reboot to take effect.
        case rebootRequired = 7
    }

    /// The sub-status strings the mapping table in §9.3 names, lowercased exactly as they are
    /// compared. Values outside this list are never discarded: they reach the user as
    /// `err.device.unknown` with the raw string.
    public enum SubStatus {
        public static let ok = "ok"
        public static let badAuthorization = "badauthorization"
        public static let incorrectUserNameOrPassword = "incorrectusernameorpassword"
        public static let userLocked = "userlocked"
        public static let notActivated = "notactivated"
        public static let insufficientPermission = "insufficientpermission"
        public static let notSupport = "notsupport"
        public static let riskPassword = "riskpassword"
        public static let badParameters = "badparameters"
        public static let invalidXMLFormat = "invalidxmlformat"
        public static let badXmlFormat = "badxmlformat"
        public static let invalidXMLContent = "invalidxmlcontent"
        public static let invalidOperation = "invalidoperation"
        public static let notFound = "notfound"
        public static let methodNotAllowed = "methodnotallowed"
        public static let deviceError = "deviceerror"
        public static let dataAbnormal = "dataabnormal"
        public static let deviceBusy = "devicebusy"
        public static let serviceUnavailable = "serviceunavailable"
        public static let upgrading = "upgrading"
        public static let noMemory = "nomemory"
        public static let rebootRequired = "rebootrequired"
        public static let ipcOffline = "ipcoffline"
    }
}
