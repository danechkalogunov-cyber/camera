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

A tuple cannot conform to `Hashable`/`Codable`, so the four-offset groups use a named struct. Do not
"simplify" these back to tuples — the conformances are load-bearing (`VideoFormatInfo` is persisted
in the camera database and diffed for format-change detection).

```swift
/// H.264 `frame_crop_*_offset`, H.265 `conf_win_*_offset` and `def_disp_win_*_offset`.
/// Units are as in the respective standard: macroblock-derived crop units for H.264,
/// chroma sample units for H.265.
public struct CropOffsets: Sendable, Hashable, Codable {
    public var left: Int, right: Int, top: Int, bottom: Int
    public init(left: Int = 0, right: Int = 0, top: Int = 0, bottom: Int = 0)
    public static let zero = CropOffsets()
    public var isZero: Bool { left == 0 && right == 0 && top == 0 && bottom == 0 }
}
```

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
    public var frameCropping: CropOffsets = .zero
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
    public var conformanceWindow: CropOffsets
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
    public var defaultDisplayWindow: CropOffsets?      // parsed, deliberately NOT applied (§13.5)
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

## 15. Format records — policy

We build and parse two ISO/IEC 14496-15 decoder configuration records:

| Record | ISO ref | Used for |
|---|---|---|
| `avcC` (`AVCDecoderConfigurationRecord`) | 14496-15 §5.3.3.1 | MP4/MOV muxing during recording, `.mp4` fixture playback, Linux unit tests, the `kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms` fallback path |
| `hvcC` (`HEVCDecoderConfigurationRecord`) | 14496-15 §8.3.3.1 | same, for HEVC |

**Binding decision: at runtime on macOS we build `CMVideoFormatDescription` with
`CMVideoFormatDescriptionCreateFromH264ParameterSets` /
`CMVideoFormatDescriptionCreateFromHEVCParameterSets`, not from a hand-built record.** See §18 for
the reasoning and the exact glue. The record builders below are still mandatory, for four reasons
that are each load-bearing:

1. **Recording.** `AVAssetWriter` in passthrough mode derives the sample description from the
   `CMFormatDescription` we give it, so it builds its own `avcC`; but our fragmented-MP4 export path
   and the `.mov` sidecar index writer need the record bytes directly.
2. **Reading.** Playing back our own recordings, or an MP4 pulled from an NVR over ISAPI, means
   *parsing* an `avcC`/`hvcC` to recover the parameter sets. Same code, other direction.
3. **Linux CI.** The record round trip (`build → parse → compare`) is the only way to regression-test
   parameter-set handling on a machine with no VideoToolbox. This is where the §22 vectors live.
4. **Fallback.** If `CMVideoFormatDescriptionCreateFrom…ParameterSets` returns an error for an
   exotic stream, we retry via `CMVideoFormatDescriptionCreate` with an extension-atoms dictionary
   containing our record. Observed necessary exactly once (a 4:2:2 10-bit HEVC NVR transcode).

---

## 16. `avcC` — exact byte layout

```
aligned(8) class AVCDecoderConfigurationRecord {
   unsigned int(8)  configurationVersion = 1;
   unsigned int(8)  AVCProfileIndication;          // == SPS NAL byte[1] (profile_idc)
   unsigned int(8)  profile_compatibility;         // == SPS NAL byte[2] (constraint flags)
   unsigned int(8)  AVCLevelIndication;            // == SPS NAL byte[3] (level_idc)
   bit(6)           reserved = '111111'b;
   unsigned int(2)  lengthSizeMinusOne;            // ALWAYS 3 in Vigil
   bit(3)           reserved = '111'b;
   unsigned int(5)  numOfSequenceParameterSets;
   for (i = 0; i < numOfSequenceParameterSets; i++) {
       unsigned int(16) sequenceParameterSetLength;
       bit(8 * len)     sequenceParameterSetNALUnit;   // incl. 1-byte NAL header, escaped
   }
   unsigned int(8)  numOfPictureParameterSets;
   for (i = 0; i < numOfPictureParameterSets; i++) {
       unsigned int(16) pictureParameterSetLength;
       bit(8 * len)     pictureParameterSetNALUnit;
   }
   if (AVCProfileIndication == 100 || 110 || 122 || 144) {     // <-- NOT 244
       bit(6)          reserved = '111111'b;
       unsigned int(2) chroma_format;                          // = chroma_format_idc
       bit(5)          reserved = '11111'b;
       unsigned int(3) bit_depth_luma_minus8;
       bit(5)          reserved = '11111'b;
       unsigned int(3) bit_depth_chroma_minus8;
       unsigned int(8) numOfSequenceParameterSetExt;
       for (i = 0; i < numOfSequenceParameterSetExt; i++) {
           unsigned int(16) sequenceParameterSetExtLength;
           bit(8 * len)     sequenceParameterSetExtNALUnit;    // NAL type 13
       }
   }
}
```

Fixed offsets of the header:

| Offset | Size | Field | Vigil value |
|---:|---:|---|---|
| 0 | 1 | `configurationVersion` | `0x01` |
| 1 | 1 | `AVCProfileIndication` | SPS byte 1 |
| 2 | 1 | `profile_compatibility` | SPS byte 2 |
| 3 | 1 | `AVCLevelIndication` | SPS byte 3 |
| 4 | 1 | `0b111111` \| `lengthSizeMinusOne` | `0xFC \| 3` = **`0xFF`** |
| 5 | 1 | `0b111` \| `numOfSequenceParameterSets` | `0xE0 \| count` |
| 6 | … | SPS array | |

### 16.1 The three bytes at offsets 1–3

They are **literally copied from the SPS NAL unit**, bytes 1, 2 and 3 (byte 0 is the NAL header
`0x67`). They must not be recomputed from a parsed model — `profile_compatibility` is the packed
constraint-flag byte including `reserved_zero_2bits`, and re-deriving it from six `Bool`s is how the
bit order gets flipped. This is why `H264SPS.constraintFlags` is stored as the raw byte (§8.7).

```swift
guard sps.count >= 4 else { throw BitstreamError.emptyNALUnit }
out.append(0x01)          // configurationVersion
out.append(sps[1])        // AVCProfileIndication
out.append(sps[2])        // profile_compatibility
out.append(sps[3])        // AVCLevelIndication
out.append(0xFC | 3)      // 0xFF
out.append(0xE0 | UInt8(spsList.count))
```

### 16.2 The trailing extension condition — the classic bug

Two *different* profile sets exist and are routinely confused:

| Condition | Profile set |
|---|---|
| SPS carries `chroma_format_idc` / bit depths / scaling lists (H.264 §7.3.2.1) | {100, 110, 122, **244**, 44, 83, 86, 118, 128, 138, 139, 134, 135} |
| `avcC` carries the trailing extension (ISO 14496-15 §5.3.3.1) | {100, 110, 122, **144**} |

144 is not a valid `profile_idc` in any published H.264 edition — it is a historical artefact of the
ISO text (it predates the renumbering of High 4:4:4 to 244). We follow the ISO text exactly when
**writing**, and when **reading** we treat any bytes remaining after the PPS array as a possible
extension regardless of profile, requiring ≥ 4 remaining bytes before interpreting them.

```swift
public func serialized() -> [UInt8] {
    // ... header, SPS array, PPS array as above ...
    switch avcProfileIndication {
    case 100, 110, 122, 144:
        out.append(0xFC | (chromaFormat ?? 1))
        out.append(0xF8 | (bitDepthLumaMinus8 ?? 0))
        out.append(0xF8 | (bitDepthChromaMinus8 ?? 0))
        out.append(UInt8(sequenceParameterSetExt.count))
        for e in sequenceParameterSetExt {
            out.append(UInt8(truncatingIfNeeded: e.count >> 8))
            out.append(UInt8(truncatingIfNeeded: e.count))
            out.append(contentsOf: e)
        }
    default: break
    }
    return out
}
```

When reading: if fewer than 4 bytes remain, stop (some muxers omit the extension even for High).
If `numOfSequenceParameterSetExt` is non-zero but the arrays are truncated, ignore the extension
entirely rather than throwing — the SPS/PPS we already recovered are what matter.

### 16.3 Worked example A — Main profile, no extension (37 bytes)

Input: SPS = vector **V1** (H.264 Main 4.0, 1920×1080 @ 25 fps), PPS = vector **P1**.

```
offset  bytes                                             meaning
------  ------------------------------------------------  --------------------------------------
00      01                                                configurationVersion = 1
01      4D                                                AVCProfileIndication = 77 (Main)
02      00                                                profile_compatibility = 0x00
03      28                                                AVCLevelIndication = 40 (Level 4.0)
04      FF                                                111111b | lengthSizeMinusOne = 3
05      E1                                                111b    | numOfSequenceParameterSets = 1
06      00 16                                             sequenceParameterSetLength = 22
08      67 4D 00 28 F4 03 C0 11 3F 2E 02 20 00 00 03 00   SPS NAL unit (22 bytes)
        20 00 00 06 50 80                                   note 00 00 03 00 = escaped 00 00 00
1E      01                                                numOfPictureParameterSets = 1
1F      00 04                                             pictureParameterSetLength = 4
21      68 EE 3C 80                                       PPS NAL unit
        (profile 77 is not in {100,110,122,144} -> no trailing extension)
```

Full hex, 37 bytes:
```
01 4D 00 28 FF E1 00 16 67 4D 00 28 F4 03 C0 11
3F 2E 02 20 00 00 03 00 20 00 00 06 50 80 01 00
04 68 EE 3C 80
```
base64: `AU0AKP/hABZnTQAo9APAET8uAiAAAAMAIAAABlCAAQAEaO48gA==`

### 16.4 Worked example B — High profile, with extension (48 bytes)

Input: SPS = vector **V2** (H.264 High 4.1, 1920×1080 @ 30 fps, VUI with colour description and
bitstream restriction), PPS = vector **P2**.

```
offset  bytes                                             meaning
------  ------------------------------------------------  --------------------------------------
00      01                                                configurationVersion = 1
01      64                                                AVCProfileIndication = 100 (High)
02      00                                                profile_compatibility = 0x00
03      29                                                AVCLevelIndication = 41 (Level 4.1)
04      FF                                                lengthSizeMinusOne = 3
05      E1                                                numOfSequenceParameterSets = 1
06      00 1D                                             sequenceParameterSetLength = 29
08      67 64 00 29 AC 2C AC 07 80 22 7E 5C 05 A8 08 08   SPS NAL unit (29 bytes)
        0A 00 00 03 00 02 00 00 03 00 79 1E DF
25      01                                                numOfPictureParameterSets = 1
26      00 04                                             pictureParameterSetLength = 4
28      68 EE 3C B0                                       PPS NAL unit
2C      FD                                                111111b | chroma_format = 1 (4:2:0)
2D      F8                                                11111b  | bit_depth_luma_minus8 = 0
2E      F8                                                11111b  | bit_depth_chroma_minus8 = 0
2F      00                                                numOfSequenceParameterSetExt = 0
```

