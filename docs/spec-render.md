# Vigil — Rendering & On-Video Interaction Specification (`VigilRender`)

**Status:** normative. **Module:** `VigilRender` (macOS-only target).
**Platform:** macOS 14.0+, Swift 6 strict concurrency, SwiftUI + AppKit interop, zero external dependencies.
**Frameworks used:** `Metal`, `MetalKit` (types only, no `MTKView`), `QuartzCore`, `CoreVideo`, `CoreMedia`,
`AVFoundation` (`AVSampleBufferDisplayLayer` only), `CoreGraphics`, `CoreImage` (snapshot path only),
`AppKit`, `SwiftUI`, `Observation`, `OSLog`, `UniformTypeIdentifiers`, `simd`, `Accelerate` (test fixtures).

This document is written so that an implementer can produce `Sources/VigilRender/` without further research.
Every number, matrix, shader line and API name below is a decision, not a suggestion.

---

## 0. Table of contents

| § | Section |
|---|---|
| 1 | Position in the architecture, ownership and threading |
| 2 | Coordinate systems and the geometry pipeline (normative core) |
| 3 | Frame ingest contract, latest-frame handoff, pacing |
| 4 | `RenderContext`: shared device, queue, texture cache, shader library, pipeline cache |
| 5 | `VideoTileView`: AppKit mechanics, layer setup, resize, scale, tracking |
| 6 | The Metal render path: passes, pipeline state, uniforms, **full shader source** |
| 7 | Colour management: YCbCr matrices, ranges, chroma siting, 10-bit, HDR/EDR |
| 8 | Post effects: order of operations, sharpen, deinterlace, night boost, resampling |
| 9 | Overlays: SwiftUI vs Metal, motion boxes, privacy mask, PTZ, 3D-position rectangle |
| 10 | Interactions: complete event table, zoom/pan/inertia math, gestures, DnD, keys, cursors |
| 11 | Video-wall compositing: per-tile layers vs single-layer atlas, K, 120 Hz budget |
| 12 | Multiple displays, backing scale, EDR headroom, display-link pacing |
| 13 | `AVSampleBufferDisplayLayer` path and the Metal-failure fallback |
| 14 | Full public Swift API |
| 15 | Performance budgets and instrumentation |
| 16 | Error taxonomy and recovery |
| 17 | Visual-correctness test checklist and fixtures |
| 18 | File layout and style compliance |
| 19 | Cross-module contracts other modules must respect |

---

## 1. Position in the architecture, ownership and threading

### 1.1 Dependency edges

```
VigilProtocols ──► VigilBitstream ──► VigilVideo ──► VigilRender ──► VigilUI ──► Vigil
       │                                  ▲              ▲
       └──────────────────────────────────┘              │
                                   VigilCore ────────────┘  (VigilCore depends on VigilRender
                                                             only for snapshot + geometry types)
```

* `VigilRender` **depends on**: `VigilProtocols` (pure value types, `MediaTimestamp`, `LoggerProtocol`,
  `FrameGeometry`, `ColorInfo`), `VigilVideo` (`VideoFrame`, `VideoSink`).
* `VigilRender` **must not import** `VigilCore`, `VigilUI`, `VigilISAPI`, `VigilRTSP`, `VigilRTP`.
  Everything it needs from the app domain arrives through `TileInteractionDelegate` (out) and
  plain value types (in). This is a hard rule: it keeps the renderer testable with a fake frame
  source and keeps the PTZ / ISAPI encoding decisions out of the view layer.
* `VigilUI` owns every SwiftUI overlay and reads geometry from `TileRenderState` (§9.4).

### 1.2 What lives here and what does not

| In `VigilRender` | Not in `VigilRender` |
|---|---|
| `CVPixelBuffer` → `MTLTexture` conversion | `VTDecompressionSession` (that is `VigilVideo`) |
| YCbCr→RGB, adjustments, deinterlace, sharpen | `CMSampleBuffer` construction (`VigilVideo`) |
| Digital zoom/pan state and math | Optical PTZ commands (`VigilISAPI` via delegate) |
| Fit/crop/SAR geometry, overlay coordinate maps | Motion event acquisition (`VigilCore`) |
| Tile drag payload types and drag sessions | Layout model, cell↔camera map (`VigilCore`) |
| Exact-displayed-frame snapshot (pixels) | File encoding + EXIF of snapshots (`VigilCore`) |
| Visibility/pixel-size reporting | Decode admission policy (`VigilCore`) |

### 1.3 Concurrency model

* **Every type in `VigilRender` is `@MainActor`** except: `TileUniforms`, `TileTransform`,
  `ImageAdjustments`, `TileGeometry`, `RenderStats`, `RenderCapabilities` (`Sendable` value types),
  and `LatestFrameBox` (a lock-protected class, `@unchecked Sendable`).
* Rationale: `CAMetalLayer.nextDrawable()`, `presentsWithTransaction` presentation, `NSView`
  geometry, `CVMetalTextureCache` and `CADisplayLink` created by `NSView.displayLink(target:selector:)`
  all want the main thread. Our measured GPU encode cost is ≤ 40 µs per tile (§15), so a 16-tile
  wall costs ≤ 0.65 ms per rendered frame on the main thread — 7.8% of a 120 Hz frame budget.
  A dedicated render thread would buy nothing and would cost us a lock around the texture cache
  plus a main-thread hop for `present()` anyway.
* The **only** nonisolated entry point is `VideoTileView.enqueue(_:)` (§3.2), which is called from
  the `VigilVideo` decode actor / VideoToolbox callback thread and does nothing but swap a
  retained `VideoFrame` into a lock-protected box.
* `MTLDevice`, `MTLCommandQueue`, `MTLLibrary`, `MTLRenderPipelineState` are wrapped in
  `RenderContext`, which is `@MainActor` and holds them as `let`. Where these Objective-C types must
  cross an isolation boundary they are carried inside an explicitly documented
  `struct UncheckedSendable<T>: @unchecked Sendable` shim — never with a blanket
  `@preconcurrency import`.

---

## 2. Coordinate systems and the geometry pipeline (normative core)

Get this section right and everything else (overlays, hit testing, snapshots, motion boxes) follows.
Five spaces, in order:

| # | Space | Units | Origin | Defined by |
|---|---|---|---|---|
| S | **Coded pixel** | pixels of the decoded `CVPixelBuffer` | top-left | `CVPixelBufferGetWidth/Height` |
| P | **Picture pixel** | pixels after crop | top-left | `FrameGeometry.cropRect` (from SPS `frame_crop_*` / `clean aperture`) |
| D | **Display pixel** | square pixels | top-left | P scaled horizontally by SAR |
| C | **Content normalized** | `[0,1]²` | top-left | D normalized; **this is the space overlays use** |
| V | **View** | AppKit points (`y` up) / SwiftUI points (`y` down) | see note | `NSView.bounds` × `contentsScale` → backing pixels |

> **Note on V:** `NSView` in Vigil is created with `isFlipped == true`. Every `VideoTileView` returns
> `true` from `isFlipped` so that AppKit point coordinates match SwiftUI's top-left origin exactly.
> This removes an entire class of Y-flip bugs in overlays and drag hit-testing. All public API in
> `VigilRender` that returns view coordinates returns **top-left-origin points**.

### 2.1 Crop and SAR

```swift
public struct TileGeometry: Sendable, Equatable {
    public var codedSize: CGSize            // S, integer pixels
    public var cropRect: CGRect             // P inside S, integer pixels, origin top-left
    public var pixelAspectRatio: Double     // SAR = pixelWidth / pixelHeight, 1.0 = square
    public var displaySize: CGSize {        // D
        CGSize(width: (cropRect.width * pixelAspectRatio).rounded(),
               height: cropRect.height)
    }
    public var displayAspect: Double { displaySize.width / displaySize.height }
}
```

SAR sources, in priority order (all produced by `VigilBitstream`, carried in `FrameGeometry`):

1. H.264 VUI `aspect_ratio_info_present_flag` → `aspect_ratio_idc` table, or `sar_width`/`sar_height`
   when `aspect_ratio_idc == 255` (Extended_SAR).
2. H.265 VUI `aspect_ratio_idc` (identical table).
3. Absent → **SAR = 1.0**. Hikvision IP channels always emit square pixels; only analog/DVR channels
   on an NVR (`704×576`, `704×480`, `352×288`) need SAR.

Reference SAR values that must be handled (from the H.264 Table E-1):

| `aspect_ratio_idc` | SAR | Typical Hikvision case | Coded | Display |
|---|---|---|---|---|
| 1 | 1:1 | all IP channels | 1920×1080 | 1920×1080 |
| 2 | 12:11 | analog PAL 4CIF | 704×576 | 768×576 |
| 3 | 10:11 | analog NTSC 4CIF | 704×480 | 640×480 |
| 4 | 16:11 | PAL 4CIF widescreen | 704×576 | 1024×576 |
| 5 | 40:33 | NTSC 4CIF widescreen | 704×480 | 854×480 |
| 255 | `sar_width:sar_height` | rare, honour verbatim | — | — |

**The 1088-vs-1080 rule.** H.264 encoders must code in whole 16-row macroblocks, so 1080 becomes
1088 with `frame_crop_bottom_offset = 4` (units of 2 luma rows for 4:2:0 progressive ⇒ 8 rows).
HEVC uses 32-row CTBs and typically codes 1080 as 1088 too (`conf_win_bottom_offset = 4`).
`cropRect` **must** be applied in the texture transform; the padded rows contain encoder garbage and
show as a green or smeared strip if sampled. Same rule for `1280×720` (already aligned, no crop) and
`2560×1440` (aligned) and `3840×2160` (aligned), and for `1920×1080` HEVC (crop 8 rows).

### 2.2 The fit rectangle

```swift
public enum VideoGravity: String, Sendable, Codable { case fit, fill, stretch }

/// Returns the unzoomed content rect in view points (top-left origin).
func fitRect(bounds: CGRect, displayAspect: Double, gravity: VideoGravity) -> CGRect {
    guard bounds.width > 0, bounds.height > 0, displayAspect > 0 else { return .zero }
    let viewAspect = Double(bounds.width / bounds.height)
    switch gravity {
    case .stretch:
        return bounds
    case .fit:
        if displayAspect > viewAspect {                    // letterbox: bars top+bottom
            let h = bounds.width / displayAspect
            return CGRect(x: bounds.minX, y: bounds.midY - h / 2, width: bounds.width, height: h)
        } else {                                           // pillarbox: bars left+right
            let w = bounds.height * displayAspect
            return CGRect(x: bounds.midX - w / 2, y: bounds.minY, width: w, height: bounds.height)
        }
    case .fill:
        if displayAspect > viewAspect {
            let w = bounds.height * displayAspect
            return CGRect(x: bounds.midX - w / 2, y: bounds.minY, width: w, height: bounds.height)
        } else {
            let h = bounds.width / displayAspect
            return CGRect(x: bounds.minX, y: bounds.midY - h / 2, width: bounds.width, height: h)
        }
    }
}
```

Expected values (used verbatim as unit-test expectations):

| Display size | Tile bounds | Gravity | fitRect |
|---|---|---|---|
| 1920×1080 | 800×600 | fit | `(0, 75, 800, 450)` |
| 1920×1080 | 800×600 | fill | `(-133.33, 0, 1066.67, 600)` |
| 768×576 | 800×600 | fit | `(0, 0, 800, 600)` |
| 640×480 | 800×600 | fit | `(0, 0, 800, 600)` |
| 1920×1080 | 400×400 | fit | `(0, 87.5, 400, 225)` |
| 1024×576 | 400×400 | fit | `(0, 87.5, 400, 225)` |

### 2.3 Zoom and pan as a single NDC matrix

The renderer draws **one quad**. Fit, zoom and pan are folded into a single `float4x4` `model`
matrix that maps the unit quad to Metal NDC (`x` right, `y` **up**, both in `[-1, 1]`).

```
model = T(t.x, t.y) · S(zoom, zoom) · S(fx, fy)
```
where `(fx, fy)` are the fit factors (`fitRect.size / bounds.size` — the *quad* half-extents in NDC
are exactly these), `zoom ∈ [1, 8]`, and `t` is the pan translation in NDC.

```swift
public struct TileTransform: Sendable, Equatable {
    public var zoom: CGFloat = 1            // 1…maxZoom (8)
    public var translation: CGPoint = .zero // NDC, y-up; (0,0) = centred
    public var flipVertical = false         // for bottom-up buffers (never true for VideoToolbox)
    public static let identity = TileTransform()
}
```

**Why the quad scales instead of the texture coordinates shrinking.** Scaling the quad and letting
the rasterizer clip means (a) zoomed content covers the letterbox bars, using the whole tile —
which is what users want on a 4:3 analog channel in a 16:9 cell; (b) pixels always stay square, no
distortion; (c) no `clampToEdge` smearing at the crop boundary; (d) clipped fragments are never
shaded, so zooming is free. The alternative (shrinking the texcoord window) keeps the bars and
wastes tile area. Decision: **scale the quad.**

**Anchored zoom (the load-bearing formula).** Given the current `(zoom z, translation t)`, a new
zoom `z'` and an anchor point `a` in NDC (the cursor), the anchor's content point stays fixed iff

```
t' = a + (z' / z) · (t − a)
```

Derivation: a base-quad point `p` maps to `z·p + t`. For the anchor, `p = (a − t)/z`. Requiring
`z'·p + t' = a` gives `t' = a − z'·(a − t)/z = a + (z'/z)·(t − a)`. □

**Pan clamp.** Let `h = (z·fx, z·fy)` be the drawn quad's half-extents. Per axis:

```
if h.axis <= 1 + ε  → t.axis = 0                       (content narrower than the tile: centre it)
else                → t.axis ∈ [1 − h.axis, h.axis − 1]  (never let a gap appear at an edge)
```
with `ε = 1e-4`. Clamping runs after every zoom, pan, inertia tick, bounds change and gravity change.

**Reset rule.** `zoom == 1` forces `t == .zero`. Changing `gravity` or `displayAspect` re-clamps but
preserves `zoom`.

### 2.4 The texture transform

`texTransform` is a `float3x3` mapping the base quad's `[0,1]²` top-left-origin coordinate to a
normalized coordinate in the **coded** texture. It encodes crop and (optionally) vertical flip:

```swift
func textureTransform(_ g: TileGeometry, flipVertical: Bool) -> simd_float3x3 {
    let sx = Float(g.cropRect.width  / g.codedSize.width)
    let sy = Float(g.cropRect.height / g.codedSize.height)
    let ox = Float(g.cropRect.minX   / g.codedSize.width)
    let oy = Float(g.cropRect.minY   / g.codedSize.height)
    if flipVertical {
        // u' = ox + sx·u ; v' = oy + sy·(1 − v)
        return simd_float3x3(columns: (simd_float3(sx, 0, 0),
                                      simd_float3(0, -sy, 0),
                                      simd_float3(ox, oy + sy, 1)))
    }
    return simd_float3x3(columns: (simd_float3(sx, 0, 0),
                                  simd_float3(0, sy, 0),
                                  simd_float3(ox, oy, 1)))
}
```
SAR does **not** appear here — it is already in `displayAspect` → `fitRect` → `(fx, fy)`. Putting SAR
in the texture transform as well is the classic double-correction bug; it is forbidden.

### 2.5 Forward and inverse mapping (the public contract)

```swift
public struct TileCoordinateMap: Sendable {
    public let bounds: CGRect          // view points, top-left origin, unscaled
    public let geometry: TileGeometry
    public let gravity: VideoGravity
    public let transform: TileTransform

    /// Content-normalized (C, top-left) → view points (top-left origin).
    public func viewPoint(content u: CGPoint) -> CGPoint
    /// View points → content-normalized. Values outside 0…1 mean "outside the picture".
    public func contentPoint(view p: CGPoint) -> CGPoint
    /// Content rect → view rect (axis-aligned; the transform has no rotation, so this is exact).
    public func viewRect(content r: CGRect) -> CGRect
    /// The visible sub-rectangle of the picture, in C. Equals (0,0,1,1) at zoom 1 with .fit.
    public var visibleContentRect: CGRect { get }
    /// Picture pixel under a view point, for the pixel-probe HUD and 3D-position PTZ.
    public func picturePixel(view p: CGPoint) -> CGPoint?
}
```

Implementation, written out because overlays depend on it being bit-identical to the shader:

```swift
public func viewPoint(content u: CGPoint) -> CGPoint {
    let f = fitRect(bounds: bounds, displayAspect: geometry.displayAspect, gravity: gravity)
    let fx = f.width / bounds.width, fy = f.height / bounds.height   // quad half-extents in NDC
    let base = CGPoint(x: 2 * u.x - 1, y: 1 - 2 * u.y)               // NDC, y-up, unzoomed
    let ndc  = CGPoint(x: base.x * fx * transform.zoom + transform.translation.x,
                       y: base.y * fy * transform.zoom + transform.translation.y)
    return CGPoint(x: (ndc.x * 0.5 + 0.5) * bounds.width,
                   y: (0.5 - ndc.y * 0.5) * bounds.height)           // top-left origin
}

public func contentPoint(view p: CGPoint) -> CGPoint {
    let f = fitRect(bounds: bounds, displayAspect: geometry.displayAspect, gravity: gravity)
    let fx = f.width / bounds.width, fy = f.height / bounds.height
    let ndc = CGPoint(x: (p.x / bounds.width) * 2 - 1, y: 1 - (p.y / bounds.height) * 2)
    let base = CGPoint(x: (ndc.x - transform.translation.x) / (fx * transform.zoom),
                       y: (ndc.y - transform.translation.y) / (fy * transform.zoom))
    return CGPoint(x: (base.x + 1) * 0.5, y: (1 - base.y) * 0.5)
}
```

Worked expectation (unit test): 1920×1080 picture, 800×600 tile, `.fit`, zoom 1 ⇒
`viewRect(content: (0.25, 0.25, 0.5, 0.5)) == (200, 187.5, 400, 225)`.

---

## 3. Frame ingest contract, latest-frame handoff, pacing

### 3.1 The types that cross the boundary

Declared in `VigilProtocols` (pure, Linux-buildable — **no CoreMedia/CoreVideo**):

```swift
public struct FrameGeometry: Sendable, Equatable, Codable {
    public var codedWidth: Int, codedHeight: Int
    public var cropLeft: Int, cropTop: Int, cropWidth: Int, cropHeight: Int
    public var sarWidth: Int, sarHeight: Int        // 1,1 when unknown
    public var bitDepth: Int                        // 8 or 10
    public var fieldOrder: FieldOrder
    public var color: ColorInfo
}
public enum FieldOrder: UInt8, Sendable, Codable { case progressive, topFieldFirst, bottomFieldFirst }
public struct ColorInfo: Sendable, Equatable, Codable {
    public enum Matrix:       UInt8, Sendable, Codable { case bt601, bt709, bt2020ncl, unspecified }
    public enum Range:        UInt8, Sendable, Codable { case video, full }
    public enum Transfer:     UInt8, Sendable, Codable { case bt709, smpte170m, srgb, pq, hlg, unspecified }
    public enum Primaries:    UInt8, Sendable, Codable { case bt709, bt2020, smpte170m, unspecified }
    public enum ChromaSiting: UInt8, Sendable, Codable { case left, center, topLeft }
    public var matrix: Matrix, range: Range, transfer: Transfer
    public var primaries: Primaries, chromaSiting: ChromaSiting
}
```

Declared in `VigilVideo` (macOS-only):

