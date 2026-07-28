//
//  ISAPIDeviceSession+Features.swift
//  VigilISAPI
//
//  The feature families hung off the device session: the read-modify-write-then-re-GET helper every
//  configuration write goes through, PTZ, events, playback, two-way audio and image settings.
//  Implements docs/spec-isapi.md §17.1 and §18, and docs/API_CONTRACT.md §4.5.
//
//  Everything here composes types that are already written and already tested on their own —
//  `PTZController`, `AlertStreamMonitor`, `RecordSearchPager`, `ImageWrite`, `MotionDetectionConfig`.
//  What this file adds is the three things only the owning actor can own:
//
//    * **The TTL table applied.** Each accessor is "serve the cached box while it is fresh, ask the
//      device otherwise", against the one `now()` reading taken for that call.
//    * **The re-GET after a write.** `readModifyWrite` is the only path a configuration `PUT` takes
//      (§17.1). Its return value is the *device's* state, read back, never the requested one.
//    * **The remaining quirk consultation points.** The path builder is consulted for the
//      daily-distribution and event-schedule resources, the body builder for the record-type filter
//      and the sharpness casing, and response interpretation for the device-local playback window.
//      Each is marked in a comment at the point of use so the set stays enumerable (§19).
//

import Foundation
import VigilProtocols

// MARK: - AnyRandomSource

/// A concrete `RandomSource` that forwards to an existential one.
///
/// Exists solely to satisfy the `inout some RandomSource` positions in this module: Swift opens an
/// existential implicitly for a plain generic parameter but not for an `inout` one, and the
/// alternative — making the session generic over its generator — would put a type parameter on the
/// device session that every caller and every stored reference would have to spell.
struct AnyRandomSource: RandomSource {

    /// The generator being forwarded to. Read back out by the caller so the draw is not lost.
    var wrapped: any RandomSource

    /// Forwards one draw. `wrapped` is a `var`, so the existential's own `mutating` requirement
    /// advances the boxed value in place.
    mutating func next() -> UInt64 { wrapped.next() }
}

// MARK: - Read-modify-write

extension ISAPIDeviceSession {

    /// `GET` → patch the tree the device sent → `PUT` the whole element → re-`GET` to confirm.
    ///
    /// The mandatory shape of every configuration write in docs/spec-isapi.md §17.1, and the reason
    /// `VigilCore` never builds a body itself. Three failures it exists to prevent: a "minimal" body
    /// that omits a mandatory sibling and draws `badParameters`; a body that omits an element this
    /// firmware resets to a factory default when it is absent; and a UI that shows the value the
    /// user asked for rather than the value the device clamped it to.
    ///
    /// - Parameters:
    ///   - resource: the sub-resource to read and write. Must address a single element, not a list.
    ///   - lane: the connection pool. `.control` for everything Vigil writes today.
    ///   - patch: receives the root element **exactly** as the device sent it, unmodelled children
    ///     and `version`/`xmlns` attributes included, and returns it with only the intended values
    ///     changed. Returning `nil` means "this setting cannot be expressed against what the device
    ///     sent", which becomes `.malformedResponse` rather than a guessed body.
    /// - Returns: the confirming `GET`'s document — the device's own state after the write.
    /// - Throws: `.malformedResponse` when `patch` declines, or when it returns an element with a
    ///   different root name than the device sent (a programming error that would otherwise reach
    ///   the device as a body it answers `invalidXMLContent` to, hours later, in the field).
    ///   Anything the device or the transport throws is propagated unchanged.
    ///
    /// The one write in this module that does **not** call this helper is `updateStream`, because it
    /// has to re-read through `streamingChannel(_:)` for the single-digit-resource quirk retry and
    /// has two caches to stale between the write and the confirming read.
    func readModifyWrite(_ resource: String,
                         lane: HTTPLane = .control,
                         patch: (XMLNode) -> XMLNode?) async throws(ISAPIError) -> ISAPIDocument {
        let current = try await get(resource, lane: lane)
        guard let patched = patch(current.root) else {
            throw ISAPIError.malformedResponse(
                "nothing to write into <\(current.rootName)> at \(resource)")
        }
        guard patched.key == current.root.key else {
            throw ISAPIError.malformedResponse(
                "patch changed the root of \(resource) from <\(current.rootName)> to <\(patched.name)>")
        }
        // **Quirk consultation point 2 (body builder):** the declaration, and the device's own
        // `version` and `xmlns`, ride back out with the element untouched (§8, §17.2).
        try await put(resource, body: resolver.bodyBytes(patched), lane: lane)
        return try await get(resource, lane: lane)
    }
}

