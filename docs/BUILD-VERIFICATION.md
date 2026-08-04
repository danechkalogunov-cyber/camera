# Build verification — what has actually been compiled, and the defects it caught

Development happens in a Linux container with **Swift 6.1.2** and no Xcode. That means the
platform-independent half of Vigil can be genuinely compiled and unit-tested here, while the
macOS-only half can only be type-checked on a Mac. This document records what has really been run,
so nobody mistakes a reviewed file for a compiled one.

## Toolchain in use

```
$ swift --version
Swift version 6.1.2 (swift-6.1.2-RELEASE)
Target: x86_64-unknown-linux-gnu
```

`swift-testing` (the `@Test` / `#expect` library) is present and works, so tests are written with it
rather than XCTest.

## What was verified, and when

### 1. Swift 6 language mode, actors and swift-testing work on Linux — verified

A throwaway package with an `actor` holding a bounded queue, a `Sendable` value type, and three
`@Test` cases built and passed under `swiftLanguageMode(.v6)`. This is what licenses the whole
architectural bet in `ARCHITECTURE.md` §4: the pure layer really is testable in CI without a Mac.

### 2. `Package.swift` from `ARCHITECTURE.md` §3 — verified, after two fixes

The manifest was extracted verbatim from the spec, every declared target directory was scaffolded
with a stub file, and both build worlds were run. Two real defects surfaced.

#### Defect 1 — the Linux purity gate did not work (`--product` on an automatic library)

`ARCHITECTURE.md` designates `swift build --product VigilPure` as *the* command Linux CI runs, and
the mechanism that keeps the pure layer pure: if someone adds `import CoreMedia` to `VigilRTP`, that
product must stop building. As originally written, the product had no explicit `type:`, so SwiftPM
treated it as an **automatic** library and refused to target it:

```
warning: '--product' cannot be used with the automatic product 'VigilPure';
         building the default target instead
```

"Building the default target instead" means the command silently builds the *whole package* — so the
gate would have passed on any code, including code that violated the purity rule it exists to
enforce. A gate that cannot fail is worse than no gate, because it is trusted.

**Fix:** declare `type: .static` on the `VigilPure` product. Now:

```
$ swift build --product VigilPure
...
[32/33] Archiving libVigilPure.a
Build of product 'VigilPure' complete! (4.33s)
```

`ARCHITECTURE.md` §3 has been amended with the fix and an explanatory comment.

#### Defect 2 — declared resource directories must exist from the first commit

The manifest declares resources (`Sources/VigilRender/Shaders`, `Sources/VigilUI/Resources`,
`Sources/VigilUI/Localizations`, and a `Fixtures` directory in nine test targets). A `.copy()` or
`.process()` pointing at a directory that does not exist is a **hard build error**, not a warning:

```
error: couldn't build .../Vigil_VigilUI.resources/Resources because of missing inputs:
       .../Sources/VigilUI/Resources
```

This is a trap for parallel implementation: the agent that creates `Package.swift` and the agent that
creates `Sources/VigilUI/Resources/` are different agents, and until the second one lands, *nobody
else can build the package at all* — every implementer would be blocked by an error in someone
else's unwritten directory.

**Fix / rule:** the scaffolding commit must create all twelve resource directories, each containing
a `.placeholder` file, before any other source lands. Recorded as an implementation rule so it is not
rediscovered painfully.

### 3. Both build worlds pass with the fixes — verified

```
$ swift build --product VigilPure        # Linux CI purity gate
Build of product 'VigilPure' complete! (4.33s)

$ swift build                            # full package on Linux
[41/42] Linking Vigil
Build complete! (7.64s)

$ swift test --filter 'VigilProtocolsTests|VigilRTSPTests|VigilRTPTests|\
                       VigilBitstreamTests|VigilISAPITests|VigilDiscoveryTests'
✔ Test run with 6 tests passed after 0.001 seconds.
```

The full-package build succeeding on Linux confirms the `#if os(macOS)` whole-file guard strategy
works: the macOS-only targets compile to empty modules rather than failing, and the `Vigil`
executable still links.

## What has NOT been verified, and cannot be here

Be honest about this list; it is the acceptance work that has to happen on a Mac.

