//
//  DiagnosticCodes+Media.swift
//  VigilProtocols
//
//  The diagnostic codes for the layers above the wire: decode, render, storage, credentials
//  and recording. The wire's own — transport, RTSP, RTP, bitstream, ISAPI, discovery — are in
//  DiagnosticCodes.swift.
//
//  ⛔ Never renumber a case and never reuse a retired number, here or there: these strings
//  reach users through Stream Doctor's "copy details" and are quoted in support requests.
//



// MARK: - Decode

public extension DecodeError {

    var diagnosticCode: String {
        switch self {
        case .vt: "VG-DEC-0001"
        case .badData: "VG-DEC-0011"                // fixed by ARCHITECTURE.md §7.3
        case .invalidSession: "VG-DEC-0012"
        case .malfunction: "VG-DEC-0013"
        case .formatChangeUnsupported: "VG-DEC-0014"
        case .noHardwareDecoder: "VG-DEC-0015"
        case .budgetDenied: "VG-DEC-0016"
        case .missingParameterSets: "VG-DEC-0017"
        case .emptyParameterSet: "VG-DEC-0018"
        case .tooManyParameterSets: "VG-DEC-0019"
        case .formatDescriptionFailed: "VG-DEC-0020"
        case .blockBufferFailed: "VG-DEC-0021"
        case .sampleBufferFailed: "VG-DEC-0022"
        case .pixelBufferPoolFailed: "VG-DEC-0023"
        case .unsupportedFormat: "VG-DEC-0024"
        }
    }

    var severity: ErrorSeverity {
        switch self {
        case .noHardwareDecoder: .degraded
        default: .recoverable
        }
    }

    /// `.badData` deliberately does **not** restart the session: the decoder recovers at the next
    /// keyframe, and tearing the session down would turn one corrupt packet into a visible stall.
    var disposition: RetryDisposition {
        switch self {
        case .badData, .invalidSession, .malfunction, .formatChangeUnsupported,
             .missingParameterSets: .retryImmediatelyOnce
        case .noHardwareDecoder: .noRetry
        case .unsupportedFormat: .retryAfterUserAction
        default: .retryWithBackoff
        }
    }

    var userMessage: String {
        switch self {
        case .noHardwareDecoder: "This Mac has no hardware decoder for this camera's video."
        case .unsupportedFormat: "This camera's video format is not supported."
        case .budgetDenied: "There is not enough decoding capacity for another camera."
        case .missingParameterSets: "Waiting for the camera to send a keyframe."
        default: "The video could not be decoded."
        }
    }

    var userRemedy: String? {
        switch self {
        case .noHardwareDecoder, .unsupportedFormat:
            "Set the camera to H.264, 8-bit, 4:2:0."
        case .budgetDenied:
            "Close some tiles, or lower the stream quality."
        default:
            nil
        }
    }

    var logMetadata: [String: String] {
        switch self {
        case .vt(let status): ["osstatus": String(status)]
        case .budgetDenied(let reason): ["reason": reason.rawValue]
        case .emptyParameterSet(let index): ["index": String(index)]
        case .tooManyParameterSets(let count): ["count": String(count)]
        case .formatDescriptionFailed(let status): ["osstatus": String(status)]
        case .blockBufferFailed(let status): ["osstatus": String(status)]
        case .sampleBufferFailed(let status): ["osstatus": String(status)]
        case .pixelBufferPoolFailed(let status): ["osstatus": String(status)]
        case .unsupportedFormat(let codec, let detail):
            ["codec": codec.rawValue, "detail": detail]
        default: [:]
        }
    }
}

// MARK: - Render

public extension RenderError {

    var diagnosticCode: String {
        switch self {
        case .metalUnavailable: "VG-RND-0001"
        case .shaderCompilationFailed: "VG-RND-0002"
        case .pipelineCompileFailed: "VG-RND-0003"
        case .textureCacheFailed: "VG-RND-0004"
        case .textureCreationFailed: "VG-RND-0005"
        case .drawableUnavailable: "VG-RND-0006"
        case .commandBufferFailed: "VG-RND-0007"
        case .deviceRemoved: "VG-RND-0008"
        case .unsupportedPixelFormat: "VG-RND-0009"
        case .captureFailed: "VG-RND-0010"
        case .atlasTooLarge: "VG-RND-0011"
        }
    }

    var severity: ErrorSeverity {
        switch self {
        case .metalUnavailable: .degraded
        default: .recoverable
        }
    }

    var disposition: RetryDisposition { .noRetry }

    var userMessage: String {
        switch self {
        case .metalUnavailable: "Vigil is drawing video without GPU acceleration."
        case .deviceRemoved: "The graphics device was disconnected."
        case .captureFailed: "The snapshot could not be taken."
        case .atlasTooLarge: "This video wall is larger than the graphics card allows."
        default: "Vigil could not draw the video."
        }
    }

    var userRemedy: String? {
        switch self {
        case .deviceRemoved: "Reconnect the display or restart Vigil."
        case .atlasTooLarge: "Use fewer or smaller tiles on this display."
        default: nil
        }
    }

    var logMetadata: [String: String] {
        switch self {
        case .shaderCompilationFailed(let detail): ["detail": detail]
        case .pipelineCompileFailed(let detail): ["detail": detail]
        case .textureCacheFailed(let status): ["osstatus": String(status)]
        case .commandBufferFailed(let code, let detail):
            ["code": String(code), "detail": detail]
        case .unsupportedPixelFormat(let format): ["pixelFormat": String(format)]
        case .captureFailed(let detail): ["detail": Redact.secrets(in: detail)]
        case .atlasTooLarge(let requested, let max):
            ["requested": requested.description, "max": String(max)]
        default: [:]
        }
    }
}

