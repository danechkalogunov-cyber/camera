# Supervisor Ruling — Device Account Lockout

**Scope:** `docs/API_CONTRACT.md` R-25, `docs/spec-core.md` §6.8 rule 2.
**Status:** binding design. Four lane audits and their refutations are inputs; where they disagree, this document decides.
**Baseline:** commit `127e55c`. Line numbers under `Sources/VigilISAPI/` were read at that commit and are being edited concurrently by other agents.

---

## 1. The arithmetic

**The true worst case is unbounded.** There is no number. The device's ~5-failure lock is crossed roughly twenty seconds into the *first* connect attempt of the *first* connection to a camera with a wrong password, and Vigil then keeps going forever. Plainly: **five or more, on the first attempt, with no user action and no device quirk.**

The tightest honest figure for one bounded window: **10 credentialed 401s per connect attempt, ~200 in the first two minutes, then 10 every five minutes indefinitely.** Take that as the headline number; the unbounded part is what actually matters.

### The one sequence

Wrong stored password. Camera not remembered, so `resolvedCandidate == nil` (`StreamController.swift:205`) and the ladder runs. Ordinary loaded NVR: some answers arrive slower than five seconds.

1. `AppSessionModel+Session.swift:197-202` builds `StreamController` with **no `governor:` argument**, so `StreamController.swift:202` mints a private `LockoutGovernor` owned by that controller. This is the only `StreamController(` call site in the repo and the only `LockoutGovernor(` construction in `Sources/`.
2. `runAttempt` reads `governor.isBlocked` once, at `StreamController+Session.swift:58`. Count is 0. **This is the last governor consultation the entire attempt makes.** Nothing consults it between rungs; `allowProbe` has zero callers; `StreamProbe.swift` contains no reference to `LockoutGovernor` at all.
3. `resolvePath` → `probe.probe` (`StreamController+Session.swift:147`). The ladder is 5 rungs (`RTSPPathCandidates.swift:80-101`). Each rung calls `dependencies.makeRTSPSession` (`StreamProbe.swift:180`), which builds a fresh `RTSPConnection` → fresh `RTSPSessionMachine` → fresh `RTSPAuthenticator` with `failureCount == 0` (`CoreDependencies.swift:78-86`).
4. **Per rung:** OPTIONS with no `Authorization` → 401 → `RTSPAuthenticator.swift:218-221` adopts and returns `.retry`. **Free — no credentials reached the device.** Resend carries `Authorization` (`RTSPSessionMachine.swift:334-338`) → 401 → `RTSPAuthenticator.swift:223`, `failureCount = 1`, `.retryWithURIFallback` → **credentialed failure.** The URI-fallback resend also carries `Authorization` → **second credentialed failure.**
5. **The break.** Vigil only *classifies* that second failure as auth if it reads the answer. Three code paths turn it into "wrong path" instead, each verified:
   - `RTSPSessionConfig.requestTimeout = 5 s` (`RTSPSessionConfig.swift:81`) fires → `RTSPSessionMachine.swift:219-223` `terminate(.timeout(.requestTimeout))` → `ProbeRun.classify` `case .timeout: return .advance(describeTimeout)` (`StreamProbe.swift:357-358`).
   - The device closes the control socket after rejecting twice → `RTSPSessionMachine.swift:257-265` `terminate(.timeout(.dataIdle))` → same `.advance`.
   - `StreamProbe`'s 8 s per-candidate deadline (`StreamProbe.swift:64, 183-186`) fires → `.advance(describeTimeout)`.
6. `.advance` → `evaluate` returns `.keepGoing` (`StreamProbe.swift:216-217, 226-227`) → the `while` loop at `StreamProbe.swift:137-148` walks to the next rung. **10 credentialed 401s per pass. The account locks partway through rung 3, about twenty seconds in. Vigil finishes the ladder.**
7. `.exhausted(describeTimeout)` → `resolvePath` at `StreamController+Session.swift:167-168`: `describeTimeout` is not in `isUserFixable` (`StreamError.swift:143-150`), so it returns `.give(.retry(...))`. `governor.block` at `:163` is never reached — that arm requires `.authenticationRequired`. `resolvedCandidate` stays `nil`.
8. `runLoop`'s `.retry` arm (`StreamController.swift:393-411`): 20 attempts on 0.5/1/2/4/8/15/30 s (`ReconnectPolicy.swift:46-51`), each re-running the whole 5-rung ladder. Then `attempt = 0` and a 300 s cold retry, **forever** (`StreamController.swift:395-402`). `forbidsColdRetry` (`StreamError.swift:156-163`) never applies because the outcome is `.retry`, not `.failed`. `StreamError.Code.accountLocked` has no producer in `VigilCore` or `VigilRTSP`, so a locked device is indistinguishable from a slow one.

