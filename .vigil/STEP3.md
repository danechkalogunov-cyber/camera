# Slice step 3 — the macOS layer

This is the part of the project that **cannot be compiled in this container**. There is no Xcode, no
AppKit, no VideoToolbox, no Metal, no Network.framework. `swift build` on Linux compiles every file
in these targets to nothing, because they are wrapped in `#if os(macOS)`. The guards are checked; the
code inside them is not.

Everything below exists to make that survivable.

## Rules for code no compiler will check

1. **Quote the signature.** Above any call into a C or Objective-C API, put the declaration as a
   comment, taken from the framework header as you understand it. A reviewer without a compiler can
   then check the call against the quoted signature. If you cannot state the signature confidently,
   say so in your result instead of guessing — a wrong guess costs the customer a build cycle.
2. **Write pointer plumbing out.** `CMVideoFormatDescriptionCreateFromH264ParameterSets` takes an
   array of pointers and an array of lengths. Build them explicitly with named locals and nested
   `withUnsafeBufferPointer` closures, one level per line. Compressed one-liners are where this code
   goes wrong and where a reviewer's eye slides off.
3. **Check every `OSStatus` and every `Bool` return.** Map to `VigilError` with the numeric status
   included in the message. A silently ignored `-12909` becomes "no video, no error" on the customer's
   machine, which is the worst failure mode we can ship.
4. **Prefer the boring API.** macOS 14.0 is the floor. Do not use anything introduced later, and do
   not use a convenience overload when the explicit form is clearer to review.
5. **No `try!`, no force-unwrap, no `fatalError`.** `Scripts/lint.py` enforces this and it matters
   more here than anywhere: every one of these is a crash on a customer machine we cannot reproduce.
6. **State your uncertainty in the result.** A list of "I am not certain `X` exists on macOS 14" is
   worth more than confident silence. That list becomes the review checklist.

## The six assignments

### 3.1 `VigilTransport` — TCP for the slice

Wire the pure `RTSPSessionMachine` to a real socket with `NWConnection`. Only what the slice needs:
TCP, no TLS, no UDP, no multicast. Feed received bytes into `ingest`, execute the machine's
`.send` actions as single atomic writes, drive `.setTimer` from a monotonic source, and surface
connection failures as `VigilError` rather than `NWError`.

Traps: `NWConnection` delivers on a queue, so the hop into the owning actor must be explicit and is
one of the few sanctioned uses of GCD in this project; `receive(minimumIncompleteLength:maximumLength:)`
can deliver zero bytes with `isComplete` false; a write completion handler firing after cancellation
must not resurrect a torn-down session.

### 3.2 `VigilVideo` — format descriptions and sample buffers

`CMVideoFormatDescriptionCreateFromH264ParameterSets` and its HEVC counterpart, with
`nalUnitHeaderLength: 4`. Wrap length-prefixed frame data in a `CMBlockBuffer`, build a
`CMSampleBuffer` with correct `CMSampleTimingInfo`, mark non-keyframes with
`kCMSampleAttachmentKey_NotSync`, and set `kCMSampleAttachmentKey_DisplayImmediately` for the live
path.

Traps: the parameter-set pointer arrays must outlive the call; `CMBlockBufferCreateWithMemoryBlock`
needs an explicit allocator and a block source that keeps the `Data` alive — a dangling block buffer
shows as garbled frames, not a crash; `CMSampleBufferCreateReady`'s sample-size array is *sizes*, not
offsets; attachments are set on the array returned by
`CMSampleBufferGetSampleAttachmentsArray(_:createIfNecessary: true)` and the flag is inverted from
what its name suggests.

### 3.3 `VigilRender` — the display layer

An `NSView` backed by `AVSampleBufferDisplayLayer`, wrapped for SwiftUI with
`NSViewRepresentable`. No Metal in the slice.

Traps: `wantsLayer` before `layer`; the layer must be opaque and black or the first frame flashes;
`videoGravity`; `contentsScale` has to follow `window.backingScaleFactor` across display changes;
`requiresFlushToResumeDecoding` after an interruption; and never
`flush(removingDisplayedImage: true)` — the contract's no-black-flash rule.

### 3.4 `VigilCore` — the minimum domain

A `Camera` value type, `CredentialStore` on the Keychain, and a `StreamController` actor that owns
the session and the decode pipeline for one camera, exposing an `AsyncStream` of state.

Traps: `SecItemCopyMatching` returns `errSecItemNotFound` as a normal outcome, not an error;
`kSecAttrAccessibleWhenUnlocked`; the `Credential` type is deliberately not `Codable` so it cannot
end up in JSON; auth failure is terminal and must not retry.

### 3.5 `VigilUI` — two screens

A connect form and a video view with a status line, on the `VTheme` tokens that already exist. No
sidebar, no inspector, no grid.

### 3.6 `Vigil` — the app target

`@main`, one window, wiring the above together, and the R1 flow: address plus password, then video.

## What "done" means for step 3

`swift build` on Linux still succeeds — proving the guards are right — `Scripts/lint.py` is clean,
and every agent has produced its uncertainty list. Then step 4 reviews the code adversarially against
those lists, because that review is the only compiler this layer gets before the customer's Mac.
