//
//  DiagnosticCodes.swift
//  VigilProtocols
//
//  The `VG-<DOMAIN>-NNNN` code tables and the severity / disposition / copy mappings
//  for every domain error.
//
//  Implements docs/API_CONTRACT.md §3.9 and docs/ARCHITECTURE.md §7.2–§7.3.
//
//  Codes are **stable forever**. They appear in logs, in the diagnostics bundle and in the Stream
//  Doctor's "copy details" text, and users quote them in support requests. Never renumber a case,
//  never reuse a retired number: append instead. The four codes fixed by ARCHITECTURE.md §7.3 —
//  VG-RTSP-0401, VG-RTSP-0453, VG-DEC-0011 and VG-STOR-0002 — are load-bearing and are marked.
//

// MARK: - Transport

public extension TransportError {

    var diagnosticCode: String {
        switch self {
        case .connectTimeout: "VG-NET-0001"
        case .connectRefused: "VG-NET-0002"
        case .hostUnreachable: "VG-NET-0003"
        case .peerClosed: "VG-NET-0004"
        case .readIdleTimeout: "VG-NET-0005"
        case .tlsFailed: "VG-NET-0006"
        case .tlsUntrusted: "VG-NET-0007"
        case .tlsPinMismatch: "VG-NET-0008"
        case .multicastBlocked: "VG-NET-0009"
        case .localNetworkDenied: "VG-NET-0010"
        case .egressBlocked: "VG-NET-0011"
        case .network: "VG-NET-0012"
        }
    }

    var severity: ErrorSeverity {
        switch self {
        case .localNetworkDenied, .egressBlocked, .tlsPinMismatch: .fatal
        default: .recoverable
        }
    }

    var disposition: RetryDisposition {
        switch self {
        case .localNetworkDenied, .egressBlocked, .tlsPinMismatch: .retryAfterUserAction
        default: .retryWithBackoff
        }
    }

    var userMessage: String {
        switch self {
        case .connectTimeout: "The camera did not answer in time."
        case .connectRefused: "The camera refused the connection."
        case .hostUnreachable: "The camera could not be reached on this network."
        case .peerClosed: "The camera closed the connection."
        case .readIdleTimeout: "The camera stopped sending video."
        case .tlsFailed: "The secure connection to the camera failed."
        case .tlsUntrusted: "This camera's certificate has not been trusted yet."
        case .tlsPinMismatch: "This camera's certificate has changed since you first connected."
        case .multicastBlocked: "This network is blocking multicast."
        case .localNetworkDenied: "Vigil is not allowed to reach devices on your local network."
        case .egressBlocked: "Vigil only connects to devices on your local network."
        case .network: "The network connection to the camera failed."
        }
    }

    var userRemedy: String? {
        switch self {
        case .connectTimeout, .hostUnreachable:
            "Check the address and that the camera is powered on."
        case .connectRefused:
            "Check the port number in the camera's settings."
        case .peerClosed, .readIdleTimeout, .network:
            nil
        case .tlsFailed:
            "Try connecting without TLS, or check the camera's certificate settings."
        case .tlsUntrusted:
            "Review the certificate and trust it if you recognise this camera."
        case .tlsPinMismatch:
            "Only continue if you know the camera's certificate was replaced."
        case .multicastBlocked:
            "Add the camera by address instead of searching for it."
        case .localNetworkDenied:
            "Allow Vigil to access your local network in System Settings ▸ Privacy & Security."
        case .egressBlocked:
            "Use an address on your local network."
        }
    }

    var logMetadata: [String: String] {
        switch self {
        case .tlsFailed(let detail): ["detail": Redact.secrets(in: detail)]
        case .tlsUntrusted(let fingerprint): ["fingerprint": fingerprint]
        case .tlsPinMismatch(let host): ["host": host]
        case .egressBlocked(let host): ["host": host]
        case .network(let detail): ["detail": Redact.secrets(in: detail)]
        default: [:]
        }
    }
}

// MARK: - RTSP

public extension RTSPError {

    var diagnosticCode: String {
        switch self {
        case .malformedResponse: "VG-RTSP-0001"
        case .headerTooLarge: "VG-RTSP-0002"
        case .unexpectedStatus: "VG-RTSP-0003"
        case .noSuitableTrack: "VG-RTSP-0004"
        case .sdpParse: "VG-RTSP-0005"
        case .interleaveDesync: "VG-RTSP-0006"
        case .commandQueueOverflow: "VG-RTSP-0007"
        case .tooManyRedirects: "VG-RTSP-0008"
        case .timeout: "VG-RTSP-0009"
        case .credentialsMissing: "VG-RTSP-0400"
        case .unauthorized: "VG-RTSP-0401"          // fixed by ARCHITECTURE.md §7.3
        case .authRejected: "VG-RTSP-0402"
        case .accessForbidden: "VG-RTSP-0403"
        case .pathNotFound: "VG-RTSP-0404"
        case .methodNotSupported: "VG-RTSP-0405"
        case .transportRejected: "VG-RTSP-0453"     // fixed by ARCHITECTURE.md §7.3
        case .sessionNotFound: "VG-RTSP-0454"
        }
    }

