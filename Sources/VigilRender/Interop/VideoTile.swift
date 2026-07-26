//
//  VideoTile.swift
//  VigilRender
//
//  The `NSViewRepresentable` that lets SwiftUI place a `VideoTileView`, and the rules a SwiftUI
//  caller must respect when it does.
//  Implements docs/API_CONTRACT.md §4.10, docs/spec-render.md §5.5 and §19, docs/DESIGN.md §3.6.
//
//  UNCOMPILED SwiftUI / AppKit code — see the header of VideoTileView.swift.
//

#if os(macOS)

import SwiftUI
import VigilProtocols

// MARK: - VideoTile

/// One camera's live video, as a SwiftUI view.
///
/// ## The video well is black, opaque, and must stay that way
///
/// The picture reaches the screen through an `AVSampleBufferDisplayLayer` that is composited
/// directly by the window server. Anything that forces SwiftUI to render this view into an
/// offscreen buffer first destroys that: the layer is copied through a texture that has to be
/// blended, latency grows by a frame, GPU cost roughly doubles, and on the sample-buffer path the
/// video can stop updating altogether because there is nothing for SwiftUI to snapshot between
/// presents.
///
/// **None of the following may be applied to a `VideoTile`** — not by the view that places it, and
/// not by any ancestor that wraps it (docs/API_CONTRACT.md §4.10, docs/spec-render.md §19):
///
/// * `.drawingGroup()` — the explicit "render offscreen" request.
/// * `.opacity(x)` for any `x < 1` — also forbidden by docs/DESIGN.md §3.6 clause 6: a live video
///   layer is never faded. Cross-fade a sibling overlay instead.
/// * `.shadow(…)` — put the shadow on a sibling background view behind the tile.
/// * `.blur(…)`, `.mask(…)`, `.clipShape(…)`, `.cornerRadius(…)`, `.rotationEffect(…)`.
///
/// Corner rounding, if a layout ever needs it, goes through `TileRenderOptions.cornerRadiusPt`,
/// which is applied on the layer where it costs one blend instead of a full offscreen pass. The
/// slice defaults it to `0` so the well stays strictly opaque.
///
/// This is the kind of constraint a later, innocent-looking UI change breaks — a designer adds a
/// `.shadow` to a card and the whole video path silently regresses — which is why it is written
/// here, at the declaration, rather than only in the spec.
///
/// ## Letterboxing
///
/// With the default `.fit` gravity the bars beside a 4:3 stream in a 16:9 well are the layer's own
/// `#000000` background. They are never the canvas colour and never a blurred-frame fill
/// (docs/DESIGN.md §3.6 clause 2). A caller must not paint its own background behind the tile in
/// the hope of colouring those bars; it will not be visible, and it is not what the design asks
/// for.
public struct VideoTile: NSViewRepresentable {

    // MARK: - Stored properties

    private let cameraID: CameraID
    private let frames: FrameStreamHandle
    private let options: TileRenderOptions
    private let logger: any LoggerProtocol
    private let onKeyframeNeeded: (() -> Void)?
    private let onDecodeFailure: ((String) -> Void)?
    private let onFramesDropped: ((Int, String) -> Void)?

    // MARK: - Lifecycle

    /// Places one camera's video.
    ///
    /// - Parameters:
    ///   - cameraID: identity for logs and for the handle's bookkeeping.
    ///   - frames: the attach point. `makeNSView` registers the view it creates with this handle,
    ///     and `dismantleNSView` unregisters it, so the frame producer never needs to know when
    ///     SwiftUI creates or destroys the view.
    ///   - options: fit policy and corner radius.
    ///   - logger: injected diagnostics; defaults to `NullLogger`.
    ///   - onKeyframeNeeded: called when the video renderer needs a flush and a fresh keyframe to
    ///     resume decoding. Ignoring it leaves the last picture frozen on screen.
    ///   - onDecodeFailure: called with a diagnostic string — `NSError` domain, numeric code and
    ///     localised description — when the video renderer fails to decode a sample. The decision
    ///     about reconnecting belongs to `VigilCore`; this only delivers the fact. Leaving it `nil`
    ///     means a decode failure reaches the log and nothing else.
    ///   - onFramesDropped: called with a count and a raw reason string when frames are dropped,
    ///     either upstream in `VigilVideo` or by this module when the renderer will not take a
    ///     sample. Leaving it `nil` makes display-path judder look like a network problem.
    public init(cameraID: CameraID,
                frames: FrameStreamHandle,
                options: TileRenderOptions = TileRenderOptions(),
                logger: any LoggerProtocol = NullLogger(),
                onKeyframeNeeded: (() -> Void)? = nil,
                onDecodeFailure: ((String) -> Void)? = nil,
                onFramesDropped: ((Int, String) -> Void)? = nil) {
        self.cameraID = cameraID
        self.frames = frames
        self.options = options
        self.logger = logger
        self.onKeyframeNeeded = onKeyframeNeeded
        self.onDecodeFailure = onDecodeFailure
        self.onFramesDropped = onFramesDropped
    }

    // MARK: - NSViewRepresentable

    /// Builds the view and attaches it to the frame handle.
    public func makeNSView(context: Context) -> VideoTileView {
        let view = VideoTileView(cameraID: cameraID, options: options, logger: logger)
        view.onKeyframeNeeded = onKeyframeNeeded
        view.onDecodeFailure = onDecodeFailure
        view.onFramesDropped = onFramesDropped
        frames.attach(view)
        return view
    }

    /// Pushes changed options down. The view applies only what differs, with CA actions disabled,
    /// so this is safe to call on every SwiftUI update.
    public func updateNSView(_ nsView: VideoTileView, context: Context) {
        if nsView.options != options {
            nsView.options = options
        }
        nsView.onKeyframeNeeded = onKeyframeNeeded
        nsView.onDecodeFailure = onDecodeFailure
        nsView.onFramesDropped = onFramesDropped
    }

    /// Detaches the view from the frame handle so the producer stops delivering into a view SwiftUI
    /// has thrown away.
    public static func dismantleNSView(_ nsView: VideoTileView, coordinator: ()) {
        nsView.detachFromFrameSource()
    }
}

#endif
