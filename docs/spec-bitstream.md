# Vigil — Video Bitstream Specification (`VigilBitstream`)

Status: normative. Every number, byte offset, and Swift signature in this document is binding.
Target: Swift 6, strict concurrency, **Foundation only**. This module compiles and its full test
suite runs on **Linux Swift 6.1** in CI. It must not import CoreMedia, VideoToolbox, AppKit,
SwiftUI, Metal, Security or Network.

Every hex/base64 example in §16, §17 and §22 was machine-generated and round-tripped through an
independent reference parser while writing this document. They are exact, not illustrative.

---

## 1. Scope and position in the module graph

`VigilBitstream` owns everything that concerns the *syntax of the coded video stream itself*:

| Concern | Owner |
|---|---|
| Start-code scanning, Annex-B ↔ length-prefixed conversion | **VigilBitstream** |
| RBSP unescaping, Exp-Golomb, byte alignment | **VigilBitstream** (raw bit reader in `VigilProtocols`) |
| H.264 SPS/PPS/SEI parsing | **VigilBitstream** |
| H.265 VPS/SPS/PPS/SEI parsing, profile_tier_level | **VigilBitstream** |
| `avcC` / `hvcC` build + parse | **VigilBitstream** |
| Parameter-set store, format-change detection, IRAP gate | **VigilBitstream** |
| RTP payload framing, FU-A/AP reassembly, AU boundaries | VigilRTP (calls into us) |
| `CMVideoFormatDescription`, `CMSampleBuffer`, VTDecompressionSession | VigilVideo |
| `sprop-parameter-sets` base64 extraction from SDP | VigilRTSP (hands us bytes) |

### 1.1 Dependency direction (binding)

```
VigilProtocols  ──▶  VigilBitstream  ──▶  VigilRTP
       │                    │                  │
       └────────────────────┴──────────────────┴──▶ VigilVideo (macOS) ──▶ VigilCore
```

`VigilRTP` **depends on** `VigilBitstream`. This is deliberate: the depacketizers need NAL type
tables, the two-byte H.265 NAL header decode, `AnnexB`/`LengthPrefixed` writers, and the
first-slice-of-picture predicate. Duplicating any of those in `VigilRTP` is a review-blocking
defect. `VigilBitstream` must never import `VigilRTP`.

### 1.2 The one hard layering rule this module enforces

`VigilBitstream` produces `VideoFormatInfo` (our own value type) and raw parameter-set byte arrays.
It never produces a `CMFormatDescription`. The conversion happens in exactly one file in
`VigilVideo` (§18). Anything in the pure layer that needs "the format" uses `VideoFormatInfo`.

---

## 2. Shared value types and where they live

These three types live in **`VigilProtocols`**, because both `VigilRTP` and `VigilBitstream`
publish them and `VigilCore` consumes them. `VigilBitstream` owns all *logic* over them.

```swift
// VigilProtocols/MediaTimestamp.swift
public struct MediaTimestamp: Sendable, Hashable, Comparable, Codable {
    public var value: Int64
    public var timescale: Int32          // 90_000 for RTP video, 1_000_000 for host time
    public init(value: Int64, timescale: Int32)
    public var seconds: Double { Double(value) / Double(timescale) }
    public static let invalid = MediaTimestamp(value: .min, timescale: 1)
}

// VigilProtocols/VideoCodec.swift
public enum VideoCodec: String, Sendable, Hashable, Codable, CaseIterable {
    case h264, h265
    /// Bytes of NAL header that precede the RBSP. 1 for H.264, 2 for H.265.
    public var nalHeaderLength: Int { self == .h264 ? 1 : 2 }
}

// VigilProtocols/ParameterSets.swift
public struct ParameterSets: Sendable, Hashable, Codable {
    public var codec: VideoCodec
    public var vps: [[UInt8]]            // H.265 only; empty for H.264
    public var sps: [[UInt8]]
    public var pps: [[UInt8]]
    public init(codec: VideoCodec, vps: [[UInt8]] = [], sps: [[UInt8]] = [], pps: [[UInt8]] = [])
}
```

### 2.1 Canonical storage form of a parameter set (binding, no exceptions)

Every `[UInt8]` inside `ParameterSets` is:

1. **With** its NAL header (1 byte for H.264, 2 bytes for H.265).
2. **Without** any Annex-B start code and **without** any length prefix.
3. **In escaped, on-wire form** — emulation-prevention `0x03` bytes are *still present*.
   We never store unescaped RBSP.
4. Byte-identical to what the camera sent (or to what base64-decoding
   `sprop-parameter-sets` / `sprop-vps` produced).

Rationale: this is exactly the form required by `avcC`, by `hvcC`, and by
`CMVideoFormatDescriptionCreateFromH264ParameterSets`. Storing unescaped RBSP would force a
re-escape before every use and risks a non-byte-identical round trip. Parsing always unescapes into
a throwaway buffer (§6).

Ordering within each array: ascending parameter-set id; if the camera re-sends a set with an id we
already hold, the new bytes **replace** the old ones in place (Hikvision re-sends SPS/PPS before
every IDR, usually identical, occasionally changed after a resolution change).

### 2.2 `EncodedFrame` (defined in `VigilProtocols`, produced by `VigilRTP`)

```swift
public struct EncodedFrame: Sendable {
    public var codec: VideoCodec
    /// ALWAYS 4-byte big-endian length-prefixed NAL units. Never Annex-B. Never 1/2-byte lengths.
    public var data: [UInt8]
    public var pts: MediaTimestamp
    public var dts: MediaTimestamp
    public var isKeyframe: Bool
    public var parameterSets: ParameterSets?   // non-nil only when they changed at this frame
    public var receivedHostTime: UInt64        // mach_absolute_time-domain, for latency accounting
}
```

**Binding decision:** `EncodedFrame.data` is *always* 4-byte big-endian length-prefixed, and
`lengthSizeMinusOne` is *always* 3 everywhere in Vigil — in `avcC`, in `hvcC`, in the
`nalUnitHeaderLength` argument to the CoreMedia constructors, and in every buffer we hand to
`CMBlockBufferCreateWithMemoryBlock`. There is no configuration knob. Consequences:

* The depacketizers in `VigilRTP` write the 4-byte length directly as they reassemble; there is
  **zero Annex-B ↔ length-prefix conversion on the live decode path**.
* Annex-B only appears at two edges: (a) reading a raw `.h264`/`.h265` file in tests or fixtures,
  (b) writing a debug dump. `§5` exists for those edges, not for the hot path.

---

## 3. NAL unit type tables

### 3.1 H.264 (ITU-T H.264 Table 7-1) — 1-byte header

```
 7   6 5   4 3 2 1 0
+---+-----+-----------+
| F | NRI | nal_type  |
+---+-----+-----------+
```
`forbidden_zero_bit` = bit 7 (must be 0), `nal_ref_idc` = bits 6..5, `nal_unit_type` = bits 4..0.

```swift
let type   = byte & 0x1F
let refIdc = (byte >> 5) & 0x03
guard byte & 0x80 == 0 else { throw BitstreamError.forbiddenBitSet }
```

| Type | Name | Class | Vigil handling |
|---:|---|---|---|
| 0 | Unspecified | — | drop |
| 1 | Coded slice, non-IDR | VCL | decode; may be I, P or B |
| 2–4 | Slice data partition A/B/C | VCL | **drop** — Hikvision never emits; we do not support DP |
| 5 | Coded slice of an **IDR** picture | VCL | decode, keyframe |
| 6 | SEI | non-VCL | parse (§19) |
| 7 | **SPS** | non-VCL | store + parse (§7) |
| 8 | **PPS** | non-VCL | store + parse (§9) |
| 9 | Access unit delimiter | non-VCL | drop (do not forward to VT) |
| 10 | End of sequence | non-VCL | flush decoder |
| 11 | End of stream | non-VCL | flush + teardown |
| 12 | Filler data | non-VCL | drop |
| 13 | SPS extension | non-VCL | store (avcC `spsExt` array), do not parse |
| 14 | Prefix NAL unit | non-VCL | drop (SVC/MVC) |
| 15 | Subset SPS | non-VCL | drop |
| 16 | Depth parameter set | non-VCL | drop |
| 19 | Aux coded slice | VCL | drop |
| 20 | Slice extension | VCL | drop |
| 21 | Slice extension for depth | VCL | drop |
| 24–31 | *RTP-only* (STAP-A/B, MTAP, FU-A/B) | — | never reaches us; `VigilRTP` unwraps them |

`isVCL` ⇔ `1...5`. Only types 1 and 5 are forwarded to the decoder, plus 6/7/8 handled internally.

### 3.2 H.265 (ITU-T H.265 Table 7-1) — 2-byte header

```
byte0:  7        6 5 4 3 2 1        0
       +---+-------------------+--------+
       | F |   nal_unit_type   | LId[5] |
       +---+-------------------+--------+
byte1:  7 6 5 4 3              2 1 0
       +-------------------+-----------+
       |    LayerId[4:0]   | TID+1     |
       +-------------------+-----------+
```

```swift
@inlinable
public static func decodeHEVCHeader(_ b0: UInt8, _ b1: UInt8) throws -> (type: UInt8, layerID: UInt8, temporalID: UInt8) {
    guard b0 & 0x80 == 0 else { throw BitstreamError.forbiddenBitSet }
    let type       = (b0 >> 1) & 0x3F
    let layerID    = ((b0 & 0x01) << 5) | ((b1 >> 3) & 0x1F)
    let tidPlus1   = b1 & 0x07
    guard tidPlus1 != 0 else { throw BitstreamError.invalidTemporalID }
    return (type, layerID, tidPlus1 - 1)
}
```

Encoding back:
```swift
let b0 = UInt8((type << 1) | (layerID >> 5))
let b1 = UInt8(((layerID & 0x1F) << 3) | (temporalID + 1))
```

| Type | Name | Class | Vigil handling |
|---:|---|---|---|
| 0,1 | TRAIL_N / TRAIL_R | VCL | decode |
| 2,3 | TSA_N / TSA_R | VCL | decode |
| 4,5 | STSA_N / STSA_R | VCL | decode |
| 6,7 | RADL_N / RADL_R | VCL | decode (leading, decodable) |
| 8,9 | **RASL_N / RASL_R** | VCL | **drop while `NoRaslOutputFlag == 1`** (§20.3) |
| 10,12,14 | RSV_VCL_N10/12/14 | VCL | drop |
| 11,13,15 | RSV_VCL_R11/13/15 | VCL | drop |
| 16 | BLA_W_LP | VCL, **IRAP** | keyframe; sets `NoRaslOutputFlag = 1` |
| 17 | BLA_W_RADL | VCL, **IRAP** | keyframe; sets `NoRaslOutputFlag = 1` |
| 18 | BLA_N_LP | VCL, **IRAP** | keyframe; sets `NoRaslOutputFlag = 1` |
| 19 | IDR_W_RADL | VCL, **IRAP** | keyframe |
| 20 | IDR_N_LP | VCL, **IRAP** | keyframe |
| 21 | **CRA_NUT** | VCL, **IRAP** | keyframe; if first picture, `NoRaslOutputFlag = 1` |
| 22,23 | RSV_IRAP_VCL22/23 | VCL, IRAP | treat as keyframe, forward |
| 24–31 | RSV_VCL24..31 | VCL | drop |
| 32 | **VPS** | non-VCL | store + parse (§12) |
| 33 | **SPS** | non-VCL | store + parse (§13) |
| 34 | **PPS** | non-VCL | store + parse (§14) |
| 35 | AUD | non-VCL | drop |
| 36 | EOS_NUT | non-VCL | flush |
| 37 | EOB_NUT | non-VCL | flush + teardown |
| 38 | FD_NUT (filler) | non-VCL | drop |
| 39 | **PREFIX_SEI** | non-VCL | parse (§19) |
| 40 | SUFFIX_SEI | non-VCL | parse (§19), rarely useful |
| 41–47 | RSV_NVCL | non-VCL | drop |
| 48–63 | *RTP-only* (48 = AP, 49 = FU, 50 = PACI) | — | `VigilRTP` unwraps |

