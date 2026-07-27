//
//  VChromeViewTests.swift
//  VigilUITests
//
//  The pure values behind the window chrome: the aggregate throughput readout, the toast dwell and
//  priority policy, the toast stack limit, and the toolbar layout switcher's ordering.
//  Covers Sources/VigilUI/Chrome/ChromeModel.swift; see docs/DESIGN.md §7.2, §9.17 and
//  docs/UX.md §3.2, §3.3.
//
//  Every function here is prefixed `chrome` because swift-testing attaches `@Test` to free
//  functions and free functions share one namespace per module (docs/BUILD-VERIFICATION.md
//  defect 4). Nothing here renders a view — the layout is checked by eye against the mockup, the
//  arithmetic is checked here.
//

#if os(macOS)

import Testing

@testable import VigilUI

// MARK: - Throughput: units and thresholds

/// The mockup's own figure: `1.8 Gb/s` from 1.8 × 10⁹ bit/s, one decimal.
@Test func chromeThroughputPrintsTheMockupsGigabitRate() {
    let rate = VThroughput(bitsPerSecond: 1_800_000_000)
    #expect(rate.unit == .gigabits)
    #expect(rate.value == "1.8")
    #expect(rate.label == "1.8 Gb/s")
}

/// A single camera's stream sits in `Mb/s`, at one decimal.
@Test func chromeThroughputPrintsMegabitsWithOneDecimal() {
    let rate = VThroughput(bitsPerSecond: 4_100_000)
    #expect(rate.unit == .megabits)
    #expect(rate.label == "4.1 Mb/s")
}

/// Below 1 Mb/s the readout drops to `kb/s` with no decimals, so a 380 kb/s sub-stream does not
/// read `0.4 Mb/s` and throw away the digit the operator is looking at.
@Test func chromeThroughputDropsToKilobitsBelowOneMegabit() {
    let rate = VThroughput(bitsPerSecond: 380_000)
    #expect(rate.unit == .kilobits)
    #expect(rate.label == "380 kb/s")
}

/// The unit promotes half a printed digit early, so no value is ever shown as `1000.0 Mb/s`.
@Test func chromeThroughputPromotesBeforeItWouldPrintFourDigits() {
    #expect(VThroughput(bitsPerSecond: 999_960_000).label == "1.0 Gb/s")
    #expect(VThroughput(bitsPerSecond: 999_900_000).label == "999.9 Mb/s")
    #expect(VThroughput(bitsPerSecond: 999_600).label == "1.0 Mb/s")
    #expect(VThroughput(bitsPerSecond: 999_400).label == "999 kb/s")
}

/// Exactly one SI step is exactly one unit up.
@Test func chromeThroughputTreatsTheSIStepsAsUnitBoundaries() {
    #expect(VThroughput(bitsPerSecond: 1_000_000_000).unit == .gigabits)
    #expect(VThroughput(bitsPerSecond: 1_000_000).unit == .megabits)
    #expect(VThroughput(bitsPerSecond: 1).unit == .kilobits)
}

// MARK: - Throughput: bits versus bytes

/// Bytes are converted exactly once, here: 225 MB/s is 1.8 Gb/s.
@Test func chromeThroughputConvertsBytesPerSecondToBits() {
    let rate = VThroughput.bytesPerSecond(225_000_000)
    #expect(rate.bitsPerSecond == 1_800_000_000)
    #expect(rate.label == "1.8 Gb/s")
}

/// A byte rate is eight times the bit rate it prints, not the other way round — the assertion that
/// catches the conversion being applied on the wrong side.
@Test func chromeThroughputBytesAreEightTimesTheBits() {
    let fromBytes = VThroughput.bytesPerSecond(1_000)
    let fromBits = VThroughput(bitsPerSecond: 8_000)
    #expect(fromBytes == fromBits)
    #expect(fromBytes.label == fromBits.label)
}

// MARK: - Throughput: malformed input

/// Zero, negative, `nan` and `inf` all mean "not measured", which prints an em dash rather than a
/// confident `0.0 Mb/s`. The unit stays `Mb/s` so nothing shifts when the first sample lands.
@Test func chromeThroughputTreatsNonFiniteAndNegativeRatesAsUnmeasured() {
    let bad = [0.0, -1.0, -1_000_000.0, Double.nan, Double.infinity, -Double.infinity]
    for value in bad {
        let rate = VThroughput(bitsPerSecond: value)
        #expect(!rate.isMeasured)
        #expect(rate.bitsPerSecond == 0)
        #expect(rate.unit == .megabits)
        #expect(rate.label == "— Mb/s")
    }
    #expect(VThroughput.bytesPerSecond(Double.nan).label == "— Mb/s")
    #expect(VThroughput.bytesPerSecond(-8).label == "— Mb/s")
    #expect(VThroughput.unmeasured.isMeasured == false)
}

