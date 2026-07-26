# Vigil — RTSP Client Specification (`VigilRTSP`)

Status: **normative**. This document is the sole source of truth for the `VigilRTSP` target. An
implementation agent must be able to write the module from this file alone. Every number, byte
offset, header spelling, hash value and Swift signature here is binding.

Applicable standards: RFC 2326 (RTSP 1.0), RFC 2617 (HTTP Digest), RFC 4566 (SDP),
RFC 6184 (H.264 RTP payload / fmtp), RFC 7798 (H.265 RTP payload / fmtp), RFC 3640 (AAC),
RFC 3986 (URI), ONVIF Streaming Specification v19.12 §6 (replay / `Require: onvif-replay`).
Where Hikvision deviates from a standard, the deviation is stated and the workaround is mandatory.

---

## Table of contents

| § | Title |
|---|-------|
| 1 | Scope, module boundary, dependencies |
| 2 | Core value types |
| 3 | Message grammar and serialization |
| 4 | Incremental wire decoder |
| 5 | Interleaved (`$`) framing, demux and resynchronization |
| 6 | Authentication: Basic and Digest (+ MD5 in `VigilProtocols`) |
| 7 | Transport header model and the transport fallback ladder |
| 8 | SDP parsing and control-URL resolution |
| 9 | `RTP-Info` and presentation-time seeding |
| 10 | URL model and Hikvision URL conventions |
| 11 | Method sequences with full wire dumps |
| 12 | Session lifecycle, keepalive and timers |
| 13 | Playback control: `Range`, `Scale`, `Rate-Control`, frame step |
| 14 | `RTSPSessionMachine` — complete public API |
| 15 | Error taxonomy and status-code handling |
| 16 | Server-initiated messages: `ANNOUNCE`, `REDIRECT`, `OPTIONS` |
| 17 | Constants and limits |
| 18 | Test plan, fixtures and golden vectors |
| 19 | Cross-module contract summary |

---

## 1. Scope, module boundary, dependencies

### 1.1 What `VigilRTSP` owns

1. The RTSP 1.0 message model (`RTSPRequest`, `RTSPResponse`, `RTSPHeaders`) plus a **strict
   serializer** and a **lenient incremental parser**.
2. Interleaved (`$`-framed) RTP-over-RTSP demultiplexing and resynchronization.
3. Basic and Digest authentication state (nonce, `nc`, `cnonce`, `opaque`, `stale` handling).
4. SDP parsing and **control-URL resolution** (the hardest correctness detail in the module).
5. `Transport`, `Session`, `RTP-Info`, `Range`, `Scale`, `Rate-Control`, `Public`, `Notice` header
   models.
6. `RTSPSessionMachine`: a pure, deterministic state machine driven by injected bytes, an injected
   monotonic clock and an injected randomness source. **No sockets, no timers, no threads.**
7. Hikvision URL construction and the DESCRIBE probing ladder.

### 1.2 What `VigilRTSP` does **not** own

| Concern | Owner |
|---|---|
| Sockets, TLS, real timers, `Network.framework` | `VigilTransport` (macOS-only) |
| RTP header parsing, depacketization, jitter buffer, RTCP generation | `VigilRTP` |
| `MediaTimestamp`, `EncodedFrame`, presentation clock, drift correction | `VigilRTP` (types declared in `VigilProtocols`) |
| SPS/PPS/VPS decoding, resolution/fps extraction, `avcC`/`hvcC` | `VigilBitstream` |
| MD5, Base64, `ByteReader`/`ByteWriter`, `LoggerProtocol` | `VigilProtocols` |
| Stream enumeration, channel discovery, two-way audio | `VigilISAPI` |
| Reconnect/backoff policy across sessions | `VigilCore` |

`VigilRTSP` hands `VigilRTP` raw interleaved payload bytes plus the negotiated per-track
description. It never parses an RTP header itself, with exactly one exception documented in
§5.5 (the *plausibility* check used during resynchronization, which reads only the RTP version
bits and payload type — it never interprets them as media).

### 1.3 Dependencies and platform rules

```swift
// Package.swift excerpt (authoritative version lives in ARCHITECTURE.md)
.target(name: "VigilRTSP", dependencies: ["VigilProtocols"])
.testTarget(name: "VigilRTSPTests", dependencies: ["VigilRTSP"],
            resources: [.copy("Fixtures")])
```

* **Imports allowed:** `Foundation` only (and `VigilProtocols`). No `CryptoKit`, no `Network`,
  no `CoreMedia`, no `os`.
* **Must compile and pass all tests on Linux Swift 6.1.** CI runs
  `swift test --filter VigilRTSPTests` on Linux.
* Every public type is `Sendable`. The module contains **no classes and no global mutable
  state**; `RTSPSessionMachine` is a `struct` mutated by its owner (an actor in `VigilCore`).
* No `Date`-based decisions anywhere in control flow. Wall-clock time appears only as parsed
  *data* (playback ranges). All timing uses the injected `RTSPInstant`.
* Only `Foundation` APIs available on Linux: no `NSRegularExpression`-dependent logic in hot
  paths (allowed in tests), no `String(format:)` in hot paths, no `URLComponents` for RTSP URLs
  (it mangles `trackID=1` style path segments and rejects some Hikvision query forms) — we
  implement `RTSPURL` ourselves (§10.1).

### 1.4 File layout

```
Sources/VigilRTSP/
├── Model/
│   ├── RTSPMethod.swift            RTSPMethod, RTSPStatus
│   ├── RTSPHeaders.swift           case-insensitive ordered header container
│   ├── RTSPMessage.swift           RTSPRequest, RTSPResponse, serialization
│   ├── RTSPURL.swift               URL value type + Hikvision path builders
│   └── RTSPError.swift             error taxonomy
├── Wire/
│   ├── RTSPWireDecoder.swift       incremental parser + interleaved demux + resync
│   ├── RTSPRequestBuilder.swift    canonical request emission
│   └── RTSPHeaderScanner.swift     token/quoted-string primitives
├── Auth/
│   ├── RTSPChallenge.swift         WWW-Authenticate parsing
│   └── RTSPAuthenticator.swift     Basic + Digest state machine
├── SDP/
│   ├── SDPDocument.swift           line model
│   ├── SDPParser.swift             lenient parser
│   ├── SDPMediaDescription.swift   rtpmap / fmtp / control
│   └── ControlURLResolver.swift    Content-Base precedence rules
├── Headers/
│   ├── TransportHeader.swift
│   ├── SessionHeader.swift
│   ├── RTPInfoHeader.swift
│   └── RangeHeader.swift           npt / clock / smpte + Scale + Rate-Control
└── Machine/
    ├── RTSPSessionMachine.swift    the state machine
    ├── RTSPAction.swift            outputs
    ├── RTSPCommand.swift           inputs
    ├── RTSPSessionConfig.swift
    └── RTSPTimer.swift             RTSPInstant, RTSPDuration, RTSPTimerID
```

---

## 2. Core value types

### 2.1 Methods and status

```swift
public enum RTSPMethod: String, Sendable, CaseIterable, Hashable {
    case options       = "OPTIONS"
    case describe      = "DESCRIBE"
    case setup         = "SETUP"
    case play          = "PLAY"
    case pause         = "PAUSE"
    case teardown      = "TEARDOWN"
    case getParameter  = "GET_PARAMETER"
    case setParameter  = "SET_PARAMETER"
    case announce      = "ANNOUNCE"
    case record        = "RECORD"
    case redirect      = "REDIRECT"

    /// Methods that carry a `Session` header once a session exists.
    public var requiresSession: Bool {
        switch self {
        case .play, .pause, .teardown, .getParameter, .setParameter, .record: return true
        case .options, .describe, .setup, .announce, .redirect: return false
        }
    }
    /// Methods we may send with a body.
    public var allowsRequestBody: Bool { self == .setParameter || self == .announce }
}

public struct RTSPStatus: RawRepresentable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public var isSuccess: Bool      { (200...299).contains(rawValue) }
    public var isRedirect: Bool     { rawValue == 301 || rawValue == 302 || rawValue == 303 }
    public var isClientError: Bool  { (400...499).contains(rawValue) }
    public var isServerError: Bool  { (500...599).contains(rawValue) }

    public static let ok                      = RTSPStatus(rawValue: 200)
    public static let created                 = RTSPStatus(rawValue: 201)
    public static let lowOnStorage            = RTSPStatus(rawValue: 250)
    public static let movedPermanently        = RTSPStatus(rawValue: 301)
    public static let movedTemporarily        = RTSPStatus(rawValue: 302)
    public static let badRequest              = RTSPStatus(rawValue: 400)
    public static let unauthorized            = RTSPStatus(rawValue: 401)
    public static let forbidden               = RTSPStatus(rawValue: 403)
    public static let notFound                = RTSPStatus(rawValue: 404)
    public static let methodNotAllowed        = RTSPStatus(rawValue: 405)
    public static let notAcceptable           = RTSPStatus(rawValue: 406)
    public static let requestTimeout          = RTSPStatus(rawValue: 408)
    public static let unsupportedMediaType    = RTSPStatus(rawValue: 415)
    public static let parameterNotUnderstood  = RTSPStatus(rawValue: 451)
    public static let conferenceNotFound      = RTSPStatus(rawValue: 452)
    public static let notEnoughBandwidth      = RTSPStatus(rawValue: 453)
    public static let sessionNotFound         = RTSPStatus(rawValue: 454)
    public static let methodNotValidInState   = RTSPStatus(rawValue: 455)
    public static let headerFieldNotValid     = RTSPStatus(rawValue: 456)
    public static let invalidRange            = RTSPStatus(rawValue: 457)
    public static let parameterIsReadOnly     = RTSPStatus(rawValue: 458)
    public static let aggregateNotAllowed     = RTSPStatus(rawValue: 459)
    public static let onlyAggregateAllowed    = RTSPStatus(rawValue: 460)
    public static let unsupportedTransport    = RTSPStatus(rawValue: 461)
    public static let destinationUnreachable  = RTSPStatus(rawValue: 462)
    public static let internalServerError     = RTSPStatus(rawValue: 500)
    public static let notImplemented          = RTSPStatus(rawValue: 501)
    public static let serviceUnavailable      = RTSPStatus(rawValue: 503)
    public static let rtspVersionNotSupported = RTSPStatus(rawValue: 505)
    public static let optionNotSupported      = RTSPStatus(rawValue: 551)
}
```

### 2.2 Header container

RTSP header names are case-insensitive (RFC 2326 §12); order must be preserved for byte-exact
round-tripping in tests, and duplicates are legal (`WWW-Authenticate` appears twice on some
firmware).

```swift
public struct RTSPHeaders: Sendable, Equatable, Sequence {
    public struct Field: Sendable, Equatable {
        public let name: String        // original casing as sent/received
        public var value: String       // OWS-trimmed
        public var lowercasedName: String
    }

    public private(set) var fields: [Field] = []

    public init() {}
    public init(_ pairs: [(String, String)])

    /// First value for `name`, case-insensitive. O(n), n ≤ 128.
    public func first(_ name: String) -> String?
    /// All values for `name`, in receive order.
    public func all(_ name: String) -> [String]
    /// Comma-joined values, for list-valued headers (`Public`, `Unsupported`).
    public func joined(_ name: String) -> String?
    public func has(_ name: String) -> Bool
    public func int(_ name: String) -> Int?

    public mutating func set(_ name: String, _ value: String)     // replaces all
    public mutating func append(_ name: String, _ value: String)  // adds a duplicate
    public mutating func remove(_ name: String)

    public func makeIterator() -> IndexingIterator<[Field]>
}
```

Header-name comparison uses ASCII-only lowercasing (`Character` Unicode folding is forbidden —
`İ` must not fold to `i`). Implement:

```swift
@inlinable func asciiLowercased(_ s: String) -> String {
    String(decoding: s.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }, as: UTF8.self)
}
```

### 2.3 Messages

```swift
public struct RTSPRequest: Sendable, Equatable {
    public var method: RTSPMethod
    public var uri: String            // exactly as it goes on the wire (no userinfo)
    public var headers: RTSPHeaders
    public var body: Data             // empty unless method.allowsRequestBody
    public var cseq: UInt32           // mirrored into headers on serialize
}

public struct RTSPResponse: Sendable, Equatable {
    public var status: RTSPStatus
    public var reasonPhrase: String
    public var headers: RTSPHeaders
    public var body: Data
    public var cseq: UInt32?          // nil if the server omitted CSeq (a protocol violation)
}

/// A message received from the peer: normally a response, but servers send requests too (§16).
public enum RTSPIncoming: Sendable, Equatable {
    case response(RTSPResponse)
    case request(RTSPRequest)
    case interleaved(channel: UInt8, payload: Data)
}
```

### 2.4 Time

```swift
/// Monotonic instant, nanoseconds since an arbitrary epoch. Never wall clock.
public struct RTSPInstant: Hashable, Comparable, Sendable {
    public var nanoseconds: Int64
    public init(nanoseconds: Int64)
    public static func + (lhs: RTSPInstant, rhs: RTSPDuration) -> RTSPInstant
    public static func - (lhs: RTSPInstant, rhs: RTSPInstant) -> RTSPDuration
    public static func < (lhs: RTSPInstant, rhs: RTSPInstant) -> Bool
}

public struct RTSPDuration: Hashable, Comparable, Sendable {
    public var nanoseconds: Int64
    public static func milliseconds(_ ms: Int64) -> RTSPDuration
    public static func seconds(_ s: Int64) -> RTSPDuration
    public static func seconds(_ s: Double) -> RTSPDuration
    public var milliseconds: Int64 { nanoseconds / 1_000_000 }
    public static let zero = RTSPDuration(nanoseconds: 0)
}
```

`VigilTransport` maps `RTSPInstant` from `DispatchTime.now().uptimeNanoseconds` (cast to
`Int64`). Tests use a plain counter.

### 2.5 Randomness injection

`cnonce` generation must be deterministic under test.

```swift
public protocol RTSPRandomSource: Sendable {
    /// Returns exactly `count` bytes.
    func randomBytes(_ count: Int) -> [UInt8]
}

public struct RTSPSystemRandom: RTSPRandomSource, Sendable {
    public init() {}
    public func randomBytes(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: 0...255) }
    }
}

/// xorshift64*, fully deterministic; used by every unit test.
public struct RTSPDeterministicRandom: RTSPRandomSource, Sendable {
    public init(seed: UInt64 = 0x2545_F491_4F6C_DD1D)
    public func randomBytes(_ count: Int) -> [UInt8]
}
```

---

## 3. Message grammar and serialization

### 3.1 Grammar subset we generate (strict) and accept (lenient)

```abnf
Request      = Request-Line *(message-header CRLF) CRLF [ body ]
Request-Line = Method SP Request-URI SP "RTSP/1.0" CRLF
Response     = Status-Line *(message-header CRLF) CRLF [ body ]
Status-Line  = "RTSP/1.0" SP 3DIGIT SP Reason-Phrase CRLF
message-header = field-name ":" OWS field-value
CRLF         = %x0D %x0A
OWS          = *( SP / HTAB )
```

Send side (strict, byte-exact — golden tests compare bytes):

* `CRLF` only, never bare `LF`.
* Exactly one `SP` between request-line tokens; exactly `": "` (colon + one space) after a field
  name.
* No obs-folding, no duplicate headers except where required.
* Request-URI is an absolute RTSP URI with **userinfo stripped** and the original
  percent-encoding preserved verbatim (§10.1). No trailing slash normalization.
* Body (only `SET_PARAMETER`/`ANNOUNCE`) starts immediately after the terminating `CRLF CRLF`,
  with a correct `Content-Length` and a `Content-Type`.

Receive side (lenient — tolerances are individually justified in §4.5):

| Tolerance | Reason |
|---|---|
| bare `LF` as line terminator | seen on Hikvision DVR firmware 3.1.x in `ANNOUNCE` |
| multiple `SP` / `HTAB` between status-line tokens | generic sloppiness |
| missing reason phrase (`RTSP/1.0 401`) | seen on some DS-2CD1xxx |
| obs-fold continuation lines (line starts with SP/HTAB) | folded into previous value with a single SP |
| leading `CRLF`s before a message | some firmware pads between messages |
| trailing `NUL` inside an SDP body counted in `Content-Length` | Hikvision 5.4.x; stripped before SDP parse |
| header value containing `:` | `a=control` URLs inside `Content-Base` |
| `RTSP/1.1` in a status line | treated as 1.0; we never send 1.1 |

### 3.2 Canonical request emission order

`RTSPRequestBuilder` emits headers in this fixed order. Fixed order is required so golden
fixtures are byte-stable and so `Authorization` is always computed against a finished URI.

| # | Header | Present when |
|---|---|---|
| 1 | `CSeq` | always |
| 2 | `Session` | a session id exists **and** `method.requiresSession` |
| 3 | `Authorization` | credentials known and a challenge has been seen (or preemptive, §6.7) |
| 4 | `User-Agent` | always |
| 5 | `Require` | ONVIF replay path only (`onvif-replay`) |
| 6 | `Accept` | `DESCRIBE` → `application/sdp` |
| 7 | `Transport` | `SETUP` |
| 8 | `Range` | `PLAY` when a range is requested |
| 9 | `Scale` | `PLAY` when scale ≠ 1.0 |
| 10 | `Rate-Control` | `PLAY` when rate control is disabled (`no`) |
| 11 | `Frames` | ONVIF replay intra-only (`intra` / `intra/<ms>`) |
| 12 | `x-Accept-Dynamic-Rate` | never sent (documented: we do not opt in) |
| 13 | `Content-Type` | body non-empty |
| 14 | `Content-Length` | body non-empty **or** method is `GET_PARAMETER`/`SET_PARAMETER` (then `0` is legal and we send it only when a body exists) |

`CSeq` starts at **1** and increments by 1 for every request the client sends on the
connection, including retries after `401`. A retried request gets a **new** `CSeq`; reusing a
`CSeq` breaks Hikvision's pipeline bookkeeping.

Canonical `User-Agent`: `Vigil/1.0` by default, configurable via
`RTSPSessionConfig.userAgent`. Some Hikvision firmware rejects an empty `User-Agent` with
`400`; the builder therefore refuses an empty string at `init` (`precondition` in debug,
substitutes `"Vigil"` in release).

### 3.3 Serializer

```swift
extension RTSPRequest {
    /// Byte-exact wire form. Deterministic for a given request value.
    public func serialized() -> Data
}
```

Implementation shape (no `String(format:)`, no `Data.append(contentsOf: String)` per byte):

```swift
public func serialized() -> Data {
    var out = Data(capacity: 256 + body.count)
    out.append(ascii: method.rawValue); out.append(0x20)
    out.append(ascii: uri);             out.append(0x20)
    out.append(ascii: "RTSP/1.0");      out.appendCRLF()
    for f in headers {                                  // already ordered by the builder
        out.append(ascii: f.name); out.append(ascii: ": ")
        out.append(ascii: f.value); out.appendCRLF()
    }
    out.appendCRLF()
    out.append(body)
    return out
}
```

