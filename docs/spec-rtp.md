# Vigil — RTP / RTCP / Depacketization Specification (module `VigilRTP`)

**Status:** normative. An implementer must be able to write `Sources/VigilRTP/**` from this document
alone, with no further research.
**Target:** Swift 6, strict concurrency, `import Foundation` only. Must compile and unit-test on
Linux Swift 6.1. **No CoreMedia, no VideoToolbox, no Network.framework, no OSLog.**
**Dependencies:** `VigilProtocols` only. `VigilRTP` must **not** import `VigilRTSP`,
`VigilBitstream`, or anything macOS-only. (Rationale in §1.1.)

---

## Table of contents

| § | Section |
|---|---|
| 1 | Scope, dependency rules, file layout |
| 2 | Boundary value types (`MediaTimestamp`, `EncodedFrame`, `Codec`, clocks) |
| 3 | RTP fixed header: layout, CSRC, extensions, padding, parser |
| 4 | Track format, payload-type binding, depacketizer factory |
| 5 | H.264 depacketization (RFC 6184) |
| 6 | H.265 depacketization (RFC 7798) |
| 7 | Access-unit boundary detection (marker bit is NOT trusted) |
| 8 | AAC depacketization (RFC 3640, `mode=AAC-hbr`) |
| 9 | G.711 PCMA/PCMU and G.726-32 |
| 10 | Reorder / jitter buffer |
| 11 | Timestamp math, wraparound, NTP mapping, presentation clock |
| 12 | RTCP: parse SR/RR/SDES/BYE, generate RR, intervals |
| 13 | `StreamStatistics` and the exact update algebra |
| 14 | Public API surface: `Depacketizer`, `RTPTrackReceiver`, events, errors |
| 15 | Test vectors and the required unit-test list |
| 16 | Performance budget and allocation rules |
| 17 | Explicit non-goals |

---

## 1. Scope, dependency rules, file layout

### 1.1 Dependency rules (cross-cutting — other modules must respect these)

```
VigilProtocols  ──┬──▶ VigilRTP
                  ├──▶ VigilRTSP
                  └──▶ VigilBitstream
VigilRTP  ──▶ (nothing else)
```

* `VigilRTP` needs two tiny bitstream facts — H.264 `first_mb_in_slice` and H.265
  `first_slice_segment_in_pic_flag` — and one optional one (H.264 `slice_type`). It gets them from
  a 40-line local peeker (§7.3) built on `VigilProtocols.BitReader`. It does **not** depend on
  `VigilBitstream`. This keeps the graph a shallow DAG and lets `VigilBitstream` and `VigilRTP` be
  implemented in parallel.
* SDP lives in `VigilRTSP`. `VigilRTP` declares its own input struct `RTPTrackFormat` (§4.1). The
  6-line adapter from `VigilRTSP.SDPMediaDescription` to `RTPTrackFormat` lives in
  `VigilTransport` (macOS) and in the test fixture (Linux). **Contract for `VigilRTSP`:** it must
  expose, per media description, `payloadType: UInt8`, `encodingName: String`, `clockRate: Int32`,
  `channels: Int32?`, and `fmtp: [String: String]` with **lower-cased keys**.
* Nothing in `VigilRTP` is a class except the test-only `ManualClock`. Everything else is a
  `Sendable` value type. Mutation happens through `mutating` methods; the owner is an `actor`
  living in `VigilTransport`/`VigilCore`.

### 1.2 File layout

```
Sources/VigilRTP/
  RTPTrackFormat.swift        RTPTrackReceiver.swift     Depacketizer.swift
  RTPPacket.swift             RTPHeaderExtension.swift   RTPError.swift
  SequenceNumber.swift        ReorderBuffer.swift        TimestampUnwrapper.swift
  AccessUnitBuilder.swift     SliceHeaderPeek.swift      BoundaryPolicy.swift
  H264/ H264NAL.swift         H264/ H264Depacketizer.swift
  H265/ H265NAL.swift         H265/ H265Depacketizer.swift
  Audio/ AACDepacketizer.swift Audio/ AudioSpecificConfig.swift Audio/ ADTS.swift
  Audio/ G711.swift            Audio/ G726.swift
  RTCP/ RTCPPacket.swift       RTCP/ RTCPParser.swift     RTCP/ RTCPReportBuilder.swift
  RTCP/ RTPSourceState.swift
  PresentationClock.swift      StreamStatistics.swift
Tests/VigilRTPTests/            (mirrors the above, plus Fixtures/)
```

---

## 2. Boundary value types

These types are declared **once, in `VigilProtocols`**, and specified here because `VigilRTP` is
their producer. No other spec may redeclare them.

### 2.1 `MediaTimestamp`

```swift
/// A rational media time: `value / timescale` seconds. Deliberately mirrors CMTime's semantics
/// without importing CoreMedia, so the pure layer stays Linux-buildable.
public struct MediaTimestamp: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var value: Int64
    public var timescale: Int32          // must be > 0; 90_000 for video, sample rate for audio

    public static let invalid = MediaTimestamp(value: .min, timescale: 1)
    public static let zero    = MediaTimestamp(value: 0, timescale: 1)

    public init(value: Int64, timescale: Int32) {
        precondition(timescale > 0 || value == Int64.min, "timescale must be positive")
        self.value = value; self.timescale = timescale
    }

    @inlinable public var seconds: Double { Double(value) / Double(timescale) }
    @inlinable public var isValid: Bool { self != .invalid }

    /// Exact rescale using 128-bit intermediate math; rounds half away from zero.
    public func converted(to newTimescale: Int32) -> MediaTimestamp {
        guard isValid else { return .invalid }
        if newTimescale == timescale { return self }
        let (hi, lo) = value.magnitude.multipliedFullWidth(by: UInt64(newTimescale))
        let half = UInt64(timescale) / 2
        let (q, _) = UInt64.divideWithOverflowGuard(hi: hi, lo: lo, by: UInt64(timescale), addend: half)
        let signed = Int64(clamping: q)
        return MediaTimestamp(value: value < 0 ? -signed : signed, timescale: newTimescale)
    }

    public static func < (a: Self, b: Self) -> Bool {
        if a.timescale == b.timescale { return a.value < b.value }
        // cross-multiply in 128-bit to avoid overflow and precision loss
        return a.value.multipliedFullWidth(by: Int64(b.timescale))
             < b.value.multipliedFullWidth(by: Int64(a.timescale))   // see note
    }
}
```

Implementation notes that are **not** optional:

* `divideWithOverflowGuard` is a small helper in `VigilProtocols` implementing 128/64 division with
  saturation (`UInt64.max` on overflow). Do not use `Double` for rescaling — at a 90 kHz timescale
  and 13 hours of uptime the value exceeds 2^32 and `Double` still has headroom, but recorded
  playback at a 1/1 000 000 timescale does not.
* The 128-bit comparison in `<` needs a real `(high, low)` lexicographic compare on
  `(Int64, UInt64)` tuples; write it explicitly, don't rely on tuple `<`.
* `duration` arithmetic: provide `+`, `-`, and `adding(_ samples: Int64)` which stay in the
  receiver's timescale.

### 2.2 Monotonic time and injectable clock

```swift
public struct MonotonicTime: Hashable, Sendable, Comparable {
    public var nanoseconds: Int64            // arbitrary epoch, never wall clock, never wraps
    @inlinable public var seconds: Double { Double(nanoseconds) / 1e9 }
    @inlinable public func adding(milliseconds ms: Double) -> MonotonicTime {
        MonotonicTime(nanoseconds: nanoseconds + Int64(ms * 1e6))
    }
    @inlinable public static func - (a: Self, b: Self) -> Double {   // seconds
        Double(a.nanoseconds - b.nanoseconds) / 1e9
    }
}

public protocol MonotonicClock: Sendable { func now() -> MonotonicTime }

public struct SystemMonotonicClock: MonotonicClock {
    public init() {}
    public func now() -> MonotonicTime {
        MonotonicTime(nanoseconds: Int64(DispatchTime.now().uptimeNanoseconds))   // macOS
    }
}
```

On Linux `DispatchTime` exists but `ContinuousClock` is cleaner; gate with
`#if canImport(Darwin)` and use `ContinuousClock.now` + a stored origin on Linux. The **entire pure
pipeline takes time as a parameter** (`ingestRTP(_:at:)`, `tick(_:)`) — no type in `VigilRTP`
calls `clock.now()` internally except the convenience initializers. `ManualClock` (test target
only) is a `final class` with an `NSLock` and `@unchecked Sendable` (not `Mutex`, which needs
macOS 15).

### 2.3 `Codec`, `ParameterSets`, `AudioFormatDescription`

```swift
public enum Codec: String, Sendable, Hashable, CaseIterable {
    case h264, h265, aac, pcmS16LE
}

/// H.264 uses `sps`/`pps`; H.265 additionally uses `vps`. Each element is one NAL unit
/// **without** start code and **without** length prefix, emulation-prevention bytes intact.
public struct ParameterSets: Sendable, Hashable {
    public var vps: [Data]
    public var sps: [Data]
    public var pps: [Data]
    public init(vps: [Data] = [], sps: [Data] = [], pps: [Data] = []) { … }
    public var isComplete: Bool { !sps.isEmpty && !pps.isEmpty }        // VPS optional for H.264
    /// For AAC this carries the AudioSpecificConfig in `sps[0]` — see §8.6.
}

public struct AudioFormatDescription: Sendable, Hashable {
    public var sampleRate: Int32
    public var channels: Int32
    public var framesPerPacket: Int32     // 1024 AAC-LC, 960 AAC-LC/960, 1 for PCM
}
```

### 2.4 `EncodedFrame` — the pure/impure boundary type

```swift
/// One access unit (video) or one audio buffer. This is the ONLY media type that crosses from the
/// pure layer to VigilVideo. Foundation-only by construction.
public struct EncodedFrame: Sendable {

    // ---- required core (named exactly as the contract demands) ----

    /// Video: concatenated NAL units, each preceded by a **4-byte big-endian length** (AVCC/HVCC
    /// style, `nalUnitHeaderLength == 4`). NEVER Annex-B. Start codes never appear here.
    /// Audio, codec == .aac:      one raw AAC access unit, no ADTS header, no length prefix.
    /// Audio, codec == .pcmS16LE: interleaved signed 16-bit little-endian samples.
    public var data: Data

    public var pts: MediaTimestamp
    /// `nil` for live H.264/H.265 from Hikvision (no B-frames in any Hikvision live profile) and
    /// for all audio. Populated only when the depacketizer sees a stream that needs reorder, in
    /// which case it equals `pts`; POC-based reordering is VigilVideo's job, not ours.
    public var dts: MediaTimestamp?
    public var isKeyframe: Bool
    public var codec: Codec
    /// Non-nil **only on the first frame after the set changed** (including the very first frame).
    /// VigilVideo must (re)create its format description whenever this is non-nil.
    public var parameterSets: ParameterSets?

    // ---- documented additions (all defaulted; the required set above is unchanged) ----

    public var duration: MediaTimestamp?          // audio always; video only when fps is known
    /// true when at least one NAL was lost or truncated. VigilVideo must drop these unless
    /// `Settings.decodeCorruptFrames` is on (default off).
    public var isCorrupt: Bool = false
    /// Extended (unwrapped) RTP sequence numbers of the first and last packet that fed this frame.
    public var sequenceRange: ClosedRange<UInt32>?
    /// Arrival time of the LAST packet of the frame — the anchor for glass-to-glass latency.
    public var receivedAt: MonotonicTime
    public var audioFormat: AudioFormatDescription?
    /// Count of NALs in `data`; lets VigilVideo size its scratch arrays without rescanning.
    public var nalCount: Int = 0

    @inlinable public var byteCount: Int { data.count }
}
```

**Rule for `VigilVideo`:** it may pass `data` straight to `CMBlockBufferCreateWithMemoryBlock`
because the length prefix width already matches `nalUnitHeaderLength: 4`. **No conversion step
exists in the pipeline.** `VigilBitstream`'s Annex-B converters are for file muxing and tests only.

---

## 3. RTP fixed header (RFC 3550 §5.1)

### 3.1 Wire layout

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|V=2|P|X|  CC   |M|     PT      |       sequence number         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           timestamp                           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|           synchronization source (SSRC) identifier            |
+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+
|            contributing source (CSRC) identifiers  (CC × 4)   |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  (if X == 1) profile-specific ID   |        length (words)    |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                  header extension data (length × 4)           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                            payload                            |
|            ... (if P == 1) padding, last byte = pad length    |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

RFC diagrams number the most-significant bit as “bit 0”. **In code we use Swift bit positions
(bit 7 = MSB).** The table below is authoritative; use the masks literally.

| Byte | Swift mask / shift | Field | Width | Valid values |
|---|---|---|---|---|
| 0 | `(b0 & 0xC0) >> 6` | version `V` | 2 | must be `2`, else `.badVersion` |
| 0 | `(b0 & 0x20) != 0` | padding `P` | 1 | |
| 0 | `(b0 & 0x10) != 0` | extension `X` | 1 | |
| 0 | `b0 & 0x0F` | CSRC count `CC` | 4 | 0…15; Hikvision always 0 |
| 1 | `(b1 & 0x80) != 0` | marker `M` | 1 | **unreliable, see §7** |
| 1 | `b1 & 0x7F` | payload type `PT` | 7 | 0, 8, or 96…127 dynamic |
| 2–3 | big-endian `UInt16` | sequence number | 16 | wraps; see §10.1 |
| 4–7 | big-endian `UInt32` | timestamp | 32 | 90 kHz video; wraps every ≈13 h 15 m |
| 8–11 | big-endian `UInt32` | SSRC | 32 | change ⇒ hard reset, §14.4 |
| 12 … 12+4·CC−1 | | CSRC list | 32 each | mixers only; we keep but ignore |

Minimum valid packet length is **12 bytes** (`RTPPacket.fixedHeaderSize`). Header end offset is
`12 + 4*CC` (+ `4 + 4*extLength` when `X == 1`).

### 3.2 CSRC list

Present only behind an RTP mixer. Hikvision cameras and NVRs never set `CC != 0`. We parse the
list because skipping it wrongly corrupts the payload offset, but we do not act on it. To avoid a
heap allocation on the hot path, `csrcs` is stored as `[UInt32]` that stays the shared empty array
when `CC == 0`:

```swift
let csrcs: [UInt32] = cc == 0 ? [] : (0..<Int(cc)).map { r.readUInt32BE(at: 12 + 4 * $0) }
```

### 3.3 Header extension (RFC 3550 §5.3.1 + RFC 8285)

When `X == 1` a 4-byte extension header follows the CSRC list:

| Offset from ext start | Field | Notes |
|---|---|---|
| 0–1 | `profile` (`UInt16` BE) | `0xBEDE` = RFC 8285 one-byte form; `0x1000 \| appBits` (i.e. top 12 bits `0x100`) = two-byte form; anything else = opaque |
| 2–3 | `length` (`UInt16` BE) | number of **32-bit words** of extension data, *excluding* these 4 bytes |
| 4 … 4+4·length−1 | extension data | |

**One-byte form (`profile == 0xBEDE`).** Elements are packed as:

```
 0
 0 1 2 3 4 5 6 7
+-+-+-+-+-+-+-+-+
|  ID   |  len  |   → dataLength = len + 1   (1…16 bytes)
+-+-+-+-+-+-+-+-+
```
* `ID == 0`: a single padding byte — skip it, continue.
* `ID == 15`: reserved “stop” marker — stop parsing, the remainder is padding.
* Otherwise consume `len + 1` bytes of value. If fewer remain, stop and count
  `.malformedExtension` (do **not** fail the packet).

**Two-byte form (`profile & 0xFFF0 == 0x1000`).** The low 4 bits are `appBits`. Elements are:

```
 0                   1
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|       ID      |     length    |   → dataLength = length (0…255, zero allowed)
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```
`ID == 0` is padding (a single `0x00` byte, no length byte follows). Same non-fatal error policy.

```swift
public struct RTPHeaderExtension: Sendable, Hashable {
    public var profile: UInt16
    public var data: Data                       // the length*4 payload, zero-copy slice
    public var isOneByteForm: Bool  { profile == 0xBEDE }
    public var isTwoByteForm: Bool  { profile & 0xFFF0 == 0x1000 }
    public var appBits: UInt8       { isTwoByteForm ? UInt8(profile & 0x0F) : 0 }

    public struct Element: Sendable, Hashable { public var id: UInt8; public var value: Data }
    /// Never throws. Returns as many well-formed elements as it can and sets `truncated`.
    public func elements() -> (elements: [Element], truncated: Bool)
}
```