Full hex, 48 bytes:
```
01 64 00 29 FF E1 00 1D 67 64 00 29 AC 2C AC 07
80 22 7E 5C 05 A8 08 08 0A 00 00 03 00 02 00 00
03 00 79 1E DF 01 00 04 68 EE 3C B0 FD F8 F8 00
```
base64: `AWQAKf/hAB1nZAAprCysB4AiflwFqAgICgAAAwACAAADAHke3wEABGjuPLD9+PgA`

---

## 17. `hvcC` — exact byte layout

```
aligned(8) class HEVCDecoderConfigurationRecord {
   unsigned int(8)  configurationVersion = 1;
   unsigned int(2)  general_profile_space;
   unsigned int(1)  general_tier_flag;
   unsigned int(5)  general_profile_idc;
   unsigned int(32) general_profile_compatibility_flags;
   unsigned int(48) general_constraint_indicator_flags;
   unsigned int(8)  general_level_idc;
   bit(4)           reserved = '1111'b;
   unsigned int(12) min_spatial_segmentation_idc;
   bit(6)           reserved = '111111'b;
   unsigned int(2)  parallelismType;
   bit(6)           reserved = '111111'b;
   unsigned int(2)  chromaFormat;
   bit(5)           reserved = '11111'b;
   unsigned int(3)  bitDepthLumaMinus8;
   bit(5)           reserved = '11111'b;
   unsigned int(3)  bitDepthChromaMinus8;
   bit(16)          avgFrameRate;                  // frames / (256 s); 0 = unspecified
   bit(2)           constantFrameRate;             // 0 unknown, 1 constant, 2 constant per layer
   bit(3)           numTemporalLayers;             // 0 unknown; else sps_max_sub_layers_minus1 + 1
   bit(1)           temporalIdNested;
   unsigned int(2)  lengthSizeMinusOne;            // ALWAYS 3
   unsigned int(8)  numOfArrays;
   for (j = 0; j < numOfArrays; j++) {
       bit(1)           array_completeness;
       unsigned int(1)  reserved = 0;
       unsigned int(6)  NAL_unit_type;             // 32 VPS, 33 SPS, 34 PPS, 39 prefix SEI
       unsigned int(16) numNalus;
       for (i = 0; i < numNalus; i++) {
           unsigned int(16) nalUnitLength;
           bit(8 * len)     nalUnit;               // incl. 2-byte NAL header, escaped
       }
   }
}
```

Fixed offsets:

| Offset | Size | Field | Source |
|---:|---:|---|---|
| 0 | 1 | `configurationVersion` | `0x01` |
| 1 | 1 | `profile_space<<6 \| tier<<5 \| profile_idc` | SPS PTL |
| 2 | 4 | `general_profile_compatibility_flags` | SPS PTL, big-endian, `flag[0]` in the MSB |
| 6 | 6 | `general_constraint_indicator_flags` | SPS PTL, the verbatim 48-bit region (§11) |
| 12 | 1 | `general_level_idc` | SPS PTL |
| 13 | 2 | `0xF000 \| min_spatial_segmentation_idc` | SPS VUI bitstream restriction, else 0 |
| 15 | 1 | `0xFC \| parallelismType` | HEVC PPS (§14), else 0 |
| 16 | 1 | `0xFC \| chromaFormat` | SPS `chroma_format_idc` |
| 17 | 1 | `0xF8 \| bitDepthLumaMinus8` | SPS |
| 18 | 1 | `0xF8 \| bitDepthChromaMinus8` | SPS |
| 19 | 2 | `avgFrameRate` | `round(fps × 256)`, 0 if fps unknown |
| 21 | 1 | `cfr<<6 \| numTemporalLayers<<3 \| temporalIdNested<<2 \| 3` | SPS |
| 22 | 1 | `numOfArrays` | 3 or 4 |
| 23 | … | arrays | VPS, SPS, PPS, [prefix SEI] |

Vigil's fixed choices:

| Field | Value | Why |
|---|---|---|
| `array_completeness` | **1** for VPS/SPS/PPS | we guarantee no other parameter set of that type appears in the samples… |
| | **0** for the optional SEI array | …but SEI absolutely does appear in-band |
| `constantFrameRate` | **1** when `fixed_frame_rate_flag`-equivalent evidence exists (VUI timing present and `field_seq_flag == 0`), else **0** | never 2; we do not do temporal-layer-aware muxing |
| `numTemporalLayers` | `sps_max_sub_layers_minus1 + 1` | 0 ("unknown") only if no SPS parsed |
| `temporalIdNested` | `sps_temporal_id_nesting_flag` | cross-checked against VPS; SPS wins |
| `lengthSizeMinusOne` | **3** | §2.2 |
| Array order | VPS (32), SPS (33), PPS (34), then SEI (39) if present | ascending `NAL_unit_type`, as ISO recommends and as `AVFoundation` expects |

`avgFrameRate` is in **frames per 256 seconds**, i.e. `fps × 256`. 25 fps ⇒ 6400 = `0x1900`.
20 fps ⇒ 5120 = `0x1400`. Getting this wrong by a factor of 256 makes QuickTime report a 0.1 fps
movie.

### 17.1 Worked example (119 bytes)

Input: VPS from §12, SPS = vector **W1** (HEVC Main level 4.1, 1920×1080 @ 25 fps,
`conformance_window_flag == 0`), PPS = vector **Q1** (`parallelismType == 1`).

```
offset  bytes                        meaning
------  ---------------------------  ----------------------------------------------------------
00      01                           configurationVersion = 1
01      01                           profile_space=0, tier_flag=0, profile_idc=1 (Main)
02      60 00 00 00                  general_profile_compatibility_flags (flags[1],[2] set)
06      B0 00 00 00 00 00            general_constraint_indicator_flags:
                                       progressive=1, interlaced=0, non_packed=1, frame_only=1
0C      7B                           general_level_idc = 123 -> Level 4.1
0D      F0 00                        1111b | min_spatial_segmentation_idc = 0
0F      FD                           111111b | parallelismType = 1 (slice-based)
10      FD                           111111b | chromaFormat = 1 (4:2:0)
11      F8                           11111b  | bitDepthLumaMinus8 = 0
12      F8                           11111b  | bitDepthChromaMinus8 = 0
13      19 00                        avgFrameRate = 0x1900 = 6400 = 25.0 fps x 256
15      4F                           01b constantFrameRate=1, 001b numTemporalLayers=1,
                                     1b temporalIdNested=1, 11b lengthSizeMinusOne=3
16      03                           numOfArrays = 3
17      A0                           array_completeness=1, reserved=0, NAL_unit_type=32 (VPS)
18      00 01                        numNalus = 1
1A      00 18                        nalUnitLength = 24
1C      40 01 0C 01 FF FF 01 60 00   VPS NAL unit (24 bytes)
        00 03 00 B0 00 00 03 00 00
        03 00 7B 97 02 40
34      A1                           array_completeness=1, NAL_unit_type=33 (SPS)
35      00 01                        numNalus = 1
37      00 32                        nalUnitLength = 50
39      42 01 01 01 60 00 00 03 00   SPS NAL unit (50 bytes)
        B0 00 00 03 00 00 03 00 7B
        A0 03 C0 80 10 E5 96 5E 49
        1B 64 BB C0 5A 80 80 80 82
        00 00 03 00 02 00 00 03 00
        32 57 08 04 10
6B      A2                           array_completeness=1, NAL_unit_type=34 (PPS)
6C      00 01                        numNalus = 1
6E      00 07                        nalUnitLength = 7
70      44 01 E1 F3 C0 CC 90         PPS NAL unit (7 bytes)
```

Full hex, 119 bytes:
```
01 01 60 00 00 00 B0 00 00 00 00 00 7B F0 00 FD
FD F8 F8 19 00 4F 03 A0 00 01 00 18 40 01 0C 01
FF FF 01 60 00 00 03 00 B0 00 00 03 00 00 03 00
7B 97 02 40 A1 00 01 00 32 42 01 01 01 60 00 00
03 00 B0 00 00 03 00 00 03 00 7B A0 03 C0 80 10
E5 96 5E 49 1B 64 BB C0 5A 80 80 80 82 00 00 03
00 02 00 00 03 00 32 57 08 04 10 A2 00 01 00 07
44 01 E1 F3 C0 CC 90
```
base64:
`AQFgAAAAsAAAAAAAe/AA/f34+BkATwOgAAEAGEABDAH//wFgAAADALAAAAMAAAMAe5cCQKEAAQAyQgEBAWAAAAMAsAAAAwAAAwB7oAPAgBDlll5JG2S7wFqAgICCAAADAAIAAAMAMlcIBBCiAAEAB0QB4fPAzJA=`

Observe at offsets 06–0B that the constraint flags in the **record** are `B0 00 00 00 00 00`
(unescaped) while inside the **SPS NAL unit** at offsets 41–48 the same field appears as
`B0 00 00 03 00 00 03 00` (escaped). The record stores parsed field values; the NAL arrays store
on-wire bytes. Mixing the two up is the second classic `hvcC` bug.

### 17.2 Record parsing (both records)

```swift
public init(parsing data: [UInt8]) throws
```

Parsing rules, both records:

* Reject `configurationVersion != 1` with `.unsupportedRecordVersion`.
* Reject `lengthSizeMinusOne != 3` with `.unsupportedLengthSize` — we have no 1/2-byte-length code
  path anywhere and silently accepting it would produce a stream the depacketizer cannot read.
* A truncated array terminates parsing; whatever parameter sets were fully read are kept.
* `numNalus == 0` for an array is legal and yields an empty array.
* Unknown `NAL_unit_type` values in `hvcC` arrays are retained in an `other: [(UInt8, [[UInt8]])]`
  bucket so a round trip is byte-exact.
* Round-trip requirement (tested): `try Record(parsing: r.serialized()).serialized() == r.serialized()`.

---

## 18. The CoreMedia boundary (implemented in `VigilVideo`, specified here)

