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

---

## 12. Decode-budget scheduler

### 12.1 Why

macOS has a finite number of concurrent hardware decode sessions (the practical limit on an M1 is
around 20–24 simultaneous `VTDecompressionSession`s before `kVTCouldNotCreateInstanceErr`, and the
media engine saturates on throughput well before that). A 16-up wall plus sidebar previews plus a
playback window plus a snapshot easily exceeds it. Without central admission the failure mode is
random: the 17th tile shows black and the log shows `-12907`. With it, the failure mode is designed:
the least important tile degrades to a JPEG refresh.

### 12.2 Cost model

Cost is expressed in **decode units (DU)**, normalised so that 1080p30 H.264 = 1.00 DU:

```
DU = (width × height × fps) / (1920 × 1080 × 30) × codecWeight × modeWeight
```

| Factor | Value |
|---|---|
| `codecWeight` H.264 8-bit | 1.00 |
| `codecWeight` H.265 8-bit | 1.35 |
| `codecWeight` H.265 Main10 | 1.70 |
| `codecWeight` MJPEG (software) | 0.40 (CPU only, does not consume a hardware slot) |
| `modeWeight` full decode | 1.00 |
| `modeWeight` fps-capped (15 fps ceiling on a 30 fps stream) | 0.55 (not 0.5 — reference frames are still decoded) |
| `modeWeight` keyframe-only | 0.12 |
| `modeWeight` downscaled output (§7.4) | +0.05 additive (the scaler pass) |
| `modeWeight` reverse playback | 6.00 (whole-GOP bursts + memory) |

Worked examples:

| Stream | DU |
|---|---|
| 704×576 @ 25 H.264 (typical Hikvision substream) | 0.16 |
| 1280×720 @ 25 H.264 | 0.37 |
| 1920×1080 @ 30 H.264 | 1.00 |
| 1920×1080 @ 30 H.265 | 1.35 |
| 2688×1520 @ 25 H.265 (4 MP main) | 2.37 |
| 3840×2160 @ 30 H.265 Main10 (8 MP) | 6.80 |
| 16 × 704×576 @ 25 H.264 substreams | 2.56 |
| 16 × 1920×1080 @ 30 H.264 substreams | 16.0 |

### 12.3 Machine budget

Seeded from a static table, then **calibrated at runtime**.

```swift
struct MachineClass: Sendable {
    let name: String
    let budgetDU: Double
    let maxSessions: Int
    let hasHardwareHEVC: Bool
    let hasHardware10bit: Bool
}
```

| Detection | Class | budget DU | max sessions |
|---|---|---|---|
| `hw.optional.arm64 == 1`, `hw.model` contains `Mac14,13`/`Mac14,14`/`Mac15,x Ultra`/two media engines | Apple silicon Max/Ultra | 48 | 32 |
| Apple silicon, `hw.perflevel0.physicalcpu >= 6` (Pro) | Apple silicon Pro | 32 | 28 |
| Apple silicon, base M1/M2/M3/M4 | Apple silicon base | 20 | 24 |
| Intel, HEVC probe session with `RequireHardware` succeeds (T2 or Kaby Lake+) | Intel + Quick Sync | 12 | 16 |
| Intel, H.264 hardware only | Intel legacy | 6 | 8 |
| Both probe sessions fail (VM, stripped GPU) | software only | 3 | 4 |

Detection code:

```swift
func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
}
func sysctlInt(_ name: String) -> Int? {
    var v: Int64 = 0; var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
    return Int(v)
}
// hw.model, machdep.cpu.brand_string, hw.optional.arm64,
// hw.perflevel0.physicalcpu, hw.perflevel1.physicalcpu, hw.memsize
```

Never gate features on the static table alone — it goes stale with every new Mac. The table is a
**seed**; the closed loop is authoritative:

| Observation (10 s window, aggregated over all streams) | Adjustment |
|---|---|
| `decodeLateRatio > 2 %` **or** any `kVTCouldNotCreateInstanceErr` | `budget *= 0.90`, `maxSessions -= 1` (floor 2 / 2 DU) |
| `decodeLateRatio < 0.2 %` **and** at least one request is queued for admission | `budget *= 1.05` (ceiling 1.5 × seed) |
| `thermalState` change | apply the §16.3 multiplier (multiplicative, not persisted) |

`decodeLateRatio` = frames whose decode wall time exceeded their duration, over frames submitted.
Calibration state persists in `~/Library/Application Support/Vigil/decode-budget.json`
(`{"model":"Mac14,2","budgetDU":19.4,"maxSessions":23,"version":1}`) so the second launch starts
calibrated. `VigilCore` owns the file write; `VigilVideo` supplies the value via
`DecodeBudget.calibration`.

### 12.4 Admission

```swift
@globalActor
public actor DecodeBudget {
    public static let shared = DecodeBudget()

    public struct Request: Sendable {
        public let streamID: StreamIdentifier
        public let cost: DecodeCost
        public let priority: TilePriority
        public let isPreemptible: Bool          // false for the focused tile and for recording
    }
    public struct Grant: Sendable, Identifiable { public let id: UUID; public let cost: DecodeCost }

    public func admit(_ r: Request) async -> AdmissionResult
    public func update(_ id: Grant.ID, cost: DecodeCost, priority: TilePriority) async
    public func release(_ id: Grant.ID) async
    public func reserveTransient(du: Double, for: Duration) async -> Bool   // §7.8 strategy switch
    public var changes: AsyncStream<BudgetChange> { get }   // demotion orders to pipelines
    public func snapshot() async -> BudgetSnapshot          // for the diagnostics panel
}

public enum AdmissionResult: Sendable {
    case granted(DecodeBudget.Grant)
    case grantedDegraded(DecodeBudget.Grant, DecodeMode)   // admitted at a cheaper mode
    case denied(reason: DenialReason)                      // caller must use JPEG poll or pause
}

public enum TilePriority: Int, Comparable, Sendable {
    case focused = 5          // the tile with keyboard focus / fullscreen / 1-up
    case visibleLarge = 4     // on screen, ≥ 640 backing px wide
    case visibleSmall = 3     // on screen, smaller
    case recording = 4        // must not be preempted while a clip is being written
    case sidebarThumbnail = 1
    case offscreen = 0
}
```

Algorithm:

1. `headroom = budget × 0.92 - committed` (8 % kept free: 2 DU minimum for transient strategy
   switches and one-shot snapshot sessions).
2. If `cost ≤ headroom` and `sessions < maxSessions` → `granted`.
3. Else try the next cheaper `DecodeMode` for this request (full → fpsCapped → keyframesOnly) and
   re-test → `grantedDegraded`.
4. Else preempt: sort existing grants by `(priority, -cost, lastPromotedAt)` ascending; for each
   preemptible grant with strictly lower priority, demote it one mode (emitting
   `BudgetChange.demote(streamID:to:)`), recompute headroom, and retry. Never demote below
   `keyframesOnly` by preemption — the last step (to `jpegPoll`) is only taken for the tile's *own*
   size policy, so a large visible tile never silently becomes a still image because of an offscreen
   one.
5. Else `denied(.insufficientBudget)`. Caller falls back to JPEG poll (visible) or paused (not).

Promotion is the mirror image and is rate-limited to one promotion per stream per 3 s, with a
minimum dwell of 5 s in the current mode, to stop wall-wide oscillation. Every admission decision
is logged once at `.info` with the resulting `BudgetSnapshot` (committed DU, session count, per-tile
mode) — this log is the first thing to look at in a "why is tile 12 a still image" bug report.

### 12.5 Tile policy table (normative — D6)

Sizes are the tile's **backing-store pixel width** (`points × backingScaleFactor`), because that is
what actually costs bandwidth. Aspect is assumed 16:9; for 4:3 channels use the width unchanged.

```swift
public enum DecodeMode: Int, Comparable, Sendable {
    case paused = 0, jpegPoll = 1, keyframesOnly = 2, fpsCapped = 3, full = 4
}
public enum StreamChoice: Sendable { case main, sub, third, none }
```

