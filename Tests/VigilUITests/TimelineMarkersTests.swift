//
//  TimelineMarkersTests.swift
//  VigilUITests
//
//  The marker model: severity ordering, the three-second seek lead, cluster reads, and the
//  event-to-event steppers. The pixel clustering in `lay(out:in:)` needs a TimelineGeometry and is
//  covered by the ruler suite; this covers the arithmetic that stands on its own.
//

#if os(macOS)

import Foundation
import Testing

@testable import VigilUI

@Suite("Timeline markers")
struct TimelineMarkersTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }
    private func marker(_ seconds: Double, _ kind: TimelineMarkerKind) -> TimelineMarker {
        TimelineMarker(id: UUID(), instant: at(seconds), kind: kind, label: "event")
    }

    // MARK: - Kind

    /// A bookmark is never masked by an automatic event; otherwise severity runs alarm → motion.
    @Test func severityOrdersBookmarkHighestAndMotionLowest() {
        #expect(TimelineMarkerKind.bookmark.severity > TimelineMarkerKind.alarm.severity)
        #expect(TimelineMarkerKind.alarm.severity > TimelineMarkerKind.videoLoss.severity)
        #expect(TimelineMarkerKind.videoLoss.severity > TimelineMarkerKind.tamper.severity)
        #expect(TimelineMarkerKind.tamper.severity > TimelineMarkerKind.intrusion.severity)
        #expect(TimelineMarkerKind.intrusion.severity > TimelineMarkerKind.lineCrossing.severity)
        #expect(TimelineMarkerKind.lineCrossing.severity > TimelineMarkerKind.motion.severity)
    }

    @Test func onlyTheBookmarkDrawsAsAPennant() {
        #expect(TimelineMarkerKind.bookmark.isPennant)
        #expect(!TimelineMarkerKind.motion.isPennant)
        #expect(!TimelineMarkerKind.alarm.isPennant)
    }

    // MARK: - Seek lead

    /// Clicking a marker seeks to three seconds before it, so the clip shows the lead-in.
    @Test func seekInstantLeadsTheMarkerByThreeSeconds() {
        #expect(marker(10, .motion).seekInstant == at(7))
        #expect(TimelineMarker.seekLeadSeconds == 3)
    }

    // MARK: - Cluster

    @Test func aClusterReportsItsCountIsClusterFlagAndFirstMarkerIdentity() {
        let first = marker(10, .motion)
        let second = marker(11, .motion)
        let cluster = TimelineMarkerCluster(markers: [first, second], x: 42)
        #expect(cluster.count == 2)
        #expect(cluster.isCluster)
        #expect(cluster.id == first.id)
        #expect(cluster.x == 42)
        #expect(cluster.seekInstant == first.seekInstant)
    }

    @Test func aLoneMarkerIsNotACluster() {
        let cluster = TimelineMarkerCluster(markers: [marker(10, .motion)], x: 0)
        #expect(cluster.count == 1)
        #expect(!cluster.isCluster)
    }

    /// The most severe member colours the glyph, even when it is not the first.
    @Test func dominantKindIsTheMostSevereMember() {
        let cluster = TimelineMarkerCluster(
            markers: [marker(10, .motion), marker(11, .alarm), marker(12, .lineCrossing)],
            x: 0)
        #expect(cluster.dominantKind == .alarm)
    }

    // MARK: - Stepping

    @Test func nextAndPreviousFindTheNearestMarkerOnEitherSide() {
        let markers = [marker(10, .motion), marker(20, .motion), marker(30, .motion)]
        #expect(TimelineMarkerLayout.next(after: at(15), in: markers)?.instant == at(20))
        #expect(TimelineMarkerLayout.previous(before: at(25), in: markers)?.instant == at(20))
        #expect(TimelineMarkerLayout.next(after: at(30), in: markers) == nil)
        #expect(TimelineMarkerLayout.previous(before: at(10), in: markers) == nil)
    }

    /// ⛔ Stepping compares `seekInstant`, not `instant`, so two forward steps never return the same
    /// marker — the playhead lands three seconds *before* the marker, and a stepper on the raw instant
    /// would find it again.
    @Test func steppingAdvancesEvenThoughLandingIsThreeSecondsEarly() {
        let markers = [marker(10, .motion), marker(20, .motion), marker(30, .motion)]
        // Land on the first marker: the playhead is now at its seek instant (7 s).
        let firstStep = TimelineMarkerLayout.stepping(from: at(7), in: markers, forward: true)
        #expect(firstStep?.instant == at(20))
        // Stepping again from that marker's seek instant (17 s) must advance, not repeat.
        let secondStep = TimelineMarkerLayout.stepping(from: at(17), in: markers, forward: true)
        #expect(secondStep?.instant == at(30))
        // Backwards from 17 s lands on the first marker (seek 7 s).
        let back = TimelineMarkerLayout.stepping(from: at(17), in: markers, forward: false)
        #expect(back?.instant == at(10))
    }

    // MARK: - Magnetism

    @Test func magnetismCandidatesAreTheMarkerInstantsInsideTheWindow() {
        let markers = [marker(10, .motion), marker(20, .motion), marker(150, .motion)]
        let window = TimelineWindow(start: t0, spanSeconds: 100)
        let candidates = TimelineMarkerLayout.magnetismCandidates(in: window, markers: markers)
        #expect(candidates.contains(at(10)))
        #expect(candidates.contains(at(20)))
        #expect(!candidates.contains(at(150)))  // outside the window
    }
}

#endif  // os(macOS)
