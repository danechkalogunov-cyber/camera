//
//  InspectorServices.swift
//  VigilUI
//
//  The protocols the inspector and the timeline depend on, declared HERE rather than imported, plus
//  the value types they exchange.
//  macOS-only. See docs/API_CONTRACT.md §4.5 for the concrete types these are adapted from.
//
//  ⛔ WHY THIS FILE EXISTS. Nothing in `Inspector/` or `Timeline/` constructs an `ISAPIClient` or an
//  `ISAPIDeviceSession`, and neither directory imports `VigilCore`. Every device capability arrives
//  through one of the four protocols below. That buys three things:
//
//   1. **Wiring is a one-line adapter per protocol.** The app target declares
//      `extension ISAPIDeviceSession: InspectorDeviceService {}` and, where a signature differs, one
//      forwarding method. Nothing in this module changes.
//   2. **Every view is previewable and testable without a device.** The `#Preview`s and the tests use
//      plain value-returning stubs.
//   3. **The dependency arrow points the right way.** `VigilUI` already sits above `VigilISAPI`; a
//      direct reference to a client actor would drag session lifetime, credentials and reconnection
//      policy into the view layer, all of which belong to `VigilCore`.
//
//  The protocols are deliberately narrow — they name only what a surface in these two directories
//  actually reads or writes, so an adapter cannot be asked for something no view needs.
//
//  ⚠️ Names of the concrete methods these forward to, for whoever writes the adapter:
//  `deviceInfo()`, `systemStatus()`, `storage()`, `imageSettings(channel:)`,
//  `setImageColor(channel:brightness:contrast:saturation:hue:)`, `setSharpness(channel:_:)`,
//  `setWDR(channel:_:)`, `setIRCut(channel:_:)`, `resetImageDefaults(channel:)`,
//  `recordTracks(force:)`, `dayIndex(track:dayStartUTC:force:)`, `monthCalendar(track:year:month:)`,
//  and `PTZController`'s `continuous(pan:tilt:zoom:)` / `stop()` / `momentary(...)` / `presets()` /
//  `gotoPreset(_:)` / `setPreset(_:name:)` / `patrols()` / `startPatrol(_:)` / `stopPatrol(_:)` /
//  `gotoHome()` / `setFocus(_:)` / `setIris(_:)` / `auxiliary(_:id:on:)`.
//

#if os(macOS)

import Foundation

import VigilISAPI
import VigilProtocols

// MARK: - InspectorDeviceIdentity

