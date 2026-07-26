# Implementation rules — binding for every agent writing Swift in this repository

Repo: `/home/user/camera` — the Vigil macOS Hikvision viewer. Read `docs/ARCHITECTURE.md` §12 (style)
if you need more than this page.

## The toolchain, and the fact that your work is actually compiled

This container is Linux with **Swift 6.1.2** and no Xcode. Use the wrapper:

```
.vigil/swift build --product VigilPure --scratch-path .build-<yourname>
.vigil/swift test  --filter <YourTestTarget> --scratch-path .build-<yourname>
```

**Always pass `--scratch-path .build-<yourname>`** with your own agent name. Several agents build
concurrently and SwiftPM takes an exclusive lock on a shared `.build` directory; without a private
scratch path you will block or fail for reasons that have nothing to do with your code.

Your code **must compile and your tests must pass before you finish**. Do not report success on
unrun code. If something cannot compile on Linux, say so explicitly in your result.

## Layering — the rule most likely to be broken

`VigilProtocols`, `VigilBitstream`, `VigilRTSP`, `VigilRTP`, `VigilISAPI` and `VigilDiscovery` are
**pure**: they may import `Foundation` and nothing else. No `CoreMedia`, `CoreVideo`, `AppKit`,
`SwiftUI`, `Network`, `Security`, `OSLog`, `CryptoKit`, `CommonCrypto`, `Accelerate`. They must build
inside `swift build --product VigilPure` on Linux — that product is the mechanical gate.

Prefer no import at all where `Swift` suffices. `Foundation` is needed for `Data`; plain integer and
collection work does not need it.

macOS-only targets (`VigilTransport`, `VigilVideo`, `VigilRender`, `VigilCore`, `VigilUI`, `Vigil`)
wrap **the whole file** in `#if os(macOS)` … `#endif`, because `swift test` compiles every target
even when filtered.

## Style

- File header: a `//` block with the filename, the module, one sentence on what the file is for, and
  a pointer to the spec section it implements (e.g. `// Implements docs/spec-rtsp.md §5.2.`).
- 110-column lines. Four-space indent. No trailing whitespace.
- `// MARK: -` sections in files over ~80 lines.
- Doc comments (`///`) on every `public`/`package` declaration, describing behaviour and the
  meaning of arguments — not restating the name. Document what happens on malformed input.
- Access control: `package` by default for cross-module API, `public` only where the app target or a
  test genuinely needs it, `internal`/`private` otherwise. Never `open`.
- **No force-unwrap, no `try!`, no `as!`, no `fatalError`, no `print`, no `TODO`** anywhere in
  `Sources/`. Precondition failures are acceptable only for programmer error that cannot come from
  network data (e.g. an out-of-range index into a constant table), and must carry a message.
- Errors: typed throws in the pure layer (`throws(SomeError)`), and every error case carries enough
  context to be diagnosed from a log line. Never swallow an error silently.
- Swift 6 strict concurrency: every type crossing a boundary is `Sendable`. Value types by default.
  No `@unchecked Sendable` without a comment justifying it. The pure layer declares **no** actors,
  **no** `@MainActor`, and **no** `Task` — parsers and state machines are plain structs that an
  owning actor drives.
- Determinism: the pure layer never calls `Date()`, `Date.now`, `Task.sleep`, or a random generator
  directly. Time and randomness arrive as injected values so every failure reproduces from a seed.
- Performance: this code runs on the per-frame path. Avoid gratuitous `Data` copies, prefer
  `withUnsafeBytes`/slices, and do not allocate inside a per-packet loop. Comment any non-obvious
  optimisation.

## Tests

- Use **swift-testing** (`import Testing`, `@Test`, `#expect`, `#require`), not XCTest — it is in the
  toolchain and works on Linux.
- Test names describe the behaviour: `@Test func digestResponseMatchesRFC2617Example()`.
- **Test function names must be unique across the entire test target, so prefix every one with the
  type under test** — `base64DecodeRejectsOddLength`, never `decodeRejectsOddLength`. swift-testing
  attaches `@Test` to free functions, and free functions share one namespace per module: two agents
  independently choosing the same obvious name makes the whole target fail to compile and takes
  every other agent's tests down with it. This has already happened once; see
  docs/BUILD-VERIFICATION.md defect 4.
- Prefer **published test vectors** over self-generated expectations. Where a spec document lists
  vectors, use exactly those and cite them in a comment. Where you must synthesise a fixture, say so
  in the comment — never imply a fabricated value came from real hardware.
- Cover malformed and hostile input explicitly: truncated buffers, zero length, oversized length
  fields, integer overflow at boundaries, and values at the exact edge of a range. This code parses
  bytes from the network; a crash is a security bug.
- No test may depend on wall-clock time, network access, or execution order.

## Do not

- Do not modify `Package.swift`, `docs/**`, or any file outside the paths you were assigned.
- Do not delete the `Placeholder.swift` files — the supervisor removes them once a target has real
  sources.
- Do not add a dependency to `Package.swift`. The package has zero dependencies by design.
- Do not reformat or "improve" a sibling agent's file.

## Progress logging (mandatory)

```
echo "[$(date -u +%H:%M:%S)] <yourname> | <stage> | <short message>" >> /home/user/camera/.build-progress.log
```

Log `START`, then `WRITTEN` when your sources are on disk, then `BUILD` with the real build result,
then `TEST` with the real pass/fail counts, then `DONE`. If you are blocked, log `BLOCKED` with the
reason. Lines under 160 characters, no embedded newlines. Report real numbers — the supervisor
re-runs the build and will see a discrepancy.
