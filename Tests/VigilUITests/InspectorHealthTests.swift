//
//  InspectorHealthTests.swift
//  VigilUITests
//
//  The five health thresholds the inspector colours its numbers by, straight from DESIGN.md §9.20.
//
//  ⛔ A THRESHOLD TABLE IS EXACTLY THE KIND OF THING THAT DRIFTS UNNOTICED. Nothing crashes when
//  "2 % loss" quietly becomes "20 %"; the only symptom is a stream reported as healthy while the
//  picture breaks up, which is the "no data, no error" shape this project refuses. These tests are
//  the table, written down a second time, so that changing one of the numbers has to be deliberate.
//
//  ⚠️ The boundary direction is the part worth pinning. Every bound is `>=` for the level it opens,
//  so a value sitting exactly on 2 % loss reports `danger`, not `warn` — rounding a boundary in the
//  user's favour is how a fault gets reported as fine.
//

#if os(macOS)

import Foundation
import Testing

@testable import VigilUI
import VigilProtocols

@Suite("Inspector health thresholds")
struct InspectorHealthTests {

    // MARK: - Packet loss

    /// DESIGN.md §9.20: ok below 0.5 %, warn 0.5–2 %, danger above 2 %.
    @Test func lossFollowsTheDesignTable() {
        #expect(InspectorHealth.level(lossFraction: 0) == .ok)
        #expect(InspectorHealth.level(lossFraction: 0.004) == .ok)
        #expect(InspectorHealth.level(lossFraction: 0.005) == .warn, "the bound opens its own level")
        #expect(InspectorHealth.level(lossFraction: 0.019) == .warn)
        #expect(InspectorHealth.level(lossFraction: 0.02) == .danger)
        #expect(InspectorHealth.level(lossFraction: 1) == .danger)
    }

    /// ⚠️ The threshold is a **fraction**, because that is what `StreamStatistics.lossFraction`
    /// holds. Feeding it a percentage — 2 for "2 %" — is the mistake this asserts against: it would
    /// read as 200 % loss and report danger on a healthy stream.
    @Test func lossIsAFractionAndNotAPercentage() {
        #expect(InspectorHealth.lossWarnFraction == 0.005)
        #expect(InspectorHealth.lossDangerFraction == 0.02)
        #expect(InspectorHealth.level(lossFraction: 0.5) == .danger, "half the packets is not 0.5 %")
    }

    // MARK: - Jitter and latency

    /// ok below 20 ms, warn 20–60, danger above 60.
    @Test func jitterFollowsTheDesignTable() {
        #expect(InspectorHealth.level(jitterMilliseconds: 19.9) == .ok)
        #expect(InspectorHealth.level(jitterMilliseconds: 20) == .warn)
        #expect(InspectorHealth.level(jitterMilliseconds: 59.9) == .warn)
        #expect(InspectorHealth.level(jitterMilliseconds: 60) == .danger)
    }

    /// ok below 250 ms, warn 250–600, danger above 600 — the same 250 ms that R3 budgets for
    /// glass-to-glass, so a stream over it is over the requirement.
    @Test func latencyFollowsTheDesignTable() {
        #expect(InspectorHealth.level(latencyMilliseconds: 249) == .ok)
        #expect(InspectorHealth.level(latencyMilliseconds: 250) == .warn)
        #expect(InspectorHealth.level(latencyMilliseconds: 599) == .warn)
        #expect(InspectorHealth.level(latencyMilliseconds: 600) == .danger)
    }

    /// ⛔ Zero latency means "not measured yet", not "instantaneous". The RTCP anchor takes a few
    /// seconds to arrive, and a suspiciously perfect green in the meantime is a claim Vigil cannot
    /// support.
    @Test func anUnmeasuredLatencyIsNotAPerfectScore() {
        #expect(InspectorHealth.level(latencyMilliseconds: 0) == .ok)
        #expect(InspectorHealth.level(latencyMilliseconds: -5) == .ok)
    }

    // MARK: - Decode queue

    /// ⚠️ DESIGN.md §9.20 says ≤2 / 3–5 / >5 and UX.md §6.2 says "> 8 frames = warn", with no
    /// ruling between them. DESIGN's is implemented, being the stricter and the one the shared
    /// thresholds are defined from. This test is where that choice is visible: if the ruling ever
    /// goes the other way, it fails here rather than passing quietly with the wrong table.
    @Test func theQueueDepthFollowsDesignRatherThanUX() {
        #expect(InspectorHealth.level(queueFrames: 2) == .ok)
        #expect(InspectorHealth.level(queueFrames: 3) == .warn)
        #expect(InspectorHealth.level(queueFrames: 5) == .warn)
        #expect(InspectorHealth.level(queueFrames: 6) == .danger)
        #expect(InspectorHealth.level(queueFrames: 8) == .danger, "UX.md would still call this ok")
    }

