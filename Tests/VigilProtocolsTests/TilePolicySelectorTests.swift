import Testing
@testable import VigilProtocols

@Suite struct TilePolicySelectorTests {
    private func context(_ edge: Int) -> TileContext {
        TileContext(pixelSize: Resolution(width: edge, height: edge))
    }

    @Test func firstMeasurementIsImmediate() {
        var selector = TilePolicySelector()
        #expect(selector.ingest(context(300), at: .zero) == .stream(.sub))
    }

    @Test func promotionRequiresDeadBandAndDwell() {
        var selector = TilePolicySelector()
        _ = selector.ingest(context(300), at: .zero)
        #expect(selector.ingest(context(1100), at: .milliseconds(10)) == nil)
        #expect(selector.ingest(context(1242), at: .milliseconds(20)) == nil)
        #expect(selector.ingest(context(1242), at: .milliseconds(769)) == nil)
        #expect(selector.ingest(context(1242), at: .milliseconds(770)) == .stream(.main))
    }

    @Test func returningAcrossBoundaryRestartsDwell() {
        var selector = TilePolicySelector()
        _ = selector.ingest(context(300), at: .zero)
        _ = selector.ingest(context(1242), at: .milliseconds(10))
        _ = selector.ingest(context(300), at: .milliseconds(500))
        #expect(selector.ingest(context(1242), at: .milliseconds(600)) == nil)
        #expect(selector.ingest(context(1242), at: .milliseconds(1_349)) == nil)
        #expect(selector.ingest(context(1242), at: .milliseconds(1_350)) == .stream(.main))
    }

    @Test func overridePreventsAutomaticSwitch() {
        var selector = TilePolicySelector()
        var small = context(300)
        small.qualityOverride = .main
        #expect(selector.ingest(small, at: .zero) == .stream(.main))
        var large = context(1400)
        large.qualityOverride = .main
        #expect(selector.ingest(large, at: .seconds(2)) == nil)
    }
}
