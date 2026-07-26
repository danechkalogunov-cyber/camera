//
//  StreamError.swift
//  VigilCore
//
//  Why a stream stopped, in the vocabulary the UI and the Stream Doctor share, plus the mapping
//  from the protocol layers' errors onto it.
//  Implements docs/spec-core.md §7.10 and docs/API_CONTRACT.md §4.8 / §5.12
//  (`Streaming/StreamError.swift`).
//
//  The one rule this file encodes: `isUserFixable` decides whether the reconnect ladder runs at
//  all. Authentication, a closed port, an unsupported codec and a missing password are **not**
//  retried on any schedule — retrying a rejected password is how an account gets locked
//  (API_CONTRACT §2 R-25), and retrying a closed port looks to the user like a hang.
//

#if os(macOS)

import Foundation
import VigilProtocols
import VigilRTSP

// MARK: - StreamError

/// A stream failure, with enough context to diagnose it from one log line.
///
/// `context` is pre-redacted by the constructor's callers and is safe to write to a log or a
/// diagnostics bundle verbatim.
public struct StreamError: Error, Sendable, Hashable {

    /// The taxonomy entry. Every case maps to one Stream Doctor row (spec-core §13.2).
    public var code: Code

    /// The underlying error's description, when there was one. Never a password, never a URL with
    /// userinfo — `RTSPURL` cannot serialise credentials, which is what makes this safe.
    public var underlyingDescription: String?

    /// The RTSP status that produced this, when one did. `401`, `404`, `461`, `454`.
    public var rtspStatus: Int?

    /// Extra key/values for logs and the diagnostics bundle. Pre-redacted.
    public var context: [String: String]

    /// Builds an error.
    public init(code: Code,
                underlyingDescription: String? = nil,
                rtspStatus: Int? = nil,
                context: [String: String] = [:]) {
        self.code = code
        self.underlyingDescription = underlyingDescription
        self.rtspStatus = rtspStatus
        self.context = context
    }

    /// True when only the user can fix this, which also means Vigil must not retry it.
    public var isUserFixable: Bool { code.isUserFixable }

    /// One sentence for the tile's status line.
    public var message: String { code.message }

    /// One imperative sentence telling the user what to do.
    public var fix: String { code.fix }

    /// Whether Stream Doctor offers itself for this failure. Same set as `isUserFixable`.
    public var doctorEntryPoint: Bool { code.isUserFixable }

    // MARK: Code

    /// The failure taxonomy. Adding a case without adding its Stream Doctor row is a defect the
    /// doctor's own test catches (spec-core §17.9).
    public enum Code: String, Sendable, Hashable, Codable, CaseIterable {

        // Fatal and user-fixable — go straight to `.failed`, never onto the ladder.

        /// No password is stored for this camera.
        case credentialsMissing
        /// The device rejected the password. **Terminal, always** (API_CONTRACT §2 R-25).
        case authenticationFailed
        /// The account exists but lacks the RTSP privilege (`403`).
        case accessForbidden
        /// The device reports the account as locked out.
        case accountLocked
        /// The RTSP port refused the connection.
        case portClosed
        /// Every path candidate answered `404`/`455`.
        case rtspPathNotFound
        /// The SDP offered no track Vigil can decode.
        case unsupportedMedia
        /// The device refused every transport Vigil can speak.
        case transportUnsupported
        /// The TLS handshake failed and downgrading silently is not on offer.
        case tlsHandshakeFailed
        /// The Keychain could not be read.
        case keychainUnavailable
        /// SADP reports the camera has no password set yet.
        case deviceNotActivated
        /// The device is not a Hikvision device and needs the ONVIF path.
        case notHikvision
        /// No decoder on this machine for the codec the device sends.
        case decodeUnsupported
        /// The decode budget refused this stream.
        case budgetExhausted

        // Transient — the reconnect ladder handles these.

