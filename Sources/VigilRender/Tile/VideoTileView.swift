//
//  VideoTileView.swift
//  VigilRender
//
//  The AppKit view that puts one camera's video on screen: an `NSView` whose backing layer is an
//  `AVSampleBufferDisplayLayer`. Slice scope — one camera, one layer, no Metal, no digital zoom,
//  no overlays, no atlas.
//  Implements docs/spec-render.md §5.1, §5.2, §13.2 and docs/DESIGN.md §3.6 (the true-black rule).
//
//  NONE OF THE APPKIT / AVFOUNDATION CODE IN THIS FILE HAS BEEN COMPILED. The container is Linux;
//  `#if os(macOS)` compiles it to nothing. Framework signatures are quoted above each call so a
//  reviewer without a compiler can check them (.vigil/STEP3.md, rule 1).
//

#if os(macOS)

import AppKit
import AVFoundation
import CoreMedia
import QuartzCore
import VigilProtocols

// MARK: - Options

/// How the picture is fitted into the video well.
///
/// The well itself is always `#000000` and opaque, so `fit` letterboxes onto black and never onto
/// the canvas colour (docs/DESIGN.md §3.6 clause 2).
public enum VideoGravity: String, Sendable, Codable, CaseIterable {
    /// Whole picture, aspect preserved, black bars where the aspect ratios differ.
    case fit
    /// Fills the well, aspect preserved, picture cropped.
    case fill
    /// Fills the well, aspect **not** preserved. Only ever a deliberate user choice.
    case stretch

    // AVFoundation: `struct AVLayerVideoGravity: RawRepresentable` with the three static members
    // `.resizeAspect`, `.resizeAspectFill`, `.resize`.
    var avGravity: AVLayerVideoGravity {
        switch self {
        case .fit: .resizeAspect
        case .fill: .resizeAspectFill
        case .stretch: .resize
        }
    }
}

public enum TileRenderBackend: String, Sendable, Codable, CaseIterable {
    case sampleBufferLayer
    case metal

    /// Which backend a tile built with the default options will actually use on **this** machine.
    ///
    /// ⚠️ Ask before the tile exists, not instead of asking the tile. `DecodePipeline` chooses its
    /// decoder once, in `init`, from `VideoSink.prefersDecodedPixelBuffers` — and the sink the app
    /// hands it is an adapter that may have no tile attached yet, because SwiftUI has not mounted
    /// one. Something has to answer, and answering "sample buffers" while the tile then comes up
    /// with a `CAMetalLayer` is the black picture this property exists to prevent: compressed
    /// samples arrive at a tile with no sample-buffer renderer and every frame is dropped.
    ///
    /// Resolved once, lazily, by building the renderer the tile would build — same code path as
    /// `MetalFrameBackend.isAvailable` and `makeBackingLayer()`, so the three cannot disagree.
    public static let resolvedDefault: TileRenderBackend =
        MetalFrameBackend(enabled: true).isAvailable ? .metal : .sampleBufferLayer
}

/// The subset of `TileRenderOptions` the slice honours.
///
/// The full type in docs/API_CONTRACT.md §4.10 also carries `adjustments`, `backendPreference`,
/// `maxZoom`, `bicubicZoomThreshold`, `cornerRadii`, `cornerColor`, the PTZ speeds, the debug HUD
/// flag and the latency preset. Every one of those only has meaning on the Metal path, which the
/// slice does not build; they are deliberately absent rather than present and ignored.
public struct TileRenderOptions: Sendable, Equatable {

    public var backend: TileRenderBackend

    /// Fit policy. Changing it retargets `AVSampleBufferDisplayLayer.videoGravity` in place.
    public var gravity: VideoGravity

    /// Corner radius in points. **Zero by default in the slice**, which is what keeps the well
    /// strictly opaque: on the sample-buffer backend a non-zero radius forces
    /// `masksToBounds = true` and therefore `isOpaque = false`, i.e. a compositor blend over the
    /// whole tile (docs/spec-render.md §5.5, §13.2). A single-camera stage has square corners, so
    /// the slice never pays that cost.
    public var cornerRadiusPt: CGFloat