/// The identity and firmware facts the Info tab shows. UX.md §6.1.
///
/// A flat value rather than the wire type, so a firmware field the inspector does not show cannot
/// become a reason to change this module.
package struct InspectorDeviceIdentity: Sendable, Hashable {

    package var model: String
    package var deviceName: String
    package var firmwareVersion: String
    /// Already formatted for display; the inspector does not parse dates it is given.
    package var firmwareReleased: String?
    package var serialNumber: String
    package var macAddress: String
    package var channel: ChannelID
    package var totalChannels: Int
    package var host: String
    package var rtspPort: Int
    package var httpPort: Int
    package var usesTLS: Bool
    /// Seconds since the device booted, for the `"6 d 4 h 12 m"` row.
    package var uptimeSeconds: Double

    /// Signed seconds the camera's clock leads this Mac's, or `nil` when it has not been read.
    ///
    /// Worth a row of its own because a camera whose clock is wrong makes *everything else* wrong
    /// in a way the user blames on Vigil: events land at the wrong minute, an archive search for
    /// "today" asks for the wrong day, and a bookmark points at footage that is not there.
    package var clockSkewSeconds: Double?

    /// Whether this firmware writes local wall-clock time with a UTC marker, which Vigil corrects
    /// for (`DeviceQuirks.playbackTimesAreDeviceLocal`).
    ///
    /// Shown because the alternative is a support conversation: on such a device the clock row
    /// would otherwise read as hours of skew on a camera whose time is perfectly correct.
    package var stampsLocalTimeAsUTC: Bool

    package init(model: String = "", deviceName: String = "", firmwareVersion: String = "",
                 firmwareReleased: String? = nil, serialNumber: String = "",
                 macAddress: String = "", channel: ChannelID = .first, totalChannels: Int = 1,
                 host: String = "", rtspPort: Int = 554, httpPort: Int = 80,
                 usesTLS: Bool = false, uptimeSeconds: Double = 0,
                 clockSkewSeconds: Double? = nil, stampsLocalTimeAsUTC: Bool = false) {
        self.model = model
        self.deviceName = deviceName
        self.firmwareVersion = firmwareVersion
        self.firmwareReleased = firmwareReleased
        self.serialNumber = serialNumber
        self.macAddress = macAddress
        self.channel = channel
        self.totalChannels = totalChannels
        self.host = host
        self.rtspPort = rtspPort
        self.httpPort = httpPort
        self.usesTLS = usesTLS
        self.uptimeSeconds = uptimeSeconds
        self.clockSkewSeconds = clockSkewSeconds
        self.stampsLocalTimeAsUTC = stampsLocalTimeAsUTC
    }

    /// How far out the camera's clock is, and whether that is worth saying.
    ///
    /// Three states, because they call for three different treatments and a `Bool` would collapse
    /// two of them: nothing read yet (say nothing), in step (say so, quietly), and out (say so
    /// loudly, because it explains symptoms the user is already seeing elsewhere).
    package enum ClockAgreement: Sendable, Hashable {

        /// `/System/time` has not answered yet.
        case unknown

        /// Within tolerance. The seconds are carried so the row can still show them.
        case inStep(seconds: Double)

        /// Beyond tolerance: everything time-stamped by this camera is off by roughly this much.
        case out(seconds: Double)
    }

    /// What ±60 s means: docs/spec-isapi.md §7.5's own threshold for warning.
    package static let clockToleranceSeconds: Double = 60

    /// The clock row's state.
    package var clockAgreement: ClockAgreement {
        guard let clockSkewSeconds else { return .unknown }
        return abs(clockSkewSeconds) <= Self.clockToleranceSeconds
            ? .inStep(seconds: clockSkewSeconds)
            : .out(seconds: clockSkewSeconds)
    }

    /// The serial masked to its ends — `"DS-2CD…4821"`.
    ///
    /// A serial number identifies a specific unit and turns up in screenshots and pasted bug reports,
    /// so the full value is revealed only on an explicit gesture (UX.md §6.1: hover plus ⌥). Masking
    /// keeps enough of both ends to recognise a unit you already know.
    ///
    /// Strings of 10 characters or fewer are returned whole: masking three of eight characters
    /// conceals nothing useful and makes the row unreadable.
    package var maskedSerialNumber: String {
        let trimmed = serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 10 else { return trimmed }
        return trimmed.prefix(6) + "\u{2026}" + trimmed.suffix(4)
    }

    /// `"host:554"`, with the HTTP port appended when it is not the default.
    package var addressLabel: String {
        var label = "\(host):\(rtspPort)"
        if httpPort != 80 && httpPort != 443 { label += " · \(httpPort)" }
        return label
    }
}

// MARK: - InspectorStreamDescription

