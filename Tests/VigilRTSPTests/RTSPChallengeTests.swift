//
//  RTSPChallengeTests.swift
//  VigilRTSPTests
//
//  `WWW-Authenticate` parsing against the forms Hikvision firmware actually emits: no `qop`, a
//  realm with parentheses and commas, `stale="FALSE"` quoted and upper-case, and two challenges in
//  one header value.
//  Covers docs/spec-rtsp.md §6.1–6.2 and the RTSPChallengeTests row of §18.2.
//

import Testing

@testable import VigilRTSP

@Suite struct RTSPChallengeTests {

    /// The exact header a DS-2CD2043G2-I sends (docs/spec-rtsp.md §6.1).
    @Test func challengeParsesTheHikvisionCameraForm() throws {
        let challenges = RTSPChallenge.parseAll(
            "Digest realm=\"IP Camera(52491)\", nonce=\"3a2f5c8e1b7d4906f2e5a8c1d4b70e93\", "
            + "stale=\"FALSE\"")
        #expect(challenges.count == 1)
        let challenge = try #require(challenges.first)
        #expect(challenge.scheme == "Digest")
        #expect(challenge.isDigest)
        #expect(challenge.realm == "IP Camera(52491)")
        #expect(challenge.nonce == "3a2f5c8e1b7d4906f2e5a8c1d4b70e93")
        #expect(challenge.qop.isEmpty)                       // RFC 2069, the primary path
        #expect(challenge.algorithm == "MD5")
        #expect(!challenge.specifiesAlgorithm)
        #expect(!challenge.stale)
        #expect(challenge.opaque == nil)
        #expect(challenge.isSupported)
    }

    @Test func challengeParsesTheNVRQopForm() throws {
        let challenges = RTSPChallenge.parseAll(
            "Digest realm=\"DS-7608NI-K2(24680)\", nonce=\"b7c41e0a9d3f625814ae7c0b6d29f4e1\", "
            + "qop=\"auth,auth-int\", opaque=\"5ccc069c\", algorithm=MD5")
        let challenge = try #require(challenges.first)
        #expect(challenge.qop == ["auth", "auth-int"])
        #expect(challenge.opaque == "5ccc069c")
        #expect(challenge.algorithm == "MD5")
        #expect(challenge.specifiesAlgorithm)
        #expect(challenge.isSupported)
    }

    /// A comma inside the quoted realm must not split the challenge — the bug that makes a client
    /// authenticate against the realm `IP Camera(52491)` and fail forever on `Building 3`.
    @Test func challengeKeepsACommaInsideTheRealm() throws {
        let challenges = RTSPChallenge.parseAll(
            "Digest realm=\"IP Camera(52491), Building 3\", nonce=\"abc\"")
        #expect(challenges.count == 1)
        let challenge = try #require(challenges.first)
        #expect(challenge.realm == "IP Camera(52491), Building 3")
        #expect(challenge.nonce == "abc")
    }

    @Test func challengeSplitsTwoChallengesInOneHeaderValue() throws {
        let challenges = RTSPChallenge.parseAll(
            "Digest realm=\"IP Camera(52491)\", nonce=\"abc\", Basic realm=\"IP Camera(52491)\"")
        #expect(challenges.count == 2)
        #expect(challenges[0].isDigest)
        #expect(challenges[0].nonce == "abc")
        #expect(challenges[1].isBasic)
        #expect(challenges[1].realm == "IP Camera(52491)")
        #expect(challenges[1].nonce == nil)
    }

    @Test func challengeReadsStaleInEverySpelling() {
        #expect(RTSPChallenge.parseAll("Digest realm=\"r\", stale=\"TRUE\"").first?.stale == true)
        #expect(RTSPChallenge.parseAll("Digest realm=\"r\", stale=true").first?.stale == true)
        #expect(RTSPChallenge.parseAll("Digest realm=\"r\", stale=\"FALSE\"").first?.stale == false)
        #expect(RTSPChallenge.parseAll("Digest realm=\"r\", stale=false").first?.stale == false)
        #expect(RTSPChallenge.parseAll("Digest realm=\"r\"").first?.stale == false)
    }