/// An absurd finite rate clamps instead of producing an unbounded string. The rate is a quotient
/// computed elsewhere, and a tiny denominator there must not reach the interface.
@Test func chromeThroughputClampsAnAbsurdFiniteRate() {
    #expect(VThroughput(bitsPerSecond: 1e30).bitsPerSecond == VThroughput.maximum)
    #expect(VThroughput.bytesPerSecond(1e30).bitsPerSecond == VThroughput.maximum)
    #expect(VThroughput(bitsPerSecond: 1e30).unit == .gigabits)
}

// MARK: - Status snapshot

/// Counts cannot go negative, whatever the health monitor hands over.
@Test func chromeStatusClampsNegativeCounts() {
    let status = VChromeStatus(liveCount: -3, degradedCount: -1)
    #expect(status.liveCount == 0)
    #expect(status.degradedCount == 0)
    #expect(status.liveText == "0")
    #expect(!status.isDegraded)
}

/// The amber form appears the moment one camera is degraded, and not before.
@Test func chromeStatusSwitchesToTheDegradedFormOnTheFirstDegradedCamera() {
    #expect(!VChromeStatus(liveCount: 6).isDegraded)
    #expect(!VChromeStatus(liveCount: 6, degradedCount: 0).isDegraded)
    #expect(VChromeStatus(liveCount: 5, degradedCount: 1).isDegraded)
    #expect(VChromeStatus(liveCount: 5, degradedCount: 1).degradedText == "1")
}

/// A status with no rate still prints a unit, so the footer's width does not jump on the first
/// measurement.
@Test func chromeStatusDefaultsToAnUnmeasuredRate() {
    #expect(VChromeStatus(liveCount: 0).throughput.label == "— Mb/s")
}

// MARK: - Toast kinds

/// Only `.error` blocks the automatic dismissal, and only `.error` announces at high priority —
/// §9.17's "indefinite for `.error` (must be dismissed)".
@Test func chromeToastOnlyTheErrorVariantBlocksDismissal() {
    for kind in VToastKind.allCases {
        #expect(kind.blocksAutomaticDismissal == (kind == .error))
        #expect(kind.priority == (kind == .error ? .high : .medium))
    }
}

/// The priority ranking is ordered, so a queue can sort by it without restating the rule.
@Test func chromeToastPriorityIsOrderedByUrgency() {
    #expect(VToastPriority.medium < VToastPriority.high)
    #expect(VToastPriority.allCases.count == 2)
}

// MARK: - Toast dwell policy

/// 4 s without an action — DESIGN.md §7.2's `toastDwell`.
@Test func chromeToastDwellIsFourSecondsWithoutAnAction() async {
    let policy = await MainActor.run { VToastPolicy.resolved(for: .info, hasAction: false) }
    #expect(policy.dwell == Duration.seconds(4))
    #expect(policy.dismissesAutomatically)
}

/// 6 s with one — `toastDwellWithAction`. The reader now has something to read *and* something to
/// decide, which is the whole reason the constant exists.
@Test func chromeToastDwellIsSixSecondsWithAnAction() async {
    for kind in [VToastKind.info, .success, .warning, .motion] {
        let policy = await MainActor.run { VToastPolicy.resolved(for: kind, hasAction: true) }
        #expect(policy.dwell == Duration.seconds(6))
    }
}

/// An error never leaves on its own, with or without an action — an error that vanishes is an
/// error the operator never read.
@Test func chromeToastAutoDismissRespectsPriority() async {
    let withAction = await MainActor.run { VToastPolicy.resolved(for: .error, hasAction: true) }
    let without = await MainActor.run { VToastPolicy.resolved(for: .error, hasAction: false) }
    #expect(withAction.dwell == nil)
    #expect(without.dwell == nil)
    #expect(!withAction.dismissesAutomatically)
    #expect(withAction.priority == .high)
    #expect(without.priority == .high)
}

/// Every variant resolves to a policy, and only the error's is indefinite.
@Test func chromeToastEveryVariantResolvesToAPolicy() async {
    for kind in VToastKind.allCases {
        let policy = await MainActor.run { VToastPolicy.resolved(for: kind, hasAction: false) }
        #expect(policy.dismissesAutomatically == (kind != .error))
    }
}

/// Hovering pauses the timer, so the view asks how much is left after the time it banked. The
/// answer is never negative — a toast hovered for a minute dismisses as soon as the pointer leaves,
/// it does not schedule a sleep into the past.
@Test func chromeToastRemainingCountsDownAndClampsAtZero() {
    let policy = VToastPolicy(dwell: Duration.seconds(4), priority: .medium)
    #expect(policy.remaining(after: .zero) == Duration.seconds(4))
    #expect(policy.remaining(after: .seconds(1)) == Duration.seconds(3))
    #expect(policy.remaining(after: .seconds(4)) == Duration.zero)
    #expect(policy.remaining(after: .seconds(90)) == Duration.zero)
}