        /// DNS or mDNS could not resolve the host.
        case hostResolutionFailed
        /// The TCP connect did not complete in time.
        case connectTimeout
        /// The authentication round trip did not complete in time.
        case authTimeout
        /// `DESCRIBE` went unanswered.
        case describeTimeout
        /// `SETUP` went unanswered.
        case setupTimeout
        /// `PLAY` went unanswered.
        case playTimeout
        /// `PLAY` was answered with a failure status.
        case playFailed
        /// No RTP arrived after a successful `PLAY`.
        case noMediaReceived
        /// RTP arrived but no keyframe did.
        case noKeyframe
        /// Media stopped arriving on a playing session.
        case mediaStalled
        /// The keepalive went unanswered.
        case keepaliveTimeout
        /// The peer closed the connection. A camera reboot lands here.
        case connectionClosed
        /// `454 Session Not Found` — the device forgot the session, usually after a reboot.
        case sessionLost
        /// The network path went away.
        case networkUnavailable
        /// The stream stayed degraded long enough to be worth one reconnect.
        case persistentDegradation
        /// A socket-level failure that is none of the above.
        case transportError
        /// The peer violated the protocol in a way the session cannot continue through.
        case protocolViolation

        /// True for the failures only the user can clear. **This is the retry gate.**
        public var isUserFixable: Bool {
            switch self {
            case .credentialsMissing, .authenticationFailed, .accessForbidden, .accountLocked,
                 .portClosed, .rtspPathNotFound, .unsupportedMedia, .transportUnsupported,
                 .tlsHandshakeFailed, .keychainUnavailable, .deviceNotActivated, .notHikvision,
                 .decodeUnsupported, .budgetExhausted:
                true
            default:
                false
            }
        }

        /// True for the failures that must never be retried automatically, on any schedule,
        /// including the five-minute cold retry: every one of them would spend an authentication
        /// attempt against a device that locks accounts.
        public var forbidsColdRetry: Bool {
            switch self {
            case .authenticationFailed, .accessForbidden, .accountLocked, .credentialsMissing:
                true
            default:
                false
            }
        }

        /// One sentence for the status line. Sentence case, no error numbers, no jargon.
        public var message: String {
            switch self {
            case .credentialsMissing: "No password saved for this camera."
            case .authenticationFailed: "The camera rejected the password."
            case .accessForbidden: "This account is not allowed to view the stream."
            case .accountLocked: "The camera has locked this account."
            case .portClosed: "The camera refused the streaming connection."
            case .rtspPathNotFound: "The camera has no stream at any address Vigil knows."
            case .unsupportedMedia: "The camera offers no video Vigil can play."
            case .transportUnsupported: "The camera refused every way of sending video."
            case .tlsHandshakeFailed: "The secure connection to the camera failed."
            case .keychainUnavailable: "Vigil could not read the saved password."
            case .deviceNotActivated: "This camera has not been given a password yet."
            case .notHikvision: "This device is not a Hikvision camera."
            case .decodeUnsupported: "This Mac cannot decode the camera's video format."
            case .budgetExhausted: "Too many cameras are decoding at once."
            case .hostResolutionFailed: "Vigil could not find the camera on the network."
            case .connectTimeout: "The camera did not answer in time."
            case .authTimeout: "The camera stopped responding while signing in."
            case .describeTimeout: "The camera stopped responding while describing its stream."
            case .setupTimeout: "The camera stopped responding while starting the stream."
            case .playTimeout: "The camera did not start playing in time."
            case .playFailed: "The camera refused to start the stream."
            case .noMediaReceived: "The stream started but no video arrived."
            case .noKeyframe: "Video is arriving but no full picture has yet."
            case .mediaStalled: "The video stopped arriving."
            case .keepaliveTimeout: "The camera stopped answering keepalives."
            case .connectionClosed: "The camera closed the connection."
            case .sessionLost: "The camera forgot the session."
            case .networkUnavailable: "This Mac has no network connection."
            case .persistentDegradation: "The stream has been unreliable for a while."
            case .transportError: "The network connection to the camera failed."
            case .protocolViolation: "The camera sent something Vigil could not follow."
            }
        }