| Tile backing width | Layout context | Stream | Mode | fps ceiling | Notes |
|---|---|---|---|---|---|
| ≥ 1600 | 1-up or 2-up, focused | `main` | `full` | native | full quality; HEVC and 4 K allowed if budget permits |
| 960 … 1599 | any | `main` if ≤ 4 tiles else `sub` | `full` | native | |
| 640 … 959 | any | `sub` | `full` | native | the common 16-up case on a 27″ display |
| 384 … 639 | any | `sub` | `fpsCapped` | 15 | `ReducedFrameDelivery = 0.5`; downscale-on-decode active |
| 224 … 383 | any | `sub` | `keyframesOnly` | ~0.5–2 | `OnlyTheseFrames = KeyFrames`; suggest the user set the camera I-frame interval to ≤ 25 for a nicer refresh |
| < 224 | grid tile | `none` | `jpegPoll` | — | ISAPI JPEG every **2.0 s**, requested at 320×180 |
| any | sidebar / camera-list thumbnail | `none` | `jpegPoll` | — | JPEG every **5.0 s**, requested at 320×180 |
| any | scrolled out of a visible scroll view | `none` | `jpegPoll` | — | JPEG every **15.0 s** |
| any | window occluded / minimised / on another Space | `none` | `paused` | — | no decode, no poll (§12.7) |
| any | tile hovered or clicked (any size) | as above | promote one step for 10 s | | "peek" promotion, so hovering a JPEG tile gives live video within ~400 ms |

JPEG request sizing: round the tile's backing width up to the next of `{320, 640, 1280}` and request
`GET /ISAPI/Streaming/channels/{id}/picture?videoResolutionWidth=W&videoResolutionHeight=H`.
Per-device JPEG concurrency is 1 and per-device rate is ≤ 1 request/s (Hikvision devices serialise
snapshot generation and a burst starves the RTSP server); the poller therefore round-robins across
that device's tiles and stretches the nominal interval when a device has many polled tiles:
`effectiveInterval = max(nominalInterval, pollingTileCount × 1.0 s)`.

Jitter every poll by ±15 % to avoid 16 tiles hitting one NVR on the same tick.

Why 224 px for keyframes-only: below ~224 px a 1080p substream is downscaled more than 3:1, so
temporal detail is nearly invisible while decode cost is unchanged; and below 224 px a 2 s JPEG
refresh is visually indistinguishable from 15 fps for surveillance content at normal viewing
distance. These two thresholds (224, 384) were chosen so that the standard layouts land cleanly:

| Layout | 1440 pt window (13″ MBA, ×2) | 2560 pt window (27″, ×2) |
|---|---|---|
| 4-up (2×2) | 1440 px → `main`, full | 2560 px → `main`, full |
| 9-up (3×3) | 960 px → `sub`/`full` | 1706 px → `main`, full |
| 16-up (4×4) | 720 px → `sub`, `full` | 1280 px → `sub`, `full` |
| 36-up (6×6) | 480 px → `sub`, `fpsCapped` 15 | 853 px → `sub`, `full` |
| 64-up (8×8) | 360 px → `sub`, `fpsCapped` 15 | 640 px → `sub`, `full` |
| 64-up in a 720 pt side panel | 180 px → `jpegPoll` 2 s | 180 px → `jpegPoll` 2 s |

So on Apple silicon the headline case — **16-up 1080p substreams — is always full decode**, which
is exactly what the product bar demands (16 × 1080p30 H.264 sub = 16.0 DU against a base-M1 budget
of 20 DU, at 9–14 % total CPU). The degraded modes exist for 36/64-up and for Intel.

```swift
public enum TilePolicy {
    public static func mode(for tile: TileContext) -> (StreamChoice, DecodeMode, Int?, TimeInterval?)
}
public struct TileContext: Sendable {
    public var backingWidth: Int
    public var tileCount: Int
    public var isFocused: Bool
    public var isSidebarThumbnail: Bool
    public var isScrolledOffscreen: Bool
    public var windowIsOccluded: Bool
    public var isHoveredRecently: Bool
    public var deviceSupportsSubstream: Bool     // some analog channels have no substream
}
```

If a camera has no substream (`deviceSupportsSubstream == false`), a tile that wanted `sub` gets
`main` at `fpsCapped`/`keyframesOnly` instead, and its cost is recomputed — a single 4 MP main stream
at keyframes-only is 0.28 DU, still cheap.

### 12.6 MJPEG channels

Some analog-encoder channels only offer MJPEG. MJPEG is decoded with
`CGImageSourceCreateWithData` + `CGImageSourceCreateImageAtIndex` (or `CIImage(data:)` for the
Metal path) on a dedicated `TaskGroup` with concurrency 2 per stream; it never creates a
`VTDecompressionSession` and never consumes a hardware slot, but it does consume CPU budget
(0.40 DU-equivalent, tracked separately as `cpuDU` with its own ceiling of
`activeProcessorCount × 0.5`). Frame rate is capped at 10 fps regardless of tile size.

### 12.7 Pausing for occlusion, minimisation and Spaces

Observed on `@MainActor` by `OcclusionMonitor`:

```swift
NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, …)
NotificationCenter.default.addObserver(forName: NSWindow.didMiniaturizeNotification, …)
NotificationCenter.default.addObserver(forName: NSWindow.didDeminiaturizeNotification, …)
NotificationCenter.default.addObserver(forName: NSApplication.didHideNotification, …)
NotificationCenter.default.addObserver(forName: NSWorkspace.shared.notificationCenter
                                             .didActivateApplicationNotification, …)   // Space change proxy
let visible = window.occlusionState.contains(.visible)
```

The escalation ladder (per stream, timers reset the moment the window becomes visible):

| Time occluded | Action | Cost freed | Resume cost |
|---|---|---|---|
| 0 s | stop calling `sink.present`; keep decoding for 1 s so a quick Cmd-Tab back is instantaneous | 0 | 0 ms |
| 1 s | stop submitting AUs to the decoder; `awaitingKeyframe = true`; keep the session and the RTSP stream | ~90 % of GPU/media engine | ~1 GOP (≤ 2 s) or instant with an IDR request |
| 30 s | `VTDecompressionSessionInvalidate`; release the `DecodeBudget` grant; keep the RTSP session (TCP keepalive only, packets discarded after depacketize) | the hardware slot | session create (~10 ms) + IDR |
| 5 min | tell `VigilCore` to tear the RTSP session down entirely (`.event(.idleTeardownAdvised)`) | socket + camera-side session | full reconnect (0.5–2 s) |

On resume: request an IDR immediately, and simultaneously fire **one** ISAPI JPEG so the tile shows
a current image within ~150 ms instead of waiting for the keyframe. This "JPEG bridge" is the
single most noticeable polish detail in the whole module — implement it.

`requiresFlushToResumeDecoding` (§6.5) frequently becomes `true` exactly here, so the resume path
must call `rendering.flush()` before enqueueing.

---

## 13. Audio playback

### 13.1 Graph

One `AVAudioEngine` for the whole app (`AudioPlaybackEngine`, an actor with a `@MainActor`-free
interior). Per camera:

```
AVAudioSourceNode(format: 48k/1ch/Float32, renderBlock:)   ← AudioRingBuffer ← decoder
        │
        ├── AVAudioMixerNode  (per-camera volume, pan, mute ramp)
        │
        └──▶ engine.mainMixerNode ──▶ engine.outputNode
```

```swift
let engineFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                 sampleRate: 48_000, channels: 1, interleaved: false)!
let source = AVAudioSourceNode(format: engineFormat) { silence, timestamp, frameCount, audioBufferList in
    // REALTIME THREAD. No allocation, no locks that can block, no Swift runtime calls that allocate,
    // no actor access, no os_log with interpolation.
    let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
    guard let out = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
    let got = ring.read(into: out, frames: Int(frameCount))     // lock-free SPSC
    if got < Int(frameCount) {
        // Underrun: fade the tail over the last 64 frames, then zero. Never emit a click.
        Ring.fadeOutAndZero(out, from: got, to: Int(frameCount))
        underrunFlag.store(true, ordering: .relaxed)            // Atomics via os_unfair_lock-free flag
    }
    return noErr
}
engine.attach(source); engine.attach(mixer)
engine.connect(source, to: mixer, format: engineFormat)
engine.connect(mixer, to: engine.mainMixerNode, format: engineFormat)
```