### Three amplifiers on top of that sequence

- **Nonce rotation makes a single rung unbounded.** `RTSPAuthenticator.swift:216-222`: when the returned nonce differs, the guard's else branch runs `adopt` + `.retry` and `failureCount` is never incremented (line 223 is skipped). `adopt` (`:235-242`) also resets `issuedAuthorization = false`. `RTSPSessionMachine.swift:802` then caps on `authenticator.failureCount < 2` — a counter that never moves. Every resend carries credentials. Hundreds of credentialed rejections per 8 s rung, bounded only by the 20 s watchdog (`StreamController+Timers.swift:61, 108-113`), whose `.connectTimeout` is transient, so the ladder runs again.
- **The concurrency widening is real but is not the dominant term.** `provesAuthentication` (`StreamProbe.swift:254-263`) treats `.advance(.rtspPathNotFound)` as proof; `ProbeRun` manufactures exactly that code from a **3xx** (`StreamProbe.swift:328-330`) and from a 404-family answer to the **uncredentialed** OPTIONS (`RTSPSessionMachine.swift:861-870`). `inFlight` becomes 3 (`StreamProbe.swift:130`) on evidence involving no credential, and the task group drains all three children (`:197-199`) before any verdict — 6 credentialed 401s in one burst. The audit's structural finding is upheld; the refutation's correction is accepted: **the ladder, not the reentrancy, is the multiplier.**
- **Counter identity is broken above the controller.** `AppSessionModel+Session.swift:41` (`controller = nil` in `stopSession()`) destroys the private governor. The `.error` arm at `:273-285` calls `stopSession()`, and `form.password` is only cleared on first frame (`:258`), so re-submitting is one keystroke away. `perform(.retry)` → `connect(form.request)` (`AppSessionModel.swift:326-327, 277-287`) mints a new controller with an empty `failures` dictionary. Every press grants two more. `credentialsUpdated(account:)` — the one designed `governor.clear` caller (`StreamController.swift:340-341`) — has **zero callers**: the budget is cleared by deallocation, not by an explicit call, which is why no audit of `clear()` call sites would find it.

### What the governor actually enforces today

`recordCredentialedFailure` (`LockoutGovernor.swift:88-95`) has zero callers in `Sources/` and `Tests/`. The governor is written only by `block()` (`StreamController+Session.swift:163, 438-441`), which stamps a flat `2` (`LockoutGovernor.swift:107-111`) and fires only when a *terminal* `authRejected`/`unauthorized` surfaces. So the governor is a **boolean latch, not a counter**. It enforces "at most one terminal auth failure per controller instance", not R-25's "at most two credentialed 401s per device, ever". Every credentialed 401 that does not end in a terminal classification is invisible to it — which is the whole cost of the sequence above.

### Cross-lane, stated precisely

`AuthLockoutRegistry.shared` (`AuthLockoutRegistry.swift:29`) keys on `(host, port, account)` (`:37-41`); `LockoutGovernor.Key` is `(host, account)` (`:38-50`). Neither reads the other. **No file in `Sources/` imports `VigilISAPI`** (grep-verified), so this is +2 latent, not +2 live today — `VigilCore` links the module in `Package.swift` but nothing imports it. It becomes live on the first import. The ISAPI lane has its own uncounted loop: `DigestStore.header` returns a pre-emptive `Authorization` whenever a challenge is cached (`DigestStore.swift:172-177`), attached to the first leg at `ISAPIClient.swift:463-464`; a rotated-nonce 401 returns `.retry` (`DigestStore.swift:119-124`) and `ISAPIClient.swift:496-499` grants two further credentialed sends before `authFailure` records anything — 3 credentialed rejections booked as 1, 5 on the lane before it blocks.

---

## 2. The unification

### 2.1 Which type survives

**`LockoutGovernor` survives. `AuthLockoutRegistry` is deleted outright — not made a forwarder.**

A forwarder would keep the `(host, port, account)` signature alive as the ISAPI-facing API, and keeping two types is precisely how two counters happened. Delete the file and rewrite its five call sites.

**Move `LockoutGovernor` from `Sources/VigilCore/Security/LockoutGovernor.swift` to `Sources/VigilProtocols/Security/LockoutGovernor.swift`, dropping the `#if os(macOS)` guard.** `VigilProtocols` is the only module both lanes already depend on (`Package.swift`: `VigilISAPI` deps `["VigilProtocols"]`; `VigilCore` deps include it), it is Foundation-only, and it already holds every type the governor uses — `Credential` (`Net/Credential.swift:26`), `MonotonicClock` (`Time/Clocks.swift:17`), `LoggerProtocol`, `NullLogger` (`Logging/LoggerProtocol.swift:57, 145`), `Redact`, `MediaInstant`, `Duration`. The move also puts it on the `VigilPure` product, which is what makes the tests in §5 Linux-runnable. **VigilISAPI never imports VigilCore; it does not have to.**

