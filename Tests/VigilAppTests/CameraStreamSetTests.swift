//
//  CameraStreamSetTests.swift
//  VigilAppTests
//
//  The filing rule behind F-LIV-01's `[CameraID: CameraStream]` map.
//
//  ⛔ THE RULE UNDER TEST IS NOT `streams[id] = stream`. The app owns one long-lived `CameraStream`
//  and re-points it at a different camera when the user switches, so filing has to remove the entry
//  the stream was under before adding the new one. Get that wrong and the map grows one stale key
//  per switch, each pointing at a stream that is now showing a different picture — and the first
//  thing to read the map for the old camera is handed the wrong media path. Nothing about that
//  failure is visible on one camera, which is the state the app has been in for its whole life.
//
//  ⚠️ These tests build a `CameraStreamSet` directly and never an `AppSessionModel`: the session
//  object needs a `CoreDependencies` — Keychain, RTSP factory, lockout governor — and this target
//  has a double for none of them. That is exactly why the rule lives in its own type.
//

#if os(macOS)

import Testing
@testable import Vigil
import VigilCore
import VigilProtocols

@Suite("Camera stream set")
@MainActor
struct CameraStreamSetTests {

    // MARK: - Fixtures

    private func camera(_ name: String, host: String = "192.168.1.10") -> Camera {
        Camera(name: name, host: host)
    }

    // MARK: - Creating and finding

    /// Asking twice hands back the same media path. Three panels addressing one camera must not
    /// each get a stream of their own.
    @Test func askingTwiceReturnsTheSameStream() {
        let set = CameraStreamSet()
        let front = camera("Front door")

        let first = set.stream(for: front)
        let second = set.stream(for: front)

        #expect(first === second)
        #expect(set.count == 1)
    }

    /// Two cameras are two streams, and neither knows about the other.
    @Test func twoCamerasGetTwoStreams() {
        let set = CameraStreamSet()
        let front = set.stream(for: camera("Front door"))
        let yard = set.stream(for: camera("Yard", host: "192.168.1.11"))

        #expect(front !== yard)
        #expect(set.count == 2)
        front.streamState = .playing
        #expect(yard.streamState == .idle)
    }

    /// The record can change under a running stream — a rename, a new port — and the stream keeps
    /// its identity while adopting the new record.
    @Test func anEditedRecordUpdatesTheStreamInPlace() {
        let set = CameraStreamSet()
        var front = camera("Front door")
        let stream = set.stream(for: front)
        stream.streamState = .playing

        front.name = "Front gate"
        let again = set.stream(for: front)

        #expect(again === stream)
        #expect(again.camera?.name == "Front gate")
        #expect(again.streamState == .playing)
        #expect(set.count == 1)
    }

    /// Lookup by identity never creates: a camera nobody has connected has no stream, and asking
    /// about it must not mint one.
    @Test func lookupByIdentityDoesNotCreate() {
        let set = CameraStreamSet()
        #expect(set.stream(for: CameraID()) == nil)
        #expect(set.count == 0)
    }

    // MARK: - Filing

    /// ⛔ The failure this type exists for: re-pointing the one stream at another camera must move
    /// its entry, not add a second one.
    @Test func filingAStreamAtANewCameraMovesItsEntry() {
        let set = CameraStreamSet()
        let front = camera("Front door")
        let yard = camera("Yard", host: "192.168.1.11")

        let stream = set.stream(for: front)
        stream.camera = yard
        set.file(stream)

        #expect(set.count == 1)
        #expect(set.stream(for: yard.id) === stream)
        #expect(set.stream(for: front.id) == nil)
    }

    /// Filing the same stream twice under the same camera is a no-op, not a duplicate.
    @Test func filingTwiceChangesNothing() {
        let set = CameraStreamSet()
        let stream = set.stream(for: camera("Front door"))

        set.file(stream)
        set.file(stream)

        #expect(set.count == 1)
    }

    /// A stream with no camera is filed nowhere — and filing it *unfiles* it, which is what
    /// disconnecting back to the connect form amounts to.
    @Test func aStreamWithNoCameraIsFiledNowhere() {
        let set = CameraStreamSet()
        let front = camera("Front door")
        let stream = set.stream(for: front)

        stream.camera = nil
        set.file(stream)

        #expect(set.count == 0)
        #expect(set.stream(for: front.id) == nil)
    }

    /// Filing a stream that was never in the set adds it. `AppSessionModel.live` starts outside the
    /// set and arrives this way, on the first connect.
    @Test func filingAnUnknownStreamAddsIt() {
        let set = CameraStreamSet()
        let stream = CameraStream()
        stream.camera = camera("Front door")

        set.file(stream)

        #expect(set.count == 1)
        #expect(set.all.first === stream)
    }

    // MARK: - Forgetting

    /// Deleting a camera returns its stream, so the caller can tear the tasks down rather than
    /// leaking them.
    @Test func forgettingReturnsTheStreamItRemoved() {
        let set = CameraStreamSet()
        let front = camera("Front door")
        let stream = set.stream(for: front)

        #expect(set.forget(front.id) === stream)
        #expect(set.count == 0)
        #expect(set.stream(for: front.id) == nil)
    }

    /// Deleting a camera that never streamed is not an error and reports nothing to tear down.
    @Test func forgettingACameraThatNeverStreamedIsHarmless() {
        let set = CameraStreamSet()
        #expect(set.forget(CameraID()) == nil)
        #expect(set.count == 0)
    }

    // MARK: - The budget's counter

    /// ⛔ What a concurrency budget has to count is streams that are *being driven*, not streams
    /// that exist. A filed but stopped camera holds no socket and no decoder; counting it would
    /// spend the budget on cameras that are doing nothing, and the fifth click would be refused
    /// while three of the four were idle.
    @Test func activeCountIgnoresStreamsThatAreNotBeingDriven() {
        let set = CameraStreamSet()
        let front = set.stream(for: camera("Front door"))
        _ = set.stream(for: camera("Yard", host: "192.168.1.11"))

        #expect(set.count == 2)
        #expect(set.activeCount == 0)

        front.beginConnecting()
        #expect(set.activeCount == 1)

        front.teardown()
        #expect(set.activeCount == 0)
        #expect(set.count == 2, "a stopped camera keeps its entry — the offline card is drawn from it")
    }

    /// Forgetting one leaves the others alone.
    @Test func forgettingOneLeavesTheRest() {
        let set = CameraStreamSet()
        let front = camera("Front door")
        let yard = camera("Yard", host: "192.168.1.11")
        _ = set.stream(for: front)
        let yardStream = set.stream(for: yard)

        set.forget(front.id)

        #expect(set.count == 1)
        #expect(set.stream(for: yard.id) === yardStream)
    }
}

#endif  // os(macOS)