`VigilBitstream` cannot import CoreMedia. It publishes `ParameterSets` + `VideoFormatInfo`; exactly
one file, `VigilVideo/FormatDescriptionFactory.swift`, converts them. The signatures below are
binding on `VigilVideo`.

```swift
// macOS 14+, framework CoreMedia
func CMVideoFormatDescriptionCreateFromH264ParameterSets(
    allocator: CFAllocator?,
    parameterSetCount: Int,
    parameterSetPointers: UnsafePointer<UnsafePointer<UInt8>>,
    parameterSetSizes: UnsafePointer<Int>,
    nalUnitHeaderLength: Int32,
    formatDescriptionOut: UnsafeMutablePointer<CMFormatDescription?>
) -> OSStatus

func CMVideoFormatDescriptionCreateFromHEVCParameterSets(
    allocator: CFAllocator?,
    parameterSetCount: Int,
    parameterSetPointers: UnsafePointer<UnsafePointer<UInt8>>,
    parameterSetSizes: UnsafePointer<Int>,
    nalUnitHeaderLength: Int32,
    extensions: CFDictionary?,                 // <-- HEVC has this extra parameter
    formatDescriptionOut: UnsafeMutablePointer<CMFormatDescription?>
) -> OSStatus
```

**Which we use and why.** The `…ParameterSets` constructors are the runtime path, always:

* They accept exactly our canonical storage form (§2.1) — NAL header included, no start code, no
  length prefix, still escaped — so there is nothing to transform.
* VideoToolbox parses the SPS itself and populates `CleanAperture`, `PixelAspectRatio`,
  `FieldCount`, `ColorPrimaries`, `TransferFunction`, `YCbCrMatrix` and `FullRangeVideo` extensions.
  Hand-building the extension dictionary means re-deriving all of that from our parse, and any
  disagreement between our parse and VideoToolbox's shows up as a subtly wrong aspect ratio or a
  washed-out picture. Letting VT parse the SPS makes our parse advisory, which is exactly the
  robustness posture we want (§21).
* For HEVC they handle the `hvcC`-adjacent extension bits (`temporalIdNested`, tier) that a
  hand-built atom gets wrong.
* Parameter-set *order* is `[SPS, PPS]` for H.264 and `[VPS, SPS, PPS]` for H.265.
  `nalUnitHeaderLength` is **4**, always — it describes the length-prefix size of the *samples*, not
  the NAL header, which is the most misread argument name in CoreMedia.

`extensions` is passed `nil` except when we must force a colour space that the SPS omits (some
Hikvision HEVC substreams carry no `colour_description_present_flag`); then we pass a dictionary
with `kCVImageBufferColorPrimariesKey` = `kCVImageBufferColorPrimaries_ITU_R_709_2`,
`kCVImageBufferTransferFunctionKey` = `…_ITU_R_709_2`, `kCVImageBufferYCbCrMatrixKey` =
`…_ITU_R_709_2`. Rec. 709 is the correct default for every Hikvision camera we support.

The nested-pointer pattern (`VigilVideo` owns it; reproduced so the two specs cannot disagree):

```swift
func makeFormatDescription(_ sets: ParameterSets) throws -> CMFormatDescription {
    let ordered: [[UInt8]] = sets.codec == .h265
        ? sets.vps + sets.sps + sets.pps
        : sets.sps + sets.pps
    guard !sets.sps.isEmpty, !sets.pps.isEmpty else { throw VideoError.incompleteParameterSets }

    let sizes = ordered.map(\.count)
    // Pin every buffer, collect base pointers, then call. Nested withUnsafeBufferPointer over an
    // array of pointers: the inner arrays must stay alive for the duration of the call, which they
    // do because `ordered` outlives it.
    var pointers = [UnsafePointer<UInt8>]()
    pointers.reserveCapacity(ordered.count)
    var boxes = [UnsafeMutableBufferPointer<UInt8>]()
    defer { for b in boxes { b.deallocate() } }
    for set in ordered {
        let box = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: set.count)
        _ = box.initialize(from: set)
        boxes.append(box)
        pointers.append(UnsafePointer(box.baseAddress!))
    }

    var out: CMFormatDescription?
    let status: OSStatus = pointers.withUnsafeBufferPointer { pp in
        sizes.withUnsafeBufferPointer { ss in
            switch sets.codec {
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: ordered.count,
                    parameterSetPointers: pp.baseAddress!,
                    parameterSetSizes: ss.baseAddress!,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &out)
            case .h265:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: ordered.count,
                    parameterSetPointers: pp.baseAddress!,
                    parameterSetSizes: ss.baseAddress!,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &out)
            }
        }
    }
    guard status == noErr, let desc = out else {
        // Fallback: extension-atoms dictionary built from our own avcC/hvcC (§15 reason 4).
        return try makeFormatDescriptionFromRecord(sets)
    }
    return desc
}
```

The copy into `boxes` exists because `[[UInt8]]` gives no guarantee that nested-array storage stays
put across the outer `withUnsafeBufferPointer`; copying a few hundred bytes once per format change
is free and the alternative (recursive nesting of `withUnsafeBufferPointer` over N arrays) cannot be
written for a runtime-determined N without recursion.

Reverse direction, used when playing an MP4: `CMVideoFormatDescriptionGetH264ParameterSetAtIndex` /
`…GetHEVCParameterSetAtIndex` recover the sets; alternatively read
`kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms` and pull the `"avcC"` / `"hvcC"`
key, then hand the bytes to `AVCDecoderConfigurationRecord(parsing:)`.

---

## 19. SEI

### 19.1 Enumeration (H.264 §7.3.2.3.1, H.265 §7.3.5 — identical structure)

```
sei_rbsp():
  do {
     payloadType = 0
     while (peek u(8) == 0xFF) { payloadType += 255; read u(8) }
     payloadType += u(8)
     payloadSize = 0
     while (peek u(8) == 0xFF) { payloadSize += 255; read u(8) }
     payloadSize += u(8)
     sei_payload(payloadType, payloadSize)     // exactly payloadSize BYTES, byte-aligned
  } while (more_rbsp_data())
  rbsp_trailing_bits()
```

Both the type and the size use the `0xFF`-continuation encoding. The payload is byte-aligned and
occupies exactly `payloadSize` bytes, which makes the enumerator robust: even for a payload type we
do not understand we advance exactly `payloadSize` bytes and continue.

```swift
public enum SEI {
    /// Enumerates the SEI messages in one SEI NAL unit. `payload` is the unescaped payload,
    /// exactly `payloadSize` bytes. Zero interpretation.
    public static func enumerate(
        nalUnit nal: UnsafeRawBufferPointer, codec: VideoCodec,
        _ body: (_ payloadType: Int, _ payload: ArraySlice<UInt8>) throws -> Void
    ) throws {
        let rbsp = try RBSP.unescape(nal, skippingHeaderBytes: codec.nalHeaderLength)
        var i = 0
        while i < rbsp.count {
            var payloadType = 0
            while i < rbsp.count && rbsp[i] == 0xFF { payloadType += 255; i += 1 }
            guard i < rbsp.count else { return }              // ran into rbsp_trailing_bits
            payloadType += Int(rbsp[i]); i += 1
            var payloadSize = 0
            while i < rbsp.count && rbsp[i] == 0xFF { payloadSize += 255; i += 1 }
            guard i < rbsp.count else { throw BitstreamError.truncatedSEI }
            payloadSize += Int(rbsp[i]); i += 1
            guard i + payloadSize <= rbsp.count else { throw BitstreamError.truncatedSEI }
            try body(payloadType, rbsp[i ..< (i + payloadSize)])
            i += payloadSize
            // Stop at the rbsp_stop_one_bit: a trailing 0x80 is the trailing-bits byte, not a message.
            if i < rbsp.count && rbsp[i] == 0x80 && i == rbsp.count - 1 { return }
        }
    }
}
```

### 19.2 The messages we care about

| Type | Name | H.264 | H.265 | Vigil use |
|---:|---|:-:|:-:|---|
| 0 | `buffering_period` | ✓ | ✓ | ignored |
| 1 | **`pic_timing`** | ✓ | ✓ | `pic_struct` only (§19.4) |
| 3 | `filler_payload` | ✓ | ✓ | ignored |
| 4 | `user_data_registered_itu_t_t35` | ✓ | ✓ | ignored |
| 5 | `user_data_unregistered` | ✓ | ✓ | **Hikvision private metadata** — skipped, logged at `.debug` with the 16-byte UUID |
| 6 | **`recovery_point`** | ✓ | ✓ | opens the IRAP gate (§20.2) |
| 45 | `frame_packing_arrangement` | ✓ | — | ignored |
| 47 | `display_orientation` | ✓ | — | ignored |
| 129 | `active_parameter_sets` | — | ✓ | ignored |
| 132 | `decoded_picture_hash` | — | ✓ | ignored |
| 137 | `mastering_display_colour_volume` | — | ✓ | forwarded to `VigilVideo` for HDR metadata (future NVR HDR streams) |
| 144 | `content_light_level_info` | — | ✓ | as above |

Everything else is skipped by `payloadSize`. **Hikvision's `user_data_unregistered` is the one to
know about**: it appears on nearly every frame on many models and carries an encoder frame counter
and sometimes a wall-clock. We deliberately ignore it — RTCP SR/NTP mapping in `VigilRTP` is the
authoritative wall clock, and trusting a vendor SEI would create a second, conflicting time base.

### 19.3 `recovery_point`

H.264 (§D.2.8):
```
recovery_frame_cnt          ue(v)
exact_match_flag            u(1)
broken_link_flag            u(1)
changing_slice_group_idc    u(2)
```
H.265 (§D.3.8):
```
recovery_poc_cnt            se(v)
exact_match_flag            u(1)
broken_link_flag            u(1)
```

```swift
public struct RecoveryPoint: Sendable, Hashable {
    public var recoveryCount: Int32        // recovery_frame_cnt (H.264) or recovery_poc_cnt (H.265)
    public var exactMatch: Bool
    public var brokenLink: Bool
    public var changingSliceGroupIDC: UInt8   // H.264 only, else 0
}

public static func parseRecoveryPoint(_ payload: ArraySlice<UInt8>, codec: VideoCodec) throws -> RecoveryPoint {
    var r = try RBSPBitReader(rbsp: Array(payload))     // payload is already unescaped
    switch codec {
    case .h264:
        let cnt = Int32(try r.ue("recovery_frame_cnt", max: 65535))
        return RecoveryPoint(recoveryCount: cnt, exactMatch: try r.flag(),
                            brokenLink: try r.flag(), changingSliceGroupIDC: UInt8(try r.u(2)))
    case .h265:
        let cnt = try r.se()
        return RecoveryPoint(recoveryCount: cnt, exactMatch: try r.flag(),
                            brokenLink: try r.flag(), changingSliceGroupIDC: 0)
    }
}
```

