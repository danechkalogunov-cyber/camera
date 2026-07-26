//
//  ErrorMappingTests.swift
//  VigilISAPITests
//
//  The §9.3 mapping table row by row: which `ISAPIError` a `statusCode`/`subStatusCode` pair
//  becomes, which message key the user sees, whether the client retries, and whether the resource
//  is remembered as unsupported.
//  Covers docs/spec-isapi.md §9.1–§9.4.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilISAPI

// MARK: - Status document

@Suite struct ResponseStatusTests {

    /// The §9.1 body, field by field. `subStatusCode` is lowercased on read so no comparison ever
    /// depends on the firmware's spelling.
    @Test func responseStatusReadsTheSpecBody() throws {
        let document = try ISAPIDocument(parsing: Data(SpecBodies.responseStatusNotSupport.utf8))
        let status = try #require(ResponseStatus(document: document))
        #expect(status.requestURL == "/ISAPI/PTZCtrl/channels/1/continuous")
        #expect(status.statusCode == 4)
        #expect(status.code == .invalidOperation)
        #expect(status.statusString == "Invalid Operation")
        #expect(status.subStatusCode == "notsupport")
        #expect(status.errorCode == 1_073_741_830)
        #expect(status.errorMsg == "notSupport")
        #expect(status.isOK == false)
    }

    /// A `<userCheck>` root carries the same fields under different names; the parser tolerates it
    /// by finding `statusCode` where it exists and reporting `nil` where it does not.
    @Test func responseStatusToleratesUserCheckAndBareRoots() throws {
        let userCheck = try ISAPIDocument(parsing: Data(SpecBodies.userCheckOK.utf8))
        #expect(ResponseStatus(document: userCheck) == nil)      // userCheck uses statusValue

        let bare = try ISAPIDocument(parsing: Data("<statusCode>7</statusCode>".utf8))
        let status = try #require(ResponseStatus(document: bare))
        #expect(status.statusCode == 7)
        #expect(status.code == .rebootRequired)

        let nested = try ISAPIDocument(parsing: Data("""
            <userCheck><statusCode>4</statusCode><subStatusCode>notActivated</subStatusCode>
            </userCheck>
            """.utf8))
        let fromUserCheck = try #require(ResponseStatus(document: nested))
        #expect(fromUserCheck.subStatusCode == "notactivated")
    }

    /// A document with no status at all is not a status — the normal case for a `GET` that
    /// returned real data.
    @Test func responseStatusIsAbsentForADataDocument() throws {
        let document = try ISAPIDocument(parsing: Data(SpecBodies.deviceInfo.utf8))
        #expect(ResponseStatus(document: document) == nil)
    }

    /// `statusCode 1` is the only success.
    @Test func responseStatusOnlyOneIsOK() {
        #expect(ResponseStatus(statusCode: 1).isOK)
        for code in 2...7 {
            #expect(ResponseStatus(statusCode: code).isOK == false)
        }
    }
}

// MARK: - Mapping table

@Suite struct ISAPIErrorMappingTests {

    /// One case per row of the §9.3 table: HTTP status, sub-status, expected error and expected
    /// message key.
    @Test(arguments: [
        (401, "badAuthorization", ISAPIError.authenticationFailed(username: "admin"),
         "err.auth.failed"),
        (401, "incorrectUserNameOrPassword", ISAPIError.authenticationFailed(username: "admin"),
         "err.auth.failed"),
        (401, "userLocked", ISAPIError.accountLocked(retryAfter: nil), "err.auth.locked"),
        (401, "notActivated", ISAPIError.deviceNotActivated, "err.device.notActivated"),
        (403, "insufficientPermission", ISAPIError.insufficientPermission(resource: "/R"),
         "err.auth.permission"),
        (403, "notSupport", ISAPIError.notSupported(resource: "/R"), "err.cap.unsupported"),
        (403, "riskPassword", ISAPIError.device(statusCode: 4, sub: "riskpassword"),
         "err.auth.riskPassword"),
        (400, "badParameters", ISAPIError.device(statusCode: 4, sub: "badparameters"),
         "err.req.badParameters"),
        (400, "invalidXMLFormat", ISAPIError.device(statusCode: 4, sub: "invalidxmlformat"),
         "err.internal"),
        (400, "badXmlFormat", ISAPIError.device(statusCode: 4, sub: "badxmlformat"),
         "err.internal"),
        (400, "invalidXMLContent", ISAPIError.device(statusCode: 4, sub: "invalidxmlcontent"),
         "err.req.badParameters"),
        (400, "invalidOperation", ISAPIError.device(statusCode: 4, sub: "invalidoperation"),
         "err.req.invalidOperation"),
        (404, "notFound", ISAPIError.notFound(resource: "/R"), "err.cap.unsupported"),
        (405, "methodNotAllowed", ISAPIError.notSupported(resource: "/R"), "err.cap.unsupported"),
        (500, "deviceError", ISAPIError.device(statusCode: 4, sub: "deviceerror"),
         "err.device.error"),
        (500, "dataAbnormal", ISAPIError.device(statusCode: 4, sub: "dataabnormal"),
         "err.device.error"),
        (503, "deviceBusy", ISAPIError.deviceBusy, "err.device.busy"),
        (503, "serviceUnavailable", ISAPIError.device(statusCode: 4, sub: "serviceunavailable"),
         "err.device.upgrading"),
        (503, "upgrading", ISAPIError.device(statusCode: 4, sub: "upgrading"),
         "err.device.upgrading"),
        (500, "noMemory", ISAPIError.device(statusCode: 4, sub: "nomemory"), "err.device.busy"),
        (200, "rebootRequired", ISAPIError.rebootRequired, "warn.rebootRequired"),
        (500, "ipcOffline", ISAPIError.device(statusCode: 4, sub: "ipcoffline"),
         "err.nvr.channelOffline"),
    ])
    func isapiErrorMappingFollowsTheSpecTable(row: (Int, String, ISAPIError, String)) {
        let (httpStatus, sub, expectedError, expectedKey) = row
        let status = ResponseStatus(statusCode: 4, subStatusCode: sub)
        let failure = ISAPIErrorMapping.classify(httpStatus: httpStatus, status: status,
                                                resource: "/R", username: "admin")
        #expect(failure.error == expectedError, "\(sub) mapped to \(failure.error)")
        #expect(failure.messageKey == expectedKey, "\(sub) keyed \(failure.messageKey)")
    }