    /// Keeps the display awake while video is playing. Surveillance video is watched, not glanced
    /// at, so this defaults to `true`.
    public var preventsDisplaySleep: Bool
    public var zoomScale: Float
    public var zoomAnchorX: Float
    public var zoomAnchorY: Float
    public var adjustments: TileColorAdjustments
    public var motionZones: [NormalizedVideoRect]

    /// Builds an options value. All parameters default to the slice defaults.
    public init(gravity: VideoGravity = .fit,
                cornerRadiusPt: CGFloat = 0,
                preventsDisplaySleep: Bool = true,
                backend: TileRenderBackend = .metal,
                zoomScale: Float = 1,
                zoomAnchorX: Float = 0.5,
                zoomAnchorY: Float = 0.5,
                adjustments: TileColorAdjustments = TileColorAdjustments(),
                motionZones: [NormalizedVideoRect] = []) {
        self.backend = backend
        self.gravity = gravity
        self.cornerRadiusPt = cornerRadiusPt
        self.preventsDisplaySleep = preventsDisplaySleep
        self.zoomScale = zoomScale
        self.zoomAnchorX = zoomAnchorX
        self.zoomAnchorY = zoomAnchorY
        self.adjustments = adjustments
        self.motionZones = motionZones
    }
}

// MARK: - VideoTileView

/// One camera's video, on screen.
///
/// The view is layer-backed by an `AVSampleBufferDisplayLayer` and does not draw: `draw(_:)` is
/// never called because `wantsUpdateLayer` is `true` and `updateLayer()` is empty. Sample buffers
/// are handed to it from `VigilVideo`'s presenter through the `nonisolated` `enqueue` entry point,
/// which never touches AppKit state and never allocates.
///
/// **The video well is `#000000`, opaque, and stays that way.** The layer is created black and
/// opaque *before* the first frame arrives, which is what prevents the white flash the window
/// background would otherwise show through for one frame. Nothing in this module tints, fades or
/// applies `.opacity()` to the layer, and letterbox bars are the layer's own black background
/// rather than a canvas-coloured fill (docs/DESIGN.md §3.6).
@MainActor
public final class VideoTileView: NSView {

    // MARK: - Stored properties

    /// The camera whose video this view shows. Diagnostic identity only; the view never resolves it.
    public let cameraID: CameraID

    /// Geometry and liveness the SwiftUI layer reads. Written here, never written from outside.
    public let state: TileRenderState

    /// Render options. Assigning re-applies only what actually changed, inside a
    /// disabled-actions `CATransaction` so nothing animates.
    public var options: TileRenderOptions {
        didSet { applyOptions(from: oldValue) }
    }

    /// Called when the video renderer reports it needs a flush before it can resume decoding. The
    /// owner must ask the camera for a fresh keyframe; without one the layer stays on the last
    /// displayed picture indefinitely.
    ///
    /// Delivered on whichever thread AVFoundation posts the notification on — see the note in this
    /// agent's report; AVFoundation does not document it and it has not been observed on hardware.
    public var onKeyframeNeeded: (() -> Void)?

    /// Called when the renderer posts `didFailToDecodeNotification`. `VigilRender` deliberately
    /// does not decide what to do: the reconnect state machine in `VigilCore` does.
    ///
    /// **The payload is a diagnostic string, not the error object.** Two reasons, both binding.
    /// `VigilProtocols.RenderError` has no case for a sample-buffer decode failure — it wants
    /// `sampleBufferDecodeFailed(String)`, which this module does not own and must not invent — and
    /// `any Error` is not `Sendable`, so it cannot cross from the thread AVFoundation posts on to
    /// the main actor. The string carries the `NSError` domain, numeric code and localised
    /// description, which is everything §6.5's `kVTVideoDecoderBadDataErr` rule needs, and it drops
    /// straight into that enum case when it lands.
    public var onDecodeFailure: ((String) -> Void)?

    /// Called when frames are dropped, with the count in this report and the reason as a stable raw
    /// string.
    ///
    /// Both origins arrive here, which is the point: drops `VigilVideo` reports through
    /// `VideoSink.didDropFrames(_:reason:)`, and this module's own refusals when the video renderer
    /// will not take a sample. Without this the second kind reached a private counter and stopped
    /// there, so routine display-path judder was indistinguishable from a network problem. See the
    /// comment on `SampleBufferBackend.enqueue` for the mechanism fix that is still owed.
    public var onFramesDropped: ((Int, String) -> Void)?

