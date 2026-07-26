//
//  LockoutGovernor.swift
//  VigilCore
//
//  The one counter that decides a device's account is not worth another guess. Shared by every
//  connect lane for a device, and — the part that matters — **it survives reconnects**.
//  Implements docs/API_CONTRACT.md §2 R-25, docs/spec-core.md §6.8 and §5.12
//  (`Security/LockoutGovernor.swift`).
//
//  Why this exists as its own actor rather than as a field on `StreamController`: Hikvision
//  firmware locks an account for about thirty minutes after roughly five consecutive failed
//  logins, including from the camera's own web UI. `RTSPAuthenticator` counts credentialed 401s
//  within one connection, and a fresh connection gets a fresh authenticator — so a reconnect loop
//  with a wrong password would burn two attempts per reconnect, forever, and lock the user out of
//  their own camera. The counter therefore has to outlive the connection, and once RTSP and ISAPI
//  both exist it has to be the *same* counter for both (R-25 rule 4), which means an actor the
//  coordinator can hand to everything that touches one device.
//

#if os(macOS)

import Foundation
import VigilProtocols

/// Per-(host, account) authentication accounting.
///
/// Two responsibilities, both about not making a bad situation worse:
/// * a hard stop after **two** credentialed `401`s, which is terminal until the user supplies a new
///   password (`clear(host:account:)`);
/// * a rate limit of three credential *probes* per ten minutes, so a bulk add or a reconnect storm
///   cannot walk a device into its own lockout.
public actor LockoutGovernor {

    // MARK: Key

    /// What the counters are keyed by. Not the camera: two channels of one NVR share an account,
    /// and letting each burn its own budget is how eight attempts happen where two were intended.
    public struct Key: Hashable, Sendable {

        /// The device host, exactly as the camera record spells it.
        public var host: String

        /// The device account, normally `admin`.
        public var account: String

        public init(host: String, account: String) {
            self.host = host
            self.account = account
        }
    }

    // MARK: Policy

    /// Credentialed `401`s that end every attempt for this account. **Two** (API_CONTRACT §2 R-25).
    public static let maxCredentialedFailures = 2

    /// Credential probes allowed per key per window.
    public static let maxProbesPerWindow = 3

    /// The probe window. Ten minutes (spec-core §6.8 rule 2).
    public static let probeWindow: Duration = .seconds(600)

    // MARK: State

    private let clock: any MonotonicClock
    private let logger: any LoggerProtocol
    private var failures: [Key: Int] = [:]
    private var probes: [Key: [MediaInstant]] = [:]

    /// Builds a governor.
    ///
    /// - Parameter clock: the monotonic source the probe window is measured on. Injected so the
    ///   ten-minute window is testable without waiting ten minutes.
    public init(clock: any MonotonicClock, logger: any LoggerProtocol = NullLogger()) {
        self.clock = clock
        self.logger = logger
    }

    // MARK: Failures

    /// Records a `401` that answered a request which already carried credentials, and returns the
    /// new count.
    ///
    /// A `401` carrying a **fresh nonce**, or `stale=true`, is not a failed login and must never
    /// reach this method — `RTSPAuthenticator` already makes that distinction, and double-counting
    /// it would halve an already tight budget.
    @discardableResult
    public func recordCredentialedFailure(host: String, account: String) -> Int {
        let key = Key(host: host, account: account)
        let count = (failures[key] ?? 0) + 1
        failures[key] = count
        logger.warning(.core, "credentialed 401 recorded",
                       ["host": Redact.host(host, salt: 0), "count": String(count)])
        return count
    }

    /// How many credentialed `401`s this account has collected since the password last changed.
    public func failureCount(host: String, account: String) -> Int {
        failures[Key(host: host, account: account)] ?? 0
    }

    /// True when no further authenticated request may be sent for this account.
    ///
    /// The caller must check this **before building a connection**, not after a failure: the point
    /// is that the device never sees the third attempt.
    public func isBlocked(host: String, account: String) -> Bool {
        failureCount(host: host, account: account) >= Self.maxCredentialedFailures
    }

    /// Clears every counter for an account. Called when the user supplies a new password, and only
    /// then — a reconnect, a network change and an app restart must all leave the count standing.
    public func clear(host: String, account: String) {
        let key = Key(host: host, account: account)
        failures.removeValue(forKey: key)
        probes.removeValue(forKey: key)
        logger.info(.core, "auth failure counters cleared",
                    ["host": Redact.host(host, salt: 0)])
    }

    /// Clears every counter for every account. Used at logout and by tests.
    public func clearAll() {
        failures.removeAll()
        probes.removeAll()
    }

    // MARK: Probes

    /// Registers a credential probe and reports whether it may proceed.
    ///
    /// Returns `false` once three probes have been made for this key inside the window; the caller
    /// surfaces "Vigil stopped trying, to protect your camera account from being locked" rather
    /// than a network error, because that is what actually happened.
    public func allowProbe(host: String, account: String) -> Bool {
        let key = Key(host: host, account: account)
        let now = clock.now()
        var recent = (probes[key] ?? []).filter { now - $0 < Self.probeWindow }
        guard recent.count < Self.maxProbesPerWindow else {
            probes[key] = recent
            logger.warning(.core, "credential probe refused locally",
                           ["host": Redact.host(host, salt: 0),
                            "window": String(Int(Self.probeWindow.seconds))])
            return false
        }
        recent.append(now)
        probes[key] = recent
        return true
    }

    /// Probes remaining in the current window, for the message the UI shows.
    public func probesRemaining(host: String, account: String) -> Int {
        let key = Key(host: host, account: account)
        let now = clock.now()
        let recent = (probes[key] ?? []).filter { now - $0 < Self.probeWindow }
        return max(0, Self.maxProbesPerWindow - recent.count)
    }
}

#endif
