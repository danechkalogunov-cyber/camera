//
//  ISAPIDeviceSession+Streaming.swift
//  VigilISAPI
//
//  Stream configuration, the keyframe request of R-24, and the session's own lifecycle.
//  Split from ISAPIDeviceSession.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

import Foundation
import VigilProtocols

// MARK: - Streaming, keyframes and lifecycle

/// ⚠️ Members are `internal`, not `private`: Swift scopes `private` to one file.
/// `Scripts/lint.py`'s `split-access` rule fails the build on any left behind.
extension ISAPIDeviceSession {

    // MARK: - Streaming

    /// `GET /ISAPI/Streaming/channels`. Cached 30 s, invalidated by any stream write.
    public func streamingChannels(force: Bool = false)
        async throws(ISAPIError) -> [StreamingChannelConfig] {
        if !force, let box = streamingBox, box.isFresh(at: now(), ttl: ttl.streamingChannels) {
            return box.value
        }
        let document = try await get(ISAPIResource.streamingChannels)
        let decoded = StreamingChannelConfig.list(document: document)
        if !decoded.skipped.isEmpty {
            logger.warning(.isapi, "streaming channels skipped",
                           ["ids": decoded.skipped.map(String.init).joined(separator: ",")])
        }
        streamingBox = Timestamped(value: decoded.channels, storedAt: now())
        return decoded.channels
    }

    /// One stream's configuration, freshly read.
    ///
    /// **Quirk consultation point 1 (path builder):** 5.1.x cameras answer only the single-digit
    /// resource. A 404 or `notSupport` on the three-digit form of a *main* stream is what teaches the
    /// session that, and the request is then retried once at the single-digit resource — so the
    /// first stream configuration a 5.1.x camera is asked for costs two round trips and every
    /// subsequent one costs one. A substream keeps the three-digit spelling either way: the
    /// single-digit resource returns the main stream, and writing that back would overwrite the
    /// main stream's configuration with the substream's.
    public func streamingChannel(_ id: StreamingChannelID)
        async throws(ISAPIError) -> StreamingChannelConfig {
        do {
            let document = try await get(resolver.streamingChannelResource(id))
            return try StreamingChannelConfig(node: document.root)
        } catch {
            guard Self.suggestsWrongResourceSpelling(error), id.quality == .main,
                  !resolver.quirks.streamingChannelIDIsSingleDigit else {
                throw error
            }
            await learn(.streamingChannelIDRejected)
            let document = try await get(resolver.streamingChannelResource(id))
            return try StreamingChannelConfig(node: document.root)
        }
    }

    /// True for the failures that mean "this resource spelling is wrong", not "the device is unwell".
    static func suggestsWrongResourceSpelling(_ error: ISAPIError) -> Bool {
        switch error {
        case .notFound, .notSupported: true
        default: false
        }
    }

    /// Writes one stream's configuration: read-modify-write on the full element, then re-`GET`
    /// (R-30).
    ///
    /// - Returns: the configuration the device is actually running, read back after the write —
    ///   never the requested one. `maxFrameRate` is clamped to what the sensor and the chosen
    ///   resolution allow, and showing the user their own request would misreport the camera.
    /// - Throws: `.device(statusCode:sub:)` with `badParameters` for a patch that client-side
    ///   validation already knows the device will reject, so an obviously bad value costs no round
    ///   trip; `.malformedResponse` when the device sent an element with nothing to modify.
    public func updateStream(_ id: StreamingChannelID, _ patch: StreamingChannelPatch)
        async throws(ISAPIError) -> StreamingChannelConfig {
        let failures = patch.validationFailures()
        guard failures.isEmpty else {
            logger.warning(.isapi, "stream patch refused locally",
                           ["reasons": failures.joined(separator: "; ")])
            throw ISAPIError.device(statusCode: 4, sub: ResponseStatus.SubStatus.badParameters)
        }
        let current = try await streamingChannel(id)
        guard let element = current.originalNode else {
            throw ISAPIError.malformedResponse(
                "no <StreamingChannel> element to modify for channel \(id.value)")
        }
        let resource = resolver.streamingChannelResource(id)
        // **Quirk consultation point 2 (body builder):** the declaration, and the device's own
        // `version` and `xmlns` attributes, ride back out with the element untouched (R-30).
        try await put(resource, body: resolver.bodyBytes(patch.applied(to: element)))
        // Any stream write invalidates the stream and channel rows (§18.1), and it must happen
        // *before* the confirming read or that read would be served from the cache it just staled.
        streamingBox = nil
        channelsBox = nil
        return try await streamingChannel(id)
    }

    /// `GET …/picture`. Never cached here: `VigilCore` owns thumbnail retention.
    ///
    /// **Quirk consultation point 1 (path builder):** a device that refused the resolution query is
    /// asked without it from then on. The first refusal is retried immediately, so the caller still
    /// gets its image, and the negative entry that refusal just made is dropped — the resource is
    /// supported, only the query was not.
    public func snapshot(_ request: SnapshotWireRequest) async throws(ISAPIError) -> Data {
        let effective = resolver.snapshotRequest(request)
        do {
            let body = try await getBytes(effective.resource, query: effective.query, lane: .snapshot)
            return try SnapshotPayload.validate(body, contentType: nil)
        } catch {
            guard Self.suggestsQueryWasRefused(error), !effective.query.isEmpty else { throw error }
            negative.forget(effective.resource)
            await learn(.snapshotResolutionQueryRejected)
            let retry = effective.withoutResolutionQuery
            let body = try await getBytes(retry.resource, query: retry.query, lane: .snapshot)
            return try SnapshotPayload.validate(body, contentType: nil)
        }
    }

