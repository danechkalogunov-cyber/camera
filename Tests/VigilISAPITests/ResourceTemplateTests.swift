//
//  SettingsAndStorageTests.swift
//  VigilISAPITests
//
//  The motion grid's `gridMap` encoding, the image sub-resources and their read-modify-write
//  patches, JPEG snapshot policy and sniffing, storage volumes in decimal MB, two-way audio codec
//  negotiation, and the event-trigger and schedule readers.
//  Covers docs/spec-isapi.md §12.5, §14.7–§14.9, §15.4, §16 and §17.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilISAPI

// MARK: - ResourceTemplateSuite

@Suite struct ResourceTemplateSuite {

    @Test func resourceTemplateCollapsesOnlyNumericComponents() {
        // One 403 on channel 3 must suppress the pointless request on channels 1…64, and a literal
        // such as `position3D` must survive.
        #expect(ISAPIResource.template(of: "/PTZCtrl/channels/3/capabilities")
                == "/PTZCtrl/channels/{n}/capabilities")
        #expect(ISAPIResource.template(of: "/PTZCtrl/channels/1/position3D")
                == "/PTZCtrl/channels/{n}/position3D")
        #expect(ISAPIResource.template(of: "/Streaming/channels/3202/picture")
                == "/Streaming/channels/{n}/picture")
        #expect(ISAPIResource.template(of: "/PTZCtrl/channels/1/presets/94/goto")
                == "/PTZCtrl/channels/{n}/presets/{n}/goto")
        #expect(ISAPIResource.template(of: "/System/deviceInfo") == "/System/deviceInfo")
        #expect(ISAPIResource.template(of: "/ContentMgmt/search") == "/ContentMgmt/search")
    }

    @Test func resourcePathsMatchTheEndpointIndex() {
        // Spot-checks against docs/spec-isapi.md Appendix A.
        #expect(ISAPIResource.deviceInfo == "/System/deviceInfo")
        #expect(ISAPIResource.userCheck == "/Security/userCheck")
        #expect(ISAPIResource.alertStream == "/Event/notification/alertStream")
        #expect(ISAPIResource.contentSearch == "/ContentMgmt/search")
        #expect(ISAPIResource.inputProxyStatusList
                == "/ContentMgmt/InputProxy/channels/status")
        #expect(ISAPIResource.inputProxyStatus(ChannelID(7))
                == "/ContentMgmt/InputProxy/channels/7/status")
        #expect(ISAPIResource.streamingChannel(StreamingChannelID(channel: ChannelID(12),
                                                                 quality: .main))
                == "/Streaming/channels/1201")
        #expect(ISAPIResource.streamingChannelSingleDigit(ChannelID(1)) == "/Streaming/channels/1")
        #expect(ISAPIResource.motionDetection(ChannelID(1))
                == "/System/Video/inputs/channels/1/motionDetection")
        #expect(ISAPIResource.twoWayAudioData(1) == "/System/TwoWayAudio/channels/1/audioData")
        #expect(ISAPIResource.dailyDistributionTracks
                == "/ContentMgmt/record/tracks/dailyDistribution")
        #expect(ISAPIResource.dailyDistributionSearch == "/ContentMgmt/search/dailyDistribution")
    }
}