**Hikvision note.** Some firmware (observed on DS-7600/DS-7700 NVR sub-streams and on a few
DS-2CD2xxx builds) emits a private extension with `profile == 0xABAC` carrying a BCD wall clock.
We expose it verbatim via `RTPPacket.headerExtension` and **do not interpret it in v1**. An unknown
profile is never an error: skip exactly `length * 4` bytes and continue. Getting this wrong shifts
the payload and produces “decoder works on cameras A and B but not C” bugs.

### 3.4 Padding

When `P == 1`, the **last byte of the packet** is the padding length *including that byte itself*.

```swift
var payloadEnd = data.count
if hasPadding {
    let pad = Int(byte(data, data.count - 1))
    guard pad >= 1, headerEnd + pad <= data.count else { throw .badPaddingLength(UInt8(pad)) }
    payloadEnd = data.count - pad
}
let payload = data[(dStart + headerEnd)..<(dStart + payloadEnd)]
```

A zero padding length or one that would eat the header is fatal for that packet only
(`.badPaddingLength`) — count it and continue with the next packet. An **empty payload after
padding removal is legal** (RFC 3550 allows it, and Hikvision emits one such packet at the end of
some GOPs); depacketizers must return no frames rather than crash.

### 3.5 `RTPPacket` and the parser

```swift
public struct RTPPacket: Sendable {
    public var version: UInt8
    public var hasPadding: Bool
    public var marker: Bool
    public var payloadType: UInt8
    public var sequenceNumber: UInt16
    public var timestamp: UInt32
    public var ssrc: UInt32
    public var csrcs: [UInt32]
    public var headerExtension: RTPHeaderExtension?
    /// Zero-copy slice of the caller's buffer, padding removed. See the hazard note below.
    public var payload: Data
    public var receivedAt: MonotonicTime
    /// Total wire size including header and padding — used for kbps accounting.
    public var wireByteCount: Int

    public static let fixedHeaderSize = 12

    public static func parse(
        _ data: Data, receivedAt: MonotonicTime
    ) throws(RTPParseError) -> RTPPacket
}
```

**Slice-indexing hazard (mandatory reading).** `Data` slices keep the parent’s indices, so
`payload[0]` traps when `payload.startIndex != 0`. Every byte access inside this module goes
through the internal wrapper:

```swift
@usableFromInline
struct Bytes {
    @usableFromInline let base: Data
    @usableFromInline let start: Int
    @usableFromInline let count: Int
    @inlinable init(_ d: Data) { base = d; start = d.startIndex; count = d.count }
    @inlinable subscript(i: Int) -> UInt8 { base[start + i] }
    @inlinable func u16(_ i: Int) -> UInt16 { UInt16(self[i]) << 8 | UInt16(self[i + 1]) }
    @inlinable func u24(_ i: Int) -> UInt32 { UInt32(self[i]) << 16 | UInt32(self[i+1]) << 8 | UInt32(self[i+2]) }
    @inlinable func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) << 16 | UInt32(u16(i + 2)) }
    @inlinable func slice(_ r: Range<Int>) -> Data { base[(start + r.lowerBound)..<(start + r.upperBound)] }
}
```

Reviewers must reject any `payload[n]` with a bare integer literal in this module.

Parser skeleton — note **typed throws** (Swift 6) so callers can exhaustively switch:

```swift
public static func parse(_ data: Data, receivedAt: MonotonicTime) throws(RTPParseError) -> RTPPacket {
    let b = Bytes(data)
    guard b.count >= fixedHeaderSize else { throw .tooShort(needed: 12, got: b.count) }
    let v = (b[0] & 0xC0) >> 6
    guard v == 2 else { throw .badVersion(v) }
    let cc = Int(b[0] & 0x0F)
    var off = fixedHeaderSize + 4 * cc
    guard b.count >= off else { throw .truncatedCSRC }
    var ext: RTPHeaderExtension?
    if b[0] & 0x10 != 0 {
        guard b.count >= off + 4 else { throw .truncatedExtension }
        let profile = b.u16(off), words = Int(b.u16(off + 2))
        guard b.count >= off + 4 + words * 4 else { throw .truncatedExtension }
        ext = RTPHeaderExtension(profile: profile, data: b.slice((off + 4)..<(off + 4 + words * 4)))
        off += 4 + words * 4
    }
    var end = b.count
    if b[0] & 0x20 != 0 {
        let pad = Int(b[b.count - 1])
        guard pad >= 1, off + pad <= b.count else { throw .badPaddingLength(UInt8(truncatingIfNeeded: pad)) }
        end = b.count - pad
    }
    return RTPPacket(
        version: 2, hasPadding: b[0] & 0x20 != 0, marker: b[1] & 0x80 != 0,
        payloadType: b[1] & 0x7F, sequenceNumber: b.u16(2), timestamp: b.u32(4), ssrc: b.u32(8),
        csrcs: cc == 0 ? [] : (0..<cc).map { b.u32(12 + 4 * $0) },
        headerExtension: ext, payload: b.slice(off..<end),
        receivedAt: receivedAt, wireByteCount: b.count)
}
```

---

## 4. Track format, payload-type binding, factory

### 4.1 `RTPTrackFormat`

```swift
public struct RTPTrackFormat: Sendable, Hashable {
    public var payloadType: UInt8
    public var encodingName: String        // as received; compare case-insensitively (§8.7)
    public var clockRate: Int32            // 90_000 video, sample rate audio, 8_000 G.711
    public var channels: Int32             // default 1
    public var fmtp: [String: String]      // keys ALREADY lower-cased by the caller
    /// From SDP `sprop-parameter-sets` / `sprop-vps|sps|pps`, already base64-decoded by VigilRTSP.
    public var initialParameterSets: ParameterSets?

    public var resolvedCodec: Codec? {
        switch encodingName.lowercased() {
        case "h264": return .h264
        case "h265", "hevc": return .h265
        case "mpeg4-generic": return .aac        // also "MPEG4-GENERIC", handled by lowercasing
        case "pcma", "pcmu", "g726-32", "aal2-g726-32", "g726": return .pcmS16LE
        default: return nil
        }
    }
    /// RFC 3551 static bindings, used when the SDP omits rtpmap (Hikvision NVRs sometimes do).
    public static func staticBinding(for pt: UInt8) -> RTPTrackFormat? {
        switch pt {
        case 0:  return .init(payloadType: 0, encodingName: "PCMU", clockRate: 8000, channels: 1, fmtp: [:])
        case 8:  return .init(payloadType: 8, encodingName: "PCMA", clockRate: 8000, channels: 1, fmtp: [:])
        case 26: return nil     // JPEG — not supported, see §17
        default: return nil
        }
    }
}
```

### 4.2 Factory and the enum wrapper

Existential + `mutating` is painful and boxes on every packet, so the pipeline uses an enum:

```swift
public enum AnyDepacketizer: Sendable {
    case h264(H264Depacketizer)
    case h265(H265Depacketizer)
    case aac(AACDepacketizer)
    case pcm(PCMDepacketizer)          // PCMA / PCMU / G726-32, decodes to pcmS16LE

    public mutating func push(_ p: RTPPacket) -> DepacketizerOutput {
        switch self {
        case .h264(var d): let o = d.push(p); self = .h264(d); return o
        case .h265(var d): let o = d.push(p); self = .h265(d); return o
        case .aac(var d):  let o = d.push(p); self = .aac(d);  return o
        case .pcm(var d):  let o = d.push(p); self = .pcm(d);  return o
        }
    }
    public mutating func flush() -> [EncodedFrame] { … }
    public mutating func reset() { … }
    public var codec: Codec { … }
    public var clockRate: Int32 { … }
}

public enum DepacketizerFactory {
    public static func make(
        for format: RTPTrackFormat, configuration: DepacketizerConfiguration = .liveDefault
    ) throws(RTPTrackError) -> AnyDepacketizer
}
```

The `case .h264(var d)` / reassign pattern is deliberate: with a single reference to `self` it is a
move, not a copy, so no CoW allocation occurs. Verify with a `-O` allocation test (§16).

**Payload-type dispatch rule.** A packet whose `payloadType` differs from the track’s is
**dropped and counted** (`.unexpectedPayloadType`), *not* routed elsewhere. One `RTPTrackReceiver`
serves exactly one PT. Exception: RFC 2198 RED / RFC 5109 FEC PTs are dropped silently (§17).

### 4.3 `DepacketizerConfiguration`

| Field | Default (`liveDefault`) | Default (`playbackDefault`) | Meaning |
|---|---|---|---|
| `maxNALBytes` | `8 << 20` | `8 << 20` | reject a reassembled NAL larger than this |
| `maxAccessUnitBytes` | `16 << 20` | `16 << 20` | reject an AU larger than this |
| `maxFragmentsPerNAL` | `4096` | `4096` | FU-A/FU fragment count cap |
| `accessUnitTimeoutMs` | `200` | `1000` | force-close an open AU after this idle time |
| `waitForKeyframeOnStart` | `true` | `true` | drop AUs until the first IRAP |
| `waitForKeyframeAfterLoss` | `true` | `false` | re-arm the gate after a gap |
| `emitCorruptFrames` | `false` | `false` | when true, damaged AUs are emitted with `isCorrupt` |
| `trustMarkerBit` | `.adaptive` | `.adaptive` | `.never` / `.adaptive` / `.always` (§7.4) |
| `dropRASLAfterCRA` | `true` | `true` | H.265 only |
| `treatRecoveryPointAsKeyframe` | `true` | `true` | H.264 only (§5.6) |

---

## 5. H.264 depacketization (RFC 6184)

### 5.1 NAL unit header and packet-type map

The 1-byte H.264 NAL header:

| Mask | Field | Notes |
|---|---|---|
| `0x80` | `forbidden_zero_bit` (F) | must be 0; if 1 → drop NAL, count `.forbiddenBitSet` |
| `0x60` | `nal_ref_idc` (NRI) | 0 = disposable |
| `0x1F` | `nal_unit_type` | see below |

| Type | Name | Class | Handling |
|---|---|---|---|
| 1 | non-IDR slice | VCL | AU content; may still be an I-slice (§5.6) |
| 2–4 | slice data partition A/B/C | VCL | never from Hikvision; pass through |
| 5 | **IDR slice** | VCL | ⇒ `isKeyframe = true` |
| 6 | SEI | prefix | scan for recovery point (payload type 6) |
| 7 | **SPS** | prefix | capture into `ParameterSets.sps` |
| 8 | **PPS** | prefix | capture into `ParameterSets.pps` |
| 9 | AUD | prefix | AU delimiter; keep in the AU, also a boundary hint |
| 10, 11 | end of seq / end of stream | prefix | close the AU, emit `.endOfStream` for 11 |
| 12 | filler | — | **discard** (wastes decode bandwidth) |
| 13 | SPS extension | prefix | keep |
| 14 | prefix NAL | prefix | SVC; keep, count `.svcSeen` |
| 15 | subset SPS | prefix | keep |
| 19 | auxiliary slice | VCL | keep |
| 20 | slice extension | VCL | SVC/MVC; keep |
| 24 | **STAP-A** | packet | §5.3 |
| 25 | STAP-B | packet | §5.3, DON skipped |
| 26 | MTAP16 | packet | unsupported, §5.3 |
| 27 | MTAP24 | packet | unsupported, §5.3 |
| 28 | **FU-A** | packet | §5.4 |
| 29 | FU-B | packet | §5.4, DON skipped |
| 30, 31 | undefined | — | drop + count |

`nal_unit_type` values 1…23 in the *packet* position mean **single NAL unit packet**: the whole
payload is one NAL unit, header included.

### 5.2 Single NAL unit packet

```swift
// payload = [NAL header][RBSP…]
guard payload.count >= 1 else { return .malformed(.emptyPayload) }
appendNAL(payload, type: b[0] & 0x1F)
```
No copy is needed at this stage — hold the `Data` slice in the AU builder and only materialize
during `finish()` (§5.7).

### 5.3 STAP-A (type 24), STAP-B (25), MTAP (26/27)

**STAP-A** layout — this is how Hikvision ships SPS+PPS before every IDR:

```
+---------------+---------------+---------------+- - -
| STAP-A hdr    |  NALU 1 size (16 bit BE)      | NALU 1 data …
| F|NRI|  24    |                               |
+---------------+---------------+---------------+- - -
… | NALU 2 size (16 bit BE) | NALU 2 data … | (repeat until payload exhausted)
```

```swift
var i = 1
while i < payload.count {
    guard i + 2 <= payload.count else { return .malformed(.truncatedAggregate) }
    let size = Int(b.u16(i)); i += 2
    guard size > 0 else { return .malformed(.zeroLengthAggregate) }
    guard i + size <= payload.count else { return .malformed(.truncatedAggregate) }
    appendNAL(b.slice(i..<(i + size)), type: b[i] & 0x1F)
    i += size
}
```
* The STAP-A header’s NRI is `max` of the aggregated NALs’ NRI. Informational — we ignore it.
* A `size` of 0 is malformed; a `size` that overruns the payload is malformed. In both cases discard
  the **remainder** of the packet but keep the NALs already extracted, and mark the AU corrupt.
* Aggregation limit: cap at 64 NALs per STAP to bound the loop against a hostile stream.

**STAP-B (25)** inserts a 16-bit **DON** (decoding order number) immediately after the STAP-B
header, before the first size field; subsequent NALs have implicit DON = DON+1. We parse it, skip
it, and process the rest exactly as STAP-A. Emit `.interleavedModeSeen` once per session.

**MTAP16 (26) / MTAP24 (27)** carry a 16-bit `DONB`, then per NAL a 16-bit size, an 8-bit `DOND`
and a 16- or 24-bit timestamp offset. They only make sense in interleaved mode (packetization-mode
2), which no Hikvision firmware uses. **Decision: unsupported.** Drop the packet, emit
`.unsupportedAggregation(type)` once, and continue. Do not try to half-implement them.

### 5.4 FU-A (type 28) and FU-B (29) — exact bit math

```
+---------------+---------------+- - - - - - -
| FU indicator  |  FU header    | FU payload …
| F|NRI| Type=28| S|E|R|  Type  |
+---------------+---------------+- - - - - - -
```

| Byte | Mask | Field |
|---|---|---|
| 0 | `0x80` / `0x60` / `0x1F` | F / NRI of the **original** NAL; Type = 28 (or 29) |
| 1 | `0x80` | `S` — start of fragmented NAL |
| 1 | `0x40` | `E` — end of fragmented NAL |
| 1 | `0x20` | `R` — reserved; **must be ignored on receive** |
| 1 | `0x1F` | `Type` — `nal_unit_type` of the **original** NAL |

The reconstructed original NAL header byte is:

```swift
let indicator = b[0], fuHeader = b[1]
let start   = (fuHeader & 0x80) != 0
let end     = (fuHeader & 0x40) != 0
let nalType =  fuHeader & 0x1F
let reconstructedHeader = (indicator & 0xE0) | nalType     // F+NRI from indicator, type from FU hdr
```

`0xE0` (not `0x60`) is correct: it carries the forbidden bit *and* NRI. The `R` bit is deliberately
not part of the reconstruction. FU-B additionally has a 16-bit DON after the FU header, present
**only when `S == 1`**; skip 2 bytes there.

Reassembly state and error handling:

```swift
struct FUState {
    var header: UInt8            // reconstructed NAL header
    var type: UInt8
    var pieces: [Data]           // fragment payloads, no FU bytes
    var byteCount: Int
    var timestamp: UInt32
    var expectedSeq: UInt16      // sequence number the next fragment must have
    var firstSeq: UInt16
    var fragmentCount: Int
}
```