| Area | Why it needs a Mac |
|---|---|
| Anything importing AppKit, SwiftUI, AVFoundation, VideoToolbox, CoreMedia, Metal, Security, Network | Frameworks absent on Linux; the `#if os(macOS)` bodies are never type-checked here |
| The Metal shaders | Need `metal`/`metallib` from Xcode |
| `Vigil.app` bundle assembly, code signing, entitlements, hardened runtime | Needs `codesign` and a Mac |
| Real hardware decode, latency and CPU numbers | Need Apple silicon and real cameras |
| The R1 zero-configuration acceptance gate (launch → live picture in 10 s) | Needs a real Hikvision camera on a real LAN |

Everything in the pure layer — RTSP message parsing, Digest authentication, SDP, RTP
depacketization, jitter buffering, H.264/H.265 bitstream parsing, avcC/hvcC construction, ISAPI XML
decoding, SADP and WS-Discovery packet codecs, CIDR maths, and the synthetic-camera test harness —
**is** verifiable here and must be green before the macOS layer is written.

## Standing rule

No specification claim about the build system is trusted until it has been executed. When a spec
prescribes a command, run it against a scaffold. This document is appended to, never rewritten.

---

## Wave 1 — first implementation, and the fourth defect

### What was verified

`VigilProtocols` gained its byte, bit, hash, text and network primitives — 13 source files and 10
test files, written by four agents working concurrently on disjoint paths.

```
$ .vigil/swift build --product VigilPure --scratch-path .build-verify
[45/46] Archiving libVigilPure.a
Build of product 'VigilPure' complete! (11.34s)
```

The purity gate holds: the whole wave compiles into `libVigilPure.a` on Linux, which means nothing
in it reached for CryptoKit, CommonCrypto, CoreMedia or any other platform framework.

### Defect 4 — two agents, one test-function name, whole target fails to compile

An agent reported "216 tests passed". Re-running the suite from the supervisor's own scratch path
immediately afterwards produced:

```
Tests/VigilProtocolsTests/Base64Tests.swift:186:12: error: invalid redeclaration of
    'decodeOrNilReportsFailureWithoutThrowing()'
error: compile command failed due to signal 4
```

Both `Base64Tests.swift` and `PercentEncodingTests.swift` declared a **free function** with that
name. swift-testing's `@Test` attaches to free functions, and free functions share one namespace per
module, so two agents writing "the same obvious test name" for two different types collide and the
entire test target stops compiling — taking every other agent's passing tests down with it. A third
agent logged `BLOCKED` on it within a minute.

The agent's report was not dishonest; it was **stale**. Its run genuinely passed, and the colliding
file landed afterwards. That is the structural hazard of parallel implementation, and the reason the
supervisor re-runs the build rather than aggregating agent self-reports.

**Fix:** renamed the percent-encoding one. **Rule, now binding:** a swift-testing function name must
be unique across its whole test target, so every test function is prefixed with the type under test
(`base64DecodeRejectsOddLength`, not `decodeRejectsOddLength`). Added to `.vigil/IMPL_RULES.md`.

**Second rule:** an agent's green test run is evidence about the tree at that instant, not about the
merged result. Every wave ends with a supervisor build and test from a clean scratch path, and only
that result is reported as the wave's status.

---

## Verification of code Linux cannot compile: three techniques, in order of what they prove

`Sources/Vigil`, `VigilUI`, `VigilRender`, `VigilVideo`, `VigilTransport` and `VigilCore` preprocess
to **nothing** on Linux. `swift build` going green over them proves the module graph and the guards,
and nothing about the code inside. Three substitutes were used, and it is worth being precise about
what each is worth, because they are not interchangeable.

**1. Shadow compilation — proves the code type-checks.** Copy the target's files into a scratch
package, strip the `#if os(macOS)` guards, stub the Apple frameworks with the signatures the author
believes are right, and compile against the *real* pure modules. This is the strongest of the three
and it found real build breaks. Its blind spot is exactly the stubs: if the believed signature is
wrong, the shadow agrees with the mistake. That is why `.vigil/STEP3.md` rule 1 requires the framework
signature quoted above every non-obvious call — the quote is what a reviewer checks the *stub*
against.

