//
//  ISAPIDeviceSession+Connect.swift
//  VigilISAPI
//
//  The connect sequence: the ten ordered steps Vigil runs the first time it talks to a device, the
//  12-second budget they share, and the functional probes that settle the capability rows
//  `/System/capabilities` left unresolved.
//  Implements docs/spec-isapi.md §18.2 and §10.5, and docs/API_CONTRACT.md §4.5.
//
//  Two steps are mandatory and eight are not, and that asymmetry is the whole design. Steps 1 and 2
//  establish "this is a Hikvision device and these credentials work"; a failure there is the user's
//  problem and is reported as such. Everything after them establishes what the device *can do*, and
//  a failure there must degrade a feature rather than fail the connection — a camera whose PTZ
//  endpoint is broken is still a camera the user wants to watch. So every later step is best-effort,
//  every one that fails records a `Degradation`, and the outcome carries the list so the UI can grey
//  out exactly what is missing instead of showing a modal.
//
//  Steps 1–4 are what the first tile needs before it can open a stream. On a DS-7608 over gigabit
//  LAN the spec measures 180–350 ms for those four.
//

import Foundation
import VigilProtocols

// MARK: - ConnectOutcome

extension ISAPIDeviceSession {

    /// A feature the connect sequence could not establish.
    ///
    /// The raw value is a stable key `VigilCore` maps to a localised string and puts in the
    /// diagnostics bundle, so adding a case is a UI change rather than a silent behaviour change.
    /// None of these is an error: each one means "hide this affordance", which is the only honest
    /// thing to do with a feature the device did not answer for.
    public enum Degradation: String, Sendable, Hashable, CaseIterable {

        /// `/System/capabilities` did not answer; the family defaults and the probes are in force.
        case capabilitiesUnavailable

        /// `/System/time` did not answer. Only affects the device-local playback quirk, which is
        /// then assumed off.
        case timeUnavailable

        /// `/Streaming/channels` did not answer, so channel 1 main/sub was synthesised. Streaming
        /// may still work; it will fail visibly at the RTSP layer if it does not.
        case channelListSynthesised

        /// No PTZ on any channel. Every PTZ affordance is hidden.
        case ptzUnavailable

        /// No recording tracks, or no storage. The playback tab is hidden.
        case playbackUnavailable

        /// The event stream was not started, because the device said it has none.
        case alertStreamUnavailable

        /// The 12 s budget ran out before the optional steps finished. What did complete is in the
        /// outcome; the rest is re-probed lazily on first use.
        case budgetExceeded
    }

    /// Everything the connect sequence established.
    ///
    /// `identity` and `credentials` are non-optional because the sequence throws rather than
    /// returning without them. Everything else may be empty or `nil`, and `degradations` says why.
    public struct ConnectOutcome: Sendable {

        /// Step 1. The identity anchor: `VigilCore` keys the camera row on `serialNumber`.
        public var identity: DeviceInfo

        /// Step 2. Both `ok == false` and a thrown `.accountLocked` mean "do not retry"; this is
        /// the former, and it carries `remainingAttempts` for the warning the UI shows at one left.
        public var credentials: UserCheckResult

        /// Step 3, then step 7's probes folded in. Never `nil`: the family defaults stand in.
        public var capabilities: DeviceCapabilitiesWire

        /// Step 4–6, merged. Never empty: channel 1 is synthesised rather than returning nothing.
        public var channels: [DeviceChannel]

        /// Step 3. `nil` when the device did not answer.
        public var time: DeviceTime?

        /// Step 8. The channels that actually have PTZ, already capability-probed and cached.
        public var ptzChannels: [ChannelID]

        /// Step 9.
        public var recordTracks: [RecordTrack]

        /// Step 9. `nil` when the device has no storage endpoint — a camera with no card.
        public var storage: StorageInfo?

        /// The quirk record as it stands after the sequence. `VigilCore` persists this.
        public var quirks: DeviceQuirks

        /// What the sequence could not establish. Empty on a healthy NVR.
        public var degradations: Set<Degradation>

        /// Wall-to-wall duration on the injected monotonic clock, for the diagnostics panel and for
        /// the regression that would otherwise let this sequence quietly grow to four seconds.
        public var elapsedSeconds: Double

        /// True when the optional steps were cut short. Also present in `degradations`.
        public var exceededBudget: Bool { degradations.contains(.budgetExceeded) }

        /// True when a tile can open a stream: steps 1–4 all landed.
        public var canStream: Bool { !channels.isEmpty }
    }
}

// MARK: - The sequence

extension ISAPIDeviceSession {

