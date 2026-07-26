//
//  RTSPAuthenticator.swift
//  VigilRTSP
//
//  Basic and Digest authentication state: nonce adoption, `nc`, `cnonce`, `opaque`, `stale`, the
//  RFC 2069 no-`qop` form Hikvision actually uses, and the two-attempt cap that keeps a wrong
//  password from locking the user out of their own camera.
//  Implements docs/spec-rtsp.md §6 and docs/API_CONTRACT.md §4.3 and §2 R-25.
//
//  MD5 is used here and nowhere else in Vigil, because RFC 2617 mandates it. It is cryptographically
//  broken and must never be used for integrity, storage or key derivation.
//

import VigilProtocols

// MARK: - Digest arithmetic

/// The RFC 2617 §3.2.2 string constructions, isolated so they can be tested against the published
/// worked example — whose method is `GET`, which no `RTSPMethod` can express.
///
/// All hashing is over UTF-8 bytes, all hex output is lowercase, and there is no trailing newline
/// anywhere. Values passed here are already unquoted.
package enum RTSPDigest {

    /// `HA1 = MD5(username ":" realm ":" password)`.
    package static func ha1(username: String, realm: String, password: String) -> String {
        MD5.hexDigest("\(username):\(realm):\(password)")
    }

    /// `MD5-sess` HA1: `MD5(HA1 ":" nonce ":" cnonce)`, computed once per nonce.
    package static func sessionHA1(base: String, nonce: String, cnonce: String) -> String {
        MD5.hexDigest("\(base):\(nonce):\(cnonce)")
    }

    /// `HA2 = MD5(method ":" digest-uri)`. `auth-int` is not implemented, so no body hash appears.
    package static func ha2(method: String, uri: String) -> String {
        MD5.hexDigest("\(method):\(uri)")
    }

    /// RFC 2069 (no `qop`) response: `MD5(HA1 ":" nonce ":" HA2)`. The primary Hikvision path.
    package static func response(ha1: String, nonce: String, ha2: String) -> String {
        MD5.hexDigest("\(ha1):\(nonce):\(ha2)")
    }

    /// RFC 2617 `qop=auth` response: `MD5(HA1 ":" nonce ":" nc ":" cnonce ":" qop ":" HA2)`.
    package static func response(ha1: String, nonce: String, nonceCount: String, cnonce: String,
                                 qop: String, ha2: String) -> String {
        MD5.hexDigest("\(ha1):\(nonce):\(nonceCount):\(cnonce):\(qop):\(ha2)")
    }

    /// Eight lowercase hex digits, as `nc` goes on the wire.
    package static func nonceCountHex(_ value: UInt32) -> String {
        var out = ""
        out.reserveCapacity(8)
        for shift in stride(from: 28, through: 0, by: -4) {
            let nibble = UInt8((value >> UInt32(shift)) & 0xF)
            out.append(Character(UnicodeScalar(nibble < 10 ? 0x30 + nibble : 0x57 + nibble)))
        }
        return out
    }
}

/// Digest and Basic authentication for one connection.
///
/// Three rules drive every decision in this type:
///
/// 1. **The Digest URI is the request-line URI, byte for byte** — per track for `SETUP`, query
///    included for playback. Re-deriving it produces a `401` loop that looks exactly like a wrong
///    password, and it is the most common RTSP client bug against Hikvision.
/// 2. **Authentication failure is terminal.** Two credentialed `401`s and this type refuses to
///    produce another `Authorization` for the rest of its life (API_CONTRACT §2 R-25). Hikvision
///    firmware locks an account for thirty minutes after roughly five failed logins, including
///    against the camera's own web UI, so a client that retries locks the user out of their camera.
/// 3. **`cnonce` comes from the injected `RandomSource`.** Never `SystemRandomNumberGenerator`
///    directly, so a failing test reproduces from its seed.
public struct RTSPAuthenticator: Sendable, CustomStringConvertible {

    // MARK: - Outcome