Verified vectors:

| Codec | NAL hex | Parse |
|---|---|---|
| H.264 | `06 06 01 C4 80` | payloadType 6, payloadSize 1, `recovery_frame_cnt = 0`, `exact_match_flag = 1`, `broken_link_flag = 0`, `changing_slice_group_idc = 0` |
| H.265 | `4E 01 06 01 D0 80` | payloadType 6, payloadSize 1, `recovery_poc_cnt = 0`, `exact_match_flag = 1`, `broken_link_flag = 0` |

Note how the payload byte differs (`C4` vs `D0`) purely because `ue(0)` is one bit and `se(0)` is
one bit but the H.264 message has two extra bits: `C4` = `1 1 0 00` + `1` alignment + `00`;
`D0` = `1 1 0` + `1` alignment + `0000`. The trailing `0x80` is `rbsp_trailing_bits()`.

### 19.4 `pic_timing` — parsed only for `pic_struct`

`pic_timing` is context-dependent: its first fields exist only if the *active SPS* had
`CpbDpbDelaysPresentFlag`, and their widths come from the SPS HRD. This is why §8.3 retains
`cpbRemovalDelayLength` and `dpbOutputDelayLength`.

```swift
public static func parsePictureTiming(_ payload: ArraySlice<UInt8>, sps: H264SPS) throws -> PictureTiming {
    var r = try RBSPBitReader(rbsp: Array(payload))
    if sps.cpbDpbDelaysPresentFlag {
        try r.skip(sps.cpbRemovalDelayLength)      // cpb_removal_delay
        try r.skip(sps.dpbOutputDelayLength)       // dpb_output_delay
    }
    guard sps.picStructPresentFlag else { return PictureTiming(picStruct: 0) }
    return PictureTiming(picStruct: UInt8(try r.u(4)))
}
```

We stop after `pic_struct` and never parse the `clock_timestamp` loop.

| `pic_struct` | Meaning | `NumClockTS` | Vigil interpretation |
|---:|---|---:|---|
| 0 | frame | 1 | progressive frame |
| 1 | top field | 1 | field — mark stream interlaced |
| 2 | bottom field | 1 | field — mark stream interlaced |
| 3 | top then bottom | 2 | interlaced frame |
| 4 | bottom then top | 2 | interlaced frame |
| 5 | top, bottom, top | 3 | interlaced + repeat |
| 6 | bottom, top, bottom | 3 | interlaced + repeat |
| 7 | frame doubling | 2 | duration × 2 |
| 8 | frame tripling | 3 | duration × 3 |

**Binding decision:** `pic_struct` is used for (a) setting `VideoFormatInfo.isProgressive` when
`frame_mbs_only_flag` is 0, and (b) the diagnostics HUD. It is **not** used to compute presentation
times — live timing is RTP, recorded timing is the container's. Frame doubling/tripling from a
Hikvision camera has never been observed and would be handled by the RTP timestamp deltas anyway.

---

## 20. Access-unit classification, IRAP gating, and mid-GOP start

### 20.1 First-slice-of-picture predicate (called per frame by `VigilRTP`)

`VigilRTP` needs to know whether a VCL NAL starts a new picture; §25 of the RTP spec explains why
the RTP marker bit alone is not trustworthy on Hikvision firmware. `VigilBitstream` owns the
predicate so it exists once:

```swift
public enum SliceHeader {
    /// True when this VCL NAL is the first slice (segment) of a picture.
    /// H.264: first_mb_in_slice == 0, and first_mb_in_slice is the first ue(v) of the slice header,
    ///        so ue(v) == 0 iff the first RBSP bit is 1.
    /// H.265: first_slice_segment_in_pic_flag is literally the first RBSP bit.
    /// Either way the answer is the MSB of the first byte after the NAL header.
    @inlinable
    public static func isFirstSliceOfPicture(
        nalUnit nal: UnsafeRawBufferPointer, codec: VideoCodec
    ) -> Bool {
        let h = codec.nalHeaderLength
        guard nal.count > h else { return false }
        return nal[h] & 0x80 != 0
    }
}
```

**Why no unescaping is needed — and this must be preserved if anyone refactors it.** An
emulation-prevention `0x03` can only be inserted after two consecutive `0x00` bytes. The byte at
index `h` is preceded only by the NAL header bytes. For H.264 the header byte of a VCL NAL is
non-zero (`nal_unit_type` ∈ 1…5 occupies the low 5 bits). For H.265 the second header byte is
`((layerID & 0x1F) << 3) | (temporalID + 1)` and `temporalID + 1 ≥ 1`, so it is non-zero. Therefore
the first payload byte can never be an escape byte, and reading it raw is exact. Cost: one bounds
check and one load, no allocation, per NAL — which is what makes 16 simultaneous streams affordable.

### 20.2 Access-unit summary and the gate

```swift
public struct AccessUnitSummary: Sendable {
    public var codec: VideoCodec
    public var containsIRAP: Bool           // H.264: type 5; H.265: 16...23
    public var containsCRAOrBLA: Bool       // H.265: 16...18, 21
    public var containsIDR: Bool            // H.264: 5; H.265: 19, 20
    public var containsRASL: Bool           // H.265: 8, 9
    public var containsVCL: Bool
    public var recoveryPoint: RecoveryPoint?
    public var parameterSetsAvailable: Bool // the store holds a complete, self-consistent set
    public var firstSliceSeen: Bool
}

public struct IRAPGate: Sendable {
    public enum Decision: Sendable, Equatable {
        case pass
        case drop(DropReason)
    }
    public enum DropReason: String, Sendable, Equatable {
        case awaitingIRAP            // stream started mid-GOP
        case missingParameterSets    // IRAP arrived before SPS/PPS
        case raslAfterCRAStart       // H.265 RASL with NoRaslOutputFlag == 1
        case brokenLink              // recovery_point with broken_link_flag == 1
        case nonVCLOnly              // AU had no VCL NAL at all
    }

    public struct Policy: Sendable {
        /// Accept a non-IRAP AU that carries a recovery_point SEI with exact_match_flag == 1.
        public var acceptRecoveryPointSEI = true
        /// Accept a recovery_point SEI even when exact_match_flag == 0 (picture may differ slightly).
        public var acceptInexactRecoveryPoint = false
        /// After this long with no IRAP, open the gate on any AU and accept the artefacts, so the
        /// user sees *something* rather than a permanently black tile on broken firmware.
        public var desperationTimeout: Duration? = .seconds(12)
        public static let strict = Policy()
        public static let recordedPlayback = Policy(acceptRecoveryPointSEI: false,
                                                    acceptInexactRecoveryPoint: false,
                                                    desperationTimeout: nil)
    }

    public init(codec: VideoCodec, policy: Policy = .strict)
    public private(set) var isOpen: Bool
    /// True while the gate is closed and no IRAP has been seen for > 1 GOP interval; `VigilCore`
    /// polls this and issues an ISAPI/RTSP keyframe request. Cleared once an IRAP arrives.
    public private(set) var shouldRequestKeyframe: Bool
    public private(set) var droppedAccessUnits: Int

    public mutating func evaluate(_ au: AccessUnitSummary, at now: ContinuousClock.Instant) -> Decision
    /// Call after any decoder reset, seek, or `kVTInvalidSessionErr`.
    public mutating func reset()
}
```

Gate algorithm:

```
if !au.containsVCL                                 -> .drop(.nonVCLOnly)   (parameter sets and SEI
                                                       are still ingested by the store first)
if !isOpen:
    if !au.parameterSetsAvailable                  -> .drop(.missingParameterSets)
    if au.containsIRAP:
        if let rp = au.recoveryPoint, rp.brokenLink -> .drop(.brokenLink)
        isOpen = true
        if codec == .h265 && au.containsCRAOrBLA { noRaslOutputFlag = true }
        -> .pass
    if policy.acceptRecoveryPointSEI,
       let rp = au.recoveryPoint,
       rp.exactMatch || policy.acceptInexactRecoveryPoint,
       !rp.brokenLink:
        isOpen = true                              -> .pass
    if let t = policy.desperationTimeout, now - firstAUInstant > t:
        isOpen = true; logger.warning("opening IRAP gate on timeout, expect artefacts")
        -> .pass
    -> .drop(.awaitingIRAP)
// gate open
if noRaslOutputFlag && au.containsRASL             -> .drop(.raslAfterCRAStart)
if !au.containsRASL { noRaslOutputFlag = false }    // first non-RASL AU clears it
-> .pass
```

### 20.3 Why the RASL rule exists

When decoding begins at a CRA (or a BLA), H.265 sets `NoRaslOutputFlag = 1` for that picture, and
the associated RASL pictures reference frames that precede the CRA and are therefore **not
available**. The standard requires them to be discarded. If we forward them, VideoToolbox returns
`kVTVideoDecoderBadDataErr` (best case) or emits pixel garbage that looks like a corrupted keyframe
(worse case, and the one users report as "the camera flashes green when I seek"). This is reachable
in Vigil on **NVR playback seeks**, which land on a CRA, not on live streams.

The flag is cleared by the first access unit that contains no RASL NAL. It is also cleared by
`reset()`.

### 20.4 Detecting that a stream started mid-GOP

We do not need to *detect* it — we assume it. A Hikvision camera begins sending at the next packet
after `PLAY`, which is almost never an IRAP boundary; with the default I-frame interval of 50 at
25 fps the expected wait is ~1 s and the worst case 2 s. Therefore:

* The gate starts **closed** on every `PLAY`, every reconnect, and every decoder reset.
* Two independent mitigations shorten the wait, both of which are other modules' work but depend on
  this module's contract:
  1. `VigilRTSP` extracts `sprop-parameter-sets` (H.264) / `sprop-vps`, `sprop-sps`, `sprop-pps`
     (H.265) from the SDP `fmtp` line and hands the base64-decoded NAL units to
     `ParameterSetStore.ingest` **before** the first RTP packet arrives, so
     `parameterSetsAvailable` is already true when the first IDR shows up and no GOP is wasted
     waiting for in-band parameter sets.
  2. `VigilCore` issues a keyframe request when `shouldRequestKeyframe` becomes true (Hikvision
     ISAPI `PUT /ISAPI/Streaming/channels/<id>/requestKeyFrame`, and as a fallback an RTSP
     re-`PLAY`).