// MARK: - PTZ

extension ISAPIDeviceSession {

    /// `GET /ISAPI/PTZCtrl/channels/{ch}/capabilities`. Cached 24 h per channel.
    ///
    /// A refusal is not an error: `.absent` is returned, every PTZ affordance disappears, and the
    /// negative cache stops the question being asked again for 24 h. `.absent` is also what a
    /// fixed camera gets, which is the common case on this hardware.
    public func ptzCapabilities(channel: ChannelID)
        async throws(ISAPIError) -> PTZCapabilitiesWire {
        if let box = ptzCapabilityBoxes[channel], box.isFresh(at: now(), ttl: ttl.ptzCapabilities) {
            return box.value
        }
        let wire: PTZCapabilitiesWire
        do {
            wire = PTZCapabilitiesWire(
                document: try await get(ISAPIResource.ptzCapabilities(channel)))
        } catch {
            logger.info(.isapi, "no PTZ on channel \(channel.value)",
                        ["reason": error.userMessageKey])
            wire = .absent
        }
        ptzCapabilityBoxes[channel] = Timestamped(value: wire, storedAt: now())
        // A controller built before the capabilities were known must learn them, or a camera whose
        // capabilities arrived late would refuse `position3D` for the rest of the session.
        await ptzControllers[channel]?.updateCapabilities(wire)
        return wire
    }

    /// The channel's PTZ controller, built once and shared.
    ///
    /// One controller per channel and never one per gesture: the 400 ms keep-alive and the triple
    /// zero-stop are per-channel state, and two controllers on one channel would race a held
    /// joystick against a preset recall — with a runaway camera as the visible result.
    ///
    /// - Throws: `.notSupported` when the channel has no PTZ, so a caller cannot get a controller
    ///   whose every call would fail. Check `ptzCapabilities(channel:)` first to decide whether to
    ///   show the affordance at all.
    public func ptzController(channel: ChannelID) async throws(ISAPIError) -> PTZController {
        if let existing = ptzControllers[channel] { return existing }
        let capabilities = try await ptzCapabilities(channel: channel)
        guard !capabilities.isAbsent else {
            throw ISAPIError.notSupported(resource: ISAPIResource.ptzContinuous(channel))
        }
        let controller = PTZController(requests: requests, channel: channel,
                                       capabilities: capabilities, clock: clock, logger: logger)
        ptzControllers[channel] = controller
        return controller
    }

    /// The channels the device says have PTZ, or every channel in the inventory when it does not
    /// answer `/PTZCtrl/channels` at all — several cameras omit the list and still pan.
    public func ptzChannels() async -> [ChannelID] {
        do {
            let listed = PTZChannelList.channels(
                document: try await get(ISAPIResource.ptzChannels))
            if !listed.isEmpty { return listed }
        } catch {
            logger.debug(.isapi, "no PTZ channel list", ["reason": error.userMessageKey])
        }
        return (try? await channels())?.map(\.channel) ?? []
    }

    /// **Quirk consultation point 3 (response interpretation):** true when `position3D` boxes for
    /// this device must be built with an upper-left Y origin.
    ///
    /// Read by the drag-to-zoom gesture, which builds the `PTZ3D` — the origin decides which corner
    /// a drag's start coordinate is measured from, and getting it wrong sends the camera the
    /// vertical mirror of what the user drew.
    public var position3DOriginIsTopLeft: Bool { resolver.position3DOriginIsTopLeft }

