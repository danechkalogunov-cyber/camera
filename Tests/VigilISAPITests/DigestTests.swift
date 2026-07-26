//
//  DigestTests.swift
//  VigilISAPITests
//
//  The Digest arithmetic against published vectors, the challenge parser against the header
//  Hikvision actually sends, and the nonce-count discipline.
//  Covers docs/spec-isapi.md §5.1–§5.3 and docs/API_CONTRACT.md §2 R-25.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilISAPI

// MARK: - Arithmetic

@Suite struct HTTPDigestArithmeticTests {

    /// RFC 2617 §3.5's worked example, verbatim: `Mufasa` / `Circle Of Life` /
    /// `testrealm@host.com`, `GET /dir/index.html`, nonce `dcd98b…c093`, cnonce `0a4f113b`,
    /// nc `00000001`, `qop=auth`.
    @Test func httpDigestMatchesRFC2617WorkedExample() {
        let ha1 = HTTPDigest.ha1(username: "Mufasa", realm: "testrealm@host.com",
                                 password: "Circle Of Life")
        #expect(ha1 == "939e7578ed9e3c518a452acee763bce9")
        let ha2 = HTTPDigest.ha2(method: "GET", uri: "/dir/index.html")
        #expect(ha2 == "39aff3a2bab6126f332b942af96d3366")
        let response = HTTPDigest.response(ha1: ha1,
                                           nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093",
                                           nonceCount: "00000001", cnonce: "0a4f113b",
                                           qop: "auth", ha2: ha2)
        #expect(response == "6629fae49393a05397450978507c4ef1")
    }

