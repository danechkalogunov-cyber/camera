//
//  ISAPIClientTests.swift
//  VigilISAPITests
//
//  The client end to end against a Digest-verifying stub device and a scripted one: pre-emptive
//  authentication, the query-bearing digest URI, the no-`qop` device, the two-failure hard block and
//  its survival across client instances, the lane gate, coalescing and the retry table.
//  Covers docs/spec-isapi.md §4.3–§4.7 and §5.3, and docs/API_CONTRACT.md §2 R-25.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilISAPI

// MARK: - Authentication

@Suite struct ISAPIClientAuthTests {

    /// The first request goes out unauthenticated, the 401 is absorbed, the resend carries
    /// `Authorization` — and every later request carries one **without** another 401.
    @Test func isapiClientAuthenticatesPreemptivelyAfterTheFirstChallenge() async throws {
        let device = DigestStubDevice()
        let client = TestClientFactory.digestClient(device: device)

        _ = try await client.get("/Security/userCheck")
        _ = try await client.get("/System/deviceInfo")

        let recorded = await device.recorded
        #expect(recorded.count == 3)                                  // 401, resend, then one more
        #expect(recorded[0].headers["Authorization"] == nil)
        #expect(recorded[1].headers["Authorization"] != nil)
        #expect(recorded[2].headers["Authorization"] != nil)
        #expect(await device.challengeCount == 1)
    }

    /// The no-`qop` device — the majority of the installed base — authenticates with the RFC 2069
    /// form and the header carries no `nc` or `cnonce` at all.
    @Test func isapiClientAuthenticatesAgainstNoQOPDevice() async throws {
        let device = DigestStubDevice(behaviour: .init(offersQOP: false))
        let client = TestClientFactory.digestClient(device: device)
        let response = try await client.get("/Security/userCheck")
        #expect(response.statusCode == 200)
        let headers = await device.authorizations
        #expect(headers.count == 1)
        #expect(headers[0].contains("qop") == false)
        #expect(await device.nonceCounts.isEmpty)
    }

    /// `qop="auth"` firmware gets `nc` values that increase and are never reused.
    @Test func isapiClientIncrementsNonceCountOnQOPDevice() async throws {
        let device = DigestStubDevice(behaviour: .init(offersQOP: true))
        let client = TestClientFactory.digestClient(device: device)
        _ = try await client.get("/Security/userCheck")
        _ = try await client.get("/System/deviceInfo")
        _ = try await client.get("/System/status")
        let counts = await device.nonceCounts
        #expect(counts == ["00000001", "00000002", "00000003"])
    }

