//
//  LockoutStore.swift
//  VigilProtocols
//
//  Persistence for the one authentication counter, so quitting Vigil does not hand a wrong password
//  a fresh budget while the device's own lock is still running.
//  Implements docs/RULING-LOCKOUT.md §2.8 and §7, and docs/API_CONTRACT.md §2 R-25.
//
//  Why the freshness stamp is the *store's* business and not the governor's: the governor measures
//  its probe window on an injected `MonotonicClock`, whose epoch is the process. A TTL that has to
//  survive a relaunch can only be measured on wall time, and the pure layer is forbidden from
//  reading a clock at all (IMPL_RULES, "Determinism"). So the implementation stamps on save and
//  filters on load, and `LockoutRecord` carries no timestamp for the governor to misuse.
//

// MARK: - LockoutRecord

/// One key's authentication tally, in the form that survives a relaunch.
///
/// Deliberately holds no secret and no timestamp. `rejectedFingerprints` are salted, truncated
/// digests (see `SecretFingerprint`): reproducible across launches because the salt is the
/// persisted `CredentialRef`, and useless to anyone who reads the file because matching one
/// requires already knowing which device it belongs to.
public struct LockoutRecord: Sendable, Hashable, Codable {

    /// The device host, exactly as the camera record spells it.
    public var host: String

    /// The device account, normally `admin`.
    public var account: String

    /// Credentialed sign-in attempts already debited against this key.
    public var failuresSpent: Int

    /// Whether the device itself reported the account locked. Distinct from a spent budget: no
    /// number of refunds reopens it.
    public var isBlocked: Bool

    /// Fingerprints of the secrets this key has already had rejected, oldest first. Bounded by
    /// `LockoutGovernor.maxDistinctSecretsPerWindow`; see §4 constraint 2.
    public var rejectedFingerprints: [String]

    /// Builds a record. Every field is written by the governor and read back verbatim.
    public init(host: String,
                account: String,
                failuresSpent: Int,
                isBlocked: Bool,
                rejectedFingerprints: [String]) {
        self.host = host
        self.account = account
        self.failuresSpent = failuresSpent
        self.isBlocked = isBlocked
        self.rejectedFingerprints = rejectedFingerprints
    }
}

// MARK: - LockoutStore

/// Where the authentication tally is kept between launches.
///
/// Both methods are synchronous and must not block for longer than a `UserDefaults` write: they are
/// called from inside the governor's actor, on the connect path.
///
/// **Implementations own the TTL.** `loadRecords()` must return only records still inside the
/// persistence window — thirty minutes from the last failure, matching the firmware's documented
/// lock window (§2.8). A record older than that describes a lock the device has already released,
/// and keeping it would refuse a sign-in for a reason that no longer exists.
public protocol LockoutStore: Sendable {

    /// Records that are still fresh enough to hold against the user. May be empty.
    ///
    /// Must never throw and must never trap: a malformed or half-written store is "nothing
    /// remembered", which costs one budget and no correctness.
    func loadRecords() -> [LockoutRecord]

    /// Replaces the whole stored set, stamping it as of now.
    ///
    /// Called after every mutation that changes a tally. Implementations that cannot write must
    /// fail silently — a governor that could not persist is still correct for this process.
    func saveRecords(_ records: [LockoutRecord])
}

// MARK: - NullLockoutStore

/// A store that remembers nothing.
///
/// The default for tests and for any lane that has no business persisting. It is **not** the right
/// default for the app: with it, quit-and-relaunch grants a fresh budget, which is the hole §2.8
/// exists to close.
public struct NullLockoutStore: LockoutStore {

    public init() {}

    public func loadRecords() -> [LockoutRecord] { [] }

    public func saveRecords(_ records: [LockoutRecord]) {}
}
