//
//  ArchiveCoordinator.swift
//  Vigil
//
//  Reads the camera's own recording index for a day, so the timeline has something to scrub.
//  macOS-only. See docs/spec-isapi.md §15 and docs/FEATURES.md F-PLB-01, F-PLB-03.
//

#if os(macOS)

import Foundation
import Observation

import VigilCore
import VigilISAPI
import VigilProtocols
import VigilUI

// MARK: - ArchiveCoordinator

/// Fills the timeline from the device's recording index.
///
/// **What this connects.** `VTimelineView` and its ruler, playhead and marker lane were written and
/// mounted inside `VRecordingsView` — but only when `VLibraryState.archive` is non-`nil`, and
/// nothing ever set it. `TimelineSegmentIndex` even has an initialiser taking a `RecordDayIndex`
/// straight from `VigilISAPI`, and `RecordSearchPager` has paged the device's search since it was
/// written. The whole path existed with one link absent, which is this type.
///
/// **Why a day at a time.** `/ISAPI/ContentMgmt/search` is paged and a busy camera answers with
/// thousands of segments; the timeline draws one day and the device caches per day, so anything
/// wider would be paging data nobody is looking at. Moving to the previous day is a fresh read, and
/// the session's own TTL makes going back to a day already seen free.
///
/// **Local clips ride along.** A track carries `localClips` so the scrubber can show what Vigil
/// itself recorded against what the camera holds. The two are different things and the timeline
/// draws them differently — a clip on this Mac survives the camera's card being overwritten.
@MainActor
@Observable
final class ArchiveCoordinator {

    // MARK: - Observable State

    /// What the timeline reads, or `nil` before a day has been loaded.
    private(set) var archive: VLibraryArchive?

    /// Why the last load failed, or `nil`.
    private(set) var lastFailure: String?

    /// Whether the device has any recording tracks at all.
    ///
    /// `false` on a camera with no card and no NVR behind it, which is the common case for a bare
    /// IP camera. The screen shows its own empty state rather than an empty scrubber, because an
    /// empty scrubber reads as "nothing recorded today" — a different and wrong claim.
    private(set) var hasTracks = false

    // MARK: - Stored Properties

    private let logger: any LoggerProtocol

    /// The session to ask, and the channel it answers for.
    private var session: ISAPIDeviceSession?
    private var channel: ChannelID?

    /// The load in flight, cancelled when the day or the camera changes.
    private var task: Task<Void, Never>?

    /// The day currently shown, so a repeat request for it is ignored.
    private var loadedDay: TimelineDay?

    // MARK: - Initialisation

    /// Creates a coordinator with nothing loaded.
    init(logger: any LoggerProtocol) {
        self.logger = logger
    }

    // MARK: - API

    /// Points the coordinator at a device, or clears it.
    func follow(session: ISAPIDeviceSession?, channel: ChannelID?) {
        guard self.session !== session || self.channel != channel else { return }
        task?.cancel()
        task = nil
        self.session = session
        self.channel = channel
        archive = nil
        loadedDay = nil
        hasTracks = false
        lastFailure = nil
    }

    /// Loads one day's index, unless it is already the day on screen.
    ///
    /// - Parameters:
    ///   - day: the local day to read.
    ///   - clock: the calendar the day was computed in, carried into the window.
    ///   - localClips: what Vigil recorded, drawn alongside the device's own segments.
    ///   - markers: events to put on the marker lane.
    func load(day: TimelineDay,
              clock: TimelineClock,
              localClips: [VTimelineLocalClip],
              markers: [TimelineMarker]) {
        guard let session, let channel else { return }
        guard loadedDay != day || archive == nil else { return }
        loadedDay = day
        task?.cancel()
        // `isLoading` on the previous archive rather than clearing it: replacing the whole value
        // would blank the scrubber for the length of a network round trip, and a timeline that
        // empties itself every time you step a day looks broken rather than busy.
        archive = Self.loading(archive, day: day, localClips: localClips, markers: markers)
        task = Task { [weak self] in
            await self?.read(session: session,
                             channel: channel,
                             day: day,
                             clock: clock,
                             localClips: localClips,
                             markers: markers)
        }
    }

    /// Moves the playhead, without touching anything else.
    ///
    /// Called on every scrub tick, so it must not re-read: the day's index does not change as the
    /// pointer moves across it.
    func movePlayhead(to instant: Date, isScrubbing: Bool) {
        guard var current = archive else { return }
        current.playhead = instant
        current.isScrubbing = isScrubbing
        archive = current
    }

