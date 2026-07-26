//
//  InspectorPTZHold.swift
//  VigilUI
//
//  The press-and-hold state machine behind the PTZ pad: what a press means, what a release means, and
//  the deadline that stops a camera nobody is holding any more.
//  macOS-only. Implements docs/UX.md §15.3 (optimistic PTZ) and §6.3.
//
//  ⛔ THE FAILURE THIS FILE PREVENTS IS A CAMERA LEFT SPINNING. `PTZController` already defends the
//  wire — 400 ms keep-alive, triple zero-stop, a stop on every error path. This type defends the
//  *gesture*, which is a different problem with a different failure mode: a pointer that leaves the
//  window mid-drag, a key-up delivered to another view, a window closed while a button is held. In
//  every one of those the device is happily receiving keep-alives for a press the user finished, and
//  no amount of care on the wire helps.
//
//  So two independent guards, and the second is the one that matters:
//
//   1. Every ``begin(_:at:)`` is paired with an ``end(at:)``, and the view calls `end` from every exit
//      it has — release, cancel, disappear, window deactivation.
//   2. **A hold expires on its own after ``maximumHoldSeconds`` (8 s), whether or not anyone released
//      it.** UX.md §15.3: "hard stop after 8 s of continuous movement regardless (safety, prevents a
//      runaway camera)". This is the guard that survives the view layer failing to call `end` at all,
//      which is the case the first guard cannot cover by construction.
//
//  The whole thing is a value with an injected clock, so all of the above is testable with no device,
//  no timers and no main actor. The view drives it from a 100 ms tick and obeys what it returns.
//

#if os(macOS)

import Foundation

// MARK: - InspectorPTZDirection

/// One of the eight compass directions of the pad, plus the four lens axes.
///
/// Discrete rather than an analogue vector because UX.md §6.3's pad is eight sectors with a discrete
/// 1…7 speed, which is also the range Hikvision's `continuous` body takes.
///
/// ⚠️ DESIGN.md §9.16 specifies an analogue joystick instead — a 152 pt ring with a draggable thumb,
/// continuous speed from `min(1, |offset| / 52)` through a 1.6 gamma. The two are materially different
/// controls and no `R-` ruling picks one. This slice implements UX.md's, because UX.md is the side R-34
/// made authoritative for structural numbers and because a discrete speed is what the wire accepts
/// without a lossy conversion. ``InspectorPTZVector`` below is deliberately shaped so an analogue pad
/// could produce one too. Reported.
package enum InspectorPTZDirection: String, Sendable, Hashable, CaseIterable {

    case up, down, left, right
    case upLeft, upRight, downLeft, downRight

    /// The pan component, −1…1.
    package var pan: Int {
        switch self {
        case .left, .upLeft, .downLeft: -1
        case .right, .upRight, .downRight: 1
        case .up, .down: 0
        }
    }

    /// The tilt component, −1…1. Positive is up, which is what Hikvision's `continuous` expects.
    package var tilt: Int {
        switch self {
        case .up, .upLeft, .upRight: 1
        case .down, .downLeft, .downRight: -1
        case .left, .right: 0
        }
    }

    /// True for the four diagonals.
    package var isDiagonal: Bool { pan != 0 && tilt != 0 }
}

// MARK: - InspectorPTZVector