* While the gate is closed the UI shows the connecting shimmer, not black — `VigilCore` observes
  `droppedAccessUnits` and the gate state.

### 20.5 Keyframe classification (what `EncodedFrame.isKeyframe` means)

| Codec | `isKeyframe == true` iff the AU contains | Notes |
|---|---|---|
| H.264 | a NAL of type **5** (IDR) | An I-slice of type 1 is *not* a keyframe: without an IDR the DPB is not reset and a decoder cannot start there. Recognised only via `recovery_point`. |
| H.265 | a NAL of type in **16…23** (IRAP) | Includes CRA and BLA. |

`AVAssetWriter` uses this for the sync-sample flag, and `VigilVideo` uses it for the
`kCMSampleAttachmentKey_NotSync` attachment (present ⇔ `!isKeyframe`), so a wrong answer here
produces an unseekable recording.

---

## 21. `ParameterSetStore` and format-change detection

```swift
public struct ParameterSetStore: Sendable {
    public init(codec: VideoCodec)

    public private(set) var sets: ParameterSets
    /// nil when no SPS has parsed successfully yet — but `sets` may still be complete and usable.
    public private(set) var format: VideoFormatInfo?
    public private(set) var h264SPS: H264SPS?
    public private(set) var h264PPS: [UInt32: H264PPS]
    public private(set) var h265VPS: H265VPS?
    public private(set) var h265SPS: H265SPS?
    public private(set) var h265PPS: [UInt32: H265PPS]

    /// Increments whenever the decode-relevant bytes change. `VigilVideo` compares this against the
    /// generation its current VTDecompressionSession / AVSampleBufferDisplayLayer was built from.
    public private(set) var generation: UInt32

    @discardableResult
    public mutating func ingest(nalUnit: UnsafeRawBufferPointer) -> IngestResult

    public enum IngestResult: Sendable, Equatable {
        case notAParameterSet
        case unchanged                       // byte-identical re-send; the common case
        case stored(generation: UInt32)      // new or changed bytes, same picture format
        case formatChanged(generation: UInt32, from: VideoFormatInfo?, to: VideoFormatInfo?)
    }

    /// True when everything needed to build a format description is present.
    public var isComplete: Bool {
        switch sets.codec {
        case .h264: return !sets.sps.isEmpty && !sets.pps.isEmpty
        case .h265: return !sets.vps.isEmpty && !sets.sps.isEmpty && !sets.pps.isEmpty
        }
    }
    public mutating func reset()
}
```

### 21.1 The parse-failure policy (binding, and it is the important one)

```
ingest(nalUnit:):
  1. classify the NAL. Not 7/8/13 (H.264) or 32/33/34 (H.265) -> .notAParameterSet
  2. if the stored bytes for that (type, id) are byte-identical -> .unchanged   [fast path,
     hit on essentially every IDR, so it must be a memcmp and nothing more]
  3. store the bytes (replacing same-id, appending otherwise). Bump `generation`.
  4. TRY to parse. On success, recompute `format`.
     On failure: log at .error, leave `format` unchanged (or nil), and STILL KEEP THE BYTES.
  5. return .formatChanged if codedWidth/codedHeight/codec/chromaFormat/bitDepth changed,
     else .stored
```

Step 4 is the policy: **a parameter set we cannot parse is still forwarded to the decoder.**
VideoToolbox has its own, more permissive parser and frequently decodes streams our parser rejects.
Our parse exists for metadata (window sizing, HUD, decode budget, `hvcC` fields) and for the IRAP
gate — none of which are prerequisites for decoding. A camera that trips our parser must still show
a picture. Conversely, `isComplete` is about *bytes*, never about parse success.

### 21.2 What counts as a format change

Only these five fields, compared between the old and new `VideoFormatInfo`:

| Field | Why it forces a decode-session rebuild |
|---|---|
| `codec` | different decoder |
| `codedWidth`, `codedHeight` | VideoToolbox session and pixel-buffer pool are size-bound |
| `chromaFormatIDC` | different output pixel format |
| `bitDepthLuma` | 8-bit vs 10-bit output format (`420YpCbCr8…` vs `420YpCbCr10…`) |

Deliberately **not** a format change: a new SAR, a new frame rate, new colour description, new
cropping offsets that leave the coded size intact, a re-sent identical SPS, or a new PPS. Those
update `format` and bump `generation` but `VigilVideo` keeps its session — rebuilding on every SPS
re-send (i.e. every 2 seconds) would make the picture stutter forever. `VigilVideo` reacts to
`generation` by rebuilding the `CMFormatDescription` (cheap) and to `formatChanged` by draining and
recreating the decode session (expensive; see the video-pipeline spec for the no-black-flash drain).

### 21.3 Identity hash

```swift
extension ParameterSets {
    /// FNV-1a 64 over codec + every set's length and bytes, in array order.
    /// Used for O(1) "is this the same configuration" checks in caches and in the recorder,
    /// never for security. Not stable across app versions and not persisted.
    public var identity: UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ b: UInt8) { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        mix(codec == .h264 ? 1 : 2)
        for group in [vps, sps, pps] {
            mix(UInt8(truncatingIfNeeded: group.count))
            for set in group {
                mix(UInt8(truncatingIfNeeded: set.count >> 8))
                mix(UInt8(truncatingIfNeeded: set.count))
                for b in set { mix(b) }
            }
        }
        return h
    }
}
```

---

## 22. Complete public API of `VigilBitstream`