```swift
public struct VideoFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer      // 420YpCbCr8BiPlanarVideoRange or 420YpCbCr10BiPlanarVideoRange
    public let geometry: FrameGeometry
    public let presentation: MediaTimestamp    // stream clock (VigilProtocols)
    public let decodeHostTime: UInt64          // mach_absolute_time() at decode completion
    public let captureHostTime: UInt64?        // RTCP-derived sender time, for glass-to-glass stats
    public let sequence: UInt64                // monotonic per stream, for drop accounting
    public let isKeyframe: Bool
}
public protocol VideoSink: AnyObject, Sendable {
    nonisolated func enqueue(_ frame: VideoFrame)
    nonisolated func streamDidReset()          // decoder recreated / format change: drop stale state
    nonisolated func streamDidEnd(reason: StreamEndReason)
}
```

`VigilRender` **requires** these exact member names. The pixel buffer must be created with
`kCVPixelBufferMetalCompatibilityKey: true` and `kCVPixelBufferIOSurfacePropertiesKey: [:]`; if
`CVPixelBufferGetIOSurface(_:) == nil` the renderer logs `renderer.nonIOSurfaceBuffer` once per
stream and falls back to a CPU upload path (§16.4) that costs ~1.4 ms per 1080p frame — treat any
occurrence as a bug in `VigilVideo`.

### 3.2 Latest-frame box

Live surveillance wants *newest frame wins*, not a queue. The handoff is a single-slot mailbox plus
an optional 2-deep queue used only by recorded playback.

```swift
final class LatestFrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var slot: VideoFrame?
    private var pending: [VideoFrame] = []      // playback mode only, capacity 3
    private(set) var droppedByReplacement: UInt64 = 0
    var mode: PacingMode = .live                // written on main, read under lock

    func put(_ frame: VideoFrame) {
        lock.lock()
        switch mode {
        case .live:
            if slot != nil { droppedByReplacement &+= 1 }
            slot = frame
        case .paced:
            if pending.count == 3 { pending.removeFirst(); droppedByReplacement &+= 1 }
            pending.append(frame)
        }
        lock.unlock()
    }

    /// Live: the newest frame. Paced: the newest frame whose PTS ≤ deadline, older ones dropped.
    func take(hostDeadline: UInt64) -> VideoFrame? { … }
    func flush() { lock.lock(); slot = nil; pending.removeAll(); lock.unlock() }
}
```

* `put` is `O(1)`, allocation-free, holds the lock for < 200 ns. It is legal to call it from the
  VideoToolbox output callback thread.
* `NSLock` (not `os_unfair_lock`) because we must never spin on a thread that may be donating
  priority to the GPU; contention is effectively zero. `Mutex` from Synchronization is macOS 15+, so
  it is not available at our 14.0 floor.
* `droppedByReplacement` feeds `RenderStats.droppedFrames` and the Stream tab sparkline.

### 3.3 Pacing with `CADisplayLink`

macOS 14 gives us `NSView.displayLink(target:selector:)`, which returns a `CADisplayLink` already
bound to the display the view is on and **automatically retargeted when the view moves to another
screen**. We use it and never touch `CVDisplayLink` (deprecated in macOS 15) or a timer.

```swift
private func startDisplayLink() {
    let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
    link.preferredFrameRateRange = frameRateRange(for: .idle)
    link.add(to: .main, forMode: .common)          // .common so it survives menu tracking & resize
    self.link = link
}

private func frameRateRange(for state: PacingState) -> CAFrameRateRange {
    switch state {
    case .idle:        // no interaction: follow content, let the OS coalesce
        let fps = Float(max(1, min(60, Int(streamFrameRate.rounded()))))
        return CAFrameRateRange(minimum: max(1, fps * 0.5), maximum: 120, preferred: fps)
    case .interacting: // zoom / pan / inertia / overlay animation in flight
        return CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
    case .liveResize:
        return CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
    }
}

@objc private func displayLinkFired(_ link: CADisplayLink) {
    let deadline = hostTime(fromMediaTime: link.targetTimestamp)
    let newFrame = box.take(hostDeadline: deadline)
    guard newFrame != nil || needsRedraw else { return }   // ← the power/perf keystone
    render(frame: newFrame, targetTimestamp: link.targetTimestamp)
}
```

**The keystone rule:** if there is no new frame and no dirty overlay/geometry state, the display-link
callback returns without encoding or presenting anything. Core Animation keeps showing the last
surface at zero cost. This is how 16 tiles coexist with a 120 Hz ProMotion display (§11.4).

`needsRedraw` is set by: a new `TileTransform`, `ImageAdjustments`, bounds/scale change, gravity
change, backend switch, privacy-mask change, inertia tick, and the first frame after `flush()`.

Interlaced streams are the one case where one decoded buffer produces **two** presents: see §8.3.

---

## 4. `RenderContext`: shared device, queue, texture cache, shader library, pipeline cache

### 4.1 One device, one queue, app-wide

```swift
@MainActor
public final class RenderContext {
    public static let shared: RenderContext? = RenderContext()

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue        // label "com.vigil.render.q", one for the app
    public let library: MTLLibrary
    public let capabilities: RenderCapabilities
    let textureCache: CVMetalTextureCache
    let linearSampler: MTLSamplerState
    let nearestSampler: MTLSamplerState
    private var pipelines: [PipelineKey: MTLRenderPipelineState] = [:]
    private var binaryArchive: MTLBinaryArchive?
    private var uniformRing: UniformRing            // 3 × 64 KiB, 256-byte-aligned slices

    init?() { … }   // returns nil if any step fails → the whole app takes the ASBDL path (§13)
}
```

* **One `MTLDevice`**: `MTLCreateSystemDefaultDevice()`. We do not enumerate `MTLCopyAllDevices()`;
  on Apple silicon there is one GPU, and on Intel Macs the system default is the one driving the
  display in the common case. On `MTLCommandBufferError.deviceRemoved` (eGPU unplug) we rebuild the
  whole context (§16.3).
* **One `MTLCommandQueue`** for the entire app. Sixteen tiles submitting to one queue serialize
  their GPU work in submission order, which is exactly what we want for a coherent wall; separate
  queues would add scheduling overhead and no parallelism (a single tile pass is ~60 µs of GPU).
* **One `CVMetalTextureCache`** created with a max texture age of two frame intervals:

```swift
let attrs: [String: Any] = [kCVMetalTextureCacheMaximumTextureAgeKey as String: 0.017]
var cache: CVMetalTextureCache?
guard CVMetalTextureCacheCreate(kCFAllocatorDefault, attrs as CFDictionary,
                                device, nil, &cache) == kCVReturnSuccess,
      let cache else { return nil }
```
  Because all texture creation happens on the main actor, one cache is safe. `CVMetalTextureCache`
  is not documented as thread-safe and we do not treat it as such.

* **Samplers** (created once):

```swift
let d = MTLSamplerDescriptor()
d.minFilter = .linear; d.magFilter = .linear; d.mipFilter = .notMipmapped
d.sAddressMode = .clampToEdge; d.tAddressMode = .clampToEdge
d.normalizedCoordinates = true; d.label = "vigil.linear"
linearSampler = device.makeSamplerState(descriptor: d)!   // guarded, no force-unwrap in real code
```

### 4.2 Zero-copy `CVPixelBuffer` → `MTLTexture`

```swift
struct PlaneTextures { let luma: CVMetalTexture; let chroma: CVMetalTexture }

func planeTextures(for pb: CVPixelBuffer, bitDepth: Int) throws -> PlaneTextures {
    let lumaFormat:   MTLPixelFormat = bitDepth > 8 ? .r16Unorm  : .r8Unorm
    let chromaFormat: MTLPixelFormat = bitDepth > 8 ? .rg16Unorm : .rg8Unorm
    var y: CVMetalTexture?, c: CVMetalTexture?
    let w0 = CVPixelBufferGetWidthOfPlane(pb, 0), h0 = CVPixelBufferGetHeightOfPlane(pb, 0)
    let w1 = CVPixelBufferGetWidthOfPlane(pb, 1), h1 = CVPixelBufferGetHeightOfPlane(pb, 1)
    guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pb, nil,
              lumaFormat, w0, h0, 0, &y) == kCVReturnSuccess,
          CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pb, nil,
              chromaFormat, w1, h1, 1, &c) == kCVReturnSuccess,
          let y, let c else { throw RenderError.textureCreationFailed }
    return PlaneTextures(luma: y, chroma: c)
}
```

Rules that are easy to get wrong and are therefore normative:

1. Use `CVPixelBufferGetWidthOfPlane` / `…HeightOfPlane`, **never** the buffer width for plane 1.
2. Retain the `CVMetalTexture` (not just the `MTLTexture` from `CVMetalTextureGetTexture`) until the
   GPU is finished. We capture it in `commandBuffer.addCompletedHandler { _ = textures }`.
3. Never call `CVPixelBufferLockBaseAddress` on a frame that is being rendered — it forces a
   surface copy and defeats zero-copy.
4. Call `CVMetalTextureCacheFlush(textureCache, 0)` once every 120 presents and on
   `NSApplication.didChangeScreenParametersNotification`, memory pressure
   (`DispatchSource.makeMemoryPressureSource`), and window occlusion. Flushing every frame measurably
   costs ~30 µs of `IOSurface` churn for no benefit.
5. `MTLPixelFormat.r16Unorm` for 10-bit: see §7.4 for the sample scaling that this implies.

### 4.3 Pipeline cache

```swift
struct PipelineKey: Hashable, Sendable {
    var tenBit: Bool
    var deinterlace: DeinterlaceMode       // .none / .bob / .blend
    var sharpen: Bool
    var nightBoost: Bool
    var bicubic: Bool
    var roundedMask: Bool
    var transfer: ColorInfo.Transfer       // drives the EOTF branch
    var outputFormat: MTLPixelFormat       // .bgra8Unorm | .rgba16Float
}
```

Variants are produced with **function constants**, not `#define` recompiles, so one `MTLLibrary`
serves all of them and specialization is ~0.4 ms per new variant:

```swift
func pipeline(for key: PipelineKey) throws -> MTLRenderPipelineState {
    if let hit = pipelines[key] { return hit }
    let cv = MTLFunctionConstantValues()
    var tenBit = key.tenBit;                    cv.setConstantValue(&tenBit, type: .bool, index: 0)
    var dmode  = UInt32(key.deinterlace.rawValue); cv.setConstantValue(&dmode, type: .uint, index: 1)
    var sharp  = key.sharpen;                   cv.setConstantValue(&sharp,  type: .bool, index: 2)
    var night  = key.nightBoost;                cv.setConstantValue(&night,  type: .bool, index: 3)
    var bicu   = key.bicubic;                   cv.setConstantValue(&bicu,   type: .bool, index: 4)
    var round  = key.roundedMask;               cv.setConstantValue(&round,  type: .bool, index: 5)
    var tf     = UInt32(key.transfer.shaderCode); cv.setConstantValue(&tf,   type: .uint, index: 6)

    let vfn = try library.makeFunction(name: "vigilTileVertex", constantValues: cv)
    let ffn = try library.makeFunction(name: "vigilTileFragment", constantValues: cv)
    let d = MTLRenderPipelineDescriptor()
    d.label = "vigil.tile.\(key.shortDescription)"
    d.vertexFunction = vfn
    d.fragmentFunction = ffn
    d.colorAttachments[0].pixelFormat = key.outputFormat
    d.colorAttachments[0].isBlendingEnabled = false      // we always write opaque pixels
    d.rasterSampleCount = 1                              // MSAA is pointless for a screen-aligned quad
    d.inputPrimitiveTopology = .triangle
    if let archive = binaryArchive { d.binaryArchives = [archive] }
    let state = try device.makeRenderPipelineState(descriptor: d)
    pipelines[key] = state
    return state
}
```

### 4.4 Where the shader source comes from (no build-system dependency)

SwiftPM does not compile `.metal` files into a `metallib` for a plain target, and we are forbidden
from hand-writing a `.pbxproj`. Decision — a two-tier load with the same source text in both tiers:

1. **If `Bundle.module` contains `default.metallib`** (the XcodeGen/Xcode build path, where the
   `.metal` file is a real compile source) → `device.makeDefaultLibrary(bundle: .module)`.
2. **Otherwise** (the `swift build` path) → compile at runtime from
   `VigilShaderSource.tileShaders`, a `static let` Swift string literal that is the byte-identical
   content of `Shaders/VigilTileShaders.metal`:

```swift
let opts = MTLCompileOptions()
opts.languageVersion = .version3_0
opts.fastMathEnabled = true                  // deprecated macOS 15; see §18.3 for the availability shim
opts.libraryType = .executable
library = try device.makeLibrary(source: VigilShaderSource.tileShaders, options: opts)
```
   Runtime compilation costs 18–40 ms once at launch on an M-series Mac. To remove it from the
   second launch we serialize an `MTLBinaryArchive` of the four hot pipeline variants to
   `~/Library/Application Support/Vigil/Shaders/pipelines-<deviceName>-<osBuild>.metallibarchive`
   and pass it via `descriptor.binaryArchives`; a mismatched OS build or device name invalidates it.

A unit test (`ShaderSourceParityTests`) asserts that `VigilShaderSource.tileShaders` equals the
contents of the `.metal` file in the repo, so the two tiers can never drift.

### 4.5 Capabilities

```swift
public struct RenderCapabilities: Sendable, Equatable {
    public let hasMetal: Bool
    public let supportsImageAdjustments: Bool     // false on the ASBDL fallback
    public let supportsDigitalZoomAboveOne: Bool  // true everywhere (CA transform on fallback)
    public let supportsHighQualityZoom: Bool      // bicubic; false on fallback
    public let supportsDeinterlace: Bool          // false on fallback
    public let supportsPrivacyBlur: Bool          // false on fallback (opaque rects only)
    public let supportsAtlasWall: Bool            // false on fallback
    public let supportsEDR: Bool                  // any attached screen with headroom > 1.0
    public let maxTextureDimension: Int           // 16384 on all Apple silicon; gates atlas size
    public let deviceName: String
    public let isLowPower: Bool                   // MTLDevice.isLowPower
}
```
`VigilUI` must disable, not hide, controls whose capability is `false`, with the tooltip string
`render.capability.unavailable` (§19).

---

## 5. `VideoTileView`: AppKit mechanics, layer setup, resize, scale, tracking

### 5.1 Class shape

```swift
@MainActor
public final class VideoTileView: NSView, VideoSink {
    public private(set) var backend: TileBackend
    public var options: TileRenderOptions { didSet { applyOptions(oldValue) } }
    public weak var interactionDelegate: (any TileInteractionDelegate)?
    public let state: TileRenderState          // @Observable, read by SwiftUI overlays

    override public var isFlipped: Bool { true }
    override public var wantsUpdateLayer: Bool { true }        // never use draw(_:)
    override public var isOpaque: Bool { true }
    override public var acceptsFirstResponder: Bool { true }
    override public var mouseDownCanMoveWindow: Bool { false }
    override public var canDrawConcurrently: Bool { false }
}
```

### 5.2 Backing layer

```swift
override public func makeBackingLayer() -> CALayer {
    switch backendPreference {
    case .metal:
        let l = CAMetalLayer()
        l.device = RenderContext.shared?.device
        l.pixelFormat = .bgra8Unorm
        l.framebufferOnly = true            // snapshots use an offscreen pass, never a drawable read
        l.isOpaque = true
        l.maximumDrawableCount = 3          // triple buffering; 2 in the .lowLatency preset
        l.displaySyncEnabled = true         // vsync on; false only in the latency-measurement mode
        l.presentsWithTransaction = false   // flipped to true only during live resize (§5.4)
        l.allowsNextDrawableTimeout = true  // nil drawable → skip the frame, never block a second
        l.needsDisplayOnBoundsChange = false
        l.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
        l.backgroundColor = NSColor.black.cgColor
        return l
    case .sampleBufferLayer:
        let l = AVSampleBufferDisplayLayer()
        l.videoGravity = options.gravity.avGravity
        l.isOpaque = true
        l.backgroundColor = NSColor.black.cgColor
        l.preventsDisplaySleepDuringVideoPlayback = true
        return l
    }
}

override public func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateScaleAndDrawableSize()
    needsRedraw = true
}
```

Configuration applied in `init`, before the layer exists:

```swift
wantsLayer = true
layerContentsRedrawPolicy = .duringViewResize   // see §5.4
layerContentsPlacement = .scaleAxesIndependently
clipsToBounds = true                            // macOS 14 API; keeps the zoomed quad inside the cell
```

### 5.3 `contentsScale` and `drawableSize`

```swift
private func updateScaleAndDrawableSize() {
    guard let layer, let window else { return }
    let scale = window.backingScaleFactor            // 1.0, 2.0, or 3.0 on future hardware
    if layer.contentsScale != scale { layer.contentsScale = scale }
    let px = CGSize(width:  (bounds.width  * scale).rounded(.toNearestOrAwayFromZero),
                    height: (bounds.height * scale).rounded(.toNearestOrAwayFromZero))
    guard px.width >= 1, px.height >= 1 else { isRenderable = false; return }
    isRenderable = true
    if let metal = layer as? CAMetalLayer, metal.drawableSize != px {
        withoutCAActions { metal.drawableSize = px }
    }
    state.pixelSize = px
    interactionDelegate?.tile(self, didChangePixelSize: px, isVisible: isEffectivelyVisible)
}
```

* `drawableSize` is set in **integer** pixels; a fractional size silently rounds inside CA and
  produces a half-pixel blur on 1× displays.
* A zero-size tile (collapsed sidebar, layout animation start) must **not** create a drawable.
  `isRenderable == false` short-circuits the display link.
* `state.pixelSize` is the number `VigilCore`'s decode-budget policy consumes (§19).

### 5.4 Killing the AppKit resize flicker

The classic symptoms and the exact cause of each:

| Symptom | Cause | Fix (all mandatory) |
|---|---|---|
| White/grey flash at the trailing edge | AppKit stretches stale layer contents, or the window background shows through | `layer.isOpaque = true` + `backgroundColor = black` + the enclosing tile container layer is also opaque black |
| Content lags the frame by one step | drawable resized but not re-rendered in the same transaction | render **synchronously** inside `setFrameSize` while `inLiveResize` |
| Tearing / a 1-frame stale surface | `present()` not ordered with the CA layout transaction | `presentsWithTransaction = true` during live resize, then `waitUntilScheduled()` + `drawable.present()` |
| Layer geometry animates | implicit CA actions on `bounds`/`position`/`drawableSize` | every geometry write wrapped in a disabled-actions transaction |
| Overlay text reflows jerkily | SwiftUI overlay animating its own layout during resize | overlays use `.animation(nil)` while `inLiveResize` (`VigilUI` contract) |

```swift
@inline(__always) func withoutCAActions(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    CATransaction.setAnimationDuration(0)
    body()
    CATransaction.commit()
}

override public func setFrameSize(_ newSize: NSSize) {
    withoutCAActions { super.setFrameSize(newSize) }
    updateScaleAndDrawableSize()
    clampTransform()
    if inLiveResize { renderSynchronously(reason: .liveResize) } else { needsRedraw = true }
}

override public func viewWillStartLiveResize() {
    super.viewWillStartLiveResize()
    isLiveResizing = true
    metalLayer?.presentsWithTransaction = true
    metalLayer?.maximumDrawableCount = 2         // lower latency, less stale-surface risk
    link?.preferredFrameRateRange = frameRateRange(for: .liveResize)
    qualityOverride = .fastDuringResize           // bicubic + sharpen off, box downsample kept
}

override public func viewDidEndLiveResize() {
    super.viewDidEndLiveResize()
    isLiveResizing = false
    metalLayer?.presentsWithTransaction = false
    metalLayer?.maximumDrawableCount = 3
    link?.preferredFrameRateRange = frameRateRange(for: .idle)
    qualityOverride = nil
    renderSynchronously(reason: .resizeEnd)
}
```

The `presentsWithTransaction` presentation sequence is **not** `commandBuffer.present(drawable)`:

