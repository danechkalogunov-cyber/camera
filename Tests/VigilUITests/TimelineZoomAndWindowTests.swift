//
//  TimelineZoomAndWindowTests.swift
//  VigilUITests
//
//  The zoom ladder (spans, tick intervals, stepping, log-nearest rounding) and the visible-window
//  value type's construction and half-open containment. The day-clamping and zoom-anchoring methods
//  need a TimelineDay and are exercised by the ruler/interaction suites; this covers the arithmetic
//  that stands on its own.
//

#if os(macOS)

import Foundation
import Testing

@testable import VigilUI

@Suite("Timeline zoom and window")
struct TimelineZoomAndWindowTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - Zoom ladder

    @Test func eachStopHasItsDocumentedSpan() {
        #expect(TimelineZoom.day.spanSeconds == 86_400)
        #expect(TimelineZoom.twelveHours.spanSeconds == 43_200)
        #expect(TimelineZoom.hour.spanSeconds == 3_600)
        #expect(TimelineZoom.thirtyMinutes.spanSeconds == 1_800)
        #expect(TimelineZoom.minute.spanSeconds == 60)
    }

    @Test func majorTicksNeverExceedTheSpanAndMinorNeverExceedMajor() {
        for zoom in TimelineZoom.allCases {
            #expect(zoom.majorTickSeconds <= zoom.spanSeconds)
            #expect(zoom.minorTickSeconds <= zoom.majorTickSeconds)
            #expect(zoom.minorTickSeconds > 0)
        }
    }

    /// Stop 0 is the widest, so tightening increments the raw value; both accessors clamp at the ends.
    @Test func tighterAndWiderStepAndClamp() {
        #expect(TimelineZoom.day.tighter == .twelveHours)
        #expect(TimelineZoom.minute.tighter == .minute)  // already tightest
        #expect(TimelineZoom.twelveHours.wider == .day)
        #expect(TimelineZoom.day.wider == .day)  // already widest
        #expect(TimelineZoom.tightest == .minute)
        #expect(TimelineZoom.widest == .day)
    }

    /// `<` means "shows less time", deliberately not the raw order.
    @Test func comparableRunsByVisibleSpan() {
        #expect(TimelineZoom.minute < TimelineZoom.hour)
        #expect(TimelineZoom.hour < TimelineZoom.day)
        #expect(!(TimelineZoom.day < TimelineZoom.minute))
    }

    @Test func nearestRoundsInLogSpaceAndFloorsAtTheTightest() {
        #expect(TimelineZoom.nearest(toSpanSeconds: 3_600) == .hour)
        #expect(TimelineZoom.nearest(toSpanSeconds: 86_400) == .day)
        #expect(TimelineZoom.nearest(toSpanSeconds: 60) == .minute)
        #expect(TimelineZoom.nearest(toSpanSeconds: 0) == .minute)
        #expect(TimelineZoom.nearest(toSpanSeconds: -10) == .minute)
    }

    // MARK: - Window construction

    @Test func aNonPositiveSpanIsFlooredAndANonFiniteOneFallsBackToAnHour() {
        #expect(TimelineWindow(start: t0, spanSeconds: 0).spanSeconds == 1)
        #expect(TimelineWindow(start: t0, spanSeconds: -5).spanSeconds == 1)
        #expect(TimelineWindow(start: t0, spanSeconds: .infinity).spanSeconds == 3_600)
        #expect(TimelineWindow(start: t0, spanSeconds: .nan).spanSeconds == 3_600)
    }

    @Test func aZoomWindowTakesTheStopsNominalSpanAndEndIsExclusive() {
        let window = TimelineWindow(start: t0, zoom: .hour)
        #expect(window.spanSeconds == 3_600)
        #expect(window.end == at(3_600))
    }

    // MARK: - Containment (half-open)

    @Test func containmentIsHalfOpen() {
        let window = TimelineWindow(start: t0, spanSeconds: 100)
        #expect(window.contains(t0))  // the start is inside
        #expect(window.contains(at(50)))
        #expect(!window.contains(at(100)))  // the end is not
        #expect(!window.contains(at(-1)))
    }

    @Test func intersectionIsHalfOpenOnBothEnds() {
        let window = TimelineWindow(start: t0, spanSeconds: 100)
        #expect(window.intersects(from: at(50), to: at(150)))
        #expect(window.intersects(from: at(-50), to: at(50)))
        // A range that only touches the exclusive end does not intersect.
        #expect(!window.intersects(from: at(100), to: at(200)))
        // A range that ends exactly at the start does not intersect.
        #expect(!window.intersects(from: at(-50), to: t0))
    }

    // MARK: - Follow-the-playhead margin

    @Test func comfortablyInsideIsTheMiddleKeepFractionOfTheWindow() {
        let window = TimelineWindow(start: t0, spanSeconds: 1_000)
        // keepFraction 0.8 → 100 s margin at each end, comfortable zone [t0+100, t0+900].
        #expect(window.isComfortablyInside(at(500)))
        #expect(window.isComfortablyInside(at(100)))
        #expect(window.isComfortablyInside(at(900)))
        #expect(!window.isComfortablyInside(at(50)))
        #expect(!window.isComfortablyInside(at(950)))
    }
}

#endif  // os(macOS)