/// What the Stream tab shows that does not come from `StreamStatistics`. UX.md §6.2.
package struct InspectorStreamDescription: Sendable, Hashable {

    /// `"H.265"`, exactly as the device spelled it.
    package var codec: String
    package var profile: String?
    package var level: String?
    package var pixelWidth: Int
    package var pixelHeight: Int
    /// `"Main"`, `"Sub"`, `"Third"` — which stream is actually open.
    package var streamInUse: String
    /// True when the choice was automatic rather than pinned by the user.
    package var isAutomaticStream: Bool
    /// `"TCP (interleaved)"`, `"UDP"`, `"UDP multicast"`.
    package var transport: String
    /// The stream's configured frame rate, for the fps deviation threshold.
    package var targetFramesPerSecond: Double
    /// The RTSP session id, masked by the caller.
    package var sessionID: String?

    package init(codec: String = "", profile: String? = nil, level: String? = nil,
                 pixelWidth: Int = 0, pixelHeight: Int = 0, streamInUse: String = "",
                 isAutomaticStream: Bool = true, transport: String = "",
                 targetFramesPerSecond: Double = 0, sessionID: String? = nil) {
        self.codec = codec
        self.profile = profile
        self.level = level
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.streamInUse = streamInUse
        self.isAutomaticStream = isAutomaticStream
        self.transport = transport
        self.targetFramesPerSecond = targetFramesPerSecond
        self.sessionID = sessionID
    }

    /// `"H.265 Main · L4.1"`.
    package var codecLabel: String {
        var parts = [codec]
        if let profile, !profile.isEmpty { parts.append(profile) }
        guard let level, !level.isEmpty else { return parts.joined(separator: " ") }
        return parts.joined(separator: " ") + " · L\(level)"
    }
}

// MARK: - InspectorImageSettings

/// The Image tab's values. UX.md §6.4.
///
/// Each is 0…100 to match the ISAPI range, and clamped on the way in so a device that reports 255
/// cannot drive a slider off its track.
package struct InspectorImageSettings: Sendable, Hashable {

    package var brightness: Int
    package var contrast: Int
    package var saturation: Int
    package var sharpness: Int

    /// WDR off / on / auto, with its level.
    package var wdrMode: InspectorTriState
    package var wdrLevel: Int

    /// Day/night handling.
    package var dayNightMode: InspectorDayNightMode

    /// Infrared supplement light.
    package var irMode: InspectorTriState
    package var irLevel: Int

    package var flip: InspectorFlipMode

    /// True when the user chose "Adjust my view only", so writes stay in the render path and never
    /// reach the camera. Essential for a shared camera — UX.md §6.4 calls it out by name.
    package var isLocalPreviewOnly: Bool

    package init(brightness: Int = 50, contrast: Int = 50, saturation: Int = 50,
                 sharpness: Int = 50, wdrMode: InspectorTriState = .off, wdrLevel: Int = 50,
                 dayNightMode: InspectorDayNightMode = .auto,
                 irMode: InspectorTriState = .auto, irLevel: Int = 50,
                 flip: InspectorFlipMode = .off, isLocalPreviewOnly: Bool = false) {
        self.brightness = Self.clamp(brightness)
        self.contrast = Self.clamp(contrast)
        self.saturation = Self.clamp(saturation)
        self.sharpness = Self.clamp(sharpness)
        self.wdrMode = wdrMode
        self.wdrLevel = Self.clamp(wdrLevel)
        self.dayNightMode = dayNightMode
        self.irMode = irMode
        self.irLevel = Self.clamp(irLevel)
        self.flip = flip
        self.isLocalPreviewOnly = isLocalPreviewOnly
    }

    /// The ISAPI range for every level in this type.
    package static let range = 0...100

    static func clamp(_ value: Int) -> Int {
        min(range.upperBound, max(range.lowerBound, value))
    }
}

/// Off / On / Auto, the shape most Hikvision image toggles take.
package enum InspectorTriState: String, Sendable, Hashable, CaseIterable {
    case off, on, auto
}

/// Day/night switching. `schedule` carries its times elsewhere; this is the mode alone.
package enum InspectorDayNightMode: String, Sendable, Hashable, CaseIterable {
    case auto, day, night, schedule
}

/// Image flip. Matches ISAPI's `ImageFlip` values.
package enum InspectorFlipMode: String, Sendable, Hashable, CaseIterable {
    case off, centre, horizontal, vertical
}

// MARK: - InspectorEvent