```swift
// ── Errors ─────────────────────────────────────────────────────────────────────
public enum BitstreamError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyNALUnit
    case tooLarge(bytes: Int)
    case unexpectedEndOfData(atBit: Int)
    case malformedExpGolomb(leadingZeros: Int)
    case valueOutOfRange(field: String, value: UInt64)
    case wrongNALType(expected: UInt8, found: UInt8)
    case forbiddenBitSet
    case invalidTemporalID
    case negativeSkip
    case invalidCropping
    case unsupportedSyntax(String)
    case truncatedSEI
    case truncatedLengthPrefix(atOffset: Int)
    case unsupportedRecordVersion(UInt8)
    case unsupportedLengthSize(UInt8)
    case invalidBase64
    public var description: String { get }
}

// ── NAL types ──────────────────────────────────────────────────────────────────
public enum H264NALType: UInt8, Sendable, Hashable, CaseIterable { /* §3.1 */ }
public enum H265NALType: UInt8, Sendable, Hashable, CaseIterable { /* §3.2 */ }
public struct NALUnitRef: Sendable, Hashable {
    public let range: Range<Int>        // into the source buffer, NAL header included
    public let typeCode: UInt8
    public let layerID: UInt8           // H.265; 0 for H.264
    public let temporalID: UInt8        // H.265; 0 for H.264
}
public enum NALHeader {
    public static func decodeH264(_ b0: UInt8) throws -> (type: UInt8, refIdc: UInt8)
    public static func decodeHEVC(_ b0: UInt8, _ b1: UInt8) throws -> (type: UInt8, layerID: UInt8, temporalID: UInt8)
    public static func encodeHEVC(type: UInt8, layerID: UInt8, temporalID: UInt8) -> (UInt8, UInt8)
    /// Reads the type code from a NAL unit of either codec.
    @inlinable public static func typeCode(_ nal: UnsafeRawBufferPointer, codec: VideoCodec) throws -> UInt8
}

// ── Annex-B / length-prefixed ──────────────────────────────────────────────────
public enum AnnexB {
    public static func findStartCode(in: UnsafeRawBufferPointer, from: Int) -> (index: Int, length: Int)?
    public static func enumerateNALUnits(in: UnsafeRawBufferPointer, _ body: (Range<Int>) throws -> Void) rethrows
    public static func nalRanges(_ bytes: [UInt8]) -> [Range<Int>]
    public static func toLengthPrefixed(_ annexB: [UInt8]) -> [UInt8]
    public static func toLengthPrefixedInPlace(_ buffer: inout [UInt8]) -> Bool
    public static func fromLengthPrefixed(_ prefixed: [UInt8], startCodeLength: Int = 4) throws -> [UInt8]
    public static func fromLengthPrefixedInPlace(_ buffer: inout [UInt8]) throws
}
public enum LengthPrefixed {
    public static func enumerate(_ bytes: UnsafeRawBufferPointer, codec: VideoCodec,
                                _ body: (Range<Int>, UInt8) throws -> Void) throws
    public static func validate(_ bytes: UnsafeRawBufferPointer) -> Bool
    @inlinable public static func appendLength(_ n: Int, to out: inout [UInt8])
    /// Writes `nal` prefixed by its 4-byte big-endian length. The one function `VigilRTP` uses.
    @inlinable public static func append(nal: UnsafeRawBufferPointer, to out: inout [UInt8])
}

// ── RBSP / bit reading ─────────────────────────────────────────────────────────
public enum RBSP {
    public static func unescape(_ nal: UnsafeRawBufferPointer, skippingHeaderBytes: Int) throws -> [UInt8]
    public static func escape(_ rbsp: [UInt8]) -> [UInt8]
    /// Count of emulation-prevention bytes, without allocating. For diagnostics.
    public static func escapeByteCount(_ nal: UnsafeRawBufferPointer, skippingHeaderBytes: Int) -> Int
}
public struct RBSPBitReader: Sendable { /* §7 */ }

// ── Parsers ────────────────────────────────────────────────────────────────────
public enum H264Parser {
    public static func parseSPS(_ nal: UnsafeRawBufferPointer) throws -> H264SPS
    public static func parsePPS(_ nal: UnsafeRawBufferPointer) throws -> H264PPS
    public static func parseSPS(base64: String) throws -> H264SPS
    /// Splits an SDP `sprop-parameter-sets` value ("<b64>,<b64>") into NAL units.
    public static func parseSpropParameterSets(_ value: String) throws -> [[UInt8]]
}
public enum H265Parser {
    public static func parseVPS(_ nal: UnsafeRawBufferPointer) throws -> H265VPS
    public static func parseSPS(_ nal: UnsafeRawBufferPointer) throws -> H265SPS
    public static func parsePPS(_ nal: UnsafeRawBufferPointer) throws -> H265PPS
    public static func parseSPS(base64: String) throws -> H265SPS
}
public struct ProfileTierLevel: Sendable, Hashable, Codable { /* §11 */ }
public struct H264SPS: Sendable, Hashable, Codable { /* §10 */ }
public struct H264PPS: Sendable, Hashable, Codable { /* §10 */ }
public struct H265VPS: Sendable, Hashable, Codable { /* §12 */ }
public struct H265SPS: Sendable, Hashable, Codable { /* §13.7 */ }
public struct H265PPS: Sendable, Hashable, Codable { /* §14 */ }

// ── The neutral format description ─────────────────────────────────────────────
public struct VideoFormatInfo: Sendable, Hashable, Codable {
    public var codec: VideoCodec
    public var codedWidth: Int
    public var codedHeight: Int
    public var displayWidth: Int
    public var displayHeight: Int
    public var sarWidth: Int
    public var sarHeight: Int
    public var frameRate: Double?
    public var profileIDC: UInt8
    public var constraintFlags: UInt8          // H.264 only
    public var levelIDC: UInt8
    public var tier: UInt8                     // H.265 only, 0 = Main tier
    public var chromaFormatIDC: UInt8
    public var bitDepthLuma: Int
    public var bitDepthChroma: Int
    public var isProgressive: Bool
    public var colourPrimaries: UInt8?
    public var transferCharacteristics: UInt8?
    public var matrixCoefficients: UInt8?
    public var fullRange: Bool
    public var maxNumReorderFrames: Int
    public var maxDecFrameBuffering: Int
    public var minSpatialSegmentationIDC: Int
    public var numTemporalLayers: Int
    public var temporalIDNested: Bool
    public var profileName: String
    public var levelName: String

    public var pixelAspectRatio: Double { Double(sarWidth) / Double(sarHeight) }
    /// Display aspect ratio including SAR. This is what the window and the tile use.
    public var displayAspectRatio: Double {
        Double(displayWidth) * pixelAspectRatio / Double(displayHeight)
    }
    /// Pixel count for the decode-budget cost function in VigilVideo.
    public var codedPixels: Int { codedWidth * codedHeight }

    public init(_ sps: H264SPS)
    public init(_ sps: H265SPS, vps: H265VPS?, pps: H265PPS?)
}

// ── Records ────────────────────────────────────────────────────────────────────
public struct AVCDecoderConfigurationRecord: Sendable, Hashable {
    public var avcProfileIndication: UInt8
    public var profileCompatibility: UInt8
    public var avcLevelIndication: UInt8
    public var lengthSizeMinusOne: UInt8            // always 3
    public var sequenceParameterSets: [[UInt8]]
    public var pictureParameterSets: [[UInt8]]
    public var chromaFormat: UInt8?
    public var bitDepthLumaMinus8: UInt8?
    public var bitDepthChromaMinus8: UInt8?
    public var sequenceParameterSetExt: [[UInt8]]
    public init(sps: [[UInt8]], pps: [[UInt8]], spsExt: [[UInt8]] = []) throws
    public init(parsing data: [UInt8]) throws
    public func serialized() -> [UInt8]
    public var parameterSets: ParameterSets { get }
}
public struct HEVCDecoderConfigurationRecord: Sendable, Hashable {
    public var ptl: ProfileTierLevel
    public var minSpatialSegmentationIDC: UInt16
    public var parallelismType: UInt8
    public var chromaFormat: UInt8
    public var bitDepthLumaMinus8: UInt8
    public var bitDepthChromaMinus8: UInt8
    public var avgFrameRate: UInt16                 // fps * 256
    public var constantFrameRate: UInt8
    public var numTemporalLayers: UInt8
    public var temporalIDNested: Bool
    public var lengthSizeMinusOne: UInt8            // always 3
    /// One entry per hvcC array, in ascending nalType order: 32 VPS, 33 SPS, 34 PPS, [39 SEI].
    /// A struct rather than a tuple so the record stays Hashable.
    public struct NALArray: Sendable, Hashable {
        public var arrayCompleteness: Bool
        public var nalUnitType: UInt8
        public var nalUnits: [[UInt8]]
    }
    public var arrays: [NALArray]
    public init(vps: [[UInt8]], sps: [[UInt8]], pps: [[UInt8]], sei: [[UInt8]] = [],
                parsedSPS: H265SPS, parsedPPS: H265PPS?) throws
    public init(parsing data: [UInt8]) throws
    public func serialized() -> [UInt8]
    public var parameterSets: ParameterSets { get }
}

// ── SEI ────────────────────────────────────────────────────────────────────────
public enum SEI {
    public static func enumerate(nalUnit: UnsafeRawBufferPointer, codec: VideoCodec,
                                _ body: (Int, ArraySlice<UInt8>) throws -> Void) throws
    public static func parseRecoveryPoint(_ payload: ArraySlice<UInt8>, codec: VideoCodec) throws -> RecoveryPoint
    public static func parsePictureTiming(_ payload: ArraySlice<UInt8>, sps: H264SPS) throws -> PictureTiming
}
public struct RecoveryPoint: Sendable, Hashable { /* §19.3 */ }
public struct PictureTiming: Sendable, Hashable { public var picStruct: UInt8 }

// ── Classification / gating ────────────────────────────────────────────────────
public enum SliceHeader {
    @inlinable public static func isFirstSliceOfPicture(nalUnit: UnsafeRawBufferPointer, codec: VideoCodec) -> Bool
}
public struct AccessUnitSummary: Sendable { /* §20.2 */ }
public struct IRAPGate: Sendable { /* §20.2 */ }
public struct ParameterSetStore: Sendable { /* §21 */ }
public enum SampleAspectRatio { public static let table: [UInt8: (Int, Int)] }
```

Concurrency: every type above is a `Sendable` value type or a namespace `enum`. There is no class,
no actor and no shared mutable state in `VigilBitstream`. `ParameterSetStore` and `IRAPGate` are
structs owned by whichever actor drives the stream (the `StreamCoordinator` actor in `VigilCore`),
which is what makes the module trivially safe under Swift 6 strict concurrency.

---

## 23. Unit-test vectors (mandatory)

### 23.1 Provenance

Vectors **V1–V7** (H.264) and **W1–W4** (H.265) are byte-exact fixtures generated by an independent
reference encoder and validated by round-tripping through an independent reference parser while
writing this specification. Their parameter values were chosen to match the configurations Hikvision
cameras and NVRs actually emit (Main/High profile 1080p25 with 1088→1080 cropping, 2560×1440@20,
704×576 substreams, HEVC Main 1080p25, HEVC 2688×1520@20, Main 10) **plus** the awkward paths that
real firmware occasionally takes (scaling lists present, MBAFF, `pic_order_cnt_type == 1`,
conformance window, inter-predicted RPS, two temporal sub-layers). They are the normative regression
corpus and they are exact: every field in the tables below was produced by parsing the given bytes.

They are *not* claimed to be captures from a specific camera. Implementers **must additionally**
commit real captures, using this procedure:

1. `DESCRIBE rtsp://<cam>/Streaming/Channels/101` and copy the `fmtp` line's
   `sprop-parameter-sets` (H.264) or `sprop-vps` / `sprop-sps` / `sprop-pps` (H.265).
2. Add one `XCTest` case per capture with the model string and firmware version in the test name,
   e.g. `test_DS2CD2385FWD_I_V5_7_3_H265_MainStream()`.
3. Assert `displayWidth`, `displayHeight`, `frameRate`, `sarWidth/sarHeight`, `profileIDC`,
   `levelIDC` and — for HEVC — `ptl.generalConstraintIndicatorFlags`.
4. Assert the `avcC`/`hvcC` round trip: `Record(parsing: built.serialized()).serialized() == built.serialized()`.

Any capture that fails to parse is a bug in the parser, not in the camera, until proven otherwise:
add it to the corpus with an `XCTExpectFailure` and fix the parser.

### 23.2 H.264 SPS vectors

| ID | Base64 | Bytes |
|---|---|---:|
| V1 | `Z00AKPQDwBE/LgIgAAADACAAAAZQgA==` | 22 |
| V2 | `Z2QAKawsrAeAIn5cBagICAoAAAMAAgAAAwB5Ht8=` | 29 |
| V3 | `Z2QAMqzoAoALWwEQAAADABAAAAMCiEA=` | 23 |
| V4 | `Z0KAHtoCwEm/8ADAALEAAAMAAQAAAwAeBA==` | 25 |
| V5 | `Z2QAKK3//////////////////////////////////////+UB4AiflwEQAAADABAAAAMDKEA=` | 53 |
| V6 | `Z00AKPYDwCJ+8BEAAAMAAQAAAwAyhA==` | 22 |
| V7 | `Z00AH9CyCBIQYCgC3YCIAAADAAgAAAMBlCA=` | 26 |

Hex:
```
V1  67 4D 00 28 F4 03 C0 11 3F 2E 02 20 00 00 03 00 20 00 00 06 50 80
V2  67 64 00 29 AC 2C AC 07 80 22 7E 5C 05 A8 08 08 0A 00 00 03 00 02 00 00 03 00 79 1E DF
V3  67 64 00 32 AC E8 02 80 0B 5B 01 10 00 00 03 00 10 00 00 03 02 88 40
V4  67 42 80 1E DA 02 C0 49 BF F0 00 C0 00 B1 00 00 03 00 01 00 00 03 00 1E 04
V5  67 64 00 28 AD FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF
    FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF E5 01 E0
    08 9F 97 01 10 00 00 03 00 10 00 00 03 03 28 40
V6  67 4D 00 28 F6 03 C0 22 7E F0 11 00 00 03 00 01 00 00 03 00 32 84
V7  67 4D 00 1F D0 B2 08 12 10 60 28 02 DD 80 88 00 00 03 00 08 00 00 03 01 94 20
```

Expected parse — the assertions each test must make:

