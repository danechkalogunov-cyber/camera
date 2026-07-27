//
//  VInspectorViewTests.swift
//  VigilUITests
//
//  The inspector panel's pure parts: the tab order and identity, the value formatting and its unit
//  suffixes, the health-level → tint mapping, the sparkline scale, and the state's derived readings.
//  Covers Sources/VigilUI/Inspector/VInspectorFormat.swift and VInspectorState.swift; see
//  docs/UX.md §6 and docs/DESIGN.md §4.4, §9.20, §9.21.
//
//  ⚠️ Every test function here is prefixed `inspectorView`. swift-testing attaches `@Test` to free
//  functions and free functions share one namespace per module, so two agents choosing the same
//  obvious name takes the whole target down — see docs/BUILD-VERIFICATION.md defect 4.
//
//  Nothing here renders a view. The rules worth testing are the ones a view *reads*: a threshold, a
//  suffix, an order. A test that instantiated a `View` would assert that SwiftUI works.
//

#if os(macOS)

import CoreGraphics
import Foundation
import Testing

import VigilISAPI
import VigilProtocols

@testable import VigilUI

// MARK: - Tabs

/// UX.md §1.3 stores the tab in `@SceneStorage` and §16 binds ⌃1…⌃6 to it positionally, so the
/// order is a compatibility surface rather than a layout preference.
@Test func inspectorViewTabsAreInTheDocumentedOrder() {
    #expect(VInspectorTab.allCases == [.info, .stream, .ptz, .image, .events, .recording])
}

/// The identity is the raw value, which is what `@SceneStorage` persists.
@Test func inspectorViewTabIdentityIsItsRawValue() {
    for tab in VInspectorTab.allCases {
        #expect(tab.id == tab.rawValue)
    }
    #expect(VInspectorTab.recording.rawValue == "recording")
    #expect(VInspectorTab.ptz.rawValue == "ptz")
}

/// ⌃1…⌃6, in order, with no gaps and no duplicates.
@Test func inspectorViewTabShortcutNumbersRunOneToSix() {
    let numbers = VInspectorTab.allCases.map(\.shortcutNumber)
    #expect(numbers == [1, 2, 3, 4, 5, 6])
    #expect(VInspectorTab.info.shortcutNumber == 1)
    #expect(VInspectorTab.recording.shortcutNumber == 6)
}

/// Each tab has its own glyph — a duplicate would make an icon-only bar unreadable.
///
/// Compared by SF Symbol *name* rather than by case: `VTheme.Symbol` declares only `CaseIterable`,
/// and leaning on Swift's implicit `Hashable` synthesis for a type this file does not own is a
/// dependency on a conformance that could be narrowed without warning.
@Test func inspectorViewTabSymbolsAreDistinct() {
    let names = VInspectorTab.allCases.map { $0.symbol.name }
    #expect(Set(names).count == VInspectorTab.allCases.count)
}

// MARK: - Uptime

/// Two units, the second zero-padded so the string cannot change width as it counts.
@Test func inspectorViewUptimeShowsTwoUnits() {
    #expect(VInspectorFormat.uptime(seconds: 6 * 86_400 + 4 * 3_600 + 12 * 60) == "6 d 04 h")
    #expect(VInspectorFormat.uptime(seconds: 4 * 3_600 + 12 * 60) == "4 h 12 m")
    #expect(VInspectorFormat.uptime(seconds: 37 * 60) == "37 m")
}

/// The hours field pads below ten, so `6 d 4 h` never appears one column narrower than `6 d 14 h`.
@Test func inspectorViewUptimePadsItsSecondUnit() {
    #expect(VInspectorFormat.uptime(seconds: 6 * 86_400 + 4 * 3_600) == "6 d 04 h")
    #expect(VInspectorFormat.uptime(seconds: 6 * 86_400 + 14 * 3_600) == "6 d 14 h")
    #expect(VInspectorFormat.uptime(seconds: 3_600 + 5 * 60) == "1 h 05 m")
}