```swift
// presentsWithTransaction == true  (live resize, and the atlas path when overlays are CA-composited)
commandBuffer.commit()
commandBuffer.waitUntilScheduled()      // ≤ ~1.2 ms; only paid while resizing
drawable.present()                      // main thread, inside the current CATransaction

// presentsWithTransaction == false (the normal case, lowest latency)
commandBuffer.present(drawable)         // or presentDrawable(_:afterMinimumDuration:) for playback
commandBuffer.commit()
```

`renderSynchronously` also guards re-entrancy with a flag, because `setFrameSize` can be called from
inside a CA layout pass.

### 5.5 Rounded corners without losing opacity

The design system gives video tiles a 10 pt continuous-corner radius. Setting
`layer.cornerRadius` + `masksToBounds` on a `CAMetalLayer` forces the layer non-opaque and adds a
compositor blend of the whole tile. Decision:

* **Metal backend:** corners are drawn **in the fragment shader** as a signed-distance rounded box,
  blended against `options.cornerColor` (the design system's canvas token, updated on
  `NSApplication.effectiveAppearance` change). The layer stays `isOpaque = true`, there is no
  compositor blend, and the corner colour is exact. Radius is passed in **drawable pixels**
  (`radiusPt * contentsScale`) as a `float4` (TL, TR, BR, BL) so a tile in a mosaic can round only
  its outer corners.
* **ASBDL fallback:** `layer.cornerRadius = r; layer.cornerCurve = .continuous;
  layer.masksToBounds = true` and accept the blend.

`VigilUI` must **not** apply `.clipShape` / `.cornerRadius` / `.shadow` / `.opacity(<1)` to the
`VideoTile` representable — every one of those forces an offscreen render pass over the full video
area. Shadows go on a sibling background view. This is a §19 contract.

### 5.6 Tracking areas, cursors, first responder

```swift
override public func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    let opts: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved,
                                        .activeInKeyWindow, .inVisibleRect, .cursorUpdate]
    addTrackingArea(NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil))
}

override public func resetCursorRects() {
    discardCursorRects()
    addCursorRect(bounds, cursor: currentCursor)
}
```

`currentCursor` table (§10.9) is recomputed on zoom change, mode change and drag state change,
followed by `window?.invalidateCursorRects(for: self)`.

### 5.7 Visibility and occlusion reporting

```swift
var isEffectivelyVisible: Bool {
    guard let window, !isHiddenOrHasHiddenAncestor else { return false }
    guard window.occlusionState.contains(.visible) else { return false }
    guard !window.isMiniaturized else { return false }
    return !visibleRect.isEmpty
}
```
Observed notifications: `NSWindow.didChangeOcclusionStateNotification`,
`NSWindow.didMiniaturizeNotification`, `NSWindow.didDeminiaturizeNotification`,
`NSApplication.didChangeScreenParametersNotification`, `NSWorkspace.willSleepNotification`,
`NSWorkspace.didWakeNotification`, `NSWorkspace.screensDidSleepNotification`.
On invisible → `link?.isPaused = true`, `box.flush()` is **not** called (we keep the last frame for
the resume crossfade), and the delegate is told so `VigilCore` can pause decode.

---

## 6. The Metal render path

### 6.1 Passes

| Pass | When | Target | Cost @1080p |
|---|---|---|---|
| **P0 Downsample** | `sourcePixels / drawablePixels ≥ 2.0` in either axis | private `bgra8Unorm` half/quarter texture | 0.10 ms per halving |
| **P1 Tile** | always | drawable (single tile) or persistent atlas (wall) | 0.06 ms |
| **P2 Privacy mask** | mask regions non-empty | same target, scissored draws | 0.02 ms per region |
| **P3 Metal overlays** | motion boxes > 32, or atlas mode | same target, instanced | 0.03 ms |
| **P4 Blit** | atlas mode only | atlas → drawable, dirty rects | 0.05 ms per dirty tile |

P0 exists because a 1080p main stream shown in a 480×270 cell aliases badly with a single bilinear
tap (we throw away 15 of every 16 pixels). It is a separable 4-tap box halving chain; two halvings
maximum, then the linear sampler handles the residual ≤ 2× ratio. The primary mitigation is still
`VigilCore` choosing the substream — P0 is the safety net for "user forced main stream in a 4×4".

### 6.2 Uniform struct (must match the shader byte-for-byte)

Field order is fixed largest-alignment-first. Expected `MemoryLayout<TileUniforms>.stride == 288`.

```swift
public struct TileUniforms: Sendable, Equatable {
    var model:            simd_float4x4     //  64   0
    var texTransform:     simd_float3x3     //  48  64
    var yuvToRGB:         simd_float3x3     //  48 112
    var cornerRadiusPx:   simd_float4       //  16 160  (TL, TR, BR, BL)
    var yuvOffset:        simd_float3       //  16 176  (padded)
    var cornerColor:      simd_float3       //  16 192  (padded)
    var lumaTexelSize:    simd_float2       //   8 208
    var chromaTexelSize:  simd_float2       //   8 216
    var chromaSiting:     simd_float2       //   8 224
    var viewportSizePx:   simd_float2       //   8 232
    var sampleScale:      Float             //   4 240
    var brightness:       Float             //   4 244
    var contrast:         Float             //   4 248
    var saturation:       Float             //   4 252
    var gammaExponent:    Float             //   4 256
    var sharpenAmount:    Float             //   4 260
    var nightBoost:       Float             //   4 264
    var fieldParity:      Float             //   4 268  (0 = top, 1 = bottom)
    var opacity:          Float             //   4 272
    var edrScale:         Float             //   4 276
    var hlgSystemGamma:   Float             //   4 280
    var _pad:             Float = 0         //   4 284 → stride 288
}
```
`UniformLayoutTests` dispatches a 1-thread compute kernel `vigilUniformSize` that writes
`sizeof(TileUniforms)` to a buffer and asserts it equals `MemoryLayout<TileUniforms>.stride`. Any
future field addition that breaks alignment fails CI on a Mac immediately.

Uniforms live in a **triple-buffered ring**: one `MTLBuffer` of 64 KiB per in-flight frame,
`storageModeShared`, sub-allocated in 256-byte-aligned slices (one slice per tile), gated by
`DispatchSemaphore(value: 3)` signalled in `addCompletedHandler`.

### 6.3 Encoding a single tile

```swift
func render(frame: VideoFrame?, targetTimestamp: CFTimeInterval) {
    guard isRenderable, let ctx = RenderContext.shared, let metalLayer else { return }
    if let frame { adopt(frame) }                        // updates geometry, colour, textures
    guard let textures = currentTextures else { return } // nothing decoded yet → keep black
    inFlight.wait()                                      // DispatchSemaphore(value: 3)

    guard let drawable = metalLayer.nextDrawable() else { inFlight.signal(); stats.drawableMisses += 1; return }
    let slice = ctx.uniformRing.next()
    slice.store(makeUniforms(drawableSize: metalLayer.drawableSize))

    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = drawable.texture
    rp.colorAttachments[0].loadAction = .clear
    rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    rp.colorAttachments[0].storeAction = .store

    guard let cb = ctx.commandQueue.makeCommandBuffer(),
          let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { inFlight.signal(); return }
    cb.label = "vigil.tile.\(cameraID.shortID).\(stats.renderedFrames)"

    enc.setRenderPipelineState(try pipelineForCurrentState())
    enc.setVertexBuffer(slice.buffer, offset: slice.offset, index: 0)
    enc.setFragmentBuffer(slice.buffer, offset: slice.offset, index: 0)
    enc.setFragmentTexture(CVMetalTextureGetTexture(textures.luma), index: 0)
    enc.setFragmentTexture(CVMetalTextureGetTexture(textures.chroma), index: 1)
    enc.setFragmentSamplerState(ctx.linearSampler, index: 0)
    enc.setCullMode(.none)
    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    encodePrivacyMask(into: enc, slice: slice)           // P2
    encodeMetalOverlays(into: enc, slice: slice)         // P3, only when needed
    enc.endEncoding()

    cb.addCompletedHandler { [weak self] buf in
        let keepAlive = textures                          // ← retains CVMetalTexture past GPU use
        _ = keepAlive
        Task { @MainActor in self?.completed(buf) }
    }
    if metalLayer.presentsWithTransaction {
        cb.commit(); cb.waitUntilScheduled(); drawable.present()
    } else {
        cb.present(drawable); cb.commit()
    }
    needsRedraw = false
    publishGeometry()                                     // §9.4: overlays see the same transform
}
```

### 6.4 Full Metal shader source

`Sources/VigilRender/Shaders/VigilTileShaders.metal` (byte-identical copy embedded as
`VigilShaderSource.tileShaders`):

```metal
//  VigilTileShaders.metal
//  Vigil — YCbCr→RGB + digital zoom/pan + adjustments + deinterlace + rounded mask.
//  One vertex + one fragment function, specialized by function constants.

#include <metal_stdlib>
#include <simd/simd.h>
using namespace metal;

// ---------------------------------------------------------------- specialization constants
constant bool  kIsTenBit          [[function_constant(0)]];
constant uint  kDeinterlaceMode   [[function_constant(1)]];  // 0 off, 1 bob, 2 blend
constant bool  kEnableSharpen     [[function_constant(2)]];
constant bool  kEnableNightBoost  [[function_constant(3)]];
constant bool  kEnableBicubic     [[function_constant(4)]];
constant bool  kEnableRoundedMask [[function_constant(5)]];
constant uint  kTransferFunction  [[function_constant(6)]];  // 0 sdr, 1 PQ→linear, 2 HLG→linear

// ---------------------------------------------------------------- uniforms (mirror of Swift)
struct TileUniforms {
    float4x4 model;
    float3x3 texTransform;
    float3x3 yuvToRGB;
    float4   cornerRadiusPx;    // TL, TR, BR, BL in drawable pixels
    float3   yuvOffset;
    float3   cornerColor;
    float2   lumaTexelSize;     // 1/codedWidth, 1/codedHeight
    float2   chromaTexelSize;   // 1/chromaWidth, 1/chromaHeight
    float2   chromaSiting;      // normalized picture-space offset applied to the chroma fetch
    float2   viewportSizePx;
    float    sampleScale;
    float    brightness;
    float    contrast;
    float    saturation;
    float    gammaExponent;
    float    sharpenAmount;
    float    nightBoost;
    float    fieldParity;
    float    opacity;
    float    edrScale;
    float    hlgSystemGamma;
    float    _pad;
};

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

// ---------------------------------------------------------------- vertex
constant float2 kQuad[4] = { float2(-1.0, -1.0), float2( 1.0, -1.0),
                             float2(-1.0,  1.0), float2( 1.0,  1.0) };

vertex VSOut vigilTileVertex(uint vid [[vertex_id]],
                             constant TileUniforms &u [[buffer(0)]])
{
    const float2 p = kQuad[vid];
    VSOut o;
    o.position = u.model * float4(p, 0.0, 1.0);
    // base: unit square, origin top-left (v grows downward like a texture)
    const float2 base = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    o.uv = (u.texTransform * float3(base, 1.0)).xy;
    return o;
}

// ---------------------------------------------------------------- helpers
static inline float sampleLuma(texture2d<float> t, sampler s, float2 uv) {
    return t.sample(s, uv).r;
}

static inline float4 catmullRom(float t) {
    const float t2 = t * t, t3 = t2 * t;
    return float4(-0.5 * t3 +       t2 - 0.5 * t,
                   1.5 * t3 - 2.5 * t2 + 1.0,
                  -1.5 * t3 + 2.0 * t2 + 0.5 * t,
                   0.5 * t3 - 0.5 * t2);
}

// 16-tap Catmull-Rom on luma; used only when magnifying (zoom ≥ 2) on a focused tile.
static inline float sampleLumaBicubic(texture2d<float> t, sampler s, float2 uv, float2 texel) {
    const float2 coord = uv / texel - 0.5;
    const float2 f = fract(coord);
    const float2 base = (floor(coord) + 0.5) * texel;
    const float4 wx = catmullRom(f.x);
    const float4 wy = catmullRom(f.y);
    float acc = 0.0;
    for (int j = 0; j < 4; ++j) {
        float row = 0.0;
        for (int i = 0; i < 4; ++i) {
            const float2 c = base + float2(float(i - 1), float(j - 1)) * texel;
            row += wx[i] * t.sample(s, c).r;
        }
        acc += wy[j] * row;
    }
    return acc;
}

// Bob deinterlace: reconstruct one field as a half-height image and interpolate vertically.
static inline float2 bobFieldUV(float2 uv, float parity, float2 texel) {
    const float h = 1.0 / texel.y;                       // coded height in rows
    const float rowF = uv.y * h - 0.5;                   // continuous luma row index
    const float fieldRow = (rowF - parity) * 0.5;        // continuous row index inside the field
    const float r0 = floor(fieldRow);
    const float frac0 = fieldRow - r0;
    const float lineA = 2.0 * r0 + parity;
    const float lineB = 2.0 * (r0 + 1.0) + parity;
    // Returns the two same-parity line centres to interpolate between; the weight comes from
    // bobFraction() below (two small functions instead of one out-parameter, for MSL clarity).
    return float2((lineA + 0.5) * texel.y, (lineB + 0.5) * texel.y);
}

static inline float bobFraction(float2 uv, float parity, float2 texel) {
    const float h = 1.0 / texel.y;
    const float rowF = uv.y * h - 0.5;
    const float fieldRow = (rowF - parity) * 0.5;
    return fieldRow - floor(fieldRow);
}

// Blend deinterlace: vertical [1 2 1]/4 on the frame. Halves vertical MTF, kills combing.
static inline float blendLuma(texture2d<float> t, sampler s, float2 uv, float2 texel) {
    const float a = t.sample(s, uv - float2(0.0, texel.y)).r;
    const float b = t.sample(s, uv).r;
    const float c = t.sample(s, uv + float2(0.0, texel.y)).r;
    return 0.25 * a + 0.5 * b + 0.25 * c;
}

// SMPTE ST 2084 (PQ) inverse EOTF. Output 1.0 == 10000 cd/m².
static inline float3 pqToLinear(float3 e) {
    const float m1 = 0.1593017578125;
    const float m2 = 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;
    const float3 p = pow(max(e, 0.0), 1.0 / m2);
    const float3 num = max(p - c1, 0.0);
    const float3 den = max(c2 - c3 * p, 1e-6);
    return pow(num / den, 1.0 / m1);
}

// ARIB STD-B67 / BT.2100 HLG inverse OETF + OOTF. Output 1.0 == nominal peak.
static inline float3 hlgToLinear(float3 e, float systemGamma) {
    const float a = 0.17883277, b = 0.28466892, c = 0.55991073;
    const float3 lo = (e * e) / 3.0;
    const float3 hi = (exp((e - c) / a) + b) / 12.0;
    const float3 scene = select(lo, hi, e > 0.5);
    const float ys = dot(scene, float3(0.2627, 0.6780, 0.0593));
    return scene * pow(max(ys, 1e-6), systemGamma - 1.0);
}

static inline float3 applyAdjustments(float3 rgb, constant TileUniforms &u) {
    rgb = (rgb - 0.5) * u.contrast + 0.5 + u.brightness;
    rgb = max(rgb, 0.0);
    if (kEnableNightBoost) {
        // Monotonic shoulder: f(0)=0, f(1)=1, f'(0)=1+k. Lifts shadows, compresses highlights.
        const float k = 3.0 * u.nightBoost;
        rgb = (rgb * (1.0 + k)) / (1.0 + k * rgb);
    }
    rgb = pow(max(rgb, 0.0), float3(u.gammaExponent));
    const float y = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    float sat = u.saturation;
    if (kEnableNightBoost) {
        // Chroma-noise guard: desaturate near-black where IR-cut-off noise lives.
        sat *= mix(1.0, smoothstep(0.02, 0.18, y), u.nightBoost);
    }
    rgb = mix(float3(y), rgb, sat);
    return rgb;
}

// Per-corner rounded box coverage with ~1 px analytic antialiasing.
// NOTE: the local must not be called `half` — that is a builtin MSL type name.
static inline float cornerCoverage(float2 fragPx, constant TileUniforms &u) {
    const float2 halfSize = u.viewportSizePx * 0.5;
    const float2 p = fragPx - halfSize;                  // centre-origin, y down
    float r;
    if (p.x < 0.0 && p.y < 0.0)       r = u.cornerRadiusPx.x;   // TL
    else if (p.x >= 0.0 && p.y < 0.0) r = u.cornerRadiusPx.y;   // TR
    else if (p.x >= 0.0)              r = u.cornerRadiusPx.z;   // BR
    else                              r = u.cornerRadiusPx.w;   // BL
    if (r <= 0.0) return 1.0;
    const float2 q = abs(p) - halfSize + r;
    const float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    return clamp(0.5 - d, 0.0, 1.0);
}

// ---------------------------------------------------------------- fragment
fragment float4 vigilTileFragment(VSOut in [[stage_in]],
                                  texture2d<float> lumaTex   [[texture(0)]],
                                  texture2d<float> chromaTex [[texture(1)]],
                                  sampler samp               [[sampler(0)]],
                                  constant TileUniforms &u   [[buffer(0)]])
{
    float2 uv = in.uv;
    float y;

    if (kDeinterlaceMode == 1) {                                    // bob
        const float2 vv = bobFieldUV(uv, u.fieldParity, u.lumaTexelSize);
        const float fr = bobFraction(uv, u.fieldParity, u.lumaTexelSize);
        y = mix(sampleLuma(lumaTex, samp, float2(uv.x, vv.x)),
                sampleLuma(lumaTex, samp, float2(uv.x, vv.y)), fr);
    } else if (kDeinterlaceMode == 2) {                             // blend
        y = blendLuma(lumaTex, samp, uv, u.lumaTexelSize);
    } else if (kEnableBicubic) {
        y = sampleLumaBicubic(lumaTex, samp, uv, u.lumaTexelSize);
    } else {
        y = sampleLuma(lumaTex, samp, uv);
    }

    if (kEnableSharpen) {
        // Unsharp mask on luma only: no chroma ringing, 4 extra taps.
        const float l = sampleLuma(lumaTex, samp, uv - float2(u.lumaTexelSize.x, 0.0));
        const float r = sampleLuma(lumaTex, samp, uv + float2(u.lumaTexelSize.x, 0.0));
        const float t = sampleLuma(lumaTex, samp, uv - float2(0.0, u.lumaTexelSize.y));
        const float b = sampleLuma(lumaTex, samp, uv + float2(0.0, u.lumaTexelSize.y));
        const float hp = 4.0 * y - (l + r + t + b);
        y += u.sharpenAmount * 0.25 * hp;
    }

    float2 cbcr = chromaTex.sample(samp, uv + u.chromaSiting).rg;
    if (kIsTenBit) {
        y    *= u.sampleScale;
        cbcr *= u.sampleScale;
    }

    float3 rgb = u.yuvToRGB * (float3(y, cbcr.x, cbcr.y) - u.yuvOffset);
    rgb = applyAdjustments(rgb, u);

    if (kTransferFunction == 0) {
        rgb = clamp(rgb, 0.0, 1.0);                 // SDR: layer colourspace interprets the encoding
    } else if (kTransferFunction == 1) {
        rgb = pqToLinear(max(rgb, 0.0)) * u.edrScale;
    } else {
        rgb = hlgToLinear(max(rgb, 0.0), u.hlgSystemGamma) * u.edrScale;
    }

    if (kEnableRoundedMask) {
        const float cov = cornerCoverage(in.position.xy, u);
        rgb = mix(u.cornerColor, rgb, cov);
    }
    return float4(rgb, u.opacity);
}

// ---------------------------------------------------------------- privacy mask (mosaic / solid)
struct MaskUniforms {
    float4 rectNDC;      // xy = min, zw = max, in the tile's NDC
    float4 texRect;      // corresponding source uv rect, for the mosaic fetch
    float2 blockSize;    // mosaic block size in uv units; (0,0) → solid fill
    float3 solidColor;
    float  _pad;
};

vertex VSOut vigilMaskVertex(uint vid [[vertex_id]], constant MaskUniforms &m [[buffer(0)]]) {
    const float2 p = kQuad[vid];
    const float2 unitYUp   = float2(p.x * 0.5 + 0.5, p.y * 0.5 + 0.5);  // NDC interpolation weight
    const float2 unitYDown = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);  // texture interpolation weight
    VSOut o;
    o.position = float4(mix(m.rectNDC.xy, m.rectNDC.zw, unitYUp), 0.0, 1.0);
    o.uv = mix(m.texRect.xy, m.texRect.zw, unitYDown);
    return o;
}

fragment float4 vigilMaskFragment(VSOut in [[stage_in]],
                                  texture2d<float> lumaTex   [[texture(0)]],
                                  texture2d<float> chromaTex [[texture(1)]],
                                  sampler samp               [[sampler(0)]],
                                  constant MaskUniforms &m   [[buffer(0)]],
                                  constant TileUniforms &u   [[buffer(1)]])
{
    if (m.blockSize.x <= 0.0) { return float4(m.solidColor, 1.0); }
    const float2 q = (floor(in.uv / m.blockSize) + 0.5) * m.blockSize;
    const float  y = lumaTex.sample(samp, q).r * (kIsTenBit ? u.sampleScale : 1.0);
    const float2 c = chromaTex.sample(samp, q).rg * (kIsTenBit ? u.sampleScale : 1.0);
    float3 rgb = u.yuvToRGB * (float3(y, c.x, c.y) - u.yuvOffset);
    return float4(clamp(rgb, 0.0, 1.0), 1.0);
}

// ---------------------------------------------------------------- instanced overlay rectangles
struct OverlayRect { float4 rectNDC; float4 color; float lineWidthPx; float _p0, _p1, _p2; };

vertex VSOut vigilOverlayVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                constant OverlayRect *rects [[buffer(0)]]) { /* … see §9.6 … */ }

// ---------------------------------------------------------------- layout self-check
kernel void vigilUniformSize(device uint *out [[buffer(0)]]) { out[0] = uint(sizeof(TileUniforms)); }
```

