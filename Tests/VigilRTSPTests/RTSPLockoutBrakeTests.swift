//
//  RTSPLockoutBrakeTests.swift
//  VigilRTSPTests
//
//  The two per-connection brakes that keep a wrong password off the wire: the hard ceiling on
//  credentialed sends that closes the nonce-rotation loop, and the allowance of zero that lets a
//  path-ladder rung answer "does this path exist" without ever writing an `Authorization` header.
//  Tests 1 and 2 of docs/RULING-LOCKOUT.md §5. Covers §2.5, §2.6, §2.7 and API_CONTRACT §2 R-25.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilRTSP

// MARK: - Driver

/// A deterministic driver for these tests only.
///
/// `RTSPSessionMachineTests` has its own `Harness`, but it is `private` to that file and so is
/// invisible here — and this file must not edit a test file it did not create. The two are
/// independent by design: this one is deliberately small and counts exactly one thing.
private struct LockoutBrakeDriver {

    var machine: RTSPSessionMachine
    var now = MediaInstant.zero
    private(set) var actions: [RTSPAction] = []

    init(credentialedAttemptAllowance: Int) {
        var config = RTSPSessionConfig(url: Self.cameraURL)
        config.credentialedAttemptAllowance = credentialedAttemptAllowance
        machine = RTSPSessionMachine(config: config,
                                     credential: Self.credential,
                                     random: SplitMix64RandomSource(seed: 0xB0FFED),
                                     now: .zero)
    }

    static var cameraURL: RTSPURL {
        RTSPURL(string: "rtsp://192.168.1.64:554/Streaming/Channels/101")
            ?? RTSPURL(scheme: "rtsp", host: "192.168.1.64", port: 554,
                       path: "/Streaming/Channels/101")
    }

    static let credential = Credential(account: "admin", secret: "definitely-not-the-password")

    @discardableResult
    mutating func send(_ command: RTSPCommand) -> [RTSPAction] {
        let produced = machine.handle(command, now: now)
        actions += produced
        return produced
    }

    @discardableResult
    mutating func feed(_ text: String) -> [RTSPAction] {
        let produced = machine.ingest(Array(text.utf8), now: now)
        actions += produced
        return produced
    }

