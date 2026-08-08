//
//  VCycleModelTests.swift
//  VigilUITests
//
//  The patrol's policy: how many pages there are, which one comes next, and what pausing means.
//
//  ⛔ THIS TYPE HAD NO TESTS AND IS NOW LOAD-BEARING. Until F-LIV-06 the cycle only ever moved one
//  camera onto the stage, so a wrong page number cost a wrong picture; `AppSessionModel.showOnStage`
//  now takes the whole page, which means a wrong page number stops and starts a whole screenful of
//  RTSP sessions. Every rule below is one the stage acts on.
//
//  ⚠️ The type holds no clock on purpose — the ticking lives in whichever view owns a timer — so
//  every rotation question here is answered without waiting for wall time.
//

#if os(macOS)

import Foundation
import Testing

@testable import VigilUI

@Suite("The camera cycle")
struct VCycleModelTests {

    // MARK: - The dwell

    /// The dwell is clamped on the way in, so no caller can arm a timer that fires faster than a
    /// page can connect or so slowly that the control looks switched off.
    @Test func theDwellIsClampedOnTheWayIn() {
        #expect(VCycleModel(interval: 0.1).interval == VCycleModel.minimumInterval)
        #expect(VCycleModel(interval: 9_999).interval == VCycleModel.maximumInterval)
        #expect(VCycleModel(interval: 15).interval == 15)
    }

    /// ⚠️ A non-finite dwell resolves to the default rather than propagating. It is what a
    /// mis-parsed preference deserialises to, and a `NaN` in a timer is a timer that never fires —
    /// a patrol that silently stops, with nothing on screen to say why.
    @Test func aNonFiniteDwellFallsBackToTheDefault() {
        #expect(VCycleModel(interval: .nan).interval == VCycleModel.defaultInterval)
        // Infinity is not finite either, so it takes the same road as `NaN` — the default, not the
        // maximum. Worth pinning: "the biggest legal dwell" is the plausible wrong answer.
        #expect(VCycleModel(interval: .infinity).interval == VCycleModel.defaultInterval)
    }

    /// Every dwell the settings menu offers survives the clamp, which is the check that stops the
    /// menu and the clamp drifting apart.
    @Test func everyOfferedDwellIsLegal() {
        for interval in VCycleModel.intervals {
            #expect(VCycleModel(interval: interval).interval == interval)
        }
    }

    // MARK: - Pages

    /// A page is a screenful, so the page count follows the layout rather than the camera count.
    @Test func pagesAreScreenfulsNotCameras() {
        let cycle = VCycleModel()

        #expect(cycle.pageCount(cameraCount: 16, layout: .grid3x3) == 2)
        #expect(cycle.pageCount(cameraCount: 16, layout: .grid4x4) == 1)
        #expect(cycle.pageCount(cameraCount: 17, layout: .grid4x4) == 2)
        #expect(cycle.pageCount(cameraCount: 5, layout: .single) == 5)
    }

    /// An empty stage is one page, not zero: dividing by a page size that could be zero is how a
    /// layout with no cells would trap.
    @Test func thereIsAlwaysAtLeastOnePage() {
        #expect(VCycleModel().pageCount(cameraCount: 0, layout: .grid3x3) == 1)
    }

    /// One page means nothing to cycle through, so the toolbar button is disabled — a lit control
    /// that visibly does nothing is worse than a greyed one.
    @Test func onePageMeansNothingToCycle() {
        let cycle = VCycleModel()

        #expect(cycle.canCycle(cameraCount: 4, layout: .grid2x2) == false)
        #expect(cycle.canCycle(cameraCount: 5, layout: .grid2x2))
        #expect(cycle.canCycle(cameraCount: 0, layout: .single) == false)
    }

    /// The visible range is clipped, so an uneven last page is short rather than out of bounds.
    @Test func theLastPageIsShortRatherThanOutOfBounds() {
        let cycle = VCycleModel(page: 1)

        #expect(cycle.visibleRange(cameraCount: 16, layout: .grid3x3) == 9..<16)
        #expect(cycle.visibleRange(cameraCount: 0, layout: .grid3x3) == 0..<0)
    }

    /// A page index past the end reads as the last page rather than as an empty range — the stage
    /// asks this question during a layout change, before anything has re-anchored the cycle.
    @Test func aPageBeyondTheEndReadsAsTheLastPage() {
        let cycle = VCycleModel(page: 99)

        #expect(cycle.visibleRange(cameraCount: 5, layout: .grid2x2) == 4..<5)
    }

    // MARK: - Rotation

    /// Forward wraps at the end.
    @Test func forwardWrapsAtTheEnd() {
        let running = VCycleModel(order: .forward, isRunning: true, page: 1)

        let next = running.next(cameraCount: 5, layout: .grid2x2)

        #expect(next.page == 0, "two pages, so page 1 wraps to page 0")
    }

    /// Backward wraps the other way, without ever producing a negative index.
    @Test func backwardWrapsWithoutGoingNegative() {
        let running = VCycleModel(order: .backward, isRunning: true, page: 0)

        let next = running.next(cameraCount: 9, layout: .grid2x2)

        #expect(next.page == 2, "three pages, so page 0 wraps to page 2")
    }

    /// ⛔ Ping-pong turns rather than jumping, and the direction is state: page 1 of 3 is reached
    /// both on the way up and on the way down, and nothing in the page number says which.
    @Test func pingPongTurnsAtEachEnd() {
        var cycle = VCycleModel(order: .pingPong, isRunning: true, page: 0)
        var pages: [Int] = [cycle.page]

        for _ in 0..<6 {
            cycle = cycle.next(cameraCount: 9, layout: .grid2x2)
            pages.append(cycle.page)
        }

        #expect(pages == [0, 1, 2, 1, 0, 1, 2], "three pages, walked up and back down")
    }

