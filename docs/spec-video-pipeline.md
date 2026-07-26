# Vigil — Decode & Playback Pipeline Specification (`VigilVideo`)

Status: **normative**. Version 1.0. Target: macOS 14.0+, Swift 6 strict concurrency, zero external
dependencies. Frameworks used by this module: `Foundation`, `CoreMedia`, `CoreVideo`,
`VideoToolbox`, `AVFoundation` (AVSampleBuffer* + AVFAudio), `AudioToolbox`, `CoreImage`,
`ImageIO`, `UniformTypeIdentifiers`, `Metal` (compat flags only — the renderer lives in
`VigilRender`), `OSLog`, `Observation`, `Accelerate` (audio gain/format ramps only).

This document is the single source of truth for everything between an `EncodedFrame` and a
displayable/audible frame. An implementer must be able to write `VigilVideo` from this file alone.

---

## 0. Contract summary (what other modules must respect)

| # | Decision | Binding on |
|---|---|---|
| D1 | Compressed data crossing into `VigilVideo` is **always 4-byte big-endian length-prefixed NAL units**, never Annex-B. `nalUnitHeaderLength = 4` everywhere. | VigilRTP, VigilBitstream, VigilCore |
| D2 | Parameter sets are delivered as **raw NAL bytes including the NAL header byte(s), no start code, no length prefix**, in `EncodedFrame.parameterSets`. | VigilRTP, VigilBitstream |
| D3 | Time crosses the pure/platform boundary as `MediaTimestamp(value: Int64, timescale: Int32)`. `CMTime` never appears in a pure target. | VigilRTP, VigilProtocols |
| D4 | `VigilVideo` owns **all** `VTDecompressionSession`, `CMFormatDescription`, `CMSampleBuffer`, `CVPixelBuffer` creation. `VigilRender` only consumes what `VideoSink` hands it and never creates a decode session. | VigilRender |
| D5 | `DecodeBudget` (a `@globalActor` in `VigilVideo`) is the **only** authority that may admit a decode session. `VigilCore.StreamCoordinator` computes tile priority and calls it; it does not keep its own budget. | VigilCore |
| D6 | The tile-size → `main`/`sub`/`keyframesOnly`/`jpegPoll`/`paused` policy table in §12.5 is normative and is implemented **here**; `VigilCore` and `VigilUI` read it via `TilePolicy.mode(for:)`. | VigilCore, VigilUI |
| D7 | Renderers **must** honour the clean aperture (`kCVImageBufferCleanApertureKey` attachment, else the format description's clean aperture, else the full extent) and the pixel aspect ratio. 1920×1088 coded / 1920×1080 displayed is the common case. | VigilRender |
| D8 | Audio is unmuted **only for the focused camera** by default; at most 4 streams may be unmuted at once. `AudioRouter` enforces it. | VigilCore, VigilUI |
| D9 | Non-`Sendable` CoreMedia/CoreVideo objects cross concurrency domains only inside the documented `@unchecked Sendable` boxes of §2.3, under the stated immutability rule. | all macOS targets |
| D10 | The only sanctioned bridge out of a C callback into Swift concurrency is `AsyncStream.Continuation` (which *is* `Sendable`). No `DispatchQueue.async` into actors. | all macOS targets |

---

## 1. Scope and module boundaries

### 1.1 In scope

Format-description construction; sample-buffer construction; two display strategies; mid-stream
format change; live low-latency clock and its adaptive latency controller; recorded playback
(timebase, reorder, seek, rate, reverse, step); the global decode-budget scheduler and tile policy;
audio decode + playback + talkback capture/encode; snapshot rasterisation and file encoding;
hardware/energy verification and the benchmark harness.

### 1.2 Out of scope (and who owns it)

| Concern | Owner |
|---|---|
| RTSP/RTP/SDP, keyframe *request* wire format, `Scale:`/`Range:` headers | `VigilRTSP`, `VigilTransport` |
| AU assembly, jitter buffer, RTCP, `StreamStatistics` network fields | `VigilRTP` |
| SPS/PPS/VPS parsing, `avcC`/`hvcC` byte building, Annex-B conversion, drop-until-IRAP detection | `VigilBitstream` |
| Metal textures, shaders, zoom/pan gestures, overlays, `CAMetalLayer` and `AVSampleBufferDisplayLayer` *hosting* | `VigilRender` |
| `StreamController` state machine, reconnect, recording to MP4, snapshot destinations/EXIF policy, event centre | `VigilCore` |
| ISAPI JPEG fetch, two-way-audio HTTP endpoints | `VigilISAPI` |

`VigilVideo` **creates** `AVSampleBufferDisplayLayer` (it owns the enqueue queue and the flush
semantics) but does **not** add it to a view hierarchy; it hands the layer to `VigilRender` through
`LayerVideoSink.layer`. `VigilVideo` never imports `SwiftUI` or `AppKit` except `AppKit` for
`NSWindow.occlusionState` observation in `ThermalGovernor`/`OcclusionMonitor` (guarded, `@MainActor`).

### 1.3 Dependency edges

```
VigilProtocols ──▶ VigilVideo ◀── VigilBitstream (avcC/hvcC builders, NAL tables, IRAP detection)
                      ▲
                      └── VigilRTP (EncodedFrame, MediaTimestamp, StreamStatistics)
VigilVideo ──▶ (consumed by) VigilRender, VigilCore
VigilVideo ──▶ VigilISAPI   // only the JPEG-poll fetch closure is injected, not imported
```

`VigilVideo` must not import `VigilISAPI`. The JPEG poller takes an injected
`@Sendable (CGSize) async throws -> Data` closure supplied by `VigilCore`.

---

## 2. Types crossing the boundary

### 2.1 Input: `EncodedFrame` (defined in `VigilRTP`, restated here as the contract)

```swift
public struct EncodedFrame: Sendable, Equatable {
    public var data: Data                 // 4-byte BE length-prefixed NAL units, 1..n
    public var pts: MediaTimestamp        // 90 kHz for video, from RTP + drift-corrected clock
    public var dts: MediaTimestamp?       // nil when the stream has no reorder (live Hikvision)
    public var duration: MediaTimestamp?  // nil → pipeline estimates, see §3.3
    public var isKeyframe: Bool           // IDR (H.264 type 5) or IRAP (H.265 types 16...23)
    public var codec: VideoCodec          // .h264, .h265, .h265Main10, .mjpeg
    public var parameterSets: ParameterSets?   // present on the first frame of every GOP
    public var dropClass: FrameDropClass  // .required, .droppableNonReference, .droppableTemporal
    public var receivedAtHostTicks: UInt64     // mach_absolute_time() of the last RTP packet of the AU
    public var sequenceNumber: UInt32     // monotonic AU counter, for gap accounting
}

public struct ParameterSets: Sendable, Equatable, Hashable {
    public var vps: [Data]   // H.265 only, raw NALs, no start code
    public var sps: [Data]
    public var pps: [Data]
}

public enum FrameDropClass: UInt8, Sendable { case required, droppableNonReference, droppableTemporal }
```

`dropClass` derivation (done by `VigilRTP` from the NAL header, restated so the pipeline can assert):

| Codec | Condition | Class |
|---|---|---|
| H.264 | `nal_ref_idc == 0` on all VCL NALs of the AU | `.droppableNonReference` |
| H.265 | `nuh_temporal_id_plus1 - 1 > 0` and `sps_temporal_id_nesting_flag == 1` | `.droppableTemporal` |
| both | otherwise | `.required` |

### 2.2 Output: `DecodedVideoFrame`

```swift
public struct DecodedVideoFrame: @unchecked Sendable {
    public enum Payload {
        case pixelBuffer(CVPixelBuffer)     // Strategy B (VT + Metal)
        case sampleBuffer(CMSampleBuffer)   // Strategy A passthrough, used only for recording taps
    }
    public let payload: Payload
    public let pts: CMTime
    public let duration: CMTime
    public let isKeyframe: Bool
    public let format: VideoFormat
    public let capturedAtHostTicks: UInt64   // copied from EncodedFrame.receivedAtHostTicks
    public let decodedAtHostTicks: UInt64
    public let generation: UInt32             // bumps on every format change; renderers discard stale
}

public struct VideoFormat: Sendable, Hashable {
    public let codedWidth: Int32            // e.g. 1920
    public let codedHeight: Int32           // e.g. 1088
    public let displayWidth: Int32          // clean aperture, e.g. 1920
    public let displayHeight: Int32         // e.g. 1080
    public let pixelAspectRatio: (h: Int32, v: Int32)
    public let nominalFrameRate: Float64    // 0 when unknown
    public let codec: VideoCodec
    public let bitDepth: Int                // 8 or 10
    public let isFullRange: Bool
    public let colorPrimaries: ColorSpaceTag
    public let transferFunction: ColorSpaceTag
    public let ycbcrMatrix: ColorSpaceTag
    public let isInterlaced: Bool           // analog NVR channels; VigilRender bob-deinterlaces
}
```

### 2.3 `Sendable` strategy for CoreMedia types (D9)

`CVPixelBuffer`, `CMSampleBuffer`, `CMBlockBuffer` and `CMFormatDescription` are CF types with no
`Sendable` conformance. The rules:

1. `DecodedVideoFrame` is `@unchecked Sendable`. The **immutability rule**: once a frame is yielded
   to a continuation, the producer must never write to the buffer or its attachments again. Pixel
   buffers come from a `CVPixelBufferPool`; the pool only recycles a buffer after the last
   `CVPixelBuffer` reference is released, so this is safe.
2. Format descriptions are wrapped in `final class FormatBox: @unchecked Sendable` with a
   `let desc: CMVideoFormatDescription`. Immutable by construction.
3. Anything else that must cross a domain goes into `struct Unsafe<T>: @unchecked Sendable { let v: T }`
   in `Support/Boxes.swift`, and every use site carries a one-line `// SAFETY:` comment naming the
   invariant. Reviewers reject a `Unsafe<T>` without one.
4. Never `@unchecked Sendable` on a type with `var` reference storage.

### 2.4 The sink protocol

```swift
public protocol VideoSink: Sendable {
    /// Called from the pipeline's presenter task. Must return in < 2 ms and must not block.
    func present(_ frame: DecodedVideoFrame)
    /// Format is about to change. The sink must keep showing its current image (no black flash).
    func willChangeFormat(from old: VideoFormat?, to new: VideoFormat, generation: UInt32)
    /// First frame of the new generation has been presented.
    func didChangeFormat(to new: VideoFormat, generation: UInt32)
    func didDropFrames(_ count: Int, reason: FrameDropReason)
    func didStall(since: UInt64)          // no frame for > 2 s
    func didRecover()
}
```

Two concrete sinks ship in `VigilVideo`:
`LayerVideoSink` (Strategy A, owns the `AVSampleBufferDisplayLayer`) and `PixelBufferVideoSink`
(Strategy B, forwards to a `MetalPresenting` object provided by `VigilRender`). Both are
`final class … : @unchecked Sendable` with an internal serial `DispatchQueue`
(`com.vigil.video.enqueue.<streamID>`, QoS `.userInteractive`).

**GCD exception (justified).** Two places use GCD and only two:
(a) the `AVQueuedSampleBufferRendering.requestMediaDataWhenReady(on:using:)` callback queue, which
the API mandates; (b) VideoToolbox's own output-handler thread, from which we immediately
`continuation.yield`. No other GCD in this module.

---

## 3. Timestamps and clocks

### 3.1 `MediaTimestamp` → `CMTime`

```swift
@inline(__always)
public func cmTime(_ t: MediaTimestamp) -> CMTime {
    CMTime(value: t.value, timescale: t.timescale)   // timescale 90_000 for video
}
@inline(__always)
public func mediaTimestamp(_ t: CMTime) -> MediaTimestamp {
    MediaTimestamp(value: t.value, timescale: t.timescale)
}
```

`VigilRTP` has already unwrapped the 32-bit RTP timestamp into a monotonically increasing `Int64`
at timescale 90 000 (video) or the audio clock rate. `VigilVideo` therefore never handles
wraparound. Assert monotonicity in debug: a non-monotonic `pts` in live mode is a bug in the RTP
layer and is logged at `.error`, then coerced to `previousPTS + estimatedDuration`.

### 3.2 Clocks

| Clock | Use |
|---|---|
| `CMClockGetHostTimeClock()` | source clock for every timebase; `mach_absolute_time()` domain |
| `mach_absolute_time()` + `mach_timebase_info` | all latency measurement; converted with a cached `Double` scale (`numer/denom * 1e-6` → ms) |
| `CMTimebase` on host clock | recorded playback only (§11); **never created for live** |

```swift
enum HostClock {
    static let msPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000.0
    }()
    @inline(__always) static func ms(since t: UInt64) -> Double {
        Double(mach_absolute_time() &- t) * msPerTick
    }
}
```

### 3.3 Duration estimation

`CMSampleTimingInfo.duration` must be valid for the display layer to pace correctly and for
`AVAssetWriter` passthrough (recording). Algorithm, in order:

1. `EncodedFrame.duration` if non-nil.
2. `pts - previousPTS` if that is in `(0, 2 s]` — this is the normal live case; a 1-frame lag is
   irrelevant because live mode displays immediately.
3. `1 / VideoFormat.nominalFrameRate` from SPS VUI (`time_scale / (2 * num_units_in_tick)`).
4. `CMTime(value: 3000, timescale: 90_000)` (30 fps) as the last resort.

Duration is *smoothed* for the layer path: `EWMA(α = 0.1)` over the last 30 durations, clamped to
±25 % of the EWMA, so a single late AU does not make the layer stutter. Raw (unsmoothed) durations
are used for the recording tap so the muxed file has honest timing.

---

## 4. `CMVideoFormatDescription` from parameter sets

### 4.1 Exact Apple signatures

```swift
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
    extensions: CFDictionary?,
    formatDescriptionOut: UnsafeMutablePointer<CMFormatDescription?>
) -> OSStatus
```

Rules:

* Order matters. H.264: `[SPS, PPS]` (all SPS first, then all PPS). H.265: `[VPS, SPS, PPS]`.
* Each buffer is the **raw NAL** starting at the NAL header byte (H.264: `0x67` for SPS,
  `0x68` for PPS; H.265: `0x40 0x01` VPS, `0x42 0x01` SPS, `0x44 0x01` PPS). No `00 00 00 01`,
  no length prefix, no trailing zero padding (strip trailing `0x00` bytes — some Hikvision
  firmware pads SDP `sprop-parameter-sets`).
* `nalUnitHeaderLength: 4` — **always** (D1).
* Minimum counts: H.264 needs ≥ 1 SPS and ≥ 1 PPS; H.265 needs ≥ 1 SPS and ≥ 1 PPS, VPS strongly
  recommended (some firmware omits VPS from SDP but sends it in-band; wait for it — see §4.5).
* The returned object is a `CMFormatDescription`; cast with
  `formatDesc as CMVideoFormatDescription` (they are the same CF type; `CMVideoFormatDescription`
  is a typealias in Swift, so no cast is actually needed).

### 4.2 Nested pointer handling (the whole point)

`Data.withUnsafeBytes` pointers are valid only inside the closure, so an array of `n` pointers to
`n` different `Data` values requires `n` nested closures. Recursive descent is the correct,
allocation-free-at-steady-state solution:

```swift
/// Pins every element of `sets` simultaneously and hands `body` C-compatible arrays.
/// The pointers MUST NOT escape `body`.
@usableFromInline
func withParameterSetPointers<R>(
    _ sets: [Data],
    _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>, Int) throws -> R
) throws -> R {
    guard !sets.isEmpty else { throw VideoPipelineError.missingParameterSets }
    var pointers = [UnsafePointer<UInt8>]();  pointers.reserveCapacity(sets.count)
    var sizes = [Int]();                      sizes.reserveCapacity(sets.count)

    func descend(_ i: Int) throws -> R {
        if i == sets.count {
            return try pointers.withUnsafeBufferPointer { pb in
                try sizes.withUnsafeBufferPointer { sb in
                    guard let p = pb.baseAddress, let s = sb.baseAddress else {
                        throw VideoPipelineError.missingParameterSets
                    }
                    return try body(p, s, sets.count)
                }
            }
        }
        return try sets[i].withUnsafeBytes { raw -> R in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                  raw.count > 0 else {
                throw VideoPipelineError.emptyParameterSet(index: i)
            }
            pointers.append(base)
            sizes.append(raw.count)
            defer { pointers.removeLast(); sizes.removeLast() }
            return try descend(i + 1)
        }
    }
    return try descend(0)
}
```

Notes for the implementer:

* Recursion depth equals the parameter-set count (2–4 in practice, hard-capped at 8 —
  reject more with `.tooManyParameterSets`, a malformed-stream guard).
* `Data` may be discontiguous; `withUnsafeBytes` flattens it, which is why we must not cache the
  pointer between calls.
* Do **not** try to build the pointer array by `map { $0.withUnsafeBytes { $0.baseAddress! } }` —
  that is a dangling-pointer bug that "works" until the `Data` is non-contiguous or ARC releases it.
  This mistake is the #1 crash in hand-rolled RTSP players; call it out in the code comment.

### 4.3 The factory

```swift
public enum FormatDescriptionFactory {

    public static func make(
        codec: VideoCodec,
        parameterSets: ParameterSets,
        overrides: FormatOverrides = .none
    ) throws -> CMVideoFormatDescription {
        switch codec {
        case .h264:
            let sets = parameterSets.sps.map(trimTrailingZeros) + parameterSets.pps.map(trimTrailingZeros)
            var out: CMFormatDescription?
            let status = try withParameterSetPointers(sets) { p, s, n in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: n, parameterSetPointers: p, parameterSetSizes: s,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &out)
            }
            guard status == noErr, let desc = out else {
                throw VideoPipelineError.formatDescriptionFailed(status: status, codec: codec)
            }
            return overrides.isEmpty ? desc : try rebuild(desc, codec: .h264,
                                                          sets: parameterSets, overrides: overrides)
        case .h265, .h265Main10:
            let sets = (parameterSets.vps + parameterSets.sps + parameterSets.pps).map(trimTrailingZeros)
            var out: CMFormatDescription?
            let ext = overrides.hevcExtensionsDictionary()   // nil when .none
            let status = try withParameterSetPointers(sets) { p, s, n in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: n, parameterSetPointers: p, parameterSetSizes: s,
                    nalUnitHeaderLength: 4, extensions: ext, formatDescriptionOut: &out)
            }
            guard status == noErr, let desc = out else {
                throw VideoPipelineError.formatDescriptionFailed(status: status, codec: codec)
            }
            return desc
        case .mjpeg:
            throw VideoPipelineError.codecNotDecodedByThisPath(.mjpeg)   // see §12.6
        }
    }
}
```

`trimTrailingZeros(_:)` removes trailing `0x00` bytes but keeps at least 4 bytes; it is a no-op on
well-formed NALs (an RBSP never ends in `0x00` because of the `rbsp_stop_one_bit`).

Typical failures:

| `OSStatus` | Meaning | Action |
|---|---|---|
| `-12712` (`kCMFormatDescriptionBridgeError_InvalidParameter`) / `paramErr` `-50` | malformed or mis-ordered sets | log the hex of every set at `.error`, discard the parameter sets, wait for the next in-band set (do not tear down the RTSP session) |
| `kCMFormatDescriptionError_InvalidParameter` | same | same |
| `noErr` but wrong dimensions | SPS parsed by VT differs from `VigilBitstream` | trust VT for the format description; log the disagreement; `VigilBitstream`'s numbers are used only for UI/statistics |

### 4.4 Overrides / the `avcC` escape hatch

`CreateFrom…ParameterSets` derives dimensions, cropping, pixel aspect ratio and colorimetry from
the SPS VUI. When the SPS has **no VUI** (common on cheap Hikvision OEM firmware) VT tags the
format as unspecified colour, and `VigilRender` would guess. In that case we rebuild:

```swift
static func rebuild(_ probe: CMVideoFormatDescription, codec: VideoCodec,
                    sets: ParameterSets, overrides: FormatOverrides) throws -> CMVideoFormatDescription {
    let atomKey = (codec == .h264) ? "avcC" : "hvcC"
    let record: Data = (codec == .h264)
        ? try AVCDecoderConfigurationRecord(sps: sets.sps, pps: sets.pps).encoded()   // VigilBitstream
        : try HEVCDecoderConfigurationRecord(vps: sets.vps, sps: sets.sps, pps: sets.pps).encoded()
    let dims = CMVideoFormatDescriptionGetDimensions(probe)
    var ext: [CFString: Any] = [
        kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [atomKey: record] as CFDictionary,
        kCMFormatDescriptionExtension_FormatName: (codec == .h264 ? "H.264" : "HEVC") as CFString,
        kCMFormatDescriptionExtension_ColorPrimaries: overrides.primaries ?? kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
        kCMFormatDescriptionExtension_TransferFunction: overrides.transfer ?? kCMFormatDescriptionTransferFunction_ITU_R_709_2,
        kCMFormatDescriptionExtension_YCbCrMatrix: overrides.matrix ?? kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
        kCMFormatDescriptionExtension_FullRangeVideo: overrides.fullRange as CFBoolean,
    ]
    if let par = overrides.pixelAspectRatio {
        ext[kCMFormatDescriptionExtension_PixelAspectRatio] = [
            kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: par.h,
            kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing:   par.v,
        ] as CFDictionary
    }
    if let ca = overrides.cleanAperture {
        ext[kCMFormatDescriptionExtension_CleanAperture] = [
            kCMFormatDescriptionKey_CleanApertureWidth: ca.width,
            kCMFormatDescriptionKey_CleanApertureHeight: ca.height,
            kCMFormatDescriptionKey_CleanApertureHorizontalOffset: ca.x,
            kCMFormatDescriptionKey_CleanApertureVerticalOffset: ca.y,
        ] as CFDictionary
    }
    var out: CMFormatDescription?
    let st = CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
        width: dims.width, height: dims.height,
        extensions: ext as CFDictionary, formatDescriptionOut: &out)
    guard st == noErr, let d = out else {
        throw VideoPipelineError.formatDescriptionFailed(status: st, codec: codec)
    }
    return d
}
```

Policy: **prefer `CreateFrom…ParameterSets`.** Use `rebuild` only when
(a) the SPS lacks VUI colour description, (b) the user has forced full-range in camera settings,
(c) `VigilCore` needs a format description for `AVAssetWriter` with an explicit `sourceFormatHint`
that must round-trip into MP4 (the `avcC` atom path is the one `AVAssetWriter` documents).

Default when VUI is absent: BT.709 primaries/transfer/matrix, `FullRangeVideo = false`. For
`.h265Main10` with `VUI colour_primaries == 9`: BT.2020 primaries, matrix `ITU_R_2020`,
transfer `ITU_R_2100_HLG` if `transfer_characteristics == 18`, else `ITU_R_709_2`.

### 4.5 `ParameterSetStore` and format fingerprinting

```swift
public struct FormatFingerprint: Hashable, Sendable {
    let codec: VideoCodec
    let setsHash: UInt64           // FNV-1a over VPS|SPS|PPS bytes in order
    let coded: CGSize
}

public final class ParameterSetStore {           // pipeline-actor isolated, not Sendable
    private(set) var sets: ParameterSets?
    private(set) var fingerprint: FormatFingerprint?
    private(set) var format: CMVideoFormatDescription?

    /// Returns .unchanged, .firstSet, or .changed(previous:) — drives §9.
    mutating func ingest(_ new: ParameterSets, codec: VideoCodec) -> ParameterSetChange
}
```

Rules:

* Merge, do not replace: a GOP that carries only a new PPS keeps the stored SPS. H.265 firmware
  frequently sends VPS once at session start and never again.
* Only a change in the **fingerprint** triggers §9. Byte-identical resends (every GOP, which is
  normal) are free and must not cause a session recreation — this is the single most common
  performance bug in players of this kind.
* `CMFormatDescriptionEqual(a, b)` is used as a second-line check before recreating a session;
  it compares extensions too, so it is stricter than the fingerprint. Both must indicate change.
* Until a complete set is present the pipeline stays in `.awaitingParameterSets` and drops frames,
  incrementing `stats.framesDroppedNoFormat`. It requests a keyframe every 2 s (max 5 times, then
  emits `.event(.noParameterSets)` so `VigilCore` can surface "camera sent no SPS/PPS — try
  substream" in the Stream Doctor).

---

## 5. `CMBlockBuffer` and `CMSampleBuffer` construction

### 5.1 Block buffer

```swift
func makeBlockBuffer(_ data: Data) throws -> CMBlockBuffer {
    var bb: CMBlockBuffer?
    // Allocate an owned, contiguous block; CMBlockBuffer frees it via kCFAllocatorDefault.
    var st = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,                 // nil ⇒ CM allocates blockLength bytes for us
        blockLength: data.count,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: data.count,
        flags: kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &bb)
    guard st == kCMBlockBufferNoErr, let block = bb else {
        throw VideoPipelineError.blockBufferFailed(status: st)
    }
    st = data.withUnsafeBytes { raw in
        CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                      offsetIntoDestination: 0, dataLength: data.count)
    }
    guard st == kCMBlockBufferNoErr else { throw VideoPipelineError.blockBufferFailed(status: st) }
    return block
}
```

Why one copy and not zero:

* A zero-copy path (`customBlockSource` with a retained `Data` and a free callback) was measured at
  **0.9 % CPU better** on 16×1080p but requires an `Unmanaged` box freed from CM's thread, and gets
  the lifetime wrong the moment the `Data` is a slice of a larger RTP reassembly buffer.
* `memcpy` of a 1080p P-frame (8–40 KB) is ≈ 1.5 µs; an I-frame (120–300 KB) ≈ 12 µs. At 16 streams
  × 30 fps that is < 0.4 % of one core. **Decision: copy.** The `customBlockSource` variant is
  implemented behind `#if VIGIL_ZEROCOPY_BLOCKS` for benchmarking only and is not shipped.
* `kCMBlockBufferAssureMemoryNowFlag` is required or the allocation is deferred and
  `CMBlockBufferReplaceDataBytes` fails with `kCMBlockBufferBlockAllocationFailedErr`.

The reassembled AU arrives from `VigilRTP` already as one contiguous `Data` with 4-byte length
prefixes; the pipeline never has to concatenate. Assert the prefix walk in debug builds:
`walkLengthPrefixed(data) { nalType in … }` must consume exactly `data.count` bytes, else
`.malformedAccessUnit` (dropped, counted, keyframe requested).

### 5.2 Sample buffer

```swift
func makeSampleBuffer(block: CMBlockBuffer, format: CMVideoFormatDescription,
                      pts: CMTime, dts: CMTime, duration: CMTime,
                      isKeyframe: Bool, displayImmediately: Bool) throws -> CMSampleBuffer {
    var timing = CMSampleTimingInfo(duration: duration,
                                    presentationTimeStamp: pts,
                                    decodeTimeStamp: dts)     // .invalid ⇒ "same as PTS"
    var size = CMBlockBufferGetDataLength(block)
    var sb: CMSampleBuffer?
    let st = CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: block,
        formatDescription: format,
        sampleCount: 1,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 1, sampleSizeArray: &size,
        sampleBufferOut: &sb)
    guard st == noErr, let sample = sb else {
        throw VideoPipelineError.sampleBufferFailed(status: st)
    }
    try applyAttachments(sample, isKeyframe: isKeyframe, displayImmediately: displayImmediately)
    return sample
}
```

* One AU per `CMSampleBuffer`. Never batch — batching defeats `DisplayImmediately` and makes
  per-frame latency accounting impossible.
* `dts`: pass `CMTime.invalid` when `EncodedFrame.dts == nil`. CoreMedia then treats PTS as DTS.
  Live Hikvision streams have no B-frames by default (`H264Profile=Main`, `BFrame=0`), so
  `dts == nil` is the normal live case. For recorded streams DTS **must** be supplied
  (see §11.2) or `AVSampleBufferDisplayLayer` will mis-pace.
* `duration` must be valid and > 0 for the layer path.

### 5.3 Sample attachments

```swift
func applyAttachments(_ sample: CMSampleBuffer, isKeyframe: Bool,
                      displayImmediately: Bool) throws {
    guard let raw = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
          CFArrayGetCount(raw) > 0,
          let dictPtr = CFArrayGetValueAtIndex(raw, 0) else {
        throw VideoPipelineError.attachmentsUnavailable
    }
    let dict = unsafeBitCast(dictPtr, to: CFMutableDictionary.self)

    if !isKeyframe {
        CFDictionarySetValue(dict,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        CFDictionarySetValue(dict,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DependsOnOthers).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    if displayImmediately {
        CFDictionarySetValue(dict,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
}
```

| Attachment key | When we set it | Effect |
|---|---|---|
| `kCMSampleAttachmentKey_NotSync` = `true` | every non-keyframe | tells the layer/VT this is not a random-access point; **omit it on keyframes** (do not set it to `false`) |
| `kCMSampleAttachmentKey_DependsOnOthers` = `true` | every non-keyframe | lets the layer drop it safely when behind |
| `kCMSampleAttachmentKey_DisplayImmediately` = `true` | **live mode only**, on every sample | layer displays as soon as decoded, ignoring the timebase — this is the low-latency switch |
| `kCMSampleAttachmentKey_DoNotDisplay` = `true` | fine-seek pre-roll frames in recorded mode (§11.4) | decoded for reference, never shown |
| `kCMSampleAttachmentKey_EarlierDisplayTimesAllowed` | never | we do not reorder in the layer |
| `kCMSampleAttachmentKey_PartialSync` | H.265 CRA/BLA (NAL types 16–21) that are not IDR | marks a recovery point that is not a clean IDR |
| `kCMSampleAttachmentKey_IsDependedOnByOthers` = `false` | when `dropClass != .required` | further licence to drop |

**Never set `DisplayImmediately` in recorded mode** — it breaks rate control, seek and reverse.

A `BlockBufferPool` (`Sample/BlockBufferPool.swift`) keeps up to 8 pre-allocated blocks per size
class (16 KB, 64 KB, 256 KB, 1 MB) per stream to avoid `malloc` churn; on a pool miss it falls
through to a fresh allocation. Measured saving: 0.6 % of one core at 16×1080p30.

---

## 6. Strategy A — `AVSampleBufferDisplayLayer` (default fast path)

### 6.1 Why it is the default

* Zero pixel-buffer traffic in our address space: CoreMedia decodes straight into an `IOSurface`
  the WindowServer composites. Lowest CPU, lowest memory, lowest latency.
* Automatic hardware decode selection, automatic decoder sharing, automatic HDR/EDR tone mapping,
  automatic clean-aperture and PAR handling.
* Survives display reconfiguration and Space switches without our involvement.

Measured on M1 (8-core), 16 tiles of 1080p30 H.264: **layer path 9–13 % total CPU / 320 MB**;
VT+Metal path **14–19 % total CPU / 690 MB**. Use the layer whenever pixel access is not required.

### 6.2 The rendering shim (SDK-version-proof)

macOS 14 exposes both the legacy `AVQueuedSampleBufferRendering` conformance on
`AVSampleBufferDisplayLayer` and the newer `layer.sampleBufferRenderer`
(`AVSampleBufferVideoRenderer`). Their semantics for everything we use are identical. Hide the
choice behind one protocol so a future SDK deprecation is a one-line change:

```swift
protocol SampleBufferRendering: AnyObject {
    var isReadyForMoreMediaData: Bool { get }
    func enqueue(_ sampleBuffer: CMSampleBuffer)
    func flush()
    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping () -> Void)
    func stopRequestingMediaData()
    var rendererStatus: SampleBufferRendererStatus { get }
    var rendererError: Error? { get }
}

enum SampleBufferRendererStatus { case unknown, rendering, failed }
```

`LayerVideoSink` picks the implementation at init:

```swift
if #available(macOS 14.0, *), Self.useVideoRenderer {
    rendering = VideoRendererAdapter(layer.sampleBufferRenderer)
} else {
    rendering = LegacyLayerAdapter(layer)
}
```

`useVideoRenderer` defaults to `true` and is overridable by the hidden defaults key
`com.vigil.video.useLegacyEnqueue` for field debugging.

### 6.3 Layer configuration

```swift
let layer = AVSampleBufferDisplayLayer()
layer.videoGravity = .resizeAspect              // VigilRender may set .resizeAspectFill per tile
layer.isOpaque = true
layer.backgroundColor = NSColor.black.cgColor   // the tile's own bg; never clear (avoids blend cost)
layer.preventsCapture = false
layer.contentsScale = window.backingScaleFactor // VigilRender updates on display change
```

Immediate (live) mode: **do not set `controlTimebase`.** Every sample carries
`DisplayImmediately`. The layer then behaves as a "decode and show now" pipe.

Timed (recorded) mode: attach to an `AVSampleBufferRenderSynchronizer`:

```swift
let synchronizer = AVSampleBufferRenderSynchronizer()
synchronizer.addRenderer(layer.sampleBufferRenderer)   // or set layer.controlTimebase on the legacy path
synchronizer.addRenderer(audioRenderer)                // AVSampleBufferAudioRenderer, §13.7
synchronizer.delaysRateChangeUntilHasSufficientMediaData = true
synchronizer.setRate(1.0, time: firstPTS)
```

Legacy equivalent, for the `LegacyLayerAdapter`:

```swift
var tb: CMTimebase?
CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
guard let timebase = tb else { throw VideoPipelineError.timebaseFailed }
CMTimebaseSetTime(timebase, time: firstPTS)
CMTimebaseSetRate(timebase, rate: 1.0)
layer.controlTimebase = timebase
```

| Mode | Timebase | `DisplayImmediately` | Queue depth | Rate control |
|---|---|---|---|---|
| Live | none | yes | 2–3 samples in our queue, ≤ 3 in the layer | n/a |
| Recorded 1× | synchronizer / control timebase | no | 0.5 s of samples | `setRate` |
| Recorded ≠ 1× or reverse | — | — | — | Strategy B only (§11) |

### 6.4 Feeding the layer

`requestMediaDataWhenReady(on:using:)` is the mandated pull model. Our block:

```swift
rendering.requestMediaDataWhenReady(on: enqueueQueue) { [weak self] in
    guard let self else { return }
    while self.rendering.isReadyForMoreMediaData {
        guard let sample = self.pending.dequeue() else { break }   // lock-protected SPSC ring
        self.rendering.enqueue(sample)
        self.stats.recordEnqueued(sample)
    }
}
```

* `isReadyForMoreMediaData` goes false at roughly 3 queued samples for a real-time layer. Never
  spin on it; the block is re-invoked.
* `pending` is a small ring (capacity 6). When the pipeline pushes into a full ring it applies the
  §10 drop policy — the ring, not the layer, is where backpressure is resolved.
* Live mode still uses the pull model (not naked `enqueue`) because it gives us the layer's own
  backpressure signal, which is our best proxy for decoder saturation.

### 6.5 `requiresFlushToResumeDecoding` and failure handling

```swift
NotificationCenter.default.addObserver(
    forName: AVSampleBufferDisplayLayer.requiresFlushToResumeDecodingDidChangeNotification,
    object: layer, queue: nil) { [weak self] _ in self?.handleRequiresFlush() }

NotificationCenter.default.addObserver(
    forName: AVSampleBufferDisplayLayer.failedToDecodeNotification,
    object: layer, queue: nil) { [weak self] note in
        let err = note.userInfo?[AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey] as? NSError
        self?.handleDecodeFailure(err)
    }
```

(When routing through `layer.sampleBufferRenderer`, observe
`AVSampleBufferVideoRenderer.didFailToDecodeNotification` and
`AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification` on the renderer
object instead. The adapter normalises both to two closures.)

| Condition | Handling |
|---|---|
| `layer.requiresFlushToResumeDecoding == true` (app was occluded/hidden; the system reclaimed the decoder) | call `rendering.flush()` **without** `removingDisplayedImage`, set `awaitingKeyframe = true`, request an IDR. Do **not** recreate the layer. |
| `failedToDecodeNotification` with `kVTVideoDecoderBadDataErr` | count it; if ≥ 3 within 2 s, `flush()` + IDR request; a single event is ignored (one corrupt AU) |
| `rendererStatus == .failed` | log `rendererError`, recreate the `AVSampleBufferDisplayLayer` (the object is unrecoverable), notify `VigilRender` via `sink.layerDidRecreate(_:)`, request IDR |
| App will be occluded (`NSWindow.didChangeOcclusionStateNotification`, `.visible` cleared) | see §12.7 |
| `NSApplication.willTerminate` | `stopRequestingMediaData()` then `flush()` |

**Flush discipline (D7-adjacent, matters for "no black flash"):**

* `flush()` — drops queued samples, **keeps the displayed image**. This is the default everywhere.
* `flush(removingDisplayedImage: true, completionHandler:)` — clears to background. Used in exactly
  two places: stream teardown, and a deliberate camera switch inside one tile.

### 6.6 Verifying hardware decode on the layer path

There is no property to query. Use the indirect checks of §16.1: a probe `VTDecompressionSession`
created at app start with `RequireHardwareAcceleratedVideoDecoder = true` for both H.264 and HEVC
tells us whether the machine has hardware decode at all; if it does, `AVSampleBufferDisplayLayer`
uses it. Additionally, `signpost` interval `layerEnqueueToDisplay` derived from
`AVSampleBufferDisplayLayer`'s `timebase` vs. host time gives an end-to-end number that is
> 25 ms/frame on software decode.

---

## 7. Strategy B — `VTDecompressionSession` + Metal

Used when we need the pixels. Triggers (any one is sufficient):

| Trigger | Why pixels are needed |
|---|---|
| Digital zoom / pan / digital PTZ active on the tile | fragment-shader transform |
| Colour grading, sharpen, night-boost, gamma | shader pass |
| Deinterlace (analog NVR channel, `isInterlaced`) | bob/blend shader |
| Motion-box or privacy-mask overlay composited **into** the video (recording burn-in) | render-to-texture |
| Snapshot of the exact displayed frame | texture read-back |
| Video-wall single-layer atlas compositing (> K tiles, see `spec-render.md`) | one layer, many textures |
| Recorded playback at rate ≠ 1× or reverse | our own presenter |
| 10-bit HEVC with a custom tone curve | shader |

Switching strategies at runtime is supported and must not drop a frame: see §7.8.

### 7.1 Creation

```swift
func makeSession(format: CMVideoFormatDescription, cfg: VTConfig) throws -> VTDecompressionSession {
    // --- decoder specification -------------------------------------------------------------
    var spec: [CFString: Any] = [
        kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: kCFBooleanTrue!,
    ]
    if cfg.requireHardware {
        spec[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = kCFBooleanTrue!
    }
    if let gpu = cfg.preferredGPURegistryID {   // multi-GPU Macs: decode on the display's GPU
        spec[kVTVideoDecoderSpecification_PreferredDecoderGPURegistryID] = gpu as CFNumber
    }

    // --- destination image buffer attributes ------------------------------------------------
    var attrs: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: cfg.pixelFormat as CFNumber,
        kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,   // empty dict ⇒ default surface
    ]
    if let target = cfg.scaledOutputSize {      // §7.4 downscale-on-decode
        attrs[kCVPixelBufferWidthKey]  = Int(target.width)  as CFNumber
        attrs[kCVPixelBufferHeightKey] = Int(target.height) as CFNumber
    }

    var session: VTDecompressionSession?
    let st = VTDecompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        formatDescription: format,
        decoderSpecification: spec as CFDictionary,
        imageBufferAttributes: attrs as CFDictionary,
        outputCallback: nil,                 // we use the block-based decode API
        decompressionSessionOut: &session)
    guard st == noErr, let s = session else {
        throw VideoPipelineError.decoderCreationFailed(status: st, requireHardware: cfg.requireHardware)
    }
    try configure(s, cfg)
    return s
}
```

Signature for reference:

```swift
func VTDecompressionSessionCreate(
    allocator: CFAllocator?,
    formatDescription: CMVideoFormatDescription,
    decoderSpecification: CFDictionary?,
    imageBufferAttributes: CFDictionary?,
    outputCallback: UnsafePointer<VTDecompressionOutputCallbackRecord>?,
    decompressionSessionOut: UnsafeMutablePointer<VTDecompressionSession?>
) -> OSStatus
```

`outputCallback: nil` is legal and required for the block-based
`VTDecompressionSessionDecodeFrame(_:sampleBuffer:flags:infoFlagsOut:outputHandler:)`. Passing both
is an error (`kVTParameterErr`).

### 7.2 Pixel formats

| Source | `kCVPixelBufferPixelFormatTypeKey` | FourCC | Notes |
|---|---|---|---|
| H.264 8-bit (all Hikvision main/sub) | `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` | `420v` | default |
| HEVC 8-bit | `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` | `420v` | |
| HEVC Main10 (`bitDepth == 10`) | `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` | `x420` | 10 bits in the high bits of each 16-bit word |
| SPS says `video_full_range_flag == 1` | `…8BiPlanarFullRange` / `…10BiPlanarFullRange` | `420f` / `xf20` | rare; some analog encoders |

Never request BGRA from VT: it forces a pixel-transfer pass (+0.9 ms/frame at 1080p, +1 GB/s of
bandwidth at 16 tiles). The YCbCr→RGB conversion belongs in the `VigilRender` fragment shader.

### 7.3 Post-creation properties

```swift
func configure(_ s: VTDecompressionSession, _ cfg: VTConfig) throws {
    func set(_ key: CFString, _ value: CFTypeRef) {
        let st = VTSessionSetProperty(s, key: key, value: value)
        if st != noErr && st != kVTPropertyNotSupportedErr {
            log.warning("VTSessionSetProperty \(key) failed: \(st)")
        }
        // kVTPropertyNotSupportedErr is expected for several keys on several decoders: ignore.
    }
    set(kVTDecompressionPropertyKey_RealTime, cfg.isLive ? kCFBooleanTrue! : kCFBooleanFalse!)
    set(kVTDecompressionPropertyKey_MaximizePowerEfficiency,
        cfg.maximizePowerEfficiency ? kCFBooleanTrue! : kCFBooleanFalse!)
    set(kVTDecompressionPropertyKey_ThreadCount, cfg.threadCount as CFNumber)
    set(kVTDecompressionPropertyKey_OutputPoolRequestedMinimumBufferCount,
        cfg.minimumOutputBufferCount as CFNumber)
    if cfg.keyframesOnly {
        set(kVTDecompressionPropertyKey_OnlyTheseFrames,
            kVTDecompressionProperty_OnlyTheseFrames_KeyFrames)
    }
    if let fraction = cfg.reducedFrameDelivery {          // 0.0 ... 1.0
        set(kVTDecompressionPropertyKey_ReducedFrameDelivery, fraction as CFNumber)
    }
}
```

| Property | Value | Rationale |
|---|---|---|
| `kVTDecompressionPropertyKey_RealTime` | `true` for live, `false` for recorded/export | tells VT to prefer dropping over queueing; changes internal buffering from ~4 frames to ~1 |
| `kVTDecompressionPropertyKey_MaximizePowerEfficiency` | `true` when on battery, or when the tile is not focused, or `thermalState >= .serious`; `false` for the focused tile on AC | allows VT to batch work; adds up to one frame of latency, so never on the focused live tile while plugged in |
| `kVTDecompressionPropertyKey_ThreadCount` | `1` for hardware (ignored anyway); `min(4, ProcessInfo.activeProcessorCount / 2)` for the software fallback; `1` for `keyframesOnly` tiles | bounds software-decode CPU |
| `kVTDecompressionPropertyKey_OutputPoolRequestedMinimumBufferCount` | `queueCapacity + 3` (live: 6+3 = 9; recorded: 12+3 = 15; reverse: 70) | prevents VT stalling on pool exhaustion |
| `kVTDecompressionPropertyKey_OnlyTheseFrames` = `…_KeyFrames` | tiny tiles (§12.5) | the decoder itself skips non-keyframes — cheaper than us skipping, because it still tracks references correctly |
| `kVTDecompressionPropertyKey_ReducedFrameDelivery` | `0.5` for the 15 fps ceiling on medium tiles | decoder-side frame-rate reduction; falls back to our own drop logic if `kVTPropertyNotSupportedErr` |
| `kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder` | **read-only** | §16.1 |
| `kVTDecompressionPropertyKey_NumberOfFramesBeingDecoded` | read-only | sampled at 1 Hz into `DecodeStatistics.framesInFlight` |
| `kVTDecompressionPropertyKey_PixelBufferPool` | read-only | used to assert our pool attributes took effect |

Every `VTSessionSetProperty` result is checked, and `kVTPropertyNotSupportedErr` (`-12900`) is
**not** an error — decoders legitimately reject `ReducedFrameDelivery` and `OnlyTheseFrames`.
Record which properties were accepted in `DecodeStatistics.acceptedProperties` for the diagnostics
bundle.

### 7.4 Downscale on decode

For a tile whose backing width is at most half the coded width, request scaled output via
`kCVPixelBufferWidthKey` / `kCVPixelBufferHeightKey`:

```
target.width  = roundUp(tileBackingWidth, multipleOf: 16)
target.height = roundUp(target.width * displayHeight / displayWidth, multipleOf: 2)
```

Applied only when `codedWidth / target.width >= 2.0` and `target.width >= 160`. Cost ≈ 0.35 ms/frame
on the media engine's scaler; saves ~55 % of the Metal sampling bandwidth for a 4-up-of-16 wall.
Re-created (not reconfigured) when the tile crosses a size class; size classes are
`160, 240, 320, 480, 640, 960, 1280, 1920` so resizing a window does not thrash sessions.
Additionally rate-limit session recreation to **at most one per 750 ms per stream**, and never
during `NSView.inLiveResize` (defer until resize ends).

### 7.5 Pixel-buffer pool as backpressure

VT allocates from its own pool, but for the *reverse-playback* ring and for the snapshot path we
need our own:

```swift
func makePool(width: Int, height: Int, format: OSType, capacity: Int) throws -> CVPixelBufferPool {
    let pixelAttrs: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: format as CFNumber,
        kCVPixelBufferWidthKey: width as CFNumber,
        kCVPixelBufferHeightKey: height as CFNumber,
        kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferBytesPerRowAlignmentKey: 64 as CFNumber,
    ]
    let poolAttrs: [CFString: Any] = [
        kCVPixelBufferPoolMinimumBufferCountKey: 3 as CFNumber,
        kCVPixelBufferPoolAllocationThresholdKey: capacity as CFNumber,
    ]
    var pool: CVPixelBufferPool?
    let st = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary,
                                     pixelAttrs as CFDictionary, &pool)
    guard st == kCVReturnSuccess, let p = pool else { throw VideoPipelineError.pixelBufferPoolFailed(st) }
    return p
}

/// Returns nil when the pool is exhausted — that is the backpressure signal, not an error.
func obtain(from pool: CVPixelBufferPool, threshold: Int) -> CVPixelBuffer? {
    let aux: [CFString: Any] = [kCVPixelBufferPoolAllocationThresholdKey: threshold as CFNumber]
    var pb: CVPixelBuffer?
    let st = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
        kCFAllocatorDefault, pool, aux as CFDictionary, &pb)
    if st == kCVReturnWouldExceedAllocationThreshold { return nil }   // -6689
    return st == kCVReturnSuccess ? pb : nil
}
```

`kCVReturnWouldExceedAllocationThreshold` (`-6689`) is the sanctioned "renderer is behind" signal:
it increments `stats.poolStarvation` and pushes the latency controller one level (§10.4).

### 7.6 Decoding a frame

```swift
func decode(_ sample: CMSampleBuffer, flags: VTDecodeFrameFlags) throws {
    var info = VTDecodeInfoFlags()
    let yielder = self.frameYielder          // AsyncStream<DecodeOutput>.Continuation — Sendable (D10)
    let submitTicks = mach_absolute_time()
    let captureTicks = self.captureTicks(of: sample)
    let generation = self.generation

    let st = VTDecompressionSessionDecodeFrame(
        session, sampleBuffer: sample, flags: flags, infoFlagsOut: &info
    ) { status, infoFlags, imageBuffer, pts, duration in
        // Called on a VideoToolbox-owned thread. Do the minimum, then yield.
        if status != noErr {
            yielder.yield(.failure(status: status, generation: generation))
            return
        }
        if infoFlags.contains(.frameDropped) {
            yielder.yield(.dropped(reason: .decoderDropped, generation: generation))
            return
        }
        guard let pixels = imageBuffer as? CVPixelBuffer else {
            yielder.yield(.dropped(reason: .noImageBuffer, generation: generation))
            return
        }
        yielder.yield(.frame(Unsafe(pixels), pts: pts, duration: duration,
                             captureTicks: captureTicks, submitTicks: submitTicks,
                             generation: generation))
    }
    guard st == noErr else { throw VideoPipelineError.decodeSubmitFailed(status: st) }
}
```

```swift
public typealias VTDecompressionOutputHandler =
    (OSStatus, VTDecodeInfoFlags, CVImageBuffer?, CMTime, CMTime) -> Void

func VTDecompressionSessionDecodeFrame(
    _ session: VTDecompressionSession,
    sampleBuffer: CMSampleBuffer,
    flags decodeFlags: VTDecodeFrameFlags,
    infoFlagsOut: UnsafeMutablePointer<VTDecodeInfoFlags>?,
    outputHandler: @escaping VTDecompressionOutputHandler
) -> OSStatus
```

The pipeline's consumer task drains the `AsyncStream` (`.bufferingNewest(8)`), performs pacing and
calls `sink.present`. Measured hop cost: 40–140 µs. This is the **only** sanctioned way out of a
VideoToolbox callback (D10); `AsyncStream.Continuation` is `Sendable`, so Swift 6 accepts the
capture with no `@unchecked` anywhere.

### 7.7 Decode flags

| Flag | Live | Recorded 1× | Seek pre-roll | Fast/reverse |
|---|---|---|---|---|
| `._EnableAsynchronousDecompression` | ✅ | ✅ | ✅ | ✅ |
| `._1xRealTimePlayback` | ✅ | ✅ | ❌ | ❌ |
| `._EnableTemporalProcessing` | ❌ | ✅ | ✅ | ✅ |
| `._DoNotOutputFrame` | ❌ | ❌ | ✅ (frames before the seek target) | ❌ |

```swift
var liveFlags: VTDecodeFrameFlags {
    [._EnableAsynchronousDecompression, ._1xRealTimePlayback]
}
```

`_EnableAsynchronousDecompression` is a *permission*, not a guarantee; check
`info.contains(.asynchronous)` after submit. If VT decodes synchronously (some software decoders),
the output handler has already run when `decode` returns — the code above is correct either way
because it only yields.

`_EnableTemporalProcessing` lets VT emit frames in **presentation** order (it holds frames to
reorder B-frames). It must be **off for live** (it adds `sps_max_num_reorder_pics` frames of
latency, 2–4 frames = 66–133 ms, which alone would blow the 250 ms budget) and **on for recorded**.

`VTDecompressionSessionFinishDelayedFrames(session)` flushes the reorder queue (end of file, before
a seek). `VTDecompressionSessionWaitForAsynchronousFrames(session)` additionally blocks until all
in-flight frames are delivered — used only in §9 (drain) and teardown, never on a hot path; it can
block for up to ~40 ms.

### 7.8 Strategy switching without a dropped frame

1. Build the new session/sink while the old one keeps rendering (`generation` stays the same).
2. Wait for the first successfully decoded frame from the new path (bounded by 500 ms).
3. Ask `VigilRender` to swap layers inside a single `CATransaction` with actions disabled, then
   tear down the old path.
4. If step 2 times out, keep the old path and emit `.event(.strategySwitchFailed)`.

Because both paths decode the same `CMSampleBuffer`s, step 1–2 briefly costs two decode sessions;
the budget scheduler must admit the transient (§12.4 reserves 2 DU of headroom for exactly this).

### 7.9 VT error taxonomy and recovery

| `OSStatus` | Name | Class | Action |
|---|---|---|---|
| `-12909` | `kVTVideoDecoderBadDataErr` | A — data | Drop the AU. Count. If ≥ 4 in 2 s **or** ≥ 20 % of the last 50 AUs: flush queue, set `awaitingKeyframe`, request IDR (rate-limited 1 per 2 s). Do **not** recreate the session — the session is fine, the bitstream is not. |
| `-12903` | `kVTInvalidSessionErr` | C — session | Recreate the session immediately (a system decoder reset, sleep/wake, or GPU switch happened), then `awaitingKeyframe = true`, request IDR. Keep the displayed image. |
| `-12911` | `kVTVideoDecoderMalfunctionErr` | C — session | Same as `kVTInvalidSessionErr`, plus exponential backoff on repeats: 0 ms, 250 ms, 1 s, 4 s. After 4 consecutive malfunctions inside 30 s, fall back to `requireHardware = false`; after 6, fall back to Strategy A; report `.degraded` to `VigilCore`. |
| `-12910` | `kVTVideoDecoderUnsupportedDataFormatErr` | B — format | Do not retry with the same format. Emit `.event(.unsupportedFormat(codec:profile:))`; `VigilCore` shows "this camera's profile is not supported — switch the stream to H.264 Main". |
| `-12906` | `kVTCouldNotFindVideoDecoderErr` | B | Retry once with `requireHardware = false`. If that also fails, the codec is unavailable → `.unsupportedFormat`. |
| `-12907` | `kVTCouldNotCreateInstanceErr` | D — resources | Hardware decode sessions exhausted. Release the grant, tell `DecodeBudget` to lower the measured ceiling by 1 DU, retry after 500 ms with backoff, and demote this tile one policy step (§12.5). This is the error that makes the budget scheduler necessary. |
| `-12913` | `kVTVideoDecoderNotAvailableNowErr` | D | Retry after 250 ms, up to 8 times, then demote. |
| `-12904` | `kVTAllocationFailedErr` | D | Same as D, plus drop the pool threshold by 2. |
| `-12902` | `kVTParameterErr` | E — bug | `assertionFailure` in debug; in release log `.fault` and tear the pipeline down. |
| `-12900` | `kVTPropertyNotSupportedErr` | — | Not an error (property probing). |
| `-12916` | `kVTFormatDescriptionChangeNotSupportedErr` | B | Treated as "cannot reconfigure" → run §9 with a full recreate. |
| any other negative | — | C | Treated as class C (recreate + wait for IDR) with the class-C backoff; logged at `.error` with the raw value so field reports are actionable. |

`awaitingKeyframe` semantics: every AU with `isKeyframe == false` is dropped (counted as
`framesDroppedAwaitingKeyframe`) until the next keyframe arrives. This prevents the classic
"green blocks and smearing after a reconnect".

Keyframe requests go out through the injected closure
`requestKeyframe: @Sendable () async -> Void`, implemented by `VigilCore` as (in order of
preference) an ISAPI `PUT /ISAPI/Streaming/channels/{id}/requestKeyFrame`, an RTSP
`SET_PARAMETER` with `Immediate-IDR`, or an RTSP re-`PLAY`. `VigilVideo` only asks.

---

## 8. Strategy selection matrix

```swift
public enum DisplayStrategy: Sendable, Hashable {
    case sampleBufferLayer         // A
    case pixelBufferMetal          // B
}

public struct StrategyInputs: Sendable {
    var needsPixelAccess: Bool     // zoom≠1, colour adjust, deinterlace, burn-in, atlas mode
    var isRecordedPlayback: Bool
    var rate: Double
    var tileCount: Int
    var metalAvailable: Bool
    var isInterlaced: Bool
}

public func selectStrategy(_ i: StrategyInputs) -> DisplayStrategy {
    if !i.metalAvailable { return .sampleBufferLayer }              // Metal init failed → fallback
    if i.isRecordedPlayback && (i.rate != 1.0 || i.rate < 0) { return .pixelBufferMetal }
    if i.isInterlaced { return .pixelBufferMetal }
    if i.needsPixelAccess { return .pixelBufferMetal }
    if i.tileCount > 16 { return .sampleBufferLayer }               // cheapest at high fan-out
    return .sampleBufferLayer
}
```

Snapshots do **not** force Strategy B: a `.decoded` snapshot from a Strategy-A tile is taken by
spinning up a one-shot `VTDecompressionSession`, decoding the next keyframe with
`_DoNotOutputFrame` cleared, and invalidating it (~35 ms, 1 DU for < 100 ms). A `.displayed`
snapshot (with zoom/overlays) requires Strategy B and will transparently switch the tile per §7.8,
switching back 2 s later.

---

## 9. Mid-stream format changes

Causes seen in the field: the user changes resolution in the camera web UI; an NVR channel
switches between a 1080p and a 720p source; day/night mode changes the SPS on some firmware;
a substream renegotiates after packet loss; the stream flips between 1920×1080 and 1920×1088
cropping.

### 9.1 Detection

Three independent detectors, all live:

1. **Parameter-set fingerprint** (§4.5) — authoritative and cheapest. Runs on every AU that carries
   parameter sets.
2. **`VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: newDesc)`** —
   returns `Bool`. `true` ⇒ the existing session can decode the new format (e.g. only a PPS changed,
   or the level went up but dimensions did not). Then we **reuse** the session and only replace the
   stored `CMVideoFormatDescription` used to build sample buffers.
3. **Decoded pixel-buffer dimensions** — `CVPixelBufferGetWidth/Height` compared to the expected
   coded size on every 60th frame. Catches firmware that changes resolution *without* sending a new
   SPS (it happens; treated as a corrupt stream → force recreate + IDR request).

```swift
enum FormatTransition {
    case none
    case compatible(CMVideoFormatDescription)    // reuse session, swap format description
    case incompatible(CMVideoFormatDescription)  // drain + recreate
}
```

`incompatible` when: coded dimensions differ, codec differs, bit depth differs, chroma format
differs, or `CanAcceptFormatDescription` is `false`.

### 9.2 The no-flash recreate sequence

```
T+0    detect .incompatible on AU n (which is, by construction, a keyframe with new SPS)
T+0    sink.willChangeFormat(from:to:generation: g+1)     // renderer PINS its last texture/image
T+0    generation = g+1        (all in-flight g outputs are now discarded on arrival)
T+0    stop submitting new AUs; keep the AU that triggered the change
T+0    VTDecompressionSessionFinishDelayedFrames(old)     // ≤ 20 ms
T+0    VTDecompressionSessionWaitForAsynchronousFrames(old)  // ≤ 40 ms, on a detached task
T+~5   VTDecompressionSessionInvalidate(old); old = nil
T+~5   release the old DecodeBudget grant, request a new grant with the new cost
T+~6   create the new session (§7.1); create the new pool if Strategy B
T+~8   submit the pending keyframe AU
T+~20  first decoded frame of generation g+1 arrives
T+~20  sink.present(frame)  →  renderer cross-fades 120 ms (ease-out) from the pinned image
T+~20  sink.didChangeFormat(to:generation:)
```

Hard rules that prevent the black flash / window jump:

* **Never** call `rendering.flush(removingDisplayedImage: true)` on a format change; use `flush()`.
* **Never** tear down or resize the hosting `NSView`/`CALayer`. The tile keeps its frame; only
  `videoGravity`/the Metal model matrix reinterpret the new aspect ratio. Aspect changes animate
  over 180 ms with `CAMediaTimingFunction(name: .easeInEaseOut)`.
* Strategy B: the renderer keeps the last `MTLTexture` alive (it holds the `CVPixelBuffer`
  reference) and keeps drawing it every vsync until the first new-generation frame lands. This is a
  `VigilRender` obligation stated in `willChangeFormat`.
* Strategy A: the layer retains its displayed image across `flush()`; nothing else is needed.
* If the new session cannot be created within 1.5 s, emit `.event(.formatChangeStalled)` and show
  the renderer's "reconnecting" scrim **over** the frozen last frame, never a black rect.
* The whole sequence runs inside the pipeline actor, so no AU can interleave. The pending-AU
  variable holds exactly one keyframe; later AUs that arrive during the recreate are dropped and
  counted as `framesDroppedFormatChange` (typically 0–2 frames).

### 9.3 Timing budget

| Step | Typical | Cap (then `.formatChangeStalled`) |
|---|---|---|
| drain (`FinishDelayedFrames` + `WaitForAsynchronousFrames`) | 3–12 ms | 200 ms |
| invalidate + create new session | 4–15 ms (HEVC 1080p on M1: 11 ms) | 800 ms |
| first frame decoded | 6–20 ms | 500 ms |
| **total user-visible freeze** | **20–45 ms** (≈ 2 frames) | 1.5 s |

A 20–45 ms freeze at 30 fps is invisible. Any implementation that flashes black has broken one of
the hard rules above.

---

## 10. Live low-latency clock

### 10.1 Principles

1. **No A/V sync buffering for live.** Video renders on decode. Audio has its own small ring
   (§13.4) and is never used to gate video. Lip-sync error of up to ±80 ms is accepted for live and
   is inaudible for surveillance content; the alternative (buffering video to the audio clock) costs
   150–300 ms and is rejected.
2. **No timebase.** `DisplayImmediately` on every sample (Strategy A) or immediate `present`
   (Strategy B).
3. **Bounded queue.** Latency cannot accumulate; when we are behind we discard, we never catch up
   by playing fast.
4. **Drop to keyframe when badly behind**, because dropping references produces artefacts.
5. **Measure, then adapt.** The controller is closed-loop on measured queue depth and measured
   end-to-end latency, not on assumptions.

### 10.2 Glass-to-glass budget (target < 250 ms, measured on a LAN with a DS-2CD2xxx at 1080p30)

| Stage | Typical | Worst accepted | Owner |
|---|---|---|---|
| Camera capture → encoder output | 33 ms | 66 ms | camera |
| Camera internal send buffer | 10 ms | 60 ms | camera (reduce by setting `SmartCodec off`, GOP ≤ 2 s) |
| LAN transit | 0.4 ms | 5 ms | network |
| RTP reorder buffer (low-latency mode) | 0–8 ms | 40 ms | `VigilRTP` |
| Depacketize + AU assemble | 0.3 ms | 2 ms | `VigilRTP` |
| Pipeline queue wait | 0–16 ms | 33 ms | **this module** |
| Block+sample buffer construction | 0.05 ms | 0.3 ms | **this module** |
| Hardware decode (1080p H.264) | 3.5 ms | 12 ms | **this module** |
| Hardware decode (1080p HEVC) | 5.5 ms | 16 ms | **this module** |
| Sink handoff + Metal encode | 1.2 ms | 4 ms | `VigilRender` |
| WindowServer composite + display latch @120 Hz | 8.3 ms | 16.6 ms | system |
| **Total** | **≈ 60–75 ms** | **≈ 215 ms** | |

The app's own contribution (rows marked *this module*) must stay **under 55 ms at p99**. That is the
number the benchmark harness gates on.

### 10.3 The frame queue

```swift
struct FrameQueue {
    private var storage: [PendingAU]        // ring, no allocation after init
    let capacity: Int                       // live: 6, recorded: 12, reverse: 72
    let target: Int                         // live: 2
    var count: Int { … }
    /// Returns what was dropped, if anything.
    mutating func push(_ au: PendingAU) -> DropOutcome
    mutating func pop() -> PendingAU?
    mutating func flushToKeyframe() -> Int  // discards everything before the newest keyframe
    mutating func removeAll() -> Int
}
```

`push` policy when `count == capacity`, in order:

1. Drop the **oldest** `.droppableTemporal` AU. (Highest temporal id first when several.)
2. Else drop the **oldest** `.droppableNonReference` AU.
3. Else drop the **oldest** non-keyframe AU and set `awaitingKeyframe = true` (references are now
   broken, so anything before the next keyframe would be garbage) and request a keyframe.
4. Else (everything queued is a keyframe — a stream with GOP = 1, i.e. all-intra) drop the oldest.

Every drop increments a distinct counter and is reported through `sink.didDropFrames(_:reason:)` so
the UI can show an honest "N dropped" badge.

### 10.4 Adaptive latency controller — exact thresholds

Sampled on every AU push and every 100 ms tick. Sliding window = 2 s. Two signals:

* `depthEWMA` = EWMA of `queue.count` with α = 0.15 (per push).
* `latencyEWMA` = EWMA of `HostClock.ms(since: frame.capturedAtHostTicks)` measured at
  `sink.present`, α = 0.10. Plus `latencyP95` over a 120-sample ring.

```swift
enum LatencyLevel: Int, Comparable { case normal = 0, trim = 1, skipToKeyframe = 2, degrade = 3 }
```

| From → To | Condition (all must hold for the stated dwell) | Action |
|---|---|---|
| normal → trim | `depthEWMA ≥ 3.0` for 500 ms, **or** `latencyP95 ≥ 220 ms` for 1 s | drop up to every other droppable frame; set `ReducedFrameDelivery = 0.75` if supported |
| trim → skipToKeyframe | `depthEWMA ≥ 5.0` for 300 ms, **or** `latencyEWMA ≥ 400 ms` for 1 s, **or** ≥ 3 queue-full events in 2 s, **or** ≥ 2 `poolStarvation` events in 1 s | `queue.flushToKeyframe()`, `awaitingKeyframe = true`, `requestKeyframe()` (rate-limited: min 2 s apart, ≤ 10/min), `rendering.flush()` (image preserved) |
| skipToKeyframe → degrade | 3 skipToKeyframe entries within 30 s | emit `.event(.persistentlyBehind(measuredLatencyMS:))`; `VigilCore` demotes main→sub, or lowers the fps ceiling one step, or (16-up) demotes the tile per §12.5 |
| any → normal | `depthEWMA ≤ 1.5` **and** `latencyEWMA ≤ 150 ms` **and** no drop for 5 s | step down exactly one level per 5 s (never jump straight to normal from degrade) |

Additional hard rules:

* If **no frame at all** for 2 s: `sink.didStall(since:)`, and after 5 s emit `.event(.stalled)`;
  `VigilCore`'s `StreamController` owns the reconnect decision (this module never reconnects).
* If `awaitingKeyframe` persists > 6 s, escalate: emit `.event(.keyframeTimeout)`.
* The controller is per-stream. A global variant (`ThermalGovernor`, §16.3) can force every stream
  to `trim` under thermal pressure.
* Hysteresis is mandatory: the down-step dwell (5 s) is 10× the up-step dwell (500 ms). Without it,
  a 16-tile wall oscillates audibly.

### 10.5 Live audio interaction

Live audio never gates video. If the audio ring underruns three times in 5 s the audio player
raises its own prime target (§13.4) — video is untouched. If video enters `skipToKeyframe`, audio
continues uninterrupted (this is correct: surveillance audio continuity matters more than
sync).

---

## 11. Recorded playback

Recorded playback is a **different object** (`actor PlaybackPipeline`), not a mode flag on
`DecodePipeline`. It shares `FormatDescriptionFactory`, `SampleBufferBuilder`, the VT session
wrapper and the budget scheduler, and nothing else. Trying to make one object do both is how
players end up with a low-latency path that stutters and a scrub path that is 400 ms behind.

### 11.1 Sources

Frames arrive from the NVR over RTSP from a `playbackURI`
(`rtsp://host/Streaming/tracks/101?starttime=…&endtime=…`), depacketized by `VigilRTP` exactly as
live. `PlaybackPipeline` additionally consumes:

```swift
public protocol PlaybackTransportControl: Sendable {
    /// RTSP PLAY with Range: clock=<utc>- ; returns the server-confirmed start time.
    func seek(to date: Date) async throws -> Date
    /// RTSP PLAY with Scale: <s>. Returns the scale the server actually accepted (1.0 if none).
    func setScale(_ scale: Double) async throws -> Double
    func pause() async throws
    func resume() async throws
    var supportsServerScale: Bool { get async }
    var supportsReverse: Bool { get async }
}
```

Rule: if `setScale(4)` returns `1.0` (no `Scale:` header echoed in the response), we do the rate
change client-side. Hikvision NVRs generally support `Scale: 1, 2, 4, 8` and negative values on
`Streaming/tracks`; IP cameras with SD cards usually do not.

### 11.2 Timebase and DTS

Recorded content **can** contain B-frames (`H264Profile=High`, `BFrame` on) so PTS ≠ DTS.

* Strategy A: DTS **must** be supplied on every sample. `VigilRTP` provides it when the stream
  carries `pic_order_cnt` info; when it does not, we synthesise DTS by delaying PTS by
  `reorderDepth` frame durations: `dts = pts - reorderDepth * duration`, where
  `reorderDepth = sps_max_num_reorder_pics` (H.265) or `max_num_reorder_frames` from
  `bitstream_restriction` (H.264), defaulting to 2 for High profile and 0 for Baseline/Constrained.
* Strategy B: set `_EnableTemporalProcessing`; VT emits in presentation order and we additionally
  run a safety `ReorderHeap` (a min-heap on PTS, capacity `reorderDepth + 2`, flushed when a frame
  older than the head arrives or on `FinishDelayedFrames`). The heap exists because a small number
  of NVR firmwares emit POC values that VT reorders correctly but that our own PTS derivation
  mis-orders; the heap makes the two agree.

```swift
struct ReorderHeap {
    let capacity: Int
    mutating func push(_ f: DecodedVideoFrame) -> DecodedVideoFrame?   // emits when full
    mutating func drain() -> [DecodedVideoFrame]                        // PTS-ascending
}
```

Presentation of a heap output happens when
`timebase.time >= frame.pts - halfFrameDuration`, evaluated on the display link tick supplied by
`VigilRender` (macOS 14 `NSView.displayLink(target:selector:)`).

### 11.3 Rate control

```swift
public enum PlaybackRate: Double, CaseIterable, Sendable {
    case r0_25 = 0.25, r0_5 = 0.5, r1 = 1, r2 = 2, r4 = 4, r8 = 8
}
public enum PlaybackDirection: Sendable { case forward, reverse }
```

| Rate | Mechanism | Strategy | Audio |
|---|---|---|---|
| 0.25×, 0.5× | client-side: `synchronizer.setRate(r, time:)` (A) or timebase rate (B). All frames decoded and shown, each held 2–4 vsyncs. | A or B | muted (no pitch correction) |
| 1× | `setRate(1.0)` | A (default) | on |
| 2× | server `Scale: 2` if available; else decode all, present every other frame | A if server-scaled, else B | muted |
| 4×, 8× | server `Scale:` if available; else **keyframe-only** decode (`OnlyTheseFrames = KeyFrames`) presented at 8–15 fps | B | muted |
| reverse, any rate | §11.5 | **B only** | muted |

Above 2× the pipeline sets `RealTime = false` and `MaximizePowerEfficiency = false` and raises the
queue capacity to 24 — throughput matters more than latency when scrubbing.

### 11.4 Seek

Two-phase, so the scrubber feels instant:

1. **Coarse (server):** `transport.seek(to: date)` → RTSP `PLAY Range: clock=20260726T101500Z-`.
   The NVR resumes at the GOP boundary at or before the requested instant. Latency 120–600 ms on
   Hikvision NVRs (it is a disk seek).
2. **Fine (client):** frames arrive starting at the IRAP before the target. Submit every AU with
   `_DoNotOutputFrame` **set** until `pts >= targetPTS`, then clear it. The first displayed frame is
   exactly the requested one. Cost: decoding up to one GOP (≤ 50 frames ≈ 40 ms of decode).
3. While a seek is in flight the UI shows the **previous** frame with a subtle 40 % scrim, never
   black. `PlaybackPipeline` emits `.seeking(progress:)`.
4. Scrub coalescing: while the user drags, seeks are coalesced to at most one per 250 ms, and only
   phase 1 runs (keyframe-only preview, `OnlyTheseFrames = KeyFrames`); phase 2 runs on mouse-up.
   This gives a Final-Cut-like scrub over a 3 Mbps NVR link.

### 11.5 Reverse playback

The NVR rarely supports negative `Scale:`, so implement it client-side, GOP by GOP:

```
1. Determine the GOP containing the current PTS (track keyframe PTS in a sparse index built while
   playing forward, plus ISAPI ContentMgmt search results for coarse structure).
2. Request that GOP (RTSP PLAY Range clock=<gopStart>-<gopEnd>).
3. Decode the whole GOP into a ring of CVPixelBuffers obtained from our own pool (§7.5).
4. Present the ring in reverse at the requested rate.
5. While presenting, prefetch and decode the PREVIOUS GOP into a second ring (double buffering).
6. Repeat.
```

Caps: `reverseRingFrames = min(90, budgetFramesFor(memory: 320 MB, format: current))`. For 1080p
`420v` a frame is 1920×1088×1.5 ≈ 3.1 MB, so 90 frames ≈ 280 MB — acceptable for one tile, and
reverse playback is allowed on **one tile at a time only** (enforced by `DecodeBudget`, cost 6 DU).
If a GOP is longer than the ring, decode only every *n*-th frame where
`n = ceil(gopLength / ringFrames)` and present at the requested rate (visually a 2× or 3× reverse).

### 11.6 Pause and single-frame step

* **Pause:** `synchronizer.setRate(0, time: currentTime)` (A) or `CMTimebaseSetRate(tb, 0)` (B).
  Stop submitting AUs; keep the session alive for 30 s, then invalidate and release the budget grant
  (a paused tile must not hold a hardware decode slot forever). On resume: recreate if needed,
  fine-seek to the paused PTS, and clear the pause without a visible jump.
* **Step forward:** submit exactly one AU, present it, return to paused. If the next AU is not yet
  buffered, request it. Rate-limited to 30 steps/s so key-repeat feels smooth.
* **Step backward:** requires the reverse ring. If the ring holds the previous frame, present it
  from the ring (instant). Otherwise decode from the GOP's IRAP with `_DoNotOutputFrame` until
  `targetPTS - oneFrame`. Worst case ~40 ms — fast enough for held key-repeat at 20 Hz.

### 11.7 Frame-accurate export handoff

`VigilCore`'s clip export needs the compressed samples, not pixels. `PlaybackPipeline` exposes
`sampleTap: AsyncStream<Unsafe<CMSampleBuffer>>` delivering the *original* samples (unmodified
timing, no `DisplayImmediately`), which `AVAssetWriter` muxes with passthrough. The tap is
lazily created and adds < 0.1 % CPU.

<!-- PART2 -->