    var severity: ErrorSeverity {
        switch self {
        case .authRejected, .accessForbidden, .credentialsMissing: .fatal
        case .interleaveDesync(let recovered): recovered ? .degraded : .recoverable
        default: .recoverable
        }
    }

    /// `.unauthorized` gets exactly one credentialed retry; a second 401 is `.authRejected`, which
    /// is **terminal**. Retrying a rejected password locks the user out of their own camera after
    /// a handful of attempts on Hikvision firmware (API_CONTRACT §2 R-25) — this is the single
    /// most important disposition in the table.
    var disposition: RetryDisposition {
        switch self {
        case .unauthorized: .retryImmediatelyOnce
        case .authRejected, .accessForbidden, .credentialsMissing: .retryAfterUserAction
        default: .retryWithBackoff
        }
    }

    var userMessage: String {
        switch self {
        case .malformedResponse: "The camera sent a reply Vigil could not read."
        case .headerTooLarge: "The camera sent an unreasonably large reply."
        case .unexpectedStatus: "The camera reported an unexpected condition."
        case .unauthorized: "The camera asked for a password."
        case .authRejected: "The user name or password is incorrect."
        case .accessForbidden: "This account is not allowed to view that camera."
        case .credentialsMissing: "Vigil has no saved password for this camera."
        case .methodNotSupported: "This camera does not support a command Vigil needs."
        case .noSuitableTrack: "This camera offered no video Vigil can play."
        case .sdpParse: "Vigil could not read the camera's stream description."
        case .transportRejected: "The camera refused the streaming connection."
        case .sessionNotFound: "The camera forgot the streaming session."
        case .pathNotFound: "That stream does not exist on this camera."
        case .interleaveDesync: "The video stream lost synchronisation."
        case .commandQueueOverflow: "The camera stopped answering."
        case .tooManyRedirects: "The camera redirected Vigil too many times."
        case .timeout: "The camera did not answer in time."
        }
    }

    var userRemedy: String? {
        switch self {
        case .authRejected, .credentialsMissing: "Enter the camera's user name and password again."
        case .accessForbidden: "Use an account with live-view permission for this channel."
        case .pathNotFound: "Check the channel number in the camera's settings."
        case .noSuitableTrack: "Check that the camera is set to H.264 or H.265."
        default: nil
        }
    }

    var logMetadata: [String: String] {
        switch self {
        case .headerTooLarge(let bytes): ["bytes": String(bytes)]
        case .unexpectedStatus(let code): ["status": String(code)]
        case .sdpParse(let detail): ["detail": Redact.secrets(in: detail)]
        case .interleaveDesync(let recovered): ["recovered": recovered ? "true" : "false"]
        case .timeout(let id): ["timer": String(describing: id)]
        default: [:]
        }
    }
}

// MARK: - RTP

public extension RTPError {

    var diagnosticCode: String {
        switch self {
        case .shortPacket: "VG-RTP-0001"
        case .badVersion: "VG-RTP-0002"
        case .truncatedCSRC: "VG-RTP-0003"
        case .truncatedExtension: "VG-RTP-0004"
        case .badPaddingLength: "VG-RTP-0005"
        case .unknownPayloadType: "VG-RTP-0006"
        case .badFragment: "VG-RTP-0007"
        case .aggregationOverflow: "VG-RTP-0008"
        case .jitterBufferOverflow: "VG-RTP-0009"
        case .gap: "VG-RTP-0010"
        case .unsupportedEncoding: "VG-RTP-0011"
        case .missingRequiredFmtp: "VG-RTP-0012"
        case .unsupportedAACMode: "VG-RTP-0013"
        case .malformedAudioConfig: "VG-RTP-0014"
        case .invalidClockRate: "VG-RTP-0015"
        }
    }

    /// Packet-level faults are `degraded`: they are counted in `StreamStatistics` and never end a
    /// session. The five negotiation faults are `recoverable` because the stream cannot start
    /// at all until something about the negotiation changes.
    var severity: ErrorSeverity {
        switch self {
        case .unsupportedEncoding, .missingRequiredFmtp, .unsupportedAACMode,
             .malformedAudioConfig, .invalidClockRate: .recoverable
        default: .degraded
        }
    }

