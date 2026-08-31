//
//  LiveConnectionStateTests.swift
//  VigilUITests
//
//  What the video screen is showing, reduced to four questions the layout asks: is the connect
//  choreography running, is a picture on the glass, which status dot belongs beside it, and — for a
//  degraded stream — whether a remedy is offered and whether the banner retires itself. The
//  @MainActor narration/message strings are SwiftUI and left to the view tests.
//

#if os(macOS)

import Foundation
import Testing

@testable import VigilUI

@Suite("Live connection state")
struct LiveConnectionStateTests {

    // MARK: - Choreography and picture

    @Test func onlyConnectingRunsTheConnectChoreography() {
        #expect(LiveConnectionState.connecting(.resolving).isConnecting)
        #expect(!LiveConnectionState.live.isConnecting)
        #expect(!LiveConnectionState.offline(OfflineDetail()).isConnecting)
    }

    /// A picture is on the glass while live, degraded, or paused — the failure overlays must not cover
    /// the frame the user was last shown.
    @Test func aPictureIsShownWhileLiveDegradedOrPaused() {
        #expect(LiveConnectionState.live.isShowingVideo)
        #expect(LiveConnectionState.degraded(.decodeBudget).isShowingVideo)
        #expect(LiveConnectionState.paused.isShowingVideo)
        #expect(!LiveConnectionState.connecting(.opening).isShowingVideo)
        #expect(!LiveConnectionState.offline(OfflineDetail()).isShowingVideo)
        #expect(!LiveConnectionState.noRecording.isShowingVideo)
    }

    // MARK: - Status dot

    @Test func theDotMatchesTheState() {
        #expect(LiveConnectionState.connecting(.resolving).dot == .connecting)
        #expect(LiveConnectionState.live.dot == .live)
        #expect(LiveConnectionState.degraded(.decodeBudget).dot == .degraded)
        #expect(LiveConnectionState.paused.dot == .offline)
        #expect(LiveConnectionState.noRecording.dot == .offline)
    }

    /// The one offline state Vigil will never retry out of on its own — a wrong password — gets its
    /// own red-with-a-slash dot; other offline states share the plain offline dot.
    @Test func aCredentialFailureGetsTheAuthFailedDot() {
        let wrongPassword = OfflineDetail(diagnosis: .wrongPassword(host: "h"))
        #expect(LiveConnectionState.offline(wrongPassword).dot == .authFailed)

        let unreachable = OfflineDetail(diagnosis: .notOnThisNetwork(host: "h"))
        #expect(LiveConnectionState.offline(unreachable).dot == .offline)

        #expect(LiveConnectionState.offline(OfflineDetail()).dot == .offline)
    }

    // MARK: - Degraded cause

    /// Only the three network-shaped causes offer the switch-to-TCP remedy.
    @Test func remediesAreOfferedOnlyForTheNetworkCauses() {
        #expect(DegradedCause.packetLoss(fraction: 0.03).remedy == .switchToTCP)
        #expect(DegradedCause.jitter(milliseconds: 90).remedy == .switchToTCP)
        #expect(DegradedCause.lowFrameRate(fps: 12, negotiated: 30).remedy == .switchToTCP)
        #expect(DegradedCause.decodeQueue(frames: 10).remedy == nil)
        #expect(DegradedCause.decodeBudget.remedy == nil)
        #expect(DegradedCause.switchedToTCP.remedy == nil)
    }

    /// Only the informational "switched to TCP" banner retires itself.
    @Test func onlyTheSwitchedToTCPBannerIsTransient() {
        #expect(DegradedCause.switchedToTCP.isTransient)
        #expect(!DegradedCause.packetLoss(fraction: 0.03).isTransient)
        #expect(!DegradedCause.decodeBudget.isTransient)
    }

    // MARK: - Offline detail

    /// A wrong password is never retried automatically; an unknown cause and a plain network failure
    /// are.
    @Test func offlineDetailRetriesUnlessTheDiagnosisForbidsIt() {
        #expect(OfflineDetail().retriesAutomatically)  // no diagnosis yet → retry
        #expect(OfflineDetail(diagnosis: .notOnThisNetwork(host: "h")).retriesAutomatically)
        #expect(!OfflineDetail(diagnosis: .wrongPassword(host: "h")).retriesAutomatically)
    }
}

#endif  // os(macOS)
