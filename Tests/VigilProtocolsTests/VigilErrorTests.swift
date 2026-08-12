//
//  VigilErrorTests.swift
//  VigilProtocolsTests
//
//  Every domain error case: its diagnostic code, its severity and — the one that costs a
//  customer their camera if it is wrong — its retry disposition.
//  Covers docs/API_CONTRACT.md §3.9 and docs/ARCHITECTURE.md §7.2–§7.3.
//

import Foundation
import Testing
import VigilProtocols

@Suite struct VigilErrorTests {

    /// One sample per case of every domain enum. Kept exhaustive by hand: a new case that is not
    /// added here shows up as a gap in `everyCaseHasAWellFormedDiagnosticCode`'s count assertion.
    static let allCases: [VigilError] =
        transport + rtsp + rtp + bitstream + isapi
        + discovery + decode + render + storage + credential + recording
        + [.cancelled, .internalInvariant("x", file: #fileID, line: 1)]

    static let transport: [VigilError] = [
        .transport(.connectTimeout), .transport(.connectRefused), .transport(.hostUnreachable),
        .transport(.peerClosed), .transport(.readIdleTimeout), .transport(.tlsFailed("x")),
        .transport(.tlsUntrusted(fingerprint: "ab")), .transport(.tlsPinMismatch(host: "h")),
        .transport(.multicastBlocked), .transport(.localNetworkDenied),
        .transport(.egressBlocked(host: "h")), .transport(.network("x")),
    ]

    static let rtsp: [VigilError] = [
        .rtsp(.malformedResponse), .rtsp(.headerTooLarge(bytes: 1)),
        .rtsp(.unexpectedStatus(code: 500)), .rtsp(.unauthorized), .rtsp(.authRejected),
        .rtsp(.accessForbidden), .rtsp(.credentialsMissing), .rtsp(.methodNotSupported),
        .rtsp(.noSuitableTrack), .rtsp(.sdpParse("m=")), .rtsp(.transportRejected),
        .rtsp(.sessionNotFound), .rtsp(.pathNotFound), .rtsp(.interleaveDesync(recovered: true)),
        .rtsp(.commandQueueOverflow), .rtsp(.tooManyRedirects), .rtsp(.timeout(.keepalive)),
        .rtsp(.multicastBlocked),
    ]

    static let rtp: [VigilError] = [
        .rtp(.shortPacket(length: 4)), .rtp(.badVersion(1)), .rtp(.truncatedCSRC),
        .rtp(.truncatedExtension), .rtp(.badPaddingLength(9)), .rtp(.unknownPayloadType(99)),
        .rtp(.badFragment), .rtp(.aggregationOverflow), .rtp(.jitterBufferOverflow(dropped: 2)),
        .rtp(.gap(count: 3)), .rtp(.unsupportedEncoding("VP9")),
        .rtp(.missingRequiredFmtp("sprop")), .rtp(.unsupportedAACMode("AAC-lbr")),
        .rtp(.malformedAudioConfig("asc")), .rtp(.invalidClockRate(0)),
    ]

    static let bitstream: [VigilError] = [
        .bitstream(.emptyNALUnit), .bitstream(.tooLarge(bytes: 1)),
        .bitstream(.unexpectedEndOfData(atBit: 7)), .bitstream(.malformedExpGolomb(leadingZeros: 40)),
        .bitstream(.valueOutOfRange(field: "pic_width", value: 99)),
        .bitstream(.wrongNALType(expected: 7, found: 1)), .bitstream(.forbiddenBitSet),
        .bitstream(.invalidTemporalID), .bitstream(.negativeSkip), .bitstream(.invalidCropping),
        .bitstream(.unsupportedSyntax("svc")), .bitstream(.unsupportedProfile(idc: 244)),
        .bitstream(.unsupportedChromaFormat(idc: 3)), .bitstream(.truncatedSEI),
        .bitstream(.truncatedLengthPrefix(atOffset: 12)),
        .bitstream(.unsupportedRecordVersion(2)), .bitstream(.unsupportedLengthSize(1)),
        .bitstream(.invalidBase64), .bitstream(.noParameterSets),
    ]

    static let isapi: [VigilError] = [
        .isapi(.notConnected("deviceInfo")), .isapi(.timedOut(resource: "x", seconds: 5)),
        .isapi(.cancelled), .isapi(.responseTooLarge(bytes: 1)),
        .isapi(.authenticationFailed(username: "admin")), .isapi(.accountLocked(retryAfter: 30)),
        .isapi(.authBlockedLocally(failures: 2)), .isapi(.unsupportedAuthentication("NTLM")),
        .isapi(.insufficientPermission(resource: "ptz")), .isapi(.deviceNotActivated),
        .isapi(.http(status: 500, resource: "x")), .isapi(.device(statusCode: 4, sub: "notSupport")),
        .isapi(.notSupported(resource: "x")), .isapi(.notFound(resource: "x")),
        .isapi(.deviceBusy), .isapi(.rebootRequired), .isapi(.malformedResponse("xml")),
        .isapi(.unexpectedContentType(expected: "text/xml", got: "text/html")),
        .isapi(.multipartProtocolError("boundary")), .isapi(.streamEnded(afterBytes: 10)),
        .isapi(.partTooLarge(bytes: 2, limit: 1)), .isapi(.tlsUnavailableOnThisPlatform),
    ]

    static let discovery: [VigilError] = [
        .discovery(.interfaceEnumerationFailed(errno: 1)), .discovery(.noEligibleInterfaces),
        .discovery(.arpReadFailed(errno: 1)), .discovery(.multicastUnavailable(.joinFailed)),
        .discovery(.channelBindFailed(port: 37020, "in use")),
        .discovery(.prefixTooWide(bits: 8, hostCount: 16_777_214)),
        .discovery(.probeSendFailed), .discovery(.budgetExhausted(.datagrams)),
        .discovery(.cancelled),
    ]

    static let decode: [VigilError] = [
        .decode(.vt(status: -12_909)), .decode(.badData), .decode(.invalidSession),
        .decode(.malfunction), .decode(.formatChangeUnsupported), .decode(.noHardwareDecoder),
        .decode(.budgetDenied(.insufficientBudget)), .decode(.missingParameterSets),
        .decode(.emptyParameterSet(index: 0)), .decode(.tooManyParameterSets(count: 9)),
        .decode(.formatDescriptionFailed(status: -1)), .decode(.blockBufferFailed(status: -1)),
        .decode(.sampleBufferFailed(status: -1)), .decode(.pixelBufferPoolFailed(status: -1)),
        .decode(.unsupportedFormat(codec: .h265, detail: "Main 4:4:4")),
    ]

    static let render: [VigilError] = [
        .render(.metalUnavailable), .render(.shaderCompilationFailed("x")),
        .render(.pipelineCompileFailed("x")), .render(.textureCacheFailed(status: -1)),
        .render(.textureCreationFailed), .render(.drawableUnavailable),
        .render(.commandBufferFailed(code: 1, detail: "x")), .render(.deviceRemoved),
        .render(.unsupportedPixelFormat(0)), .render(.captureFailed("x")),
        .render(.atlasTooLarge(requested: .uhd4K, max: 16_384)),
    ]

    static let storage: [VigilError] = [
        .storage(.notWritable(path: "/x")), .storage(.corruptDocument("eof")),
        .storage(.schemaTooNew(found: 4, supported: 3)), .storage(.missingMigration(from: 1)),
        .storage(.notAnObject), .storage(.diskFull(needBytes: 1)),
        .storage(.atomicReplaceFailed), .storage(.documentTooLarge(bytes: 1)),
    ]

    static let credential: [VigilError] = [
        .credential(.keychainStatus(-25_300, operation: "read")), .credential(.notFound),
        .credential(.duplicate), .credential(.userCancelledUnlock), .credential(.keychainLocked),
        .credential(.missingEntitlement), .credential(.decodeFailed),
    ]

    static let recording: [VigilError] = [
        .recording(.firstSampleNotKeyframe), .recording(.writerFailed("x")),
        .recording(.destinationUnwritable(path: "/x")),
        .recording(.spaceBelowReserve(freeBytes: 1)), .recording(.folderUnavailable),
        .recording(.formatChangedMidClip),
    ]

    // MARK: - Codes

    @Test func everyCaseHasAWellFormedDiagnosticCode() {
        // 12 + 18 + 15 + 19 + 22 + 9 + 15 + 11 + 8 + 7 + 6 domain cases, plus the two root cases.
        #expect(Self.allCases.count == 144)
        for error in Self.allCases {
            let code = error.diagnosticCode
            let parts = code.split(separator: "-", omittingEmptySubsequences: false)
            #expect(parts.count == 3, "\(code) is not VG-<DOMAIN>-NNNN")
            #expect(parts.first == "VG", "\(code) does not start with VG")
            #expect(parts.last?.count == 4, "\(code) does not end in four digits")
            #expect(parts.last?.allSatisfy(\.isNumber) == true, "\(code) has a non-digit tail")
            #expect(parts[1].allSatisfy({ $0.isUppercase || $0.isNumber }), "\(code) domain")
        }
    }

    @Test func everyCaseHasAUniqueDiagnosticCode() {
        var seen: [String: String] = [:]
        for error in Self.allCases {
            let code = error.diagnosticCode
            let described = String(describing: error)
            #expect(seen[code] == nil, "\(code) is used by both \(seen[code] ?? "") and \(described)")
            seen[code] = described
        }
        #expect(seen.count == Self.allCases.count)
    }

    @Test func theCodesFixedByArchitectureSectionSevenAreUnchanged() {
        // These four appear in ARCHITECTURE.md §7.3 as examples, which makes them published API.
        #expect(VigilError.rtsp(.unauthorized).diagnosticCode == "VG-RTSP-0401")
        #expect(VigilError.rtsp(.transportRejected).diagnosticCode == "VG-RTSP-0453")
        #expect(VigilError.decode(.badData).diagnosticCode == "VG-DEC-0011")
        #expect(VigilError.storage(.corruptDocument("x")).diagnosticCode == "VG-STOR-0002")
    }

    @Test func everyCaseHasUserFacingCopy() {
        for error in Self.allCases {
            let message = error.userMessage
            #expect(!message.isEmpty, "\(error.diagnosticCode) has no user message")
            #expect(message.hasSuffix("."), "\(error.diagnosticCode): copy is not a sentence")
            // "No error numbers" — the code must never leak into the sentence.
            #expect(!message.contains("VG-"), "\(error.diagnosticCode) leaks its code")
            if let remedy = error.userRemedy {
                #expect(!remedy.isEmpty)
                #expect(remedy.hasSuffix("."), "\(error.diagnosticCode): remedy is not a sentence")
            }
        }
    }

    @Test func theRootErrorForwardsToItsCause() {
        let cause = RTSPError.authRejected
        let wrapped = VigilError.rtsp(cause)
        #expect(wrapped.diagnosticCode == cause.diagnosticCode)
        #expect(wrapped.severity == cause.severity)
        #expect(wrapped.disposition == cause.disposition)
        #expect(wrapped.userMessage == cause.userMessage)
        #expect(wrapped.userRemedy == cause.userRemedy)
    }

    // MARK: - Retry classification

    @Test func authenticationFailureIsTerminalInEveryDomain() {
        // Retrying a rejected password locks the user out of their own camera (R-25). This is the
        // single most important row in the disposition table.
        let terminal: [any VigilFailure] = [
            RTSPError.authRejected, RTSPError.accessForbidden, RTSPError.credentialsMissing,
            ISAPIError.authenticationFailed(username: "admin"),
            ISAPIError.accountLocked(retryAfter: nil),
            ISAPIError.authBlockedLocally(failures: 2),
            ISAPIError.deviceNotActivated,
            ISAPIError.insufficientPermission(resource: "live"),
        ]
        for error in terminal {
            #expect(
                error.disposition == .retryAfterUserAction,
                "\(error.diagnosticCode) must not be retried automatically")
            #expect(error.isAutomaticallyRetryable == false, "\(error.diagnosticCode)")
            #expect(error.severity == .fatal, "\(error.diagnosticCode) must be fatal")
            #expect(error.userRemedy != nil, "\(error.diagnosticCode) must tell the user what to do")
        }
    }

    @Test func theFirstUnauthorizedGetsExactlyOneImmediateRetry() {
        // 401 with a fresh challenge is normal: answer it once. The *second* 401 is authRejected.
        #expect(RTSPError.unauthorized.disposition == .retryImmediatelyOnce)
        #expect(RTSPError.unauthorized.severity == .recoverable)
        #expect(RTSPError.unauthorized.isAutomaticallyRetryable)
        #expect(RTSPError.authRejected.disposition == .retryAfterUserAction)
    }

    @Test func transientTransportFailuresRetryWithBackoff() {
        let transient: [TransportError] = [
            .connectTimeout, .connectRefused, .hostUnreachable,
            .peerClosed, .readIdleTimeout, .network("x"),
            .multicastBlocked, .tlsFailed("x"),
            .tlsUntrusted(fingerprint: "ab"),
        ]
        for error in transient {
            #expect(error.disposition == .retryWithBackoff, "\(error.diagnosticCode)")
            #expect(error.severity == .recoverable, "\(error.diagnosticCode)")
        }
    }

    @Test func policyAndTrustTransportFailuresAreTerminal() {
        let terminal: [TransportError] = [
            .localNetworkDenied, .egressBlocked(host: "8.8.8.8"),
            .tlsPinMismatch(host: "cam"),
        ]
        for error in terminal {
            #expect(error.severity == .fatal, "\(error.diagnosticCode)")
            #expect(error.disposition == .retryAfterUserAction, "\(error.diagnosticCode)")
        }
    }

    @Test func packetLevelRTPFaultsAreCountedNotRetried() {
        let counted: [RTPError] = [
            .shortPacket(length: 4), .badVersion(1), .truncatedCSRC,
            .truncatedExtension, .badPaddingLength(9),
            .unknownPayloadType(99), .badFragment, .aggregationOverflow,
            .jitterBufferOverflow(dropped: 1), .gap(count: 1),
        ]
        for error in counted {
            #expect(error.severity == .degraded, "\(error.diagnosticCode) must not fail a session")
            #expect(error.disposition == .noRetry, "\(error.diagnosticCode)")
        }
    }

    @Test func negotiationRTPFaultsNeedTheUser() {
        let negotiation: [RTPError] = [
            .unsupportedEncoding("VP9"), .missingRequiredFmtp("x"),
            .unsupportedAACMode("x"), .malformedAudioConfig("x"),
            .invalidClockRate(0),
        ]
        for error in negotiation {
            #expect(error.severity == .recoverable, "\(error.diagnosticCode)")
            #expect(error.disposition == .retryAfterUserAction, "\(error.diagnosticCode)")
        }
    }

    @Test func badDataRecoversAtTheNextKeyframeWithoutASessionRestart() {
        #expect(DecodeError.badData.disposition == .retryImmediatelyOnce)
        #expect(DecodeError.invalidSession.disposition == .retryImmediatelyOnce)
        #expect(DecodeError.malfunction.disposition == .retryImmediatelyOnce)
        #expect(DecodeError.noHardwareDecoder.severity == .degraded)
        #expect(DecodeError.noHardwareDecoder.disposition == .noRetry)
    }

    @Test func schemaTooNewIsFatalAndEveryOtherStorageFailureNeedsTheUser() {
        #expect(StorageError.schemaTooNew(found: 4, supported: 3).severity == .fatal)
        #expect(StorageError.diskFull(needBytes: 1).severity == .recoverable)
        for error in [
            StorageError.notWritable(path: "/x"), .corruptDocument("x"),
            .diskFull(needBytes: 1), .atomicReplaceFailed,
        ] {
            #expect(error.disposition == .retryAfterUserAction, "\(error.diagnosticCode)")
        }
    }

    @Test func noParameterSetsWaitsForTheNextKeyframe() {
        #expect(BitstreamError.noParameterSets.disposition == .retryImmediatelyOnce)
        #expect(BitstreamError.noParameterSets.severity == .recoverable)
        #expect(BitstreamError.emptyNALUnit.disposition == .retryWithBackoff)
    }

    @Test func renderFailuresNeverRetryAndMetalLossIsOnlyDegraded() {
        for error in Self.render {
            #expect(error.disposition == .noRetry, "\(error.diagnosticCode)")
        }
        #expect(RenderError.metalUnavailable.severity == .degraded)
    }

    @Test func severityOrdersFromDegradedToFatal() {
        #expect(ErrorSeverity.degraded < ErrorSeverity.recoverable)
        #expect(ErrorSeverity.recoverable < ErrorSeverity.fatal)
    }

    // MARK: - Metadata

    @Test func logMetadataIsRedactedAndCarriesTheContext() {
        let error = VigilError.isapi(.malformedResponse("password=hunter2 in body"))
        let metadata = error.logMetadata
        #expect(metadata["detail"]?.contains("hunter2") == false)
        #expect(VigilError.rtsp(.unexpectedStatus(code: 503)).logMetadata["status"] == "503")
        #expect(VigilError.rtp(.gap(count: 7)).logMetadata["gap"] == "7")
        #expect(
            VigilError.transport(.egressBlocked(host: "8.8.8.8")).logMetadata["host"]
                == "8.8.8.8")
    }

