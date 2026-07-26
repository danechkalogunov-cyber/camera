//
//  ProgressEstimatorTests.swift
//  VigilDiscoveryTests
//
//  Progress arithmetic: the weighted fraction and its monotonic guard, the EWMA ETA with its
//  suppression and upward-drift rules, the 20 Hz emission throttle, and the degenerate cases —
//  zero hosts, one host, and a run cancelled midway.
//  Covers docs/spec-discovery.md §8.1–§8.3; tests 79–82 of §13.7.
//

import Foundation
import Testing

import VigilProtocols
@testable import VigilDiscovery

@Suite struct DiscoveryProgressEstimatorBehaviour {

    // MARK: - Degenerate cases

    /// Zero planned hosts — a multicast-only "Refresh". The sweep half of the fraction is complete
    /// from the start and no ETA is invented.
    @Test func progressEstimatorHandlesZeroHosts() {
        var estimator = DiscoveryProgressEstimator(hostsPlanned: 0)
        #expect(estimator.portProbesPlanned == 0)
        let early = estimator.snapshot(at: .milliseconds(100))
        #expect(early.fraction == nil)                     // indeterminate for the first 300 ms
        let later = estimator.snapshot(at: .seconds(1))
        #expect(later.fraction == 1.0)
        #expect(later.estimatedRemaining == nil)
        #expect(later.hostsPlanned == 0)
        #expect(later.throughputHostsPerSecond == 0)
    }

    /// A negative host count cannot happen but must not produce a negative denominator either.
    @Test func progressEstimatorClampsNegativeHostCounts() {
        var estimator = DiscoveryProgressEstimator(hostsPlanned: -10, portsPerHost: -2)
        #expect(estimator.hostsPlanned == 0)
        #expect(estimator.portProbesPlanned == 0)
        let progress = estimator.snapshot(at: .seconds(1))
        #expect(progress.fraction == 1.0)
    }

    /// One host: the fraction reaches 1 exactly when its two tier A probes complete.
    @Test func progressEstimatorHandlesASingleHost() {
        var estimator = DiscoveryProgressEstimator(hostsPlanned: 1)
        #expect(estimator.portProbesPlanned == 2)
        let atStart = estimator.snapshot(at: .milliseconds(400))
        #expect(atStart.fraction == 0.25)                  // multicast weight only, no window
        estimator.completePortProbes(2)
        estimator.completeHost(alive: true)
        let atEnd = estimator.snapshot(at: .milliseconds(500))
        #expect(atEnd.fraction == 1.0)
        #expect(atEnd.hostsProbed == 1)
        #expect(atEnd.hostsAlive == 1)
    }

    /// Cancelled midway: the bar freezes where it was and the ETA disappears rather than counting
    /// down work that will never happen.
    @Test func progressEstimatorFreezesOnCancellation() {
        var estimator = DiscoveryProgressEstimator(hostsPlanned: 254,
                                                   multicastWindow: .seconds(3.5))
        estimator.completePortProbes(254)
        for _ in 0..<127 { estimator.completeHost(alive: false) }
        estimator.tick(at: .seconds(1))
        let before = estimator.snapshot(at: .seconds(1))
        #expect(before.estimatedRemaining != nil)
        let frozenFraction = before.fraction

        estimator.cancel()
        let after = estimator.snapshot(at: .seconds(2))
        #expect(estimator.isCancelled)
        #expect(after.estimatedRemaining == nil)
        #expect(after.fraction == frozenFraction)
        #expect(after.multicastWindowRemaining == .zero)
        #expect(after.hostsProbed == 127)                  // partial results survive
    }

    // MARK: - Fraction

    /// Test 79: tier B growing the denominator slows the bar, never reverses it.
    @Test func progressEstimatorFractionIsMonotonic() throws {
        var estimator = DiscoveryProgressEstimator(hostsPlanned: 100)   // 200 tier A probes
        estimator.completePortProbes(100)
        let halfSnapshot = estimator.snapshot(at: .seconds(1))
        let half = try #require(halfSnapshot.fraction)
        #expect(abs(half - 0.625) < 1e-9)                  // 0.75 × 0.5 + 0.25 × 1

        estimator.schedulePortProbes(200)                  // tier B doubles the work
        let grownSnapshot = estimator.snapshot(at: .seconds(2))
        let afterGrowth = try #require(grownSnapshot.fraction)
        #expect(afterGrowth == half)

        estimator.completePortProbes(200)
        let laterSnapshot = estimator.snapshot(at: .seconds(3))
        let later = try #require(laterSnapshot.fraction)
        #expect(later > half)
        #expect(later <= 1.0)
    }

    /// The multicast window contributes its own quarter of the bar as it elapses.
    @Test func progressEstimatorWeighsTheMulticastWindow() throws {
        var estimator = DiscoveryProgressEstimator(hostsPlanned: 0,
                                                   multicastWindow: .seconds(4))
        let atOneSecond = estimator.snapshot(at: .seconds(1))
        let quarterElapsed = try #require(atOneSecond.fraction)
        #expect(abs(quarterElapsed - (0.75 + 0.25 * 0.25)) < 1e-9)
        #expect(atOneSecond.multicastWindowRemaining == .seconds(3))
        let atFiveSeconds = estimator.snapshot(at: .seconds(5))
        #expect(atFiveSeconds.fraction == 1.0)
    }