    /// The overall budget for one connect sequence (docs/spec-isapi.md §18.2).
    ///
    /// Checked **between** steps rather than raced against them: enforcing it as a hard deadline
    /// would mean cancelling a request mid-flight, and a cancelled `PUT`-less `GET` still costs the
    /// device the work it has already done while telling Vigil nothing. Each individual request is
    /// separately bounded by its lane's timeout in `ISAPIClient.Configuration`, so the worst case is
    /// one over-running step and not an unbounded wait. See the deviation note in the module result.
    public static let connectBudgetSeconds: Double = 12

    /// How many optional requests the sequence has in flight at once (§18.2, "parallel (2)").
    ///
    /// Two, not more: the documented ceiling for a low-end camera is three concurrent ISAPI
    /// requests in total, and the connect sequence is not the only thing talking to the device —
    /// the first tile is already trying to open an RTSP stream while step 7 runs.
    static let connectProbeConcurrency = 2

    /// Runs the connect sequence.
    ///
    /// - Parameters:
    ///   - startingAlertStream: step 10. `true` runs it, which is the documented sequence. Pass
    ///     `false` when the caller wants to subscribe to `alertStream().notifications()` *before*
    ///     the first event can arrive — the notification stream is live, so an event that lands
    ///     between `start()` and the first subscription is not replayed.
    /// - Returns: what was established, plus the list of what was not.
    /// - Throws: only from steps 1 and 2. `.authenticationFailed` when the credentials are wrong —
    ///   the UI prompts. `.accountLocked` when the device has locked the account — the UI must
    ///   **not** retry, because each retry extends the lock-out. `.notFound` / `.timedOut` /
    ///   `.malformedResponse` when the endpoint is not ISAPI at all, which is where the UI offers
    ///   the ONVIF fallback.
    @discardableResult
    public func connect(startingAlertStream: Bool = true)
        async throws(ISAPIError) -> ConnectOutcome {
        let started = now()
        let deadline = started.nanoseconds + Int64(Self.connectBudgetSeconds * 1e9)
        var degradations: Set<Degradation> = []

        // Step 1 — identity. Serial, mandatory. Also seeds the quirk record from the firmware.
        let identity = try await deviceInfo(force: true)
        logger.notice(.isapi, "device identified", [
            "model": identity.model,
            "firmware": identity.firmwareVersion.raw,
            "family": String(describing: identity.family),
        ])

        // Step 2 — credentials and lock-out. Serial, mandatory, and never cached: its whole value
        // is being current. A locked account is thrown, not returned, because the one thing the UI
        // must not do is retry.
        let credentials = try await checkCredentials()
        if credentials.isLocked {
            throw ISAPIError.accountLocked(retryAfter: credentials.unlockAfter)
        }
        if credentials.notActivated {
            throw ISAPIError.deviceNotActivated
        }

        // Step 3 — capabilities and time, in parallel. Both optional.
        var wire = await bestEffortCapabilities(&degradations)
        let deviceTime = await bestEffortTime(&degradations)

        // Steps 4–6 — the channel inventory. `channels()` is steps 4, 5 and 6: it reads
        // `/Streaming/channels`, then the NVR's proxied channels and their status, then the local
        // video inputs, and merges them. Keeping the merge in one place is why they are not spelled
        // out separately here.
        let inventory = try await bestEffortChannels(&degradations)

        // Step 7 — functional probes, but only for the rows `/System/capabilities` left unresolved.
        if withinBudget(deadline) {
            wire = await probeCapabilities(wire, channels: inventory)
        } else {
            degradations.insert(.budgetExceeded)
        }
        // The counted rows come from the inventory that was just built rather than from a probe:
        // the device already told us, in the one answer we had to have anyway.
        wire.applyCount(.videoInputChannels, inventory.count)
        storeCapabilities(wire, firmware: identity.firmwareVersion.raw)

        // Step 8 — PTZ. `ptzCapabilities` caches per channel and returns `.absent` on a refusal, so
        // the channels that survive the filter are exactly the ones with a usable PTZ surface.
        var ptzChannels: [ChannelID] = []
        if withinBudget(deadline) {
            ptzChannels = await probePTZ(channels: inventory)
            if ptzChannels.isEmpty { degradations.insert(.ptzUnavailable) }
        } else {
            degradations.insert(.budgetExceeded)
        }

        // Step 9 — playback. Tracks and storage together decide whether the tab appears at all.
        var tracks: [RecordTrack] = []
        var volumes: StorageInfo?
        if withinBudget(deadline) {
            tracks = (try? await recordTracks()) ?? []
            volumes = try? await storage()
        } else {
            degradations.insert(.budgetExceeded)
        }
        if tracks.isEmpty, volumes?.volumes.isEmpty ?? true {
            degradations.insert(.playbackUnavailable)
        }

        // Step 10 — the event stream, in the background. Not budgeted: it never completes, it runs
        // for the life of the session, and its own backoff ladder owns its timing.
        if startingAlertStream, wire.supportsAlertStream {
            await alertStream().start()
        } else if !wire.supportsAlertStream {
            degradations.insert(.alertStreamUnavailable)
        }

        let elapsed = now().seconds(since: started)
        logger.notice(.isapi, "connect sequence complete", [
            "elapsedMS": String(Int(elapsed * 1000)),
            "channels": String(inventory.count),
            "degraded": degradations.map(\.rawValue).sorted().joined(separator: ","),
        ])
        return ConnectOutcome(identity: identity, credentials: credentials, capabilities: wire,
                              channels: inventory, time: deviceTime, ptzChannels: ptzChannels,
                              recordTracks: tracks, storage: volumes, quirks: resolver.quirks,
                              degradations: degradations, elapsedSeconds: elapsed)
    }