    /// A request with query items is signed over path **plus** query. The stub device rejects a
    /// header whose `uri` is not the request-line URI, so a green test here is a real check of the
    /// single most common cause of a permanent 401.
    @Test func isapiClientSignsQueryBearingURIIncludingTheQuery() async throws {
        let device = DigestStubDevice()
        let client = TestClientFactory.digestClient(device: device)
        _ = try await client.get("/Security/userCheck")            // learn the challenge

        let response = try await client.get(
            "/Streaming/channels/102/picture",
            query: [URLQueryItem(name: "videoResolutionWidth", value: "640"),
                    URLQueryItem(name: "videoResolutionHeight", value: "360")])
        #expect(response.statusCode == 200)

        let recorded = await device.recorded
        let last = try #require(recorded.last)
        let header = try #require(last.headers["Authorization"])
        #expect(header.contains(
            "uri=\"/ISAPI/Streaming/channels/102/picture"
            + "?videoResolutionWidth=640&videoResolutionHeight=360\""))
    }

    /// `stale="TRUE"` costs a resend and **no** failure: the nonce expired, the password did not.
    @Test func isapiClientRetriesStaleChallengeWithoutCountingAFailure() async throws {
        let device = DigestStubDevice(behaviour: .init(staleOnFirstCredentialedRequest: true))
        let registry = AuthLockoutRegistry()
        let client = TestClientFactory.digestClient(device: device, registry: registry)
        let response = try await client.get("/Security/userCheck")
        #expect(response.statusCode == 200)
        #expect(await registry.failureCount(host: "192.168.1.64", port: 80, account: "admin") == 0)
        #expect(await device.challengeCount == 2)
    }

    /// A wrong password fails once with `.authenticationFailed`, then the **second** attempt is
    /// terminal: `.authBlockedLocally`, and nothing further reaches the device.
    @Test func isapiClientBlocksHardAfterTwoAuthenticationFailures() async throws {
        let device = DigestStubDevice()
        let registry = AuthLockoutRegistry()
        let client = TestClientFactory.digestClient(device: device,
                                                   credential: TestClientFactory.wrongCredential,
                                                   registry: registry)

        await #expect(throws: ISAPIError.authenticationFailed(username: "admin")) {
            try await client.get("/Security/userCheck")
        }
        let afterFirst = await device.recorded.count

        await #expect(throws: ISAPIError.authBlockedLocally(failures: 2)) {
            try await client.get("/Security/userCheck")
        }
        let afterSecond = await device.recorded.count
        #expect(afterSecond > afterFirst)

        // Third and fourth attempts must not reach the network at all.
        await #expect(throws: ISAPIError.authBlockedLocally(failures: 2)) {
            try await client.get("/System/deviceInfo")
        }
        await #expect(throws: ISAPIError.authBlockedLocally(failures: 2)) {
            try await client.get("/System/status")
        }
        #expect(await device.recorded.count == afterSecond)
    }

    /// The block **survives a new client instance**, because the counter is per (host, port,
    /// account) and lives outside any client. A per-object counter would let a rebuilt view or a
    /// second poller spend the device's five attempts in a second.
    @Test func isapiClientLockoutSurvivesAFreshClientInstance() async throws {
        let host = "10.77.0.9"                                     // unique to this test
        let device = DigestStubDevice()
        await AuthLockoutRegistry.shared.reset(host: host, port: 80, account: "admin")

        let first = ISAPIClient(endpoint: ISAPIEndpoint(host: host),
                                credential: TestClientFactory.wrongCredential,
                                transport: DigestStubTransport(device: device),
                                trustEvaluator: AlwaysTrustEvaluator(),
                                clock: InstantTestClock(),
                                random: SplitMix64RandomSource(seed: 1))
        await #expect(throws: ISAPIError.authenticationFailed(username: "admin")) {
            try await first.get("/Security/userCheck")
        }
        await #expect(throws: ISAPIError.authBlockedLocally(failures: 2)) {
            try await first.get("/Security/userCheck")
        }
        let requestsSoFar = await device.recorded.count

        // A brand-new client for the same device and account, with its own DigestStore.
        let second = ISAPIClient(endpoint: ISAPIEndpoint(host: host),
                                 credential: TestClientFactory.wrongCredential,
                                 transport: DigestStubTransport(device: device),
                                 trustEvaluator: AlwaysTrustEvaluator(),
                                 clock: InstantTestClock(),
                                 random: SplitMix64RandomSource(seed: 2))
        #expect(await second.isAuthBlocked)
        await #expect(throws: ISAPIError.authBlockedLocally(failures: 2)) {
            try await second.get("/Security/userCheck")
        }
        #expect(await device.recorded.count == requestsSoFar)      // not one more packet

        // And a new credential is the only way out.
        await second.setCredential(TestClientFactory.goodCredential)
        #expect(await second.isAuthBlocked == false)
        let response = try await second.get("/Security/userCheck")
        #expect(response.statusCode == 200)
        await AuthLockoutRegistry.shared.reset(host: host, port: 80, account: "admin")
    }

    /// A successful authenticated request clears the counter, so an intermittent failure does not
    /// accumulate towards a block over a long session.
    @Test func isapiClientClearsFailureCounterAfterSuccess() async throws {
        let device = DigestStubDevice()
        let registry = AuthLockoutRegistry()
        await registry.recordFailure(host: "192.168.1.64", port: 80, account: "admin")
        let client = TestClientFactory.digestClient(device: device, registry: registry)
        _ = try await client.get("/Security/userCheck")
        #expect(await registry.failureCount(host: "192.168.1.64", port: 80, account: "admin") == 0)
    }

    /// A device offering only SHA-256 over plain HTTP is refused with the scheme named, rather than
    /// downgraded to Basic over cleartext.
    @Test func isapiClientRefusesUnsupportedAuthenticationOverPlainHTTP() async throws {
        let device = DigestStubDevice(behaviour: .init(alsoOffersBasic: true,
                                                      unsupportedAlgorithm: "SHA-256"))
        let client = TestClientFactory.digestClient(device: device)
        await #expect(throws: ISAPIError.unsupportedAuthentication("SHA-256")) {
            try await client.get("/Security/userCheck")
        }
    }
}

// MARK: - Policy

@Suite struct ISAPIClientPolicyTests {

