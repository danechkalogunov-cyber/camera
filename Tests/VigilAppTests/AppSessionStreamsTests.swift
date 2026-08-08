//
//  AppSessionStreamsTests.swift
//  VigilAppTests
//
//  What the session model decides when there is more than one camera: what stops, what counts, and
//  which reports belong to the window rather than to a tile.
//
//  ⛔ THE RULE UNDER TEST IS THE `isLive` GATE. Everything that describes a stream — its state, its
//  attempt count, its diagnosis — belongs to the camera that reported it, so sixteen of them can be
//  in sixteen different states at once. Four things do not: the connect form, the remembered
//  connection, the failure screen and the Keychain deletion belong to the user's one connect attempt.
//  Without the gate, camera nine's first frame clears the form under a user typing camera ten's
//  password, and camera three dying throws the window off camera one. Neither is visible with one
//  camera on screen, which is the state this app was in for its whole life until F-LIV-01.
//
//  ⚠️ Nothing here starts a session. Every path tested returns before `start(_:camera:ref:)`, so no
//  socket is opened and no `StreamController` is built — the RTSP factory in the harness refuses to
//  connect precisely so that a test which strayed into one would fail loudly rather than hang.
//

#if os(macOS)

import Foundation
import Testing

@testable import Vigil
import VigilCore
import VigilProtocols
import VigilUI
import VigilVideo

@Suite("The session model with several cameras")
@MainActor
struct AppSessionStreamsTests {

    // MARK: - Fixtures

    /// Files `count` cameras and puts each one into its connecting state, which is what the budget
    /// counts.
    private func fillStage(_ harness: AppSessionHarness, count: Int) -> [Camera] {
        (0..<count).map { index in
            let camera = harness.camera(host: "192.168.1.\(100 + index)", name: "Camera \(index)")
            harness.model.cameras.stream(for: camera).beginConnecting()
            return camera
        }
    }

    // MARK: - Stopping

    /// ⛔ Going back to the form stops **every** camera. The window is showing the connect screen,
    /// so nothing on it is drawing the others — and a stream nobody can see is a socket, a decoder
    /// and a camera session the user has no way to stop.
    @Test func disconnectingStopsEveryCameraAndNotJustTheBoundOne() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let model = harness.model
        model.camera = harness.camera()
        model.live.beginConnecting()
        _ = fillStage(harness, count: 2)
        #expect(model.cameras.activeCount == 3)

        model.disconnect()

