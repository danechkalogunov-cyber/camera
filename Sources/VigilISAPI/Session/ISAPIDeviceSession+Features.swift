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
