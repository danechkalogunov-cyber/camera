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

    /// What the device said when asked whether it records anything.
    private(set) var tracks: TrackAvailability = .unknown

    // MARK: - TrackAvailability

    /// Whether this camera records at all, as far as Vigil has been able to find out.
    ///
    /// Three states and not a `Bool`, because "we have not asked yet" and "we asked and it has
    /// none" must not look the same: the first is a reason to say nothing, the second is a reason
    /// to explain why there is no scrubber.
    enum TrackAvailability: Sendable, Hashable {

        /// Not asked yet, or the camera changed.
        case unknown

        /// The device answered and has at least one enabled track on this channel.
        case present

        /// The device answered the tracks query and offered nothing usable.
        ///
        /// ⛔ **Not** "the camera has no memory card." This says only that
        /// `/ISAPI/ContentMgmt/record/tracks` returned no enabled track — which also happens on
        /// firmware that does not implement the endpoint, and on a device that records to a card
        /// it will not describe. Claiming the stronger fact was wrong: a camera reporting 75 %
        /// storage in use is plainly writing somewhere.
        case none

        /// The device would not say, with its own reason.
        case refused(String)
    }

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
        tracks = .unknown
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
        // ⛔ Nothing is published here on the first load, and that is the whole point. Showing an
        // empty scrubber while the device is being asked meant a camera with no SD card drew a
        // timeline for a moment and then had it vanish — which reads as a bug in the app rather
        // than as a fact about the camera. A scrubber appears only once there is an index behind
        // it. On a *subsequent* day, the one already drawn stays and only raises `isLoading`, so
        // stepping a day does not blank a timeline that is genuinely there.
        if archive != nil {
            archive = Self.loading(archive, day: day)
        }
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

    /// Shows what is under the pointer, without moving the playhead.
    ///
    /// `nil` when the pointer leaves. The preview carries the instant and what kind of recording is
    /// there — continuous, motion, alarm — and **no image**: a thumbnail needs a decoded frame, and
    /// this app's decode path is passthrough and never produces one. `VTimelinePreview` takes the
    /// image as an optional for exactly this case, so the tooltip is honest rather than absent.
    func preview(at instant: Date?) {
        guard var current = archive else { return }
        guard let instant else {
            guard current.preview != nil else { return }
            current.preview = nil
            archive = current
            return
        }
        current.preview = VTimelinePreview(instant: instant, kind: Self.kind(at: instant, in: current))
        archive = current
    }

    /// Steps the playhead, clamped to the day being shown.
    ///
    /// Clamped rather than wrapped or allowed to run past midnight: the index loaded is one day's,
    /// so a playhead outside it would point at footage the scrubber is not drawing.
    func stepPlayhead(by seconds: Double) {
        guard let current = archive else { return }
        let moved = current.playhead.addingTimeInterval(seconds)
        movePlayhead(to: min(max(moved, current.day.start), current.day.end), isScrubbing: false)
    }

    /// Moves to the edge of the next or previous run of footage.
    ///
    /// The gesture that matters on a sparse day: with twenty minutes recorded out of twenty-four
    /// hours, stepping ten seconds at a time is not navigation. `TimelineSeek` already knows where
    /// the edges are.
    func stepToEdge(forward: Bool) {
        guard let current = archive, let index = current.tracks.first?.index else { return }
        let seek = TimelineSeek.resolve(current.playhead, in: index)
        let moved = forward ? seek.nextEdge(in: index) : seek.previousEdge(in: index)
        guard let instant = moved.resumesAt else { return }
        movePlayhead(to: instant, isScrubbing: false)
    }

    /// What kind of recording covers an instant, or `nil` when it lies in a gap.
    private static func kind(at instant: Date, in archive: VLibraryArchive) -> VTimelineSegmentKind? {
        guard let index = archive.tracks.first?.index,
              let position = index.containing(instant) else { return nil }
        return VTimelineSegmentKind(index.segments[position].recordType)
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
        let found: [RecordTrack]
        do {
            found = try await session.recordTracks()
            logger.info(.isapi, "recording tracks: \(found.count) listed")
        } catch {
            let reason = String(describing: error)
            logger.info(.isapi, "no recording tracks: \(reason)")
            lastFailure = reason
            tracks = .refused(reason)
            archive = nil
            return
        }

        // An NVR answers for every input, and drawing sixteen lanes for a window showing one camera
        // is not a timeline — so prefer this channel's tracks.
        let enabled = found.filter(\.enabled)
        let onChannel = enabled.filter { $0.channel == channel }

        // ⚠️ But the channel on a track is inferred, not given. `RecordTrack.list` reads `<Channel>`
        // and falls back to `id / 100`, because Hikvision numbers a track `101` for channel 1's main
        // stream. Plenty of single-channel cameras report `<id>1</id>` instead, which divides to
        // channel **0** and matches nothing — so a camera that records perfectly well would report
        // no tracks at all. When the filter empties a non-empty list, the filter is what is wrong:
        // every track on a one-camera device belongs to that camera.
        let mine: [RecordTrack]
        if !onChannel.isEmpty {
            mine = onChannel
        } else if !enabled.isEmpty {
            logger.info(.isapi, "recording tracks report channel "
                + "\(enabled.map { String($0.channel.value) }.joined(separator: ",")) "
                + "and the camera is channel \(channel.value); using them anyway")
            mine = enabled
        } else {
            mine = []
        }

        guard !mine.isEmpty else {
            logger.info(.isapi, "the device listed \(found.count) recording track(s), "
                + "none of them enabled")
            tracks = .none
            archive = nil
            return
        }
        tracks = .present

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
            let reason = "the device would not return a recording index for this day"
            lastFailure = reason
            tracks = .refused(reason)
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
                                day: TimelineDay) -> VLibraryArchive? {
        guard var existing = current else { return nil }
        existing.isLoading = true
        existing.day = day
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