    @Test func keychainMetadataNeverCarriesAnAccountOrPassword() {
        let metadata = CredentialError.keychainStatus(-25_300, operation: "read").logMetadata
        #expect(metadata["osstatus"] == "-25300")
        #expect(metadata["operation"] == "read")
        #expect(metadata.count == 2)
    }

    // MARK: - Root cases

    @Test func cancellationIsDegradedAndNeverRetried() {
        #expect(VigilError.cancelled.severity == .degraded)
        #expect(VigilError.cancelled.disposition == .noRetry)
        #expect(VigilError.cancelled.diagnosticCode == "VG-CORE-0001")
        #expect(VigilError.cancelled.userRemedy == nil)
    }

    @Test func vigilRequireThrowsOnlyWhenTheConditionFails() throws {
        // The guard reads backwards; this is the test that pins its direction.
        try vigilRequire(true, "must not throw")
        var thrown: VigilError?
        do {
            try vigilRequire(false, "sps id out of range")
        } catch {
            thrown = error
        }
        let error = try #require(thrown)
        #expect(error.diagnosticCode == "VG-CORE-0002")
        #expect(error.severity == .fatal)
        #expect(error.disposition == .noRetry)
        #expect(error.logMetadata["invariant"] == "sps id out of range")
        #expect(error.logMetadata["file"]?.isEmpty == false)
        #expect(error.logMetadata["line"]?.isEmpty == false)
    }

    @Test func theRootErrorIsHashableDespiteItsStaticStringPayload() {
        let a = VigilError.internalInvariant("x", file: "A.swift", line: 3)
        let b = VigilError.internalInvariant("x", file: "A.swift", line: 3)
        let c = VigilError.internalInvariant("x", file: "A.swift", line: 4)
        #expect(a == b)
        #expect(a != c)
        #expect(Set([a, b, c]).count == 2)
        #expect(VigilError.cancelled != a)
        #expect(VigilError.rtsp(.unauthorized) != VigilError.rtsp(.authRejected))
        #expect(VigilError.rtsp(.unauthorized) == VigilError.rtsp(.unauthorized))
    }
}
