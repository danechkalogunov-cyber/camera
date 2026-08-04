//
//  PTZCoordinator.swift
//  Vigil
//
//  Drives the camera's pan, tilt, zoom, focus, iris, presets and patrols from the inspector.
//  macOS-only. See docs/spec-isapi.md §11 and docs/UX.md §6.3.
//

#if os(macOS)

    import Foundation
    import Observation

    import VigilCore
    import VigilISAPI
    import VigilProtocols
    import VigilUI

    // MARK: - PTZCoordinator

    /// Connects the PTZ tab to the camera.
    ///
    /// **What this adds.** `PTZController` — the actor that owns the 400 ms keep-alive, the triple
    /// zero-stop and the capability gate — was written and tested and never constructed by anything.
    /// `VInspectorPTZTab` was drawn against `InspectorPTZCapability`, `[PTZPreset]` and `[PTZPatrol]`
    /// and never given any of them. This is the missing link, and it is deliberately thin: everything
    /// that could go wrong with a moving camera already lives in the controller.
    ///
    /// **Why it does not own safety.** The eight-second hold ceiling, the tap-versus-hold threshold and
    /// the stop-on-release are `InspectorPTZHold`'s, in the view. The keep-alive and the stop that
    /// repeats three times are the controller's. Between them there is one job left — turn a gesture
    /// into a call and publish what came back — and doing more here would be a third place that can
    /// leave a camera spinning.
    ///
    /// **Every failure is named.** A PTZ button that does nothing and says nothing is worse here than
    /// anywhere else in the app: the user is watching the picture, not the panel, and a camera that did
    /// not move is indistinguishable from one that cannot.
    @MainActor
    @Observable
    final class PTZCoordinator {

        // MARK: - Observable State

        /// What this channel can do. `isPresent == false` hides every PTZ affordance, which is the
        /// right answer for a fixed camera and for one whose PTZ endpoints answered 403.
        private(set) var capability = InspectorPTZCapability(isPresent: false)

        /// The stored presets, as the device reports them.
        private(set) var presets: [PTZPreset] = []

        /// The stored patrols.
        private(set) var patrols: [PTZPatrol] = []

        /// The patrol currently running, or `nil`. Tracked here rather than polled: Hikvision has no
        /// "which patrol is running" query, so the only honest source is what Vigil last started.
        private(set) var runningPatrol: Int?

        /// Why the last command failed, or `nil` when the last one succeeded.
        private(set) var lastFailure: String?

        // MARK: - Stored Properties

        private let logger: any LoggerProtocol

        /// The device's controller, once the channel has been found to have PTZ at all.
        private var controller: PTZController?

        /// Which channel ``controller`` drives, so a camera change rebuilds it.
        private var channel: ChannelID?

        /// The capability read in flight, cancelled when the camera changes.
        private var probe: Task<Void, Never>?

        /// Firmware-calibrated Y orientation for 3D positioning.
        private var position3DOriginIsTopLeft = false

        // MARK: - Initialisation

        /// Creates a coordinator with nothing to drive yet.
        init(logger: any LoggerProtocol) {
            self.logger = logger
        }

        // MARK: - Lifecycle

        /// Points the coordinator at a channel of a device, or clears it.
        ///
        /// Idempotent for the same session and channel: re-running it on every inspector tab change
        /// would ask the device for its capabilities again, and that answer is cached for 24 h precisely
        /// because it never changes.
        func follow(session: ISAPIDeviceSession?, channel: ChannelID?) {
            guard let session, let channel else {
                probe?.cancel()
                probe = nil
                controller = nil
                self.channel = nil
                capability = InspectorPTZCapability(isPresent: false)
                presets = []
                patrols = []
                runningPatrol = nil
                return
            }
            guard self.channel != channel || controller == nil else { return }
            self.channel = channel
            probe?.cancel()
            probe = Task { [weak self] in await self?.load(session: session, channel: channel) }
        }

        // MARK: - Movement

        /// Starts, updates or ends a continuous move.
        ///
        /// A zero vector is a stop, and it is routed to ``stop()`` rather than sent as a zero-velocity
        /// move: `PTZController.stop()` sends the zero three times, which is what makes a camera
        /// actually halt on a firmware that drops one datagram.
        func move(_ vector: InspectorPTZVector) {
            guard vector.isStopped == false else { return stop() }
            run("move") { controller in
                try await controller.continuous(pan: vector.pan, tilt: vector.tilt, zoom: vector.zoom)
            }
        }

        /// A self-terminating pulse, for a tap rather than a hold.
        ///
        /// `momentary` is preferred over start-then-stop because the camera itself ends the move: a
        /// stop that is lost on the network leaves a camera panning, and a tap is exactly the gesture
        /// where the user is not holding anything down to notice.
        func nudge(_ vector: InspectorPTZVector) {
            guard !vector.isStopped else { return }
            run("nudge") { controller in
                try await controller.momentary(
                    pan: vector.pan,
                    tilt: vector.tilt,
                    zoom: vector.zoom,
                    duration: .milliseconds(InspectorPTZHold.tapPulseMilliseconds))
            }
        }

        /// Halts every axis.
        ///
        /// Never reports a failure, because `PTZController.stop()` does not throw — deliberately, and
        /// the controller's own doc gives the reason: a stop that can fail is a camera that can be left
        /// spinning, so it retries rather than surfacing an error nobody could act on.
        func stop() {
            guard let controller else { return }
            Task { await controller.stop() }
        }

        /// Returns the camera to its home position.
        func home() {
            run("home") { controller in try await controller.gotoHome() }
        }

        /// Drives focus. `0` stops.
        func focus(_ velocity: Int) {
            run("focus") { controller in try await controller.setFocus(velocity) }
        }

        /// Drives the iris. `0` stops.
        func iris(_ velocity: Int) {
            run("iris") { controller in try await controller.setIris(velocity) }
        }

        // MARK: - Presets

        /// Recalls a preset.
        func goToPreset(_ number: Int) {
            run("preset recall") { controller in try await controller.gotoPreset(number) }
        }

        /// Stores the current position in a preset slot, then re-reads the list.
        ///
        /// The name is the one already in that slot when there is one, so overwriting a preset the user
        /// called "Gate" leaves it called "Gate". An empty slot gets the device's own convention,
        /// `Preset N`, which is what `PTZPreset.displayName` falls back to anyway.
        func savePreset(_ number: Int) {
            let existing = presets.first { $0.id == number }?.name ?? ""
            let chosen = existing.isEmpty ? "Preset \(number)" : existing
            runAndRefreshPresets("preset save") { controller in
                try await controller.setPreset(number, name: chosen)
            }
        }

        /// Deletes a preset, then re-reads the list.
        func deletePreset(_ number: Int) {
            runAndRefreshPresets("preset delete") { controller in
                try await controller.deletePreset(number)
            }
        }

        /// Sends a tile-space drag through the device's calibrated coordinate mapping.
        func position3D(rect: CGRect, viewSize: CGSize) {
            guard capability.supportsPosition3D else { return }
            let box = PTZ3D.box(
                rectX: rect.origin.x, rectY: rect.origin.y,
                rectWidth: rect.width, rectHeight: rect.height,
                viewWidth: viewSize.width, viewHeight: viewSize.height,
                originIsTopLeft: position3DOriginIsTopLeft)
            run("3D positioning") { controller in
                try await controller.position3D(box)
            }
        }

        // MARK: - Patrols

        /// Starts a patrol and remembers which one is running.
        func startPatrol(_ number: Int) {
            run("patrol start", then: { self.runningPatrol = number }) { controller in
                try await controller.startPatrol(number)
            }
        }

        /// Stops a patrol.
        ///
        /// The running marker is cleared even when the device refuses: the alternative is a panel that
        /// insists a patrol is running on a camera that has been power-cycled underneath it, and the
        /// user's next Start would then be disabled for a patrol that no longer exists.
        func stopPatrol(_ number: Int) {
            run("patrol stop", then: { self.runningPatrol = nil }) { controller in
                try await controller.stopPatrol(number)
            }
        }

        // MARK: - Private Helpers

        /// Reads the channel's capabilities and, when it has any, its presets and patrols.
        ///
        /// A channel with no PTZ is the common case on this hardware, and it is not a failure:
        /// `ptzController(channel:)` throws `.notSupported` rather than handing back a controller whose
        /// every call would fail, and the capability stays `isPresent: false` so the tab shows its own
        /// unsupported state instead of a pad that does nothing.
        private func load(session: ISAPIDeviceSession, channel: ChannelID) async {
            let wire: PTZCapabilitiesWire
            do {
                wire = try await session.ptzCapabilities(channel: channel)
            } catch {
                logger.debug(.isapi, "PTZ capabilities unavailable: \(String(describing: error))")
                capability = InspectorPTZCapability(isPresent: false)
                return
            }
            guard !wire.isAbsent else {
                logger.info(.isapi, "channel \(channel.value) has no PTZ")
                capability = InspectorPTZCapability(isPresent: false)
                return
            }
            capability = Self.inspectorCapability(from: wire)
            position3DOriginIsTopLeft = await session.position3DOriginIsTopLeft
            guard let built = try? await session.ptzController(channel: channel) else {
                // The capabilities answered but the controller refused, which means the endpoints the
                // controller needs are gone. Report no PTZ rather than an affordance that cannot act.
                capability = InspectorPTZCapability(isPresent: false)
                return
            }
            controller = built
            if wire.supportsPresets { await refreshPresets() }
            if wire.supportsPatrols {
                patrols = (try? await built.patrols()) ?? []
            }
            logger.info(.isapi, "PTZ ready: \(presets.count) preset(s), \(patrols.count) patrol(s)")
        }

        /// Re-reads the preset list from the device.
        private func refreshPresets() async {
            guard let controller else { return }
            presets = (try? await controller.presets()) ?? presets
        }

        /// Runs one command against the controller and names any failure.
        ///
        /// - Parameters:
        ///   - label: what appears in the log line and, on failure, in ``lastFailure``.
        ///   - success: applied on the main actor when the command was accepted, before the failure is
        ///     cleared, so a caller can record what it just did.
        ///   - command: the call.
        private func run(
            _ label: String,
            then success: (@MainActor () -> Void)? = nil,
            _ command: @escaping @Sendable (PTZController) async throws -> Void
        ) {
            guard let controller else {
                logger.debug(.isapi, "PTZ \(label) ignored: this channel has no PTZ")
                return
            }
            Task {
                do {
                    try await command(controller)
                    success?()
                    lastFailure = nil
                } catch {
                    let reason = String(describing: error)
                    lastFailure = "\(label): \(reason)"
                    logger.error(.isapi, "PTZ \(label) refused: \(reason)")
                }
            }
        }

        /// A command that changes the stored presets, followed by a re-read.
        ///
        /// The re-read is not optional. Several firmwares silently clamp the slot number or refuse a
        /// reserved command with a `200`, so the only trustworthy answer to "what is stored now" is the
        /// device's own list.
        private func runAndRefreshPresets(
            _ label: String,
            _ command: @escaping @Sendable (PTZController) async throws -> Void
        ) {
            guard let controller else { return }
            Task {
                do {
                    try await command(controller)
                    lastFailure = nil
                } catch {
                    let reason = String(describing: error)
                    lastFailure = "\(label): \(reason)"
                    logger.error(.isapi, "PTZ \(label) refused: \(reason)")
                }
                await refreshPresets()
            }
        }

        /// Narrows the device's capability document to what the panel asks about.
        ///
        /// `maximumPresets` is clamped to the slots Vigil actually offers. A camera that advertises 300
        /// would otherwise draw three hundred cells into a 288 pt panel, and `PTZPreset.userSlots` is
        /// the range the preset grid was designed around.
        private static func inspectorCapability(
            from wire: PTZCapabilitiesWire
        ) -> InspectorPTZCapability {
            InspectorPTZCapability(
                isPresent: true,
                supportsContinuous: wire.supportsContinuous,
                supportsMomentary: wire.supportsMomentary,
                supportsPresets: wire.supportsPresets,
                maximumPresets: min(
                    wire.maxPresets,
                    PTZPreset.userSlots.upperBound),
                supportsPatrols: wire.supportsPatrols,
                supportsFocus: wire.supportsFocus,
                supportsIris: wire.supportsIris,
                supportsPosition3D: wire.supportsPosition3D,
                auxiliaries: wire.auxiliaries)
        }
    }

#endif  // os(macOS)