    /// True while the budget has time left on the injected clock.
    func withinBudget(_ deadlineNanoseconds: Int64) -> Bool {
        now().nanoseconds < deadlineNanoseconds
    }

    // MARK: Step 3

    /// Step 3's capabilities read. Never throws: `capabilities()` already falls back to the family
    /// defaults, so only a `deviceInfo` re-read inside it could fail, and that has already happened.
    func bestEffortCapabilities(_ degradations: inout Set<Degradation>)
        async -> DeviceCapabilitiesWire {
        guard let wire = try? await capabilities(force: true) else {
            degradations.insert(.capabilitiesUnavailable)
            // `deviceInfo` has already succeeded by the time step 3 runs, so the box is populated;
            // `.unknown` is the defensive branch, and its defaults are the conservative ones.
            let family: DeviceFamily = deviceInfoBox?.value.family ?? .unknown
            return DeviceCapabilitiesWire(family: family, probedAt: wallClock.now)
        }
        // Every row still unresolved after the read is one the device did not mention, which is
        // exactly what step 7 exists to settle.
        if !wire.unresolved.isEmpty {
            logger.debug(.isapi, "capability rows unresolved after read",
                         ["rows": wire.unresolved.map(\.rawValue).sorted().joined(separator: ",")])
        }
        return wire
    }

    /// Step 3's time read.
    func bestEffortTime(_ degradations: inout Set<Degradation>) async -> DeviceTime? {
        guard let value = try? await time(force: true) else {
            degradations.insert(.timeUnavailable)
            return nil
        }
        return value
    }

    // MARK: Steps 4–6

    /// Steps 4, 5 and 6: the merged channel inventory, or the synthesised single channel.
    ///
    /// `channels()` already synthesises channel 1 when `/Streaming/channels` fails, so the only way
    /// this rethrows is a failure the inventory could not absorb at all — and then the connection is
    /// genuinely unusable, because nothing can be streamed.
    func bestEffortChannels(_ degradations: inout Set<Degradation>)
        async throws(ISAPIError) -> [DeviceChannel] {
        let inventory = try await channels(force: true)
        // The synthesised fallback is exactly one channel with no streams attached; a real
        // single-channel camera has its stream configurations merged in.
        if inventory.count == 1, inventory[0].streams.isEmpty {
            degradations.insert(.channelListSynthesised)
        }
        return inventory
    }

    // MARK: Step 7 — functional probes

    /// The `GET` that settles one capability row, for the rows that can be settled by one.
    ///
    /// A row with no entry here stays unresolved, which is the honest answer and not an omission:
    /// `supportsAlertStream` cannot be probed without opening the stream — step 10 and the monitor's
    /// own state report it — and `supportsHTTPS` cannot be probed at all from the plain-HTTP session
    /// that is already connected. Guessing either would be worse than saying "not known yet".
    ///
    /// - Parameter channel: the channel the per-channel probes address. Channel 1 in practice; the
    ///   negative cache collapses the number to `{n}` anyway, so one probe settles every channel.
    static func probeResource(for capability: DeviceCapability,
                              channel: ChannelID) -> (resource: String, lane: HTTPLane)? {
        switch capability {
        case .supportsPTZ: (ISAPIResource.ptzCapabilities(channel), .control)
        case .supportsPatrols: (ISAPIResource.ptzPatrols(channel), .control)
        case .supportsTwoWayAudio: (ISAPIResource.twoWayAudioChannels, .control)
        case .supportsRecordSearch: (ISAPIResource.recordTracks, .control)
        case .supportsInputProxy: (ISAPIResource.inputProxyChannels, .control)
        case .supportsImageColor: (ISAPIResource.image(channel, .color), .control)
        case .supportsWDR: (ISAPIResource.image(channel, .wdr), .control)
        case .supportsIRCutFilter: (ISAPIResource.image(channel, .ircut), .control)
        case .supportsAlertStream, .supportsHTTPS, .supportsSmartEvents,
             .supportsJPEGSnapshot, .videoInputChannels, .audioInputChannels,
             .streamsPerChannel, .alarmInputs, .alarmOutputs:
            nil
        }
    }