    /// True for the answers a `/picture` request with resolution query items draws on the firmwares
    /// that do not implement it: `403 notSupport` maps to `.notSupported`, a bare 403 to
    /// `.insufficientPermission`, and some builds answer 400 as `badParameters`.
    static func suggestsQueryWasRefused(_ error: ISAPIError) -> Bool {
        switch error {
        case .notSupported, .insufficientPermission: true
        case let .device(_, sub): sub == ResponseStatus.SubStatus.badParameters
        default: false
        }
    }

    // MARK: - Keyframe request (R-24)

    /// Asks the device for an immediate I-frame (R-24, docs/FEATURES.md F-DEC-05).
    ///
    /// The primary rung of the keyframe chain. Rate-limited to one request per channel per 2 s and
    /// five per 30 s; over either limit this is a **silent no-op** and `suppressedKeyFrameRequests`
    /// grows. Suppression is not an error, because the caller chooses its fallback rung from
    /// `keyFrameRequestIsAvailable(channel:)` rather than from a thrown error — and because a
    /// keyframe-request storm is how an NVR is made unresponsive.
    ///
    /// Two spellings are tried: `…/requestKeyFrame` on current firmware and `…/keyFrame` on older
    /// builds. The first refusal is cached by template, so a device without the feature costs two
    /// round trips once and none afterwards.
    public func requestKeyFrame(channel: ChannelID) async throws(ISAPIError) {
        guard keyFrameRequestIsAvailable(channel: channel) else {
            suppressedKeyFrameRequests += 1
            return
        }
        keyFrameRequests[channel, default: []].append(now())
        let id = StreamingChannelID(channel: channel, quality: .main)
        do {
            try await put(Self.requestKeyFrameResource(id), body: nil)
        } catch {
            guard Self.suggestsWrongResourceSpelling(error) else { throw error }
            try await put(Self.legacyKeyFrameResource(id), body: nil)
        }
    }

    /// True when the R-24 rate limit would let a keyframe request through right now.
    ///
    /// Exposed so `VigilCore` can go straight to its fallback rung instead of calling into a no-op.
    /// Trims the window as it reads it, so the history cannot grow with uptime.
    public func keyFrameRequestIsAvailable(channel: ChannelID) -> Bool {
        let instant = now()
        let cutoff = instant.nanoseconds - Int64(Self.keyFrameBurstWindowSeconds * 1e9)
        let recent = (keyFrameRequests[channel] ?? []).filter { $0.nanoseconds >= cutoff }
        keyFrameRequests[channel] = recent
        guard recent.count < Self.keyFrameBurstLimit else { return false }
        guard let last = recent.last else { return true }
        return instant.seconds(since: last) >= Self.keyFrameMinimumIntervalSeconds
    }

    /// `PUT /ISAPI/Streaming/channels/{id}/requestKeyFrame`.
    ///
    /// Spelled here rather than in `ISAPIResource` because the keyframe request is not in the
    /// Appendix A endpoint table that file mirrors: it comes from docs/spec-rtp.md §7 and
    /// docs/FEATURES.md F-DEC-05. Folding it into `ISAPIResource` is a one-line follow-up.
    static func requestKeyFrameResource(_ id: StreamingChannelID) -> String {
        "/Streaming/channels/\(id.value)/requestKeyFrame"
    }

    /// The legacy spelling some older firmware uses instead.
    static func legacyKeyFrameResource(_ id: StreamingChannelID) -> String {
        "/Streaming/channels/\(id.value)/keyFrame"
    }

    // MARK: - Lifecycle

    /// The quirk record as it now stands. `VigilCore` persists this on the camera row.
    public var observedQuirks: DeviceQuirks { resolver.quirks }

    /// Templates this device has refused, for the diagnostics bundle.
    public var suppressedCapabilityTemplates: [String] { negative.suppressedTemplates }

    /// `PUT /ISAPI/System/reboot`.
    ///
    /// A lost connection or a timeout **after** the request went out counts as success
    /// (docs/spec-isapi.md §17.3): the device stopped answering because it is rebooting, which is
    /// what was asked for. Every cache is flushed either way.
    public func reboot() async throws(ISAPIError) {
        do {
            try await put(ISAPIResource.reboot, body: nil)
        } catch {
            invalidateCaches()
            switch error {
            case .notConnected, .timedOut, .streamEnded:
                logger.info(.isapi, "reboot lost its connection, which means it landed")
                return
            default:
                throw error
            }
        }
        invalidateCaches()
    }

    /// Drops every cached value and every negative entry.
    ///
    /// Called on a credential change, a detected reboot, `AlertStreamState.authFailed` and an
    /// endpoint change (docs/spec-isapi.md §18.1). The quirk record deliberately survives: it
    /// describes the firmware, not the session, and re-learning it costs the user real round trips.
    public func invalidateCaches() {
        deviceInfoBox = nil
        capabilitiesBox = nil
        capabilitiesFirmware = nil
        timeBox = nil
        statusBox = nil
        channelsBox = nil
        streamingBox = nil
        recordTracksBox = nil
        storageBox = nil
        eventTriggersBox = nil
        ptzCapabilityBoxes.removeAll()
        imageBoxes.removeAll()
        dayIndexBoxes.removeAll()
        monthCalendarBoxes.removeAll()
        negative.clear()
    }

    /// Stops everything this session owns: every PTZ keep-alive, the alert stream, every cache.
    ///
    /// PTZ is stopped **first**, with the triple zero-stop discipline `PTZController.stop()`
    /// implements, because a camera left panning after the app quits is the one failure a user
    /// cannot undo from inside Vigil.
    public func shutdown() async {
        for controller in ptzControllers.values {
            await controller.stop()
        }
        ptzControllers.removeAll()
        await alertMonitor?.stop()
        alertMonitor = nil
        invalidateCaches()
    }
}