    // MARK: - Frame rate

    /// The frame-rate level is a *deviation* from the stream's target, not an absolute: 12 fps is
    /// correct for a 12 fps camera and broken for a 25 fps one.
    @Test func theFrameRateIsJudgedAgainstItsTarget() {
        #expect(InspectorHealth.level(framesPerSecond: 25, target: 25) == .ok)
        #expect(InspectorHealth.level(framesPerSecond: 23, target: 25) == .ok, "8 % under")
        #expect(InspectorHealth.level(framesPerSecond: 22.5, target: 25) == .warn, "10 % under")
        #expect(InspectorHealth.level(framesPerSecond: 18, target: 25) == .danger, "28 % under")
        #expect(InspectorHealth.level(framesPerSecond: 12, target: 12) == .ok)
    }

    /// Running *fast* is a deviation too. A camera delivering 30 fps where 25 was asked for is
    /// telling you something — usually that the sub-stream is not the stream you think it is.
    @Test func runningFastIsADeviationAsWell() {
        #expect(InspectorHealth.level(framesPerSecond: 30, target: 25) == .warn, "20 % over")
    }

    /// ⚠️ No target means no verdict. Vigil does not know the intended rate for every stream, and
    /// inventing a fault out of a missing denominator is worse than saying nothing.
    @Test func aMissingTargetReportsNothing() {
        #expect(InspectorHealth.level(framesPerSecond: 25, target: 0) == .ok)
        #expect(InspectorHealth.level(framesPerSecond: 0, target: 25) == .ok)
        #expect(InspectorHealth.level(framesPerSecond: .nan, target: 25) == .ok)
    }

    // MARK: - Non-finite input

    /// ⛔ Every level function survives `NaN` and infinity, because they arrive: a counter divided
    /// by an interval that has not elapsed yet is `NaN`, and it reaches the inspector before the
    /// first second of telemetry does. `NaN` compares false against everything, so an unguarded
    /// `>=` ladder would silently report `ok` — which is the right answer here, but by accident
    /// rather than by decision. These assert the decision.
    @Test func nonFiniteReadingsReportNothingRatherThanTrapping() {
        #expect(InspectorHealth.level(lossFraction: .nan) == .ok)
        #expect(InspectorHealth.level(lossFraction: .infinity) == .ok)
        #expect(InspectorHealth.level(jitterMilliseconds: .nan) == .ok)
        #expect(InspectorHealth.level(latencyMilliseconds: .nan) == .ok)
        #expect(InspectorHealth.level(framesPerSecond: 25, target: .infinity) == .ok)
    }

    // MARK: - The overall level

    /// The header's dot shows the **worst** of the five, because a stream with perfect jitter and
    /// 10 % packet loss is a broken stream.
    @Test func theOverallLevelIsTheWorstOfThem() {
        var stats = StreamStatistics()
        stats.lossFraction = 0.03
        stats.jitterMilliseconds = 1
        stats.estimatedLatencyMilliseconds = 40
        stats.decodeQueueDepth = 0

        #expect(InspectorHealth.overall(stats) == .danger)
    }

    /// A quiet stream is quiet on every axis.
    @Test func aHealthyStreamIsHealthyOverall() {
        var stats = StreamStatistics()
        stats.lossFraction = 0.001
        stats.jitterMilliseconds = 5
        stats.estimatedLatencyMilliseconds = 120
        stats.decodeQueueDepth = 1
        stats.framesPerSecond = 25

        #expect(InspectorHealth.overall(stats, targetFramesPerSecond: 25) == .ok)
    }

    /// A fresh, all-zero sample — what the inspector reads for the first second of every stream —
    /// reports `ok` rather than lighting up because nothing has been measured.
    @Test func aFreshSampleIsNotAFault() {
        #expect(InspectorHealth.overall(StreamStatistics()) == .ok)
    }

    // MARK: - The level type

    /// Severity ordering, which is what `worse(than:)` and the overall reduction depend on.
    @Test func theLevelsAreOrderedBySeverity() {
        #expect(InspectorHealthLevel.ok < .warn)
        #expect(InspectorHealthLevel.warn < .danger)
        #expect(InspectorHealthLevel.ok.worse(than: .danger) == .danger)
        #expect(InspectorHealthLevel.danger.worse(than: .ok) == .danger)
        #expect(InspectorHealthLevel.warn.worse(than: .warn) == .warn)
    }
}

#endif  // os(macOS)
