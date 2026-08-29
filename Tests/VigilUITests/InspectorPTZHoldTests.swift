//
//  InspectorPTZHoldTests.swift
//  VigilUITests
//
//  The press-and-hold state machine behind the PTZ pad. This type had no tests, and one of the two
//  guards it exists for — the 8 s safety deadline — carried a dead condition that stopped a redirect
//  from restarting it. The suite pins both halves of the deadline rule: a genuine redirect restarts
//  it (the user is still driving), a held key's auto-repeat does not (a stuck key must still stop).
//

#if os(macOS)

import Foundation
import Testing

@testable import VigilUI

@Suite("PTZ press-and-hold")
struct InspectorPTZHoldTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    private let up = InspectorPTZVector.pad(.up, speed: 4)
    private let right = InspectorPTZVector.pad(.right, speed: 4)

    // MARK: - Begin and end

    @Test func aFreshPressStartsTheHoldAndTheClock() {
        var hold = InspectorPTZHold()
        let action = hold.begin(up, at: at(0), direction: .up)
        #expect(action == .start(up))
        #expect(hold.isHolding)
        #expect(hold.direction == .up)
        #expect(hold.elapsed(at: at(2)) == 2)
    }

    @Test func aStoppedVectorIsTreatedAsARelease() {
        var hold = InspectorPTZHold()
        _ = hold.begin(up, at: at(0), direction: .up)
        #expect(hold.begin(.stopped, at: at(1)) == .stop)
        #expect(!hold.isHolding)
    }

    @Test func endingWhileIdleIsHarmless() {
        var hold = InspectorPTZHold()
        #expect(hold.end(at: at(0)) == .none)
    }

    // MARK: - The safety deadline

    /// ⛔ THE REGRESSION THIS SUITE EXISTS FOR. Dragging from one pad sector to another is a redirect,
    /// and a redirect restarts the 8 s deadline because the user is still actively driving. Before the
    /// fix, `begin` tested `self.vector != vector` *after* assigning it — always false — so the
    /// deadline kept counting from the first press and an active drag was cut off with a spurious
    /// safety stop 8 s after the original press rather than 8 s after the redirect.
    @Test func aRedirectRestartsTheSafetyDeadline() {
        var hold = InspectorPTZHold()
        _ = hold.begin(up, at: at(0), direction: .up)
        // Redirect at 5 s: still driving, now to the right.
        #expect(hold.begin(right, at: at(5), direction: .right) == .start(right))
        // 8 s after the original press, but only 3 s after the redirect: the camera keeps moving.
        #expect(hold.tick(at: at(8)) == .none)
        #expect(hold.isHolding)
        // 8 s after the redirect: now the deadline fires.
        #expect(hold.tick(at: at(13)) == .stopExpired)
        #expect(!hold.isHolding)
    }

    /// The other half of the rule: a held key's auto-repeat re-sends the *same* vector, and that must
    /// not extend the deadline — otherwise a stuck key could drive the camera indefinitely.
    @Test func anIdenticalResendDoesNotExtendTheDeadline() {
        var hold = InspectorPTZHold()
        _ = hold.begin(up, at: at(0), direction: .up)
        #expect(hold.begin(up, at: at(5), direction: .up) == .none)
        // Still stops 8 s after the FIRST press, not 8 s after the re-send.
        #expect(hold.tick(at: at(8)) == .stopExpired)
    }

    @Test func theDeadlineFiresExactlyOncePerGesture() {
        var hold = InspectorPTZHold()
        _ = hold.begin(up, at: at(0), direction: .up)
        #expect(hold.tick(at: at(8)) == .stopExpired)
        #expect(hold.tick(at: at(9)) == .none)
        #expect(hold.didExpire)
    }

    @Test func aFreshPressAfterAnExpiryWorksNormally() {
        var hold = InspectorPTZHold()
        _ = hold.begin(up, at: at(0), direction: .up)
        _ = hold.tick(at: at(8))
        // A new press clears the expiry flag and starts a fresh deadline from its own instant.
        #expect(hold.begin(right, at: at(10), direction: .right) == .start(right))
        #expect(!hold.didExpire)
        #expect(hold.tick(at: at(17)) == .none)  // 7 s in
        #expect(hold.tick(at: at(18)) == .stopExpired)  // 8 s in
    }

    // MARK: - Taps

    @Test func aShortGestureIsATap() {
        var hold = InspectorPTZHold()
        _ = hold.begin(up, at: at(0), direction: .up)
        #expect(hold.isTap(endingAt: at(0.2)))
        #expect(!hold.isTap(endingAt: at(0.5)))
    }
}

#endif  // os(macOS)