    /// What the caller should do after a `401`/`407`.
    public enum Outcome: Sendable, Equatable {
        /// New or changed nonce, or `stale=true`, or a first challenge: attach `Authorization` and
        /// resend with a **new** `CSeq`. Does not count as a failed login.
        case retry
        /// The same nonce came back with `stale=false` after we sent credentials. One more attempt
        /// is allowed, and it is spent on the URI-fallback rung (docs/spec-rtsp.md §6.8) rather than
        /// on repeating a request the device already rejected.
        case retryWithURIFallback(rung: Int)
        /// Terminal. The error's `disposition` is `.retryAfterUserAction`; nothing may retry it on
        /// any schedule until the user supplies a new credential.
        case failed(RTSPError)
    }

    // MARK: - Configuration

    /// Credentialed `401`s that end the session. **Two** (API_CONTRACT §2 R-25), not RFC-flavoured
    /// optimism.
    public static let maxCredentialedFailures = 2

    /// `cnonce` length in hex characters, from 8 random bytes.
    private static let cnonceHexLength = 16

    // MARK: - State

    private let credential: Credential?
    private var random: any RandomSource
    private let allowBasicOverPlaintext: Bool
    private let isTLS: Bool

    private var challenge: RTSPChallenge?
    private var cnonce = ""
    private var nonceCount: UInt32 = 0
    private var cachedHA1: String?
    private var uriRung = 0
    private var issuedAuthorization = false
    private var terminalError: RTSPError?

    /// Consecutive `401`s answering a request that already carried an `Authorization` header.
    /// **Two is terminal.** A `401` with a new nonce or `stale=true` never increments it.
    public private(set) var failureCount = 0

    /// Challenges absorbed on this connection, for logs and tests.
    public private(set) var challengeCount = 0

    /// What the last `absorb` decided. `nil` before the first challenge.
    ///
    /// `absorb` returns `Void` per the contract, so the decision is read from here; a session
    /// machine that ignores it and retries anyway still cannot get an `Authorization` out of a
    /// terminal authenticator, because the terminality is enforced in `authorization(for:uri:)`.
    public private(set) var lastOutcome: Outcome?

    // MARK: - Init

    /// Creates an authenticator.
    ///
    /// - Parameters:
    ///   - credential: the account, or `nil` when Vigil has no password for this device. A `nil`
    ///     credential makes the first challenge terminal with `.credentialsMissing` rather than
    ///     producing empty-password guesses.
    ///   - random: the source of `cnonce`. Inject a seeded generator in tests.
    ///   - allowBasicOverPlaintext: opt-in to Basic on a non-TLS connection. Off by default: Basic
    ///     puts the password on the wire in clear, where the device also logs it.
    ///   - isTLS: whether the connection is `rtsps`, which makes Basic acceptable.
    public init(credential: Credential?, random: any RandomSource,
                allowBasicOverPlaintext: Bool = false, isTLS: Bool = false) {
        self.credential = credential
        self.random = random
        self.allowBasicOverPlaintext = allowBasicOverPlaintext
        self.isTLS = isTLS
    }

    // MARK: - Introspection

    /// Whether an `Authorization` can be produced right now.
    public var hasUsableState: Bool {
        terminalError == nil && credential != nil && challenge != nil
    }

    /// The realm of the challenge in force, for the credential prompt.
    public var realm: String? { challenge?.realm }

    /// The error that ended authentication, or `nil`. Once set, nothing this type does can produce
    /// another `Authorization`.
    public var terminalFailure: RTSPError? { terminalError }

    /// The next `nc` value that would be sent, as it appears on the wire. `nil` when `qop` is not
    /// in use, which is the normal Hikvision case.
    public var nextNonceCount: String? {
        guard let challenge, challenge.qop.contains("auth") else { return nil }
        return RTSPDigest.nonceCountHex(nonceCount + 1)
    }

    /// The client nonce in force. Constant while `nc` increments; regenerated when the nonce
    /// changes (RFC 2617 permits this, and it keeps golden fixtures deterministic).
    public var clientNonce: String { cnonce }

    /// Redacted. Names the realm and the counters, never the nonce, the cnonce or the password.
    public var description: String {
        let realmText = challenge.map { Redact.secrets(in: "realm=\($0.realm)") } ?? "no challenge"
        let scheme = challenge?.scheme ?? "-"
        return "RTSPAuthenticator(\(scheme), \(realmText), failures: \(failureCount)"
            + ", terminal: \(terminalError != nil))"
    }

