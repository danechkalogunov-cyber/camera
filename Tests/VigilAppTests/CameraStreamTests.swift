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
}

#endif  // os(macOS)