| Condition | Action | Accounting |
|---|---|---|
| `S == 1` while a FU is already open | abandon the open FU, start a new one, mark AU corrupt | `.lostLastFragment` |
| `S == 0` and no FU open | discard the fragment, mark AU corrupt, arm the keyframe gate | `.lostFirstFragment` |
| `packet.sequenceNumber != fuState.expectedSeq` | abandon the FU (a middle fragment was lost), mark AU corrupt | `.fragmentGap` |
| `packet.timestamp != fuState.timestamp` | abandon the FU (illegal per RFC 6184 §5.8) | `.fragmentTimestampChange` |
| payload length < 2 (`< 4` for FU-B with S=1) | drop packet | `.truncatedFragment` |
| `fragmentCount > maxFragmentsPerNAL` or `byteCount > maxNALBytes` | abandon FU | `.nalTooLarge` |
| `E == 1` | finish the NAL: `Data` of `[header] + pieces`, append to AU | — |
| AU closes with a FU still open | discard that NAL, mark AU corrupt | `.incompleteFragmentAtAUEnd` |

**Never emit a partially reassembled slice NAL.** A truncated slice makes VideoToolbox return
`kVTVideoDecoderBadDataErr`, and on some HEVC builds it produces visibly corrupted output that
persists for the whole GOP. Discard the NAL; if it was a VCL NAL, discard the entire AU (a picture
missing a slice is worse than a dropped picture) and request a keyframe (§10.6).

Reassembly buffer strategy: `pieces` is `[Data]`, appended without copying. On `E == 1`,
`reserveCapacity(byteCount + 1)` once, then a single concatenation pass. A 1080p IDR at 4 Mbps is
~40 fragments; the amortized cost is one allocation per NAL.

### 5.5 DON (decoding order number)

DON exists only for interleaved packetization (`packetization-mode=2`). Our position:

* We announce nothing in SETUP that requests interleaving; Hikvision offers mode 0 or 1.
* If SDP says `packetization-mode=2`, emit `.interleavedModeUnsupported` once and continue in
  non-interleaved mode. Frames may be reordered by DON in theory; in practice this never triggers.
* STAP-B / FU-B DON fields are parsed for correct byte alignment and then discarded.
* Reordering by DON is **not** implemented. §17.

### 5.6 Keyframe determination (H.264)

An AU is a keyframe if **either**:

1. it contains a NAL of type 5 (IDR), **or**
2. `treatRecoveryPointAsKeyframe` is on **and** the AU contains an SEI (type 6) whose first
   `payloadType` is `6` (recovery point) **and** at least one VCL slice with
   `slice_type ∈ {2, 4, 7, 9}` (I / SI).

Rule 2 matters: several Hikvision H.264 builds signal open-GOP random access points as type-1
slices with a recovery-point SEI and only send a true IDR every few minutes. Without rule 2 the
keyframe gate (§14.4) can stall a stream for minutes after any packet loss.

SEI scanning: after the NAL header, SEI messages are `payloadType` and `payloadSize` encoded as
sequences of `0xFF`-continuation bytes:

```swift
func firstSEIPayloadTypes(_ nal: Data, limit: Int = 8) -> [Int] {
    var out: [Int] = [], i = 1, b = Bytes(nal)
    while i < b.count, out.count < limit {
        var type = 0; while i < b.count, b[i] == 0xFF { type += 255; i += 1 }
        guard i < b.count else { break }; type += Int(b[i]); i += 1
        var size = 0; while i < b.count, b[i] == 0xFF { size += 255; i += 1 }
        guard i < b.count else { break }; size += Int(b[i]); i += 1
        out.append(type); i += size
        if i < b.count, b[i] == 0x80 { break }        // rbsp_trailing_bits
    }
    return out
}
```

### 5.7 AU materialization

`AccessUnitBuilder.finish()` produces the `EncodedFrame.data` in a single pass:

```swift
var out = Data(); out.reserveCapacity(byteCount + 4 * nals.count)
for nal in nals {
    let n = UInt32(nal.count)
    out.append(UInt8(truncatingIfNeeded: n >> 24)); out.append(UInt8(truncatingIfNeeded: n >> 16))
    out.append(UInt8(truncatingIfNeeded: n >> 8));  out.append(UInt8(truncatingIfNeeded: n))
    out.append(nal)
}
```

Filler NALs (type 12) and, when `stripAUD` is on (default **off** — VideoToolbox tolerates AUD),
type-9 NALs are excluded before this loop. Parameter sets are kept **both** inside `data` and in
`parameterSets` — VideoToolbox accepts in-band SPS/PPS in AVCC-style buffers and Hikvision’s
in-band copies are the only ones some NVR playback streams provide.

---

## 6. H.265 depacketization (RFC 7798)

### 6.1 The 2-byte PayloadHdr / NAL header

```
 0                   1
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|F|   Type    |  LayerId  | TID |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

| Field | Width | Extraction | Notes |
|---|---|---|---|
| `F` (`forbidden_zero_bit`) | 1 | `(b0 & 0x80) >> 7` | must be 0 |
| `Type` (`nal_unit_type`) | 6 | `(b0 >> 1) & 0x3F` | **6 bits, straddles no byte** |
| `LayerId` (`nuh_layer_id`) | 6 | `((UInt16(b0 & 0x01) << 5) \| UInt16(b1 >> 3))` | spans both bytes |
| `TID` (`nuh_temporal_id_plus1`) | 3 | `b1 & 0x07` | `temporal_id = TID - 1`; TID must be ≥ 1 |

Composition: `b0 = (F << 7) | (Type << 1) | (LayerId >> 5)`,
`b1 = ((LayerId & 0x1F) << 3) | TID`.

We drop NALs with `LayerId != 0` (scalable/multiview layers) and count `.nonBaseLayerDropped`;
Hikvision never sends them, and passing them to VideoToolbox risks a malfunction error.

### 6.2 NAL type table

| Type | Name | Class | Handling |
|---|---|---|---|
| 0 | TRAIL_N | VCL, sub-layer non-ref | AU content |
| 1 | TRAIL_R | VCL | AU content |
| 2, 3 | TSA_N, TSA_R | VCL | AU content |
| 4, 5 | STSA_N, STSA_R | VCL | AU content |
| 6, 7 | RADL_N, RADL_R | VCL, leading | AU content |
| 8, 9 | RASL_N, RASL_R | VCL, leading | **dropped when the stream started at a CRA** (§6.6) |
| 10–15 | RSV_VCL_N/R 10…15 | VCL reserved | keep, count |
| 16 | BLA_W_LP | VCL **IRAP** | keyframe |
| 17 | BLA_W_RADL | VCL **IRAP** | keyframe |
| 18 | BLA_N_LP | VCL **IRAP** | keyframe |
| 19 | **IDR_W_RADL** | VCL **IRAP** | keyframe — Hikvision’s normal keyframe |
| 20 | IDR_N_LP | VCL **IRAP** | keyframe |
| 21 | CRA_NUT | VCL **IRAP** | keyframe; see RASL rule |
| 22, 23 | RSV_IRAP_VCL22/23 | VCL **IRAP** | keyframe |
| 24–31 | RSV_VCL 24…31 | VCL reserved | keep, count |
| 32 | **VPS** | prefix | `ParameterSets.vps` |
| 33 | **SPS** | prefix | `ParameterSets.sps` |
| 34 | **PPS** | prefix | `ParameterSets.pps` |
| 35 | AUD | prefix | AU delimiter + boundary hint |
| 36, 37 | EOS_NUT, EOB_NUT | prefix | close AU; `.endOfStream` for 37 |
| 38 | FD_NUT (filler) | — | **discard** |
| 39 | PREFIX_SEI | prefix | scan for recovery point (SEI payload type 6) |
| 40 | SUFFIX_SEI | suffix | see §7.5 |
| 41–47 | reserved non-VCL | — | keep, count |
| 48 | **AP** (aggregation) | packet | §6.3 |
| 49 | **FU** (fragmentation) | packet | §6.4 |
| 50 | PACI | packet | **unsupported**, §6.5 |
| 51–63 | reserved | — | drop, count |

Derived predicates (put them in `H265NAL` as `@inlinable static func`):

```swift
static func isVCL(_ t: UInt8) -> Bool          { t <= 31 }
static func isIRAP(_ t: UInt8) -> Bool         { (16...23).contains(t) }
static func isParameterSet(_ t: UInt8) -> Bool { (32...34).contains(t) }
static func isRASL(_ t: UInt8) -> Bool         { t == 8 || t == 9 }
static func isSliceSegment(_ t: UInt8) -> Bool { t <= 21 }     // the "slice types 0..21" range
```

Note the assignment’s “slice types (0..21)” = the VCL types actually defined by H.265 v1
(0…21); 22…31 are reserved VCL. Treat 22…31 as VCL for AU-building purposes but never as
keyframes unless in 22…23 (reserved IRAP).

### 6.3 AP — aggregation packet (type 48)

```
+-------------+-------------+---------------------------------+- - -
| PayloadHdr (Type=48)      | [DONL (16b, if sprop-max-don-   |
|                           |  diff > 0)]                     |
+-------------+-------------+---------------------------------+- - -
| NALU 1 size (16b BE)      | NALU 1 (incl. its 2-byte hdr)   |
+---------------------------+---------------------------------+
| [DOND (8b)] | NALU 2 size (16b BE) | NALU 2 …                |
+-------------------------------------------------------------+
```

* `DONL` is present **once**, before the first aggregation unit, and **only** when the SDP fmtp
  contains `sprop-max-don-diff` with a value > 0.
* When DONL is in use, every aggregation unit *after the first* is preceded by an 8-bit `DOND`.
  When it is not in use, there is no DOND anywhere.
* Parse loop:

```swift
var i = 2
if usesDONL { guard payload.count >= 4 else { return .malformed(.truncatedAggregate) }; i = 4 }
var first = true
while i < payload.count {
    if !first && usesDONL { guard i + 1 <= payload.count else { break }; i += 1 }   // DOND
    guard i + 2 <= payload.count else { return .malformed(.truncatedAggregate) }
    let size = Int(b.u16(i)); i += 2
    guard size >= 2, i + size <= payload.count else { return .malformed(.truncatedAggregate) }
    appendNAL(b.slice(i..<(i + size)))
    i += size; first = false
}
```
`size >= 2` (not `> 0`) because an H.265 NAL always has a 2-byte header.

### 6.4 FU — fragmentation unit (type 49)

```
+-------------+-------------+---------------+-------------+- - -
| PayloadHdr (Type=49)      | [DONL (16b)]  | FU header   | FU payload …
|                           |               | S|E| FuType |
+-------------+-------------+---------------+-------------+- - -
```

| Byte (of FU header) | Mask | Field |
|---|---|---|
| 0 | `0x80` | `S` — start |
| 0 | `0x40` | `E` — end |
| 0 | `0x3F` | `FuType` — the original `nal_unit_type` (6 bits, **not** 5) |

`DONL` is present when `sprop-max-don-diff > 0` and **only in the fragment with `S == 1`**
(RFC 7798 §4.4.3). So the FU header offset is `2` normally, `4` when `usesDONL && S == 1` — but
`S` lives in the FU header, which is the byte you need the offset for. Resolve it as follows: when
`usesDONL`, read the candidate FU header at offset 4; if its `S` bit is 0, re-read at offset 2.
Concretely:

```swift
var fuOffset = 2
if usesDONL {
    guard payload.count >= 5 else { return .malformed(.truncatedFragment) }
    if (b[4] & 0x80) != 0 { fuOffset = 4 } else { fuOffset = 2 }
}
guard payload.count > fuOffset else { return .malformed(.truncatedFragment) }
let fu = b[fuOffset]
let start = (fu & 0x80) != 0, end = (fu & 0x40) != 0
let fuType = fu & 0x3F
let dataStart = fuOffset + 1
```

Reconstructing the original 2-byte NAL header — **this is the H.265 equivalent of the FU-A math**:

```swift
let hdr0 = (b[0] & 0x81) | (fuType << 1)      // keep F (0x80) and LayerId's top bit (0x01)
let hdr1 =  b[1]                              // LayerId low bits + TID unchanged
```

`0x81` is the load-bearing constant: bit 7 is `F`, bit 0 is `nuh_layer_id >> 5`. Masking with
`0x80` alone silently zeroes the top layer-id bit; masking with `0x01` alone drops `F`. Verify with
the vector in §15.4.

Error handling is identical to FU-A (§5.4 table), plus:
* `fuType` in 48…50 is illegal (a FU cannot fragment an AP/FU/PACI) → drop, `.nestedPacketization`.
* A single-fragment FU (`S == 1 && E == 1`) is legal and must work; it appears on some NVR streams.

### 6.5 PACI (type 50)

PACI wraps a NAL together with a payload-header extension structure (`A`, `cType`, `PHSsize`,
`F`, `Y`, plus TSCI). It exists for temporal scalability signalling. No Hikvision firmware emits
it. **Decision: unsupported.** Drop the packet, emit `.unsupportedPacketization(50)` once per
session. Do not attempt a partial implementation — a wrong `PHSsize` skip produces garbage NALs.

### 6.6 CRA / RASL start-up rule

When the first IRAP we accept is a CRA (type 21) or a BLA (16…18), `NoRaslOutputFlag` is 1 and the
RASL pictures that follow reference unavailable pictures. With `dropRASLAfterCRA == true`, drop
every AU whose first VCL NAL is type 8 or 9 until an AU with a non-RASL VCL NAL arrives. Count them
as `framesDropped`, not as loss.

### 6.7 Keyframe determination (H.265)

`isKeyframe = AU contains a VCL NAL with type in 16…23`. The recovery-point fallback of §5.6 also
applies (PREFIX_SEI type 39 containing SEI payload type 6 plus an I-slice), but Hikvision H.265
always sends IDR_W_RADL, so it is a safety net only.

---

## 7. Access-unit boundary detection — **do not trust the marker bit**

This is the single most important behavioural requirement in this module.

### 7.1 The problem

RFC 3550 says the marker bit “allows significant events such as frame boundaries to be marked”, and
RFC 6184 §5.1 says it is set on the last packet of an access unit. Hikvision firmware in the field
does all of the following, sometimes on different channels of the same NVR:

| Observed behaviour | Consequence if we trust `M` |
|---|---|
| `M` never set (some DS-2CD2xxx H.265 builds, sub-stream) | AUs never close → the pipeline stalls, memory grows |
| `M` set on **every** packet (older DS-2DExxx) | every fragment becomes a frame → decoder floods with garbage |
| `M` set only on the last packet of the last *slice* — correct | fine |
| `M` set on the last packet of *each* slice in a multi-slice picture | pictures split into partial AUs → tearing, `BadDataErr` |
| `M` set one packet early on I-frames (a DS-7616 playback bug) | last fragment of the IDR lands in the next AU → green blocks |

Therefore: **the marker bit is a latency optimization, never a correctness input.**

### 7.2 The authoritative rules

Detection is split into *open* rules (does this NAL start a new AU?) and *close* rules (can we emit
the AU now?).

**Open rules — evaluated for each NAL, in order. First match wins.**

| # | Condition | Result |
|---|---|---|
| O1 | builder is empty | start the AU with this NAL |
| O2 | `packet.timestamp != builder.rtpTimestamp` | **close** the open AU, start a new one |
| O3 | NAL is a prefix NAL (H.264 6/7/8/9/13/14/15, H.265 32/33/34/35/39) **and** `builder.sawVCL` | close, start new |
| O4 | NAL is VCL **and** `builder.sawVCL` **and** `firstSliceFlag(NAL) == true` | close, start new |
| O5 | otherwise | append to the current AU |

O2 is the load-bearing rule: RFC 3550 guarantees that all packets of one access unit carry the same
RTP timestamp, and every firmware we have tested honours this. O4 catches the pathological case
where two pictures share a timestamp (seen on NVR playback streams that re-mux two channels, and on
one DS-7608 firmware where the timestamp only advances every second picture).

**Close rules — evaluated after appending, in order. First match wins.**

| # | Condition | Added latency | Notes |
|---|---|---|---|
| C1 | next packet has a different timestamp (rule O2) | up to one frame interval | always active, always correct |
| C2 | `packet.marker == true` and `markerTrust == .trusted` | 0 | §7.4 |
| C3 | `sliceProfile == .singleSlicePerPicture` and we just completed a VCL NAL | 0 | §7.4 |
| C4 | `now - builder.firstArrival > accessUnitTimeoutMs` | timeout | mark corrupt if a FU is open |
| C5 | `maxAccessUnitBytes` exceeded | — | drop the AU, `.accessUnitTooLarge`, request keyframe |
| C6 | H.264 type 10/11 or H.265 type 36/37 appended | 0 | end of sequence/stream |

C3 is how we reach zero added latency on the overwhelmingly common Hikvision configuration (one
slice per picture): the last FU fragment with `E == 1` *is* the end of the picture, so we can emit
immediately without waiting for the next frame’s first packet and without trusting `M`.

### 7.3 `firstSliceFlag` — the two-bit peek

We need one bit from the slice header. No full parser, no `VigilBitstream` dependency.

**H.264.** The slice header begins immediately after the 1-byte NAL header with
`first_mb_in_slice` as `ue(v)`. An Exp-Golomb-coded zero is the single bit `1`. Therefore
`first_mb_in_slice == 0` **iff the most significant bit of the first RBSP byte is 1**:

```swift
@inlinable static func h264FirstSliceInPicture(_ nal: Data) -> Bool? {
    let b = Bytes(nal)
    guard b.count >= 2, H264NAL.isVCL(b[0] & 0x1F) else { return nil }
    return (b[1] & 0x80) != 0
}
```
No emulation-prevention handling is needed: `0x000003` cannot start at RBSP byte 0 of a slice
header whose first bit is meaningful, and we only read one byte.

**H.265.** The slice segment header begins after the 2-byte NAL header with
`first_slice_segment_in_pic_flag` as `u(1)` — literally the MSB of the third byte:

```swift
@inlinable static func h265FirstSliceInPicture(_ nal: Data) -> Bool? {
    let b = Bytes(nal)
    guard b.count >= 3, H265NAL.isVCL((b[0] >> 1) & 0x3F) else { return nil }
    return (b[2] & 0x80) != 0
}
```

**H.264 `slice_type` (needed only for §5.6).** Parse two `ue(v)` fields with
`VigilProtocols.BitReader` in RBSP mode:

```swift
static func h264SliceType(_ nal: Data) -> Int? {
    var r = BitReader(rbsp: nal.dropFirst())          // strips emulation-prevention bytes lazily
    guard let _ = try? r.readUE(), let st = try? r.readUE(), st <= 9 else { return nil }
    return Int(st)     // I-slice iff st == 2, 4, 7, or 9
}
```

When a fragmented NAL is still incomplete, the first fragment already contains the bytes we need,
so O4 can be evaluated on the **first fragment** of a FU (`S == 1`) — do it there, not after
reassembly, otherwise a multi-slice picture opens a new AU one NAL too late.

### 7.4 Adaptive learning of `sliceProfile` and `markerTrust`

```swift
public enum SliceProfile: Sendable { case unknown, singleSlicePerPicture, multiSlice }
public enum MarkerTrust: Sendable  { case probing, trusted, broken }