    /// Records the outcome of a drag-to-zoom calibration (docs/spec-isapi.md §13.5).
    ///
    /// The only way the `ptz3DOriginIsTopLeft` row is ever set: it cannot be read from the device
    /// and cannot be seeded from a model string, because the two families that differ ship under
    /// the same model prefix.
    public func calibratePosition3DOrigin(topLeft: Bool) async {
        await learn(.position3DOriginCalibrated(topLeft: topLeft))
    }
}

// MARK: - Events

extension ISAPIDeviceSession {

    /// The one alert-stream monitor for this device (API_CONTRACT §2 R-28).
    ///
    /// Memoised, and deliberately **not** per channel: the device multiplexes every channel's events
    /// onto one `alertStream` response, and opening a second one exhausts the HTTP worker pool that
    /// the snapshot and control lanes also draw from. Not `start`ed here — the caller subscribes to
    /// `notifications()` first and then starts, so no event is dropped between the two.
    public func alertStream() -> AlertStreamMonitor {
        if let existing = alertMonitor { return existing }
        let monitor = AlertStreamMonitor(requests: requests, clock: clock, wallClock: wallClock,
                                         random: random, logger: logger)
        alertMonitor = monitor
        return monitor
    }

    /// `GET /ISAPI/Event/triggers`. Cached 5 min.
    public func eventTriggers(force: Bool = false) async throws(ISAPIError) -> [EventTrigger] {
        if !force, let box = eventTriggersBox, box.isFresh(at: now(), ttl: ttl.eventTriggers) {
            return box.value
        }
        let triggers = EventTrigger.list(document: try await get(ISAPIResource.eventTriggers))
        eventTriggersBox = Timestamped(value: triggers, storedAt: now())
        return triggers
    }

    /// One trigger's arming schedule, or `nil` when the device has no schedule endpoint.
    ///
    /// **Quirk consultation point 1 (path builder):** two spellings exist —
    /// `/Event/schedules/{triggerID}` and a whole-device `/Event/schedules` — and which one answers
    /// is a property of the firmware. The resolver supplies the candidates in order; the one that
    /// answers is remembered on the camera row so later triggers cost one request instead of two.
    public func eventSchedule(triggerID: String) async throws(ISAPIError) -> EventSchedule? {
        for resource in resolver.eventScheduleResources(triggerID: triggerID) {
            do {
                let schedule = EventSchedule(document: try await get(resource))
                await learn(.eventScheduleResolved(resource: resource))
                return schedule
            } catch {
                continue
            }
        }
        return nil
    }

    /// `GET …/motionDetection` for one channel. Never cached: the grid editor must not open on a
    /// stale grid, because the user's first edit would then be applied to it.
    public func motionDetection(channel: ChannelID)
        async throws(ISAPIError) -> MotionDetectionConfig {
        MotionDetectionConfig(document: try await get(ISAPIResource.motionDetection(channel)))
    }

    /// Writes motion detection: read-modify-write on the whole `<MotionDetection>`, then re-`GET`.
    ///
    /// - Returns: the configuration the device is actually running. `sensitivity` is clamped by the
    ///   device and the grid may be snapped to its own row/column count, so the editor redraws from
    ///   this rather than from what it asked for.
    /// - Throws: `.malformedResponse` when the device sent a `<MotionDetection>` with no element to
    ///   patch, rather than inventing a body — a hand-built minimal grid write is what wipes a
    ///   user's carefully drawn mask.
    @discardableResult
    public func setMotionDetection(channel: ChannelID, enabled: Bool?, sensitivity: Int?,
                                   grid: MotionGrid?) async throws(ISAPIError)
        -> MotionDetectionConfig {
        let resource = ISAPIResource.motionDetection(channel)
        let confirmed = try await readModifyWrite(resource) { node in
            MotionDetectionConfig(document: ISAPIDocument(root: node))
                .patchedNode(enabled: enabled, sensitivity: sensitivity, grid: grid)
        }
        return MotionDetectionConfig(document: confirmed)
    }
}

// MARK: - Playback

extension ISAPIDeviceSession {