    /// Diagnostics. Never used on the per-sample path except behind `isEnabled`.
    let logger: any LoggerProtocol

    /// The lock-protected bridge between the decode thread and the display layer.
    ///
    /// A plain `let` of a `Sendable` type, so the three `nonisolated` ingest entry points below may
    /// read it without hopping. `nonisolated(unsafe)` was tried first, to avoid spending an R-52
    /// slot, and does **not** compile: Swift 6 will not let a non-`Sendable` value leave a
    /// `@MainActor` class into `nonisolated` code however the property is annotated. See the
    /// justification comment on `SampleBufferBackend`.
    let sampleBuffers = SampleBufferBackend()
    let metalFrames: MetalFrameBackend

    /// `true` between `viewWillStartLiveResize()` and `viewDidEndLiveResize()`.
    var isLiveResizing = false

    /// The handle that attached this view, held weakly so the handle can outlive the view and vice
    /// versa. Set by `FrameStreamHandle.attach(_:)`.
    weak var frameSource: FrameStreamHandle?

    // MARK: - Lifecycle

    /// Builds a tile view for one camera.
    ///
    /// The backing layer is created during this initialiser — `wantsLayer` is set only after every
    /// stored property exists, because AppKit calls `makeBackingLayer()` synchronously from that
    /// assignment and the layer configuration reads `options`.
    ///
    /// - Parameters:
    ///   - cameraID: identity for logs; the view never dereferences it.
    ///   - options: fit policy and corner radius. Defaults are the slice defaults.
    ///   - logger: injected; defaults to `NullLogger`, so nothing is written unless the app wires
    ///     a real logger in.
    public init(cameraID: CameraID,
                options: TileRenderOptions = TileRenderOptions(),
                logger: any LoggerProtocol = NullLogger()) {
        self.cameraID = cameraID
        self.options = options
        self.logger = logger
        self.state = TileRenderState()
        self.metalFrames = MetalFrameBackend(enabled: options.backend == .metal)
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        configureBeforeLayer()

        // TRAP (.vigil/STEP3.md §3.3): `wantsLayer` must be set before `layer` is touched.
        // Reading `layer` first gives AppKit an ordinary CALayer and `makeBackingLayer()` is then
        // never consulted, so the view silently loses its video layer.
        wantsLayer = true
        adoptBackingLayer()
    }

    /// Not supported. Vigil builds every view in code; there are no nibs.
    public required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        // Safe from a nonisolated deinit: `NotificationCenter` is thread-safe and this touches no
        // main-actor state. Selector-based observers have been zeroing-weak since 10.11, so this is
        // belt and braces rather than a correctness requirement.
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - AppKit overrides

    /// Top-left origin, so AppKit point coordinates match SwiftUI's exactly and no overlay ever
    /// needs a Y flip (docs/spec-render.md §2, note on space V).
    override public var isFlipped: Bool { true }

    /// The well is fully covered by opaque black plus video, so AppKit can skip everything behind
    /// it. This is half of the no-white-flash rule; the other half is the layer's own `isOpaque`.
    ///
    /// A non-zero corner radius means the view no longer covers its own rectangle, so it stops
    /// claiming to — the two answers must agree or AppKit leaves the corners undrawn.
    override public var isOpaque: Bool { options.cornerRadiusPt <= 0 }

    /// `updateLayer()` instead of `draw(_:)`. `draw(_:)` would allocate a CPU backing store for a
    /// view that never draws a pixel itself.
    override public var wantsUpdateLayer: Bool { true }

    /// Focusable, so a later step can attach key handling without changing the view's shape.
    override public var acceptsFirstResponder: Bool { true }

    /// A drag inside the video well is a video interaction, never a window move.
    override public var mouseDownCanMoveWindow: Bool { false }

    /// Intentionally empty: `AVSampleBufferDisplayLayer` owns its own contents and AppKit must not
    /// put anything into them. This override exists so that the `wantsUpdateLayer` path is a no-op
    /// rather than inherited behaviour.
    override public func updateLayer() {}

    // MARK: - Public API

