# Vigil — VigilISAPI Specification (Hikvision ISAPI Control Plane)

Status: normative. Version 1.0. Target module: **VigilISAPI**.
Everything in this document is a decision, not a suggestion. Implementers must not deviate
without changing this document first.

---

## Table of contents

1. [Scope, module boundaries, dependencies](#1-scope-module-boundaries-dependencies)
2. [Linux/macOS layering and file guards](#2-linuxmacos-layering-and-file-guards)
3. [Addressing, endpoints, credentials](#3-addressing-endpoints-credentials)
4. [The HTTP client](#4-the-http-client-isapiclient)
5. [Digest authentication](#5-digest-authentication)
6. [TLS, self-signed certificates, plain HTTP](#6-tls-self-signed-certificates-plain-http)
7. [The lenient XML decoder](#7-the-lenient-xml-decoder)
8. [The XML builder](#8-the-xml-builder)
9. [Error model and user-facing mapping](#9-error-model-and-user-facing-mapping)
10. [Device identity and capability](#10-device-identity-and-capability)
11. [Channel inventory](#11-channel-inventory)
12. [Streaming configuration, RTSP mapping, JPEG snapshots](#12-streaming-configuration-rtsp-mapping-jpeg-snapshots)
13. [PTZ control](#13-ptz-control)
14. [Events: the alert stream](#14-events-the-alert-stream)
15. [Recorded video: search, tracks, storage, timeline](#15-recorded-video-search-tracks-storage-timeline)
16. [Two-way audio](#16-two-way-audio)
17. [Image settings, reboot, users](#17-image-settings-reboot-users)
18. [The device session actor: caching and capability resolution](#18-the-device-session-actor)
19. [Firmware quirks matrix](#19-firmware-quirks-matrix)
20. [Testing](#20-testing)
21. [Appendix A — endpoint index](#appendix-a--endpoint-index)
22. [Appendix B — public API summary](#appendix-b--public-api-summary)

---

## 1. Scope, module boundaries, dependencies

`VigilISAPI` is the **control plane**: everything Vigil learns about a device, and everything
Vigil commands a device to do, that is not carried over RTSP/RTP. It owns:

* the HTTP client (including Digest auth, connection lanes, per-device concurrency limits),
* a lenient XML reader and a small XML writer,
* one typed request builder + response model per endpoint,
* the multipart `alertStream` parser,
* the ISAPI error taxonomy and its user-facing mapping,
* the per-device capability probe and quirk resolution.

It does **not** own: RTSP/RTP (that is `VigilRTSP`/`VigilRTP`), device discovery
(`VigilDiscovery`), Keychain storage (`VigilCore`), UI strings (`VigilUI`).

### Dependency graph

```
VigilProtocols  ──▶ VigilISAPI ──▶ VigilCore ──▶ VigilUI ──▶ Vigil
                        │
                        └── (produces PlaybackLocator, StreamPath) consumed by VigilRTSP/VigilCore
```

`VigilISAPI` imports **only**: `Foundation`, `FoundationNetworking` (Linux), `FoundationXML`
(Linux), and `VigilProtocols`. It must never import `Security`, `AppKit`, `SwiftUI`,
`CoreMedia`, `Network`, or `OSLog`.

### What VigilISAPI takes from VigilProtocols

| Symbol | Used for |
| --- | --- |
| `MD5` (`static func digest(_ bytes: [UInt8]) -> [UInt8]`, `func hexString`) | Digest auth. Shared with `VigilRTSP`; implemented once, in `VigilProtocols`. |
| `ByteReader` / `ByteWriter` | multipart scanning, audio chunk framing |
| `VigilLogger` protocol (`log(_ level:, _ category:, _ message: @autoclosure () -> String)`) | all logging; no `OSLog` import |
| `VigilClock` protocol (`var now: Date`, `func sleep(for:) async throws`) | backoff, TTLs, deterministic tests |
| `MediaTimestamp` | playback segment time math at the boundary |
| `Redaction.mask(_:)` | password / session-id / serial masking in logs |

> **Cross-cutting requirement:** `VigilProtocols` must expose MD5 publicly (`public enum MD5`).
> `VigilRTSP` needs the identical primitive; do not duplicate it.

---

## 2. Linux/macOS layering and file guards

`VigilISAPI` is a **platform-independent** target and is compiled and unit-tested on
Linux Swift 6.1 in CI. Three portability facts drive concrete decisions:

1. **`URLSession` lives in `FoundationNetworking` on Linux.** Every file that touches
   `URLSession`, `URLRequest`, `HTTPURLResponse` starts with:

   ```swift
   import Foundation
   #if canImport(FoundationNetworking)
   import FoundationNetworking
   #endif
   ```

2. **`XMLParser` lives in `FoundationXML` on Linux.** Every file that touches `XMLParser`
   starts with:

   ```swift
   import Foundation
   #if canImport(FoundationXML)
   import FoundationXML
   #endif
   ```

3. **`URLAuthenticationChallenge.protectionSpace.serverTrust` is `SecTrust?` and does not
   exist on Linux corelibs.** Therefore server-trust evaluation is *not* performed inside
   `VigilISAPI`. `VigilISAPI` declares the protocol; the macOS side injects the
   implementation.

   ```swift
   /// Injected server-trust policy. Implemented in VigilCore (macOS) where `Security` is
   /// available; on Linux the only shipped conformance is `.plainHTTPOnly`, used by tests.
   public protocol ServerTrustEvaluating: Sendable {
       /// Called once per TLS handshake. `chainDER` is leaf-first.
       /// Returns `.trust` to proceed, `.reject(reason)` to fail the task.
       func evaluate(host: String, port: Int, chainDER: [Data]) -> ServerTrustDecision
   }

   public enum ServerTrustDecision: Sendable, Equatable {
       case trust
       case reject(String)
   }
   ```

   The concrete `URLSessionDelegate` inside `VigilISAPI` extracts the DER chain behind
   `#if canImport(Security)` and hands it to the evaluator; the whole block compiles out on
   Linux, where `https://` endpoints are rejected up front with
   `ISAPIError.tlsUnavailableOnThisPlatform`.

4. **Do not use `URLSession.data(for:delegate:)`.** The `delegate:` overload is not reliably
   present in swift-corelibs-foundation. All requests go through our own continuation bridge
   (§4.6), which also gives us precise `Task` cancellation.

5. **No `Synchronization.Mutex`** (macOS 15+ only; our floor is macOS 14). Delegate state is
   guarded by `NSLock` and a serial `OperationQueue`.

---

## 3. Addressing, endpoints, credentials

```swift
public struct ISAPIEndpoint: Sendable, Hashable, Codable {
    public var host: String          // IPv4 literal, IPv6 literal (no brackets), or DNS name
    public var port: Int             // default 80 (http) / 443 (https)
    public var useTLS: Bool
    /// Path prefix. Almost always "/ISAPI". Devices behind a reverse proxy may need
    /// a prefix such as "/cam1/ISAPI"; the field exists so we never string-concatenate blindly.
    public var pathPrefix: String    // default "/ISAPI"

    public init(host: String, port: Int = 80, useTLS: Bool = false, pathPrefix: String = "/ISAPI")

    /// Builds an absolute URL. `resource` is written WITHOUT the "/ISAPI" prefix,
    /// e.g. "/System/deviceInfo". Query items are percent-encoded per RFC 3986
    /// with `+` encoded as %2B (Hikvision does not decode `+` as space).
    public func url(_ resource: String, query: [URLQueryItem] = []) throws -> URL
}

public struct ISAPICredential: Sendable, Hashable {
    public var username: String
    public var password: String
    public init(username: String, password: String)
}
```

`ISAPICredential` **must not** be `Codable`, must not appear in `description`, and must
override `CustomStringConvertible` to print `ISAPICredential(user: adm***, password: ***)`.
`VigilCore` loads it from the Keychain per request set; `VigilISAPI` never persists it.

IPv6 hosts are bracketed exactly once inside `url(_:query:)`; `host` is stored unbracketed.

---

## 4. The HTTP client (`ISAPIClient`)

```swift
public actor ISAPIClient {
    public struct Configuration: Sendable {
        /// Max simultaneous *control* requests to one device. Hikvision devices run a small
        /// HTTP worker pool; more than 4 concurrent ISAPI requests reliably produces 503 /
        /// `deviceBusy` and, on 5.4.x firmware, can stall the RTSP service for seconds.
        public var maxConcurrentControlRequests: Int = 3
        /// Max simultaneous snapshot requests (separate lane, see §4.2).
        public var maxConcurrentSnapshotRequests: Int = 2
        public var connectTimeout: TimeInterval = 4.0
        public var controlTimeout: TimeInterval = 8.0
        public var searchTimeout: TimeInterval = 15.0
        public var snapshotTimeout: TimeInterval = 6.0
        /// Idle (between-bytes) timeout for long-lived streams. Doubles as stall detection.
        public var streamIdleTimeout: TimeInterval = 30.0
        public var userAgent: String = "Vigil/1.0 (macOS)"
        /// Retry policy for idempotent GETs only.
        public var maxTransientRetries: Int = 2
        public var allowBasicFallbackOverTLS: Bool = true
        public init() {}
    }

    public init(endpoint: ISAPIEndpoint,
                credential: ISAPICredential,
                configuration: Configuration = .init(),
                transport: any ISAPIHTTPTransporting,
                trustEvaluator: any ServerTrustEvaluating,
                clock: any VigilClock,
                logger: any VigilLogger)

    // MARK: Core verbs
    public func get(_ resource: String, query: [URLQueryItem] = [],
                    lane: Lane = .control) async throws -> ISAPIResponse
    public func put(_ resource: String, query: [URLQueryItem] = [],
                    body: Data?, contentType: String = "application/xml",
                    lane: Lane = .control) async throws -> ISAPIResponse
    public func post(_ resource: String, query: [URLQueryItem] = [],
                     body: Data?, contentType: String = "application/xml",
                     lane: Lane = .control) async throws -> ISAPIResponse
    public func delete(_ resource: String, query: [URLQueryItem] = [],
                       lane: Lane = .control) async throws -> ISAPIResponse

    // MARK: XML convenience — throws on non-2xx AND on ResponseStatus statusCode != 1
    public func getXML(_ resource: String, query: [URLQueryItem] = [],
                       lane: Lane = .control) async throws -> ISAPIDocument
    public func putXML(_ resource: String, body: XMLBuilder,
                       query: [URLQueryItem] = []) async throws -> ResponseStatus
    public func postXML(_ resource: String, body: XMLBuilder,
                        query: [URLQueryItem] = [],
                        lane: Lane = .control) async throws -> ISAPIDocument

    // MARK: Streams
    /// Long-lived byte stream (alertStream, two-way audio download). Never buffers
    /// more than `chunkLimit` bytes; the returned stream is back-pressured.
    public func byteStream(_ resource: String, method: String = "GET",
                           query: [URLQueryItem] = [],
                           headers: [String: String] = [:])
        async throws -> (headers: HTTPHeaders, bytes: AsyncThrowingStream<Data, Error>)

    /// Chunked upload with a caller-driven body (two-way audio push).
    public func chunkedUpload(_ resource: String,
                              contentType: String) async throws -> ISAPIChunkedUpload

    public enum Lane: Sendable { case control, snapshot, stream, audio }
}

public struct ISAPIResponse: Sendable {
    public let statusCode: Int
    public let headers: HTTPHeaders          // case-insensitive dictionary
    public let body: Data
    public var contentType: String? { headers["Content-Type"] }
}
```

### 4.1 Transport protocol (test seam)

```swift
public protocol ISAPIHTTPTransporting: Sendable {
    func perform(_ request: ISAPIRawRequest) async throws -> ISAPIResponse
    func stream(_ request: ISAPIRawRequest) async throws
        -> (Int, HTTPHeaders, AsyncThrowingStream<Data, Error>)
    func upload(_ request: ISAPIRawRequest) async throws -> ISAPIUploadHandle
}

public struct ISAPIRawRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval
    public var lane: ISAPIClient.Lane
}
```

Two shipped conformances:

| Type | Where | Purpose |
| --- | --- | --- |
| `URLSessionTransport` | VigilISAPI | production; four `URLSession`s (one per lane) |
| `FixtureTransport` | VigilISAPITests | replays recorded request/response pairs; Linux CI |

### 4.2 URLSession lane matrix

Four sessions per device session, created lazily, all with
`URLSessionConfiguration.ephemeral` (no disk cache, no cookie persistence — Hikvision sets a
`WebSession` cookie we must not reuse across credential changes).

| Lane | `httpMaximumConnectionsPerHost` | `timeoutIntervalForRequest` | `timeoutIntervalForResource` | Notes |
| --- | --- | --- | --- | --- |
| `.control` | 3 | 8 s (15 s for search) | 30 s | `waitsForConnectivity = false` |
| `.snapshot` | 2 | 6 s | 8 s | `networkServiceType = .responsiveData` |
| `.stream` | 1 | 30 s (idle) | 0 (∞) | alertStream, audio download |
| `.audio` | 1 | 30 s (idle) | 0 (∞) | chunked upload |

Common settings for all lanes:

```swift
cfg.requestCachePolicy        = .reloadIgnoringLocalCacheData
cfg.urlCache                  = nil
cfg.httpCookieAcceptPolicy    = .never
cfg.httpShouldUsePipelining   = false      // Hikvision mis-handles pipelined GETs
cfg.httpAdditionalHeaders     = ["User-Agent": configuration.userAgent,
                                 "Accept": "*/*",
                                 "Connection": "keep-alive"]
cfg.allowsCellularAccess      = false      // LAN only
cfg.allowsExpensiveNetworkAccess = false
cfg.allowsConstrainedNetworkAccess = false
cfg.tlsMinimumSupportedProtocolVersion = .TLSv12
```

Connection reuse is essential: with keep-alive plus pre-emptive Digest, a snapshot GET costs
one round trip (~12 ms LAN). Without it, three (TCP + 401 + 200).

### 4.3 Concurrency limiter

A counting semaphore per lane implemented as an actor-internal FIFO of continuations —
never `DispatchSemaphore` (it blocks a cooperative thread and deadlocks under Swift 6).

```swift
actor RequestGate {
    private let limit: Int
    private var inFlight = 0
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var order: [UUID] = []

    func acquire() async throws { /* FIFO; supports cancellation by removing the waiter */ }
    func release() { /* resume the head waiter */ }
}
```

Cancellation: `acquire()` is wrapped in `withTaskCancellationHandler`; a cancelled waiter is
removed from `order` and resumed with `CancellationError()`.

**Priority inversion guard:** the `.snapshot` lane is separate precisely so a burst of 16 grid
thumbnails cannot starve a PTZ command. PTZ, and only PTZ, may additionally *bypass* the gate
when `inFlight < limit + 1` — a documented over-subscription of one slot, because a dropped
PTZ stop command leaves a camera spinning. This is the single exception; nothing else bypasses.

### 4.4 Request coalescing

Identical concurrent **GET**s (same lane, method, path, query) share one underlying task.
Keyed by `"\(lane)|\(method)|\(url.absoluteString)"`. Coalescing is disabled for
`.stream`/`.audio` lanes and for all PUT/POST/DELETE.

### 4.5 Timeouts and cancellation

* Every public method honours `Task.isCancelled` before acquiring the gate and installs a
  `withTaskCancellationHandler` that calls `URLSessionTask.cancel()`.
* A cancelled `URLSessionTask` surfaces as `URLError.cancelled`; the bridge translates it to
  `CancellationError()` so callers never see a `URLError` for their own cancellation.
* Per-request timeout overrides the lane default via `ISAPIRawRequest.timeout`.
* **PTZ continuous commands get `controlTimeout = 2.0 s`.** A stop command that takes longer
  than 2 s is worse than useless; the caller re-sends.

### 4.6 The continuation bridge

```swift
final class URLSessionTransport: NSObject, ISAPIHTTPTransporting,
                                 URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var dataTasks: [Int: DataTaskState] = [:]      // keyed by taskIdentifier
    private var streamTasks: [Int: StreamTaskState] = [:]
    private let queue: OperationQueue                      // maxConcurrentOperationCount = 1
}
```

* Unary requests: `urlSession(_:dataTask:didReceive:)` accumulates into a `Data` capped at
  **8 MiB** (`ISAPIError.responseTooLarge` beyond that — no ISAPI response is legitimately
  larger; `/System/capabilities` peaks around 90 KiB, a 4K JPEG snapshot around 1.5 MiB).
* Streaming requests: `didReceive data:` yields into an `AsyncThrowingStream` created with
  `.bufferingPolicy(.bufferingNewest(64))`. When the continuation reports
  `.terminated`/`.dropped`, the task is cancelled — that is our back-pressure signal.
* `urlSession(_:task:didCompleteWithError:)` resumes / finishes exactly once, guarded by
  removing the state from the dictionary under `lock`.

### 4.7 Retry rules

Retries apply to **idempotent** requests only: all `GET`s, plus `PUT /PTZCtrl/.../continuous`
with an all-zero (stop) body.

| Condition | Action |
| --- | --- |
| `URLError.timedOut`, `.networkConnectionLost`, `.cannotConnectToHost` | retry after 250 ms, 750 ms (max 2) |
| HTTP 503, or `subStatusCode == deviceBusy` | retry after 400 ms, 1200 ms (max 2) |
| HTTP 401 with a *new* nonce or `stale="TRUE"` | re-auth once, does not count as a retry |
| HTTP 401 twice with the same nonce | fail `authenticationFailed`, **no further retries** |
| HTTP 403 / `notSupport` | never retry; record a negative capability (§18.3) |
| Anything else 4xx | never retry |

**Account-lockout safety:** Hikvision locks a user after 5 failed authentications (default
lock 30 min). The client keeps a per-(host, username) failure counter; after **2** consecutive
authentication failures it enters `authBlocked` and refuses further requests until
`VigilCore` supplies a new credential. This rule is absolute and applies across all lanes.

---

## 5. Digest authentication

We implement Digest ourselves instead of using `URLCredential` +
`urlSession(_:didReceive:completionHandler:)`. Reasons:

1. **Pre-emptive authentication.** URLSession will not send an `Authorization` header until
   challenged. For the snapshot fast path (target ≤120 ms) and for the 1 Hz thumbnail poll,
   the extra 401 round trip is 30–40% of the budget.
2. **Streamed bodies cannot be replayed.** `uploadTask(withStreamedRequest:)` has no body to
   re-send after a 401, so the two-way-audio POST *must* carry a valid `Authorization` header
   on the first attempt. This is not optional.
3. `URLCredentialStorage` behaviour differs on swift-corelibs-foundation; our Linux tests
   would not exercise the production path.
4. We need visibility into `nonce`, `nc`, and `stale` for diagnostics (Stream Doctor).

### 5.1 Challenge model

```swift
public struct DigestChallenge: Sendable, Hashable {
    public var realm: String
    public var nonce: String
    public var opaque: String?
    public var qop: [String]          // e.g. ["auth"]; empty means RFC 2069 no-qop mode
    public var algorithm: Algorithm   // .md5, .md5sess, .unsupported(String)
    public var stale: Bool
    public var domain: [String]

    public enum Algorithm: Sendable, Hashable { case md5, md5sess, unsupported(String) }
}
```

Hikvision sends, verbatim, on both HTTP and RTSP:

```
WWW-Authenticate: Digest realm="IP Camera(51253)", nonce="4e5a4f5a5a...", stale="FALSE"
```

Note: no `qop`, no `algorithm`, no `opaque` on many 5.2–5.5 firmwares — the **RFC 2069
no-qop variant is the common case** and must be implemented first-class, not as a fallback
afterthought. Newer 5.7+/6.x firmware adds `qop="auth"`.

Header parsing rules:
* Comma-separated `name=value`, values optionally double-quoted; whitespace tolerated.
* `stale` is compared case-insensitively against `"true"`.
* Multiple `WWW-Authenticate` headers may appear (Digest + Basic). Prefer Digest.
* `algorithm=MD5-sess` → `.md5sess`. `SHA-256`/`SHA-256-sess` → `.unsupported`.

### 5.2 Response computation

Let `H(x) = MD5(x).hexStringLowercase` and `KD(s, d) = H(s + ":" + d)`.

```
A1 (MD5)      = username ":" realm ":" password
A1 (MD5-sess) = H(username ":" realm ":" password) ":" nonce ":" cnonce
A2            = method ":" digestURI
```

`digestURI` is the **request URI exactly as written on the request line**: path plus query,
percent-encoded, no scheme/host. For
`GET /ISAPI/Streaming/channels/101/picture?videoResolutionWidth=640` the `digestURI` is
`/ISAPI/Streaming/channels/101/picture?videoResolutionWidth=640`. Getting this wrong is the
single most common cause of a permanent 401.

```
with qop:    response = KD(H(A1), nonce ":" nc ":" cnonce ":" qop ":" H(A2))
without qop: response = KD(H(A1), nonce ":" H(A2))
```

* `nc` is 8 lowercase hex digits, starting at `00000001`, incremented **per request** per
  (realm, nonce). Never reused. On overflow (unreachable in practice) force re-challenge.
* `cnonce` is 16 random hex characters from `SystemRandomNumberGenerator`. New per request.
* Emitted header (order matters for at least one 5.1.x firmware; use exactly this order):

```
Authorization: Digest username="admin", realm="IP Camera(51253)",
  nonce="4e5a...", uri="/ISAPI/System/deviceInfo", response="6629fae4...",
  qop=auth, nc=00000001, cnonce="0a4f113b", opaque="..."
```

Emit `qop=auth` **unquoted** (RFC 7616 says unquoted; Hikvision accepts both, some proxies do
not). Omit `qop`, `nc`, `cnonce` entirely in no-qop mode. Omit `opaque` if absent from the
challenge. `algorithm=MD5` is omitted (default) unless the challenge specified `MD5-sess`,
in which case emit `algorithm=MD5-sess`.

### 5.3 Challenge cache and pre-emptive auth

```swift
actor DigestStore {
    /// Keyed by realm. Devices use exactly one realm.
    func header(for method: String, uri: String,
                credential: ISAPICredential) -> String?   // nil ⇒ send unauthenticated
    func absorb(_ challenge: DigestChallenge)
    func invalidate(reason: InvalidationReason)
}
```

Flow:
1. First request to a device is sent **without** `Authorization` (we do not know the realm).
2. On 401, parse the challenge, store it, resend the identical request with `nc = 1`.
3. Every subsequent request pre-computes the header from the cached challenge with the next
   `nc`. No 401 is expected.
4. On a 401 despite a cached challenge: if the returned nonce differs or `stale="TRUE"`,
   replace the challenge and resend once (this is *not* an auth failure). If the nonce is
   identical, the credential is wrong → `authenticationFailed`.
5. `Authentication-Info: nextnonce="..."` is honoured when present (rare, but 6.x sends it).

### 5.4 Basic auth

Used only when: (a) the challenge advertises Basic and no Digest, or (b) the Digest algorithm
is `.unsupported` **and** `useTLS == true` **and** `allowBasicFallbackOverTLS`. Over plain
HTTP with an unsupported Digest algorithm we fail with
`ISAPIError.unsupportedAuthentication(algorithm)` and a user-facing instruction to enable
HTTPS or Digest on the device. Never silently send Basic over cleartext.

`Authorization: Basic ` + base64(`username:password`), ASCII only. If either field is
non-ASCII, encode UTF-8 and log a warning (Hikvision truncates non-ASCII passwords).

---

## 6. TLS, self-signed certificates, plain HTTP

* **Plain HTTP on the LAN is the default and is fully supported.** The app's `Info.plist`
  carries `NSAppTransportSecurity → NSAllowsLocalNetworking = true` (owned by the
  architecture doc); `VigilISAPI` assumes it is present and does not work around ATS.
* **HTTPS with a self-signed certificate is the normal case for Hikvision.** Devices ship a
  self-signed leaf with CN equal to the device serial, no SAN, and a 10-year validity.
  Standard evaluation always fails.
* Policy: **trust on first use (TOFU), pinned by SPKI SHA-256.**
  * First successful handshake: compute SHA-256 over the leaf certificate's
    `subjectPublicKeyInfo` DER and hand it to `ServerTrustEvaluating`, which stores it in the
    camera record (`Camera.tlsPinSPKI256: Data?`, owned by `VigilCore`).
  * Later handshakes: mismatch ⇒ `.reject("certificate changed")` ⇒
    `ISAPIError.tlsPinMismatch`. The UI must present this as a security warning with an
    explicit "trust the new certificate" action; it is never auto-accepted.
  * Hostname mismatch, expiry, and missing SAN are **ignored** when a pin matches. This is a
    deliberate, documented decision for LAN devices.
* `SecTrustEvaluateWithError` is *not* used to gate the connection; it is called only to
  populate diagnostics (`chainSummary` string in the diagnostics bundle).
* `rtsps` (RTSP over TLS, port 322) is out of scope here; `VigilRTSP` owns it but must reuse
  the same pin from the camera record.

---

## 7. The lenient XML decoder

### 7.1 Why not Codable

| Reason | Detail |
| --- | --- |
| No XML Codable in Foundation | There is no `XMLDecoder`. We would have to write a full `Decoder` anyway — strictly more code than a path-keyed reader, with worse errors. |
| `XMLDocument`/XPath is not portable | On Linux it lives in `FoundationXML` and its XPath support is libxml2-dependent and historically flaky. `XMLParser` (SAX) is the only reliably portable API, and it is what we use. |
| Firmware casing varies | The *same* logical field appears as `<SharpnessLevel>` and `<sharpnessLevel>`; `<MotionDetectionLayout>` vs `<motionDetectionLayout>`; `<PTZChanelCap>` (sic) vs `<PTZChannelCap>`. `CodingKeys` cannot express "either of these". |
| Cardinality varies | Some firmwares emit a single `<TimeBlock>` where others emit a list; some emit `<hddList size="1">`, others omit `size`. Codable's `[T]` vs `T` decision must be made at compile time; ours is made at read time. |
| Unknown elements | New firmware adds elements constantly. Strict decoding fails; we must ignore additions. |
| Namespaces | `xmlns="http://www.hikvision.com/ver20/XMLSchema"` vs `ver10`, sometimes with an `hik:` prefix. We are namespace-agnostic by design. |
| Diagnostics | A path-keyed reader can say *"missing Video/videoResolutionWidth in StreamingChannel; present keys: video, audio, transport"*. `DecodingError` cannot, because the document is gone by then. |

We keep the parsed tree so error messages can enumerate siblings, and so read-modify-write
PUTs (§17.1) can round-trip unknown elements untouched.

### 7.2 The tree

```swift
public struct XMLNode: Sendable, Hashable {
    /// Local name with original casing, namespace prefix stripped. e.g. "videoResolutionWidth".
    public let name: String
    /// `name.lowercased()`; the matching key. Precomputed once.
    public let key: String
    /// Attribute names are also lowercased-keyed; values verbatim.
    public let attributes: [String: String]
    /// Concatenated character data, whitespace-trimmed at the ends, interior preserved.
    /// CDATA is merged in. Empty string when the element has only children.
    public let text: String
    public let children: [XMLNode]

    public subscript(_ path: String) -> XMLValue { get }
    public func node(_ path: String) -> XMLNode?
    public func nodes(_ path: String) -> [XMLNode]
    /// Serializes this subtree back to XML, preserving unknown elements and attributes.
    public func serialized(declaration: Bool = true) -> Data
    /// Returns a copy with the value at `path` replaced (creating intermediate
    /// elements only if `createIfMissing`). Used for read-modify-write PUTs.
    public func setting(_ path: String, to value: String,
                        createIfMissing: Bool = false) -> XMLNode
}

public struct ISAPIDocument: Sendable {
    public let root: XMLNode
    /// Parsed with a hard 8 MiB input cap and a 64-level depth cap.
    public init(parsing data: Data) throws
    public var rootName: String { root.name }

    public subscript(_ path: String) -> XMLValue { root[path] }
    public func node(_ path: String) -> XMLNode? { root.node(path) }
    public func nodes(_ path: String) -> [XMLNode] { root.nodes(path) }
}
```

### 7.3 Path grammar

Paths are relative to the receiving node (for `ISAPIDocument`, relative to the root's
children — the root element name itself is **not** part of the path).

| Syntax | Meaning |
| --- | --- |
| `Video/videoCodecType` | direct child chain, case-insensitive |
| `a|b|c` at any segment | first alternative that matches, left to right: `Sharpness/SharpnessLevel|sharpnessLevel` |
| `*` | exactly one level, any name |
| `**` | zero or more levels (descendant search, breadth-first, first match wins) |
| `[n]` | zero-based index among same-named siblings: `matchList/searchMatchItem[3]` |
| `[]` | all same-named siblings — only meaningful with `nodes(_:)` |
| `@attr` | attribute of the addressed element: `hddList@size` |
| `.` | the receiving node itself |

Whole-path alternation is also allowed: `"MotionDetection/enabled || enabled"` (double pipe,
tried as complete paths in order). This is how we absorb firmwares that hoist or nest an
element differently.

Implementation: paths are compiled once into `[PathSegment]` and memoized in a
`static let` table keyed by the literal string, because the same ~200 paths are used
repeatedly. Matching is allocation-free on the happy path.

### 7.4 Typed values

```swift
public struct XMLValue: Sendable {
    public let node: XMLNode?
    public let path: String            // for error messages
    public let parent: XMLNode?        // for sibling enumeration in errors

    public var exists: Bool { node != nil }
    public var string: String?         // nil when absent OR empty
    public var int: Int?               // trims, tolerates leading '+', ignores trailing units
    public var double: Double?         // accepts "1,5" (comma decimal) → 1.5
    public var bool: Bool?             // see table below
    public var date: Date?             // see §7.5
    public var hexData: Data?          // even-length hex, whitespace stripped
    public var base64Data: Data?
    public var uuidString: String?     // strips surrounding {} braces

    // Throwing variants used wherever a missing value is a hard error.
    public func requiredString() throws -> String
    public func requiredInt() throws -> Int
    public func requiredBool() throws -> Bool
    public func requiredDate() throws -> Date

    // Defaulting helpers used for optional/firmware-variant fields.
    public func int(or fallback: Int) -> Int
    public func bool(or fallback: Bool) -> Bool
    public func string(or fallback: String) -> String
    /// Clamped integer read, for device fields that occasionally return out-of-range junk.
    public func int(clampedTo range: ClosedRange<Int>, or fallback: Int) -> Int
}
```

Boolean leniency (case-insensitive, after trimming):

| Accepted as `true` | Accepted as `false` |
| --- | --- |
| `true`, `1`, `yes`, `on`, `enable`, `enabled`, `open` | `false`, `0`, `no`, `off`, `disable`, `disabled`, `close` |

Anything else ⇒ `nil` (and `requiredBool()` throws `.malformedValue`).

Thrown errors:

```swift
public enum XMLReadError: Error, Sendable, CustomStringConvertible {
    case missing(path: String, in: String, siblings: [String])
    case malformedValue(path: String, raw: String, expected: String)
    case parseFailure(line: Int, column: Int, message: String)
    case tooLarge(bytes: Int)
    case tooDeep(depth: Int)
    case notXML(contentType: String?, firstBytes: String)   // e.g. an HTML login page
}
```

`.notXML` matters: a device with web-auth misconfigured returns an HTML login page with
HTTP 200. We detect a body whose first non-whitespace byte is not `<` **or** whose root
element is `html`, and surface `.notXML` rather than a confusing "missing element".

### 7.5 Date and time parsing

ISAPI emits at least these forms. All are accepted; parsing is tried in this order.

| Form | Example | Interpretation |
| --- | --- | --- |
| ISO 8601 with offset | `2024-05-01T12:34:56+08:00` | absolute |
| ISO 8601 UTC | `2024-05-01T04:34:56Z` | absolute |
| ISO 8601 naive | `2024-05-01T12:34:56` | device-local; converted using the cached `/System/time` offset. If unknown, treated as UTC and flagged `dateAssumedUTC` in the model. |
| Compact UTC (playback query form) | `20240501T043456Z` | absolute |
| Compact naive | `20240501T123456` | device-local, as above |
| Fractional seconds | `2024-05-01T12:34:56.789+08:00` | absolute, ms preserved |

Implementation: a hand-rolled fixed-width scanner over ASCII bytes, **not** `DateFormatter`
(which is ~40× slower and locale-sensitive) and **not** `ISO8601DateFormatter` (rejects the
compact form and naive form). One `Calendar`/`TimeZone`-free computation using
`timeIntervalSince1970` arithmetic with a days-from-civil algorithm; unit-tested against a
table of 40 vectors including leap days.

Emission helpers:

```swift
public enum ISAPITime {
    /// "2024-05-01T04:34:56Z" — used in CMSearchDescription bodies.
    public static func iso8601UTC(_ date: Date) -> String
    /// "20240501T043456Z" — used in RTSP playback query strings.
    public static func compactUTC(_ date: Date) -> String
    /// Parses the Hikvision POSIX-inverted timezone string, e.g. "CST-8:00:00" ⇒ +28800 s.
    public static func parseTimeZone(_ raw: String) -> Int?
}
```

> **`timeZone` gotcha:** `/ISAPI/System/time` returns strings like `CST-8:00:00`. The sign is
> POSIX-inverted: `-8` means **UTC+8**. `parseTimeZone` negates it. Format is
> `<abbrev><±><h>:<mm>:<ss>`, hours may be 1 or 2 digits.

### 7.6 Parser implementation notes

* `XMLParser` with `shouldProcessNamespaces = false` and `shouldReportNamespacePrefixes =
  false`; we strip anything before the first `:` in `didStartElement` ourselves. This is
  cheaper and immune to malformed namespace declarations, which occur.
* `externalEntityResolvingPolicy = .never` and `shouldResolveExternalEntities = false` —
  XXE defence, mandatory.
* Delegate builds nodes on an explicit stack of `(name, attributes, textBuffer, children)`;
  no recursion, so the 64-level depth cap is enforced by counting, not by stack overflow.
* Character data arrives in fragments; append to a `String` reservoir per stack frame,
  trimming only at `didEndElement`.
* `parserErrorOccurred` maps to `.parseFailure` with `parser.lineNumber` /
  `parser.columnNumber`.
* **Truncated-document tolerance:** if parsing fails *after* the root element closed
  (trailing garbage — some firmware appends a stray NUL), we keep the tree and log a warning.
  If it fails before, we throw.
* Byte-order marks and a leading `<?xml ... ?>` with `encoding="utf-8"`, `"UTF-8"`, or
  `"gb2312"` are handled: for `gb2312`/`gbk` we transcode via
  `String(data:encoding:)` with `.init(rawValue: 0x0632)` (CFStringEncoding GB_18030_2000)
  on macOS, and on Linux fall back to a Latin-1 read plus a `nonUTF8Payload` warning flag —
  affected fields are only free-text names, which the UI then shows with a "?" placeholder.

---

## 8. The XML builder

Request bodies are built with an explicit, ordered builder. **Element order matters** to
Hikvision's XML validator on several firmwares (notably `<PTZData>` and
`<CMSearchDescription>`), so we never rely on dictionary ordering.

```swift
public struct XMLBuilder: Sendable {
    public init(_ root: String, attributes: [(String, String)] = [])
    public mutating func add(_ name: String, _ value: String)
    public mutating func add(_ name: String, _ value: Int)
    public mutating func add(_ name: String, _ value: Bool)          // emits "true"/"false"
    public mutating func addChild(_ name: String, attributes: [(String, String)] = [],
                                 _ build: (inout XMLBuilder) -> Void)
    public mutating func addRaw(_ xmlFragment: String)               // pre-escaped, tests only
    public func data() -> Data                                      // UTF-8, with declaration
    public var stringValue: String { get }
}
```

* Always emits `<?xml version="1.0" encoding="UTF-8"?>` followed by a newline. Some 5.2.x
  firmwares reject a body without the declaration with `invalidXMLFormat`.
* Text is escaped for `& < > " '` only. No pretty-printing, no indentation (smaller bodies,
  and one firmware chokes on indented `<PTZData>`).
* **Namespace policy:**
  * For *constructed* bodies (`PTZData`, `CMSearchDescription`, `TwoWayAudioChannel`) emit
    **no** `xmlns` and **no** `version` attribute. Verified accepted on 5.2.x–6.x.
  * For *read-modify-write* bodies (§17.1) echo back the `version` and `xmlns` attributes
    exactly as received on the GET.

---

## 9. Error model and user-facing mapping

### 9.1 `ResponseStatus`

Nearly every non-GET returns this document (HTTP 200 on success, 4xx/5xx on failure — but
**not consistently**; some firmwares return HTTP 200 with `statusCode != 1`, so the body must
always be inspected).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ResponseStatus version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <requestURL>/ISAPI/PTZCtrl/channels/1/continuous</requestURL>
  <statusCode>4</statusCode>
  <statusString>Invalid Operation</statusString>
  <subStatusCode>notSupport</subStatusCode>
  <errorCode>1073741830</errorCode>
  <errorMsg>notSupport</errorMsg>
</ResponseStatus>
```

```swift
public struct ResponseStatus: Sendable, Hashable {
    public let requestURL: String?
    public let statusCode: Int          // 1 == OK
    public let statusString: String?
    public let subStatusCode: String?   // lowercased on read
    public let errorCode: Int?          // 32-bit Hikvision internal code
    public let errorMsg: String?
    public var isOK: Bool { statusCode == 1 }

    /// Tolerates <ResponseStatus>, <userCheck>, and bare <statusCode> roots.
    public init?(document: ISAPIDocument)
}
```

`statusCode` enumeration:

| `statusCode` | `statusString` | Meaning |
| --- | --- | --- |
| 1 | OK | success |
| 2 | Device Busy | retry later |
| 3 | Device Error | internal failure |
| 4 | Invalid Operation | not permitted / not supported in current state |
| 5 | Invalid XML Format | our body is syntactically wrong — a bug |
| 6 | Invalid XML Content | our body has bad values |
| 7 | Reboot Required | change accepted, needs reboot |

### 9.2 `ISAPIError`

```swift
public enum ISAPIError: Error, Sendable, Equatable {
    // Transport
    case notConnected(underlying: String)
    case timedOut(resource: String, seconds: TimeInterval)
    case cancelled
    case responseTooLarge(bytes: Int)
    case tlsPinMismatch(host: String)
    case tlsUnavailableOnThisPlatform
    // Auth
    case authenticationFailed(username: String)
    case accountLocked(retryAfter: TimeInterval?, unlockTime: TimeInterval?)
    case authBlockedLocally(failures: Int)
    case unsupportedAuthentication(algorithm: String)
    case insufficientPermission(resource: String)
    case deviceNotActivated
    // Protocol / semantics
    case http(status: Int, resource: String, status2: ResponseStatus?)
    case device(ResponseStatus)
    case notSupported(resource: String)
    case notFound(resource: String)
    case deviceBusy
    case rebootRequired
    case malformedResponse(XMLReadError)
    case unexpectedContentType(expected: String, got: String?)
    // Stream-specific
    case multipartProtocolError(String)
    case streamEnded(afterBytes: Int)
    case partTooLarge(bytes: Int, limit: Int)
}
```

### 9.3 Mapping table (authoritative)

`subStatusCode` values are compared lowercased. Column *Retry* is what the client does
automatically; column *Message key* is the `Localizable.strings` key `VigilUI` must define
(English text shown; Russian is required per FEATURES.md).

| HTTP | subStatusCode | `ISAPIError` | Retry | Message key / English text | Suggested action |
| --- | --- | --- | --- | --- | --- |
| 200 | `ok` | — | — | — | — |
| 401 | `badAuthorization` / absent | `.authenticationFailed` | re-auth once | `err.auth.failed` — "Incorrect username or password." | Open credentials sheet |
| 401 | `incorrectUserNameOrPassword` | `.authenticationFailed` | no | `err.auth.failed` | Open credentials sheet |
| 401 | `userLocked` | `.accountLocked` | no | `err.auth.locked` — "This account is locked by the camera after too many failed sign-ins. It unlocks in %@." | Show countdown, disable retry |
| 401 | `notActivated` | `.deviceNotActivated` | no | `err.device.notActivated` — "This device has not been activated. Set an admin password in the camera's web interface first." | Open `http://host/` |
| 403 | `insufficientPermission` | `.insufficientPermission` | no | `err.auth.permission` — "The account %@ is not allowed to do this. Use an Administrator account." | — |
| 403 | `notSupport` | `.notSupported` | no, cache negative | `err.cap.unsupported` — "This camera does not support %@." | Hide the control |
| 403 | `riskPassword` | `.device` | no | `err.auth.riskPassword` — "The camera reports a weak password and is refusing requests. Change it in the camera's web interface." | — |
| 400 | `badParameters` | `.device` | no | `err.req.badParameters` — "The camera rejected these settings." | Revert UI to last-known |
| 400 | `invalidXMLFormat` / `badXmlFormat` | `.device` | no | `err.internal` — "Vigil sent a malformed request. Please report this." | log full body at debug |
| 400 | `invalidXMLContent` | `.device` | no | `err.req.badParameters` | — |
| 400 | `invalidOperation` | `.device` | no | `err.req.invalidOperation` — "The camera cannot do that right now." | — |
| 404 | `notFound` / absent | `.notFound` | no, cache negative | `err.cap.unsupported` | Hide the control |
| 405 | `methodNotAllowed` | `.notSupported` | no, cache negative | `err.cap.unsupported` | Hide the control |
| 500 | `deviceError` / `dataAbnormal` | `.device` | no | `err.device.error` — "The camera reported an internal error." | Offer reboot |
| 503 | `deviceBusy` | `.deviceBusy` | 2 retries | `err.device.busy` — "The camera is busy. Vigil will try again." | — |
| 503 | `serviceUnavailable` / `upgrading` | `.device` | no | `err.device.upgrading` — "The camera is upgrading its firmware. Try again in a few minutes." | Pause polling 5 min |
| 500 | `noMemory` | `.device` | 1 retry after 2 s | `err.device.busy` | Reduce concurrency to 1 |
| 200 | `rebootRequired` | `.rebootRequired` | no | `warn.rebootRequired` — "Saved. The camera must restart for this to take effect." | Offer reboot |
| — | `ipcOffline` | `.device` | no | `err.nvr.channelOffline` — "The NVR reports this camera as offline." | Show in channel list |

Unknown `subStatusCode` values map to `.device(status)` with
`err.device.unknown` — "The camera reported an error (%d/%@)." carrying `statusCode` and
the raw `subStatusCode`. **Never** discard an unknown code; it goes into the diagnostics
bundle verbatim.

### 9.4 Decision helper

```swift
/// Applied to every response before the typed decode. Throws for anything not OK.
func validate(_ response: ISAPIResponse, resource: String) throws -> ISAPIDocument?
```

Rules, in order:
1. `statusCode == 200...299` **and** body is empty or non-XML content-type ⇒ return `nil`.
2. Body parses as XML ⇒ try `ResponseStatus(document:)`. If present and `!isOK`, map per
   §9.3 **even if the HTTP status was 200**.
3. HTTP status outside 2xx and no parsable `ResponseStatus` ⇒ `.http(status:resource:nil)`.
4. Content-Type is `text/html` ⇒ `.malformedResponse(.notXML(...))`.

---

## 10. Device identity and capability

### 10.1 `GET /ISAPI/System/deviceInfo`

Auth: Digest. Query: none. Cache TTL: **24 h**, invalidated on reboot or credential change.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<DeviceInfo version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <deviceName>Front Door</deviceName>
  <deviceID>48343131-3435-3234-3138-343131343535</deviceID>
  <deviceDescription>IPCamera</deviceDescription>
  <deviceLocation>hangzhou</deviceLocation>
  <systemContact>Hikvision.China</systemContact>
  <model>DS-2CD2385FWD-I</model>
  <serialNumber>DS-2CD2385FWD-I20200114AAWR123456789</serialNumber>
  <macAddress>44:47:cc:11:22:33</macAddress>
  <firmwareVersion>V5.6.3</firmwareVersion>
  <firmwareReleasedDate>build 190923</firmwareReleasedDate>
  <encoderVersion>V7.3</encoderVersion>
  <encoderReleasedDate>build 190103</encoderReleasedDate>
  <bootVersion>V1.3.4</bootVersion>
  <bootReleasedDate>100316</bootReleasedDate>
  <hardwareVersion>0x0</hardwareVersion>
  <deviceType>IPCamera</deviceType>
  <telecontrolID>88</telecontrolID>
  <supportBeep>false</supportBeep>
  <supportVideoLoss>false</supportVideoLoss>
  <firmwareVersionInfo>B-R-G3-0</firmwareVersionInfo>
</DeviceInfo>
```

NVR/DVR variant differs in `<deviceType>DVR</deviceType>` (also seen: `NVR`, `Hybrid DVR`),
`<deviceName>Embedded Net DVR</deviceName>`, and the presence of `<supportVideoLoss>true</…>`.

```swift
public struct DeviceInfo: Sendable, Hashable, Codable {
    public let deviceName: String
    public let deviceID: String?
    public let model: String                 // "DS-2CD2385FWD-I"
    public let serialNumber: String          // redact in logs
    public let macAddress: String?
    public let firmwareVersion: FirmwareVersion
    public let firmwareReleasedDate: String?
    public let hardwareVersion: String?
    public let deviceType: String            // raw
    public let family: DeviceFamily          // derived
    public let supportsBeep: Bool
    public let supportsVideoLoss: Bool

    public init(document: ISAPIDocument) throws
}

public enum DeviceFamily: String, Sendable, Codable {
    case ipCamera, nvr, dvr, hybridDVR, encoder, decoder, doorbell, unknown
}

/// Parses "V5.6.3", "V5.5.82 build 190220", "V4.30.005" into comparable components.
public struct FirmwareVersion: Sendable, Hashable, Codable, Comparable {
    public let major: Int, minor: Int, patch: Int
    public let build: Int?
    public let raw: String
    public static func < (l: Self, r: Self) -> Bool
}
```

Family derivation (first match wins):

| Test | Family |
| --- | --- |
| `deviceType` contains `nvr` | `.nvr` |
| `deviceType` contains `hybrid` | `.hybridDVR` |
| `deviceType` contains `dvr` | `.dvr` |
| `model` starts with `DS-76`, `DS-77`, `DS-78`, `DS-96`, `DS-KH` | `.nvr` |
| `model` starts with `DS-KV`, `DS-KD` | `.doorbell` |
| `deviceType` contains `ipcamera`, `ipdome`, `ipzoom` | `.ipCamera` |
| `deviceType` contains `encoder` | `.encoder` |
| else | `.unknown` (treated as `.ipCamera` for behaviour) |

Errors: `401` → auth; `404` → this is not an ISAPI device (map to
`err.device.notISAPI` — "This device does not speak Hikvision ISAPI." and let
`VigilDiscovery`/ONVIF fallback take over).

### 10.2 `GET /ISAPI/Security/userCheck` — the cheap credential probe

**This is the canonical probe.** It is the cheapest authenticated ISAPI GET (≈200 byte
response), is present on every firmware since 5.1, and is the only endpoint that reports
lock-out state. Use it for: credential validation in the Add-Camera sheet, Stream Doctor
step 3, and the 60 s liveness probe for the alert stream.

Success (HTTP 200):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<userCheck version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <statusValue>200</statusValue>
  <statusString>OK</statusString>
</userCheck>
```

Failure (HTTP 401 — body is still present and is the useful part):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<userCheck version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <statusValue>401</statusValue>
  <statusString>Unauthorized</statusString>
  <isIllegalLogin>true</isIllegalLogin>
  <retryLoginTime>3</retryLoginTime>
  <lockStatus>unlock</lockStatus>
  <unlockTime>0</unlockTime>
</userCheck>
```

Locked (HTTP 401):

```xml
<userCheck version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <statusValue>401</statusValue>
  <statusString>Unauthorized</statusString>
  <isIllegalLogin>true</isIllegalLogin>
  <retryLoginTime>0</retryLoginTime>
  <lockStatus>lock</lockStatus>
  <unlockTime>1737</unlockTime>
</userCheck>
```

| Field | Type | Units | Meaning |
| --- | --- | --- | --- |
| `statusValue` | Int | — | mirrors an HTTP status: 200 OK, 401 unauthorized |
| `isIllegalLogin` | Bool | — | true when the credential was rejected |
| `retryLoginTime` | Int | attempts | **remaining** attempts before lock-out. Counts down 4→3→2→1→0. |
| `lockStatus` | enum | — | `unlock` / `lock` |
| `unlockTime` | Int | seconds | remaining lock duration. Default lock is 1800 s. |

Some 5.4.x devices return `<ResponseStatus>` with `subStatusCode = notActivated` instead;
`UserCheckResult.init` accepts both roots.

```swift
public struct UserCheckResult: Sendable, Hashable {
    public let ok: Bool
    public let remainingAttempts: Int?    // nil when the device does not report it
    public let isLocked: Bool
    public let unlockAfter: TimeInterval? // seconds
    public let notActivated: Bool
    public init(document: ISAPIDocument, httpStatus: Int) throws
}
```

**Hard rule:** when `remainingAttempts <= 1` or `isLocked`, the client sets
`authBlockedLocally` for that (host, username) and refuses all further requests until
`VigilCore` supplies a different credential. Vigil must never be the reason a customer's
camera locks out.

### 10.3 `GET /ISAPI/System/status`

Cache TTL: 5 s (it is the health-poll endpoint). Timeout 4 s.

```xml
<DeviceStatus version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <currentDeviceTime>2024-05-01T12:34:56</currentDeviceTime>
  <deviceUpTime>987654</deviceUpTime>
  <deviceStatus>ok</deviceStatus>
  <CPUList>
    <CPU><cpuDescription>cpu</cpuDescription><cpuUtilization>17</cpuUtilization></CPU>
  </CPUList>
  <MemoryList>
    <Memory>
      <memoryDescription>DDR</memoryDescription>
      <memoryUsage>117.34</memoryUsage>
      <memoryAvailable>72.65</memoryAvailable>
    </Memory>
  </MemoryList>
  <openFileHandles>63</openFileHandles>
</DeviceStatus>
```

NVRs add `<TemperatureList><Temperature><temperature>42</temperature>…` and
`<FanList>`. Memory values are **MB as a decimal string**.

```swift
public struct DeviceStatus: Sendable, Hashable {
    public let currentDeviceTime: Date?
    public let uptime: TimeInterval          // seconds
    public let status: String                 // "ok" | "badStatus" | …
    public let cpuUtilization: [Int]          // percent, one per CPU
    public let memoryUsedMB: Double?
    public let memoryAvailableMB: Double?
    public let temperaturesCelsius: [Double]
    public let openFileHandles: Int?
    public init(document: ISAPIDocument) throws
}
```

`uptime` is our reboot detector: if `uptime` decreases between two polls, every cache for
that device is flushed and `VigilCore` is notified (`DeviceEvent.rebooted`).

### 10.4 `GET /ISAPI/System/time`

```xml
<Time version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <timeMode>NTP</timeMode>
  <localTime>2024-05-01T12:34:56+08:00</localTime>
  <timeZone>CST-8:00:00</timeZone>
</Time>
```

`timeMode`: `NTP` | `manual`. Cache TTL 5 min. The parsed UTC offset is stored on the device
session and used to interpret every naive timestamp the device emits (§7.5).

We also compute `clockSkew = deviceLocalTime − ourNow`. If `|clockSkew| > 60 s`, the UI shows
a warning on the camera row, because playback search and event timestamps will look wrong.
`PUT /ISAPI/System/time` (setting the clock) is **out of scope** — we never write device time.

```swift
public struct DeviceTime: Sendable, Hashable {
    public let mode: String
    public let localTime: Date
    public let utcOffsetSeconds: Int
    public let rawTimeZone: String
    public var skew: TimeInterval    // computed by the session against its clock
}
```

### 10.5 `GET /ISAPI/System/capabilities`

Returns `<DeviceCap>`: 20–90 KiB, wildly firmware-dependent, with sub-blocks `<SysCap>`,
`<NetworkCap>`, `<VideoCap>`, `<AudioCap>`, `<ImageCap>`, `<SerialCap>`, `<EventCap>`,
`<RaidCap>`, `<SmartCap>`. Abbreviated real sample:

```xml
<DeviceCap version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <SysCap>
    <isSupportHttps>true</isSupportHttps>
    <networkNo>1</networkNo>
    <serialNo>0</serialNo>
    <videoInNo>1</videoInNo>
    <audioInNo>1</audioInNo>
    <videoOutNo>0</videoOutNo>
    <audioOutNo>1</audioOutNo>
    <alarmInNo>1</alarmInNo>
    <alarmOutNo>1</alarmOutNo>
    <isSupportPTZ>false</isSupportPTZ>
    <isSupportTwoWayAudio>true</isSupportTwoWayAudio>
    <isSupportRedirectHttpToHttps>false</isSupportRedirectHttpToHttps>
    <SupportStreamingChannelNums>3</SupportStreamingChannelNums>
    <IOCap><IOInputPortNums>1</IOInputPortNums><IOOutputPortNums>1</IOOutputPortNums></IOCap>
  </SysCap>
  <VideoCap>
    <isSupportSmartCodec>true</isSupportSmartCodec>
    <videoInputChannelNums>1</videoInputChannelNums>
  </VideoCap>
  <AudioCap><audioInputChannelNums>1</audioInputChannelNums></AudioCap>
  <EventCap>
    <isSupportMotionDetection>true</isSupportMotionDetection>
    <isSupportLineDetection>true</isSupportLineDetection>
    <isSupportFieldDetection>true</isSupportFieldDetection>
    <isSupportRegionEntrance>true</isSupportRegionEntrance>
    <isSupportTamperDetection>true</isSupportTamperDetection>
    <isSupportFaceDetection>false</isSupportFaceDetection>
  </EventCap>
</DeviceCap>
```

**Decision: we do not model `DeviceCap` as a schema.** We resolve each capability through an
ordered list of candidate paths, then — if all paths are absent — through a *functional
probe* (a cheap GET whose 200/403 answers the question). Absent-and-unprobeable defaults are
chosen conservatively per row.

```swift
public struct DeviceCapabilities: Sendable, Hashable, Codable {
    public var videoInputChannels: Int
    public var audioInputChannels: Int
    public var streamsPerChannel: Int          // 1…3
    public var supportsPTZ: Bool
    public var supportsPTZPosition3D: Bool
    public var maxPresets: Int
    public var supportsPatrols: Bool
    public var supportsTwoWayAudio: Bool
    public var twoWayAudioCodecs: [AudioCodec]
    public var supportsAlertStream: Bool
    public var supportsSmartEvents: Bool
    public var supportsHTTPS: Bool
    public var supportsJPEGSnapshot: Bool
    public var supportsRecordSearch: Bool
    public var supportsInputProxy: Bool        // NVR IP-channel management
    public var supportsImageColor: Bool
    public var supportsWDR: Bool
    public var supportsIRCutFilter: Bool
    public var alarmInputs: Int
    public var alarmOutputs: Int
    public var probedAt: Date
    public var schemaVersion: Int              // 1
}
```

Capability resolution table (`bool` unless stated):

| Capability | Candidate paths (in order) | Functional probe | Default if all fail |
| --- | --- | --- | --- |
| `videoInputChannels` (Int) | `VideoCap/videoInputChannelNums`, `SysCap/videoInNo`, `RacmCap/videoInputChannelNums` | count of `/System/Video/inputs/channels` | 1 |
| `audioInputChannels` (Int) | `AudioCap/audioInputChannelNums`, `SysCap/audioInNo` | — | 0 |
| `streamsPerChannel` (Int) | `SysCap/SupportStreamingChannelNums`, `RacmCap/SupportStreamingChannelNums` | count of `/Streaming/channels` ÷ channels | 2 |
| `supportsPTZ` | `SysCap/isSupportPTZ`, `SysCap/isSupportPtz`, `PTZCap/**/isSupportPTZ` | `GET /PTZCtrl/channels/{ch}/capabilities` → 200 | false |
| `supportsPTZPosition3D` | `PTZChanelCap/isSupportPosition3D` (from PTZ caps, §13.9) | — | false |
| `maxPresets` (Int) | `PTZChanelCap/maxPresetNum`, `PTZCap/maxPresetNums` | count of `GET /presets` | 255 if PTZ else 0 |
| `supportsPatrols` | `PTZChanelCap/isSupportPatrol` | `GET /PTZCtrl/channels/{ch}/patrols` → 200 | false |
| `supportsTwoWayAudio` | `SysCap/isSupportTwoWayAudio` | `GET /System/TwoWayAudio/channels` → 200 with ≥1 channel | false |
| `supportsAlertStream` | `EventCap/isSupportAlertStream` | `GET /Event/notification/alertStream` — 200 within 3 s, then cancel | **true** (assume yes; it is near-universal) |
| `supportsSmartEvents` | any of `EventCap/isSupportLineDetection`, `…FieldDetection`, `…RegionEntrance` | — | false |
| `supportsJPEGSnapshot` | `VideoCap/isSupportSnapshot`, `SysCap/isSupportSnapshot` | `GET /Streaming/channels/{id}/picture` → 200 | **true** |
| `supportsRecordSearch` | `RacmCap/isSupportSearch`, `ContentMgmtCap/**/isSupportSearch` | `POST /ContentMgmt/search` with a 1-minute span → 200 | true if family ∈ {nvr,dvr,hybridDVR} else probe |
| `supportsInputProxy` | `RacmCap/isSupportInputProxy` | `GET /ContentMgmt/InputProxy/channels` → 200 | true iff family ∈ {nvr,dvr,hybridDVR} |
| `supportsWDR` | `ImageCap/**/isSupportWDR` | `GET /Image/channels/{ch}/WDR` → 200 | false |
| `supportsIRCutFilter` | `ImageCap/**/isSupportIrcutFilter` | `GET /Image/channels/{ch}/ircutFilter` → 200 | false |
| `supportsImageColor` | `ImageCap/**/isSupportColor` | `GET /Image/channels/{ch}/color` → 200 | true |
| `alarmInputs` (Int) | `SysCap/alarmInNo`, `SysCap/IOCap/IOInputPortNums` | — | 0 |
| `alarmOutputs` (Int) | `SysCap/alarmOutNo`, `SysCap/IOCap/IOOutputPortNums` | — | 0 |

Functional probes run **only** when the paths are absent, at most once per device per
capability, in a low-priority task group with `maxConcurrent = 2`, and their results are
cached with the capability snapshot (TTL 24 h, keyed additionally by
`firmwareVersion.raw` so a firmware update re-probes).

`GET /ISAPI/System/capabilities` is also allowed to fail entirely (some 5.1.x devices 404 it).
That is not an error; every row then falls through to probe/default.

### 10.6 `GET /ISAPI/System/Network/interfaces`

```xml
<NetworkInterfaceList version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <NetworkInterface version="2.0">
    <id>1</id>
    <IPAddress version="2.0">
      <ipVersion>dual</ipVersion>
      <addressingType>static</addressingType>
      <ipAddress>192.168.1.64</ipAddress>
      <subnetMask>255.255.255.0</subnetMask>
      <ipv6Address>::</ipv6Address>
      <bitMask>0</bitMask>
      <DefaultGateway><ipAddress>192.168.1.1</ipAddress></DefaultGateway>
      <PrimaryDNS><ipAddress>192.168.1.1</ipAddress></PrimaryDNS>
      <SecondaryDNS><ipAddress>8.8.8.8</ipAddress></SecondaryDNS>
    </IPAddress>
    <Discovery>
      <UPnP><enabled>true</enabled></UPnP>
      <Zeroconf><enabled>false</enabled></Zeroconf>
    </Discovery>
    <Link>
      <MACAddress>44:47:cc:11:22:33</MACAddress>
      <autoNegotiation>true</autoNegotiation>
      <speed>100</speed>
      <duplex>full</duplex>
      <MTU>1500</MTU>
    </Link>
  </NetworkInterface>
</NetworkInterfaceList>
```

```swift
public struct NetworkInterfaceInfo: Sendable, Hashable {
    public let id: Int
    public let addressingType: String       // "static" | "dynamic"
    public let ipv4: String?
    public let subnetMask: String?
    public let ipv6: [String]
    public let gateway: String?
    public let dns: [String]
    public let macAddress: String?
    public let linkSpeedMbps: Int?          // 10 | 100 | 1000
    public let duplex: String?
    public let mtu: Int?
}
```

Uses: (a) Stream Doctor prints link speed — a 10 Mbit half-duplex link explains a stuttering
4 K stream better than any other diagnostic; (b) MAC is a stable device identity for
discovery reconciliation; (c) MTU informs the RTP-over-UDP packet-size warning.

Read-only. We never write network configuration.

---

## 11. Channel inventory

Vigil must present a single flat list of *streamable channels* regardless of whether the
device is a camera (1 channel) or an NVR (up to 64 IP channels, some offline). Resolution
order:

```
1. GET /ISAPI/Streaming/channels                    ← authoritative streaming inventory
2. if family ∈ {nvr,dvr,hybrid}:
       GET /ISAPI/ContentMgmt/InputProxy/channels   ← names + upstream identity
       GET /ISAPI/ContentMgmt/InputProxy/channels/status  ← online flags
3. GET /ISAPI/System/Video/inputs/channels          ← local analog/sensor inputs + names
4. merge by channel number; Streaming wins for stream facts, InputProxy/VideoInputs win for names
```

### 11.1 `GET /ISAPI/ContentMgmt/InputProxy/channels` (NVR IP channels)

```xml
<InputProxyChannelList version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <InputProxyChannel version="2.0">
    <id>1</id>
    <name>Driveway</name>
    <sourceInputPortDescriptor>
      <proxyProtocol>ISAPI</proxyProtocol>
      <addressingFormatType>ipaddress</addressingFormatType>
      <ipAddress>192.168.1.64</ipAddress>
      <managePortNo>8000</managePortNo>
      <srcInputPort>1</srcInputPort>
      <userName>admin</userName>
      <streamType>auto</streamType>
      <deviceID>48343131-3435-3234-3138-343131343535</deviceID>
    </sourceInputPortDescriptor>
  </InputProxyChannel>
</InputProxyChannelList>
```

`proxyProtocol` values seen: `ISAPI`, `ONVIF`, `HIKVISION`, `PSIA`, `RTSP`. `streamType`:
`auto`, `main`, `sub`.

### 11.2 `GET /ISAPI/ContentMgmt/InputProxy/channels/{id}/status`

```xml
<InputProxyChannelStatus version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <id>1</id>
  <online>true</online>
  <streamingProxyChannelIdList>
    <streamingProxyChannelId>1</streamingProxyChannelId>
    <streamingProxyChannelId>2</streamingProxyChannelId>
  </streamingProxyChannelIdList>
  <chanDetectResult>online</chanDetectResult>
</InputProxyChannelStatus>
```

`GET /ISAPI/ContentMgmt/InputProxy/channels/status` returns
`<InputProxyChannelStatusList>` containing all of the above — **always prefer the list form**
(one request instead of 32). Fall back to per-channel only on 404/405.

`chanDetectResult` values: `online`, `offline`, `notSupport`, `networkAbnormal`,
`userOrPasswordError`, `notActivated`. These are surfaced verbatim in the channel row
subtitle because "wrong password on channel 7" is exactly what the user needs to know.

Poll cadence: every **30 s** while an NVR has any visible channel; immediately after a
channel's stream fails.

### 11.3 `GET /ISAPI/System/Video/inputs/channels`

```xml
<VideoInputChannelList version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <VideoInputChannel version="2.0">
    <id>1</id>
    <inputPort>1</inputPort>
    <name>Camera 01</name>
    <videoFormat>PAL</videoFormat>
    <powerLineFrequencyMode>50hz</powerLineFrequencyMode>
    <whiteBalanceMode>auto</whiteBalanceMode>
    <resDesc>1080p</resDesc>
  </VideoInputChannel>
</VideoInputChannelList>
```

This is also the endpoint whose `{ch}` index is used by `/ISAPI/Image/channels/{ch}` and
`/ISAPI/System/Video/inputs/channels/{ch}/motionDetection` — note the **critical distinction**:

| Index space | Range | Used by |
| --- | --- | --- |
| **video input channel** (`ch`) | 1…N | `/Image/channels/{ch}`, `/System/Video/inputs/channels/{ch}/…`, `/PTZCtrl/channels/{ch}/…`, `EventNotificationAlert.channelID` |
| **streaming channel** (`id`) | `ch*100 + stream` | `/Streaming/channels/{id}`, `/Streaming/channels/{id}/picture`, RTSP path |
| **track** (`trackID`) | `ch*100 + stream` | `/ContentMgmt/record/tracks`, `CMSearchDescription.trackIDList`, `/Streaming/tracks/{id}` |

Confusing these is the second most common ISAPI bug after the Digest URI. The model makes it
impossible:

```swift
/// 1-based video input channel.
public struct ChannelID: Sendable, Hashable, Codable, ExpressibleByIntegerLiteral,
                         CustomStringConvertible {
    public let value: Int
}

public enum StreamIndex: Int, Sendable, Codable, CaseIterable {
    case main = 1, sub = 2, third = 3
}

/// ch*100 + stream. Used for /Streaming/channels and RTSP.
public struct StreamingChannelID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let value: Int
    public init(channel: ChannelID, stream: StreamIndex) { value = channel.value * 100 + stream.rawValue }
    public init?(rawValue: Int)          // rejects values < 101 or stream ∉ 1…3
    public var channel: ChannelID { ChannelID(value / 100) }
    public var stream: StreamIndex { StreamIndex(rawValue: value % 100) ?? .main }
}

/// Same numeric space as StreamingChannelID but a distinct type: tracks are a
/// recording concept and the two are not interchangeable across firmwares.
public struct TrackID: Sendable, Hashable, Codable { public let value: Int }
```

### 11.4 Merged model

```swift
public struct DeviceChannel: Sendable, Hashable, Codable {
    public let channel: ChannelID
    public var displayName: String            // best of InputProxy.name, VideoInput.name,
                                              // StreamingChannel.channelName, "Channel N"
    public var isEnabled: Bool
    public var isOnline: Bool                 // NVR IP channels only; true for local inputs
    public var offlineReason: String?         // chanDetectResult when !isOnline
    public var upstream: UpstreamSource?      // NVR IP channels only
    public var streams: [StreamIndex: StreamingChannelConfig]
    public var supportsPTZ: Bool              // per channel, not per device
}

public struct UpstreamSource: Sendable, Hashable, Codable {
    public let protocolName: String           // "ISAPI" | "ONVIF" | …
    public let ipAddress: String?
    public let managePort: Int?
    public let sourceInputPort: Int?
    public let userName: String?
    public let deviceID: String?
}
```

Name precedence is deliberate: on an NVR the InputProxy name is what the operator typed into
the NVR, and is what they expect to see.

---

## 12. Streaming configuration, RTSP mapping, JPEG snapshots

### 12.1 `GET /ISAPI/Streaming/channels`

Returns every stream of every channel. On a 32-channel NVR this is ~250 KiB; it is the single
most valuable request we make, so it is fetched once at connect and cached for **30 s**
(invalidated immediately after any successful `PUT`).

```xml
<StreamingChannelList version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <StreamingChannel version="2.0">
    <id>101</id>
    <channelName>Driveway</channelName>
    <enabled>true</enabled>
    <Transport>
      <rtspPortNo>554</rtspPortNo>
      <maxPacketSize>1000</maxPacketSize>
      <ControlProtocolList>
        <ControlProtocol><streamingTransport>RTSP</streamingTransport></ControlProtocol>
        <ControlProtocol><streamingTransport>HTTP</streamingTransport></ControlProtocol>
      </ControlProtocolList>
      <Unicast><enabled>true</enabled><rtpTransportType>RTP/TCP</rtpTransportType></Unicast>
      <Multicast>
        <enabled>false</enabled>
        <destIPAddress>0.0.0.0</destIPAddress>
        <videoDestPortNo>8600</videoDestPortNo>
        <audioDestPortNo>8602</audioDestPortNo>
      </Multicast>
      <Security><enabled>true</enabled><certificateType>digest</certificateType></Security>
    </Transport>
    <Video>
      <enabled>true</enabled>
      <videoInputChannelID>1</videoInputChannelID>
      <videoCodecType>H.265</videoCodecType>
      <videoScanType>progressive</videoScanType>
      <videoResolutionWidth>3840</videoResolutionWidth>
      <videoResolutionHeight>2160</videoResolutionHeight>
      <videoQualityControlType>VBR</videoQualityControlType>
      <constantBitRate>8192</constantBitRate>
      <fixedQuality>60</fixedQuality>
      <vbrUpperCap>8192</vbrUpperCap>
      <vbrLowerCap>32</vbrLowerCap>
      <maxFrameRate>2000</maxFrameRate>
      <keyFrameInterval>2000</keyFrameInterval>
      <snapShotImageType>JPEG</snapShotImageType>
      <GovLength>40</GovLength>
      <SVC><enabled>false</enabled></SVC>
      <H265Profile>Main</H265Profile>
      <SmartCodec><enabled>true</enabled></SmartCodec>
    </Video>
    <Audio>
      <enabled>true</enabled>
      <audioInputChannelID>1</audioInputChannelID>
      <audioCompressionType>G.711ulaw</audioCompressionType>
    </Audio>
  </StreamingChannel>
  <StreamingChannel version="2.0">
    <id>102</id>
    …
  </StreamingChannel>
</StreamingChannelList>
```

**Units — memorize these, they are the classic source of wrong UI numbers:**

| Element | Unit | Example | Notes |
| --- | --- | --- | --- |
| `maxFrameRate` | **fps × 100** | `2000` = 20 fps, `1250` = 12.5 fps | Values below 100 mean sub-1 fps modes (`50` = 0.5 fps) |
| `keyFrameInterval` | **milliseconds** | `2000` = 2 s | Not frames. |
| `GovLength` | **frames** | `40` | GOP length. `GovLength ≈ fps × keyFrameInterval/1000`. When both are present, `GovLength` is authoritative for the decoder's keyframe expectation. |
| `constantBitRate` | kbit/s | `8192` | Meaningful when `videoQualityControlType == CBR` |
| `vbrUpperCap` / `vbrLowerCap` | kbit/s | `8192` / `32` | VBR ceiling / floor |
| `fixedQuality` | 0–100 | `60` | VBR quality when the device uses quality-based VBR |
| `maxPacketSize` | bytes | `1000` | RTP payload cap; drives MTU-safety. Values >1400 with UDP transport must be flagged. |

`videoCodecType` values: `H.264`, `H.265`, `MJPEG`, `MPEG4`, and (rarely) `H.264-BP`,
`H.264-MP`, `H.264-HP`, `SVAC`. Parsing is prefix-based and case-insensitive.
`videoQualityControlType`: `CBR` | `VBR`. `videoScanType`: `progressive` | `interlace`.
`audioCompressionType`: `G.711ulaw`, `G.711alaw`, `G.722.1`, `G.726`, `AAC`, `MP2L2`, `PCM`.
`rtpTransportType`: `RTP/TCP` | `RTP/UDP`.

```swift
public struct StreamingChannelConfig: Sendable, Hashable, Codable {
    public let id: StreamingChannelID
    public var channelName: String?
    public var enabled: Bool
    // Video
    public var codec: VideoCodec                 // .h264(profile), .h265(profile), .mjpeg, .other
    public var width: Int
    public var height: Int
    public var frameRate: Double                 // maxFrameRate / 100
    public var bitrateControl: BitrateControl    // .cbr(kbps) | .vbr(upper: Int, lower: Int, quality: Int)
    public var keyFrameIntervalMS: Int
    public var govLength: Int?
    public var smartCodecEnabled: Bool
    public var svcEnabled: Bool
    public var scanType: ScanType
    // Audio
    public var audioEnabled: Bool
    public var audioCodec: AudioCodec?
    // Transport
    public var rtspPort: Int
    public var maxPacketSize: Int
    public var preferredRTPTransport: RTPTransport
    public var multicast: MulticastConfig?
    /// The verbatim node, retained for read-modify-write PUTs (§12.3).
    public var originalNode: XMLNode

    public init(node: XMLNode) throws
}

public enum VideoCodec: Sendable, Hashable, Codable {
    case h264(profile: String?)      // "Baseline" | "Main" | "High"
    case h265(profile: String?)      // "Main" | "Main10"
    case mjpeg
    case mpeg4
    case other(String)
    public var isHardwareDecodable: Bool { if case .other = self { false } else { true } }
}
```

### 12.2 `GET /ISAPI/Streaming/channels/{id}`

Identical `<StreamingChannel>` element, single. Used when only one stream is needed (tile
quality switch) and as the read half of read-modify-write.

Some 5.1.x firmware answers `/ISAPI/Streaming/channels/1` (1-digit, main only). Probe order
on first use, remembered per device in the quirk record: `101` → `1` → give up.

### 12.3 `PUT /ISAPI/Streaming/channels/{id}` — changing substream settings

**Mandatory pattern: read-modify-write on the whole `<StreamingChannel>` element.**
Hikvision's validator rejects partial documents with `invalidXMLContent`, and — worse — some
firmwares *accept* a partial document and reset the omitted fields to defaults. Never
hand-craft this body.

```
PUT /ISAPI/Streaming/channels/102 HTTP/1.1
Host: 192.168.1.64
Authorization: Digest …
Content-Type: application/xml
Content-Length: 1043

<?xml version="1.0" encoding="UTF-8"?>
<StreamingChannel version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <id>102</id>
  <channelName>Driveway</channelName>
  <enabled>true</enabled>
  <Transport> … unchanged, echoed verbatim … </Transport>
  <Video>
    <enabled>true</enabled>
    <videoInputChannelID>1</videoInputChannelID>
    <videoCodecType>H.264</videoCodecType>
    <videoScanType>progressive</videoScanType>
    <videoResolutionWidth>640</videoResolutionWidth>
    <videoResolutionHeight>360</videoResolutionHeight>
    <videoQualityControlType>VBR</videoQualityControlType>
    <constantBitRate>512</constantBitRate>
    <fixedQuality>60</fixedQuality>
    <vbrUpperCap>512</vbrUpperCap>
    <vbrLowerCap>32</vbrLowerCap>
    <maxFrameRate>1200</maxFrameRate>
    <keyFrameInterval>2000</keyFrameInterval>
    <GovLength>24</GovLength>
    <SVC><enabled>false</enabled></SVC>
    <H264Profile>Main</H264Profile>
    <SmartCodec><enabled>false</enabled></SmartCodec>
  </Video>
  <Audio> … unchanged … </Audio>
</StreamingChannel>
```

Response: `<ResponseStatus>` with `statusCode` 1 (or 7 = reboot required, which happens when
the codec changes on some DVRs).

API:

```swift
public struct StreamingChannelPatch: Sendable {
    public var codec: VideoCodec?
    public var resolution: (width: Int, height: Int)?
    public var frameRate: Double?
    public var bitrateControl: BitrateControl?
    public var keyFrameIntervalMS: Int?
    public var govLength: Int?
    public var smartCodecEnabled: Bool?
    public var audioEnabled: Bool?
    public init() {}
}

extension ISAPIDeviceSession {
    /// GETs the channel, applies the patch onto `originalNode`, PUTs the whole element,
    /// invalidates the streaming cache, and re-GETs to confirm. Returns the confirmed config.
    public func updateStream(_ id: StreamingChannelID,
                             _ patch: StreamingChannelPatch) async throws -> StreamingChannelConfig
}
```

The confirming re-GET is not optional. Several firmwares silently clamp values (e.g. a
requested 512 kbit/s VBR cap becomes 768) and the UI must show what the device actually did.

Client-side pre-validation before the PUT (avoids a pointless round trip and a scary error):

| Field | Rule |
| --- | --- |
| `maxFrameRate` | must be one of the device's advertised rates; when unknown, must be a multiple of 25 in `[50, 6000]` |
| width × height | must be ≤ the main stream's resolution for sub/third streams |
| `vbrUpperCap` | 32…16384 |
| `keyFrameInterval` | 20…10000 ms |
| `GovLength` | 1…400 |
| codec | must appear in the channel's advertised codec list when we have one |

Sensible substream target that Vigil offers as a one-click "Optimize for grid" action:
`H.264 Main, 640×360, 12 fps, VBR upper 512 kbit/s, keyFrameInterval 2000 ms,
SmartCodec off`. SmartCodec must be **off** on substreams: its long-GOP behaviour delays the
first keyframe to 4–8 s, which destroys tile-open latency.

### 12.4 Channel ID → RTSP path mapping

Canonical formula, and the only one Vigil generates:

```
streamingChannelID = channel * 100 + streamIndex      (streamIndex: 1 main, 2 sub, 3 third)
rtspPath           = "/Streaming/Channels/" + streamingChannelID
```

| Device / channel / stream | `StreamingChannelID` | RTSP path |
| --- | --- | --- |
| IP camera, ch 1, main | 101 | `rtsp://host:554/Streaming/Channels/101` |
| IP camera, ch 1, sub | 102 | `rtsp://host:554/Streaming/Channels/102` |
| IP camera, ch 1, third | 103 | `rtsp://host:554/Streaming/Channels/103` |
| NVR, ch 7, sub | 702 | `rtsp://host:554/Streaming/Channels/702` |
| NVR, ch 12, main | 1201 | `rtsp://host:554/Streaming/Channels/1201` |
| NVR, ch 32, sub | 3202 | `rtsp://host:554/Streaming/Channels/3202` |
| Playback track, ch 1 main | trackID 101 | `rtsp://host:554/Streaming/tracks/101?starttime=…` |

Notes:
* The `/Streaming/Channels/{ch}0{stream}` form quoted in old Hikvision documents is the
  *same* number for `ch ≤ 9`; for `ch ≥ 10` it is wrong. Only the arithmetic form is used.
* Path case: `Streaming/Channels` with capitals. `/streaming/channels/101` works on 5.5+ but
  404s on 5.2.x. Always capitalized.
* Legacy fallbacks, tried by `VigilRTSP` only after `/Streaming/Channels/{id}` fails with
  RTSP 404, in this order: `/h264/ch{ch}/main/av_stream`, `/h264/ch{ch}/sub/av_stream`,
  `/Streaming/Channels/{ch}0{stream}`, `/mpeg4/ch{ch}/sub/av_stream`.
* `VigilISAPI` exports the path builder so exactly one implementation exists:

```swift
public enum HikvisionURL {
    public static func livePath(_ id: StreamingChannelID) -> String
    public static func liveURL(_ endpoint: ISAPIEndpoint, rtspPort: Int,
                               _ id: StreamingChannelID) -> URL
    public static func legacyLivePaths(channel: ChannelID, stream: StreamIndex) -> [String]
    public static func playbackPath(_ track: TrackID) -> String
}
```

**Credentials are never embedded in RTSP URLs.** `rtsp://user:pass@host/...` leaks into logs
and crash reports; `VigilRTSP` authenticates with Digest instead.

### 12.5 JPEG snapshot — the thumbnail fast path

```
GET /ISAPI/Streaming/channels/101/picture?videoResolutionWidth=640&videoResolutionHeight=360
Accept: image/jpeg
```

Response: `HTTP/1.1 200 OK`, `Content-Type: image/jpeg`, `Content-Length: 41537`, JPEG body.

| Query item | Range | Notes |
| --- | --- | --- |
| `videoResolutionWidth` | 64…7680 | Must pair with height. Device snaps to the nearest supported size. |
| `videoResolutionHeight` | 64…4320 | |
| `compression` | 1…100 | Optional, 6.x only. We do not send it. |

Behaviour and quirks:
* Cost on the device is real: a 4 K snapshot takes 300–700 ms and briefly competes with the
  encoder. Never request main-stream resolution for a thumbnail.
* Request the **substream** channel (`102`) for thumbnails; it is 5–10× faster than `101`
  because no scaling is needed.
* Some firmwares return **403 + `notSupport`** when resolution query items are present.
  Recovery: retry once with no query string, then downscale locally. Remember the result in
  the quirk record (`snapshotIgnoresResolutionQuery`).
* Some 5.2.x devices return `Content-Type: text/html` with a JPEG body. We sniff the SOI
  marker `FF D8 FF` instead of trusting the header, and reject bodies that do not start with
  it (`ISAPIError.unexpectedContentType`).
* Empty 200 with `Content-Length: 0` happens when the channel is offline on an NVR ⇒
  `ISAPIError.device(ResponseStatus(statusCode: 4, subStatusCode: "ipcOffline"))`.

```swift
public struct SnapshotRequest: Sendable {
    public var channel: StreamingChannelID
    public var width: Int?
    public var height: Int?
    public var timeout: TimeInterval = 6.0
}

extension ISAPIDeviceSession {
    /// Returns raw JPEG bytes. Runs on the `.snapshot` lane. Cancellable.
    public func snapshot(_ request: SnapshotRequest) async throws -> Data
}
```

Polling policy (the numbers `VigilCore`'s admission policy must use):

| Consumer | Source channel | Requested size | Cadence | Lane budget |
| --- | --- | --- | --- | --- |
| Sidebar row thumbnail | sub (`ch*100+2`) | 160×90 | every 3 s, phase-staggered by `hash(cameraID) % 3000 ms` | 2 concurrent per device, 6 app-wide |
| Grid tile below 160 px | sub | tile size × 2, capped 480×270 | every 1 s | same |
| Offline placeholder retry | sub | 160×90 | every 15 s | same |
| Event thumbnail (no JPEG in the alert part) | sub | 320×180 | once, within 500 ms of the event | bypasses stagger |

App-wide the snapshot lane is capped at **6 concurrent** across all devices; requests beyond
that are dropped, not queued (a stale thumbnail is better than a backlog).

---

## 13. PTZ control

All PTZ writes are `PUT`, all carry `Content-Type: application/xml`, all use the **video
input channel** index (`ch`, 1-based) — *not* the streaming channel ID. On an NVR, `ch` is
the NVR's channel number and the NVR proxies the command to the camera.

`Content-Type: application/xml` is **required**. Sending `text/xml` produces
`invalidXMLFormat` on 5.4.x; sending no Content-Type produces HTTP 400.

Empty-bodied PUTs (`/goto`, `/start`, `/stop`) must send `Content-Length: 0` explicitly.
URLSession omits the header for a nil body on some paths; set it manually.

### 13.1 `PUT /ISAPI/PTZCtrl/channels/{ch}/continuous`

The workhorse: velocity control. Send once to start, send zeros to stop.

```
PUT /ISAPI/PTZCtrl/channels/1/continuous HTTP/1.1
Content-Type: application/xml
Content-Length: 96

<?xml version="1.0" encoding="UTF-8"?>
<PTZData><pan>60</pan><tilt>-40</tilt><zoom>0</zoom></PTZData>
```

| Element | Range | Units | Sign convention |
| --- | --- | --- | --- |
| `pan` | −100…100 | % of max speed | **+ = right (clockwise)**, − = left |
| `tilt` | −100…100 | % of max speed | **+ = up**, − = down |
| `zoom` | −100…100 | % of max speed | + = tele (in), − = wide (out) |

Element order `pan, tilt, zoom` is required by 5.2.x validators. All three elements must be
present even when zero.

Response: `<ResponseStatus>` `statusCode 1`. `403 notSupport` on fixed cameras.

**Stop semantics (critical):** a continuous command runs until stopped or until the device's
internal watchdog fires (typically 500 ms–2 s, model-dependent and unreliable). Therefore:

* Every `continuous` start is paired with a stop.
* The client maintains a **PTZ keep-alive**: while a control is held, resend the identical
  command every **400 ms**. This defeats every firmware watchdog we have seen.
* On stop, send the all-zero body up to **3 times** at 80 ms spacing, ignoring individual
  failures. A camera left panning is the worst possible failure mode.
* On `Task` cancellation, app deactivation, window close, stream stop, or app termination,
  the pending stop is sent synchronously-as-possible (a detached task with a 1 s budget).

```swift
public struct PTZVelocity: Sendable, Hashable {
    public var pan: Int      // clamped -100…100
    public var tilt: Int
    public var zoom: Int
    public static let stopped = PTZVelocity(pan: 0, tilt: 0, zoom: 0)
    public var isStopped: Bool { pan == 0 && tilt == 0 && zoom == 0 }
}

public actor PTZController {       // one per PTZ-capable channel; lives in VigilISAPI
    public init(session: ISAPIDeviceSession, channel: ChannelID, capabilities: PTZCapabilities)
    /// Starts or updates a continuous move and (re)arms the 400 ms keep-alive.
    public func move(_ v: PTZVelocity) async throws
    /// Cancels the keep-alive and sends the triple stop. Never throws.
    public func stop() async
    public func momentary(_ v: PTZVelocity, duration: Duration) async throws
    public func absolute(_ p: PTZAbsolutePosition) async throws
    public func relative(_ r: PTZRelativeMove) async throws
    public func position3D(_ box: PTZBox) async throws
    public func gotoPreset(_ n: Int) async throws
    public func setPreset(_ n: Int, name: String) async throws
    public func deletePreset(_ n: Int) async throws
    public func presets() async throws -> [PTZPreset]
    public func patrols() async throws -> [PTZPatrol]
    public func startPatrol(_ n: Int) async throws
    public func stopPatrol(_ n: Int) async throws
    public func gotoHome() async throws
    public func status() async throws -> PTZStatus
    public func setFocus(_ v: Int) async throws       // -100…100 continuous
    public func setIris(_ v: Int) async throws        // -100…100 continuous
    public func auxiliary(_ aux: PTZAuxiliary, on: Bool) async throws
}
```

Speed scaling: the UI exposes a 1–10 speed setting; the controller multiplies the normalized
direction vector by `speedSetting * 10` and clamps. Diagonal moves are **not** normalized to
unit length — Hikvision treats pan and tilt speeds independently and users expect a diagonal
drag to move at full speed on both axes.

### 13.2 `PUT /ISAPI/PTZCtrl/channels/{ch}/momentary`

Fire-and-forget nudge; the device stops itself. This is what the arrow-key tap uses.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<PTZData>
  <pan>40</pan><tilt>0</tilt><zoom>0</zoom>
  <Momentary><duration>300</duration></Momentary>
</PTZData>
```

`duration`: **milliseconds**, 0…60000; practical range 50…2000. Vigil uses **300 ms** for a
key tap and **120 ms** for a shift-key fine nudge.

Preferred over `continuous` for discrete nudges because it needs no stop command and cannot
leave the camera moving if the app is killed mid-gesture. `403 notSupport` ⇒ fall back to
`continuous` + a timed stop (record `momentaryUnsupported` in the quirk record).

### 13.3 `PUT /ISAPI/PTZCtrl/channels/{ch}/absolute`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<PTZData>
  <AbsoluteHigh>
    <elevation>-150</elevation>
    <azimuth>1350</azimuth>
    <absoluteZoom>40</absoluteZoom>
  </AbsoluteHigh>
</PTZData>
```

| Element | Range | Units | Meaning |
| --- | --- | --- | --- |
| `azimuth` | 0…3600 | 0.1° | pan, 0 = the device's zero reference, increasing clockwise |
| `elevation` | −900…2700 | 0.1° | tilt; most domes use −900…900 (−90°…+90°), ceiling-mount models report 0…2700 |
| `absoluteZoom` | 1…1000 | ×0.1 optical steps | 10 ≈ 1× wide; the true maximum is `PTZChanelCap/ZoomRange/max` |

The actual per-model ranges come from `/PTZCtrl/channels/{ch}/capabilities` (§13.9). Values
outside them are clamped client-side and the clamp is logged; we do not send out-of-range
values because some firmware answers `deviceError` and then ignores the *next* valid command.

`PTZAbsolutePosition` stores degrees as `Double` and converts at the wire boundary:

```swift
public struct PTZAbsolutePosition: Sendable, Hashable {
    public var azimuthDegrees: Double      // 0…360
    public var elevationDegrees: Double     // -90…270
    public var zoomSteps: Int               // 1…1000, wire units
}
```

### 13.4 `PUT /ISAPI/PTZCtrl/channels/{ch}/relative`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<PTZData>
  <Relative>
    <positionX>120</positionX>
    <positionY>-60</positionY>
    <relativeZoom>0</relativeZoom>
  </Relative>
</PTZData>
```

| Element | Range | Units |
| --- | --- | --- |
| `positionX` | −255…255 | device-relative pan steps (screen-pixel-like, not degrees) |
| `positionY` | −255…255 | device-relative tilt steps; **+ = up** |
| `relativeZoom` | −255…255 | relative zoom steps |

Used for trackpad-scroll pan on a PTZ camera and for the "recenter on double-click" gesture
when `position3D` is unsupported. Frequently `403 notSupport` on non-speed-dome models.

### 13.5 `PUT /ISAPI/PTZCtrl/channels/{ch}/position3D` — drag-to-zoom

This powers dragging a rectangle directly on the video to zoom there. It is the single most
delightful PTZ interaction and must work.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<PTZData>
  <Position3D>
    <StartPoint><positionX>62</positionX><positionY>180</positionY></StartPoint>
    <EndPoint><positionX>190</positionX><positionY>60</positionY></EndPoint>
  </Position3D>
</PTZData>
```

| Element | Range | Coordinate space |
| --- | --- | --- |
| `positionX` | 0…255 | horizontal, 0 = left edge of the image, 255 = right edge |
| `positionY` | 0…255 | vertical, **0 = bottom edge, 255 = top edge** (origin lower-left) |

Semantics:
* `StartPoint != EndPoint` ⇒ the device centres on the box and zooms so the box fills the
  frame. Drag direction is irrelevant to the device; only the rectangle matters.
* `StartPoint == EndPoint` ⇒ centre on that point at the current zoom (click-to-centre).
* Zoom-out gesture: Hikvision has no "zoom out box". Vigil maps a **right-drag** (or
  ⌥-drag) to `continuous` zoom-out for the drag duration instead. Documented UI decision.

**Y-axis orientation quirk and its calibration.** A minority of firmwares (observed on some
DS-2DE4xxx builds) treat the origin as upper-left. The quirk record therefore carries
`ptz3DOriginIsTopLeft: Bool?`, resolved as follows:

1. Default `false` (lower-left), which is correct for the large majority.
2. A one-time calibration is available from the PTZ settings popover: Vigil reads
   `/status`, issues a `position3D` click at `(128, 200)` (upper half), waits 1.5 s, reads
   `/status` again. If `elevation` **decreased** (camera tilted down) the axis is inverted and
   the flag is set to `true`, then persisted on the camera record.
3. Until calibration is run, if the user reports inverted behaviour they can flip the flag
   from the same popover.

Conversion from a SwiftUI drag in view coordinates (`VigilUI` calls this; the function lives
here so there is one implementation):

```swift
public struct PTZBox: Sendable, Hashable {
    public var startX: Int, startY: Int, endX: Int, endY: Int   // all 0…255, wire space
}

public enum PTZ3D {
    /// `rect` and `viewSize` are in SwiftUI top-left-origin points, already mapped onto the
    /// video's letterboxed content rect by the caller.
    public static func box(from rect: CGRect, viewSize: CGSize,
                           originIsTopLeft: Bool) -> PTZBox
    /// Minimum drag that counts as a box rather than a click, in points.
    public static let minimumDragPoints: CGFloat = 12
}
```

Note the caller must map from the *view* rect to the *video content* rect first: with digital
zoom or letterboxing applied, view coordinates are not image coordinates. `VigilRender`
exposes `contentRect` and `visibleImageRect` for exactly this.

### 13.6 Presets

| Operation | Method + path | Body | Response |
| --- | --- | --- | --- |
| List | `GET /ISAPI/PTZCtrl/channels/{ch}/presets` | — | `<PTZPresetList>` |
| Get one | `GET /ISAPI/PTZCtrl/channels/{ch}/presets/{n}` | — | `<PTZPreset>` |
| Set to current position | `PUT /ISAPI/PTZCtrl/channels/{ch}/presets/{n}` | `<PTZPreset>` | `<ResponseStatus>` |
| Go to | `PUT /ISAPI/PTZCtrl/channels/{ch}/presets/{n}/goto` | empty, `Content-Length: 0` | `<ResponseStatus>` |
| Delete | `DELETE /ISAPI/PTZCtrl/channels/{ch}/presets/{n}` | — | `<ResponseStatus>` |

```xml
<PTZPresetList version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <PTZPreset version="2.0">
    <enabled>true</enabled>
    <id>1</id>
    <presetName>Gate</presetName>
  </PTZPreset>
  <PTZPreset version="2.0">
    <enabled>true</enabled>
    <id>2</id>
    <presetName>Driveway</presetName>
  </PTZPreset>
</PTZPresetList>
```

Set body:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<PTZPreset><id>3</id><presetName>Back gate</presetName></PTZPreset>
```

`presetName`: ≤ 32 UTF-8 bytes on most firmware; Vigil truncates at 30 bytes on a grapheme
boundary and warns. Empty names are accepted by the device but render as "Preset 3".

**Reserved preset numbers.** Presets 33–105 are special commands on Hikvision PTZ hardware,
not storage slots. Calling preset 94 reboots the camera. Vigil therefore:

* offers preset slots **1–32** in the normal UI;
* lists any device-reported presets above 32 in a separate, clearly labelled
  "Special commands" section, read-only, with confirmation before invoking;
* refuses `setPreset(n)` for `33 ≤ n ≤ 105` with `ISAPIError.device(...)` and the message
  `err.ptz.reservedPreset` — "Presets 33–105 are reserved by the camera for built-in
  commands."

| Preset | Built-in meaning |
| --- | --- |
| 33 | auto-flip |
| 34 | return to zero |
| 35–38 | run patrol 1–4 |
| 39 | IR-cut in (day mode) |
| 40 | IR-cut out (night mode) |
| 41–42 | model-specific |
| 92 | enable manual limit stops |
| 93 | set manual limit stop |
| 94 | remote reboot |
| 95 | open OSD menu |
| 96 | stop scan |
| 97 | random scan |
| 98 | frame scan |
| 99 | auto scan |
| 100 | tilt scan |
| 101 | panorama scan |
| 102–105 | run patrol 1–4 (alternate mapping) |

```swift
public struct PTZPreset: Sendable, Hashable, Codable, Identifiable {
    public let id: Int
    public var name: String
    public var enabled: Bool
    public var isReservedCommand: Bool { (33...105).contains(id) }
}
```

### 13.7 Patrols

| Operation | Method + path |
| --- | --- |
| List | `GET /ISAPI/PTZCtrl/channels/{ch}/patrols` |
| Get one | `GET /ISAPI/PTZCtrl/channels/{ch}/patrols/{n}` |
| Define | `PUT /ISAPI/PTZCtrl/channels/{ch}/patrols/{n}` |
| Start | `PUT /ISAPI/PTZCtrl/channels/{ch}/patrols/{n}/start` (empty body) |
| Stop | `PUT /ISAPI/PTZCtrl/channels/{ch}/patrols/{n}/stop` (empty body) |
| Delete | `DELETE /ISAPI/PTZCtrl/channels/{ch}/patrols/{n}` |

```xml
<PTZPatrolList version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <PTZPatrol version="2.0">
    <id>1</id>
    <enabled>true</enabled>
    <patrolName>Perimeter</patrolName>
    <PatrolSequenceList>
      <PatrolSequence>
        <id>1</id><PresetID>1</PresetID><dwellTime>10</dwellTime><speed>30</speed>
      </PatrolSequence>
      <PatrolSequence>
        <id>2</id><PresetID>2</PresetID><dwellTime>15</dwellTime><speed>30</speed>
      </PatrolSequence>
    </PatrolSequenceList>
  </PTZPatrol>
</PTZPatrolList>
```

| Element | Range | Units |
| --- | --- | --- |
| `id` (patrol) | 1…8 | — |
| `PresetID` | 1…255 | preset number |
| `dwellTime` | 0…255 | **seconds** at each preset |
| `speed` | 1…40 | device-specific speed index (not the −100…100 scale) |

Patrol element casing varies: `<PresetID>` is also seen as `<presetID>` and `<presetId>`;
`<dwellTime>` as `<DwellTime>`. Read paths use alternation:
`"PatrolSequenceList/PatrolSequence[]"` then `"PresetID|presetID|presetId"`.

Start/stop return `<ResponseStatus>`. Starting a patrol while a continuous move is active
returns `invalidOperation`; the controller therefore always `stop()`s first.

### 13.8 Home position, status, focus, iris, auxiliary

| Operation | Method + path | Body |
| --- | --- | --- |
| Go home | `PUT /ISAPI/PTZCtrl/channels/{ch}/homeposition/goto` | empty |
| Read home config | `GET /ISAPI/PTZCtrl/channels/{ch}/homeposition` | — |
| Set home enable | `PUT /ISAPI/PTZCtrl/channels/{ch}/homeposition` | `<PTZHomePosition><enabled>true</enabled></PTZHomePosition>` |
| Status | `GET /ISAPI/PTZCtrl/channels/{ch}/status` | — |
| Continuous focus | `PUT /ISAPI/System/Video/inputs/channels/{ch}/focus` | `<FocusData><focus>50</focus></FocusData>` |
| Continuous iris | `PUT /ISAPI/System/Video/inputs/channels/{ch}/iris` | `<IrisData><iris>50</iris></IrisData>` |
| Aux (light/wiper) | `PUT /ISAPI/PTZCtrl/channels/{ch}/auxcommand` | `<PTZAux><id>1</id><type>LIGHT</type><status>on</status></PTZAux>` |

```xml
<PTZStatus version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <AbsoluteHigh>
    <elevation>-150</elevation>
    <azimuth>1350</azimuth>
    <absoluteZoom>40</absoluteZoom>
  </AbsoluteHigh>
</PTZStatus>
```

`focus` / `iris` are **continuous velocity** values, −100…100, zero to stop — same
start/keep-alive/stop discipline as `continuous` pan. Note the unusual path: focus and iris
live under `/System/Video/inputs/channels/{ch}`, **not** under `/PTZCtrl`.

`PTZAux` `type` values: `LIGHT`, `WIPER`, `HEATER`, `FAN`, `AUX1`, `AUX2`. `status`: `on` |
`off`. Aux support is discovered from PTZ capabilities; absent ⇒ hide the buttons.

`GET /ISAPI/PTZCtrl/channels/{ch}/status` is polled at **2 Hz** only while the PTZ panel is
visible, and never otherwise (it is a surprisingly expensive call on some domes and can
stutter the encoder). It is never cached.

### 13.9 `GET /ISAPI/PTZCtrl/channels/{ch}/capabilities`

The root element is spelled **`PTZChanelCap`** (Hikvision's own typo) on most firmwares and
`PTZChannelCap` on a few. Accept both.

```xml
<PTZChanelCap version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <AbsolutePanTiltPositionSpace>
    <XRange><min>0</min><max>3600</max></XRange>
    <YRange><min>-900</min><max>900</max></YRange>
  </AbsolutePanTiltPositionSpace>
  <AbsoluteZoomPositionSpace><ZRange><min>1</min><max>1000</max></ZRange></AbsoluteZoomPositionSpace>
  <RelativePanTiltSpace><XRange><min>-255</min><max>255</max></XRange>
    <YRange><min>-255</min><max>255</max></YRange></RelativePanTiltSpace>
  <ContinuousPanTiltSpace><XRange><min>-100</min><max>100</max></XRange>
    <YRange><min>-100</min><max>100</max></YRange></ContinuousPanTiltSpace>
  <ContinuousZoomSpace><ZRange><min>-100</min><max>100</max></ZRange></ContinuousZoomSpace>
  <isSupportPosition3D>true</isSupportPosition3D>
  <isSupportPreset>true</isSupportPreset>
  <maxPresetNum>300</maxPresetNum>
  <isSupportPatrol>true</isSupportPatrol>
  <maxPatrolNum>8</maxPatrolNum>
  <isSupportPatternn>true</isSupportPatternn>
  <isSupportFocus>true</isSupportFocus>
  <isSupportIris>true</isSupportIris>
  <isSupportAux>true</isSupportAux>
  <PTZRs485Para>…</PTZRs485Para>
</PTZChanelCap>
```

```swift
public struct PTZCapabilities: Sendable, Hashable, Codable {
    public var supportsContinuous: Bool
    public var supportsMomentary: Bool          // probed; rarely advertised
    public var supportsAbsolute: Bool
    public var supportsRelative: Bool
    public var supportsPosition3D: Bool
    public var supportsPresets: Bool
    public var maxPresets: Int
    public var supportsPatrols: Bool
    public var maxPatrols: Int
    public var supportsFocus: Bool
    public var supportsIris: Bool
    public var auxiliaries: [PTZAuxiliary]
    public var azimuthRange: ClosedRange<Int>       // wire units (0.1°)
    public var elevationRange: ClosedRange<Int>
    public var zoomRange: ClosedRange<Int>
    /// True when the whole PTZ subsystem answered 403/404 — hide every PTZ affordance.
    public var isAbsent: Bool
    public init(document: ISAPIDocument)            // never throws; missing ⇒ conservative
}
```

Absent capabilities document (403/404) ⇒ `isAbsent = true`, everything false. A device that
answers `capabilities` but omits `isSupportPosition3D` gets `supportsPosition3D = false`;
we do not guess, because a rejected `position3D` looks like a broken drag gesture.

`GET /ISAPI/PTZCtrl/channels` lists PTZ-capable channels on an NVR
(`<PTZChannelList><PTZChannel><id>…`); on a camera it is often 404. Used to set
`DeviceChannel.supportsPTZ` per channel without probing every channel.

---

## 14. Events: the alert stream

### 14.1 `GET /ISAPI/Event/notification/alertStream`

One long-lived HTTP response per **device** (never per channel — an NVR multiplexes all
channels onto one stream, and opening several streams to one device exhausts its HTTP
workers). Lane `.stream`.

```
GET /ISAPI/Event/notification/alertStream HTTP/1.1
Host: 192.168.1.64
Authorization: Digest username="admin", realm="IP Camera(51253)", nonce="…",
  uri="/ISAPI/Event/notification/alertStream", response="…"
Accept: multipart/mixed
Connection: keep-alive
```

Response header:

```
HTTP/1.1 200 OK
Content-Type: multipart/mixed; boundary=<boundary>
Transfer-Encoding: chunked
Connection: keep-alive
```

Boundary handling — this is where naive parsers break:

| Observed `Content-Type` | Boundary token | Delimiter line on the wire |
| --- | --- | --- |
| `multipart/mixed; boundary=<boundary>` | `<boundary>` (angle brackets included!) | `--<boundary>` |
| `multipart/mixed; boundary=boundary` | `boundary` | `--boundary` |
| `multipart/mixed;boundary=--myboundary` | `--myboundary` | `----myboundary` |
| `multipart/mixed; boundary="MIME_boundary"` | `MIME_boundary` | `--MIME_boundary` |

Rule: take the token **verbatim** after `boundary=`; strip surrounding double quotes only;
**never** strip angle brackets or leading dashes; the delimiter is `"--" + token`.
If the header carries no boundary at all (seen on one 5.1.x build), fall back to sniffing:
buffer up to 512 bytes, find the first line matching `^--\S{1,70}\r?$`, and adopt it.

### 14.2 A realistic wire sample

```
--<boundary>
Content-Type: application/xml; charset="UTF-8"
Content-Length: 671

<?xml version="1.0" encoding="UTF-8"?>
<EventNotificationAlert version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
<ipAddress>192.168.1.64</ipAddress>
<portNo>80</portNo>
<protocol>HTTP</protocol>
<macAddress>44:47:cc:11:22:33</macAddress>
<channelID>1</channelID>
<dateTime>2024-05-01T12:34:56+08:00</dateTime>
<activePostCount>1</activePostCount>
<eventType>VMD</eventType>
<eventState>active</eventState>
<eventDescription>Motion alarm</eventDescription>
<channelName>Driveway</channelName>
<DetectionRegionList>
<DetectionRegion>
<regionID>1</regionID>
<sensitivityLevel>60</sensitivityLevel>
<RegionCoordinatesList>
<RegionCoordinates><positionX>0</positionX><positionY>0</positionY></RegionCoordinates>
<RegionCoordinates><positionX>1000</positionX><positionY>0</positionY></RegionCoordinates>
<RegionCoordinates><positionX>1000</positionX><positionY>560</positionY></RegionCoordinates>
<RegionCoordinates><positionX>0</positionX><positionY>560</positionY></RegionCoordinates>
</RegionCoordinatesList>
</DetectionRegion>
</DetectionRegionList>
</EventNotificationAlert>

--<boundary>
Content-Type: image/jpeg
Content-Length: 30245

<30245 raw JPEG bytes, no encoding>

--<boundary>
Content-Type: application/xml; charset="UTF-8"
Content-Length: 402

<?xml version="1.0" encoding="UTF-8"?>
<EventNotificationAlert version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
<ipAddress>192.168.1.64</ipAddress>
<portNo>80</portNo>
<protocol>HTTP</protocol>
<macAddress>44:47:cc:11:22:33</macAddress>
<channelID>1</channelID>
<dateTime>2024-05-01T12:35:01+08:00</dateTime>
<activePostCount>0</activePostCount>
<eventType>videoloss</eventType>
<eventState>inactive</eventState>
<eventDescription>videoloss alarm</eventDescription>
</EventNotificationAlert>

--<boundary>
```

The final part in that sample is the **heartbeat**. When nothing is happening, Hikvision
devices emit a `videoloss` / `inactive` / `activePostCount 0` part every ~5 s (some models
every 30 s, some only on state change). It is the liveness signal, and it must **not** be
surfaced as an event.

### 14.3 `EventNotificationAlert` fields

| Element | Type | Notes |
| --- | --- | --- |
| `ipAddress` / `ipv6Address` | String | the *device's* address; for NVR channels it is the NVR's |
| `portNo` | Int | device HTTP port |
| `protocol` | String | `HTTP` / `HTTPS` |
| `macAddress` | String | device MAC; stable identity |
| `channelID` | Int | **video input channel**, 1-based. Absent on some device-level events ⇒ treat as 0 = device-wide. |
| `dynChannelID` | Int | NVR only: the dynamic (IP) channel number. **When present it, not `channelID`, is the channel the user sees.** |
| `channelName` | String | NVR/6.x only |
| `dateTime` | Date | device-local or offset-bearing; see §7.5 |
| `activePostCount` | Int | 0 for heartbeats; ≥1 and increasing while an alarm persists. Used for dedupe and for "still active" |
| `eventType` | String | see the table below |
| `eventState` | String | `active` \| `inactive` |
| `eventDescription` | String | human text, firmware-localized — **never** shown to the user, we localize ourselves |
| `inputIOPortID` | Int | `io` events only |
| `DetectionRegionList` | list | polygon(s), see §14.4 |
| `Extensions/serialNumber` | String | 6.x |

`eventType` values Vigil recognizes (compared **lowercased**):

| Wire value | `VigilEventType` | Default UI severity | Notes |
| --- | --- | --- | --- |
| `VMD` | `.motion` | info | classic motion detection |
| `linedetection` | `.lineCrossing` | warning | tripwire |
| `fielddetection` | `.intrusion` | warning | intrusion / field detection |
| `regionEntrance` | `.regionEntrance` | warning | |
| `regionExiting` | `.regionExit` | warning | |
| `facedetection` | `.faceDetected` | info | detection only; no recognition |
| `tamperdetection` | `.tamper` | critical | also seen as `shelteralarm` |
| `io` | `.alarmInput` | warning | uses `inputIOPortID` |
| `videoloss` | `.videoLoss` | critical | **also the heartbeat carrier** — see §14.5 |
| `diskfull` | `.diskFull` | critical | |
| `diskerror` | `.diskError` | critical | |
| `illegalaccess` | `.illegalAccess` | warning | failed logins on the device |
| `nicbroken` | `.networkBroken` | critical | |
| `ipconflict` | `.ipConflict` | warning | |
| `badvideo` | `.badVideo` | warning | |
| `pirAlarm` | `.pir` | info | |
| `unattendedBaggage` | `.unattendedBaggage` | warning | |
| `attendedBaggage` | `.objectRemoved` | warning | |
| `audioexception` | `.audioException` | info | |
| `scenechangedetection` | `.sceneChange` | warning | |
| anything else | `.other(raw)` | info | never dropped; shown with the raw name |

```swift
public struct EventNotification: Sendable, Hashable {
    public let deviceIP: String?
    public let deviceMAC: String?
    public let channel: ChannelID          // dynChannelID ?? channelID ?? 0
    public let channelName: String?
    public let timestamp: Date
    public let timestampWasNaive: Bool
    public let type: VigilEventType
    public let rawType: String
    public let state: EventState           // .active | .inactive
    public let activePostCount: Int
    public let ioPort: Int?
    public let regions: [DetectionRegion]
    /// JPEG bytes from a following image/jpeg part, when the device sent one.
    public var snapshot: Data?
    public var isHeartbeat: Bool {
        type == .videoLoss && state == .inactive && activePostCount == 0 && regions.isEmpty
    }
    public init(document: ISAPIDocument) throws
}
```

### 14.4 `DetectionRegionList` polygons

```swift
public struct DetectionRegion: Sendable, Hashable {
    public let regionID: Int
    public let sensitivityLevel: Int?          // 0…100
    /// Normalized to 0…1 in a **top-left-origin** space, ready for SwiftUI overlay.
    public let polygon: [CGPoint]
    /// Optional smart-event target box, same normalization.
    public let targetRect: CGRect?
}
```

Wire coordinates are integers in **0…1000** on both axes (`positionX`, `positionY`), with the
origin at the **lower-left**. Conversion for display:

```
displayX = positionX / 1000
displayY = 1 - positionY / 1000
```

Some smart-event firmwares emit 0…10000 instead. Detection rule: if any coordinate exceeds
1000, divide by 10000; else by 1000. Fewer than 3 points ⇒ the region is dropped (a 2-point
"polygon" from `linedetection` is instead exposed as `polygon` of exactly 2 points and drawn
as a line — that is legitimate and must not be dropped, so the rule is: keep 2 points only
for `.lineCrossing`, drop <3 otherwise).

`<TargetRect><X>…</X><Y>…</Y><width>…</width><height>…</height></TargetRect>` uses the same
normalization and is present on smart events from 5.5+.

### 14.5 Streaming multipart parser

Bounded-memory requirement: the parser must never hold more than a fixed budget regardless of
what the device sends, including a device that sends a 2 GiB "part" or no delimiter at all.

```swift
public struct MultipartStreamParser: Sendable {
    public struct Limits: Sendable {
        public var maxHeaderBytes: Int = 8 * 1024          // per part
        public var maxTextPartBytes: Int = 256 * 1024      // XML parts; real ones are <2 KiB
        public var maxBinaryPartBytes: Int = 4 * 1024 * 1024   // JPEG parts
        public var maxPreambleBytes: Int = 64 * 1024
        public init() {}
    }

    public enum Output: Sendable {
        /// Headers of a new part (keys lowercased).
        case partBegan(headers: [String: String], declaredLength: Int?)
        /// A chunk of the current part's body. Emitted incrementally; never accumulated
        /// by the parser for binary parts.
        case partData(Data)
        /// Current part finished cleanly.
        case partEnded
        /// Part exceeded its limit; body bytes after this point are discarded until the
        /// next delimiter. Reported so we can count and log, not throw.
        case partTruncated(reason: String)
        /// Closing delimiter "--boundary--" seen.
        case streamEnded
    }

    public init(boundary: String, limits: Limits = .init())

    /// Feeds bytes; returns zero or more outputs. Never throws for device misbehaviour that
    /// is recoverable — it resynchronizes and reports `.partTruncated`. Throws only for
    /// unrecoverable framing loss (`ISAPIError.multipartProtocolError`).
    public mutating func ingest(_ bytes: Data) throws -> [Output]

    /// Called when the byte stream ends. Flushes a final `.partEnded` if a part was open.
    public mutating func finish() -> [Output]
}
```

**State machine.**

| State | Behaviour | Bounded by |
| --- | --- | --- |
| `preamble` | scan for the first delimiter; discard everything before it | `maxPreambleBytes`, then throw |
| `headers` | accumulate until `CRLFCRLF` or `LFLF`; parse `name: value` lines | `maxHeaderBytes`, then `.partTruncated` + resync |
| `bodyCounted(remaining:)` | `Content-Length` known: emit `min(remaining, chunk.count)` bytes directly, then expect the delimiter | exact; no scanning |
| `bodyScanning` | no `Content-Length`: emit bytes while retaining a **carry** of the last `boundary.utf8.count + 4` bytes so a delimiter split across two TCP reads is still found | carry is O(70 bytes) |
| `resync` | discard bytes, scanning only for the delimiter with the same small carry | O(70 bytes) |
| `ended` | ignore everything | — |

The critical invariant: **in body states the parser's retained buffer is at most
`boundary.count + 4` bytes.** Body bytes are handed out as they arrive. XML accumulation
happens one layer up, in the consumer, which caps it at `maxTextPartBytes`; JPEG
accumulation happens in the consumer too and is capped at `maxBinaryPartBytes`, dropping the
image (but keeping the event) on overflow.

Line-ending tolerance: delimiters and header terminators accept `CRLF` **or** bare `LF`.
Hikvision 5.2.x sends bare `LF` after the boundary and `CRLF` in headers, in the same stream.

Delimiter matching detail: a delimiter is `--<token>` optionally followed by `--` (closing),
then optional whitespace, then a line ending. A bare occurrence of the token inside JPEG data
that is not preceded by CRLF/LF **must not** match — the scanner therefore searches for
`LF + "--" + token` (and separately handles the stream's very first delimiter, which has no
preceding LF).

Search implementation: `Data.range(of: needle, in: searchWindow)` over
`carry + newChunk`. For a 70-byte needle this is fast enough (a 4 MiB JPEG at 8 MiB/s costs
<1 ms/MiB); no need for Boyer-Moore, but the needle is hoisted out of the loop as a
`[UInt8]` and compared with `memcmp` semantics via `withUnsafeBytes`.

### 14.6 The consumer: `AlertStreamMonitor`

```swift
public actor AlertStreamMonitor {
    public init(session: ISAPIDeviceSession,
                policy: Policy = .init(),
                clock: any VigilClock,
                logger: any VigilLogger)

    public struct Policy: Sendable {
        public var backoff: [TimeInterval] = [1, 2, 4, 8, 15, 30, 60]
        public var jitterFraction: Double = 0.20
        public var healthyResetInterval: TimeInterval = 120
        public var idleWatchdog: TimeInterval = 90
        public var livenessProbeAfterIdle: TimeInterval = 60
        public var maxAuthFailures: Int = 2
        public var attachSnapshots: Bool = true
        public var snapshotMaxBytes: Int = 4 * 1024 * 1024
        public init() {}
    }

    /// Hot stream of decoded events (heartbeats excluded). Buffering policy
    /// `.bufferingNewest(256)`: an event backlog must never grow without bound.
    public var events: AsyncStream<EventNotification> { get }
    /// Connection state for the UI badge.
    public var state: AsyncStream<AlertStreamState> { get }

    public func start()
    public func stop() async
}

public enum AlertStreamState: Sendable, Equatable {
    case idle
    case connecting(attempt: Int)
    case streaming(since: Date)
    case backingOff(until: Date, attempt: Int, reason: String)
    case unsupported                 // device answered 403/404
    case authFailed                  // do not retry; needs new credentials
    case stopped
}
```

**Pairing XML parts with image parts.** A JPEG part belongs to the *immediately preceding*
XML part. The monitor holds at most one pending `EventNotification`; when the next part is
`image/jpeg` it attaches it, otherwise it emits the pending event as-is. A pending event is
also flushed after **1.5 s** so an event is never delayed waiting for an image that will not
come.

**Reconnect policy.**

| Trigger | Action |
| --- | --- |
| Stream ends cleanly or errors | backoff step `n`, ±20% jitter, reconnect. `n` advances per consecutive failure, capped at 60 s. |
| ≥1 part received and 120 s elapsed | reset `n` to 0 |
| No bytes for 60 s | issue `GET /ISAPI/Security/userCheck` on the `.control` lane. Success ⇒ keep waiting (a quiet device is legal). Failure ⇒ tear down and reconnect immediately. |
| No bytes for 90 s | tear down and reconnect regardless of probe result |
| HTTP 401 | re-auth once with a fresh challenge; second 401 ⇒ `.authFailed`, stop permanently, notify `VigilCore` |
| HTTP 403 / 404 / 405 | `.unsupported`, stop permanently, record negative capability. **No synthetic event fallback** — Vigil shows "This camera does not support the event stream" in the camera's health panel rather than inventing events. |
| Device reboot detected (uptime dropped) | immediate reconnect, reset `n` |
| `NWPathMonitor` reports the network came back (`VigilCore` calls `start()` again) | immediate reconnect, reset `n` |
| App sleep / display off | `stop()`; on wake `start()` with `n = 0` |

At most **one** `AlertStreamMonitor` per device, owned by `ISAPIDeviceSession`, referenced by
`VigilCore.EventCenter`. Dedupe, coalescing, persistence, and notifications are
`VigilCore`'s job (see spec-core); `VigilISAPI` delivers every non-heartbeat event exactly
once.

We deliberately do **not** use `PUT /ISAPI/Event/notification/httpHosts` (device-push to a
listener we run). It would require an inbound TCP listener, a firewall exception, and
writing configuration into the customer's camera. Pull-only is the decision.

### 14.7 `GET /ISAPI/Event/triggers`

Read-only in Vigil: it tells us which event types the device has *configured*, which lets the
event feed show a helpful "motion detection is off for this channel" hint.

```xml
<EventTriggerList version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <EventTrigger version="2.0">
    <id>VMD-1</id>
    <eventType>VMD</eventType>
    <eventDescription>Motion Detection</eventDescription>
    <videoInputChannelID>1</videoInputChannelID>
    <dynVideoInputChannelID>1</dynVideoInputChannelID>
    <EventTriggerNotificationList>
      <EventTriggerNotification>
        <id>beep</id>
        <notificationMethod>beep</notificationMethod>
        <notificationRecurrence>beginning</notificationRecurrence>
      </EventTriggerNotification>
      <EventTriggerNotification>
        <id>record</id>
        <notificationMethod>record</notificationMethod>
        <notificationRecurrence>beginning</notificationRecurrence>
      </EventTriggerNotification>
    </EventTriggerNotificationList>
  </EventTrigger>
  <EventTrigger version="2.0">
    <id>tamperdetection-1</id>
    <eventType>tamperdetection</eventType>
    <eventDescription>Tamper Detection</eventDescription>
    <videoInputChannelID>1</videoInputChannelID>
    <EventTriggerNotificationList/>
  </EventTrigger>
</EventTriggerList>
```

`id` format is `{eventType}-{channel}` (and `{eventType}-{channel}-{index}` for IO ports).
`notificationMethod` values: `email`, `IM`, `IO`, `syslog`, `HTTP`, `FTP`, `beep`, `ptz`,
`record`, `monitorAlarm`, `center`, `LightAudioAlarm`, `focus`, `trace`, `cloud`.

```swift
public struct EventTrigger: Sendable, Hashable {
    public let id: String
    public let type: VigilEventType
    public let rawType: String
    public let channel: ChannelID
    public let notificationMethods: [String]
    public var isConfigured: Bool { !notificationMethods.isEmpty }
}
```

`GET /ISAPI/Event/triggers/{id}` returns the single `<EventTrigger>`. `PUT` is supported by
the device but Vigil never writes triggers: reconfiguring a customer's alarm actions is out of
scope and dangerous. Cache TTL 5 min.

### 14.8 `GET /ISAPI/Event/schedules/{triggerID}`

Arming schedule, read-only and best-effort. Path and root element vary by firmware; treat a
404/403 as "unknown schedule" and show nothing rather than an error.

```xml
<EventSchedule version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <id>VMD-1</id>
  <TimeBlockList>
    <TimeBlock>
      <dayOfWeek>Monday</dayOfWeek>
      <TimeRange><beginTime>00:00:00</beginTime><endTime>24:00:00</endTime></TimeRange>
    </TimeBlock>
    <TimeBlock>
      <dayOfWeek>Tuesday</dayOfWeek>
      <TimeRange><beginTime>08:00:00</beginTime><endTime>18:00:00</endTime></TimeRange>
    </TimeBlock>
  </TimeBlockList>
</EventSchedule>
```

Path probe order, remembered per device: `/ISAPI/Event/schedules/{triggerID}` →
`/ISAPI/Event/schedules` (list form, filter by `id`) → give up.
`endTime` of `24:00:00` is legal and means end-of-day; the parser maps it to 86400 s.

```swift
public struct EventSchedule: Sendable, Hashable {
    public struct Block: Sendable, Hashable {
        public let weekday: Int          // 1 = Monday … 7 = Sunday
        public let startSeconds: Int     // 0…86400
        public let endSeconds: Int
    }
    public let triggerID: String
    public let blocks: [Block]
    public var isAlwaysArmed: Bool       // 7 blocks covering 0…86400
}
```

### 14.9 `GET`/`PUT /ISAPI/System/Video/inputs/channels/{ch}/motionDetection`

Read-modify-write, like all Hikvision configuration.

```xml
<MotionDetection version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <enabled>true</enabled>
  <enableHighlight>true</enableHighlight>
  <samplingInterval>2</samplingInterval>
  <startTriggerTime>500</startTriggerTime>
  <endTriggerTime>500</endTriggerTime>
  <regionType>grid</regionType>
  <Grid>
    <rowGranularity>18</rowGranularity>
    <columnGranularity>22</columnGranularity>
  </Grid>
  <MotionDetectionLayout version="2.0">
    <sensitivityLevel>60</sensitivityLevel>
    <layout>
      <gridMap>fffffcfffffcfffffcfffffcfffffcfffffc000000000000000000000000…</gridMap>
    </layout>
  </MotionDetectionLayout>
</MotionDetection>
```

| Field | Range | Units |
| --- | --- | --- |
| `enabled` | bool | — |
| `samplingInterval` | 1…10 | frames between samples |
| `startTriggerTime` / `endTriggerTime` | 0…10000 | ms |
| `sensitivityLevel` | 0…100 | higher = more sensitive |
| `regionType` | `grid` \| `ROI` | grid is universal |
| `rowGranularity` × `columnGranularity` | usually 18 × 22 | grid cells |

**`gridMap` encoding** (the part everyone gets wrong): a hex string of
`rowGranularity × ceil(columnGranularity / 4)` characters. Each row contributes
`ceil(columns/4)` hex digits = `4 × ceil(columns/4)` bits, MSB first, where bit *k* (from the
most significant bit of the row's first hex digit) is column *k*. Trailing bits beyond
`columnGranularity` are padding and must be written as 0. For the common 22×18 grid:
`ceil(22/4) = 6` hex digits per row × 18 rows = **108 hex characters**, of which the last 2
bits of each row are padding.

```swift
public struct MotionGrid: Sendable, Hashable {
    public let rows: Int, columns: Int
    public private(set) var cells: [Bool]      // row-major, rows*columns
    public init(rows: Int, columns: Int)
    public init?(hex: String, rows: Int, columns: Int)
    public subscript(row: Int, column: Int) -> Bool { get set }
    public var hexString: String               // padding bits forced to 0
    public var isFullFrame: Bool
    public mutating func fill(_ value: Bool)
    /// Rasterizes a normalized (0…1, top-left origin) polygon into cells.
    public mutating func set(polygon: [CGPoint], to value: Bool)
}

public struct MotionDetectionConfig: Sendable, Hashable {
    public var enabled: Bool
    public var sensitivity: Int
    public var samplingInterval: Int
    public var startTriggerMS: Int
    public var endTriggerMS: Int
    public var grid: MotionGrid
    public var originalNode: XMLNode           // for RMW
    public init(document: ISAPIDocument) throws
    public func patchedNode(enabled: Bool?, sensitivity: Int?, grid: MotionGrid?) -> XMLNode
}
```

`PUT` sends the entire `<MotionDetection>` element back with only the intended fields
changed. Response `<ResponseStatus>`; `statusCode 7` (reboot required) does occur on DVRs.

Vigil's motion UI: an enable toggle, a sensitivity slider, and a paint-on-video grid editor
(the grid is drawn as a 22×18 overlay on the live view with the top-left cell at the image's
top-left — note the grid, unlike detection-region polygons, is **top-left origin, row-major**,
so no Y flip). Whole-frame is the default for new users.

---

## 15. Recorded video: search, tracks, storage, timeline

### 15.1 `GET /ISAPI/ContentMgmt/record/tracks`

A *track* is a recording stream. `trackID = channel * 100 + streamIndex`, same arithmetic as
streaming channels but a distinct concept (a channel can have a main-stream track with no
sub-stream track, and NVR channels can have tracks that no longer stream).

```xml
<TrackList version="1.0" xmlns="http://www.hikvision.com/ver10/XMLSchema">
  <Track>
    <id>101</id>
    <Channel>1</Channel>
    <Enable>true</Enable>
    <Description>Track</Description>
    <TrackGUID>{B4D0F1C2-0000-0000-0000-000000000000}</TrackGUID>
    <DefaultRecordingMode>CMR</DefaultRecordingMode>
    <Duration>P30DT0H0M0S</Duration>
    <Loop>true</Loop>
    <SrcDescriptor>
      <SrcGUID>{A1B2C3D4-0000-0000-0000-000000000000}</SrcGUID>
      <SrcType>camera</SrcType>
      <SrcName>Driveway</SrcName>
      <SrcIndex>1</SrcIndex>
      <SrcLocation>local</SrcLocation>
      <StreamHint>video, audio</StreamHint>
    </SrcDescriptor>
  </Track>
  <Track>
    <id>102</id>
    <Channel>1</Channel>
    …
  </Track>
</TrackList>
```

Note the `ver10` namespace and the **capitalized** `<Channel>`, `<Enable>` — the
`ContentMgmt` family is older and uses different casing conventions from `/Streaming`. Our
path matching is case-insensitive so this costs nothing, but hand-written body XML must copy
the device's casing.

| Field | Notes |
| --- | --- |
| `id` | trackID |
| `Channel` | video input channel |
| `Enable` | recording enabled for this track |
| `DefaultRecordingMode` | `CMR` (continuous), `EMR` (event), `MMR` (manual), `OMR` (command) |
| `Duration` | ISO 8601 duration = retention period. `P30DT0H0M0S` = 30 days. |
| `Loop` | overwrite oldest when full |
| `SrcDescriptor/StreamHint` | `video` or `video, audio` — tells us whether playback will have audio |

```swift
public struct RecordTrack: Sendable, Hashable, Codable, Identifiable {
    public let id: TrackID
    public let channel: ChannelID
    public let enabled: Bool
    public let sourceName: String?
    public let recordingMode: String?
    public let retention: TimeInterval?     // parsed from Duration
    public let hasAudio: Bool
    public let loopRecording: Bool
}
```

Only tracks with `Enable == true` are offered in the playback UI. Cache TTL 5 min.
`GET /ISAPI/ContentMgmt/record/tracks/{id}` returns a single `<Track>`.

An ISO 8601 duration parser is needed for `Duration`; it handles
`P<n>Y<n>M<n>DT<n>H<n>M<n>S` with any subset present, treating a year as 365 d and a month as
30 d (retention display only, so the approximation is fine and is documented in the UI as
"about 30 days").

### 15.2 `POST /ISAPI/ContentMgmt/search`

The universal recording search. `Content-Type: application/xml`. Timeout 15 s (a month-wide
search on a busy 32-channel NVR genuinely takes 8 s).

```
POST /ISAPI/ContentMgmt/search HTTP/1.1
Content-Type: application/xml
Content-Length: 512

<?xml version="1.0" encoding="UTF-8"?>
<CMSearchDescription>
  <searchID>{6F9619FF-8B86-D011-B42D-00CF4FC964FF}</searchID>
  <trackIDList>
    <trackID>101</trackID>
  </trackIDList>
  <timeSpanList>
    <timeSpan>
      <startTime>2024-05-01T00:00:00Z</startTime>
      <endTime>2024-05-01T23:59:59Z</endTime>
    </timeSpan>
  </timeSpanList>
  <contentTypeList>
    <contentType>video</contentType>
  </contentTypeList>
  <maxResults>40</maxResults>
  <searchResultPostion>0</searchResultPostion>
  <metadataList>
    <metadataDescriptor>//recordType.meta.std-cgi.com</metadataDescriptor>
  </metadataList>
</CMSearchDescription>
```

**Element order is mandatory** in exactly the sequence above; 5.4.x DVRs reject reordered
documents with `invalidXMLContent`. Do not add a namespace to this body.

| Element | Required | Notes |
| --- | --- | --- |
| `searchID` | yes | A GUID in braces, uppercase hex, format `{8-4-4-4-12}`. **Generate a new one per logical search and reuse it across pages** — the device keys its result cursor by `searchID`. Reusing a completed search's ID returns stale results; using a fresh ID per page breaks paging. |
| `trackIDList/trackID` | yes | one or more. Multi-track search works but interleaves results; Vigil searches **one track per request** so paging and timeline math stay simple. |
| `timeSpanList/timeSpan/startTime`,`endTime` | yes | ISO 8601. **Send UTC with a `Z`.** Naive local times are interpreted in device time and are a bug source. Max span accepted is device-dependent; Vigil never asks for more than 24 h in one search. |
| `contentTypeList/contentType` | no | `video`, `audio`, `metadata`. Omitted ⇒ all. Vigil sends `video`. |
| `maxResults` | yes | Device max is nominally 50; **use 40**. Values >50 yield `badParameters` on several firmwares. |
| `searchResultPostion` | yes | **Note the real misspelling** (`Postion`, not `Position`). Zero-based offset of the first result to return. This is the paging cursor. |
| `metadataList/metadataDescriptor` | yes on DVR/NVR, optional on cameras | See the descriptor table below. Omitting it returns nothing on some DVRs, so always send it. |

`metadataDescriptor` values:

| Descriptor | Meaning |
| --- | --- |
| `//recordType.meta.std-cgi.com` | all record types (Vigil's default) |
| `//recordType.meta.std-cgi.com/timing` | scheduled/continuous recordings only |
| `//recordType.meta.std-cgi.com/motion` | motion-triggered only |
| `//recordType.meta.std-cgi.com/alarm` | alarm-input-triggered only |
| `//recordType.meta.std-cgi.com/manual` | manual recordings only |
| `//recordType.meta.std-cgi.com/command` | command-triggered only |

If a filtered descriptor returns `badParameters`, retry once with the generic
`//recordType.meta.std-cgi.com` and filter client-side on
`metadataMatches/metadataDescriptor` from the results. Record
`recordTypeFilterUnsupported` in the quirk record.

Response:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CMSearchResult version="1.0" xmlns="http://www.hikvision.com/ver10/XMLSchema">
  <searchID>{6F9619FF-8B86-D011-B42D-00CF4FC964FF}</searchID>
  <responseStatus>true</responseStatus>
  <responseStatusStrip>MORE</responseStatusStrip>
  <numOfMatches>40</numOfMatches>
  <matchList>
    <searchMatchItem>
      <sourceID>{A1B2C3D4-0000-0000-0000-000000000000}</sourceID>
      <trackID>101</trackID>
      <timeSpan>
        <startTime>2024-05-01T08:00:00Z</startTime>
        <endTime>2024-05-01T08:14:59Z</endTime>
      </timeSpan>
      <mediaSegmentDescriptor>
        <contentType>video</contentType>
        <codecType>H.264-BP</codecType>
        <playbackURI>rtsp://192.168.1.64/Streaming/tracks/101?starttime=20240501T080000Z&amp;endtime=20240501T081459Z&amp;name=ch01_00000000019000000&amp;size=536870912</playbackURI>
      </mediaSegmentDescriptor>
      <metadataMatches>
        <metadataDescriptor>recordType.meta.std-cgi.com/timing</metadataDescriptor>
      </metadataMatches>
    </searchMatchItem>
    <searchMatchItem>
      …
    </searchMatchItem>
  </matchList>
</CMSearchResult>
```

| Field | Notes |
| --- | --- |
| `responseStatus` | `true` even when there are zero matches |
| `responseStatusStrip` | **the paging signal**: `OK` = this is the last page; `MORE` = call again with `searchResultPostion += numOfMatches`; `NO MATCHES` = empty result set |
| `numOfMatches` | number of `searchMatchItem`s in *this* page |
| `codecType` | `H.264-BP`, `H.264-MP`, `H.264-HP`, `H.265`, `MJPEG`, `MPEG4`, `SVAC`. Parsed with the same prefix logic as `videoCodecType`. |
| `playbackURI` | the RTSP URL to play this segment — see §15.3 |
| `metadataMatches/metadataDescriptor` | why this segment exists: `…/timing`, `…/motion`, `…/alarm`, `…/manual`, `…/command`. Note the response omits the leading `//`. |

Paging loop (normative):

```swift
public struct RecordSearchQuery: Sendable {
    public var track: TrackID
    public var start: Date
    public var end: Date
    public var recordTypes: Set<RecordType> = []      // empty = all
    public var pageSize: Int = 40
    public var hardSegmentCap: Int = 2000             // safety valve per query
}

public struct RecordSegment: Sendable, Hashable, Identifiable {
    public var id: String { "\(track.value)-\(start.timeIntervalSince1970)" }
    public let track: TrackID
    public let start: Date
    public let end: Date
    public let codec: VideoCodec
    public let contentType: String
    public let recordType: RecordType
    public let locator: PlaybackLocator
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public enum RecordType: String, Sendable, Codable, CaseIterable {
    case timing, motion, alarm, manual, command, other
}

extension ISAPIDeviceSession {
    /// Pages until responseStatusStrip != "MORE", the cap is hit, or the task is cancelled.
    /// Uses one searchID for the whole query.
    public func searchRecordings(_ q: RecordSearchQuery) async throws -> [RecordSegment]
}
```

Errors: `403 notSupport` on cameras without storage ⇒ `.notSupported`, playback UI hidden.
`400 badParameters` ⇒ almost always a bad time format or `maxResults > 50`; log the body.
An empty `matchList` with `NO MATCHES` is a success with zero segments, never an error.

### 15.3 `playbackURI` and `PlaybackLocator`

Form:

```
rtsp://192.168.1.64/Streaming/tracks/101
  ?starttime=20240501T080000Z
  &endtime=20240501T081459Z
  &name=ch01_00000000019000000
  &size=536870912
```

| Query item | Meaning |
| --- | --- |
| `starttime` | compact UTC, `yyyyMMdd'T'HHmmss'Z'` |
| `endtime` | compact UTC |
| `name` | device-internal file name; **pass through verbatim**, do not synthesize |
| `size` | file size in bytes; informational |

Handling rules — all normative, because getting them wrong is the classic "playback works on
some cameras" bug:

1. **Rewrite scheme/host/port, keep path and query verbatim.** The device fills in the
   address it thinks it has, which on a multi-homed NVR or behind NAT is not the address we
   reached it on. Vigil replaces host/port with the known-good RTSP endpoint from the camera
   record and keeps everything after the path intact.
2. **Do not re-encode the query.** `&amp;` in the XML becomes `&` after XML unescaping;
   nothing else is escaped and nothing else needs escaping. Running the query through
   `URLComponents` re-encodes `name`'s underscores-and-digits harmlessly but has been observed
   to reorder items on some Foundation versions — so we store the raw query string and
   concatenate.
3. **Never embed credentials.**
4. Some firmwares omit `name`/`size`. That is fine; `starttime`/`endtime` are sufficient.
5. Some firmwares emit `/Streaming/tracks/101/` (trailing slash) — normalize by trimming.

```swift
/// A fully resolved, ready-to-play recorded segment address. Consumed by VigilRTSP.
public struct PlaybackLocator: Sendable, Hashable, Codable {
    public let path: String        // "/Streaming/tracks/101"
    public let rawQuery: String    // "starttime=…&endtime=…&name=…&size=…"
    public let start: Date
    public let end: Date
    public let fileName: String?
    public let sizeBytes: Int64?

    /// Builds the request URI VigilRTSP puts on the RTSP request line.
    public func requestURI(host: String, port: Int, useTLS: Bool) -> String
    /// Range header value for the PLAY request: "clock=20240501T080000Z-20240501T081459Z".
    public var clockRange: String

    /// Constructs a locator without a search, for direct seeking (see below).
    public init(track: TrackID, start: Date, end: Date)
    public init?(playbackURI: String)
}
```

**Direct seeking without a search.** Hikvision accepts a synthesized URI:
`rtsp://host/Streaming/tracks/101?starttime=20240501T081000Z` (no `endtime` = play to the end
of available footage). Vigil uses this for timeline scrubbing *within* a segment it already
knows about, avoiding a search round trip per scrub. It does **not** use it to discover
footage — an arbitrary time with no recording yields an RTSP 404 or an immediately-ending
stream.

**Time zone trap.** `starttime` is UTC with a `Z`, but a number of firmwares interpret it as
**device-local** time despite the `Z`. Detection and correction: after `PLAY`, `VigilRTSP`
reports the first frame's `RTP-Info rtptime`/`Range` echo; if the device's echoed range differs
from what we asked by exactly the device's UTC offset, the quirk
`playbackTimesAreDeviceLocal` is set and all subsequent locators are built with device-local
compact times. The check is cheap (one comparison) and the flag is persisted per device.

### 15.4 `GET /ISAPI/ContentMgmt/Storage`

```xml
<storage version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <hddList size="2">
    <hdd>
      <id>1</id>
      <hddName>hdd1</hddName>
      <hddPath>/</hddPath>
      <hddType>SATA</hddType>
      <status>ok</status>
      <capacity>3815447</capacity>
      <freeSpace>1258291</freeSpace>
      <property>RW</property>
      <group>1</group>
    </hdd>
    <hdd>
      <id>2</id>
      <hddName>sd1</hddName>
      <hddType>SD</hddType>
      <status>unformatted</status>
      <capacity>61035</capacity>
      <freeSpace>0</freeSpace>
      <property>RW</property>
    </hdd>
  </hddList>
  <nasList size="0"/>
  <workMode>group</workMode>
</storage>
```

| Field | Units | Values |
| --- | --- | --- |
| `capacity`, `freeSpace` | **MB** (1 MB = 1 000 000 B in Hikvision's accounting; we display with `ByteCountFormatter` using `.decimal` so the numbers match the camera's own web UI) | |
| `hddType` | — | `SATA`, `SD`, `eSATA`, `NAS`, `local`, `iSCSI` |
| `status` | — | `ok`, `unformatted`, `unformated` (sic), `error`, `sleeping`, `idle`, `mismatch`, `notExist`, `formatting` |
| `property` | — | `RW`, `RO`, `redundancy` |
| `workMode` | — | `group`, `quota` |

`<nasList>` entries carry `<id>`, `<addressingFormatType>`, `<ipAddress>`, `<mountType>`
(`NFS`/`SMB`), `<path>`, plus the same `status`/`capacity`/`freeSpace`.

Quota is only meaningful when `workMode == quota`:
`GET /ISAPI/ContentMgmt/Storage/quota` →
`<QuotaList><Quota><id>1</id><type>picture|record</type><totalSpace>…</totalSpace><usedSpace>…</usedSpace></Quota></QuotaList>`
(MB). This endpoint 404s on many devices; on failure the quota section of the UI is hidden.
Never surface an error for it.

```swift
public struct StorageVolume: Sendable, Hashable, Identifiable {
    public let id: Int
    public let name: String?
    public let kind: Kind                    // .sata, .sd, .nas(mount: String), .other(String)
    public let status: Status                 // .ok, .unformatted, .error, .sleeping, .formatting, .absent, .other
    public let capacityMB: Int
    public let freeSpaceMB: Int
    public let isReadOnly: Bool
    public var usedFraction: Double { capacityMB > 0 ? 1 - Double(freeSpaceMB)/Double(capacityMB) : 0 }
}

public struct StorageInfo: Sendable, Hashable {
    public let volumes: [StorageVolume]
    public let workMode: String
    public let quotas: [StorageQuota]        // empty when unsupported
    public var totalCapacityMB: Int
    public var totalFreeMB: Int
    /// True when any volume is in .error/.unformatted — surfaced as a camera-row warning.
    public var needsAttention: Bool
}
```

Poll cadence: on device connect, then every **5 min** while a playback or health view is open.

### 15.5 The timeline: exactly what we call

**Decision.** The playback timeline for a selected day is painted **exclusively** from
`POST /ISAPI/ContentMgmt/search` results for that day. There is no other endpoint we depend
on. Rationale: `search` is supported by every device that can play back at all, its response
gives exact segment boundaries *and* record types (which is what the heatmap colours encode),
and its paging behaviour is well defined. Any "distribution" endpoint is an optional
accelerator only.

Algorithm (normative):

```
buildDayIndex(track, dayStart /* device-local midnight, converted to UTC */):
    segments = searchRecordings(track: track,
                               start: dayStart,
                               end: dayStart + 86400,
                               recordTypes: [],           // all
                               pageSize: 40,
                               hardSegmentCap: 2000)
    merge adjacent segments of the SAME recordType whose gap < 2.0 s
    bins = [RecordType?](repeating: nil, count: 1440)     // one per minute
    for each merged segment:
        for minute in floor(start)…ceil(end):
            bins[minute] = max(bins[minute], segment.recordType, by: severity)
    return RecordDayIndex(day: dayStart, segments: merged, minuteBins: bins,
                          truncated: segments.count >= hardSegmentCap)
```

Severity order for bin colouring (higher wins when two record types share a minute):
`alarm > motion > manual > command > timing`. The UI paints
`timing` in a muted accent, `motion` in the warning accent, `alarm` in the critical accent.

```swift
public struct RecordDayIndex: Sendable, Hashable, Codable {
    public let track: TrackID
    public let dayStartUTC: Date
    public let segments: [RecordSegment]
    /// 1440 entries, one per minute of the device-local day. nil = no footage.
    public let minuteBins: [RecordType?]
    public let truncated: Bool
    public var totalRecordedSeconds: TimeInterval
    public var coverageFraction: Double        // 0…1, for the "12 h 04 m recorded" label
}
```

Caching: `RecordDayIndex` is cached per `(deviceID, trackID, dayStartUTC)`.
Past days are immutable and persisted in
`~/Library/Application Support/Vigil/Cache/recordIndex/` as JSON (owned by `VigilCore`, which
also caps the directory at 20 MB LRU); today's index has a 60 s TTL and is refreshed on
timeline focus.

Prefetch: opening the timeline builds the selected day, then, at `.utility` priority with
concurrency 1, the previous and next day.

**Month calendar dots (optional accelerator).** For the month picker we want one request, not
30 searches. Probe order, once per device, result persisted in the quirk record:

1. `POST /ISAPI/ContentMgmt/record/tracks/dailyDistribution`
2. `POST /ISAPI/ContentMgmt/search/dailyDistribution`

Body:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<trackDailyParam>
  <year>2024</year>
  <monthOfYear>5</monthOfYear>
  <trackID>101</trackID>
</trackDailyParam>
```

Response:

```xml
<trackDailyDistribution version="1.0" xmlns="http://www.hikvision.com/ver10/XMLSchema">
  <dayList>
    <day>
      <id>1</id>
      <dayOfMonth>1</dayOfMonth>
      <record>true</record>
      <recordType>timing,motion</recordType>
    </day>
    <day>
      <id>2</id>
      <dayOfMonth>2</dayOfMonth>
      <record>false</record>
    </day>
    …
  </dayList>
</trackDailyDistribution>
```

If **both** paths fail (403/404/`badParameters`), the fallback is deterministic and specified:
resolve dots lazily with a `maxResults=1` search per visible day, at `.utility` priority,
concurrency **2**, cancelled when the month picker closes. 31 cheap searches complete in about
2–4 s on a typical NVR and the dots fill in progressively. Days not yet resolved render as
"unknown" (a hairline outline), never as "empty".

```swift
public struct MonthRecordCalendar: Sendable, Hashable, Codable {
    public let year: Int, month: Int
    public let track: TrackID
    /// index 0 = day 1. nil = not yet known.
    public let days: [DayState?]
    public enum DayState: Sendable, Hashable, Codable { case none; case some(Set<RecordType>) }
}

extension ISAPIDeviceSession {
    public func monthCalendar(track: TrackID, year: Int, month: Int) async throws -> MonthRecordCalendar
}
```

### 15.6 Clip export

Vigil exports clips by **re-playing the RTSP segment and passthrough-muxing** it
(`VigilCore.ClipRecorder`), not by using Hikvision's HTTP download. Reasons: the ISAPI
download endpoint (`GET /ISAPI/ContentMgmt/download` with a `<downloadRequest>` body) yields a
proprietary Hikvision container that no Mac player opens without conversion, and it is absent
on cameras. Passthrough re-play produces a standard MP4 at 1× wall-clock or faster with the
`Scale` header. This keeps the code path identical to live recording.

---

## 16. Two-way audio

### 16.1 `GET /ISAPI/System/TwoWayAudio/channels`

```xml
<TwoWayAudioChannelList version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <TwoWayAudioChannel version="2.0">
    <id>1</id>
    <enabled>true</enabled>
    <audioCompressionType>G.711ulaw</audioCompressionType>
    <audioInputType>MicIn</audioInputType>
    <noisereduce>true</noisereduce>
    <audioBitRate>64</audioBitRate>
    <audioSamplingRate>8</audioSamplingRate>
    <associateVideoInputs>
      <enabled>true</enabled>
      <videoInputChannelList><videoInputChannelID>1</videoInputChannelID></videoInputChannelList>
    </associateVideoInputs>
  </TwoWayAudioChannel>
</TwoWayAudioChannelList>
```

| Field | Units / values |
| --- | --- |
| `id` | two-way audio channel; **1 on cameras.** On NVRs the NVR's own audio is `1` and IP-channel talk-back uses the channel number. |
| `audioCompressionType` | `G.711ulaw`, `G.711alaw`, `G.722.1`, `G.726`, `AAC`, `MP2L2`, `PCM` |
| `audioBitRate` | kbit/s (64 for G.711) |
| `audioSamplingRate` | **kHz as an integer** (`8` = 8000 Hz, `16` = 16000 Hz) |
| `audioInputType` | `MicIn`, `LineIn` |

`GET /ISAPI/System/TwoWayAudio/channels/{id}` returns the single channel.
`GET /ISAPI/System/TwoWayAudio/channels/{id}/capabilities` lists the supported
`audioCompressionType` values as an `<opt>` attribute:
`<audioCompressionType opt="G.711ulaw,G.711alaw,G.722.1,AAC">G.711ulaw</audioCompressionType>`.
That `opt` attribute is how we enumerate choices — read it with `@opt` and split on `,`.

### 16.2 Codec negotiation

Vigil's decision procedure, in order:

1. Read `/capabilities` for the channel and parse `audioCompressionType@opt`.
   If absent, read the channel's current `audioCompressionType` and treat it as the only
   option.
2. Choose the first supported codec from Vigil's preference list:
   **`G.711ulaw` → `G.711alaw` → `G.722.1` → `AAC` → `PCM`.**
   G.711 is first because it is universally supported, is trivially encodable from
   AVAudioEngine's 8 kHz mono float buffers with no framework dependency, and has no
   container framing. `G.722.1` and `AAC` are accepted for *reading* device audio but Vigil
   never *sends* them (we would need an encoder; AudioToolbox has AAC but the added
   negotiation risk is not worth it for talk-back).
3. If the device's current `audioCompressionType` differs from the chosen one, `PUT` the
   channel (read-modify-write on `<TwoWayAudioChannel>`) to set it **before** opening. Some
   firmwares ignore the codec of the uploaded data entirely and decode according to this
   setting — sending µ-law to a device configured for A-law produces loud static, so this
   step is mandatory, not an optimization.
4. Sample rate is not negotiable per-request; use whatever `audioSamplingRate` reports
   (8 kHz in practice) and resample locally.

```swift
public struct TwoWayAudioChannel: Sendable, Hashable {
    public let id: Int
    public var enabled: Bool
    public var codec: AudioCodec
    public var supportedCodecs: [AudioCodec]
    public var bitrateKbps: Int
    public var sampleRateHz: Int
    public var inputType: String?
    public var associatedVideoChannels: [ChannelID]
    public var originalNode: XMLNode
}

public enum AudioCodec: String, Sendable, Hashable, Codable {
    case g711ulaw = "G.711ulaw"
    case g711alaw = "G.711alaw"
    case g7221    = "G.722.1"
    case g726     = "G.726"
    case aac      = "AAC"
    case mp2l2    = "MP2L2"
    case pcm      = "PCM"
    /// Bytes per 20 ms frame at the channel's sample rate; 160 for 8 kHz G.711.
    public func frameBytes(sampleRateHz: Int) -> Int
}
```

### 16.3 `PUT /ISAPI/System/TwoWayAudio/channels/{id}/open`

Empty body, `Content-Length: 0`.

```xml
<TwoWayAudioSession version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <sessionId>112</sessionId>
</TwoWayAudioSession>
```

Some firmwares return `<ResponseStatus>` with `statusCode 1` and no session id; that is
success, and `sessionId` is simply unused. Failure modes:

| Response | Meaning | User message |
| --- | --- | --- |
| `403` + `notSupport` | no speaker / talk-back not supported | `err.audio.notSupported` — "This camera has no speaker." |
| `403` + `invalidOperation` / `deviceBusy` | another client already holds the audio channel | `err.audio.busy` — "Someone else is talking to this camera." |
| `401` | credential lacks the two-way-audio permission | `err.auth.permission` |

The device allows exactly **one** open talk session at a time. Vigil enforces app-side
exclusivity too: at most one `TwoWayAudioSession` across all cameras, because the Mac has one
microphone and simultaneous talk to two cameras is not a feature anyone wants.

### 16.4 `POST /ISAPI/System/TwoWayAudio/channels/{id}/audioData` (chunked upload)

```
POST /ISAPI/System/TwoWayAudio/channels/1/audioData HTTP/1.1
Host: 192.168.1.64
Authorization: Digest username="admin", …, nc=00000007, …
Content-Type: application/octet-stream
Transfer-Encoding: chunked
Connection: keep-alive

<G.711 µ-law payload, streamed, 160 bytes per 20 ms, no framing headers>
```

The body is raw codec bytes with **no RTP header, no length prefix, no container**. For
8 kHz µ-law that is 160 bytes per 20 ms = 8000 B/s. Vigil sends one write per 20 ms frame and
lets `URLSession` coalesce; frames are **not** batched beyond 4 (80 ms) because latency is the
point.

**Implementation (concrete, and the reason §5 exists).**

```swift
public actor TwoWayAudioSession {
    public enum State: Sendable, Equatable { case opening, talking, closing, closed, failed(String) }

    public init(session: ISAPIDeviceSession, channel: Int, codec: AudioCodec, sampleRateHz: Int)

    /// Opens the device session, negotiates the codec, and starts the chunked upload.
    public func open() async throws
    /// Enqueues one frame of already-encoded codec bytes. Non-blocking; drops the oldest
    /// frame when the outbound queue exceeds 25 frames (500 ms) so we never build latency.
    public func send(frame: Data)
    /// Optional: device → client audio (see §16.6).
    public var incoming: AsyncStream<Data> { get }
    public func close() async
    public var state: State { get }
}
```

Transport mechanics:

* `URLSession.uploadTask(withStreamedRequest:)` plus
  `urlSession(_:task:needNewBodyStream:)` returning the read end of a bound stream pair
  created with `Stream.getBoundStreams(withBufferSize: 32 * 1024)`.
  (`InputStream`/`OutputStream` bound pairs exist on Linux corelibs as well, so the code
  compiles in CI even though we only exercise it on macOS.)
* The output stream is driven from a dedicated `Thread`-less loop: we schedule the
  `OutputStream` on a `RunLoop` owned by a single `OperationQueue`, and write on
  `stream(_:handle:)` `.hasSpaceAvailable`. If no frame is queued, write **silence**
  (µ-law `0xFF` for 160 bytes) rather than starving the stream — several firmwares close the
  session after ~1 s of no data.
* Because the body is unreplayable, `Authorization` **must** be correct on the first attempt.
  The `open()` call immediately precedes the upload and guarantees a fresh, valid challenge in
  `DigestStore`; the upload uses the next `nc`. If the upload nevertheless gets a 401, the
  session fails with `.failed("authentication lost")` and the UI re-arms the button — we do
  not attempt to resume a half-sent audio stream.
* `Transfer-Encoding: chunked` is set implicitly by URLSession when the body length is
  unknown; do not set `Content-Length`. Do not set `Transfer-Encoding` manually (URLSession
  rejects reserved headers on some OS versions) — verify by asserting in debug that
  `httpBodyStream != nil && value(forHTTPHeaderField: "Content-Length") == nil`.
* Timeout: the `.audio` lane has `timeoutIntervalForResource = 0` (unbounded) and
  `timeoutIntervalForRequest = 30` (idle). Since we always write silence, idle never trips
  during a live talk session.

Microphone capture (in `VigilCore`/`VigilVideo`, listed here so the contract is unambiguous):
`AVAudioEngine` input tap → `AVAudioConverter` to 8 kHz mono `Int16` → µ-law encode
(a 256-entry table plus the standard 8-bit compression; ~25 lines, unit-tested against the
G.711 reference vectors, implemented in `VigilProtocols` so it is Linux-testable) → 160-byte
frames → `TwoWayAudioSession.send(frame:)`.

### 16.5 `PUT /ISAPI/System/TwoWayAudio/channels/{id}/close`

Empty body. Returns `<ResponseStatus>`. Always sent, including on error paths, cancellation,
window close, and app termination (detached task, 1 s budget). A session left open blocks
every other client until the device times it out (60–120 s), so this is as important as the
PTZ stop.

### 16.6 Device → client audio

`GET /ISAPI/System/TwoWayAudio/channels/{id}/audioData` returns an endless chunked body of raw
codec bytes in the same format. Vigil uses it only when the RTSP stream carries no audio track
(some doorbell models), and treats it as a fallback listen path on the `.stream` lane. It is
decoded by `VigilVideo`'s audio path exactly like RTP-delivered G.711.

---

## 17. Image settings, reboot, users

### 17.1 The read-modify-write rule

**Every** ISAPI configuration `PUT` in this section follows the same mandatory pattern:

```swift
extension ISAPIDeviceSession {
    /// GET → mutate the parsed tree → PUT the whole element → validate → re-GET → return.
    /// `mutate` receives the node exactly as the device sent it, including elements Vigil
    /// does not model, and must return a node with the same root name.
    func readModifyWrite(_ resource: String,
                         mutate: (XMLNode) throws -> XMLNode) async throws -> ISAPIDocument
}
```

Why: Hikvision's validators require every mandatory sibling to be present, several firmwares
reset omitted elements to factory defaults, and new firmware adds elements we do not know
about which must survive round-tripping. Constructing a "minimal" body is a bug, always.

The re-GET is skipped only for `/PTZCtrl/**` (which has no persistent state to confirm) and
for `/System/reboot`.

### 17.2 Image endpoints

Base: `/ISAPI/Image/channels/{ch}` where `{ch}` is the **video input channel**.
`GET` on the base returns the whole `<ImageChannel>`; we use the sub-resources for writes
because a whole-`ImageChannel` PUT is rejected by most firmware.

| Setting | Method + path | Element | Range / values |
| --- | --- | --- | --- |
| Brightness / contrast / saturation | `GET`,`PUT /ISAPI/Image/channels/{ch}/color` | `<Color><brightnessLevel>`, `<contrastLevel>`, `<saturationLevel>` | 0…100, default 50 |
| Sharpness | `GET`,`PUT /ISAPI/Image/channels/{ch}/sharpness` | `<Sharpness><SharpnessLevel>` (also seen `<sharpnessLevel>`) | 0…100 |
| WDR | `GET`,`PUT /ISAPI/Image/channels/{ch}/WDR` | `<WDR><mode>`,`<WDRLevel>` | mode `open`\|`close`\|`auto`; level 0…100 |
| BLC | `GET`,`PUT /ISAPI/Image/channels/{ch}/BLC` | `<BLC><enabled>`,`<BLCRegion>` | region `up`\|`down`\|`left`\|`right`\|`center`\|`auto` |
| HLC | `GET`,`PUT /ISAPI/Image/channels/{ch}/HLC` | `<HLC><enabled>`,`<HLCLevel>` | 0…100 |
| IR-cut / day-night | `GET`,`PUT /ISAPI/Image/channels/{ch}/ircutFilter` | `<IrcutFilter><IrcutFilterType>`, `<nightToDayFilterLevel>`, `<nightToDayFilterTime>` | type `auto`\|`day`\|`night`\|`schedule`\|`triggeredByAlarmIn`; level 0…7; time 3…10 (seconds) |
| Noise reduction | `GET`,`PUT /ISAPI/Image/channels/{ch}/noiseReduce` | `<NoiseReduce><mode>`, `<GeneralMode><generalLevel>` | mode `close`\|`general`\|`advanced`\|`expert`; level 0…100 |
| White balance | `GET`,`PUT /ISAPI/Image/channels/{ch}/whiteBalance` | `<WhiteBalance><whiteBalanceStyle>`,`<whiteBalanceRed>`,`<whiteBalanceBlue>` | style `auto`\|`manual`\|`indoor`\|`outdoor`\|`fluorescentLamp`\|`sodiumLamp`\|`autoTrack`\|`onceWB`; red/blue 0…100 |
| Exposure | `GET`,`PUT /ISAPI/Image/channels/{ch}/exposure` | `<Exposure><ExposureType>`,`<OverexposeSuppress>` | type `auto`\|`manual`\|`irisFirst`\|`shutterFirst`\|`gainFirst` |
| Shutter | `GET`,`PUT /ISAPI/Image/channels/{ch}/shutter` | `<Shutter><ShutterLevel>` | e.g. `1/25`, `1/50`, `1/100`, `1/250`, `1/500`, `1/1000` |
| Gamma | `GET`,`PUT /ISAPI/Image/channels/{ch}/gamma` | `<Gamma><enabled>`,`<gammaLevel>` | 0…100 |
| Image flip / corridor | `GET`,`PUT /ISAPI/Image/channels/{ch}/imageFlip` | `<ImageFlip><enabled>`,`<ImageFlipStyle>` | `CENTER`\|`LEFTRIGHT`\|`UPDOWN` |
| Power line frequency | `GET`,`PUT /ISAPI/Image/channels/{ch}/powerLineFrequency` | `<PowerLineFrequency><powerLineFrequencyMode>` | `50hz`\|`60hz` |
| Defaults | `PUT /ISAPI/Image/channels/{ch}/defaultConfiguration` | empty | resets image settings |

Sample:

```
GET /ISAPI/Image/channels/1/color
→
<Color version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <brightnessLevel>50</brightnessLevel>
  <contrastLevel>50</contrastLevel>
  <saturationLevel>50</saturationLevel>
</Color>

PUT /ISAPI/Image/channels/1/color
Content-Type: application/xml

<?xml version="1.0" encoding="UTF-8"?>
<Color version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <brightnessLevel>62</brightnessLevel>
  <contrastLevel>50</contrastLevel>
  <saturationLevel>55</saturationLevel>
</Color>
→
<ResponseStatus version="2.0" xmlns="…">
  <requestURL>/ISAPI/Image/channels/1/color</requestURL>
  <statusCode>1</statusCode><statusString>OK</statusString><subStatusCode>ok</subStatusCode>
</ResponseStatus>
```

Note the echoed `version` and `xmlns` on the PUT — that is the read-modify-write rule in
action, and some 5.4.x builds reject a `<Color>` body without them.

```swift
public struct ImageSettings: Sendable, Hashable {
    public var brightness: Int?        // 0…100
    public var contrast: Int?
    public var saturation: Int?
    public var sharpness: Int?
    public var wdr: WDRSetting?
    public var irCut: IRCutSetting?
    public var noiseReduction: Int?
    public var whiteBalanceStyle: String?
    public var flip: String?
    public var powerLineFrequency: String?
    /// Which of the above the device actually exposed — drives which controls the UI shows.
    public var available: Set<ImageControl>
}

public enum ImageControl: String, Sendable, Hashable, CaseIterable {
    case color, sharpness, wdr, blc, hlc, ircut, noiseReduce, whiteBalance,
         exposure, shutter, gamma, flip, powerLine
}

extension ISAPIDeviceSession {
    /// Fetches every sub-resource concurrently (max 3 at a time), tolerating 403/404 per
    /// control, and reports which controls exist.
    public func imageSettings(channel: ChannelID) async throws -> ImageSettings
    public func setImageColor(channel: ChannelID, brightness: Int?, contrast: Int?,
                              saturation: Int?) async throws
    public func setSharpness(channel: ChannelID, _ level: Int) async throws
    public func setWDR(channel: ChannelID, _ setting: WDRSetting) async throws
    public func setIRCut(channel: ChannelID, _ setting: IRCutSetting) async throws
    public func resetImageDefaults(channel: ChannelID) async throws
}
```

UI behaviour: sliders are **debounced at 250 ms** and coalesced — a drag produces at most
4 PUTs per second, and only the final value is guaranteed to be sent. A PUT that returns
`badParameters` reverts the slider to the last confirmed value with a brief shake animation.

### 17.3 `PUT /ISAPI/System/reboot`

Empty body, `Content-Length: 0`.

```xml
<ResponseStatus version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <requestURL>/ISAPI/System/reboot</requestURL>
  <statusCode>1</statusCode>
  <statusString>OK</statusString>
  <subStatusCode>ok</subStatusCode>
</ResponseStatus>
```

Post-conditions Vigil enforces:
* Two-step confirmation in the UI (destructive action).
* On success: stop every stream for that device, flush all caches, mark the device
  `rebooting`, and poll `GET /ISAPI/System/status` every 5 s for up to 180 s. First success
  ⇒ resume streams. Timeout ⇒ `err.device.rebootTimeout`.
* The response frequently never arrives (the device reboots mid-response). A
  `URLError.networkConnectionLost` or timeout **after** a reboot PUT is treated as success.

`PUT /ISAPI/System/factoryReset?mode=basic|full` exists and is deliberately **not** exposed.

### 17.4 `GET /ISAPI/Security/users`

```xml
<UserList version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
  <User version="2.0">
    <id>1</id>
    <userName>admin</userName>
    <userLevel>Administrator</userLevel>
  </User>
  <User version="2.0">
    <id>2</id>
    <userName>viewer</userName>
    <userLevel>Operator</userLevel>
    <bondIpAddressList/>
    <bondMacAddressList/>
  </User>
</UserList>
```

`userLevel`: `Administrator` | `Operator` | `Viewer`. Vigil reads this for exactly one
purpose: when a PTZ or configuration call returns `insufficientPermission`, the diagnostics
panel can say *"the account 'viewer' is an Operator; PTZ requires Administrator on this
camera"*. **Vigil never creates, deletes, or modifies device users**, and never writes
passwords to a device — that is the camera vendor's web UI's job and doing it here is a
support liability. `PUT /ISAPI/Security/users/{id}` is documented here only so implementers
know we chose not to call it.

`GET /ISAPI/Security/UserPermission/{id}` (or `/ISAPI/Security/userPermission`) returns
per-user permission bitmaps; read-only, best-effort, used only for the same diagnostic text.

```swift
public struct DeviceUser: Sendable, Hashable, Identifiable {
    public let id: Int
    public let userName: String
    public let level: Level      // .administrator, .operator, .viewer, .other(String)
}
```

---

## 18. The device session actor

```swift
public actor ISAPIDeviceSession {
    public init(endpoint: ISAPIEndpoint,
                credential: ISAPICredential,
                configuration: ISAPIClient.Configuration = .init(),
                transport: any ISAPIHTTPTransporting,
                trustEvaluator: any ServerTrustEvaluating,
                clock: any VigilClock,
                logger: any VigilLogger)

    // Identity & inventory
    public func deviceInfo(force: Bool = false) async throws -> DeviceInfo
    public func status() async throws -> DeviceStatus
    public func time(force: Bool = false) async throws -> DeviceTime
    public func capabilities(force: Bool = false) async throws -> DeviceCapabilities
    public func networkInterfaces() async throws -> [NetworkInterfaceInfo]
    public func checkCredentials() async throws -> UserCheckResult
    public func channels(force: Bool = false) async throws -> [DeviceChannel]
    public func users() async throws -> [DeviceUser]

    // Streaming
    public func streamingChannels(force: Bool = false) async throws -> [StreamingChannelConfig]
    public func streamingChannel(_ id: StreamingChannelID) async throws -> StreamingChannelConfig
    public func updateStream(_ id: StreamingChannelID,
                             _ patch: StreamingChannelPatch) async throws -> StreamingChannelConfig
    public func snapshot(_ request: SnapshotRequest) async throws -> Data

    // PTZ
    public func ptzCapabilities(channel: ChannelID) async throws -> PTZCapabilities
    public func ptzController(channel: ChannelID) async throws -> PTZController

    // Events
    public func alertStream() -> AlertStreamMonitor          // memoized, one per device
    public func eventTriggers(force: Bool = false) async throws -> [EventTrigger]
    public func eventSchedule(triggerID: String) async throws -> EventSchedule?
    public func motionDetection(channel: ChannelID) async throws -> MotionDetectionConfig
    public func setMotionDetection(channel: ChannelID, enabled: Bool?,
                                  sensitivity: Int?, grid: MotionGrid?) async throws

    // Playback
    public func recordTracks(force: Bool = false) async throws -> [RecordTrack]
    public func searchRecordings(_ q: RecordSearchQuery) async throws -> [RecordSegment]
    public func dayIndex(track: TrackID, dayStartUTC: Date,
                         force: Bool = false) async throws -> RecordDayIndex
    public func monthCalendar(track: TrackID, year: Int, month: Int) async throws -> MonthRecordCalendar
    public func storage(force: Bool = false) async throws -> StorageInfo

    // Audio
    public func twoWayAudioChannels() async throws -> [TwoWayAudioChannel]
    public func openTwoWayAudio(channel: Int) async throws -> TwoWayAudioSession

    // Image
    public func imageSettings(channel: ChannelID) async throws -> ImageSettings
    // …setters per §17.2

    // Lifecycle
    public func reboot() async throws
    public func invalidateCaches()
    public func shutdown() async         // stops alertStream, closes audio, cancels tasks
    public var quirks: DeviceQuirks { get }
}
```

### 18.1 Cache TTLs (authoritative)

| Data | TTL | Invalidated by |
| --- | --- | --- |
| `DeviceInfo` | 24 h | reboot, credential change |
| `DeviceCapabilities` | 24 h (keyed by firmware version) | firmware change, reboot |
| `DeviceTime` | 5 min | reboot |
| `DeviceStatus` | 5 s | — |
| channel inventory (`[DeviceChannel]`) | 60 s | any stream PUT, reboot |
| `[StreamingChannelConfig]` | 30 s | any stream PUT |
| InputProxy status | 30 s | stream failure on that channel |
| `[RecordTrack]` | 5 min | reboot |
| `StorageInfo` | 5 min | reboot |
| `RecordDayIndex` (today) | 60 s | — |
| `RecordDayIndex` (past day) | ∞ (persisted) | reboot does not invalidate |
| `MonthRecordCalendar` (current month) | 10 min | — |
| `[EventTrigger]` | 5 min | — |
| `PTZCapabilities` | 24 h | reboot |
| `PTZStatus` | never cached | — |
| `ImageSettings` | 30 s | any image PUT |
| JPEG snapshots | never cached in VigilISAPI (VigilCore owns thumbnail retention) | — |

All caches are flushed by `invalidateCaches()`, which is called on: credential change,
detected reboot (uptime regression), `AlertStreamState.authFailed`, and endpoint change.

### 18.2 Connect sequence

The first thing Vigil does with a new device. Ordered, with a hard 12 s overall budget; a
failure at step 2 aborts, everything later is best-effort.

| # | Call | Concurrency | On failure |
| --- | --- | --- | --- |
| 1 | `GET /ISAPI/System/deviceInfo` | serial | 401 ⇒ prompt for credentials; 404/timeout ⇒ "not an ISAPI device", offer ONVIF fallback |
| 2 | `GET /ISAPI/Security/userCheck` | serial | maps lock-out state; abort on lock |
| 3 | `GET /ISAPI/System/capabilities`, `GET /ISAPI/System/time` | parallel (2) | ignore; fall through to probes/defaults |
| 4 | `GET /ISAPI/Streaming/channels` | serial | fatal for streaming: fall back to synthesizing channel 1 main/sub |
| 5 | `GET /ISAPI/ContentMgmt/InputProxy/channels` + `/status` (NVR only) | parallel (2) | ignore |
| 6 | `GET /ISAPI/System/Video/inputs/channels` | serial | ignore |
| 7 | capability functional probes (only the unresolved ones) | parallel (2), `.utility` | ignore |
| 8 | `GET /ISAPI/PTZCtrl/channels` then per-channel `capabilities` for PTZ channels | parallel (2), `.utility` | PTZ hidden |
| 9 | `GET /ISAPI/ContentMgmt/record/tracks`, `GET /ISAPI/ContentMgmt/Storage` | parallel (2), `.utility` | playback hidden |
| 10 | start `AlertStreamMonitor` | background | `.unsupported` shown in health panel |

Steps 1–4 must complete before the first tile can open a stream; measured budget on a
DS-7608 over gigabit LAN: 180–350 ms total.

### 18.3 Negative capability cache

Any `403 notSupport`, `404 notFound`, or `405 methodNotAllowed` on a *capability-bearing*
resource is recorded as a negative capability keyed by the resource template (with channel
numbers normalized to `{ch}` / `{id}`), for **24 h** or until reboot. Subsequent calls to that
template throw `ISAPIError.notSupported` **without a network round trip**. This is what stops
Vigil from re-asking a fixed camera for PTZ capabilities 40 times a session.

Negative entries are visible in the diagnostics bundle, and there is a "re-probe device"
action in the camera settings that clears them.

---

## 19. Firmware quirks matrix

`DeviceQuirks` is a `Codable` value type persisted on the camera record by `VigilCore`.
Every flag is either resolved by observation (marked **obs**) or seeded from a model/firmware
match (marked **seed**) and then corrected by observation.

```swift
public struct DeviceQuirks: Sendable, Hashable, Codable {
    public var schemaVersion: Int = 1
    public var streamingChannelIDIsSingleDigit: Bool = false
    public var snapshotIgnoresResolutionQuery: Bool = false
    public var momentaryUnsupported: Bool = false
    public var ptz3DOriginIsTopLeft: Bool? = nil
    public var recordTypeFilterUnsupported: Bool = false
    public var playbackTimesAreDeviceLocal: Bool = false
    public var dailyDistributionPath: String? = nil       // resolved endpoint or nil
    public var eventSchedulePath: String? = nil
    public var alertStreamBoundaryFromSniff: Bool = false
    public var requiresXMLDeclarationInBody: Bool = true
    public var digestNoQOP: Bool = false
    public var maxConcurrentRequestsOverride: Int? = nil
    public var inputProxyStatusListUnsupported: Bool = false
    public var sharpnessElementIsCapitalized: Bool = true
}
```

| Firmware / family | Observed behaviour | Flag |
| --- | --- | --- |
| 5.1.x cameras | `/Streaming/channels/1` only; 3-digit IDs 404 | `streamingChannelIDIsSingleDigit` (**obs**) |
| 5.1.x–5.2.x | Digest without `qop`; RFC 2069 response form | `digestNoQOP` (**obs**) |
| 5.2.x | bare `LF` after the multipart boundary | handled unconditionally by the parser |
| 5.2.x | rejects request bodies lacking `<?xml …?>` | `requiresXMLDeclarationInBody` (**seed** true, always sent) |
| 5.2.x | snapshot returns `Content-Type: text/html` with JPEG body | handled unconditionally (SOI sniff) |
| 5.4.x DVR | `CMSearchDescription` element order enforced | handled unconditionally (fixed order) |
| 5.4.x | `text/xml` on PTZ PUT ⇒ `invalidXMLFormat` | handled unconditionally (`application/xml`) |
| 5.4.x–5.5.x | `<sharpnessLevel>` lowercase | `sharpnessElementIsCapitalized` (**obs**) — reads use alternation regardless |
| 5.5.x+ | `qop="auth"` present | automatic |
| 5.5.x+ smart cameras | detection-region coordinates 0…10000 | handled unconditionally (magnitude sniff) |
| some DS-2DE4xxx | `position3D` Y origin upper-left | `ptz3DOriginIsTopLeft` (**obs**, via §13.5 calibration) |
| some 6.x NVRs | `dailyDistribution` under `/search/` not `/record/tracks/` | `dailyDistributionPath` (**obs**) |
| some 6.x | `Authentication-Info: nextnonce` | automatic |
| DS-76xx/77xx | `/InputProxy/channels/status` list form 404s | `inputProxyStatusListUnsupported` (**obs**) |
| several DVRs | playback `starttime` interpreted as device-local despite `Z` | `playbackTimesAreDeviceLocal` (**obs**, via §15.3 range echo) |
| low-end cameras (≤ DS-2CD1xxx) | >2 concurrent ISAPI requests ⇒ 503 storm | `maxConcurrentRequestsOverride = 2` (**obs**, after 3 `deviceBusy` in 10 s) |

The matrix is data, not code paths sprinkled through call sites: quirks are consulted in
exactly four places (path builder, body builder, parser configuration, and the request gate).

---

## 20. Testing

All of `VigilISAPI` is unit-testable on Linux. `swift test --filter VigilISAPITests` must pass
on Linux Swift 6.1 with zero macOS-only code paths exercised.

### 20.1 Fixtures

Recorded real responses live in `Tests/VigilISAPITests/Fixtures/` as plain files, one per
response, named `{family}-{firmware}-{endpoint}.xml`, e.g.
`ipc-5.6.3-streaming-channels.xml`, `nvr-4.30.005-cmsearch-page1.xml`. Binary fixtures
(`alertstream-with-jpeg.bin`) are byte-exact captures including CRLFs.

Minimum fixture set (33 files): `deviceInfo` × 4 families, `capabilities` × 3,
`status` × 2, `time` × 2, `userCheck` × 3 (ok / wrong / locked), `Streaming/channels` × 3
(IPC 3-stream, NVR 16-channel, 5.1.x single-digit), `InputProxy` × 2, `videoInputs` × 1,
PTZ `capabilities` × 2 (`PTZChanelCap` and `PTZChannelCap`), `presets` × 1, `patrols` × 1,
`status` (PTZ) × 1, `alertStream` × 4 (motion, line-crossing with polygon, heartbeat-only,
motion + JPEG), `CMSearchResult` × 3 (OK / MORE / NO MATCHES), `record/tracks` × 1,
`Storage` × 2 (HDD, SD unformatted), `TwoWayAudio/channels` × 1 + `capabilities` × 1,
`Image/color` × 1, `motionDetection` × 1, `ResponseStatus` error bodies × 6.

```swift
public struct FixtureTransport: ISAPIHTTPTransporting, Sendable {
    public init(routes: [Route])
    public struct Route: Sendable {
        public var method: String
        public var pathPattern: String          // "/ISAPI/Streaming/channels/*"
        public var status: Int
        public var headers: [String: String]
        public var body: Data
        /// Artificial delay, for timeout and cancellation tests.
        public var delay: Duration = .zero
        /// Splits `body` into chunks for streaming routes, to exercise partial reads.
        public var chunking: [Int]? = nil
    }
    /// Every request is recorded, so tests can assert on the exact bytes we sent.
    public var recordedRequests: [ISAPIRawRequest] { get }
}
```

### 20.2 Test list (each item is at least one `XCTest`/`swift-testing` case)

**XML reader (24 cases)**
namespace-prefixed elements; `ver10` vs `ver20`; casing variance both directions; path
alternation `|` and `||`; `*` and `**`; `[n]`; `@attr`; missing-value error names siblings;
bool table (all 14 accepted spellings + 2 rejected); every date form in §7.5 including a leap
day and a `+05:30` offset; `gb2312` fallback; 8 MiB cap; 64-level depth cap; XXE payload is
ignored; HTML login page ⇒ `.notXML`; trailing-NUL tolerance; empty element vs absent element;
CDATA merge; `<hddList size="2">` attribute read.

**XML builder (6)** declaration present; escaping of `& < > " '`; element order preserved;
no xmlns on constructed bodies; xmlns echoed on RMW bodies; `Int`/`Bool` rendering.

**Digest (14)** RFC 2617 §3.5 reference vector; no-qop (RFC 2069) vector; MD5-sess;
`nc` increments and is 8 hex digits; `cnonce` differs per request; digestURI includes the
query string; realm with parentheses and spaces (`IP Camera(51253)`); `stale=TRUE` triggers
re-auth without counting a failure; identical nonce twice ⇒ `authenticationFailed`;
two failures ⇒ `authBlockedLocally`; `Authentication-Info: nextnonce` adopted;
multiple `WWW-Authenticate` headers prefer Digest; unsupported algorithm over http ⇒ throws;
unsupported algorithm over https ⇒ Basic.

**Client (12)** gate limits concurrency to 3 (assert via `FixtureTransport` overlap
counting); PTZ over-subscription of exactly one slot; cancellation propagates and the
recorded request count stops growing; timeout maps to `.timedOut`; 503 retried twice then
throws; GET coalescing produces one recorded request for five concurrent callers; POST is not
coalesced; 8 MiB response cap; `.notXML` on an HTML body; snapshot 403 ⇒ retried without
query then remembered; negative capability cache prevents the second request; reboot's lost
connection counts as success.

**Endpoint decoding (30)** one per model type, asserting every field of at least one fixture,
including: `maxFrameRate 1250 ⇒ 12.5 fps`; `keyFrameInterval 2000 ⇒ 2 s`; `GovLength` kept
separately; `capacity` in MB; `userCheck` lock fields; `Duration P30DT0H0M0S ⇒ 2 592 000 s`;
`timeZone "CST-8:00:00" ⇒ +28800`; `chanDetectResult` passthrough.

**ID mapping (8)** `StreamingChannelID(channel: 12, stream: .sub).value == 1202`;
round-trip; rejects `100`, `104`, `99`; `livePath` string; `legacyLivePaths` order;
`TrackID` is not interchangeable with `StreamingChannelID` (compile-time, verified by a
`// swift-format-ignore` negative-compile fixture documented in the test file).

**Multipart parser (18)** the four boundary spellings in §14.1; boundary split across two
`ingest` calls at every offset (parameterized over 1…len); `CRLF` and bare `LF`;
`Content-Length` present and absent; JPEG containing the boundary token *not* preceded by a
newline is not split; preamble discarded; closing `--boundary--`; header over 8 KiB ⇒
`.partTruncated` then resync; text part over 256 KiB ⇒ truncated, stream survives; binary
part over 4 MiB ⇒ truncated, event still emitted; **memory assertion: retained buffer never
exceeds `boundary.count + 4` in body states** (white-box check on an `internal` property);
`finish()` closes an open part; garbage between parts resynchronizes.

**Alert stream monitor (12)** heartbeat suppressed; motion event emitted; XML+JPEG pairing;
pending event flushed after 1.5 s without an image; backoff sequence exactly
`1,2,4,8,15,30,60,60` under a fake clock, with jitter within ±20%; reset after 120 s healthy;
60 s idle triggers `userCheck` probe; 90 s idle forces reconnect; 401 twice ⇒ `.authFailed`
and no further connections; 403 ⇒ `.unsupported` and no further connections;
`AsyncStream` back-pressure drops oldest beyond 256 without unbounded growth;
`stop()` cancels promptly.

**Search & timeline (10)** paging follows `MORE` and stops on `OK`; one `searchID` across
pages (assert the recorded bodies); `NO MATCHES` ⇒ empty, not an error; `searchResultPostion`
spelling in the emitted body; `hardSegmentCap` respected; segment merge with a 1.5 s gap
merges and a 3 s gap does not; minute-bin severity ordering; `playbackURI` host rewrite keeps
the query verbatim; synthesized locator for mid-segment seek; `clockRange` format.

**Motion grid (6)** 22×18 hex round-trip; padding bits forced to zero; `isFullFrame`;
polygon rasterization; odd column counts (e.g. 25 columns ⇒ 7 hex digits/row); malformed hex
⇒ `nil`.

**PTZ (10)** body bytes for continuous/momentary/absolute/relative/position3D asserted
byte-for-byte; clamping to −100…100; keep-alive resends every 400 ms under a fake clock;
`stop()` sends three zero bodies; reserved preset 94 rejected by `setPreset`; `PTZChanelCap`
and `PTZChannelCap` both parse; absent capabilities ⇒ `isAbsent`;
`PTZ3D.box` conversion for both origin conventions.

**Error mapping (14)** one case per row of §9.3, asserting the `ISAPIError` case and the
message key; HTTP 200 with `statusCode 4` still throws; unknown `subStatusCode` preserved.

**Two-way audio (6)** codec preference selection from an `opt` list; codec PUT precedes
`open`; silence frames written when the queue is empty; queue drops oldest beyond 25 frames;
`close` sent on the error path; µ-law encoder vectors.

### 20.3 What needs a Mac

Only three things, all thin and all covered by an XCTest target that is skipped on Linux:

1. `URLSessionTransport` against a local `NWListener`-based stub HTTP server (verifies real
   chunked upload, keep-alive reuse, and delegate wiring).
2. TLS pinning through `ServerTrustEvaluating` with a generated self-signed certificate.
3. `AVAudioEngine` → µ-law capture path (lives in `VigilCore`, listed here for completeness).

Everything else — every parser, every builder, every state machine, every policy — runs on
Linux.

---

## Appendix A — endpoint index

| # | Method | Path | Auth | Body | Response root | Swift model | §|
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | GET | `/ISAPI/System/deviceInfo` | Digest | — | `DeviceInfo` | `DeviceInfo` | 10.1 |
| 2 | GET | `/ISAPI/Security/userCheck` | Digest | — | `userCheck` | `UserCheckResult` | 10.2 |
| 3 | GET | `/ISAPI/System/status` | Digest | — | `DeviceStatus` | `DeviceStatus` | 10.3 |
| 4 | GET | `/ISAPI/System/time` | Digest | — | `Time` | `DeviceTime` | 10.4 |
| 5 | GET | `/ISAPI/System/capabilities` | Digest | — | `DeviceCap` | `DeviceCapabilities` | 10.5 |
| 6 | GET | `/ISAPI/System/Network/interfaces` | Digest | — | `NetworkInterfaceList` | `[NetworkInterfaceInfo]` | 10.6 |
| 7 | GET | `/ISAPI/ContentMgmt/InputProxy/channels` | Digest | — | `InputProxyChannelList` | `[UpstreamSource]` | 11.1 |
| 8 | GET | `/ISAPI/ContentMgmt/InputProxy/channels/status` | Digest | — | `InputProxyChannelStatusList` | channel online flags | 11.2 |
| 9 | GET | `/ISAPI/ContentMgmt/InputProxy/channels/{id}/status` | Digest | — | `InputProxyChannelStatus` | same | 11.2 |
| 10 | GET | `/ISAPI/System/Video/inputs/channels` | Digest | — | `VideoInputChannelList` | channel names | 11.3 |
| 11 | GET | `/ISAPI/Streaming/channels` | Digest | — | `StreamingChannelList` | `[StreamingChannelConfig]` | 12.1 |
| 12 | GET | `/ISAPI/Streaming/channels/{id}` | Digest | — | `StreamingChannel` | `StreamingChannelConfig` | 12.2 |
| 13 | PUT | `/ISAPI/Streaming/channels/{id}` | Digest | `StreamingChannel` (RMW) | `ResponseStatus` | — | 12.3 |
| 14 | GET | `/ISAPI/Streaming/channels/{id}/picture` | Digest | — | `image/jpeg` | `Data` | 12.5 |
| 15 | PUT | `/ISAPI/PTZCtrl/channels/{ch}/continuous` | Digest | `PTZData` | `ResponseStatus` | — | 13.1 |
| 16 | PUT | `/ISAPI/PTZCtrl/channels/{ch}/momentary` | Digest | `PTZData`+`Momentary` | `ResponseStatus` | — | 13.2 |
| 17 | PUT | `/ISAPI/PTZCtrl/channels/{ch}/absolute` | Digest | `PTZData`/`AbsoluteHigh` | `ResponseStatus` | — | 13.3 |
| 18 | PUT | `/ISAPI/PTZCtrl/channels/{ch}/relative` | Digest | `PTZData`/`Relative` | `ResponseStatus` | — | 13.4 |
| 19 | PUT | `/ISAPI/PTZCtrl/channels/{ch}/position3D` | Digest | `PTZData`/`Position3D` | `ResponseStatus` | — | 13.5 |
| 20 | GET | `/ISAPI/PTZCtrl/channels/{ch}/presets` | Digest | — | `PTZPresetList` | `[PTZPreset]` | 13.6 |
| 21 | PUT | `/ISAPI/PTZCtrl/channels/{ch}/presets/{n}` | Digest | `PTZPreset` | `ResponseStatus` | — | 13.6 |
| 22 | PUT | `/ISAPI/PTZCtrl/channels/{ch}/presets/{n}/goto` | Digest | empty | `ResponseStatus` | — | 13.6 |
| 23 | DELETE | `/ISAPI/PTZCtrl/channels/{ch}/presets/{n}` | Digest | — | `ResponseStatus` | — | 13.6 |
| 24 | GET | `/ISAPI/PTZCtrl/channels/{ch}/patrols` | Digest | — | `PTZPatrolList` | `[PTZPatrol]` | 13.7 |
| 25 | PUT | `/ISAPI/PTZCtrl/channels/{ch}/patrols/{n}/start` | Digest | empty | `ResponseStatus` | — | 13.7 |
| 26 | PUT | `/ISAPI/PTZCtrl/channels/{ch}/patrols/{n}/stop` | Digest | empty | `ResponseStatus` | — | 13.7 |
| 27 | PUT | `/ISAPI/PTZCtrl/channels/{ch}/homeposition/goto` | Digest | empty | `ResponseStatus` | — | 13.8 |
| 28 | GET | `/ISAPI/PTZCtrl/channels/{ch}/status` | Digest | — | `PTZStatus` | `PTZStatus` | 13.8 |
| 29 | GET | `/ISAPI/PTZCtrl/channels/{ch}/capabilities` | Digest | — | `PTZChanelCap` | `PTZCapabilities` | 13.9 |
| 30 | PUT | `/ISAPI/System/Video/inputs/channels/{ch}/focus` | Digest | `FocusData` | `ResponseStatus` | — | 13.8 |
| 31 | PUT | `/ISAPI/System/Video/inputs/channels/{ch}/iris` | Digest | `IrisData` | `ResponseStatus` | — | 13.8 |
| 32 | PUT | `/ISAPI/PTZCtrl/channels/{ch}/auxcommand` | Digest | `PTZAux` | `ResponseStatus` | — | 13.8 |
| 33 | GET | `/ISAPI/Event/notification/alertStream` | Digest | — | `multipart/mixed` | `EventNotification` stream | 14.1 |
| 34 | GET | `/ISAPI/Event/triggers` | Digest | — | `EventTriggerList` | `[EventTrigger]` | 14.7 |
| 35 | GET | `/ISAPI/Event/schedules/{triggerID}` | Digest | — | `EventSchedule` | `EventSchedule` | 14.8 |
| 36 | GET/PUT | `/ISAPI/System/Video/inputs/channels/{ch}/motionDetection` | Digest | `MotionDetection` (RMW) | `MotionDetection` / `ResponseStatus` | `MotionDetectionConfig` | 14.9 |
| 37 | GET | `/ISAPI/ContentMgmt/record/tracks` | Digest | — | `TrackList` | `[RecordTrack]` | 15.1 |
| 38 | POST | `/ISAPI/ContentMgmt/search` | Digest | `CMSearchDescription` | `CMSearchResult` | `[RecordSegment]` | 15.2 |
| 39 | POST | `/ISAPI/ContentMgmt/record/tracks/dailyDistribution` | Digest | `trackDailyParam` | `trackDailyDistribution` | `MonthRecordCalendar` | 15.5 |
| 40 | GET | `/ISAPI/ContentMgmt/Storage` | Digest | — | `storage` | `StorageInfo` | 15.4 |
| 41 | GET | `/ISAPI/ContentMgmt/Storage/quota` | Digest | — | `QuotaList` | `[StorageQuota]` | 15.4 |
| 42 | GET | `/ISAPI/System/TwoWayAudio/channels` | Digest | — | `TwoWayAudioChannelList` | `[TwoWayAudioChannel]` | 16.1 |
| 43 | GET | `/ISAPI/System/TwoWayAudio/channels/{id}/capabilities` | Digest | — | `TwoWayAudioChannel` | codec list | 16.1 |
| 44 | PUT | `/ISAPI/System/TwoWayAudio/channels/{id}` | Digest | `TwoWayAudioChannel` (RMW) | `ResponseStatus` | — | 16.2 |
| 45 | PUT | `/ISAPI/System/TwoWayAudio/channels/{id}/open` | Digest | empty | `TwoWayAudioSession` | session id | 16.3 |
| 46 | POST | `/ISAPI/System/TwoWayAudio/channels/{id}/audioData` | Digest | chunked raw codec | `ResponseStatus` | — | 16.4 |
| 47 | GET | `/ISAPI/System/TwoWayAudio/channels/{id}/audioData` | Digest | — | chunked raw codec | `AsyncStream<Data>` | 16.6 |
| 48 | PUT | `/ISAPI/System/TwoWayAudio/channels/{id}/close` | Digest | empty | `ResponseStatus` | — | 16.5 |
| 49 | GET/PUT | `/ISAPI/Image/channels/{ch}/color` | Digest | `Color` (RMW) | `Color` / `ResponseStatus` | `ImageSettings` | 17.2 |
| 50 | GET/PUT | `/ISAPI/Image/channels/{ch}/sharpness` | Digest | `Sharpness` (RMW) | as above | — | 17.2 |
| 51 | GET/PUT | `/ISAPI/Image/channels/{ch}/WDR` | Digest | `WDR` (RMW) | as above | `WDRSetting` | 17.2 |
| 52 | GET/PUT | `/ISAPI/Image/channels/{ch}/ircutFilter` | Digest | `IrcutFilter` (RMW) | as above | `IRCutSetting` | 17.2 |
| 53 | GET/PUT | `/ISAPI/Image/channels/{ch}/{noiseReduce,BLC,HLC,whiteBalance,exposure,shutter,gamma,imageFlip,powerLineFrequency}` | Digest | element (RMW) | as above | `ImageSettings` | 17.2 |
| 54 | PUT | `/ISAPI/Image/channels/{ch}/defaultConfiguration` | Digest | empty | `ResponseStatus` | — | 17.2 |
| 55 | PUT | `/ISAPI/System/reboot` | Digest | empty | `ResponseStatus` | — | 17.3 |
| 56 | GET | `/ISAPI/Security/users` | Digest | — | `UserList` | `[DeviceUser]` | 17.4 |

Deliberately **not** implemented: `/ISAPI/System/factoryReset`, `/ISAPI/System/updateFirmware`,
`/ISAPI/Security/users` writes, `/ISAPI/Event/notification/httpHosts`,
`/ISAPI/System/time` writes, `/ISAPI/ContentMgmt/download`, `/ISAPI/System/Network/*` writes,
`/ISAPI/Streaming/channels/{id}/picture` with `compression`. Each is a support liability or
superseded by a better path, per the sections above.

---

## Appendix B — public API summary

```
// Addressing & auth
ISAPIEndpoint, ISAPICredential, DigestChallenge, ServerTrustEvaluating, ServerTrustDecision

// Transport
ISAPIClient (actor), ISAPIClient.Configuration, ISAPIClient.Lane
ISAPIHTTPTransporting, ISAPIRawRequest, ISAPIResponse, HTTPHeaders
URLSessionTransport, ISAPIChunkedUpload

// XML
XMLNode, ISAPIDocument, XMLValue, XMLReadError, XMLBuilder, ISAPITime

// Errors
ISAPIError, ResponseStatus

// Identity & inventory
DeviceInfo, DeviceFamily, FirmwareVersion, DeviceStatus, DeviceTime,
DeviceCapabilities, NetworkInterfaceInfo, UserCheckResult, DeviceUser,
DeviceChannel, UpstreamSource, DeviceQuirks

// Identifiers
ChannelID, StreamIndex, StreamingChannelID, TrackID, HikvisionURL

// Streaming
StreamingChannelConfig, StreamingChannelPatch, VideoCodec, AudioCodec,
BitrateControl, ScanType, RTPTransport, MulticastConfig, SnapshotRequest

// PTZ
PTZController (actor), PTZVelocity, PTZAbsolutePosition, PTZRelativeMove,
PTZBox, PTZ3D, PTZPreset, PTZPatrol, PTZStatus, PTZCapabilities, PTZAuxiliary

// Events
AlertStreamMonitor (actor), AlertStreamState, EventNotification, EventState,
VigilEventType, DetectionRegion, EventTrigger, EventSchedule,
MultipartStreamParser, MotionDetectionConfig, MotionGrid

// Playback
RecordTrack, RecordSearchQuery, RecordSegment, RecordType, PlaybackLocator,
RecordDayIndex, MonthRecordCalendar, StorageInfo, StorageVolume, StorageQuota

// Audio
TwoWayAudioChannel, TwoWayAudioSession (actor)

// Image
ImageSettings, ImageControl, WDRSetting, IRCutSetting

// Session
ISAPIDeviceSession (actor)

// Test support (in VigilISAPITests)
FixtureTransport, FixtureTransport.Route
```