    /// Pages a single recording search may take before it is abandoned.
    ///
    /// Not a performance limit — the segment cap in `RecordSearchQuery` is that. This is a liveness
    /// guard: a device that answers `MORE` with a positive `numberOfMatches` and an empty
    /// `<matchList>` advances the cursor for ever without the segment count ever reaching its cap,
    /// and one such NVR would otherwise hold this actor and its HTTP lane open until the app quits.
    static let maximumSearchPages = 64

    /// `GET /ISAPI/ContentMgmt/record/tracks`. Cached 5 min.
    public func recordTracks(force: Bool = false) async throws(ISAPIError) -> [RecordTrack] {
        if !force, let box = recordTracksBox, box.isFresh(at: now(), ttl: ttl.recordTracks) {
            return box.value
        }
        let tracks = RecordTrack.list(document: try await get(ISAPIResource.recordTracks))
        recordTracksBox = Timestamped(value: tracks, storedAt: now())
        return tracks
    }

    /// `POST /ISAPI/ContentMgmt/search`, paged to exhaustion (API_CONTRACT §2 R-29).
    ///
    /// The only call in Vigil allowed to paint a timeline. One `searchID` for the whole search, and
    /// `searchResultPostion` advanced by the device's own `numberOfMatches` — Hikvision's own
    /// spelling of that field, kept verbatim because the device ignores the corrected one.
    ///
    /// Two quirks are consulted here:
    ///
    /// * **Point 2 (body builder):** the record-type filter is sent only while the device has not
    ///   rejected one. The first `badParameters`/`invalidXMLContent` on page one flips the row and
    ///   the search is retried asking for every type, which is slower but never wrong. A rejection
    ///   *mid*-search is propagated instead: re-asking from a cursor the device established under
    ///   different filter semantics would silently skip or duplicate a stretch of the timeline.
    /// * **Point 3 (response interpretation):** several DVRs read `starttime` as device-local even
    ///   though it carries `Z`. The requested window is shifted by the device's own UTC offset on
    ///   the way out and the returned segment times are shifted back on the way in, so the caller
    ///   only ever sees real instants. `PlaybackLocator` is deliberately not rewritten (R-29).
    public func searchRecordings(_ query: RecordSearchQuery)
        async throws(ISAPIError) -> [RecordSegment] {
        let offsetSeconds = await deviceUTCOffsetSeconds()
        let effective = resolver.searchWindow(query, deviceUTCOffsetSeconds: offsetSeconds)
        var pager = RecordSearchPager(query: effective, searchID: nextSearchID())
        var filtered = resolver.recordSearchMayFilterByType && !effective.recordTypes.isEmpty
        while !pager.isFinished, pager.pageCount < Self.maximumSearchPages {
            let body = resolver.bodyBytes(pager.nextBody(filtered: filtered))
            let document: ISAPIDocument
            do {
                document = try await post(ISAPIResource.contentSearch, body: body)
            } catch {
                guard filtered, pager.pageCount == 0,
                      Self.suggestsRecordTypeFilterWasRefused(error) else { throw error }
                await learn(.recordTypeFilterRejected)
                filtered = false
                continue
            }
            pager.accept(CMSearchResult(document: document, track: effective.track))
        }
        if pager.truncated || pager.pageCount >= Self.maximumSearchPages {
            logger.warning(.isapi, "recording search truncated", [
                "track": String(effective.track.value),
                "pages": String(pager.pageCount),
                "segments": String(pager.segments.count),
            ])
        }
        return resolver.correctedSegmentTimes(pager.segments,
                                              deviceUTCOffsetSeconds: offsetSeconds)
    }

    /// Draws one search id from the injected generator, advancing it.
    ///
    /// `CMSearchDescription.searchID(from:)` takes `inout some RandomSource`, and an `inout`
    /// generic argument is the one position Swift will not implicitly open an existential in — so
    /// the session's `any RandomSource` is boxed in a concrete forwarder for the call and written
    /// back afterwards. Writing it back is the point: the generator must *advance*, or a session
    /// that runs two searches would send the same `searchID` twice and the second would be answered
    /// from the first's cursor.
    func nextSearchID() -> String {
        var source = AnyRandomSource(wrapped: random)
        let id = CMSearchDescription.searchID(from: &source)
        random = source.wrapped
        return id
    }