    /// The RFC 2069 no-`qop` form over the same inputs. The expected digest was computed
    /// independently with `python3 -c hashlib.md5` from `HA1:nonce:HA2`, not from this code.
    @Test func httpDigestNoQOPUsesRFC2069Form() {
        let ha1 = HTTPDigest.ha1(username: "Mufasa", realm: "testrealm@host.com",
                                 password: "Circle Of Life")
        let ha2 = HTTPDigest.ha2(method: "GET", uri: "/dir/index.html")
        let response = HTTPDigest.response(ha1: ha1,
                                          nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093", ha2: ha2)
        #expect(response == "670fd8c2df070c60b045671b8b24ff02")
    }

    /// `MD5-sess` folds the nonce and cnonce into HA1. Expected values computed independently
    /// with `hashlib.md5`.
    @Test func httpDigestSessionAlgorithmFoldsNonceIntoHA1() {
        let base = HTTPDigest.ha1(username: "Mufasa", realm: "testrealm@host.com",
                                  password: "Circle Of Life")
        let session = HTTPDigest.sessionHA1(base: base,
                                            nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093",
                                            cnonce: "0a4f113b")
        #expect(session == "5edb191b66dce1584c16cb7e7346fcee")
        let ha2 = HTTPDigest.ha2(method: "GET", uri: "/dir/index.html")
        #expect(HTTPDigest.response(ha1: session, nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093",
                                    nonceCount: "00000001", cnonce: "0a4f113b", qop: "auth",
                                    ha2: ha2) == "8e3825c57e897f5a0dec6c2d4e5059d0")
    }

    /// A2 is hashed over path **plus query**. The two expected digests were computed
    /// independently; that they differ is the whole point — hashing the path alone 401s every
    /// parameterised request while the unparameterised ones work.
    @Test func httpDigestURIIncludesTheQueryString() {
        let ha1 = HTTPDigest.ha1(username: "admin", realm: "IP Camera(51253)",
                                 password: "Vigil-Test-1")
        #expect(ha1 == "b625d816f30bbcb8c3eb777cf06b903c")
        let withQuery = "/ISAPI/Streaming/channels/101/picture"
            + "?videoResolutionWidth=640&videoResolutionHeight=360"
        let nonce = "4e5a4f5a5a4d5a4f5a4d3d3d"
        let signedWithQuery = HTTPDigest.response(
            ha1: ha1, nonce: nonce, ha2: HTTPDigest.ha2(method: "GET", uri: withQuery))
        let signedPathOnly = HTTPDigest.response(
            ha1: ha1, nonce: nonce,
            ha2: HTTPDigest.ha2(method: "GET", uri: "/ISAPI/Streaming/channels/101/picture"))
        #expect(signedWithQuery == "44ba150c7ca038251fc11989b88a405b")
        #expect(signedPathOnly == "0716c1bc604695b9ffb2bd9426117924")
        #expect(signedWithQuery != signedPathOnly)
    }

    /// `nc` is eight lowercase hex digits, always.
    @Test func httpDigestNonceCountIsEightLowercaseHexDigits() {
        #expect(HTTPDigest.nonceCountHex(1) == "00000001")
        #expect(HTTPDigest.nonceCountHex(255) == "000000ff")
        #expect(HTTPDigest.nonceCountHex(0xABCDEF12) == "abcdef12")
        #expect(HTTPDigest.nonceCountHex(.max) == "ffffffff")
    }

    /// In no-`qop` mode the header carries no `qop`, `nc` or `cnonce` at all, and `qop=auth` is
    /// emitted unquoted when it is present (RFC 7616; some proxies reject the quoted spelling).
    @Test func httpDigestAuthorizationShapeFollowsTheChallenge() throws {
        let credential = Credential(account: "admin", secret: "Vigil-Test-1")
        let noQOP = DigestChallenge(realm: "IP Camera(51253)", nonce: "abc")
        let plain = try #require(HTTPDigest.authorization(challenge: noQOP, credential: credential,
                                                          method: "GET", uri: "/ISAPI/x",
                                                          cnonce: "0a4f113b", nonceCount: 1))
        #expect(!plain.contains("qop"))
        #expect(!plain.contains("nc="))
        #expect(!plain.contains("cnonce"))
        #expect(plain.hasPrefix("Digest username=\"admin\", realm=\"IP Camera(51253)\", "))

        let withQOP = DigestChallenge(realm: "r", nonce: "abc", opaque: "op", qop: ["auth"])
        let full = try #require(HTTPDigest.authorization(challenge: withQOP, credential: credential,
                                                         method: "GET", uri: "/ISAPI/x",
                                                         cnonce: "0a4f113b", nonceCount: 2))
        #expect(full.contains("qop=auth,"))
        #expect(full.contains("nc=00000002"))
        #expect(full.contains("cnonce=\"0a4f113b\""))
        #expect(full.contains("opaque=\"op\""))
    }

    /// `MD5-sess` is announced back to the device; plain MD5 is left implicit.
    @Test func httpDigestAuthorizationAnnouncesSessionAlgorithmOnly() throws {
        let credential = Credential(account: "admin", secret: "p")
        let session = DigestChallenge(realm: "r", nonce: "n", qop: ["auth"], algorithm: .md5sess)
        let header = try #require(HTTPDigest.authorization(challenge: session,
                                                           credential: credential, method: "GET",
                                                           uri: "/x", cnonce: "cc", nonceCount: 1))
        #expect(header.contains("algorithm=MD5-sess"))
        let plain = try #require(HTTPDigest.authorization(
            challenge: DigestChallenge(realm: "r", nonce: "n"), credential: credential,
            method: "GET", uri: "/x", cnonce: "cc", nonceCount: 1))
        #expect(!plain.contains("algorithm"))
    }

    /// An algorithm Vigil cannot compute yields no header at all rather than a wrong one.
    @Test func httpDigestAuthorizationRefusesUnsupportedAlgorithm() {
        let challenge = DigestChallenge(realm: "r", nonce: "n",
                                        algorithm: .unsupported("SHA-256"))
        #expect(HTTPDigest.authorization(challenge: challenge,
                                         credential: Credential(account: "a", secret: "b"),
                                         method: "GET", uri: "/x", cnonce: "c",
                                         nonceCount: 1) == nil)
    }

    /// A quote inside a username cannot end the parameter early.
    @Test func httpDigestEscapesQuotesInsideQuotedParameters() throws {
        let credential = Credential(account: "ad\"min", secret: "p")
        let header = try #require(HTTPDigest.authorization(
            challenge: DigestChallenge(realm: "r", nonce: "n"), credential: credential,
            method: "GET", uri: "/x", cnonce: "c", nonceCount: 1))
        #expect(header.contains("username=\"ad\\\"min\""))
    }

    /// Basic is `base64(user:password)`, UTF-8.
    @Test func httpDigestBasicHeaderIsBase64OfUserAndPassword() {
        let header = HTTPDigest.basicAuthorization(
            credential: Credential(account: "Aladdin", secret: "open sesame"))
        #expect(header == "Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==")
    }
}