    /// The control lane never runs more than three requests at once, whatever the caller does.
    @Test func isapiClientLimitsControlConcurrencyToThree() async throws {
        let device = ScriptedDevice(replies: [.xml(SpecBodies.userCheckOK)])
        let client = TestClientFactory.scriptedClient(device: device)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<9 {
                group.addTask {
                    _ = try? await client.get("/System/status/\(index)")
                }
            }
            await group.waitForAll()
        }
        #expect(await device.peakConcurrency == 3)
        #expect(await device.recorded.count == 9)
    }

    /// Five concurrent identical GETs share one round trip (§4.4).
    @Test func isapiClientCoalescesIdenticalConcurrentGETs() async throws {
        let device = ScriptedDevice(replies: [.xml(SpecBodies.deviceInfo)])
        let client = TestClientFactory.scriptedClient(device: device)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { _ = try? await client.get("/System/deviceInfo") }
            }
            await group.waitForAll()
        }
        #expect(await device.recorded.count == 1)
    }

    /// A body-bearing verb is never coalesced: two identical PUTs are two commands.
    @Test func isapiClientDoesNotCoalescePUTs() async throws {
        let device = ScriptedDevice(replies: [.xml(SpecBodies.responseStatus(code: 1, sub: "ok"))])
        let client = TestClientFactory.scriptedClient(device: device)
        var builder = XMLBuilder("PTZData")
        builder.add("pan", 0)
        let body = builder.data()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    _ = try? await client.put("/PTZCtrl/channels/1/continuous", body: body)
                }
            }
            await group.waitForAll()
        }
        #expect(await device.recorded.count == 3)
    }

    /// `503 deviceBusy` is retried twice — at 400 ms then 1200 ms on the injected clock — and then
    /// gives up.
    @Test func isapiClientRetriesDeviceBusyTwiceThenThrows() async throws {
        let busy = ScriptedDevice.Reply.xml(
            SpecBodies.responseStatus(code: 2, sub: "deviceBusy"), status: 503)
        let device = ScriptedDevice(replies: [busy, busy, busy, busy])
        let clock = InstantTestClock()
        let client = TestClientFactory.scriptedClient(device: device, clock: clock)

        await #expect(throws: ISAPIError.deviceBusy) {
            try await client.get("/System/status")
        }
        #expect(await device.recorded.count == 3)                  // original plus two retries
        #expect(clock.recordedSleeps == [.milliseconds(400), .milliseconds(1200)])
    }

    /// A device that is busy once and then answers is not an error the caller ever sees.
    @Test func isapiClientSucceedsAfterATransientBusyAnswer() async throws {
        let busy = ScriptedDevice.Reply.xml(
            SpecBodies.responseStatus(code: 2, sub: "deviceBusy"), status: 503)
        let device = ScriptedDevice(replies: [busy, .xml(SpecBodies.deviceInfo)])
        let client = TestClientFactory.scriptedClient(device: device)
        let document = try await client.getXML("/System/deviceInfo")
        #expect(document.rootName == "DeviceInfo")
        #expect(await device.recorded.count == 2)
    }

    /// A transport timeout on a GET is retried at 250 ms then 750 ms, and then surfaces.
    @Test func isapiClientRetriesTransportTimeoutOnIdempotentGET() async throws {
        let failure = ScriptedDevice.Reply(
            failure: .timedOut(resource: "/ISAPI/System/status", seconds: 8))
        let device = ScriptedDevice(replies: [failure, failure, failure])
        let clock = InstantTestClock()
        let client = TestClientFactory.scriptedClient(device: device, clock: clock)
        await #expect(throws: ISAPIError.timedOut(resource: "/ISAPI/System/status", seconds: 8)) {
            try await client.get("/System/status")
        }
        #expect(await device.recorded.count == 3)
        #expect(clock.recordedSleeps == [.milliseconds(250), .milliseconds(750)])
    }

    /// A `PUT` is not idempotent, so a timeout is not repeated: a re-sent PTZ move would move the
    /// camera twice.
    @Test func isapiClientDoesNotRetryNonIdempotentPUT() async throws {
        let failure = ScriptedDevice.Reply(
            failure: .timedOut(resource: "/ISAPI/PTZCtrl/channels/1/absolute", seconds: 2))
        let device = ScriptedDevice(replies: [failure, failure])
        let client = TestClientFactory.scriptedClient(device: device)
        var builder = XMLBuilder("PTZData")
        builder.add("elevation", 10)
        _ = try? await client.put("/PTZCtrl/channels/1/absolute", body: builder.data())
        #expect(await device.recorded.count == 1)
    }

    /// `403 notSupport` is never retried and arrives as `.notSupported` for the negative cache.
    @Test func isapiClientMapsNotSupportWithoutRetrying() async throws {
        let device = ScriptedDevice(replies: [
            .xml(SpecBodies.responseStatus(code: 4, sub: "notSupport"), status: 403),
        ])
        let client = TestClientFactory.scriptedClient(device: device)
        await #expect(throws: ISAPIError.notSupported(resource: "/PTZCtrl/channels/1/momentary")) {
            try await client.get("/PTZCtrl/channels/1/momentary")
        }
        #expect(await device.recorded.count == 1)
    }

    /// HTTP 200 carrying `statusCode 4` still throws: the body wins over the status line.
    @Test func isapiClientThrowsOnHTTP200WithDeviceFailure() async throws {
        let device = ScriptedDevice(replies: [.xml(SpecBodies.responseStatusNotSupport)])
        let client = TestClientFactory.scriptedClient(device: device)
        await #expect(throws: ISAPIError.notSupported(resource: "/PTZCtrl/channels/1/continuous")) {
            try await client.get("/PTZCtrl/channels/1/continuous")
        }
    }

    /// An HTML login page — HTTP 200, `text/html` — is reported as a non-XML body, not as a missing
    /// element in a document that never existed.
    @Test func isapiClientReportsHTMLLoginPageAsMalformed() async throws {
        var headers = HTTPHeaders()
        headers["Content-Type"] = "text/html"
        let device = ScriptedDevice(replies: [
            .init(status: 200, headers: headers,
                  body: Data("<html><body>Please log in</body></html>".utf8)),
        ])
        let client = TestClientFactory.scriptedClient(device: device)
        do {
            _ = try await client.getXML("/System/deviceInfo")
            Issue.record("expected a malformed-response error")
        } catch {
            guard case let .malformedResponse(message) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(message.contains("not XML"))
        }
    }

    /// A quirk record lowering the concurrency ceiling takes effect immediately.
    @Test func isapiClientHonoursConcurrencyOverrideFromQuirks() async throws {
        let device = ScriptedDevice(replies: [.xml(SpecBodies.userCheckOK)])
        let client = ISAPIClient(endpoint: ISAPIEndpoint(host: "192.168.1.70"),
                                 credential: TestClientFactory.goodCredential,
                                 quirks: DeviceQuirks(maxConcurrentRequestsOverride: 1),
                                 transport: ScriptedTransport(device: device),
                                 trustEvaluator: AlwaysTrustEvaluator(),
                                 clock: InstantTestClock(),
                                 lockoutRegistry: AuthLockoutRegistry())
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<4 {
                group.addTask { _ = try? await client.get("/System/status/\(index)") }
            }
            await group.waitForAll()
        }
        #expect(await device.peakConcurrency == 1)
    }

    /// An empty-bodied PUT still declares `Content-Length: 0`; without it Hikvision answers 400.
    @Test func isapiClientSendsExplicitContentLengthForEmptyPUT() async throws {
        let device = ScriptedDevice(replies: [
            .xml(SpecBodies.responseStatus(code: 1, sub: "ok")),
        ])
        let client = TestClientFactory.scriptedClient(device: device)
        _ = try await client.put("/PTZCtrl/channels/1/presets/1/goto", body: nil)
        let recorded = try #require(await device.recorded.first)
        #expect(recorded.headers["Content-Length"] == "0")
        #expect(recorded.headers["Content-Type"] == "application/xml")
    }

    /// PTZ commands get the two-second budget, not the eight-second control default.
    @Test func isapiClientGivesPTZTheShortTimeout() async throws {
        let device = ScriptedDevice(replies: [
            .xml(SpecBodies.responseStatus(code: 1, sub: "ok")),
        ])
        let client = TestClientFactory.scriptedClient(device: device)
        var builder = XMLBuilder("PTZData")
        builder.add("pan", 0)
        _ = try await client.put("/PTZCtrl/channels/1/continuous", body: builder.data())
        let recorded = try #require(await device.recorded.first)
        #expect(recorded.timeout == .seconds(2))
    }
}

