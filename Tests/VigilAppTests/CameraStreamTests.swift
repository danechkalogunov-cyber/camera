//
//  CameraStreamTests.swift
//  VigilAppTests
//
//  The two state transitions one camera's stream owns: starting a connect attempt, and being torn
//  down.
//
//  ⚠️ These are the parts of the session lifecycle that can be checked without a network, a
//  Keychain or a decoder — which is exactly why they were moved onto `CameraStream` in the first
//  place. What is left on `AppSessionModel` needs a `CoreDependencies` and stays uncheckable here.
//

#if os(macOS)

import Foundation
import Testing
@testable import Vigil
import VigilCore
import VigilProtocols
import VigilUI

@Suite("Camera stream transitions")
@MainActor
struct CameraStreamTests {

    // MARK: - Starting

    /// A new attempt clears what the previous one measured, and nothing else.
    @Test func beginningAConnectClearsTheLastAttemptsMeasurements() {
        let stream = CameraStream()
        stream.streamState = .failed
        stream.isReceivingMedia = true
        stream.hasFirstPacket = true
        stream.firstFrameLatency = .seconds(3)
        stream.retryInSeconds = 12
        stream.attempt = 7

        stream.beginConnecting()

        #expect(stream.streamState == .resolving)
        #expect(!stream.isReceivingMedia)
        #expect(!stream.hasFirstPacket)
        #expect(stream.firstFrameLatency == nil)
        #expect(stream.retryInSeconds == nil)
        #expect(stream.attempt == 1)
    }

    /// ⛔ The camera and the last-seen time survive a new attempt. They are what the offline card
    /// and the sidebar row are drawn from, and blanking them would make a reconnect look like a
    /// camera that had never existed.
    @Test func beginningAConnectKeepsWhatTheCardIsDrawnFrom() {
        let stream = CameraStream()
        let seen = Date(timeIntervalSince1970: 1_000)
        stream.camera = Camera(name: "Front door", host: "192.168.1.10")
        stream.lastSeen = seen
        stream.resolvedPath = "/Streaming/Channels/101"

        stream.beginConnecting()

        #expect(stream.camera?.name == "Front door")
        #expect(stream.lastSeen == seen)
        #expect(stream.resolvedPath == "/Streaming/Channels/101")
    }

    // MARK: - Tearing down

    /// A stream that never ran has nothing to hand back, and saying so is what lets the caller skip
    /// starting a teardown task for nothing.
    @Test func tearingDownAnIdleStreamHandsBackNothing() {
        let stream = CameraStream()
        #expect(!stream.isRunning)

        let outgoing = stream.teardown()

        #expect(outgoing.controller == nil)
        #expect(outgoing.pipeline == nil)
    }

    /// Teardown clears the per-session state the window reads, synchronously — the window draws on
    /// the next frame and must not see a stopped stream still claiming to be receiving media.
    @Test func tearingDownClearsTheSessionState() {
        let stream = CameraStream()
        stream.streamState = .playing
        stream.isReceivingMedia = true
        stream.hasFirstPacket = true
        stream.retryInSeconds = 4
        stream.firstFrameLatency = .seconds(1)
        stream.attemptStartedAt = Date()
        stream.decodeFailures = 3
        stream.droppedByReason["noFormat"] = 120

        stream.teardown()

        #expect(stream.streamState == .idle)
        #expect(!stream.isReceivingMedia)
        #expect(!stream.hasFirstPacket)
        #expect(stream.retryInSeconds == nil)
        #expect(stream.firstFrameLatency == nil)
        #expect(stream.attemptStartedAt == nil)
        #expect(stream.decodeFailures == 0)
        #expect(stream.droppedByReason.isEmpty)
    }

    /// ⛔ The camera, its last-seen time and the resolved path outlive the session. The offline card
    /// is drawn from all three, and R1.2's "probe once, ever" depends on the path surviving a stop.
    @Test func tearingDownKeepsWhatOutlivesTheSession() {
        let stream = CameraStream()
        let seen = Date(timeIntervalSince1970: 2_000)
        stream.camera = Camera(name: "Yard", host: "192.168.1.11")
        stream.lastSeen = seen
        stream.resolvedPath = "/Streaming/Channels/101"

        stream.teardown()

        #expect(stream.camera?.name == "Yard")
        #expect(stream.lastSeen == seen)
        #expect(stream.resolvedPath == "/Streaming/Channels/101")
    }

    /// Tearing down twice is safe: `disconnect` on a camera that is already stopped is an ordinary
    /// thing for a user to do.
    @Test func tearingDownTwiceIsHarmless() {
        let stream = CameraStream()
        stream.teardown()
        let second = stream.teardown()

        #expect(second.controller == nil)
        #expect(second.pipeline == nil)
        #expect(stream.streamState == .idle)
    }