### 2.2 The key

**`Key = (host: String, account: String)`. The port is OUT.**

The safety property is a fact about the *device's* tally, and the firmware keeps one tally per account regardless of which service the rejection arrived on. A camera answers ISAPI on 80 and RTSP on 554; one account is one account. Including the port splits one device budget into two, which is the bug.

The existing justification for including it (`AuthLockoutRegistry.swift:35-36`, "two devices behind one NAT differ only by port") names a real case and is **overruled**. Two port-forwarded cameras behind one public IP will share a budget under this key, so a wrong password on camera A will make Vigil refuse to sign in to camera B. That is over-blocking: recoverable by entering a password, and it is the fail-safe direction. Splitting by port under-blocks, and under-blocking is a 30-minute admin lockout — the exact failure the rule exists to prevent. Vigil is a LAN viewer; the NAT case is rarer than the single-device case by a wide margin. Document the limitation on `Key` and move on.

### 2.3 Where the instance lives, and how it reaches both lanes

- **Owner:** one stored `let governor: LockoutGovernor` on `AppEnvironment` (`Sources/Vigil/AppEnvironment.swift`), built once per process. Nothing else in the app may construct one.
- **Injection into VigilCore:** add a **non-optional** `governor: LockoutGovernor` field to `CoreDependencies` (`Sources/VigilCore/Platform/CoreDependencies.swift`), set in the memberwise init and in `.live` (`:73-86`). `StreamController` reads `dependencies.governor`. `StreamProbe` gets it for free — it already stores `dependencies` (`StreamProbe.swift:52`), so **no signature change**, which matters because `StreamProbe` is where the credentials are actually spent.
- **Injection into VigilISAPI:** `ISAPIClient.init` takes `governor: LockoutGovernor` as a **required parameter with no default**. Replace the field at `ISAPIClient.swift:110` and the parameter at `:154`. Delete `AuthLockoutRegistry.shared` (`:29`) and every `= .shared` default. A defaulted parameter is exactly how the private-counter bug happened on the RTSP side; it must not be reintroduced on the HTTP side.

### 2.4 The optional parameter that silently creates a private counter

**Delete `governor: LockoutGovernor? = nil` (`StreamController.swift:189`) and the `governor ?? LockoutGovernor(...)` fallback (`:202`).** After the move there is no initialiser anywhere that can produce a private counter, and the only construction site in the app is `AppEnvironment`. A private counter becomes unrepresentable rather than merely discouraged. The doc comment at `StreamController.swift:179-182` — which states the requirement and then hands out a default that violates it — is deleted with it.

This also fixes the counter-dies-with-the-controller hole at `AppSessionModel+Session.swift:41` by construction: the governor outlives every controller because the app owns it.

### 2.5 Counting model: reservation, not counting

**This is the load-bearing decision.** A count-after-the-fact model cannot be made safe here, for three independent reasons already demonstrated in §1: concurrent sends all land before the first record; a rejection Vigil misclassifies is never recorded; and a credentialed request whose answer Vigil never reads is invisible while the device saw it perfectly well. So:

**Strikes are debited before a credentialed request can be written, and refunded only against evidence.**

```swift
// Sources/VigilProtocols/Security/LockoutGovernor.swift
public actor LockoutGovernor {
    public struct Key: Hashable, Sendable { public var host: String; public var account: String }
    public static let maxCredentialedFailures = 2
    public static let maxProbesPerWindow = 3
    public static let probeWindow: Duration = .seconds(600)

    /// Debits up to `count` credentialed sign-in attempts; returns how many were granted (0…count).
    public func reserve(host: String, account: String, count: Int) -> Int

    /// Returns strikes that were never put on the wire (a connection that failed before sending).
    public func refund(host: String, account: String, count: Int)

    /// A credentialed request was answered with anything other than 401: the password is right.
    /// Clears failures AND the probe window for this key.
    public func recordSuccess(host: String, account: String)

    /// The device itself reports the account locked (ISAPI /Security/userCheck): spend nothing more.
    public func block(host: String, account: String, reason: String)
    public func isBlocked(host: String, account: String) -> Bool
    public func allowProbe(host: String, account: String) -> ProbeDecision      // §3
    public func clear(host: String, account: String, secretFingerprint: String) -> Bool  // §4
}
```

`recordCredentialedFailure` (`:88-95`) is deleted; it never had a caller and its contract ("must never be reached by a fresh nonce") is the wrong contract — see §2.7.

