//
//  SyncedPlaybackTests.swift
//  VigilProtocolsTests
//
//  The decidable half of F-PLB-05 — the feature its own document calls the hardest in the app.
//
//  ⛔ THE ONE THING THAT MAKES THIS FEATURE WORSE THAN NOTHING IF IT IS WRONG IS THRASH. A re-seek is
//  a whole new RTSP session: five round trips and a second of black. Correct at the same figure the
//  design calls acceptable and every camera that reaches it is torn down and rebuilt, only to be
//  found out again on the next sample — four cameras flickering forever in the name of
//  synchronisation. `driftInsideTheThresholdIsLeftAlone` and `hysteresisSeparatesTheTwoNumbers` are
//  that hazard written down.
//

import Foundation
import Testing

import VigilProtocols

@Suite("Synchronised playback")
struct SyncedPlaybackTests {

    // MARK: - Fixtures

    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }

    private func playhead(_ offset: TimeInterval = 0,
                          rate: Double = 1,
                          paused: Bool = false) -> SyncedPlayhead {
        SyncedPlayhead(instant: at(offset), rate: rate, isPaused: paused)
    }

    // MARK: - The playhead

    /// It moves in wall time multiplied by the rate, because that is what "4×" means to a person
    /// reviewing an hour of footage.
    @Test func thePlayheadMovesAtItsRate() {
        #expect(playhead().advanced(byWallSeconds: 10).instant == at(10))
        #expect(playhead(rate: 4).advanced(byWallSeconds: 10).instant == at(40))
    }

    /// ⛔ A paused playhead does not move. Everything else compares against it, so a held review
    /// that crept forward would spend the pause re-seeking four cameras towards a target the user
    /// had explicitly stopped.
    @Test func aPausedPlayheadDoesNotMove() {
        let held = playhead(100, paused: true)

        #expect(held.advanced(byWallSeconds: 30) == held)
    }

    /// A rate of zero is not a legal speed — a stopped review is `isPaused`, which is a different
    /// state with different behaviour. Anything non-positive resolves to real time rather than
    /// freezing the playhead in a way nothing could explain on screen.
    @Test func aZeroRateIsRealTimeAndNotAFrozenPlayhead() {
        #expect(SyncedPlayhead(instant: origin, rate: 0).rate == 1)
        #expect(SyncedPlayhead(instant: origin, rate: -2).rate == 1)
    }

    // MARK: - Correcting one camera

    /// A camera with no session is seeked, not held: "nowhere" is not "close enough".
    @Test func aCameraWithNoSessionIsSeeked() {
        let correction = SyncedPlaybackPolicy.correction(
            position: nil, playhead: playhead(60), hasCoverage: true)

        #expect(correction == .seek(to: at(60)))
    }

    /// ⛔ Inside the threshold, nothing happens. A re-seek costs five round trips and a second of
    /// black, so correcting a camera 80 ms out would buy less synchronisation than it spends.
    @Test func driftInsideTheThresholdIsLeftAlone() {
        let correction = SyncedPlaybackPolicy.correction(
            position: at(60.08), playhead: playhead(60), hasCoverage: true)

        #expect(correction == .hold)
    }

    /// Past it, the camera is brought back to the playhead — not to where it should have been.
    @Test func driftBeyondTheThresholdIsSeekedToThePlayhead() {
        let correction = SyncedPlaybackPolicy.correction(
            position: at(59.2), playhead: playhead(60), hasCoverage: true)

        #expect(correction == .seek(to: at(60)))
    }

    /// Drift is symmetric: a camera running ahead is as wrong as one running behind, and on a
    /// device whose clock gains that is the common case.
    @Test func driftIsSymmetric() {
        let ahead = SyncedPlaybackPolicy.correction(
            position: at(60.9), playhead: playhead(60), hasCoverage: true)

        #expect(ahead == .seek(to: at(60)))
    }

    /// ⛔ THE HYSTERESIS, WHICH IS THE WHOLE ANTI-THRASH DESIGN. The target and the threshold are
    /// two different numbers on purpose: a camera is allowed to sit between them without being
    /// touched. Making them equal turns every camera that reaches the acceptable figure into a
    /// teardown and rebuild, and the next sample finds it out again.
    @Test func hysteresisSeparatesTheTwoNumbers() {
        #expect(SyncedPlaybackPolicy.reseekThreshold > SyncedPlaybackPolicy.targetSkew)

        let between = SyncedPlaybackPolicy.correction(
            position: at(60 + SyncedPlaybackPolicy.targetSkew + 0.05),
            playhead: playhead(60),
            hasCoverage: true)

        #expect(between == .hold, "past the target, inside the threshold, and left alone")
    }

    /// ⚠️ A held review is exactly when a drifted camera should be fixed: the seek costs the user
    /// nothing while nothing is moving, and it is the only moment four cameras can be made to agree
    /// precisely.
    @Test func aPausedReviewStillCorrectsDrift() {
        let correction = SyncedPlaybackPolicy.correction(
            position: at(58), playhead: playhead(60, paused: true), hasCoverage: true)

        #expect(correction == .seek(to: at(60)))
    }

    // MARK: - Coverage

    /// A camera with nothing recorded at the playhead waits rather than being seeked into a gap.
    /// Acceptance 3: it says "No recording at this time" and rejoins when coverage resumes.
    @Test func aCameraWithNoCoverageWaits() {
        let correction = SyncedPlaybackPolicy.correction(
            position: nil, playhead: playhead(60), hasCoverage: false)

        #expect(correction == .awaitCoverage)
    }

    /// Coverage beats drift: a camera that is both far out and outside its recording is still
    /// waiting, not seeking — seeking it would ask the device for a moment that does not exist,
    /// which `spec-isapi.md` §15.6 says answers 404 or a stream that dies at once.
    @Test func coverageIsCheckedBeforeDrift() {
        let correction = SyncedPlaybackPolicy.correction(
            position: at(10), playhead: playhead(60), hasCoverage: false)

        #expect(correction == .awaitCoverage)
    }

    /// And it rejoins by itself: the same camera, once coverage returns, is seeked without anybody
    /// pressing anything.
    @Test func aCameraRejoinsWhenCoverageReturns() {
        let waiting = SyncedPlaybackPolicy.correction(
            position: nil, playhead: playhead(60), hasCoverage: false)
        let resumed = SyncedPlaybackPolicy.correction(
            position: nil, playhead: playhead(60), hasCoverage: true)

        #expect(waiting == .awaitCoverage)
        #expect(resumed == .seek(to: at(60)))
    }

    // MARK: - The set

    /// Four is the cap the feature's own title carries, and the fifth camera is told to wait rather
    /// than started: a device that is asked for a fifth playback session commonly stops answering
    /// the four that were working.
    @Test func theFifthCameraIsNotStarted() {
        let cameras = Array(repeating: (position: Date?.none, hasCoverage: true), count: 6)

        let corrections = SyncedPlaybackPolicy.corrections(for: cameras, playhead: playhead(60))

        #expect(corrections.prefix(4).allSatisfy { $0 == .seek(to: at(60)) })
        #expect(corrections.suffix(2).allSatisfy { $0 == .awaitCoverage })
    }

    /// Each camera is judged on its own: one drifting does not disturb the three that are fine.
    @Test func eachCameraIsJudgedOnItsOwn() {
        let cameras: [(position: Date?, hasCoverage: Bool)] = [
            (at(60.0), true),
            (at(60.1), true),
            (at(55.0), true),
            (nil, false),
        ]

        let corrections = SyncedPlaybackPolicy.corrections(for: cameras, playhead: playhead(60))

        #expect(corrections == [.hold, .hold, .seek(to: at(60)), .awaitCoverage])
    }

    // MARK: - Measuring the skew

    /// ⛔ Measured **between the cameras**, not against the playhead. Four sessions each 300 ms
    /// behind the playhead are perfectly synchronised with one another, which is what a person
    /// comparing two views actually needs; scoring them against the playhead would report a
    /// failure nobody could see.
    @Test func skewIsMeasuredBetweenCamerasNotAgainstThePlayhead() {
        let positions: [Date?] = [at(59.7), at(59.7), at(59.7)]

        #expect(SyncedPlaybackPolicy.skew(of: positions) == 0)
        #expect(SyncedPlaybackPolicy.isWithinTarget(positions))
    }

    /// The widest gap is the number, not the average: two cameras agreeing does not excuse a third.
    @Test func skewIsTheWidestGap() {
        let positions: [Date?] = [at(60), at(60.05), at(60.4)]

        let skew = SyncedPlaybackPolicy.skew(of: positions) ?? 0
        #expect(abs(skew - 0.4) < 0.001)
        #expect(SyncedPlaybackPolicy.isWithinTarget(positions) == false)
    }

    /// Cameras that are not playing contribute nothing rather than counting as the epoch, which
    /// would report a fifty-six-year skew the first time one tile was waiting for coverage.
    @Test func aCameraThatIsNotPlayingDoesNotWidenTheSkew() {
        let positions: [Date?] = [at(60), nil, at(60.1)]

        let skew = SyncedPlaybackPolicy.skew(of: positions) ?? 0
        #expect(abs(skew - 0.1) < 0.001)
    }

    /// One camera cannot disagree with itself, so there is no skew to report and nothing to fail.
    @Test func oneCameraHasNoSkew() {
        #expect(SyncedPlaybackPolicy.skew(of: [at(60)]) == nil)
        #expect(SyncedPlaybackPolicy.skew(of: [nil, nil]) == nil)
        #expect(SyncedPlaybackPolicy.isWithinTarget([at(60)]))
    }
}