`append(ascii:)` asserts every scalar is < 0x80. Non-ASCII in a header value (possible in a
Hikvision `realm` on Chinese firmware) is percent-free UTF-8 pass-through: we write the raw
UTF-8 bytes and log `.nonASCIIHeaderValue`. Digest hashing uses the same UTF-8 bytes (§6.4).

### 3.4 `Content-Length` rules

* **Requests we send:** present iff `body.count > 0`, value = exact byte count.
* **Responses we receive:** absent ⇒ body length 0. There is **no** "read to end of connection"
  mode — that is impossible on a multiplexed interleaved connection.
* A `200` response to `DESCRIBE` with `Content-Type: application/sdp` and **no**
  `Content-Length` is a hard error: `RTSPError.missingContentLength(cseq:)`. All Hikvision
  firmware sends it; a device that does not is unusable over interleaved TCP.
* `Content-Length` > `limits.maxBodyBytes` (256 KiB) ⇒ `RTSPError.bodyTooLarge`.
* Non-numeric or negative ⇒ `RTSPError.malformedHeader("Content-Length")`.
* Both `Content-Length` and duplicated `Content-Length` with differing values ⇒ hard error
  (request smuggling defence, even on LAN).

---

## 4. Incremental wire decoder

`RTSPWireDecoder` is the only place bytes are interpreted. It is a `struct`, fully
deterministic, and **split-invariant**: feeding the same byte stream in any chunking must
produce an identical sequence of `RTSPIncoming` values (this is a property test, §18.3).

### 4.1 Public API

```swift
public struct RTSPWireDecoder: Sendable {
    public struct Limits: Sendable {
        public var maxStartLineBytes  = 4_096
        public var maxHeaderLineBytes = 8_192
        public var maxHeaderBlockBytes = 32_768
        public var maxHeaderCount     = 128
        public var maxBodyBytes       = 262_144        // 256 KiB
        public var maxBufferedBytes   = 2_097_152      // 2 MiB high-water
        public var maxInterleavedPayload = 65_535      // protocol ceiling
        public var resyncChainDepth   = 2
        public var maxResyncScanBytes = 131_072
        public init() {}
    }

    public init(limits: Limits = .init())

    /// Channels negotiated by SETUP; used to validate `$` frames and to resynchronize.
    public mutating func registerInterleavedChannels(_ channels: Set<UInt8>)

    /// Appends bytes and drains every complete unit. Never throws for want of data.
    /// - Throws: `RTSPError` for unrecoverable framing/limit violations.
    public mutating func ingest(_ bytes: some Collection<UInt8>) throws -> [RTSPIncoming]

    /// Bytes currently buffered (for stats/assertions).
    public var bufferedByteCount: Int { get }
    public var isResynchronizing: Bool { get }
    public private(set) var statistics: DecoderStatistics
}

public struct DecoderStatistics: Sendable, Equatable {
    public var messagesDecoded = 0
    public var interleavedFramesDecoded = 0
    public var interleavedBytes: UInt64 = 0
    public var resyncEvents = 0
    public var bytesDiscardedByResync: UInt64 = 0
    public var toleratedBareLF = 0
    public var midHeaderInterleavedFrames = 0
}
```

### 4.2 Internal state

```swift
private enum Phase {
    case atBoundary                       // next unit may be $ frame or a message
    case startLine                        // accumulating the first line
    case headers(HeaderAccumulator)        // accumulating header lines
    case body(BodyPending)                 // need exactly n more bytes
    case interleavedHeader                 // have 0x24, need 3 more bytes
    case interleavedPayload(ch: UInt8, need: Int)
    case resynchronizing(scanned: Int)
    case failed(RTSPError)                 // terminal
}
```

Buffer discipline: a single `[UInt8]` ring is **not** used. Use `Data` with a `readIndex`, and
compact (`removeFirst(readIndex)`) whenever `readIndex > 8192 || readIndex > count / 2`. This
keeps amortized cost O(n) and avoids the quadratic `Data.removeFirst` pattern that dominates
naive implementations at 16 concurrent streams.

### 4.3 Decode loop

```
loop:
  switch phase
  case .failed(e):            throw e
  case .atBoundary:
      skip any leading CRLF / LF padding (max limits.maxStartLineBytes total, else error)
      if buffer empty: return collected
      if buffer[0] == 0x24:   phase = .interleavedHeader
      else:                   phase = .startLine
  case .interleavedHeader:
      if available < 4: return collected
      ch  = buffer[1]
      len = Int(buffer[2]) << 8 | Int(buffer[3])
      if !validChannel(ch): resyncStart(reason: .unknownChannel); continue
      if len == 0:          consume 4; count as empty frame; phase = .atBoundary; continue
      consume 4; phase = .interleavedPayload(ch, need: len)
  case .interleavedPayload(ch, need):
      if available < need: return collected                       // stay, no copy
      emit .interleaved(channel: ch, payload: Data(next need bytes))
      consume need; phase = .atBoundary
  case .startLine:
      find CRLF (or bare LF, §4.5) within limits.maxStartLineBytes
      if not found and available > maxStartLineBytes: throw .startLineTooLong
      if not found: return collected
      parse; phase = .headers(fresh accumulator seeded with the start line)
  case .headers(acc):
      repeat: read one line
        - empty line  -> header block complete; determine body length; phase = .body or emit
        - starts with SP/HTAB -> obs-fold into acc.last
        - starts with 0x24 at a line boundary AND looksLikeInterleavedFrame() -> §5.4
        - otherwise split at first ':' -> append field
      enforce maxHeaderLineBytes, maxHeaderBlockBytes, maxHeaderCount
  case .body(p):
      if available < p.need: return collected
      take exactly p.need bytes -> message body; emit; phase = .atBoundary
  case .resynchronizing: see §5.5
```

The loop returns as soon as it cannot make progress. It never blocks and never allocates for
incomplete units (payload copies happen once, at emit time).

### 4.4 Body length determination

```swift
func bodyLength(of headers: RTSPHeaders, status: RTSPStatus?, method: RTSPMethod?) throws -> Int {
    let values = headers.all("Content-Length")
    guard !values.isEmpty else {
        if let s = status, s.isSuccess,
           headers.first("Content-Type")?.lowercased().hasPrefix("application/sdp") == true {
            throw RTSPError.missingContentLength(cseq: headers.int("CSeq").map(UInt32.init))
        }
        return 0
    }
    guard Set(values).count == 1, let n = Int(values[0].trimmedOWS()), n >= 0 else {
        throw RTSPError.malformedHeader("Content-Length")
    }
    guard n <= limits.maxBodyBytes else { throw RTSPError.bodyTooLarge(n) }
    return n
}
```

### 4.5 Exact error cases

| Condition | Error | Recoverable? |
|---|---|---|
| Start line > 4096 B without CRLF | `.startLineTooLong` | no → reconnect |
| Single header line > 8192 B | `.headerLineTooLong` | no |
| Header block > 32768 B or > 128 fields | `.headerBlockTooLarge` | no |
| `Content-Length` > 256 KiB | `.bodyTooLarge(Int)` | no |
| Buffered bytes > 2 MiB with no progress | `.receiveBufferOverflow` | no |
| Start line is not `RTSP/1.0 <code>` and not `<METHOD> <uri> RTSP/1.0` | `.malformedStartLine(String)` | yes → resync |
| Header line with no `:` | `.malformedHeader(String)` | yes → skip the line, count it, continue (Hikvision `a=Media_header` has leaked into headers on one firmware) |
| `$` frame channel not registered | — | yes → resync (§5.5) |
| Interleaved length > 65535 | impossible (16-bit) | — |
| Resync scanned > 128 KiB | `.unrecoverableFraming` | no → reconnect |
| Status code not 3 digits | `.malformedStartLine` | yes → resync |
| Missing `CSeq` on a response | `.missingCSeq` (surfaced by the machine, not the decoder) | yes → log + ignore |

"Recoverable" means the decoder can continue on the same connection. Non-recoverable errors put
the decoder in `.failed` permanently; the machine must emit `.fail` and `VigilCore` reconnects.

### 4.6 Header-line parsing primitives

```swift
enum RTSPHeaderScanner {
    /// RFC 2326 token: 1*<any CHAR except CTLs or separators>
    static func isTokenByte(_ b: UInt8) -> Bool
    /// Parses `name = value` / `name = "value"` lists, honouring \" escapes and
    /// ignoring separators inside quoted strings. Used for Transport, WWW-Authenticate,
    /// RTP-Info, Session.
    static func parameters(_ s: Substring, separator: UInt8 = UInt8(ascii: ";"))
        -> [(name: String, value: String)]
    /// Splits a comma list at top level only (commas inside quotes are kept).
    static func topLevelSplit(_ s: Substring, on: UInt8) -> [Substring]
    static func unquote(_ s: Substring) -> String   // strips one layer of "" and \ escapes
}
```

These four functions are the shared substrate for §6, §7, §8 and §9. They must be
allocation-light (`Substring` slices, one `String` at the end) and unit-tested independently
with 30+ cases including `realm="IP Camera(52491), Building 3"` and
`uri="rtsp://h/a?b=1;c=2"`.

---

## 5. Interleaved (`$`) framing, demux and resynchronization

### 5.1 Why interleaved TCP is the default

Hikvision devices on LAN reach a camera's substream reliably over UDP, but: consumer routers and
macOS's local-network permission flow make UDP inbound fragile; multiple 1080p mainstreams
produce 1500-byte-MTU fragmentation loss under Wi-Fi; and interleaved TCP gives us **exact**
frame boundaries plus TCP backpressure, which we exploit for `Rate-Control: no` playback
(§13.4). Therefore `RTSPTransportPreference.tcpInterleaved` is the default and UDP is the
documented fallback.

### 5.2 Frame layout

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  '$' = 0x24   |    channel    |         length (big-endian)    |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        payload (length bytes)                  |
|                        one RTP or RTCP packet                  |
+---------------------------------------------------------------+
```

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 1 | magic | always `0x24` (`'$'`) |
| 1 | 1 | channel | as negotiated in `Transport: ...;interleaved=a-b` |
| 2 | 2 | length | **big-endian** `UInt16`, payload only, header excluded, max 65535 |
| 4 | length | payload | exactly one complete RTP or RTCP packet, no padding between frames |

There is no CRC, no sync word other than `0x24`, and no length redundancy. That is why §5.5
exists.

### 5.3 Channel assignment

We request, for track index `i` (0-based, in SDP `m=` order among tracks we set up):

```
RTP  channel = 2 * i
RTCP channel = 2 * i + 1
```

so video = `interleaved=0-1`, audio = `interleaved=2-3`, metadata (if enabled) = `4-5`.

**The server's response is authoritative.** Parse `interleaved=a-b` from the SETUP response and
use those numbers. Rules:

* If the response omits `interleaved` for an `RTP/AVP/TCP` transport, assume the values we
  requested and log `.assumedInterleavedChannels`.
* If two tracks are assigned an overlapping channel pair, that is
  `RTSPError.interleavedChannelCollision(track:channel:)`. Do not attempt to guess; tear down
  and retry the whole session with `RTSPTransportPreference.udpUnicast` (§7.4). This happens on
  a small number of DS-77xx firmware builds that always answer `interleaved=0-1`.
* Channels ≥ 4 are legal; channel numbers are not required to be contiguous.
* Unknown channel in a received frame ⇒ resync (§5.5), **not** a hard error: a mid-stream
  `SETUP` of a third track can race the first frames on its channel, so we re-register channels
  *before* sending the SETUP request, not after the response (see `registerInterleavedChannels`
  usage in §14.7).

### 5.4 Demuxing media frames from RTSP responses on one socket

The connection carries three kinds of unit, interleaved arbitrarily:

1. `$` frames (media),
2. responses to our requests,
3. server-originated requests (`ANNOUNCE`, `OPTIONS`, `REDIRECT`, §16).

Disambiguation rule at a **unit boundary** is unambiguous by construction: `0x24` cannot start
an RTSP start line (it is not a token character and not `R`). So:

```
next byte == 0x24  ->  interleaved frame
otherwise          ->  RTSP message
```

Mid-**body** there is no ambiguity either: bodies are consumed as an exact opaque byte count,
never scanned. **Never look for `$` inside a body.**

Mid-**header** the situation is real and must be handled: two Hikvision firmware families
(DS-7604N-K1 V4.30 and DS-2CD2385 V5.5.53) can emit a `$` frame between the header block's
first line and the remaining headers when a PLAY response races the first RTP packet.
Therefore, while in `.headers`, at a **line boundary only**, if the next byte is `0x24` we apply
`looksLikeInterleavedFrame()`:

```swift
/// Heuristic gate for accepting a `$` frame inside a header block. All conditions required.
func looksLikeInterleavedFrame(at i: Int) -> Bool {
    guard available(from: i) >= 4 else { return false }        // wait for more bytes
    let ch = buffer[i + 1]
    guard registeredChannels.contains(ch) else { return false }
    let len = Int(buffer[i + 2]) << 8 | Int(buffer[i + 3])
    guard len >= 4, len <= limits.maxInterleavedPayload else { return false }
    guard available(from: i) >= 4 + len else { return false }   // require the whole frame
    // RTP/RTCP plausibility: version bits must be 2.
    let firstPayloadByte = buffer[i + 4]
    guard (firstPayloadByte >> 6) == 2 else { return false }
    return true
}
```

If it returns true: emit the interleaved frame, increment
`statistics.midHeaderInterleavedFrames`, and **stay in `.headers` with the accumulator intact**.
If it returns false because bytes are missing, return and wait. If it returns false on the
merits, treat the line as a malformed header line (skip it) — this cannot corrupt state because
the header block is bounded.

### 5.5 Resynchronization after corruption

Corruption is observed in practice when a device reboots its media pipeline mid-stream or when a
buggy firmware writes a truncated frame. Algorithm:

```
resyncStart(reason):
    statistics.resyncEvents += 1
    phase = .resynchronizing(scanned: 0)

while scanning:
    if scanned > limits.maxResyncScanBytes: throw .unrecoverableFraming
    candidate A — interleaved chain:
        at offset i, buffer[i] == 0x24
        AND registeredChannels.contains(buffer[i+1])
        AND 4 <= len <= 65535
        AND (buffer[i+4] >> 6) == 2                      // RTP version 2
        AND the frame at i+4+len ALSO validates the same way, repeated
            `limits.resyncChainDepth` (= 2) times, or ends exactly at the buffer end
            with a partial-but-consistent frame
    candidate B — RTSP message:
        the 9 ASCII bytes "RTSP/1.0 " appear at offset i
    take the LOWEST offset i that satisfies A or B
    discard bytes [0, i), add to statistics.bytesDiscardedByResync
    phase = .atBoundary
    if not enough bytes to decide, keep the buffer and return (scanning resumes on next ingest)
```

Chain validation with depth 2 makes a false positive require two independent 4-byte coincidences
plus a valid RTP version bit; measured false-positive probability on random data is below
2⁻⁴⁰ per offset.

Policy on top of the mechanism (enforced by `RTSPSessionMachine`, not the decoder):

* More than `config.maxResyncsPerMinute` (**3**) resync events inside a 60 s sliding window ⇒
  `.fail(.excessiveFramingErrors)` and let `VigilCore` reconnect. Silent, endless resyncing is
  worse than a 400 ms reconnect.
* Every resync emits `.log(.framingResync(discarded: Int, reason: String))`.

### 5.6 Sending on interleaved channels

Only RTCP Receiver Reports are sent this way (`VigilRTP` produces the bytes; §14 exposes
`RTSPAction.sendInterleaved`). Encoding is symmetric: `0x24`, channel, big-endian length,
payload. RTCP goes on the **odd** channel of the pair.

RTSP requests and interleaved frames must never be split across a `send` boundary in a way that
interleaves them; the machine therefore emits each as one `Data` and `VigilTransport` must write
each `Data` atomically (one `NWConnection.send` per action, `contentContext: .defaultMessage`).
This is a hard cross-module requirement.

Two-way audio is **not** carried over RTSP `RECORD`; it is an ISAPI `PUT` to
`/ISAPI/System/TwoWayAudio/channels/1/audioData`. `VigilRTSP` deliberately implements no
`RECORD`/`ANNOUNCE` client role.

---

## 6. Authentication: Basic and Digest

### 6.1 What Hikvision actually sends

```
RTSP/1.0 401 Unauthorized
CSeq: 2
WWW-Authenticate: Digest realm="IP Camera(52491)", nonce="3a2f5c8e1b7d4906f2e5a8c1d4b70e93", stale="FALSE"
Date: Mon, 15 Jan 2024 09:12:33 GMT
```

Observations that drive the design:

1. **No `qop` parameter.** The overwhelming majority of Hikvision IP cameras (firmware 5.x) use
   the RFC 2069-style, no-`qop` digest. The `qop=auth` path exists on NVR firmware 4.x+ and on
   ONVIF-hardened builds. **Both must be implemented; no-`qop` is the primary path.**
2. `realm` embeds a device-specific number: `IP Camera(52491)`, `DS-7608NI-K2(24680)`,
   `Hikvision(12345)`. It contains parentheses and may contain spaces or a comma — the
   parser must be quoted-string-correct, not comma-split.
3. `stale` is sent **quoted and upper-case** (`stale="FALSE"`). RFC 2617 says it is an unquoted
   token `true`/`false`. Comparison must be: unquote, ASCII-lowercase, compare to `"true"`.
4. `algorithm` is usually absent ⇒ MD5. Some builds send `algorithm=MD5` unquoted; a few ONVIF
   builds send `algorithm="MD5"`. `MD5-sess` is accepted by our implementation but has never
   been observed from Hikvision.
5. `opaque` is usually absent. When present it must be echoed verbatim.
6. `OPTIONS` is typically answered `200` **without** authentication; `DESCRIBE` is the first
   challenged method. Do not assume the challenge arrives on the first request.
7. Some builds send both `WWW-Authenticate: Digest ...` and `WWW-Authenticate: Basic realm="..."`.
   We always pick Digest.

### 6.2 Challenge parsing

```swift
public struct RTSPChallenge: Sendable, Equatable {
    public enum Scheme: Sendable, Equatable { case basic, digest, other(String) }
    public var scheme: Scheme
    public var realm: String?
    public var nonce: String?
    public var opaque: String?
    public var algorithm: Algorithm      // .md5 default
    public var qopOptions: [String]      // parsed from qop="auth,auth-int"
    public var isStale: Bool
    public var domain: [String]

    public enum Algorithm: Sendable, Equatable { case md5, md5sess, unsupported(String) }

