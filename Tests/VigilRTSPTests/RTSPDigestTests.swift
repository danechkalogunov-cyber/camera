//
//  RTSPDigestTests.swift
//  VigilRTSPTests
//
//  Every golden Digest vector of docs/spec-rtsp.md §6.5, asserted as exact hashes: the RFC 2617
//  §3.5 worked example, the Hikvision camera no-`qop` rows, the NVR `qop=auth` rows with their `nc`
//  ladder, `MD5-sess`, and Basic. Plus the rules that keep a wrong password from locking an
//  account: two credentialed 401s are terminal, and `reset()` does not forgive them.
//
//  The expected values are the specification's, which were computed from the credentials it names;
//  none is claimed to have been captured from hardware.
//

import Testing

import VigilProtocols

@testable import VigilRTSP

@Suite struct RTSPDigestTests {

    // MARK: - (a) RFC 2617 §3.5

    /// The published worked example. Its method is `GET`, which no `RTSPMethod` can express, so it
    /// exercises `RTSPDigest` — the same arithmetic `RTSPAuthenticator` calls.
    @Test func digestReproducesTheRFC2617WorkedExample() {
        let ha1 = RTSPDigest.ha1(username: "Mufasa", realm: "testrealm@host.com",
                                 password: "Circle Of Life")
        let ha2 = RTSPDigest.ha2(method: "GET", uri: "/dir/index.html")
        let response = RTSPDigest.response(ha1: ha1,
                                           nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093",
                                           nonceCount: "00000001", cnonce: "0a4f113b",
                                           qop: "auth", ha2: ha2)
        #expect(ha1 == "939e7578ed9e3c518a452acee763bce9")
        #expect(ha2 == "39aff3a2bab6126f332b942af96d3366")
        #expect(response == "6629fae49393a05397450978507c4ef1")
    }

    // MARK: - (b) Hikvision camera, no qop