/// A device that has not reported yet shows a dash, not a confident zero.
@Test func inspectorViewUptimeIsADashBeforeTheDeviceHasAnswered() {
    #expect(VInspectorFormat.uptime(seconds: 0) == VInspectorFormat.placeholder)
    #expect(VInspectorFormat.uptime(seconds: -12) == VInspectorFormat.placeholder)
    #expect(VInspectorFormat.uptime(seconds: .nan) == VInspectorFormat.placeholder)
    #expect(VInspectorFormat.uptime(seconds: .infinity) == VInspectorFormat.placeholder)
}

/// Under a minute is still a real reading — the camera did boot.
@Test func inspectorViewUptimeUnderOneMinuteIsZeroMinutes() {
    #expect(VInspectorFormat.uptime(seconds: 30) == "0 m")
}

/// The placeholder is a true em dash, not a hyphen: one glyph for "unknown" everywhere.
@Test func inspectorViewPlaceholderIsAnEmDash() {
    #expect(VInspectorFormat.placeholder == "\u{2014}")
}

// MARK: - Capacity

/// The suffix ladder: MB below a gigabyte, GB below a terabyte, TB above.
@Test func inspectorViewCapacityPicksItsUnitSuffix() {
    #expect(VInspectorFormat.capacity(megabytes: 930) == "930 MB")
    #expect(VInspectorFormat.capacity(megabytes: 512_000) == "512 GB")
    #expect(VInspectorFormat.capacity(megabytes: 4_000_000) == "4.0 TB")
}

/// Decimal megabytes, as `VigilISAPI/StorageInfo.swift` documents the device's own accounting:
/// 1 000 000 MB is exactly 1 TB, and one below it is still gigabytes.
@Test func inspectorViewCapacityUsesDecimalMegabytes() {
    #expect(VInspectorFormat.capacity(megabytes: 1_000_000) == "1.0 TB")
    #expect(VInspectorFormat.capacity(megabytes: 999_000) == "999 GB")
    #expect(VInspectorFormat.capacity(megabytes: 1_000) == "1 GB")
    #expect(VInspectorFormat.capacity(megabytes: 999) == "999 MB")
}

/// A volume reporting nothing has not been read yet; `0 MB` would read as a fault.
@Test func inspectorViewCapacityIsADashWhenTheVolumeReportsNothing() {
    #expect(VInspectorFormat.capacity(megabytes: 0) == VInspectorFormat.placeholder)
    #expect(VInspectorFormat.capacity(megabytes: -1) == VInspectorFormat.placeholder)
}

// MARK: - Percentage

/// Whole numbers, and the space before the sign that both shipping locales use.
@Test func inspectorViewPercentRoundsToWholeNumbers() {
    #expect(VInspectorFormat.percent(fraction: 0.74) == "74 %")
    #expect(VInspectorFormat.percent(fraction: 0.7449) == "74 %")
    #expect(VInspectorFormat.percent(fraction: 0.745) == "75 %")
    #expect(VInspectorFormat.percent(fraction: 0) == "0 %")
}

/// A device reporting more used than it has still draws a full bar rather than an over-full one.
@Test func inspectorViewPercentClampsOutsideZeroToOne() {
    #expect(VInspectorFormat.percent(fraction: 1.6) == "100 %")
    #expect(VInspectorFormat.percent(fraction: -0.2) == "0 %")
    #expect(VInspectorFormat.percent(fraction: .nan) == VInspectorFormat.placeholder)
}

// MARK: - Duration

/// `m:ss`, growing to `h:mm:ss` only when there are hours to show.
@Test func inspectorViewDurationGrowsToHoursOnlyWhenNeeded() {
    #expect(VInspectorFormat.duration(seconds: 8) == "0:08")
    #expect(VInspectorFormat.duration(seconds: 252) == "4:12")
    #expect(VInspectorFormat.duration(seconds: 3_599) == "59:59")
    #expect(VInspectorFormat.duration(seconds: 3_723) == "1:02:03")
}

/// Negative and non-finite lengths are unknown, not zero.
@Test func inspectorViewDurationRejectsImpossibleLengths() {
    #expect(VInspectorFormat.duration(seconds: -1) == VInspectorFormat.placeholder)
    #expect(VInspectorFormat.duration(seconds: .nan) == VInspectorFormat.placeholder)
}