    /// The three answers that mean "this firmware does not have that endpoint" are the three that
    /// seed the negative capability cache, and nothing else is.
    @Test func isapiErrorMappingMarksOnlyCapabilityAnswersForTheNegativeCache() {
        for sub in ["notSupport", "notFound", "methodNotAllowed"] {
            let failure = ISAPIErrorMapping.classify(
                httpStatus: 403, status: ResponseStatus(statusCode: 4, subStatusCode: sub),
                resource: "/R")
            #expect(failure.cachesNegativeCapability, "\(sub) should cache a negative")
        }
        for sub in ["deviceBusy", "badParameters", "userLocked"] {
            let failure = ISAPIErrorMapping.classify(
                httpStatus: 503, status: ResponseStatus(statusCode: 4, subStatusCode: sub),
                resource: "/R")
            #expect(failure.cachesNegativeCapability == false, "\(sub) should not cache")
        }
    }

    /// Retry advice: `deviceBusy` twice, `noMemory` once after two seconds, an upgrade pauses
    /// polling, and a rejected credential waits for the user.
    @Test func isapiErrorMappingCarriesTheRetryAdvice() {
        let busy = ISAPIErrorMapping.classify(
            httpStatus: 503, status: ResponseStatus(statusCode: 2, subStatusCode: "deviceBusy"),
            resource: "/R")
        #expect(busy.retry == .transient(attempts: 2,
                                         delays: [.milliseconds(400), .milliseconds(1200)]))

        let memory = ISAPIErrorMapping.classify(
            httpStatus: 500, status: ResponseStatus(statusCode: 3, subStatusCode: "noMemory"),
            resource: "/R")
        #expect(memory.retry == .transient(attempts: 1, delays: [.seconds(2)]))

        let upgrading = ISAPIErrorMapping.classify(
            httpStatus: 503, status: ResponseStatus(statusCode: 3, subStatusCode: "upgrading"),
            resource: "/R")
        #expect(upgrading.retry == .pausePolling(.seconds(300)))

        let locked = ISAPIErrorMapping.classify(
            httpStatus: 401, status: ResponseStatus(statusCode: 4, subStatusCode: "userLocked"),
            resource: "/R")
        #expect(locked.retry == .afterUserAction)

        let notSupported = ISAPIErrorMapping.classify(
            httpStatus: 403, status: ResponseStatus(statusCode: 4, subStatusCode: "notSupport"),
            resource: "/R")
        #expect(notSupported.retry == .never)
    }

    /// An unknown sub-status is never discarded: it reaches the user as `err.device.unknown` with
    /// the raw string, which is how the next firmware quirk gets found.
    @Test func isapiErrorMappingPreservesAnUnknownSubStatus() {
        let status = ResponseStatus(statusCode: 4, subStatusCode: "somethingBrandNew")
        let failure = ISAPIErrorMapping.classify(httpStatus: 500, status: status, resource: "/R")
        #expect(failure.error == .device(statusCode: 4, sub: "somethingbrandnew"))
        #expect(failure.messageKey == "err.device.unknown")
        #expect(failure.retry == .never)
    }

    /// A 401 with no sub-status at all is still a rejected credential, and it re-authenticates once
    /// before counting against the lockout budget.
    @Test func isapiErrorMappingHandlesA401WithNoSubStatus() {
        let failure = ISAPIErrorMapping.classify(httpStatus: 401, status: nil, resource: "/R",
                                                username: "admin")
        #expect(failure.error == .authenticationFailed(username: "admin"))
        #expect(failure.retry == .reauthenticateOnce)
    }

    /// An HTTP status Vigil has no row for becomes `.http`, carrying the status and the resource.
    @Test func isapiErrorMappingFallsBackToTheHTTPStatus() {
        let failure = ISAPIErrorMapping.classify(httpStatus: 418, status: nil, resource: "/R")
        #expect(failure.error == .http(status: 418, resource: "/R"))
    }

    /// Every error case has a user-facing key, and none of them leaks an enum description.
    @Test func isapiErrorUserMessageKeyIsTotal() {
        let all: [ISAPIError] = [
            .notConnected("x"), .timedOut(resource: "/R", seconds: 8), .cancelled,
            .responseTooLarge(bytes: 1), .authenticationFailed(username: "admin"),
            .accountLocked(retryAfter: 1800), .authBlockedLocally(failures: 2),
            .unsupportedAuthentication("SHA-256"), .insufficientPermission(resource: "/R"),
            .deviceNotActivated, .http(status: 500, resource: "/R"),
            .device(statusCode: 4, sub: "notsupport"), .notSupported(resource: "/R"),
            .notFound(resource: "/R"), .deviceBusy, .rebootRequired,
            .malformedResponse("x"), .unexpectedContentType(expected: "a", got: "b"),
            .multipartProtocolError("x"), .streamEnded(afterBytes: 1),
            .partTooLarge(bytes: 2, limit: 1), .tlsUnavailableOnThisPlatform,
        ]
        for error in all {
            let key = error.userMessageKey
            #expect(key.hasPrefix("err.") || key.hasPrefix("warn."), "\(error) keyed \(key)")
            #expect(key.contains(" ") == false)
        }
    }
}