/// An indefinite policy reports `nil`, which is not the same as "no time left" — the caller must
/// not turn it into an immediate dismissal.
@Test func chromeToastIndefinitePolicyNeverReportsTimeLeft() {
    let policy = VToastPolicy(dwell: nil, priority: .high)
    #expect(policy.remaining(after: .zero) == nil)
    #expect(policy.remaining(after: .seconds(600)) == nil)
    #expect(!policy.hasExpired(after: .seconds(600)))
    #expect(!policy.dismissesAutomatically)
}

/// Expiry is inclusive at the boundary, so a dwell of exactly its own length is over.
@Test func chromeToastExpiryIsInclusiveAtTheBoundary() {
    let policy = VToastPolicy(dwell: Duration.seconds(6), priority: .medium)
    #expect(!policy.hasExpired(after: .seconds(5)))
    #expect(policy.hasExpired(after: .seconds(6)))
    #expect(policy.hasExpired(after: .seconds(7)))
}

// MARK: - Toast stack

/// Three visible, the rest collapsed — and the two always sum to the queue depth, so a "+0 more"
/// row can never be produced.
@Test func chromeToastStackShowsAtMostThree() {
    #expect(VToastStack.maxVisible == 3)
    for depth in 0...8 {
        let split = VToastStack.split(depth: depth)
        #expect(split.visible == min(depth, 3))
        #expect(split.collapsed == max(0, depth - 3))
        #expect(split.visible + split.collapsed == depth)
    }
}

/// A negative depth cannot come from a queue, but it must not produce a negative row count either.
@Test func chromeToastStackTreatsANegativeDepthAsEmpty() {
    let split = VToastStack.split(depth: -4)
    #expect(split.visible == 0)
    #expect(split.collapsed == 0)
}

// MARK: - Layout switcher

/// The four segments are the mockup's, in the mockup's order: one, four, the 1 + 5 hero, then nine.
@Test func chromeLayoutSwitcherOffersTheMockupsFourStepsInOrder() {
    #expect(VChromeLayoutSwitcher.options == [.single, .grid2x2, .hero1p5, .grid3x3])
    #expect(VChromeLayoutSwitcher.options == VGridLayout.pickerSteps)
    #expect(VChromeLayoutSwitcher.options.map(\.tileCount) == [1, 4, 6, 9])
}

/// The segments are distinct and every one of them is a real layout.
@Test func chromeLayoutSwitcherOffersDistinctRealLayouts() {
    let options = VChromeLayoutSwitcher.options
    #expect(Set(options).count == options.count)
    #expect(options.allSatisfy { VGridLayout.allCases.contains($0) })
    #expect(options.allSatisfy(\.isWellFormed))
}

/// Each segment reports its own index, and nothing else's.
@Test func chromeLayoutSwitcherIndexesEachOfferedLayout() throws {
    #expect(VChromeLayoutSwitcher.selectedIndex(of: .single) == 0)
    #expect(VChromeLayoutSwitcher.selectedIndex(of: .grid2x2) == 1)
    #expect(VChromeLayoutSwitcher.selectedIndex(of: .hero1p5) == 2)
    #expect(VChromeLayoutSwitcher.selectedIndex(of: .grid3x3) == 3)
    let index = try #require(VChromeLayoutSwitcher.selectedIndex(of: .hero1p5))
    #expect(VChromeLayoutSwitcher.options[index] == .hero1p5)
}

/// Exactly one segment lights up for a layout the switcher offers.
@Test func chromeLayoutSwitcherSelectsExactlyOneSegment() {
    for current in VChromeLayoutSwitcher.options {
        let lit = VChromeLayoutSwitcher.options.filter {
            VChromeLayoutSwitcher.isSelected($0, current: current)
        }
        #expect(lit == [current])
    }
}

/// `⌘5`…`⌘8` reach layouts the switcher does not offer. When the stage is on one of those, **no**
/// segment is selected — lighting the nearest one would tell the operator the stage is in a state
/// it is not in.
@Test func chromeLayoutSwitcherLightsNothingForAnUnofferedLayout() {
    let unoffered: [VGridLayout] = [.grid4x4, .hero1p7, .dual2p8, .mosaic4x3]
    for current in unoffered {
        #expect(VChromeLayoutSwitcher.selectedIndex(of: current) == nil)
        #expect(VChromeLayoutSwitcher.options.allSatisfy {
            !VChromeLayoutSwitcher.isSelected($0, current: current)
        })
    }
}

#endif  // os(macOS)