struct BoundaryPolicy: Sendable {
    var sliceProfile: SliceProfile = .unknown
    var markerTrust: MarkerTrust = .probing
    private var vclCountsWindow = RingCounter(capacity: 64)   // VCL NALs per closed AU
    private var cleanMarkerAUs = 0
    private var markerViolations = 0
}
```

Learning rules, evaluated when an AU closes:

| Signal | Transition |
|---|---|
| 32 consecutive closed AUs each with exactly 1 VCL NAL | `sliceProfile = .singleSlicePerPicture` |
| any closed AU with ≥ 2 VCL NALs | `sliceProfile = .multiSlice`; needs 64 consecutive single-VCL AUs to go back |
| marker was set on exactly the last packet of the AU and on no earlier packet of it | `cleanMarkerAUs += 1`; at 32 → `markerTrust = .trusted` |
| marker set on a non-final packet, or not set at all on a completed AU | `markerViolations += 1`, `cleanMarkerAUs = 0`; at 2 violations → `.broken` |
| `.broken` and 128 consecutive clean AUs | back to `.trusted` (handles a firmware that fixes itself after a re-PLAY) |
| resolution change / SPS change / SSRC change / reset | reset both to `.unknown` / `.probing` |

Convergence: at 25 fps the policy settles in ≈1.3 s. During `.probing` with
`sliceProfile == .unknown`, only C1 and C4 apply, so added latency is at most one frame interval
(40 ms at 25 fps) — acceptable, bounded, and self-healing. `trustMarkerBit = .always` forces
`markerTrust = .trusted` (debug only); `.never` pins `.broken`.

Emit `.boundaryPolicyChanged(sliceProfile:markerTrust:)` on each transition so the diagnostics
panel can show it. This is one of the few places where a user-visible “why is this camera laggy”
answer comes from.

### 7.5 Suffix NALs after an early close

If C2/C3 closed an AU and a NAL with the *same* RTP timestamp then arrives:

* H.265 SUFFIX_SEI (40) or H.264 SEI (6): **discard**, count `.suffixNALAfterClose`. It carries no
  decode-critical data.
* A VCL NAL with `firstSliceFlag == false`: the close was wrong — we split a multi-slice picture.
  Force `sliceProfile = .multiSlice`, `markerTrust = .broken`, discard the already-emitted AU’s
  successor slices, mark the *next* AU corrupt, and request a keyframe. Count
  `.prematureAccessUnitClose`. This is the self-correction path for the DS-7616 early-marker bug.
* Anything else: attach to the new AU (harmless).

---

## 8. AAC depacketization (RFC 3640, `mode=AAC-hbr`)

### 8.1 fmtp parameters

Real Hikvision SDP (DS-2CD2385, 16 kHz mono AAC-LC):

```
m=audio 0 RTP/AVP 98
a=rtpmap:98 mpeg4-generic/16000
a=fmtp:98 streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;
          indexdeltalength=3;config=1408
```

| fmtp key (lower-cased) | Meaning | Default if absent | Our handling |
|---|---|---|---|
| `mode` | `AAC-hbr`, `AAC-lbr`, `generic` | — | required; only `aac-hbr` supported, else `.unsupportedMode` |
| `sizelength` | bits of the AU-size field | **13** | 1…32; > 32 → error |
| `indexlength` | bits of `AU-Index` (first AU) | **3** | |
| `indexdeltalength` | bits of `AU-Index-delta` | **3** | |
| `ctsdeltalength` | bits of CTS delta | **0** | non-zero ⇒ a CTS-flag bit per AU (§8.3) |
| `dtsdeltalength` | bits of DTS delta | **0** | same |
| `randomaccessindication` | 1 bit per AU when `1` | **0** | consumed, exposed as `isKeyframe` |
| `streamstateindication` | bits per AU | **0** | consumed and ignored |
| `auxiliarydatasizelength` | bits | **0** | non-zero ⇒ auxiliary section (§8.2) |
| `constantsize` | fixed AU size | absent | if present, there is **no** size field |
| `config` | hex AudioSpecificConfig | — | required; §8.5 |
| `profile-level-id`, `streamtype`, `objecttype` | MPEG-4 signalling | — | ignored |

Parsing note: fmtp values must be trimmed of spaces and CRLF, and `config` may be split across
folded SDP lines by some NVRs — `VigilRTSP` joins them before handing over.

### 8.2 Payload structure

```
+--------------------------------------------------------------+
| AU-headers-length (16 bit BE) — length in BITS, not bytes     |
+--------------------------------------------------------------+
| AU-header(1) | AU-header(2) | … | AU-header(n)                |
+--------------------------------------------------------------+
| padding bits to the next byte boundary                        |
+--------------------------------------------------------------+
| [auxiliary-data-size (auxiliarydatasizelength bits) + data +  |
|  padding]  — only when auxiliarydatasizelength > 0            |
+--------------------------------------------------------------+
| AU(1) bytes | AU(2) bytes | … | AU(n) bytes                    |
+--------------------------------------------------------------+
```

* The 16-bit prefix is the AU **header section** length in **bits**. `0` means “no AU headers”
  (only valid when `constantsize` is set). Byte length of the header section is
  `(bits + 7) / 8`, and AU data starts at `2 + thatByteLength` (+ auxiliary section).
* All AU **data** blocks are byte-aligned and concatenated in order; their lengths come from the
  headers. If the sum of sizes does not match the remaining payload, the packet is malformed →
  emit nothing, count `.auSizeMismatch`.

### 8.3 AU header layout (per AU, in the bit stream)

Fields in exactly this order, each present only when its configured length > 0:

| Order | Field | Bits | Present |
|---|---|---|---|
| 1 | `AU-size` | `sizelength` | when `constantsize` absent |
| 2 | `AU-Index` | `indexlength` | **first AU of the packet only** |
| 2′ | `AU-Index-delta` | `indexdeltalength` | **every AU after the first** |
| 3 | `CTS-flag` | 1 | when `ctsdeltalength > 0` |
| 3′ | `CTS-delta` | `ctsdeltalength` | when `CTS-flag == 1` |
| 4 | `DTS-flag` | 1 | when `dtsdeltalength > 0` |
| 4′ | `DTS-delta` | `dtsdeltalength` | when `DTS-flag == 1` |
| 5 | `RAP-flag` | 1 | when `randomaccessindication == 1` |
| 6 | `stream-state` | `streamstateindication` | when > 0 |

For `AAC-hbr` as Hikvision configures it, this collapses to **13 bits of size + 3 bits of
index/delta = 16 bits per AU**, which is why `AU-headers-length` is `n * 16`.

### 8.4 Multi-AU packets and per-AU timestamps

`AU-Index` of the first AU is the AU’s position relative to the RTP timestamp; Hikvision always
sends 0. For subsequent AUs, `AU-Index-delta` gives the gap: `index(i) = index(i-1) + delta + 1`.
Presentation time of AU *i*:

```
pts(i) = rtpTimestamp + index(i) * framesPerPacket        // in clockRate units
```

with `framesPerPacket` = 1024 for AAC-LC (960 when `frameLengthFlag == 1`, 512 for AAC-LD/AOT 23).
`MediaTimestamp(value: extendedRTPTimestamp + Int64(index(i)) * frames, timescale: clockRate)`.
Each AU becomes **one** `EncodedFrame` with `duration = frames / clockRate` and `isKeyframe = true`
(every AAC AU is independently decodable; `RAP-flag`, if present, overrides).

Fragmentation: an AAC AU larger than the MTU is split across packets in `AAC-hbr` mode by sending
the *same* AU-header with the size of the whole AU and letting the receiver concatenate until it
has `AU-size` bytes. In practice Hikvision AAC AUs are ≤ 400 bytes and never fragment. Implement
the concatenation path anyway: keep a pending `(size, bytesSoFar, timestamp)`; if a packet with a
new timestamp arrives while pending, discard the partial AU and count `.truncatedAudioAU`. Multi-AU
and fragmented AU are mutually exclusive within one packet.

### 8.5 `AudioSpecificConfig` from a hex string

`config=1210` → bytes `0x12 0x10` → bits `00010 0100 0001 0000`:

| Field | Bits | Value | Meaning |
|---|---|---|---|
| `audioObjectType` | 5 | `00010` = 2 | AAC-LC |
| `samplingFrequencyIndex` | 4 | `0100` = 4 | 44 100 Hz |
| `channelConfiguration` | 4 | `0001` = 1 | mono |
| `frameLengthFlag` | 1 | 0 | 1024 samples |
| `dependsOnCoreCoder` | 1 | 0 | |
| `extensionFlag` | 1 | 0 | |

`config=1408` → `0x14 0x08` → AOT 2, sfi 8 (16 000 Hz), ch 1 → the Hikvision default.
`config=1588` → `0x15 0x88` → AOT 2, sfi 11 (8 000 Hz), ch 1.

Sampling-frequency index table (RFC 3640 / ISO 14496-3):

| idx | Hz | idx | Hz | idx | Hz |
|---|---|---|---|---|---|
| 0 | 96000 | 5 | 32000 | 10 | 11025 |
| 1 | 88200 | 6 | 24000 | 11 | 8000 |
| 2 | 64000 | 7 | 22050 | 12 | 7350 |
| 3 | 48000 | 8 | 16000 | 13, 14 | reserved → error |
| 4 | 44100 | 9 | 12000 | 15 | escape: next 24 bits are the rate |

```swift
public struct AudioSpecificConfig: Sendable, Hashable {
    public var audioObjectType: Int
    public var samplingFrequency: Int
    public var samplingFrequencyIndex: Int      // 15 when explicit
    public var channelConfiguration: Int
    public var frameLengthSamples: Int          // 1024 / 960 / 512
    public var raw: Data                        // verbatim, for the AudioConverter magic cookie

    public static func parse(_ data: Data) throws(AudioConfigError) -> AudioSpecificConfig
    /// Accepts upper or lower case; rejects odd-length or non-hex input.
    public static func parse(hexConfig: String) throws(AudioConfigError) -> AudioSpecificConfig
}
```

Parsing rules:
* `audioObjectType == 31` → escape: read 6 more bits, `AOT = 32 + those`.
* `samplingFrequencyIndex == 15` → read 24 bits as the explicit rate.
* `AOT == 5` (SBR) or `29` (PS): read `extensionSamplingFrequencyIndex` (4 bits, escape as above)
  then the real `AOT` (5 bits). The **RTP clock rate stays the core rate from `a=rtpmap`** — do not
  substitute the extension rate, or every timestamp doubles.
* `channelConfiguration == 0` means a Program Config Element follows; we do not parse PCE.
  Fall back to the channel count from `a=rtpmap:<pt> mpeg4-generic/<rate>/<channels>`; if that is
  also absent, default to 1 and emit `.assumedMonoFromPCE`.
* `frameLengthFlag` is bit 0 of GASpecificConfig for AOT 1, 2, 3, 4, 6, 7, 17, 19, 20, 21, 22, 23.
  AOT 23 (AAC-LD) → 512 samples; else `flag ? 960 : 1024`.
* Odd-length hex, non-hex characters, or fewer than 2 bytes → `.malformedConfig`.

### 8.6 What we emit, and ADTS

`EncodedFrame` for AAC carries **raw AAC AU bytes** (`data`), `codec == .aac`,
`parameterSets.sps[0] == asc.raw` on the first frame and whenever the config changes, and
`audioFormat = AudioFormatDescription(sampleRate:channels:framesPerPacket:)`.

**Decision:** the decode path on macOS uses `AudioConverterNew` with
`kAudioConverterDecompressionMagicCookie` set from `asc.raw`, so **ADTS is not used at runtime**.
We still ship an ADTS builder because (a) the recorder writes `.aac`/MPEG-TS sidecar files, (b) it
makes test vectors trivially checkable with `ffprobe`, and (c) some diagnostics dump raw streams.

7-byte ADTS header (`protection_absent = 1`, no CRC):

| Bits | Field | Value |
|---|---|---|
| 12 | `syncword` | `0xFFF` |
| 1 | `ID` | 0 (MPEG-4) |
| 2 | `layer` | 0 |
| 1 | `protection_absent` | 1 |
| 2 | `profile` | `audioObjectType - 1` (AAC-LC → 1) |
| 4 | `sampling_frequency_index` | from ASC |
| 1 | `private_bit` | 0 |
| 3 | `channel_configuration` | from ASC |
| 1 | `original_copy` | 0 |
| 1 | `home` | 0 |
| 1 | `copyright_id_bit` | 0 |
| 1 | `copyright_id_start` | 0 |
| 13 | `aac_frame_length` | `7 + auByteCount` |
| 11 | `adts_buffer_fullness` | `0x7FF` (VBR) |
| 2 | `number_of_raw_data_blocks_in_frame` | 0 (⇒ 1 block) |

```swift
public enum ADTS {
    public static func header(auByteCount: Int, config: AudioSpecificConfig) -> [UInt8] {
        let len = auByteCount + 7
        let profile = UInt8(max(1, config.audioObjectType - 1)) & 0x03
        let sfi = UInt8(config.samplingFrequencyIndex) & 0x0F
        let ch = UInt8(config.channelConfiguration) & 0x07
        return [
            0xFF, 0xF1,
            (profile << 6) | (sfi << 2) | (ch >> 2),
            ((ch & 0x03) << 6) | UInt8(truncatingIfNeeded: len >> 11),
            UInt8(truncatingIfNeeded: (len >> 3) & 0xFF),
            (UInt8(truncatingIfNeeded: (len & 0x07)) << 5) | 0x1F,
            0xFC,
        ]
    }
}
```
(`0xFF, 0xF1` = syncword + MPEG-4 + layer 0 + protection_absent 1. The trailing `0x1F, 0xFC` encode
buffer fullness `0x7FF` and 0 raw blocks.)

### 8.7 Case-insensitivity

`mpeg4-generic` is registered lower-case but appears as `MPEG4-GENERIC` in Hikvision SDP and as
`MPEG4-generic` on at least one NVR build. Likewise `mode=AAC-hbr` appears as `AAC-HBR` and
`aac-hbr`, and fmtp keys appear as `sizeLength`/`SizeLength`/`sizelength`.

**Rule:** every SDP token comparison in Vigil uses ASCII case-insensitive comparison. `VigilRTSP`
lower-cases fmtp **keys** on the way out; `VigilRTP` lower-cases **values** at the point of
comparison (`format.fmtp["mode"]?.lowercased() == "aac-hbr"`). Use
`String.compare(_:options:.caseInsensitive)` or `lowercased()`, never `localizedLowercase`
(locale-dependent: the Turkish dotless-ı problem would break `"MPEG4-GENERIC"`).

---

## 9. G.711 PCMA / PCMU and G.726

### 9.1 Payload framing

| Encoding | PT | Clock | Payload |
|---|---|---|---|
| PCMU (μ-law) | **0** (static) | 8000 | one byte per sample, no header, no fragmentation |
| PCMA (A-law) | **8** (static) | 8000 | same |
| G726-32 | dynamic (Hikvision uses 96–99) | 8000 | 4-bit codewords, 2 per byte, MSB-first |
| AAL2-G726-32 | dynamic | 8000 | same codewords, **little-endian** packing within the byte |

Every G.711 packet is a complete, independently decodable buffer: `frames = payload.count`,
`pts = extendedTimestamp`, `duration = frames / 8000`. Hikvision sends 160 samples (20 ms), 320
(40 ms) or 400 (50 ms) per packet. The marker bit is typically 0 always and is ignored entirely
(there are no access units to delimit). Talk-back streams set `M` on the first packet after
silence — we ignore that too.

`PCMDepacketizer` outputs `codec == .pcmS16LE` with `data` = interleaved signed 16-bit
little-endian samples, so `VigilVideo` can hand the buffer to an `AVAudioSourceNode` with an
`AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true)`
without any further conversion. **Cross-cutting: `VigilVideo` must not expect compressed G.711.**

### 9.2 μ-law ⇄ linear (ITU-T G.711)

μ-law is a sign/exponent/mantissa format stored **inverted** on the wire, with a bias of 132
(`0x84`) and a peak magnitude of 32124.

```swift
public enum G711 {
    @inlinable public static func muLawToLinear(_ byte: UInt8) -> Int16 {
        let u = ~byte
        let exponent = Int((u >> 4) & 0x07)
        let mantissa = Int(u & 0x0F)
        var sample = ((mantissa << 3) + 0x84) << exponent
        sample -= 0x84
        return (u & 0x80) != 0 ? Int16(-sample) : Int16(sample)
    }