// MARK: - Challenge parsing

@Suite struct DigestChallengeParsingTests {

    /// The header Hikvision sends verbatim on 5.2–5.5 firmware: a realm with a space and
    /// parentheses, no `qop`, no `algorithm`, no `opaque`.
    @Test func digestChallengeParsesHikvisionNoQOPHeader() throws {
        let header = "Digest realm=\"IP Camera(51253)\", "
            + "nonce=\"4e5a4f5a5a4d5a4f5a4d3d3d\", stale=\"FALSE\""
        let challenge = try #require(DigestChallenge.parse(header: header))
        #expect(challenge.realm == "IP Camera(51253)")
        #expect(challenge.nonce == "4e5a4f5a5a4d5a4f5a4d3d3d")
        #expect(challenge.qop.isEmpty)
        #expect(challenge.usesQOPAuth == false)
        #expect(challenge.algorithm == .md5)
        #expect(challenge.stale == false)
        #expect(challenge.opaque == nil)
    }

    /// `qop="auth"`, `opaque` and `algorithm=MD5` on newer firmware.
    @Test func digestChallengeParsesQOPOpaqueAndAlgorithm() throws {
        let header = "Digest qop=\"auth\", realm=\"IP Camera(1)\", nonce=\"abc\", "
            + "opaque=\"5ccc069c\", algorithm=MD5, stale=FALSE"
        let challenge = try #require(DigestChallenge.parse(header: header))
        #expect(challenge.qop == ["auth"])
        #expect(challenge.usesQOPAuth)
        #expect(challenge.opaque == "5ccc069c")
        #expect(challenge.algorithm == .md5)
    }

    /// `stale` is compared case-insensitively; Hikvision writes it upper-case.
    @Test func digestChallengeReadsStaleCaseInsensitively() throws {
        let upper = try #require(DigestChallenge.parse(
            header: "Digest realm=\"r\", nonce=\"n\", stale=\"TRUE\""))
        #expect(upper.stale)
        let mixed = try #require(DigestChallenge.parse(
            header: "Digest realm=\"r\", nonce=\"n\", stale=True"))
        #expect(mixed.stale)
    }

    /// Digest wins when both schemes are offered, in either header order.
    @Test func digestChallengePrefersDigestOverBasic() throws {
        var headers = HTTPHeaders()
        headers.append("WWW-Authenticate", "Basic realm=\"IP Camera(51253)\"")
        headers.append("WWW-Authenticate", "Digest realm=\"IP Camera(51253)\", nonce=\"n1\"")
        let challenge = try #require(DigestChallenge.parse(headers: headers))
        #expect(challenge.nonce == "n1")
        #expect(DigestChallenge.offersBasic(headers: headers))
    }

    /// Two schemes inside one header value, with a space in the realm, still split correctly.
    @Test func digestChallengeSplitsTwoSchemesInOneHeader() throws {
        var headers = HTTPHeaders()
        headers.append("WWW-Authenticate",
                       "Digest realm=\"IP Camera(51253)\", nonce=\"n2\", Basic realm=\"IP Camera\"")
        let challenge = try #require(DigestChallenge.parse(headers: headers))
        #expect(challenge.realm == "IP Camera(51253)")
        #expect(challenge.nonce == "n2")
        #expect(DigestChallenge.offersBasic(headers: headers))
    }

    /// SHA-256 is reported as unsupported rather than silently downgraded to MD5.
    @Test func digestChallengeReportsUnsupportedAlgorithm() throws {
        let challenge = try #require(DigestChallenge.parse(
            header: "Digest realm=\"r\", nonce=\"n\", algorithm=SHA-256"))
        #expect(challenge.algorithm == .unsupported("SHA-256"))
    }

    /// A header with no realm or no nonce is not a usable challenge.
    @Test func digestChallengeRejectsIncompleteHeader() {
        #expect(DigestChallenge.parse(header: "Digest realm=\"r\"") == nil)
        #expect(DigestChallenge.parse(header: "Digest nonce=\"n\"") == nil)
        #expect(DigestChallenge.parse(header: "Basic realm=\"r\"") == nil)
    }

    /// 6.x firmware sends `Authentication-Info: nextnonce="…"`, which is adopted.
    @Test func digestChallengeReadsNextNonceFromAuthenticationInfo() throws {
        var headers = HTTPHeaders()
        headers["Authentication-Info"] = "nextnonce=\"deadbeef\", qop=auth, rspauth=\"x\""
        #expect(DigestChallenge.nextNonce(headers: headers) == "deadbeef")
        #expect(DigestChallenge.nextNonce(headers: HTTPHeaders()) == nil)
    }
}