    /// More completions than planned cannot push the fraction past 1.
    @Test func progressEstimatorClampsFractionAtOne() throws {
        var estimator = DiscoveryProgressEstimator(hostsPlanned: 10)
        estimator.completePortProbes(1_000)
        let progress = estimator.snapshot(at: .seconds(1))
        #expect(progress.fraction == 1.0)
    }

    // MARK: - ETA

    /// Test 81: no ETA in the first 750 ms, and none while throughput is below half a host a second.
    @Test func progressEstimatorSuppressesEarlyAndSlowETAs() {
        var estimator = DiscoveryProgressEstimator(hostsPlanned: 1_000)
        for _ in 0..<100 { estimator.completeHost(alive: true) }
        estimator.tick(at: .milliseconds(500))
        let tooEarly = estimator.snapshot(at: .milliseconds(700))
        let lateEnough = estimator.snapshot(at: .milliseconds(800))
        #expect(tooEarly.estimatedRemaining == nil)
        #expect(lateEnough.estimatedRemaining != nil)

        var crawling = DiscoveryProgressEstimator(hostsPlanned: 1_000)
        crawling.tick(at: .seconds(10))                    // ten seconds, no completions
        let stalled = crawling.snapshot(at: .seconds(10))
        #expect(stalled.estimatedRemaining == nil)
    }

    /// The EWMA itself: the first sample seeds it, later samples smooth it at α = 0.2.
    @Test func progressEstimatorSeedsThenSmoothsThroughput() {
        var estimator = DiscoveryProgressEstimator(hostsPlanned: 1_000)
        for _ in 0..<100 { estimator.completeHost(alive: true) }
        estimator.tick(at: .seconds(1))
        let seeded = estimator.snapshot(at: .seconds(1))
        #expect(abs(seeded.throughputHostsPerSecond - 100) < 1e-9)

        // A second later with no completions: 0.2 × 0 + 0.8 × 100.
        estimator.tick(at: .seconds(2))
        let smoothed = estimator.snapshot(at: .seconds(2))
        #expect(abs(smoothed.throughputHostsPerSecond - 80) < 1e-9)
    }

    /// A tick with no elapsed time is ignored rather than dividing by zero.
    @Test func progressEstimatorIgnoresZeroLengthTicks() {
        var estimator = DiscoveryProgressEstimator(hostsPlanned: 100)
        estimator.completeHost(alive: true)
        estimator.tick(at: .zero)
        let progress = estimator.snapshot(at: .seconds(1))
        #expect(progress.throughputHostsPerSecond == 0)
    }

    /// The ETA is the remaining hosts over the smoothed rate.
    @Test func progressEstimatorEstimatesRemainingFromThroughput() throws {
        var estimator = DiscoveryProgressEstimator(hostsPlanned: 1_000)
        for _ in 0..<100 { estimator.completeHost(alive: true) }
        estimator.tick(at: .seconds(1))
        let progress = estimator.snapshot(at: .seconds(1))
        let eta = try #require(progress.estimatedRemaining)
        #expect(eta == .seconds(9))                        // 900 hosts at 100/s
    }

    /// Test 82: a throughput collapse may not make the displayed ETA jump — at most +20 %.
    @Test func progressEstimatorClampsUpwardETADrift() throws {
        var estimator = DiscoveryProgressEstimator(hostsPlanned: 1_000)
        for _ in 0..<100 { estimator.completeHost(alive: true) }
        estimator.tick(at: .seconds(1))
        let firstSnapshot = estimator.snapshot(at: .seconds(1))
        let first = try #require(firstSnapshot.estimatedRemaining)
        #expect(first == .seconds(9))

        // Everything stalls: the raw estimate would be 900 / 80 = 11.25 s.
        estimator.tick(at: .seconds(2))
        let secondSnapshot = estimator.snapshot(at: .seconds(2))
        let second = try #require(secondSnapshot.estimatedRemaining)
        #expect(second == .seconds(9 * 1.2))

        // It keeps rising by no more than 20 % per emission.
        estimator.tick(at: .seconds(3))
        let thirdSnapshot = estimator.snapshot(at: .seconds(3))
        let third = try #require(thirdSnapshot.estimatedRemaining)
        #expect(third == .seconds(9 * 1.2 * 1.2))
    }

    /// A falling ETA is not clamped: good news arrives immediately.
    @Test func progressEstimatorLetsETAFallFreely() throws {
        var estimator = DiscoveryProgressEstimator(hostsPlanned: 1_000)
        for _ in 0..<100 { estimator.completeHost(alive: true) }
        estimator.tick(at: .seconds(1))
        _ = estimator.snapshot(at: .seconds(1))
        for _ in 0..<800 { estimator.completeHost(alive: true) }
        estimator.tick(at: .seconds(2))
        let progress = estimator.snapshot(at: .seconds(2))
        let eta = try #require(progress.estimatedRemaining)
        #expect(eta < .seconds(9))
    }