| Field | V1 | V2 | V3 | V4 | V5 | V6 | V7 |
|---|---|---|---|---|---|---|---|
| `profileIDC` | 77 | 100 | 100 | 66 | 100 | 77 | 77 |
| profile name | Main | High | High | Baseline | High | Main | Main |
| `constraintFlags` (SPS byte 2) | `0x00` | `0x00` | `0x00` | `0x80` | `0x00` | `0x00` | `0x00` |
| `levelIDC` / name | 40 / 4.0 | 41 / 4.1 | 50 / 5.0 | 30 / 3.0 | 40 / 4.0 | 40 / 4.0 | 31 / 3.1 |
| `seqParameterSetID` | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `chromaFormatIDC` | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| bit depths | 8 / 8 | 8 / 8 | 8 / 8 | 8 / 8 | 8 / 8 | 8 / 8 | 8 / 8 |
| `seqScalingMatrixPresent` | false | false | false | n/a | **true** | false | false |
| `log2MaxFrameNum` | 4 | 8 | 4 | 4 | 4 | 4 | 4 |
| `picOrderCntType` | 0 | 0 | 0 | **2** | 0 | 0 | **1** |
| `log2MaxPicOrderCntLsb` | 4 | 8 | 4 | — | 4 | 4 | — |
| `offsetForRefFrame` | — | — | — | — | — | — | `[4, -4, 8]` |
| `offsetForNonRefPic` | — | — | — | — | — | — | −2 |
| `maxNumRefFrames` | 1 | 2 | 1 | 1 | 4 | 2 | 2 |
| `picWidthInMbs` | 120 | 120 | 160 | 44 | 120 | 120 | 80 |
| `picHeightInMapUnits` | 68 | 68 | 90 | 36 | 68 | **34** | 45 |
| `frameMbsOnlyFlag` | 1 | 1 | 1 | 1 | 1 | **0** | 1 |
| `mbAdaptiveFrameFieldFlag` | — | — | — | — | — | **true** | — |
| crop (l,r,t,b) | 0,0,0,4 | 0,0,0,4 | 0,0,0,0 | 0,0,0,0 | 0,0,0,4 | 0,0,0,**2** | 0,0,0,0 |
| CropUnitX / CropUnitY | 2 / 2 | 2 / 2 | 2 / 2 | 2 / 2 | 2 / 2 | 2 / **4** | 2 / 2 |
| **coded** W×H | 1920×1088 | 1920×1088 | 2560×1440 | 704×576 | 1920×1088 | 1920×1088 | 1280×720 |
| **display** W×H | **1920×1080** | **1920×1080** | **2560×1440** | **704×576** | **1920×1080** | **1920×1080** | **1280×720** |
| `aspectRatioIDC` | 1 | 1 | 1 | **255** | 1 | 1 | 1 |
| SAR | 1:1 | 1:1 | 1:1 | **12:11** | 1:1 | 1:1 | 1:1 |
| `numUnitsInTick` / `timeScale` | 1 / 50 | 1 / 60 | 1 / 40 | 1 / 30 | 1 / 50 | 1 / 50 | 1 / 50 |
| **fps** | **25.0** | **30.0** | **20.0** | **15.0** | **25.0** | **25.0** | **25.0** |
| `maxNumReorderFrames` | — | 0 | — | — | — | — | — |
| `maxDecFrameBuffering` | — | 0 | — | — | — | — | — |
| colour primaries / transfer / matrix | — | 1/1/1 | — | — | — | — | — |
| `isProgressive` | true | true | true | true | true | **false** | true |
| RBSP bits consumed / available | 152 / 160 | 207 / 208 | 153 / 160 | 173 / 176 | 393 / 400 | 149 / 152 | 178 / 184 |

The last row is the strongest single assertion in the suite: it proves the parse consumed exactly
the right number of bits, so every skip loop (scaling lists in V5, the POC type 1 cycle in V7, the
VUI/HRD in V2) landed on the correct bit. `bitsConsumed` must always be within 8 bits of the
available total, the slack being `rbsp_trailing_bits()`. Expose it as
`H264SPS.debugBitsConsumed: Int` under `#if DEBUG` or as an internal property visible via
`@testable import`.

Notes on individual vectors:

* **V1** is the reference 1080p case: 1088 coded rows cropped to 1080 with `CropUnitY = 2`. Also the
  emulation-prevention showcase — `num_units_in_tick = 1` and `time_scale = 50` are 32-bit fields
  full of zero bytes, producing two `0x03` insertions (`00 00 03 00` at bytes 12–15 and again at
  17–20).
* **V2** exercises `bitstream_restriction_flag`, giving `maxNumReorderFrames = 0` and
  `maxDecFrameBuffering = 0` — the "this stream has no reordering, decode with zero latency" signal
  that `VigilVideo`'s low-latency path keys on.
* **V4** is the only vector with a non-square SAR (12:11) and with `pic_order_cnt_type == 2`, and the
  only one whose `constraintFlags` is non-zero: `0x80` is `constraint_set0_flag`, **not**
  `constraint_set1_flag`, so `profileName` must report plain **"Baseline"**. Reporting
  "Constrained Baseline" here is the exact bug the vector exists to catch — Constrained Baseline
  requires `constraint_set1_flag` (mask `0x40`). `displayAspectRatio` = 704 × (12/11) / 576 = 4:3
  exactly, which is the assertion that proves SAR is applied to the *display* size rather than
  ignored.
* **V5** has all eight scaling lists present with every `delta_scale == 0` (each coded as a single
  `1` bit, hence the run of `0xFF`). It is the `skipScalingList` regression: 6 × 16 + 2 × 64 = 224
  `se(v)` reads must be consumed. A parser that skips a fixed number of bits, or that stops on
  `nextScale == 0`, lands in the wrong place and reports a nonsense resolution.
* **V6** is interlaced/MBAFF: `frame_mbs_only_flag == 0` doubles both the height derivation
  (34 map units × 2 × 16 = 1088) and `CropUnitY` (2 × 2 = 4), so `frame_crop_bottom_offset = 2`
  removes 8 rows. Getting `CropUnitY` wrong here yields 1084 or 1080 by luck; the vector catches it.
* **V7** carries a three-entry `offset_for_ref_frame` cycle. If the loop is skipped or mis-bounded,
  `maxNumRefFrames` reads as garbage and the resolution is wrong.

### 23.3 H.264 PPS vectors

| ID | Base64 | Hex | Assertions |
|---|---|---|---|
| P1 | `aO48gA==` | `68 EE 3C 80` | pps_id 0, sps_id 0, CABAC true, `usesSliceGroups` false, `transform8x8ModeFlag` **false**, `moreRBSPData()` **false** at the decision point, 16 of 24 bits consumed |
| P2 | `aO48sA==` | `68 EE 3C B0` | as P1 but `transform8x8ModeFlag` **true**, `moreRBSPData()` **true**, 17 of 24 bits consumed |

### 23.4 H.265 vectors

VPS (24 bytes) — `QAEMAf//AWAAAAMAsAAAAwAAAwB7lwJA`
```
40 01 0C 01 FF FF 01 60 00 00 03 00 B0 00 00 03 00 00 03 00 7B 97 02 40
```
Assertions: `vpsID = 0`, `maxLayersMinus1 = 0`, `maxSubLayersMinus1 = 0`,
`temporalIDNestingFlag = true`, reserved field == `0xFFFF`, PTL `generalProfileIDC = 1`,
`generalLevelIDC = 123`.

| ID | Base64 | Bytes |
|---|---|---:|
| W1 | `QgEBAWAAAAMAsAAAAwAAAwB7oAPAgBDlll5JG2S7wFqAgICCAAADAAIAAAMAMlcIBBA=` | 50 |
| W2 | `QgEBAWAAAAMAsAAAAwAAAwB7oAPIgBEHEy5ZeSRtm+t14CAgAAADACAAAAMDJRcIBBA=` | 50 |
| W3 | `QgEDAWAAAAMAsAAAAwAAAwCWwAABYAAAAwCwAAADAAADAJagAVAgBfFlly8kjbJd4CAgAAADACAAAAMChXCAQQ==` | 64 |
| W4 | `QgEBAiQAAAMAsAAAAwAAAwB7oAPAgBDk2WXkkbZLvAQEAAADAAQAAAMAZK4QCCA=` | 47 |

| Field | W1 | W2 | W3 | W4 |
|---|---|---|---|---|
| `sps_video_parameter_set_id` | 0 | 0 | 0 | 0 |
| `sps_max_sub_layers_minus1` | 0 | 0 | **1** | 0 |
| `sps_temporal_id_nesting_flag` | true | true | true | true |
| `generalProfileSpace` / `generalTierFlag` | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| `generalProfileIDC` / name | 1 / Main | 1 / Main | 1 / Main | **2 / Main 10** |
| `generalProfileCompatibilityFlags` | `0x60000000` | `0x60000000` | `0x60000000` | **`0x24000000`** |
| `generalConstraintIndicatorFlags` | `0xB00000000000` | `0xB00000000000` | `0xB00000000000` | `0xB00000000000` |
| progressive / interlaced / non_packed / frame_only | 1/0/1/1 | 1/0/1/1 | 1/0/1/1 | 1/0/1/1 |
| `generalLevelIDC` / name | 123 / 4.1 | 123 / 4.1 | **150 / 5.0** | 123 / 4.1 |
| `subLayerLevelIDC` | `[]` | `[]` | **`[150]`** | `[]` |
| `chromaFormatIDC` | 1 | 1 | 1 | 1 |
| bit depths | 8 / 8 | 8 / 8 | 8 / 8 | **10 / 10** |
| `log2MaxPicOrderCntLsb` | 8 | 8 | 8 | 8 |
| **coded** W×H | 1920×1080 | **1936×1088** | 2688×1520 | 1920×1080 |
| conformance window (l,r,t,b) | 0,0,0,0 | **0,8,0,4** | 0,0,0,0 | 0,0,0,0 |
| SubWidthC / SubHeightC | 2 / 2 | 2 / 2 | 2 / 2 | 2 / 2 |
| **display** W×H | **1920×1080** | **1920×1080** | **2688×1520** | **1920×1080** |
| `minCbLog2SizeY` / `ctbLog2SizeY` / `ctbSizeY` | 3 / 6 / 64 | 3 / 6 / 64 | 3 / 6 / 64 | 3 / 6 / 64 |
| `numShortTermRefPicSets` | 1 | **2** | 1 | 1 |
| `numDeltaPocs` | `[1]` | **`[2, 3]`** | `[1]` | `[1]` |
| `numUnitsInTick` / `timeScale` | 1 / 25 | 1 / 25 | 1 / 20 | 1 / 25 |
| **fps** | **25.0** | **25.0** | **20.0** | **25.0** |
| SAR | 1:1 | 1:1 | 1:1 | 1:1 |
| `minSpatialSegmentationIDC` | 0 | **4** | 0 | 0 |
| colour primaries / transfer / matrix | 1/1/1 | — | — | — |
| `numTemporalLayers` | 1 | 1 | **2** | 1 |
| `sps_extension_present_flag` | false | false | false | false |
| RBSP bits consumed / available | 339 / 344 | 339 / 344 | 431 / 432 | 314 / 320 |

Notes:

