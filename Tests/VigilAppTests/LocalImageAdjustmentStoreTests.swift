#if os(macOS)

import Foundation
import Testing

@testable import Vigil
import VigilProtocols
import VigilUI

@Suite("Local image adjustments")
@MainActor
struct LocalImageAdjustmentStoreTests {
    @Test func valuesPersistPerCameraAndResetToNeutral() throws {
        let suite = "VigilTests.LocalImage.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let camera = CameraID()
        let store = LocalImageAdjustmentStore(defaults: defaults)
        let settings = InspectorImageSettings(brightness: 75, contrast: 60, saturation: 40,
                                              sharpness: 55, clientGamma: 80,
                                              isLocalPreviewOnly: true)

        store.save(settings, for: camera)
        let adjustment = store.adjustments(for: camera)
        #expect(adjustment.brightness == 0.5)
        #expect(adjustment.contrast == 1.2)
        #expect(adjustment.saturation == 0.8)
        #expect(adjustment.gamma == 1.3)

        let restored = LocalImageAdjustmentStore(defaults: defaults)
        #expect(restored.settings(for: camera)?.clientGamma == 80)
        let neutral = restored.reset(camera)
        #expect(neutral.brightness == 50)
        #expect(neutral.clientGamma == 50)
        #expect(neutral.isLocalPreviewOnly)
    }
}

#endif