    /// Changes the visible span, re-anchored on the playhead.
    func zoom(_ zoom: TimelineZoom) {
        guard var current = archive else { return }
        current.zoom = zoom
        // Anchored so the instant under the playhead stays put. Zooming about the window's start
        // instead would walk the picture off toward midnight on every step.
        let span = TimelineWindow(start: current.playhead, zoom: zoom).spanSeconds
        let anchored = current.playhead.addingTimeInterval(-span / 2)
        current.window = TimelineWindow(start: max(anchored, current.day.start),
                                        spanSeconds: span)
        archive = current
    }

    // MARK: - Private Helpers

    /// Reads the tracks and this day's index for each of them.
    private func read(session: ISAPIDeviceSession,
                      channel: ChannelID,
                      day: TimelineDay,
                      clock: TimelineClock,
                      localClips: [VTimelineLocalClip],
                      markers: [TimelineMarker]) async {
        let tracks: [RecordTrack]
        do {
            tracks = try await session.recordTracks()
        } catch {
            let reason = String(describing: error)
            logger.info(.isapi, "no recording tracks: \(reason)")
            lastFailure = reason
            hasTracks = false
            archive = nil
            return
        }

        // Only this channel's tracks, and only the enabled ones. An NVR answers for every input,
        // and drawing sixteen lanes for a window showing one camera is not a timeline.
        let mine = tracks.filter { $0.channel == channel && $0.enabled }
        hasTracks = !mine.isEmpty
        guard !mine.isEmpty else {
            logger.info(.isapi, "channel \(channel.value) has no enabled recording track")
            archive = nil
            return
        }

        var built: [VTimelineTrack] = []
        for (position, track) in mine.enumerated() {
            guard !Task.isCancelled else { return }
            do {
                let index = try await session.dayIndex(track: track.id, dayStartUTC: day.start)
                built.append(VTimelineTrack(
                    id: Self.identity(of: track.id),
                    name: track.sourceName ?? "Track \(track.id)",
                    identityIndex: position,
                    index: TimelineSegmentIndex(dayIndex: index, day: day),
                    markers: markers,
                    // Only on the first lane. The clips are Vigil's, not any one device track's,
                    // and repeating them under every lane would triple-count the same recording.
                    localClips: position == 0 ? localClips : []))
            } catch {
                // One track that refuses does not lose the others: an NVR commonly has a track for
                // a channel whose disk was pulled, and that is not a reason to show no timeline.
                logger.info(.isapi, "day index unavailable for track \(track.id): "
                    + String(describing: error))
            }
        }
        guard !Task.isCancelled else { return }
        guard !built.isEmpty else {
            lastFailure = "the device would not return an index for this day"
            archive = nil
            return
        }
        lastFailure = nil
        archive = VLibraryArchive(tracks: built,
                                  day: day,
                                  window: TimelineWindow(start: day.start, zoom: .day),
                                  zoom: .day,
                                  // Today opens at the current instant, an older day at its start.
                                  // Opening a past day "now" would put the playhead in empty space
                                  // past the end of everything recorded.
                                  playhead: Self.openingInstant(for: day, clock: clock),
                                  isLoading: false,
                                  preview: nil)
        logger.info(.isapi, "archive: \(built.count) track(s) for the selected day")
    }

    /// The archive as it looks while a read is in flight.
    ///
    /// Keeps whatever was already drawn and only raises `isLoading`, so stepping a day does not
    /// blank the scrubber for the length of a round trip.
    private static func loading(_ current: VLibraryArchive?,
                                day: TimelineDay,
                                localClips: [VTimelineLocalClip],
                                markers: [TimelineMarker]) -> VLibraryArchive {
        guard var existing = current else {
            return VLibraryArchive(tracks: [],
                                   day: day,
                                   window: TimelineWindow(start: day.start, zoom: .day),
                                   zoom: .day,
                                   playhead: day.start,
                                   isLoading: true)
        }
        existing.isLoading = true
        return existing
    }

    /// Where the playhead sits when a day is opened.
    private static func openingInstant(for day: TimelineDay, clock: TimelineClock) -> Date {
        let now = clock.now
        return (now >= day.start && now <= day.end) ? now : day.start
    }

    /// A stable `UUID` for a track, so a lane keeps its identity across a reload.
    ///
    /// `TrackID` is a number on the wire, and minting a fresh `UUID` per read would make `ForEach`
    /// rebuild every lane — losing the scroll position and restarting the draw on each day change.
    private static func identity(of track: TrackID) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        let value = UInt64(bitPattern: Int64(track.value))
        for index in 0..<8 { bytes[index] = UInt8((value >> (8 * UInt64(index))) & 0xFF) }
        for index in 8..<16 { bytes[index] = bytes[index - 8] }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

#endif  // os(macOS)