/// One row of the Events tab. UX.md §6.5.
package struct InspectorEvent: Sendable, Hashable, Identifiable {

    package let id: UUID
    package let instant: Date
    package let kind: TimelineMarkerKind
    /// The localised type name, resolved by the caller — this module does not own the event taxonomy.
    package let label: String
    /// Length in seconds, when the device reported one.
    package let duration: Double?
    /// True when a thumbnail is cached for this event.
    package let hasThumbnail: Bool

    package init(id: UUID, instant: Date, kind: TimelineMarkerKind, label: String,
                 duration: Double? = nil, hasThumbnail: Bool = false) {
        self.id = id
        self.instant = instant
        self.kind = kind
        self.label = label
        self.duration = duration
        self.hasThumbnail = hasThumbnail
    }

    /// The timeline marker for this event, so the Events tab and the scrubber cannot disagree about
    /// where an event sits or where clicking it goes.
    package var marker: TimelineMarker {
        TimelineMarker(id: id, instant: instant, kind: kind, label: label)
    }
}

// MARK: - InspectorPTZCapability

/// What a channel's PTZ can do, narrowed from `PTZCapabilitiesWire` to what the surface needs.
package struct InspectorPTZCapability: Sendable, Hashable {

    package var isPresent: Bool
    package var supportsContinuous: Bool
    package var supportsMomentary: Bool
    package var supportsPresets: Bool
    package var maximumPresets: Int
    package var supportsPatrols: Bool
    package var supportsFocus: Bool
    package var supportsIris: Bool
    package var supportsPosition3D: Bool
    package var auxiliaries: [PTZAuxiliary]

    package init(isPresent: Bool, supportsContinuous: Bool = true, supportsMomentary: Bool = true,
                 supportsPresets: Bool = true, maximumPresets: Int = 32,
                 supportsPatrols: Bool = true, supportsFocus: Bool = true,
                 supportsIris: Bool = true, supportsPosition3D: Bool = false,
                 auxiliaries: [PTZAuxiliary] = []) {
        self.isPresent = isPresent
        self.supportsContinuous = supportsContinuous
        self.supportsMomentary = supportsMomentary
        self.supportsPresets = supportsPresets
        self.maximumPresets = maximumPresets
        self.supportsPatrols = supportsPatrols
        self.supportsFocus = supportsFocus
        self.supportsIris = supportsIris
        self.supportsPosition3D = supportsPosition3D
        self.auxiliaries = auxiliaries
    }

    /// A camera with no PTZ at all. The whole tab becomes an empty state (UX.md §6.3) — the tab itself
    /// stays selectable, because predictable navigation beats a disappearing tab.
    package static let absent = InspectorPTZCapability(
        isPresent: false, supportsContinuous: false, supportsMomentary: false,
        supportsPresets: false, maximumPresets: 0, supportsPatrols: false,
        supportsFocus: false, supportsIris: false, supportsPosition3D: false, auxiliaries: [])

    /// Derived from the wire capabilities, so an adapter is a single expression.
    package init(wire: PTZCapabilitiesWire) {
        self.init(isPresent: !wire.isAbsent,
                  supportsContinuous: wire.supportsContinuous,
                  supportsMomentary: wire.supportsMomentary,
                  supportsPresets: wire.supportsPresets,
                  maximumPresets: wire.maxPresets,
                  supportsPatrols: wire.supportsPatrols,
                  supportsFocus: wire.supportsFocus,
                  supportsIris: wire.supportsIris,
                  supportsPosition3D: wire.supportsPosition3D,
                  auxiliaries: wire.auxiliaries)
    }
}

// MARK: - The protocols

/// Identity, firmware and image settings for one camera.
///
/// `async throws` with an untyped error: the concrete implementation throws `ISAPIError`, but a typed
/// throw would bind this module to that error's shape, and the inspector's only response to a failure
/// is the same inline "Unavailable" badge whatever the cause (UX.md §6.1 — "never an alert").
package protocol InspectorDeviceService: Sendable {

    /// Identity and firmware. Cached by the implementation; the inspector calls it per tab activation.
    func inspectorIdentity() async throws -> InspectorDeviceIdentity

    /// The current image settings.
    func inspectorImageSettings() async throws -> InspectorImageSettings

    /// Writes image settings. Called on a 250 ms trailing debounce, latest-wins (UX.md §15.4).
    ///
    /// The caller has already applied the change locally, so a throw means "revert the control and
    /// explain", never "the user's edit is lost".
    func inspectorApplyImageSettings(_ settings: InspectorImageSettings) async throws

    /// Restores the device's defaults.
    func inspectorResetImageSettings() async throws
}