    var disposition: RetryDisposition {
        switch self {
        case .unsupportedEncoding, .missingRequiredFmtp, .unsupportedAACMode,
             .malformedAudioConfig, .invalidClockRate: .retryAfterUserAction
        default: .noRetry
        }
    }

    var userMessage: String {
        switch self {
        case .unsupportedEncoding: "This camera is streaming a format Vigil cannot play."
        case .missingRequiredFmtp: "The camera's stream description is missing required details."
        case .unsupportedAACMode: "This camera's audio format is not supported."
        case .malformedAudioConfig: "The camera's audio configuration could not be read."
        case .invalidClockRate: "The camera reported an impossible stream clock."
        default: "Some video packets were lost or damaged."
        }
    }

    var userRemedy: String? {
        switch self {
        case .unsupportedEncoding, .invalidClockRate:
            "Set the camera's video encoding to H.264 or H.265."
        case .missingRequiredFmtp:
            "Update the camera's firmware if this keeps happening."
        case .unsupportedAACMode, .malformedAudioConfig:
            "Set the camera's audio encoding to AAC or G.711."
        default:
            nil
        }
    }

    var logMetadata: [String: String] {
        switch self {
        case .shortPacket(let length): ["length": String(length)]
        case .badVersion(let version): ["version": String(version)]
        case .badPaddingLength(let padding): ["padding": String(padding)]
        case .unknownPayloadType(let type): ["payloadType": String(type)]
        case .jitterBufferOverflow(let dropped): ["dropped": String(dropped)]
        case .gap(let count): ["gap": String(count)]
        case .unsupportedEncoding(let encoding): ["encoding": encoding]
        case .missingRequiredFmtp(let key): ["fmtp": key]
        case .unsupportedAACMode(let mode): ["mode": mode]
        case .malformedAudioConfig(let detail): ["detail": Redact.secrets(in: detail)]
        case .invalidClockRate(let rate): ["clockRate": String(rate)]
        default: [:]
        }
    }
}

// MARK: - Bitstream

public extension BitstreamError {

    var diagnosticCode: String {
        switch self {
        case .emptyNALUnit: "VG-BITS-0001"
        case .tooLarge: "VG-BITS-0002"
        case .unexpectedEndOfData: "VG-BITS-0003"
        case .malformedExpGolomb: "VG-BITS-0004"
        case .valueOutOfRange: "VG-BITS-0005"
        case .wrongNALType: "VG-BITS-0006"
        case .forbiddenBitSet: "VG-BITS-0007"
        case .invalidTemporalID: "VG-BITS-0008"
        case .negativeSkip: "VG-BITS-0009"
        case .invalidCropping: "VG-BITS-0010"
        case .unsupportedSyntax: "VG-BITS-0011"
        case .unsupportedProfile: "VG-BITS-0012"
        case .unsupportedChromaFormat: "VG-BITS-0013"
        case .truncatedSEI: "VG-BITS-0014"
        case .truncatedLengthPrefix: "VG-BITS-0015"
        case .unsupportedRecordVersion: "VG-BITS-0016"
        case .unsupportedLengthSize: "VG-BITS-0017"
        case .invalidBase64: "VG-BITS-0018"
        case .noParameterSets: "VG-BITS-0019"
        }
    }

    var severity: ErrorSeverity { .recoverable }

    /// `.noParameterSets` is not a failure to retry — the next IRAP carries the parameter sets and
    /// the pipeline simply continues, which is the "one free attempt" shape.
    var disposition: RetryDisposition {
        switch self {
        case .noParameterSets: .retryImmediatelyOnce
        case .unsupportedProfile, .unsupportedChromaFormat, .unsupportedSyntax: .retryAfterUserAction
        default: .retryWithBackoff
        }
    }

    var userMessage: String {
        switch self {
        case .unsupportedProfile, .unsupportedChromaFormat:
            "This camera is using a video profile Vigil cannot decode."
        case .unsupportedSyntax:
            "This camera is using a video feature Vigil does not support."
        case .noParameterSets:
            "Waiting for the camera to send a keyframe."
        default:
            "The camera sent video Vigil could not decode."
        }
    }

    var userRemedy: String? {
        switch self {
        case .unsupportedProfile, .unsupportedChromaFormat, .unsupportedSyntax:
            "Set the camera's video profile to Main or High, 4:2:0, 8-bit."
        default:
            nil
        }
    }

