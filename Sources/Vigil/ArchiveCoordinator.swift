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

    /// The month the calendar popover is showing, or `nil` before one has been asked for.
    ///
    /// Always non-`nil` once the popover has been opened, even while the device is being asked — an
    /// all-unknown grid is the honest picture of "we have not been told yet", and it lets the
    /// calendar appear at once instead of after a round trip.
    ///
    /// ⚠️ Not `private(set)` like its neighbours, and the reason is Swift rather than intent:
    /// `private(set)` scopes the *setter* to this file, and the only code that writes it lives in
    /// `ArchiveCoordinator+Month.swift`. The window still only reads it.
    var month: TimelineMonthGrid?

    /// Whether the month on screen is still being fetched, which the picker draws as a footnote.
    ///
    /// Writable for the same reason as ``month``.
    var isLoadingMonth = false

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

    let logger: any LoggerProtocol

    /// The session to ask, and the channel it answers for.
    var session: ISAPIDeviceSession?
    private var channel: ChannelID?

    /// The load in flight, cancelled when the day or the camera changes.
    private var task: Task<Void, Never>?

    /// The day currently shown, so a repeat request for it is ignored.
    private var loadedDay: TimelineDay?

    /// Every track this camera records to, in the order the device listed them.
    ///
    /// Plural because a camera routinely has more than one — 101 and 103 with the day split between
    /// them is ordinary Hikvision behaviour. Anything that asks the device "what is recorded" has to
    /// ask all of them or it reports half a day as the whole day.
    var myTracks: [TrackID] = []

    /// The device's own track behind the first lane.
    ///
    /// Kept because `VTimelineTrack.id` is a `UUID` derived from it and the derivation is one-way —
    /// and playback addresses a `TrackID`, not a lane. Only the first: the scrubber draws one
    /// camera, so the lane the playhead belongs to is the lane the picture came from.
    private var primaryTrack: TrackID?

    /// What the lane is labelled with — the camera's name, not a track's.
    private var cameraName = ""

    /// Months already read from the device, so stepping back and forth costs nothing.
    ///
    /// Kept as the device's own answer rather than as built grids: the grid also encodes which day
    /// is selected, and that changes without the month's contents changing at all.
    var monthCalendars: [MonthSlot: MonthRecordCalendar] = [:]

    /// The month the popover is on, and the fetch for it.
    var visibleMonth: MonthSlot?
    var monthTask: Task<Void, Never>?

    // MARK: - MonthSlot

    /// A year and a 1-based month, as one key.
    struct MonthSlot: Sendable, Hashable {
        let year: Int
        let month: Int
    }

    // MARK: - Initialisation

    /// Creates a coordinator with nothing loaded.
    init(logger: any LoggerProtocol) {
        self.logger = logger
    }

    // MARK: - API

    /// Points the coordinator at a device, or clears it.
    ///
    /// - Parameters:
    ///   - session: the ISAPI session to ask, or `nil` to clear.
    ///   - channel: the channel the camera streams on.
    ///   - name: what to label the lane. The camera's name and not a track's: the lane is one
    ///     camera's footage however many device tracks the firmware filed it across.
    func follow(session: ISAPIDeviceSession?, channel: ChannelID?, name: String) {
        cameraName = name
        guard self.session !== session || self.channel != channel else { return }
        task?.cancel()
        task = nil
        monthTask?.cancel()
        monthTask = nil
        self.session = session
        self.channel = channel
        archive = nil
        loadedDay = nil
        primaryTrack = nil
        myTracks = []
        tracks = .unknown
        lastFailure = nil
        // ⛔ The month cache is keyed by year and month alone, so carrying it across a camera change
        // would show one camera's recording days under another's name.
        monthCalendars = [:]
        visibleMonth = nil
        month = nil
        isLoadingMonth = false
    }

    /// The address to play from an instant, or `nil` when nothing was recorded there.
    ///
    /// **No `endtime`.** spec-isapi.md §15.6 calls that "play to the end of available footage",
    /// which is what a scrub release means — the user picked a moment and wants it to run on, not
    /// to stop at a segment boundary they cannot see. Stopping at the segment's own end would also
    /// make a recording that spans two files halt in the middle for no reason the user can name.
    ///
    /// Refuses an instant in a gap rather than seeking near it. §15.6 is explicit that an arbitrary
    /// time with no footage yields a 404 or a stream that ends immediately, and the honest answer
    /// to "play here" when there is nothing here is to say so.
    ///
    /// **The track comes from the segment, not from the camera.** A camera that files its day across
    /// tracks 101 and 103 must be played from whichever of them actually holds the instant asked
    /// for. Asking 101 for a time only 103 recorded is a request for footage that track does not
    /// have, and the device answers it exactly as it answers a gap — a 404, or a stream that ends
    /// the moment it starts.
    func locator(at instant: Date) -> PlaybackLocator? {
        guard let index = archive?.tracks.first?.index,
              let position = index.containing(instant) else { return nil }
        let track = index.segments[position].track
        return PlaybackLocator(track: track, start: instant, end: nil)
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

    /// Moves to the next or previous event marker — `.` and `,` (UX.md §7.3).
    ///
    /// Strictly past the playhead, so holding the key walks the day's events rather than sticking on
    /// the one already under it. Lands on the marker's ``TimelineMarker/seekInstant`` — three
    /// seconds early — because an event's timestamp is the moment detection *fired*, which is
    /// already after the thing that caused it entered frame.
    func stepToMarker(forward: Bool) {
        guard let current = archive, let markers = current.tracks.first?.markers else { return }
        guard let target = TimelineMarkerLayout.stepping(from: current.playhead,
                                                         in: markers,
                                                         forward: forward) else { return }
        movePlayhead(to: target.seekInstant, isScrubbing: false)
    }

    /// Home and End: the first or last instant of the day being shown (UX.md §7.3).
    func moveToDayEdge(start: Bool) {
        guard let current = archive else { return }
        movePlayhead(to: start ? current.day.start : current.day.end, isScrubbing: false)
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
        // Captured before the first `await`: `load` has already replaced `archive` with its loading
        // form, which keeps the outgoing playhead, and this is the last point at which it is still
        // the *previous* day's position rather than the new day's.
        let carried = archive?.playhead

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

        primaryTrack = mine.first?.id
        myTracks = mine.map(\.id)

        // ⛔ Every one of this camera's device tracks goes into ONE lane, not a lane each.
        //
        // A Hikvision camera routinely records to more than one track — 101 and 103 on the same
        // channel, for instance, with the day split between them. They are not two cameras and not
        // two things to compare; they are one camera's footage, filed by the device however its
        // firmware felt like filing it. A lane in UX.md §7.3 is a *camera*, for watching several at
        // once in step. Mapping device tracks onto lanes put half of one camera's day in a second
        // compact strip that reads as a different source, and — worse — left it unseekable, because
        // everything that answers "what is at this instant" looked at the first lane only.
        //
        // Merging is lossless: `RecordSegment` carries its own `TrackID`, so the instant a scrub
        // lands on still knows which track to play from. `TimelineSegmentIndex(raw:day:)` sorts and
        // already tolerates overlap without inventing gaps, which is exactly the case here.
        var segments: [RecordSegment] = []
        var truncated = false
        var answered = 0
        for track in mine {
            guard !Task.isCancelled else { return }
            do {
                let index = try await session.dayIndex(track: track.id, dayStartUTC: day.start)
                segments.append(contentsOf: index.segments)
                truncated = truncated || index.truncated
                answered += 1
                logger.info(.isapi, "track \(track.id): \(index.segments.count) segment(s)")
            } catch {
                // One track that refuses does not lose the others: an NVR commonly has a track for
                // a channel whose disk was pulled, and that is not a reason to show no timeline.
                logger.info(.isapi, "day index unavailable for track \(track.id): "
                    + String(describing: error))
            }
        }
        guard !Task.isCancelled else { return }
        guard answered > 0 else {
            let reason = "the device would not return a recording index for this day"
            lastFailure = reason
            tracks = .refused(reason)
            archive = nil
            return
        }
        let merged = TimelineSegmentIndex(raw: segments, day: day, isTruncated: truncated)
        let built = [VTimelineTrack(id: Self.identity(of: mine[0].id),
                                    name: cameraName,
                                    identityIndex: 0,
                                    index: merged,
                                    markers: markers,
                                    localClips: localClips)]
        let listed = mine.map { String($0.id.value) }.joined(separator: ",")
        logger.info(.isapi, "archive: \(merged.segments.count) segment(s) merged from "
            + "\(answered) of \(mine.count) track(s) [\(listed)]")

        lastFailure = nil
        archive = VLibraryArchive(tracks: built,
                                  day: day,
                                  window: TimelineWindow(start: day.start, zoom: .day),
                                  zoom: .day,
                                  playhead: Self.openingInstant(for: day,
                                                                carrying: carried,
                                                                clock: clock),
                                  isLoading: false,
                                  preview: nil)
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
    ///
    /// Three cases, in order:
    ///
    /// 1. **Today** opens at the current instant — the live edge is where the picture is.
    /// 2. **A day stepped to from another** keeps the wall-clock position (UX.md §7.4: "10:14 on
    ///    the 26th → 10:14 on the 25th"). Someone comparing ten past ten across three days should
    ///    not have to re-scrub to ten past ten twice.
    /// 3. **The first day opened** that is not today starts at midnight, there being nothing to
    ///    carry over. Opening it at "now" would put the playhead in empty space past the end of
    ///    everything the camera recorded that day.
    private static func openingInstant(for day: TimelineDay,
                                       carrying previous: Date?,
                                       clock: TimelineClock) -> Date {
        let now = clock.now
        if now >= day.start, now <= day.end { return now }
        guard let previous else { return day.start }
        return clock.sameTimeOfDay(as: previous, on: day)
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
