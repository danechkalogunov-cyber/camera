//
//  PTZController.swift
//  VigilISAPI
//
//  One PTZ-capable channel's command surface: continuous motion with its 400 ms keep-alive and its
//  triple zero-stop, momentary nudges, absolute and relative moves, drag-to-zoom, presets and
//  patrols. Implements docs/spec-isapi.md §13 and docs/API_CONTRACT.md §4.5 (`PTZController`).
//
//  The failure this file exists to prevent is a camera left spinning. A `continuous` command runs
//  until it is stopped or until the device's own watchdog fires, and that watchdog is somewhere
//  between 500 ms and 2 s depending on the model and is not reliable. So: every start is paired
//  with a stop, a held control re-sends the identical command every 400 ms, and the stop is sent as
//  three all-zero bodies 80 ms apart with individual failures ignored — on cancel, on quit, and on
//  any error path out of a move.
//
//  This actor is one of the seven `VigilISAPI` is explicitly granted by API_CONTRACT §2 R-32. It
//  holds only `Sendable` state, reads time only through the injected `MonotonicClock`, and touches
//  no platform framework.
//

import Foundation
import VigilProtocols

// MARK: - PTZController

/// Drives one video input channel's PTZ.
///
/// On an NVR the channel number is the **NVR's** channel and the NVR proxies the command upstream;
/// it is a video input channel in every case, never a streaming channel id.
public actor PTZController {

    /// How often a held control re-sends its command. Defeats every firmware watchdog observed.
    public static let keepAliveInterval: Duration = .milliseconds(400)
    /// How many all-zero bodies a stop sends.
    public static let stopRepeatCount = 3
    /// The gap between them.
    public static let stopRepeatSpacing: Duration = .milliseconds(80)

    private let requests: any ISAPIRequesting
    private let channel: ChannelID
    private let clock: any MonotonicClock
    private let logger: any LoggerProtocol

    /// Capabilities, used to clamp absolute moves and to refuse commands the channel lacks.
    public private(set) var capabilities: PTZCapabilitiesWire

    /// The velocity currently being kept alive, or `nil` when the camera should be stationary.
    private var activeVelocity: PTZVelocity?
    private var keepAlive: Task<Void, Never>?
    /// Counts keep-alive re-sends, so a test can assert the cadence without a wall clock.
    public private(set) var keepAliveSendCount = 0

    /// - Parameters:
    ///   - requests: the HTTP surface; PTZ writes go on `.control`, which the client gives a 2 s
    ///     budget and one over-subscribed slot when the resource is under `/PTZCtrl/`.
    ///   - channel: the **video input** channel.
    ///   - capabilities: from `/PTZCtrl/channels/{ch}/capabilities`, or `.absent`.
    ///   - clock: the only time source; the keep-alive and the stop spacing both use it.
    public init(requests: any ISAPIRequesting, channel: ChannelID,
                capabilities: PTZCapabilitiesWire, clock: any MonotonicClock,
                logger: any LoggerProtocol = NullLogger()) {
        self.requests = requests
        self.channel = channel
        self.capabilities = capabilities
        self.clock = clock
        self.logger = logger
    }

    // MARK: Continuous motion

    /// Starts or updates a continuous move and re-arms the 400 ms keep-alive.
    ///
    /// An all-zero triple is a stop and is routed to `stop()`, so a caller that drives this from a
    /// joystick axis never has to special-case the centre position.
    public func continuous(pan: Int, tilt: Int, zoom: Int) async throws(ISAPIError) {
        try await move(PTZVelocity(pan: pan, tilt: tilt, zoom: zoom))
    }

    /// Starts or updates a continuous move.
    ///
    /// On any failure the keep-alive is torn down and a stop is issued before the error is
    /// rethrown: a half-started move that keeps being re-sent is the exact runaway this file is
    /// written to prevent.
    public func move(_ velocity: PTZVelocity) async throws(ISAPIError) {
        guard !velocity.isStopped else {
            await stop()
            return
        }
        guard !capabilities.isAbsent else {
            throw ISAPIError.notSupported(resource: ISAPIResource.ptzContinuous(channel))
        }
        activeVelocity = velocity
        do {
            try await send(velocity)
        } catch {
            await stop()
            throw error
        }
        armKeepAlive(velocity)
    }

    /// Cancels the keep-alive and sends the triple zero-stop. **Never throws.**
    ///
    /// Individual failures are ignored on purpose: two of the three may fail and the camera still
    /// stops, whereas propagating the first failure would skip the other two.
    public func stop() async {
        keepAlive?.cancel()
        keepAlive = nil
        activeVelocity = nil
        for index in 0..<Self.stopRepeatCount {
            try? await send(.stopped)
            if index + 1 < Self.stopRepeatCount {
                try? await clock.sleep(for: Self.stopRepeatSpacing)
            }
        }
    }

    /// Fires a stop without waiting for it, for the paths that cannot `await`: task cancellation,
    /// app deactivation, window close and termination.
    ///
    /// Detached rather than a child task, so cancelling the caller does not cancel the stop — the
    /// whole point is that the camera stops even as the app goes away. There is deliberately **no**
    /// artificial deadline racing it: cutting a stop short is the failure this file exists to
    /// prevent, and the writes are already bounded, at two seconds each, by the client's PTZ
    /// timeout.
    ///
    /// - Returns: the task, so a caller that *can* wait — a test, or an orderly shutdown — may.
    @discardableResult
    public nonisolated func stopDetached() -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) { [self] in
            await stop()
        }
    }

    // MARK: Discrete motion

    /// A self-terminating nudge. Preferred over `continuous` for taps: it needs no stop and cannot
    /// leave the camera moving if the app is killed mid-gesture.
    ///
    /// `duration` is clamped to 0…60 s at the wire boundary. A `403 notSupport` is the caller's
    /// signal to fall back to `continuous` plus a timed stop and to remember the quirk.
    public func momentary(pan: Int, tilt: Int, zoom: Int,
                          duration: Duration) async throws(ISAPIError) {
        let velocity = PTZVelocity(pan: pan, tilt: tilt, zoom: zoom)
        let milliseconds = Int(duration.components.seconds * 1000
                               + duration.components.attoseconds / 1_000_000_000_000_000)
        try await requests.put(ISAPIResource.ptzMomentary(channel),
                               velocity.momentaryBody(durationMilliseconds: milliseconds),
                               lane: .control)
    }

    /// Moves to an absolute position, clamped into the channel's advertised ranges.
    public func absolute(_ position: PTZAbsolutePosition) async throws(ISAPIError) {
        guard !capabilities.isAbsent else {
            throw ISAPIError.notSupported(resource: ISAPIResource.ptzAbsolute(channel))
        }
        try await requests.put(ISAPIResource.ptzAbsolute(channel),
                               position.body(clampedTo: capabilities), lane: .control)
    }

    /// Moves by a relative offset in device steps.
    public func relative(_ move: PTZRelativeMove) async throws(ISAPIError) {
        try await requests.put(ISAPIResource.ptzRelative(channel), move.body, lane: .control)
    }

    /// Drag-to-zoom, or click-to-centre when the box is a point.
    ///
    /// Refused when the channel did not advertise `isSupportPosition3D`: a rejected `position3D`
    /// reads to the user as a broken drag gesture rather than as an unsupported feature, so the
    /// affordance is hidden instead.
    public func position3D(_ box: PTZ3D) async throws(ISAPIError) {
        guard capabilities.supportsPosition3D else {
            throw ISAPIError.notSupported(resource: ISAPIResource.ptzPosition3D(channel))
        }
        try await requests.put(ISAPIResource.ptzPosition3D(channel), box.body, lane: .control)
    }

    // MARK: Presets

    /// The channel's presets, including the reserved 33–105 commands the device reports.
    ///
    /// They are returned rather than filtered out: the UI lists them in a separate, clearly
    /// labelled read-only section, because hiding a preset the camera says it has is confusing.
    public func presets() async throws(ISAPIError) -> [PTZPreset] {
        PTZPreset.list(document: try await requests.getDocument(ISAPIResource.ptzPresets(channel)))
    }

    /// Recalls a preset. Reserved numbers are allowed here — invoking 94 really does reboot the
    /// camera, which is why the UI confirms first — but never written.
    public func gotoPreset(_ n: Int) async throws(ISAPIError) {
        try await requests.putEmpty(ISAPIResource.ptzPresetGoto(channel, n), lane: .control)
    }

    /// Stores the current position in a preset slot.
    ///
    /// Refuses 33–105 without a round trip: those are built-in device commands, and writing 94
    /// would reboot the camera the user was trying to bookmark.
    public func setPreset(_ n: Int, name: String) async throws(ISAPIError) {
        guard !PTZPreset.reservedCommands.contains(n) else {
            logger.warning(.isapi, "refusing to write reserved preset \(n) on channel \(channel)")
            throw ISAPIError.device(statusCode: 4, sub: "reservedPreset")
        }
        try await requests.put(ISAPIResource.ptzPreset(channel, n),
                               PTZPreset.writeBody(id: n, name: name))
    }

    /// Deletes a preset slot. Reserved numbers are refused for the same reason as `setPreset`.
    public func deletePreset(_ n: Int) async throws(ISAPIError) {
        guard !PTZPreset.reservedCommands.contains(n) else {
            throw ISAPIError.device(statusCode: 4, sub: "reservedPreset")
        }
        _ = try await requests.deleteDocument(ISAPIResource.ptzPreset(channel, n),
                                              query: [], lane: .control)
    }

    // MARK: Patrols

    /// The channel's patrols and their stops.
    public func patrols() async throws(ISAPIError) -> [PTZPatrol] {
        PTZPatrol.list(document: try await requests.getDocument(ISAPIResource.ptzPatrols(channel)))
    }

    /// Starts a patrol.
    ///
    /// Stops any continuous move first: starting a patrol while one is active returns
    /// `invalidOperation`, and the user's patrol would silently not run.
    public func startPatrol(_ n: Int) async throws(ISAPIError) {
        await stop()
        try await requests.putEmpty(ISAPIResource.ptzPatrolStart(channel, n))
    }

    /// Stops a patrol.
    public func stopPatrol(_ n: Int) async throws(ISAPIError) {
        try await requests.putEmpty(ISAPIResource.ptzPatrolStop(channel, n))
    }

    // MARK: Home, status, lens, auxiliary

    /// Recalls the configured home position.
    public func gotoHome() async throws(ISAPIError) {
        try await requests.putEmpty(ISAPIResource.ptzHomeGoto(channel), lane: .control)
    }

    /// Reads the current absolute position. Never cached.
    public func status() async throws(ISAPIError) -> PTZStatus {
        try PTZStatus(document: try await requests.getDocument(ISAPIResource.ptzStatus(channel)))
    }

    /// Continuous focus, −100…100, zero to stop. Note the path: focus lives under the video input.
    public func setFocus(_ velocity: Int) async throws(ISAPIError) {
        try await requests.put(ISAPIResource.focus(channel), PTZLensCommand.focus(velocity),
                               lane: .control)
    }

    /// Continuous iris, −100…100, zero to stop.
    public func setIris(_ velocity: Int) async throws(ISAPIError) {
        try await requests.put(ISAPIResource.iris(channel), PTZLensCommand.iris(velocity),
                               lane: .control)
    }

    /// Switches an auxiliary output such as a light or wiper.
    public func auxiliary(_ aux: PTZAuxiliary, id: Int = 1, on: Bool) async throws(ISAPIError) {
        try await requests.put(ISAPIResource.ptzAux(channel), aux.body(id: id, on: on), lane: .control)
    }

    /// Replaces the capability snapshot, after a re-probe.
    public func updateCapabilities(_ capabilities: PTZCapabilitiesWire) {
        self.capabilities = capabilities
    }

    // MARK: Internals

    /// One `PUT .../continuous` with the given triple.
    private func send(_ velocity: PTZVelocity) async throws(ISAPIError) {
        try await requests.put(ISAPIResource.ptzContinuous(channel), velocity.body, lane: .control)
    }

    /// (Re)arms the keep-alive for `velocity`, replacing any previous one.
    private func armKeepAlive(_ velocity: PTZVelocity) {
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            await self?.runKeepAlive(velocity)
        }
    }

    /// Re-sends `velocity` every `keepAliveInterval` until it is superseded or cancelled.
    ///
    /// The loop stops the moment `activeVelocity` changes, so a joystick that moves from
    /// (60, 0, 0) to (0, 40, 0) does not end up with two keep-alives fighting each other.
    private func runKeepAlive(_ velocity: PTZVelocity) async {
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: Self.keepAliveInterval)
            } catch {
                return          // cancelled while sleeping; `stop()` owns the zero-stop
            }
            guard !Task.isCancelled, activeVelocity == velocity else { return }
            keepAliveSendCount += 1
            do {
                try await send(velocity)
            } catch {
                // A dropped keep-alive is survivable — the next one is 400 ms away — but a
                // sustained failure means the device is gone, and a camera we cannot command is a
                // camera we must not leave moving.
                logger.warning(.isapi, "PTZ keep-alive failed on channel \(channel): \(error)")
                await stop()
                return
            }
        }
    }
}
