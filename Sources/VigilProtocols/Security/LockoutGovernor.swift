//
//  LockoutGovernor.swift
//  VigilProtocols
//
//  The one counter that decides a device's account is not worth another guess. Shared by every
//  connect lane for a device, it survives every reconnect, and — the part §2.8 adds — it survives
//  quitting the app.
//  Implements docs/RULING-LOCKOUT.md §2.1, §2.2, §2.5, §2.8, §3, §4 and §7, docs/API_CONTRACT.md
//  §2 R-25, docs/spec-core.md §6.8 and §5.12.
//
//  Why this lives in `VigilProtocols` and not in `VigilCore`. It has to be the *same* counter for
//  RTSP and for ISAPI (R-25 rule 4), and `VigilProtocols` is the only module both lanes already
//  depend on — `VigilISAPI` never imports `VigilCore` and does not have to. The move also puts it on
//  the `VigilPure` product, which is what makes its tests runnable on Linux instead of only on a Mac.
//
//  Why it counts by **reservation** rather than by recording failures after the fact. A
//  count-after-the-fact model cannot be made safe here, for three independent reasons, all of them
//  observed in the shipped code: concurrent sends all land before the first record; a rejection the
//  app misclassifies as a timeout is never recorded at all; and a credentialed request whose answer
//  the app never reads is invisible to us while the device saw it perfectly well. So strikes are
//  **debited before a credentialed request can be written**, and refunded only against evidence.
//

// MARK: - LockoutGovernor

