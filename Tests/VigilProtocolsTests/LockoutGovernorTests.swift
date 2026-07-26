//
//  LockoutGovernorTests.swift
//  VigilProtocolsTests
//
//  The reservation model, the shared key, the probe window, the proof-of-difference clear and
//  clear-on-success — tests 3 to 7 of docs/RULING-LOCKOUT.md §5.
//  Covers docs/RULING-LOCKOUT.md §2.2, §2.5, §2.8, §3, §4, §7 and docs/API_CONTRACT.md §2 R-25.
//

import Foundation
import Testing
import VigilProtocols

// MARK: - Doubles

/// A monotonic clock a test can advance while the governor holds it.
///
/// `VigilTestKit.VirtualClock` is a *struct*, so an actor that stores one holds a copy and the
/// test's `advance(by:)` never reaches it. A reference type is the only shape that works here.
///
/// `@unchecked Sendable` is justified: every mutation and every read goes through `lock`.
private final class SteppableClock: MonotonicClock, @unchecked Sendable {

    private let lock = NSLock()
    private var instant: MediaInstant

    init(start: MediaInstant = .zero) { instant = start }

    func now() -> MediaInstant {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func advance(by duration: Duration) {
        lock.lock()
        defer { lock.unlock() }
        instant = instant + duration
    }

    func sleep(for duration: Duration) async throws {}
    func sleep(until deadline: MediaInstant) async throws {}
}

/// An in-memory `LockoutStore`, so the persistence seam is exercised without a `UserDefaults`.
///
/// `@unchecked Sendable` is justified: every access goes through `lock`.
private final class MemoryLockoutStore: LockoutStore, @unchecked Sendable {

    private let lock = NSLock()
    private var records: [LockoutRecord]

    init(seeded: [LockoutRecord] = []) { records = seeded }

    func loadRecords() -> [LockoutRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    func saveRecords(_ newValue: [LockoutRecord]) {
        lock.lock()
        defer { lock.unlock() }
        records = newValue
    }

    var saved: [LockoutRecord] { loadRecords() }
}

private let fingerprintA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
private let fingerprintB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
private let fingerprintC = "cccccccccccccccccccccccccccccccc"

// MARK: - Test 3 — reserve / refund

/// §5 test 3. The whole reservation model in one assertion: a budget of two, debited up front,
/// exhausted by the first caller, and returned only by an explicit refund.
@Test func lockoutGovernorReserveDebitsUpFrontAndRefundReturnsUnsentStrikes() async {
    let governor = LockoutGovernor(clock: SteppableClock())

    let first = await governor.reserve(host: "h", account: "admin", count: 2,
                                       secretFingerprint: fingerprintA)
    #expect(first == 2)

    // Nothing has failed yet and nothing has been recorded — and the second caller still gets
    // nothing, because the strikes are already spent. This is the property a count-after-the-fact
    // model cannot have.
    let second = await governor.reserve(host: "h", account: "admin", count: 2,
                                        secretFingerprint: fingerprintA)
    #expect(second == 0)
    #expect(await governor.isBlocked(host: "h", account: "admin"))

    await governor.refund(host: "h", account: "admin", count: 1)
    #expect(await governor.attemptsRemaining(host: "h", account: "admin") == 1)

    let third = await governor.reserve(host: "h", account: "admin", count: 2,
                                       secretFingerprint: fingerprintA)
    #expect(third == 1)
}

/// A caller that asks for nothing is granted nothing, and a refund of a key that was never reserved
/// cannot manufacture a budget.
@Test func lockoutGovernorRefusesZeroCountAndCannotBeRefundedIntoCredit() async {
    let governor = LockoutGovernor(clock: SteppableClock())
    #expect(await governor.reserve(host: "h", account: "admin", count: 0,
                                   secretFingerprint: fingerprintA) == 0)
    await governor.refund(host: "h", account: "admin", count: 99)
    #expect(await governor.attemptsRemaining(host: "h", account: "admin")
        == LockoutGovernor.maxCredentialedFailures)
}

// MARK: - Test 4 — one key across both lanes

/// §5 test 4, and the §2.2 port ruling. The ISAPI lane talks to port 80 and the RTSP lane to port
/// 554; the firmware keeps one tally per account regardless. Two reserves of one — one per lane —
/// therefore exhaust the *same* budget, and the third is refused.
///
/// This was unwritable before the unification because the two lanes counted in two different types
/// with two different keys, one of which included the port.
@Test func lockoutGovernorSharesOneBudgetAcrossTheISAPIAndRTSPLanes() async {
    let governor = LockoutGovernor(clock: SteppableClock())
    let host = "192.168.1.64"

    // The ISAPI lane, whose endpoint is port 80.
    let isapi = await governor.reserve(host: host, account: "admin", count: 1,
                                       secretFingerprint: fingerprintA)
    // The RTSP lane, whose endpoint is port 554.
    let rtsp = await governor.reserve(host: host, account: "admin", count: 1,
                                      secretFingerprint: fingerprintA)
    #expect(isapi == 1)
    #expect(rtsp == 1)

    let third = await governor.reserve(host: host, account: "admin", count: 1,
                                       secretFingerprint: fingerprintA)
    #expect(third == 0)
    #expect(await governor.isBlocked(host: host, account: "admin"))

    // A different account on the same device keeps its own budget: one account is one account, but
    // two accounts are two.
    #expect(await governor.reserve(host: host, account: "operator", count: 1,
                                   secretFingerprint: fingerprintA) == 1)
}