**The allowance reaches the wire through config, not through an await.** Add `RTSPSessionConfig.credentialedAttemptAllowance: Int` (default `2`) alongside `maxAuthAttemptsPerRequest` (`RTSPSessionConfig.swift:109`). `RTSPAuthenticator` refuses to produce an `Authorization` once it has issued that many (`authorization(for:uri:)`, `RTSPAuthenticator.swift:264-304`, which is the single place `issuedAuthorization` is set, at `:267` and `:302`) and sets terminal `.authRejected` instead. The pure machine stays synchronous; the budget is a number handed to it at construction. Callers set it from `reserve`.

**Add a second, independent per-connection brake for the rotated-nonce loop.** `RTSPAuthenticator.maxCredentialedSendsPerConnection = 3`, counted on every `Authorization` issued, not cleared by `reset()` (same reasoning as `failureCount` at `:348-355`). Three, not two, so one genuine `stale=true` re-auth still works. `absorb` sets terminal `.authRejected` when the cap is hit, which `RTSPSessionMachine.swift:795-796` already honours. This is what closes `RTSPSessionMachine.swift:802`'s comparison against a counter that never moves.

**Book the rejection at send, clear on success.** The machine already knows: `PendingRequest.carriedAuthorization` (`RTSPSessionMachine.swift:347`). Add `RTSPConnectionEvent.credentialedRequestSent` and `.credentialedRequestAccepted`, emitted by `RTSPConnection` from the machine's actions, and handle both in `StreamController.handle(_:)` (`StreamController+Session.swift:178-197`) and in `ProbeRun.run()`'s event loop (`StreamProbe.swift:305-339`). `.credentialedRequestAccepted` → `governor.recordSuccess`. This mirrors what the ISAPI lane already gets right (`noteAuthenticationSucceeded`, `ISAPIClient.swift:645-649`); the RTSP lane has no clear-on-success today and gains one.

### 2.6 The probe ladder gets one strike for the whole sequence

The decisive sequence dies here. In `resolvePath` (`StreamController+Session.swift:139-170`), after the two short-circuits and before `probe.probe` at `:147`:

- `reserve(count: 1)` for the entire probe sequence.
- **Rung 1 runs with `credentialedAttemptAllowance = 1`. It is the only rung that may ever send credentials.**
- Rung 1's credentialed request answered non-401 → `recordSuccess` → password **proven** → rungs 2…5 run with a full allowance and `inFlight = 3`.
- Rung 1 answered 401 → `.authenticationRequired`, ladder stops (already the behaviour at `StreamProbe.swift:212-215`), strike spent.
- Rung 1 proves nothing (timeout, socket close, malformed) → strike spent (booked at send) → **rungs 2…5 run with allowance 0.** They can still answer "does this path exist" against an unauthenticated device; a rung that meets a 401 with allowance 0 returns `.authenticationRequired` without sending anything, which is the honest answer and stops the ladder.

**Five rungs can now spend at most one credentialed 401 between them.**

This also retires `ProbeResult.provesAuthentication` (`StreamProbe.swift:246-263`) in its current form. Proof stops being inferred from the *shape* of an answer — which is unsound, because `StreamProbe.swift:328-330` manufactures `.rtspPathNotFound` from a 3xx and `RTSPSessionMachine.swift:861-870` produces the 404 family in answer to the **uncredentialed** OPTIONS — and becomes the single fact "this rung's credentialed request got a non-401 answer", reported by the connection. Rewrite `provesAuthentication` to read that flag; delete the redirect and 404-family inferences.

Add `group.cancelAll()` in `evaluate`'s task group (`StreamProbe.swift:172-200`) as soon as any child reports a credentialed rejection, so `:197-199` can no longer drain three logins onto the wire before the first verdict.

### 2.7 One doc correction this forces

`LockoutGovernor.swift:81-86` and R-25 rule 1 currently say a rotated-nonce or `stale=true` 401 "must never" reach the counter. That is correct reasoning about *our* Digest state machine and says nothing about the *device's* tally. **Ruling: the governor counts every credentialed request answered 401, with exactly one exception — a challenge carrying `stale=true` whose nonce differs, which RFC 2617 defines as the server explicitly asking us to re-authenticate with credentials it has not rejected.** A *silently* rotated nonce with no `stale` flag is counted. Amend `docs/API_CONTRACT.md` R-25.1 and the `LockoutGovernor` header. `Tests/VigilRTSPTests/RTSPDigestTests.swift:92-121` stays valid as a statement about the Digest protocol — the loop is bounded by §2.5's send cap, not by `failureCount`.

### 2.8 Persistence

Neither counter is persisted today, so quit-and-relaunch grants a fresh budget while the device's 30-minute lock is still running. **Persist `Key → (failures, lastFailureAt, secretFingerprint)`** through a small `LockoutStore` protocol in `VigilProtocols`, with a `UserDefaults` implementation in `Sources/Vigil` beside `LastConnection` (`AppEnvironment.swift:59`). TTL 30 minutes from `lastFailureAt`, matching the firmware's documented lock window.