    /// Parses one `WWW-Authenticate` field value, which may contain MULTIPLE challenges.
    public static func parseAll(_ value: String) -> [RTSPChallenge]
}
```

Multi-challenge splitting is the subtle part: a new challenge begins at a bare token that is
**not** followed by `=` (i.e. `..., Basic realm="x"` → the token `Basic` followed by SP and
another `name=` pair). Algorithm:

```
tokens = topLevelSplit(value, on: ',')            // quote-aware
challenges = []
for t in tokens:
    t = t.trimmedOWS()
    if let sp = firstUnquotedSpace(in: t), !t[..<sp].contains("=") {
        // "Digest realm=\"x\"" — starts a new challenge
        challenges.append(Challenge(scheme: t[..<sp]))
        parseParam(t[(sp+1)...], into: &challenges.last!)
    } else if t is a lone token without '=' {
        challenges.append(Challenge(scheme: t))     // e.g. "Negotiate"
    } else {
        parseParam(t, into: &challenges.last!)      // continuation of current challenge
    }
```

Selection rule: prefer `.digest` with a `nonce` and a supported algorithm; else `.basic` **only
if** `config.allowBasicOverPlaintext == true` **or** the connection is TLS; else
`.unsupportedAuthenticationScheme`.

### 6.3 MD5 lives in `VigilProtocols`

`CryptoKit` is unavailable on Linux and external packages are forbidden, so we implement MD5
ourselves. It is ~120 lines and is used *only* for RFC 2617 compatibility — never for integrity,
storage or key derivation. This must be stated in the source header comment.

```swift
// VigilProtocols/Crypto/MD5.swift
/// RFC 1321 MD5. Present ONLY to satisfy RFC 2617 Digest authentication, which mandates it.
/// MD5 is cryptographically broken; do not use it for anything else.
public struct MD5: Sendable {
    public init()
    public mutating func update<C: Collection<UInt8>>(_ bytes: C)
    public mutating func update(_ string: String)                       // UTF-8 bytes
    public consuming func finalize() -> [UInt8]                         // 16 bytes
    public static func digest<C: Collection<UInt8>>(_ bytes: C) -> [UInt8]
    /// Lowercase 32-char hex of MD5 over the UTF-8 bytes of `string`.
    public static func hexDigest(_ string: String) -> String
    /// Lowercase hex of an arbitrary byte array.
    public static func hex(_ bytes: [UInt8]) -> String
}
```

Implementation requirements: little-endian word packing; the four rounds with the standard
`K[i] = floor(abs(sin(i+1)) * 2^32)` table **hard-coded as literals** (not computed at runtime,
so the pure layer needs no `Foundation` math); per-round shift table
`[7,12,17,22, 5,9,14,20, 4,11,16,23, 6,10,15,21]`; message padding `0x80` then zeros to
56 mod 64 then the 64-bit little-endian bit length; streaming `update` with a 64-byte block
buffer so `update` may be called with arbitrary chunk sizes.

**Mandatory RFC 1321 §A.5 test vectors** (all verified):

| Input | MD5 (lowercase hex) |
|---|---|
| `""` | `d41d8cd98f00b204e9800998ecf8427e` |
| `"a"` | `0cc175b9c0f1b6a831c399e269772661` |
| `"abc"` | `900150983cd24fb0d6963f7d28e17f72` |
| `"message digest"` | `f96b697d7cb7938d525a2f31aaf161d0` |
| `"abcdefghijklmnopqrstuvwxyz"` | `c3fcd3d76192e4007dfb496cca67e13b` |
| `"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"` | `d174ab98d277d9f5a5611c2c9f419d9f` |
| `"1234567890"` × 8 (80 bytes) | `57edf4a22be3c955ac49da2e2107b67a` |

Plus a streaming test: feed `"abcdefghijklmnopqrstuvwxyz"` in chunk sizes 1, 3, 7, 13, 25, 26
and assert the same digest each time (exercises the 64-byte block boundary).

`VigilProtocols` must also provide the lenient Base64 decoder used by §8.6:

```swift
public enum Base64 {
    /// Tolerates missing padding, embedded whitespace/CRLF, and the URL-safe alphabet.
    /// Returns nil only on an illegal character or an impossible length (len % 4 == 1).
    public static func decode(_ string: String) -> [UInt8]?
    public static func encode(_ bytes: [UInt8]) -> String   // standard alphabet, padded
}
```

`Data(base64Encoded:)` is **not** acceptable: Hikvision `sprop-parameter-sets` values are
sometimes emitted without `=` padding, which Foundation rejects, and a rejected SPS means a
black stream.

### 6.4 Digest string construction (exact)

Let `unq(X)` be the value with one layer of quoting removed. All hashing is over **UTF-8 bytes**;
all hex output is **lowercase**; there is **no** trailing newline anywhere.

```
A1  (algorithm = MD5, the normal case)
    A1 = username ":" unq(realm) ":" password
    HA1 = MD5hex(A1)

A1  (algorithm = MD5-sess)
    HA1 = MD5hex( MD5hex(username ":" unq(realm) ":" password)
                  ":" unq(nonce) ":" unq(cnonce) )
    (computed once per nonce, then reused for every nc)

A2  (qop absent or qop = "auth")
    A2 = Method ":" digest-uri
    HA2 = MD5hex(A2)

A2  (qop = "auth-int")  -- NOT IMPLEMENTED, see below
    A2 = Method ":" digest-uri ":" MD5hex(entity-body)

response (qop = "auth")
    response = MD5hex( HA1 ":" unq(nonce) ":" nc ":" unq(cnonce) ":" qop ":" HA2 )

response (no qop, RFC 2069 style)
    response = MD5hex( HA1 ":" unq(nonce) ":" HA2 )
```

Hard rules:

* **`digest-uri` MUST be byte-identical to the Request-URI on the request line.** For `SETUP`
  that is the *track control URL*, so `HA2` differs per track. For playback it includes the
  `?starttime=...&endtime=...` query. Getting this wrong yields an endless 401 loop — the single
  most common RTSP client bug against Hikvision.
* `nc` is exactly 8 lowercase hex digits, sent **unquoted**, starting at `00000001` for each new
  nonce and incrementing by 1 for every request sent with that nonce (including retries and
  keepalives).
* `cnonce` is 16 lowercase hex characters from `RTSPRandomSource.randomBytes(8)`. It is
  generated **once per nonce** and held constant while `nc` increments (RFC 2617 permits this and
  it keeps golden fixtures deterministic).
* `qop` is sent **unquoted** in `Authorization` (`qop=auth`) and is quoted in
  `WWW-Authenticate`. `username`, `realm`, `nonce`, `uri`, `response`, `cnonce`, `opaque` are
  **quoted** in `Authorization`.
* `algorithm`, when the server sent one, is echoed unquoted (`algorithm=MD5`). When the server
  sent none, we omit it.
* `auth-int` is **not implemented**: no Hikvision device offers it, and our requests that carry
  bodies (`SET_PARAMETER`) are not sent on authenticated paths that require it. If a server
  offers only `auth-int`, fail with `.unsupportedQop` rather than sending a wrong hash.

Header shape (single line, `, ` between parameters, this exact parameter order):

```
Authorization: Digest username="admin", realm="IP Camera(52491)", nonce="3a2f5c8e1b7d4906f2e5a8c1d4b70e93", uri="rtsp://192.168.1.64:554/Streaming/Channels/101", response="33439787cead5b387dab032b929cd5aa"
```

with `qop`/`nc`/`cnonce` appended (in that order) when `qop=auth` is in use, and `opaque` last
when the server sent one.

### 6.5 Golden Digest vectors

**(a) RFC 2617 §3.5 reference vector** — proves the `qop=auth` path:

| Item | Value |
|---|---|
| username / realm / password | `Mufasa` / `testrealm@host.com` / `Circle Of Life` |
| method / uri | `GET` / `/dir/index.html` |
| nonce | `dcd98b7102dd2f0e8b11d0f600bfb0c093` |
| nc / cnonce / qop | `00000001` / `0a4f113b` / `auth` |
| **HA1** | `939e7578ed9e3c518a452acee763bce9` |
| **HA2** | `39aff3a2bab6126f332b942af96d3366` |
| **response** | `6629fae49393a05397450978507c4ef1` |

**(b) Hikvision camera, no-`qop`** — `admin` / `Hik12345`, realm `IP Camera(52491)`,
nonce `3a2f5c8e1b7d4906f2e5a8c1d4b70e93`, `HA1 = b77ebbd873cb0b706fec7d517a8bd70e`:

| Method | digest-uri | HA2 | response |
|---|---|---|---|
| `OPTIONS` | `rtsp://192.168.1.64:554/Streaming/Channels/101` | `430442026acf176cb1cd78f7bdd97904` | `7a71d2670d28b6741cd8311d5c2faa39` |
| `DESCRIBE` | `rtsp://192.168.1.64:554/Streaming/Channels/101` | `b5032047f3acc3227e88a91732cc21a9` | `33439787cead5b387dab032b929cd5aa` |
| `SETUP` | `…/Streaming/Channels/101/trackID=1` | `86636168ed1619b40ab33a3e55c3439f` | `cc40451c686fe00f49dab7ead43cf51e` |
| `SETUP` | `…/Streaming/Channels/101/trackID=2` | `7d43bcddfadd3ec1c08603ef2af3adb6` | `15f95fdc9d48a6f4d84fdbb235cb8047` |
| `PLAY` | `rtsp://192.168.1.64:554/Streaming/Channels/101` | `4fb324fa81cda8c7032ca1f0844fd4e1` | `ed5735beb54441291f97015c1f94fa9e` |
| `PAUSE` | `rtsp://192.168.1.64:554/Streaming/Channels/101` | `61230d880bd8668da127109c32b7b47e` | `ec60e61d1e102f8e0db40f1572ab3c2b` |
| `GET_PARAMETER` | `rtsp://192.168.1.64:554/Streaming/Channels/101` | `110277f5940d28695bfcb9ced7472a3c` | `7784fa4d5936a634efec80eeb5700774` |
| `TEARDOWN` | `rtsp://192.168.1.64:554/Streaming/Channels/101` | `aec2fa393b8980483d7a253d0950f1c2` | `6c562c1ab1c2a7b664e7303d52167fcc` |

Re-auth after `stale`: same credentials, new nonce `9d1c7b3e5f2a48061c8e0b9a7d3f6520`,
`DESCRIBE` response = `7e59f57bd7e98d245ea2633e2b19d7b1`.

**(c) Hikvision NVR, `qop=auth`** — `admin` / `Nvr#2024`, realm `DS-7608NI-K2(24680)`,
nonce `b7c41e0a9d3f625814ae7c0b6d29f4e1`, cnonce `1c8f4a09be23d7f5`,
`HA1 = 992d115501e817da1a9b5886c47de657`, base URI
`rtsp://192.168.1.200:554/Streaming/Channels/301`:

| nc | Method | digest-uri | HA2 | response |
|---|---|---|---|---|
| `00000001` | `DESCRIBE` | base | `c8a2ad16043ed9fd8276ea879db655a3` | `7a525b747736353ecd4833fd99cbc565` |
| `00000002` | `SETUP` | base + `/trackID=1` | `f45509227068c34a973f992ba7339ff5` | `530838bed48ccf4b34d73cab7ccba0ce` |
| `00000003` | `SETUP` | base + `/trackID=2` | `43ae3e81b5dd3dd2faf75ef0e4e6f674` | `299acee76e354c38820f5d0089d9969a` |
| `00000004` | `PLAY` | base | `1ad5bca995c5819208fb45e4fe9dee04` | `3df6c275791b14ea383f1f11c5217113` |
| `00000005` | `GET_PARAMETER` | base | `1d540e54a03e0f7a00a831e68569bcb1` | `b80b79fd9f31c6761ace1b2e2df0b9cd` |
| `00000006` | `TEARDOWN` | base | `ffc8bfa4dd72d833d1a82ff79357bfdb` | `a271fd1b76b1861f447dcbd4767daa97` |

**(d) `MD5-sess` HA1** for credentials (b) with nonce (b) and cnonce `1c8f4a09be23d7f5`:
`8e02847dbbf1e8b0643c4dc284808c30`.

**(e) Basic** (only over TLS or with the opt-in flag):
`Authorization: Basic YWRtaW46SGlrMTIzNDU=` is `admin:Hik12345`;
`YWRtaW46TnZyIzIwMjQ=` is `admin:Nvr#2024`.

Every row above is a unit test in `RTSPDigestTests`. In addition, one *property* test asserts
that the no-`qop` response equals `MD5.hexDigest("\(ha1):\(nonce):\(ha2)")` for 100
pseudorandom credential/URI combinations, which pins the formula independently of the literals.

### 6.6 Authenticator API and state

```swift
public struct RTSPCredentials: Sendable, Equatable {
    public var username: String
    public var password: String
    public init(username: String, password: String)
}

public struct RTSPAuthenticator: Sendable {
    public init(credentials: RTSPCredentials?, random: any RTSPRandomSource,
                allowBasicOverPlaintext: Bool = false, isTLS: Bool = false)

    /// Feeds a 401/407 response. Returns whether a retry is worthwhile.
    public mutating func handleChallenge(_ headers: RTSPHeaders) -> ChallengeOutcome

    /// Produces the `Authorization` value for a request, or nil if we have no usable state.
    /// Increments `nc` as a side effect when qop=auth is in use.
    public mutating func authorization(method: RTSPMethod, uri: String) -> String?

    public var hasUsableState: Bool { get }
    public var realm: String? { get }
    public private(set) var challengeCount: Int
    /// Reset after a REDIRECT or reconnect: nonce state is per-connection.
    public mutating func resetNonceState()

    public enum ChallengeOutcome: Sendable, Equatable {
        case retry                     // new/changed nonce or first challenge -> retry request
        case retryWithURIFallback      // §6.8 compatibility rung
        case failed(RTSPError)         // credentials rejected or scheme unsupported
    }
}
```

### 6.7 Retry policy

```
send request without Authorization (unless we already have nonce state → preemptive, below)
  200/2xx                     -> done
  401 + challenge, first time  -> attach Authorization, resend with a NEW CSeq   (attempt 2)
  401 + challenge, nonce differs from ours (or stale=true)
                               -> adopt new nonce, reset nc to 1, regenerate cnonce,
                                  resend with a NEW CSeq                          (attempt 3)
  401 + identical nonce, stale=false, attempt ≥ 2
                               -> one URI-fallback attempt (§6.8)                 (attempt 4)
  401 again                    -> RTSPError.authenticationFailed(realm:)  [terminal]
  403                          -> RTSPError.accessForbidden  [terminal; do not retry]
```

`config.maxAuthAttemptsPerRequest = 4` (the four attempts above). Terminal auth failures must
propagate to `VigilCore` as *non-retryable* so the UI can prompt for credentials instead of
hammering the device — Hikvision locks an account after 5–7 failed attempts
(`/ISAPI/Security/illegalLoginLock`), and a reconnect loop will lock the user out of their own
camera. **This is a product-critical rule.**

**Preemptive authentication:** once a nonce is established, attach `Authorization` to *every*
subsequent request on that connection (recomputing `HA2` for the new method+URI, incrementing
`nc` when `qop=auth`). This removes one round trip per request and matches Hikvision's
expectation. Nonce state is per-TCP-connection: call `resetNonceState()` on reconnect.

### 6.8 The URI-fallback compatibility rung

A minority of firmware canonicalizes the request URI before hashing (dropping the query, or
dropping a default `:554`). If we get a second `401` carrying the *same* nonce with
`stale=false`, we retry once with `digest-uri` computed over a *normalized* URI, in this order,
one rung per retry budget slot:

1. URI without the query component.
2. URI with an explicit `:554` removed (`rtsp://host/path`).

The request line itself is **unchanged**; only the `uri=` parameter and `HA2` differ. Log
`.digestURIFallbackUsed(rung:)`. If rung 2 also fails, the error is
`.authenticationFailed(realm:)`.

---

## 7. Transport header model and the transport fallback ladder

### 7.1 Model

```swift
public struct TransportSpec: Sendable, Equatable {
    public enum Profile: Sendable, Equatable { case rtpAVP, rtpAVPTCP, other(String) }
    public enum Delivery: Sendable, Equatable { case unicast, multicast }

    public var profile: Profile
    public var delivery: Delivery
    public var interleaved: ClosedRange<UInt8>?    // TCP only
    public var clientPorts: ClosedRange<UInt16>?   // UDP request/response
    public var serverPorts: ClosedRange<UInt16>?   // UDP response
    public var destination: String?                // multicast group or unicast dest
    public var source: String?                     // server's source address
    public var ssrc: UInt32?                       // hex in the header
    public var ttl: UInt8?
    public var mode: String?                       // "PLAY" / "play" / quoted or not

    public func serialized() -> String
    public static func parse(_ value: String) -> [TransportSpec]   // comma list, first = chosen
}
```

`parse` must accept the messy real forms: `mode=PLAY`, `mode="PLAY"`, `mode="play"`,
`ssrc=48A9C1B2` (hex, no `0x`), `ssrc=48a9c1b2`, missing `unicast`, extra unknown params
(`x-transport-options`, `setup=`, `connection=`), and a comma-separated list of alternatives
(we take the first that we can honour).

### 7.2 Request forms we emit

| Mode | `Transport` value |
|---|---|
| TCP interleaved (**default**) | `RTP/AVP/TCP;unicast;interleaved=0-1` |
| UDP unicast | `RTP/AVP;unicast;client_port=51000-51001` |
| UDP multicast | `RTP/AVP;multicast` |

Notes:
* We never send `RTP/AVP/UDP` spelled out; Hikvision accepts `RTP/AVP` and some builds reject
  the explicit `/UDP`.
* We never request `destination=` (source-routing abuse vector; several servers refuse it).
* We do not send `mode=PLAY` — it is the default and one DS-7616 build rejects it.
* UDP client ports come from a per-process allocator over **51000–51998, even ports only**
  (RTP even, RTCP = RTP+1), owned by `VigilTransport`; `VigilRTSP` receives the pair as a
  parameter. Ports are held for the session's lifetime plus a 2 s lingering guard.

### 7.3 Response parsing table

| Response text | Interpretation |
|---|---|
| `RTP/AVP/TCP;unicast;interleaved=0-1;ssrc=48A9C1B2;mode="play"` | TCP, channels 0/1, SSRC known |
| `RTP/AVP/TCP;unicast;interleaved=2-3` | TCP, channels 2/3 (second track) |
| `RTP/AVP/TCP;unicast` (no `interleaved`) | assume requested channels, log |
| `RTP/AVP;unicast;client_port=51000-51001;server_port=8200-8201;ssrc=1A2B3C4D;source=192.168.1.64` | UDP; send RTCP to `source:8201`; expect RTP from `192.168.1.64:8200` |
| `RTP/AVP;multicast;destination=239.255.42.42;port=8600-8601;ttl=64` | join group, bind 8600/8601 |
| Profile differs from what we asked (e.g. we asked TCP, got `RTP/AVP`) | `RTSPError.transportMismatch` → tear down, restart with the offered mode |