    /// With no sweep estimate but multicast still listening, the known wait is reported on its own.
    @Test func progressEstimatorReportsMulticastWaitWithoutSweepThroughput() throws {
        var estimator = DiscoveryProgressEstimator(hostsPlanned: 0,
                                                   multicastWindow: .seconds(3.5))
        let progress = estimator.snapshot(at: .seconds(1))
        let eta = try #require(progress.estimatedRemaining)
        #expect(eta == .seconds(2.5))
    }

    /// The display rounding: coarse on purpose, so nobody watches a per-second countdown.
    @Test func progressEstimatorFormatsETAForDisplay() {
        func text(_ seconds: Double) -> String? {
            DiscoveryProgress(estimatedRemaining: .seconds(seconds)).estimatedRemainingText
        }
        #expect(text(0.4) == "a moment")
        #expect(text(2.9) == "a moment")
        #expect(text(12) == "about 12 seconds")
        #expect(text(59) == "about 59 seconds")
        #expect(text(61) == "about 1 minute")
        #expect(text(200) == "about 3 minutes")
        #expect(DiscoveryProgress().estimatedRemainingText == nil)
    }

    // MARK: - Emission throttle

    /// Test 80: at most 20 progress events per second, but a device event always forces one.
    @Test func progressEstimatorThrottlesEmissionsToTwentyHertz() {
        var estimator = DiscoveryProgressEstimator(hostsPlanned: 10_000)
        let atZero = estimator.shouldEmit(at: .zero)
        let atTen = estimator.shouldEmit(at: .milliseconds(10))
        let atFortyNine = estimator.shouldEmit(at: .milliseconds(49))
        let atFifty = estimator.shouldEmit(at: .milliseconds(50))
        let atSixty = estimator.shouldEmit(at: .milliseconds(60))
        let forced = estimator.shouldEmit(at: .milliseconds(60), force: true)
        let afterForced = estimator.shouldEmit(at: .milliseconds(70))
        #expect(atZero)
        #expect(!atTen)
        #expect(!atFortyNine)
        #expect(atFifty)
        #expect(!atSixty)
        #expect(forced)
        #expect(!afterForced)

        // Ten thousand completions inside one virtual second yield no more than 21 emissions.
        var counter = DiscoveryProgressEstimator(hostsPlanned: 10_000)
        var emissions = 0
        for step in 0..<10_000 {
            counter.completeHost(alive: false)
            let now = Duration.microseconds(step * 100)     // 10 000 steps across one second
            if counter.shouldEmit(at: now) { emissions += 1 }
        }
        #expect(emissions <= 21)
        #expect(emissions >= 20)
    }

    /// Events that must force a progress emission, per §8.1.
    @Test func progressEstimatorIdentifiesForcingEvents() {
        let device = DiscoveredDevice(id: .endpoint(IPv4Address(192, 168, 1, 64), 80),
                                     address: IPv4Address(192, 168, 1, 64),
                                     firstSeen: Date(timeIntervalSince1970: 0),
                                     lastSeen: Date(timeIntervalSince1970: 0))
        #expect(DiscoveryEvent.deviceFound(device).forcesProgressEmission)
        #expect(DiscoveryEvent.deviceUpdated(device, changes: [.mac]).forcesProgressEmission)
        #expect(DiscoveryEvent.deviceMerged(absorbed: [], into: device.id).forcesProgressEmission)
        #expect(!DiscoveryEvent.progress(DiscoveryProgress()).forcesProgressEmission)
        #expect(DiscoveryEvent.deviceFound(device).isDeviceFound)
        #expect(!DiscoveryEvent.deviceUpdated(device, changes: []).isDeviceFound)
    }

    // MARK: - Counters

    /// The device counters come straight from the merge engine and are reported verbatim.
    @Test func progressEstimatorReportsDeviceCounters() {
        var estimator = DiscoveryProgressEstimator(hostsPlanned: 254)
        estimator.setDeviceCounts(found: 3, candidates: 11)
        let progress = estimator.snapshot(at: .seconds(1), phase: .sweepA,
                                          activePhases: [.sweepA, .sadp])
        #expect(progress.devicesFound == 3)
        #expect(progress.candidatesFound == 11)
        #expect(progress.phase == .sweepA)
        #expect(progress.activePhases == [.sweepA, .sadp])
        #expect(progress.elapsed == .seconds(1))
    }

    /// Phase labels exist for every case, and the narrowest active phase sorts last.
    @Test func progressEstimatorPhaseOrderingIsBySpecificity() {
        #expect(DiscoveryPhase.allCases.allSatisfy { !$0.label.isEmpty })
        let narrowest = DiscoveryPhase.allCases.max { $0.specificity < $1.specificity }
        #expect(narrowest == .finished)
        #expect(DiscoveryPhase.fingerprint.specificity > DiscoveryPhase.sweepA.specificity)
    }
}
