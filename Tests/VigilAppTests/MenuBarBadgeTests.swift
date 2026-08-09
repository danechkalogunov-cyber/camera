//
//  MenuBarBadgeTests.swift
//  VigilAppTests
//

#if os(macOS)

import Testing
@testable import Vigil
import VigilCore

@Suite("Menu-bar badge priority")
@MainActor
struct MenuBarBadgeTests {

    @Test func offlineOutranksDegradedAndUnreadEvents() {
        let offline = CameraStream()
        offline.streamState = .failed
        let degraded = CameraStream()
        degraded.streamState = .degraded

        #expect(MenuBarBadgeState.resolve(streams: [degraded, offline],
                                          isRecording: false, unreadEvents: 9) == .offline(1))
    }

    @Test func recordingOutranksUnreadAndNominalHasNoBadge() {
        let live = CameraStream()
        live.streamState = .playing
        live.isReceivingMedia = true

        #expect(MenuBarBadgeState.resolve(streams: [live],
                                          isRecording: true, unreadEvents: 4) == .recording(1))
        #expect(MenuBarBadgeState.resolve(streams: [live],
                                          isRecording: false, unreadEvents: 0) == .nominal)
    }
}

#endif  // os(macOS)