**2. Isolated-shape probes — proves the language rule, not the framework.** Where the risk is a Swift
6 concurrency rule rather than an API, the question can be extracted into a file with no frameworks in
it at all and compiled for real. Verified this way:

| Question | Answer | Probe |
|---|---|---|
| Does a non-`Sendable` closure literal formed in a `@MainActor` context inherit that isolation, so it may call a `@MainActor` method while stored in a **non-isolated** `((String) -> Void)?` property? | **Yes.** `RootView`'s `onDecodeFailure` / `onFramesDropped` wiring compiles. | `scratchpad/closureiso` — compiled *and run* under `-swift-version 6 -enable-upcoming-feature ExistentialAny`, exit 0. |
| Does `AsyncStream.Continuation.yield` report drops? | **Yes** — `.enqueued(remaining:)` / `.dropped(element)`. The author's uncertainty list said it did not, and was wrong; R-27's counting gap for the event stream is closed rather than acknowledged. | executed, `yield 4: DROPPED 0`. |
| Does `EgressGuard` classify correctly across 20 literals, and does the new resolver path behave? | **Yes**, 20/20, including `nvr.example.internal` → `.unresolvedName` and a public answer → refused. | linked against the real `VigilProtocols` and executed. |

A probe that is *run* rather than only compiled is worth more again: two of the three above corrected
a belief that a compile alone would have left standing.

**3. Reading against a quoted signature — proves nothing, and is still necessary.** For AppKit and
SwiftUI, stubbing is out of proportion to the risk. This is the residual, and `ЗАПУСК.md` says so to
the customer in plain words rather than pretending the first build is certain to succeed.

### A defect this found that neither a compiler nor a review would have

`RootView` built its `VideoTile` with `logger:` omitted and both report callbacks left at `nil`. Every
one of those parameters has a default that compiles and says nothing — `NullLogger`, `nil`, `nil` — so
a decode failure or a drop storm reached neither the screen nor the log. The code was *correct* at
every individual site and the composition was silent. Defaults that make a diagnostic disappear are
worse than no defaults, and the fix was to name all three explicitly at the call site.

---

## Prototype gate — the first green run over a still tree

Run once, over a tree no agent was writing to, after eight agents finished (five reviewers, four
implementers, one review follow-up each for render and UI).

```
== lint ==
lint: clean — 255 source files, 98 test files

== purity gate: the pure targets must build without any platform framework ==
Build of product 'VigilPure' complete! (20.74s)

== full package on Linux (macOS targets compile to empty modules) ==
Build complete! (5.95s)

== pure tests ==
✔ Test run with 1907 tests passed after 10.192 seconds.

check: PASS
```

Separately, and this is the result that had been missing all session: `swift build` with no `--product`
compiled **all 316 units, zero errors, zero warnings** — the first time the whole non-test graph has
gone green, including `VigilISAPI` and `VigilDiscovery`, whose in-flight state had kept the full build
red (`VigilCore` links both, so the app could not build without them).

Test count went 1229 → 1907 in this wave: +293 discovery, +148 ISAPI client/auth/XML, and the rest
from the endpoint half and the review fixes.

**What this does and does not prove.** It proves the pure layer — RTSP, RTP, the H.264/H.265
bitstream readers, ISAPI, SADP, WS-Discovery, the sweep planner and the merge engine — compiles and
passes its tests on a real toolchain. It proves the module graph and the `#if os(macOS)` guards for
everything else. It proves nothing about the roughly one third of the code inside those guards, which
preprocesses to nothing here and meets a compiler for the first time on the customer's Mac. That
distinction is stated in `ЗАПУСК.md` in plain words rather than left for the customer to discover.

---

## First real launch: `Bundle.module` is a `fatalError` on the app's startup path

The app compiled, signed, verified, launched — and died the instant SwiftUI evaluated the connect
form:

```
_assertionFailure(_:_:file:line:flags:)
closure #1 in variable initialization expression of static NSBundle.module
    (resource_bundle_accessor.swift:12)
closure #1 in ConnectFormView.content.getter    (ConnectFormView.swift:113)
```