    /// Every `.send` payload concatenated: exactly the bytes this client put on the wire.
    var clientStream: String {
        var out = Data()
        for action in actions {
            if case let .send(data) = action { out.append(data) }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// How many requests carried an `Authorization` header. This is the number the device's own
    /// failed-login tally would have counted.
    var credentialedRequestCount: Int {
        clientStream.components(separatedBy: "\r\n")
            .filter { $0.hasPrefix("Authorization:") }
            .count
    }

    /// The terminal error the machine produced, if it produced one.
    var terminalError: RTSPError? {
        for action in actions.reversed() {
            if case let .fail(error) = action { return error }
        }
        return nil
    }
}

/// A `401` carrying one Digest challenge. `nonce` is the whole point of test 1, so it is a parameter.
///
/// The CSeq is omitted deliberately: `RTSPSessionMachine.handle(response:)` matches a response with
/// no CSeq to the outstanding request, which keeps these fixtures independent of the machine's
/// internal numbering. `stale` is never set — a silently rotated nonce is the case that used to be
/// unbounded.
private func lockoutBrakeUnauthorized(nonce: String, stale: Bool = false) -> String {
    let staleField = stale ? ", stale=\"TRUE\"" : ""
    return "RTSP/1.0 401 Unauthorized\r\n"
        + "WWW-Authenticate: Digest realm=\"IP Camera(52491)\", nonce=\"\(nonce)\"\(staleField)\r\n"
        + "\r\n"
}

// MARK: - Test 1 — the nonce-rotation loop is bounded

/// §5 test 1. A device that answers every credentialed request with a `401` carrying a **fresh**
/// nonce and no `stale` flag.
///
/// This used to be unbounded: `RTSPAuthenticator` correctly declines to count a rotated nonce as a
/// failed login, and the machine's only cap compared against that same counter — so every resend
/// carried credentials and nothing ever stopped, bounded in the field only by a twenty-second
/// watchdog, after which the whole path ladder ran again.
@Test func rtspSessionMachineStopsAfterThreeCredentialedSendsWhenTheNonceRotatesForever() {
    var driver = LockoutBrakeDriver(
        credentialedAttemptAllowance: RTSPAuthenticator.maxCredentialedSendsPerConnection)
    driver.send(.start)

    // The first 401 answers an uncredentialed OPTIONS: free, nothing reached the device.
    driver.feed(lockoutBrakeUnauthorized(nonce: "00000000000000000000000000000001"))
    // Every subsequent 401 answers a request that carried credentials, and every one rotates.
    for index in 2...12 {
        let nonce = String(format: "%032x", index)
        driver.feed(lockoutBrakeUnauthorized(nonce: nonce))
    }

    #expect(driver.credentialedRequestCount <= RTSPAuthenticator.maxCredentialedSendsPerConnection)
    #expect(driver.terminalError == .authRejected)
}

/// The same device, but with the production default allowance of two rather than the ceiling of
/// three: the tighter of the two brakes is the one that binds.
@Test func rtspSessionMachineSpendsOnlyTheAllowanceWhenTheNonceRotatesForever() {
    var driver = LockoutBrakeDriver(
        credentialedAttemptAllowance: RTSPAuthenticator.maxCredentialedFailures)
    driver.send(.start)
    driver.feed(lockoutBrakeUnauthorized(nonce: "00000000000000000000000000000001"))
    for index in 2...12 {
        driver.feed(lockoutBrakeUnauthorized(nonce: String(format: "%032x", index)))
    }
    #expect(driver.credentialedRequestCount == RTSPAuthenticator.maxCredentialedFailures)
    #expect(driver.terminalError == .authRejected)
}

/// A device that sets `stale=true` on every rejection buys back one attempt against the allowance
/// each time — RFC 2617 §3.2.1 says it has not rejected the credential — but never against the hard
/// ceiling. Whether real firmware increments its own tally on a `stale` 401 is unknown
/// (docs/RULING-LOCKOUT.md §6.1), so the ceiling has to hold regardless of the flag.
@Test func rtspSessionMachineStillBoundsAStaleHappyDeviceAtTheHardCeiling() {
    var driver = LockoutBrakeDriver(
        credentialedAttemptAllowance: RTSPAuthenticator.maxCredentialedFailures)
    driver.send(.start)
    driver.feed(lockoutBrakeUnauthorized(nonce: "00000000000000000000000000000001"))
    for index in 2...12 {
        driver.feed(lockoutBrakeUnauthorized(nonce: String(format: "%032x", index), stale: true))
    }
    #expect(driver.credentialedRequestCount == RTSPAuthenticator.maxCredentialedSendsPerConnection)
    #expect(driver.terminalError == .authRejected)
}

// MARK: - Test 2 — an allowance of zero sends nothing

/// §5 test 2. A rung of the path ladder that was granted no strikes meets a `401`.
///
/// It must answer "the path is right and I may not sign in" without writing a single credentialed
/// request. That is what lets rungs 2…5 of the ladder run at all after rung 1 spent the sequence's
/// one strike — they can still tell a `404` from a `401` against a device that does not challenge
/// them, and a rung that *is* challenged stops the ladder honestly instead of spending a login.
@Test func rtspSessionMachineWritesNoAuthorizationWhenTheAllowanceIsZero() {
    var driver = LockoutBrakeDriver(credentialedAttemptAllowance: 0)
    driver.send(.start)

    // The request line went out with no credentials, as every first OPTIONS does.
    #expect(driver.credentialedRequestCount == 0)

    driver.feed(lockoutBrakeUnauthorized(nonce: "0123456789abcdef0123456789abcdef"))

    #expect(driver.credentialedRequestCount == 0)
    #expect(driver.terminalError == .authRejected)

    // And it stays terminal: further challenges cannot talk it into signing.
    driver.feed(lockoutBrakeUnauthorized(nonce: "fedcba9876543210fedcba9876543210"))
    #expect(driver.credentialedRequestCount == 0)
}

// MARK: - The healthy session must not be caught by the cap

/// The regression the "clear on success" half of §2.5 exists to prevent.
///
/// A real session writes four credentialed requests — `DESCRIBE`, two `SETUP`s and a `PLAY` — after
/// its one `401`. A ceiling of three counted over the life of the connection would terminate that
/// session on the fourth request with `authRejected`, which is a wrong password reported for a camera
/// that is working. The counter is therefore a budget of credentialed sends **since the last one the
/// device accepted**, and this test pins that reading.
@Test func rtspAuthenticatorReturnsItsSendBudgetWhenTheDeviceAcceptsTheCredential() {
    var authenticator = RTSPAuthenticator(
        credential: LockoutBrakeDriver.credential,
        random: SplitMix64RandomSource(seed: 11),
        credentialedAttemptAllowance: RTSPAuthenticator.maxCredentialedFailures)
    authenticator.absorb(RTSPChallenge.parseAll(
        "Digest realm=\"IP Camera(52491)\", nonce=\"0123456789abcdef0123456789abcdef\""))

    for _ in 0..<6 {
        #expect(authenticator.hasCredentialedSendBudget)
        #expect(authenticator.authorization(for: .describe, uri: "rtsp://h/s") != nil)
        #expect(authenticator.credentialedSends == 1)
        authenticator.noteCredentialsAccepted()
        #expect(authenticator.credentialedSends == 0)
    }
    #expect(authenticator.terminalFailure == nil)
}

/// `reset()` is per-connection nonce hygiene and must not hand back the send budget: a reconnect that
/// cleared it would spend two more attempts per reconnect, forever, which is the failure R-25 exists
/// to prevent.
@Test func rtspAuthenticatorResetKeepsTheCredentialedSendCount() {
    var authenticator = RTSPAuthenticator(credential: LockoutBrakeDriver.credential,
                                          random: SplitMix64RandomSource(seed: 13))
    authenticator.absorb(RTSPChallenge.parseAll(
        "Digest realm=\"IP Camera(52491)\", nonce=\"0123456789abcdef0123456789abcdef\""))
    _ = authenticator.authorization(for: .describe, uri: "rtsp://h/s")
    #expect(authenticator.credentialedSends == 1)
    authenticator.reset()
    #expect(authenticator.credentialedSends == 1)
}