    /// True for the answers a `CMSearchDescription` carrying a record-type filter draws on the
    /// firmwares that do not implement one.
    ///
    /// `invalidXMLContent` and `badParameters` are the two documented sub-statuses; a bare 400 with
    /// no `ResponseStatus` is included because one 5.4.x DVR answers exactly that.
    static func suggestsRecordTypeFilterWasRefused(_ error: ISAPIError) -> Bool {
        switch error {
        case let .device(_, sub):
            sub == ResponseStatus.SubStatus.badParameters
                || sub == ResponseStatus.SubStatus.invalidXMLContent
        case let .http(status, _): status == 400
        default: false
        }
    }

    /// The device's UTC offset in seconds, or `0` when it cannot be read.
    ///
    /// Only consulted for the device-local playback quirk, and only meaningful when that quirk is
    /// set — so a failure to read `/System/time` degrades to "assume the device means UTC", which is
    /// what the majority of firmware actually does.
    func deviceUTCOffsetSeconds() async -> Int {
        do {
            return try await time().utcOffsetSeconds
        } catch {
            logger.debug(.isapi, "device time unavailable; assuming UTC for playback",
                         ["reason": error.userMessageKey])
            return 0
        }
    }

    /// One day's recording index for one track, built from a full-day search.
    ///
    /// Cached per (track, day): 60 s for today, which is still being written to, and **for ever**
    /// for a past day, whose recordings cannot change (§18.1). That asymmetry is the whole reason
    /// the timeline can be scrubbed backwards without re-searching the same day on every redraw.
    ///
    /// - Parameter dayStartUTC: midnight UTC of the day. Used verbatim as the cache key and as the
    ///   search window's start, so a caller that passes a local midnight gets a local day — which
    ///   is a legitimate thing to want and not this actor's business to correct.
    public func dayIndex(track: TrackID, dayStartUTC: Date,
                         force: Bool = false) async throws(ISAPIError) -> RecordDayIndex {
        let key = DayIndexKey(track: track, dayStartUTC: dayStartUTC)
        let isToday = isCurrentUTCDay(dayStartUTC)
        if !force, let box = dayIndexBoxes[key] {
            // A past day never expires; `Double.infinity` is a real TTL here rather than a sentinel
            // because `isFresh` compares against it correctly.
            let lifetime = isToday ? ttl.dayIndexToday : .infinity
            if box.isFresh(at: now(), ttl: lifetime) { return box.value }
        }
        var query = RecordSearchQuery(track: track, start: dayStartUTC,
                                      end: dayStartUTC.addingTimeInterval(86_400))
        query.recordTypes = []
        let segments = try await searchRecordings(query)
        let index = RecordDayIndex.build(track: track, dayStartUTC: dayStartUTC,
                                         segments: segments,
                                         truncated: segments.count >= query.hardSegmentCap)
        dayIndexBoxes[key] = Timestamped(value: index, storedAt: now())
        return index
    }

    /// True when `dayStartUTC` is the UTC day the wall clock is in.
    ///
    /// Integer division on the Unix epoch rather than a `Calendar`: UTC days are exactly 86 400
    /// seconds in `Date`'s time base — there are no leap seconds in it — so this is exact, and it
    /// avoids a `Calendar` whose time zone would have to be forced back to UTC anyway.
    func isCurrentUTCDay(_ dayStartUTC: Date) -> Bool {
        func dayNumber(_ date: Date) -> Int64 {
            Int64((date.timeIntervalSince1970 / 86_400).rounded(.down))
        }
        return dayNumber(dayStartUTC) == dayNumber(wallClock.now)
    }