**Not a missing file — a layout disagreement between two components that are each correct.** SwiftPM's
synthesised accessor looks for `Vigil_VigilUI.bundle` beside `Bundle.main.bundleURL`, which for an
`.app` is the bundle **root**. Apple's layout puts resources in `Contents/Resources/`, which is where
`build-app.sh` places them and where `codesign` requires them. Moving the bundle to the root to
satisfy the accessor would create unsealed top-level content and break signing instead, so the
accessor is what had to change.

`Bundle.vigilUI` now searches six plausible locations and falls back to `Bundle.main`. It cannot
crash. That matters more than the lookup: in this module every `LocalizedStringKey` *is* its English
text, so a missing `.strings` file costs nothing at all — the interface renders correctly with no
bundle present. Trading that for a process death is indefensible.

### The lint rule that should have caught it, and why it could not

`Scripts/lint.py` bans `fatalError` in `Sources/` precisely because every one is a crash on a machine
we cannot reproduce. This `fatalError` was **generated at build time by SwiftPM**, so it never existed
in `Sources/` for the rule to see. Worth stating plainly as a general limit: a source-text lint cannot
see synthesised code, and `Bundle.module` is the one piece of synthesised code in this project that can
terminate the process.

### Where the failures actually landed

Six defects surfaced between "compiles on Linux" and "runs on a Mac", and only two were in Swift code:

| # | Failure | Class |
|---|---|---|
| 1 | `--arch universal` needs XCBuild, absent from the Command Line Tools | build script default |
| 2 | `static let` in a generic type (`VTextField<FocusValue>`) | Swift, caught by a new lint rule |
| 3 | main-actor read inside a `@Sendable` `withLock` closure | Swift concurrency |
| 4 | empty resource bundles are unsignable | packaging |
| 5 | a managed entitlement makes the app unlaunchable, not unsignable | packaging |
| 6 | `Bundle.module`'s synthesised `fatalError` | packaging, surfaced at runtime |

Four of six were packaging and build-script defects rather than program logic — which is worth
recording, because the project's whole verification effort went into the Swift and none into the
scripts, on the assumption that a shell script is easy to get right. `Scripts/build-app.sh` still
carries the header "THIS SCRIPT HAS NEVER BEEN EXECUTED", and that line predicted the distribution of
failures better than any of the code review did.

---

## The first weeks of running the tests, not just compiling them

`macos.yml` began running `swift test --parallel` on a real macOS runner, and the first days of it
found more than the preceding weeks of review. Recorded because the distribution is the point: none
of these was visible to a compiler, and none was found by reading.

| # | Defect | How it hid |
|---|---|---|
| 7 | `#Preview`s referenced `VLibrarySample`, which did not exist | `#if DEBUG` is stripped from the release build, and Linux skips macOS files — nothing compiled it |
| 8 | `InspectorDeviceIdentity.previewIdentity` exceeded the type-checker's budget | same; and the first fix, a typed local, did not work either |
| 9 | `.finished` was yielded before the discovery sockets closed | a consumer acting on it — which is the point of the event — did so while the run still held sockets |
| 10 | a channel finishing its open after a run ended was stored, never closed | needed a cancel to land inside the factory call, so it appeared roughly once a week |
| 11 | twenty `LocalizedStringKey`s were in no `.strings` table | the key IS the English text, so it renders correctly for anyone reading in English |
| 12 | `Scripts/check-localizations.py` scanned only `Sources/VigilUI` | the app target speaks these keys too, through `vigilUIString(_:)` |

### Defect 13 — a virtual clock's sleep deadline depended on when it registered

Found by chasing the failure the section below calls "genuine load sensitivity", which turned out to
be a plain bug with an exact mechanism.

`VirtualDiscoveryClock` computed a sleeper's deadline as `current + duration` inside `register`,
which runs *after* `withCheckedThrowingContinuation` — a real suspension the pump can advance
across. The caller had already measured `duration` against the earlier reading, so anything the pump
moved in that window was added on top of the requested duration.

The arithmetic named it. Probes came out at `[50, 550, 1050]` ms against a schedule of
`[10, 510, 1010]`: one uniform 40 ms shift, and 40 ms is `cameraScript()`'s scripted answer delay.
The multicast phase asked to pause until 10 ms; the pump saw only the datagram's 40 ms sleeper,
because this one had not registered yet; it jumped to 40 ms; the sleeper then filed at 50 ms.