// MARK: - Speed and counts

/// The label can never disagree with the vector the same value produces, so it clamps to
/// `InspectorPTZVector.speedRange`.
@Test func inspectorViewSpeedLabelClampsToTheWireRange() {
    #expect(VInspectorFormat.speed(4) == "4 / 7")
    #expect(VInspectorFormat.speed(7) == "7 / 7")
    #expect(VInspectorFormat.speed(99) == "7 / 7")
    #expect(VInspectorFormat.speed(0) == "1 / 7")
    #expect(VInspectorFormat.speed(-3) == "1 / 7")
}

/// A counter genuinely at zero is information, so zero prints as zero — and never as a negative.
@Test func inspectorViewCountNeverGoesNegative() {
    #expect(VInspectorFormat.count(0) == "0")
    #expect(VInspectorFormat.count(417) == "417")
    #expect(VInspectorFormat.count(-5) == "0")
    #expect(VInspectorFormat.count(UInt64(18_446_744_073_709_551_615)) == "18446744073709551615")
}

// MARK: - Health tint

/// A healthy reading is quiet by default: `text.primary`, not a green.
@Test func inspectorViewHealthTintIsQuietWhenHealthy() {
    #expect(VInspectorHealthTint(.ok) == .neutral)
    #expect(VInspectorHealthTint(.ok, emphasisesHealth: true) == .ok)
}

/// Warning and failure are always coloured, whatever the metric asked for.
@Test func inspectorViewHealthTintAlwaysColoursAProblem() {
    #expect(VInspectorHealthTint(.warn) == .warn)
    #expect(VInspectorHealthTint(.danger) == .danger)
    #expect(VInspectorHealthTint(.warn, emphasisesHealth: true) == .warn)
    #expect(VInspectorHealthTint(.danger, emphasisesHealth: true) == .danger)
}

/// ⛔ The thresholds are `InspectorHealth`'s and are never re-derived in a view. This walks the
/// packet-loss row of DESIGN.md §9.20 through the same `InspectorStat` factory the tab uses.
@Test func inspectorViewHealthTintFollowsInspectorHealthThresholds() {
    #expect(VInspectorHealthTint(InspectorStat.loss(fraction: 0.0002).level,
                                 emphasisesHealth: true) == .ok)
    #expect(VInspectorHealthTint(InspectorStat.loss(fraction: 0.005).level) == .warn)
    #expect(VInspectorHealthTint(InspectorStat.loss(fraction: 0.019).level) == .warn)
    #expect(VInspectorHealthTint(InspectorStat.loss(fraction: 0.02).level) == .danger)
    #expect(VInspectorHealthTint(InspectorStat.jitter(milliseconds: 74).level) == .danger)
    #expect(VInspectorHealthTint(InspectorStat.latency(milliseconds: 300).level) == .warn)
    #expect(VInspectorHealthTint(InspectorStat.decodeQueue(frames: 9).level) == .danger)
}

/// §10.5: only the problem states carry a non-colour partner. A tick beside every healthy row is
/// noise, and the two quiet tints deliberately have no glyph.
@Test func inspectorViewHealthTintCarriesAGlyphOnlyWhenAlarming() {
    #expect(VInspectorHealthTint.neutral.symbol == nil)
    #expect(VInspectorHealthTint.ok.symbol == nil)
    #expect(VInspectorHealthTint.warn.symbol?.name == VTheme.Symbol.warning.name)
    #expect(VInspectorHealthTint.danger.symbol?.name == VTheme.Symbol.error.name)
}

/// The flag VoiceOver uses to decide whether the level is worth announcing.
@Test func inspectorViewHealthTintKnowsWhichCasesAreAlarming() {
    #expect(VInspectorHealthTint.neutral.isAlarming == false)
    #expect(VInspectorHealthTint.ok.isAlarming == false)
    #expect(VInspectorHealthTint.warn.isAlarming)
    #expect(VInspectorHealthTint.danger.isAlarming)
}