> **Shader review notes.** (a) The `sampleScale` multiply is inside `if (kIsTenBit)` so the 8-bit
> pipeline has zero extra ALU. (b) The sharpen taps read the *unfiltered* plane on purpose: sharpening
> the bicubic result double-counts high frequencies. (c) `select(lo, hi, e > 0.5)` is component-wise
> in MSL. (d) `in.position.xy` in a fragment function is the fragment's window coordinate in
> **drawable pixels**, which is why `cornerRadiusPx` is in pixels.

### 6.5 Building the uniforms

```swift
func makeUniforms(drawableSize: CGSize) -> TileUniforms {
    let g = state.geometry
    let f = fitRect(bounds: bounds, displayAspect: g.displayAspect, gravity: options.gravity)
    let fx = Float(f.width / bounds.width), fy = Float(f.height / bounds.height)
    let z  = Float(state.transform.zoom)
    let t  = state.transform.translation
    var m  = matrix_identity_float4x4
    m.columns.0.x = fx * z
    m.columns.1.y = fy * z
    m.columns.3.x = Float(t.x)
    m.columns.3.y = Float(t.y)

    let color = ColorConversion.make(for: g.color, bitDepth: g.bitDepth)   // §7
    var u = TileUniforms(
        model: m,
        texTransform: textureTransform(g, flipVertical: state.transform.flipVertical),
        yuvToRGB: color.matrix,
        cornerRadiusPx: options.cornerRadii * Float(layer?.contentsScale ?? 1),
        yuvOffset: color.offset,
        cornerColor: options.cornerColor.simd3,
        lumaTexelSize: [1 / Float(g.codedSize.width), 1 / Float(g.codedSize.height)],
        chromaTexelSize: [2 / Float(g.codedSize.width), 2 / Float(g.codedSize.height)],
        chromaSiting: color.chromaSiting,
        viewportSizePx: [Float(drawableSize.width), Float(drawableSize.height)],
        sampleScale: color.sampleScale,
        brightness: Float(options.adjustments.brightness),
        contrast: Float(options.adjustments.contrast),
        saturation: Float(options.adjustments.saturation),
        gammaExponent: Float(1.0 / options.adjustments.gamma),
        sharpenAmount: Float(options.adjustments.sharpen),
        nightBoost: Float(options.adjustments.nightBoost),
        fieldParity: Float(currentFieldParity),
        opacity: 1,
        edrScale: color.edrScale,
        hlgSystemGamma: color.hlgSystemGamma)
    return u
}
```
Note `gammaExponent = 1/gamma`: the user-facing "gamma 2.2" means *apply* a 1/2.2 exponent.

---

## 7. Colour management

### 7.1 Where the colour description comes from

Priority order, highest first:

1. `CVPixelBuffer` attachments set by VideoToolbox: `kCVImageBufferYCbCrMatrixKey`,
   `kCVImageBufferColorPrimariesKey`, `kCVImageBufferTransferFunctionKey`,
   `kCVImageBufferChromaLocationTopFieldKey`, and `CVBufferGetAttachment(pb,
   kCVImageBufferICCProfileKey, nil)` (ignored — we never apply an ICC profile in the shader).
2. `FrameGeometry.color`, derived by `VigilBitstream` from the SPS VUI
   (`colour_primaries`, `transfer_characteristics`, `matrix_coefficients`, `video_full_range_flag`).
3. Heuristic default: `cropHeight <= 576 → BT.601`, otherwise **BT.709**, `range = .video`,
   `chromaSiting = .left`. Hikvision firmware very often omits the VUI entirely; this default matches
   what their encoders actually produce.

A mismatch between (1) and (2) is logged once per stream at `.debug` with both values; (1) wins.

### 7.2 The matrices (normative constants)

`R'G'B'` output is the **gamma-encoded** signal in the source's primaries. Rows are applied to
`(Y − yOff, Cb − cOff, Cr − cOff)`.

**BT.709, video (limited) range, 8-bit** — the overwhelmingly common Hikvision case.
`yOff = 16/255 = 0.0627451`, `cOff = 128/255 = 0.5019608`.

```
| 1.164384   0.000000   1.792741 |
| 1.164384  -0.213249  -0.532909 |
| 1.164384   2.112402   0.000000 |
```

**BT.709, full range** (`video_full_range_flag == 1`). `yOff = 0`, `cOff = 0.5`.

```
| 1.000000   0.000000   1.574800 |
| 1.000000  -0.187324  -0.468124 |
| 1.000000   1.855600   0.000000 |
```

**BT.601 (SMPTE 170M), video range, 8-bit** — analog channels on an NVR.
`yOff = 0.0627451`, `cOff = 0.5019608`.

```
| 1.164384   0.000000   1.596027 |
| 1.164384  -0.391762  -0.812968 |
| 1.164384   2.017232   0.000000 |
```

**BT.601, full range.** `yOff = 0`, `cOff = 0.5`.

```
| 1.000000   0.000000   1.402000 |
| 1.000000  -0.344136  -0.714136 |
| 1.000000   1.772000   0.000000 |
```

**BT.2020 non-constant luminance, video range, 10-bit.**
`yOff = 64/1023 = 0.0625611`, `cOff = 512/1023 = 0.5004888`.

```
| 1.167808   0.000000   1.683567 |
| 1.167808  -0.187877  -0.652337 |
| 1.167808   2.147982   0.000000 |
```

**BT.2020, full range, 10-bit.** `yOff = 0`, `cOff = 512/1023`.

```
| 1.000000   0.000000   1.474600 |
| 1.000000  -0.164553  -0.571353 |
| 1.000000   1.881400   0.000000 |
```

Derivation for reviewers: with luma weights `(Kr, Kg, Kb)`,
`Cr` coefficient for R is `2(1 − Kr)`, `Cb` for B is `2(1 − Kb)`, and G takes
`−2Kr(1 − Kr)/Kg` and `−2Kb(1 − Kb)/Kg`. Video-range scaling multiplies the luma column by
`(2^n − 1)/(219·2^(n−8))` and the chroma columns by `(2^n − 1)/(224·2^(n−8))`.

```swift
struct ColorConversion {
    var matrix: simd_float3x3       // column-major; build with rows then transpose
    var offset: simd_float3
    var sampleScale: Float
    var chromaSiting: simd_float2
    var edrScale: Float
    var hlgSystemGamma: Float
    var layerColorSpaceName: CFString
    var layerPixelFormat: MTLPixelFormat
}
```

`simd_float3x3(rows:)` exists in Swift, so the tables above can be transcribed literally as rows —
do not hand-transpose.

### 7.3 Chroma siting

4:2:0 chroma is **not** co-sited with luma. H.264/H.265 default (`chroma_sample_loc_type == 0`) is
"left": chroma sample *j* sits at luma column *2j*. A naive shared-`uv` bilinear fetch places it at
luma column `2j + 0.5`, so the picture drifts half a luma pixel left, visible as coloured fringes on
vertical edges after 4× zoom.

```
chromaSiting = (.left    → simd_float2(0.5 / codedWidth, 0))
             = (.center  → simd_float2(0, 0))
             = (.topLeft → simd_float2(0.5 / codedWidth, 0.5 / codedHeight))
```
Read `kCVImageBufferChromaLocationTopFieldKey` (`"Left"`, `"Center"`, `"TopLeft"`,
`"DV420"`); default `.left`.

### 7.4 10-bit sampling

`kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` (`'x420'`) stores each 10-bit sample in a
little-endian 16-bit word, **left-justified**: the 10 significant bits occupy bits 15…6 and bits
5…0 are zero. Sampling as `.r16Unorm` therefore yields `code·64 / 65535 = code / 1023.98`, which is
short of `code / 1023` by a factor of `65535 / 65472 = 1.000962`.

**Decision:** `sampleScale = 65535.0 / 65472.0` for 10-bit and `1.0` for 8-bit. A single named
constant, `ColorConversion.tenBitLeftJustified` (default `true`), inverts to
`sampleScale = 65535.0 / 1023.0 = 64.0616` if a future OS/codec combination is found to store the
samples right-justified. `TenBitScaleTests` decodes a fixture with a known 10-bit ramp and asserts
`|observedPeak − 1.0| < 0.002`, which fails loudly by a factor of 64 if the alignment ever flips.

### 7.5 SDR output and layer tagging

We render the **encoded** `R'G'B'` signal and let Core Animation convert to the display, which is
both faster and more accurate than linearising ourselves.

| Source | `CAMetalLayer.pixelFormat` | `CAMetalLayer.colorspace` | `wantsExtendedDynamicRangeContent` |
|---|---|---|---|
| 8-bit BT.709 SDR | `.bgra8Unorm` | `CGColorSpace.itur_709` | false |
| 8-bit BT.601 SDR | `.bgra8Unorm` | `CGColorSpace.itur_709` (see note) | false |
| 10-bit BT.709 SDR | `.bgr10_xr` | `CGColorSpace.itur_709` | false |
| 10-bit BT.2020 SDR | `.rgba16Float` | `CGColorSpace.itur_2020` | false |
| 10-bit BT.2020 PQ | `.rgba16Float` | `CGColorSpace.extendedLinearITUR_2020` | true |
| 10-bit BT.2020 HLG | `.rgba16Float` | `CGColorSpace.extendedLinearITUR_2020` | true |

*Note on BT.601:* `CGColorSpace(name: .itur_709)` and SMPTE-170M share the same transfer function
and differ only in primaries; the visible error on an analog SD channel is under 1 ΔE00 and tagging
`.itur_709` avoids a colourspace conversion pass. If a user complains, the exact space is
`CGColorSpace(name: CGColorSpace.itur_709)` replaced by
`CGColorSpace(name: CGColorSpace.sRGB)` — do not invent a custom space.

`.bgr10_xr` is chosen over `.rgba16Float` for 10-bit SDR because it is half the bandwidth and CA
handles it natively; note it is an *extended-range* format where `[0,1]` maps to `[64, 940]` in a
1023-code container, so the shader writes plain `[0,1]` values and CA does the right thing.

### 7.6 HDR / EDR

* **When EDR is enabled:** only when `ColorInfo.transfer ∈ {.pq, .hlg}` **and** the current screen
  reports `maximumExtendedDynamicRangeColorComponentValue > 1.0`. Most Hikvision "HDR"/WDR cameras
  emit SDR BT.709 with tone mapping already applied in-camera; turning EDR on for them washes the
  image out and doubles the drawable bandwidth for nothing.
* **Scaling.** With `extendedLinearITUR_2020`, `1.0` means SDR diffuse white. Per ITU-R BT.2408
  reference white is 203 cd/m².
  * PQ: `pqToLinear` returns `1.0 == 10000 cd/m²`, so `edrScale = 10000 / 203 = 49.2611`.
  * HLG: nominal peak 1000 cd/m² at reference white 203, so `edrScale = 1000 / 203 = 4.9261`, and
    `hlgSystemGamma = 1.2 + 0.42 · log10(peakLuminance / 1000)`, with `peakLuminance` taken from the
    screen's `maximumExtendedDynamicRangeColorComponentValue × 203`, clamped to `[400, 4000]`.
* **Headroom clamp.** After scaling, clamp to `screen.maximumExtendedDynamicRangeColorComponentValue`
  (re-read on `NSApplication.didChangeScreenParametersNotification` and
  `NSWindow.didChangeScreenNotification`, and polled at 1 Hz while EDR is active because macOS ramps
  headroom over ~1 s when a bright HDR window appears).
* **`CAMetalLayer.edrMetadata`.** Set `CAEDRMetadata.hlg` for HLG. For PQ set
  `CAEDRMetadata.hdr10(minLuminance: 0.005, maxLuminance: 1000, opticalOutputScale: 100)` when the
  stream carries a mastering-display SEI, otherwise leave `nil` and rely on the colourspace tag.
* **Never mix.** A tile is either SDR or EDR for the whole life of a decode session; a transfer
  change is treated like a format change (drain, rebuild pipeline, keep showing the last frame).
* **Grid rule.** In a wall with mixed SDR and EDR tiles, EDR is disabled entirely (single atlas, one
  colourspace). Justification: a 16-up wall is a monitoring surface, not a mastering surface, and per
  tile EDR would force per-tile layers and blow the §11 budget.

---

## 8. Post effects

### 8.1 Order of operations (fixed)

```
crop → (P0 box downsample if ≥2×) → luma fetch (bilinear | bicubic | bob | blend)
     → unsharp mask on luma → chroma fetch with siting → 10-bit scale
     → YCbCr→R'G'B' matrix → contrast → brightness → night curve → gamma
     → saturation → [PQ/HLG EOTF → edrScale]  → rounded-corner blend → output
```

Justification for the two non-obvious choices: adjustments run on the **gamma-encoded** signal
because that is where "brightness", "contrast" and "gamma" have their conventional, expected
behaviour and where every NVR client applies them; sharpening runs **before** the matrix on luma
only so it cannot produce chroma ringing or hue shifts.

### 8.2 Adjustment ranges and defaults

| Field | Range | Default | Neutral | UI step | Notes |
|---|---|---|---|---|---|
| `brightness` | −0.5…+0.5 | 0 | 0 | 0.01 | additive on encoded signal |
| `contrast` | 0.5…2.0 | 1 | 1 | 0.01 | about a 0.5 pivot |
| `saturation` | 0…2 | 1 | 1 | 0.01 | luma-preserving mix |
| `gamma` | 0.5…2.5 | 1 | 1 | 0.05 | shader exponent is `1/gamma` |
| `sharpen` | 0…1.5 | 0 | 0 | 0.05 | > 1.0 rings visibly; UI warns above 1.0 |
| `nightBoost` | 0…1 | 0 | 0 | 0.05 | `k = 3·nightBoost` |
| `deinterlace` | none/bob/blend | auto | none | — | auto = bob when `fieldOrder != .progressive` |

`ImageAdjustments` is `Codable` and persisted **per camera** by `VigilCore`; it is *not* a global
setting. `ImageAdjustments.isIdentity` gates the pipeline variant and, when true together with
`zoom == 1` and no privacy mask, permits the cheap ASBDL backend (§13.3).

### 8.3 Deinterlace, and the two-presents rule

Hikvision NVRs expose analog channels as interlaced 4CIF (`704×576i25` PAL, `704×480i30` NTSC), and
some older IP cameras emit `1920×1080i25`. Detection, in priority order: H.264 SPS
`frame_mbs_only_flag == 0` → interlaced; per-picture `field_pic_flag` / SEI `pic_struct`
(`pic_struct ∈ {1,2}` = single field, `{3,4}` = interleaved fields) → field order; HEVC
`general_interlaced_source_flag` + `SEI pic_struct`. `VigilBitstream` reports this in
`FrameGeometry.fieldOrder`.

* **Auto mode** picks `bob` — motion-adaptive is out of scope and blend halves vertical resolution.
* **Bob** must double the presentation rate: one decoded `CVPixelBuffer` is rendered **twice**,
  first with `fieldParity = (fieldOrder == .topFieldFirst ? 0 : 1)` at PTS `t`, then with the
  opposite parity at `t + frameDuration/2`. The frame is retained across both presents; the second
  present is scheduled by the display link (a `pendingSecondField` flag) so 25i becomes 50p.
* **Blend** presents once per decoded frame.
* Deinterlace + bicubic are mutually exclusive (bob already interpolates vertically); the pipeline
  key silently drops `bicubic` when `deinterlace != .none`.
* Chroma in 4:2:0 interlaced content is field-interleaved as well; we accept the resulting slight
  vertical chroma error rather than adding a chroma-field pass. It is invisible at 4CIF.

### 8.4 Resampling policy

| Scale factor `sourcePx / drawablePx` | Path | Rationale |
|---|---|---|
| ≥ 4.0 | P0 two box halvings, then bilinear | 1080p in a ≤ 480 px cell |
| 2.0 … 4.0 | P0 one box halving, then bilinear | 1080p in a 480–960 px cell |
| 1.05 … 2.0 | bilinear only | CA/GPU bilinear is adequate |
| 0.95 … 1.05 | nearest sampler | 1:1, avoids a needless softening |
| ≤ 0.95 (magnifying) | bilinear, or **Catmull-Rom bicubic when `zoom ≥ 2.0`** | digital zoom must not look mushy |

Bicubic is only ever enabled on a tile whose `pixelSize.width ≥ 640` and which is focused or
fullscreen, bounding its 16-tap cost to one tile.

### 8.5 Night boost, spelled out

`f(x) = x(1+k) / (1 + kx)`, `k = 3·nightBoost`. Properties: `f(0)=0`, `f(1)=1`, `f'(0)=1+k`,
monotonic, no clipping. At `nightBoost = 1` (`k = 3`): `f(0.05) = 0.174`, `f(0.10) = 0.308`,
`f(0.25) = 0.571`, `f(0.50) = 0.800`, `f(0.75) = 0.923`. Paired with the shadow desaturation guard
`sat *= mix(1, smoothstep(0.02, 0.18, luma), nightBoost)` so lifted IR noise does not turn purple.

---

## 9. Overlays

### 9.1 The decision rule

> **An overlay is drawn in Metal if and only if it must be pixel-registered with the video, must
> sample the video, or must appear in a capture. Everything else is SwiftUI, animated on the
> compositor, and never triggers a Metal redraw.**