    /// Every row of §6.5(b). The digest URI is the request-line URI byte for byte, which is why the
    /// two `SETUP` rows differ: their URIs are the per-track control URLs.
    @Test func digestReproducesEveryHikvisionNoQopRow() {
        let base = MessageLayerFixtures.cameraBase
        let rows: [(RTSPMethod, String, String, String)] = [
            (.options, base, "430442026acf176cb1cd78f7bdd97904", "7a71d2670d28b6741cd8311d5c2faa39"),
            (.describe, base, "b5032047f3acc3227e88a91732cc21a9", "33439787cead5b387dab032b929cd5aa"),
            (.setup, base + "/trackID=1",
             "86636168ed1619b40ab33a3e55c3439f", "cc40451c686fe00f49dab7ead43cf51e"),
            (.setup, base + "/trackID=2",
             "7d43bcddfadd3ec1c08603ef2af3adb6", "15f95fdc9d48a6f4d84fdbb235cb8047"),
            (.play, base, "4fb324fa81cda8c7032ca1f0844fd4e1", "ed5735beb54441291f97015c1f94fa9e"),
            (.pause, base, "61230d880bd8668da127109c32b7b47e", "ec60e61d1e102f8e0db40f1572ab3c2b"),
            (.getParameter, base,
             "110277f5940d28695bfcb9ced7472a3c", "7784fa4d5936a634efec80eeb5700774"),
            (.teardown, base, "aec2fa393b8980483d7a253d0950f1c2", "6c562c1ab1c2a7b664e7303d52167fcc"),
        ]
        let ha1 = RTSPDigest.ha1(username: "admin", realm: "IP Camera(52491)", password: "Hik12345")
        #expect(ha1 == "b77ebbd873cb0b706fec7d517a8bd70e")

        for (method, uri, expectedHA2, expectedResponse) in rows {
            let ha2 = RTSPDigest.ha2(method: method.rawValue, uri: uri)
            #expect(ha2 == expectedHA2, "HA2 for \(method.rawValue) \(uri)")

            var authenticator = RTSPAuthenticator(credential: MessageLayerFixtures.cameraCredential,
                                                  random: SplitMix64RandomSource(seed: 7))
            authenticator.absorb(MessageLayerFixtures.cameraChallenge)
            let header = authenticator.authorization(for: method, uri: uri) ?? ""
            #expect(header.contains("response=\"\(expectedResponse)\""),
                    "response for \(method.rawValue) \(uri)")
            #expect(header.contains("uri=\"\(uri)\""))
            #expect(!header.contains("qop"))
            #expect(!header.contains("nc="))
            #expect(!header.contains("algorithm"))            // the camera sent none, we echo none
        }
    }

    /// The `Authorization` line of docs/spec-rtsp.md §11.1 step (5), byte for byte.
    @Test func digestBuildsTheExactCameraAuthorizationHeader() throws {
        var authenticator = RTSPAuthenticator(credential: MessageLayerFixtures.cameraCredential,
                                              random: SplitMix64RandomSource(seed: 1))
        authenticator.absorb(MessageLayerFixtures.cameraChallenge)
        let header = try #require(authenticator.authorization(for: .describe,
                                                              uri: MessageLayerFixtures.cameraBase))
        let expected = "Digest username=\"admin\", realm=\"IP Camera(52491)\", "
            + "nonce=\"3a2f5c8e1b7d4906f2e5a8c1d4b70e93\", "
            + "uri=\"rtsp://192.168.1.64:554/Streaming/Channels/101\", "
            + "response=\"33439787cead5b387dab032b929cd5aa\""
        #expect(header == expected)
    }

    /// `stale` is a re-authentication, not a failure: adopt the new nonce and retry.
    @Test func digestReauthenticatesOnStaleWithoutCountingAFailure() throws {
        var authenticator = RTSPAuthenticator(credential: MessageLayerFixtures.cameraCredential,
                                              random: SplitMix64RandomSource(seed: 3))
        authenticator.absorb(MessageLayerFixtures.cameraChallenge)
        _ = authenticator.authorization(for: .describe, uri: MessageLayerFixtures.cameraBase)

        let stale = RTSPChallenge.parseAll("Digest realm=\"IP Camera(52491)\", "
            + "nonce=\"9d1c7b3e5f2a48061c8e0b9a7d3f6520\", stale=\"TRUE\"")
        authenticator.absorb(stale)
        #expect(authenticator.lastOutcome == .retry)
        #expect(authenticator.failureCount == 0)

        let header = try #require(authenticator.authorization(for: .describe,
                                                              uri: MessageLayerFixtures.cameraBase))
        #expect(header.contains("nonce=\"9d1c7b3e5f2a48061c8e0b9a7d3f6520\""))
        #expect(header.contains("response=\"7e59f57bd7e98d245ea2633e2b19d7b1\""))
    }

    /// A `401` carrying a *different* nonce is not a failed login either (API_CONTRACT §2 R-25.1).
    @Test func digestTreatsANewNonceAsARetryNotAFailure() {
        var authenticator = RTSPAuthenticator(credential: MessageLayerFixtures.cameraCredential,
                                              random: SplitMix64RandomSource(seed: 5))
        authenticator.absorb(MessageLayerFixtures.cameraChallenge)
        _ = authenticator.authorization(for: .describe, uri: MessageLayerFixtures.cameraBase)
        authenticator.absorb(RTSPChallenge.parseAll(
            "Digest realm=\"IP Camera(52491)\", nonce=\"0000000000000000000000000000ffff\""))
        #expect(authenticator.lastOutcome == .retry)
        #expect(authenticator.failureCount == 0)
    }

    // MARK: - (c) Hikvision NVR, qop=auth

    /// Every row of §6.5(c), in one session, so the `nc` ladder is exercised end to end: `nc`
    /// increments per request while `cnonce` stays fixed for the nonce.
    @Test func digestReproducesTheNVRQopLadderWithIncrementingNonceCount() {
        // The word whose little-endian bytes are 1c 8f 4a 09 be 23 d7 f5 — the published cnonce.
        var authenticator = RTSPAuthenticator(credential: MessageLayerFixtures.nvrCredential,
                                              random: MessageLayerFixedRandom([0xf5d7_23be_094a_8f1c]))
        authenticator.absorb(MessageLayerFixtures.nvrChallenge)
        #expect(authenticator.clientNonce == "1c8f4a09be23d7f5")
        #expect(authenticator.lastOutcome == .retry)

        let base = MessageLayerFixtures.nvrBase
        let rows: [(String, RTSPMethod, String, String, String)] = [
            ("00000001", .describe, base,
             "c8a2ad16043ed9fd8276ea879db655a3", "7a525b747736353ecd4833fd99cbc565"),
            ("00000002", .setup, base + "/trackID=1",
             "f45509227068c34a973f992ba7339ff5", "530838bed48ccf4b34d73cab7ccba0ce"),
            ("00000003", .setup, base + "/trackID=2",
             "43ae3e81b5dd3dd2faf75ef0e4e6f674", "299acee76e354c38820f5d0089d9969a"),
            ("00000004", .play, base,
             "1ad5bca995c5819208fb45e4fe9dee04", "3df6c275791b14ea383f1f11c5217113"),
            ("00000005", .getParameter, base,
             "1d540e54a03e0f7a00a831e68569bcb1", "b80b79fd9f31c6761ace1b2e2df0b9cd"),
            ("00000006", .teardown, base,
             "ffc8bfa4dd72d833d1a82ff79357bfdb", "a271fd1b76b1861f447dcbd4767daa97"),
        ]
        for (nonceCount, method, uri, expectedHA2, expectedResponse) in rows {
            #expect(authenticator.nextNonceCount == nonceCount)
            #expect(RTSPDigest.ha2(method: method.rawValue, uri: uri) == expectedHA2)
            let header = authenticator.authorization(for: method, uri: uri) ?? ""
            #expect(header.contains("nc=\(nonceCount)"), "nc for \(method.rawValue)")
            #expect(header.contains("qop=auth"))
            #expect(header.contains("cnonce=\"1c8f4a09be23d7f5\""))
            #expect(header.contains("response=\"\(expectedResponse)\""),
                    "response for \(method.rawValue) at nc \(nonceCount)")
        }
    }

    @Test func digestRegeneratesTheClientNonceAndResetsCountOnANewNonce() {
        var authenticator = RTSPAuthenticator(
            credential: MessageLayerFixtures.nvrCredential,
            random: MessageLayerFixedRandom([0xf5d7_23be_094a_8f1c, 0x0102_0304_0506_0708]))
        authenticator.absorb(MessageLayerFixtures.nvrChallenge)
        _ = authenticator.authorization(for: .describe, uri: MessageLayerFixtures.nvrBase)
        _ = authenticator.authorization(for: .play, uri: MessageLayerFixtures.nvrBase)
        #expect(authenticator.nextNonceCount == "00000003")
        let firstCNonce = authenticator.clientNonce

        authenticator.absorb(RTSPChallenge.parseAll(
            "Digest realm=\"DS-7608NI-K2(24680)\", nonce=\"aaaa1111bbbb2222cccc3333dddd4444\", "
            + "qop=\"auth\""))
        #expect(authenticator.nextNonceCount == "00000001")
        #expect(authenticator.clientNonce != firstCNonce)
        #expect(authenticator.clientNonce == "0807060504030201")
    }

    @Test func digestEchoesOpaqueVerbatimAndLast() throws {
        var authenticator = RTSPAuthenticator(credential: MessageLayerFixtures.nvrCredential,
                                              random: MessageLayerFixedRandom([0xf5d7_23be_094a_8f1c]))
        authenticator.absorb(RTSPChallenge.parseAll(
            "Digest realm=\"DS-7608NI-K2(24680)\", nonce=\"b7c41e0a9d3f625814ae7c0b6d29f4e1\", "
            + "qop=\"auth\", opaque=\"5ccc069c403ebaf9f0171e9517f40e41\""))
        let header = try #require(authenticator.authorization(for: .describe,
                                                              uri: MessageLayerFixtures.nvrBase))
        #expect(header.hasSuffix("opaque=\"5ccc069c403ebaf9f0171e9517f40e41\""))
    }

    // MARK: - (d) MD5-sess

    @Test func digestComputesTheSessionAlgorithmHA1() {
        let base = RTSPDigest.ha1(username: "admin", realm: "IP Camera(52491)",
                                  password: "Hik12345")
        let sessionHA1 = RTSPDigest.sessionHA1(base: base,
                                               nonce: "3a2f5c8e1b7d4906f2e5a8c1d4b70e93",
                                               cnonce: "1c8f4a09be23d7f5")
        #expect(sessionHA1 == "8e02847dbbf1e8b0643c4dc284808c30")
    }

    @Test func digestUsesTheSessionHA1AndEchoesTheAlgorithm() throws {
        var authenticator = RTSPAuthenticator(credential: MessageLayerFixtures.cameraCredential,
                                              random: MessageLayerFixedRandom([0xf5d7_23be_094a_8f1c]))
        authenticator.absorb(RTSPChallenge.parseAll(
            "Digest realm=\"IP Camera(52491)\", nonce=\"3a2f5c8e1b7d4906f2e5a8c1d4b70e93\", "
            + "algorithm=MD5-sess"))
        let header = try #require(authenticator.authorization(for: .describe,
                                                              uri: MessageLayerFixtures.cameraBase))
        #expect(header.contains("algorithm=MD5-sess"))
        let expected = RTSPDigest.response(
            ha1: "8e02847dbbf1e8b0643c4dc284808c30",
            nonce: "3a2f5c8e1b7d4906f2e5a8c1d4b70e93",
            ha2: RTSPDigest.ha2(method: "DESCRIBE", uri: MessageLayerFixtures.cameraBase))
        #expect(header.contains("response=\"\(expected)\""))
    }

    // MARK: - (e) Basic

    @Test func basicAuthorizationMatchesTheGoldenEncodings() throws {
        for (credential, expected) in [(MessageLayerFixtures.cameraCredential,
                                        "Basic YWRtaW46SGlrMTIzNDU="),
                                       (MessageLayerFixtures.nvrCredential,
                                        "Basic YWRtaW46TnZyIzIwMjQ=")] {
            var authenticator = RTSPAuthenticator(credential: credential,
                                                  random: SplitMix64RandomSource(seed: 2),
                                                  allowBasicOverPlaintext: true)
            authenticator.absorb(RTSPChallenge.parseAll("Basic realm=\"IP Camera(52491)\""))
            let header = try #require(authenticator.authorization(for: .describe,
                                                                  uri: MessageLayerFixtures.cameraBase))
            #expect(header == expected)
        }
    }

    @Test func basicIsRefusedOnPlaintextWithoutTheOptIn() {
        var authenticator = RTSPAuthenticator(credential: MessageLayerFixtures.cameraCredential,
                                              random: SplitMix64RandomSource(seed: 2))
        authenticator.absorb(RTSPChallenge.parseAll("Basic realm=\"IP Camera(52491)\""))
        let header = authenticator.authorization(for: .describe, uri: MessageLayerFixtures.cameraBase)
        #expect(authenticator.lastOutcome == .failed(.authRejected))
        #expect(header == nil)
    }

    // MARK: - Lockout safety (API_CONTRACT §2 R-25)

    /// Two credentialed 401s and the authenticator is done — for good. Hikvision locks an account
    /// after roughly five failures, so a client that keeps trying locks the user out of their own
    /// camera.
    @Test func digestStopsAfterTwoCredentialedRejections() {
        var authenticator = RTSPAuthenticator(credential: MessageLayerFixtures.cameraCredential,
                                              random: SplitMix64RandomSource(seed: 11))
        authenticator.absorb(MessageLayerFixtures.cameraChallenge)
        #expect(authenticator.lastOutcome == .retry)
        let firstAttempt = authenticator.authorization(for: .describe,
                                                       uri: MessageLayerFixtures.cameraBase)
        #expect(firstAttempt != nil)

        // First credentialed 401: same nonce, not stale. One retry remains, spent on the URI rung.
        authenticator.absorb(MessageLayerFixtures.cameraChallenge)
        let secondAttempt = authenticator.authorization(for: .describe,
                                                        uri: MessageLayerFixtures.cameraBase)
        #expect(authenticator.failureCount == 1)
        #expect(authenticator.lastOutcome == .retryWithURIFallback(rung: 1))
        #expect(secondAttempt != nil)

        // Second credentialed 401: terminal.
        authenticator.absorb(MessageLayerFixtures.cameraChallenge)
        let thirdAttempt = authenticator.authorization(for: .describe,
                                                       uri: MessageLayerFixtures.cameraBase)
        #expect(authenticator.failureCount == 2)
        #expect(authenticator.lastOutcome == .failed(.authRejected))
        #expect(authenticator.terminalFailure == .authRejected)
        #expect(thirdAttempt == nil)
        #expect(!authenticator.hasUsableState)
    }

    /// The terminality is in the error type, not only in a comment: `.authRejected` is
    /// `.retryAfterUserAction`, so no retry policy anywhere may schedule another attempt.
    @Test func digestTerminalErrorIsNotAutomaticallyRetryable() {
        let error = RTSPError.authRejected
        #expect(error.disposition == .retryAfterUserAction)
        #expect(!error.isAutomaticallyRetryable)
        #expect(error.severity == .fatal)
        #expect(RTSPError.credentialsMissing.disposition == .retryAfterUserAction)
    }

    /// Reconnecting clears the nonce, never the failure count — otherwise a reconnect loop would
    /// walk straight into the device's lockout threshold.
    @Test func digestResetKeepsTheFailureCountAndTerminalState() {
        var authenticator = RTSPAuthenticator(credential: MessageLayerFixtures.cameraCredential,
                                              random: SplitMix64RandomSource(seed: 13))
        authenticator.absorb(MessageLayerFixtures.cameraChallenge)
        _ = authenticator.authorization(for: .describe, uri: MessageLayerFixtures.cameraBase)
        authenticator.absorb(MessageLayerFixtures.cameraChallenge)
        authenticator.absorb(MessageLayerFixtures.cameraChallenge)
        #expect(authenticator.terminalFailure == .authRejected)

        authenticator.reset()
        let afterReset = authenticator.authorization(for: .options,
                                                     uri: MessageLayerFixtures.cameraBase)
        #expect(authenticator.failureCount == 2)
        #expect(authenticator.terminalFailure == .authRejected)
        #expect(afterReset == nil)
    }

    @Test func digestWithNoCredentialFailsWithCredentialsMissing() {
        var authenticator = RTSPAuthenticator(credential: nil,
                                              random: SplitMix64RandomSource(seed: 17))
        authenticator.absorb(MessageLayerFixtures.cameraChallenge)
        let header = authenticator.authorization(for: .describe,
                                                 uri: MessageLayerFixtures.cameraBase)
        #expect(authenticator.lastOutcome == .failed(.credentialsMissing))
        #expect(header == nil)
    }

    @Test func digestProducesNothingBeforeAChallengeArrives() {
        var authenticator = RTSPAuthenticator(credential: MessageLayerFixtures.cameraCredential,
                                              random: SplitMix64RandomSource(seed: 19))
        let header = authenticator.authorization(for: .options,
                                                 uri: MessageLayerFixtures.cameraBase)
        #expect(!authenticator.hasUsableState)
        #expect(header == nil)
    }

    // MARK: - URI fallback

    /// The compatibility rung changes only `uri=` and therefore `HA2`; the request line is the
    /// caller's business and is not touched here.
    @Test func digestURIFallbackDropsTheQueryOnTheSecondAttempt() throws {
        let playback = "rtsp://192.168.1.200:554/Streaming/tracks/301"
            + "?starttime=20240115T090000Z&endtime=20240115T093000Z"
        var authenticator = RTSPAuthenticator(credential: MessageLayerFixtures.nvrCredential,
                                              random: SplitMix64RandomSource(seed: 23))
        authenticator.absorb(MessageLayerFixtures.nvrChallenge)
        let first = try #require(authenticator.authorization(for: .describe, uri: playback))
        #expect(first.contains("uri=\"\(playback)\""))

        authenticator.absorb(MessageLayerFixtures.nvrChallenge)
        #expect(authenticator.lastOutcome == .retryWithURIFallback(rung: 1))
        let second = try #require(authenticator.authorization(for: .describe, uri: playback))
        #expect(second.contains("uri=\"rtsp://192.168.1.200:554/Streaming/tracks/301\""))
        #expect(!second.contains("starttime"))
    }

    // MARK: - Formula property

    /// Pins the no-`qop` formula independently of any literal: for pseudorandom credentials and
    /// URIs, the response is always `MD5(HA1 ":" nonce ":" HA2)`.
    @Test func digestNoQopFormulaHoldsForRandomInputs() {
        var generator = SplitMix64RandomSource(seed: 0x4F6C_DD1D_2545_F491)
        for iteration in 0 ..< 100 {
            let user = "user\(generator.next() % 100_000)"
            let password = Hex.lowercase(generator.randomBytes(6))
            let realm = "IP Camera(\(generator.next() % 99_999))"
            let nonce = Hex.lowercase(generator.randomBytes(16))
            let uri = "rtsp://192.168.1.\(generator.next() % 254 + 1):554/Streaming/Channels/"
                + "\(generator.next() % 1_600)?probe=\(iteration)"
            let method: RTSPMethod = [.options, .describe, .setup, .play,
                                      .teardown][Int(generator.next() % 5)]

            var authenticator = RTSPAuthenticator(credential: Credential(account: user,
                                                                         secret: password),
                                                  random: SplitMix64RandomSource(seed: 1))
            authenticator.absorb([RTSPChallenge(scheme: "Digest", realm: realm, nonce: nonce)])
            let header = authenticator.authorization(for: method, uri: uri) ?? ""

            let ha1 = MD5.hexDigest("\(user):\(realm):\(password)")
            let ha2 = MD5.hexDigest("\(method.rawValue):\(uri)")
            let expected = MD5.hexDigest("\(ha1):\(nonce):\(ha2)")
            #expect(header.contains("response=\"\(expected)\""), "iteration \(iteration)")
        }
    }

    // MARK: - Redaction

    @Test func digestAuthenticatorDescriptionRevealsNoSecret() {
        var authenticator = RTSPAuthenticator(credential: MessageLayerFixtures.cameraCredential,
                                              random: MessageLayerFixedRandom([0xf5d7_23be_094a_8f1c]))
        authenticator.absorb(MessageLayerFixtures.cameraChallenge)
        _ = authenticator.authorization(for: .describe, uri: MessageLayerFixtures.cameraBase)
        let text = authenticator.description
        #expect(text.contains("IP Camera(52491)"))
        #expect(!text.contains("Hik12345"))
        #expect(!text.contains("3a2f5c8e1b7d4906f2e5a8c1d4b70e93"))
        #expect(!text.contains("1c8f4a09be23d7f5"))
    }

    @Test func credentialDescriptionMasksTheSecret() {
        let credential = MessageLayerFixtures.cameraCredential
        #expect(!credential.description.contains("Hik12345"))
        #expect(!credential.debugDescription.contains("Hik12345"))
        #expect(credential.description.contains("admin"))
    }
}