    var logMetadata: [String: String] {
        switch self {
        case .tooLarge(let bytes): ["bytes": String(bytes)]
        case .unexpectedEndOfData(let bit): ["atBit": String(bit)]
        case .malformedExpGolomb(let zeros): ["leadingZeros": String(zeros)]
        case .valueOutOfRange(let field, let value): ["field": field, "value": String(value)]
        case .wrongNALType(let expected, let found):
            ["expected": String(expected), "found": String(found)]
        case .unsupportedSyntax(let detail): ["detail": detail]
        case .unsupportedProfile(let idc): ["profileIDC": String(idc)]
        case .unsupportedChromaFormat(let idc): ["chromaFormatIDC": String(idc)]
        case .truncatedLengthPrefix(let offset): ["offset": String(offset)]
        case .unsupportedRecordVersion(let version): ["version": String(version)]
        case .unsupportedLengthSize(let size): ["lengthSize": String(size)]
        default: [:]
        }
    }
}

// MARK: - ISAPI

public extension ISAPIError {

    var diagnosticCode: String {
        switch self {
        case .notConnected: "VG-ISAPI-0001"
        case .timedOut: "VG-ISAPI-0002"
        case .cancelled: "VG-ISAPI-0003"
        case .responseTooLarge: "VG-ISAPI-0004"
        case .http: "VG-ISAPI-0005"
        case .device: "VG-ISAPI-0006"
        case .rebootRequired: "VG-ISAPI-0007"
        case .malformedResponse: "VG-ISAPI-0008"
        case .unexpectedContentType: "VG-ISAPI-0009"
        case .multipartProtocolError: "VG-ISAPI-0010"
        case .streamEnded: "VG-ISAPI-0011"
        case .partTooLarge: "VG-ISAPI-0012"
        case .tlsUnavailableOnThisPlatform: "VG-ISAPI-0013"
        case .insufficientPermission: "VG-ISAPI-0403"
        case .notFound: "VG-ISAPI-0404"
        case .unsupportedAuthentication: "VG-ISAPI-0406"
        case .deviceBusy: "VG-ISAPI-0409"
        case .deviceNotActivated: "VG-ISAPI-0412"
        case .authenticationFailed: "VG-ISAPI-0401"
        case .accountLocked: "VG-ISAPI-0423"
        case .authBlockedLocally: "VG-ISAPI-0429"
        case .notSupported: "VG-ISAPI-0501"
        }
    }

    var severity: ErrorSeverity {
        switch self {
        case .accountLocked, .authenticationFailed, .authBlockedLocally,
             .deviceNotActivated, .insufficientPermission: .fatal
        case .cancelled: .degraded
        default: .recoverable
        }
    }

    /// `.authenticationFailed` and `.authBlockedLocally` are terminal by design. Hikvision
    /// firmware locks an account after a handful of failed logins, so an automatic retry with a
    /// password we already know is wrong costs the user access to their own camera (R-25).
    var disposition: RetryDisposition {
        switch self {
        case .accountLocked, .authenticationFailed, .authBlockedLocally, .deviceNotActivated,
             .insufficientPermission, .unsupportedAuthentication: .retryAfterUserAction
        case .notSupported, .notFound, .cancelled, .tlsUnavailableOnThisPlatform: .noRetry
        default: .retryWithBackoff
        }
    }

    var userMessage: String {
        switch self {
        case .notConnected: "Vigil is not connected to the camera."
        case .timedOut: "The camera did not answer in time."
        case .cancelled: "The request was cancelled."
        case .responseTooLarge: "The camera sent an unreasonably large reply."
        case .authenticationFailed: "The user name or password is incorrect."
        case .accountLocked: "The camera has locked this account after too many failed sign-ins."
        case .authBlockedLocally: "Vigil stopped signing in to avoid locking your camera account."
        case .unsupportedAuthentication: "This camera uses a sign-in method Vigil does not support."
        case .insufficientPermission: "This account does not have permission for that."
        case .deviceNotActivated: "This camera has not been set up yet."
        case .http: "The camera reported an error."
        case .device: "The camera rejected the request."
        case .notSupported: "This camera does not support that feature."
        case .notFound: "That setting does not exist on this camera."
        case .deviceBusy: "The camera is busy."
        case .rebootRequired: "The camera needs to restart before that takes effect."
        case .malformedResponse: "The camera sent a reply Vigil could not read."
        case .unexpectedContentType: "The camera sent an unexpected kind of reply."
        case .multipartProtocolError: "The camera's event stream is malformed."
        case .streamEnded: "The camera's event stream ended."
        case .partTooLarge: "The camera sent an unreasonably large event."
        case .tlsUnavailableOnThisPlatform: "Secure connections are unavailable in this build."
        }
    }