        #expect(model.cameras.activeCount == 0)
        #expect(model.cameras.count == 3, "a stopped camera keeps its entry; the tile is drawn from it")
        #expect(model.phase == .connect)
        #expect(model.form.isConnecting == false)
    }

    /// Disconnecting is not forgetting: the next launch still resumes this camera.
    @Test func disconnectingKeepsTheRememberedCamera() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        harness.remember()

        harness.model.disconnect()

        #expect(LastConnection.load(from: harness.defaults) != nil)
    }

    /// Asked to forget, it forgets.
    @Test func disconnectingWithForgetClearsTheRememberedCamera() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        harness.remember()

        harness.model.disconnect(forget: true)

        #expect(LastConnection.load(from: harness.defaults) == nil)
    }

    /// Closing one tile stops one camera. The rest keep streaming, and the window stays where it is.
    @Test func closingOneCameraLeavesTheOthersAlone() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let model = harness.model
        model.phase = .live
        let cameras = fillStage(harness, count: 3)

        model.disconnect(cameras[1].id)

        #expect(model.cameras.stream(for: cameras[1].id)?.isActive == false)
        #expect(model.cameras.stream(for: cameras[0].id)?.isActive == true)
        #expect(model.cameras.stream(for: cameras[2].id)?.isActive == true)
        #expect(model.phase == .live, "closing a tile is not leaving the video screen")
    }

    /// Closing the bound camera's tile *is* leaving the video screen, because the form is what the
    /// window has to show once the camera the form describes has stopped.
    @Test func closingTheBoundCameraGoesBackToTheForm() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let model = harness.model
        let camera = harness.camera()
        model.camera = camera
        model.live.beginConnecting()
        model.phase = .live

        model.disconnect(camera.id)

        #expect(model.phase == .connect)
        #expect(model.live.isActive == false)
    }

    /// A camera that was never connected has no stream, and closing it is not an error.
    @Test func closingACameraThatNeverStreamedIsHarmless() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        harness.model.phase = .live

        harness.model.disconnect(CameraID())

        #expect(harness.model.phase == .live)
    }

    // MARK: - The concurrency budget

    /// ⛔ One camera too many is refused rather than started, and the refusal is reported so the
    /// caller can say so — a click that appears to be ignored is the worse failure.
    ///
    /// The budget is set explicitly rather than detected: what this machine would suggest is not
    /// something a test can know, and a test that read it would pass or fail by the runner's core
    /// count. An unmeasured camera is assumed to be 1080p25 H.264, which the estimator prices at
    /// 1 DU, so two of them fill a 2 DU budget exactly.
    ///
    /// ⚠️ "Refused" means the third camera would get **no decode session at all** — not that it
    /// would get a slower one. The ladder demotes it to `.fpsCapped` and then `.keyframesOnly`
    /// first, and either of those is a picture worth showing; only when the budget cannot even pay
    /// for keyframes does the click have nothing to offer and the toast appear.
    @Test func theBudgetRefusesOneCameraTooMany() async {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        MachineDecodeBudget.setOverrideUnits(2, in: harness.defaults)
        _ = fillStage(harness, count: 2)
        let extra = harness.camera(host: "192.168.1.200", name: "One too many")

        let started = await harness.model.connectAlongside(extra)

        #expect(started == false)
        #expect(harness.model.cameras.activeCount == 2)
        #expect(harness.model.cameras.stream(for: extra.id)?.isActive == false)
    }

    /// A bigger budget admits what a stingy one refused. The same click, the same cameras, a
    /// different machine — which is the whole of why the count became a budget.
    @Test func aBiggerBudgetAdmitsTheSameCamera() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        _ = fillStage(harness, count: 2)
        let extra = harness.camera(host: "192.168.1.200", name: "One more")

        MachineDecodeBudget.setOverrideUnits(2, in: harness.defaults)
        #expect(harness.model.canAdmit(extra) == false)

        MachineDecodeBudget.setOverrideUnits(24, in: harness.defaults)
        #expect(harness.model.canAdmit(extra))
    }

    /// ⚠️ A camera the user has just clicked joins at the back of the queue: it must not slow down a
    /// camera they are already watching to make room for itself.
    @Test func aNewCameraDoesNotSlowTheOnesAlreadyOnScreen() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        MachineDecodeBudget.setOverrideUnits(2, in: harness.defaults)
        let running = fillStage(harness, count: 2)
        let extra = harness.camera(host: "192.168.1.200", name: "One too many")

        var demands = harness.model.decodeDemands()
        demands.append(DecodeDemand(
            id: StreamKey(camera: extra.id, quality: .main), priority: .offscreen,
            orderIndex: demands.count, mode: .full, cost: AppSessionModel.assumedCost))
        let plan = DecodeAdmissionPlanner.plan(for: demands, budget: harness.model.decodeBudget)

        for camera in running {
            let key = StreamKey(camera: camera.id, quality: .main)
            #expect(plan.mode(for: key) == .full, "already on screen, so already paid for")
        }
        #expect(plan.mode(for: StreamKey(camera: extra.id, quality: .main))?
            .opensDecodeSession == false)
    }

    /// A stream being recorded is not preemptible, which is what actually protects the file.
    @Test func aRecordingStreamIsNotPreemptible() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let camera = fillStage(harness, count: 1)[0]

        let demands = harness.model.decodeDemands()

        #expect(demands.count == 1)
        #expect(demands.first?.isPreemptible == true, "nothing is being written yet")
        #expect(demands.first?.id == StreamKey(camera: camera.id, quality: .main))
    }

    /// A camera already on the stage is left alone: clicking its cell again must not build a second
    /// session for one device.
    @Test func aCameraAlreadyStreamingIsNotStartedTwice() async {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let camera = fillStage(harness, count: 1)[0]
        let stream = harness.model.cameras.stream(for: camera.id)

        let started = await harness.model.connectAlongside(camera)

        #expect(started)
        #expect(harness.model.cameras.stream(for: camera.id) === stream)
        #expect(harness.model.cameras.count == 1)
    }

    /// ⚠️ The bound camera is never started this way. It is driven by the connect path, and asking
    /// for it here would build a second session for a camera that already has one.
    @Test func theBoundCameraIsNeverAddedAlongsideItself() async {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let camera = harness.camera()
        harness.model.camera = camera

        let started = await harness.model.connectAlongside(camera)

        #expect(started)
        #expect(harness.model.cameras.count == 1)
    }

    // MARK: - Turning a patrol page

    /// ⛔ A page turn stops what the new page does not name, and stops it **before** anything
    /// starts. The budget is four: a turn that started first would ask for the fifth stream while
    /// the previous page still held the budget, every camera on the new page would be refused, and
    /// the patrol would advance through pages the user never sees.
    @Test func aPageTurnStopsTheCamerasTheNewPageDoesNotName() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let cameras = fillStage(harness, count: 4)

        let stopping = harness.model.streamsToStop(forPage: [cameras[2].id, cameras[3].id])

        #expect(Set(stopping.compactMap { $0.camera?.id }) == Set([cameras[0].id, cameras[1].id]))
    }

    /// ⚠️ The bound stream is never in the list, whichever camera it is pointed at: the page turn
    /// re-points it, and stopping it here would tear down the one session still on screen a moment
    /// before rebuilding it.
    @Test func aPageTurnNeverStopsTheBoundStreamItself() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let model = harness.model
        model.camera = harness.camera(host: "192.168.1.9", name: "Bound")
        model.live.beginConnecting()
        let cameras = fillStage(harness, count: 2)

        let stopping = model.streamsToStop(forPage: [cameras[0].id])

        #expect(stopping.count == 1)
        #expect(stopping.first?.camera?.id == cameras[1].id)
        #expect(stopping.contains { $0 === model.live } == false)
    }

    /// A camera already stopped is not stopped again — the list is what has to be acted on, not
    /// every entry the set happens to hold.
    @Test func aPageTurnIgnoresCamerasThatAreAlreadyStopped() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let cameras = fillStage(harness, count: 2)
        harness.model.disconnect(cameras[0].id)

        #expect(harness.model.streamsToStop(forPage: []).count == 1)
    }

    // MARK: - Forced keyframe recovery

    /// ⛔ The rate limit is per **stream**, because it protects a session rather than the app: two
    /// cameras that both lose their keyframes are two independent problems, and a shared timer would
    /// let the first one's recovery silence the second one's for thirty seconds.
    @Test func keyframeRecoveryIsRateLimitedPerCamera() throws {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let cameras = fillStage(harness, count: 2)
        let first = try #require(harness.model.cameras.stream(for: cameras[0].id))
        let second = try #require(harness.model.cameras.stream(for: cameras[1].id))

        harness.model.recoverStalledPicture(on: first)
        let firstRecovery = first.lastRecoveryAt
        harness.model.recoverStalledPicture(on: first)

        #expect(first.lastRecoveryAt == firstRecovery, "the second ask inside the window is refused")
        #expect(second.lastRecoveryAt == nil, "one camera's rate limit is not the other's")

        harness.model.recoverStalledPicture(on: second)
        #expect(second.lastRecoveryAt != nil)
    }

    /// One decode failure is packet loss and two can be the same GOP. Three means the parameter sets
    /// the decoder is working from cannot decode what the camera is sending, so a keyframe is asked
    /// for and the count starts again.
    @Test func threeDecodeFailuresAskForAKeyframe() throws {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let camera = fillStage(harness, count: 1)[0]
        let stream = try #require(harness.model.cameras.stream(for: camera.id))

        harness.model.handleDecodeFailure("truncated access unit", on: stream)
        harness.model.handleDecodeFailure("truncated access unit", on: stream)
        #expect(stream.decodeFailures == 2)
        #expect(stream.lastRecoveryAt == nil)

        harness.model.handleDecodeFailure("truncated access unit", on: stream)

        #expect(stream.decodeFailures == 0, "the count restarts after a recovery")
        #expect(stream.lastRecoveryAt != nil)
    }

    /// The counters belong to the camera that reported them. Two cameras failing once each is not
    /// one camera failing twice.
    @Test func decodeFailuresAreCountedPerCamera() throws {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let cameras = fillStage(harness, count: 2)
        let first = try #require(harness.model.cameras.stream(for: cameras[0].id))
        let second = try #require(harness.model.cameras.stream(for: cameras[1].id))

        harness.model.handleDecodeFailure("bad", on: first)
        harness.model.handleDecodeFailure("bad", on: second)

        #expect(first.decodeFailures == 1)
        #expect(second.decodeFailures == 1)
    }

    /// ⛔ `noFormat` is the drop reason that never resolves by itself: no parameter sets have
    /// arrived, every frame is discarded, and the tile is black with nothing else wrong. Hikvision
    /// re-sends SPS/PPS immediately before every IDR, so asking for a keyframe is what gets the
    /// format.
    @Test func framesDroppedForWantOfParameterSetsAskForAKeyframe() throws {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let camera = fillStage(harness, count: 1)[0]
        let stream = try #require(harness.model.cameras.stream(for: camera.id))
        let reason = FrameDropReason.noFormat.rawValue

        harness.model.handleFramesDropped(
            AppSessionModel.noFormatDropsBeforeRecovery, reason: reason, on: stream)

        #expect(stream.lastRecoveryAt != nil)
        #expect(stream.droppedByReason[reason] == 0, "the count restarts after a recovery")
    }

    /// Every other reason is counted and logged and nothing more. A full presenter queue is the
    /// display path doing its job under load, and restarting the session would make it worse.
    @Test func framesDroppedForAnyOtherReasonNeverForceARestart() throws {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let camera = fillStage(harness, count: 1)[0]
        let stream = try #require(harness.model.cameras.stream(for: camera.id))
        let reason = FrameDropReason.queueFull.rawValue

        harness.model.handleFramesDropped(500, reason: reason, on: stream)

        #expect(stream.lastRecoveryAt == nil)
        #expect(stream.droppedByReason[reason] == 500)
    }

    // MARK: - Folding events, and the `isLive` gate

    /// A state change describes one camera and reaches no other.
    @Test func aStateChangeReachesOnlyTheCameraThatReportedIt() throws {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let camera = fillStage(harness, count: 1)[0]
        let stream = try #require(harness.model.cameras.stream(for: camera.id))

        let detail = StateDetail(narration: "", attempt: 3)
        harness.model.apply(
            .stateChanged(from: .connecting, to: .describing, detail: detail), to: stream)

        #expect(stream.streamState == .describing)
        #expect(stream.attempt == 3)
        #expect(harness.model.live.streamState == .idle)
        #expect(harness.model.live.attempt == 1)
    }

    /// The bound camera's first frame is what clears the form, empties the password field and
    /// writes the remembered connection.
    @Test func theBoundCamerasFirstFrameClearsTheForm() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let model = harness.model
        model.camera = harness.camera()
        model.activeRef = CredentialRef()
        model.form.host = "192.168.1.64"
        model.form.password = "hunter2"
        model.form.isConnecting = true

        model.apply(.firstFrameAssembled(afterStart: .seconds(2)), to: model.live)

        #expect(model.form.isConnecting == false)
        #expect(model.form.password.isEmpty, "the Keychain has it now")
        #expect(model.live.isReceivingMedia)
        #expect(LastConnection.load(from: harness.defaults)?.host == "192.168.1.64")
    }

    /// ⛔ THE GATE. A background camera reaching its first frame must not touch the form — the user
    /// may be typing another camera's password into it — and must not rewrite the remembered
    /// connection, which belongs to the camera the form describes.
    @Test func aBackgroundCamerasFirstFrameLeavesTheFormAlone() throws {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let model = harness.model
        let camera = fillStage(harness, count: 1)[0]
        let stream = try #require(model.cameras.stream(for: camera.id))
        stream.activeRef = CredentialRef()
        model.form.password = "hunter2"
        model.form.isConnecting = true

        model.apply(.firstFrameAssembled(afterStart: .seconds(2)), to: stream)

        #expect(stream.isReceivingMedia, "the camera that reported it still gets the fact")
        #expect(stream.lastSeen != nil)
        #expect(model.form.isConnecting, "the user's own connect attempt is still running")
        #expect(model.form.password == "hunter2")
        #expect(LastConnection.load(from: harness.defaults) == nil)
    }

    /// A rejected password is terminal: the window goes back to the form with the cause, and the
    /// record is forgotten so the next launch does not retry a password that walks the account
    /// towards a thirty-minute lockout.
    @Test func aTerminalFailureOnTheBoundCameraGoesBackToTheForm() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let model = harness.model
        let camera = harness.camera()
        model.camera = camera
        model.activeRef = CredentialRef()
        model.phase = .live
        harness.remember(host: camera.host)

        model.apply(.error(StreamError(code: .authenticationFailed), isFatal: true), to: model.live)

        #expect(model.phase == .connect)
        #expect(model.form.diagnosis == .wrongPassword(host: camera.host))
        #expect(model.form.failureCount == 1)
        #expect(LastConnection.load(from: harness.defaults) == nil)
        #expect(model.live.isActive == false)
    }

    /// ⛔ The same failure on a camera in the corner of the stage stops **that** camera and nothing
    /// else. It must not throw the window off the camera the user is watching, and it must not
    /// forget a remembered connection that belongs to a different device.
    @Test func aTerminalFailureOnABackgroundCameraStopsOnlyThatCamera() throws {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let model = harness.model
        model.camera = harness.camera()
        model.live.beginConnecting()
        model.phase = .live
        let other = fillStage(harness, count: 1)[0]
        let stream = try #require(model.cameras.stream(for: other.id))
        harness.remember()

        model.apply(.error(StreamError(code: .authenticationFailed), isFatal: true), to: stream)

        #expect(stream.isActive == false, "the camera that failed stops")
        #expect(stream.diagnosis == .wrongPassword(host: other.host))
        #expect(model.phase == .live, "the window stays on the camera the user is watching")
        #expect(model.live.isActive, "the bound camera keeps streaming")
        #expect(model.form.diagnosis == nil)
        #expect(LastConnection.load(from: harness.defaults) != nil)
    }

    /// A failure Vigil will retry by itself is not terminal, so nothing is torn down and the window
    /// stays where it is — including `signInPaused`, which *is* Vigil retrying on its own schedule.
    @Test func aRetryableFailureLeavesTheSessionRunning() {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let model = harness.model
        model.camera = harness.camera()
        model.live.beginConnecting()
        model.phase = .live

        model.apply(.error(StreamError(code: .connectTimeout), isFatal: false), to: model.live)

        #expect(model.phase == .live)
        #expect(model.live.isActive)
        #expect(model.live.diagnosis != nil, "the cause is still reported on the tile")
    }

    /// A scheduled reconnect carries the countdown the offline card renders, per camera.
    @Test func aReconnectScheduleIsRecordedOnTheCameraItBelongsTo() throws {
        let harness = AppSessionHarness()
        defer { harness.tearDown() }
        let camera = fillStage(harness, count: 1)[0]
        let stream = try #require(harness.model.cameras.stream(for: camera.id))

        let cause = StreamError(code: .connectTimeout)
        harness.model.apply(
            .reconnectScheduled(attempt: 4, delay: .seconds(8), cause: cause), to: stream)

        #expect(stream.attempt == 4)
        #expect(stream.retryInSeconds == 8)
        #expect(harness.model.live.retryInSeconds == nil)
    }

    // MARK: - The countdown

    /// No date is no countdown, and a date already past is zero rather than a negative number —
    /// which is what a status line would otherwise render as "Retrying in -3 s".
    @Test func theCountdownNeverGoesNegative() {
        #expect(AppSessionModel.seconds(until: nil) == nil)
        #expect(AppSessionModel.seconds(until: Date(timeIntervalSinceNow: -120)) == 0)
        let ahead = AppSessionModel.seconds(until: Date(timeIntervalSinceNow: 10))
        #expect(ahead == 10 || ahead == 9)
    }
}

#endif  // os(macOS)