| Overlay | Where | Why |
|---|---|---|
| Timestamp OSD | **SwiftUI** | text quality, localisation (ru), `monospacedDigit`, no GPU cost; burn-in for recordings is a separate CG composite at capture time |
| Camera-name chip | **SwiftUI** | design-system material + typography; must not re-render video |
| Recording indicator (pulsing dot) | **SwiftUI** | a 2 s breathing animation would otherwise force 120 Metal redraws/s |
| Live/degraded status dot, packet-loss banner | **SwiftUI** | chrome |
| Focus ring, hover chrome, tile toolbar | **SwiftUI** | design system owns these |
| Stats HUD | **SwiftUI** | text-heavy, updates at 1 Hz |
| PTZ direction indicator | **SwiftUI** (`Canvas`) | vector arc, spring animated |
| 3D-position drag rectangle | **SwiftUI** (`Canvas`) | must track the mouse with zero latency; a GPU round-trip would add a frame |
| Drag-target highlight | **SwiftUI** | chrome |
| **Motion boxes ≤ 32** | **SwiftUI** (`Canvas`) | vector strokes, animatable opacity, trivial count |
| **Motion boxes > 32, or atlas wall mode** | **Metal** (instanced) | per-tile SwiftUI overlays multiply badly at 16 tiles; and in atlas mode there is no per-tile layer |
| **Privacy mask** | **Metal** | must sample the video (mosaic/blur), must be pixel-exact under zoom, and must appear in snapshots and recordings |
| Deinterlace, adjustments, night boost | **Metal** | pixel operations |
| Zoom/pan | **Metal** | pixel operations |

Consequence for `VigilUI`: the SwiftUI overlay stack sits in a `ZStack` **above** the
`VideoTile` representable, is `.allowsHitTesting(false)` except for the tile toolbar, and reads all
geometry from `TileRenderState` (§9.4). It must never wrap the video in `.drawingGroup()`,
`.opacity(<1)`, `.shadow`, `.blur`, or a SwiftUI `.mask` — see §5.5.

### 9.2 Camera normalized space → view space (motion boxes, privacy masks, VCA rules)

Hikvision expresses regions in a **0…1000** normalized integer space. Two conventions exist in the
field and both must be supported:

| ISAPI surface | Space | Origin | Notes |
|---|---|---|---|
| `/ISAPI/System/Video/inputs/channels/{c}/motionDetection` (`<gridMap>`) | 22×18 grid mask | **top-left** | hex bitmask, 396 cells, row-major, MSB-first per row |
| `/ISAPI/Smart/FieldDetection`, `LineDetection`, `regionEntrance`, `intrusion` | 0…1000 | **bottom-left** | `<RegionCoordinatesList><RegionCoordinates><positionX/><positionY/>` |
| `/ISAPI/Event/…/notification/alertStream` `<DetectionRegionList>` | 0…1000 | **bottom-left** on most firmware, **top-left** on some 5.5.x DVRs | probe once, cache |
| `privacyMask/regions` | 0…1000 | **bottom-left** | 4-point polygons, up to 4 (some models 8) |
| `PTZCtrl/…/position3D` | 0…255 | **bottom-left** | see §9.7 |

```swift
public enum NormalizedOrigin: String, Sendable, Codable { case topLeft, bottomLeft }

/// Camera 0…1000 rect → content-normalized rect (C, top-left origin, 0…1).
public func contentRect(cameraRect r: CGRect, origin: NormalizedOrigin) -> CGRect {
    let n = CGRect(x: r.minX / 1000, y: r.minY / 1000,
                   width: r.width / 1000, height: r.height / 1000)
    switch origin {
    case .topLeft:    return n
    case .bottomLeft: return CGRect(x: n.minX, y: 1 - n.maxY, width: n.width, height: n.height)
    }
}
```

**The flip is of the rectangle, not the point.** `y' = 1 − (y + h)`, never `y' = 1 − y`. Flipping the
origin point alone is the single most common bug in this area and produces boxes that are mirrored
*and* offset by their own height.

For polygons (privacy masks, intrusion regions) flip each vertex: `y' = 1 − y`, then re-order the
vertex list to preserve winding (`reversed()`), because a Y flip reverses orientation and the mask
rasteriser assumes counter-clockwise.

Full chain, camera region → view points:

```swift
let content = contentRect(cameraRect: box.rect, origin: capabilities.regionOrigin)
let viewRect = coordinateMap.viewRect(content: content)     // §2.5, honours zoom/pan/fit/crop
```

Worked expectation (unit test `MotionBoxMappingTests`): camera rect `(250, 250, 500, 500)` in 0…1000
with `origin == .topLeft`, picture 1920×1080, tile 800×600, `.fit`, zoom 1 ⇒
`viewRect == (200, 187.5, 400, 225)`. With `origin == .bottomLeft` the same input ⇒ identical rect
(because the rect is centred); the discriminating case is `(0, 0, 200, 100)`, which maps to
`(0, 75, 160, 45)` for `.topLeft` and `(0, 375, 160, 45)` for `.bottomLeft`.

**Also normative:** camera regions are defined on the **displayed (cropped)** picture, not the coded
picture. Therefore the mapping goes through content space C, which already has crop and SAR applied.
Never map 0…1000 onto `codedSize`.

### 9.3 Motion box behaviour

* ISAPI `alertStream` delivers detections at roughly 1 Hz while motion persists; boxes must not
  strobe. Timeline per box: fade in over **120 ms** (`spring(response: 0.22, dampingFraction: 0.86)`
  on opacity + `scale 1.04 → 1.0`), hold **900 ms** from the last refresh, fade out over **240 ms**
  (`easeOut`).
* Coalescing: a new detection whose IoU with a live box exceeds **0.6** updates that box's rect
  (spring-interpolated) and resets its hold timer instead of adding a new box.
* Cap: **48** live boxes per tile; beyond that keep the 48 largest and show a `+N` chip.
* Boxes are pinned to the *event's* wall-clock time, not the render time. If the tile's latency
  estimate exceeds 400 ms, boxes are delayed by that estimate so they land on the frame they
  describe.
* Boxes are **hidden entirely** while a PTZ movement is in flight and for 1.5 s afterwards; camera
  coordinates are meaningless during a pan. `TileRenderState.suppressesEventOverlays` drives this and
  is set from the delegate.
* When a box lies fully outside `visibleContentRect` (i.e. the user has zoomed away from it) draw a
  **12×12 pt chevron** on the nearest tile edge at the box's projected position, at 60% opacity. This
  is the "off-screen motion indicator"; it is what makes digital zoom safe to use during monitoring.
* Colour: the design system's `motion` token (amber), 1.5 pt stroke at the tile's `contentsScale`,
  4 pt corner radius, plus a 20%-opacity fill. Line-crossing rules draw a line with a direction
  arrowhead; intrusion regions draw the polygon.

### 9.4 How SwiftUI overlays learn the geometry

```swift
@MainActor @Observable
public final class TileRenderState {
    public private(set) var geometry: TileGeometry
    public private(set) var transform: TileTransform
    public private(set) var pixelSize: CGSize
    public private(set) var boundsSize: CGSize
    public private(set) var contentsScale: CGFloat
    public private(set) var coordinateMap: TileCoordinateMap    // recomputed with every publish
    public private(set) var backend: TileBackend
    public private(set) var isReceivingFrames: Bool
    public private(set) var lastFrameHostTime: UInt64
    public private(set) var stats: RenderStats
    public var suppressesEventOverlays: Bool = false
    public var visibleContentRect: CGRect { coordinateMap.visibleContentRect }
}
```

`publishGeometry()` is called **after** the uniforms for the presented frame are built and **before**
`present()`, so the value SwiftUI reads describes exactly the frame that is about to appear. Publishes
are coalesced to at most one per display refresh; a publish with an unchanged
`(bounds, scale, transform, geometry)` is skipped so `@Observable` does not wake SwiftUI needlessly.

During an inertial pan the overlay follows on the same refresh as the video because both read the same
`TileTransform` — the transform is mutated once per display-link tick, before rendering.

### 9.5 Privacy-mask preview (Metal)

Two render modes, both driven by `PrivacyMaskSet`:

```swift
public struct PrivacyRegion: Sendable, Equatable, Codable, Identifiable {
    public var id: Int                     // Hikvision region index, 1-based
    public var polygon: [CGPoint]          // content-normalized, ≥3 points, ≤8
    public var style: Style                // .solid(color) | .mosaic(blockPx: 16) | .blur(radiusPx: 24)
    public var isEnabled: Bool
}
```

* `.solid` and `.mosaic` are one scissored draw each with `vigilMaskFragment`. `blockSize` is
  converted from pixels to source-uv units: `blockSize = blockPx / codedSize`, so mosaic blocks stay
  a constant size **in the source image**, which is what a privacy mask means (it must not become
  fine-grained when the user zooms in).
* `.blur` needs a two-pass separable Gaussian and therefore an intermediate texture; it is only
  offered when the tile is focused or fullscreen. In grid mode `.blur` silently renders as `.mosaic`
  with `blockPx = radiusPx`. Justification: a 9-tap × 2 pass blur per region per tile at 16 tiles is
  0.6 ms of GPU that buys nothing at 240 px tile height.
* Non-rectangular polygons are triangulated on the CPU with a fan from the centroid (regions are
  always convex on Hikvision firmware) and drawn as a triangle list; the scissor rect is the
  polygon's bounding box in drawable pixels.
* The **editor** (drawing/dragging mask polygons) lives in `VigilUI` and manipulates
  content-normalized points; it uses `TileCoordinateMap` for hit-testing handles. `VigilRender` only
  renders the current set and never mutates it.

### 9.6 Metal overlay rectangles (wall mode)

One instanced draw for all boxes across all tiles:

```metal
struct OverlayRect { float4 rectNDC; float4 color; float lineWidthPx; float _p0, _p1, _p2; };
```
The vertex function expands instance *i* into the quad `rectNDC`; the fragment function computes the
distance to the rect border in pixels from `in.position.xy` and outputs `color` where
`distanceToBorder < lineWidthPx`, or `color * 0.2` inside (the fill), else discards. Blending for this
pass only: `isBlendingEnabled = true`, `sourceRGBBlendFactor = .sourceAlpha`,
`destinationRGBBlendFactor = .oneMinusSourceAlpha`. Up to 256 instances per draw
(`MTLBuffer` of `256 * 48` bytes = 12 KiB, in the uniform ring).

### 9.7 3D-positioning drag rectangle → PTZ

`VigilRender` emits the gesture in **content-normalized** coordinates and knows nothing about ISAPI:

```swift
public struct Position3DGesture: Sendable, Equatable {
    public var start: CGPoint          // content-normalized, top-left origin
    public var end: CGPoint
    public var isClick: Bool           // travel < 4 pt → centre-on-point
    public var direction: Direction    // .zoomIn (down-right) | .zoomOut (up-left)
}
```
Semantics that must be implemented (these are Hikvision's, and users expect them):

* Drag **down-right** ⇒ zoom **in** to the drawn rectangle.
* Drag **up-left** ⇒ zoom **out** by the ratio of the rectangle to the frame.
* A click (travel < 4 pt) ⇒ centre the camera on that point and zoom in one step.
* The rectangle is drawn with a 1.5 pt accent stroke, 8% accent fill, `crosshair` cursor,
  and snaps to the tile's visible content rect.
* While the gesture is active, digital zoom/pan input is ignored (mode is exclusive).

`VigilISAPI` converts to the wire format: 0…255 in both axes with a **bottom-left** origin,
`x = round(255 · u.x)`, `y = round(255 · (1 − u.y))`, sent as
`PUT /ISAPI/PTZCtrl/channels/{c}/position3D` with
`<Position3D><StartPoint><positionX/><positionY/></StartPoint><EndPoint>…</EndPoint></Position3D>`.
The origin convention is overridable via a capability flag because a minority of firmware uses
top-left. **Important:** if the tile is digitally zoomed, `u` is still the content-normalized point,
so 3D positioning composes correctly with digital zoom for free.

### 9.8 PTZ direction indicator

Drawn in SwiftUI: a 96 pt circle at the tile centre, 2 pt ring at 12% white, with a 60°
accent-coloured arc pointing in the active direction, arc opacity = `0.35 + 0.65 · speed/7`, plus a
centred SF Symbol (`arrow.up`, `arrow.up.left`, …). Entrance `spring(0.22, 0.86)` with
`scale 0.9 → 1`; exit `easeOut(0.14)`. During continuous movement the arc breathes at 1.2 s. Zoom
in/out shows `plus.magnifyingglass` / `minus.magnifyingglass` instead of an arc. Fully suppressed when
`reduceMotion` is on except for opacity.

---

## 10. Interactions

### 10.1 Master event table

| Input | AppKit entry point | Effect |
|---|---|---|
| Scroll, mouse wheel (`!hasPreciseScrollingDeltas`) | `scrollWheel(with:)` | **zoom** anchored at cursor |
| Two-finger trackpad scroll, `zoom == 1` | `scrollWheel(with:)` | **zoom** anchored at cursor |
| Two-finger trackpad scroll, `zoom > 1` | `scrollWheel(with:)` | **pan** (with momentum) |
| ⌘ + scroll (any device) | `scrollWheel(with:)` | **zoom** (escape hatch on a trackpad) |
| ⇧ + scroll | `scrollWheel(with:)` | **pan horizontally** |
| Pinch | `NSMagnificationGestureRecognizer` | **zoom** anchored at gesture location |
| Smart-zoom (two-finger double tap) | `smartMagnify(with:)` | toggle zoom 1 ⇄ 2 anchored at cursor |
| Left drag, `zoom > 1`, no mode | `mouseDown/Dragged/Up` | **pan** with inertia |
| Left drag, `mode == .position3D` | `mouseDown/Dragged/Up` | draw the PTZ rectangle |
| Left drag, `mode == .privacyEdit` | `mouseDown/Dragged/Up` | move a mask handle (delegate) |
| Left drag, `zoom == 1`, no mode | `mouseDown` + 3 pt threshold | **begin a tile drag session** |
| Double-click | `mouseDown` `clickCount == 2` | toggle fullscreen for this tile |
| ⌥ double-click | `mouseDown` | reset zoom to 1 (and stop inertia) |
| Right-click / ⌃-click | SwiftUI `.contextMenu` (view returns `nil` from `menu(for:)`) | context menu |
| Middle-click | `otherMouseDown` | toggle mute for this camera (delegate) |
| Arrows | `keyDown`/`keyUp` | continuous PTZ while held |
| ⇧+arrows | `keyDown` | PTZ at 2× speed |
| ⌥+arrows | handled by `VigilUI` | move focus between tiles (view returns `false`) |
| `+` / `-` / `=` | `keyDown` | digital zoom in/out by 1.25× at the tile centre |
| `0` | `keyDown` | reset digital zoom |
| `[` / `]` | `keyDown` | PTZ zoom out / in (optical) |
| Space, ⌘R, ⌘⇧S, ⌘F, ⌘K… | **not handled** (`super.keyDown`) | menu/shortcut chain owns them |
| Drop of `com.vigil.camera-ref` | `NSDraggingDestination` | assign camera to this cell |
| Drop of `com.vigil.tile-assignment` | `NSDraggingDestination` | move/swap tiles |
| Drop of image/PDF | rejected | `draggingEntered` returns `[]` |
| Mouse moved | `mouseMoved(with:)` | hover chrome timer, cursor update, pixel-probe HUD |
| Mouse exited | `mouseExited(with:)` | dismiss hover chrome after 180 ms |

Rules that keep this from fighting the rest of the app:

1. `performKeyEquivalent(with:)` returns `false` always — menu shortcuts must win.
2. `keyDown` for any event with `⌘` in `modifierFlags.intersection(.deviceIndependentFlagsMask)`
   calls `super.keyDown(with:)` immediately.
3. While an `NSMagnificationGestureRecognizer` is in `.began`/`.changed`, `scrollWheel` is ignored.
4. A `mouseDown` cancels inertia. A double-click is only recognised if travel stayed under 3 pt.
5. Right-click never starts a drag and never changes focus (matches Finder).

### 10.2 Scroll → zoom

```swift
override public func scrollWheel(with event: NSEvent) {
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let wantsPan = event.hasPreciseScrollingDeltas && state.transform.zoom > 1
                   && !mods.contains(.command)
    if wantsPan { panFromScroll(event); return }
    if mods.contains(.shift), state.transform.zoom > 1 { panFromScroll(event, horizontalOnly: true); return }

    // Zoom. Precise deltas are in points; line deltas are in lines (≈ 1 per notch).
    let raw = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
    let sign: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
    let factor = exp(sign * raw * 0.0075)                     // 1 notch ≈ ×1.062
    zoom(to: state.transform.zoom * factor, anchorViewPoint: convertToLocal(event))
    setPacing(.interacting)
}

func zoom(to newZoom: CGFloat, anchorViewPoint p: CGPoint) {
    let z  = state.transform.zoom
    let z2 = min(max(newZoom, 1), options.maxZoom)            // maxZoom = 8
    guard z2 != z else { return }
    let a = ndc(fromViewPoint: p)                             // (2x/w − 1, 1 − 2y/h)
    var t = state.transform.translation
    t = CGPoint(x: a.x + (z2 / z) * (t.x - a.x),
                y: a.y + (z2 / z) * (t.y - a.y))              // §2.3
    apply(TileTransform(zoom: z2, translation: t, flipVertical: state.transform.flipVertical))
}
```

* `exp()` keeps zoom perceptually uniform: N notches always multiply by the same factor.
* Zoom snaps to exactly `1.0` when the result lands within 2% of 1.0, and to integers `2, 4, 8` within
  1.5%, with a 6 ms `spring(0.18, 1.0)` settle. This makes "back to normal" reliable without a
  modifier.
* Zoom crossing 1.0 → > 1.0 promotes the backend from `.sampleBufferLayer` to `.metal` (§13.3).

### 10.3 Pan, momentum and rubber banding

```swift
func panFromScroll(_ event: NSEvent, horizontalOnly: Bool = false) {
    let s = 2 / bounds.width                                  // points → NDC x
    var d = CGVector(dx: -event.scrollingDeltaX * s,
                     dy:  event.scrollingDeltaY * (2 / bounds.height))
    if horizontalOnly { d.dy = 0 }
    translate(by: d, rubberBand: event.phase != .ended)
    if event.momentumPhase == .ended || event.phase == .ended { settle() }
}
```

* **Drag pan** integrates `mouseDragged` deltas directly (`event.deltaX/deltaY` are in points,
  already backing-scale independent) and records a velocity estimate as an exponential moving average
  with `α = 0.35` over the last 4 events, in NDC/s, using `event.timestamp` differences.
* **Inertia** runs on the display link: `v *= exp(-dt / τ)` with `τ = 0.16 s`; stop when
  `|v| < 0.02 NDC/s`. Each tick applies `t += v · dt` then clamps.
* **Rubber band** while a gesture is active: allowed overshoot beyond the clamp is
  `o = d · (1 − 1/(x·c/d + 1))` with `c = 0.55`, `d = 0.12` NDC (the standard AppKit/UIKit curve),
  and on release the overshoot returns with `spring(response: 0.34, dampingFraction: 0.82)` — the
  design system's `standard` spring, so the video moves like the rest of the app.
* `reduceMotion` on ⇒ no inertia, no rubber band; pans clamp hard and settle instantly.
* All of pan, inertia and rubber band set `needsRedraw` and `setPacing(.interacting)`; pacing returns
  to `.idle` 250 ms after the last change.

### 10.4 Pinch

```swift
private func installGestures() {
    let magnify = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:)))
    magnify.delaysPrimaryMouseButtonEvents = false
    addGestureRecognizer(magnify)
}

@objc private func handleMagnify(_ g: NSMagnificationGestureRecognizer) {
    switch g.state {
    case .began:
        zoomAtGestureStart = state.transform.zoom
        gestureAnchor = g.location(in: self)          // isFlipped == true → top-left origin
        cancelInertia()
        setPacing(.interacting)
    case .changed:
        zoom(to: zoomAtGestureStart * (1 + g.magnification), anchorViewPoint: gestureAnchor)
    case .ended, .cancelled, .failed:
        settle(); setPacing(.idle)
    default: break
    }
}
```
`magnification` is cumulative for the gesture and starts at 0, hence the `1 + m` form against the
zoom captured at `.began`. The anchor is captured once at `.began` (not per `.changed`) so a slight
finger drift does not make the image swim.

`smartMagnify(with:)` toggles between 1 and 2 with `spring(0.34, 0.82)` animated over 8 display-link
ticks, anchored at the event location.

### 10.5 Double-click to fullscreen — the transition

Two cases, and the difference matters:

**Same window (grid cell ⇄ stage-fullscreen).** Keep **one** `VideoTileView` instance and animate the
hosting view's frame. Reparenting or recreating the view mid-animation guarantees a black flash
because the new `CAMetalLayer` has no drawable yet.

```swift
// VigilUI drives this; VigilRender guarantees it survives the move.
NSAnimationContext.runAnimationGroup { ctx in
    ctx.duration = 0.34
    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1.0)
    ctx.allowsImplicitAnimation = true
    tileHost.animator().frame = destinationFrame
}
```
`VideoTileView` renders on every display-link tick during the animation (`setPacing(.interacting)`
while `isAnimatingGeometry`), updating `drawableSize` each tick inside `withoutCAActions`. This is
the same code path as live resize, so it is already flicker-free.

**Across windows (second display, separate fullscreen window, PiP).** A layer cannot be animated
between windows. Therefore:

1. `let still = try tile.captureImage(includeOverlays: false, scale: nil)` — the exact displayed frame.
2. `VigilUI` shows a SwiftUI `Image(still)` with `matchedGeometryEffect` in an overlay window and
   animates it to the destination (`spring(0.5, 0.7)`, the `expressive` token).
3. The live `VideoTileView` is moved to the destination window while hidden, receives its first
   frame, and only then crossfades in over **80 ms**; the still is removed on completion.
4. If no frame arrives within 400 ms the still stays and the connecting skeleton fades in over it.

`TileRenderState.lastPresentedImageProvider` exists precisely so `VigilUI` can do step 1 without
reaching into Metal.

### 10.6 Context menu

`VideoTileView` overrides `menu(for event: NSEvent) -> NSMenu?` and returns `nil`, letting the
SwiftUI `.contextMenu` attached by `VigilUI` handle right-clicks so the menu inherits the design
system. The required items (order fixed, `VigilUI` owns the strings):

Fullscreen · Open in New Window · — · Snapshot ⌘⇧S · Start/Stop Recording ⌘R · Copy Frame ·
Save Frame As… · — · Main stream / Substream · Aspect: Fit / Fill / Stretch · Digital Zoom: Reset ·
Image Adjustments… · — · Audio: Mute / Solo · — · PTZ: Presets ▸ / Go Home / 3D Positioning ·
— · Show Motion Boxes · Show Timestamp · Show Stats HUD · — · Reconnect · Stream Doctor… ·
Remove From Cell.

### 10.7 Drag and drop

Two payloads, both `Transferable`, both also exposed as `NSPasteboard` types so AppKit drags work:

```swift
public struct TileAssignmentTransfer: Codable, Transferable, Sendable {
    public var sourceCellID: UUID
    public var cameraID: UUID
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .vigilTileAssignment)
    }
}
public struct CameraRefTransfer: Codable, Transferable, Sendable {
    public var cameraID: UUID
    public var displayName: String
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .vigilCameraRef)
        ProxyRepresentation(exporting: \.displayName)          // so it can drop into text fields
    }
}
public extension UTType {
    static let vigilTileAssignment = UTType(exportedAs: "com.vigil.tile-assignment")
    static let vigilCameraRef      = UTType(exportedAs: "com.vigil.camera-ref")
}
```
Both must be declared in `Info.plist` under `UTExportedTypeDeclarations` (a §19 contract on the
architecture doc).

**The live ghost.** `NSDraggingItem.imageComponentsProvider` returns one
`NSDraggingImageComponent(key: .icon)` whose `contents` is a snapshot taken **at drag start**, scaled
to 60% of the tile size, with the design system's corner radius and a soft shadow baked in, plus a
second component (`key: .label`) carrying the camera-name chip. To make it feel *live* we refresh the
component every 100 ms during the drag by calling
`draggingSession.enumerateDraggingItems(options:for:classes:searchOptions:using:)` and reassigning
`imageComponentsProvider` — AppKit re-renders the dragging image on the next update. Refresh is
throttled to 10 Hz and skipped when `reduceMotion` is on (static ghost).

```swift
override public func mouseDragged(with event: NSEvent) {
    if shouldBeginTileDrag(event) {
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem(for: assignment))
        item.draggingFrame = CGRect(origin: .zero, size: bounds.size).insetBy(dx: 0, dy: 0)
        item.imageComponentsProvider = { [weak self] in self?.dragImageComponents() ?? [] }
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        activeDragSession = session
        return
    }
    …pan or position3D…
}
```

`NSDraggingSource`:

```swift
public func draggingSession(_ s: NSDraggingSession,
                            sourceOperationMaskFor ctx: NSDraggingContext) -> NSDragOperation {
    switch ctx {
    case .withinApplication: return [.move]      // move/swap between cells
    case .outsideApplication: return [.copy]     // a PNG snapshot promise for Finder
    @unknown default: return []
    }
}
```
Dropping outside the app writes a snapshot PNG via `NSFilePromiseProvider` with the file name
`{camera} {yyyy-MM-dd HH.mm.ss}.png` — dragging a tile to the Desktop saves that frame. This is a
deliberate delight feature and costs one offscreen render.

**Drop target.** Each grid cell in `VigilUI` uses `.dropDestination(for:)`; `VideoTileView` also
implements `NSDraggingDestination` for the case where the tile itself is the target (`draggingEntered`
returns `.move` for a tile assignment, `.copy` for a camera ref, `[]` otherwise). Visual feedback is
SwiftUI's: a 2 pt inset accent ring + 6% accent fill, `spring(0.22, 0.86)`; when the target already
holds a camera, a centred `arrow.left.arrow.right` chip announces a swap. `concludeDragOperation`
calls `interactionDelegate?.tile(self, didReceiveDrop:)`; `VigilRender` never mutates the layout.

**Autoscroll** during a drag over the sidebar is AppKit's (`NSView.autoscroll(with:)` in the
sidebar), not ours.