Engine lifecycle: started lazily on the first unmuted stream; stopped 5 s after the last one goes
silent (saves ~1.5 % CPU and lets the audio hardware idle). `AVAudioEngineConfigurationChange`
notification (device change, sample-rate change, headphones) → stop, rebuild connections, restart,
reprime every ring. Never assume the output sample rate; always convert to 48 kHz internally and let
the engine's output node resample if the device runs at 44.1 kHz.

### 13.2 AAC decode (AudioToolbox `AudioConverter`)

Input: `EncodedAudioFrame` from `VigilRTP` (RFC 3640 AAC-hbr), one or more raw AAC access units per
RTP packet, plus the `AudioSpecificConfig` bytes derived from the SDP `config=` hex string.

```swift
final class AACDecoder {
    private var converter: AudioConverterRef?
    private var inASBD = AudioStreamBasicDescription()
    private var outASBD = AudioStreamBasicDescription()

    init(asc: Data, channels: UInt32, sampleRate: Double) throws {
        inASBD.mSampleRate = sampleRate
        inASBD.mFormatID = kAudioFormatMPEG4AAC
        inASBD.mFormatFlags = 0
        inASBD.mChannelsPerFrame = channels
        inASBD.mFramesPerPacket = 1024              // 2048 for AAC-LD/ELD; 960 for some configs
        inASBD.mBytesPerPacket = 0                  // variable
        inASBD.mBytesPerFrame = 0
        inASBD.mBitsPerChannel = 0

        outASBD.mSampleRate = sampleRate            // decode at native rate; resample in §13.3
        outASBD.mFormatID = kAudioFormatLinearPCM
        outASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        outASBD.mChannelsPerFrame = channels
        outASBD.mFramesPerPacket = 1
        outASBD.mBytesPerPacket = 4 * channels
        outASBD.mBytesPerFrame = 4 * channels
        outASBD.mBitsPerChannel = 32

        var conv: AudioConverterRef?
        let st = AudioConverterNew(&inASBD, &outASBD, &conv)
        guard st == noErr, let c = conv else { throw AudioError.converterCreate(st) }
        converter = c
        // The magic cookie IS the AudioSpecificConfig for MPEG-4 AAC.
        try asc.withUnsafeBytes { raw in
            let st = AudioConverterSetProperty(c, kAudioConverterDecompressionMagicCookie,
                                              UInt32(raw.count), raw.baseAddress!)
            guard st == noErr else { throw AudioError.magicCookie(st) }
        }
    }

    /// Decodes one access unit into interleaved Float32. Returns frames produced.
    func decode(_ au: Data, into out: UnsafeMutablePointer<Float>, capacityFrames: Int) throws -> Int
}
```

`decode` uses `AudioConverterFillComplexBuffer` with an input proc that hands over exactly one
packet and then reports `0` packets:

```swift
let inputProc: AudioConverterComplexInputDataProc = { _, ioNumberDataPackets, ioData, outPD, userData in
    let ctx = userData!.assumingMemoryBound(to: FeedContext.self)
    if ctx.pointee.consumed { ioNumberDataPackets.pointee = 0; return noErr }
    ctx.pointee.consumed = true
    ioNumberDataPackets.pointee = 1
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: ctx.pointee.base)
    ioData.pointee.mBuffers.mDataByteSize = UInt32(ctx.pointee.count)
    ioData.pointee.mBuffers.mNumberChannels = ctx.pointee.channels
    ctx.pointee.packetDesc = AudioStreamPacketDescription(
        mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(ctx.pointee.count))
    outPD?.pointee = withUnsafeMutablePointer(to: &ctx.pointee.packetDesc) { $0 }
    return noErr
}
```

Notes: `AudioConverterFillComplexBuffer` returning `noErr` with `ioOutputDataPacketSize == 0` means
"needs more input" — that is normal for the first call after a reset. On
`kAudioConverterErr_*`/`-50` reset with `AudioConverterReset` and drop 1 AU. Multi-AU RTP packets are
decoded in a loop; the RFC 3640 AU-header parsing (`AU-headers-length`, `sizeLength=13`,
`indexLength=3`, `indexDeltaLength=3`) belongs to `VigilRTP`.

We do **not** use `AVAudioConverter`: the compressed-buffer packet-description plumbing for
multi-AU RTP payloads and the inability to set `kAudioConverterPrimeMethod` make it a worse fit,
and `AudioConverterRef` is what `AVAudioConverter` wraps anyway.

Hikvision AAC is almost always 16 kHz mono (`config=1408` → AAC-LC, 16 kHz, mono) or 8 kHz mono
(`config=1588`). ADTS wrapping is never needed for `AudioConverter` — pass raw AUs with the magic
cookie.

### 13.3 G.711 (and G.726)

```swift
enum G711 {
    /// 256-entry decode tables, built once at type-initialisation time.
    static let uLawToLinear: [Int16] = (0..<256).map { decodeMuLaw(UInt8($0)) }
    static let aLawToLinear: [Int16] = (0..<256).map { decodeALaw(UInt8($0)) }

    static func decodeMuLaw(_ u: UInt8) -> Int16 {
        let x = ~u
        let sign = (x & 0x80) != 0
        let exponent = Int((x >> 4) & 0x07)
        let mantissa = Int(x & 0x0F)
        var sample = ((mantissa << 1) + 33) << exponent - 33   // bias 33, 14-bit
        sample <<= 2                                            // scale to 16-bit
        return Int16(clamping: sign ? -sample : sample)
    }

    static func decodeALaw(_ a: UInt8) -> Int16 {
        let x = a ^ 0x55
        let sign = (x & 0x80) != 0
        let exponent = Int((x >> 4) & 0x07)
        let mantissa = Int(x & 0x0F)
        var sample = exponent == 0 ? (mantissa << 1) + 1 : ((mantissa << 1) + 33) << (exponent - 1)
        sample <<= 3
        return Int16(clamping: sign ? -sample : sample)
    }

    /// Hot path: byte → Float in one pass, no branches.
    static func decode(_ bytes: UnsafeRawBufferPointer, law: Law,
                       into out: UnsafeMutablePointer<Float>) {
        let table = law == .aLaw ? aLawToLinear : uLawToLinear
        table.withUnsafeBufferPointer { t in
            for i in 0..<bytes.count { out[i] = Float(t[Int(bytes[i])]) * (1.0 / 32768.0) }
        }
    }
}
```

Payload types: `PCMU` = 0 (μ-law, 8 kHz), `PCMA` = 8 (A-law, 8 kHz). Hikvision two-way audio also
offers G.726 (16/24/32/40 kbit/s ADPCM); implement the 32 kbit/s (4-bit) variant only, per
ITU-T G.726 §4, as `G726Codec` with the standard quantiser tables — it is used by a minority of
older DS-2CD2 models. If a device offers only G.726 at a rate we do not implement, talkback is
disabled with a clear message and *playback* falls back to G.711 (every device offers it).

Cost: 8 kHz G.711 decode is ~0.02 % of one core per stream. Resample 8 kHz → 48 kHz with a 6×
linear-phase FIR (31 taps, designed offline, coefficients in the source) applied via
`vDSP_desamp`/`vDSP_conv`; linear interpolation is audibly harsh on speech and is not acceptable at
this product bar.

### 13.4 Ring buffer and drift

```swift
final class AudioRingBuffer: @unchecked Sendable {   // SPSC: writer = decode task, reader = RT thread
    init(capacityFrames: Int)                        // 48_000 × 0.4 = 19_200 frames (400 ms)
    func write(_ src: UnsafePointer<Float>, frames: Int) -> Int   // returns frames written
    func read(into dst: UnsafeMutablePointer<Float>, frames: Int) -> Int
    var availableFrames: Int { get }                 // relaxed atomic load
}
```

