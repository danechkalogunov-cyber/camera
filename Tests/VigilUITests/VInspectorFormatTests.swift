//
//  VInspectorFormatTests.swift
//  VigilUITests
//
//  The inspector's value strings — uptime, capacity, percent, duration, PTZ speed, counts — and the
//  sparkline's y-scale. All functions of their arguments, deliberately un-localised so a telemetry
//  readout pasted into a bug report reads the same everywhere.
//

#if os(macOS)

import CoreGraphics
import Foundation
import Testing

@testable import VigilUI

@Suite("Inspector format")
struct VInspectorFormatTests {

    private let dash = VInspectorFormat.placeholder

    // MARK: - Uptime

    @Test func uptimeShowsTwoUnitsAndPadsTheSecond() {
        // Annotated as Int so the compiler need not type-check the literal arithmetic against Double.
        let sixDaysFourHours: Int = 6 * 86_400 + 4 * 3_600 + 12 * 60
        #expect(VInspectorFormat.uptime(seconds: Double(sixDaysFourHours)) == "6 d 04 h")
        let fourHoursTwelve: Int = 4 * 3_600 + 12 * 60
        #expect(VInspectorFormat.uptime(seconds: Double(fourHoursTwelve)) == "4 h 12 m")
        let thirtySevenMinutes: Int = 37 * 60
        #expect(VInspectorFormat.uptime(seconds: Double(thirtySevenMinutes)) == "37 m")
    }

    @Test func uptimeIsADashBeforeItIsKnown() {
        #expect(VInspectorFormat.uptime(seconds: 0) == dash)
        #expect(VInspectorFormat.uptime(seconds: -5) == dash)
        #expect(VInspectorFormat.uptime(seconds: .nan) == dash)
    }

    // MARK: - Capacity (decimal, matching the device's own accounting)

    @Test func capacityScalesThroughDecimalUnits() {
        #expect(VInspectorFormat.capacity(megabytes: 930) == "930 MB")
        #expect(VInspectorFormat.capacity(megabytes: 512_000) == "512 GB")
        #expect(VInspectorFormat.capacity(megabytes: 4_000_000) == "4.0 TB")
    }

    @Test func capacityIsADashWhenNothingWasRead() {
        #expect(VInspectorFormat.capacity(megabytes: 0) == dash)
        #expect(VInspectorFormat.capacity(megabytes: -5) == dash)
    }

    // MARK: - Percent

    @Test func percentIsAWholeNumberWithASpaceAndClamps() {
        #expect(VInspectorFormat.percent(fraction: 0.74) == "74 %")
        #expect(VInspectorFormat.percent(fraction: 0) == "0 %")
        #expect(VInspectorFormat.percent(fraction: 1.02) == "100 %")  // over-full clamps to 100
        #expect(VInspectorFormat.percent(fraction: -0.5) == "0 %")
        #expect(VInspectorFormat.percent(fraction: .nan) == dash)
    }

    // MARK: - Duration

    @Test func durationGrowsFromMinuteSecondsToHourMinuteSeconds() {
        #expect(VInspectorFormat.duration(seconds: 4) == "0:04")
        #expect(VInspectorFormat.duration(seconds: 125) == "2:05")
        #expect(VInspectorFormat.duration(seconds: 3_661) == "1:01:01")
        #expect(VInspectorFormat.duration(seconds: -1) == dash)
        #expect(VInspectorFormat.duration(seconds: .nan) == dash)
    }

    // MARK: - Speed and counts

    @Test func ptzSpeedClampsIntoTheDiscreteRange() {
        #expect(VInspectorFormat.speed(4) == "4 / 7")
        #expect(VInspectorFormat.speed(10) == "7 / 7")
        #expect(VInspectorFormat.speed(0) == "1 / 7")
    }

    @Test func countsFloorAtZeroAndPrintPlainly() {
        #expect(VInspectorFormat.count(-5) == "0")
        #expect(VInspectorFormat.count(42) == "42")
        #expect(VInspectorFormat.count(UInt64(1_000)) == "1000")
    }

    @Test func paddedIsTwoDigitsBelowTen() {
        #expect(VInspectorFormat.padded(0) == "00")
        #expect(VInspectorFormat.padded(9) == "09")
        #expect(VInspectorFormat.padded(10) == "10")
    }

    // MARK: - Sparkline scale

    @Test func upperBoundAddsHeadroomHonoursTheFloorAndStaysPositive() {
        #expect(VInspectorSparklineScale.upperBound([10, 20], floor: 5) == 23)  // 20 × 1.15
        #expect(VInspectorSparklineScale.upperBound([], floor: 5) == 5)
        #expect(VInspectorSparklineScale.upperBound([], floor: 0) == 1)  // never zero
        // A NaN sample is ignored rather than poisoning the maximum.
        #expect(VInspectorSparklineScale.upperBound([.nan, 10], floor: 0) == 11.5)
    }

    @Test func offsetPutsZeroAtTheBottomAndTheBoundAtTheTop() {
        let size = CGSize(width: 10, height: 100)
        #expect(VInspectorSparklineScale.offset(0, size: size, bound: 10) == 100)
        #expect(VInspectorSparklineScale.offset(10, size: size, bound: 10) == 0)
        #expect(VInspectorSparklineScale.offset(5, size: size, bound: 10) == 50)
        // A non-finite sample is dropped to the baseline rather than escaping the box.
        #expect(VInspectorSparklineScale.offset(.nan, size: size, bound: 10) == 100)
    }

    @Test func pointsAreEmptyForAnEmptySeriesOrADegenerateBox() {
        let empty = VInspectorSparklineScale.points([], in: CGSize(width: 10, height: 10), upperBound: 1)
        #expect(empty.isEmpty)
        let flat = CGSize(width: 0, height: 10)
        #expect(VInspectorSparklineScale.points([1, 2], in: flat, upperBound: 1).isEmpty)
    }
}

#endif  // os(macOS)