### 10.8 Keyboard PTZ

```swift
override public func keyDown(with event: NSEvent) {
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard !mods.contains(.command), !mods.contains(.option) else { return super.keyDown(with: event) }
    guard let dir = PTZDirection(keyCode: event.keyCode) else { return super.keyDown(with: event) }
    guard !event.isARepeat else { return }                     // one start, not one per repeat
    let speed = mods.contains(.shift) ? options.ptzFastSpeed : options.ptzNormalSpeed   // 7 : 4
    heldDirections.insert(dir)
    interactionDelegate?.tile(self, didBeginPTZ: dir, speed: speed)
}

override public func keyUp(with event: NSEvent) {
    guard let dir = PTZDirection(keyCode: event.keyCode), heldDirections.contains(dir) else {
        return super.keyUp(with: event)
    }
    heldDirections.remove(dir)
    interactionDelegate?.tile(self, didEndPTZ: dir)
}
```
Key codes: left 123, right 124, down 125, up 126, `[` 33, `]` 30, `+`/`=` 24, `-` 27, `0` 29.
Diagonals: two held arrows combine into `.upLeft` etc. and re-issue a single continuous command.
Safety net for the dropped-`keyUp` case (it happens when the window loses focus mid-hold):
`resignFirstResponder`, `windowDidResignKey`, `flagsChanged` with an empty set, and a 3 s watchdog all
call `endAllPTZ()`. A camera left panning because a key-up was missed is unacceptable.

### 10.9 Cursors

| Condition | Cursor |
|---|---|
| `zoom == 1`, no mode | `NSCursor.arrow` |
| `zoom > 1`, hovering | `NSCursor.openHand` |
| Panning (mouse down) | `NSCursor.closedHand` |
| `mode == .position3D` | `NSCursor.crosshair` |
| `mode == .privacyEdit`, over a handle | `NSCursor.pointingHand` |
| Over a mosaic splitter (custom layout) | `NSCursor.resizeLeftRight` / `.resizeUpDown` |
| Click-to-move PTZ armed, near an edge | custom 24×24 directional arrow images (`ptz-cursor-*`) |
| Drag in progress | AppKit's drag cursor (do not override) |
| Cinema/fullscreen, idle 2.5 s | `NSCursor.setHiddenUntilMouseMoves(true)` |

Custom cursors are `NSCursor(image:hotSpot:)` built from SF Symbols at render time
(`NSImage(systemSymbolName:)` + `withSymbolConfiguration`), cached, and rebuilt on appearance change.
`NSCursor.hide()`/`unhide()` calls must be balanced; we use only
`setHiddenUntilMouseMoves(_:)` to avoid unbalanced-hide bugs.

---

## 11. Video-wall compositing

### 11.1 The decision

> **One `CAMetalLayer` per tile for `N ≤ K` tiles (K = 6). For `N > K`, a single `CAMetalLayer` for
> the whole stage with atlas compositing.** Hysteresis: promote to atlas at `N ≥ 7`, demote to
> per-tile at `N ≤ 5`.

### 11.2 Why

| Cost, per rendered frame | Per-tile layers (N tiles) | Single atlas layer |
|---|---|---|
| Command buffers | N | 1 |
| GPU submit overhead @ ~25 µs | N × 25 µs | 25 µs |
| CPU encode | N × ~35 µs | ~15 µs + N × ~8 µs |
| `nextDrawable()` calls (each can block) | N | 1 |
| Drawable IOSurface memory (960×540, 3 deep) | N × 6.2 MB | 24.9 MB (2560×1440 × 4 B × 3) |
| Present / compositor layers | N | 1 |
| Independent per-tile pacing | **yes** | no (one present serves all) |
| ASBDL backend possible | **yes** | no |
| Per-tile `NSView` hit-testing, cursors | **free** | needs a rect lookup |
| Per-tile SwiftUI overlay layers | N stacks | N stacks (unchanged) |

At `N = 6`: `6 × (25 + 35) µs = 0.36 ms` of pure overhead per frame; at 120 Hz that is 4.3% of the
frame budget and 43 ms/s of main-thread time — acceptable. At `N = 16` it becomes `0.96 ms`
(11.5% of a 120 Hz frame) plus 16 drawable acquisitions and 99 MB of drawable memory, and the
main-thread cost approaches 115 ms/s. The atlas collapses that to ~0.15 ms and one drawable set.

Per-tile layers win below the crossover because they preserve two properties we care about a lot in
small layouts: (a) a 25 fps camera presents at 25 Hz without waking the other tiles, and (b) the
cheap `AVSampleBufferDisplayLayer` backend stays available for unzoomed, unadjusted tiles — which is
the single biggest CPU/GPU saving we have for the 1-up and 2×2 layouts that users spend most of their
time in.

`K = 6` and not 4 or 9: 4 would push the common 1+5 layout (six tiles) into the atlas and lose ASBDL
for the big focused tile; 9 would put 3×3 at 0.54 ms of overhead per frame plus 56 MB of drawables
with no compensating benefit, since at 3×3 nobody is watching individual tile pacing.

**Consequence that other modules must respect:** atlas mode requires pixel access, so it forces the
Metal backend, which forces `VigilVideo` to use an explicit `VTDecompressionSession` producing
`CVPixelBuffer`s for every tile in that layout. Layouts of 7+ tiles therefore never use the
`AVSampleBufferDisplayLayer` fast path. (§19)

### 11.3 Atlas mechanics

```swift
@MainActor
public final class WallCompositorView: NSView {
    public func setLayout(_ cells: [WallCell])              // cell = id, frame in view points, tile
    public func tile(at point: CGPoint) -> WallCell.ID?     // hit testing for interaction routing
    public func renderer(for cellID: WallCell.ID) -> TileRenderer
}
```

* **One persistent atlas texture**, not the drawable, is the render target:
  `MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H,
  mipmapped: false)` with `usage = [.renderTarget, .shaderRead]`, `storageMode = .private`, where
  `(W, H)` is the view's size in drawable pixels, rounded up to a multiple of 16 and clamped to
  `maxTextureDimension` (16384). Recreated on bounds/scale change only.
* Each tile draws into the atlas with `setViewport(MTLViewport(originX:originY:width:height:znear:0,
  zfar:1))` and `setScissorRect(MTLScissorRect(...))` set to its cell rect in atlas pixels. The
  viewport makes NDC tile-local so §2.3's matrix math is unchanged, and the scissor clips the zoomed
  quad to the cell — **both are required**; a viewport alone does not clip.
* Load action for the atlas pass is `.load` (contents persist across frames), so **only dirty tiles
  are re-drawn**. A cell is dirty when it has a new frame, a transform/adjustment change, a mask
  change, or its rect moved.
* Because triple-buffered drawables rotate, the previous contents of *this* drawable are 3 frames
  stale. We therefore blit from the atlas to the drawable, tracking dirt per drawable slot:

```swift
// 3 slots, one per in-flight drawable. Union of everything that changed since the slot was last used.
private var pendingDirty: [Set<WallCell.ID>] = [[], [], []]

func present(dirty: Set<WallCell.ID>, slot: Int, drawable: CAMetalDrawable, blit: MTLBlitCommandEncoder) {
    for i in pendingDirty.indices { pendingDirty[i].formUnion(dirty) }
    let toCopy = pendingDirty[slot]
    pendingDirty[slot].removeAll()
    if toCopy.count >= cells.count / 2 {          // more than half dirty: one full-surface blit
        blit.copy(from: atlas, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: atlas.width, height: atlas.height, depth: 1),
                  to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    } else {
        for id in toCopy { blitRect(cellRectInPixels(id), blit: blit) }   // partial copies
    }
}
```
  On atlas recreation (resize, scale change) all three slots are marked fully dirty.
* **`framebufferOnly` must be `true`** on the layer; we only ever write the drawable via the blit.
* Rounded corners in atlas mode are drawn per cell by the same shader path (the corner SDF uses the
  *viewport* size, which the uniforms already carry as `viewportSizePx`).
* Interaction routing: `WallCompositorView` is one `NSView`, so it implements `hitTestCell(_:)` and
  forwards mouse/keyboard events to the per-cell `TileRenderer`'s interaction state. Cursor rects are
  per cell via multiple `addCursorRect` calls. Focus is a cell index, not a view.

### 11.4 How we hold 120 Hz with 16 tiles

The honest answer is that we do not render 120 times a second — we render only when something
changed, and we make every change cheap.

1. **Content-rate rendering.** 16 substreams at 12–15 fps effective (Hikvision substreams are
   typically `640×360@12` or `704×576@12`) produce 190–240 new frames per second in total. Frames
   arriving within the same display refresh are coalesced into one atlas pass, so the wall renders
   **at most 120 times/s and typically 60–90 times/s**, each pass touching only the 1–3 cells that
   actually changed.
2. **Per-pass cost at 16 dirty cells (worst case).** Fragment work: the atlas is 2560×1440 = 3.69 Mpx;
   the tile shader is ~38 ALU ops + 3 texture fetches per fragment ⇒ ~140 MFLOP and 11 M fetches per
   full pass. An M1 (2.6 TFLOP/s, 82 Gtexel/s) does that in **~0.20 ms**. Bandwidth: read
   `16 × 640×360 × 1.5 B = 5.5 MB`, write `3.69 Mpx × 4 B = 14.8 MB`, blit another 29.5 MB read+write
   ⇒ ~50 MB per full pass. At a *sustained* 120 Hz that is 6 GB/s against ~68 GB/s of unified memory
   bandwidth on an M1 — 9%. In practice the dirty-rect path moves a fraction of that.
3. **Overlays never cost a Metal frame.** Every animating overlay (live dot, motion-box fades, hover
   chrome, toasts) is a CA/SwiftUI layer animation running on the compositor. A 2 s breathing dot on
   16 tiles costs the render loop exactly zero.
4. **Interaction is scoped.** Zoom/pan/inertia marks **one** cell dirty. `preferredFrameRateRange`
   goes to 120 only while an interaction or animation is in flight.
5. **Decode, not render, is the real budget.** 16 × 640×360@12 fps ≈ 44 Mpx/s of decode, well inside
   one hardware decode block; `VigilCore`'s admission policy (tile pixel size → main/sub/JPEG/paused)
   keeps it there. `VigilRender` contributes the input to that policy by publishing
   `TileRenderState.pixelSize` and visibility.
6. **Measured budget assertion.** `WallPerformanceTests` renders a synthetic 16-tile atlas for 600
   frames offscreen and asserts mean GPU time per pass < 0.45 ms and p99 < 0.9 ms on Apple silicon.

---

## 12. Multiple displays, backing scale, EDR headroom, pacing

| Event | Notification / override | Action |
|---|---|---|
| Window moved to another display | `NSWindow.didChangeScreenNotification` | re-read `backingScaleFactor`, update `contentsScale` + `drawableSize`, re-evaluate EDR, re-read the screen's max frame rate; **the `CADisplayLink` retargets itself** (macOS 14 `NSView.displayLink`) |
| Backing scale changed in place (display swapped, resolution change) | `viewDidChangeBackingProperties()`, `NSWindow.didChangeBackingPropertiesNotification` (`NSBackingPropertyOldScaleFactorKey`) | same as above, plus force a synchronous render so no blurry stretched frame is shown |
| Screen configuration changed | `NSApplication.didChangeScreenParametersNotification` | re-read EDR headroom on all tiles, flush the texture cache, recreate the atlas |
| EDR headroom ramped | 1 Hz poll while EDR active | update `edrScale` clamp |
| Display sleep / wake | `NSWorkspace.screensDidSleepNotification` / `…DidWake` | pause/resume the display link; on wake force one render from the retained last frame |
| App occluded | `NSWindow.didChangeOcclusionStateNotification` | pause the display link, tell the delegate (decode pause) |
| Window straddles two displays | — | AppKit reports one `backingScaleFactor` for the window; the half on the other display is scaled by the compositor. Accepted; documented; not worth a per-display layer |

Extra rules:

* A tile on a 60 Hz display and a tile on a 120 Hz display get **separate** display links (they are
  per view), so each paces to its own screen correctly. This is why we do not use one app-wide timer.
* `NSScreen.maximumFramesPerSecond` sets the `maximum` of `CAFrameRateRange`; never request 120 on a
  60 Hz panel (CA clamps, but the log noise is unhelpful).
* The video wall on a second display is a separate `NSWindow` with its own
  `WallCompositorView`, its own atlas texture and its own display link. The shared
  `RenderContext` (device, queue, texture cache, pipelines) is reused.
* `CAMetalLayer.colorspace` is a property of the layer, not the screen; when a tile moves to a
  display with a different profile, CA converts. We do **not** retag per display.

---

## 13. `AVSampleBufferDisplayLayer` path and the Metal-failure fallback

### 13.1 When ASBDL is used

| Condition | Backend |
|---|---|
| `RenderContext.shared == nil` (Metal unavailable) | **ASBDL, always** |
| `N ≤ K` tiles, `zoom == 1`, `adjustments.isIdentity`, no privacy mask, `fieldOrder == .progressive`, no Metal overlays, SDR | **ASBDL** (preferred: cheapest path) |
| anything else | **Metal** |

ASBDL's advantage is that VideoToolbox decodes straight into the layer with no `CVPixelBuffer` hop and
no render pass at all: measured ~35% less GPU time and ~8% less CPU per 1080p tile than our Metal
path. It is the right default for 1-up and 2×2.

### 13.2 ASBDL configuration

