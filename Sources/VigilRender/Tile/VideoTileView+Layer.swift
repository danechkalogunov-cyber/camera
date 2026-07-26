//
//  VideoTileView+Layer.swift
//  VigilRender
//
//  Backing-layer creation, `contentsScale` tracking across displays, and the AppKit live-resize
//  flicker fixes for `VideoTileView`.
//  Implements docs/spec-render.md §5.2, §5.3, §5.4, §12 and docs/DESIGN.md §3.6.
//
//  UNCOMPILED AppKit / AVFoundation code — see the header of VideoTileView.swift.
//

#if os(macOS)

import AppKit
import AVFoundation
import QuartzCore
import VigilProtocols

// MARK: - CA transaction helper

/// Runs `body` with implicit `CAAnimation`s off.
///
/// Every geometry write on a video layer goes through this. Without it, CoreAnimation attaches its
/// default 0.25 s action to `bounds`, `position` and `contentsScale`, and the video well visibly
/// slides and rescales during a window resize or a display change.
@inline(__always)
func withoutCAActions(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    CATransaction.setAnimationDuration(0)
    body()
    CATransaction.commit()
}

// MARK: - Layer

extension VideoTileView {

    /// The backing layer, typed. `nil` only if AppKit has not created it yet.
    var displayLayer: AVSampleBufferDisplayLayer? {
        layer as? AVSampleBufferDisplayLayer
    }

    /// Creates the video layer.
    ///
    /// AppKit calls this once, synchronously, from `wantsLayer = true`. Everything that makes the
    /// well black is set **here**, before the layer is ever composited: if `isOpaque` and
    /// `backgroundColor` were assigned after the fact, the window background would show through for
    /// the frames between layer creation and the first sample — the white flash the slice brief
    /// calls out.
    ///
    /// AppKit signature:
    ///   `class NSView { func makeBackingLayer() -> CALayer }`
    override public func makeBackingLayer() -> CALayer {
        // AVFoundation: `class AVSampleBufferDisplayLayer: CALayer` with
        //   `var videoGravity: AVLayerVideoGravity`
        //   `var preventsDisplaySleepDuringVideoPlayback: Bool`   (macOS 11.0+)
        let videoLayer = AVSampleBufferDisplayLayer()

        // docs/DESIGN.md §3.6, clauses 1-3. Black first, opaque first, then everything else.
        // NSColor.black is a static, not a dynamic system colour, so it does not follow the
        // appearance and cannot resolve to anything but #000000.
        videoLayer.backgroundColor = NSColor.black.cgColor
        videoLayer.isOpaque = true

        videoLayer.videoGravity = options.gravity.avGravity
        videoLayer.preventsDisplaySleepDuringVideoPlayback = options.preventsDisplaySleep

        // Geometry changes on this layer are driven by AppKit's layout, never animated by us.
        videoLayer.needsDisplayOnBoundsChange = false
        videoLayer.contentsScale = currentBackingScale()

        applyCornerRadius(to: videoLayer)
        return videoLayer
    }

    /// Corner radius on the sample-buffer backend, and the opacity it costs.
    ///
    /// Radius `0` — the slice default — leaves the layer strictly opaque. A non-zero radius needs
    /// `masksToBounds`, which forces a compositor blend over the whole tile
    /// (docs/spec-render.md §5.5). The background stays black either way, so a rounded well never
    /// shows canvas colour behind the picture.
    func applyCornerRadius(to videoLayer: AVSampleBufferDisplayLayer) {
        let radius = max(0, options.cornerRadiusPt)
        videoLayer.cornerRadius = radius
        videoLayer.cornerCurve = .continuous
        videoLayer.masksToBounds = radius > 0
        videoLayer.isOpaque = radius == 0
    }

    // MARK: - Backing scale

    /// The scale factor the layer should be rendering at.
    ///
    /// `window` is `nil` while the view is being built and between removal and re-insertion, so the
    /// screen is consulted next and 1.0 is the last resort. Whatever this returns is corrected by
    /// `viewDidMoveToWindow()` as soon as there is a real window.
    func currentBackingScale() -> CGFloat {
        if let window { return window.backingScaleFactor }
        if let screen = NSScreen.main { return screen.backingScaleFactor }
        return 1
    }

    /// Re-reads `window.backingScaleFactor` and republishes the tile's size in backing pixels.
    ///
    /// This is the fix for "sharp on the laptop display, soft on the external one": a layer keeps
    /// whatever `contentsScale` it was created with until something assigns a new one, and moving a
    /// window between a 2× and a 1× display does not do that by itself.
    ///
    /// A zero-area tile (collapsed pane, the first pass of a layout animation) publishes a zero
    /// `Resolution` rather than being skipped, so a consumer of `state.pixelSize` can tell "not laid
    /// out yet" from "small".
    func updateScaleAndBackingSize() {
        guard let videoLayer = displayLayer else { return }
        guard bounds.width.isFinite, bounds.height.isFinite else { return }

        let scale = currentBackingScale()
        withoutCAActions {
            if videoLayer.contentsScale != scale {
                videoLayer.contentsScale = scale
            }
        }

        // Integer backing pixels. A fractional size rounds inside CoreAnimation and lands a
        // half-pixel blur on 1× displays (docs/spec-render.md §5.3).
        let widthPx = Int((bounds.width * scale).rounded(.toNearestOrAwayFromZero))
        let heightPx = Int((bounds.height * scale).rounded(.toNearestOrAwayFromZero))
        let size = Resolution(width: max(0, widthPx), height: max(0, heightPx))
        if state.pixelSize != size {
            state.setPixelSize(size)
        }
    }

    // MARK: - AppKit geometry callbacks