// MARK: - Test 5 — the probe window

/// §5 test 5. Three probes per ten minutes; the fourth is refused with the window minus the age of
/// the oldest entry, and the window reopens exactly when that entry expires. No real waiting.
@Test func lockoutGovernorAllowsThreeProbesPerWindowThenRefusesWithARetryAfter() async {
    let clock = SteppableClock()
    let governor = LockoutGovernor(clock: clock)

    #expect(await governor.allowProbe(host: "h", account: "admin") == .allowed)
    clock.advance(by: .seconds(60))
    #expect(await governor.allowProbe(host: "h", account: "admin") == .allowed)
    clock.advance(by: .seconds(60))
    #expect(await governor.allowProbe(host: "h", account: "admin") == .allowed)
    #expect(await governor.probesRemaining(host: "h", account: "admin") == 0)

    // The oldest probe is 120 s old, so the window frees in 600 − 120 = 480 s.
    let decision = await governor.allowProbe(host: "h", account: "admin")
    #expect(decision == .refused(retryAfter: .seconds(480)))

    // One second short of the oldest entry's expiry: still refused, and still counting down.
    clock.advance(by: .seconds(479))
    #expect(await governor.allowProbe(host: "h", account: "admin") == .refused(retryAfter: .seconds(1)))

    // Past it: the oldest entry has left the window, so a slot is free again.
    clock.advance(by: .seconds(2))
    #expect(await governor.allowProbe(host: "h", account: "admin") == .allowed)
}

// MARK: - Test 6 — proof of difference

/// §5 test 6. The clear gate. The same password may not reset the counter, a new one may, and an
/// unbounded number of new ones may not.
@Test func lockoutGovernorClearsOnlyForADifferentSecretAndOnlyTwiceAWindow() async {
    let governor = LockoutGovernor(clock: SteppableClock())

    #expect(await governor.reserve(host: "h", account: "admin", count: 2,
                                   secretFingerprint: fingerprintA) == 2)
    #expect(await governor.failureCount(host: "h", account: "admin") == 2)

    // Retyping the same characters is the most likely route to a real lockout, so it clears nothing.
    #expect(await governor.clear(host: "h", account: "admin",
                                 secretFingerprint: fingerprintA) == false)
    #expect(await governor.failureCount(host: "h", account: "admin") == 2)

    // A genuinely different password does.
    #expect(await governor.clear(host: "h", account: "admin",
                                 secretFingerprint: fingerprintB) == true)
    #expect(await governor.failureCount(host: "h", account: "admin") == 0)
    #expect(await governor.isBlocked(host: "h", account: "admin") == false)

    // A third distinct secret inside the window does not: three passwords is guessing.
    #expect(await governor.clear(host: "h", account: "admin",
                                 secretFingerprint: fingerprintC) == false)
}

/// The distinct-secret ceiling is a statement about the *window*, not about the life of the process:
/// once the tried secrets age out, a clear is granted again.
@Test func lockoutGovernorLetsTheDistinctSecretCeilingDrainWithTheWindow() async {
    let clock = SteppableClock()
    let governor = LockoutGovernor(clock: clock)

    _ = await governor.reserve(host: "h", account: "admin", count: 2,
                              secretFingerprint: fingerprintA)
    #expect(await governor.clear(host: "h", account: "admin",
                                 secretFingerprint: fingerprintB) == true)
    #expect(await governor.clear(host: "h", account: "admin",
                                 secretFingerprint: fingerprintC) == false)

    clock.advance(by: LockoutGovernor.probeWindow + .seconds(1))
    #expect(await governor.clear(host: "h", account: "admin",
                                 secretFingerprint: fingerprintC) == true)
}

