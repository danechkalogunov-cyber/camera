//
//  VTimelinePreviews.swift
//  VigilUI
//
//  The archive scrubber's `#Preview` blocks and the deterministic fixtures behind them: a full day,
//  a two-hour window over two synchronised cameras, a day full of gaps, and a marker run dense
//  enough to force clustering.
//  macOS-only. Supports Sources/VigilUI/Timeline/VTimelineView.swift.
//
//  ⚠️ Every segment, marker and clip here is SYNTHESISED. The shapes follow docs/spec-isapi.md §15
//  — a continuous run split into files, a short event clip, files that abut exactly — but no value
//  came off a device. The frozen "now" is 2026-07-26 10:14:38 UTC, the approved mockup's instant,
//  so no preview calls `Date()` and none of them moves between redraws.
//

#if os(macOS)
#if DEBUG && !VIGIL_NO_PREVIEWS

import Foundation
import SwiftUI

import VigilISAPI
import VigilProtocols

// MARK: - VTimelineSample

/// Deterministic fixtures for the previews.
///
/// ⚠️ Synthesised, not captured from hardware. The shapes follow docs/spec-isapi.md §15 — a
/// continuous run split into files, a short event clip, files that abut exactly — but no value here
/// came off a device. The frozen "now" is 2026-07-26 10:14:38 UTC, the mockup's instant, so the
/// previews never call `Date()` and never move.
@MainActor
private enum VTimelineSample {

    /// 2026-07-26 10:14:38 UTC.
    static let now = Date(timeIntervalSince1970: 1_785_060_878)

    static let clock = TimelineClock(timeZoneIdentifier: "UTC",
                                     now: now,
                                     locale: Locale(identifier: "en_GB"))

    static var day: TimelineDay { clock.today }

    /// A stable UUID for a fixture, so a preview redraw does not re-identify every marker.
    static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012ld", number)) ?? UUID()
    }

    static func at(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Double {
        Double(hour) * 3_600 + Double(minute) * 60 + Double(second)
    }

    static func segment(_ from: Double, _ to: Double,
                        _ type: RecordType = RecordType.timing) -> RecordSegment {
        let start = day.instant(atOffset: from)
        let end = day.instant(atOffset: to)
        return RecordSegment(track: TrackID(101),
                             start: start,
                             end: end,
                             codec: VideoCodecWire(raw: "H.265"),
                             contentType: "video",
                             recordType: type,
                             locator: PlaybackLocator(track: TrackID(101),
                                                      start: start, end: end))
    }

    /// The mockup's shape: continuous runs broken by motion, two real gaps, and a 20 s alarm clip
    /// that is 0.28 pt wide at the 24 h zoom — the segment the minimum-width rule exists for.
    static var mockupSegments: [RecordSegment] {
        [
            segment(at(9, 0), at(9, 12)),
            segment(at(9, 12), at(9, 14), RecordType.motion),
            segment(at(9, 20), at(9, 22), RecordType.motion),
            segment(at(9, 22), at(9, 34)),
            segment(at(9, 34), at(9, 34, 20), RecordType.alarm),
            segment(at(9, 35), at(9, 48)),
            segment(at(10, 2), at(10, 30)),
            segment(at(10, 30), at(10, 44), RecordType.motion),
            segment(at(10, 44), at(11, 0)),
        ]
    }

    /// A day whose footage stops for hours at a time, so the dotted "no recording" baseline and the
    /// legend's fourth key have something to describe.
    static var gappySegments: [RecordSegment] {
        [
            segment(at(0, 0), at(1, 30)),
            segment(at(6, 15), at(6, 18), RecordType.motion),
            segment(at(9, 0), at(9, 40)),
            segment(at(14, 0), at(14, 0, 25), RecordType.alarm),
            segment(at(18, 30), at(23, 59, 59)),
        ]
    }

    static func markers(_ offsets: [Double],
                        kind: TimelineMarkerKind = TimelineMarkerKind.motion,
                        from: Int = 0) -> [TimelineMarker] {
        offsets.enumerated().map { position, offset in
            TimelineMarker(id: id(from + position),
                           instant: day.instant(atOffset: offset),
                           kind: kind,
                           label: "Motion")
        }
    }

    /// Thirty events inside four minutes. At the 2 h zoom those are well inside the 8 pt collapse
    /// distance, so `TimelineMarkerLayout` folds them into counted clusters.
    static var denseMarkers: [TimelineMarker] {
        let offsets = (0..<30).map { at(10, 12) + Double($0) * 8 }
        return markers(offsets, from: 100)
            + markers([at(10, 5), at(10, 40)], kind: TimelineMarkerKind.alarm, from: 200)
            + markers([at(9, 30)], kind: TimelineMarkerKind.bookmark, from: 300)
    }

    static func track(name: String,
                      identity: Int,
                      segments: [RecordSegment],
                      markers: [TimelineMarker] = [],
                      clipOffsets: [(Double, Double)] = []) -> VTimelineTrack {
        let clips = clipOffsets.enumerated().map { position, span in
            VTimelineLocalClip(id: id(400 + position),
                               start: day.instant(atOffset: span.0),
                               end: day.instant(atOffset: span.1),
                               title: "Vigil clip")
        }
        return VTimelineTrack(id: id(identity),
                              name: name,
                              identityIndex: identity,
                              index: TimelineSegmentIndex(raw: segments, day: day),
                              markers: markers,
                              localClips: clips)
    }

    static var frontDoor: VTimelineTrack {
        track(name: "Front Door",
              identity: 0,
              segments: mockupSegments,
              markers: markers([at(9, 25), at(9, 34), at(10, 14), at(10, 36)])
                  + markers([at(9, 12)], kind: TimelineMarkerKind.bookmark, from: 50),
              clipOffsets: [(at(9, 38), at(9, 44)), (at(10, 20), at(10, 23))])
    }

    static var backYard: VTimelineTrack {
        track(name: "Back Yard",
              identity: 3,
              segments: [segment(at(9, 0), at(9, 30)),
                         segment(at(9, 55), at(10, 25), RecordType.motion),
                         segment(at(10, 25), at(11, 0))],
              clipOffsets: [(at(9, 15), at(9, 18))])
    }

    static func window(_ zoom: TimelineZoom, from offset: Double) -> TimelineWindow {
        TimelineWindow(start: day.instant(atOffset: offset), zoom: zoom).clamped(to: day)
    }
}