/// Per-(host, account) authentication accounting.
///
/// Three responsibilities, all about not making a bad situation worse:
/// * a hard budget of **two** credentialed sign-in attempts, debited up front (`reserve`) and
///   refunded only when a connection provably never put a credential on the wire (`refund`);
/// * a rate limit of three credential *probes* per ten minutes, so a bulk add or a reconnect storm
///   cannot walk a device into its own lockout;
/// * a way out that requires proof the password actually changed (`clear`), because a user whose
///   password genuinely is wrong will retype the same characters, and that is the single most likely
///   route to a real thirty-minute lockout.
public actor LockoutGovernor {

    // MARK: Key

    /// What the counters are keyed by.
    ///
    /// **The port is deliberately not part of this.** The safety property is a fact about the
    /// *device's* tally, and the firmware keeps one tally per account regardless of which service the
    /// rejection arrived on: a camera answers ISAPI on 80 and RTSP on 554, and one account is one
    /// account. Including the port splits one device budget into two, which is the bug.
    ///
    /// **Accepted limitation.** Two port-forwarded cameras behind one public address share a budget
    /// under this key, so a wrong password on one will make Vigil refuse to sign in to the other.
    /// That is over-blocking — recoverable by entering a password, and the fail-safe direction.
    /// Splitting by port under-blocks, and under-blocking is a thirty-minute admin lockout. If the
    /// NAT case turns out to be common, the fix is a device-identity discriminator resolved from the
    /// library, **not** putting the port back in the key (§2.2).
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

    // MARK: ProbeDecision

    /// What `allowProbe` decided.
    ///
    /// A decision rather than a `Bool` because a refusal has to be able to say *how long*: the
    /// caller turns `retryAfter` into the countdown the UI renders, and without it the run loop would
    /// spin at the gate for the whole window.
    public enum ProbeDecision: Sendable, Hashable {

        /// Go ahead. The probe has been counted against the window.
        case allowed

        /// Do not open a socket. `retryAfter` is the window minus the age of its oldest entry, so a
        /// caller that sleeps for it wakes up exactly when a slot frees.
        case refused(retryAfter: Duration)
    }

    // MARK: Policy

    /// Credentialed sign-in attempts allowed per key before every lane refuses to send. **Two**
    /// (API_CONTRACT §2 R-25), which is safe under any plausible value of the firmware's own
    /// threshold — every comment in this tree says "about five", and that number is unverified.
    public static let maxCredentialedFailures = 2

    /// Credential probes allowed per key per window.
    public static let maxProbesPerWindow = 3

    /// The probe window. Ten minutes (spec-core §6.8 rule 2).
    ///
    /// This is also the number the "Vigil paused sign-in" countdown is driven from, and that is
    /// deliberate: it is a number Vigil controls and can state truthfully, unlike a guess at the
    /// firmware's lock window (§7, "Also ruled, on gap 2").
    public static let probeWindow: Duration = .seconds(600)

    /// Distinct secrets one key may have tried inside `probeWindow` before it stops accepting
    /// clears at all.
    ///
    /// Three. A user who has tried three passwords is guessing, and guessing is what locks accounts.
    /// Concretely: the secret that was rejected is refused as "the same password", the next distinct
    /// one is granted, and the one after that is refused until the window drains. This is also the
    /// backstop for the one way the fingerprint check can fail open — if a `CredentialRef` is ever
    /// regenerated for the same host and account, every stored fingerprint becomes unmatchable, so
    /// this ceiling keys on the *count*, never on the fingerprint (§7 consequence 2).
    public static let maxDistinctSecretsPerWindow = 3

    // MARK: State

    /// One key's tally.
    private struct Entry {

        /// Sign-in attempts debited and not refunded.
        var spent = 0

        /// The device itself said the account is locked. No refund reopens this.
        var isBlocked = false

        /// Secrets this key has already had under test, oldest first, with when they were seen.
        var rejected: [(fingerprint: String, at: MediaInstant)] = []

        /// Whether this entry still holds anything worth persisting.
        var isEmpty: Bool { spent == 0 && !isBlocked && rejected.isEmpty }
    }

    private let clock: any MonotonicClock
    private let logger: any LoggerProtocol
    private let store: any LockoutStore
    private var entries: [Key: Entry] = [:]
    private var probes: [Key: [MediaInstant]] = [:]

    /// Builds a governor and restores whatever survived the last launch.
    ///
    /// - Parameters:
    ///   - clock: the monotonic source the probe window is measured on. Injected so the ten-minute
    ///     window is testable without waiting ten minutes.
    ///   - logger: structured logging. Never receives a secret or a fingerprint.
    ///   - store: persistence. Defaults to `NullLockoutStore`, which is right for a test and wrong
    ///     for the app — with it, quit-and-relaunch grants a fresh budget while the device's own lock
    ///     is still running (§2.8).
    ///
    /// Restored fingerprints are stamped as of *now* rather than as of when they were rejected: the
    /// store carries no timestamp the governor could trust across an epoch change, and dating them
    /// now keeps them inside the window longer, which is the fail-safe direction.
    public init(clock: any MonotonicClock,
                logger: any LoggerProtocol = NullLogger(),
                store: any LockoutStore = NullLockoutStore()) {
        self.clock = clock
        self.logger = logger
        self.store = store
        let now = clock.now()
        for record in store.loadRecords() {
            let key = Key(host: record.host, account: record.account)
            entries[key] = Entry(
                spent: record.failuresSpent,
                isBlocked: record.isBlocked,
                rejected: record.rejectedFingerprints.map { (fingerprint: $0, at: now) })
        }
    }

    // MARK: Reservation

    /// Debits up to `count` credentialed sign-in attempts and returns how many were granted, `0…count`.
    ///
    /// **Call this before a credentialed request can be written, not after it fails.** The number
    /// returned is the allowance handed to the connection (`RTSPSessionConfig`'s
    /// `credentialedAttemptAllowance`); a caller that is granted zero must not open a socket at all.
    ///
    /// - Parameters:
    ///   - host: the device host, as the camera record spells it.
    ///   - account: the device account the credential names. Must be the account the gate and
    ///     `block` key on, or the clear and the block key differently and neither works.
    ///   - count: how many attempts the caller would like. The probe ladder asks for exactly one for
    ///     the whole five-rung sequence (§2.6).
    ///   - secretFingerprint: `SecretFingerprint.of(credential)`. Stored so `clear` can tell a new
    ///     password from the same one retyped. The governor never derives this and never logs it.
    public func reserve(host: String, account: String, count: Int,
                        secretFingerprint: String) -> Int {
        guard count > 0 else { return 0 }
        let key = Key(host: host, account: account)
        var entry = pruned(entries[key] ?? Entry())
        guard !entry.isBlocked else {
            entries[key] = entry
            logger.warning(.core, "sign-in refused: this account is blocked",
                           ["host": Redact.host(host, salt: 0)])
            return 0
        }
        let remaining = max(0, Self.maxCredentialedFailures - entry.spent)
        let granted = min(count, remaining)
        guard granted > 0 else {
            entries[key] = entry
            logger.warning(.core, "sign-in refused: budget spent",
                           ["host": Redact.host(host, salt: 0), "spent": String(entry.spent)])
            return 0
        }
        entry.spent += granted
        // A debit is a booked rejection, so the secret it was spent on is on record from here. A
        // later `refund` deliberately does **not** take it off: the user still typed it, and
        // over-counting distinct secrets refuses a clear rather than granting one.
        if !entry.rejected.contains(where: { $0.fingerprint == secretFingerprint }) {
            entry.rejected.append((fingerprint: secretFingerprint, at: clock.now()))
        }
        entries[key] = entry
        persist()
        logger.notice(.core, "credentialed sign-in reserved",
                      ["host": Redact.host(host, salt: 0),
                       "granted": String(granted),
                       "spent": String(entry.spent)])
        return granted
    }

    /// Returns strikes that were never put on the wire.
    ///
    /// The only honest caller is one that can prove no `Authorization` header was written — a
    /// connection that failed before sending, or a probe rung the ladder refused. Refunding on the
    /// strength of "the answer looked like a timeout" is exactly the mistake the reservation model
    /// exists to prevent: a device that answered `401` and then dropped the socket saw the credential.
    public func refund(host: String, account: String, count: Int) {
        guard count > 0 else { return }
        let key = Key(host: host, account: account)
        guard var entry = entries[key] else { return }
        entry.spent = max(0, entry.spent - count)
        entries[key] = entry
        persist()
        logger.debug(.core, "credentialed sign-in refunded",
                     ["host": Redact.host(host, salt: 0), "count": String(count)])
    }

    /// A credentialed request was answered with something other than `401`: the password is right.
    ///
    /// Clears the budget **and** the probe window for this key, and forgets the secrets under test.
    /// This is the one clear that needs no proof of difference, because the device has just supplied
    /// better proof than a fingerprint ever could.
    public func recordSuccess(host: String, account: String) {
        let key = Key(host: host, account: account)
        guard entries[key] != nil || probes[key] != nil else { return }
        entries.removeValue(forKey: key)
        probes.removeValue(forKey: key)
        persist()
        logger.info(.core, "credentials accepted; auth counters cleared",
                    ["host": Redact.host(host, salt: 0)])
    }

    /// The device itself reports the account locked: spend nothing more.
    ///
    /// Used when ISAPI's `/Security/userCheck` reports `lockStatus`, or when a session machine
    /// reports a terminal `authRejected` — that error is already the verdict of the connection's own
    /// cap, so the attempts behind it have been spent and counting one failure here would
    /// under-report and permit another connection.
    public func block(host: String, account: String, reason: String) {
        let key = Key(host: host, account: account)
        var entry = entries[key] ?? Entry()
        entry.spent = max(entry.spent, Self.maxCredentialedFailures)
        entry.isBlocked = true
        entries[key] = entry
        persist()
        logger.warning(.core, "authentication blocked for this account",
                       ["host": Redact.host(host, salt: 0), "reason": reason])
    }

    /// True when no further authenticated request may be sent for this account.
    ///
    /// The caller must check this **before building a connection**, not after a failure: the point is
    /// that the device never sees the third attempt.
    public func isBlocked(host: String, account: String) -> Bool {
        guard let entry = entries[Key(host: host, account: account)] else { return false }
        return entry.isBlocked || entry.spent >= Self.maxCredentialedFailures
    }

    /// Attempts debited against this account since the password last provably changed.
    public func failureCount(host: String, account: String) -> Int {
        entries[Key(host: host, account: account)]?.spent ?? 0
    }

    /// Attempts still available, `0…maxCredentialedFailures`.
    public func attemptsRemaining(host: String, account: String) -> Int {
        guard let entry = entries[Key(host: host, account: account)] else {
            return Self.maxCredentialedFailures
        }
        guard !entry.isBlocked else { return 0 }
        return max(0, Self.maxCredentialedFailures - entry.spent)
    }

    // MARK: Probes

    /// Registers a credential probe and reports whether it may proceed.
    ///
    /// Called once per probe *sequence* — the five-rung path ladder is one probe, not five — from the
    /// one place that starts one. A refusal must produce `StreamError.signInPaused`, never
    /// `authenticationFailed`: on this path the camera has rejected nothing and the user has nothing
    /// to fix (§3).
    public func allowProbe(host: String, account: String) -> ProbeDecision {
        let key = Key(host: host, account: account)
        let now = clock.now()
        var recent = (probes[key] ?? []).filter { now - $0 < Self.probeWindow }
        guard recent.count < Self.maxProbesPerWindow else {
            probes[key] = recent
            // The oldest entry is the one whose expiry frees a slot. `recent` is append-ordered and
            // append order is time order, so the first element is the oldest.
            let oldest = recent.first ?? now
            let retryAfter = Self.probeWindow - (now - oldest)
            logger.warning(.core, "credential probe refused locally",
                           ["host": Redact.host(host, salt: 0),
                            "retryAfterSeconds": String(Int(max(0, retryAfter.seconds)))])
            return .refused(retryAfter: retryAfter > .zero ? retryAfter : .zero)
        }
        recent.append(now)
        probes[key] = recent
        return .allowed
    }

    /// Probes remaining in the current window, for the message the UI shows.
    public func probesRemaining(host: String, account: String) -> Int {
        let key = Key(host: host, account: account)
        let now = clock.now()
        let recent = (probes[key] ?? []).filter { now - $0 < Self.probeWindow }
        return max(0, Self.maxProbesPerWindow - recent.count)
    }

    // MARK: Clearing

    /// The user supplied a password. Clears this account's budget **only if it is a different one**.
    ///
    /// This is the single most important gate in the file. A reconnect, a network change, a rebuilt
    /// controller and an app restart must all leave the count standing; only a genuinely new secret
    /// may reset it, because a user whose password is wrong will retype the same characters and that
    /// is the most likely route to a real lockout.
    ///
    /// - Parameter secretFingerprint: `SecretFingerprint.of(credential)`, computed by the caller.
    /// - Returns: `true` when the counters were cleared. `false` — and nothing changed — when the
    ///   fingerprint matches one already under test for this key, or when this key has already had
    ///   `maxDistinctSecretsPerWindow` distinct secrets inside the window.
    @discardableResult
    public func clear(host: String, account: String, secretFingerprint: String) -> Bool {
        let key = Key(host: host, account: account)
        var entry = pruned(entries[key] ?? Entry())
        guard !entry.rejected.contains(where: { $0.fingerprint == secretFingerprint }) else {
            entries[key] = entry
            logger.notice(.core, "password unchanged; auth counters left standing",
                          ["host": Redact.host(host, salt: 0)])
            return false
        }
        guard entry.rejected.count + 1 < Self.maxDistinctSecretsPerWindow else {
            entries[key] = entry
            logger.warning(.core, "too many passwords tried for this account; clear refused",
                           ["host": Redact.host(host, salt: 0),
                            "tried": String(entry.rejected.count)])
            return false
        }
        entry.rejected.append((fingerprint: secretFingerprint, at: clock.now()))
        entry.spent = 0
        entry.isBlocked = false
        entries[key] = entry
        probes.removeValue(forKey: key)
        persist()
        logger.info(.core, "new password; auth counters cleared",
                    ["host": Redact.host(host, salt: 0)])
        return true
    }

    /// Clears every counter for every account. Used at logout and by tests.
    public func clearAll() {
        entries.removeAll()
        probes.removeAll()
        persist()
    }

    // MARK: Private

    /// Drops secrets last seen more than `probeWindow` ago, so the distinct-secret ceiling is a
    /// statement about the current window and not about the life of the process.
    private func pruned(_ entry: Entry) -> Entry {
        let now = clock.now()
        var out = entry
        out.rejected.removeAll { now - $0.at >= Self.probeWindow }
        return out
    }

    /// Writes the whole tally out. Called after every mutation; empty entries are not persisted, so
    /// the store does not grow with every camera that ever worked.
    private func persist() {
        let records = entries.compactMap { key, entry -> LockoutRecord? in
            guard !entry.isEmpty else { return nil }
            return LockoutRecord(host: key.host,
                                 account: key.account,
                                 failuresSpent: entry.spent,
                                 isBlocked: entry.isBlocked,
                                 rejectedFingerprints: entry.rejected.map(\.fingerprint))
        }
        store.saveRecords(records)
    }
}