    // MARK: - Challenges

    /// Feeds the challenges from a `401`/`407` and decides what happens next; read `lastOutcome`.
    ///
    /// The classification is R-25's, exactly:
    ///
    /// * a challenge whose nonce differs from ours, or which carries `stale=true`, is **not** a
    ///   failed login — adopt the nonce, reset `nc` to zero, regenerate `cnonce`, retry once;
    /// * a `401` answering a request that already carried an `Authorization`, with the same nonce
    ///   and `stale=false`, **is** a failed login and counts;
    /// * the second such `401` is terminal `.authRejected`.
    ///
    /// A challenge Vigil cannot answer (only `auth-int`, an unknown algorithm, or only Basic on a
    /// plaintext connection without the opt-in) is terminal too: sending a hash computed the wrong
    /// way would burn a lockout attempt for nothing.
    public mutating func absorb(_ challenges: [RTSPChallenge]) {
        challengeCount += 1
        guard terminalError == nil else {
            lastOutcome = .failed(terminalError ?? .authRejected)
            return
        }
        guard credential != nil else {
            setTerminal(.credentialsMissing)
            return
        }
        guard let selected = RTSPChallenge.select(from: challenges,
                                                  allowBasicOverPlaintext: allowBasicOverPlaintext,
                                                  isTLS: isTLS) else {
            setTerminal(.authRejected)
            return
        }
        let isSameNonce = selected.isDigest && selected.nonce != nil
            && selected.nonce == challenge?.nonce && challenge?.isDigest == true
        guard issuedAuthorization, isSameNonce, !selected.stale else {
            adopt(selected)
            lastOutcome = .retry
            return
        }
        failureCount += 1
        if failureCount >= RTSPAuthenticator.maxCredentialedFailures {
            setTerminal(.authRejected)
            return
        }
        // The one permitted retry goes to the compatibility rung, because repeating the identical
        // request against the identical nonce cannot produce a different answer.
        uriRung += 1
        lastOutcome = .retryWithURIFallback(rung: uriRung)
    }

    /// Adopts a challenge: new nonce, `nc` back to zero, fresh `cnonce`, rung back to zero.
    private mutating func adopt(_ selected: RTSPChallenge) {
        challenge = selected
        nonceCount = 0
        cnonce = random.hexString(count: RTSPAuthenticator.cnonceHexLength)
        cachedHA1 = nil
        uriRung = 0
        issuedAuthorization = false
    }

    /// Records a terminal failure.
    private mutating func setTerminal(_ error: RTSPError) {
        terminalError = error
        lastOutcome = .failed(error)
    }

    // MARK: - Authorization