// MARK: - Storage

public extension StorageError {

    var diagnosticCode: String {
        switch self {
        case .notWritable: "VG-STOR-0001"
        case .corruptDocument: "VG-STOR-0002"       // fixed by ARCHITECTURE.md §7.3
        case .schemaTooNew: "VG-STOR-0003"
        case .missingMigration: "VG-STOR-0004"
        case .notAnObject: "VG-STOR-0005"
        case .diskFull: "VG-STOR-0006"
        case .atomicReplaceFailed: "VG-STOR-0007"
        case .documentTooLarge: "VG-STOR-0008"
        }
    }

    var severity: ErrorSeverity {
        switch self {
        case .schemaTooNew: .fatal
        default: .recoverable
        }
    }

    var disposition: RetryDisposition { .retryAfterUserAction }

    var userMessage: String {
        switch self {
        case .notWritable: "Vigil cannot write to its library folder."
        case .corruptDocument: "Vigil's library file is damaged."
        case .schemaTooNew: "This library was saved by a newer version of Vigil."
        case .missingMigration: "Vigil cannot upgrade this library."
        case .notAnObject: "Vigil's library file is not in the expected format."
        case .diskFull: "The disk is full."
        case .atomicReplaceFailed: "Vigil could not save its library."
        case .documentTooLarge: "Vigil's library file is unexpectedly large."
        }
    }

    var userRemedy: String? {
        switch self {
        case .notWritable, .atomicReplaceFailed: "Check the permissions on Vigil's library folder."
        case .corruptDocument, .notAnObject, .missingMigration: "Restore the library from a backup."
        case .schemaTooNew: "Update Vigil to open this library."
        case .diskFull: "Free up disk space and try again."
        case .documentTooLarge: nil
        }
    }

    var logMetadata: [String: String] {
        switch self {
        case .notWritable(let path): ["path": Redact.path(path)]
        case .corruptDocument(let detail): ["detail": Redact.secrets(in: detail)]
        case .schemaTooNew(let found, let supported):
            ["found": String(found), "supported": String(supported)]
        case .missingMigration(let from): ["from": String(from)]
        case .diskFull(let need): ["needBytes": String(need)]
        case .documentTooLarge(let bytes): ["bytes": String(bytes)]
        default: [:]
        }
    }
}

// MARK: - Credential

public extension CredentialError {

    var diagnosticCode: String {
        switch self {
        case .keychainStatus: "VG-CRED-0001"
        case .notFound: "VG-CRED-0002"
        case .duplicate: "VG-CRED-0003"
        case .userCancelledUnlock: "VG-CRED-0004"
        case .keychainLocked: "VG-CRED-0005"
        case .missingEntitlement: "VG-CRED-0006"
        case .decodeFailed: "VG-CRED-0007"
        }
    }

    var severity: ErrorSeverity { .recoverable }

    var disposition: RetryDisposition { .retryAfterUserAction }

    var userMessage: String {
        switch self {
        case .keychainStatus: "The keychain could not be read."
        case .notFound: "No saved password was found for this camera."
        case .duplicate: "A password is already saved for this camera."
        case .userCancelledUnlock: "The keychain was not unlocked."
        case .keychainLocked: "The keychain is locked."
        case .missingEntitlement: "Vigil is not allowed to use the keychain."
        case .decodeFailed: "The saved password could not be read."
        }
    }

    var userRemedy: String? {
        switch self {
        case .notFound, .decodeFailed: "Enter the camera's password again."
        case .userCancelledUnlock, .keychainLocked: "Unlock your keychain and try again."
        case .duplicate: nil
        case .missingEntitlement: "Reinstall Vigil."
        case .keychainStatus: "Try again, or re-enter the camera's password."
        }
    }

    var logMetadata: [String: String] {
        switch self {
        // Never the password, never the account: only the status and what was attempted.
        case .keychainStatus(let status, let operation):
            ["osstatus": String(status), "operation": operation]
        default: [:]
        }
    }
}

// MARK: - Recording

public extension RecordingError {

    var diagnosticCode: String {
        switch self {
        case .firstSampleNotKeyframe: "VG-REC-0001"
        case .writerFailed: "VG-REC-0002"
        case .destinationUnwritable: "VG-REC-0003"
        case .spaceBelowReserve: "VG-REC-0004"
        case .folderUnavailable: "VG-REC-0005"
        case .formatChangedMidClip: "VG-REC-0006"
        }
    }

    var severity: ErrorSeverity { .recoverable }

    var disposition: RetryDisposition { .retryAfterUserAction }

    var userMessage: String {
        switch self {
        case .firstSampleNotKeyframe: "Recording could not start on this frame."
        case .writerFailed: "Recording stopped because the file could not be written."
        case .destinationUnwritable: "Vigil cannot write to the recordings folder."
        case .spaceBelowReserve: "Recording stopped because the disk is nearly full."
        case .folderUnavailable: "The recordings folder is unavailable."
        case .formatChangedMidClip: "Recording stopped because the video format changed."
        }
    }

    var userRemedy: String? {
        switch self {
        case .destinationUnwritable, .folderUnavailable: "Choose a different recordings folder."
        case .spaceBelowReserve: "Free up disk space and start recording again."
        case .firstSampleNotKeyframe, .formatChangedMidClip: "Start recording again."
        case .writerFailed: nil
        }
    }

    var logMetadata: [String: String] {
        switch self {
        case .writerFailed(let detail): ["detail": Redact.secrets(in: detail)]
        case .destinationUnwritable(let path): ["path": Redact.path(path)]
        case .spaceBelowReserve(let free): ["freeBytes": String(free)]
        default: [:]
        }
    }
}