| Parameter | Value |
|---|---|
| Capacity | 400 ms |
| Prime target (frames buffered before the source node starts emitting) | 120 ms |
| Minimum before start | 60 ms |
| Overrun trim | if `available > 300 ms` for 2 s, discard the oldest 40 ms (with a 5 ms cross-fade) |
| Underrun response | fade to silence over 64 frames; count it |
| Adaptive prime | 3 underruns in 5 s → prime target += 20 ms, cap 240 ms; 30 s clean → -10 ms, floor 80 ms |
| Long-term drift | camera clock vs. output clock differ by 10–200 ppm. Correct by dropping/duplicating one 10 ms block whenever the smoothed depth drifts 30 ms from target. No resampler PLL — inaudible for speech, and far simpler. |

### 13.5 Mute, solo and focus (D8)

```swift
public actor AudioRouter {
    public func setFocused(_ id: StreamIdentifier?) async
    public func setUserMuted(_ id: StreamIdentifier, _ muted: Bool) async
    public func setSolo(_ id: StreamIdentifier?) async
    public func setVolume(_ id: StreamIdentifier, _ gain: Float) async  // 0...1, applied as dB
    public func setFollowFocus(_ enabled: Bool) async                   // default true
    public var audible: Set<StreamIdentifier> { get async }
}
```

| Situation | Result |
|---|---|
| `followFocus == true` (default) | exactly the focused camera is audible; every other stream's audio RTP is depacketized but **not decoded** (saves the AAC decode) |
| User explicitly unmutes a non-focused camera | it stays audible when focus moves; at most **4** simultaneously unmuted (the 5th unmute mutes the least-recently-unmuted, with a toast) |
| `solo(x)` | `x` audible, everything else muted, previous mute states remembered and restored on `solo(nil)` |
| Focus change | 100 ms equal-power fade-out on the old, 100 ms fade-in on the new (`AVAudioMixerNode.volume` ramped over 6 ticks; never a hard cut) |
| More than one audible | each mixer gets `-3 dB × (n - 1)` headroom so summing cannot clip |
| System output muted / no output device | engine paused, decoders released |
| Talkback active | see §14 |

An audio stream that is not audible has its `AACDecoder` torn down after 5 s (it costs 0.3 MB and a
little CPU) and rebuilt on unmute; the first ~200 ms after unmute may be silent while the ring
primes. That is the correct trade.

### 13.6 Audio statistics

`AudioStatistics` (per stream): `sampleRate`, `channels`, `codec`, `ringDepthMS` (EWMA α = 0.2),
`underruns`, `overruns`, `decodeErrors`, `peakLevel` and `rmsLevel` over the last 100 ms (computed
with `vDSP_maxmgv` / `vDSP_rmsqv` in the decode task, never on the RT thread) — `VigilUI` draws the
level meter from these.

### 13.7 Recorded-playback audio

Recorded playback uses `AVSampleBufferAudioRenderer` added to the same
`AVSampleBufferRenderSynchronizer` as the video renderer, fed with compressed AAC
`CMSampleBuffer`s (built exactly like video samples, with an audio `CMFormatDescription` from
`CMAudioFormatDescriptionCreate`). This gives real A/V sync, correct behaviour at rate 0.25×–2×, and
automatic muting outside `[0.5, 2.0]`. `AVAudioEngine` is **not** used for recorded playback. This
split is deliberate: live needs a custom low-latency path, recorded needs sync, and each API is
best at one of them.

---

## 14. Two-way audio (talkback)

### 14.1 Capture path

```
AVAudioEngine.inputNode ──tap(bufferSize: 320 frames @ device rate)
   └─▶ AVAudioConverter (device format → 8 kHz mono Float32)
        └─▶ Int16 clamp ─▶ G.711 A-law encode ─▶ 320-byte chunks (40 ms)
             └─▶ ISAPI POST /ISAPI/System/TwoWayAudio/channels/{id}/audioData (chunked)
```

```swift
public actor TalkbackController {
    public enum State: Sendable { case idle, opening, live, closing, failed(TalkbackError) }
    public private(set) var state: State
    public func begin(camera: StreamIdentifier) async throws   // negotiate + open + start capture
    public func end() async
    public var levels: AsyncStream<Float> { get }              // for the PTT meter
}
```

Negotiation (via injected `VigilISAPI` closures — `VigilVideo` never imports it):

1. `GET /ISAPI/System/TwoWayAudio/channels` → list with `audioCompressionType`
   (`G.711ulaw`, `G.711alaw`, `G.726`, `AAC`), `audioInputType`, `speakerVolume`, `noisereduce`.
2. Preference order: **`G.711alaw` → `G.711ulaw` → `G.726` (32 k)**. AAC upload is not implemented
   (it needs an encoder and no Hikvision device requires it).
3. `PUT /ISAPI/System/TwoWayAudio/channels/{id}/open` → `<TwoWayAudioSession>` with the accepted
   codec and sample rate. If the device replies `deviceBusy`, surface "another client is talking".
4. Start the chunked `POST …/audioData` upload; keep it open for the duration.
5. `PUT …/close` on end, on error, and on a 2 s idle timeout.

### 14.2 Encoder

```swift
enum G711Encoder {
    static func encodeALaw(_ pcm: UnsafePointer<Int16>, count: Int, into out: UnsafeMutablePointer<UInt8>)
    static func encodeMuLaw(_ pcm: UnsafePointer<Int16>, count: Int, into out: UnsafeMutablePointer<UInt8>)
}
```
A-law encode: take `|x| >> 3` (13-bit), find the segment via the position of the highest set bit
above bit 4, form `(sign << 7) | (exponent << 4) | mantissa`, XOR with `0x55`. μ-law encode: add the
132 bias, find the exponent, `(sign << 7) | (exp << 4) | mantissa`, then complement. Both are exact
inverses of §13.3 and must be unit-tested round-trip over all 65 536 inputs with the standard
maximum error bound.

Chunking: **320 bytes = 320 samples = 40 ms** at 8 kHz. Hikvision firmware is sensitive to chunk
size; 40 ms is the value that works across DS-2CD2, DS-2DE and DS-7xxx. Send at a steady 25 Hz from
a `Task` with `Task.sleep(until:)` pacing, not as fast as the encoder produces.

### 14.3 Echo cancellation and push-to-talk

* Enable Apple's voice-processing I/O while talkback is active:
  `try engine.inputNode.setVoiceProcessingEnabled(true)` **and**
  `try engine.outputNode.setVoiceProcessingEnabled(true)`. This gives AEC, AGC and noise
  suppression for free. It **must** be toggled while the engine is stopped, so `begin` does:
  stop engine → enable voice processing → rebuild the graph → start engine, and `end` reverses it.
  The whole transition takes 80–200 ms, which is why we do it on `begin`, not per PTT press.
* Additionally attenuate the camera's *downstream* audio to **−18 dB** while transmitting
  (a 30 ms ramp). Belt and braces: AEC plus attenuation makes speaker-to-mic howl practically
  impossible on a MacBook's built-in mic.
* Microphone permission: `Info.plist` `NSMicrophoneUsageDescription`, and
  `AVCaptureDevice.requestAccess(for: .audio)` before `begin`. A denial maps to
  `TalkbackError.microphonePermissionDenied` with a "Open System Settings ▸ Privacy" action.

Push-to-talk semantics:

| Gesture | Behaviour |
|---|---|
| Hold the talk button, or hold **Space** while a tile is focused | `begin` on key-down (the ISAPI open happens once and is then kept warm for 10 s), transmit while held, `end` 250 ms after release (the tail avoids clipping the last syllable) |
| Press-and-release under 200 ms | treated as a **latch**: transmission stays on until the next press (Discord-style); the UI shows a pulsing red "ON AIR" chip. Escape always ends it. |
| Focus moves to another camera while transmitting | transmission ends (never accidentally talk to the wrong camera) |
| First 150 ms after `begin` | 150 ms of captured audio is buffered and sent once the session opens, so the beginning of the first word is not lost |
| Window loses focus / app hides | transmission ends immediately |
| Device or permission error | `end`, show a non-modal error, restore the previous audio graph |

---

## 15. Snapshot capture

### 15.1 Sources

