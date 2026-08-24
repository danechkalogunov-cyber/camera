//
//  VCycleModel.swift
//  VigilUI
//
//  The camera cycle (patrol): how long a page stays up, which way the rotation runs, whether it is
//  paused, and which page comes next for a given stage layout. A pure `Sendable` value with no
//  clock in it — the *policy* lives here, the ticking lives in whichever view owns a timer, which
//  is the only arrangement in which the rotation can be tested without waiting for wall time.
//  macOS-only. Implements docs/UX.md §3.2 (the Cycle toolbar control) over the layouts of §5.1.
//

#if os(macOS)

import Foundation

// MARK: - VCycleOrder

/// Which way the cycle walks its pages.
package enum VCycleOrder: String, Sendable, Hashable, CaseIterable, Identifiable {

    /// `0, 1, 2, …, 0` — the default, and the only order most installations ever use.
    case forward

    /// `…, 2, 1, 0, …` — the same rotation run backwards.
    case backward

    /// `0, 1, 2, 1, 0, 1, …` — walks to the end and turns round rather than jumping.
    ///
    /// Worth having on a wall of cameras that are physically arranged in a line: a hard jump from
    /// the far end back to the near end reads as a glitch, a turn does not.
    case pingPong

    /// Stable identity for `ForEach`.
    package var id: String { rawValue }
}

// MARK: - VCycleModel