// MARK: - Store

@Suite struct DigestStoreTests {

    /// A fresh store cannot authenticate: the first request must go out unauthenticated, because
    /// the realm is not known until the device names it.
    @Test func digestStoreProducesNoHeaderBeforeAChallenge() async {
        let store = DigestStore(random: SplitMix64RandomSource(seed: 1))
        #expect(await store.header(for: "GET", uri: "/ISAPI/System/deviceInfo",
                                   credential: TestClientFactory.goodCredential) == nil)
    }

    /// `nc` starts at one and increments per request; a value is never reused for a nonce.
    @Test func digestStoreIncrementsNonceCountPerRequest() async throws {
        let store = DigestStore(random: SplitMix64RandomSource(seed: 1))
        await store.absorb(DigestChallenge(realm: "r", nonce: "n", qop: ["auth"]))
        let first = try #require(await store.header(for: "GET", uri: "/a",
                                                    credential: TestClientFactory.goodCredential))
        let second = try #require(await store.header(for: "GET", uri: "/a",
                                                     credential: TestClientFactory.goodCredential))
        #expect(first.contains("nc=00000001"))
        #expect(second.contains("nc=00000002"))
    }

    /// A new nonce restarts the counter and draws a new `cnonce`.
    @Test func digestStoreResetsCounterOnNewNonce() async throws {
        let store = DigestStore(random: SplitMix64RandomSource(seed: 7))
        await store.absorb(DigestChallenge(realm: "r", nonce: "n1", qop: ["auth"]))
        let first = try #require(await store.header(for: "GET", uri: "/a",
                                                    credential: TestClientFactory.goodCredential))
        await store.absorb(DigestChallenge(realm: "r", nonce: "n2", qop: ["auth"]))
        let second = try #require(await store.header(for: "GET", uri: "/a",
                                                     credential: TestClientFactory.goodCredential))
        #expect(first.contains("nc=00000001"))
        #expect(second.contains("nc=00000001"))
        #expect(second.contains("nonce=\"n2\""))
    }

    /// The same nonce answering a credentialed request is a rejected credential.
    @Test func digestStoreTreatsRepeatedNonceAsAuthenticationFailure() async {
        let store = DigestStore(random: SplitMix64RandomSource(seed: 1))
        var headers = HTTPHeaders()
        headers.append("WWW-Authenticate", "Digest realm=\"r\", nonce=\"n\", stale=\"FALSE\"")
        #expect(await store.absorb(headers: headers, didSendAuthorization: false,
                                   isTLS: false) == .retry)
        _ = await store.header(for: "GET", uri: "/a",
                               credential: TestClientFactory.goodCredential)
        #expect(await store.absorb(headers: headers, didSendAuthorization: true,
                                   isTLS: false) == .authenticationFailed)
    }

    /// `stale="TRUE"` is a retry, never a failure — the nonce expired, the password did not change.
    @Test func digestStoreTreatsStaleChallengeAsRetry() async {
        let store = DigestStore(random: SplitMix64RandomSource(seed: 1))
        var first = HTTPHeaders()
        first.append("WWW-Authenticate", "Digest realm=\"r\", nonce=\"n\", stale=\"FALSE\"")
        _ = await store.absorb(headers: first, didSendAuthorization: false, isTLS: false)
        _ = await store.header(for: "GET", uri: "/a",
                               credential: TestClientFactory.goodCredential)
        var stale = HTTPHeaders()
        stale.append("WWW-Authenticate", "Digest realm=\"r\", nonce=\"n\", stale=\"TRUE\"")
        #expect(await store.absorb(headers: stale, didSendAuthorization: true,
                                   isTLS: false) == .retry)
    }

    /// A `SHA-256`-only device over plain HTTP is refused, not silently downgraded to Basic.
    @Test func digestStoreRefusesUnsupportedAlgorithmOverPlainHTTP() async {
        let store = DigestStore(random: SplitMix64RandomSource(seed: 1), allowBasicFallback: false)
        var headers = HTTPHeaders()
        headers.append("WWW-Authenticate", "Digest realm=\"r\", nonce=\"n\", algorithm=SHA-256")
        headers.append("WWW-Authenticate", "Basic realm=\"r\"")
        #expect(await store.absorb(headers: headers, didSendAuthorization: false,
                                   isTLS: false) == .unsupported("SHA-256"))
    }

    /// Over TLS, with the fallback permitted, the same device gets Basic.
    @Test func digestStoreFallsBackToBasicOverTLS() async throws {
        let store = DigestStore(random: SplitMix64RandomSource(seed: 1), allowBasicFallback: true)
        var headers = HTTPHeaders()
        headers.append("WWW-Authenticate", "Digest realm=\"r\", nonce=\"n\", algorithm=SHA-256")
        headers.append("WWW-Authenticate", "Basic realm=\"r\"")
        #expect(await store.absorb(headers: headers, didSendAuthorization: false,
                                   isTLS: true) == .retry)
        let header = try #require(await store.header(for: "GET", uri: "/a",
                                                     credential: TestClientFactory.goodCredential))
        #expect(header.hasPrefix("Basic "))
    }

    /// Invalidation drops everything, so a credential change cannot reuse a nonce count.
    @Test func digestStoreInvalidationClearsTheChallenge() async {
        let store = DigestStore(random: SplitMix64RandomSource(seed: 1))
        await store.absorb(DigestChallenge(realm: "r", nonce: "n", qop: ["auth"]))
        await store.invalidate(reason: "credential changed")
        #expect(await store.currentChallenge == nil)
        #expect(await store.header(for: "GET", uri: "/a",
                                   credential: TestClientFactory.goodCredential) == nil)
    }

    /// A `nextnonce` from `Authentication-Info` replaces the cached nonce and restarts `nc`.
    @Test func digestStoreAdoptsNextNonce() async throws {
        let store = DigestStore(random: SplitMix64RandomSource(seed: 1))
        await store.absorb(DigestChallenge(realm: "r", nonce: "n1", qop: ["auth"]))
        var headers = HTTPHeaders()
        headers["Authentication-Info"] = "nextnonce=\"n2\""
        await store.adoptNextNonce(headers: headers)
        let header = try #require(await store.header(for: "GET", uri: "/a",
                                                     credential: TestClientFactory.goodCredential))
        #expect(header.contains("nonce=\"n2\""))
        #expect(header.contains("nc=00000001"))
    }
}