| Mode | Source | Contents |
|---|---|---|
| `.decoded` | the last decoded `CVPixelBuffer` (Strategy B), or a one-shot decode session on the next keyframe (Strategy A) | full frame, no zoom, no overlays |
| `.displayed` | `VigilRender` renders the current tile into an offscreen `MTLTexture` and returns a `CVPixelBuffer` | exactly what the user sees: zoom, pan, colour grading, deinterlace |
| `.jpeg` | ISAPI `/picture` (owned by `VigilCore`) | cheapest, camera-side, no decode |

### 15.2 `CVPixelBuffer` → `CGImage`

Primary (fast, hardware-assisted, handles all our YCbCr formats and clean aperture):

```swift
func makeCGImage(_ pb: CVPixelBuffer) throws -> CGImage {
    var out: Unmanaged<CGImage>?
    let st = VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &out)
    guard st == noErr, let image = out?.takeRetainedValue() else {
        return try makeCGImageWithCoreImage(pb)      // fallback
    }
    return image
}
```

`VTCreateCGImageFromCVPixelBuffer(_ pixelBuffer: CVPixelBuffer, options: CFDictionary?, imageOut: UnsafeMutablePointer<Unmanaged<CGImage>?>) -> OSStatus`
— note `Unmanaged`: use `takeRetainedValue()` exactly once. Leaking here is a common bug because the
function returns a +1 reference.

Fallback / colour-managed path (used for 10-bit HEVC, for BT.2020, and whenever the primary returns
`kVTPixelTransferNotSupportedErr`):

```swift
let ciContext = CIContext(options: [
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
    .outputColorSpace:  CGColorSpace(name: CGColorSpace.displayP3)!,
    .cacheIntermediates: false,
    .useSoftwareRenderer: false,
])
let ci = CIImage(cvPixelBuffer: pb, options: [.applyOrientationProperty: false])
    .cropped(to: cleanApertureRect(pb))
guard let cg = ciContext.createCGImage(ci, from: ci.extent,
                                       format: pb.is10Bit ? .RGBA16 : .RGBA8,
                                       colorSpace: outputColorSpace) else { throw … }
```

One shared `CIContext` per app (creating one costs ~30 ms and a chunk of VRAM); it lives in
`SnapshotEncoder` behind a lazy `static let`. Clean aperture must be applied here — otherwise a
1920×1088 snapshot appears with 8 rows of garbage at the bottom, which is a visible bug.

```swift
func cleanApertureRect(_ pb: CVPixelBuffer) -> CGRect {
    if let d = CVBufferGetAttachment(pb, kCVImageBufferCleanApertureKey, nil) as? [CFString: Any],
       let w = d[kCVImageBufferCleanApertureWidthKey] as? CGFloat,
       let h = d[kCVImageBufferCleanApertureHeightKey] as? CGFloat,
       let x = d[kCVImageBufferCleanApertureHorizontalOffsetKey] as? CGFloat,
       let y = d[kCVImageBufferCleanApertureVerticalOffsetKey] as? CGFloat {
        let full = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        return CGRect(x: (full.width - w) / 2 + x, y: (full.height - h) / 2 + y, width: w, height: h)
    }
    return CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
}
```

### 15.3 Encoding to a file

```swift
public struct SnapshotOptions: Sendable {
    public var format: SnapshotFormat = .png           // .png, .jpeg(quality: 0.9), .heic(quality: 0.85)
    public var burnInOverlay: Bool = false             // camera name + timestamp, drawn by VigilRender
    public var metadata: SnapshotMetadata
}
public struct SnapshotMetadata: Sendable {
    public var cameraName: String
    public var host: String            // never credentials
    public var captureDate: Date
    public var channel: Int
    public var appVersion: String
}

func write(_ image: CGImage, to url: URL, options: SnapshotOptions) throws {
    let type: UTType = switch options.format {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
    }
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
    else { throw SnapshotError.destinationUnavailable(url) }

    let fmt = DateFormatter.exif      // "yyyy:MM:dd HH:mm:ss", en_US_POSIX, device time zone
    var props: [CFString: Any] = [
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFMake: "Hikvision",
            kCGImagePropertyTIFFModel: options.metadata.cameraName,
            kCGImagePropertyTIFFSoftware: "Vigil \(options.metadata.appVersion)",
            kCGImagePropertyTIFFDateTime: fmt.string(from: options.metadata.captureDate),
            kCGImagePropertyTIFFImageDescription: "\(options.metadata.cameraName) ch\(options.metadata.channel)",
        ] as CFDictionary,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: fmt.string(from: options.metadata.captureDate),
            kCGImagePropertyExifSubsecTimeOriginal: String(
                format: "%03d", Int(options.metadata.captureDate.timeIntervalSince1970
                                    .truncatingRemainder(dividingBy: 1) * 1000)),
            kCGImagePropertyExifUserComment: "Captured by Vigil from \(options.metadata.host)",
        ] as CFDictionary,
        kCGImagePropertyIPTCDictionary: [
            kCGImagePropertyIPTCObjectName: options.metadata.cameraName,
            kCGImagePropertyIPTCDateCreated: ISO8601DateFormatter().string(from: options.metadata.captureDate),
        ] as CFDictionary,
    ]
    if case .jpeg(let q) = options.format { props[kCGImageDestinationLossyCompressionQuality] = q }
    if case .heic(let q) = options.format { props[kCGImageDestinationLossyCompressionQuality] = q }
    if options.format == .png { props[kCGImagePropertyPNGDictionary] = [
        kCGImagePropertyPNGSoftware: "Vigil" ] as CFDictionary }

    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw SnapshotError.encodeFailed(url) }
}
```

| Format | Use | 1080p size | Encode time (M1) |
|---|---|---|---|
| PNG | default; lossless; 16-bit for 10-bit sources | 1.8–3.5 MB | 28 ms |
| JPEG q0.9 | sharing, evidence bundles | 280–450 KB | 7 ms |
| HEIC q0.85 | archives; keeps 10-bit and wide gamut | 150–260 KB | 22 ms |

Never encode on the pipeline actor or the MainActor — `SnapshotEncoder` runs the whole
raster+encode on a detached `Task(priority: .userInitiated)`. Target: shutter feedback within one
frame, file on disk within 120 ms. `VigilCore` owns destinations (folder, clipboard via
`NSPasteboard`, Quick Look) and the file-name template.

---

## 16. Hardware verification, energy and thermals

### 16.1 Proving hardware decode is engaged

1. **Authoritative, programmatic:**

```swift
func isUsingHardwareDecode(_ s: VTDecompressionSession) -> Bool {
    var value: CFTypeRef?
    let st = VTSessionCopyProperty(
        s, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
        allocator: kCFAllocatorDefault, valueOut: &value)
    guard st == noErr, let b = value as? Bool else { return false }
    return b
}
```
Read once, ~200 ms after the first successful decode (the property is not meaningful before the
decoder has committed), and store it in `DecodeStatistics.hardwareAccelerated`. Surface it in the
diagnostics panel as "Hardware decode: yes/no" per stream — users and support need this.

2. **Capability probe at launch** (`HardwareProbe`): create two throwaway sessions from canned
   parameter sets (a 64×64 H.264 SPS/PPS and a 64×64 HEVC VPS/SPS/PPS embedded as literals) with
   `RequireHardwareAcceleratedVideoDecoder = true`. Success/failure fills
   `MachineClass.hasHardwareHEVC` / `hasHardware10bit` and takes < 15 ms total. Also decides whether
   HEVC cameras should be asked (via ISAPI) to switch to H.264.

3. **Signpost timing** (`OSSignposter`, category `decode`): interval `decodeFrame`, per frame.
   1080p H.264 hardware p50 is **2–4 ms**; software is **12–25 ms**. A p50 above 8 ms means
   software decode regardless of what the property says.

4. **Instruments**: the *Metal System Trace* + *os_signpost* template shows our intervals against
   GPU work; the *Energy Log* shows the media-engine contribution as low CPU with non-zero GPU.

5. **`powermetrics`** (documented in the benchmark harness README):
   `sudo powermetrics -i 1000 -n 30 --samplers cpu_power,gpu_power`. Acceptance: 16×1080p30 H.264
   on an M1 must stay under **3.5 W** combined CPU+GPU package power delta over idle. Software
   decode blows straight past 12 W.

