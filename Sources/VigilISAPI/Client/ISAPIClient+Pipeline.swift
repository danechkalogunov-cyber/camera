//
//  ISAPIClient+Pipeline.swift
//  VigilISAPI
//
//  The request pipeline, lock reporting, and the policy helpers around them.
//  Split from ISAPIClient.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

import Foundation
import VigilProtocols

// MARK: - The request pipeline

/// ⚠️ Members are `internal`, not `private`: Swift scopes `private` to one file.
/// `Scripts/lint.py`'s `split-access` rule fails the build on any left behind.
extension ISAPIClient {

    // MARK: The request pipeline

    /// Sends one request, applying coalescing, the gate, Digest and the retry table.
    func send(method: String, resource: String, query: [URLQueryItem], body: Data?,
              contentType: String?, lane: Lane,
              idempotent: Bool) async throws(ISAPIError) -> CompletedRequest {
        try await guardBeforeSending()
        let url = try endpoint.url(resource, query: query)

        // Identical concurrent GETs share one round trip (§4.4). Never for a body-bearing verb,
        // and never on the long-lived lanes.
        guard method == "GET", lane == .control || lane == .snapshot else {
            return try await execute(method: method, resource: resource, url: url, query: query,
                                     body: body, contentType: contentType, lane: lane,
                                     idempotent: idempotent)
        }
        let key = "\(lane.rawValue)|\(method)|\(url.absoluteString)"
        if let existing = inFlightGETs[key] {
            do {
                return try await existing.value
            } catch let error as ISAPIError {
                throw error
            } catch {
                throw ISAPIError.notConnected(String(describing: error))
            }
        }
        let task = Task { [self] in
            try await execute(method: method, resource: resource, url: url, query: query,
                              body: body, contentType: contentType, lane: lane,
                              idempotent: idempotent)
        }
        inFlightGETs[key] = task
        do {
            let completed = try await task.value
            inFlightGETs[key] = nil
            return completed
        } catch let error as ISAPIError {
            inFlightGETs[key] = nil
            throw error
        } catch {
            inFlightGETs[key] = nil
            throw ISAPIError.notConnected(String(describing: error))
        }
    }

    /// Acquires the lane's permit and runs the attempt loop.
    private func execute(method: String, resource: String, url: URL, query: [URLQueryItem],
                         body: Data?, contentType: String?, lane: Lane,
                         idempotent: Bool) async throws(ISAPIError) -> CompletedRequest {
        guard let gate = gates[lane] else {
            throw ISAPIError.notConnected("no gate for lane \(lane.rawValue)")
        }
        // PTZ, and only PTZ, may over-subscribe the control gate by exactly one slot: a dropped
        // stop command leaves a camera spinning.
        let isPTZ = resource.hasPrefix("/PTZCtrl/") || resource.hasPrefix("PTZCtrl/")
        do {
            try await gate.acquire(overSubscribeByOne: isPTZ && lane == .control)
        } catch {
            throw ISAPIError.cancelled
        }
        // Explicit release on both paths rather than a `defer`: releasing a permit is an `await`
        // on another actor, and a `defer` cannot await without spawning a task that outlives the
        // failure it is cleaning up after.
        do {
            let completed = try await attemptLoop(method: method, resource: resource, url: url,
                                                  query: query, body: body,
                                                  contentType: contentType, lane: lane,
                                                  idempotent: idempotent)
            await gate.release()
            return completed
        } catch {
            await gate.release()
            throw error
        }
    }