### 2.9 Files to change

| File | Change |
|---|---|
| `Sources/VigilCore/Security/LockoutGovernor.swift` | **moved** to `Sources/VigilProtocols/Security/LockoutGovernor.swift`; `#if os(macOS)` dropped; `reserve`/`refund`/`recordSuccess`/`allowProbe` reshaped; `recordCredentialedFailure` deleted |
| `Sources/VigilISAPI/Client/AuthLockoutRegistry.swift` | **deleted** |
| `Sources/VigilISAPI/Client/ISAPIClient.swift` | `:110`, `:154` take `LockoutGovernor`, no default; `:479-481`, `:491`, `:566-572`, `:629-641`, `:645-649` rewritten to `reserve`/`recordSuccess`/`block`; `:496-499` must debit before each extra credentialed send |
| `Sources/VigilProtocols/Security/LockoutStore.swift` | **new** — persistence protocol |
| `Sources/Vigil/AppEnvironment.swift` | owns the one `LockoutGovernor` + the `UserDefaults`-backed store |
| `Sources/VigilCore/Platform/CoreDependencies.swift` | non-optional `governor` field; `.live` at `:73-86` |
| `Sources/VigilCore/Streaming/StreamController.swift` | delete `:189` parameter and `:202` fallback; use `dependencies.governor`; `.retry` arm at `:393-411` honours `signInPaused`'s retry-after |
| `Sources/VigilCore/Streaming/StreamController+Session.swift` | `allowProbe` + `reserve` before `:147`; handle the two new events in `handle(_:)` at `:178-197`; add the generation guard the event loop at `:117-120` is missing |
| `Sources/VigilCore/Streaming/StreamProbe.swift` | per-rung allowance (§2.6); rewrite `provesAuthentication` `:246-263`; `cancelAll` in `:172-200`; handle new events in `ProbeRun.run()` `:305-339` |
| `Sources/VigilCore/Streaming/StreamError.swift` | new `.signInPaused` code + message/remedy (§3) |
| `Sources/VigilRTSP/Machine/RTSPSessionConfig.swift` | `credentialedAttemptAllowance` beside `:109` |
| `Sources/VigilRTSP/Auth/RTSPAuthenticator.swift` | allowance + `maxCredentialedSendsPerConnection`; `reset()` at `:348-355` preserves both |
| `Sources/VigilRTSP/Machine/RTSPSessionMachine.swift` | emit the credentialed-send/accepted actions from `request(...)` `:333-338`; `:802` guard on the send cap |
| `Sources/VigilTransport/RTSPConnection.swift` | map the new actions to the new `RTSPConnectionEvent` cases (`:36-63`) |
| `Sources/VigilUI/Connect/ConnectDiagnosis.swift` | new case + remedies (§3) |
| `Sources/Vigil/ConnectDiagnosisMapping.swift` | map `.signInPaused` at `:33-41` |
| `docs/API_CONTRACT.md`, `docs/spec-core.md`, `docs/spec-isapi.md` | R-25 rule 1 wording; §6.8 rule 2 call site; §4.7 registry removal |

---

## 3. The probe limit

### Where the call goes

**`StreamController+Session.swift`, inside `resolvePath(credential:)`, after the `resolvedCandidate` short-circuit at `:140` and the `rtspPathOverride` short-circuit at `:141-145`, immediately before `probe.probe` at `:147`.**

That is the only correct point, and it is provably the only point: `probe.probe` has exactly one caller in the repo (`StreamController+Session.swift:147`), and `findWorkingPath` (`StreamProbe.swift:76-84`) has zero. The two short-circuits above it must stay above it, because a learned path and a user-typed override are not probe sequences and must not consume the budget.

### What it does when it refuses

`allowProbe` returns `ProbeDecision.refused(retryAfter: Duration)` rather than `Bool`, computed from the oldest timestamp in the window (`LockoutGovernor.swift:147`). On refusal `resolvePath` returns

```swift
.give(.retry(StreamError(code: .signInPaused,
                         context: ["retryAfterSeconds": String(Int(retryAfter.seconds))])))
```

**No socket is opened, no reservation is debited.** `signInPaused` is **not** in `isUserFixable` and **not** in `forbidsColdRetry` (`StreamError.swift:143-163`) — the rate limit is a wait, not a verdict. `runLoop`'s `.retry` arm (`StreamController.swift:404-411`) must, for this one code, sleep `max(ladderDelay, retryAfter)` instead of the ladder delay, or it will spin at the gate for ten minutes; `nextRetryAt` is set from the same value, which is what feeds the countdown the UI already renders (`AppSessionModel+Session.swift:225`).

### What the user is told

New `StreamError.Code` case: **`signInPaused`**.