6. **`log stream --predicate 'subsystem == "com.apple.coremedia"' --level debug`** shows decoder
   selection (`AppleAVD` for the hardware path on Apple silicon). Useful only for triage.

### 16.2 Expected numbers (acceptance targets)

Measured on M1 (8-core, 16 GB), macOS 14, 120 Hz display, Strategy A unless noted. Percentages are
of **total machine CPU** (all cores).

| Scenario | CPU | GPU | Memory (RSS) | Media engine |
|---|---|---|---|---|
| 1 × 1080p30 H.264, layer | 1.5–2.5 % | 3–5 % | 120 MB | ~4 % |
| 1 × 1080p30 H.264, VT+Metal, zoom active | 2.5–4 % | 7–10 % | 165 MB | ~4 % |
| 4 × 1080p30 H.264 sub, layer | 3–5 % | 8–12 % | 250 MB | ~15 % |
| **16 × 1080p30 H.264 sub, layer** | **9–14 %** | **25–33 %** | **640 MB** | ~60 % |
| 16 × 1080p30 H.264 sub, VT+Metal atlas | 14–19 % | 30–38 % | 980 MB | ~60 % |
| 16 × 704×576@25 H.264 sub, layer | 4–6 % | 10–14 % | 340 MB | ~14 % |
| 4 × 1080p30 HEVC main, layer | 5–8 % | 12–16 % | 320 MB | ~28 % |
| 1 × 4 K30 HEVC Main10 main, VT+Metal | 6–9 % | 18–24 % | 380 MB | ~30 % |
| 64-up mixed (16 decode + 48 JPEG poll) | 11–16 % | 26–34 % | 780 MB | ~60 % |

Product bar: **16 × 1080p under 35 % CPU** — the layer path meets it with a 2.5× margin. Regression
gate in CI: any scenario exceeding its table value by > 15 % fails the benchmark job.

Per-frame cost references (M1, hardware): H.264 1080p decode 2.8 ms, HEVC 1080p 4.1 ms,
HEVC 4 K Main10 9.5 ms, sample-buffer construction 45 µs, `CVPixelBuffer` → `MTLTexture` 30 µs,
one Metal tile draw 90 µs.

### 16.3 Thermal and power adaptation

`ThermalGovernor` (an actor, observes `ProcessInfo.thermalStateDidChangeNotification`,
`NSProcessInfoPowerStateDidChange`, and `NSWorkspace` sleep/wake):

| Condition | Budget multiplier | Other actions |
|---|---|---|
| `.nominal`, on AC | 1.00 | `MaximizePowerEfficiency = false` on the focused tile |
| `.nominal`, on battery | 0.85 | `MaximizePowerEfficiency = true` everywhere; cap non-focused tiles at 15 fps |
| Low Power Mode | 0.60 | as above **plus** 30 Hz display pacing cap, JPEG intervals × 2 |
| `.fair` | 0.85 | non-focused tiles → `fpsCapped` |
| `.serious` | 0.60 | non-focused → `keyframesOnly`; disable colour-grading shader passes; JPEG intervals × 1.5 |
| `.critical` | 0.35 | only the focused tile decodes; everything else → `jpegPoll` at 5 s; emit a user-visible warning chip; log `.fault` |
| System will sleep | — | invalidate all sessions, release grants, stop the engine |
| System did wake | — | expect `kVTInvalidSessionErr` on the first submit; recreate everything, request IDRs, one JPEG bridge per visible tile |

Every transition is announced through `DecodeBudget.changes` so pipelines act at once, and logged at
`.notice` (thermal events are the top cause of "it got worse after 20 minutes" reports).

---

## 17. Benchmark harness

`BenchmarkHarness` lives in `VigilVideo` (shipped, not test-only, so it can run on a user's machine
for support) and is driven by a hidden launch argument:

```
Vigil.app/Contents/MacOS/Vigil --benchmark <plan.json> [--out results.csv] [--duration 60]
```

### 17.1 Inputs

Elementary-stream fixtures in `Tests/Fixtures/Streams/`, each a 4-byte-length-prefixed NAL file plus
a `.json` sidecar with the parameter sets, timing and expected format:

| Fixture | Contents |
|---|---|
| `h264-1080p30-main-gop50.bin` | 300 frames, synthetic moving pattern, encoded once with VideoToolbox and committed (1.9 MB) |
| `h264-704x576-25-gop50.bin` | typical substream (410 KB) |
| `h265-1080p30-main.bin` | (1.4 MB) |
| `h265-4k30-main10.bin` | 90 frames (4.8 MB) |
| `h264-1080p30-bframes.bin` | High profile, 2 reorder frames — exercises §11.2 |
| `h264-midstream-resolution-change.bin` | 1080p → 720p → 1080p, three SPS — exercises §9 |
| `h264-corrupt-au.bin` | deliberately damaged NALs — exercises `kVTVideoDecoderBadDataErr` |
| `h264-starts-mid-gop.bin` | begins on a P-frame — exercises `awaitingKeyframe` |
| `aac-16k-mono.bin`, `g711a-8k.bin` | audio |

A `Scripts/make-fixtures.swift` regenerates them with `VTCompressionSession` (run manually, output
committed, because CI must not depend on encoder version differences).

### 17.2 Plan and metrics

```json
{ "name": "wall-16x1080p",
  "streams": [{ "fixture": "h264-1080p30-main-gop50.bin", "count": 16, "strategy": "layer",
                "tileWidth": 1280, "realtime": true }],
  "durationSeconds": 60, "warmupSeconds": 5 }
```

Emitted per stream and aggregate:

| Metric | Definition |
|---|---|
| `decodeMS` p50/p95/p99/max | signpost `decodeFrame` interval |
| `pipelineMS` p50/p95/p99 | submit → `sink.present` (our 55 ms budget) |
| `framesSubmitted / presented / dropped{queueFull,awaitingKeyframe,badData,decoder,formatChange}` | counters |
| `hardwareAccelerated` | §16.1 |
| `cpuPercent`, `gpuPercent` | sampled at 1 Hz via `host_statistics64` / `IOReport`-free approximation: `ProcessInfo` + `task_info(TASK_ABSOLUTETIME_INFO)` for our own CPU; GPU from `MTLDevice.currentAllocatedSize` deltas plus `powermetrics` when run with `--privileged` |
| `rssBytes`, `peakRSS` | `task_vm_info` |
| `sessionCreates`, `sessionRecreates`, `vtErrors[code]` | counters |
| `thermalTransitions` | governor log |

Output: one CSV row per (scenario, stream) plus a JSON summary. `Scripts/bench-gate.swift` compares
against `Tests/Fixtures/baselines/<machine-class>.json` and fails on p95 regressions > 10 % or any
increase in `framesDropped`. The harness feeds frames from the fixture at real time using
`Task.sleep(until:)` against a host-clock schedule (never `Thread.sleep`), so measured latency is
comparable to a live camera.

The same harness runs the **synthetic RTSP server + RTP generator** fixture from
`ARCHITECTURE.md` when `--via-rtsp` is passed, which exercises the whole stack end to end on one
machine with no camera present.

---

## 18. Public API reference

### 18.1 `DecodePipeline`