    /// One month's per-day recording summary — the accelerator that colours the date picker.
    ///
    /// **Quirk consultation point 1 (path builder):** the resource moved between firmware
    /// generations, from `/ContentMgmt/record/tracks/dailyDistribution` to
    /// `/ContentMgmt/search/dailyDistribution`. Candidates are tried in order and the one that
    /// answers is remembered, because the probe costs a `POST` that some NVRs answer slowly and
    /// repeating it every time the month view opens is visible to the user.
    ///
    /// - Returns: a calendar whose unmentioned days are `nil`, meaning **unknown** rather than
    ///   empty. A device with no accelerator at all yields an all-`nil` calendar and no error: the
    ///   date picker then fills days in lazily from `dayIndex(track:dayStartUTC:)`, which is slower
    ///   but correct, and an error here would put a failure banner over a working month view.
    public func monthCalendar(track: TrackID, year: Int,
                              month: Int) async throws(ISAPIError) -> MonthRecordCalendar {
        let key = MonthKey(track: track, year: year, month: month)
        if let box = monthCalendarBoxes[key], box.isFresh(at: now(), ttl: ttl.monthCalendar) {
            return box.value
        }
        let body = resolver.bodyBytes(MonthRecordCalendar.requestBody(track: track, year: year,
                                                                      month: month))
        var calendar = MonthRecordCalendar(year: year, month: month, track: track,
                                           days: [MonthRecordCalendar.DayState?](repeating: nil,
                                                                                 count: 31))
        for resource in resolver.dailyDistributionResources {
            do {
                let document = try await post(resource, body: body)
                calendar = MonthRecordCalendar(document: document, track: track,
                                               year: year, month: month)
                await learn(.dailyDistributionResolved(resource: resource))
                break
            } catch {
                logger.debug(.isapi, "daily distribution refused",
                             ["resource": resource, "reason": error.userMessageKey])
                continue
            }
        }
        monthCalendarBoxes[key] = Timestamped(value: calendar, storedAt: now())
        return calendar
    }

    /// `GET /ISAPI/ContentMgmt/Storage`. Cached 5 min.
    ///
    /// The quota sub-resource is best-effort and merged in when it answers: a device without quotas
    /// still has volumes, and failing the whole call would hide the free-space readout that the
    /// user actually came to the panel for.
    public func storage(force: Bool = false) async throws(ISAPIError) -> StorageInfo {
        if !force, let box = storageBox, box.isFresh(at: now(), ttl: ttl.storage) {
            return box.value
        }
        var info = StorageInfo(document: try await get(ISAPIResource.storage))
        if let document = try? await get(ISAPIResource.storageQuota) {
            info.quotas = StorageQuota.list(document: document)
        }
        storageBox = Timestamped(value: info, storedAt: now())
        return info
    }
}

// MARK: - Two-way audio

extension ISAPIDeviceSession {

    /// `GET /ISAPI/System/TwoWayAudio/channels`, with each channel's capabilities merged in.
    ///
    /// Not cached: the list is read once when the talk button is armed, and the codec list it
    /// carries is what the negotiation depends on — a stale one would pick a codec the device has
    /// since been reconfigured away from.
    public func twoWayAudioChannels() async throws(ISAPIError) -> [TwoWayAudioChannel] {
        let listed = TwoWayAudioChannel.list(
            document: try await get(ISAPIResource.twoWayAudioChannels))
        var merged: [TwoWayAudioChannel] = []
        merged.reserveCapacity(listed.count)
        for channel in listed {
            // Capabilities are advisory: the channel list alone is enough to open a session, so a
            // device that 404s the capabilities sub-resource is still talkable-to.
            if let document = try? await get(ISAPIResource.twoWayAudioCapabilities(channel.id)) {
                merged.append(channel.mergingCapabilities(document))
            } else {
                merged.append(channel)
            }
        }
        return merged
    }