- `message` (`StreamError.swift:167`): **"Vigil paused sign-in attempts to protect this camera's account."**
- `remedy` (`:204`): **"Nothing to do — Vigil will try again by itself."**

New `ConnectDiagnosis` case, which is where user-facing copy carrying a number already lives (`.accountLocked(host:minutesRemaining:)`, `ConnectDiagnosis.swift:42`):

```swift
case signInPausedByVigil(host: String, minutesRemaining: Int)
```

- **Title:** "Waiting before trying again"
- **Message:** **"Vigil stopped signing in to {host} so the camera's account cannot be locked out. It will try again in about {minutesRemaining} minutes. Nothing is wrong with the camera."**
- **Remedies:** `[.updatePassword, .openCameraWebPage]` — the first moves focus to the password field, which is the one action that legitimately shortens the wait (§4); the second lets the user check the account on the device without spending Vigil's budget. Neither retries, neither is a dead end.
- `allowsAutomaticRetry` = **`true`** (`:75-84`): Vigil *is* retrying, and `AppSessionModel+Session.swift:277` must therefore not tear the session down.
- `fieldToFocus` = `.password` (`:87-98`); tint = `warn`, not `danger` — nothing has failed.

**Reusing `authenticationFailed` here is forbidden.** Its message is "The camera rejected the password" (`StreamError.swift:169`) and on this path the camera has rejected nothing. Note that the *existing* `isBlocked` refusal at `StreamController+Session.swift:59-63` also returns `authenticationFailed`; that one stays, because two real rejections did happen — but its remedy string should read "Vigil stopped trying after two rejected sign-ins, to keep the account from locking. Enter the password again to let it retry."

---

## 4. Clear-on-password-change

**Ruling: a new password may reset the counter. The same password may not. Neither may an unbounded number of new ones.**

Today `credentialsUpdated(account:)` (`StreamController.swift:340-349`) calls `governor.clear` unconditionally, with no check that the secret changed, and the `account` argument is caller-supplied and never reconciled with `credentialProvider()`'s `Credential.account`, which is what the gate and `block()` key on (`StreamController+Session.swift:54, 58, 438-441`) — a mismatch silently clears nothing. It has zero callers, so today the reset happens by deallocation instead. Both halves are wrong.

Three constraints, all required:

1. **Proof of difference.** `clear` takes a fingerprint, not a promise:
   ```swift
   public func clear(host: String, account: String, secretFingerprint: String) -> Bool
   ```
   The governor stores the fingerprint of the secret that was rejected and clears **only** when the new one differs, returning `false` otherwise. The fingerprint is `SHA256(processSalt ‖ secret)` truncated to 16 bytes, using `VigilProtocols/Crypto/SHA256.swift`, with a per-process random salt so nothing password-derived is ever persisted or logged. `Credential.secret` is in-process (`Credential.swift:34`), so this is computable at the call site. **This is the single most important line in this section:** a user whose password genuinely is wrong will retype the same characters, and that is the most likely route to a real lockout.

2. **A ceiling on distinct passwords.** Three *different* rejected passwords for one key inside `probeWindow` and the key stops accepting clears until the window drains. A user who has tried three passwords is guessing, and guessing is what locks accounts. This reuses the probe window; no new state.

3. **The account must be the one the gate keys on.** Delete the `account:` parameter from `credentialsUpdated`. Read `credentialProvider()`'s `Credential.account` inside the method, exactly as `runAttempt` does at `StreamController+Session.swift:54`, so the clear and the block can never key differently.

Also fix, in the same change, the misfire the audit found: `credentialsUpdated` from `.failed` calls `start()`, which returns immediately on its `runTask == nil` guard (`StreamController.swift:264`) because the loop is asleep in the 300 s cold retry with `runTask` still set (`:386-391`). Fail-safe for lockout, wrong for the user. `credentialsUpdated` must cancel and join before starting.

And wire it up: give `credentialsUpdated` its missing caller. On a successful Keychain save in `AppSessionModel.connect(_:ref:rtspPath:)`, call it instead of rebuilding the controller — the rebuild path (`AppSessionModel.swift:277-287` → `stopSession()` → `AppSessionModel+Session.swift:197`) is what grants two more strikes today, and after §2.4 the governor survives the rebuild but the *clear* still has to be explicit and still has to pass the fingerprint check.

---

## 5. Tests

This is not closed until all nine exist and pass. Tests 1–4 **fail today**; 5 and 7 cannot be written today.

**Pure / Linux — `Tests/VigilRTSPTests/RTSPSessionMachineTests.swift`**