    // MARK: - Being driven

    /// ⛔ A stream that is resolving an address has no controller yet, and the stage must still draw
    /// it as connecting. `isRunning` answers "is there something to stop"; this answers "is the app
    /// driving this camera", and a tile that asked the first question would offer to connect a
    /// camera that is already connecting.
    @Test func aStreamIsActiveFromTheMomentItStartsResolving() {
        let stream = CameraStream()
        #expect(!stream.isActive)
        #expect(!stream.isRunning)

        stream.beginConnecting()
        #expect(stream.isActive)
        #expect(!stream.isRunning)

        stream.teardown()
        #expect(!stream.isActive)
    }

    // MARK: - What the tile says

    /// `Live` is a claim about pixels. With a tile mounted, the tile's own render state decides.
    @Test func liveIsClaimedOnlyWhenSomethingIsOnTheGlass() {
        let stream = CameraStream()
        stream.streamState = .playing
        stream.isReceivingMedia = true

        // No tile mounted: the assembled-access-unit fact is the safe fallback.
        #expect(stream.isDisplayingPicture)
        #expect(stream.liveState == .live)
    }

    /// A planned reduction must be visible even though the transport itself is healthy.
    @Test func decodeBudgetReductionIsReportedAsDegraded() {
        let stream = CameraStream()
        stream.streamState = .playing
        stream.isReceivingMedia = true
        stream.decodeMode = .fpsCapped

        #expect(stream.liveState == .degraded(.decodeBudget))
    }

    /// Media arriving is not a picture: before the first frame is drawn the tile narrates, and which
    /// sentence it uses depends on whether any RTP has arrived at all.
    @Test func theConnectingNarrationSplitsOnTheFirstPacket() {
        let stream = CameraStream()
        stream.streamState = .playing

        #expect(stream.liveState == .connecting(.waitingForVideo))
        stream.hasFirstPacket = true
        #expect(stream.liveState == .connecting(.waitingForKeyframe))
    }

    /// The five transient states collapse into the connecting ladder, in order.
    @Test func everyTransientStateHasItsOwnRungOfTheLadder() {
        let stream = CameraStream()
        let expected: [(StreamState, LiveConnectionState)] = [
            (.idle, .connecting(.resolving)),
            (.resolving, .connecting(.resolving)),
            (.connecting, .connecting(.connecting)),
            (.authenticating, .connecting(.authenticating)),
            (.describing, .connecting(.negotiating)),
            (.settingUp, .connecting(.opening)),
        ]
        for (state, narration) in expected {
            stream.streamState = state
            #expect(stream.liveState == narration)
        }
    }

    /// Offline carries the numbers the card is drawn from, and turns persistent at the fifth
    /// attempt.
    @Test func offlineCarriesTheAttemptAndTheRetry() {
        let stream = CameraStream()
        let seen = Date(timeIntervalSince1970: 3_000)
        stream.streamState = .reconnecting
        stream.attempt = 5
        stream.retryInSeconds = 8
        stream.lastSeen = seen

        guard case let .offline(detail) = stream.liveState else {
            Issue.record("a reconnecting stream is offline")
            return
        }
        #expect(detail.attempt == 5)
        #expect(detail.retryInSeconds == 8)
        #expect(detail.lastSeen == seen)
        #expect(detail.isPersistent)
    }

    /// ⚠️ The degraded cause reports whichever measurement is actually non-zero, in the order loss,
    /// jitter, queue — every case carries a number the user can act on, so guessing is not allowed.
    @Test func degradedNamesTheMeasurementThatIsActuallyNonZero() {
        let stream = CameraStream()
        stream.streamState = .degraded
        var statistics = StreamStatistics()
        statistics.decodeQueueDepth = 12
        stream.statistics = statistics
        #expect(stream.liveState == .degraded(.decodeQueue(frames: 12)))

        statistics.jitterMilliseconds = 40
        stream.statistics = statistics
        #expect(stream.liveState == .degraded(.jitter(milliseconds: 40)))

        statistics.lossFraction = 0.03
        stream.statistics = statistics
        #expect(stream.liveState == .degraded(.packetLoss(fraction: 0.03)))
    }

    /// A gap in synchronized archive coverage is its own state: it is neither a failed connection
    /// nor a user pause, and it remains visible after the socket is torn down while the lane waits.
    @Test func archiveGapHasAnHonestStateAcrossTeardown() {
        let stream = CameraStream()
        stream.playback = PlaybackLocator(track: TrackID(101), start: Date(), end: nil)
        stream.hasPlaybackCoverage = false

        stream.teardown()

        #expect(stream.liveState == .noRecording)
        #expect(stream.playback != nil)
    }
}

#endif  // os(macOS)