// MARK: - Validation

@Suite struct ISAPIResponseValidatorTests {

    /// A JPEG answer is a success with no document: a snapshot is not XML and must not be treated
    /// as a malformed one.
    @Test func isapiResponseValidatorReturnsNoDocumentForBinaryBody() throws {
        var headers = HTTPHeaders()
        headers["Content-Type"] = "image/jpeg"
        let response = HTTPResponse(statusCode: 200, headers: headers,
                                    body: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00]))
        let document = try ISAPIResponseValidator.validate(response, resource: "/picture")
        #expect(document == nil)
    }

    /// An empty 200 — what a reboot answers with — is a success.
    @Test func isapiResponseValidatorAcceptsAnEmptySuccess() throws {
        let document = try ISAPIResponseValidator.validate(HTTPResponse(statusCode: 200),
                                                          resource: "/System/reboot")
        #expect(document == nil)
    }

    /// The body wins over the status line: 200 with `statusCode 4` throws.
    @Test func isapiResponseValidatorThrowsOnDeviceFailureInsideA200() throws {
        var headers = HTTPHeaders()
        headers["Content-Type"] = "application/xml"
        let response = HTTPResponse(statusCode: 200, headers: headers,
                                    body: Data(SpecBodies.responseStatusNotSupport.utf8))
        #expect(throws: ISAPIError.notSupported(resource: "/PTZCtrl")) {
            try ISAPIResponseValidator.validate(response, resource: "/PTZCtrl")
        }
    }

    /// An HTML login page is reported as a non-XML body even though the status was 200.
    @Test func isapiResponseValidatorRejectsAnHTMLBody() {
        var headers = HTTPHeaders()
        headers["Content-Type"] = "text/html; charset=utf-8"
        let response = HTTPResponse(statusCode: 200, headers: headers,
                                    body: Data("<html><body>login</body></html>".utf8))
        #expect(throws: ISAPIError.self) {
            try ISAPIResponseValidator.validate(response, resource: "/System/deviceInfo")
        }
    }

    /// A non-2xx with no parsable status becomes `.http`, carrying the resource.
    @Test func isapiResponseValidatorMapsABareHTTPFailure() {
        let response = HTTPResponse(statusCode: 500, body: Data("upstream error".utf8))
        #expect(throws: ISAPIError.http(status: 500, resource: "/System/status")) {
            try ISAPIResponseValidator.validate(response, resource: "/System/status")
        }
    }

    /// A successful XML answer comes back parsed, ready for the endpoint layer.
    @Test func isapiResponseValidatorReturnsTheParsedDocument() throws {
        var headers = HTTPHeaders()
        headers["Content-Type"] = "application/xml"
        let response = HTTPResponse(statusCode: 200, headers: headers,
                                    body: Data(SpecBodies.deviceInfo.utf8))
        let document = try ISAPIResponseValidator.validate(response, resource: "/System/deviceInfo")
        #expect(document?.rootName == "DeviceInfo")
        #expect(document?["model"].string == "DS-2CD2385FWD-I")
    }
}
