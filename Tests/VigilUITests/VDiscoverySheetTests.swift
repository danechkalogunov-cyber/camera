#if os(macOS)
import Foundation
import Testing
@testable import VigilUI

@Test("Discovery rows preserve activation and authenticated NVR occupancy")
func discoveryRowStatus() {
    let summary = VDiscoveredCamera.ChannelSummary(online: 6, empty: 2)
    let row = VDiscoveredCamera(id: UUID(), title: "NVR", address: "192.0.2.1",
                                confidence: 100, supportsISAPI: true,
                                needsActivation: true, channelSummary: summary)

    #expect(row.needsActivation)
    #expect(row.channelSummary == summary)
}

@Test("A malformed channel summary cannot print negative counts")
func discoveryChannelSummaryClampsCounts() {
    let summary = VDiscoveredCamera.ChannelSummary(online: -1, empty: -2)
    #expect(summary.online == 0)
    #expect(summary.empty == 0)
}
#endif