    /// ⛔ A paused cycle does not move. This is what makes pause mean something: a view that leaks a
    /// timer across a pause cannot drag the stage with it, so the worst a stray clock can do is
    /// waste a wakeup.
    @Test func aPausedCycleDoesNotAdvance() {
        let held = VCycleModel(isRunning: true, isPaused: true, page: 1)

        #expect(held.next(cameraCount: 9, layout: .grid2x2).page == 1)
    }

    /// Nor does a stopped one.
    @Test func aStoppedCycleDoesNotAdvance() {
        let stopped = VCycleModel(isRunning: false, page: 1)

        #expect(stopped.next(cameraCount: 9, layout: .grid2x2).page == 1)
    }

    /// With one page there is nowhere to go, and the cycle returns to page zero rather than sitting
    /// on an index the stage cannot draw.
    @Test func onePageGoesHomeRatherThanNowhere() {
        let running = VCycleModel(isRunning: true, page: 3)

        #expect(running.next(cameraCount: 2, layout: .grid2x2).page == 0)
    }

    // MARK: - Re-anchoring

    /// ⛔ Growing the layout leaves the page index past the end. Re-anchoring is what the stage calls
    /// on every layout change, and without it the next tick would read a range that no longer
    /// exists.
    @Test func aLargerLayoutPullsThePageBackInside() {
        let cycle = VCycleModel(page: 3)

        let anchored = cycle.retargeted(cameraCount: 9, layout: .grid4x4)

        #expect(anchored.page == 0, "nine cameras in sixteen cells is one page")
    }

    /// A page that is already inside the grid is left exactly as it was — including ping-pong's
    /// direction, which a needless reset would lose.
    @Test func aPageThatStillFitsIsUntouched() {
        let cycle = VCycleModel(order: .pingPong, page: 1, isReversing: true)

        let anchored = cycle.retargeted(cameraCount: 9, layout: .grid2x2)

        #expect(anchored == cycle)
    }

    /// Re-anchoring a page that must move resets the ping-pong direction, because "heading down"
    /// from a page that no longer exists means nothing.
    @Test func reanchoringResetsThePingPongDirection() {
        let cycle = VCycleModel(order: .pingPong, page: 5, isReversing: true)

        let anchored = cycle.retargeted(cameraCount: 9, layout: .grid4x4)

        #expect(anchored.isReversing == false)
    }

    // MARK: - Running, pausing and the toolbar

    /// Starting goes back to the top: the operator pressed Cycle to see the wall from the beginning.
    @Test func startingReturnsToTheFirstPage() {
        let started = VCycleModel(isRunning: false, page: 4, isReversing: true).started()

        #expect(started.isRunning)
        #expect(started.isPaused == false)
        #expect(started.page == 0)
        #expect(started.isReversing == false)
    }

    /// Stopping clears the pause flag too, so the next start is not born held.
    @Test func stoppingClearsTheHold() {
        let stopped = VCycleModel(isRunning: true, isPaused: true).stopped()

        #expect(stopped.isRunning == false)
        #expect(stopped.isPaused == false)
    }

    /// The toolbar button is one toggle over those two.
    @Test func theToolbarButtonTogglesRunning() {
        let on = VCycleModel().toggledRunning()
        #expect(on.isRunning)
        #expect(on.toggledRunning().isRunning == false)
    }

    /// ⚠️ Hovering a still stage must not arm a pause. Otherwise the operator's next Cycle press
    /// would start a cycle that is already held, and nothing would move.
    @Test func aStoppedCycleCannotBePaused() {
        let idle = VCycleModel(isRunning: false)

        #expect(idle.paused().isPaused == false)
    }

    /// A running cycle holds and releases, and the page does not move on resume — the dwell simply
    /// starts again.
    @Test func aRunningCycleHoldsAndReleasesWithoutMoving() {
        let running = VCycleModel(isRunning: true, page: 2)

        let held = running.paused()
        #expect(held.isPaused)
        #expect(held.isTicking == false)

        let released = held.resumed()
        #expect(released.isPaused == false)
        #expect(released.isTicking)
        #expect(released.page == 2)
    }

    /// The one question a view's timer asks: running and not held, nothing else.
    @Test func tickingIsRunningAndNotHeld() {
        #expect(VCycleModel(isRunning: true).isTicking)
        #expect(VCycleModel(isRunning: true, isPaused: true).isTicking == false)
        #expect(VCycleModel(isRunning: false, isPaused: false).isTicking == false)
    }

    // MARK: - Settings

    /// Changing the dwell keeps everything else, and clamps the new value like the initialiser does.
    @Test func changingTheDwellKeepsTheRest() {
        let running = VCycleModel(interval: 10, order: .backward, isRunning: true, page: 2)

        let slower = running.withInterval(9_999)

        #expect(slower.interval == VCycleModel.maximumInterval)
        #expect(slower.order == .backward)
        #expect(slower.isRunning)
        #expect(slower.page == 2)
    }

    /// Changing direction resets ping-pong's stored direction, since it belonged to a walk that is
    /// over.
    @Test func changingDirectionResetsTheWalk() {
        let reversing = VCycleModel(order: .pingPong, page: 1, isReversing: true)

        #expect(reversing.withOrder(.forward).isReversing == false)
        #expect(reversing.withOrder(.forward).page == 1, "only the direction is a fact about the walk")
    }
}

#endif  // os(macOS)
