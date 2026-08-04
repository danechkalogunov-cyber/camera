#if os(macOS)

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
}

#endif