    @Test func challengeNormalisesAlgorithmSpellings() {
        #expect(RTSPChallenge.parseAll("Digest algorithm=MD5").first?.algorithm == "MD5")
        #expect(RTSPChallenge.parseAll("Digest algorithm=\"MD5\"").first?.algorithm == "MD5")
        #expect(RTSPChallenge.parseAll("Digest algorithm=md5-sess").first?.algorithm == "MD5-sess")
        #expect(RTSPChallenge.parseAll("Digest algorithm=SHA-256").first?.algorithm == "SHA-256")
        #expect(RTSPChallenge.parseAll("Digest algorithm=md5-sess").first?.isSessionAlgorithm == true)
    }

    @Test func challengeWithoutANonceIsUnsupported() throws {
        let challenge = try #require(RTSPChallenge.parseAll("Digest realm=\"r\"").first)
        #expect(!challenge.isSupported)
    }

    @Test func challengeOfferingOnlyAuthIntIsUnsupported() throws {
        let challenge = try #require(
            RTSPChallenge.parseAll("Digest realm=\"r\", nonce=\"n\", qop=\"auth-int\"").first)
        #expect(!challenge.isSupported)
    }

    @Test func challengeWithAnUnknownAlgorithmIsUnsupported() throws {
        let challenge = try #require(
            RTSPChallenge.parseAll("Digest realm=\"r\", nonce=\"n\", algorithm=SHA-256").first)
        #expect(!challenge.isSupported)
    }

    @Test func challengeAcceptsUnquotedValuesAndSpacesAroundEquals() throws {
        let challenge = try #require(
            RTSPChallenge.parseAll("Digest realm = \"IP Camera(1)\" , nonce = abc123").first)
        #expect(challenge.realm == "IP Camera(1)")
        #expect(challenge.nonce == "abc123")
    }

    @Test func challengeKeepsABareSchemeToken() throws {
        let challenges = RTSPChallenge.parseAll("Negotiate")
        #expect(challenges.count == 1)
        #expect(challenges[0].scheme == "Negotiate")
        #expect(!challenges[0].isSupported)
    }

    @Test func challengeIgnoresUnknownParametersAndEmptyInput() {
        let challenges = RTSPChallenge.parseAll(
            "Digest realm=\"r\", nonce=\"n\", domain=\"/live\", charset=UTF-8, userhash=false")
        #expect(challenges.count == 1)
        #expect(challenges[0].isSupported)
        #expect(RTSPChallenge.parseAll("").isEmpty)
        #expect(RTSPChallenge.parseAll("   ").isEmpty)
    }

    // MARK: - Selection

    @Test func challengeSelectionPrefersDigestOverBasic() throws {
        let challenges = RTSPChallenge.parseAll(
            "Digest realm=\"r\", nonce=\"n\", Basic realm=\"r\"")
        let chosen = try #require(RTSPChallenge.select(from: challenges,
                                                       allowBasicOverPlaintext: true, isTLS: false))
        #expect(chosen.isDigest)
    }

    @Test func challengeSelectionRefusesBasicOnPlaintextWithoutOptIn() {
        let challenges = RTSPChallenge.parseAll("Basic realm=\"IP Camera(52491)\"")
        #expect(RTSPChallenge.select(from: challenges,
                                     allowBasicOverPlaintext: false, isTLS: false) == nil)
        #expect(RTSPChallenge.select(from: challenges,
                                     allowBasicOverPlaintext: false, isTLS: true)?.isBasic == true)
        #expect(RTSPChallenge.select(from: challenges,
                                     allowBasicOverPlaintext: true, isTLS: false)?.isBasic == true)
    }
}