/// A resolved PTZ command: the three signed velocities the wire takes.
package struct InspectorPTZVector: Sendable, Hashable {

    /// −100…100.
    package let pan: Int
    /// −100…100.
    package let tilt: Int
    /// −100…100.
    package let zoom: Int

    package init(pan: Int, tilt: Int, zoom: Int) {
        self.pan = Self.clamp(pan)
        self.tilt = Self.clamp(tilt)
        self.zoom = Self.clamp(zoom)
    }

    /// Everything stopped.
    package static let stopped = InspectorPTZVector(pan: 0, tilt: 0, zoom: 0)

    package var isStopped: Bool { pan == 0 && tilt == 0 && zoom == 0 }

    static func clamp(_ value: Int) -> Int { min(100, max(-100, value)) }

    /// The vector for a pad direction at a discrete speed.
    ///
    /// - Parameters:
    ///   - direction: which way.
    ///   - speed: 1…7, Hikvision's range, clamped.
    ///
    /// A diagonal is **not** scaled down by √2. The device's own firmware treats the two axes
    /// independently and normalising them here makes a diagonal noticeably slower than a cardinal move
    /// at the same speed setting, which reads as the control sticking.
    package static func pad(_ direction: InspectorPTZDirection, speed: Int) -> InspectorPTZVector {
        let magnitude = Self.wireSpeed(speed)
        return InspectorPTZVector(pan: direction.pan * magnitude,
                                  tilt: direction.tilt * magnitude,
                                  zoom: 0)
    }

    /// The vector for a zoom rocker at a discrete speed.
    package static func zoom(inward: Bool, speed: Int) -> InspectorPTZVector {
        InspectorPTZVector(pan: 0, tilt: 0, zoom: (inward ? 1 : -1) * Self.wireSpeed(speed))
    }

    /// The discrete 1…7 speed as the −100…100 magnitude the wire wants.
    ///
    /// Speed 7 maps to exactly 100 and speed 1 to 14, so the fastest setting is the device's maximum
    /// and the slowest is genuinely slow. Rounded rather than truncated, so speed 4 is 57 rather than
    /// 57.14 truncated to 57 by accident — the same answer, arrived at on purpose.
    package static func wireSpeed(_ speed: Int) -> Int {
        let clamped = min(speedRange.upperBound, max(speedRange.lowerBound, speed))
        return Int((Double(clamped) / Double(speedRange.upperBound) * 100).rounded())
    }

    /// The discrete speed range of UX.md §6.3.
    package static let speedRange = 1...7
}

// MARK: - InspectorPTZHoldAction

/// What the view should do to the device after a state change.
///
/// Returned rather than performed, so the state machine stays pure and every transition is assertable.
package enum InspectorPTZHoldAction: Sendable, Hashable {

    /// Nothing to do.
    case none

    /// Send a continuous move. The service's own keep-alive takes over from here.
    case start(InspectorPTZVector)

    /// Send the zero-stop.
    case stop

    /// Send the zero-stop **because the safety deadline expired**, not because the user released.
    ///
    /// Distinguished from ``stop`` so the UI can say so: the pad flashes and a toast explains, because
    /// a camera that stopped on its own while the user was still holding the key looks like a fault
    /// unless it is named.
    case stopExpired
}

// MARK: - InspectorPTZHold