    @inlinable public static func linearToMuLaw(_ pcm: Int16) -> UInt8 {
        let clip = 32635, bias = 0x84
        var magnitude = Int(pcm)
        let sign: UInt8 = magnitude < 0 ? 0x80 : 0x00
        if magnitude < 0 { magnitude = -magnitude }
        magnitude = min(magnitude, clip) + bias
        // exponent = position of the highest set bit above bit 7
        let exponent = 7 - min(7, (magnitude >> 7).leadingZeroBitCount - 24)
        let mantissa = (magnitude >> (exponent + 3)) & 0x0F
        return ~(sign | UInt8(exponent << 4) | UInt8(mantissa))
    }
}
```

Sanity checks the unit test must assert: `muLawToLinear(0xFF) == 0`,
`muLawToLinear(0x7F) == -0` → the negative zero encoding maps to `0`,
`muLawToLinear(0x00) == -32124`, `muLawToLinear(0x80) == 32124`,
and `linearToMuLaw(muLawToLinear(x)) == x` for all 256 `x` (round-trip identity holds for μ-law).
The exponent expression is fiddly; if `leadingZeroBitCount` arithmetic is unclear, implement it as
the classic 8-entry segment lookup — but keep the round-trip test either way.

### 9.3 A-law ⇄ linear (ITU-T G.711)

A-law XORs the wire byte with `0x55`, has no bias, and a peak magnitude of 32256.

```swift
@inlinable public static func aLawToLinear(_ byte: UInt8) -> Int16 {
    let a = byte ^ 0x55
    let exponent = Int((a >> 4) & 0x07)
    let mantissa = Int(a & 0x0F)
    let magnitude = exponent == 0 ? (mantissa << 4) + 8
                                  : ((mantissa << 4) + 0x108) << (exponent - 1)
    return (a & 0x80) != 0 ? Int16(-magnitude) : Int16(magnitude)
}

@inlinable public static func linearToALaw(_ pcm: Int16) -> UInt8 {
    let clip = 32635
    var magnitude = Int(pcm)
    let sign: UInt8 = magnitude >= 0 ? 0x80 : 0x00      // note: A-law sign is INVERTED vs μ-law
    if magnitude < 0 { magnitude = -magnitude - 1 }
    magnitude = min(magnitude, clip)
    var byte: UInt8
    if magnitude < 256 {
        byte = UInt8(magnitude >> 4)
    } else {
        let exponent = 7 - min(7, (magnitude >> 8).leadingZeroBitCount - 24)
        byte = UInt8((exponent << 4) | ((magnitude >> (exponent + 3)) & 0x0F))
    }
    return (byte | sign) ^ 0x55
}
```

**Performance decision:** both decoders are driven through a **256-entry `[Int16]` lookup table**
built once as a `static let` (`G711.muLawTable`, `G711.aLawTable`) — 512 bytes each, resident in L1.
The closed-form functions above are the *specification* and the table generator; the hot loop is:

```swift
let table = isALaw ? G711.aLawTable : G711.muLawTable
var out = Data(count: payload.count * 2)
out.withUnsafeMutableBytes { raw in
    let dst = raw.bindMemory(to: Int16.self)
    let src = Bytes(payload)
    for i in 0..<src.count { dst[i] = table[Int(src[i])].littleEndian }
}
```
Encoding for talk-back uses an 8192-entry table indexed by `(sample >> 2) & 0x1FFF`? **No** — use
the closed-form encoder; talk-back is 8 kHz mono, 8000 calls/second, immeasurable.

### 9.4 G.726-32 (Hikvision two-way audio)

Hikvision’s two-way audio channel advertises `G.711ulaw`, `G.711alaw`, and `G.726` in
`/ISAPI/System/TwoWayAudio/channels`. Where G.726 appears it is always **32 kbit/s, 4 bits per
sample, 8 kHz** (`G726-32` in RFC 3551 terms).

**Packing.** RFC 3551 §4.5.4 packs codewords into octets starting from the **most significant**
bits: sample 0 in bits 7…4, sample 1 in bits 3…0. The `AAL2-G726-32` encoding name (RFC 3551 §4.5.6)
uses the opposite in-octet order. Support both, selected by `encodingName`:

```swift
@inlinable func codeword(_ b: UInt8, index i: Int, aal2: Bool) -> UInt8 {
    let hiFirst = !aal2
    return (i % 2 == 0) == hiFirst ? (b >> 4) & 0x0F : b & 0x0F
}
```

**Algorithm.** G.726 is ADPCM with an adaptive quantizer and a 2-pole/6-zero adaptive predictor.
State per direction:

```swift
public struct G726State: Sendable {
    var yl: Int32 = 34816            // slow quantizer scale factor (Q12 << 6)
    var yu: Int32 = 544              // fast quantizer scale factor
    var dms: Int32 = 0, dml: Int32 = 0, ap: Int32 = 0
    var a = (Int32(0), Int32(0))                     // 2 pole coefficients
    var b = (Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(0))
    var pk = (Int32(0), Int32(0))
    var dq = [Int32](repeating: 32, count: 6)
    var sr = (Int32(32), Int32(32))
    var td = false
}
```

Per-sample decode steps (ITU-T G.726 §4, transcoded to the well-known CCITT/Sun reference form):

1. `predictor_zero()` + `predictor_pole()` → signal estimate `se`, partial `sez`.
2. Reconstruct: `dq = reconstruct(sign: i & 0x08, dqln: _dqlntab[i], y: y)` where
   `y = step_size(state)` blends `yl`/`yu` through `ap`.
3. `sr = se + dq` (the linear output, then scaled to 14-bit and shifted to Int16).
4. `update(codeSize: 4, y: y, wi: _witab[i] << 5, fi: _fitab[i], dq: dq, sr: sr, dqsez: dqsez)`
   adapts `yl`, `yu`, `dms`, `dml`, `ap`, `a`, `b`, `pk`, and the tone/transition detector `td`.

The three tables required for the 32 kbit/s rate (4-bit) — these are the ITU reference values as
carried in the CCITT/Sun `g726_32.c`:

```swift
let qtab32:  [Int32] = [-124, 80, 178, 246, 300, 349, 400]
let dqlntab: [Int32] = [-2048, 4, 135, 213, 273, 323, 373, 425,
                          425, 373, 323, 273, 213, 135, 4, -2048]
let witab:   [Int32] = [-12, 18, 41, 64, 112, 198, 355, 1122,
                        1122, 355, 198, 112, 64, 41, 18, -12]
let fitab:   [Int32] = [0, 0, 0, 0x200, 0x200, 0x200, 0x600, 0xE00,
                        0xE00, 0x600, 0x200, 0x200, 0x200, 0, 0, 0]
```

**Validation is mandatory:** the implementation must reproduce the ITU-T G.726 conformance
sequences byte-for-byte. Check the reference vectors into
`Tests/VigilRTPTests/Fixtures/g726/` (`nrm.rc`, `ovr.rc`, `rn32fa.o` …) and assert exact equality;
an ADPCM predictor that is 99% right sounds like distortion and is unfixable by ear.

**Scope decision:** G.726 is **decode-only in v1** (incoming talk-back monitoring and the rare NVR
that only offers G.726 audio). Outgoing talk-back always negotiates G.711 μ-law via
`/ISAPI/System/TwoWayAudio/channels/1/open` with `<audioCompressionType>G.711ulaw</>`. Implement
`G726Encoder` behind the same state struct only if the ITU vectors pass; otherwise ship the decoder
and have `VigilCore` refuse a G.726-only talk-back channel with a clear error.

**No RTP packetizer is needed for talk-back:** Hikvision two-way audio is an HTTP chunked `PUT` of
a raw codec stream to `/ISAPI/System/TwoWayAudio/channels/{id}/audioData`, not RTP. The encoders
live in `VigilRTP` because they are pure DSP and Linux-testable; `VigilVideo` calls them.

---

## 10. Reorder / jitter buffer

### 10.1 Wraparound-safe sequence comparison

```swift
/// True when `a` precedes `b` in modulo-2^16 sequence space.
@inlinable public func seqLess(_ a: UInt16, _ b: UInt16) -> Bool {
    Int16(bitPattern: a &- b) < 0
}
/// Signed distance a - b, correct across the wrap. Range ±32768.
@inlinable public func seqDiff(_ a: UInt16, _ b: UInt16) -> Int32 {
    Int32(Int16(bitPattern: a &- b))
}
```

| a | b | `a &- b` | `Int16(bitPattern:)` | `seqLess` |
|---|---|---|---|---|
| 0 | 1 | 0xFFFF | −1 | true |
| 65535 | 0 | 0xFFFF | −1 | true |
| 0 | 65535 | 0x0001 | 1 | false |
| 5 | 5 | 0x0000 | 0 | false |
| 0 | 0x8000 | 0x8000 | −32768 | true (ambiguous half-space; documented) |

Never compare sequence numbers with `<`. Never use `Int(a) - Int(b)`. A repo-wide lint rule should
flag `sequenceNumber <` and `sequenceNumber >`.

### 10.2 Structure

```swift
public struct ReorderBuffer: Sendable {
    public struct Policy: Sendable {
        public var maxPackets: Int            // ring capacity, power of two
        public var maxDelayMilliseconds: Double
        public var mode: Mode
        public enum Mode: Sendable { case passthrough, reorder, adaptiveLowLatency }

        public static let tcpInterleaved = Policy(maxPackets: 0,  maxDelayMilliseconds: 0,   mode: .passthrough)
        public static let udpLive        = Policy(maxPackets: 128, maxDelayMilliseconds: 60,  mode: .adaptiveLowLatency)
        public static let udpLossy      = Policy(maxPackets: 512, maxDelayMilliseconds: 200, mode: .reorder)
        public static let udpPlayback   = Policy(maxPackets: 512, maxDelayMilliseconds: 400, mode: .reorder)
    }

    public init(policy: Policy)
    /// Returns packets ready for depacketization, in strict sequence order, plus gap reports.
    public mutating func push(_ packet: RTPPacket) -> Output
    /// Time-driven release; call from RTPTrackReceiver.tick.
    public mutating func drain(now: MonotonicTime, force: Bool = false) -> Output
    public mutating func reset()
    public var depth: Int { get }                      // packets currently held
    public var bufferedMilliseconds: Double { get }    // now - oldest.receivedAt
    public var nextDeadline: MonotonicTime? { get }

    public struct Output: Sendable {
        public var packets: [RTPPacket] = []
        public var gaps: [ClosedRange<UInt16>] = []     // sequence numbers definitively lost
        public var late = 0, duplicates = 0, reordered = 0
    }
}
```

Storage is a fixed `[RTPPacket?]` of `maxPackets` (power of two, mask = capacity − 1), indexed by
`Int(seq) & mask`, plus `baseSeq: UInt16?` = the next sequence number to release, and `held: Int`.

### 10.3 Insertion algorithm

```
on push(p):
  if policy.mode == .passthrough            → return Output(packets: [p])   // TCP: order guaranteed
  if baseSeq == nil { baseSeq = p.seq }                                     // first packet
  d = seqDiff(p.seq, baseSeq!)
  if d < 0                                  → late += 1; drop; return       // too old, already released
  if d >= capacity                          → forced flush: release everything contiguous,
                                              report the gap, set baseSeq = p.seq, then insert
  if slot[p.seq & mask] != nil               → duplicates += 1; drop; return
  slot[p.seq & mask] = p; held += 1
  if d > 0 { reordered += 1 }               // arrived out of order (a hole exists below it)
  releaseContiguous()                        // pop while slot[baseSeq] != nil
  if held > 0 and bufferedMilliseconds > maxDelayMilliseconds → releaseWithGap()