    /// Step 7: probes the unresolved rows, at most `connectProbeConcurrency` at a time.
    ///
    /// A probe is a plain `GET`: a 200 resolves the row `true`, a `403 notSupport` / `404` / `405`
    /// resolves it `false`, and either way the row stops being unresolved so it is never probed
    /// twice. The refusals also land in the negative-capability cache on the way through `get`, so
    /// the feature that would have used the endpoint costs no round trip for the next 24 h.
    func probeCapabilities(_ wire: DeviceCapabilitiesWire,
                           channels: [DeviceChannel]) async -> DeviceCapabilitiesWire {
        let channel = channels.first?.channel ?? .first
        let rows = wire.unresolved
            .compactMap { row in
                Self.probeResource(for: row, channel: channel).map { (row, $0.resource, $0.lane) }
            }
            .sorted { $0.0.rawValue < $1.0.rawValue }   // deterministic probe order for the tests
        guard !rows.isEmpty else { return wire }

        var results: [DeviceCapability: Bool] = [:]
        await withTaskGroup(of: (DeviceCapability, Bool).self) { group in
            var pending = rows[...]
            func addNext() {
                guard let (row, resource, lane) = pending.popFirst() else { return }
                group.addTask { (row, await self.probe(resource, lane: lane)) }
            }
            for _ in 0..<Self.connectProbeConcurrency { addNext() }
            while let (row, supported) = await group.next() {
                results[row] = supported
                addNext()
            }
        }
        var resolved = wire
        for (row, supported) in results.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            resolved.applyProbe(row, supported: supported)
        }
        logger.info(.isapi, "capability probes settled", [
            "supported": results.filter(\.value).keys.map(\.rawValue).sorted()
                .joined(separator: ","),
            "unsupported": results.filter { !$0.value }.keys.map(\.rawValue).sorted()
                .joined(separator: ","),
        ])
        return resolved
    }

    /// One functional probe. `true` when the device answered, `false` when it refused.
    ///
    /// A transport failure — a timeout, a dropped connection — resolves the row `false` as well.
    /// That is the pragmatic choice rather than the pedantic one: a row left unresolved would be
    /// re-probed on every connect, and a device that cannot answer this endpoint inside its lane
    /// timeout cannot usefully serve the feature behind it either. The row is re-probed on the next
    /// firmware change, because the capability cache is keyed by firmware version.
    func probe(_ resource: String, lane: HTTPLane) async -> Bool {
        do {
            _ = try await get(resource, lane: lane)
            return true
        } catch {
            logger.debug(.isapi, "capability probe refused",
                         ["resource": resource, "reason": error.userMessageKey])
            return false
        }
    }

    // MARK: Step 8 — PTZ

    /// Step 8: the channels with a usable PTZ surface, capabilities cached along the way.
    ///
    /// `/PTZCtrl/channels` is asked first because on an NVR it is one request instead of one per
    /// channel; a camera that does not have the list falls back to the inventory. Per-channel
    /// capability reads then run two at a time, and `.absent` is what filters a channel out.
    func probePTZ(channels: [DeviceChannel]) async -> [ChannelID] {
        let candidates = await ptzChannels()
        let known = Set(channels.map(\.channel))
        // A channel the PTZ list names but the inventory does not is dropped: it cannot be shown,
        // and building a controller for it would put PTZ buttons on nothing.
        let filtered = candidates.filter { known.contains($0) || known.isEmpty }
        guard !filtered.isEmpty else { return [] }

        var supported: Set<ChannelID> = []
        await withTaskGroup(of: (ChannelID, Bool).self) { group in
            var pending = filtered[...]
            func addNext() {
                guard let channel = pending.popFirst() else { return }
                group.addTask {
                    let wire = try? await self.ptzCapabilities(channel: channel)
                    return (channel, !(wire?.isAbsent ?? true))
                }
            }
            for _ in 0..<Self.connectProbeConcurrency { addNext() }
            while let (channel, hasPTZ) = await group.next() {
                if hasPTZ { supported.insert(channel) }
                addNext()
            }
        }
        // Returned in inventory order, not completion order, so the UI's channel list is stable.
        return filtered.filter { supported.contains($0) }
    }
}