    /// The attempt loop: authenticate, send, classify, maybe retry.
    private func attemptLoop(method: String, resource: String, url: URL, query: [URLQueryItem],
                             body: Data?, contentType: String?, lane: Lane,
                             idempotent: Bool) async throws(ISAPIError) -> CompletedRequest {
        let uri = endpoint.requestURI(resource, query: query)
        var transientAttempts = 0
        var authRetries = 0

        while true {
            try await guardBeforeSending()
            if Task.isCancelled { throw ISAPIError.cancelled }

            var request = HTTPRequest(url: url, method: method, headers: baseHeaders(extra: .init()),
                                      body: body, timeout: timeout(for: lane, resource: resource),
                                      lane: lane)
            if let contentType { request.headers["Content-Type"] = contentType }
            // An empty-bodied PUT must still say so: URLSession omits `Content-Length` for a nil
            // body on some paths and Hikvision answers HTTP 400 (spec-isapi §13).
            if body == nil, method == "PUT" || method == "POST" {
                request.headers["Content-Length"] = "0"
            }
            let authorization = await digest.header(for: method, uri: uri, credential: credential)
            if let authorization { request.headers["Authorization"] = authorization }

            let response: HTTPResponse
            do {
                response = try await transport.perform(request)
            } catch {
                guard idempotent, isTransient(error),
                      transientAttempts < configuration.maxTransientRetries else { throw error }
                try await backoff(Self.transportDelays[min(transientAttempts,
                                                           Self.transportDelays.count - 1)])
                transientAttempts += 1
                continue
            }

            if response.statusCode == 401 {
                // The device's own lock report wins over everything else: one more attempt would
                // be the one that locks the account (spec-isapi §10.2's hard rule).
                if let report = Self.credentialLockReport(response), report.isTerminal {
                    await lockout.block(host: endpoint.host, port: endpoint.port,
                                        account: credential.account)
                    logger.error(.isapi, "device reports the account locked or one attempt from it",
                                 ["account": credential.account,
                                  "remaining": report.remainingAttempts.map(String.init) ?? "?"])
                    if report.isLocked {
                        throw ISAPIError.accountLocked(retryAfter: report.unlockAfter)
                    }
                    throw ISAPIError.authBlockedLocally(
                        failures: AuthLockoutRegistry.maximumFailures)
                }
                let disposition = await digest.absorb(headers: response.headers,
                                                      didSendAuthorization: authorization != nil,
                                                      isTLS: endpoint.useTLS)
                if case .retry = disposition, authRetries < 2 {
                    authRetries += 1
                    continue
                }
                let terminal: DigestStore.Disposition =
                    disposition == .retry ? .authenticationFailed : disposition
                throw await authFailure(terminal)
            }

            await noteAuthenticationSucceeded(sentAuthorization: authorization != nil)
            await digest.adoptNextNonce(headers: response.headers)

            let document: ISAPIDocument?
            do {
                document = try ISAPIResponseValidator.validate(response, resource: resource,
                                                               username: credential.account)
            } catch {
                let retryable = isRetryableDeviceFailure(error) && idempotent
                guard retryable, transientAttempts < configuration.maxTransientRetries else {
                    throw error
                }
                try await backoff(Self.busyDelays[min(transientAttempts,
                                                      Self.busyDelays.count - 1)])
                transientAttempts += 1
                continue
            }
            return CompletedRequest(response: response, document: document)
        }
    }

    // MARK: Lock reporting

    /// What a 401 body says about how close the account is to being locked.
    struct CredentialLockReport: Sendable {
        /// The device says the account is locked right now.
        var isLocked: Bool
        /// Attempts the device says remain before it locks. Counts down 4→3→2→1→0.
        var remainingAttempts: Int?
        /// Seconds of lock remaining, when the device reports one.
        var unlockAfter: Double?

        /// True when sending anything else risks the lockout: locked already, or one attempt left.
        var isTerminal: Bool { isLocked || (remainingAttempts ?? Int.max) <= 1 }
    }

    /// Reads `<userCheck>`'s lock fields out of a 401 body, or `nil` when it carries none.
    ///
    /// `/Security/userCheck` is the only endpoint that reports lockout state, and it answers the
    /// same body on any 401 on most firmware — which is why this is read on every 401 rather than
    /// only when the caller happened to ask for `userCheck`.
    static func credentialLockReport(_ response: HTTPResponse) -> CredentialLockReport? {
        guard !response.body.isEmpty, ISAPIDocument.looksLikeXML(response.body),
              let document = try? ISAPIDocument(parsing: response.body) else { return nil }
        let locked = document["lockStatus"].string?.lowercased() == "lock"
        let remaining = document["retryLoginTime"].int
        guard locked || remaining != nil else { return nil }
        return CredentialLockReport(isLocked: locked, remainingAttempts: remaining,
                                    unlockAfter: document["unlockTime"].double)
    }