        /// One imperative sentence: what the user should do now.
        public var fix: String {
            switch self {
            case .credentialsMissing: "Enter the camera's password."
            case .authenticationFailed: "Check the password and enter it again."
            case .accessForbidden: "Give this account live-view rights in the camera's settings."
            case .accountLocked: "Wait for the camera to unlock the account, or reboot it."
            case .portClosed: "Turn RTSP on in the camera's network settings, or check a firewall."
            case .rtspPathNotFound: "Run Stream Doctor so Vigil can look for the stream again."
            case .unsupportedMedia: "Set the camera to H.264 or H.265 in its encoding settings."
            case .transportUnsupported: "Enable RTP over TCP in the camera's network settings."
            case .tlsHandshakeFailed: "Check the camera's certificate, or turn HTTPS off for it."
            case .keychainUnavailable: "Unlock your login keychain, then reconnect."
            case .deviceNotActivated: "Set a password on the camera, then add it again."
            case .notHikvision: "Add this device over ONVIF instead."
            case .decodeUnsupported: "Set the camera to H.264 in its encoding settings."
            case .budgetExhausted: "Close some tiles, or lower their quality."
            default: "Vigil is retrying on its own."
            }
        }
    }
}

// MARK: - Mapping from the protocol layers

public extension StreamError {

    /// Maps an `RTSPError` from the session machine onto the stream taxonomy.
    ///
    /// The auth cases are the load-bearing ones: `.authRejected`, `.unauthorized` and
    /// `.credentialsMissing` must all land on codes whose `isUserFixable` is true, because that is
    /// what stops the reconnect ladder before it locks the account.
    static func from(_ error: RTSPError, context: [String: String] = [:]) -> StreamError {
        let code: Code
        var status: Int?
        switch error {
        case .authRejected, .unauthorized:
            code = .authenticationFailed
            status = 401
        case .credentialsMissing:
            code = .credentialsMissing
            status = 401
        case .accessForbidden:
            code = .accessForbidden
            status = 403
        case .pathNotFound:
            code = .rtspPathNotFound
            status = 404
        case .noSuitableTrack, .sdpParse:
            code = .unsupportedMedia
        case .transportRejected:
            code = .transportUnsupported
            status = 461
        case .sessionNotFound:
            code = .sessionLost
            status = 454
        case .methodNotSupported:
            code = .protocolViolation
            status = 405
        case .malformedResponse, .headerTooLarge, .interleaveDesync, .commandQueueOverflow,
             .tooManyRedirects:
            code = .protocolViolation
        case let .unexpectedStatus(statusCode):
            code = .protocolViolation
            status = statusCode
        case let .timeout(timer):
            code = Self.code(forTimeout: timer)
        }
        return StreamError(code: code, underlyingDescription: error.diagnosticCode,
                           rtspStatus: status, context: context)
    }

    /// Maps a transport failure. `.connectRefused` is deliberately **not** retryable: a closed port
    /// does not open by being asked again, and the ladder would hide the real problem behind a
    /// permanent spinner (spec-core §7.6 rule 5).
    static func from(_ error: TransportError, context: [String: String] = [:]) -> StreamError {
        let code: Code = switch error {
        case .connectTimeout: .connectTimeout
        case .connectRefused: .portClosed
        case .hostUnreachable: .hostResolutionFailed
        case .peerClosed: .connectionClosed
        case .readIdleTimeout: .mediaStalled
        case .tlsFailed, .tlsUntrusted, .tlsPinMismatch: .tlsHandshakeFailed
        case .multicastBlocked, .localNetworkDenied: .networkUnavailable
        case .egressBlocked: .networkUnavailable
        case .network: .transportError
        }
        return StreamError(code: code, underlyingDescription: error.diagnosticCode,
                           context: context)
    }

    /// Maps a Keychain failure. Everything here is user-fixable and none of it is retried.
    static func from(_ error: CredentialError, context: [String: String] = [:]) -> StreamError {
        let code: Code = switch error {
        case .notFound: .credentialsMissing
        default: .keychainUnavailable
        }
        return StreamError(code: code, underlyingDescription: error.diagnosticCode,
                           context: context)
    }

    /// Which timeout produced a `RTSPError.timeout`.
    private static func code(forTimeout timer: RTSPTimerID) -> Code {
        switch timer {
        case .requestTimeout: .connectTimeout
        case .keepalive: .keepaliveTimeout
        case .firstMediaTimeout: .noMediaReceived
        case .dataIdle: .mediaStalled
        case .sessionExpiry: .sessionLost
        case .teardownGrace: .connectionClosed
        }
    }
}

#endif