> ## ⚠️ §13.2 is wrong on four counts — corrected during the step-4 review
>
> Verified against the real `AVSampleBufferDisplayLayer.h` and `AVSampleBufferVideoRenderer.h`
> headers and Apple's Swift API index, not from memory. Do not follow this section as written.
>
> 1. **The notification names are not members of the layer.** They are declared `NSString *const`,
>    not `NSNotificationName`, so they import as static members of `NSNotification.Name` —
>    `NSNotification.Name.AVSampleBufferDisplayLayerFailedToDecode` and
>    `…RequiresFlushToResumeDecodingDidChange`. The nested spellings this section uses name nothing.
> 2. **The error key is a global**, `AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey`,
>    not a nested member.
> 3. **Observe the renderer, not the layer.** The header says outright: *"Do not use
>    AVSampleBufferDisplayLayer's AVQueuedSampleBufferRendering functions when using
>    sampleBufferRenderer"*, and `layer.requiresFlushToResumeDecoding` carries
>    `API_DEPRECATED(macos(11.0, 15.0))`. Observing the layer while enqueuing on the renderer means
>    recovery never fires and the picture freezes on its last frame — a symptom indistinguishable
>    from a network stall. Use `AVSampleBufferVideoRenderer`'s
>    `requiresFlushToResumeDecodingDidChangeNotification`, `didFailToDecodeNotification` and
>    `didFailToDecodeNotificationErrorKey`, all macOS 14.0+ and none deprecated.
> 4. **`preventsAutomaticBackgroundingDuringVideoPlayback` does not exist on macOS.** It is
>    `API_AVAILABLE(visionos(1.0)) API_UNAVAILABLE(macos, …)`. Setting it, as this section instructs,
>    would not compile. `preventsDisplaySleepDuringVideoPlayback` is real and is macOS 10.15+, not
>    11.0 as stated.


```swift
let l = AVSampleBufferDisplayLayer()
l.videoGravity = .resizeAspect                       // .resizeAspectFill / .resize per options
l.isOpaque = true
l.backgroundColor = NSColor.black.cgColor
l.preventsDisplaySleepDuringVideoPlayback = true
l.preventsAutomaticBackgroundingDuringVideoPlayback = true
l.cornerRadius = options.cornerRadiusPt
l.cornerCurve = .continuous
l.masksToBounds = options.cornerRadiusPt > 0
```
* **Live:** no `controlTimebase`; samples carry the `DisplayImmediately` attachment (`VigilVideo`
  sets it). Enqueue via `l.sampleBufferRenderer.enqueue(_:)` on macOS 14+
  (`AVSampleBufferVideoRenderer`), which is the supported surface; the deprecated
  `l.enqueue(_:)` is not used.
* **Recorded playback:** a `CMTimebase` created with `CMTimebaseCreateWithSourceClock` on
  `CMClockGetHostTimeClock()`, set as `sampleBufferRenderer.timebase`, rate driven by the transport
  controls.
* **Flush discipline:** `sampleBufferRenderer.flush()` on stream restart, seek, and format change;
  `flushAndRemoveImage()` **only** when we deliberately want black (camera removed from the cell) —
  never on reconnect, because keeping the last frame dimmed is a specified offline state.
* Observe `AVSampleBufferDisplayLayer.requiresFlushToResumeDecodingDidChangeNotification` and
  `.failedToDecodeNotification`; on `requiresFlushToResumeDecoding == true` flush and ask
  `VigilVideo` for a keyframe. On `failedToDecode` with
  `AVSampleBufferDisplayLayer.failedToDecodeNotificationErrorKey`, report through the delegate and
  let the reconnect state machine decide.
* `isReadyForMoreMediaData` backpressure is `VigilVideo`'s concern; `VigilRender` only exposes
  `var isReadyForMoreMediaData: Bool` on the backend.

### 13.3 Live backend switching without a flash

Triggers: zoom crosses 1.0, adjustments become non-identity (or return to identity for 2 s), a
privacy mask appears, deinterlace turns on, the layout crosses `K`, or Metal reports a fatal error.

Sequence (both directions):

1. Capture the current frame as a `CGImage` (Metal: offscreen pass; ASBDL: the last
   `CVPixelBuffer` we retained, or `nil` if none).
2. Insert a **still layer** (`CALayer` with `contents = cgImage`, `contentsGravity` matching
   `videoGravity`) above the video layer, opacity 1, inside `withoutCAActions`.
3. Tear down the old backing layer, install the new one (`wantsLayer` dance: set
   `backendPreference`, then `layer = makeBackingLayer(); wantsLayer = true`).
4. Wait for the first present on the new backend (or 400 ms, whichever comes first).
5. Fade the still layer to 0 over **80 ms** (`easeOut`), then remove it.

`stats.backendSwitches` counts these; more than 4 in 10 s triggers a 5 s hysteresis lock that keeps
Metal (the superset) to stop oscillation.

### 13.4 What the fallback loses, and what it substitutes

| Feature | Metal | ASBDL fallback |
|---|---|---|
| Digital zoom | shader, bicubic ≥ 2× | `layer.setAffineTransform(CGAffineTransform)` on the ASBDL inside a `masksToBounds` superlayer — CA scales for free with bilinear quality; pan clamp math is identical |
| Brightness/contrast/gamma/saturation/sharpen/night | yes | **unavailable** (`RenderCapabilities.supportsImageAdjustments == false`); `VigilUI` disables the Image adjustments group with an explanatory tooltip |
| Deinterlace | bob/blend | unavailable; combing is visible on analog channels. We instead ask `VigilCore` to prefer a progressive substream when one exists |
| Privacy mask | solid/mosaic/blur | opaque `CALayer` rectangles only (`supportsPrivacyBlur == false`) |
| Motion boxes | SwiftUI or Metal | SwiftUI only |
| Video wall > 6 tiles | atlas | per-tile ASBDL layers, no atlas; the wall is capped at 16 with a warning banner |
| Snapshot of the exact displayed frame | offscreen render | `VTCreateCGImageFromCVPixelBuffer` on the retained last buffer; overlays composited in CoreGraphics |
| Rounded corners | in-shader SDF, opaque | `layer.cornerRadius`, non-opaque blend |

The fallback is reachable in practice (some VMs, `MTLCreateSystemDefaultDevice()` returning `nil`
under screen sharing on old Intel Macs, and a GPU reset storm) so it is a supported configuration,
tested by `FallbackBackendTests` with an injected `RenderContext` factory that returns `nil`.

---

## 14. Full public Swift API

```swift
// ============================================================ VigilRender/Public

// MARK: - Options and adjustments

public struct ImageAdjustments: Sendable, Codable, Equatable {
    public var brightness: Double = 0          // −0.5…0.5
    public var contrast: Double = 1            // 0.5…2
    public var saturation: Double = 1          // 0…2
    public var gamma: Double = 1               // 0.5…2.5
    public var sharpen: Double = 0             // 0…1.5
    public var nightBoost: Double = 0          // 0…1
    public var deinterlace: DeinterlaceMode = .auto
    public static let identity = ImageAdjustments()
    public var isIdentity: Bool { get }
    public func clamped() -> ImageAdjustments
}

public enum DeinterlaceMode: UInt8, Sendable, Codable, CaseIterable {
    case auto, none, bob, blend
    var rawShaderMode: UInt32 { get }
}

public struct TileRenderOptions: Sendable, Equatable {
    public var gravity: VideoGravity = .fit
    public var adjustments: ImageAdjustments = .identity
    public var backendPreference: BackendPreference = .automatic
    public var maxZoom: CGFloat = 8
    public var bicubicZoomThreshold: CGFloat = 2
    public var cornerRadiusPt: CGFloat = 10
    public var cornerRadii: simd_float4 = .init(repeating: 10)   // TL, TR, BR, BL
    public var cornerColor: CGColor = .black
    public var ptzNormalSpeed: Int = 4          // 1…7, ISAPI continuous speed
    public var ptzFastSpeed: Int = 7
    public var showsDebugHUD = false
    public var latencyPreset: LatencyPreset = .balanced   // .low → 2 drawables, no bicubic
    public enum BackendPreference: Sendable, Equatable { case automatic, forceMetal, forceSampleBuffer }
    public enum LatencyPreset: Sendable, Equatable { case low, balanced, quality }
}

public enum VideoGravity: String, Sendable, Codable, CaseIterable {
    case fit, fill, stretch
    var avGravity: AVLayerVideoGravity { get }
}

public enum TileBackend: String, Sendable, Equatable { case metal, sampleBufferLayer }

public enum TileInteractionMode: Sendable, Equatable {
    case normal            // zoom/pan/drag
    case position3D        // draw the PTZ rectangle
    case privacyEdit       // manipulate mask polygons
    case clickToCenter     // click sends a centre-on-point PTZ
    case inert             // sidebar thumbnails: no input at all
}

// MARK: - Geometry

public struct TileGeometry: Sendable, Equatable { /* §2.1 */ }
public struct TileTransform: Sendable, Equatable { /* §2.3 */ }
public struct TileCoordinateMap: Sendable { /* §2.5 */ }
public enum NormalizedOrigin: String, Sendable, Codable { case topLeft, bottomLeft }
public func contentRect(cameraRect: CGRect, origin: NormalizedOrigin) -> CGRect
public func contentPolygon(cameraPolygon: [CGPoint], origin: NormalizedOrigin) -> [CGPoint]

// MARK: - Overlay inputs (data in, no behaviour)

public struct MotionBox: Sendable, Equatable, Identifiable {
    public var id: Int
    public var cameraRect: CGRect            // 0…1000 space, as delivered by ISAPI
    public var kind: Kind                    // .motion, .lineCrossing, .intrusion, .tamper, .face
    public var confidence: Double?
    public var eventTime: Date
    public enum Kind: Sendable, Equatable { case motion, lineCrossing, intrusion, tamper, face }
}
public struct PrivacyRegion: Sendable, Equatable, Codable, Identifiable { /* §9.5 */ }
public struct PrivacyMaskSet: Sendable, Equatable, Codable {
    public var regions: [PrivacyRegion]
    public var origin: NormalizedOrigin
    public var isEnabled: Bool
}

// MARK: - Context

@MainActor public final class RenderContext {
    public static let shared: RenderContext?
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let capabilities: RenderCapabilities
    public static func makeForTesting(device: MTLDevice) -> RenderContext?
    public func flushCaches()
    public func purgePipelineCache()
}
public struct RenderCapabilities: Sendable, Equatable { /* §4.5 */ }

// MARK: - The tile

@MainActor public final class VideoTileView: NSView, VideoSink {
    public init(cameraID: UUID, options: TileRenderOptions, logger: any LoggerProtocol)
    public var options: TileRenderOptions { get set }
    public var interactionMode: TileInteractionMode { get set }
    public var motionBoxes: [MotionBox] { get set }        // ≤48 kept; drives Metal or SwiftUI path
    public var privacyMask: PrivacyMaskSet { get set }
    public var regionOrigin: NormalizedOrigin { get set }
    public private(set) var backend: TileBackend
    public let state: TileRenderState
    public weak var interactionDelegate: (any TileInteractionDelegate)?

    // Frame input (VideoSink)
    public nonisolated func enqueue(_ frame: VideoFrame)
    public nonisolated func enqueue(_ sampleBuffer: CMSampleBuffer)     // ASBDL fast path
    public nonisolated func streamDidReset()
    public nonisolated func streamDidEnd(reason: StreamEndReason)

    // Transform control
    public func setTransform(_ t: TileTransform, animated: Bool)
    public func zoom(to zoom: CGFloat, anchorViewPoint: CGPoint, animated: Bool)
    public func resetZoom(animated: Bool)
    public func cancelInertia()

    // Lifecycle
    public func pause()                     // display link paused, last frame retained
    public func resume()
    public func clear(showingBlack: Bool)   // camera removed from the cell

    // Capture
    public func captureImage(includeOverlays: Bool, scale: CGFloat?) throws -> CGImage
    public func captureLastPixelBuffer() -> CVPixelBuffer?
}

@MainActor @Observable public final class TileRenderState { /* §9.4 */ }

public struct RenderStats: Sendable, Equatable {
    public var renderedFrames: UInt64
    public var presentedFrames: UInt64
    public var droppedByReplacement: UInt64
    public var drawableMisses: UInt64
    public var backendSwitches: UInt32
    public var gpuTimeMsMean: Double
    public var gpuTimeMsP99: Double
    public var presentIntervalMsP50: Double
    public var presentIntervalMsP99: Double
    public var estimatedGlassToGlassMs: Double?     // captureHostTime → present, when RTCP is available
    public var lastError: RenderError?
}

// MARK: - SwiftUI

public struct VideoTile: NSViewRepresentable {
    public init(cameraID: UUID,
                frames: FrameStreamHandle,
                options: TileRenderOptions = .init(),
                mode: TileInteractionMode = .normal,
                motionBoxes: [MotionBox] = [],
                privacyMask: PrivacyMaskSet = .disabled,
                delegate: (any TileInteractionDelegate)?,
                state: Binding<TileRenderState?>)
    public func makeNSView(context: Context) -> VideoTileView
    public func updateNSView(_ view: VideoTileView, context: Context)
    public static func dismantleNSView(_ view: VideoTileView, coordinator: ())
}

/// Opaque handle that lets `VigilCore` attach a stream's frames to whichever tile view SwiftUI
/// happens to create, without `VigilRender` importing `VigilCore`.
public final class FrameStreamHandle: @unchecked Sendable {
    public init()
    public func attach(_ sink: any VideoSink)
    public func detach()
}

// MARK: - Wall

@MainActor public final class WallCompositorView: NSView { /* §11.3 */ }
public struct WallCell: Sendable, Identifiable, Equatable {
    public var id: UUID
    public var frame: CGRect            // view points
    public var cameraID: UUID?
    public var options: TileRenderOptions
    public var cornerRadii: simd_float4
}
public struct VideoWall: NSViewRepresentable { /* SwiftUI wrapper over WallCompositorView */ }

// MARK: - Delegate (everything that leaves the renderer)

@MainActor public protocol TileInteractionDelegate: AnyObject {
    func tile(_ tile: VideoTileView, didChangePixelSize size: CGSize, isVisible: Bool)
    func tile(_ tile: VideoTileView, didChangeTransform transform: TileTransform)
    func tileDidRequestFullscreenToggle(_ tile: VideoTileView)
    func tileDidRequestZoomReset(_ tile: VideoTileView)
    func tile(_ tile: VideoTileView, didBeginPTZ direction: PTZDirection, speed: Int)
    func tile(_ tile: VideoTileView, didEndPTZ direction: PTZDirection)
    func tile(_ tile: VideoTileView, didRequestPosition3D gesture: Position3DGesture)
    func tile(_ tile: VideoTileView, didRequestCenterOn contentPoint: CGPoint)
    func tile(_ tile: VideoTileView, didReceiveDrop drop: TileDrop) -> Bool
    func tile(_ tile: VideoTileView, willBeginDrag assignment: TileAssignmentTransfer)
    func tile(_ tile: VideoTileView, didToggleMute isMuted: Bool)
    func tile(_ tile: VideoTileView, didMovePrivacyHandle region: Int, vertex: Int, to point: CGPoint)
    func tile(_ tile: VideoTileView, didEncounter error: RenderError)
    func tileDidBecomeFocused(_ tile: VideoTileView)
}
public enum PTZDirection: Sendable, Equatable, CaseIterable {
    case up, down, left, right, upLeft, upRight, downLeft, downRight, zoomIn, zoomOut
    init?(keyCode: UInt16)
    public var isaptiltPan: (pan: Int, tilt: Int) { get }   // −1/0/+1 pair for ISAPI continuous
}
public struct Position3DGesture: Sendable, Equatable { /* §9.7 */ }
public enum TileDrop: Sendable, Equatable {
    case cameraRef(CameraRefTransfer)
    case tileAssignment(TileAssignmentTransfer)
}

// MARK: - Errors

public enum RenderError: Error, Sendable, Equatable, CustomStringConvertible {
    case metalUnavailable
    case shaderCompilationFailed(String)
    case pipelineCreationFailed(String)
    case textureCacheCreationFailed(OSStatus)
    case textureCreationFailed
    case drawableUnavailable
    case commandBufferFailed(code: Int, description: String)
    case deviceRemoved
    case unsupportedPixelFormat(OSType)
    case captureFailed(String)
    case atlasTooLarge(requested: CGSize, max: Int)
    public var isRecoverable: Bool { get }
    public var requiresBackendFallback: Bool { get }
}
```

---

## 15. Performance budgets and instrumentation

### 15.1 Budgets (asserted by tests on Apple silicon, M1 baseline)

| Scenario | GPU per present | CPU (main) per present | Drawable memory | Notes |
|---|---|---|---|---|
| 1 tile, 1080p, ASBDL | ~0.00 ms (no pass) | ~0.02 ms | CA-managed | the cheapest path |
| 1 tile, 1080p, Metal, no effects | 0.06 ms | 0.035 ms | 24.9 MB | 1920×1080 ×4 B ×3 |
| 1 tile, 1080p, Metal, zoom 4 + bicubic | 0.14 ms | 0.035 ms | 24.9 MB | 16-tap luma |
| 1 tile, 4K, Metal, downsample to 1080p | 0.19 ms | 0.04 ms | 24.9 MB | P0 one halving |
| 2×2, per-tile layers, 720p subs | 0.24 ms total | 0.14 ms | 4 × 3.5 MB | |
| 4×4, atlas, 640×360 subs, all dirty | 0.42 ms | 0.15 ms | 24.9 MB | §11.4 |
| 4×4, atlas, 2 cells dirty | 0.08 ms | 0.05 ms | 24.9 MB | the common case |
| Sidebar micro-thumbnails, 16 × 96×54, atlas | 0.04 ms | 0.06 ms | 1.2 MB | `mode == .inert` |

Whole-app targets that `VigilRender` must not break: **< 250 ms glass-to-glass on LAN** (render
contributes ≤ 1 display interval, 8.3 ms, plus ≤ 1 ms of GPU) and **16 × 1080p substreams under ~35%
CPU**, of which the renderer's share is ≤ 4%.

### 15.2 Signposts and logs

```swift
let renderLog = Logger(subsystem: "com.vigil.render", category: "render")
let signposter = OSSignposter(subsystem: "com.vigil.render", category: .pointsOfInterest)
```
| Signpost | Type | Interval covers |
|---|---|---|
| `tile.render` | interval | encode + commit, `cameraID` + `dirtyCells` metadata |
| `tile.gpu` | interval | emitted from `addCompletedHandler` using `gpuStartTime`/`gpuEndTime` |
| `tile.present` | event | at `drawable.present()`; carries `targetTimestamp` delta |
| `tile.backendSwitch` | event | old → new backend and the reason |
| `wall.atlasRebuild` | event | new atlas size |
| `frame.dropped` | event | `droppedByReplacement` increments, rate-limited to 1 Hz |

OSLog categories: `render` (lifecycle, errors), `render.pacing` (`.debug`, off by default),
`render.color` (colour description decisions, once per stream), `render.input` (`.debug`).
Never log at `.info` or above inside the display-link callback — one line per frame at 120 Hz will
itself cost measurable CPU. The renderer takes a `LoggerProtocol` from `VigilProtocols` in its
initialiser so headless tests can capture logs.

### 15.3 The debug HUD (`options.showsDebugHUD`)

A SwiftUI overlay, updated at 4 Hz, showing: resolution + SAR + crop, codec, backend, colour
description (`BT.709 / video / left / 8-bit`), pipeline variant key, zoom + translation, drawable
size + scale, present interval p50/p99, GPU ms mean/p99, dropped/replaced counts, drawable misses,
decode queue depth (from `VigilCore`), estimated glass-to-glass, EDR headroom, and a
`hwDecode: yes/no` flag. Toggled by `⌥⌘D`. It exists because "is hardware decode actually on" and
"where did my 400 ms go" are the two questions that otherwise cost hours.

---

## 16. Error taxonomy and recovery