```swift
public actor DecodePipeline {

    public init(streamID: StreamIdentifier,
                configuration: DecodePipelineConfiguration,
                sink: any VideoSink,
                budget: DecodeBudget = .shared,
                requestKeyframe: @escaping @Sendable () async -> Void,
                jpegProvider: (@Sendable (CGSize) async throws -> Data)? = nil,
                logger: any LoggerProtocol)

    // Lifecycle -------------------------------------------------------------------------------
    public func start() async throws
    public func stop() async
    public var events: AsyncStream<PipelineEvent> { get }

    // Feeding ---------------------------------------------------------------------------------
    /// Never throws, never suspends on I/O, never blocks the caller. Applies the §10.3 drop policy.
    public func submit(_ frame: EncodedFrame)
    public func submitAudio(_ frame: EncodedAudioFrame)

    // Control ---------------------------------------------------------------------------------
    public func setStrategy(_ strategy: DisplayStrategy) async throws
    public func setMode(_ mode: DecodeMode, stream: StreamChoice) async
    public func setTileContext(_ context: TileContext) async     // recomputes policy + cost
    public func setPaused(_ paused: Bool, reason: PauseReason) async
    public func flushAndRequestKeyframe() async
    public func setAudioEnabled(_ enabled: Bool) async

    // Query -----------------------------------------------------------------------------------
    public func statistics() -> DecodeStatistics
    public func currentFormat() -> VideoFormat?
    public func snapshot(_ mode: SnapshotSource) async throws -> DecodedVideoFrame
}

public struct DecodePipelineConfiguration: Sendable {
    public var isLive: Bool = true
    public var queueCapacity: Int = 6
    public var targetQueueDepth: Int = 2
    public var requireHardwareDecode: Bool = false
    public var allowDownscaleOnDecode: Bool = true
    public var initialStrategy: DisplayStrategy = .sampleBufferLayer
    public var audioEnabled: Bool = false
    public var maximumKeyframeRequestsPerMinute: Int = 10
    public static let live = DecodePipelineConfiguration()
    public static let thumbnail = DecodePipelineConfiguration(queueCapacity: 2, targetQueueDepth: 1)
}

public enum PipelineEvent: Sendable {
    case started
    case firstFrame(latencyMS: Double)
    case formatChanged(VideoFormat)
    case formatChangeStalled
    case hardwareDecodeDetermined(Bool)
    case latencyLevelChanged(LatencyLevel, measuredLatencyMS: Double)
    case persistentlyBehind(measuredLatencyMS: Double)
    case modeChanged(DecodeMode, reason: ModeChangeReason)
    case stalled(sinceMS: Double)
    case recovered
    case awaitingParameterSets
    case noParameterSets
    case keyframeRequested
    case keyframeTimeout
    case unsupportedFormat(codec: VideoCodec, detail: String)
    case degraded(VideoPipelineError)
    case failed(VideoPipelineError)
    case stopped
}
```

### 18.2 `PlaybackPipeline`

```swift
public actor PlaybackPipeline {
    public init(streamID: StreamIdentifier, transport: any PlaybackTransportControl,
                sink: any VideoSink, budget: DecodeBudget = .shared, logger: any LoggerProtocol)

    public func submit(_ frame: EncodedFrame)
    public func submitAudio(_ frame: EncodedAudioFrame)

    public func play() async throws
    public func pause() async
    public func setRate(_ rate: PlaybackRate, direction: PlaybackDirection) async throws
    public func seek(to date: Date, precise: Bool) async throws
    public func stepForward() async throws
    public func stepBackward() async throws
    public func setLoop(_ range: ClosedRange<Date>?) async

    public var currentTime: Date { get async }
    public var state: PlaybackState { get async }
    public var events: AsyncStream<PlaybackEvent> { get }
    public var sampleTap: AsyncStream<Unsafe<CMSampleBuffer>> { get }
}

public enum PlaybackState: Sendable, Equatable {
    case idle, buffering, playing(rate: Double), paused, seeking(progress: Double), ended, failed
}
```

### 18.3 Statistics

```swift
public struct DecodeStatistics: Sendable, Codable {
    public var hardwareAccelerated: Bool?
    public var codec: VideoCodec?
    public var format: VideoFormat?
    public var mode: DecodeMode
    public var strategy: DisplayStrategy
    public var costDU: Double

    public var framesSubmitted: UInt64
    public var framesPresented: UInt64
    public var framesDroppedQueueFull: UInt64
    public var framesDroppedAwaitingKeyframe: UInt64
    public var framesDroppedBadData: UInt64
    public var framesDroppedByDecoder: UInt64
    public var framesDroppedFormatChange: UInt64
    public var framesDroppedNoFormat: UInt64
    public var framesDroppedPolicy: UInt64        // fps ceiling / keyframes-only

    public var decodeMSp50: Double
    public var decodeMSp95: Double
    public var pipelineMSp50: Double              // submit → present
    public var pipelineMSp95: Double
    public var endToEndMSEWMA: Double             // capture → present
    public var queueDepthEWMA: Double
    public var framesInFlight: Int
    public var poolStarvation: UInt64

    public var sessionCreates: UInt32
    public var sessionRecreates: UInt32
    public var lastVTError: OSStatus?
    public var acceptedProperties: [String]
    public var latencyLevel: LatencyLevel
    public var audio: AudioStatistics?
}
```

Percentiles come from a fixed 256-slot reservoir per metric (no allocation, `p95` computed by
partial selection on demand). `HealthMonitor` in `VigilCore` samples `statistics()` at 1 Hz; the
call must cost < 20 µs, so it returns a copied struct and never recomputes anything eagerly.

### 18.4 Error type

```swift
public enum VideoPipelineError: Error, Sendable, CustomStringConvertible {
    // Format
    case missingParameterSets
    case emptyParameterSet(index: Int)
    case tooManyParameterSets(count: Int)
    case formatDescriptionFailed(status: OSStatus, codec: VideoCodec)
    case malformedAccessUnit(reason: String)
    case codecNotDecodedByThisPath(VideoCodec)
    // Buffers
    case blockBufferFailed(status: OSStatus)
    case sampleBufferFailed(status: OSStatus)
    case attachmentsUnavailable
    case pixelBufferPoolFailed(CVReturn)
    // Decoder
    case decoderCreationFailed(status: OSStatus, requireHardware: Bool)
    case decodeSubmitFailed(status: OSStatus)
    case decoderMalfunction(status: OSStatus, recreateAttempt: Int)
    case unsupportedFormat(codec: VideoCodec, detail: String)
    case hardwareDecodeUnavailable
    // Display
    case timebaseFailed
    case layerFailed(underlying: Error?)
    case metalUnavailable
    // Budget
    case admissionDenied(reason: DenialReason)
    // Playback
    case seekFailed(underlying: Error)
    case rateNotSupported(Double)
    case reverseNotAvailable(reason: String)
    // Audio
    case audio(AudioError)
    case talkback(TalkbackError)

    public var isRecoverable: Bool { … }        // drives §7.9 class A/C vs. B/E
    public var userFacingMessage: String { … }  // localised, actionable, never a raw OSStatus
    public var diagnosticDetail: String { … }   // includes the OSStatus and the four-char code
}
```

Every `OSStatus` is rendered in the diagnostic detail as both decimal and FourCC
(`"-12909 (kVTVideoDecoderBadDataErr)"`) using a static table in `Diagnostics/VTErrorNames.swift` —
users paste these into support tickets, so the mapping ships in the app.

Errors never propagate as thrown errors out of `submit`; they surface as `PipelineEvent.degraded`
or `.failed`. Only `start()`, `setStrategy`, `snapshot()` and the playback control methods throw.
`VigilCore.StreamController` maps `.failed` to its `failed` state and owns reconnect.

---

## 19. Observability

| Signal | Detail |
|---|---|
| OSLog subsystem | `com.vigil.app` |
| Categories | `video.pipeline`, `video.format`, `video.budget`, `video.playback`, `audio.playback`, `audio.talkback`, `video.snapshot`, `video.bench` |
| Signposter intervals | `decodeFrame`, `presentFrame`, `sessionCreate`, `formatChange`, `seek`, `snapshot`, `jpegPoll` |
| Signpost events | `keyframeRequested`, `dropToKeyframe`, `budgetDemote`, `budgetPromote`, `thermalTransition`, `underrun` |
| Log levels | `.debug` per-frame (compiled out of release via `if VigilLog.isFrameLoggingEnabled`), `.info` for lifecycle and admission, `.notice` for thermal/mode changes, `.error` for recoverable failures, `.fault` for class-E bugs |
| Privacy | no credentials, no host names in `.debug` frame logs; `%{private}` on host and camera name in release |
| Rate limiting | any repeated log inside a frame loop goes through `RateLimitedLog(every: 2.0)` |

The pipeline never imports `OSLog` directly in code shared with the pure layer; it uses
`LoggerProtocol` from `VigilProtocols` and the macOS implementation wraps `Logger`.