#Preview("Timeline — full day") {
    VTimelineView(tracks: [VTimelineSample.frontDoor],
                  day: VTimelineSample.day,
                  window: TimelineWindow.fitting(VTimelineSample.day,
                                                 zoom: TimelineZoom.day),
                  zoom: TimelineZoom.day,
                  clock: VTimelineSample.clock,
                  playhead: VTimelineSample.now)
        .padding(VTheme.Space.md)
        .frame(width: 980)
        .background(VTheme.Color.Layer.canvas)
}

#Preview("Timeline — two-hour window") {
    VTimelineView(tracks: [VTimelineSample.frontDoor, VTimelineSample.backYard],
                  day: VTimelineSample.day,
                  window: TimelineWindow(start: VTimelineSample.day.instant(atOffset: 9 * 3_600),
                                         spanSeconds: 2 * 3_600),
                  zoom: TimelineZoom.threeHours,
                  clock: VTimelineSample.clock,
                  playhead: VTimelineSample.now,
                  preview: VTimelinePreview(instant: VTimelineSample.now,
                                            kind: VTimelineSegmentKind.motion))
        .padding(.top, 140)
        .padding(VTheme.Space.md)
        .frame(width: 1_180)
        .background(VTheme.Color.Layer.canvas)
}

#Preview("Timeline — a day full of gaps") {
    VTimelineView(tracks: [VTimelineSample.track(name: "Loading Bay",
                                                 identity: 5,
                                                 segments: VTimelineSample.gappySegments,
                                                 clipOffsets: [(3_600, 4_200)])],
                  day: VTimelineSample.day,
                  window: TimelineWindow.fitting(VTimelineSample.day,
                                                 zoom: TimelineZoom.day),
                  zoom: TimelineZoom.day,
                  clock: VTimelineSample.clock,
                  playhead: VTimelineSample.day.instant(atOffset: 3 * 3_600))
        .padding(VTheme.Space.md)
        .frame(width: 980)
        .background(VTheme.Color.Layer.canvas)
}

#Preview("Timeline — clustered markers") {
    VTimelineView(tracks: [VTimelineSample.track(name: "Driveway",
                                                 identity: 1,
                                                 segments: VTimelineSample.mockupSegments,
                                                 markers: VTimelineSample.denseMarkers)],
                  day: VTimelineSample.day,
                  window: VTimelineSample.window(TimelineZoom.threeHours, from: 9 * 3_600),
                  zoom: TimelineZoom.threeHours,
                  clock: VTimelineSample.clock,
                  playhead: VTimelineSample.now,
                  isScrubbing: true)
        .padding(VTheme.Space.md)
        .frame(width: 900)
        .background(VTheme.Color.Layer.canvas)
}

#endif  // DEBUG && !VIGIL_NO_PREVIEWS
#endif  // os(macOS)
