//
//  ConnectDiagnosisMapping.swift
//  Vigil
//
//  Turns a `VigilCore.StreamError` into the named cause `VigilUI` shows. The app owns this map
//  because it is the only module that sees both types.
//  macOS-only. See docs/REQUIREMENTS-CUSTOMER.md §R1.5, docs/UX.md §8.4 and API_CONTRACT §4.8.
//

#if os(macOS)

import Foundation

import VigilCore
import VigilProtocols
import VigilUI

// MARK: - StreamError → ConnectDiagnosis

extension ConnectDiagnosis {

    /// The named cause for a stream failure, in the vocabulary the connect screen renders.
    ///
    /// R1.5 requires every failure to resolve to a named cause with a concrete next action. The
    /// full mapping is Stream Doctor's job in W4 — it runs thirteen probes and can tell "no route
    /// to the host" from "RTSP is switched off" — so what this does is narrower and says so: it
    /// maps the codes whose meaning is unambiguous, and sends everything else to
    /// ``ConnectDiagnosis/undiagnosed(host:detail:)``, which still names a cause in plain words,
    /// still offers an action, and puts the device's own words behind a disclosure.
    ///
    /// - Parameters:
    ///   - error: the controller's failure.
    ///   - camera: the camera it was connecting to, for the host and ports the copy interpolates.
    static func from(_ error: StreamError, camera: Camera) -> ConnectDiagnosis {
        let host = camera.host
        switch error.code {
        case .authenticationFailed, .credentialsMissing:
            // `credentialsMissing` lands here on purpose: the remedy — put the cursor in the
            // password field — is the same, and "no password saved" is not a sentence a user who
            // just typed one would believe.
            return .wrongPassword(host: host)
        case .accountLocked:
            return .accountLocked(host: host, minutesRemaining: Self.minutes(in: error))
        case .signInPaused:
            // Vigil's own rate limit, not the device's verdict. The countdown comes from
            // `context["retryAfterSeconds"]`, which `StreamController.resolvePath` computes from
            // `LockoutGovernor.probeWindow` — a number we control — and never from a guess at the
            // firmware's lock window (docs/RULING-LOCKOUT.md §3, §7).
            return .signInPausedByVigil(host: host, minutesRemaining: Self.pauseMinutes(in: error))
        case .deviceNotActivated:
            return .cameraNotActivated(host: host)
        case .portClosed, .transportUnsupported:
            return .rtspPortClosed(host: host, httpPort: camera.httpPort, rtspPort: camera.rtspPort)
        case .notHikvision:
            return .notHikvisionDevice(host: host)
        case .unsupportedMedia, .decodeUnsupported:
            return .codecUnsupported(host: host, codec: Self.codec(in: error))
        case .hostResolutionFailed, .connectTimeout, .networkUnavailable:
            return .notOnThisNetwork(host: host)
        case .noMediaReceived:
            return .noPictureUDPBlocked(host: host)
        case .noKeyframe, .mediaStalled:
            return .pictureStalls(host: host)
        default:
            // Everything the slice cannot distinguish: the cause sentence and the remedy the error
            // already carries, kept verbatim so support sees exactly what the device said.
            return .undiagnosed(host: host, detail: "\(error.message) \(error.fix)")
        }
    }

    // MARK: - Private Helpers

    /// The lock-out duration the device reported, if it reported one.
    ///
    /// Hikvision returns the remaining time in the ISAPI body for `userLocked`; the controller puts
    /// it in the error's context. An absent or unparseable value means "it does not say", which the
    /// copy handles with its own sentence.
    private static func minutes(in error: StreamError) -> Int? {
        guard let raw = error.context["lockoutMinutes"] else { return nil }
        return Int(raw)
    }

    /// Whole minutes of Vigil's own wait, rounded up and never below one.
    ///
    /// Rounded **up** so the copy never promises a retry sooner than it will happen, and clamped to at
    /// least one because "in about 0 minutes" reads as a bug. A missing or unparseable value falls
    /// back to the whole probe window, which is the longest the wait can be.
    private static func pauseMinutes(in error: StreamError) -> Int {
        guard let raw = error.context["retryAfterSeconds"], let seconds = Int(raw), seconds > 0 else {
            return Int((LockoutGovernor.probeWindow.seconds / 60).rounded(.up))
        }
        return max(1, Int((Double(seconds) / 60).rounded(.up)))
    }

    /// The codec the camera offered, for the "Unsupported video format" sentence.
    ///
    /// Falls back to a phrase rather than to an empty string, because the sentence reads
    /// "This camera streams \(codec)." and an empty interpolation would produce a broken line.
    private static func codec(in error: StreamError) -> String {
        error.context["codec"] ?? "a format Vigil does not recognise"
    }
}

#endif  // os(macOS)