    var userRemedy: String? {
        switch self {
        case .authenticationFailed: "Enter the camera's user name and password again."
        case .accountLocked: "Wait for the camera to unlock the account, or reset it on the device."
        case .authBlockedLocally: "Correct the saved password, then try again."
        case .insufficientPermission: "Use an account with the right permissions."
        case .deviceNotActivated: "Set an admin password on the camera first."
        case .unsupportedAuthentication: "Enable Digest authentication in the camera's settings."
        case .rebootRequired: "Restart the camera to apply the change."
        default: nil
        }
    }

    var logMetadata: [String: String] {
        switch self {
        case .notConnected(let what): ["resource": what]
        case .timedOut(let resource, let seconds): ["resource": resource,
                                                   "seconds": String(seconds)]
        case .responseTooLarge(let bytes): ["bytes": String(bytes)]
        case .authenticationFailed(let username): ["username": username]
        case .accountLocked(let after): ["retryAfter": after.map { String($0) } ?? "unknown"]
        case .authBlockedLocally(let failures): ["failures": String(failures)]
        case .unsupportedAuthentication(let scheme): ["scheme": scheme]
        case .insufficientPermission(let resource): ["resource": resource]
        case .http(let status, let resource): ["status": String(status), "resource": resource]
        case .device(let code, let sub): ["deviceStatus": String(code), "sub": sub ?? ""]
        case .notSupported(let resource): ["resource": resource]
        case .notFound(let resource): ["resource": resource]
        case .malformedResponse(let detail): ["detail": Redact.secrets(in: detail)]
        case .unexpectedContentType(let expected, let got):
            ["expected": expected, "got": got ?? ""]
        case .multipartProtocolError(let detail): ["detail": Redact.secrets(in: detail)]
        case .streamEnded(let bytes): ["afterBytes": String(bytes)]
        case .partTooLarge(let bytes, let limit): ["bytes": String(bytes), "limit": String(limit)]
        default: [:]
        }
    }
}

// MARK: - Discovery

public extension DiscoveryError {

    var diagnosticCode: String {
        switch self {
        case .interfaceEnumerationFailed: "VG-DISC-0001"
        case .noEligibleInterfaces: "VG-DISC-0002"
        case .arpReadFailed: "VG-DISC-0003"
        case .multicastUnavailable: "VG-DISC-0004"
        case .channelBindFailed: "VG-DISC-0005"
        case .prefixTooWide: "VG-DISC-0006"
        case .probeSendFailed: "VG-DISC-0007"
        case .budgetExhausted: "VG-DISC-0008"
        case .cancelled: "VG-DISC-0009"
        }
    }

    var severity: ErrorSeverity {
        switch self {
        case .cancelled: .degraded
        default: .recoverable
        }
    }

    var disposition: RetryDisposition {
        switch self {
        case .multicastUnavailable, .cancelled, .budgetExhausted, .prefixTooWide: .noRetry
        default: .retryWithBackoff
        }
    }

    var userMessage: String {
        switch self {
        case .interfaceEnumerationFailed: "Vigil could not read this Mac's network interfaces."
        case .noEligibleInterfaces: "No usable network connection was found."
        case .arpReadFailed: "Vigil could not read the network's address table."
        case .multicastUnavailable: "Vigil could not search by broadcast, so it scanned instead."
        case .channelBindFailed: "Vigil could not open a network port for searching."
        case .prefixTooWide: "That network is too large to scan."
        case .probeSendFailed: "The search message could not be sent."
        case .budgetExhausted: "The search stopped early to stay gentle on the network."
        case .cancelled: "The search was stopped."
        }
    }

    var userRemedy: String? {
        switch self {
        case .noEligibleInterfaces: "Connect to a network and try again."
        case .prefixTooWide: "Search a smaller range, or add the camera by address."
        case .multicastUnavailable: "Add the camera by address if it is not found."
        case .channelBindFailed: "Quit other apps that may be using the same port."
        default: nil
        }
    }

    var logMetadata: [String: String] {
        switch self {
        case .interfaceEnumerationFailed(let code): ["errno": String(code)]
        case .arpReadFailed(let code): ["errno": String(code)]
        case .multicastUnavailable(let reason): ["reason": reason.rawValue]
        case .channelBindFailed(let port, let detail): ["port": String(port), "detail": detail]
        case .prefixTooWide(let bits, let hosts): ["bits": String(bits), "hosts": String(hosts)]
        case .budgetExhausted(let kind): ["budget": kind.rawValue]
        default: [:]
        }
    }
}