/// `block` is the device's own verdict, so no clear that fails its proof reopens it.
@Test func lockoutGovernorBlockSurvivesAClearForTheSameSecret() async {
    let governor = LockoutGovernor(clock: SteppableClock())
    _ = await governor.reserve(host: "h", account: "admin", count: 1,
                              secretFingerprint: fingerprintA)
    await governor.block(host: "h", account: "admin", reason: "device reports the account locked")
    #expect(await governor.isBlocked(host: "h", account: "admin"))
    #expect(await governor.reserve(host: "h", account: "admin", count: 1,
                                   secretFingerprint: fingerprintA) == 0)
    #expect(await governor.clear(host: "h", account: "admin",
                                 secretFingerprint: fingerprintA) == false)
    #expect(await governor.isBlocked(host: "h", account: "admin"))
    #expect(await governor.clear(host: "h", account: "admin",
                                 secretFingerprint: fingerprintB) == true)
    #expect(await governor.isBlocked(host: "h", account: "admin") == false)
}

// MARK: - Test 7 — clear on success

/// §5 test 7. A credentialed request answered with anything other than `401` is better proof than a
/// fingerprint, so it clears both the budget and the probe window.
@Test func lockoutGovernorRecordSuccessClearsBothFailuresAndProbes() async {
    let governor = LockoutGovernor(clock: SteppableClock())

    _ = await governor.reserve(host: "h", account: "admin", count: 2,
                              secretFingerprint: fingerprintA)
    #expect(await governor.allowProbe(host: "h", account: "admin") == .allowed)
    #expect(await governor.allowProbe(host: "h", account: "admin") == .allowed)
    #expect(await governor.allowProbe(host: "h", account: "admin") == .allowed)
    #expect(await governor.probesRemaining(host: "h", account: "admin") == 0)
    #expect(await governor.isBlocked(host: "h", account: "admin"))

    await governor.recordSuccess(host: "h", account: "admin")

    #expect(await governor.failureCount(host: "h", account: "admin") == 0)
    #expect(await governor.isBlocked(host: "h", account: "admin") == false)
    #expect(await governor.probesRemaining(host: "h", account: "admin")
        == LockoutGovernor.maxProbesPerWindow)
    // And the secrets under test are forgotten, because the device just proved one of them right.
    #expect(await governor.clear(host: "h", account: "admin",
                                 secretFingerprint: fingerprintA) == true)
}

// MARK: - Persistence (§2.8)

/// The hole §2.8 exists to close: quit-and-relaunch must not grant a fresh budget while the device's
/// own lock is still running. A new governor over the same store starts blocked.
@Test func lockoutGovernorRestoresASpentBudgetFromItsStore() async {
    let store = MemoryLockoutStore()
    let first = LockoutGovernor(clock: SteppableClock(), store: store)
    #expect(await first.reserve(host: "h", account: "admin", count: 2,
                                secretFingerprint: fingerprintA) == 2)
    #expect(store.saved.count == 1)

    let second = LockoutGovernor(clock: SteppableClock(), store: store)
    #expect(await second.isBlocked(host: "h", account: "admin"))
    #expect(await second.reserve(host: "h", account: "admin", count: 1,
                                 secretFingerprint: fingerprintA) == 0)
    // §7's ruling: the fingerprint is salted with the persisted `CredentialRef`, so the "did the
    // password actually change" check survives the relaunch too. Before that ruling this returned
    // `true` unconditionally once per launch.
    #expect(await second.clear(host: "h", account: "admin",
                               secretFingerprint: fingerprintA) == false)
    #expect(await second.clear(host: "h", account: "admin",
                               secretFingerprint: fingerprintB) == true)
}

/// A cleared key leaves nothing behind in the store, so it does not grow with every camera that ever
/// signed in.
@Test func lockoutGovernorPrunesEmptyEntriesFromItsStore() async {
    let store = MemoryLockoutStore()
    let governor = LockoutGovernor(clock: SteppableClock(), store: store)
    _ = await governor.reserve(host: "h", account: "admin", count: 1,
                              secretFingerprint: fingerprintA)
    #expect(store.saved.count == 1)
    await governor.recordSuccess(host: "h", account: "admin")
    #expect(store.saved.isEmpty)
}

// MARK: - Fingerprint

/// The fingerprint is salted with the `CredentialRef`, so the same password under two different
/// Keychain handles produces two different values — which is what makes a stored fingerprint
/// unmatchable against a precomputed table.
@Test func secretFingerprintIsSaltedByTheCredentialRefAndTruncated() {
    let refOne = CredentialRef()
    let refTwo = CredentialRef()
    let one = SecretFingerprint.of(ref: refOne, secret: "Hik12345")
    let two = SecretFingerprint.of(ref: refTwo, secret: "Hik12345")
    #expect(one != two)
    #expect(one == SecretFingerprint.of(ref: refOne, secret: "Hik12345"))
    #expect(one != SecretFingerprint.of(ref: refOne, secret: "Hik12346"))
    #expect(one.count == SecretFingerprint.byteCount * 2)
    // Nothing password-derived is recoverable from it, and nothing here is the password.
    #expect(!one.contains("Hik12345"))

    let credential = Credential(ref: refOne, account: "admin", secret: "Hik12345")
    #expect(SecretFingerprint.of(credential) == one)
}
