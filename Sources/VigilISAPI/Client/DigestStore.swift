//
//  DigestStore.swift
//  VigilISAPI
//
//  The challenge cache: one realm, one nonce, a per-(realm, nonce) counter, and the pre-emptive
//  `Authorization` header that turns a snapshot into one round trip instead of three.
//  Implements docs/spec-isapi.md §5.3 and §5.4.
//
//  Digest is implemented here rather than through `URLCredential` because URLSession will not send
//  an `Authorization` header until it has been challenged — which costs a 401 round trip on every
//  first request, is impossible for a streamed upload body that cannot be replayed, and behaves
//  differently on swift-corelibs-foundation, where our Linux tests run.
//

import Foundation
import VigilProtocols

// MARK: - DigestStore

/// The per-device authentication state.
///
/// Flow (§5.3): the first request goes out unauthenticated because the realm is unknown; the 401
/// carries the challenge, which is absorbed and the request resent with `nc = 1`; every later
/// request pre-computes its header from the cached challenge with the next `nc`, and no further
/// 401 is expected. A 401 that *does* arrive is only a failure when the nonce is unchanged and
/// `stale` is false — see `Disposition`.
public actor DigestStore {

    /// What to do with a 401 that arrived despite a cached challenge.
    public enum Disposition: Sendable, Hashable {
        /// The challenge was new, changed, or stale: resend once. **Not** a failed login (R-25).
        case retry
        /// The device repeated the same nonce with `stale=false`: the credential is wrong.
        case authenticationFailed
        /// The device offers only a scheme Vigil cannot compute over this transport.
        case unsupported(String)
    }

    /// The cached challenge, or `nil` before the first 401.
    private var challenge: DigestChallenge?

    /// The `cnonce` in force for the current nonce. Regenerated whenever the nonce changes.
    private var cnonce = ""

    /// The last `nc` used for the current nonce; the next request uses this plus one.
    private var nonceCount: UInt32 = 0

    /// True once a Basic-only challenge has been seen and Basic is permitted.
    private var useBasic = false

    /// The nonce the last issued header was computed from, so a 401 can be told apart from a
    /// stale-nonce retry without trusting the device's `stale` flag alone.
    private var lastIssuedNonce: String?

    /// The injected randomness for `cnonce`. Never `SystemRandomNumberGenerator` directly: a
    /// failing test must reproduce from its seed (R-32).
    private var random: any RandomSource

    /// Whether Basic may be sent when Digest cannot be computed. Only ever true over TLS.
    private let allowBasicFallback: Bool

    /// Creates a store.
    ///
    /// - Parameters:
    ///   - random: the `cnonce` source. Seed it in tests.
    ///   - allowBasicFallback: `true` only when the connection is TLS *and* the configuration
    ///     permits it. Basic over cleartext is never sent, whatever the device asks for.
    public init(random: any RandomSource = SystemRandomSource(), allowBasicFallback: Bool = false) {
        self.random = random
        self.allowBasicFallback = allowBasicFallback
    }

    // MARK: Reading state

    /// The cached challenge, for diagnostics and for the Stream Doctor's report.
    public var currentChallenge: DigestChallenge? { challenge }

    /// The `nc` the next request will use. Starts at 1.
    public var nextNonceCount: UInt32 { nonceCount &+ 1 }

    /// True when a header can be produced without another round trip.
    public var canAuthenticatePreemptively: Bool { challenge != nil || useBasic }

    // MARK: Absorbing challenges

    /// Absorbs a challenge from a 401 and reports what the caller should do.
    ///
    /// - Parameters:
    ///   - headers: the 401's headers.
    ///   - didSendAuthorization: whether the request that was refused already carried a plausible
    ///     `Authorization` header. This is what distinguishes "we had not authenticated yet" from
    ///     "the device rejected our credential", and therefore what R-25 counts.
    ///   - isTLS: whether the connection is TLS, which is the only case in which Basic is allowed.
    /// - Returns: `.retry` for a new, changed or stale challenge; `.authenticationFailed` when the
    ///   device repeated the nonce it just rejected; `.unsupported` for an algorithm Vigil cannot
    ///   compute over this transport.
    public func absorb(headers: HTTPHeaders, didSendAuthorization: Bool,
                       isTLS: Bool) -> Disposition {
        guard let fresh = DigestChallenge.parse(headers: headers) else {
            if DigestChallenge.offersBasic(headers: headers), isTLS || !didSendAuthorization {
                // Basic-only device. Permitted over TLS; over cleartext it is refused below.
                guard isTLS else { return .unsupported("Basic over cleartext") }
                useBasic = true
                return didSendAuthorization ? .authenticationFailed : .retry
            }
            return didSendAuthorization ? .authenticationFailed : .unsupported("no challenge")
        }

        if case let .unsupported(name) = fresh.algorithm {
            if isTLS, allowBasicFallback, DigestChallenge.offersBasic(headers: headers) {
                useBasic = true
                challenge = nil
                return .retry
            }
            return .unsupported(name)
        }

        let sameNonce = fresh.nonce == lastIssuedNonce
        absorb(fresh)
        if didSendAuthorization && sameNonce && !fresh.stale {
            return .authenticationFailed
        }
        return .retry
    }

    /// Adopts `challenge`, resetting the counter when the nonce changed.
    ///
    /// A repeated nonce keeps its counter: `nc` must never be reused for the same nonce, or the
    /// device treats the request as a replay and answers 401 for the rest of the connection.
    public func absorb(_ challenge: DigestChallenge) {
        if self.challenge?.nonce != challenge.nonce {
            nonceCount = 0
            cnonce = random.hexString(count: 16)
        }
        self.challenge = challenge
        useBasic = false
    }

    /// Adopts a `nextnonce` from an `Authentication-Info` header, when the device sent one.
    public func adoptNextNonce(headers: HTTPHeaders) {
        guard let nonce = DigestChallenge.nextNonce(headers: headers),
              var updated = challenge, updated.nonce != nonce else { return }
        updated.nonce = nonce
        updated.stale = false
        absorb(updated)
    }

    /// Drops the cached challenge. Used on a credential change and on a `stale` challenge whose
    /// replacement failed to parse.
    public func invalidate(reason: String) {
        challenge = nil
        cnonce = ""
        nonceCount = 0
        useBasic = false
        lastIssuedNonce = nil
        _ = reason      // Carried for the caller's log line; the store itself never logs.
    }

    // MARK: Producing headers

    /// The `Authorization` header for a request, or `nil` when the device has not challenged yet.
    ///
    /// Each call consumes one `nc`: the counter is per (realm, nonce) and a value is never reused,
    /// so this must be called exactly once per request attempt. A resend after a 401 is a new
    /// attempt and takes the next value.
    ///
    /// - Parameters:
    ///   - method: the HTTP verb, upper-case.
    ///   - uri: the request-line URI — path **and** query, exactly as it will be written.
    ///   - credential: the account to authenticate as.
    /// - Returns: the header value, or `nil` when nothing can be computed yet.
    public func header(for method: String, uri: String, credential: Credential) -> String? {
        if let challenge {
            nonceCount &+= 1
            if cnonce.isEmpty { cnonce = random.hexString(count: 16) }
            lastIssuedNonce = challenge.nonce
            return HTTPDigest.authorization(challenge: challenge, credential: credential,
                                            method: method, uri: uri,
                                            cnonce: cnonce, nonceCount: nonceCount)
        }
        if useBasic {
            return HTTPDigest.basicAuthorization(credential: credential)
        }
        return nil
    }
}