⚠️ It is *only* a test-double defect. A real monotonic clock does not jump, so `now()` and a
registration a moment later agree. The deadline is now captured at the top of `sleep(for:)`, before
any suspension.

It is also not airtight, and the remaining gap is stated rather than papered over: the async call
boundary between a caller's `now()` and that capture no longer contains a *guaranteed* suspension,
but is not provably free of one. Closing it needs an absolute `sleep(until:)` on the `DiscoveryClock`
protocol — production surface changed to suit a test double, which is not worth it until the
evidence says the residual window actually fires.

### What `--parallel` actually did: it made three real bugs visible

`DiscoveryCoordinatorOrchestration` and `EventMonitorService` assert against a **virtual** clock
whose pump infers quiescence from the tasks in flight. `@Suite(.serialized)` runs those tests one at
a time *within* the suite; it does nothing about `swift test --parallel` running every other suite
alongside them, so on a busy runner tasks get starved and the inference is wrong.

The tempting conclusion was "flaky tests, re-run them". It was wrong all three times:

* `.finished` before the sockets closed — a **production** bug (defect 9).
* the event-monitor gate — a **test** bug: `alertsForwarded` is incremented before the store write,
  so waiting on it and then reading the store reads a store several ingests behind.
* the probe timetable — a **test-double** bug (defect 13), and the one that looked most like noise.

So load did not *cause* any of them. It removed the slack that had been hiding all three, which is
the argument for keeping `--parallel` rather than reaching for `--num-workers 1` to quiet CI down.

⚠️ Do not make the nanosecond assertion tolerant. On a virtual clock exact *is* the correct
expectation, and every time it was loosened-by-instinct the underlying bug would have survived —
three for three. If it fires again, the residual window named in defect 13 is the first suspect, and
the fix for that is an absolute `sleep(until:)` rather than a wider tolerance.

#### 2026-08-02: it fired again — and the fix attempt failed, twice over

`sleep(until:)` exists now, and `discoveryCoordinatorSequencesPhasesOnTheSpecTimetable` failed on
Linux anyway — on a commit whose whole diff was macOS-only files, so nothing in it can have caused
this. The signature is **different from defect 13's**:

```
wsdProbes → [10 ms, 550 ms, 1010 ms]   expected [10, 510, 1010]
```

One probe adrift, on one of the two channels, by exactly the script's 40 ms answer delay — where
defect 13 shifted *every* probe on *both* channels uniformly. A uniform shift is a deadline computed
against a stale reading; a single displaced sample is not. The first and third probes landing exactly
on their deadlines proves the registration window defect 13 named is closed.

The window that is left is **after** the wake, not before the registration:

1. The pump resumes the sleeper due at 510 ms and holds `pendingWakes` so it cannot advance.
2. The woken task returns from `sleep(untilRegistered:)`, whose `defer` clears that wake at once.
3. The task then has to reach `channel.send`, which is an actor hop, and the send is what stamps
   `clock.now()`.
4. In that hop the task touches no clock. Eight quiet checks — about 2 ms of real time — are enough
   on a loaded runner, so the pump concludes quiescence and advances to the next deadline, 550 ms,
   which is the scripted SADP answer at 510 + 40. The send is then stamped 550.

⛔ The two obvious levers are both known-bad. Raising `quietChecks` is the change that was made and
reverted — it broke `discoveryCoordinatorStreamTerminationCancelsTheRun` on *both* platforms, because
the pump and `DiscoveryTestBed.run`'s settle loop are coupled through real time. Widening the
assertion buries the next real defect, three for three.

#### The settle-credit attempt, and why it was reverted

⛔ **This was tried and it failed. Do not try it again.**

Three consecutive Linux runs produced the *identical* `[10, 550, 1010]`. That was read as
determinism rather than a race, which made it look worth fixing rather than recording, and
`advanceToEarliestDeadline` was changed to mint one **settle credit** per task it woke — spent by
that task's next clock read, with the pump waiting, bounded, for the credits before advancing again.
The argument for it was that the wait is charged only while a credit is outstanding, so unlike the
reverted `quietChecks` change it costs nothing on the common path.