// MARK: - Gate

@Suite struct RequestGateTests {

    /// Permits are capped, and releasing hands the permit to the queue rather than the pool.
    @Test func requestGateCapsPermitsAtItsLimit() async throws {
        let gate = RequestGate(limit: 2)
        try await gate.acquire()
        try await gate.acquire()
        #expect(await gate.inFlight == 2)
        await gate.release()
        #expect(await gate.inFlight == 1)
    }

    /// PTZ — and only PTZ — may take one slot beyond the ceiling, because a dropped stop command
    /// leaves a camera spinning.
    @Test func requestGateOverSubscribesByExactlyOneSlot() async throws {
        let gate = RequestGate(limit: 2)
        try await gate.acquire()
        try await gate.acquire()
        try await gate.acquire(overSubscribeByOne: true)
        #expect(await gate.inFlight == 3)
        #expect(await gate.queueDepth == 0)
    }

    /// Raising the ceiling admits waiters; lowering it revokes nothing already held.
    @Test func requestGateSetLimitNeverRevokesAHeldPermit() async throws {
        let gate = RequestGate(limit: 3)
        try await gate.acquire()
        try await gate.acquire()
        try await gate.acquire()
        await gate.setLimit(1)
        #expect(await gate.inFlight == 3)
        #expect(await gate.currentLimit == 1)
    }

    /// A limit below one is nonsense and is clamped, so a bad quirk record cannot deadlock a device.
    @Test func requestGateClampsNonPositiveLimits() async {
        let gate = RequestGate(limit: 0)
        #expect(await gate.currentLimit == 1)
    }
}