    // MARK: Policy helpers

    /// Delays after a transport failure: 250 ms then 750 ms (§4.7).
    static let transportDelays: [Duration] = [.milliseconds(250), .milliseconds(750)]

    /// Delays after a 503 or `deviceBusy`: 400 ms then 1200 ms (§4.7).
    static let busyDelays: [Duration] = [.milliseconds(400), .milliseconds(1200)]

    /// Refuses to send at all once the account is two credentialed 401s deep, and refuses `https`
    /// on a build whose trust evaluator cannot evaluate anything.
    func guardBeforeSending() async throws(ISAPIError) {
        if Task.isCancelled { throw ISAPIError.cancelled }
        let failures = await lockout.failureCount(host: endpoint.host, port: endpoint.port,
                                                  account: credential.account)
        if failures >= AuthLockoutRegistry.maximumFailures {
            throw ISAPIError.authBlockedLocally(failures: failures)
        }
        if endpoint.useTLS,
           case .reject = trustEvaluator.evaluate(host: endpoint.host, port: endpoint.port,
                                                  chainDER: []) {
            throw ISAPIError.tlsUnavailableOnThisPlatform
        }
    }

    /// Headers every request carries.
    func baseHeaders(extra: HTTPHeaders) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers["User-Agent"] = configuration.userAgent
        headers["Accept"] = "*/*"
        for entry in extra { headers[entry.name] = entry.value }
        return headers
    }

    /// The budget for a request, by lane and by resource.
    private func timeout(for lane: Lane, resource: String) -> Duration {
        switch lane {
        case .snapshot: return configuration.snapshotTimeout
        case .stream, .audio: return configuration.streamIdleTimeout
        case .control:
            if resource.contains("/PTZCtrl/") { return configuration.ptzTimeout }
            if resource.contains("/ContentMgmt/search") { return configuration.searchTimeout }
            return configuration.controlTimeout
        }
    }

    /// True for a transport failure worth repeating.
    private func isTransient(_ error: ISAPIError) -> Bool {
        switch error {
        case .timedOut, .notConnected: return true
        default: return false
        }
    }

    /// True for a device answer the retry table repeats: 503 and `deviceBusy`.
    private func isRetryableDeviceFailure(_ error: ISAPIError) -> Bool {
        if case .deviceBusy = error { return true }
        if case let .http(status, _) = error, status == 503 { return true }
        return false
    }

    /// Sleeps `delay` on the injected clock. A cancelled sleep becomes `.cancelled`.
    private func backoff(_ delay: Duration) async throws(ISAPIError) {
        do {
            try await clock.sleep(for: delay)
        } catch {
            throw ISAPIError.cancelled
        }
    }

    /// Records a credentialed 401 and produces the error to throw.
    ///
    /// The **second** failure is terminal and reported as `.authBlockedLocally`, which no schedule
    /// retries: only a new credential clears it.
    func authFailure(_ disposition: DigestStore.Disposition) async -> ISAPIError {
        if case let .unsupported(scheme) = disposition {
            return .unsupportedAuthentication(scheme)
        }
        let failures = await lockout.recordFailure(host: endpoint.host, port: endpoint.port,
                                                   account: credential.account)
        logger.warning(.isapi, "authentication rejected by \(endpoint.host)",
                       ["account": credential.account, "failures": String(failures)])
        if failures >= AuthLockoutRegistry.maximumFailures {
            return .authBlockedLocally(failures: failures)
        }
        return .authenticationFailed(username: credential.account)
    }

    /// Clears the failure counter after a request that carried credentials succeeded.
    func noteAuthenticationSucceeded(sentAuthorization: Bool) async {
        guard sentAuthorization else { return }
        await lockout.reset(host: endpoint.host, port: endpoint.port, account: credential.account)
    }
}