// MARK: - Headers

@Suite struct HTTPHeadersReadingTests {

    /// Lookup is case-insensitive, because no two firmwares spell a header name the same way.
    @Test func httpHeadersLookUpNamesCaseInsensitively() {
        var headers = HTTPHeaders()
        headers.append("Content-Type", "application/xml")
        #expect(headers["content-type"] == "application/xml")
        #expect(headers["CONTENT-TYPE"] == "application/xml")
        #expect(headers["Content-Length"] == nil)
    }

    /// Duplicates are kept and ordered: a 401 may carry two `WWW-Authenticate` headers and the
    /// second one is not noise.
    @Test func httpHeadersKeepDuplicatesInOrder() {
        var headers = HTTPHeaders()
        headers.append("WWW-Authenticate", "Digest realm=\"a\"")
        headers.append("www-authenticate", "Basic realm=\"a\"")
        #expect(headers.all("WWW-Authenticate").count == 2)
        #expect(headers.all("WWW-Authenticate")[0].hasPrefix("Digest"))
        #expect(headers["WWW-Authenticate"]?.hasPrefix("Digest") == true)
        #expect(headers.count == 2)
    }

    /// Assigning collapses duplicates to one value; assigning `nil` removes every copy.
    @Test func httpHeadersAssignmentCollapsesDuplicates() {
        var headers = HTTPHeaders()
        headers.append("X", "1")
        headers.append("x", "2")
        headers["X"] = "3"
        #expect(headers.all("x") == ["3"])
        headers["x"] = nil
        #expect(headers.all("X").isEmpty)
    }