    /// Fires when the window's backing scale or colour space changes, including when the window is
    /// dragged onto a display with a different scale.
    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScaleAndBackingSize()
    }

    /// Rebinds the window-scoped notifications and corrects the scale the layer was created with.
    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindowNotifications()
        updateScaleAndBackingSize()
    }

    /// Resizes without letting CoreAnimation animate the layer geometry.
    ///
    /// The Metal path renders synchronously here while `inLiveResize` (docs/spec-render.md §5.4).
    /// The sample-buffer backend cannot: it has no drawable of its own and re-presents its held
    /// picture on the next CA commit. What it can do — and what this does — is make sure the
    /// geometry write itself is not animated and that the tile's published pixel size is correct
    /// before that commit.
    override public func setFrameSize(_ newSize: NSSize) {
        withoutCAActions {
            super.setFrameSize(newSize)
        }
        updateScaleAndBackingSize()
    }

    /// Live resize begins. Recorded so a later step can lower quality here without changing shape.
    override public func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        isLiveResizing = true
    }

    /// Live resize ends; re-read the geometry once more because the last `setFrameSize` during a
    /// drag can be coalesced.
    override public func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        isLiveResizing = false
        updateScaleAndBackingSize()
    }

    // MARK: - Notifications

    /// Observes the window and screen changes that invalidate the backing scale.
    ///
    /// Selector-based rather than block-based on purpose: the block form takes a
    /// `@Sendable (Notification) -> Void`, and `Notification` is not `Sendable`, so under Swift 6
    /// strict concurrency the block form needs an escape hatch that this does not.
    func observeWindowNotifications() {
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didChangeBackingPropertiesNotification,
                              object: nil)
        center.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification,
                              object: nil)

        guard let window else { return }
        center.addObserver(self, selector: #selector(backingPropertiesDidChange(_:)),
                           name: NSWindow.didChangeScreenNotification, object: window)
        center.addObserver(self, selector: #selector(backingPropertiesDidChange(_:)),
                           name: NSWindow.didChangeBackingPropertiesNotification, object: window)
        center.addObserver(self, selector: #selector(backingPropertiesDidChange(_:)),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// Observes the two notifications the slice must not ignore, **on the renderer**.
    ///
    /// The renderer, not the layer, for two independent reasons.
    ///
    /// 1. Samples go in through `layer.sampleBufferRenderer`, and AVFoundation's own header is
    ///    explicit: *"Do not use AVSampleBufferDisplayLayer's AVQueuedSampleBufferRendering
    ///    functions when using sampleBufferRenderer."* The layer's `requiresFlushToResumeDecoding`
    ///    is deprecated from macOS 15 in favour of the renderer's, so the layer is the wrong object
    ///    to ask whether decoding stopped. Observing it risked a picture frozen on a held frame
    ///    with no recovery — indistinguishable from a network stall.
    /// 2. The layer's spellings this file used previously do not exist in Swift at all.
    ///    `AVSampleBufferDisplayLayerFailedToDecodeNotification` is declared `NSString *const`, not
    ///    `NSNotificationName`, so it imports as `NSNotification.Name.AVSampleBufferDisplayLayer‌-`
    ///    `FailedToDecode` rather than as a member of the layer; the same is true of the
    ///    requires-flush notification. `AVSampleBufferDisplayLayer.failedToDecodeNotification` and
    ///    `.failedToDecodeNotificationErrorKey` are not members of that class.
    ///
    /// AVFoundation, on `AVSampleBufferVideoRenderer` (macOS 14.0+, none deprecated):
    ///   `class let requiresFlushToResumeDecodingDidChangeNotification: NSNotification.Name`
    ///   `class let didFailToDecodeNotification: NSNotification.Name`
    ///   `class let didFailToDecodeNotificationErrorKey: String`
    ///   `var requiresFlushToResumeDecoding: Bool`
    func observeRendererNotifications(_ renderer: AVSampleBufferVideoRenderer) {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(requiresFlushToResumeDecodingDidChange(_:)),
            name: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
            object: renderer)
        center.addObserver(
            self,
            selector: #selector(rendererFailedToDecode(_:)),
            name: AVSampleBufferVideoRenderer.didFailToDecodeNotification,
            object: renderer)
    }

    @objc
    private func backingPropertiesDidChange(_ note: Notification) {
        updateScaleAndBackingSize()
    }

    /// The layer stopped decoding — app suspension, a GPU reset, a stream interruption.
    ///
    /// Recovery is a `flush()` plus a fresh keyframe. It is **not** `flush(removingDisplayedImage:)`:
    /// the picture on screen is the last good frame and it stays there until a new one replaces it.
    @objc
    private func requiresFlushToResumeDecodingDidChange(_ note: Notification) {
        guard let videoLayer = displayLayer else { return }
        guard videoLayer.requiresFlushToResumeDecoding else { return }
        logger.notice(.render, "display layer requires a flush to resume decoding",
                      ["camera": cameraID.short])
        sampleBuffers.flushKeepingLastImage(reason: .resumeDecoding)
        onKeyframeNeeded?()
    }

    /// The layer failed to decode a sample. Reported, never swallowed; the decision about
    /// reconnecting belongs to `VigilCore`.
    @objc
    private func layerFailedToDecode(_ note: Notification) {
        let key = AVSampleBufferDisplayLayer.failedToDecodeNotificationErrorKey
        let failure = note.userInfo?[key] as? any Error
        logger.error(.render, "display layer failed to decode",
                     ["camera": cameraID.short,
                      "error": failure.map { String(describing: $0) } ?? "unspecified"])
        if let failure {
            onDecodeFailure?(failure)
        }
    }
}

#endif