/// Live telemetry for one camera.
///
/// Separate from ``InspectorDeviceService`` because it has a completely different cadence and owner:
/// statistics come from `HealthMonitor` at 1 Hz over RTP, not from ISAPI over HTTP, and a surface may
/// legitimately have one without the other.
package protocol InspectorTelemetryService: Sendable {

    /// The most recent 1 Hz sample.
    func inspectorStatistics() async -> StreamStatistics

    /// What the stream is, for the rows `StreamStatistics` does not describe.
    func inspectorStreamDescription() async -> InspectorStreamDescription

    /// The last `count` samples, oldest first, for the sparklines. Shorter than `count` while the ring
    /// is filling; empty is legal and renders as "No data yet" (DESIGN.md §9.21).
    func inspectorRecentStatistics(count: Int) async -> [StreamStatistics]
}

/// PTZ for one channel.
///
/// Mirrors `PTZController`'s surface exactly, so the adapter is a forwarding `extension` with no
/// logic. In particular ``inspectorPTZStop()`` does not throw — `PTZController.stop()` does not
/// either, deliberately, because a stop that can fail is a camera that can be left spinning.
package protocol InspectorPTZService: Sendable {

    /// What this channel can do.
    func inspectorPTZCapability() async -> InspectorPTZCapability

    /// Starts or updates a continuous move. The implementation owns the 400 ms keep-alive.
    func inspectorPTZContinuous(pan: Int, tilt: Int, zoom: Int) async throws

    /// Stops. **Never throws** — see ``PTZController/stop()``.
    func inspectorPTZStop() async

    /// A self-terminating nudge, preferred for a tap.
    func inspectorPTZMomentary(pan: Int, tilt: Int, zoom: Int, milliseconds: Int) async throws

    func inspectorPTZPresets() async throws -> [PTZPreset]
    func inspectorPTZGoToPreset(_ number: Int) async throws
    func inspectorPTZSavePreset(_ number: Int, name: String) async throws
    func inspectorPTZDeletePreset(_ number: Int) async throws

    func inspectorPTZPatrols() async throws -> [PTZPatrol]
    func inspectorPTZStartPatrol(_ number: Int) async throws
    func inspectorPTZStopPatrol(_ number: Int) async throws

    func inspectorPTZGoHome() async throws
    func inspectorPTZSetFocus(_ velocity: Int) async throws
    func inspectorPTZSetIris(_ velocity: Int) async throws
}

/// The archive, for the timeline.
///
/// Declared alongside the inspector's protocols because it is the same pattern and the same reason:
/// `Timeline/` must not construct a client either.
package protocol TimelineArchiveService: Sendable {

    /// The recording tracks, so the timeline knows which to search. Only enabled tracks are offered.
    func timelineTracks() async throws -> [RecordTrack]

    /// One day's index for one track. `dayStartUTC` is the device-local midnight as an absolute
    /// instant — the value ``TimelineDay/start`` holds.
    func timelineDayIndex(track: TrackID, dayStartUTC: Date) async throws -> RecordDayIndex

    /// The month calendar accelerator. A partial answer is expected and correct: days the device did
    /// not mention stay `nil` and render as unknown, never as empty (spec-isapi.md §15.5).
    func timelineMonthCalendar(track: TrackID, year: Int,
                               month: Int) async throws -> MonthRecordCalendar

    /// The event markers for a span, for the marker lane.
    func timelineEvents(from: Date, to: Date) async throws -> [InspectorEvent]
}

#endif  // os(macOS)
