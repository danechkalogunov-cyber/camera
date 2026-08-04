#if os(macOS)

import CoreGraphics
import Testing
@testable import VigilRender

@Suite("Metal tile geometry")
struct MetalTileRendererTests {
    @Test func identityZoomUsesTheEntireSource() {
        let crop = DigitalZoomGeometry.crop(scale: 1, anchorX: 0.1, anchorY: 0.9)
        #expect(crop == NormalizedVideoRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func zoomKeepsTheAnchorAtTheSameRelativePosition() {
        let crop = DigitalZoomGeometry.crop(scale: 4, anchorX: 0.75, anchorY: 0.25)
        #expect(crop == NormalizedVideoRect(x: 0.5625, y: 0.1875, width: 0.25, height: 0.25))
    }

    @Test func zoomAndRectInputsAreClamped() {
        #expect(DigitalZoomGeometry.crop(scale: 100, anchorX: -1, anchorY: 2)
            == NormalizedVideoRect(x: 0, y: 0.9375, width: 0.0625, height: 0.0625))
        #expect(NormalizedVideoRect(x: -1, y: 0.75, width: 2, height: 1)
            == NormalizedVideoRect(x: 0, y: 0.75, width: 1, height: 0.25))
    }

    @Test func colorAdjustmentsRejectOutOfRangeValues() {
        let values = TileColorAdjustments(brightness: 3, contrast: -1, saturation: 5)
        #expect(values == TileColorAdjustments(brightness: 1, contrast: 0, saturation: 2))
    }

    @Test func tileDefaultsSelectMetalAndIdentityEffects() {
        let options = TileRenderOptions()
        #expect(options.backend == .metal)
        #expect(options.zoomScale == 1)
        #expect(options.adjustments == TileColorAdjustments())
        #expect(options.motionZones.isEmpty)
    }

    @Test func tileOptionsCarryZoomColorAndZonesToTheBackend() {
        let zone = NormalizedVideoRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let color = TileColorAdjustments(brightness: 0.2, contrast: 1.3, saturation: 0.7)
        let options = TileRenderOptions(
            backend: .metal, zoomScale: 3, zoomAnchorX: 0.25, zoomAnchorY: 0.75,
            adjustments: color, motionZones: [zone]
        )
        #expect(options.zoomScale == 3)
        #expect(options.zoomAnchorX == 0.25)
        #expect(options.zoomAnchorY == 0.75)
        #expect(options.adjustments == color)
        #expect(options.motionZones == [zone])
    }

    // MARK: - Aspect

    // ⛔ The first live camera this app ever showed was stretched. The shader draws one quad over
    // the whole drawable, so a 16:9 frame in a tile of any other shape is distorted, and
    // `videoGravity` — which the other backend gets from AVFoundation for free — reached nothing.
    //
    // `MetalTileRenderer.fit` is arithmetic over four numbers and is deliberately separable from
    // everything around it: the rest of that file needs a Metal device and a drawable, so this is
    // the only part of the fix a test can reach.

    /// 16:9 into a square: full width, centred vertically, and the source untouched.
    @Test func fitLetterboxesAWideFrameInASquareTile() {
        let (crop, viewport) = MetalTileRenderer.fit(
            gravity: .fit, crop: NormalizedVideoRect(x: 0, y: 0, width: 1, height: 1),
            source: CGSize(width: 1920, height: 1080), target: CGSize(width: 1000, height: 1000))
        #expect(crop == NormalizedVideoRect(x: 0, y: 0, width: 1, height: 1))
        // Compared with a tolerance, not `==`: 1920 × (1000 / 1920) is 1000.0000000000001 in binary
        // floating point, and a viewport a ten-thousandth of a pixel wide of exact is correct.
        #expect(abs((viewport?.width ?? 0) - 1000) < 0.001)
        #expect(abs((viewport?.height ?? 0) - 562.5) < 0.001)
        #expect(abs(viewport?.originX ?? 1) < 0.001)
        #expect(abs((viewport?.originY ?? 0) - 218.75) < 0.001)
    }

    /// The same tile in `.fill`: no viewport, because the drawable must be covered edge to edge —
    /// the source is trimmed instead, symmetrically.
    @Test func fillTrimsTheSourceInsteadOfInsettingTheViewport() {
        let (crop, viewport) = MetalTileRenderer.fit(
            gravity: .fill, crop: NormalizedVideoRect(x: 0, y: 0, width: 1, height: 1),
            source: CGSize(width: 1920, height: 1080), target: CGSize(width: 1000, height: 1000))
        #expect(viewport == nil)
        #expect(crop == NormalizedVideoRect(x: 0.21875, y: 0, width: 0.5625, height: 1))
    }

    /// A tall tile trims the other axis.
    @Test func fillTrimsHeightWhenTheTileIsWiderThanTheSource() {
        let (crop, viewport) = MetalTileRenderer.fit(
            gravity: .fill, crop: NormalizedVideoRect(x: 0, y: 0, width: 1, height: 1),
            source: CGSize(width: 500, height: 1000), target: CGSize(width: 1000, height: 400))
        #expect(viewport == nil)
        #expect(crop == NormalizedVideoRect(x: 0, y: 0.4, width: 1, height: 0.2))
    }

    /// `.stretch` is the one mode that is allowed to distort, and it is never the default.
    @Test func stretchIsLeftAlone() {
        let source = NormalizedVideoRect(x: 0, y: 0, width: 1, height: 1)
        let (crop, viewport) = MetalTileRenderer.fit(
            gravity: .stretch, crop: source,
            source: CGSize(width: 1920, height: 1080), target: CGSize(width: 1000, height: 1000))
        #expect(viewport == nil)
        #expect(crop == source)
    }

    /// Matching aspects cost nothing: no viewport, no trim. A 1920×1080 frame in a 16:9 tile is not
    /// exactly 16:9 once the tile is rounded to backing pixels, and insetting by a third of a pixel
    /// is worse than not insetting at all.
    @Test func aMatchingAspectIsNotInset() {
        let source = NormalizedVideoRect(x: 0, y: 0, width: 1, height: 1)
        for gravity in [VideoGravity.fit, .fill] {
            let (crop, viewport) = MetalTileRenderer.fit(
                gravity: gravity, crop: source,
                source: CGSize(width: 1920, height: 1080), target: CGSize(width: 1280, height: 720))
            #expect(viewport == nil)
            #expect(crop == source)
        }
    }

    /// Digital zoom composes with the fit: the crop that arrives is the zoom's, and `.fit` must
    /// letterbox against *that* rectangle's aspect rather than the whole frame's.
    @Test func fitUsesTheZoomedRectangleNotTheWholeFrame() {
        let zoomed = NormalizedVideoRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let (crop, viewport) = MetalTileRenderer.fit(
            gravity: .fit, crop: zoomed,
            source: CGSize(width: 1000, height: 1000), target: CGSize(width: 1000, height: 500))
        #expect(crop == zoomed)
        // The zoomed rectangle is square (500 × 500 source pixels) in a 2:1 tile.
        #expect(abs((viewport?.width ?? 0) - 500) < 0.001)
        #expect(abs((viewport?.height ?? 0) - 500) < 0.001)
        #expect(abs((viewport?.originX ?? 0) - 250) < 0.001)
        #expect(abs(viewport?.originY ?? 1) < 0.001)
    }

    /// A tile that has not been laid out yet has a zero-sized drawable. Dividing by it would give
    /// an infinite scale and a viewport of NaNs.
    @Test func aZeroSizedTargetIsRefusedRatherThanDividedBy() {
        let source = NormalizedVideoRect(x: 0, y: 0, width: 1, height: 1)
        let (crop, viewport) = MetalTileRenderer.fit(
            gravity: .fit, crop: source,
            source: CGSize(width: 1920, height: 1080), target: CGSize(width: 0, height: 0))
        #expect(viewport == nil)
        #expect(crop == source)
    }
}

#endif