1. **FAILS TODAY.** Drive the machine with a 401 whose nonce is fresh on every response and which never sets `stale`. *Assert: the machine writes at most 3 requests carrying an `Authorization` header, then terminates with `.authRejected`.* Today it writes unboundedly — `RTSPAuthenticator.swift:216-222` never increments `failureCount` and `RTSPSessionMachine.swift:802` caps on that same counter.
2. **FAILS TODAY.** With `credentialedAttemptAllowance = 0`, answer OPTIONS with a 401 challenge. *Assert: zero requests carry an `Authorization` header and the machine terminates `.authRejected`.* No such config field exists today.

**Pure / Linux — `Tests/VigilProtocolsTests/LockoutGovernorTests.swift` (new)**

3. **FAILS TODAY (unwritable).** *Assert: `reserve(host:"h", account:"admin", count: 2)` returns 2; an immediate second `reserve(count: 2)` returns 0; `refund(count: 1)` then makes the next `reserve(count: 2)` return 1.*
4. **FAILS TODAY (unwritable).** *Assert: strikes debited via the ISAPI lane's port-80 endpoint and the RTSP lane's port-554 endpoint draw from the same key — two reserves of 1 exhaust the budget across the two lanes.* This is the port-in-the-key ruling, and it is unwritable today because the two counters are different types.
5. *Assert: `allowProbe` grants 3 within `probeWindow`, refuses the 4th with `retryAfter` equal to `probeWindow` minus the age of the oldest, and grants again once the clock advances past it.* Uses the injected clock (`LockoutGovernor.swift:74`) — no real waiting.
6. *Assert: `clear(secretFingerprint:)` returns `false` and leaves the count when the fingerprint equals the rejected one; returns `true` and zeroes it when it differs; returns `false` for a third distinct fingerprint inside the window.*
7. *Assert: `recordSuccess` clears both `failures` and `probes` for the key.*

**macOS — `Tests/VigilCoreTests/` (which contains only `Placeholder.swift` today)**

8. **FAILS TODAY, and this is the one that pins §1's sequence.** Fake `makeRTSPSession` factory that counts every request carrying an `Authorization` header. Script every rung to answer the uncredentialed OPTIONS with a 401 challenge, then let the credentialed resend time out and the socket close. Run `StreamController.start()` through the full 20-attempt ladder on a fake clock. *Assert: total credentialed requests across the entire run ≤ 2, and after the second the factory is never invoked again.* Today: ~10 per attempt, ~200 across the ladder, then forever.
9. **FAILS TODAY.** Governor pre-loaded with a full probe window. *Assert: `runAttempt()` returns `.retry` with code `.signInPaused` carrying a non-zero `retryAfterSeconds`, and the session factory is invoked **zero** times.* Today `allowProbe` has no callers and the factory is invoked five times.
10. Controller-lifetime test. Governor `G`; controller A spends the budget; drop A; build controller B on the same `CoreDependencies`. *Assert: B's session factory is never invoked.* Plus a compile-level guarantee: `StreamController.init` has no `governor` parameter, so no test can accidentally construct a private one.
11. Concurrency test. Probe window widened to 3 in flight with a proven password, then all three rungs answer 401. *Assert: at most one credentialed request reaches the wire and the sibling tasks are cancelled before writing theirs.*

**macOS — `Tests/VigilISAPITests/`**

12. Rotated-nonce 401 on every response, one `send()`. *Assert: at most 1 credentialed request per debited strike — i.e. `ISAPIClient.swift:496-499`'s two extra credentialed sends each debit the governor before being written, and the third is refused.* Today three go out for one recorded failure.
13. *Assert: a 200 answer to a credentialed request calls `recordSuccess`, and a subsequent 401 therefore starts from a full budget* — preserving the behaviour `ISAPIClient.swift:645-649` already has.

---

## 6. What I could not establish

Named, not smoothed over.