```

`releaseContiguous()` pops `slot[baseSeq & mask]` while non-nil, incrementing `baseSeq` with `&+ 1`.
`releaseWithGap()` finds the lowest occupied slot above `baseSeq`, reports
`baseSeq ... (thatSeq &- 1)` as a gap, sets `baseSeq` to `thatSeq`, and then releases contiguously.

`drain(now:force:)` applies the same delay rule on a timer so a stream that stops mid-gap still
flushes; `force: true` (used on TEARDOWN/PAUSE) releases everything and reports all holes.

### 10.4 Depth in both packets *and* milliseconds

Both bounds are enforced independently and the tighter one wins:

| Policy | packets | ms | typical use |
|---|---|---|---|
| `.tcpInterleaved` | 0 | 0 | RTSP interleaved (default transport) — the TCP stream is already ordered |
| `.udpLive` | 128 | 60 | UDP unicast live view; 60 ms ≈ 1.5 frames at 25 fps |
| `.udpLossy` | 512 | 200 | auto-selected after loss > 1% over 10 s (§10.5) |
| `.udpPlayback` | 512 | 400 | recorded playback, where latency does not matter |

512 packets × ~1450 B ≈ 740 kB worst case per stream; at 16 streams that is 11.8 MB — acceptable.
`maxPackets` must be a power of two; `Policy.init` rounds up and asserts ≤ 4096.

### 10.5 `adaptiveLowLatency` — the fast path

While packets arrive strictly in order, buffering adds pure latency for nothing. So:

* State `.streaming`: if `p.seq == baseSeq`, release it immediately without touching the ring
  (zero added latency, zero bookkeeping beyond stats).
* First out-of-order or duplicate packet → switch to `.buffering` with the policy’s bounds.
* After **256 consecutive in-order packets** in `.buffering` with no gaps, return to `.streaming`.
* If loss exceeds **1%** over a 10 s window, escalate the policy to `.udpLossy` (200 ms) and emit
  `.jitterPolicyEscalated`. De-escalate after 60 s below 0.1%.

Over TCP interleaved this whole subsystem is inert: mode is `.passthrough`, and a sequence
discontinuity there means the *camera* dropped packets (or our `$`-framing desynced, which
`VigilRTSP` reports separately) — so it still counts loss and still fires `onGap`.

### 10.6 Gaps and the keyframe request

```swift
public struct GapPolicy: Sendable {
    /// Called for every definitively lost sequence range. Optional push-style hook.
    public var onGap: (@Sendable (ClosedRange<UInt16>) -> Void)?
    public var requestKeyframeOnGap = true
    public var minimumKeyframeRequestInterval: Double = 2.0     // seconds, per stream
}
```

The **primary** mechanism is the event stream: `ReorderBuffer.Output.gaps` → `RTPTrackReceiver`
converts each gap into `.packetLoss(range:count:)` and, when a gap intersects an in-progress AU or
`waitForKeyframeAfterLoss` is set, `.keyframeNeeded(reason:)`. The `onGap` closure exists for
callers who prefer push semantics; because it makes the containing struct non-`Sendable`-by-default
it is stored in a separate `GapPolicy` value that the receiver holds as
`let` and only the reference pipeline leaves `nil`.

`VigilCore` services `.keyframeNeeded` in this order, rate-limited to one attempt per 2 s:

1. **ISAPI** `PUT /ISAPI/Streaming/channels/{id}/requestKeyFrame` with an empty
   `<KeyFrameRequest/>` body — the only mechanism Hikvision reliably honours.
   **Cross-cutting: `VigilISAPI` must expose `requestKeyFrame(channelID:)`.**
2. RTCP PSFB **FIR** (PT 206, FMT 4) on the RTCP channel — cheap, usually ignored; send anyway.
3. After 3 failed attempts or 6 s without an IRAP, `VigilCore` tears down and re-`PLAY`s the
   session (a fresh `PLAY` always produces an IDR).

While waiting, the depacketizer’s keyframe gate discards non-IRAP AUs so the decoder never sees a
reference-missing picture.

---

## 11. Timestamp math and the presentation clock

### 11.1 The clocks

| Stream | RTP clock rate | `MediaTimestamp.timescale` |
|---|---|---|
| H.264 / H.265 | **90 000** (always, per RFC 6184/7798) | 90 000 |
| AAC | the core sample rate from `a=rtpmap` (8000/16000/44100/48000) | same |
| PCMA / PCMU / G726-32 | 8 000 | 8 000 |

Never hard-code 90 000 in the depacketizers — take `clockRate` from `RTPTrackFormat`. Do assert it
is 90 000 for video and emit `.unexpectedClockRate` otherwise (some NVR SDPs say 90000 for audio
tracks by mistake; in that case prefer the sample rate from the AAC config and log).

### 11.2 32-bit wraparound

A 90 kHz timestamp wraps every `2^32 / 90000 = 47 721.858 s ≈ 13 h 15 m 22 s`. A camera left
running overnight *will* wrap. Unwrap into a monotone `Int64`:

```swift
public struct TimestampUnwrapper: Sendable {
    private var cycles: Int64 = 0
    private var last: UInt32?
    private var origin: Int64?

    /// Returns the extended timestamp, rebased so the first packet is 0.
    public mutating func extend(_ ts: UInt32) -> Int64 {
        if let l = last {
            let delta = Int32(bitPattern: ts &- l)        // signed 32-bit distance
            if ts < l && delta > 0 { cycles += 1 }        // forward wrap
            if ts > l && delta < 0 { cycles -= 1 }        // backward wrap (reordered across it)
            // only advance `last` forward, so a reordered packet does not un-wrap us
            if delta > 0 { last = ts }
        } else {
            last = ts
        }
        let extended = cycles << 32 | Int64(ts)
        if origin == nil { origin = extended }
        return extended - origin!
    }
    public mutating func reset() { cycles = 0; last = nil; origin = nil }
}
```

`Int32(bitPattern: ts &- l)` gives the correct signed distance for gaps up to ±2^31 (±6.6 h at
90 kHz), which is far beyond any real reorder or discontinuity. The `if delta > 0` guard on `last`
is essential: without it, a single reordered packet flips `cycles` twice and throws PTS by 13 hours.

Rebasing to `origin` keeps PTS values small (`Int64` at 90 kHz overflows after 3.2 million years
regardless, but small values keep the `MediaTimestamp` rescale math exact and make logs readable).
A **discontinuity** (`|delta| > 90_000 * 10`, i.e. > 10 s) is not a wrap: emit
`.timestampDiscontinuity(seconds:)`, keep the extended value (so playback seeks work), and let
`PresentationClock` hard-reset (§11.4).

### 11.3 RTCP SR: NTP → RTP → wall clock

An SR gives a simultaneous reading of the sender’s NTP clock and its RTP clock:

```
ntp64  = UInt64(ntpMSW) << 32 | UInt64(ntpLSW)          // seconds.fraction since 1900-01-01
unix   = Double(ntpMSW) - 2_208_988_800 + Double(ntpLSW) / 4_294_967_296
```

`2_208_988_800` is the seconds between the NTP epoch (1900-01-01) and the Unix epoch (1970-01-01).

Wall-clock time of any RTP timestamp:

```swift
public struct RTPWallClockMapping: Sendable {
    public var referenceRTP: UInt32
    public var referenceUnixSeconds: Double
    public var clockRate: Int32
    public func unixTime(forRTP ts: UInt32) -> Double {
        referenceUnixSeconds + Double(Int32(bitPattern: ts &- referenceRTP)) / Double(clockRate)
    }
}
```

Rules:
* Keep the mapping from the **most recent** SR. Cameras’ NTP clocks jump when they sync, so
  smoothing across SRs is wrong; take the newest and note the jump.
* Hikvision cameras with NTP disabled report an NTP time near 1970 or near their boot time. Detect
  `unix < 1_000_000_000` (before 2001-09-09) and mark the mapping `isPlausible = false`. In that
  case OSD/recording timestamps come from ISAPI `/ISAPI/System/time`, not from RTCP.
* This mapping is used for (a) the OSD wall clock, (b) recording file naming and MP4 creation time,
  (c) cross-camera synchronization in the video wall. It is **not** used for live pacing.
* When two tracks (audio + video) of one session both have SR mappings, A/V sync uses
  `unixTime(forRTP:)` on both. Without SRs there is no valid cross-track sync; in that case audio is
  played on arrival and video is displayed immediately, and we accept up to ~100 ms of skew (this is
  what every RTSP client does for Hikvision live streams).

### 11.4 The drift-correcting presentation clock

The camera’s 90 kHz clock and the Mac’s clock differ by tens to hundreds of ppm. Over an hour, an
uncorrected mapping drifts by hundreds of milliseconds, which shows up as a slowly growing latency
that ends in a buffer flush and a visible hiccup.

Model: `hostSeconds ≈ offset + rate * mediaSeconds`, estimated with a **min-filter followed by a
first-order PLL** (a plain EWMA is wrong here — arrival times are asymmetrically delayed by network
and OS queueing, so the *minimum* observed offset is the unbiased estimator of the true offset, and
the EWMA of a right-skewed distribution drifts upward).

```swift
public struct PresentationClock: Sendable {
    public private(set) var offsetSeconds: Double = 0     // host = offset + rate * media
    public private(set) var rateRatio: Double = 1.0
    public private(set) var isLocked = false

    public struct Tuning: Sendable {
        public var minFilterWindow: Double = 2.0      // seconds of history for the min filter
        public var proportionalGain = 0.05            // Kp  → ~0.8 s time constant at 25 fps
        public var integralGain = 0.0008              // Ki  → ~50 s time constant
        public var maxRateDeviation = 0.005           // ±5000 ppm clamp
        public var resetThreshold = 0.5               // seconds of step error ⇒ hard reset
        public var lockAfterSamples = 50              // 2 s at 25 fps
        public static let live = Tuning()
        public static let playback = Tuning(minFilterWindow: 5.0, proportionalGain: 0.02,
                                           integralGain: 0.0002, maxRateDeviation: 0.02,
                                           resetThreshold: 1.0, lockAfterSamples: 100)
    }

    public mutating func observe(mediaSeconds: Double, hostTime: MonotonicTime)
    public func hostTime(forMedia mediaSeconds: Double) -> MonotonicTime
    public func mediaSeconds(forHost hostTime: MonotonicTime) -> Double
    /// Instantaneous end-to-end delay estimate: how long ago this frame was captured.
    public func latencySeconds(forMedia mediaSeconds: Double, now: MonotonicTime) -> Double
    public mutating func reset()
}
```

`observe` per frame:

```
raw   = hostTime.seconds - mediaSeconds
push (hostTime, raw) into a deque; pop entries older than minFilterWindow
m     = min(raw over the window)                       // unbiased offset estimate
pred  = offsetSeconds + (rateRatio - 1) * mediaSeconds
err   = m - pred
if |err| > resetThreshold { reset(); offsetSeconds = m; return }
offsetSeconds += proportionalGain * err
rateRatio     += integralGain * err / max(mediaSeconds - lastMediaSeconds, 1e-3)
rateRatio      = min(max(rateRatio, 1 - maxRateDeviation), 1 + maxRateDeviation)
samples += 1;  isLocked = samples >= lockAfterSamples
```

Where the clock is and is not used:

| Use | Uses the clock? |
|---|---|
| Live display pacing | **No** — VigilVideo displays on decode (`DisplayImmediately`) |
| Latency readout in the stats HUD | Yes (`latencySeconds`) |
| Audio/video sync when audio is enabled | Yes, via §11.3 plus this clock |
| Recorded playback timebase | Yes, with `Tuning.playback` |
| Deciding to drop to keyframe when behind | Yes — `latencySeconds > 0.4` for 1 s is one of
  VigilVideo’s drop triggers |

A hard reset is triggered by: SSRC change, `.timestampDiscontinuity`, RTSP PAUSE/PLAY, seek, or a
step error above `resetThreshold`.

---

## 12. RTCP

### 12.1 Transport

| Transport | RTP | RTCP |
|---|---|---|
| RTSP interleaved (default) | `$` channel 0 (track 1), 2 (track 2), … | **`$` channel 1** (track 1), 3 (track 2), … |
| UDP unicast | negotiated even port *N* | port *N+1*, symmetric (we send from *N+1* too) |

**Interleaved channel 1 carries RTCP.** `VigilRTSP` owns the `$`-framing (magic `0x24`, 1-byte
channel, 16-bit BE length) and the channel↔track map from the `Transport:` response header;
`VigilRTP` only produces and consumes the RTCP **payload bytes**. `RTPTrackReceiver` returns
outbound RTCP as `[Data]` and the transport wraps each in framing on the correct channel.

### 12.2 Common header (all RTCP packet types)

| Byte | Mask | Field |
|---|---|---|
| 0 | `0xC0 >> 6` | version, must be 2 |
| 0 | `0x20` | padding `P` |
| 0 | `0x1F` | item count: `RC` (report count) for SR/RR, `SC` (source count) for SDES/BYE, `FMT` for feedback |
| 1 | — | packet type: 200 SR, 201 RR, 202 SDES, 203 BYE, 204 APP, 205 RTPFB, 206 PSFB, 207 XR |
| 2–3 | BE `UInt16` | **length in 32-bit words minus one** ⇒ byte length = `(length + 1) * 4` |

A compound RTCP packet is a concatenation of these; parse until the buffer is exhausted. Rules:
* Total length must be a multiple of 4; if not, parse what fits and count `.rtcpMisaligned`.
* A sub-packet whose declared length overruns the buffer stops parsing (no throw).
* Unknown packet types are skipped by their length — never fatal.
* Only the **last** sub-packet may have `P == 1`.

### 12.3 Sender Report (PT 200)

| Offset (from body start) | Size | Field |
|---|---|---|
| 0 | 4 | sender SSRC |
| 4 | 4 | NTP timestamp, most significant word |
| 8 | 4 | NTP timestamp, least significant word |
| 12 | 4 | RTP timestamp (same clock as the media) |
| 16 | 4 | sender's packet count |
| 20 | 4 | sender's octet count |
| 24 + 24·*i* | 24 | report block *i* (`RC` of them) |

Report block (24 bytes) — identical in SR and RR:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | SSRC of the source being reported on |
| 4 | 1 | fraction lost (8-bit fixed point, `lost/expected * 256`) |
| 5 | 3 | cumulative packets lost (24-bit **signed**) |
| 8 | 4 | extended highest sequence number received |
| 12 | 4 | interarrival jitter (RTP timestamp units) |
| 16 | 4 | LSR — middle 32 bits of the NTP timestamp of the last SR received |
| 20 | 4 | DLSR — delay since last SR, units of 1/65536 s |

```swift
public struct SenderReport: Sendable, Hashable {
    public var ssrc: UInt32
    public var ntpMSW: UInt32, ntpLSW: UInt32
    public var rtpTimestamp: UInt32
    public var packetCount: UInt32, octetCount: UInt32
    public var reports: [ReceptionReportBlock]
    public var unixSeconds: Double { Double(ntpMSW) - 2_208_988_800 + Double(ntpLSW) / 4_294_967_296 }
    /// Middle 32 bits, i.e. what a report block's LSR field must contain.
    public var compactNTP: UInt32 { (ntpMSW << 16) | (ntpLSW >> 16) }
}
```

`RTPTrackReceiver` reacts to an SR by (a) updating `RTPWallClockMapping`, (b) storing
`compactNTP` and its arrival time for DLSR, (c) emitting `.senderReport(SenderReport)`.

### 12.4 Receiver Report (PT 201), SDES (202), BYE (203)

* **RR** body: 4-byte reporter SSRC followed by `RC` report blocks. `RC == 0` (an empty RR) is legal
  and is what a receiver sends before it has any source — we never need it since we always have one.
* **SDES** body: `SC` chunks. Each chunk = 4-byte SSRC, then items `type(1), length(1), text(length)`
  until a `0x00` type byte, then null padding to the next 32-bit boundary. Item types: 1 CNAME,
  2 NAME, 3 EMAIL, 4 PHONE, 5 LOC, 6 TOOL, 7 NOTE, 8 PRIV. We keep CNAME and TOOL (Hikvision sends
  `TOOL: Hikvision` on some models — useful for the device-info panel) and ignore the rest. Text is
  UTF-8; on invalid UTF-8 fall back to Latin-1 rather than dropping the chunk.
* **BYE** body: `SC` SSRCs, then optionally a length-prefixed reason string. On BYE for our source’s
  SSRC: emit `.bye(reason:)`, flush the depacketizer, and let `VigilCore` decide (for live streams
  a BYE means the camera is closing the stream ⇒ reconnect; for playback it means end-of-file ⇒
  stop). This is the *only* reliable end-of-playback signal for Hikvision `Streaming/tracks` URLs.

### 12.5 Source state (RFC 3550 A.1) — required for correct reports

```swift
public struct RTPSourceState: Sendable {
    public static let seqMod: UInt32 = 1 << 16
    static let maxDropout: UInt32 = 3000
    static let maxMisorder: UInt32 = 100
    static let minSequential: UInt32 = 2

    var maxSeq: UInt16 = 0
    var cycles: UInt32 = 0            // shifted left 16
    var baseSeq: UInt32 = 0
    var badSeq: UInt32 = seqMod + 1   // "impossible" value
    var probation: UInt32 = minSequential
    var received: UInt32 = 0
    var expectedPrior: UInt32 = 0
    var receivedPrior: UInt32 = 0
    var transit: Int32 = 0
    var jitter: UInt32 = 0            // stored scaled by 16
    var ssrc: UInt32 = 0

    var extendedMax: UInt32 { cycles + UInt32(maxSeq) }
    var expected: UInt32 { extendedMax - baseSeq + 1 }
    var lost: Int32 { Int32(bitPattern: expected) - Int32(bitPattern: received) }