// MARK: - Sparkline scale

/// §9.21: `[0, max(observedMax × 1.15, floor)]`.
@Test func inspectorViewSparklineUpperBoundAddsFifteenPercentHeadroom() {
    let bound = VInspectorSparklineScale.upperBound([2, 4, 3], floor: 1)
    #expect(abs(bound - 4.6) < 1e-9)
}

/// The floor stops an idle stream from magnifying its own rounding noise into a mountain range.
@Test func inspectorViewSparklineUpperBoundHonoursItsFloor() {
    let bound = VInspectorSparklineScale.upperBound([0.1, 0.2], floor: 5)
    #expect(abs(bound - 5) < 1e-9)
}

/// A single NaN from a zero-length measurement window must not flatten the whole series.
@Test func inspectorViewSparklineUpperBoundIgnoresNonFiniteSamples() {
    let bound = VInspectorSparklineScale.upperBound([.nan, 3, .infinity], floor: 0)
    #expect(abs(bound - 3.45) < 1e-9)
}

/// Never zero, so the caller can divide by it without a guard.
@Test func inspectorViewSparklineUpperBoundIsAlwaysPositive() {
    #expect(VInspectorSparklineScale.upperBound([], floor: 0) > 0)
    #expect(VInspectorSparklineScale.upperBound([0, 0, 0], floor: 0) > 0)
}

/// Oldest at `x = 0`, newest at the trailing edge, which is the direction "last 60 s" reads in.
@Test func inspectorViewSparklinePointsSpanTheFullWidth() throws {
    let size = CGSize(width: 90, height: 40)
    let points = VInspectorSparklineScale.points([1, 2, 3, 4], in: size, upperBound: 4)
    #expect(points.count == 4)
    let first = try #require(points.first)
    let last = try #require(points.last)
    #expect(abs(first.x - 0) < 1e-9)
    #expect(abs(last.x - 90) < 1e-9)
    // Zero is the bottom of the box, as a chart reads: the maximum sample sits at y = 0.
    #expect(abs(last.y - 0) < 1e-9)
    #expect(abs(first.y - 30) < 1e-9)
}

/// A sample above the bound clamps to the top edge instead of escaping the well.
@Test func inspectorViewSparklinePointsClampAboveTheUpperBound() throws {
    let size = CGSize(width: 10, height: 20)
    let points = VInspectorSparklineScale.points([0, 80], in: size, upperBound: 4)
    let last = try #require(points.last)
    #expect(abs(last.y - 0) < 1e-9)
    let first = try #require(points.first)
    #expect(abs(first.y - 20) < 1e-9)
}

/// An empty series draws §9.21's empty state, not a path through nothing.
@Test func inspectorViewSparklinePointsAreEmptyForAnEmptySeries() {
    let size = CGSize(width: 90, height: 40)
    #expect(VInspectorSparklineScale.points([], in: size, upperBound: 4).isEmpty)
    #expect(VInspectorSparklineScale.points([1, 2], in: .zero, upperBound: 4).isEmpty)
    #expect(VInspectorSparklineScale.points([1, 2], in: size, upperBound: 0).isEmpty)
}

/// One sample is pinned to the trailing edge, where the newest sample lives.
@Test func inspectorViewSparklineSinglePointSitsAtTheTrailingEdge() throws {
    let size = CGSize(width: 90, height: 40)
    let points = VInspectorSparklineScale.points([2], in: size, upperBound: 4)
    #expect(points.count == 1)
    let only = try #require(points.first)
    #expect(abs(only.x - 90) < 1e-9)
    #expect(abs(only.y - 20) < 1e-9)
}

// MARK: - Derived state

/// The sparkline reads the samples' bitrate in the order it was given them.
@Test func inspectorViewStateDerivesItsBitrateSeriesFromTheSamples() {
    var first = StreamStatistics()
    first.bitsPerSecond = 1_000
    var second = StreamStatistics()
    second.bitsPerSecond = 2_000
    let state = VInspectorState(recentStatistics: [first, second])
    #expect(state.bitrateSeries == [1_000, 2_000])
    #expect(state.lossSeries == [0, 0])
}