    /// Opens a talk-back session on `channel`.
    ///
    /// The codec is negotiated from what the channel advertises, against Vigil's send preference
    /// (G.711µ, then G.711A, then 16-bit PCM). A channel that advertises nothing Vigil can encode
    /// throws rather than opening a session that would send static.
    ///
    /// The returned session is **not** yet pumping: `VigilCore` attaches the chunked upload handle
    /// with `TwoWayAudioSession.attach(_:)` and drives `pump()`. That handle comes from
    /// `ISAPIClient.chunkedUpload(_:contentType:)`, which is deliberately absent from the
    /// `ISAPIRequesting` seam — a streaming upload is not something a fixture double can honestly
    /// pretend to be, so the split is where the test boundary belongs.
    ///
    /// - Throws: `.notSupported` when the device has no such channel or no codec in common.
    public func openTwoWayAudio(channel: Int) async throws(ISAPIError) -> TwoWayAudioSession {
        let channels = try await twoWayAudioChannels()
        guard let wire = channels.first(where: { $0.id == channel }) else {
            throw ISAPIError.notSupported(resource: ISAPIResource.twoWayAudioChannel(channel))
        }
        guard let codec = wire.negotiatedSendCodec() else {
            logger.warning(.isapi, "no encodable two-way audio codec", [
                "channel": String(channel),
                "offered": wire.supportedCodecs.map(\.raw).joined(separator: ","),
            ])
            throw ISAPIError.notSupported(resource: ISAPIResource.twoWayAudioOpen(channel))
        }
        let session = TwoWayAudioSession(requests: requests, channel: channel, codec: codec,
                                        sampleRateHz: wire.sampleRateHz, logger: logger)
        try await session.open(configuring: wire)
        return session
    }
}

// MARK: - Image settings

extension ISAPIDeviceSession {

    /// How many image sub-resources are read at once (docs/spec-isapi.md §17.2).
    ///
    /// Fourteen sub-resources with no limit is fourteen simultaneous requests at a device whose
    /// documented ceiling is three, and the answer to that is a `deviceBusy` storm that this
    /// session would then mis-learn as a permanent concurrency quirk.
    static let imageProbeConcurrency = 3

    /// Every image control the channel exposes, and its current values. Cached 30 s.
    ///
    /// Each sub-resource is read independently and a `403`/`404` on one is not an error — it means
    /// the control does not exist, which is exactly what `available` reports and what the settings
    /// panel needs in order to show only the sliders that will work. A device that refuses all
    /// fourteen yields an `ImageSettings` with an empty `available` and no thrown error, because a
    /// camera without image controls is a normal camera.
    public func imageSettings(channel: ChannelID,
                             force: Bool = false) async throws(ISAPIError) -> ImageSettings {
        if !force, let box = imageBoxes[channel], box.isFresh(at: now(), ttl: ttl.imageSettings) {
            return box.value
        }
        var settings = ImageSettings()
        for (control, document) in await readImageControls(channel: channel) {
            settings.absorb(control, document: document)
        }
        imageBoxes[channel] = Timestamped(value: settings, storedAt: now())
        return settings
    }

    /// Reads every image sub-resource, at most `imageProbeConcurrency` at a time.
    ///
    /// Results come back in `ImageControl.allCases` order rather than completion order, so a
    /// settings panel built from them does not reshuffle between two reads of the same camera.
    func readImageControls(channel: ChannelID) async -> [(ImageControl, ISAPIDocument)] {
        var found: [ImageControl: ISAPIDocument] = [:]
        await withTaskGroup(of: (ImageControl, ISAPIDocument?).self) { group in
            var pending = ImageControl.allCases[...]
            func addNext() {
                guard let control = pending.popFirst() else { return }
                group.addTask { (control, await self.readImageControl(channel: channel,
                                                                     control: control)) }
            }
            for _ in 0..<Self.imageProbeConcurrency { addNext() }
            while let (control, document) = await group.next() {
                if let document { found[control] = document }
                addNext()
            }
        }
        return ImageControl.allCases.compactMap { control in
            found[control].map { (control, $0) }
        }
    }

    /// One image sub-resource, or `nil` when the device does not have it.
    func readImageControl(channel: ChannelID, control: ImageControl) async -> ISAPIDocument? {
        try? await get(ISAPIResource.image(channel, control))
    }