---

## 20. File layout

```
Sources/VigilVideo/
  Format/
    FormatDescriptionFactory.swift      §4.1–4.4
    ParameterSetStore.swift             §4.5
    FormatFingerprint.swift
    FormatOverrides.swift
    VideoFormat.swift                   §2.2
  Sample/
    SampleBufferBuilder.swift           §5.1–5.3
    BlockBufferPool.swift
    SampleAttachments.swift
    TimestampConversion.swift           §3
  Decode/
    DecodePipeline.swift                §18.1
    DecodeSessionProtocol.swift         §8
    LayerDecodeSession.swift            §6
    SampleBufferRendering.swift         §6.2
    VTDecodeSession.swift               §7
    VTConfig.swift
    PixelBufferPool.swift               §7.5
    FrameQueue.swift                    §10.3
    LatencyController.swift             §10.4
    FormatChangeCoordinator.swift       §9
  Playback/
    PlaybackPipeline.swift              §11, §18.2
    ReorderHeap.swift                   §11.2
    RateController.swift                §11.3
    SeekController.swift                §11.4
    ReverseGOPDecoder.swift             §11.5
  Budget/
    DecodeBudget.swift                  §12.4
    DecodeCost.swift                    §12.2
    MachineClass.swift                  §12.3
    TilePolicy.swift                    §12.5
    JPEGPoller.swift                    §12.5
    MJPEGDecoder.swift                  §12.6
    OcclusionMonitor.swift              §12.7
    ThermalGovernor.swift               §16.3
  Audio/
    AudioPlaybackEngine.swift           §13.1
    AudioStreamPlayer.swift
    AACDecoder.swift                    §13.2
    G711.swift                          §13.3
    G726.swift
    Resampler.swift
    AudioRingBuffer.swift               §13.4
    AudioRouter.swift                   §13.5
    TalkbackController.swift            §14
    G711Encoder.swift                   §14.2
  Snapshot/
    SnapshotEncoder.swift               §15
    PixelBufferImaging.swift
  Diagnostics/
    DecodeStatistics.swift              §18.3
    VideoSignposts.swift
    VTErrorNames.swift
    HardwareProbe.swift                 §16.1
    BenchmarkHarness.swift              §17
  Support/
    Boxes.swift                         §2.3
    VideoSink.swift                     §2.4
    VideoPipelineError.swift            §18.4
Tests/VigilVideoTests/                  (macOS-only; see §21)
```

Every file carries the repo-standard header, `internal` by default, `public` only for the API in
§18, no force-unwraps outside tests (the `!` on `kCFBooleanTrue` and on canned literal parameter
sets is the documented exception, wrapped in helpers `cfTrue` / `cfFalse`), 110-column lines,
`// MARK:` sections.

---

## 21. Test matrix

macOS-only (these need VideoToolbox, so they run on the Mac CI job, not the Linux job):

| # | Test | Assertion |
|---|---|---|
| 1 | `FormatDescriptionFactory` with 6 real Hikvision SPS/PPS pairs (shared fixtures with `spec-bitstream.md`) | dimensions, clean aperture, PAR match the expected table |
| 2 | Same, but sets in the wrong order (PPS first) | throws, does not crash |
| 3 | Parameter set with 3 trailing `0x00` | trimmed, creation succeeds |
| 4 | `withParameterSetPointers` with 4 non-contiguous `Data` slices | pointers distinct, sizes correct, no dangling access under Address Sanitizer |
| 5 | Sample buffer attachments | keyframe has no `NotSync`; P-frame has `NotSync` + `DependsOnOthers`; live sample has `DisplayImmediately`; recorded sample does not |
| 6 | `h264-1080p30-main-gop50.bin` through Strategy B | 300 frames in, 300 presented, 0 dropped, monotonic PTS, `hardwareAccelerated == true` on Apple silicon |
| 7 | `h264-starts-mid-gop.bin` | frames before the first IDR are dropped and counted; first presented frame is the IDR |
| 8 | `h264-corrupt-au.bin` | `kVTVideoDecoderBadDataErr` handled, session **not** recreated, exactly one keyframe request after 4 errors |
| 9 | `h264-midstream-resolution-change.bin` | 2 format changes, `sessionRecreates == 2`, `framesDroppedFormatChange ≤ 4`, `willChangeFormat`/`didChangeFormat` called in pairs, `generation` increments |
| 10 | Injected `kVTInvalidSessionErr` (a test hook that invalidates the session mid-stream) | recreated once, `awaitingKeyframe` set, recovery within 1 GOP |
| 11 | Injected `kVTCouldNotCreateInstanceErr` on the 17th session | budget lowers, tile demotes, no black tile |
| 12 | `FrameQueue` drop policy | all four ordered rules, including the all-keyframes case |
| 13 | `LatencyController` fed synthetic depth traces | exact level transitions at the §10.4 thresholds, hysteresis honoured, no oscillation on a noisy trace |
| 14 | `TilePolicy.mode(for:)` over the §12.5 table | every row, including the 16-up-at-1280 = `full` case |
| 15 | `DecodeCost` arithmetic | matches the §12.2 worked examples to 0.01 DU |
| 16 | `DecodeBudget` admission and preemption | priority ordering, no preemption below `keyframesOnly`, promotion rate limit, transient reservation |
| 17 | `h264-1080p30-bframes.bin` through `PlaybackPipeline` | presented in PTS order, `ReorderHeap` emits ascending, no duplicate PTS |
| 18 | Seek to a mid-GOP timestamp | first displayed frame PTS == requested, pre-roll frames carry `DoNotDisplay` |
| 19 | Reverse playback over 3 GOPs | strictly descending PTS, memory under the 320 MB cap |
| 20 | `G711` decode tables | match the ITU-T G.711 reference vectors for all 256 codes, both laws |
| 21 | `G711Encoder` round-trip | all 65 536 Int16 inputs within the standard error bound |
| 22 | `AACDecoder` with `aac-16k-mono.bin` | exact frame count, RMS within 0.5 dB of the reference |
| 23 | `AudioRingBuffer` SPSC under `ThreadSanitizer` | 10 M frames, no races, no lost frames, underrun/overrun counts exact |
| 24 | `AudioRouter` | focus-follow, 4-stream cap, solo restore, fade timing |
| 25 | Snapshot from a 1920×1088 buffer with clean aperture | output is exactly 1920×1080, no garbage rows |
| 26 | Snapshot of a 10-bit HEVC frame to HEIC | 10-bit preserved (`CGImage.bitsPerComponent == 16`), EXIF present |
| 27 | `SnapshotEncoder` metadata | TIFF/EXIF/IPTC keys present, no credential substring anywhere in the file bytes |
| 28 | Occlusion ladder with a fake clock | each escalation fires at its threshold; resume issues 1 IDR request and 1 JPEG bridge |
| 29 | `ThermalGovernor` with injected thermal states | multipliers applied, modes changed, restored on return to nominal |
| 30 | Strategy switch A→B→A under load | no black frame (the sink records a continuous stream of presented frames with gaps ≤ 2 frames) |
| 31 | 16-stream soak, 30 minutes | no leaked `CVPixelBuffer` (`CVPixelBufferPool` allocation count stable), RSS flat within 5 %, `sessionRecreates == 0` |
| 32 | Swift 6 strict-concurrency build with `-warnings-as-errors` | zero data-race warnings; no `@unchecked Sendable` outside `Support/Boxes.swift` and the three documented types |

Linux job: this module does not build on Linux and is excluded from `swift build --target` on the
Linux CI matrix. All its *inputs* (`EncodedFrame`, parameter sets, `MediaTimestamp`, cost
arithmetic) are tested there through `VigilRTP`/`VigilBitstream`. `DecodeCost` and `TilePolicy` are
pure arithmetic and are additionally compiled into a small Foundation-only file
(`Budget/DecodeCost.swift`, `Budget/TilePolicy.swift`, both free of CoreMedia imports) so those two
test groups (#14, #15) also run on Linux via the `VigilProtocols` test target — a deliberate
exception to the "macOS-only target" rule, achieved by keeping those two files import-free.