| Error | Detection | Recovery |
|---|---|---|
| `metalUnavailable` | `MTLCreateSystemDefaultDevice() == nil` | whole app takes the ASBDL path; `RenderCapabilities` reflects it; a one-time non-blocking notice in Settings → Advanced |
| `shaderCompilationFailed` | `makeLibrary(source:)` throws | log the full compiler diagnostic at `.fault`, delete the binary archive, retry once with `fastMathEnabled = false`, then fall back to ASBDL |
| `pipelineCreationFailed` | `makeRenderPipelineState` throws | drop the offending feature (bicubic → bilinear, night → off) and retry with a simpler `PipelineKey`; if the base variant fails, fall back to ASBDL |
| `textureCacheCreationFailed` | `CVMetalTextureCacheCreate != kCVReturnSuccess` | fall back to ASBDL (this indicates a broken IOSurface path) |
| `textureCreationFailed` | `CVMetalTextureCacheCreateTextureFromImage` fails | skip the frame, count it, flush the cache; 8 consecutive failures → recreate the cache; 24 → ASBDL |
| `drawableUnavailable` | `nextDrawable()` returns `nil` (1 s timeout) | skip the frame, `stats.drawableMisses += 1`; > 10 in 2 s → recreate the layer |
| `commandBufferFailed` | `commandBuffer.status == .error` in the completion handler | inspect `MTLCommandBufferError`: `.outOfMemory` → drop to `.bgra8Unorm`, disable EDR, shrink the atlas; `.timeout`/`.internal` → recreate pipelines; `.notPermitted`/`.accessRevoked` (screen lock, fast user switch) → pause until `NSWorkspace.sessionDidBecomeActiveNotification` |
| `deviceRemoved` | `MTLCommandBufferError.deviceRemoved`, or `MTLCopyAllDevices` change | rebuild `RenderContext` on the new default device, recreate every layer's `device`, replay from the last retained frame |
| `unsupportedPixelFormat` | `CVPixelBufferGetPixelFormatType` not in `{420v, 420f, x420, xf20}` | log once with the FourCC, show the "unsupported format" tile state, ask `VigilCore` to renegotiate the stream |
| `atlasTooLarge` | wall bigger than `maxTextureDimension` | split the wall into two atlases along the longer axis (only reachable above ~16 K px) |
| Non-IOSurface pixel buffer | `CVPixelBufferGetIOSurface == nil` | CPU upload path: `CVPixelBufferLockBaseAddress(.readOnly)` + `MTLTexture.replace(region:…)`, ~1.4 ms per 1080p frame; log at `.error` because it is a `VigilVideo` bug |
| GPU hang / recovery storm | ≥ 3 `commandBufferFailed` in 5 s | permanent ASBDL for the session, one user-visible notice |

Every error path is exercised by `RenderErrorInjectionTests` via a `FaultInjector` seam on
`RenderContext` (`makeForTesting`), not by mocking Metal.

---

## 17. Visual-correctness test checklist and fixtures

All visual tests run **headless** with an offscreen `MTLTexture` target — no window, no display
required — so they work on a Mac CI runner. Only §17.3 needs an `NSWindow`. None of these run on
Linux; `VigilRenderTests` is excluded from the Linux target subset.

### 17.1 Fixtures

```swift
public enum RenderFixture {
    /// Deterministic YCbCr biplanar buffer generator. No AVFoundation, no files.
    public static func makeBuffer(width: Int, height: Int, bitDepth: Int,
                                  range: ColorInfo.Range, pattern: Pattern) -> CVPixelBuffer
    public enum Pattern {
        case colorBars75          // EBU 75% bars, BT.709
        case colorBars100
        case pluge                // 0/2/4% and 95/100% patches
        case rampLuma             // full-code horizontal ramp
        case checker(px: Int)
        case combing(px: Int)     // alternating-row content: makes interlacing visible
        case markedPadding        // valid picture + magenta padding rows/cols outside cropRect
        case sarGrid              // circles that must stay circular only if SAR is applied
        case pixelProbe([UInt8])  // exact code values at known coordinates
    }
    public static func render(_ buffer: CVPixelBuffer, geometry: FrameGeometry,
                             into size: CGSize, options: TileRenderOptions,
                             transform: TileTransform) throws -> CGImage
}
```
75% bar reference RGB (8-bit sRGB after BT.709 decode), used as the golden expectation:
white `(191,191,191)`, yellow `(191,191,0)`, cyan `(0,191,191)`, green `(0,191,0)`,
magenta `(191,0,191)`, red `(191,0,0)`, blue `(0,0,191)`, black `(0,0,0)`. The fixture generates the
YCbCr from these with the inverse of the §7.2 matrix, so the test is a true round trip.
Tolerance: **ΔE00 < 1.0** per patch, sampled at each patch centre over a 16×16 average.

### 17.2 The checklist (each row is one test, all mandatory)

| # | Test | Assertion |
|---|---|---|
| 1 | `SAR_square` | 1920×1080 SAR 1:1 in 800×600 `.fit` ⇒ content rect `(0,75,800,450)` ±0.5 px |
| 2 | `SAR_pal4CIF` | 704×576 SAR 12:11 ⇒ `displaySize == 768×576`; `sarGrid` circles have aspect 1.00 ±0.01 |
| 3 | `SAR_ntsc4CIF` | 704×480 SAR 10:11 ⇒ `displaySize == 640×480` (rounded) |
| 4 | `SAR_notDoubleApplied` | rendering with SAR ≠ 1 twice through the pipeline gives identical output; `texTransform` contains no SAR term |
| 5 | `Crop_1088to1080` | coded 1920×1088, `cropRect (0,0,1920,1080)`, `markedPadding` ⇒ **zero** magenta pixels in the output (0 of 480 000 sampled) |
| 6 | `Crop_leftOffset` | coded 1920×1088, crop `(8,4,1904,1080)` ⇒ the left 8 columns never sampled; a `pixelProbe` at picture (0,0) reads the value written at coded (8,4) |
| 7 | `Crop_hevcConfWindow` | HEVC 1920×1088 with `conf_win_bottom_offset = 4` behaves identically to #5 |
| 8 | `ColorBars709Video` | ΔE00 < 1.0 for all 8 patches |
| 9 | `ColorBars709Full` | same content tagged full-range differs from video-range by the expected 16/235 expansion; code 16 → 0, code 235 → 255 ±1 |
| 10 | `ColorBars601` | SD content decoded with the BT.601 matrix; using BT.709 instead shifts green by > 3 ΔE00 (proves the matrix is actually selected) |
| 11 | `ColorBars2020_10bit` | ΔE00 < 1.5 with the BT.2020 10-bit limited matrix |
| 12 | `TenBitScale` | 10-bit ramp peak maps to 1.0 ±0.002; a deliberate 64× error is detected |
| 13 | `TenBitPrecision` | ≥ 900 distinct output codes from a 1024-step ramp rendered to `.rgba16Float` |
| 14 | `ChromaSitingLeft` | a vertical red/green edge shows no chroma fringe wider than 1 luma pixel at zoom 4; disabling the siting offset makes the test fail |
| 15 | `Interlaced_bobParity` | `combing` fixture, bob, parity 0 vs 1 differ; each output has no row-alternating high-frequency component (FFT row energy at Nyquist < 2% of DC) |
| 16 | `Interlaced_twoPresents` | one interlaced buffer produces exactly 2 presents with parities `[0,1]` for TFF and `[1,0]` for BFF |
| 17 | `Interlaced_blendMTF` | blend output vertical MTF at Nyquist/2 is 0.5 ±0.05 of the progressive reference |
| 18 | `ZoomAnchorInvariance` | zoom 1→4 at 200 randomized anchors: the content point under the anchor moves < 0.5 px |
| 19 | `ZoomPanClamp` | 10 000 randomized (zoom, pan) states: the output has no pixel of `cornerColor`/black gap inside `fitRect` |
| 20 | `ZoomSnapping` | scrolling back to 1.02 snaps to exactly 1.0 and forces `translation == .zero` |
| 21 | `GravityFitFillStretch` | all three match the §2.2 table exactly |
| 22 | `BicubicSharperThanBilinear` | at zoom 4, bicubic output has ≥ 15% more gradient energy than bilinear on the `checker` fixture, with no overshoot > 4% |
| 23 | `DownsampleAliasing` | 1080p `checker(px:2)` into a 320×180 target: moiré energy with P0 is < 25% of the no-P0 case |
| 24 | `AdjustmentNeutrality` | `ImageAdjustments.identity` output is **bit-identical** to the pipeline variant with all adjustment constants off |
| 25 | `NightBoostMonotonic` | the curve is monotonic over 1024 samples and `f(0)==0`, `f(1)==1` for all `nightBoost ∈ {0,0.25,…,1}` |
| 26 | `SharpenNoChromaShift` | sharpen 1.0 changes luma but leaves Cb/Cr-derived hue within 0.5° |
| 27 | `RoundedCornerAA` | corner alpha profile is monotonic over ~1 px; the layer remains `isOpaque == true`; corner pixels equal `cornerColor` exactly |
| 28 | `PrivacyMosaicSourceLocked` | mosaic block size measured in *source* pixels is constant across zoom 1, 2, 4, 8 |
| 29 | `PrivacyPolygonWinding` | a bottom-left-origin polygon renders identically to the equivalent top-left-origin one |
| 30 | `MotionBoxMapping` | the §9.2 worked values, both origin conventions, at zoom 1/2/4 and both gravities |
| 31 | `MotionBoxOffscreenChevron` | a box outside `visibleContentRect` yields exactly one edge chevron at the correct projected position |
| 32 | `UniformLayout` | shader `sizeof(TileUniforms) == MemoryLayout<TileUniforms>.stride == 288` |
| 33 | `ShaderSourceParity` | `VigilShaderSource.tileShaders` equals the `.metal` file byte-for-byte |
| 34 | `SnapshotMatchesScreen` | `captureImage(includeOverlays: false)` is bit-identical to the on-screen render of the same frame |
| 35 | `SnapshotWithOverlays` | overlay composite is within ΔE00 1.0 of a reference PNG |
| 36 | `BackendSwitchNoBlack` | Metal ⇄ ASBDL in both directions: no captured frame is entirely black; the still layer covers the gap |
| 37 | `FallbackCapabilities` | with an injected `nil` context, `supportsImageAdjustments == false` and zoom still works via the CA transform |
| 38 | `AtlasDirtyRectCorrectness` | 5 000 randomized per-cell updates: dirty-rect atlas output is **bit-identical** to a full redraw |
| 39 | `AtlasScissorClipsZoom` | a zoomed cell never writes a pixel outside its cell rect |
| 40 | `AtlasHysteresis` | 6→7→6→7 cell transitions produce exactly 2 backend/mode changes, not 4 |
| 41 | `EDRScaleClamp` | PQ content with headroom 2.0 produces max component ≤ 2.0; with headroom 1.0 EDR is not enabled at all |
| 42 | `MidStreamResolutionChange` | 1080p → 720p mid-stream: geometry, `texTransform` and `fitRect` update on the first frame; no black frame is presented |
| 43 | `PixelSizeReporting` | `state.pixelSize` equals `bounds × backingScaleFactor` rounded, on 1×, 2× and after a live scale change |

### 17.3 Windowed tests (need an `NSWindow`, run in the test host app)

| # | Test | Assertion |
|---|---|---|
| 44 | `LiveResizeNoFlicker` | 200 randomized resize steps: every step renders exactly once before its present; `drawableSize` always matches `bounds × scale`; no captured frame contains a pixel that is neither video nor `cornerColor` |
| 45 | `ScaleFactorChange` | moving between a 1× and 2× screen updates `contentsScale` within 1 frame; no blurry frame persists for more than 1 present |
| 46 | `DisplayLinkRetarget` | moving to a 60 Hz screen changes the observed present interval to 16.7 ms ±1 ms without recreating the link |
| 47 | `CursorRects` | the §10.9 table, driven by synthetic events |
| 48 | `DragGhostRefresh` | the dragging image component updates at ~10 Hz and stops at drag end |
| 49 | `PTZKeyUpWatchdog` | losing key focus mid-hold delivers `didEndPTZ` within 50 ms |
| 50 | `OcclusionPausesRender` | miniaturising the window stops presents within 2 frames and resumes on deminiaturise showing the retained frame |

---

## 18. File layout and style compliance

```
Sources/VigilRender/
├── RenderContext.swift                 // device, queue, library, caches, capabilities
├── RenderCapabilities.swift
├── RenderError.swift
├── Shaders/
│   ├── VigilTileShaders.metal          // §6.4, compiled by Xcode when available
│   ├── VigilShaderSource.swift         // byte-identical embedded copy for `swift build`
│   ├── TileUniforms.swift              // the Swift mirror + layout self-check
│   ├── PipelineKey.swift
│   └── PipelineCache.swift             // + MTLBinaryArchive persistence
├── Geometry/
│   ├── TileGeometry.swift
│   ├── TileTransform.swift
│   ├── FitRect.swift
│   ├── TileCoordinateMap.swift
│   └── NormalizedRegions.swift         // 0…1000 / 0…255 conversions, both origins
├── Color/
│   ├── ColorConversion.swift           // §7.2 matrices, ranges, siting, sampleScale
│   └── EDRPolicy.swift
├── Frames/
│   ├── LatestFrameBox.swift
│   ├── FramePacer.swift                // display link ownership, field doubling
│   └── FrameStreamHandle.swift
├── Tile/
│   ├── VideoTileView.swift             // the NSView, options, state
│   ├── VideoTileView+Layer.swift       // makeBackingLayer, scale, resize
│   ├── VideoTileView+Render.swift      // encode/present for the Metal backend
│   ├── VideoTileView+Input.swift       // §10 events, gestures, cursors
│   ├── VideoTileView+DragDrop.swift
│   ├── SampleBufferBackend.swift       // §13
│   ├── BackendSwitcher.swift           // still-layer crossfade
│   └── TileRenderState.swift
├── Effects/
│   ├── DownsampleChain.swift           // P0
│   ├── PrivacyMaskPass.swift           // P2
│   └── OverlayRectPass.swift           // P3
├── Wall/
│   ├── WallCompositorView.swift
│   ├── AtlasTarget.swift
│   └── DirtySlotTracker.swift          // §11.3 per-drawable dirty union
├── Interop/
│   ├── VideoTile.swift                 // NSViewRepresentable
│   ├── VideoWall.swift
│   ├── TileInteractionDelegate.swift
│   └── TransferTypes.swift             // UTType + Transferable payloads
├── Snapshot/
│   └── TileSnapshotter.swift           // offscreen render, overlay composite, CGImage
└── Diagnostics/
    ├── RenderStats.swift
    ├── RenderSignposts.swift
    └── DebugHUDModel.swift

Tests/VigilRenderTests/            // macOS only, excluded from the Linux target subset
├── RenderFixture.swift
├── GeometryTests.swift             // #1–#7, #18–#21, #30–#31, #43
├── ColorTests.swift               // #8–#14, #41
├── EffectsTests.swift             // #15–#17, #22–#28
├── AtlasTests.swift               // #38–#40
├── BackendTests.swift             // #36–#37, #42
├── LayoutSelfCheckTests.swift     // #32–#33
├── SnapshotTests.swift            // #34–#35
├── RenderErrorInjectionTests.swift
└── WallPerformanceTests.swift
Tests/VigilRenderUITests/          // #44–#50, needs a window
```

Style compliance (from the architecture doc's repo-wide rules): every file opens with the standard
header; all types `internal` unless listed in §14; no force-unwrap outside tests (every
`makeSamplerState` / `makeCommandBuffer` / `makeFunction` result is `guard let` or `try`); errors are
`throws` at API edges and `RenderError` internally, never `fatalError` except for programmer errors
in `precondition`; doc comments on every `public` symbol; `// MARK: -` sections in the order
*Types, Stored properties, Lifecycle, Public API, Rendering, Input, Private helpers*; 110-column
lines.

**Availability shim** for the one deprecated API we touch:

```swift
private func makeCompileOptions() -> MTLCompileOptions {
    let o = MTLCompileOptions()
    o.languageVersion = .version3_0
    if #available(macOS 15.0, *) { o.mathMode = .fast } else { o.fastMathEnabled = true }
    return o
}
```

---

## 19. Cross-module contracts other modules must respect

1. **Value-type ownership.** `FrameGeometry`, `ColorInfo`, `FieldOrder` are declared in
   **`VigilProtocols`** (pure, no CoreVideo/CoreMedia) because `VigilBitstream` computes them from
   the SPS/VPS VUI on Linux. `VideoFrame` (which holds a `CVPixelBuffer`) is declared in
   **`VigilVideo`**. `VigilRender` declares only rendering types.
2. **`VideoSink` shape.** `VigilVideo` must expose exactly
   `nonisolated func enqueue(_ frame: VideoFrame)`, `streamDidReset()`,
   `streamDidEnd(reason:)`, and must also offer a `CMSampleBuffer` overload for the ASBDL fast path.
   `VideoTileView` conforms to it.
3. **Pixel buffer requirements.** Every `CVPixelBuffer` must be IOSurface-backed and
   Metal-compatible (`kCVPixelBufferMetalCompatibilityKey`, `kCVPixelBufferIOSurfacePropertiesKey`),
   in `420v` / `420f` / `x420` / `xf20`, with the CoreVideo colour attachments set. Buffers must stay
   valid until the render's completion handler runs (VigilVideo's pool must be ≥ 6 deep).
4. **Layout size forces the decode strategy.** Layouts of **7 or more** tiles use the single-layer
   atlas, which requires pixel access, which forces `VTDecompressionSession` + `CVPixelBuffer` for
   every tile in that layout. 1–6 tiles may use `AVSampleBufferDisplayLayer` when
   `zoom == 1 && adjustments.isIdentity && no privacy mask && progressive && SDR`.
5. **`VigilCore` owns admission; `VigilRender` supplies the inputs.**
   `TileRenderState.pixelSize` (= `bounds × backingScaleFactor`, integer) and
   `tile(_:didChangePixelSize:isVisible:)` are the authoritative signals for the
   tile-size → main/sub/JPEG/paused policy table and for pause-on-occlusion.
6. **Camera region coordinates.** All 0…1000 regions are interpreted against the **cropped,
   SAR-corrected** picture, never the coded buffer. `NormalizedOrigin` is per-ISAPI-surface (§9.2);
   `VigilISAPI` must report which convention each device uses, defaulting to `.bottomLeft` for
   `/ISAPI/Smart/*` and `privacyMask`, `.topLeft` for the motion `gridMap`. The rect flip is
   `y' = 1 − (y + h)`.
7. **PTZ wire encoding is not the renderer's job.** `VigilRender` emits `PTZDirection` +
   speed (1…7) and `Position3DGesture` in content-normalized coordinates. `VigilISAPI` converts
   3D positioning to 0…255 bottom-left coordinates.
8. **SwiftUI must not wrap the video in an offscreen pass.** No `.drawingGroup()`, `.opacity(<1)`,
   `.shadow`, `.blur`, `.mask`, `.clipShape` or `.rotationEffect` on `VideoTile`/`VideoWall`. Corner
   radius comes from `TileRenderOptions.cornerRadii`; shadows go on sibling views. Overlays are a
   sibling `ZStack` layer with `.allowsHitTesting(false)`.
9. **Overlay ownership.** `VigilUI` draws timestamp, name chip, recording dot, status, focus ring,
   hover chrome, stats HUD, PTZ indicator, 3D drag rect and ≤ 32 motion boxes; `VigilRender` draws
   privacy masks, > 32 motion boxes and all wall-mode overlays. Geometry always comes from
   `TileRenderState.coordinateMap`, never recomputed independently.
10. **Capability gating.** When `RenderCapabilities.supportsImageAdjustments/PrivacyBlur/Deinterlace`
    is `false` (the Metal-failure fallback), `VigilUI` disables — not hides — those controls.
11. **Info.plist.** `UTExportedTypeDeclarations` must declare `com.vigil.tile-assignment` and
    `com.vigil.camera-ref` (both conforming to `public.data`), or drag and drop silently fails.
12. **Motion / adjustment settings are per camera**, persisted by `VigilCore` as
    `ImageAdjustments` (Codable); digital `TileTransform` is per *cell* and **not** persisted across
    launches (it resets to identity), while `gravity` **is** persisted per camera.