/// The bar shows what is **used**, and the device reports what is free — getting this backwards
/// would draw a full disk as an empty one.
@Test func inspectorViewStateStorageFractionIsUsedNotFree() throws {
    let storage = StorageInfo(volumes: [inspectorViewVolume(capacityMB: 4_000_000,
                                                            freeSpaceMB: 1_040_000)],
                              workMode: "group")
    let state = VInspectorState(storage: storage)
    let used = try #require(state.storageUsedFraction)
    #expect(abs(used - 0.74) < 1e-9)
    #expect(state.storageCapacityMB == 4_000_000)
}

/// Capacity is summed across every volume, which is what the Device block prints.
@Test func inspectorViewStateStorageSumsEveryVolume() throws {
    let storage = StorageInfo(volumes: [inspectorViewVolume(capacityMB: 2_000_000,
                                                            freeSpaceMB: 1_000_000),
                                        inspectorViewVolume(capacityMB: 2_000_000,
                                                            freeSpaceMB: 0)],
                              workMode: "group")
    let state = VInspectorState(storage: storage)
    #expect(state.storageCapacityMB == 4_000_000)
    let used = try #require(state.storageUsedFraction)
    #expect(abs(used - 0.75) < 1e-9)
}

/// No storage document, or a device reporting no capacity, is *unknown* rather than empty.
@Test func inspectorViewStateStorageIsUnknownWithoutCapacity() {
    #expect(VInspectorState().storageCapacityMB == nil)
    #expect(VInspectorState().storageUsedFraction == nil)
    let empty = StorageInfo(volumes: [inspectorViewVolume(capacityMB: 0, freeSpaceMB: 0)],
                            workMode: "group")
    #expect(VInspectorState(storage: empty).storageUsedFraction == nil)
}

/// The header's dot shows the **worst** metric in the sample, not an average of them.
@Test func inspectorViewStateOverallHealthTakesTheWorstMetric() {
    var statistics = StreamStatistics()
    statistics.lossFraction = 0
    statistics.jitterMilliseconds = 2
    statistics.estimatedLatencyMilliseconds = 80
    statistics.decodeQueueDepth = 1
    #expect(VInspectorState(statistics: statistics).overallHealth == .ok)

    statistics.jitterMilliseconds = 74
    #expect(VInspectorState(statistics: statistics).overallHealth == .danger)
}

/// A camera that is not recording is the default, and its elapsed time is zero rather than stale.
@Test func inspectorViewRecordingStateDefaultsToIdle() {
    let recording = VInspectorRecordingState()
    #expect(recording.isRecording == false)
    #expect(recording.elapsedSeconds == 0)
    #expect(recording.destination == nil)
    #expect(recording.clipsToday == 0)
}

/// The panel is never blank: with no camera the state still resolves, and the view routes to the
/// "no camera selected" copy rather than to a tab.
@Test func inspectorViewStateWithoutACameraIsStillValid() {
    let state = VInspectorState()
    #expect(state.camera == nil)
    #expect(state.bitrateSeries.isEmpty)
    #expect(state.overallHealth == .ok)
}

// MARK: - Event day grouping

/// A day group is identified by its midnight, so two groups on one day cannot both exist.
@Test func inspectorViewEventDayIsIdentifiedByItsMidnight() {
    let midnight = Date(timeIntervalSince1970: 1_700_000_000)
    let group = VInspectorEventDay(day: midnight, events: [])
    #expect(group.id == midnight)
}

// MARK: - Helpers

/// A synthesised volume. ⚠️ Not captured from hardware — the figures are chosen to make the
/// arithmetic above readable.
private func inspectorViewVolume(capacityMB: Int, freeSpaceMB: Int) -> StorageVolume {
    StorageVolume(id: 1,
                  name: "HDD1",
                  kind: .sata,
                  status: .ok,
                  capacityMB: capacityMB,
                  freeSpaceMB: freeSpaceMB,
                  isReadOnly: false)
}

#endif  // os(macOS)