Useful predicates (exact definitions from H.265 §3):

| Predicate | Definition |
|---|---|
| `isVCL` | `type <= 31` |
| `isIRAP` | `16 <= type <= 23` |
| `isIDR` | `type == 19 || type == 20` |
| `isCRA` | `type == 21` |
| `isBLA` | `16 <= type <= 18` |
| `isRASL` | `type == 8 || type == 9` |
| `isRADL` | `type == 6 || type == 7` |
| `isLeading` | `6 <= type <= 9` |
| `isSubLayerNonReference` | `type <= 14 && type.isMultiple(of: 2)` |
| `isParameterSet` | `32 <= type <= 34` |

Hikvision H.265 encoders emit **IDR_W_RADL (19)** for the periodic keyframe and **TRAIL_R (1)** for
everything else. CRA (21) appears on some NVR playback streams. RASL never appears in live streams
from a Hikvision camera but *does* appear when seeking an NVR playback stream, which is exactly the
case where §20.3 matters.

---

## 4. Bounds and sanity limits (security-relevant)

A camera on a hostile LAN, or firmware with a byte-swap bug, will hand us garbage. Every parser
enforces this table and throws rather than allocating or looping on attacker-chosen counts.

| Quantity | Accepted range | Action outside |
|---|---|---|
| Parameter-set NAL length | 1 … 4096 bytes | `throw .tooLarge` / `.emptyNALUnit` |
| SEI NAL length | 1 … 65536 bytes | `throw .tooLarge` |
| `chroma_format_idc` | 0 … 3 | `throw .valueOutOfRange` |
| `bit_depth_luma_minus8`, `bit_depth_chroma_minus8` | 0 … 8 | `throw` |
| `log2_max_frame_num_minus4` | 0 … 12 | `throw` |
| `log2_max_pic_order_cnt_lsb_minus4` | 0 … 12 | `throw` |
| `pic_order_cnt_type` | 0 … 2 | `throw` |
| `num_ref_frames_in_pic_order_cnt_cycle` | 0 … 255 | `throw` |
| `max_num_ref_frames` | 0 … 16 | clamp to 16, log warning |
| H.264 coded width / height | 16 … 16384 luma samples | `throw` |
| H.265 `pic_width_in_luma_samples` / height | 8 … 16888 | `throw` |
| `sps_max_sub_layers_minus1` | 0 … 6 | `throw` |
| `num_short_term_ref_pic_sets` | 0 … 64 | `throw` |
| `num_long_term_ref_pics_sps` | 0 … 32 | `throw` |
| `log2_min_luma_coding_block_size_minus3` | 0 … 3 | `throw` |
| `CtbLog2SizeY` (derived) | 4 … 6 | `throw` |
| Exp-Golomb leading zeros | 0 … 32 | `throw .malformedExpGolomb` |
| Cropping/conformance offsets | must not exceed coded size | `throw .invalidCropping` |
| NAL units per access unit | ≤ 512 | truncate, log warning |

Additionally: no parser ever allocates a buffer whose size derives from a parsed count. The only
count-driven allocations are `offset_for_ref_frame` (≤ 255 `Int32`) and the RPS bookkeeping array
(≤ 64 `Int`), both bounded above.

---

## 5. Start-code scanning and Annex-B ↔ length-prefixed conversion

### 5.1 The scanner

Annex-B start code prefix is `0x000001`. A leading extra `0x00` (giving `0x00000001`) is the
optional `zero_byte`; both forms occur in the same stream. Trailing `0x00` bytes after a NAL unit
are `trailing_zero_8bits` and are **not** part of the NAL: H.264 §7.4.1 forbids a NAL unit from
ending in `0x00`, so every trailing zero can be trimmed unconditionally and correctly.

The normative scanner is a scalar loop with a 3-byte skip. Justification for the skip: we are
testing whether index `i` holds the `0x01` of a start code. If `bytes[i] > 1` then `i` is not the
`0x01`; `i+1` cannot be either (it would require `bytes[i] == 0`); and `i+2` cannot be either (it
would require `bytes[i] == 0` as the first of the two zeros). So `i`, `i+1`, `i+2` are all
excluded and we may jump to `i+3`. The same argument applies when `bytes[i] == 1` and the
two-zero test fails. Only `bytes[i] == 0` forces a single-byte step. On real video payload the mean
step is ≈ 2.9 bytes.

```swift
// VigilBitstream/AnnexB.swift
public enum AnnexB {

    /// Index of the first byte of the next start-code prefix at or after `from`,
    /// together with its length (3 or 4 — 4 when a `zero_byte` precedes it).
    public static func findStartCode(
        in bytes: UnsafeRawBufferPointer, from: Int
    ) -> (index: Int, length: Int)? {
        let n = bytes.count
        guard n >= 3 else { return nil }
        var i = max(from + 2, 2)
        while i < n {
            let c = bytes[i]
            if c > 1 {
                i += 3
            } else if c == 0 {
                i += 1
            } else {                                  // c == 1
                if bytes[i - 1] == 0 && bytes[i - 2] == 0 {
                    if i >= 3 && bytes[i - 3] == 0 {
                        return (i - 3, 4)
                    }
                    return (i - 2, 3)
                }
                i += 3
            }
        }
        return nil
    }

    /// Enumerates NAL unit payload ranges (start code stripped, trailing zero bytes trimmed).
    /// Zero allocation. `body` may throw to abort.
    public static func enumerateNALUnits(
        in bytes: UnsafeRawBufferPointer,
        _ body: (Range<Int>) throws -> Void
    ) rethrows {
        guard var sc = findStartCode(in: bytes, from: 0) else { return }
        while true {
            let payloadStart = sc.index + sc.length
            let next = findStartCode(in: bytes, from: payloadStart)
            var end = next?.index ?? bytes.count
            while end > payloadStart && bytes[end - 1] == 0 { end -= 1 }   // trailing_zero_8bits
            if end > payloadStart { try body(payloadStart ..< end) }
            guard let n = next else { return }
            sc = n
        }
    }
}
```

An optional SIMD fast path may replace the inner loop when a benchmark shows > 25 % gain: load
`SIMD16<UInt8>` with `UnsafeRawPointer.loadUnaligned(fromByteOffset:as:)`, test
`any(v .== SIMD16<UInt8>(repeating: 0))`, and fall back to the scalar loop inside any 16-byte block
that contains a zero. `SIMD16` is Swift *stdlib*, so this stays Linux-clean. The scalar loop remains
the reference implementation and the correctness oracle in tests.

### 5.2 Annex-B → 4-byte length-prefixed

```swift
extension AnnexB {
    /// Copying conversion. Always correct.
    public static func toLengthPrefixed(_ annexB: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(annexB.count + 8)
        annexB.withUnsafeBytes { raw in
            enumerateNALUnits(in: raw) { r in
                let n = UInt32(r.count)
                out.append(UInt8(truncatingIfNeeded: n >> 24))
                out.append(UInt8(truncatingIfNeeded: n >> 16))
                out.append(UInt8(truncatingIfNeeded: n >> 8))
                out.append(UInt8(truncatingIfNeeded: n))
                out.append(contentsOf: raw[r].bindMemory(to: UInt8.self))
            }
        }
        return out
    }

    /// In-place conversion. Succeeds **only** when every start code is 4 bytes long and no
    /// trailing-zero trimming is required, i.e. when the byte count is unchanged.
    /// Returns false and leaves `buffer` untouched otherwise; caller falls back to the copy above.
    public static func toLengthPrefixedInPlace(_ buffer: inout [UInt8]) -> Bool { /* §5.2.1 */ }
}
```

**5.2.1 — why in-place is conditional.** A 3-byte start code carries 3 bytes of overhead; a 4-byte
length prefix needs 4. Rewriting in place would require shifting all following bytes up by one for
every 3-byte start code, which is O(n·k) and defeats the purpose. `toLengthPrefixedInPlace` therefore
performs a **two-pass** conversion: pass 1 uses `enumerateNALUnits` to verify that (a) every start
code was 4 bytes and (b) no NAL had trailing zeros trimmed; if either fails it returns `false`
without mutating. Pass 2 overwrites each 4-byte start code with the big-endian NAL length. Because
Vigil's live path never produces Annex-B (§2.2), this function exists for file-fixture loading only
and its slow path is irrelevant to performance.

### 5.3 Length-prefixed → Annex-B (always exactly in place)

With `lengthSizeMinusOne == 3` the prefix is 4 bytes and a 4-byte start code is 4 bytes, so the
conversion is size-preserving and unconditionally in place:

```swift
extension AnnexB {
    /// Overwrites each 4-byte big-endian length with 0x00000001. Byte count unchanged.
    /// Throws `.truncatedLengthPrefix` if the buffer is not a well-formed length-prefixed stream.
    public static func fromLengthPrefixedInPlace(_ buffer: inout [UInt8]) throws {
        var i = 0
        while i < buffer.count {
            guard i + 4 <= buffer.count else { throw BitstreamError.truncatedLengthPrefix(atOffset: i) }
            let n = (Int(buffer[i]) << 24) | (Int(buffer[i+1]) << 16)
                  | (Int(buffer[i+2]) << 8) |  Int(buffer[i+3])
            guard n > 0, i + 4 + n <= buffer.count else {
                throw BitstreamError.truncatedLengthPrefix(atOffset: i)
            }
            buffer[i] = 0; buffer[i+1] = 0; buffer[i+2] = 0; buffer[i+3] = 1
            i += 4 + n
        }
    }
}
```

`LengthPrefixed.enumerate` is the read-only counterpart used everywhere on the hot path:

```swift
public enum LengthPrefixed {
    /// Zero-allocation walk. `body` receives the payload range (header byte included) and the
    /// raw NAL type code (5 bits for H.264, 6 bits for H.265).
    public static func enumerate(
        _ bytes: UnsafeRawBufferPointer, codec: VideoCodec,
        _ body: (Range<Int>, UInt8) throws -> Void
    ) throws

    public static func validate(_ bytes: UnsafeRawBufferPointer) -> Bool
    @inlinable public static func appendLength(_ n: Int, to out: inout [UInt8])
}
```

### 5.4 Worked example (verified bytes)

Annex-B input, 47 bytes: 4-byte SC + SPS(22 B) + 4-byte SC + PPS(4 B) + **3-byte** SC + IDR(10 B).

```
00 00 00 01 67 4D 00 28 F4 03 C0 11 3F 2E 02 20   <- SC(4) + SPS
00 00 03 00 20 00 00 06 50 80 00 00 00 01 68 EE   <- ...SPS end, SC(4) + PPS
3C 80 00 00 01 65 88 84 04 BF 00 00 03 01 AA      <- ...PPS end, SC(3) + IDR slice
```

Length-prefixed output, 48 bytes (one byte larger — the 3-byte SC became a 4-byte prefix, so
`toLengthPrefixedInPlace` returns `false` here):