The very next run gave `[10, 510, 1050]`: second probe fixed, **third** probe adrift by the same
40 ms. The mechanism moved the symptom one deadline along instead of removing it, and cost the suite
8.4 s → 10.9 s. Reverted in full.

Two beliefs behind it were wrong, and both are worth writing down because they are easy to have
again:

1. **Three identical failures are not evidence of determinism.** The run immediately before them
   passed and the run after passed too. Three draws from a loaded die look like a constant if you
   only look at the three.
2. **"Close the window after the wake" is not a different *kind* of fix from "wait longer".** A
   spent credit is still an inference about whether a task has run, made from outside the task. Both
   levers are the same lever, and this pump has now moved the failure twice without removing it.

The failure is intermittent, it is in the harness rather than in production, and it does not
misreport anything a user would see. The only fix that removes the class is a custom executor that
the run is driven on, advanced when its queue is empty; Swift exposes no runnable-task signal short
of that. Until someone writes it, this test will occasionally go red on a loaded runner, and a re-run
is the correct response to *this specific assertion* — the one and only place in this document where
that sentence is true, and it is true only because two attempts have now measured the mechanism.

Splitting these suites into their own non-parallel invocation is also worse than it looks: a
`--filter` typo runs nothing at all and reports success, which is a green CI that tests nothing.

### One that was mine, and worth the warning it left behind

Fixing defect 10 the obvious way — making `register(_:)` `async` so it could `await channel.close()`
— put a suspension point between opening a multicast channel and scheduling its probes, on the exact
path defect-class above measures to the millisecond. The guarantee never needed it: the late path is
not the hot path, so the close is spawned and the ordinary path keeps its timing. The note on
`register` says so, because the `async` spelling will look tidier to the next person too.

---

## The macOS half compiles — 2026-08-04

`swift build` completed on the developer's Mac. Every target in the package, including the six that
Linux compiles to empty modules — `VigilTransport`, `VigilVideo`, `VigilRender`, `VigilCore`,
`VigilUI` and `Vigil` — was type-checked by a real compiler for the first time.

```
Building for debugging...
Build complete!
```

### What that sentence does and does not cover

- **Does:** debug configuration, the whole package, on macOS with the Command Line Tools.
- **Does not:** the previews. The build ran with `-Xswiftc -DVIGIL_NO_PREVIEWS` because the
  `PreviewsMacros` plugin ships with Xcode and not with the CLT, so every `#Preview` block in
  `VigilUI` was compiled out. Those blocks and their fixtures are still unverified.
- **Does not:** the tests. 688 of them have still never executed.
- **Does not:** release configuration, `Vigil.app` assembly, signing, or a camera.

### What it caught, by class

Nineteen errors over five rounds, and they fall into three groups worth naming because the next
drop will produce the same three.

1. **Code that moved without what it depends on** — five of them. `DeepLinkTarget`, `ColorTag` and
   `CameraID` were each used in a file that did not import the module declaring them; two more were
   a call site and a declaration that had drifted apart (`StageTimelineOverlay` gained three
   arguments its initialiser never grew, and the narrow-window rail called a `selectCamera` that
   does not exist). A transitive import makes the *name* resolve, which is why the `CameraID` case
   surfaced as "`CameraWatchPolicy` does not conform to `Equatable`" rather than as a missing type:
   a synthesised conformance needs the real declaration, not a leaked name.

2. **Expressions too large for the type checker** — two, both in `MainWindowView.body`, and the
   second only appeared after the first was fixed. The working budget is four or five modifiers per
   function, with any `@ViewBuilder` overlay whose content is more than a single property lifted
   out. Eleven modifiers with four overlays still failed. There is no diagnostic that says "you are
   close"; it compiles until it doesn't.

3. **API that was never checked against the framework** — `Button(_:bundle:)` (no such
   initialiser), `VSidebarSelection.library` (no such case), `.enableAsynchronousDecompression`
   (the importer keeps the underscore), a `static let` inside a type nested in a generic type's
   extension, `deinit` reading a `@MainActor` property, and implicit `self` one closure too deep.

`Scripts/lint.py` gained two rules from this: `preview-guard`, and an extension to `generic-static`
that follows `extension Foo` when `Foo` is generic anywhere in the tree — the rule existed and
missed the case that hit, because nothing in the extension's own file says `<Video>`.