    mutating func initSeq(_ seq: UInt16)
    /// Returns false while the source is in probation (packet not yet counted as valid).
    mutating func updateSeq(_ seq: UInt16) -> Bool
    mutating func updateJitter(rtpTimestamp: UInt32, arrivalRTP: UInt32)
}
```

`updateSeq` implements A.1 verbatim: in probation, require `minSequential` consecutive packets;
otherwise accept `udelta < maxDropout` as in-order (bumping `cycles` on wrap), treat
`udelta <= seqMod - maxMisorder` as a large jump (restart via `badSeq` matching), and count the rest
as duplicate/reordered. Do not invent a simplification — the RR fields are only correct with this
exact algorithm, and Hikvision NVRs do produce sequence restarts on channel switch.

### 12.6 Interarrival jitter (RFC 3550 §6.4.1 / A.8)

For packets *i* and *j*, with `S` = RTP timestamp and `R` = arrival time **expressed in the same
RTP clock units**:

```
D(i,j) = (Rj - Sj) - (Ri - Si) = (Rj - Ri) - (Sj - Si)
J(i)   = J(i-1) + ( |D(i-1,i)| - J(i-1) ) / 16
```

Stored scaled by 16 so the divide is a shift and no precision is lost:

```swift
mutating func updateJitter(rtpTimestamp: UInt32, arrivalRTP: UInt32) {
    let t = Int32(bitPattern: arrivalRTP &- rtpTimestamp)
    let d = abs(t - transit)
    transit = t
    jitter = UInt32(Int32(bitPattern: jitter) + d - ((Int32(bitPattern: jitter) + 8) >> 4))
}
public var jitterMilliseconds: Double { Double(jitter >> 4) * 1000 / Double(clockRate) }
```

Converting arrival time to RTP units:

```swift
let arrivalRTP = UInt32(truncatingIfNeeded:
    Int64((Double(now.nanoseconds) * Double(clockRate) / 1e9).rounded()))
```

Truncating to 32 bits is correct and intended — only differences matter, and `&-` handles the wrap.

### 12.7 Fraction lost and cumulative lost

```swift
func makeReportBlock(now: MonotonicTime) -> ReceptionReportBlock {
    let expected = source.expected
    let expectedInterval = expected &- source.expectedPrior
    let receivedInterval = source.received &- source.receivedPrior
    source.expectedPrior = expected
    source.receivedPrior = source.received
    let lostInterval = Int32(bitPattern: expectedInterval) - Int32(bitPattern: receivedInterval)
    let fraction: UInt8 = (expectedInterval == 0 || lostInterval <= 0)
        ? 0 : UInt8((lostInterval << 8) / Int32(bitPattern: expectedInterval))
    // cumulative lost is 24-bit signed, saturating
    let cumulative = max(min(source.lost, 0x7FFFFF), -0x800000)
    let dlsr: UInt32 = lastSRArrival.map { UInt32((now - $0) * 65536.0) } ?? 0
    return ReceptionReportBlock(
        ssrc: source.ssrc, fractionLost: fraction, cumulativeLost: cumulative,
        extendedHighestSequence: source.extendedMax, jitter: source.jitter >> 4,
        lastSRTimestamp: lastSRCompactNTP ?? 0, delaySinceLastSR: dlsr)
}
```

Note `jitter >> 4` on the wire (the field is unscaled) while the state keeps the ×16 form.

### 12.8 Generating our compound packet

A compound RTCP packet **must** begin with SR or RR and **must** contain an SDES CNAME
(RFC 3550 §6.1). We are receive-only, so we send `RR + SDES(CNAME, TOOL)`:

```swift
public struct RTCPReportBuilder: Sendable {
    public var ourSSRC: UInt32            // random, non-zero, drawn once per session
    public var cname: String              // "vigil-<8 hex>@<local-ip-or-hostname>", ≤ 255 bytes
    public var tool: String = "Vigil/1.0"
    public mutating func makeCompoundReport(source: inout RTPSourceState,
                                            now: MonotonicTime) -> Data
    public func makeBye(reason: String?) -> Data
    /// RFC 5104 FIR. Sent alongside the ISAPI keyframe request; most Hikvision firmware ignores it.
    public func makeFullIntraRequest(target: UInt32, sequenceNumber: UInt8) -> Data
}
```

* `ourSSRC`: `UInt32.random(in: 1...UInt32.max)` from `SystemRandomNumberGenerator`. Never 0.
  Regenerate on SSRC collision (an incoming packet with our SSRC) per RFC 3550 §8.2.
* CNAME must be stable for the whole session and unique per host+process.
* FIR (PT 206, FMT 4) body: our SSRC, target SSRC (0 per RFC 5104 for PSFB media SSRC), then FCI
  entries of `{targetSSRC(4), seqNr(1), reserved(3)}`. `seqNr` increments per request.

### 12.9 RTCP interval

RFC 3550 §6.2/6.3 sets the interval from session bandwidth; for a unicast receive-only client the
rules collapse to:

| Situation | Interval |
|---|---|
| Steady state | **5.0 s**, multiplied by `Double.random(in: 0.5...1.5)` each time |
| First report after PLAY | half the above (RFC 3550 allows the reduced initial interval), min 1.5 s |
| Immediately after a loss burst > 5% | send an extra RR at once, then reset the timer (helps NVRs that adapt bitrate) |
| Server sent `RTCP-Interval` in SETUP/PLAY | honour it, clamped to 1…30 s |
| Session paused | stop sending |

`RTPTrackReceiver.tick(now:)` returns `outboundRTCP` when due and reports `nextDeadline` so the
transport can arm a single coalesced timer. RTCP RR also serves as a secondary keepalive; the
primary keepalive remains `GET_PARAMETER` (owned by `VigilRTSP`), because several Hikvision builds
ignore RTCP entirely for session-timeout purposes. **Do not rely on RTCP for keepalive.**

---

## 13. `StreamStatistics` and the exact update algebra

```swift
public struct StreamStatistics: Sendable, Equatable {
    // counters (monotone)
    public var framesEmitted: UInt64 = 0
    public var framesDropped: UInt64 = 0          // gate, corruption, RASL, over-budget
    public var keyframesEmitted: UInt64 = 0
    public var bytesReceived: UInt64 = 0          // RTP wire bytes incl. headers
    public var packetsReceived: UInt64 = 0
    public var packetsLost: UInt64 = 0
    public var packetsOutOfOrder: UInt64 = 0
    public var packetsDuplicate: UInt64 = 0
    public var packetsLate: UInt64 = 0            // arrived after their slot was released
    public var malformedPackets: UInt64 = 0

    // smoothed gauges
    public var fps: Double = 0                    // EWMA, α = 0.10
    public var kilobitsPerSecond: Double = 0      // EWMA over 500 ms windows, α = 0.25
    public var keyframeIntervalSeconds: Double = 0 // EWMA, α = 0.20
    public var jitterMilliseconds: Double = 0     // exact, from RTPSourceState
    public var lossFraction: Double = 0           // last RTCP interval, exact
    public var latencyEstimateMilliseconds: Double = 0

    // instantaneous
    public var reorderBufferDepth: Int = 0
    public var reorderBufferMilliseconds: Double = 0
    public var decodeQueueDepth: Int = 0          // written by VigilVideo, read-through
    public var currentBitrateBytesInWindow: Int = 0
    public var sliceProfile: SliceProfile = .unknown
    public var markerTrust: MarkerTrust = .probing
    public var lastKeyframeAt: MonotonicTime?
    public var lastFrameAt: MonotonicTime?
    public var wallClockMapping: RTPWallClockMapping?
}
```

### 13.1 EWMA constants and seeding

One helper, used everywhere, seeded on first sample so gauges never ramp from zero:

```swift
@inlinable func ewma(_ current: Double, _ sample: Double, _ alpha: Double) -> Double {
    current == 0 ? sample : current + alpha * (sample - current)
}
```

| Gauge | Sample | Trigger | α | ≈ time constant |
|---|---|---|---|---|
| `fps` | `1 / dt`, `dt` clamped to `[1/240, 2.0]` s | each emitted video frame | **0.10** | 10 frames (0.4 s at 25 fps) |
| `kilobitsPerSecond` | `bytesInWindow * 8 / 1000 / windowSeconds` | 500 ms tick | **0.25** | 2 s |
| `keyframeIntervalSeconds` | `now - lastKeyframeAt` | each keyframe | **0.20** | 5 keyframes |

Rationale for the clamps: a 2 s cap stops a reconnect from showing 0.02 fps for ten seconds; the
1/240 floor stops a duplicate-timestamp pair from showing 10 000 fps.

`jitterMilliseconds` and `lossFraction` are **not** smoothed — RFC 3550 already smooths jitter, and
loss fraction is defined per interval. Smoothing them again hides bursts.

### 13.2 Bitrate windowing

```
accumulate: bytesReceived += packet.wireByteCount; currentBitrateBytesInWindow += wireByteCount
on tick(now) with now - windowStart >= 0.5:
    let secs = now - windowStart
    kilobitsPerSecond = ewma(kilobitsPerSecond, Double(currentBitrateBytesInWindow) * 8 / 1000 / secs, 0.25)
    currentBitrateBytesInWindow = 0; windowStart = now
```

Count **wire** bytes (RTP header + payload + padding), not payload bytes: the operator comparing
Vigil’s readout with the camera’s configured bitrate needs the number that matches what the switch
sees. Show payload bitrate separately in the diagnostics panel if desired.

### 13.3 Loss, reorder, duplicate accounting

| Statistic | Source of truth |
|---|---|
| `packetsReceived` | incremented once per successfully parsed RTP packet |
| `packetsLost` | sum of `ReorderBuffer.Output.gaps` widths (authoritative for the UI) |
| `lossFraction` | `RTPSourceState` per RTCP interval (authoritative for the RR wire field) |
| `packetsOutOfOrder` | `ReorderBuffer` `reordered` counter |
| `packetsDuplicate` | `ReorderBuffer` `duplicates` counter |
| `packetsLate` | `ReorderBuffer` `late` counter |

The two loss numbers can differ slightly (the buffer sees a lost packet the moment it gives up; the
RFC algorithm sees it at the next report). That is expected. Document it in the HUD tooltip.

### 13.4 Latency estimate

```
latencyEstimateMilliseconds =
      reorderBufferMilliseconds                                   // jitter buffer occupancy
    + Double(decodeQueueDepth) * 1000 / max(fps, 1)               // frames waiting for the decoder
    + presentationClock.latencySeconds(...) * 1000                // capture→arrival, when locked
    + displayLatencyMilliseconds                                  // 8.3 at 120 Hz, 16.7 at 60 Hz
```

When the presentation clock is not locked, substitute the median packetization+network delay
measured as `min(raw offset)` over the last 2 s. The HUD shows the total and, on hover, the four
terms — this is how a user distinguishes “the camera’s encoder is slow” from “our queue is deep”.

`decodeQueueDepth` is written by `VigilVideo` through
`RTPTrackReceiver.updateDecodeQueueDepth(_:)`; the pure layer never learns it on its own.

---

## 14. Public API surface

### 14.1 `Depacketizer`

```swift
public protocol Depacketizer: Sendable {
    var codec: Codec { get }
    var clockRate: Int32 { get }
    var statistics: DepacketizerStatistics { get }
    /// Consume one in-order RTP packet. Never throws: malformed input is counted and reported
    /// through `output.events`, because one bad packet must never tear down a stream.
    mutating func push(_ packet: RTPPacket) -> DepacketizerOutput
    /// Emit any complete pending access unit (called on PAUSE/TEARDOWN/timeout).
    mutating func flush() -> [EncodedFrame]
    /// Full state reset: SSRC change, seek, reconnect. Keeps `initialParameterSets`.
    mutating func reset()
}

public struct DepacketizerOutput: Sendable {
    public var frames: [EncodedFrame] = []
    public var events: [DepacketizerEvent] = []
    public var isEmpty: Bool { frames.isEmpty && events.isEmpty }
    public static let none = DepacketizerOutput()
}
```

Conformers are **structs**, so `mutating` + `Sendable` compose cleanly under Swift 6 strict
concurrency and the whole thing can live inside an actor without any `nonisolated(unsafe)`.
`AnyDepacketizer` (§4.2) is the enum used on the hot path; the protocol exists for tests, for the
synthetic-stream fixture, and as documentation. Allocation note: `push` returns `.none` for the
~97% of packets that are mid-frame fragments, and `.none` is a `static let` — no allocation.

### 14.2 `RTPTrackReceiver` — the unit `VigilTransport` drives

```swift
public struct RTPTrackReceiver: Sendable {
    public init(format: RTPTrackFormat,
                reorderPolicy: ReorderBuffer.Policy,
                gapPolicy: GapPolicy = .init(),
                configuration: DepacketizerConfiguration = .liveDefault,
                cname: String,
                startTime: MonotonicTime) throws(RTPTrackError)

    public private(set) var statistics: StreamStatistics
    public private(set) var presentationClock: PresentationClock
    public var format: RTPTrackFormat { get }

    public mutating func ingestRTP(_ bytes: Data, at now: MonotonicTime) -> RTPIngestResult
    public mutating func ingestRTCP(_ bytes: Data, at now: MonotonicTime) -> RTPIngestResult
    /// Timer-driven work: buffer drain, AU timeout, RTCP RR generation, stats windows.
    public mutating func tick(_ now: MonotonicTime) -> RTPIngestResult
    /// Earliest time at which `tick` has something to do. Coalesce timers on this.
    public var nextDeadline: MonotonicTime? { get }
    public mutating func flush(at now: MonotonicTime) -> RTPIngestResult
    public mutating func reset(at now: MonotonicTime)
    public mutating func updateDecodeQueueDepth(_ depth: Int)
    /// Seeds RTP-Info from the RTSP PLAY response so the first PTS is right.
    public mutating func seed(rtpInfoSeq: UInt16?, rtpInfoTimestamp: UInt32?)
}

public struct RTPIngestResult: Sendable {
    public var frames: [EncodedFrame] = []
    public var events: [DepacketizerEvent] = []
    public var outboundRTCP: [Data] = []            // payloads only; transport adds framing
    public var isEmpty: Bool { … }
}
```

This is the whole surface `VigilTransport` needs: bytes in, frames + events + RTCP out, plus a
deadline. Everything above it is testable on Linux with `ManualClock` and a byte array. The
synthetic RTP generator specified in `ARCHITECTURE.md` must target exactly this API.

### 14.3 Errors

```swift
public enum RTPParseError: Error, Equatable, Sendable {
    case tooShort(needed: Int, got: Int)
    case badVersion(UInt8)
    case truncatedCSRC
    case truncatedExtension
    case badPaddingLength(UInt8)
}

public enum RTPTrackError: Error, Equatable, Sendable {
    case unsupportedEncoding(String)
    case missingRequiredFmtp(String)
    case unsupportedAACMode(String)
    case malformedAudioConfig(String)
    case invalidClockRate(Int32)
}

public enum AudioConfigError: Error, Equatable, Sendable {
    case malformedConfig, truncated, reservedSamplingFrequencyIndex(Int),
         unsupportedAudioObjectType(Int), programConfigElementUnsupported
}
```

`RTPParseError` is thrown (typed) only from `RTPPacket.parse`. Everything downstream is
**non-throwing**: a stream must survive garbage. Nothing in this module ever calls `fatalError`,
`try!`, `as!`, or force-unwraps outside `#if DEBUG` assertions.

### 14.4 Events

```swift
public enum DepacketizerEvent: Sendable, Equatable {
    // loss & recovery
    case packetLoss(range: ClosedRange<UInt16>, count: Int)
    case keyframeNeeded(reason: KeyframeRequestReason)
    case awaitingKeyframe(droppedAccessUnits: Int)
    case accessUnitDropped(reason: DropReason)
    // format
    case parameterSetsChanged(ParameterSets)
    case audioConfigChanged(AudioSpecificConfig)
    // stream identity & continuity
    case ssrcChanged(old: UInt32, new: UInt32)
    case timestampDiscontinuity(seconds: Double)
    case senderReport(SenderReport)
    case bye(reason: String?)
    case endOfStream
    // policy / diagnostics
    case boundaryPolicyChanged(slice: SliceProfile, marker: MarkerTrust)
    case jitterPolicyEscalated(ReorderBuffer.Policy.Mode)
    case malformed(MalformedReason)
    case unsupported(UnsupportedFeature)
}

public enum KeyframeRequestReason: Sendable, Equatable {
    case streamStart, packetLoss, corruptAccessUnit, decoderReset, formatChange, userRequest
}
public enum DropReason: Sendable, Equatable {
    case awaitingKeyframe, incompleteFragment, corrupt, tooLarge, raslAfterCRA,
         prematureClose, timeout, nonBaseLayer
}
public enum MalformedReason: Sendable, Equatable {
    case emptyPayload, truncatedAggregate, zeroLengthAggregate, truncatedFragment,
         lostFirstFragment, lostLastFragment, fragmentGap, fragmentTimestampChange,
         forbiddenBitSet, nestedPacketization, auSizeMismatch, truncatedAudioAU,
         rtcpMisaligned, malformedExtension, unexpectedPayloadType
}
public enum UnsupportedFeature: Sendable, Equatable {
    case aggregationType(UInt8)        // MTAP16 / MTAP24
    case packetizationType(UInt8)      // PACI
    case interleavedMode
    case nonBaseLayer(UInt16)
    case redundantEncoding, forwardErrorCorrection
}
```