    /// Builds the `Authorization` value for a request, or `nil` when there is no usable state.
    ///
    /// - Parameters:
    ///   - method: the request method; it is the first half of A2.
    ///   - uri: **the exact request-line URI**. It is hashed verbatim into A2 and echoed verbatim
    ///     into `uri=`. For `SETUP` this is the track control URL, so `HA2` differs per track; for
    ///     playback it includes `?starttime=…&endtime=…`.
    /// - Returns: the header value, or `nil` when no challenge has been absorbed, when there is no
    ///   credential, or when authentication has already failed terminally.
    ///
    /// Side effect: `nc` increments when `qop=auth` is in use, and the authenticator remembers that
    /// it issued credentials, which is what makes the next `401` count as a failed login.
    public mutating func authorization(for method: RTSPMethod, uri: String) -> String? {
        guard terminalError == nil, let credential, let challenge else { return nil }
        if challenge.isBasic {
            issuedAuthorization = true
            let raw = Array("\(credential.account):\(credential.secret)".utf8)
            return "Basic " + Base64.encode(raw)
        }
        guard challenge.isDigest, let nonce = challenge.nonce else { return nil }
        let digestURI = fallbackApplied(to: uri)
        let ha1 = hashA1(realm: challenge.realm, nonce: nonce)
        let ha2 = RTSPDigest.ha2(method: method.rawValue, uri: digestURI)

        var parameters = [
            "username=" + RTSPHeaderScanner.quote(credential.account),
            "realm=" + RTSPHeaderScanner.quote(challenge.realm),
            "nonce=" + RTSPHeaderScanner.quote(nonce),
            "uri=" + RTSPHeaderScanner.quote(digestURI),
        ]
        let response: String
        if challenge.qop.contains("auth") {
            nonceCount += 1
            let nc = RTSPDigest.nonceCountHex(nonceCount)
            response = RTSPDigest.response(ha1: ha1, nonce: nonce, nonceCount: nc,
                                           cnonce: cnonce, qop: "auth", ha2: ha2)
            parameters.append("response=" + RTSPHeaderScanner.quote(response))
            appendAlgorithm(to: &parameters)
            parameters.append("qop=auth")                      // unquoted in Authorization
            parameters.append("nc=" + nc)                      // unquoted, 8 lowercase hex
            parameters.append("cnonce=" + RTSPHeaderScanner.quote(cnonce))
        } else {
            // RFC 2069, the primary Hikvision path: no qop, no nc, no cnonce in the response hash.
            response = RTSPDigest.response(ha1: ha1, nonce: nonce, ha2: ha2)
            parameters.append("response=" + RTSPHeaderScanner.quote(response))
            appendAlgorithm(to: &parameters)
        }
        if let opaque = challenge.opaque {
            parameters.append("opaque=" + RTSPHeaderScanner.quote(opaque))   // echoed verbatim, last
        }
        issuedAuthorization = true
        return "Digest " + parameters.joined(separator: ", ")
    }

    /// Echoes `algorithm` only when the server sent one — a bare `Digest` challenge gets a bare
    /// `Authorization`, which is the form the §11.1 wire dump shows.
    private func appendAlgorithm(to parameters: inout [String]) {
        guard let challenge, challenge.specifiesAlgorithm else { return }
        parameters.append("algorithm=" + challenge.algorithm)                // unquoted
    }

    /// HA1, computed once per nonce and cached.
    ///
    /// `MD5-sess` folds the nonce and the cnonce into HA1, so the cache is invalidated whenever a
    /// nonce is adopted, which is also when a fresh cnonce is drawn.
    private mutating func hashA1(realm: String, nonce: String) -> String {
        if let cachedHA1 { return cachedHA1 }
        guard let credential else { return "" }
        let base = RTSPDigest.ha1(username: credential.account, realm: realm,
                                  password: credential.secret)
        let value = challenge?.isSessionAlgorithm == true
            ? RTSPDigest.sessionHA1(base: base, nonce: nonce, cnonce: cnonce)
            : base
        cachedHA1 = value
        return value
    }

    /// Applies the URI-fallback rung to the request URI (docs/spec-rtsp.md §6.8).
    ///
    /// Rung 0 is the request-line URI verbatim, which is what every correct device expects. Rung 1
    /// drops the query and rung 2 additionally drops a default `:554`, for the minority of firmware
    /// that canonicalises the URI before hashing it. **The request line itself never changes** —
    /// only the `uri=` parameter and therefore `HA2`.
    private func fallbackApplied(to uri: String) -> String {
        guard uriRung > 0, let parsed = RTSPURL(string: uri) else { return uri }
        return uriRung == 1 ? parsed.formWithoutQuery : parsed.formWithoutDefaultPort
    }

    // MARK: - Reset

    /// Clears per-connection nonce state: nonce, `nc`, `cnonce`, cached HA1 and the URI rung.
    ///
    /// **Deliberately keeps `failureCount` and the terminal failure.** Nonce state is
    /// per-connection, but a rejected password is a property of the credential, and clearing the
    /// counter on reconnect would turn a reconnect loop into an account lockout — exactly the
    /// failure R-25 exists to prevent. A new password means a new `RTSPAuthenticator`.
    public mutating func reset() {
        challenge = nil
        cnonce = ""
        nonceCount = 0
        cachedHA1 = nil
        uriRung = 0
        issuedAuthorization = false
    }
}
