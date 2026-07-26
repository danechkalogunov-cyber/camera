//
//  AuthLockoutRegistry.swift
//  VigilISAPI
//
//  The process-wide credentialed-401 counter, per (host, port, account), that makes the two-failure
//  hard block survive a new `ISAPIClient`.
//  Implements docs/spec-isapi.md §4.7 and docs/API_CONTRACT.md §2 R-25.
//
//  Why this is not a field on the client: Hikvision firmware locks an account for thirty minutes
//  after roughly five failed logins, including against the camera's own web interface. A counter
//  that resets when a view is rebuilt, a session reconnects, or a snapshot poller makes its own
//  client is not a lockout guard at all — it is a way to spend five attempts in a second and lock
//  the user out of their own camera. The counter therefore outlives every client that consults it.
//

import Foundation
import VigilProtocols

// MARK: - AuthLockoutRegistry

/// Consecutive credentialed 401s per device account, shared across every client and every lane.
///
/// A 401 with a new nonce or `stale=true` is **not** counted: it is a challenge, not a rejection
/// (R-25 rule 1). Only a 401 answering a request that already carried a plausible `Authorization`
/// header increments the counter, and the **second** one is terminal.
public actor AuthLockoutRegistry {

    /// The process-wide registry. Every `ISAPIClient` uses this unless a test injects its own.
    public static let shared = AuthLockoutRegistry()

    /// Failures that end the conversation. Two, not five: the margin below the firmware's own
    /// lock threshold is what keeps a wrong stored password from locking the account.
    public static let maximumFailures = 2

    /// The key a counter hangs on. Port is included because two devices behind one NAT differ only
    /// by port, and account because a device may hold several.
    struct Key: Hashable, Sendable {
        var host: String
        var port: Int
        var account: String
    }

    /// Counters, keyed per device account. Bounded in practice by the size of the camera library.
    private var failures: [Key: Int] = [:]

    /// Creates an empty registry. Tests make their own; production uses `shared`.
    public init() {}

    /// Records one credentialed 401 and returns the new count.
    @discardableResult
    public func recordFailure(host: String, port: Int, account: String) -> Int {
        let key = Key(host: host, port: port, account: account)
        let count = (failures[key] ?? 0) + 1
        failures[key] = count
        return count
    }

    /// Clears the counter after a successful authentication, or when the user supplies a new
    /// credential. This is the **only** way out of a block.
    public func reset(host: String, port: Int, account: String) {
        failures[Key(host: host, port: port, account: account)] = nil
    }

    /// Consecutive failures recorded for this device account.
    public func failureCount(host: String, port: Int, account: String) -> Int {
        failures[Key(host: host, port: port, account: account)] ?? 0
    }

    /// True when no further request may be sent for this device account.
    public func isBlocked(host: String, port: Int, account: String) -> Bool {
        failureCount(host: host, port: port, account: account) >= Self.maximumFailures
    }

    /// Forgets every counter. For test isolation only; nothing in the app calls it.
    public func removeAll() {
        failures.removeAll()
    }
}