1. **Whether Hikvision firmware increments its own failed-login tally on a rotated-nonce or `stale=true` 401.** Not readable from any code in this repo. It decides whether the nonce-rotation loop locks an account in milliseconds or is "merely" an unbounded credentialed-auth flood. I ruled the conservative way (§2.7: count everything except an explicit `stale=true`), which is safe under either answer but will produce a spurious "Vigil paused" card on a `stale`-happy device. **This must be settled against a real device before any number in §1 is called exact.**
2. **The real lock threshold and window.** Every comment in the tree says "about five" and "about thirty minutes" (`LockoutGovernor.swift:11-12`, `AuthLockoutRegistry.swift:9-10`, `RTSPSessionConfig.swift:105-107`). Whether it is 5 or 7, whether it resets on success, and whether it is per-account or per-account-per-service are all unverified. The budget of 2 is safe under any plausible value, but the §3 copy's "about N minutes" is only as honest as this number.
3. **Whether a truthful unlock countdown is obtainable.** `ISAPIClient.swift:477-486` reads `lockStatus`/`retryLoginTime` out of a 401 body, which implies it is available pre-auth, but I did not verify that against a device. Without it, `ConnectDiagnosis.accountLocked(minutesRemaining:)` can only ever be `nil`.
4. **I compiled nothing and ran nothing.** No test executed, no device touched. In particular, moving `LockoutGovernor` to `VigilProtocols` drops an `#if os(macOS)` guard; I read every type it uses and all are pure, but `swift build --product VigilPure` on Linux is the only proof and I did not run it.
5. **The stale-event-drain interleaving.** I confirmed by reading that the event-consumption phase has no generation guard (`StreamController+Session.swift:117-120`; the only check is `StreamController.swift:361`) and that buffered events survive `close()` (`RTSPConnection.swift:381-390, 1388-1389`). I could not establish whether the multi-event drain is actually reachable on the real executor. The reservation model makes it lockout-irrelevant; it remains a state-corruption bug (a stale handler closing the live attempt's session at `:448-451`, clearing `resolvedCandidate` at `:253-260`) and still needs the guard. **Ruled in as required, evidenced as unproven.**
6. **`RTSPConnection` cancellation.** `connect()` is a bare `withCheckedContinuation` with no `withTaskCancellationHandler` (`RTSPConnection.swift:661-693`), and `stop()` cancels `runTask` without joining it (`StreamController.swift:280-282`). I did not trace every unstructured `Task` inside the connection actor, so I cannot bound how long a cancelled probe keeps running. The reservation model makes that survivable; a joining `stop()` is still owed.
7. **`VigilISAPI` is being edited by other agents right now.** Every `Sources/VigilISAPI/` line number above was read at `127e55c` and may have moved. The rulings are about behaviour, not offsets.
8. **The NAT false-merge in §2.2 is a real, accepted regression** and I did not quantify how often it occurs in the target deployment. If it turns out to be common, the fix is a device-identity discriminator resolved from the library — **not** putting the port back in the key.
9. **Persistence store choice.** I ruled that the counter must survive relaunch and proposed `UserDefaults` beside `LastConnection` (`AppEnvironment.swift:59`). I did not check the project's security documentation for whether a per-device failure count and a salted secret fingerprint are acceptable there. The salt is per-process and unpersisted, so a stored fingerprint is useless across launches — meaning after a relaunch the failure count survives but the "did the password change" check cannot, and the first clear after a relaunch will be granted. **That is a real residual hole in §4 and I did not close it.**
---

## 7. Supervisor addendum — closing gap 9

The ruling flags its own residual hole and it is a real one, so it gets decided rather than inherited.

**Gap 9 restated.** §4 gates `clear` on a fingerprint `SHA256(processSalt ‖ secret)`. The salt is
per-process and unpersisted, so after a relaunch the stored fingerprint cannot be reproduced. The
failure count survives, the comparison does not, and the first clear after every relaunch is granted
unconditionally — which hands back the exact bypass §4 exists to close, once per launch. Quitting the
app is not a difficult thing for a user to do while guessing a password.

**Ruling: salt with the `CredentialRef`, not with a process-random value.**

```
fingerprint = SHA256(credentialRef.uuidString ‖ secret) truncated to 16 bytes
```

The `CredentialRef` is already persisted — `LastConnection` stores it (`Sources/Vigil/…`), and it is
the Keychain handle, so it necessarily outlives the process. That makes the fingerprint reproducible
across launches, which is the whole requirement, and costs no new storage.

Why this is acceptable where a bare `SHA256(secret)` would not be: the ref is a per-device random
UUID, so the stored value is not a hash of the password alone. An attacker who reads the persisted
file gets a salted, truncated digest and must already know which device it belongs to; they cannot
match it against a precomputed table, and they gain nothing they could not get more directly, since
anyone with read access to the app's container is already past the boundary the Keychain defends.

Two consequences to implement rather than discover:

1. **The fingerprint is derived where the ref is known.** `VigilProtocols` must not reach for a
   `CredentialRef` it does not own; pass the fingerprint in, computed by the caller, exactly as §4
   already has it. The governor stores and compares, never derives.
2. **Rotating the Keychain item rotates the fingerprint.** If a `CredentialRef` is ever regenerated
   for the same host and account, every stored fingerprint for that key becomes unmatchable and the
   next clear is granted. That is the fail-open direction, so it must be bounded: constraint 2 of §4
   (three distinct rejected secrets per window) is the backstop, and it keys on the count, not on the
   fingerprint. Keep both.

**Also ruled, on gap 2.** Do not write "about N minutes" into any user-facing string until the real
lock window is measured against a device. Until then the copy says that Vigil will try again by
itself, with the countdown driven by *Vigil's own* `probeWindow` — a number we control and can state
truthfully — and never by a guess at the firmware's. A confident wrong number is the failure mode
this project has spent its whole budget refusing.
