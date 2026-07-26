//
//  VigilError.swift
//  VigilProtocols
//
//  The root error type, the protocol every Vigil error answers to, and the throwing
//  replacement for `precondition`.
//
//  Implements docs/API_CONTRACT.md §3.9 (rulings R-10, R-11).
//

// MARK: - The protocol

/// Everything an error must be able to tell us: how to log it, what to show a human, and whether
/// to retry. `VigilErrorDescribing` does not exist (API_CONTRACT §2 R-11).
public protocol VigilFailure: Error, Sendable {
    /// Stable machine code, `VG-<DOMAIN>-NNNN`. Appears in logs, the diagnostics bundle and the
    /// Stream Doctor's "copy details". **Stable forever; never reuse a retired code.**
    var diagnosticCode: String { get }
    var severity: ErrorSeverity { get }
    var disposition: RetryDisposition { get }
    /// One sentence, sentence case, no jargon, no error numbers. Localised.
    var userMessage: String { get }
    /// One imperative sentence telling the user what to do, or `nil` if there is nothing to do.
    var userRemedy: String? { get }
    /// Extra key/values for the log line. MUST already be redacted.
    var logMetadata: [String: String] { get }
}

public extension VigilFailure {
    /// Most errors carry no structured context beyond their code. Domains that do — a host, a
    /// status code, a byte count — override this and are responsible for redacting first.
    var logMetadata: [String: String] { [:] }

    /// True when Vigil may retry on its own. `retryAfterUserAction` and `noRetry` are terminal:
    /// nothing changes until the user does something, and hammering the device makes it worse —
    /// a repeated 401 locks the account on Hikvision firmware (API_CONTRACT §2 R-25).
    var isAutomaticallyRetryable: Bool {
        switch disposition {
        case .retryWithBackoff, .retryImmediatelyOnce: true
        case .retryAfterUserAction, .noRetry: false
        }
    }
}

public enum ErrorSeverity: Int, Sendable, Hashable, Codable, Comparable {
    /// The stream is still usable; something is worse than it should be.
    case degraded
    /// This attempt failed; another attempt may work.
    case recoverable
    /// This will not work again without a change outside Vigil.
    case fatal

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum RetryDisposition: Sendable, Hashable, Codable {
    /// Transient: network blip, timeout, camera reboot. Uses the 0.5/1/2/4/8/15/30 s ladder.
    case retryWithBackoff
    /// Stale Digest nonce, 401 with a new nonce, `kVTInvalidSessionErr`. One free retry.
    case retryImmediatelyOnce
    /// Wrong password, camera not activated, unsupported codec. **Never auto-retry.**
    case retryAfterUserAction
    /// Programmer error, unsupported OS feature.
    case noRetry
}

// MARK: - The root error

/// The root error. Every domain enum it wraps is declared in `VigilProtocols` too — otherwise
/// `VigilProtocols` would have to import `VigilRTSP`, which imports `VigilProtocols`, and nothing
/// would build (API_CONTRACT §2 R-10).
public enum VigilError: Error, Sendable, Hashable, VigilFailure {
    case transport(TransportError)
    case rtsp(RTSPError)
    case rtp(RTPError)
    case bitstream(BitstreamError)
    case isapi(ISAPIError)
    case discovery(DiscoveryError)
    case decode(DecodeError)
    case render(RenderError)
    case storage(StorageError)
    case credential(CredentialError)
    case recording(RecordingError)
    case cancelled
    case internalInvariant(String, file: StaticString, line: UInt)
}

// MARK: - Root error behaviour

public extension VigilError {

    /// The wrapped domain error, or `nil` for `.cancelled` and `.internalInvariant`.
    ///
    /// Retry decisions switch on this, which is why the root type is an enum of concrete cases and
    /// not a box around `any VigilFailure` (API_CONTRACT §2 R-10).
    var cause: (any VigilFailure)? {
        switch self {
        case .transport(let e): e
        case .rtsp(let e): e
        case .rtp(let e): e
        case .bitstream(let e): e
        case .isapi(let e): e
        case .discovery(let e): e
        case .decode(let e): e
        case .render(let e): e
        case .storage(let e): e
        case .credential(let e): e
        case .recording(let e): e
        case .cancelled, .internalInvariant: nil
        }
    }