* **W2** is the important one. It has (a) a conformance window that must be multiplied by
  `SubWidthC`/`SubHeightC` — `1936 − 2·8 = 1920`, `1088 − 2·4 = 1080` — and (b) two short-term RPSs
  where the second is **inter-predicted** from the first. `NumDeltaPocs[0] = 2`, so
  `st_ref_pic_set(1)` reads `NumDeltaPocs[0] + 1 = 3` flag groups and derives
  `NumDeltaPocs[1] = 3`. It also sets `min_spatial_segmentation_idc = 4`, which must reach
  `hvcC` offset 13–14 as `0xF0 0x04`. A parser that treats the inclusive `0...N` bound as `0..<N`,
  or that returns `NumDeltaPocs[RefRpsIdx]` unchanged, mis-parses the VUI and reports the wrong fps.
* **W3** exercises the sub-layer loops of `profile_tier_level`: `sps_max_sub_layers_minus1 == 1`
  means one `sub_layer_profile_present_flag`/`sub_layer_level_present_flag` pair, then
  `2 × (8 − 1) = 14` bits of `reserved_zero_2bits`, then an 88-bit sub-layer profile block and an
  8-bit `sub_layer_level_idc`. Omitting the reserved-bits loop (the common error) shifts everything
  and yields a nonsensical `pic_width_in_luma_samples`.
* **W4** is Main 10: `generalProfileIDC == 2`, compatibility flags `0x24000000`, bit depths 10/10.
  `VigilVideo` must select `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` on the strength of
  `bitDepthLuma == 10` from this parse.

### 23.5 HEVC PPS vectors

| ID | Base64 | Hex | tiles | WPP | `parallelismType` |
|---|---|---|---:|---:|---:|
| Q1 | `RAHh88DMkA==` | `44 01 E1 F3 C0 CC 90` | 0 | 0 | 1 |
| Q2 | `RAHh88JLzJA=` | `44 01 E1 F3 C2 4B CC 90` | 1 (2×2) | 0 | 2 |
| Q3 | `RAHh88HMkA==` | `44 01 E1 F3 C1 CC 90` | 0 | 1 | 3 |

### 23.6 Record vectors

| ID | Record | Input | Expected bytes |
|---|---|---|---|
| R1 | `avcC` | V1 + P1 | §16.3, 37 bytes, base64 `AU0AKP/hABZnTQAo9APAET8uAiAAAAMAIAAABlCAAQAEaO48gA==` |
| R2 | `avcC` | V2 + P2 | §16.4, 48 bytes, base64 `AWQAKf/hAB1nZAAprCysB4AiflwFqAgICgAAAwACAAADAHke3wEABGjuPLD9+PgA` |
| R3 | `hvcC` | VPS + W1 + Q1 | §17.1, 119 bytes |

Each record vector requires three assertions: `build == expected`, `parse(expected)` recovers the
exact parameter-set byte arrays, and `parse(expected).serialized() == expected`.

### 23.7 Remaining mandatory test cases

| ID | What it tests |
|---|---|
| T-EG-1 | The Exp-Golomb table in §7.1, both directions, plus the 33-leading-zero rejection |
| T-EP-1 | Every `escape`/`unescape` row in §6, both directions |
| T-EP-2 | `unescape` of a NAL ending in `00 00 03` (trailing-escape case) |
| T-EP-3 | `unescape` refuses to drop `0x03` in `00 00 03 04` (strict form) |
| T-AB-1 | `findStartCode` on 3-byte and 4-byte prefixes, and on a buffer with no start code |
| T-AB-2 | Trailing-zero trimming: `00 00 01 65 AA 00 00 00 00 01 41 BB` yields NALs `65 AA` and `41 BB` |
| T-AB-3 | §5.4 round trip: Annex-B → length-prefixed → Annex-B, with the embedded `00 00 03` payloads |
| T-AB-4 | `toLengthPrefixedInPlace` returns `false` for the §5.4 input (mixed 3/4-byte prefixes) and `true` for an all-4-byte one, leaving the buffer untouched on failure |
| T-LP-1 | `fromLengthPrefixedInPlace` rejects a truncated final NAL and a zero length |
| T-NAL-1 | H.265 header encode/decode round trip over all 64 types × layer 0…63 × TID 0…6 |
| T-NAL-2 | `forbidden_zero_bit == 1` throws; `nuh_temporal_id_plus1 == 0` throws |
| T-SL-1 | `isFirstSliceOfPicture` for H.264 `first_mb_in_slice` ∈ {0, 1, 99} and H.265 flag ∈ {0, 1} |
| T-GATE-1 | Gate stays closed through 40 non-IRAP AUs, opens on the 41st carrying an IDR, and reports `droppedAccessUnits == 40` |
| T-GATE-2 | Gate opens on a `recovery_point` SEI with `exact_match_flag == 1`, stays closed when `broken_link_flag == 1` |
| T-GATE-3 | H.265: starting at CRA sets `NoRaslOutputFlag`; the following RASL AUs are dropped; the first non-RASL AU clears it |
| T-GATE-4 | `desperationTimeout` opens the gate and logs a warning |
| T-STORE-1 | Re-ingesting a byte-identical SPS returns `.unchanged` and does **not** bump `generation` |
| T-STORE-2 | A new SPS with the same coded size but a different fps returns `.stored`, not `.formatChanged` |
| T-STORE-3 | V1 → V3 (1920×1088 → 2560×1440) returns `.formatChanged` |
| T-STORE-4 | An SPS whose parse throws is still stored, `isComplete` becomes true, `format` stays nil |
| T-BOUND-1 | Every row of the §4 bounds table throws the documented error rather than allocating |
| T-FUZZ-1 | 10⁶ random mutations of V1/V2/W1/W2 (single-bit flips, truncations, byte injections): the parser must either return a value or throw — never crash, never allocate > 64 KiB, never exceed 1 ms |

T-FUZZ-1 runs in CI on Linux with a fixed RNG seed and a 30-second budget. It is the only test
allowed to be slow, and it is not optional: a parameter-set parser is directly reachable from the
network by any device on the LAN.

---

## 24. Performance budget

| Operation | Budget | Notes |
|---|---|---|
| `findStartCode` throughput | ≥ 2.0 GB/s single core on M-series | scalar 3-step loop; only relevant for file fixtures |
| `LengthPrefixed.enumerate` over a 1080p keyframe (≈ 120 KB) | ≤ 4 µs | no allocation |
| `H264Parser.parseSPS` | ≤ 3 µs | one allocation (the unescape buffer, ≤ 64 B typical) |
| `H265Parser.parseSPS` | ≤ 6 µs | PTL + RPS + VUI/HRD |
| `AVCDecoderConfigurationRecord.serialized()` | ≤ 2 µs | |
| `ParameterSetStore.ingest` — unchanged fast path | ≤ 200 ns | `memcmp` only; this is the path taken twice per GOP per stream |
| `SliceHeader.isFirstSliceOfPicture` | ≤ 2 ns | one bounds check + one load; called once per NAL |
| `IRAPGate.evaluate` | ≤ 50 ns | |
| Steady-state allocations per decoded frame | **0** | enforced by a `malloc` counter assertion in the perf test |

Total per-stream steady-state cost of `VigilBitstream`: one `SliceHeader` call and one NAL-type read
per NAL, plus a `memcmp`-only `ingest` twice per GOP. At 16 streams × 25 fps × ~4 NALs per frame
that is 1600 calls/s of a 2 ns function — under 0.001 % of one core. Parameter-set parsing happens
on format change only. **There is no per-frame parsing in Vigil**, and any change that introduces
some is a performance regression that the allocation assertion will catch.

---

## 25. Cross-module contract summary

Binding on other modules:

1. **Dependency order** is `VigilProtocols → VigilBitstream → VigilRTP`. `VigilRTP` must use this
   module's NAL tables, H.265 header codec, `LengthPrefixed.append`, and
   `SliceHeader.isFirstSliceOfPicture`. No duplicates.
2. **`EncodedFrame.data` is always 4-byte big-endian length-prefixed**, and
   `lengthSizeMinusOne == 3` / `nalUnitHeaderLength == 4` everywhere. Annex-B never appears on the
   live path.
3. **Parameter sets are stored with the NAL header, without a start code or length prefix, still
   escaped, byte-identical to the wire.** `VigilRTSP` hands base64-decoded `sprop-*` values in
   exactly this form; `VigilVideo` passes them straight to CoreMedia.
4. **`VigilBitstream` publishes `VideoFormatInfo`, never `CMVideoFormatDescription`.** The single
   conversion site is `VigilVideo/FormatDescriptionFactory.swift`, and it uses the
   `…CreateFrom{H264,HEVC}ParameterSets` APIs with `nalUnitHeaderLength: 4` and parameter-set order
   `[SPS, PPS]` / `[VPS, SPS, PPS]`. Record builders are for muxing, reading MP4s, and tests.
5. **Report cropped display size, allocate from coded size.** 1080p H.264 is coded 1920×1088;
   `VigilRender`, `VigilUI` and the recorder must read `displayWidth`/`displayHeight` from
   `VideoFormatInfo` and never from the pixel buffer.
6. **Parsed fps is metadata only.** RTP timestamps drive the live clock; the container drives
   recorded playback. The fps fallback chain is VUI → RTP-measured → ISAPI → 25.0. H.264 divides by
   `2 × num_units_in_tick`; H.265 does not divide by 2.
7. **A parameter set we cannot parse is still stored and still forwarded to the decoder.**
   `isComplete` is about bytes; `format == nil` must never block decoding.
8. **Format change means only:** codec, coded width, coded height, chroma format, or luma bit depth.
   Everything else bumps `generation` (rebuild the format description) without recreating the decode
   session.
9. **The IRAP gate starts closed on every PLAY, reconnect and decoder reset.** `VigilCore` must act
   on `shouldRequestKeyframe`, and `VigilUI` must render "connecting", never black, while it is
   closed. For H.265, RASL pictures after a CRA start are dropped.
10. **`isKeyframe` means IDR (H.264 type 5) or IRAP (H.265 types 16–23)** — not "an I-slice". This
    drives sync samples in recordings and the `NotSync` sample attachment.
11. **This module is 100 % value types, zero shared state, Linux-clean.** `ParameterSetStore` and
    `IRAPGate` are structs owned by `VigilCore`'s per-stream actor.
12. **`VigilProtocols.BitReader` has the API in §7** (`u`, `u64`, `flag`, `skip`, `alignToByte`,
    `peek`, `bitsRemaining`, `isByteAligned`); Exp-Golomb and emulation-prevention live in
    `VigilBitstream.RBSPBitReader`, not in `VigilProtocols`.