/// Everything the camera cycle knows about itself.
///
/// ## Pages, not cameras
///
/// The cycle advances a **page** — one screenful of the stage — rather than one camera, because the
/// stage shows `layout.tileCount` cameras at a time and stepping by one camera would scroll the
/// whole wall sideways every few seconds. With sixteen cameras and ``VGridLayout/grid3x3`` there
/// are two pages: cameras 0…8, then 9…15 with the last three tiles empty.
///
/// The layout is therefore an *argument* to every rotation question rather than a stored property.
/// It is owned by the stage, it changes independently of the cycle, and duplicating it here is how
/// the two would end up disagreeing about how many pages exist.
///
/// ## Why every mutator returns a new value
///
/// This type is `Sendable` and has no reference identity, so a caller holds it in `@State` and
/// replaces it. That is what lets the timer policy cross an actor boundary — and what stops a view
/// from reaching in and advancing a paused cycle, since ``next(cameraCount:layout:)`` is the only
/// way forward and it refuses while ``isTicking`` is `false`.
package struct VCycleModel: Sendable, Hashable {

    // MARK: - Tuning

    /// The dwell the toolbar starts with: 10 seconds.
    package static let defaultInterval: TimeInterval = 10

    /// The dwells the settings menu offers, in seconds.
    package static let intervals: [TimeInterval] = [5, 10, 15, 30, 60]

    /// Two seconds. Below this a page cannot finish connecting before it is replaced, so the wall
    /// shows nothing but spinners.
    package static let minimumInterval: TimeInterval = 2

    /// Five minutes. Beyond this the control is indistinguishable from being switched off.
    package static let maximumInterval: TimeInterval = 300

    /// Clamps a dwell into `minimumInterval…maximumInterval`.
    ///
    /// A non-finite input — which is what a mis-parsed preference deserialises to — resolves to
    /// ``defaultInterval`` rather than propagating a `NaN` into a timer that would then never fire.
    package static func clamp(_ interval: TimeInterval) -> TimeInterval {
        guard interval.isFinite else { return defaultInterval }
        return Swift.min(Swift.max(interval, minimumInterval), maximumInterval)
    }

    // MARK: - Stored Properties

    /// How long a page stays up, in seconds. Always within
    /// ``minimumInterval``…``maximumInterval``.
    package let interval: TimeInterval

    /// Which way the rotation runs.
    package let order: VCycleOrder

    /// Whether the operator has switched cycling on. The toolbar's Cycle button lights on this.
    package let isRunning: Bool

    /// Whether a running cycle is temporarily held.
    ///
    /// Distinct from `!isRunning` on purpose: the cycle pauses itself while a menu is open, while
    /// the pointer is over the stage, or while a tile is being dragged, and it must come back on its
    /// own afterwards without pretending the operator switched it off.
    package let isPaused: Bool

    /// The page currently on the stage, counting from zero.
    package let page: Int

    /// For ``VCycleOrder/pingPong`` only: whether the walk is currently heading back down.
    ///
    /// Stored rather than derived because the direction genuinely is state — page 1 of 3 is reached
    /// both on the way up and on the way down, and nothing in the page number says which.
    package let isReversing: Bool

    // MARK: - Initialisation

    /// Creates a cycle policy.
    ///
    /// - Parameters:
    ///   - interval: the dwell in seconds; clamped by ``clamp(_:)``.
    ///   - order: the rotation direction.
    ///   - isRunning: whether cycling is switched on.
    ///   - isPaused: whether a running cycle is held.
    ///   - page: the page on the stage, floored at zero.
    ///   - isReversing: ping-pong direction; ignored by the other two orders.
    package init(
        interval: TimeInterval = VCycleModel.defaultInterval,
        order: VCycleOrder = .forward,
        isRunning: Bool = false,
        isPaused: Bool = false,
        page: Int = 0,
        isReversing: Bool = false
    ) {
        self.interval = VCycleModel.clamp(interval)
        self.order = order
        self.isRunning = isRunning
        self.isPaused = isPaused
        self.page = Swift.max(0, page)
        self.isReversing = isReversing
    }

    // MARK: - State

    /// Whether a clock should currently be running.
    ///
    /// The one question a view's timer asks. Running **and** not paused; nothing else.
    package var isTicking: Bool {
        isRunning && !isPaused
    }

    /// How many pages this many cameras fill at this layout. Never less than one.
    ///
    /// - Parameters:
    ///   - cameraCount: how many cameras are assigned to the stage.
    ///   - layout: the stage's layout, whose ``VGridLayout/tileCount`` is the page size.
    package func pageCount(cameraCount: Int, layout: VGridLayout) -> Int {
        let perPage = Swift.max(1, layout.tileCount)
        guard cameraCount > perPage else { return 1 }
        // Integer ceiling. `Double` division and `ceil` would be exact at these magnitudes, but it
        // would also put a float in the middle of a page index, which is not worth it.
        return (cameraCount + perPage - 1) / perPage
    }

    /// Whether there is anything to cycle *through* at all.
    ///
    /// One page means the Cycle button should be disabled: switching it on would light a control
    /// that then visibly does nothing, which UX.md treats as worse than the control being greyed.
    package func canCycle(cameraCount: Int, layout: VGridLayout) -> Bool {
        pageCount(cameraCount: cameraCount, layout: layout) > 1
    }

    /// The camera indices the current page shows.
    ///
    /// Clipped to `cameraCount`, so the final page of an uneven division is short rather than out of
    /// bounds — the stage leaves those tiles empty.
    package func visibleRange(cameraCount: Int, layout: VGridLayout) -> Range<Int> {
        guard cameraCount > 0 else { return 0..<0 }
        let perPage = Swift.max(1, layout.tileCount)
        let clamped = Swift.min(page, pageCount(cameraCount: cameraCount, layout: layout) - 1)
        let start = Swift.min(clamped * perPage, cameraCount)
        let end = Swift.min(start + perPage, cameraCount)
        return start..<end
    }

    // MARK: - Rotation

    /// The policy one tick later.
    ///
    /// - Parameters:
    ///   - cameraCount: how many cameras are assigned to the stage.
    ///   - layout: the stage's current layout.
    /// - Returns: a copy on the next page, or **this same value** when the cycle is not ticking or
    ///   there is only one page.
    ///
    /// Returning `self` while paused rather than advancing silently is what makes pause mean
    /// something: a view that keeps a stray timer alive across a pause cannot move the stage with
    /// it, so the worst a leaked clock can do is waste a wakeup.
    package func next(cameraCount: Int, layout: VGridLayout) -> VCycleModel {
        guard isTicking else { return self }
        let count = pageCount(cameraCount: cameraCount, layout: layout)
        guard count > 1 else { return with(page: 0, isReversing: false) }
        let current = Swift.min(page, count - 1)
        switch order {
        case .forward:
            return with(page: (current + 1) % count, isReversing: false)
        case .backward:
            return with(page: (current + count - 1) % count, isReversing: false)
        case .pingPong:
            if isReversing {
                // Turn at the bottom: from page 0 the next page is 1, heading up again.
                return current > 0
                    ? with(page: current - 1, isReversing: true)
                    : with(page: 1, isReversing: false)
            }
            // Turn at the top: from the last page the next page is the one before it, heading down.
            return current + 1 < count
                ? with(page: current + 1, isReversing: false)
                : with(page: count - 2, isReversing: true)
        }
    }

    /// The same policy with its page pulled back inside the grid.
    ///
    /// Call it when the layout changes or cameras are added or removed: going from
    /// ``VGridLayout/grid3x3`` to ``VGridLayout/single`` multiplies the page count, and going the
    /// other way leaves ``page`` pointing past the end. Ping-pong's direction is reset with it,
    /// because "heading down" from a page that no longer exists means nothing.
    package func retargeted(cameraCount: Int, layout: VGridLayout) -> VCycleModel {
        let count = pageCount(cameraCount: cameraCount, layout: layout)
        let clamped = Swift.min(page, count - 1)
        guard clamped != page else { return self }
        return with(page: clamped, isReversing: false)
    }

    /// Moves to a page selected outside the automatic patrol, clamped to the current stage.
    package func selectingPage(
        _ requested: Int,
        cameraCount: Int,
        layout: VGridLayout
    ) -> VCycleModel {
        let last = pageCount(cameraCount: cameraCount, layout: layout) - 1
        return with(page: Swift.min(Swift.max(requested, 0), last), isReversing: false)
    }

    // MARK: - Running and pausing

    /// Switched on, unpaused, back at the first page.
    ///
    /// Starting from page 0 rather than resuming where a previous run stopped is deliberate: the
    /// operator pressed Cycle to see the wall from the top.
    package func started() -> VCycleModel {
        with(isRunning: true, isPaused: false, page: 0, isReversing: false)
    }

    /// Switched off, and the pause flag cleared so the next start is not born held.
    package func stopped() -> VCycleModel {
        with(isRunning: false, isPaused: false)
    }

    /// What the toolbar's Cycle button does.
    package func toggledRunning() -> VCycleModel {
        isRunning ? stopped() : started()
    }

    /// Held. A no-op when the cycle is not running, so a hover over a still stage cannot arm a
    /// pause that then suppresses the operator's next Cycle press.
    package func paused() -> VCycleModel {
        guard isRunning else { return self }
        return with(isPaused: true)
    }

    /// Released. The page does not move on resume — the dwell simply starts again.
    package func resumed() -> VCycleModel {
        with(isPaused: false)
    }

    /// Held or released from one flag, which is how a hover or a menu drives it.
    package func paused(_ shouldPause: Bool) -> VCycleModel {
        shouldPause ? paused() : resumed()
    }

    // MARK: - Settings

    /// The same policy at a different dwell, clamped.
    package func withInterval(_ interval: TimeInterval) -> VCycleModel {
        with(interval: interval)
    }

    /// The same policy walking the other way. Ping-pong's direction is reset, since the stored
    /// direction belongs to a walk that is over.
    package func withOrder(_ order: VCycleOrder) -> VCycleModel {
        with(order: order, isReversing: false)
    }

    // MARK: - Private Helpers

    /// One copy-with, so no mutator has to restate all six fields and get one of them wrong.
    private func with(
        interval: TimeInterval? = nil,
        order: VCycleOrder? = nil,
        isRunning: Bool? = nil,
        isPaused: Bool? = nil,
        page: Int? = nil,
        isReversing: Bool? = nil
    ) -> VCycleModel {
        VCycleModel(
            interval: interval ?? self.interval,
            order: order ?? self.order,
            isRunning: isRunning ?? self.isRunning,
            isPaused: isPaused ?? self.isPaused,
            page: page ?? self.page,
            isReversing: isReversing ?? self.isReversing)
    }
}

#endif  // os(macOS)