    /// Tells the frame source to stop delivering into this view.
    ///
    /// Called from `VideoTile.dismantleNSView`. The display layer is deliberately **not** flushed
    /// and **not** blanked: the view is on its way out, and blanking it would produce exactly the
    /// black flash the contract forbids if SwiftUI is merely rebuilding the hierarchy.
    public func detachFromFrameSource() {
        guard let frameSource, frameSource.sink === self else { return }
        frameSource.detach()
    }

    // MARK: - Frame ingest (nonisolated)

    /// Hands one decoded-but-not-yet-displayed sample to the display layer.
    ///
    /// Called from `VigilVideo`'s presenter task, **not** the main actor, and it must return in
    /// well under a millisecond. It takes one `NSLock`, may call `flush()`, calls
    /// `AVSampleBufferVideoRenderer.enqueue(_:)`, and returns. It allocates nothing and touches no
    /// AppKit state.
    ///
    /// `sampleBuffer` is neither boxed nor stored: both sides of this call are `nonisolated` and
    /// the call is synchronous, so no isolation boundary is crossed and `Sendable` is not required
    /// (docs/API_CONTRACT.md §2 R-51).
    ///
    /// - Parameters:
    ///   - sampleBuffer: a ready sample carrying its own format description, built by `VigilVideo`.
    ///   - format: the neutral description of that format. Accepted for signature compatibility
    ///     with `VideoSink` and **not consulted** on this path: the sample buffer already carries
    ///     its `CMVideoFormatDescription`, and the display layer applies crop and aspect itself.
    ///     The Metal backend, which has to build geometry, is the member that will need it.
    ///   - generation: bumps on every format change. A change flushes the pending queue —
    ///     `flush()` alone, which discards queued samples and **keeps the displayed picture**.
    public nonisolated func enqueue(_ sampleBuffer: CMSampleBuffer,
                                    format: VideoFormatInfo,
                                    generation: UInt32) {
        let outcome = sampleBuffers.enqueue(sampleBuffer, generation: generation)
        publishIfNoteworthy(outcome)
    }

    /// The decoder was recreated or the stream restarted: drop everything queued.
    ///
    /// This is `flush()`, never `flush(removingDisplayedImage:)`. Holding the last picture across a
    /// reconnect is the specified behaviour — the offline state is a held frame, dimmed by a
    /// sibling overlay in `VigilUI`, not a black rectangle (docs/API_CONTRACT.md §4.9, the
    /// no-black-flash rule; docs/spec-render.md §13.2).
    public nonisolated func streamDidReset() {
        // `logger` and `cameraID` are immutable and `Sendable`, so a nonisolated method may read
        // them without hopping to the main actor.
        logger.debug(.render, "stream reset: pending samples dropped, displayed picture kept",
                     ["camera": cameraID.short])
        sampleBuffers.flushKeepingLastImage(reason: .streamReset)
        // Both backends, because either may be the one that has been drawing. The Metal backend has
        // nothing queued to discard — it hands each frame straight to a drawable — so this only
        // resets its "has anything been drawn since" flag, which is what makes the next frame
        // publish and the status line come back to life.
        metalFrames.markFlushed()
        publishIdle()
    }

    /// Whether the display layer can take another sample right now.
    ///
    /// Backpressure policy belongs to `VigilVideo`; `VigilRender` only reports the flag
    /// (docs/spec-render.md §13.2). Safe to read from the decode thread.
    public nonisolated var isReadyForMoreMediaData: Bool {
        sampleBuffers.isReadyForMoreMediaData
    }

    // MARK: - Private helpers

    /// Everything that must be true before the backing layer exists.
    private func configureBeforeLayer() {
        // `.duringViewResize` makes AppKit re-lay-out rather than stretch stale layer contents at
        // the trailing edge during a live resize (docs/spec-render.md §5.4, row 1).
        layerContentsRedrawPolicy = .duringViewResize
        layerContentsPlacement = .scaleAxesIndependently

        // NSView.clipsToBounds is macOS 14.0+, which is the deployment floor.
        clipsToBounds = true

        // NSView declares this settable, so it is assigned rather than overridden. Rendering never
        // happens on a background thread here.
        canDrawConcurrently = false
    }