    /// Writes brightness, contrast, saturation and hue in one `<Color>` read-modify-write.
    ///
    /// - Returns: the settings the device is actually running, re-read after the write. Every level
    ///   is clamped by the device — several firmwares quantise to steps of two — so the sliders are
    ///   repositioned from this and never from the drag that produced it.
    @discardableResult
    public func setImageColor(channel: ChannelID, brightness: Int?, contrast: Int?,
                              saturation: Int?, hue: Int? = nil)
        async throws(ISAPIError) -> ImageSettings {
        try await writeImage(channel: channel, control: .color) { node in
            ImageWrite.color(node, brightness: brightness, contrast: contrast,
                             saturation: saturation, hue: hue)
        }
    }

    /// Writes sharpness.
    ///
    /// **Quirk consultation point 2 (body builder):** 5.4.x–5.5.x spell the level element in lower
    /// case. Reads use alternation so this only matters when the device sent a `<Sharpness>` with no
    /// level element at all and the casing has to be chosen — which is what the quirk row records.
    @discardableResult
    public func setSharpness(channel: ChannelID, _ level: Int)
        async throws(ISAPIError) -> ImageSettings {
        // A value copy of the resolver, so the patch closure reads the quirk row without capturing
        // the actor whose `resolver` it lives on.
        let casing = resolver
        return try await writeImage(channel: channel, control: .sharpness) { node in
            casing.sharpnessNode(node, level: level)
        }
    }

    /// Writes the WDR mode and, when the mode takes one, its level.
    @discardableResult
    public func setWDR(channel: ChannelID, _ setting: WDRSetting)
        async throws(ISAPIError) -> ImageSettings {
        try await writeImage(channel: channel, control: .wdr) { node in
            ImageWrite.wdr(node, setting)
        }
    }

    /// Writes the IR-cut / day-night mode.
    ///
    /// - Throws: `.malformedResponse` for `schedule` and `triggeredByAlarmIn`, which carry schedule
    ///   and alarm-input configuration Vigil does not model — writing the mode alone would discard
    ///   the user's schedule silently, so the mode is not offered in the UI and is refused here.
    @discardableResult
    public func setIRCut(channel: ChannelID, _ setting: IRCutSetting)
        async throws(ISAPIError) -> ImageSettings {
        try await writeImage(channel: channel, control: .ircut) { node in
            ImageWrite.irCut(node, setting)
        }
    }

    /// Writes the image flip.
    @discardableResult
    public func setFlip(channel: ChannelID, _ setting: FlipSetting)
        async throws(ISAPIError) -> ImageSettings {
        try await writeImage(channel: channel, control: .flip) { node in
            ImageWrite.flip(node, setting)
        }
    }

    /// Writes the supplement lamp's mode and brightness.
    ///
    /// Separate from ``setIRCut(channel:_:)`` because they are separate things: the filter decides
    /// whether the sensor sees infrared, the lamp decides whether any is being emitted. A camera can
    /// have either without the other.
    @discardableResult
    public func setSupplementLight(channel: ChannelID, _ setting: SupplementLightSetting)
        async throws(ISAPIError) -> ImageSettings {
        try await writeImage(channel: channel, control: .supplementLight) { node in
            ImageWrite.supplementLight(node, setting)
        }
    }

    /// `PUT …/defaultConfiguration` — the "reset image settings" action.
    ///
    /// The one image write with no read-modify-write: it has no body at all, so there is nothing to
    /// echo and nothing to preserve. The cache is dropped rather than confirmed by a re-read,
    /// because the caller re-reads the whole panel after a reset anyway.
    public func resetImageDefaults(channel: ChannelID) async throws(ISAPIError) {
        try await put(ISAPIResource.imageDefaults(channel), body: nil)
        imageBoxes[channel] = nil
    }

    /// The shared body of every image setter: read-modify-write, then re-read the whole panel.
    ///
    /// The cache is dropped **before** the confirming read, not after: dropping it afterwards would
    /// let the re-read be served from the entry the write just invalidated, and the caller would be
    /// shown the value it asked for rather than the value the device kept.
    func writeImage(channel: ChannelID, control: ImageControl,
                    patch: (XMLNode) -> XMLNode?) async throws(ISAPIError) -> ImageSettings {
        _ = try await readModifyWrite(ISAPIResource.image(channel, control), patch: patch)
        imageBoxes[channel] = nil
        return try await imageSettings(channel: channel)
    }
}