**Event rate limiting is mandatory.** Each `MalformedReason` and `UnsupportedFeature` is emitted at
most once per 5 s per receiver (a broken stream would otherwise emit 3000 events/s and the logging
subsystem would become the bottleneck). Counters keep incrementing. Implement with a small
`[UInt8: MonotonicTime]` keyed by a case discriminant.

**SSRC change handling.** On the first packet with a new SSRC: emit `.ssrcChanged`, `reset()` the
depacketizer, `reset()` the reorder buffer and `RTPSourceState`, reset the presentation clock and
`TimestampUnwrapper`, re-arm the keyframe gate, and reset `BoundaryPolicy`. Hikvision NVRs change
SSRC when switching channels on a shared session and after an internal encoder restart; treating it
as loss instead of a reset produces a permanently broken stream.

---

## 15. Test vectors and the required unit-test list

All vectors below are hex, MSB-first, and are checked in as
`Tests/VigilRTPTests/Fixtures/*.hex`. The video NAL payload bytes are opaque on purpose — these
tests pin the **framing arithmetic**. Real camera SPS/PPS vectors with expected parsed values are
`spec-bitstream.md`'s responsibility.

### 15.1 RTP header parsing

```
80 60 12 34 00 0A 5C 90 12 34 56 78 | 65 88 84 00 12 34
```
| Field | Expected |
|---|---|
| version | 2 |
| P, X, CC | false, false, 0 |
| M | false |
| PT | 96 |
| sequenceNumber | 0x1234 = 4660 |
| timestamp | 0x000A5C90 = 679 056 |
| ssrc | 0x12345678 |
| payload | `65 88 84 00 12 34` (6 bytes) |
| H.264 nal type | 5 (IDR) ⇒ keyframe |
| `first_mb_in_slice == 0`? | yes (`0x88 & 0x80 != 0`) |

With padding (`P` set, 3 bytes of padding):
```
A0 60 12 35 00 0A 5C 90 12 34 56 78 | 41 9A 00 00 03
```
⇒ payload is `41 9A` (2 bytes), `wireByteCount == 17`.

With a one-byte extension:
```
90 60 12 36 00 0A 5C 90 12 34 56 78 | BE DE 00 01 | 12 AB 00 00 | 41 9A
```
⇒ `headerExtension.profile == 0xBEDE`, `data == 12 AB 00 00`, elements = `[(id: 1, value: AB)]`
(then id 0 padding twice), payload `41 9A`.

### 15.2 H.264 STAP-A

```
78 00 0A 67 4D 00 29 95 A8 1E 00 89 F9 00 04 68 EE 3C B0
```
19 payload bytes ⇒ two NALs: SPS (10 bytes, type 7) and PPS (4 bytes, type 8).
Expected `EncodedFrame.data` prefix after the AU closes:
`00 00 00 0A 67 4D 00 29 95 A8 1E 00 89 F9 00 00 00 04 68 EE 3C B0`
and `parameterSets.sps == [67 4D 00 29 95 A8 1E 00 89 F9]`,
`parameterSets.pps == [68 EE 3C B0]`.

### 15.3 H.264 FU-A across three packets

| # | seq | payload | S | E | notes |
|---|---|---|---|---|---|
| 1 | 100 | `7C 85 AA BB` | 1 | 0 | indicator 0x7C: F=0 NRI=3 type=28; FU hdr 0x85 ⇒ type 5 |
| 2 | 101 | `7C 05 CC DD` | 0 | 0 | |
| 3 | 102 | `7C 45 EE FF` | 0 | 1 | marker may or may not be set — must not matter |

Reconstructed NAL = `65 AA BB CC DD EE FF` (header `(0x7C & 0xE0) | 0x05 == 0x65`), length 7,
`isKeyframe == true`.
Negative cases the test must cover: drop packet 1 (⇒ `.lostFirstFragment`, no frame);
drop packet 2 (⇒ `.fragmentGap`, no frame); drop packet 3 then send a new timestamp
(⇒ `.incompleteFragmentAtAUEnd`, no frame, `.keyframeNeeded`).

### 15.4 H.265 FU and AP

FU, three packets, IDR_W_RADL (type 19), TID = 1:

| # | payload | notes |
|---|---|---|
| 1 | `62 01 93 AA BB` | PayloadHdr `62 01` ⇒ type 49, LayerId 0, TID 1; FU hdr `0x93` ⇒ S=1, type 19 |
| 2 | `62 01 13 CC DD` | S=0 E=0 |
| 3 | `62 01 53 EE FF` | E=1 |

Reconstructed NAL header = `26 01` (`(0x62 & 0x81) | (19 << 1) == 0x26`), full NAL
`26 01 AA BB CC DD EE FF`, `isKeyframe == true`, `isIRAP((0x26 >> 1) & 0x3F) == true`.

AP with VPS + SPS + PPS (no DONL):
```
60 01 00 06 40 01 0C 01 FF FF 00 08 42 01 01 01 60 00 00 03 00 04 44 01 C1 72
```
26 payload bytes ⇒ NALs of 6, 8 and 4 bytes with types 32, 33, 34. Note the `00 00 03` inside the
SPS body must **not** be treated as a start code or removed at this layer.

The same AP with `sprop-max-don-diff=1` (DONL/DOND active):
```
60 01 00 2A 00 06 40 01 0C 01 FF FF 07 00 08 42 01 01 01 60 00 00 03 05 00 04 44 01 C1 72
```
⇒ DONL = 0x002A, then unit 1 (no DOND), then DOND 0x07 + unit 2, DOND 0x05 + unit 3.

### 15.5 AAC (`sizelength=13, indexlength=3, indexdeltalength=3`)

Single AU of 291 bytes:
```
00 10 09 18 <291 bytes>
```
`AU-headers-length = 0x0010` = 16 bits; header `0x0918` ⇒ top 13 bits `0000100100011` = 291,
index = 0.

Two AUs of 100 and 120 bytes, `rtpTimestamp = T`, clock 16 000:
```
00 20 03 20 03 C0 <100 bytes><120 bytes>
```
`AU-headers-length = 32`; headers `0000001100100 000` and `0000001111000 000`.
Expected: two frames, `pts = T` and `pts = T + 1024`, each `duration = 1024/16000 = 64 ms`,
`isKeyframe == true`.

`AudioSpecificConfig` cases:

| `config=` | AOT | rate | channels | frame length |
|---|---|---|---|---|
| `1210` | 2 | 44100 | 1 | 1024 |
| `1408` | 2 | 16000 | 1 | 1024 |
| `1588` | 2 | 8000 | 1 | 1024 |
| `1190` | 2 | 48000 | 2 | 1024 |
| `121056E500` | 5 (SBR) → core 2 | 44100 core | 1 | 1024 |

(`0x1190` = `00010 0011 0010 000…` ⇒ AOT 2, sfi 3 = 48000, ch 2.)
ADTS header for a 291-byte AU with `config=1408`: `FF F1 60 40 25 9F FC`.
The test asserts `ADTS.header(auByteCount: 291, config:)` equals that, and that `ffprobe` accepts
the concatenation (offline check, documented in the fixture README).

### 15.6 G.711

| Input byte | μ-law → Int16 | A-law → Int16 |
|---|---|---|
| `0xFF` | 0 | −8 |
| `0x7F` | 0 (negative zero) | 8 |
| `0x00` | −32124 | −5504 |
| `0x80` | 32124 | 5504 |
| `0x2A` | −4988 | 0 |
| `0xD5` | 876 | 0 |

Plus: full 256-value round-trip identity for μ-law; A-law round trip within ±1 LSB of the segment;
table equals closed-form for all 256 inputs; a 160-byte payload yields a 320-byte
`EncodedFrame.data` with `duration == 160/8000`.

### 15.7 RTCP

Inbound SR from a camera:
```
80 C8 00 06 12 34 56 78 E9 A4 3B 21 80 00 00 00 00 0A 5C 90 00 00 27 10 00 12 34 56
```
| Field | Expected |
|---|---|
| length | 6 words ⇒ 28 bytes total |
| RC | 0 |
| ssrc | 0x12345678 |
| ntpMSW / ntpLSW | 0xE9A43B21 / 0x80000000 |
| `unixSeconds` | 1 710 671 009.5 ⇒ 2024-03-16T10:23:29.5Z |
| rtpTimestamp | 0x000A5C90 |
| packetCount / octetCount | 10 000 / 0x123456 = 1 193 046 |
| `compactNTP` | 0x3B218000 |

Outbound compound RR + SDES with `ourSSRC = 0xCAFEBABE`,
`cname = "vigil@192.168.1.42"` (18 bytes):

```
81 C9 00 07 CA FE BA BE  12 34 56 78 00 00 00 05 00 00 12 40 00 00 00 21
3B 21 80 00 00 00 1F 40
81 CA 00 07 CA FE BA BE  01 12 76 69 67 69 6C 40 31 39 32 2E 31 36 38 2E
31 2E 34 32 00 00 00 00
```
RR: `0x81` = V2, RC=1; PT 201; length 7 ⇒ 32 bytes. Report block: source 0x12345678,
fractionLost 0, cumulativeLost 5, extendedHighest 0x00001240, jitter 0x21 = 33 RTP units
(0.37 ms at 90 kHz), LSR 0x3B218000, DLSR 0x1F40 = 8000/65536 = 0.122 s.
SDES: length 7 ⇒ 32 bytes; item type 1, length 0x12 = 18, text, terminator, padding to a 32-bit
boundary.

The jitter test drives the A.8 recurrence with a scripted arrival/timestamp table and asserts the
exact integer sequence — that is the only way to catch the `>> 4` scaling being applied twice.

### 15.8 Required test list (each is a named `XCTest` / `swift-testing` case)

**Header:** min length, bad version, CC=1..15 offsets, X with 0-word and 4-word extensions,
one-byte and two-byte element parsing, id 0 padding, id 15 stop, unknown profile skip,
padding = 1 / = payload length / = 0 (error) / > packet (error), empty payload after padding.
**Sequence math:** `seqLess`/`seqDiff` exhaustive over a wrap window; the table in §10.1.
**Reorder buffer:** in-order passthrough; single swap; 3-packet reversal; duplicate; late; wrap at
65535→0; capacity overflow forced flush; ms-bound release; `adaptiveLowLatency` state transitions;
`.passthrough` never buffers.
**H.264:** every row of §15.3; STAP-A with 1/2/64 NALs; STAP-A truncated; zero-size aggregate;
STAP-B DON skip; MTAP rejection; FU-A single-fragment; `maxNALBytes` guard;
`maxFragmentsPerNAL` guard.
**H.265:** §15.4; AP with and without DONL; FU with DONL on the S fragment only; `LayerId != 0`
drop; PACI rejection; nested `fuType == 49` rejection; RASL-after-CRA drop.
**AU boundaries:** timestamp change closes; marker never set (must still emit — the regression
test for the whole §7 design); marker on every packet with `.adaptive` (must not split);
multi-slice picture with `first_mb_in_slice != 0` stays one AU; two pictures sharing a timestamp
split via O4; AUD/SPS mid-AU splits via O3; timeout close; premature-close self-correction (§7.5).
**AAC:** §15.5; `AU-headers-length` = 0; size mismatch; fragmented AU across two packets;
`MPEG4-GENERIC` and `mode=AAC-HBR` upper-case acceptance; malformed and odd-length `config`;
sfi 15 explicit rate; AOT escape; `channelConfiguration == 0` fallback.
**G.711/G.726:** §15.6; ITU G.726 conformance vectors byte-exact.
**Timestamps:** wrap forward, wrap with a reordered packet straddling it, 10 s discontinuity,
rebasing to origin, `MediaTimestamp.converted(to:)` against a table of known rational conversions
including 90 000 → 1 000 000 and back.
**Presentation clock:** constant-offset input ⇒ zero rate error; +100 ppm ramp ⇒ `rateRatio`
converges within 20 ppm in 30 s of simulated frames; a 1 s step ⇒ hard reset; asymmetric delay
spikes ⇒ offset does **not** drift upward (this is the test that justifies the min filter).
**RTCP:** §15.7; compound parsing with SR+SDES+BYE; unknown PT skip; truncated sub-packet;
misaligned buffer; RR field encoding across a sequence wrap; fraction-lost saturation;
cumulative-lost negative (duplicates) clamping.
**Statistics:** EWMA seeding; fps clamps; bitrate window boundary; loss counters vs RFC counters.
**Fuzz:** 10 000 pseudo-random buffers (fixed seed) through `RTPPacket.parse` and each
depacketizer — no crash, no unbounded memory, all errors accounted. Run in CI on Linux.

---

## 16. Performance budget and allocation rules

16 × 1080p sub-streams at 25 fps ≈ 16 × 1500 packets/s ≈ **24 000 packets/s** across the app. The
whole pure path must cost well under 1% of one core.

| Rule | Enforcement |
|---|---|
| No `Data` copy on parse — `payload` is always a slice | reviewed; `Bytes` wrapper only reads |
| One allocation per reassembled NAL (the concatenation) | `reserveCapacity` before the loop |
| One allocation per emitted AU (`EncodedFrame.data`) | ditto |
| `DepacketizerOutput.none` is a `static let` for the no-output case | ~97% of packets |
| Fixed-capacity `[RTPPacket?]` ring; no per-packet dictionary | `ReorderBuffer` |
| No string formatting on the hot path; events carry enums, never `String` | see §14.4; `MalformedReason` is an enum for exactly this reason |
| `@inlinable` on every accessor in `Bytes`, `seqLess`, the G.711 table lookup | |
| Event rate limiting (§14.4) | one `[UInt8: MonotonicTime]` per receiver |
| No `Foundation.Date`, no `DateFormatter`, no locale-sensitive API anywhere in this module | lint |

Benchmarks that must exist in `Tests/VigilRTPTests/Benchmarks` and be run manually before release
(not in CI): packets/s through `RTPPacket.parse`; packets/s through `H264Depacketizer.push` with a
realistic 40-fragment-per-IDR pattern; allocations per 10 000 packets measured with
`malloc` counters. Targets: ≥ 3 M parses/s and ≤ 2.1 allocations per emitted frame on an M1.

---

## 17. Explicit non-goals

The following are deliberately **not** implemented in `VigilRTP` v1. Each would need its own design
pass; none is required for Hikvision LAN viewing.

| Not implemented | Why |
|---|---|
| SRTP / SRTCP | Hikvision does not offer it for RTSP; RTSP-over-TLS covers confidentiality |
| RFC 2198 RED, RFC 5109 ULP FEC, RFC 4588 RTX | Hikvision never negotiates them; PTs are dropped and counted |
| Interleaved packetization mode 2 (DON-based reordering) | never offered by Hikvision; STAP-B/FU-B DON is parsed and discarded |
| MTAP16 / MTAP24, H.265 PACI | see §5.3, §6.5 |
| RTP/JPEG (RFC 2435, PT 26) | still-image refresh uses the ISAPI JPEG endpoint instead |
| MPEG-4 Part 2 (`MP4V-ES`) | legacy Hikvision `/mpeg4/` URLs; VigilVideo would need a second decoder path. `VigilRTSP` must surface a clear "unsupported codec" error for these |
| Opus, G.722, G.729, AMR | not offered by Hikvision cameras |
| B-frame / POC reordering | no Hikvision live profile uses B-frames; recorded playback reorder is `VigilVideo`'s job using POC from `VigilBitstream` |
| Multicast source dedup, SSM | multicast is a `VigilTransport` concern; one SSRC per session is assumed |
| RTCP XR (PT 207), receiver-side congestion control | out of scope for a LAN client |
| Sending RTP (a packetizer) | two-way audio is an ISAPI HTTP `PUT`, not RTP (§9.4) |