    /// Wires the freshly created backing layer to the ingest path and the notifications.
    private func adoptBackingLayer() {
        if let metalLayer = layer as? CAMetalLayer {
            metalFrames.adopt(metalLayer)
            applyMetalOptions()
            state.setBackend(.metal)
            updateScaleAndBackingSize()
            return
        }
        guard let displayLayer else {
            logger.error(.render, "backing layer is not an AVSampleBufferDisplayLayer",
                         ["camera": cameraID.short])
            return
        }
        // AVFoundation, macOS 14.0+:
        //   extension AVSampleBufferDisplayLayer {
        //       var sampleBufferRenderer: AVSampleBufferVideoRenderer { get }
        //   }
        // The layer's own `enqueue(_:)` is deprecated from macOS 15 and the header forbids mixing
        // the two surfaces; the renderer is the supported one (docs/spec-render.md §13.2). It is
        // also the object that posts the decode notifications this view must not miss, so the same
        // reference is used for both.
        let renderer = displayLayer.sampleBufferRenderer
        sampleBuffers.adopt(renderer)
        observeRendererNotifications(renderer)
        state.setBackend(.sampleBufferLayer)
        updateScaleAndBackingSize()
    }

    /// Applies whatever actually changed, with implicit CA animations off.
    private func applyOptions(from old: TileRenderOptions) {
        if layer is CAMetalLayer {
            applyMetalOptions()
            return
        }
        guard let displayLayer else { return }
        withoutCAActions {
            if options.gravity != old.gravity {
                displayLayer.videoGravity = options.gravity.avGravity
            }
            if options.cornerRadiusPt != old.cornerRadiusPt {
                applyCornerRadius(to: displayLayer)
            }
            if options.preventsDisplaySleep != old.preventsDisplaySleep {
                displayLayer.preventsDisplaySleepDuringVideoPlayback = options.preventsDisplaySleep
            }
        }
    }

    private func applyMetalOptions() {
        metalFrames.configure(
            crop: DigitalZoomGeometry.crop(scale: options.zoomScale,
                                           anchorX: options.zoomAnchorX,
                                           anchorY: options.zoomAnchorY),
            adjustments: options.adjustments,
            motionZones: options.motionZones,
            gravity: options.gravity
        )
    }

    /// Publishes an ingest outcome to `state`, but only when something changed that a status line
    /// would want to show. The per-sample path must not schedule a main-actor hop per frame.
    ///
    /// A refusal publishes *and* reports, in the one hop it was already taking.
    private nonisolated func publishIfNoteworthy(_ outcome: SampleBufferBackend.Outcome) {
        guard outcome.isFirstSinceFlush || !outcome.accepted else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            state.absorb(outcome)
            if let refusal = outcome.refusal {
                onFramesDropped?(1, refusal.rawValue)
            }
        }
    }

    /// Folds a drop that happened upstream of this tile into the published counters and reports it.
    ///
    /// `nonisolated` because `VideoSink.didDropFrames(_:reason:)` is, and the witness in
    /// `VideoTileView+VideoSink.swift` is the only caller. `reason` is already a raw string so that
    /// this file needs nothing from `VigilVideo`.
    nonisolated func reportUpstreamDrop(_ count: Int, reason: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            state.absorbUpstreamDrop(count, reason: reason)
            onFramesDropped?(count, reason)
        }
    }

    /// The Metal path's half of `publishIfNoteworthy`: a picture is now on the glass.
    ///
    /// Called for the first frame after each flush and no other, so this stays one hop per stream.
    /// `AppSessionModel.isDisplayingPicture` reads the flag this sets, and `liveState` will not
    /// leave `.connecting(.waitingForKeyframe)` without it.
    nonisolated func publishFirstDrawnFrame() {
        Task { @MainActor [weak self] in
            self?.state.markDrawn()
        }
    }

    /// Marks the tile as no longer receiving after a flush.
    private nonisolated func publishIdle() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            state.markIdle()
        }
    }
}

// MARK: - VideoSink

// `VideoTileView` is the one implementer of `VigilVideo.VideoSink` (docs/API_CONTRACT.md §2 R-51).
// The conformance itself is declared in `VideoTileView+VideoSink.swift`, which is the only file in
// this module that imports `VigilVideo`; the two members above are the witnesses and need nothing
// from that module to compile. The pixel-buffer requirement `enqueue(_ frame: VideoFrame)` is not
// part of the protocol in the slice — it belongs to the Metal backend, which the slice does not
// build — so this file honours the whole of `VideoSink` as it currently stands.

#endif