### 7.4 Fallback ladder

Applied by `RTSPSessionMachine` and surfaced as `.stateChanged` + `.log`:

```
rung 1: TCP interleaved                         (config.transportPreference default)
        461 Unsupported Transport, or
        interleaved channel collision, or
        no media frames within 5 s of PLAY       -> rung 2
rung 2: UDP unicast (client_port pair)
        461, or no RTP within udpFirstPacketTimeout = 3 s after PLAY  -> rung 3
rung 3: TCP interleaved again, but with `Transport: RTP/AVP/TCP;unicast` and NO
        `interleaved` parameter (a handful of 3.x DVRs require the omission)
        failure -> .fail(.noUsableTransport)
```

The ladder is attempted **once per session**; the chosen rung is reported to `VigilCore` which
persists it per camera so the next connect starts at the known-good rung (field
`Camera.preferredTransport`). Each rung requires a full teardown + fresh TCP connection: a
device that answered `461` may leave the session in an undefined state.

### 7.5 RTSP over TLS (`rtsps`)

| Item | Decision |
|---|---|
| Scheme | `rtsps://` |
| Default port | **322** (Hikvision's RTSPS port; also the IANA `rtsps` assignment) |
| TLS version | minimum TLS 1.2, prefer 1.3 |
| Certificate | cameras ship self-signed certs. `VigilTransport` implements trust-on-first-use: pin the SHA-256 of the leaf certificate per camera in the camera record; a change produces a user-visible `certificateChanged` error, never a silent accept |
| ALPN | none |
| Framing | **identical** — interleaved `$` framing is applied on the plaintext side of TLS. `VigilRTSP` is unaware of TLS except that `isTLS = true` permits Basic auth |
| SNI | the hostname as typed by the user (IP literals ⇒ no SNI) |

`VigilRTSP` never opens sockets; it exposes `RTSPSessionConfig.isTLS` purely to gate Basic auth
and to select the default port when building URLs.

---

## 8. SDP parsing and control-URL resolution

### 8.1 Line model

SDP is a sequence of `<type>=<value>` lines. We parse leniently: unknown types are retained as
raw lines (for logging), never fatal.

```swift
public struct SDPDocument: Sendable, Equatable {
    public var version: Int                       // v=
    public var origin: String?                    // o=
    public var sessionName: String?               // s=
    public var information: String?               // i=
    public var connection: SDPConnection?         // c= (session level)
    public var bandwidthKbps: Int?                // b=AS:
    public var sessionControl: String?            // session-level a=control
    public var range: RTSPRange?                  // session-level a=range
    public var attributes: [SDPAttribute]         // all session-level a=
    public var media: [SDPMediaDescription]
    public var unknownLines: [String]
}

public struct SDPAttribute: Sendable, Equatable {
    public var name: String        // lowercased for lookup
    public var originalName: String
    public var value: String?      // nil for flag attributes (a=recvonly)
}

public struct SDPMediaDescription: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case video, audio, application, other(String) }
    public var kind: Kind
    public var port: UInt16                       // always 0 for RTSP-controlled media
    public var proto: String                      // "RTP/AVP"
    public var formats: [UInt8]                   // payload types in m= order
    public var control: String?                   // raw a=control value
    public var rtpmaps: [UInt8: SDPRTPMap]
    public var fmtps: [UInt8: String]             // raw parameter string
    public var bandwidthKbps: Int?
    public var dimensions: (width: Int, height: Int)?   // a=x-dimensions
    public var framerate: Double?                  // a=framerate / a=x-framerate
    public var direction: Direction                // recvonly / sendrecv / sendonly / inactive
    public var attributes: [SDPAttribute]
}

public struct SDPRTPMap: Sendable, Equatable {
    public var payloadType: UInt8
    public var encodingName: String                // ORIGINAL case preserved
    public var clockRate: UInt32
    public var encodingParameters: String?         // channel count for audio
}
```

### 8.2 Parser rules

| Rule | Detail |
|---|---|
| Line split | on `\r\n`, `\n` **or** `\r` (all three seen); empty lines skipped |
| Trailing garbage | strip trailing `0x00` bytes and trailing whitespace from the whole body before splitting (Hikvision 5.4.x appends a NUL counted in `Content-Length`) |
| BOM | strip a leading UTF-8 BOM |
| Encoding | decode as UTF-8; on failure fall back to ISO-8859-1 byte-mapping (never fail: a non-UTF-8 `s=` line must not kill the stream) |
| Line without `=` | added to `unknownLines`, ignored |
| `m=` starts a media section | every subsequent `a=`/`b=`/`c=` belongs to that section |
| `a=` before the first `m=` | session level |
| Attribute name | case-insensitive for lookup, original preserved |
| `a=fmtp` parameters | split on `;`, then on the **first** `=`; names lower-cased; values kept verbatim (base64 is case-sensitive!) |
| Duplicate `a=control` in a section | last one wins, log |
| Missing `a=control` in a media section | use the aggregate control URL if there is exactly one media section, else the track is unusable → `.trackMissingControl(index:)` (non-fatal: other tracks continue) |
| Zero media sections | `RTSPError.sdpNoMedia` |
| `m=` port ≠ 0 | ignored; RTSP-controlled media always uses `Transport`, never the SDP port |

**Attributes that must be ignored gracefully** (they are not errors, and they must not appear as
warnings in the UI):

| Attribute | Example | Handling |
|---|---|---|
| `a=Media_header` | `a=Media_header:MEDIAINFO=494D4B48010200000400...;` | ignore entirely. It is Hikvision's private "IMKH" media info blob (ASCII `IMKH` = `494D4B48`). Do not attempt to parse it; its layout differs across firmware and it carries nothing we need |
| `a=appversion` | `a=appversion:1.0` | ignore |
| `a=x-onvif-track` | `a=x-onvif-track:VIDEO000` | ignore (informational) |
| `a=x-qt-text-*` | QuickTime metadata | ignore |
| `a=Media_stream` / `a=Media_channel` | Hikvision extras | ignore |
| `a=recvonly` | direction flag | parsed into `direction` |
| `a=x-dimensions:1920,1080` | resolution hint | parsed — useful to size the view before the SPS arrives |
| `a=x-framerate:25` | fps hint | parsed |
| `a=control:*` | aggregate | see §8.3 |

### 8.3 Control-URL resolution — the precedence rules, exactly

This algorithm decides the URI used for `SETUP` (per track) and for `PLAY`/`PAUSE`/`TEARDOWN`
(the aggregate). Get it wrong and you get `454`/`404` on SETUP.

**Step 1 — determine the base URL** (RFC 2326 Appendix C.1.1 order, highest priority first):

1. The `Content-Base` header of the DESCRIBE response, if present and absolute.
2. The `Content-Location` header of the DESCRIBE response, if present and absolute.
   If `Content-Location` is relative, resolve it against the DESCRIBE request URI first.
3. The DESCRIBE **request URI** — after following any redirects, i.e. the URI actually used for
   the DESCRIBE that produced this SDP.

**Step 2 — normalize the base for concatenation.** If the base does not end with `/`, append
one. We deliberately do **not** use RFC 3986 relative-reference resolution here (which would
strip the last path segment, turning
`rtsp://h/Streaming/Channels/101` + `trackID=1` into `rtsp://h/Streaming/trackID=1` — a `404`).
Every mainstream RTSP client (Live555, GStreamer, VLC) uses the append rule, and Hikvision's
own `Content-Base` ends with `/` precisely because of it.

**Step 3 — determine the aggregate control URL.**

```
if session-level a=control exists:
    if it is "*"            -> aggregate = base (with the trailing slash removed if the
                               original base had none; see note)
    else if absolute        -> aggregate = that URL
    else                    -> aggregate = merge(base, value)
else                        -> aggregate = base
```

Note on the trailing slash of the aggregate: `PLAY`/`TEARDOWN` must target the URL the server
expects. Rule: **if the session `a=control` is `*` or absent, use the DESCRIBE request URI
verbatim as the aggregate** (not the slash-normalized base). Hikvision accepts both, but the
verbatim request URI is what the device logged at DESCRIBE time and is what a strict server
matches; it also keeps the digest URI consistent between DESCRIBE and PLAY.

**Step 4 — resolve each media `a=control`.**

```
resolve(control, base, aggregate) -> String
  if control == "*"                          -> aggregate
  if control contains "://"                  -> control                       (absolute)
  if control starts with "//"                -> scheme(base) + ":" + control   (protocol-relative)
  if control starts with "/"                 -> scheme://authority(base) + control
  otherwise                                  -> merge(base, control)

merge(base, control):
  b = base with query and fragment removed
  if !b.hasSuffix("/") { b += "/" }
  merged = b + control        // control has no leading "/" here
  if base had a query AND control contains no "?" { merged += "?" + baseQuery }
  return merged
```

**Query preservation is mandatory** for playback: DESCRIBE of
`rtsp://h/Streaming/tracks/301?starttime=…&endtime=…` yields `a=control:trackID=1`, and the
SETUP URI must be
`rtsp://h/Streaming/tracks/301/trackID=1?starttime=…&endtime=…`. Dropping the query makes the
NVR set up a *live* track and the playback range is silently ignored.

**Worked examples** (all observed on real devices):

| Base source | Base | `a=control` | Resolved SETUP URI |
|---|---|---|---|
| `Content-Base` | `rtsp://192.168.1.64:554/Streaming/Channels/101/` | `rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=1` | unchanged (absolute) |
| `Content-Base` | `rtsp://192.168.1.200:554/Streaming/Channels/301/` | `trackID=1` | `rtsp://192.168.1.200:554/Streaming/Channels/301/trackID=1` |
| request URI (no `Content-Base`) | `rtsp://192.168.1.64:554/h264/ch1/main/av_stream` | `trackID=1` | `rtsp://192.168.1.64:554/h264/ch1/main/av_stream/trackID=1` |
| request URI with query | `rtsp://192.168.1.200:554/Streaming/tracks/301?starttime=20240115T090000Z&endtime=20240115T093000Z` | `trackID=1` | `rtsp://192.168.1.200:554/Streaming/tracks/301/trackID=1?starttime=20240115T090000Z&endtime=20240115T093000Z` |
| `Content-Base` | `rtsp://192.168.1.64:554/` | `/Streaming/Channels/101/trackID=1` | `rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=1` |
| any | any | `*` | the aggregate URL |

**Step 5 — SETUP failure fallback.** If a SETUP with the resolved URI returns `404`, `454`,
`455` or `460`, retry that SETUP **once** with the aggregate URL (some single-track devices only
accept aggregate SETUP). If that also fails, mark the track `.unusable` and continue with the
remaining tracks; if no track survives, `.fail(.noUsableTrack)`.

### 8.4 `rtpmap` and codec identification

```
a=rtpmap:<pt> <encoding>/<clock>[/<params>]
```

Matching is **case-insensitive** on the encoding name. Canonical mapping:

| Encoding name (any case) | `RTSPCodec` | Clock rate expectation |
|---|---|---|
| `H264` | `.h264` | 90000 |
| `H265`, `HEVC` | `.h265` | 90000 |
| `MP4V-ES` | `.mpeg4Video` (unsupported for decode; track marked unusable with a clear error) | 90000 |
| `mpeg4-generic`, `MPEG4-GENERIC` | `.aac` | 8000/16000/32000/44100/48000 |
| `MPEG4-LATM` | `.aacLATM` (unsupported; documented) | — |
| `PCMU` | `.g711uLaw` | 8000 (static PT 0) |
| `PCMA` | `.g711aLaw` | 8000 (static PT 8) |
| `G726-16/24/32/40` | `.g726(bitrate:)` | 8000 |
| `vnd.onvif.metadata` | `.onvifMetadata` | 90000 |

Static payload types must work **without** an `rtpmap` line (RFC 3551): PT 0 ⇒ PCMU/8000/1,
PT 8 ⇒ PCMA/8000/1, PT 14 ⇒ MPA/90000, PT 26 ⇒ JPEG/90000, PT 33 ⇒ MP2T/90000. Hikvision
audio-only substreams sometimes omit the `rtpmap`.

If a media section lists several payload types, choose the first one we support; record the rest
in `SDPMediaDescription.formats` so a mid-stream payload-type change can be detected by
`VigilRTP`.

### 8.5 `fmtp` parsing

The raw parameter string is split on `;`, trimmed, then on the first `=`. Names are
lower-cased; **values are not** (base64 is case-sensitive). Recognized keys:

| Codec | Key | Meaning / use |
|---|---|---|
| H.264 | `packetization-mode` | 0 = single NAL, 1 = non-interleaved (all Hikvision), 2 = interleaved (we reject with `.unsupportedPacketizationMode(2)`) |
| H.264 | `profile-level-id` | 6 hex digits, e.g. `640028` = High profile, level 4.0. Informational; SPS is authoritative |
| H.264 | `sprop-parameter-sets` | comma-separated base64 NAL units, typically `SPS,PPS` |
| H.265 | `profile-id`, `tier-flag`, `level-id`, `profile-space`, `interop-constraints` | informational |
| H.265 | `sprop-vps`, `sprop-sps`, `sprop-pps` | each a base64 NAL (may itself be a comma-separated list) |
| H.265 | `sprop-max-don-diff` | > 0 enables DONL parsing in `VigilRTP` — **must be forwarded** |
| H.265 | `tx-mode` | `SRST` expected; `MRST`/`MRMT` unsupported |
| AAC | `mode` | `AAC-hbr` expected (case-insensitive) |
| AAC | `config` | hex AudioSpecificConfig, e.g. `1408`, `1210` |
| AAC | `sizelength`, `indexlength`, `indexdeltalength` | AU-header field widths (13/3/3) |
| AAC | `streamtype`, `profile-level-id`, `objecttype` | informational |
| any | unknown keys | retained in `RTSPTrack.fmtpParameters` and logged at debug |

### 8.6 Parameter-set extraction

```swift
public struct ParameterSets: Sendable, Equatable {
    public var vps: [[UInt8]] = []     // H.265 only
    public var sps: [[UInt8]] = []
    public var pps: [[UInt8]] = []
    public var sei: [[UInt8]] = []     // rarely present; forwarded
}
```

Extraction rules:

* H.264: `sprop-parameter-sets=<b64>,<b64>[,...]`. Split on `,` **before** base64 decoding.
  Classify each decoded NAL by `nal[0] & 0x1F`: 7 ⇒ SPS, 8 ⇒ PPS, 6 ⇒ SEI, 5/1 ⇒ ignore
  (a firmware bug), anything else ⇒ ignore with a log.
* H.265: `sprop-vps`, `sprop-sps`, `sprop-pps`, each possibly a comma list. Classify by
  `(nal[0] >> 1) & 0x3F`: 32 ⇒ VPS, 33 ⇒ SPS, 34 ⇒ PPS.
* Decoding uses `VigilProtocols.Base64.decode` (padding-tolerant). A value that fails to decode
  is skipped with `.log(.malformedParameterSet)`; the stream still starts because Hikvision
  repeats parameter sets in-band before every IDR.
* Empty parameter sets are **not** an error. In-band SPS/PPS is the norm for Hikvision
  (`Streaming/Channels` sends SPS+PPS+IDR every GOP). `VigilVideo` must be able to start from
  in-band sets alone.
* Parameter sets are stored as raw NAL bytes **without** a start code and **without** a length
  prefix. `VigilBitstream` adds whatever framing it needs.

### 8.7 `a=range` and `a=framerate`

```
a=range:npt=now-                     live
a=range:npt=0-                       live (some builds)
a=range:clock=20240115T090000Z-20240115T093000Z    recorded, absolute
a=framerate:25.0
a=x-framerate:25
```

`RTSPRange` model:

```swift
public enum RTSPRange: Sendable, Equatable {
    case npt(start: NPTTime, end: NPTTime?)
    case clock(start: Date, end: Date?)
    case smpte(start: String, end: String?)      // parsed but unused
    public enum NPTTime: Sendable, Equatable { case now, seconds(Double) }

    public func serialized() -> String            // for the Range request header
    public static func parse(_ s: String) -> RTSPRange?
}
```

Clock format is ISO 8601 **basic** with a mandatory `Z`: `YYYYMMDD"T"HHMMSS["."frac]"Z"`.
Parse and format it by hand (no `DateFormatter` — it is slow, locale-sensitive and its Linux
behaviour differs):

```swift
enum RTSPClockTime {
    /// "20240115T090000Z" or "20240115T090000.500Z" -> Date. Strict; nil on any deviation.
    static func parse(_ s: some StringProtocol) -> Date?
    /// Always 16 chars + optional ".mmm": "20240115T090000Z"
    static func format(_ date: Date, fractionalSeconds: Bool = false) -> String
}
```

Implement with explicit civil-date arithmetic (days-from-civil algorithm) so it is
timezone-free and identical on Linux and macOS. Unit-test against these pairs:

| String | Unix epoch seconds |
|---|---|
| `19700101T000000Z` | 0 |
| `20240115T090000Z` | 1705309200 |
| `20240229T235959Z` | 1709251199 |
| `20991231T235959Z` | 4102444799 |

### 8.8 Complete real SDP — DS-2CD2043G2-I camera, main stream (H.264 + AAC)

```
v=0
o=- 1109162014219182 1109162014219182 IN IP4 192.168.1.64
s=Media Presentation
e=NONE
b=AS:5100
t=0 0
a=control:rtsp://192.168.1.64:554/Streaming/Channels/101/
a=range:npt=now-
a=appversion:1.0
m=video 0 RTP/AVP 96
c=IN IP4 0.0.0.0
b=AS:5000
a=recvonly
a=x-dimensions:1920,1080
a=control:rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=1
a=rtpmap:96 H264/90000
a=fmtp:96 profile-level-id=640028; packetization-mode=1; sprop-parameter-sets=Z2QAKKzZQHgCJ+WEAAADAAQAAAMAwjxgySA=,aO48sA==
a=Media_header:MEDIAINFO=494D4B48010200000400000100000000000000000000000000000000000000000000000000000000;
a=appversion:1.0
m=audio 0 RTP/AVP 104
c=IN IP4 0.0.0.0
b=AS:50
a=recvonly
a=control:rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=2
a=rtpmap:104 mpeg4-generic/16000/1
a=fmtp:104 streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3;config=1408
a=Media_header:MEDIAINFO=494D4B48020200000000000000000000000000000000000000000000000000000000000000000000;
a=appversion:1.0
```

Decoded parameter sets from that `fmtp`:

| NAL | Base64 | Hex |
|---|---|---|
| SPS (26 B) | `Z2QAKKzZQHgCJ+WEAAADAAQAAAMAwjxgySA=` | `67640028ACD940780227E584000003000400000300C23C60C920` |
| PPS (4 B) | `aO48sA==` | `68EE3CB0` |

Substream (`/Streaming/Channels/102`, 704×576) parameter sets used by fixtures:
SPS `Z00AHp2oXBPy4CIAAAMAIAAABlHixdQ=` (`674D001E9DA85C13F2E022000003002000000651E2C5D4`),
PPS `aO48gA==` (`68EE3C80`).

### 8.9 Complete real SDP — DS-7608NI-K2 NVR, channel 3 main stream (H.265 + G.711)

Note the **relative** `a=control` values and the session-level `a=control:*` — this is the case
that exercises §8.3 step 2/4.

```
v=0
o=- 1109162014219182 1109162014219182 IN IP4 192.168.1.200
s=Media Presentation
e=NONE
b=AS:5100
t=0 0
a=control:*
a=range:npt=now-
m=video 0 RTP/AVP 98
c=IN IP4 0.0.0.0
b=AS:5000
a=recvonly
a=x-dimensions:1920,1080
a=control:trackID=1
a=rtpmap:98 H265/90000
a=fmtp:98 profile-space=0;profile-id=1;tier-flag=0;level-id=120;interop-constraints=000000000000;sprop-vps=QAEMAf//AWAAAAMAsAAAAwAAAwBdlZgJ;sprop-sps=QgEBAWAAAAMAsAAAAwAAAwBdoAKAgC0WWVmkkyuAQEAAAAMAQAAAB4I=;sprop-pps=RAHBcrRiQA==
a=Media_header:MEDIAINFO=494D4B48010200000400000100000000000000000000000000000000000000000000000000000000;
a=appversion:1.0
m=audio 0 RTP/AVP 8
c=IN IP4 0.0.0.0
b=AS:64
a=recvonly
a=control:trackID=2
a=rtpmap:8 PCMA/8000
a=Media_header:MEDIAINFO=494D4B48020200000000000000000000000000000000000000000000000000000000000000000000;
a=appversion:1.0
```

Decoded H.265 parameter sets:

| NAL | Base64 | Hex |
|---|---|---|
| VPS (24 B) | `QAEMAf//AWAAAAMAsAAAAwAAAwBdlZgJ` | `40010C01FFFF016000000300B0000003000003005D959809` |
| SPS (41 B) | `QgEBAWAAAAMAsAAAAwAAAwBdoAKAgC0WWVmkkyuAQEAAAAMAQAAAB4I=` | `420101016000000300B0000003000003005DA00280802D165959A4932B804040000003004000000782` |
| PPS (7 B) | `RAHBcrRiQA==` | `4401C172B46240` |

Resolved URIs for this SDP (base = `Content-Base: rtsp://192.168.1.200:554/Streaming/Channels/301/`):

* aggregate (session control `*`) → `rtsp://192.168.1.200:554/Streaming/Channels/301`
  (the verbatim DESCRIBE request URI, per §8.3 step 3)
* video → `rtsp://192.168.1.200:554/Streaming/Channels/301/trackID=1`
* audio → `rtsp://192.168.1.200:554/Streaming/Channels/301/trackID=2`

### 8.10 Track output type

```swift
public struct RTSPTrack: Sendable, Equatable, Identifiable {
    public var id: Int                     // SDP media index, stable
    public var kind: SDPMediaDescription.Kind
    public var codec: RTSPCodec
    public var payloadType: UInt8
    public var clockRate: UInt32
    public var channelCount: Int?          // audio
    public var controlURI: String          // fully resolved, ready for SETUP
    public var parameterSets: ParameterSets
    public var fmtpParameters: [String: String]
    public var packetizationMode: Int?     // H.264
    public var spropMaxDONDiff: Int        // H.265, default 0
    public var aacConfig: [UInt8]?         // decoded from config=
    public var aacSizeLength: Int?         // default 13
    public var aacIndexLength: Int?        // default 3
    public var aacIndexDeltaLength: Int?   // default 3
    public var hintedDimensions: (width: Int, height: Int)?
    public var hintedFramerate: Double?
    public var bandwidthKbps: Int?
    public var interleavedChannels: ClosedRange<UInt8>?   // filled after SETUP
    public var udpPorts: (client: ClosedRange<UInt16>, server: ClosedRange<UInt16>)?
    public var ssrc: UInt32?
}
```

`RTSPTrack` is what crosses into `VigilRTP`/`VigilVideo`. It contains **no** CoreMedia types, no
`Data` (byte arrays only), and is fully `Sendable`.

---

## 9. `RTP-Info` and presentation-time seeding

### 9.1 Grammar and parsing

```
RTP-Info: url=<uri>;seq=<n>;rtptime=<n>[;ssrc=<hex>] [, url=...;seq=...;rtptime=...]
```

Parsing rules:

1. Split the field value on **top-level commas** (quote-aware; a URI may legally contain a
   comma, and `topLevelSplit` also refuses to split inside `<>` if present).
2Within each entry, split on `;`, then on the first `=`. Parameter names are
   case-insensitive; `url` may be quoted (`url="rtsp://…"` — seen on ONVIF builds).
3. Match the entry to a track by comparing `url` to the track's control URI using
   `RTSPURL.equivalent(_:_:)` (§10.1): case-insensitive scheme/host, default-port aware,
   query-insensitive **fall-back** comparison if the exact comparison fails, and finally a
   suffix match on the last path segment (`trackID=1`) — Hikvision sometimes returns a relative
   `url=trackID=1`.
4. `seq` is `UInt16` (values > 65535 ⇒ malformed → ignore the entry, log).
5. `rtptime` is `UInt32` (parse as `UInt64` then truncate; values above 2³² appear on one
   firmware and truncation is the correct recovery).
6. A missing `RTP-Info` header is **legal and common** on Hikvision live streams. It is not an
   error.

```swift
public struct RTPInfoEntry: Sendable, Equatable {
    public var url: String
    public var seq: UInt16?
    public var rtptime: UInt32?
    public var ssrc: UInt32?
}
public enum RTPInfoHeader {
    public static func parse(_ value: String) -> [RTPInfoEntry]
}
```

Example (real, from the camera in §11.1):

```
RTP-Info: url=rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=1;seq=52937;rtptime=2599730432,url=rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=2;seq=19104;rtptime=1173920256
```

### 9.2 Seeding presentation time

`VigilRTSP` does **not** compute media timestamps. It emits, per track, immediately after a
successful `PLAY`:

```swift
public struct RTSPTrackTiming: Sendable, Equatable {
    public var trackID: Int
    public var clockRate: UInt32          // from rtpmap, e.g. 90000
    public var initialSequence: UInt16?   // from RTP-Info seq, nil if absent
    public var initialRTPTimestamp: UInt32?   // from RTP-Info rtptime, nil if absent
    /// Absolute media time of `initialRTPTimestamp`, for recorded playback only.
    /// Derived from the PLAY response `Range: clock=` (preferred) or the requested range.
    public var absoluteStart: Date?
    public var scale: Double              // echoed PLAY Scale, 1.0 for live
    public var isRateControlDisabled: Bool
    /// Monotonic instant at which the PLAY response was processed — the anchor for
    /// glass-to-glass latency measurement.
    public var playResponseInstant: RTSPInstant
}
```

Rules the consumer (`VigilRTP`) must apply, stated here because the seeding contract lives with
the header parser:

* If `initialRTPTimestamp` is present, the first AU's presentation offset is
  `(rtp − initialRTPTimestamp)` interpreted as a **signed 32-bit wrap-safe difference**, divided
  by `clockRate`. Packets may legitimately arrive with `rtp < initialRTPTimestamp` (B-frame-free
  Hikvision streams do not, but NVR playback does after a seek).
* If `initialRTPTimestamp` is absent, the first received packet's timestamp becomes the origin.
  Never wait for `RTP-Info`.
* Cross-track synchronization uses **RTCP SR NTP↔RTP mapping**, not `RTP-Info`: `rtptime`
  values of two tracks are unrelated (different random offsets) and must never be compared
  directly. For live viewing before the first SR arrives, each track is played on its own
  timeline with the video track as the master — audio is muted for at most 1 s until the first
  SR pair is available, then locked. `VigilRTP` owns this; `VigilRTSP` only guarantees that
  `clockRate` and the raw seeds are delivered before the first media packet is emitted
  (ordering guarantee, §14.6).
* For recorded playback, `absoluteStart` lets the UI show the true wall-clock time of the
  currently displayed frame: `wallClock = absoluteStart + (pts − ptsOfFirstFrame)`.

---

## 10. URL model and Hikvision URL conventions

### 10.1 `RTSPURL`

`URL`/`URLComponents` are unusable here: they percent-escape `=` in path segments
inconsistently across platforms, and `URLComponents` rejects `rtsp://h/a?b=1;c=2`. We implement
a minimal, lossless value type.

```swift
public struct RTSPURL: Sendable, Equatable, Hashable, CustomStringConvertible {
    public var scheme: String            // "rtsp" | "rtsps", lowercased
    public var username: String?         // percent-decoded
    public var password: String?         // percent-decoded
    public var host: String              // literal IPv4/IPv6/hostname, brackets stripped for IPv6
    public var explicitPort: UInt16?
    public var path: String              // starts with "/", percent-encoding PRESERVED verbatim
    public var query: String?            // without "?", verbatim
    public var isIPv6Literal: Bool

    public var port: UInt16 { explicitPort ?? (scheme == "rtsps" ? 322 : 554) }

    /// Parses leniently. Accepts a missing scheme (assumes rtsp://) and a missing path (⇒ "/").
    public init?(string: String)

    /// The wire form for a request line: NO userinfo, port omitted iff it equals the default.
    public var requestLineForm: String { get }
    /// Same but with the port always explicit (used by the digest URI fallback rung 2 inverse).
    public var absoluteFormWithPort: String { get }
    /// Appends a path component, inserting exactly one "/" and preserving the query (§8.3).
    public func appendingControl(_ control: String) -> RTSPURL
    /// Loose equivalence used to match RTP-Info urls to tracks.
    public static func equivalent(_ a: String, _ b: String) -> Bool
    public var description: String { requestLineForm }   // never leaks the password
}
```

Rules:

* **Credentials never appear on the wire.** `rtsp://admin:Hik12345@192.168.1.64/…` is parsed,
  the userinfo is moved into `RTSPCredentials`, and `requestLineForm` omits it. This is both a
  security requirement (RTSP is plaintext; the userinfo would also land in device logs) and a
  compatibility one (some firmware 400s on userinfo in the request line).
* Passwords are percent-decoded on parse (`%40` → `@`) and percent-encoded when a URL is
  rebuilt for display. Hikvision passwords commonly contain `@`, `#`, `/`, `:`.
* `description`/`CustomStringConvertible` and every log path must use `requestLineForm`, so a
  password can never be written to a log. Add a `Sendable` wrapper `RedactedURL` if a full URL
  with credentials must be stored.
* IPv6: `rtsp://[fe80::1%25en0]:554/…` — brackets stripped into `host`, zone id kept.
  `requestLineForm` re-adds brackets.
* The port is omitted from `requestLineForm` when it equals the scheme default, because
  Hikvision's digest implementation on some builds hashes the URI it *parsed*, and a redundant
  `:554` is the most common cause of a digest mismatch. (The `:554` variant is rung 2 of §6.8.)

### 10.2 Hikvision URL conventions

`ch` = channel number (1-based; for an NVR, the camera input index: D1 → 1), `stream` = 1 main,
2 sub, 3 third.

| URL path | Device / firmware generation | Channel–stream encoding | Notes |
|---|---|---|---|
| `/Streaming/Channels/101` | **Canonical.** All ISAPI cameras and NVRs, firmware ≥ 5.1.0 (DS-2CD2xxx, DS-2CD5xxx, DS-2DExxx) and NVR ≥ 3.0 | `ch*100 + stream`, decimal, no padding | Try this first. `101` = ch1 main, `102` = ch1 sub, `103` = ch1 third |
| `/Streaming/Channels/301` | NVR DS-76xx/77xx/96xx (the `{ch}0{stream}` form) | same arithmetic: ch3 main = `301`, ch3 sub = `302`, ch12 main = `1201` | Identical arithmetic — the `{ch}0{stream}` notation only holds for `stream < 10`, which is always true. Use `ch*100 + stream` |
| `/Streaming/Channels/1` | Transitional 5.0.x IPC | plain channel, main stream implied | Some builds require a trailing `/`. Tolerate, never generate |
| `/Streaming/tracks/101` | ISAPI ≥ 5.2 cameras, all NVRs | `ch*100 + track`, track 1 = video(+audio) composite, 2 = sub | **Required for playback** (`?starttime=`). Also works for live on NVRs |
| `/h264/ch1/main/av_stream` | Legacy 4.x DVR/DVS and old IPC (DS-2CD8xx, DS-72xx, DS-81xx) | codec + `ch{n}` + `main`/`sub` in the path | Codec segment must match the actual encoder; `/h264/` on an H.265 channel returns `415` |
| `/mpeg4/ch1/sub/av_stream` | Legacy MPEG-4 encoders | as above | Decode unsupported by us; DESCRIBE succeeds, track is marked unusable with a clear message |
| `/h265/ch1/main/av_stream` | Some 2017-era H.265 DVRs | as above | rare |
| `/PSIA/Streaming/channels/101` | PSIA-era 4.x | `ch*100 + stream` | Alias; accepted, never generated |
| `/ISAPI/Streaming/channels/101` | A few 5.4 NVR builds accept this alias | same | Never generated |
| `/Streaming/Channels/101?transportmode=unicast` | ONVIF-profile builds | — | The query is optional; add `&profile=Profile_1` only when a profile token came from ONVIF discovery |
| `/Streaming/tracks/101?starttime=20240101T000000Z&endtime=20240101T010000Z` | Playback, ISAPI ≥ 5.2 and all NVRs | — | Times are UTC, ISO 8601 **basic**, mandatory `Z`. `endtime` may be omitted to play to the end of the recording |

Builders (pure functions, unit-tested):

```swift
public enum HikvisionURL {
    public enum Stream: Int, Sendable { case main = 1, sub = 2, third = 3 }

    /// rtsp://host:port/Streaming/Channels/{channel*100 + stream}
    public static func liveISAPI(host: String, port: UInt16 = 554, scheme: String = "rtsp",
                                channel: Int, stream: Stream) -> RTSPURL
    /// rtsp://host:port/Streaming/tracks/{channel*100 + track}
    public static func track(host: String, port: UInt16 = 554, channel: Int, track: Int) -> RTSPURL
    /// rtsp://host:port/Streaming/tracks/{…}?starttime=…&endtime=…
    public static func playback(host: String, port: UInt16 = 554, channel: Int, track: Int = 1,
                                start: Date, end: Date?) -> RTSPURL
    /// rtsp://host:port/{codec}/ch{channel}/{main|sub}/av_stream
    public static func legacy(host: String, port: UInt16 = 554, channel: Int,
                              stream: Stream, codec: String = "h264") -> RTSPURL

    /// Ordered DESCRIBE probe ladder for an unknown device.
    public static func probeLadder(host: String, port: UInt16, channel: Int,
                                   stream: Stream) -> [RTSPURL]
}
```

`probeLadder` order (stop at the first DESCRIBE that returns `200`; a `401` counts as "this URL
exists" and authentication proceeds normally):

1. `/Streaming/Channels/{ch*100+stream}`
2. `/Streaming/tracks/{ch*100+stream}`
3. `/h264/ch{ch}/{main|sub}/av_stream`
4. `/PSIA/Streaming/channels/{ch*100+stream}`

Only `404`, `451`, `455` and `460` advance the ladder. `401` never advances it; `503` never
advances it (it means "too many streams", §15). Probing is a **fallback**: when `VigilISAPI` has
enumerated the device, the URL is known and the ladder is skipped.

---

## 11. Method sequences with full wire dumps

Legend: `C→S` client to server, `S→C` server to client. **Every line ends with CRLF**; a blank
line is a bare CRLF. Interleaved data is shown as a hex summary in `«…»`.

### 11.1 DS-2CD2043G2-I camera, firmware V5.7.3, TCP interleaved, no-`qop` Digest

```
(1) C→S
OPTIONS rtsp://192.168.1.64:554/Streaming/Channels/101 RTSP/1.0
CSeq: 1
User-Agent: Vigil/1.0

(2) S→C
RTSP/1.0 200 OK
CSeq: 1
Public: OPTIONS, DESCRIBE, PLAY, PAUSE, SETUP, TEARDOWN, SET_PARAMETER, GET_PARAMETER
Date: Mon, 15 Jan 2024 09:12:33 GMT

(3) C→S
DESCRIBE rtsp://192.168.1.64:554/Streaming/Channels/101 RTSP/1.0
CSeq: 2
User-Agent: Vigil/1.0
Accept: application/sdp

(4) S→C
RTSP/1.0 401 Unauthorized
CSeq: 2
WWW-Authenticate: Digest realm="IP Camera(52491)", nonce="3a2f5c8e1b7d4906f2e5a8c1d4b70e93", stale="FALSE"
Date: Mon, 15 Jan 2024 09:12:33 GMT

(5) C→S   [new CSeq, Authorization added; response from §6.5(b) DESCRIBE row]
DESCRIBE rtsp://192.168.1.64:554/Streaming/Channels/101 RTSP/1.0
CSeq: 3
Authorization: Digest username="admin", realm="IP Camera(52491)", nonce="3a2f5c8e1b7d4906f2e5a8c1d4b70e93", uri="rtsp://192.168.1.64:554/Streaming/Channels/101", response="33439787cead5b387dab032b929cd5aa"
User-Agent: Vigil/1.0
Accept: application/sdp

(6) S→C
RTSP/1.0 200 OK
CSeq: 3
Content-Type: application/sdp
Content-Base: rtsp://192.168.1.64:554/Streaming/Channels/101/
Content-Length: 712

<the SDP of §8.8>

(7) C→S   [track 1, video; digest URI is the TRACK url]
SETUP rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=1 RTSP/1.0
CSeq: 4
Authorization: Digest username="admin", realm="IP Camera(52491)", nonce="3a2f5c8e1b7d4906f2e5a8c1d4b70e93", uri="rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=1", response="cc40451c686fe00f49dab7ead43cf51e"
User-Agent: Vigil/1.0
Transport: RTP/AVP/TCP;unicast;interleaved=0-1

(8) S→C
RTSP/1.0 200 OK
CSeq: 4
Session: 1885573958;timeout=60
Transport: RTP/AVP/TCP;unicast;interleaved=0-1;ssrc=48a9c1b2;mode="play"
Date: Mon, 15 Jan 2024 09:12:33 GMT

(9) C→S   [track 2, audio; Session now present]
SETUP rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=2 RTSP/1.0
CSeq: 5
Session: 1885573958
Authorization: Digest username="admin", realm="IP Camera(52491)", nonce="3a2f5c8e1b7d4906f2e5a8c1d4b70e93", uri="rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=2", response="15f95fdc9d48a6f4d84fdbb235cb8047"
User-Agent: Vigil/1.0
Transport: RTP/AVP/TCP;unicast;interleaved=2-3

(10) S→C
RTSP/1.0 200 OK
CSeq: 5
Session: 1885573958;timeout=60
Transport: RTP/AVP/TCP;unicast;interleaved=2-3;ssrc=7c31e05a;mode="play"

(11) C→S   [aggregate URI = the DESCRIBE request URI]
PLAY rtsp://192.168.1.64:554/Streaming/Channels/101 RTSP/1.0
CSeq: 6
Session: 1885573958
Authorization: Digest username="admin", realm="IP Camera(52491)", nonce="3a2f5c8e1b7d4906f2e5a8c1d4b70e93", uri="rtsp://192.168.1.64:554/Streaming/Channels/101", response="ed5735beb54441291f97015c1f94fa9e"
User-Agent: Vigil/1.0
Range: npt=0.000-

(12) S→C
RTSP/1.0 200 OK
CSeq: 6
Session: 1885573958
RTP-Info: url=rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=1;seq=52937;rtptime=2599730432,url=rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=2;seq=19104;rtptime=1173920256
Range: npt=0.000-
Date: Mon, 15 Jan 2024 09:12:33 GMT

(13) S→C  interleaved media begins on the same socket, immediately after (12)
«24 00 05 A0» «80 60 CE C9 9A F1 22 C0 48 A9 C1 B2 …»     ch0, 1440 B, RTP video (FU-A)
«24 00 05 A0» «80 60 CE CA 9A F1 22 C0 48 A9 C1 B2 …»     ch0, 1440 B
«24 01 00 34» «81 C8 00 0C 48 A9 C1 B2 …»                 ch1, 52 B, RTCP SR
«24 02 00 A4» «80 E8 4A A0 45 F5 3B 00 7C 31 E0 5A …»      ch2, 164 B, RTP audio (AAC)

(14) C→S  keepalive, ~every 20 s (timeout 60 / 3)
GET_PARAMETER rtsp://192.168.1.64:554/Streaming/Channels/101 RTSP/1.0
CSeq: 7
Session: 1885573958
Authorization: Digest username="admin", realm="IP Camera(52491)", nonce="3a2f5c8e1b7d4906f2e5a8c1d4b70e93", uri="rtsp://192.168.1.64:554/Streaming/Channels/101", response="7784fa4d5936a634efec80eeb5700774"
User-Agent: Vigil/1.0

(15) S→C
RTSP/1.0 200 OK
CSeq: 7
Session: 1885573958

(16) C→S  optional PAUSE (live streams: Hikvision accepts it and stops sending)
PAUSE rtsp://192.168.1.64:554/Streaming/Channels/101 RTSP/1.0
CSeq: 8
Session: 1885573958
Authorization: Digest username="admin", realm="IP Camera(52491)", nonce="3a2f5c8e1b7d4906f2e5a8c1d4b70e93", uri="rtsp://192.168.1.64:554/Streaming/Channels/101", response="ec60e61d1e102f8e0db40f1572ab3c2b"
User-Agent: Vigil/1.0

(17) S→C
RTSP/1.0 200 OK
CSeq: 8
Session: 1885573958

(18) C→S
TEARDOWN rtsp://192.168.1.64:554/Streaming/Channels/101 RTSP/1.0
CSeq: 9
Session: 1885573958
Authorization: Digest username="admin", realm="IP Camera(52491)", nonce="3a2f5c8e1b7d4906f2e5a8c1d4b70e93", uri="rtsp://192.168.1.64:554/Streaming/Channels/101", response="6c562c1ab1c2a7b664e7303d52167fcc"
User-Agent: Vigil/1.0

(19) S→C
RTSP/1.0 200 OK
CSeq: 9
Session: 1885573958
```

Notes on this exchange:

* Step (2): `Public` does **not** list `REDIRECT` or `ANNOUNCE`; we still handle both if the
  server sends them (§16).
* `Content-Length: 712` in (6) is the exact byte length of the §8.8 SDP with CRLF line endings
  and no trailing NUL. Fixtures must be stored with CRLF (`.gitattributes: *.rtsp -text`).
* Between (12) and (13) there is no delay: the first `$` frame frequently arrives in the **same
  TCP segment** as the PLAY response. The decoder handles this naturally; a test asserts it
  (fixture `play_response_with_trailing_media.rtsp`).
* Step (14) uses `GET_PARAMETER` with **no body and no `Content-Length`** — Hikvision answers
  `200` and this is the least intrusive keepalive.

### 11.2 DS-7608NI-K2 NVR, firmware V4.30.085, channel 3, `qop=auth` Digest, H.265

```
(1) C→S
OPTIONS rtsp://192.168.1.200:554/Streaming/Channels/301 RTSP/1.0
CSeq: 1
User-Agent: Vigil/1.0

(2) S→C
RTSP/1.0 401 Unauthorized
CSeq: 1
WWW-Authenticate: Digest realm="DS-7608NI-K2(24680)", nonce="b7c41e0a9d3f625814ae7c0b6d29f4e1", stale="FALSE", qop="auth"
Date: Mon, 15 Jan 2024 09:20:11 GMT

(3) C→S  [nc=00000001, cnonce fixed for this nonce; §6.5(c) DESCRIBE row]
DESCRIBE rtsp://192.168.1.200:554/Streaming/Channels/301 RTSP/1.0
CSeq: 2
Authorization: Digest username="admin", realm="DS-7608NI-K2(24680)", nonce="b7c41e0a9d3f625814ae7c0b6d29f4e1", uri="rtsp://192.168.1.200:554/Streaming/Channels/301", response="7a525b747736353ecd4833fd99cbc565", qop=auth, nc=00000001, cnonce="1c8f4a09be23d7f5"
User-Agent: Vigil/1.0
Accept: application/sdp

(4) S→C
RTSP/1.0 200 OK
CSeq: 2
Content-Type: application/sdp
Content-Base: rtsp://192.168.1.200:554/Streaming/Channels/301/
Content-Length: 843

<the SDP of §8.9 — session control is "*", track controls are RELATIVE>

(5) C→S  [resolved: base + "trackID=1"; nc=00000002]
SETUP rtsp://192.168.1.200:554/Streaming/Channels/301/trackID=1 RTSP/1.0
CSeq: 3
Authorization: Digest username="admin", realm="DS-7608NI-K2(24680)", nonce="b7c41e0a9d3f625814ae7c0b6d29f4e1", uri="rtsp://192.168.1.200:554/Streaming/Channels/301/trackID=1", response="530838bed48ccf4b34d73cab7ccba0ce", qop=auth, nc=00000002, cnonce="1c8f4a09be23d7f5"
User-Agent: Vigil/1.0
Transport: RTP/AVP/TCP;unicast;interleaved=0-1

(6) S→C
RTSP/1.0 200 OK
CSeq: 3
Session: 100114;timeout=60
Transport: RTP/AVP/TCP;unicast;interleaved=0-1;ssrc=13ac7b1e;mode="play"

(7) C→S  [nc=00000003]
SETUP rtsp://192.168.1.200:554/Streaming/Channels/301/trackID=2 RTSP/1.0
CSeq: 4
Session: 100114
Authorization: Digest username="admin", realm="DS-7608NI-K2(24680)", nonce="b7c41e0a9d3f625814ae7c0b6d29f4e1", uri="rtsp://192.168.1.200:554/Streaming/Channels/301/trackID=2", response="299acee76e354c38820f5d0089d9969a", qop=auth, nc=00000003, cnonce="1c8f4a09be23d7f5"
User-Agent: Vigil/1.0
Transport: RTP/AVP/TCP;unicast;interleaved=2-3

(8) S→C
RTSP/1.0 200 OK
CSeq: 4
Session: 100114;timeout=60
Transport: RTP/AVP/TCP;unicast;interleaved=2-3;ssrc=6b0f2ad4;mode="play"

(9) C→S  [nc=00000004]
PLAY rtsp://192.168.1.200:554/Streaming/Channels/301 RTSP/1.0
CSeq: 5
Session: 100114
Authorization: Digest username="admin", realm="DS-7608NI-K2(24680)", nonce="b7c41e0a9d3f625814ae7c0b6d29f4e1", uri="rtsp://192.168.1.200:554/Streaming/Channels/301", response="3df6c275791b14ea383f1f11c5217113", qop=auth, nc=00000004, cnonce="1c8f4a09be23d7f5"
User-Agent: Vigil/1.0
Range: npt=0.000-

(10) S→C
RTSP/1.0 200 OK
CSeq: 5
Session: 100114
RTP-Info: url=trackID=1;seq=8801;rtptime=411250632,url=trackID=2;seq=3312;rtptime=97240100
Range: npt=0.000-

(11) S→C  interleaved H.265 begins
«24 00 05 A8» «80 62 22 61 18 87 4C 08 13 AC 7B 1E 62 01 …»   ch0, 1448 B, H.265 FU (PayloadHdr 62 01)
«24 02 00 AC» «80 88 0C F0 05 CB 5D 24 6B 0F 2A D4 …»          ch2, 172 B, PCMA

(12) C→S  keepalive [nc=00000005]
GET_PARAMETER rtsp://192.168.1.200:554/Streaming/Channels/301 RTSP/1.0
CSeq: 6
Session: 100114
Authorization: Digest username="admin", realm="DS-7608NI-K2(24680)", nonce="b7c41e0a9d3f625814ae7c0b6d29f4e1", uri="rtsp://192.168.1.200:554/Streaming/Channels/301", response="b80b79fd9f31c6761ace1b2e2df0b9cd", qop=auth, nc=00000005, cnonce="1c8f4a09be23d7f5"
User-Agent: Vigil/1.0

(13) S→C
RTSP/1.0 200 OK
CSeq: 6
Session: 100114

(14) C→S  [nc=00000006]
TEARDOWN rtsp://192.168.1.200:554/Streaming/Channels/301 RTSP/1.0
CSeq: 7
Session: 100114
Authorization: Digest username="admin", realm="DS-7608NI-K2(24680)", nonce="b7c41e0a9d3f625814ae7c0b6d29f4e1", uri="rtsp://192.168.1.200:554/Streaming/Channels/301", response="a271fd1b76b1861f447dcbd4767daa97", qop=auth, nc=00000006, cnonce="1c8f4a09be23d7f5"
User-Agent: Vigil/1.0

(15) S→C
RTSP/1.0 200 OK
CSeq: 7
Session: 100114
```

Notes:

* Step (2): the NVR challenges **`OPTIONS`**, unlike the camera. The state machine must accept a
  challenge on any request.
* Step (10): `RTP-Info` uses **relative** `url=trackID=1` values — this is why `equivalent()`
  needs the last-path-segment fallback (§9.1 rule 3).
* Session IDs on NVRs are short decimal strings (`100114`); on cameras they are large decimals
  (`1885573958`). Both are opaque: treat `Session` as an **opaque string**, never as a number.

### 11.3 Playback: DS-7608NI-K2, channel 3, 09:00–09:30 UTC on 2024-01-15

```
(1) C→S
DESCRIBE rtsp://192.168.1.200:554/Streaming/tracks/301?starttime=20240115T090000Z&endtime=20240115T093000Z RTSP/1.0
CSeq: 2
Authorization: Digest username="admin", realm="DS-7608NI-K2(24680)", nonce="b7c41e0a9d3f625814ae7c0b6d29f4e1", uri="rtsp://192.168.1.200:554/Streaming/tracks/301?starttime=20240115T090000Z&endtime=20240115T093000Z", response="5b87816f4729fc5cece68be9501682e7", qop=auth, nc=00000001, cnonce="1c8f4a09be23d7f5"
User-Agent: Vigil/1.0
Accept: application/sdp

(2) S→C
RTSP/1.0 200 OK
CSeq: 2
Content-Type: application/sdp
Content-Base: rtsp://192.168.1.200:554/Streaming/tracks/301/
Content-Length: 476

v=0
o=- 1109162014219182 1109162014219182 IN IP4 192.168.1.200
s=Media Presentation
e=NONE
b=AS:5100
t=0 0
a=control:*
a=range:clock=20240115T090000Z-20240115T093000Z
m=video 0 RTP/AVP 98
c=IN IP4 0.0.0.0
b=AS:5000
a=recvonly
a=control:trackID=1
a=rtpmap:98 H265/90000
a=fmtp:98 profile-id=1;level-id=120;sprop-vps=QAEMAf//AWAAAAMAsAAAAwAAAwBdlZgJ;sprop-sps=QgEBAWAAAAMAsAAAAwAAAwBdoAKAgC0WWVmkkyuAQEAAAAMAQAAAB4I=;sprop-pps=RAHBcrRiQA==
a=appversion:1.0

(3) C→S   [note: the query is carried onto the track URI — §8.3 step 4]
SETUP rtsp://192.168.1.200:554/Streaming/tracks/301/trackID=1?starttime=20240115T090000Z&endtime=20240115T093000Z RTSP/1.0
CSeq: 3
Authorization: Digest username="admin", realm="DS-7608NI-K2(24680)", nonce="b7c41e0a9d3f625814ae7c0b6d29f4e1", uri="rtsp://192.168.1.200:554/Streaming/tracks/301/trackID=1?starttime=20240115T090000Z&endtime=20240115T093000Z", response="f65cb391d4106a16f2b2690744765ca9", qop=auth, nc=00000002, cnonce="1c8f4a09be23d7f5"
User-Agent: Vigil/1.0
Transport: RTP/AVP/TCP;unicast;interleaved=0-1

(4) S→C
RTSP/1.0 200 OK
CSeq: 3
Session: 100117;timeout=60
Transport: RTP/AVP/TCP;unicast;interleaved=0-1;ssrc=2f5c11a0;mode="play"

(5) C→S   [absolute range; Rate-Control: no makes the NVR push as fast as TCP allows]
PLAY rtsp://192.168.1.200:554/Streaming/tracks/301?starttime=20240115T090000Z&endtime=20240115T093000Z RTSP/1.0
CSeq: 4
Session: 100117
Authorization: Digest username="admin", realm="DS-7608NI-K2(24680)", nonce="b7c41e0a9d3f625814ae7c0b6d29f4e1", uri="rtsp://192.168.1.200:554/Streaming/tracks/301?starttime=20240115T090000Z&endtime=20240115T093000Z", response="77a5a4af3c7c82b4cacd3e24ccdc64fb", qop=auth, nc=00000003, cnonce="1c8f4a09be23d7f5"
User-Agent: Vigil/1.0
Range: clock=20240115T090000Z-20240115T093000Z
Scale: 1.000
Rate-Control: no

(6) S→C
RTSP/1.0 200 OK
CSeq: 4
Session: 100117
Range: clock=20240115T090000Z-20240115T093000Z
Scale: 1.000
Rate-Control: no
RTP-Info: url=trackID=1;seq=1;rtptime=0

(7) S→C  interleaved playback data …

(8) S→C  end of the requested range — server-initiated notice
ANNOUNCE rtsp://192.168.1.200:554/Streaming/tracks/301 RTSP/1.0
CSeq: 1
Session: 100117
Notice: 2101 End-of-Stream Reached; event-date=20240115T093000Z
Range: clock=20240115T093000Z-

(9) C→S  we must acknowledge
RTSP/1.0 200 OK
CSeq: 1
Session: 100117
```

`Scale` is serialized with **exactly 3 decimal places** (`1.000`, `4.000`, `-2.000`, `0.500`):
one DS-96xx build rejects `Scale: 1` and another rejects `Scale: 1.0`; `%.3f`-style formatting
is accepted by every build tested. Format it manually (no `String(format:)` in the pure layer):

```swift
func serializeScale(_ s: Double) -> String {
    let milli = Int64((s * 1000).rounded())
    let sign = milli < 0 ? "-" : ""
    let a = abs(milli)
    var frac = String(a % 1000)
    while frac.count < 3 { frac = "0" + frac }
    return "\(sign)\(a / 1000).\(frac)"
}
```

---

## 12. Session lifecycle, keepalive and timers

### 12.1 `Session` header

```
Session: 1885573958;timeout=60
Session: 100114
Session: 0AF3B2C1;timeout=60;
```

```swift
public struct SessionHeader: Sendable, Equatable {
    public var id: String                // OPAQUE. Never parse as an integer.
    public var timeout: RTSPDuration     // default 60 s when absent
    public static func parse(_ value: String) -> SessionHeader?
}
```

Rules: the id is everything before the first `;`, OWS-trimmed, **case-sensitively preserved**.
`timeout` is in **seconds**; clamp the parsed value to `10...600` (a `timeout=0` has been seen;
treat it as the 60 s default). The `timeout` parameter usually appears only on the first SETUP
response — cache it and never let a later omission reset it. Echo the id on every
session-scoped request, without the `timeout` parameter.

### 12.2 Keepalive

```
keepaliveInterval = clamp(sessionTimeout / 3, 5 s, 20 s)      // timeout 60 s -> 20 s
```

Rationale: a third of the timeout survives two consecutive lost keepalives; the 20 s cap keeps a
dead-link detection latency low enough that the UI reconnects before a user notices.

Method selection, in order:

| Condition | Keepalive method |
|---|---|
| `Public` (from OPTIONS) lists `GET_PARAMETER` | `GET_PARAMETER` with no body — **default for all Hikvision** |
| `Public` lists `SET_PARAMETER` but not `GET_PARAMETER` | `SET_PARAMETER` with body `ping: yes\r\n` and `Content-Type: text/parameters` |
| Neither, or no `Public` seen | `OPTIONS` with the `Session` header (RFC 2326 §10.1 permits it; every Hikvision build accepts it) |

The keepalive timer is reset by **any** successfully completed request, not just keepalives — a
`PLAY` or `SET_PARAMETER` refreshes the session, so we do not send a redundant keepalive right
after user interaction.

While `Rate-Control: no` playback is in flight, keepalives are still sent: the transport may be
throttled by our own read backpressure, so the machine enqueues the keepalive and
`VigilTransport` must be able to write while reads are paused (documented cross-module
requirement: reads and writes are independently controllable).

### 12.3 Timers

| `RTSPTimerID` | Duration | Purpose | On fire |
|---|---|---|---|
| `.keepalive` | `clamp(timeout/3, 5, 20)` s | session refresh | send keepalive, rearm |
| `.requestTimeout(cseq:)` | 5 s (`TEARDOWN`: 2 s) | detect a lost response | `.fail(.requestTimeout)`; for `TEARDOWN`, `.closeTransport(.normal)` instead |
| `.firstMediaTimeout` | 5 s after the PLAY response | detect "PLAY 200 but no media" | advance the transport ladder (§7.4) |
| `.dataIdle` | 8 s of no media while `playing` | detect a silently dead stream | `.fail(.mediaStalled)` |
| `.sessionExpiry` | `timeout` s, reset on every response | belt-and-braces | `.fail(.sessionExpired)` |
| `.teardownGrace` | 500 ms after `TEARDOWN` is sent | do not wait forever to close | `.closeTransport(.normal)` |

`.dataIdle` is armed only for `playing` and only when at least one media frame has been seen. It
is **not** armed during `Rate-Control: no` playback when our own read backpressure is active
(the machine tracks a `readsPaused` flag set via `RTSPCommand.setReadBackpressure(_:)`).

### 12.4 Connection loss

`connectionClosed(error:now:)` transitions to `.failed(.transportClosed(underlying:))` unless the
machine is in `.tearingDown` or `.closed`, in which case it completes normally. The machine
never reconnects — that is `VigilCore`'s reconnect state machine, which owns the backoff.

---

## 13. Playback control

### 13.1 `Range` on `PLAY`

| Intent | `Range` |
|---|---|
| live from now | `npt=0.000-` (we always send this on live PLAY; some builds dislike an absent Range) |
| recorded, absolute window | `clock=20240115T090000Z-20240115T093000Z` |
| recorded, open-ended | `clock=20240115T090000Z-` |
| seek within an active playback session | `clock=<new start>-<original end>` on a fresh `PLAY` (no new SETUP needed) |
| resume after `PAUSE` | `PLAY` with **no** `Range` (server resumes where it stopped) |

A seek is just another `PLAY` on the same session. Hikvision requires the session to be in
`playing` or `paused` state; sending `PLAY` twice without `PAUSE` is accepted and performs a
gapless re-position. We do not send `PAUSE` before a seek — that adds ~80 ms and one round trip.

After any `PLAY`, the response's `Range` is authoritative for where playback actually started
(the NVR snaps to the preceding I-frame, typically up to one GOP = 1–4 s earlier). Emit the
snapped start in `RTSPTrackTiming.absoluteStart` so the scrubber does not fight the device.

### 13.2 `Scale`

| Value | Meaning | Hikvision behaviour |
|---|---|---|
| `1.000` | normal | all frames |
| `2.000`, `4.000`, `8.000` | fast forward | **I-frames only**; RTP timestamps continue to advance at the media rate, so the renderer must divide inter-frame delays by `Scale` |
| `16.000`, `32.000` | very fast | I-frames only, may drop to 1 frame/s of content |
| `0.500`, `0.250` | slow | all frames, decoder paces slower |
| `-1.000`, `-2.000`, `-4.000` | reverse | I-frames only, **descending** RTP timestamps; `VigilRTP` must not treat this as a wrap |
| `0` | **never sent.** Ambiguous across firmware | — |

Supported set advertised by us: `{-8, -4, -2, -1, 0.25, 0.5, 1, 2, 4, 8, 16}`. The response
echoes the actual `Scale`; **adopt the echoed value** and report it upward, because devices clamp
silently (asking for 32 may yield 8). If the response omits `Scale`, assume the requested value
took effect.

Reverse playback additionally requires `Rate-Control: no` on several DS-76xx builds; we always
pair `Scale < 0` with `Rate-Control: no`.

### 13.3 RTCP-based progress

During playback the NVR sends RTCP SR on the odd interleaved channel with the NTP field set to
the **recorded wall-clock time** of the RTP timestamp in the same SR. That mapping, delivered by
`VigilRTP`, is the authoritative source for the scrubber position — more reliable than
accumulating frame durations, and it survives gaps in the recording (Hikvision skips
unrecorded intervals without any RTSP-level notification, so the RTP timeline is not continuous
with wall-clock time).

`VigilRTSP` contributes: `absoluteStart` (from `Range`) as the initial anchor, and the
`Notice`-based end-of-stream signal. The rule for the UI, stated once here: **prefer RTCP SR
mapping when available; fall back to `absoluteStart + elapsed media time`.**

### 13.4 `Rate-Control: no`

Sent on `PLAY` for: any `Scale ≠ 1`, any explicit "download/export" operation, and any seek where
we want the frames as fast as possible. Semantics:

* The server ignores media timing and pushes data at line rate.
* **Arrival time carries no timing information.** The client must pace using RTP timestamps.
  This is a hard requirement on `VigilVideo`'s frame pacer.
* Flow control is our responsibility. With interleaved TCP we throttle by **not reading the
  socket**: the machine emits `.setReadBackpressure(true)` when the downstream queue exceeds
  `config.playbackPrefetchFrames` (**120** frames) and `false` when it drops below half that
  (**60**). `VigilTransport` must implement `pauseReads()`/`resumeReads()` — a hard cross-module
  requirement. Over UDP, `Rate-Control: no` is refused (`config` forces TCP for it) because
  there is no backpressure mechanism and the NVR will overrun us.
* Keepalives continue (§12.2).

For gapless seeking: issue the new `PLAY` with `Rate-Control: no` and the new `Range`, keep
displaying the old frames until the first AU of the new range decodes, then swap. The visible
result is a seek that appears instant because the NVR delivers the first GOP in a few
milliseconds on a LAN.

### 13.5 ONVIF replay compatibility

When the device advertises ONVIF replay (`Public` contains `GET_PARAMETER` and the device is
known via ONVIF discovery), the following optional headers become available on `PLAY`, and are
gated by `config.useONVIFReplayExtensions` (default **false**, enabled per-camera when ONVIF
replay is detected):

| Header | Value | Effect |
|---|---|---|
| `Require` | `onvif-replay` | activates replay semantics; a `551 Option not supported` response means we must retry **without** `Require` (and remember that for the camera) |
| `Rate-Control` | `no` | as §13.4 |
| `Frames` | `intra` | I-frames only regardless of `Scale` |
| `Frames` | `intra/2000` | I-frames at most one per 2000 ms |
| `Immediate-Header` | `yes` | parameter sets sent before the first frame |

On `551`, the machine strips `Require`, remembers `onvifReplaySupported = false`, and reissues
the `PLAY` with a new `CSeq`. The `Unsupported:` response header, when present, is logged.

### 13.6 Frame step

Decision: **frame step is a client-side operation for the forward direction and a
re-`PLAY` for the backward direction.** We deliberately do not use `Scale: 0` (unsupported and
ambiguous) and do not rely on any vendor frame-step extension.

```swift
public enum FrameStepDirection: Sendable { case forward, backward }
```

* `frameStep(.forward)` while `paused`: if `VigilVideo` still holds a decoded AU after the
  current one, it presents it and no RTSP traffic occurs (`.log(.frameStepServedLocally)`).
  Otherwise the machine sends `PLAY` with `Range: clock=<currentPosition>-`, `Scale: 1.000`,
  `Rate-Control: no`, and arms `.frameStepPending`. On the first complete AU delivered, it
  immediately sends `PAUSE`. Net cost on LAN: one round trip, ~15–40 ms.
* `frameStep(.backward)`: always a re-`PLAY`. Target
  `T' = currentPosition − max(1/fps, 0.040 s)`; because the NVR snaps back to the preceding
  I-frame, `VigilVideo` decodes forward from that I-frame and presents the AU immediately
  preceding `currentPosition`. The machine sends
  `PLAY Range: clock=<T'>-<originalEnd>`, `Rate-Control: no`, then `PAUSE` once the target AU has
  been decoded. `VigilCore` caches the decoded GOP so repeated backward steps within one GOP need
  **zero** further RTSP traffic — this is what makes frame-by-frame scrubbing feel instant.

The precise GOP-caching policy belongs to `VigilCore`; the RTSP-visible contract is:
`RTSPCommand.frameStep(FrameStepDirection, currentPosition: Date, fps: Double)` and the
`.frameStepPending` completion event.

---

## 14. `RTSPSessionMachine` — complete public API

### 14.1 Design contract

* A `struct`. Owned and mutated by one actor. No internal locking, no `Task`, no `DispatchQueue`.
* Deterministic: identical `(config, credentials, random seed, byte stream, clock values,
  command order)` ⇒ identical action sequence, byte for byte. Golden tests depend on this.
* All I/O intent leaves as `RTSPAction` values. The machine never performs I/O.
* One outstanding request at a time (no pipelining). Commands queue (max 8, then
  `.commandQueueOverflow`).
* Every entry point returns `[RTSPAction]` in the exact order the driver must execute them.
  The assignment's notion of "events" is represented by the `emit*` / `stateChanged` /
  `ready` / `log` action cases: a single ordered sink means the driver has one deterministic
  replay order and tests can assert on one array.

### 14.2 Configuration

```swift
public struct RTSPSessionConfig: Sendable {
    public var url: RTSPURL                       // the DESCRIBE target
    public var userAgent: String = "Vigil/1.0"
    public var transportPreference: RTSPTransportPreference = .tcpInterleaved
    public var isTLS: Bool = false                // informational; set by VigilTransport
    public var allowBasicOverPlaintext: Bool = false
    public var setupAudio: Bool = true
    public var setupMetadataTrack: Bool = false
    public var maxTracks: Int = 4

    public var requestTimeout: RTSPDuration = .seconds(5)
    public var teardownTimeout: RTSPDuration = .seconds(2)
    public var firstMediaTimeout: RTSPDuration = .seconds(5)
    public var dataIdleTimeout: RTSPDuration = .seconds(8)
    public var udpFirstPacketTimeout: RTSPDuration = .seconds(3)
    public var keepaliveFloor: RTSPDuration = .seconds(5)
    public var keepaliveCeiling: RTSPDuration = .seconds(20)

    public var maxAuthAttemptsPerRequest: Int = 4
    public var maxRedirects: Int = 3
    public var maxResyncsPerMinute: Int = 3
    public var maxCommandQueueDepth: Int = 8
    public var playbackPrefetchFrames: Int = 120
    public var useONVIFReplayExtensions: Bool = false
    public var decoderLimits: RTSPWireDecoder.Limits = .init()
    /// UDP client port pair allocated by VigilTransport; required for .udpUnicast.
    public var udpClientPorts: ClosedRange<UInt16>? = nil
    /// Playback intent; nil ⇒ live.
    public var playback: PlaybackRequest? = nil

    public struct PlaybackRequest: Sendable, Equatable {
        public var start: Date
        public var end: Date?
        public var scale: Double = 1.0
        public var disableRateControl: Bool = false
    }
    public init(url: RTSPURL)
}

public enum RTSPTransportPreference: String, Sendable, CaseIterable {
    case tcpInterleaved, udpUnicast, udpMulticast, tcpInterleavedNoChannelHint
}
```

### 14.3 Actions

```swift
public enum RTSPAction: Sendable, Equatable {
    /// Write these bytes to the connection, as ONE atomic write.
    case send(Data)
    /// Frame and write an interleaved packet (RTCP RR). One atomic write.
    case sendInterleaved(channel: UInt8, payload: Data)
    /// Arm (or re-arm) a timer. An existing timer with the same id is replaced.
    case setTimer(RTSPTimerID, deadline: RTSPInstant)
    case cancelTimer(RTSPTimerID)
    /// A track has been fully negotiated (post-SETUP). Emitted once per track, in SDP order.
    case emitTrack(RTSPTrack)
    /// Presentation-time seeds, emitted after PLAY, BEFORE any media for that track.
    case emitTiming(RTSPTrackTiming)
    /// One RTP or RTCP packet for a known channel. `payload` excludes the 4-byte framing.
    case emitMedia(channel: UInt8, payload: Data)
    /// The session is playing; all tracks and timings have been emitted.
    case ready(RTSPSessionDescription)
    /// State transition, for observability and UI.
    case stateChanged(RTSPSessionState)
    /// Structured log record; the driver forwards it to LoggerProtocol.
    case log(RTSPLogEvent)
    /// Ask the transport to stop/resume reading (Rate-Control: no backpressure).
    case setReadBackpressure(Bool)
    /// Terminal failure. No further actions will be produced.
    case fail(RTSPError)
    /// Close the connection. `.normal` after TEARDOWN, `.error` otherwise.
    case closeTransport(reason: RTSPCloseReason)
    /// The transport must reconnect to a new endpoint (302/REDIRECT) and re-drive the machine.
    case reconnect(to: RTSPURL, resetAuthState: Bool)
}

public enum RTSPCloseReason: Sendable, Equatable { case normal, error, redirect, ladderAdvance }

public enum RTSPTimerID: Hashable, Sendable {
    case keepalive
    case requestTimeout(cseq: UInt32)
    case firstMediaTimeout
    case dataIdle
    case sessionExpiry
    case teardownGrace
}

public struct RTSPSessionDescription: Sendable, Equatable {
    public var tracks: [RTSPTrack]
    public var sessionID: String
    public var sessionTimeout: RTSPDuration
    public var transport: RTSPTransportPreference
    public var range: RTSPRange?
    public var scale: Double
    public var isRateControlDisabled: Bool
    public var serverPublicMethods: Set<RTSPMethod>
    public var sdp: SDPDocument
}
```

### 14.4 States and commands

```swift
public enum RTSPSessionState: Sendable, Equatable {
    case idle
    case awaitingOptions
    case awaitingDescribe
    case authenticating(retryOf: RTSPMethod)
    case settingUp(trackIndex: Int, of: Int)
    case awaitingPlay
    case playing
    case awaitingPause
    case paused
    case seeking
    case tearingDown
    case closed
    case failed(RTSPError)
}

public enum RTSPCommand: Sendable, Equatable {
    /// Begin: OPTIONS -> DESCRIBE -> SETUP* -> PLAY. The normal entry point.
    case start
    /// DESCRIBE only (used by the URL probe ladder and by ISAPI-less discovery).
    case describeOnly
    case play(range: RTSPRange?, scale: Double?, disableRateControl: Bool?)
    case pause
    case seek(to: Date, scale: Double?)
    case frameStep(FrameStepDirection, currentPosition: Date, fps: Double)
    case keepaliveNow
    case getParameter(names: [String])
    case setParameter(name: String, value: String)
    case teardown
    /// Feed an RTCP RR built by VigilRTP; the machine frames and forwards it.
    case sendRTCP(channel: UInt8, payload: Data)
    /// Downstream queue pressure crossed a threshold (Rate-Control: no flow control).
    case setDownstreamPressure(frames: Int)
}
```

### 14.5 The machine

```swift
public struct RTSPSessionMachine: Sendable {

    // MARK: - Construction

    public init(config: RTSPSessionConfig,
                credentials: RTSPCredentials?,
                random: any RTSPRandomSource = RTSPSystemRandom(),
                now: RTSPInstant)

    // MARK: - Inputs (each returns the ordered actions the driver must perform)

    /// Bytes from the connection. Never throws; framing errors surface as `.fail`.
    public mutating func ingest(_ bytes: some Collection<UInt8>, now: RTSPInstant) -> [RTSPAction]

    /// Time-driven progress. Safe to call at any cadence; idempotent when nothing is due.
    public mutating func step(now: RTSPInstant) -> [RTSPAction]

    /// A timer previously armed via `.setTimer` has fired.
    public mutating func timerFired(_ id: RTSPTimerID, now: RTSPInstant) -> [RTSPAction]

    /// A control command from VigilCore.
    public mutating func handle(_ command: RTSPCommand, now: RTSPInstant) -> [RTSPAction]

    /// The transport connected (or reconnected after a redirect / ladder advance).
    public mutating func transportReady(isTLS: Bool, now: RTSPInstant) -> [RTSPAction]

    /// The connection went away. `error` is nil for a clean FIN.
    public mutating func connectionClosed(error: String?, now: RTSPInstant) -> [RTSPAction]

    // MARK: - Observation (pure reads, no mutation)

    public var state: RTSPSessionState { get }
    public var tracks: [RTSPTrack] { get }
    public var sessionID: String? { get }
    public var negotiatedTransport: RTSPTransportPreference { get }
    public var statistics: RTSPSessionStatistics { get }
    /// Interleaved channels currently registered, for assertions and diagnostics.
    public var interleavedChannels: Set<UInt8> { get }
}

public struct RTSPSessionStatistics: Sendable, Equatable {
    public var requestsSent = 0
    public var responsesReceived = 0
    public var authChallenges = 0
    public var authRetries = 0
    public var redirectsFollowed = 0
    public var keepalivesSent = 0
    public var interleavedFrames = 0
    public var interleavedBytes: UInt64 = 0
    public var mediaBytesByChannel: [UInt8: UInt64] = [:]
    public var framingResyncs = 0
    public var lastRoundTripMilliseconds: Int64?
    public var transportLadderRung = 0
    public var serverRequestsReceived = 0          // ANNOUNCE / OPTIONS / REDIRECT
    public var decoder = DecoderStatistics()
}
```

### 14.6 Ordering guarantees (normative)

The driver may rely on all of these:

1. `.stateChanged` precedes any action caused by the new state.
2. Every `.emitTrack` for a track precedes any `.emitTiming` for that track, which precedes any
   `.emitMedia` on that track's channels. This is why `registerInterleavedChannels` happens at
   SETUP-request time and why media arriving before the PLAY response is buffered by the machine
   (bounded: `maxPreplayMediaFrames = 64`, then oldest dropped with a log) rather than emitted
   early.
3. `.ready` is emitted exactly once per successful `PLAY`-from-`awaitingPlay` transition, after
   all `.emitTrack`/`.emitTiming` actions.
4. `.fail` is the last action ever produced. All subsequent calls return `[]` except
   `handle(.teardown)` which returns `[.closeTransport(reason: .error)]` once.
5. `.setTimer` with an id replaces any previous timer with that id; the driver must not stack
   them.
6. `.send` payloads, concatenated in emission order, form exactly the client's byte stream.
7. `.emitMedia` payloads are exactly the interleaved frame payloads, in arrival order, with no
   coalescing and no reordering across channels.

### 14.7 Driver skeleton (how `VigilCore` uses it)

```swift
actor RTSPSessionDriver {
    private var machine: RTSPSessionMachine
    private let connection: RTSPConnection          // VigilTransport
    private var timers: [RTSPTimerID: Task<Void, Never>] = [:]

    func run() async throws {
        try await connection.connect()
        await perform(machine.transportReady(isTLS: connection.isTLS, now: now()))
        await perform(machine.handle(.start, now: now()))
        for try await chunk in connection.bytes {           // AsyncStream<Data>
            await perform(machine.ingest(chunk, now: now()))
            if case .failed = machine.state { break }
        }
    }

    private func perform(_ actions: [RTSPAction]) async {
        for action in actions {
            switch action {
            case .send(let data):
                try? await connection.write(data)                   // ONE atomic write
            case .sendInterleaved(let ch, let payload):
                try? await connection.write(frame(ch, payload))
            case .setTimer(let id, let deadline):
                timers[id]?.cancel()
                timers[id] = Task { [weak self] in
                    try? await Task.sleep(until: deadline)
                    await self?.perform(self?.machine.timerFired(id, now: now()) ?? [])
                }
            case .cancelTimer(let id):  timers.removeValue(forKey: id)?.cancel()
            case .emitTrack(let t):     await pipeline.add(track: t)
            case .emitTiming(let s):    await pipeline.seed(s)
            case .emitMedia(let ch, let p): await pipeline.ingestRTP(channel: ch, payload: p)
            case .ready(let d):         await coordinator.sessionReady(d)
            case .setReadBackpressure(let on): on ? connection.pauseReads() : connection.resumeReads()
            case .stateChanged(let s):  await coordinator.stateChanged(s)
            case .log(let e):           logger.log(e)
            case .closeTransport:       await connection.close()
            case .reconnect(let url, let reset): await coordinator.reconnect(to: url, resetAuth: reset)
            case .fail(let e):          await coordinator.failed(e)
            }
        }
    }
}
```

### 14.8 Log events

```swift
public enum RTSPLogEvent: Sendable, Equatable {
    case requestSent(method: RTSPMethod, cseq: UInt32, uri: String)     // uri is redacted form
    case responseReceived(status: Int, cseq: UInt32?, rttMilliseconds: Int64?)
    case authChallenged(realm: String, qop: String?, stale: Bool)
    case authRetried(attempt: Int)
    case digestURIFallbackUsed(rung: Int)
    case sdpParsed(trackCount: Int, codecs: [String])
    case trackControlResolved(index: Int, uri: String, viaBase: String)
    case assumedInterleavedChannels(ClosedRange<UInt8>)
    case transportLadderAdvanced(from: String, to: String, reason: String)
    case framingResync(discarded: Int, reason: String)
    case midHeaderInterleavedFrame(channel: UInt8, length: Int)
    case malformedHeaderIgnored(String)
    case malformedParameterSet(codec: String)
    case unknownSDPAttribute(String)
    case serverRequest(method: RTSPMethod, notice: String?)
    case noticeReceived(code: Int, text: String)
    case scaleClamped(requested: Double, actual: Double)
    case rangeSnapped(requested: String, actual: String)
    case keepaliveSent(method: RTSPMethod)
    case preplayMediaDropped(count: Int)
    case frameStepServedLocally
    case nonASCIIHeaderValue(name: String)
}
```

The pure layer never imports `OSLog`; the driver maps these to `Logger` categories
(`ARCHITECTURE.md` owns the mapping).

---

## 15. Error taxonomy and status-code handling

```swift
public enum RTSPError: Error, Sendable, Equatable {
    // Framing / parsing
    case startLineTooLong
    case headerLineTooLong
    case headerBlockTooLarge
    case bodyTooLarge(Int)
    case receiveBufferOverflow
    case malformedStartLine(String)
    case malformedHeader(String)
    case missingContentLength(cseq: UInt32?)
    case missingCSeq
    case unsolicitedResponse(cseq: UInt32?)
    case unrecoverableFraming
    case excessiveFramingErrors
    case interleavedChannelCollision(track: Int, channel: UInt8)

    // Protocol level
    case unexpectedStatus(RTSPStatus, method: RTSPMethod, reason: String)
    case requestTimeout(method: RTSPMethod, cseq: UInt32)
    case sessionExpired
    case sessionNotFound
    case mediaStalled(afterMilliseconds: Int64)
    case redirectLoop
    case tooManyRedirects(Int)

    // Auth
    case authenticationRequired
    case authenticationFailed(realm: String?)
    case accessForbidden
    case unsupportedAuthenticationScheme(String)
    case unsupportedQop(String)
    case credentialsMissing

    // SDP / media
    case sdpParseFailed(String)
    case sdpNoMedia
    case noSupportedCodec(found: [String])
    case trackMissingControl(index: Int)
    case noUsableTrack
    case unsupportedPacketizationMode(Int)

    // Transport
    case unsupportedTransport
    case transportMismatch(requested: String, offered: String)
    case noUsableTransport
    case transportClosed(underlying: String?)
    case deviceOutOfResources          // 453 / 503

    // Misc
    case commandQueueOverflow
    case invalidState(command: String, state: String)
    case malformedURL(String)
}
```

`RTSPError` conforms to a shared `VigilFailure` protocol declared in `VigilProtocols`:

```swift
public protocol VigilFailure: Error, Sendable {
    var isRetryable: Bool { get }             // may VigilCore reconnect automatically?
    var requiresUserAction: Bool { get }      // must we prompt (credentials, etc.)?
    var diagnosticCode: String { get }        // stable short code for logs/UI, e.g. "RTSP-401"
}
```

Classification (binding — `VigilCore`'s reconnect logic depends on it):

| Error group | `isRetryable` | `requiresUserAction` |
|---|---|---|
| framing, timeout, stall, transportClosed, sessionExpired, sessionNotFound | **true** | false |
| `deviceOutOfResources` | true (with a longer backoff floor: 5 s) | false |
| `authenticationFailed`, `credentialsMissing`, `accessForbidden` | **false** | **true** |
| `noSupportedCodec`, `unsupportedPacketizationMode`, `sdpNoMedia`, `noUsableTrack`, `malformedURL` | false | true (configuration problem) |
| `noUsableTransport`, `transportMismatch` | false | true |
| everything else | true | false |

Per-status handling:

| Status | Action |
|---|---|
| 200/201/250 | normal |
| 301/302 | follow: parse `Location`, `.reconnect(to:resetAuthState: true)`, count against `maxRedirects`; a repeat of a URL already visited ⇒ `.redirectLoop` |
| 303 | treated as 302 |
| 400 | `.unexpectedStatus`; log the full request we sent (redacted) — this is our bug |
| 401 | §6.7 |
| 403 | `.accessForbidden`, terminal, prompt user |
| 404 | during DESCRIBE probing: advance the ladder. During SETUP: aggregate-URL fallback (§8.3 step 5). Otherwise `.unexpectedStatus` |
| 405 | if the method was `GET_PARAMETER`: switch the keepalive method (§12.2) and continue. Otherwise terminal |
| 406 / 415 | `.noSupportedCodec` (a `/h264/` URL on an H.265 channel) — advance the probe ladder with the other codec segment |
| 451 / 455 / 456 / 460 | advance the probe ladder / SETUP fallback; otherwise `.unexpectedStatus` |
| 453 / 503 | `.deviceOutOfResources` — Hikvision's "too many streams" answer. Retryable with a 5 s floor. Do **not** hammer: cameras cap at 6–10 concurrent RTSP sessions and NVRs at 32–128 |
| 454 | `.sessionNotFound` — the session died; retryable, requires a full re-SETUP |
| 457 | `.unexpectedStatus` with a UI-visible "requested time range not recorded" mapping |
| 459 | we sent a per-track request the device wants aggregate-only: retry with the aggregate URI |
| 461 | advance the transport ladder (§7.4) |
| 462 | `.noUsableTransport` |
| 500 / 501 | retryable once, then terminal |
| 505 | `.unexpectedStatus` (we only speak 1.0; no device does this) |
| 551 | strip `Require`, retry (§13.5) |
| unknown 4xx/5xx | `.unexpectedStatus`, retryable if 5xx, terminal if 4xx |

---

## 16. Server-initiated messages

Servers send requests on the same connection. We must answer them or Hikvision will tear the
session down.

| Method | When | Our response |
|---|---|---|
| `ANNOUNCE` | end of a playback range; session about to be terminated | `RTSP/1.0 200 OK` echoing `CSeq` and `Session`. Parse the `Notice` header and act (below) |
| `OPTIONS` | some NVRs probe the client | `RTSP/1.0 200 OK`, `CSeq`, `Public: OPTIONS, ANNOUNCE, REDIRECT` |
| `REDIRECT` | rare load balancing | `200 OK`, then `.reconnect(to: Location, resetAuthState: true)` |
| `SET_PARAMETER` | never observed | `501 Not Implemented` with the correct `CSeq` |
| anything else | — | `501 Not Implemented`; never drop silently |

Responses to server requests reuse the server's `CSeq` verbatim (that is the only place we do
not allocate our own `CSeq`), and carry no `Authorization`.

`Notice` header: `Notice: <code> <text>[; parameters]`

```swift
public struct NoticeHeader: Sendable, Equatable {
    public var code: Int
    public var text: String
    public var eventDate: Date?         // event-date=20240115T093000Z
    public static func parse(_ value: String) -> NoticeHeader?
}
```

| Code | Meaning | Machine behaviour |
|---|---|---|
| 1103 | Playback complete | `.stateChanged(.paused)`, emit end-of-stream to `VigilCore` |
| 2101 | End-of-Stream Reached | same as 1103; the primary Hikvision/ONVIF signal |
| 2103 | Session terminated (server-side) | `.closeTransport(.normal)` + `.fail(.sessionExpired)` |
| 2104 | Session reset | `.fail(.sessionNotFound)` (retryable) |
| 2306 | Continuous feed terminated | `.fail(.mediaStalled(...))` (retryable) |
| 5200 / other | unknown | log `.noticeReceived`, otherwise ignore |

An RTCP `BYE` on a media channel is delivered by `VigilRTP`; `VigilCore` treats it the same as
notice 2101 for playback and as `.mediaStalled` for live.

---

## 17. Constants and limits

| Constant | Value | Where |
|---|---|---|
| Default RTSP port | 554 | `RTSPURL.port` |
| Default RTSPS port | **322** | `RTSPURL.port` |
| Interleave magic | `0x24` | §5.2 |
| Max interleaved payload | 65535 | protocol |
| Max start line | 4096 B | decoder limits |
| Max header line | 8192 B | decoder limits |
| Max header block | 32768 B / 128 fields | decoder limits |
| Max body | 262144 B | decoder limits |
| Receive high-water | 2 MiB | decoder limits |
| Resync chain depth | 2 frames | §5.5 |
| Max resync scan | 131072 B | §5.5 |
| Max resyncs / minute | 3 | §5.5 |
| First `CSeq` | 1 | §3.2 |
| `nc` start | `00000001` | §6.4 |
| `cnonce` length | 16 hex chars (8 random bytes) | §6.4 |
| Max auth attempts / request | 4 | §6.7 |
| Session timeout default | 60 s (clamped to 10…600) | §12.1 |
| Keepalive interval | `clamp(timeout/3, 5 s, 20 s)` | §12.2 |
| Request timeout | 5 s (`TEARDOWN` 2 s) | §12.3 |
| First-media timeout | 5 s | §12.3 |
| Data-idle timeout | 8 s | §12.3 |
| UDP first-packet timeout | 3 s | §7.4 |
| UDP client port range | 51000–51998, even | §7.2 |
| Max redirects | 3 | §15 |
| Command queue depth | 8 | §14.1 |
| Pre-PLAY media buffer | 64 frames | §14.6 |
| Playback prefetch high/low | 120 / 60 frames | §13.4 |
| `Scale` serialization | 3 decimals | §11.3 |
| Supported scales | ±1, ±2, ±4, ±8, 16, 0.5, 0.25 | §13.2 |

---

## 18. Test plan, fixtures and golden vectors

All tests run on Linux. Target: **≥ 90 % line coverage** of `VigilRTSP`, and 100 % of
`RTSPWireDecoder` and `RTSPAuthenticator`.

### 18.1 Fixtures

```
Tests/VigilRTSPTests/Fixtures/
├── camera_ds2cd2043_full_session.rtsp      byte-exact transcript of §11.1 (server side)
├── nvr_ds7608_full_session.rtsp            §11.2
├── nvr_ds7608_playback.rtsp                §11.3
├── sdp_camera_h264_aac.sdp
├── sdp_nvr_h265_pcma.sdp
├── sdp_playback_h265.sdp
├── sdp_legacy_h264_only.sdp                /h264/ch1/main/av_stream, no Content-Base
├── sdp_hikvision_trailing_nul.sdp          body with a trailing 0x00
├── sdp_bare_lf.sdp                         LF-only line endings
├── sdp_metadata_track.sdp                  vnd.onvif.metadata third m= section
├── play_response_with_trailing_media.rtsp  PLAY 200 + first $ frame in one segment
├── midheader_interleaved.rtsp              $ frame inside a header block (§5.4)
├── corrupt_then_resync.rtsp                256 random bytes injected mid-stream
└── oversized_header.rtsp                   40 KiB header block
```

`.gitattributes` must contain `*.rtsp -text` and `*.sdp -text` so CRLF survives checkout on
every platform. One test asserts every `.rtsp` fixture contains at least one `\r\n` and no
lone `\n` outside `.sdp` bodies — this catches a mangled checkout immediately.

### 18.2 Unit-test matrix

| Suite | Cases (minimum) |
|---|---|
| `RTSPHeadersTests` | case-insensitive lookup, duplicates, order preservation, ASCII-only folding (`İ` ≠ `i`), `joined`, `int` |
| `RTSPSerializerTests` | byte-exact output for all 11 methods; header order; `Content-Length` presence rules; ASCII assertion |
| `RTSPWireDecoderTests` | 200 OK no body; 200 + SDP body; two messages in one chunk; message split across 50 chunks; interleaved before/after/inside messages; empty `$` frame (len 0); unknown channel → resync; each limit violation; bare LF; obs-fold; missing reason phrase; leading CRLF padding; 2 MiB overflow; `Content-Length` mismatch duplicates |
| `RTSPResyncTests` | 1 B, 3 B, 4095 B of garbage; garbage that contains a false `0x24`; garbage ending mid-frame; scan-limit exceeded; resync-rate policy |
| `MD5Tests` (in `VigilProtocolsTests`) | 7 RFC 1321 vectors; streaming chunk sizes 1/3/7/13/25/26; 1 MiB input; empty `update` calls |
| `Base64Tests` | padded, unpadded, whitespace-laden, URL-safe, illegal char, `len % 4 == 1` |
| `RTSPChallengeTests` | Hikvision camera form; NVR `qop="auth"` form; `realm` containing a comma; two challenges in one header; `stale="FALSE"`/`stale=true`; `algorithm=MD5`/`"MD5"`/`MD5-sess`; missing `nonce` |
| `RTSPDigestTests` | every row of §6.5 (a)–(e); `nc` increment across 6 requests; `cnonce` stability within a nonce; nonce change resets `nc`; the no-`qop` property test (100 random cases); URI-fallback rungs |
| `SDPParserTests` | all fixture SDPs; missing `a=control`; duplicate `a=control`; unknown attributes produce no error; `a=Media_header` ignored; static PT 8 with no `rtpmap`; multiple payload types; trailing NUL; bare LF; non-UTF-8 `s=` |
| `ControlURLResolverTests` | all six rows of §8.3 plus: base without trailing slash; base with query; control with its own query; `//host` form; `/absolute-path` form; `*` at both levels |
| `TransportHeaderTests` | all rows of §7.3; `mode` quoted/unquoted; hex `ssrc` both cases; comma list; unknown params |
| `RTPInfoTests` | absolute urls; relative `url=trackID=1`; quoted urls; missing `seq`; `rtptime` > 2³²; url containing `;` in a query |
| `RangeScaleTests` | `npt=now-`, `npt=0-`, `npt=0.000-12.5`, `clock=…-…`, open-ended clock; the four clock/epoch pairs of §8.7; `Scale` serialization for 1, 4, −2, 0.5, 0.25, 16 |
| `SessionMachineTests` | happy path camera (§11.1) driven from the fixture, asserting the **exact** action array; happy path NVR; auth on OPTIONS; `stale` re-auth; 461 → UDP ladder; 404 → probe ladder; 503 backoff classification; keepalive cadence with a fake clock; `.dataIdle` firing; TEARDOWN grace; `connectionClosed` mid-SETUP; command queue overflow; `.fail` is terminal |
| `PlaybackMachineTests` | playback session (§11.3) including the `ANNOUNCE`/`Notice: 2101` exchange and our `200 OK`; seek without PAUSE; `Scale` clamp adoption; `551` → retry without `Require`; backpressure thresholds at 120/60 |
| `HikvisionURLTests` | every row of §10.2 built from `(channel, stream)`; probe-ladder order; playback URL formatting; IPv6; credentials stripped from `requestLineForm`; password never in `description` |

### 18.3 Property tests

1. **Split invariance.** For each `.rtsp` fixture and 200 pseudorandom chunkings (chunk sizes
   1…4096), `RTSPWireDecoder` must produce an identical `[RTSPIncoming]` sequence.
2. **Machine determinism.** The same fixture + seed produces a byte-identical concatenation of
   `.send` payloads and an identical action array, across 100 different chunkings.
3. **No crash on garbage.** 100 000 random byte streams (lengths 1–8192) fed to `ingest` must
   either decode or throw a listed `RTSPError`; never trap, never loop forever. Bound the loop
   with an iteration counter assertion in debug.
4. **Digest formula.** As described in §6.5.
5. **Serializer/parser round trip.** Any `RTSPRequest` built by `RTSPRequestBuilder`, serialized
   and re-parsed by the decoder's request path, yields an equal value.

### 18.4 Fixture-driven synthetic server

`ARCHITECTURE.md` specifies a shared synthetic RTSP server + RTP generator. `VigilRTSP`'s tests
use only its *pure* half: a `ScriptedPeer` that owns a fixture transcript, matches each request
we send against an expected pattern (method + URI + required headers, with digest values checked
by recomputation rather than literal comparison where the fixture allows), and returns the
scripted response bytes with a configurable chunking. `VigilRTSP` must not depend on
`VigilRTP`; the generator's RTP payloads appear here only as opaque bytes.

---

## 19. Cross-module contract summary

Binding requirements this module places on others:

1. **`VigilProtocols` must provide** `MD5` (RFC 1321, streaming, hex helper), a padding-tolerant
   `Base64`, the `VigilFailure` protocol, and `LoggerProtocol`. No `CryptoKit`, no `swift-crypto`.
2. **`VigilTransport` must** write each `.send` / `.sendInterleaved` as one atomic write; support
   independent `pauseReads()`/`resumeReads()` while writes continue; supply `RTSPInstant` from a
   monotonic clock; allocate even/odd UDP port pairs from 51000–51998; implement TLS with
   trust-on-first-use leaf pinning on port 322; and re-drive a fresh machine on
   `.reconnect(to:)`.
3. **`VigilRTP` must** accept `.emitMedia(channel:payload:)` as complete RTP/RTCP packets, use
   `RTSPTrackTiming` (raw `seq`/`rtptime`/`clockRate`, wrap-safe signed differences) to seed
   presentation time, never compare `rtptime` across tracks, honour `spropMaxDONDiff`, and pace
   by RTP timestamps — never by arrival time — whenever `isRateControlDisabled` is true or
   `scale ≠ 1`.
4. **`VigilBitstream` must** accept parameter sets as raw NAL bytes with no start code and no
   length prefix, and must be able to start a stream from in-band SPS/PPS alone (SDP `sprop-*`
   may legitimately be empty).
5. **`VigilCore` must** own reconnect/backoff, must **not** retry `authenticationFailed`,
   `accessForbidden` or `credentialsMissing` (Hikvision locks accounts after ~5 failures), must
   use a ≥ 5 s backoff floor for `deviceOutOfResources`, and must persist the working transport
   rung and `onvifReplaySupported` per camera.
6. **Everyone:** RTSP credentials never appear in a URL on the wire or in any log; use
   `RTSPURL.requestLineForm` / `description`.