    var diagnosticCode: String {
        switch self {
        case .cancelled: "VG-CORE-0001"
        case .internalInvariant: "VG-CORE-0002"
        default: cause?.diagnosticCode ?? "VG-CORE-0000"
        }
    }

    var severity: ErrorSeverity {
        switch self {
        case .cancelled: .degraded
        case .internalInvariant: .fatal
        default: cause?.severity ?? .recoverable
        }
    }

    var disposition: RetryDisposition {
        switch self {
        case .cancelled, .internalInvariant: .noRetry
        default: cause?.disposition ?? .noRetry
        }
    }

    var userMessage: String {
        switch self {
        case .cancelled: "The operation was cancelled."
        case .internalInvariant: "Vigil ran into an internal problem."
        default: cause?.userMessage ?? "Something went wrong."
        }
    }

    var userRemedy: String? {
        switch self {
        case .cancelled: nil
        case .internalInvariant: "Please send a diagnostics report so we can fix it."
        default: cause?.userRemedy
        }
    }

    var logMetadata: [String: String] {
        switch self {
        case .internalInvariant(let message, let file, let line):
            // The message is developer-authored, but it interpolates runtime values, so it goes
            // through the one redaction point like everything else that reaches a log line.
            ["invariant": Redact.secrets(in: message),
             "file": file.description,
             "line": String(line)]
        case .cancelled:
            [:]
        default:
            cause?.logMetadata ?? [:]
        }
    }
}

// MARK: - Equatable and Hashable

// `StaticString` conforms to neither `Equatable` nor `Hashable`, so `.internalInvariant`'s `file`
// payload defeats synthesis and the conformance is written out. Comparing `file.description` is
// exact: `#fileID` literals are compile-time constants.
public extension VigilError {

    static func == (a: VigilError, b: VigilError) -> Bool {
        switch (a, b) {
        case (.transport(let x), .transport(let y)): x == y
        case (.rtsp(let x), .rtsp(let y)): x == y
        case (.rtp(let x), .rtp(let y)): x == y
        case (.bitstream(let x), .bitstream(let y)): x == y
        case (.isapi(let x), .isapi(let y)): x == y
        case (.discovery(let x), .discovery(let y)): x == y
        case (.decode(let x), .decode(let y)): x == y
        case (.render(let x), .render(let y)): x == y
        case (.storage(let x), .storage(let y)): x == y
        case (.credential(let x), .credential(let y)): x == y
        case (.recording(let x), .recording(let y)): x == y
        case (.cancelled, .cancelled): true
        case (.internalInvariant(let m1, let f1, let l1), .internalInvariant(let m2, let f2, let l2)):
            m1 == m2 && f1.description == f2.description && l1 == l2
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .transport(let e): hasher.combine(0); hasher.combine(e)
        case .rtsp(let e): hasher.combine(1); hasher.combine(e)
        case .rtp(let e): hasher.combine(2); hasher.combine(e)
        case .bitstream(let e): hasher.combine(3); hasher.combine(e)
        case .isapi(let e): hasher.combine(4); hasher.combine(e)
        case .discovery(let e): hasher.combine(5); hasher.combine(e)
        case .decode(let e): hasher.combine(6); hasher.combine(e)
        case .render(let e): hasher.combine(7); hasher.combine(e)
        case .storage(let e): hasher.combine(8); hasher.combine(e)
        case .credential(let e): hasher.combine(9); hasher.combine(e)
        case .recording(let e): hasher.combine(10); hasher.combine(e)
        case .cancelled: hasher.combine(11)
        case .internalInvariant(let message, let file, let line):
            hasher.combine(12)
            hasher.combine(message)
            hasher.combine(file.description)
            hasher.combine(line)
        }
    }
}

// MARK: - Invariants

/// Throws instead of trapping. We never take the whole window down because one camera sent
/// something odd; these bytes come from the network, so a crash is a security bug.
///
/// Reads backwards on purpose: the guard passes — and the function returns — exactly when
/// `condition` holds. Verbatim from API_CONTRACT §3.9.
@inline(__always)
public func vigilRequire(_ condition: Bool, _ message: @autoclosure () -> String,
                         file: StaticString = #fileID, line: UInt = #line) throws(VigilError) {
    guard !condition else { return }
    throw VigilError.internalInvariant(message(), file: file, line: line)
}