```
00 00 00 16 67 4D 00 28 F4 03 C0 11 3F 2E 02 20   <- len=0x16=22, SPS
00 00 03 00 20 00 00 06 50 80 00 00 00 04 68 EE   <- len=4, PPS
3C 80 00 00 00 0A 65 88 84 04 BF 00 00 03 01 AA   <- len=0x0A=10, IDR slice
```

Note the `00 00 03 00` inside the SPS at offsets 16–19 and the `00 00 03 01` inside the IDR slice at
offsets 42–45 of the output: those are **emulation-prevention bytes inside NAL payloads**, and the
scanner correctly does *not* mistake them for start codes because the pattern is `00 00 03`, not
`00 00 01`. This is the single most important property to test (§22, T-AB-3).

---

## 6. RBSP: emulation-prevention byte removal

Inside a NAL unit the encoder inserts `emulation_prevention_three_byte` = `0x03` whenever the next
raw bytes would produce `0x000000`, `0x000001`, `0x000002` or `0x000003`. The decoder removes a
`0x03` that is preceded by exactly two `0x00` bytes **and** followed by a byte ≤ `0x03` (or by
end-of-NAL — the encoder must append the `0x03` when the RBSP ends in `00 00`, because a NAL unit
may not end with `0x00`).

We implement the strict form. It agrees with the looser "drop any `0x03` after two zeros" form
(FFmpeg's `ff_h2645_extract_rbsp`) on every conforming stream, because a conforming encoder can
never emit `00 00 03 xx` with `xx > 0x03`; the strict form additionally refuses to corrupt data from
non-conforming firmware.

```swift
// VigilBitstream/RBSP.swift
public enum RBSP {

    /// Removes emulation-prevention bytes. `nal` includes the NAL header; pass
    /// `skippingHeaderBytes: codec.nalHeaderLength` to unescape only the RBSP.
    public static func unescape(
        _ nal: UnsafeRawBufferPointer, skippingHeaderBytes header: Int
    ) throws -> [UInt8] {
        guard nal.count > header else { throw BitstreamError.emptyNALUnit }
        guard nal.count <= 65536 else { throw BitstreamError.tooLarge(bytes: nal.count) }
        var out = [UInt8]()
        out.reserveCapacity(nal.count - header)
        var zeroRun = 0
        var i = header
        let n = nal.count
        while i < n {
            let b = nal[i]
            if zeroRun >= 2 && b == 0x03 {
                let isLast = (i + 1 == n)
                if isLast || nal[i + 1] <= 0x03 {
                    zeroRun = 0
                    i += 1
                    continue                          // drop the emulation-prevention byte
                }
            }
            out.append(b)
            zeroRun = (b == 0x00) ? zeroRun + 1 : 0
            i += 1
        }
        guard !out.isEmpty else { throw BitstreamError.emptyNALUnit }
        return out
    }

    /// Inverse: inserts emulation-prevention bytes. Used only by test fixtures and by the
    /// debug bitstream writer. Never on the receive path.
    public static func escape(_ rbsp: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(rbsp.count + rbsp.count / 64 + 4)
        var zeroRun = 0
        for b in rbsp {
            if zeroRun >= 2 && b <= 0x03 {
                out.append(0x03)
                zeroRun = 0
            }
            out.append(b)
            zeroRun = (b == 0x00) ? zeroRun + 1 : 0
        }
        return out
    }
}
```

Verified round trips (`escape` then `unescape` is the identity):

| RBSP bytes | On the wire (escaped) |
|---|---|
| `00 00 00 01` | `00 00 03 00 01` |
| `00 00 00` | `00 00 03 00` |
| `00 00 00 00 00` | `00 00 03 00 00 03 00` |
| `67 64 00 28 00 00 01` | `67 64 00 28 00 00 03 01` |
| `00 03` | `00 03` (unchanged — only one leading zero) |
| `00 00 03` | `00 00 03 03` |
| `00 00 03 00` | `00 00 03 03 00` |

And unescaping direction only:

| On the wire | RBSP |
|---|---|
| `00 00 03 00` | `00 00 00` |
| `00 00 03 00 00 00 03 00` | `00 00 00 00 00 00` |
| `65 88 84 04 BF 00 00 03 01` | `65 88 84 04 BF 00 00 01` |

**Cost note.** Unescaping allocates. That is acceptable because we unescape *only* parameter sets
and SEI NALs — a few hundred bytes, a few times per GOP. We never unescape slice data. The
per-frame "is this the first slice of the picture" test (§20.1) is a single byte read with no
unescaping at all, and its safety is proved there.

---

## 7. `BitReader` and `RBSPBitReader`

`VigilProtocols` owns the raw MSB-first bit reader. Its API is fixed here because `VigilBitstream`
is its principal consumer; the architecture spec must adopt this signature verbatim.

```swift
// VigilProtocols/BitReader.swift
public struct BitReader: Sendable {
    public let bytes: [UInt8]
    public private(set) var bitOffset: Int
    private let totalBits: Int

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.bitOffset = 0
        self.totalBits = bytes.count * 8
    }

    @inlinable public var bitsRemaining: Int { totalBits - bitOffset }
    @inlinable public var isByteAligned: Bool { bitOffset & 7 == 0 }
    @inlinable public var bytePosition: Int { bitOffset >> 3 }

    /// Reads `n` in 0...32 bits, MSB first.
    public mutating func u(_ n: Int) throws -> UInt32 {
        precondition(n >= 0 && n <= 32, "BitReader.u supports 0...32 bits")
        if n == 0 { return 0 }
        guard bitOffset + n <= totalBits else {
            throw BitstreamError.unexpectedEndOfData(atBit: bitOffset)
        }
        var result: UInt32 = 0
        var remaining = n
        while remaining > 0 {
            let byteIndex = bitOffset >> 3
            let bitInByte = bitOffset & 7
            let available = 8 - bitInByte
            let take = min(available, remaining)
            let byte = UInt32(bytes[byteIndex])
            let shifted = byte >> UInt32(available - take)
            let mask: UInt32 = (1 << UInt32(take)) - 1        // take <= 8, no overflow
            result = (result << UInt32(take)) | (shifted & mask)
            bitOffset += take
            remaining -= take
        }
        return result
    }

    /// Reads `n` in 0...64 bits. Required for `general_constraint_indicator_flags` (48 bits).
    public mutating func u64(_ n: Int) throws -> UInt64 {
        precondition(n >= 0 && n <= 64)
        if n <= 32 { return UInt64(try u(n)) }
        let high = try u(n - 32)
        let low  = try u(32)
        return (UInt64(high) << 32) | UInt64(low)
    }

    @inlinable public mutating func flag() throws -> Bool { try u(1) == 1 }

    public mutating func skip(_ n: Int) throws {
        guard n >= 0 else { throw BitstreamError.negativeSkip }
        guard bitOffset + n <= totalBits else {
            throw BitstreamError.unexpectedEndOfData(atBit: bitOffset)
        }
        bitOffset += n
    }

    /// Discards bits up to the next byte boundary. Does not validate their value.
    public mutating func alignToByte() { bitOffset = (bitOffset + 7) & ~7 }

    /// Peeks without advancing.
    public func peek(_ n: Int) throws -> UInt32 { var c = self; return try c.u(n) }
}
```

`RBSPBitReader` adds emulation-prevention removal, Exp-Golomb, and `more_rbsp_data()`:

```swift
// VigilBitstream/RBSPBitReader.swift
public struct RBSPBitReader: Sendable {
    private var reader: BitReader
    /// Bit index of the `rbsp_stop_one_bit`, i.e. of the last set bit in the buffer.
    /// Computed once at init; -1 when the buffer is all zeros (malformed).
    private let stopBitIndex: Int

    /// `nal` includes the NAL header. Unescapes and positions at the first RBSP bit.
    public init(nalUnit nal: UnsafeRawBufferPointer, codec: VideoCodec) throws {
        try self.init(rbsp: RBSP.unescape(nal, skippingHeaderBytes: codec.nalHeaderLength))
    }

    /// For already-unescaped payloads (SEI payloads, test fixtures).
    public init(rbsp: [UInt8]) throws {
        guard !rbsp.isEmpty else { throw BitstreamError.emptyNALUnit }
        self.reader = BitReader(rbsp)
        var idx = rbsp.count * 8 - 1
        var found = -1
        while idx >= 0 {
            let byte = rbsp[idx >> 3]
            if byte != 0 {
                // Scan the bits of this byte from LSB up.
                if (byte >> (7 - UInt8(idx & 7))) & 1 == 1 { found = idx; break }
                idx -= 1
            } else {
                idx -= (idx & 7) + 1                 // skip the whole zero byte
            }
        }
        self.stopBitIndex = found
    }

    // ---- pass-through surface ----
    @inlinable public var bitOffset: Int { reader.bitOffset }
    @inlinable public var bitsRemaining: Int { reader.bitsRemaining }
    @inlinable public var isByteAligned: Bool { reader.isByteAligned }
    @inlinable public mutating func u(_ n: Int) throws -> UInt32 { try reader.u(n) }
    @inlinable public mutating func u64(_ n: Int) throws -> UInt64 { try reader.u64(n) }
    @inlinable public mutating func flag() throws -> Bool { try reader.flag() }
    @inlinable public mutating func skip(_ n: Int) throws { try reader.skip(n) }
    @inlinable public mutating func alignToByte() { reader.alignToByte() }

    // ---- Exp-Golomb ----

    /// ue(v) — unsigned Exp-Golomb, H.264 §9.1 / H.265 §9.2.
    /// Reads `leadingZeroBits` zeros, then a `1`, then that many suffix bits.
    /// codeNum = 2^lz - 1 + suffix.
    public mutating func ue() throws -> UInt32 {
        var leadingZeros = 0
        while true {
            guard reader.bitsRemaining > 0 else {
                throw BitstreamError.unexpectedEndOfData(atBit: reader.bitOffset)
            }
            if try reader.u(1) == 1 { break }
            leadingZeros += 1
            if leadingZeros > 32 { throw BitstreamError.malformedExpGolomb(leadingZeros: leadingZeros) }
        }
        if leadingZeros == 0 { return 0 }
        let suffix = try reader.u64(leadingZeros)
        let value = (UInt64(1) << UInt64(leadingZeros)) - 1 + suffix
        guard value <= UInt64(UInt32.max) else {
            throw BitstreamError.malformedExpGolomb(leadingZeros: leadingZeros)
        }
        return UInt32(value)
    }

    /// se(v) — signed Exp-Golomb, H.264 §9.1.1.
    /// k = ue(); value = (-1)^(k+1) * ceil(k / 2), i.e. odd k -> positive, even k -> negative.
    public mutating func se() throws -> Int32 {
        let k = try ue()
        guard k < UInt32.max else { throw BitstreamError.malformedExpGolomb(leadingZeros: 32) }
        let magnitude = Int64((UInt64(k) + 1) / 2)
        let signed = (k & 1) == 1 ? magnitude : -magnitude
        guard signed >= Int64(Int32.min), signed <= Int64(Int32.max) else {
            throw BitstreamError.valueOutOfRange(field: "se(v)", value: UInt64(k))
        }
        return Int32(signed)
    }

    /// Convenience readers that range-check in one step.
    public mutating func ue(_ field: String, max: UInt32) throws -> UInt32 {
        let v = try ue()
        guard v <= max else { throw BitstreamError.valueOutOfRange(field: field, value: UInt64(v)) }
        return v
    }

    /// more_rbsp_data() — H.264 §7.2. True iff there is at least one bit before the
    /// rbsp_stop_one_bit. O(1): `stopBitIndex` was precomputed.
    public func moreRBSPData() -> Bool {
        guard stopBitIndex >= 0 else { return false }
        return reader.bitOffset < stopBitIndex
    }

    /// Validates rbsp_trailing_bits(): a single `1` then zeros to the byte boundary.
    /// Called at the end of a parse in DEBUG builds only; a mismatch is logged, never fatal,
    /// because it is the single most common firmware nonconformance and is harmless to us.
    public mutating func checkRBSPTrailingBits() -> Bool {
        guard (try? reader.u(1)) == 1 else { return false }
        while !reader.isByteAligned {
            guard (try? reader.u(1)) == 0 else { return false }
        }
        return true
    }
}
```

### 7.1 Exp-Golomb reference values (test table T-EG-1)

| Bit string | `ue(v)` | `se(v)` |
|---|---:|---:|
| `1` | 0 | 0 |
| `010` | 1 | +1 |
| `011` | 2 | −1 |
| `00100` | 3 | +2 |
| `00101` | 4 | −2 |
| `00110` | 5 | +3 |
| `00111` | 6 | −3 |
| `0001000` | 7 | +4 |
| `0001111` | 14 | −7 |
| 32 zeros then `1` then 32 ones | throws `.malformedExpGolomb` | throws |

---

## 8. H.264 SPS — full parse (ITU-T H.264 §7.3.2.1)

The set of `profile_idc` values that carry the chroma/bit-depth/scaling-list block is:

```swift
@inlinable
static func h264ProfileHasChromaExtension(_ profileIDC: UInt8) -> Bool {
    switch profileIDC {
    case 100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135: return true
    default: return false
    }
}
```

**Do not confuse this list with the `avcC` trailing-extension condition, which is the different
and shorter set {100, 110, 122, 144}** (§16.2). Getting these two mixed up is the classic avcC bug.

### 8.1 Syntax, in order

| Field | Descriptor | Notes |
|---|---|---|
| `profile_idc` | u(8) | |
| `constraint_set0_flag` … `constraint_set5_flag` | u(1) × 6 | packed into one `UInt8` for `avcC` byte 2 |
| `reserved_zero_2bits` | u(2) | value ignored |
| `level_idc` | u(8) | |
| `seq_parameter_set_id` | ue(v) | 0…31 |
| **if** `h264ProfileHasChromaExtension(profile_idc)` | | |
|  `chroma_format_idc` | ue(v) | 0…3, default 1 |
|  **if** `chroma_format_idc == 3`: `separate_colour_plane_flag` | u(1) | |
|  `bit_depth_luma_minus8` | ue(v) | 0…8 |
|  `bit_depth_chroma_minus8` | ue(v) | 0…8 |
|  `qpprime_y_zero_transform_bypass_flag` | u(1) | ignored |
|  `seq_scaling_matrix_present_flag` | u(1) | |
|  **if** set: `seq_scaling_list_present_flag[i]` u(1) for `i` in `0..<count`, and `scaling_list()` when set | | `count = (chroma_format_idc != 3) ? 8 : 12` |
| `log2_max_frame_num_minus4` | ue(v) | 0…12 |
| `pic_order_cnt_type` | ue(v) | 0…2 |
| **if** `== 0`: `log2_max_pic_order_cnt_lsb_minus4` | ue(v) | 0…12 |
| **else if** `== 1`: `delta_pic_order_always_zero_flag` | u(1) | |
|  `offset_for_non_ref_pic` | se(v) | |
|  `offset_for_top_to_bottom_field` | se(v) | |
|  `num_ref_frames_in_pic_order_cnt_cycle` | ue(v) | 0…255 |
|  `offset_for_ref_frame[i]` | se(v) × N | |
| `max_num_ref_frames` | ue(v) | 0…16 |
| `gaps_in_frame_num_value_allowed_flag` | u(1) | |
| `pic_width_in_mbs_minus1` | ue(v) | |
| `pic_height_in_map_units_minus1` | ue(v) | |
| `frame_mbs_only_flag` | u(1) | |
| **if** `== 0`: `mb_adaptive_frame_field_flag` | u(1) | |
| `direct_8x8_inference_flag` | u(1) | |
| `frame_cropping_flag` | u(1) | |
| **if** set: `frame_crop_left/right/top/bottom_offset` | ue(v) × 4 | |
| `vui_parameters_present_flag` | u(1) | |
| **if** set: `vui_parameters()` | | §8.4 — parsed leniently |
| `rbsp_trailing_bits()` | | checked in DEBUG only |

### 8.2 `scaling_list()` — the skip loop (H.264 §7.3.2.1.1.1)

This is the loop that must be correct or every subsequent field is garbage. The termination
condition is subtle: once `nextScale` becomes 0 the remaining `delta_scale` values are **not
present** and must not be read.

```swift
/// Consumes exactly the bits of one scaling_list(sizeOfScalingList).
/// We discard the coefficients — VideoToolbox re-parses the SPS itself — but the bit
/// consumption must be exact.
private static func skipScalingList(_ r: inout RBSPBitReader, size: Int) throws {
    var lastScale: Int32 = 8
    var nextScale: Int32 = 8
    for _ in 0 ..< size {
        if nextScale != 0 {
            let deltaScale = try r.se()
            guard deltaScale >= -128 && deltaScale <= 127 else {
                throw BitstreamError.valueOutOfRange(field: "delta_scale", value: UInt64(bitPattern: Int64(deltaScale)))
            }
            nextScale = (lastScale + deltaScale + 256) % 256
            // useDefaultScalingMatrixFlag = (j == 0 && nextScale == 0) — irrelevant to bit count.
        }
        lastScale = (nextScale == 0) ? lastScale : nextScale
    }
}

// call site
if seqScalingMatrixPresent {
    let listCount = (chromaFormatIDC != 3) ? 8 : 12
    for i in 0 ..< listCount where try r.flag() {
        try skipScalingList(&r, size: i < 6 ? 16 : 64)
    }
}
```

Note the `for … where try r.flag()` form reads `seq_scaling_list_present_flag[i]` exactly once per
iteration, including when it is false — that is required.

### 8.3 `hrd_parameters()` — the skip (H.264 §E.1.2)

Needed only to reach `pic_struct_present_flag` and `bitstream_restriction_flag`. Bit-exact:

```swift
private static func skipHRDParameters(_ r: inout RBSPBitReader) throws {
    let cpbCnt = Int(try r.ue("cpb_cnt_minus1", max: 31)) + 1
    try r.skip(4)                                  // bit_rate_scale
    try r.skip(4)                                  // cpb_size_scale
    for _ in 0 ..< cpbCnt {
        _ = try r.ue()                             // bit_rate_value_minus1[i]
        _ = try r.ue()                             // cpb_size_value_minus1[i]
        try r.skip(1)                              // cbr_flag[i]
    }
    try r.skip(5)                                  // initial_cpb_removal_delay_length_minus1
    try r.skip(5)                                  // cpb_removal_delay_length_minus1
    try r.skip(5)                                  // dpb_output_delay_length_minus1
    try r.skip(5)                                  // time_offset_length
}
```

We *retain* `initial_cpb_removal_delay_length_minus1`, `cpb_removal_delay_length_minus1` and
`dpb_output_delay_length_minus1` in `H264SPS` (as `cpbRemovalDelayLength` etc.) because
`pic_timing` SEI parsing needs them (§19.3). `nalHRDPresent || vclHRDPresent` is stored as
`cpbDpbDelaysPresentFlag`.

### 8.4 `vui_parameters()` (H.264 §E.1.1) — parsed leniently

```swift
private static func parseVUI(_ r: inout RBSPBitReader, into sps: inout H264SPS) throws {
    if try r.flag() {                                      // aspect_ratio_info_present_flag
        let idc = UInt8(try r.u(8))
        sps.aspectRatioIDC = idc
        if idc == 255 {                                    // Extended_SAR
            let w = try r.u(16), h = try r.u(16)
            sps.sarWidth = Int(w); sps.sarHeight = Int(h)
        } else if let table = SampleAspectRatio.table[idc] {
            sps.sarWidth = table.0; sps.sarHeight = table.1
        }                                                  // reserved idc -> leave 1:1
    }
    if try r.flag() { try r.skip(1) }                      // overscan_appropriate_flag
    if try r.flag() {                                      // video_signal_type_present_flag
        sps.videoFormat = UInt8(try r.u(3))
        sps.videoFullRangeFlag = try r.flag()
        if try r.flag() {                                  // colour_description_present_flag
            sps.colourPrimaries = UInt8(try r.u(8))
            sps.transferCharacteristics = UInt8(try r.u(8))
            sps.matrixCoefficients = UInt8(try r.u(8))
        }
    }
    if try r.flag() {                                      // chroma_loc_info_present_flag
        _ = try r.ue(); _ = try r.ue()
    }
    if try r.flag() {                                      // timing_info_present_flag
        let numUnitsInTick = try r.u(32)
        let timeScale = try r.u(32)
        sps.fixedFrameRateFlag = try r.flag()
        sps.numUnitsInTick = numUnitsInTick
        sps.timeScale = timeScale
    }
    let nalHRD = try r.flag()
    if nalHRD { try skipHRDParameters(&r) }
    let vclHRD = try r.flag()
    if vclHRD { try skipHRDParameters(&r) }
    sps.cpbDpbDelaysPresentFlag = nalHRD || vclHRD
    if nalHRD || vclHRD { sps.lowDelayHRDFlag = try r.flag() }
    sps.picStructPresentFlag = try r.flag()
    if try r.flag() {                                      // bitstream_restriction_flag
        try r.skip(1)                                      // motion_vectors_over_pic_boundaries_flag
        _ = try r.ue()                                     // max_bytes_per_pic_denom
        _ = try r.ue()                                     // max_bits_per_mb_denom
        _ = try r.ue()                                     // log2_max_mv_length_horizontal
        _ = try r.ue()                                     // log2_max_mv_length_vertical
        sps.maxNumReorderFrames = Int(try r.ue("max_num_reorder_frames", max: 32))
        sps.maxDecFrameBuffering = Int(try r.ue("max_dec_frame_buffering", max: 32))
    }
}
```

**Lenient-VUI rule (binding).** The caller wraps `parseVUI` in a nested `do/catch`:

```swift
if vuiPresent {
    sps.vuiPresent = true
    do { try parseVUI(&r, into: &sps) }
    catch { sps.vuiParseFailed = true; logger.notice("SPS VUI truncated/malformed, keeping partial metadata") }
}
```

A VUI failure **never** fails the SPS parse. Rationale: several Hikvision firmware revisions emit a
VUI whose HRD section does not match §E.1.2, and the fields we already recovered before the failure
(SAR, timing, colour) are still valid because the parse is strictly sequential. Everything after
the failure point falls back to its default. The mandatory prefix (everything in §8.1 above
`vui_parameters_present_flag`) is parsed **strictly** — a failure there is a real error.

### 8.5 `aspect_ratio_idc` table (H.264 Table E-1 / H.265 Table E-1, identical)

```swift
public enum SampleAspectRatio {
    /// idc -> (sarWidth, sarHeight). idc 0 = Unspecified (we substitute 1:1).
    /// idc 255 = Extended_SAR, read from the bitstream. 17...254 reserved (we substitute 1:1).
    public static let table: [UInt8: (Int, Int)] = [
        1: (1, 1),    2: (12, 11),  3: (10, 11),  4: (16, 11),
        5: (40, 33),  6: (24, 11),  7: (20, 11),  8: (32, 11),
        9: (80, 33), 10: (18, 11), 11: (15, 11), 12: (64, 33),
       13: (160, 99),14: (4, 3),   15: (3, 2),   16: (2, 1),
    ]
}
```

**SAR sanity rule:** if either component is 0, or `aspect_ratio_info_present_flag` is 0, or the idc
is reserved, use **1:1**. Hikvision routinely omits the SAR entirely on substreams.

### 8.6 Derivation — exact width, height, SAR, fps

```swift
// Chroma subsampling (H.264 Table 6-1)
// chroma_format_idc: 0 monochrome, 1 = 4:2:0, 2 = 4:2:2, 3 = 4:4:4
static func subSampling(_ chromaFormatIDC: UInt8, separateColourPlane: Bool) -> (subWidthC: Int, subHeightC: Int) {
    if separateColourPlane { return (1, 1) }
    switch chromaFormatIDC {
    case 1:  return (2, 2)
    case 2:  return (2, 1)
    case 3:  return (1, 1)
    default: return (1, 1)          // monochrome: SubWidthC/SubHeightC undefined, unused
    }
}
```

```
ChromaArrayType      = separate_colour_plane_flag ? 0 : chroma_format_idc
PicWidthInMbs        = pic_width_in_mbs_minus1 + 1
PicWidthInSamplesL   = PicWidthInMbs * 16
FrameHeightInMbs     = (2 - frame_mbs_only_flag) * (pic_height_in_map_units_minus1 + 1)
FrameHeightInSamplesL= FrameHeightInMbs * 16

CropUnitX = (ChromaArrayType == 0) ? 1 : SubWidthC
CropUnitY = (ChromaArrayType == 0) ? (2 - frame_mbs_only_flag)
                                   : SubHeightC * (2 - frame_mbs_only_flag)

displayWidth  = PicWidthInSamplesL    - CropUnitX * (frame_crop_left_offset + frame_crop_right_offset)
displayHeight = FrameHeightInSamplesL - CropUnitY * (frame_crop_top_offset  + frame_crop_bottom_offset)
```

The two cases that matter in practice:

| Case | `frame_mbs_only_flag` | `ChromaArrayType` | CropUnitX | CropUnitY |
|---|---:|---:|---:|---:|
| 4:2:0 progressive (all Hikvision live streams) | 1 | 1 | 2 | 2 |
| 4:2:0 interlaced / MBAFF (some analogue-input DVRs) | 0 | 1 | 2 | **4** |
| Monochrome progressive | 1 | 0 | 1 | 1 |

The 1080p case: `pic_height_in_map_units_minus1 = 67` → 68 map units → 1088 coded luma rows.
`frame_crop_bottom_offset = 4`, `CropUnitY = 2` → `1088 − 2·4 = 1080`. **Never** report 1088 to the
UI, to the renderer, or to the recorder; always report the cropped 1080. But **always** allocate
decoder surfaces from the *coded* size — VideoToolbox handles the crop via the format description's
`CleanAperture`, and `VigilRender` must read the display size from `VideoFormatInfo`, not from
`CVPixelBufferGetHeight`.

**Frame rate.**
```
fps_H264 = time_scale / (2 * num_units_in_tick)
```
The factor 2 is because H.264 `time_scale` counts *field* ticks. `num_units_in_tick = 1,
time_scale = 50` ⇒ 25.0 fps. A `fixed_frame_rate_flag` of 0 does not invalidate the value; it only
means the encoder does not guarantee constant spacing.

**fps fallback chain (binding order):**
1. VUI `timing_info` per the formula above, accepted only if `num_units_in_tick > 0` and the result
   is in `[1.0, 240.0]`.
2. The measured fps EWMA from `VigilRTP.StreamStatistics` once ≥ 2 s of packets have arrived.
3. ISAPI `<maxFrameRate>` ÷ 100 from `VigilISAPI` (Hikvision reports centi-fps, e.g. `2500`).
4. Literal `25.0`.

**Binding decision:** the parsed fps is **metadata only**. It feeds the `hvcC` `avgFrameRate` field,
the UI overlay, the recorder's fallback duration, and the decode-budget cost function in
`VigilVideo`. It must **never** drive the presentation clock — RTP timestamps do that. Vigil has no
"assume 25 fps and increment PTS" code path anywhere.

### 8.7 Profile and level naming

```swift
public static func h264ProfileName(_ idc: UInt8, constraintFlags: UInt8) -> String {
    let cs1 = constraintFlags & 0b0100_0000 != 0        // constraint_set1_flag
    switch idc {
    case 66:  return cs1 ? "Constrained Baseline" : "Baseline"
    case 77:  return "Main"
    case 88:  return "Extended"
    case 100: return "High"
    case 110: return "High 10"
    case 122: return "High 4:2:2"
    case 244: return "High 4:4:4 Predictive"
    case 44:  return "CAVLC 4:4:4 Intra"
    default:  return "Unknown (\(idc))"
    }
}
```

`constraintFlags` is the single byte formed as `cs0<<7 | cs1<<6 | … | cs5<<2` — i.e. exactly
**byte 2 of the SPS NAL**, which is also exactly `avcC.profile_compatibility`. Store it as that byte
and never as six `Bool`s; that removes any chance of a bit-order mistake in `avcC`.

| `level_idc` | Name | | `level_idc` | Name |
|---:|---|---|---:|---|
| 9 or 11 with `cs3` | **1b** | | 40 | 4.0 |
| 10 | 1.0 | | 41 | 4.1 |
| 11 | 1.1 | | 42 | 4.2 |
| 12 | 1.2 | | 50 | 5.0 |
| 13 | 1.3 | | 51 | 5.1 |
| 20 | 2.0 | | 52 | 5.2 |
| 21 | 2.1 | | 60 | 6.0 |
| 22 | 2.2 | | 61 | 6.1 |
| 30 | 3.0 | | 62 | 6.2 |
| 31 | 3.1 | | | |
| 32 | 3.2 | | | |

`constraint_set3_flag` is bit `0b0001_0000` of the constraint byte. Level "1b" only exists for
Baseline/Main/Extended.

---

## 9. H.264 PPS — the minimal parse, and what we skip

### 9.1 What we parse and why

| Field | Descriptor | Why we need it |
|---|---|---|
| `pic_parameter_set_id` | ue(v) | keying the store; a slice references it |
| `seq_parameter_set_id` | ue(v) | binds this PPS to an SPS; mismatch ⇒ we hold an orphan PPS and must wait |
| `entropy_coding_mode_flag` | u(1) | CABAC vs CAVLC — diagnostics overlay and a decode-cost weight input |
| `bottom_field_pic_order_in_frame_present_flag` | u(1) | required to parse a slice header past `pic_order_cnt_lsb`; we keep it so recorded-playback POC reordering in `VigilVideo` is possible without re-parsing |
| `num_slice_groups_minus1` | ue(v) | must be 0; see §9.2 |
| `num_ref_idx_l0/l1_default_active_minus1` | ue(v) ×2 | slice-header parse prerequisite |
| `weighted_pred_flag`, `weighted_bipred_idc` | u(1), u(2) | slice-header parse prerequisite |
| `pic_init_qp_minus26` | se(v) | QP overlay in the diagnostics HUD |
| `pic_init_qs_minus26`, `chroma_qp_index_offset` | se(v) ×2 | consumed to stay aligned |
| `deblocking_filter_control_present_flag` | u(1) | slice-header parse prerequisite |
| `constrained_intra_pred_flag` | u(1) | consumed |
| `redundant_pic_cnt_present_flag` | u(1) | slice-header parse prerequisite |
| **if** `more_rbsp_data()`: `transform_8x8_mode_flag` | u(1) | High-profile marker, diagnostics |

We stop after `transform_8x8_mode_flag`. Everything beyond it —
`pic_scaling_matrix_present_flag`, the scaling lists, `second_chroma_qp_index_offset` — is
**deliberately not parsed**.

### 9.2 What we skip and why (explicit)

| Skipped | Why it is safe |
|---|---|
| `slice_group_map_type` and the whole FMO/ASO block | Only reachable when `num_slice_groups_minus1 > 0`. FMO exists in Baseline profile only and **no Hikvision or Dahua encoder has ever been observed to emit it**; H.264 High/Main forbid it. If we see a non-zero value we set `pps.usesSliceGroups = true`, abandon the remainder of the parse, and keep the PPS **bytes** for pass-through. Decode still works because VideoToolbox parses the PPS itself. |
| `pic_scaling_matrix_present_flag` + scaling lists | We never reconstruct scaling matrices; VideoToolbox does. Parsing them would only be needed to reach `second_chroma_qp_index_offset`, which we do not use. |
| `second_chroma_qp_index_offset` | Diagnostics only; not worth the scaling-list skip loop. |

**The load-bearing principle:** we parse a PPS for *metadata and store keying*, never for decode.
The decoder receives the original PPS bytes. A PPS whose parse throws is still stored and still
forwarded (§10, §21). This is why the "minimal parse" is legitimate rather than lazy.

### 9.3 Verified PPS vectors

| Vector | Base64 | Hex | Parse |
|---|---|---|---|
| P1 (Main, CABAC) | `aO48gA==` | `68 EE 3C 80` | pps_id 0, sps_id 0, CABAC, `more_rbsp_data() == false` |
| P2 (High, CABAC, 8×8) | `aO48sA==` | `68 EE 3C B0` | pps_id 0, sps_id 0, CABAC, `more_rbsp_data() == true`, `transform_8x8_mode_flag == 1` |

P1/P2 differ in one byte and are the canonical regression pair for `moreRBSPData()`: in P1 the RBSP
is `EE 3C 80`, the stop bit is at bit index 16, and the reader sits at bit 16 after
`redundant_pic_cnt_present_flag` ⇒ `16 < 16` is false ⇒ no more data. In P2 the RBSP is
`EE 3C B0`, the last set bit is at index 19, so `16 < 19` ⇒ more data, and the three remaining
bits are `transform_8x8_mode_flag = 1`, `pic_scaling_matrix_present_flag = 0`,
`second_chroma_qp_index_offset = se(1) = 0`.

---

## 10. Parsed-model Swift types

```swift
public struct H264SPS: Sendable, Hashable, Codable {
    // raw
    public var profileIDC: UInt8
    public var constraintFlags: UInt8            // == SPS NAL byte 2 == avcC profile_compatibility
    public var levelIDC: UInt8
    public var seqParameterSetID: UInt32
    public var chromaFormatIDC: UInt8 = 1
    public var separateColourPlaneFlag = false
    public var bitDepthLuma = 8
    public var bitDepthChroma = 8
    public var seqScalingMatrixPresent = false
    public var log2MaxFrameNum: Int              // = minus4 + 4
    public var picOrderCntType: UInt8
    public var log2MaxPicOrderCntLsb: Int?       // poc type 0
    public var deltaPicOrderAlwaysZeroFlag = false          // poc type 1
    public var offsetForNonRefPic: Int32 = 0
    public var offsetForTopToBottomField: Int32 = 0
    public var offsetForRefFrame: [Int32] = []
    public var maxNumRefFrames: Int
    public var gapsInFrameNumValueAllowed = false
    public var picWidthInMbs: Int
    public var picHeightInMapUnits: Int
    public var frameMbsOnlyFlag = true
    public var mbAdaptiveFrameFieldFlag = false
    public var direct8x8InferenceFlag = false
    public var frameCropping: (left: Int, right: Int, top: Int, bottom: Int) = (0, 0, 0, 0)
    // VUI
    public var vuiPresent = false
    public var vuiParseFailed = false
    public var aspectRatioIDC: UInt8?
    public var sarWidth = 1
    public var sarHeight = 1
    public var videoFormat: UInt8?
    public var videoFullRangeFlag = false
    public var colourPrimaries: UInt8?
    public var transferCharacteristics: UInt8?
    public var matrixCoefficients: UInt8?
    public var numUnitsInTick: UInt32?
    public var timeScale: UInt32?
    public var fixedFrameRateFlag = false
    public var cpbDpbDelaysPresentFlag = false
    public var cpbRemovalDelayLength = 24
    public var dpbOutputDelayLength = 24
    public var lowDelayHRDFlag = false
    public var picStructPresentFlag = false
    public var maxNumReorderFrames = 0
    public var maxDecFrameBuffering = 0

    // derived (computed once at parse time, stored)
    public var chromaArrayType: UInt8 { separateColourPlaneFlag ? 0 : chromaFormatIDC }
    public var codedWidth: Int { picWidthInMbs * 16 }
    public var codedHeight: Int { (frameMbsOnlyFlag ? 1 : 2) * picHeightInMapUnits * 16 }
    public var displayWidth: Int { get }
    public var displayHeight: Int { get }
    public var frameRate: Double? { get }
    public var isProgressive: Bool { frameMbsOnlyFlag }
}

public struct H264PPS: Sendable, Hashable, Codable {
    public var picParameterSetID: UInt32
    public var seqParameterSetID: UInt32
    public var entropyCodingModeFlag: Bool          // true = CABAC
    public var bottomFieldPicOrderInFramePresentFlag: Bool
    public var usesSliceGroups: Bool                // num_slice_groups_minus1 > 0 -> partial parse
    public var numRefIdxL0DefaultActive: Int
    public var numRefIdxL1DefaultActive: Int
    public var weightedPredFlag: Bool
    public var weightedBipredIDC: UInt8
    public var picInitQP: Int
    public var deblockingFilterControlPresentFlag: Bool
    public var constrainedIntraPredFlag: Bool
    public var redundantPicCntPresentFlag: Bool
    public var transform8x8ModeFlag: Bool
}
```

The parser entry points:

```swift
public enum H264Parser {
    /// `nal` includes the 1-byte NAL header. Throws `.wrongNALType` unless type == 7.
    public static func parseSPS(_ nal: UnsafeRawBufferPointer) throws -> H264SPS
    public static func parsePPS(_ nal: UnsafeRawBufferPointer) throws -> H264PPS
    /// Convenience for SDP `sprop-parameter-sets`.
    public static func parseSPS(base64: String) throws -> H264SPS
}
```

---

## 11. H.265 `profile_tier_level()` (ITU-T H.265 §7.3.3)

This is the field that most third-party parsers get wrong, and it is the direct source of ten bytes
of `hvcC`. Bit-exact layout for `profile_tier_level(profilePresentFlag = 1, maxNumSubLayersMinus1)`:

| Field | Bits | Cumulative |
|---|---:|---:|
| `general_profile_space` | 2 | 2 |
| `general_tier_flag` | 1 | 3 |
| `general_profile_idc` | 5 | 8 |
| `general_profile_compatibility_flag[0..31]` | 32 | 40 |
| `general_progressive_source_flag` | 1 | 41 |
| `general_interlaced_source_flag` | 1 | 42 |
| `general_non_packed_constraint_flag` | 1 | 43 |
| `general_frame_only_constraint_flag` | 1 | 44 |
| reserved / RExt constraint flags | 43 | 87 |
| `general_inbld_flag` or `general_reserved_zero_bit` | 1 | 88 |
| `general_level_idc` | 8 | 96 |

So the region from `general_progressive_source_flag` through the `inbld`/reserved bit is exactly
**48 bits = 6 bytes**, and it starts on a byte boundary (bit 40). That 6-byte region *is*
`hvcC.general_constraint_indicator_flags`, verbatim. We therefore read it as a single
`u64(48)` and re-emit it big-endian — no bit shuffling, no chance of error.

Then, for sub-layers:

| Field | Bits |
|---|---|
| `sub_layer_profile_present_flag[i]`, `sub_layer_level_present_flag[i]` for `i in 0..<maxNumSubLayersMinus1` | 2 each |
| **if** `maxNumSubLayersMinus1 > 0`: `reserved_zero_2bits[i]` for `i in maxNumSubLayersMinus1..<8` | 2 each |
| for `i in 0..<maxNumSubLayersMinus1`: **if** `sub_layer_profile_present_flag[i]` → 88 bits (same layout as general, minus `general_level_idc`) | 88 |
| … **if** `sub_layer_level_present_flag[i]` → `sub_layer_level_idc[i]` | 8 |

The `reserved_zero_2bits` padding loop runs from `maxNumSubLayersMinus1` to 7 inclusive — that is
`8 - maxNumSubLayersMinus1` iterations, and it is **absent entirely** when
`maxNumSubLayersMinus1 == 0`. Omitting the condition, or looping the wrong number of times, shifts
everything after it and yields a nonsense `pic_width_in_luma_samples`. Hikvision emits
`sps_max_sub_layers_minus1 = 0` for live streams and `1` on some NVR transcoded streams, so both
paths are reachable in production.

```swift
public struct ProfileTierLevel: Sendable, Hashable, Codable {
    public var generalProfileSpace: UInt8            // 2 bits
    public var generalTierFlag: UInt8                // 1 bit: 0 = Main tier, 1 = High tier
    public var generalProfileIDC: UInt8              // 5 bits
    public var generalProfileCompatibilityFlags: UInt32   // 32 bits, bit 31 == flag[0]
    public var generalConstraintIndicatorFlags: UInt64    // 48 bits, right-aligned
    public var generalLevelIDC: UInt8
    public var subLayerLevelIDC: [UInt8?]

    public var progressiveSourceFlag: Bool  { generalConstraintIndicatorFlags & (1 << 47) != 0 }
    public var interlacedSourceFlag: Bool   { generalConstraintIndicatorFlags & (1 << 46) != 0 }
    public var nonPackedConstraintFlag: Bool{ generalConstraintIndicatorFlags & (1 << 45) != 0 }
    public var frameOnlyConstraintFlag: Bool{ generalConstraintIndicatorFlags & (1 << 44) != 0 }

    /// The 6 bytes to place in hvcC, big-endian, most significant first.
    public var constraintIndicatorBytes: [UInt8] {
        (0..<6).map { UInt8(truncatingIfNeeded: generalConstraintIndicatorFlags >> UInt64(40 - 8 * $0)) }
    }
}

static func parseProfileTierLevel(
    _ r: inout RBSPBitReader, maxNumSubLayersMinus1: Int
) throws -> ProfileTierLevel {
    var ptl = ProfileTierLevel(
        generalProfileSpace: UInt8(try r.u(2)),
        generalTierFlag: UInt8(try r.u(1)),
        generalProfileIDC: UInt8(try r.u(5)),
        generalProfileCompatibilityFlags: try r.u(32),
        generalConstraintIndicatorFlags: try r.u64(48),
        generalLevelIDC: UInt8(try r.u(8)),
        subLayerLevelIDC: []
    )
    guard maxNumSubLayersMinus1 <= 6 else {
        throw BitstreamError.valueOutOfRange(field: "sps_max_sub_layers_minus1",
                                             value: UInt64(maxNumSubLayersMinus1))
    }
    var profilePresent = [Bool](); var levelPresent = [Bool]()
    for _ in 0 ..< maxNumSubLayersMinus1 {
        profilePresent.append(try r.flag())
        levelPresent.append(try r.flag())
    }
    if maxNumSubLayersMinus1 > 0 {
        try r.skip(2 * (8 - maxNumSubLayersMinus1))      // reserved_zero_2bits[i]
    }
    for i in 0 ..< maxNumSubLayersMinus1 {
        if profilePresent[i] { try r.skip(88) }          // 2+1+5+32+48 = 88
        ptl.subLayerLevelIDC.append(levelPresent[i] ? UInt8(try r.u(8)) : nil)
    }
    return ptl
}
```

`generalProfileCompatibilityFlags` is stored with `flag[0]` in bit 31 (i.e. as read MSB-first), which
is exactly the `hvcC` field order. Main profile ⇒ `0x60000000` (flags 1 and 2 set). Main 10 ⇒
`0x24000000` (flags 2 and 5 set) as emitted by Hikvision's HEVC encoder.

H.265 profile names: `1` Main, `2` Main 10, `3` Main Still Picture, `4` Format Range Extensions
(RExt), `5` High Throughput, `9` Screen Content Coding. Level name = `general_level_idc / 30`
formatted to one decimal (`123` ⇒ "4.1", `150` ⇒ "5.0"), suffixed " High tier" when
`general_tier_flag == 1`.

---

## 12. H.265 VPS (ITU-T H.265 §7.3.2.1)

We parse the VPS only far enough to key the store and cross-check the SPS. The whole NAL is
retained byte-for-byte for re-emission in `hvcC` and to `CMVideoFormatDescriptionCreateFromHEVCParameterSets`.

| Field | Descriptor | Kept? |
|---|---|---|
| `vps_video_parameter_set_id` | u(4) | yes — store key |
| `vps_base_layer_internal_flag` | u(1) | no |
| `vps_base_layer_available_flag` | u(1) | no |
| `vps_max_layers_minus1` | u(6) | yes — must be 0; > 0 means multi-layer, unsupported, log and continue |
| `vps_max_sub_layers_minus1` | u(3) | yes — cross-check against SPS |
| `vps_temporal_id_nesting_flag` | u(1) | yes — feeds `hvcC.temporalIdNested` |
| `vps_reserved_0xffff_16bits` | u(16) | validated == 0xFFFF (a cheap corruption canary) |
| `profile_tier_level(1, vps_max_sub_layers_minus1)` | | parsed, then **discarded** |
| everything after | | **not parsed** |

**Binding decision: `hvcC`'s profile/tier/level fields come from the SPS, not the VPS.** For a
single-layer stream ISO/IEC 14496-15 requires them to be identical, and the SPS is the parameter set
that actually governs the decoded pictures. If the two differ we log a warning at `.notice` and use
the SPS. Nothing downstream reads a VPS-derived PTL.

```swift
public struct H265VPS: Sendable, Hashable, Codable {
    public var vpsID: UInt8
    public var maxLayersMinus1: UInt8
    public var maxSubLayersMinus1: UInt8
    public var temporalIDNestingFlag: Bool
}
```

Verified VPS vector (24 bytes):

```
40 01 0C 01 FF FF 01 60 00 00 03 00 B0 00 00 03 00 00 03 00 7B 97 02 40
```
base64 `QAEMAf//AWAAAAMAsAAAAwAAAwB7lwJA`

Byte-by-byte: `40 01` NAL header (type 32, layer 0, TID 0). `0C` = `0000 1 1 00` →
`vps_video_parameter_set_id = 0`, `base_layer_internal = 1`, `base_layer_available = 1`, then the
top 2 bits of `vps_max_layers_minus1`. `01` completes `vps_max_layers_minus1 = 0`,
`vps_max_sub_layers_minus1 = 0`, `vps_temporal_id_nesting_flag = 1`. `FF FF` is the reserved
canary. Then the PTL: `01` (space 0, tier 0, idc 1), `60 00 00 03 00` → after removing the
emulation-prevention `03` the compatibility flags are `60 00 00 00`, then constraints
`B0 00 00 03 00 00 03 00` → unescaped `B0 00 00 00 00 00`, then `7B` = level 123 = 4.1.

---

## 13. H.265 SPS (ITU-T H.265 §7.3.2.2.1)

### 13.1 Syntax, in order

| Field | Descriptor | Notes |
|---|---|---|
| `sps_video_parameter_set_id` | u(4) | |
| `sps_max_sub_layers_minus1` | u(3) | 0…6 |
| `sps_temporal_id_nesting_flag` | u(1) | → `hvcC.temporalIdNested` |
| `profile_tier_level(1, sps_max_sub_layers_minus1)` | | §11 |
| `sps_seq_parameter_set_id` | ue(v) | 0…15 |
| `chroma_format_idc` | ue(v) | 0…3 |
| **if** `== 3`: `separate_colour_plane_flag` | u(1) | |
| `pic_width_in_luma_samples` | ue(v) | multiple of `MinCbSizeY` |
| `pic_height_in_luma_samples` | ue(v) | multiple of `MinCbSizeY` |
| `conformance_window_flag` | u(1) | |
| **if** set: `conf_win_left/right/top/bottom_offset` | ue(v) × 4 | **in chroma units** |
| `bit_depth_luma_minus8` | ue(v) | |
| `bit_depth_chroma_minus8` | ue(v) | |
| `log2_max_pic_order_cnt_lsb_minus4` | ue(v) | 0…12 |
| `sps_sub_layer_ordering_info_present_flag` | u(1) | |
| for `i` in `(flag ? 0 : maxSub) ... maxSub`: `sps_max_dec_pic_buffering_minus1[i]`, `sps_max_num_reorder_pics[i]`, `sps_max_latency_increase_plus1[i]` | ue(v) × 3 | keep the `[maxSub]` entry |
| `log2_min_luma_coding_block_size_minus3` | ue(v) | |
| `log2_diff_max_min_luma_coding_block_size` | ue(v) | |
| `log2_min_luma_transform_block_size_minus2` | ue(v) | |
| `log2_diff_max_min_luma_transform_block_size` | ue(v) | |
| `max_transform_hierarchy_depth_inter` | ue(v) | |
| `max_transform_hierarchy_depth_intra` | ue(v) | |
| `scaling_list_enabled_flag` | u(1) | |
| **if** set: `sps_scaling_list_data_present_flag` u(1); **if** set: `scaling_list_data()` | | §13.2 |
| `amp_enabled_flag` | u(1) | |
| `sample_adaptive_offset_enabled_flag` | u(1) | |
| `pcm_enabled_flag` | u(1) | |
| **if** set: `pcm_sample_bit_depth_luma_minus1` u(4), `pcm_sample_bit_depth_chroma_minus1` u(4), `log2_min_pcm_luma_coding_block_size_minus3` ue(v), `log2_diff_max_min_pcm_luma_coding_block_size` ue(v), `pcm_loop_filter_disabled_flag` u(1) | | |
| `num_short_term_ref_pic_sets` | ue(v) | 0…64 |
| for `i` in `0..<num`: `st_ref_pic_set(i)` | | §13.3 — **the hard one** |
| `long_term_ref_pics_present_flag` | u(1) | |
| **if** set: `num_long_term_ref_pics_sps` ue(v) (0…32); then per entry `lt_ref_pic_poc_lsb_sps[i]` u(`log2_max_pic_order_cnt_lsb`), `used_by_curr_pic_lt_sps_flag[i]` u(1) | | §13.4 |
| `sps_temporal_mvp_enabled_flag` | u(1) | |
| `strong_intra_smoothing_enabled_flag` | u(1) | |
| `vui_parameters_present_flag` | u(1) | |
| **if** set: `vui_parameters()` | | §13.6, lenient |
| `sps_extension_present_flag` | u(1) | parsed, then we stop |

Derived:
```
MinCbLog2SizeY = log2_min_luma_coding_block_size_minus3 + 3
CtbLog2SizeY   = MinCbLog2SizeY + log2_diff_max_min_luma_coding_block_size     // must be 4...6
CtbSizeY       = 1 << CtbLog2SizeY                                            // 16, 32 or 64
PicWidthInCtbsY  = ceil(pic_width_in_luma_samples  / CtbSizeY)
PicHeightInCtbsY = ceil(pic_height_in_luma_samples / CtbSizeY)
```

### 13.2 `scaling_list_data()` skip (H.265 §7.3.4)

```swift
private static func skipScalingListData(_ r: inout RBSPBitReader) throws {
    for sizeId in 0 ..< 4 {
        var matrixId = 0
        let step = (sizeId == 3) ? 3 : 1              // sizeId 3 has only matrixId 0 and 3
        while matrixId < 6 {
            if try !r.flag() {                        // scaling_list_pred_mode_flag == 0
                _ = try r.ue()                        // scaling_list_pred_matrix_id_delta
            } else {
                let coefNum = min(64, 1 << (4 + (sizeId << 1)))   // 16, 64, 64, 64
                if sizeId > 1 { _ = try r.se() }      // scaling_list_dc_coef_minus8
                for _ in 0 ..< coefNum { _ = try r.se() }         // scaling_list_delta_coef
            }
            matrixId += step
        }
    }
}
```

The `step = 3` for `sizeId == 3` is mandatory: 32×32 has only two matrices (intra and inter), so
`matrixId` takes the values 0 and 3, not 0…5.

### 13.3 `st_ref_pic_set()` — the skip that must be exact (H.265 §7.3.7)

The trap: when `inter_ref_pic_set_prediction_flag` is 1, the number of syntax elements to read
depends on `NumDeltaPocs[RefRpsIdx]` — a value derived from a *previous* RPS. A parser that does not
maintain the `NumDeltaPocs` array cannot skip a chain of inter-predicted RPSs and will desynchronise
before `pic_width` … no, before the VUI, silently producing a plausible-but-wrong frame rate. Worse,
the derivation of `NumDeltaPocs` for the inter-predicted case is *not* simply
`NumDeltaPocs[RefRpsIdx]`: it is the count of `j` for which `used_by_curr_pic_flag[j]` or
`use_delta_flag[j]` is 1. (Each such `j` contributes exactly one entry to either the negative or the
positive delta-POC list, so the count of contributing `j` equals
`NumNegativePics + NumPositivePics` = `NumDeltaPocs`. Equations 7-59 … 7-61.)

```swift
/// Consumes one st_ref_pic_set(stRpsIdx) and returns NumDeltaPocs[stRpsIdx].
/// `numDeltaPocs` holds the values for indices 0 ..< stRpsIdx.
private static func skipShortTermRefPicSet(
    _ r: inout RBSPBitReader,
    stRpsIdx: Int,
    numShortTermRefPicSets: Int,
    numDeltaPocs: [Int]
) throws -> Int {
    var interPrediction = false
    if stRpsIdx != 0 { interPrediction = try r.flag() }   // inter_ref_pic_set_prediction_flag

    if interPrediction {
        var deltaIdxMinus1: UInt32 = 0
        if stRpsIdx == numShortTermRefPicSets {           // only in the slice-header form
            deltaIdxMinus1 = try r.ue("delta_idx_minus1", max: UInt32(stRpsIdx))
        }
        try r.skip(1)                                     // delta_rps_sign
        _ = try r.ue()                                    // abs_delta_rps_minus1
        let refRpsIdx = stRpsIdx - (Int(deltaIdxMinus1) + 1)
        guard refRpsIdx >= 0, refRpsIdx < numDeltaPocs.count else {
            throw BitstreamError.unsupportedSyntax("st_ref_pic_set RefRpsIdx out of range")
        }
        var count = 0
        for _ in 0 ... numDeltaPocs[refRpsIdx] {          // note: inclusive upper bound
            let usedByCurrPic = try r.flag()              // used_by_curr_pic_flag[j]
            var useDelta = true
            if !usedByCurrPic { useDelta = try r.flag() } // use_delta_flag[j]
            if usedByCurrPic || useDelta { count += 1 }
        }
        return count
    } else {
        let numNegative = try r.ue("num_negative_pics", max: 16)
        let numPositive = try r.ue("num_positive_pics", max: 16)
        for _ in 0 ..< numNegative {
            _ = try r.ue()                                // delta_poc_s0_minus1[i]
            try r.skip(1)                                 // used_by_curr_pic_s0_flag[i]
        }
        for _ in 0 ..< numPositive {
            _ = try r.ue()                                // delta_poc_s1_minus1[i]
            try r.skip(1)                                 // used_by_curr_pic_s1_flag[i]
        }
        return Int(numNegative) + Int(numPositive)
    }
}

// call site
let numSets = Int(try r.ue("num_short_term_ref_pic_sets", max: 64))
var numDeltaPocs = [Int]()
numDeltaPocs.reserveCapacity(numSets)
for i in 0 ..< numSets {
    numDeltaPocs.append(try skipShortTermRefPicSet(
        &r, stRpsIdx: i, numShortTermRefPicSets: numSets, numDeltaPocs: numDeltaPocs))
}
sps.numDeltaPocs = numDeltaPocs
```

Two details worth restating because they are the two ways this goes wrong:

* `inter_ref_pic_set_prediction_flag` is **absent** when `stRpsIdx == 0` and is inferred as 0.
* The loop bound is `0 ... numDeltaPocs[refRpsIdx]` — **inclusive**, i.e.
  `NumDeltaPocs[RefRpsIdx] + 1` iterations, because index `j` ranges over the reference set's
  delta-POCs *plus* the reference picture itself.

Vector W2 (§22) exercises exactly this: two RPSs, the second inter-predicted from the first with
`NumDeltaPocs[0] = 2` ⇒ 3 flag pairs ⇒ `NumDeltaPocs[1] = 3`.

### 13.4 Long-term reference picture set

```swift
if try r.flag() {                                          // long_term_ref_pics_present_flag
    let n = try r.ue("num_long_term_ref_pics_sps", max: 32)
    for _ in 0 ..< n {
        try r.skip(sps.log2MaxPicOrderCntLsb)              // lt_ref_pic_poc_lsb_sps[i]
        try r.skip(1)                                      // used_by_curr_pic_lt_sps_flag[i]
    }
}
```
`log2MaxPicOrderCntLsb` = `log2_max_pic_order_cnt_lsb_minus4 + 4`, range 4…16, so the `skip` is
between 4 and 16 bits. Using a fixed 8 or 16 here — a real bug seen in third-party code — shifts the
VUI and produces a wrong fps.

### 13.5 Conformance window derivation

```
SubWidthC, SubHeightC per H.265 Table 6-1 (identical to H.264):
   chroma_format_idc 0 (mono) -> (1,1)    1 (4:2:0) -> (2,2)
   chroma_format_idc 2 (4:2:2) -> (2,1)   3 (4:4:4) -> (1,1)
   separate_colour_plane_flag == 1 -> (1,1)

displayWidth  = pic_width_in_luma_samples  - SubWidthC  * (conf_win_left_offset + conf_win_right_offset)
displayHeight = pic_height_in_luma_samples - SubHeightC * (conf_win_top_offset  + conf_win_bottom_offset)
```

The offsets are in **chroma sample units**, hence the multiply. For 4:2:0 that means every unit of
offset removes **two** luma columns/rows. H.265 needs a conformance window much less often than
H.264 needs cropping, because `pic_height_in_luma_samples` only has to be a multiple of
`MinCbSizeY` (8, typically) rather than 16: 1080 = 135 × 8, so a 1080p HEVC SPS usually has
`conformance_window_flag == 0`. Vector W2 covers the windowed case (1936×1088 → 1920×1080).

`default_display_window` in the VUI is a *separate*, additional crop. **Binding decision: we parse
it into `H265SPS.defaultDisplayWindow` but do not apply it.** It is an authoring hint, not a
conformance requirement; VideoToolbox ignores it; applying it would make our reported size disagree
with the decoded `CVPixelBuffer` and with the `CleanAperture` extension. It is surfaced in the
diagnostics HUD only.

### 13.6 H.265 VUI (H.265 §E.2.1) and `hrd_parameters()`

Order differs from H.264 — five extra flags appear between `chroma_loc_info` and the timing block,
and the timing block itself has no `fixed_frame_rate_flag`:

| Field | Descriptor |
|---|---|
| `aspect_ratio_info_present_flag` u(1); **if** set `aspect_ratio_idc` u(8); **if** 255 `sar_width` u(16), `sar_height` u(16) | |
| `overscan_info_present_flag` u(1); **if** set `overscan_appropriate_flag` u(1) | |
| `video_signal_type_present_flag` u(1); **if** set `video_format` u(3), `video_full_range_flag` u(1), `colour_description_present_flag` u(1); **if** set `colour_primaries` u(8), `transfer_characteristics` u(8), `matrix_coeffs` u(8) | |
| `chroma_loc_info_present_flag` u(1); **if** set two ue(v) | |
| `neutral_chroma_indication_flag` | u(1) |
| `field_seq_flag` | u(1) |
| `frame_field_info_present_flag` | u(1) |
| `default_display_window_flag` u(1); **if** set four ue(v) | |
| `vui_timing_info_present_flag` u(1); **if** set `vui_num_units_in_tick` u(32), `vui_time_scale` u(32), `vui_poc_proportional_to_timing_flag` u(1); **if** set `vui_num_ticks_poc_diff_one_minus1` ue(v); then `vui_hrd_parameters_present_flag` u(1); **if** set `hrd_parameters(1, sps_max_sub_layers_minus1)` | |
| `bitstream_restriction_flag` u(1); **if** set: `tiles_fixed_structure_flag` u(1), `motion_vectors_over_pic_boundaries_flag` u(1), `restricted_ref_pic_lists_flag` u(1), **`min_spatial_segmentation_idc` ue(v)**, `max_bytes_per_pic_denom` ue(v), `max_bits_per_min_cu_denom` ue(v), `log2_max_mv_length_horizontal` ue(v), `log2_max_mv_length_vertical` ue(v) | |

```
fps_H265 = vui_time_scale / vui_num_units_in_tick
```
**No factor of 2** — H.265 `vui_time_scale` counts frame ticks, not field ticks. This asymmetry with
H.264 is the single most common fps bug. `num_units_in_tick = 1, time_scale = 25` ⇒ 25.0 fps.

`min_spatial_segmentation_idc` is the only reason we parse the H.265 HRD at all: it sits *after*
the HRD and feeds `hvcC.min_spatial_segmentation_idc`. Default 0 when absent.

```swift
private static func skipHRDParameters(
    _ r: inout RBSPBitReader, commonInfPresent: Bool, maxNumSubLayersMinus1: Int
) throws {
    var nalHRD = false, vclHRD = false, subPicParams = false
    if commonInfPresent {
        nalHRD = try r.flag()
        vclHRD = try r.flag()
        if nalHRD || vclHRD {
            subPicParams = try r.flag()                 // sub_pic_hrd_params_present_flag
            if subPicParams {
                try r.skip(8)                           // tick_divisor_minus2
                try r.skip(5)                           // du_cpb_removal_delay_increment_length_minus1
                try r.skip(1)                           // sub_pic_cpb_params_in_pic_timing_sei_flag
                try r.skip(5)                           // dpb_output_delay_du_length_minus1
            }
            try r.skip(4)                               // bit_rate_scale
            try r.skip(4)                               // cpb_size_scale
            if subPicParams { try r.skip(4) }           // cpb_size_du_scale
            try r.skip(5)                               // initial_cpb_removal_delay_length_minus1
            try r.skip(5)                               // au_cpb_removal_delay_length_minus1
            try r.skip(5)                               // dpb_output_delay_length_minus1
        }
    }
    for _ in 0 ... maxNumSubLayersMinus1 {
        let fixedPicRateGeneral = try r.flag()
        // fixed_pic_rate_within_cvs_flag is inferred equal to fixed_pic_rate_general_flag when it is 1
        let fixedPicRateWithinCVS = fixedPicRateGeneral ? true : try r.flag()
        var lowDelay = false
        if fixedPicRateWithinCVS {
            _ = try r.ue()                              // elemental_duration_in_tc_minus1
        } else {
            lowDelay = try r.flag()                     // low_delay_hrd_flag
        }
        var cpbCnt = 1
        if !lowDelay { cpbCnt = Int(try r.ue("cpb_cnt_minus1", max: 31)) + 1 }
        if nalHRD { try skipSubLayerHRD(&r, cpbCnt: cpbCnt, subPicParams: subPicParams) }
        if vclHRD { try skipSubLayerHRD(&r, cpbCnt: cpbCnt, subPicParams: subPicParams) }
    }
}

private static func skipSubLayerHRD(
    _ r: inout RBSPBitReader, cpbCnt: Int, subPicParams: Bool
) throws {
    for _ in 0 ..< cpbCnt {
        _ = try r.ue()                                  // bit_rate_value_minus1
        _ = try r.ue()                                  // cpb_size_value_minus1
        if subPicParams {
            _ = try r.ue()                              // cpb_size_du_value_minus1
            _ = try r.ue()                              // bit_rate_du_value_minus1
        }
        try r.skip(1)                                   // cbr_flag
    }
}
```

Same lenient rule as H.264: a VUI/HRD failure sets `vuiParseFailed`, keeps whatever was decoded
before the failure (crucially the timing info, which precedes the HRD), and defaults
`minSpatialSegmentationIDC` to 0. It never fails the SPS parse.

### 13.7 `H265SPS`

```swift
public struct H265SPS: Sendable, Hashable, Codable {
    public var vpsID: UInt8
    public var maxSubLayersMinus1: UInt8
    public var temporalIDNestingFlag: Bool
    public var ptl: ProfileTierLevel
    public var spsID: UInt32
    public var chromaFormatIDC: UInt8
    public var separateColourPlaneFlag: Bool
    public var picWidthInLumaSamples: Int
    public var picHeightInLumaSamples: Int
    public var conformanceWindow: (left: Int, right: Int, top: Int, bottom: Int)
    public var bitDepthLuma: Int
    public var bitDepthChroma: Int
    public var log2MaxPicOrderCntLsb: Int
    public var maxDecPicBuffering: Int
    public var maxNumReorderPics: Int
    public var minCbLog2SizeY: Int
    public var ctbLog2SizeY: Int
    public var maxTransformHierarchyDepthInter: Int
    public var maxTransformHierarchyDepthIntra: Int
    public var ampEnabled: Bool
    public var saoEnabled: Bool
    public var pcmEnabled: Bool
    public var numShortTermRefPicSets: Int
    public var numDeltaPocs: [Int]
    public var longTermRefPicsPresent: Bool
    public var temporalMVPEnabled: Bool
    public var strongIntraSmoothingEnabled: Bool
    // VUI
    public var vuiPresent: Bool
    public var vuiParseFailed: Bool
    public var sarWidth: Int
    public var sarHeight: Int
    public var fieldSeqFlag: Bool
    public var frameFieldInfoPresent: Bool
    public var defaultDisplayWindow: (left: Int, right: Int, top: Int, bottom: Int)?
    public var numUnitsInTick: UInt32?
    public var timeScale: UInt32?
    public var colourPrimaries: UInt8?
    public var transferCharacteristics: UInt8?
    public var matrixCoefficients: UInt8?
    public var videoFullRangeFlag: Bool
    public var minSpatialSegmentationIDC: Int
    // derived
    public var codedWidth: Int { picWidthInLumaSamples }
    public var codedHeight: Int { picHeightInLumaSamples }
    public var displayWidth: Int { get }
    public var displayHeight: Int { get }
    public var frameRate: Double? { get }        // timeScale / numUnitsInTick
    public var ctbSizeY: Int { 1 << ctbLog2SizeY }
    public var numTemporalLayers: Int { Int(maxSubLayersMinus1) + 1 }
}
```

---

## 14. H.265 PPS — minimal parse (for `parallelismType`)

We parse the HEVC PPS as far as `entropy_coding_sync_enabled_flag` because `hvcC` requires
`parallelismType`, and that value is defined in terms of the PPS. Field order (§7.3.2.3.1):

`pps_pic_parameter_set_id` ue(v), `pps_seq_parameter_set_id` ue(v),
`dependent_slice_segments_enabled_flag` u(1), `output_flag_present_flag` u(1),
`num_extra_slice_header_bits` u(3), `sign_data_hiding_enabled_flag` u(1),
`cabac_init_present_flag` u(1), `num_ref_idx_l0_default_active_minus1` ue(v),
`num_ref_idx_l1_default_active_minus1` ue(v), `init_qp_minus26` se(v),
`constrained_intra_pred_flag` u(1), `transform_skip_enabled_flag` u(1),
`cu_qp_delta_enabled_flag` u(1) [**if set** `diff_cu_qp_delta_depth` ue(v)],
`pps_cb_qp_offset` se(v), `pps_cr_qp_offset` se(v),
`pps_slice_chroma_qp_offsets_present_flag` u(1), `weighted_pred_flag` u(1),
`weighted_bipred_flag` u(1), `transquant_bypass_enabled_flag` u(1),
**`tiles_enabled_flag` u(1)**, **`entropy_coding_sync_enabled_flag` u(1)**.

`num_extra_slice_header_bits` and `dependent_slice_segments_enabled_flag` are retained because a
future slice-header parse (recorded-playback POC reordering) needs them.

```swift
/// ISO/IEC 14496-15 §8.3.3.1.2
public static func parallelismType(tilesEnabled: Bool, entropyCodingSync: Bool) -> UInt8 {
    switch (tilesEnabled, entropyCodingSync) {
    case (true, true):   return 0      // mixed tiles + WPP -> "unknown"
    case (true, false):  return 2      // tile-based
    case (false, true):  return 3      // entropy-coding-sync (WPP) based
    case (false, false): return 1      // slice-based
    }
}
```

If no PPS is available or its parse throws, emit `parallelismType = 0` ("unknown"). Every decoder
including VideoToolbox tolerates 0; it is an informational field.

Verified HEVC PPS vectors:

| Vector | Base64 | Hex | tiles | WPP | `parallelismType` |
|---|---|---|---:|---:|---:|
| Q1 | `RAHh88DMkA==` | `44 01 E1 F3 C0 CC 90` | 0 | 0 | 1 |
| Q2 | `RAHh88JLzJA=` | `44 01 E1 F3 C2 4B CC 90` | 1 (2×2) | 0 | 2 |
| Q3 | `RAHh88HMkA==` | `44 01 E1 F3 C1 CC 90` | 0 | 1 | 3 |

---

<!-- PART2 -->