/// The press-and-hold state of one PTZ pad.
///
/// ⛔ Deliberately **not** `@MainActor`, despite R-40's rule that every top-level type carries one.
/// It is a `Sendable` value with no reference semantics, exactly like ``ConnectFormState``, and the
/// tests below drive it off the main actor. The view holds it in `@State`, which supplies the isolation.
package struct InspectorPTZHold: Sendable, Hashable {

    /// The hold that is currently running, if any.
    package private(set) var vector: InspectorPTZVector?

    /// When the current hold began, on the injected clock's timeline.
    package private(set) var startedAt: Date?

    /// The direction being held, for the pad's lit sector. `nil` for a zoom or lens hold.
    package private(set) var direction: InspectorPTZDirection?

    /// True once the safety deadline has fired for the current gesture, so the UI can explain itself
    /// and so a second expiry cannot be reported for one press.
    package private(set) var didExpire = false

    /// The discrete speed the pad is set to, 1…7.
    package var speed: Int {
        didSet { speed = min(7, max(1, speed)) }
    }

    /// UX.md §15.3's hard stop. A hold is abandoned after this long **no matter what**.
    package static let maximumHoldSeconds: Double = 8

    /// A tap shorter than this is treated as a nudge rather than a hold, and is answered with a
    /// momentary command that needs no stop at all (UX.md §6.3: "tap = 300 ms pulse").
    package static let tapThresholdSeconds: Double = 0.3

    /// The duration of the momentary pulse a tap sends.
    package static let tapPulseMilliseconds = 300

    package init(speed: Int = 4) {
        self.speed = min(7, max(1, speed))
    }

    /// Whether a hold is running.
    package var isHolding: Bool { vector != nil }

    // MARK: Transitions

    /// Begins, or redirects, a hold.
    ///
    /// Redirecting is a first-class case: dragging from one sector of the pad to another must change
    /// direction without an intervening stop, or the camera stutters at every sector boundary.
    /// `PTZController.move` supersedes the previous keep-alive on its own, so no stop is emitted.
    ///
    /// Beginning a hold clears ``didExpire``, so a fresh press after a safety stop works normally.
    package mutating func begin(_ vector: InspectorPTZVector, at instant: Date,
                                direction: InspectorPTZDirection? = nil) -> InspectorPTZHoldAction {
        guard !vector.isStopped else { return end(at: instant) }
        // An identical vector re-sent for the same gesture is not a new hold — the deadline keeps
        // running from the original press, so holding a key whose auto-repeat fires cannot extend the
        // 8 s safety window indefinitely. That would defeat the entire point of the deadline.
        if self.vector == vector, startedAt != nil {
            self.direction = direction ?? self.direction
            return .none
        }
        self.vector = vector
        self.direction = direction
        if startedAt == nil || self.vector != vector {
            // A redirect restarts the clock, which is correct: the user is still actively driving, and
            // the deadline exists to catch a gesture nobody is driving at all.
            startedAt = instant
        }
        didExpire = false
        return .start(vector)
    }

    /// Ends a hold.
    ///
    /// Safe to call when nothing is held — every exit path the view has calls this, including several
    /// that fire when no gesture is running, and each of them must be harmless. Returns
    /// ``InspectorPTZHoldAction/none`` in that case rather than a redundant stop, because a stop is
    /// three HTTP writes and firing them on every `onDisappear` in the window would be rude.
    package mutating func end(at instant: Date) -> InspectorPTZHoldAction {
        guard vector != nil else { return .none }
        vector = nil
        startedAt = nil
        direction = nil
        return .stop
    }

    /// Whether the gesture that just ended was short enough to be a tap.
    ///
    /// Asked *before* ``end(at:)``, because ending clears the start time.
    package func isTap(endingAt instant: Date) -> Bool {
        guard let startedAt else { return false }
        return instant.timeIntervalSince(startedAt) < Self.tapThresholdSeconds
    }

    /// Drives the safety deadline. The view calls this from its tick.
    ///
    /// Returns ``InspectorPTZHoldAction/stopExpired`` exactly once per gesture, at the first tick at or
    /// after the deadline. The hold is cleared as it fires, so a missed tick cannot leave the state
    /// machine believing a stop was sent when it was not.
    package mutating func tick(at instant: Date) -> InspectorPTZHoldAction {
        guard vector != nil, let startedAt else { return .none }
        guard instant.timeIntervalSince(startedAt) >= Self.maximumHoldSeconds else { return .none }
        vector = nil
        self.startedAt = nil
        direction = nil
        didExpire = true
        return .stopExpired
    }

    /// How long the current hold has been running, or 0 when nothing is held.
    package func elapsed(at instant: Date) -> Double {
        guard let startedAt else { return 0 }
        return max(0, instant.timeIntervalSince(startedAt))
    }

    /// 0…1 progress towards the safety deadline, for the pad's thin arc.
    ///
    /// Shown only in the last two seconds by the view, so a normal press never displays a countdown —
    /// but the value is defined throughout so the view has no special case.
    package func expiryProgress(at instant: Date) -> Double {
        guard isHolding else { return 0 }
        return min(1, max(0, elapsed(at: instant) / Self.maximumHoldSeconds))
    }
}

#endif  // os(macOS)