    /// Headers survive the `Codable` round trip that puts them in a diagnostics bundle.
    @Test func httpHeadersRoundTripThroughCodable() throws {
        var headers = HTTPHeaders()
        headers.append("Content-Type", "application/xml")
        headers.append("WWW-Authenticate", "Digest realm=\"IP Camera(51253)\"")
        let decoded = try JSONDecoder().decode(HTTPHeaders.self,
                                               from: try JSONEncoder().encode(headers))
        #expect(decoded == headers)
        #expect(decoded["www-authenticate"] == "Digest realm=\"IP Camera(51253)\"")
    }
}

// MARK: - Lockout registry

@Suite struct AuthLockoutRegistryTests {

    /// Two is terminal.
    @Test func authLockoutRegistryBlocksAfterTwoFailures() async {
        let registry = AuthLockoutRegistry()
        #expect(await registry.isBlocked(host: "h", port: 80, account: "admin") == false)
        #expect(await registry.recordFailure(host: "h", port: 80, account: "admin") == 1)
        #expect(await registry.isBlocked(host: "h", port: 80, account: "admin") == false)
        #expect(await registry.recordFailure(host: "h", port: 80, account: "admin") == 2)
        #expect(await registry.isBlocked(host: "h", port: 80, account: "admin"))
    }

    /// Counters are per (host, port, account): one wrong password does not block another device.
    @Test func authLockoutRegistryIsKeyedPerHostPortAndAccount() async {
        let registry = AuthLockoutRegistry()
        await registry.recordFailure(host: "h1", port: 80, account: "admin")
        await registry.recordFailure(host: "h1", port: 80, account: "admin")
        #expect(await registry.isBlocked(host: "h1", port: 80, account: "admin"))
        #expect(await registry.isBlocked(host: "h2", port: 80, account: "admin") == false)
        #expect(await registry.isBlocked(host: "h1", port: 8080, account: "admin") == false)
        #expect(await registry.isBlocked(host: "h1", port: 80, account: "viewer") == false)
    }

    /// A success clears the counter; that is the only automatic way out.
    @Test func authLockoutRegistryResetClearsTheCounter() async {
        let registry = AuthLockoutRegistry()
        await registry.recordFailure(host: "h", port: 80, account: "admin")
        await registry.reset(host: "h", port: 80, account: "admin")
        #expect(await registry.failureCount(host: "h", port: 80, account: "admin") == 0)
    }
}
