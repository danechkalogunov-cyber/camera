//
//  VInspectorState.swift
//  VigilUI
//
//  What the inspector panel is given: the six tabs, one value carrying everything the panel prints,
//  and one bag of callbacks carrying everything it can do.
//  macOS-only. Implements docs/UX.md §6 and §1.3 (the tab enum and its ⌃1…⌃6 shortcuts).
//
//  ⛔ NOTHING IN `Inspector/` FETCHES ANYTHING. The protocols in `InspectorServices.swift` describe
//  the device; the app adapts them, samples them on its own cadence, and hands the whole panel one
//  ``VInspectorState``. No view in this directory owns a service, spawns a `Task`, or reads a
//  singleton. Three things follow, and all three are the point:
//
//   1. Every tab is previewable and testable with a literal.
//   2. The 1 Hz telemetry cadence stays the app's decision. UX.md §6.2 makes it a hard performance
//      rule that the inspector costs < 0.4 ms per frame; a view that subscribed to its own stream
//      would put a SwiftUI invalidation on the frame path.
//   3. `now` arrives as data. The uptime row, the event ages and the PTZ safety deadline all read
//      the same instant, so they cannot disagree, and a test can move time without a clock.
//

#if os(macOS)

import Foundation

import SwiftUI

import VigilISAPI
import VigilProtocols

// MARK: - VInspectorTab

/// The six tabs, in the order they appear and in the order ⌃1…⌃6 select them.
///
/// The order is not cosmetic: UX.md §1.3 stores the selection in `@SceneStorage` and §16 binds
/// ⌃1…⌃6 to it positionally, so inserting a tab in the middle would silently re-point every user's
/// restored state and every keyboard shortcut. Append only.
package enum VInspectorTab: String, Sendable, Hashable, CaseIterable, Identifiable {

    /// Identity, firmware, storage and the device actions (UX.md §6.1).
    case info

    /// Live telemetry (UX.md §6.2). The tab the mockup renders.
    case stream

    /// Pan, tilt, zoom, presets and patrols (UX.md §6.3).
    case ptz

    /// The image pipeline (UX.md §6.4).
    case image

    /// This camera's recent events (UX.md §6.5).
    case events

    /// Local recording (UX.md §6.6). Titled `Rec` in the bar, where six full words do not fit.
    case recording

    package var id: String { rawValue }

    /// The tab's label. `Rec` is deliberately the short form — design/mockups/01-main-window.html
    /// fits six tabs across a 320 pt panel only because the last one is abbreviated.
    @MainActor
    package var title: LocalizedStringKey {
        switch self {
        case .info: return "Info"
        case .stream: return "Stream"
        case .ptz: return "PTZ"
        case .image: return "Image"
        case .events: return "Events"
        case .recording: return "Rec"
        }
    }

    /// The glyph for the tab: used by the empty states and available to a future icon-only bar.
    ///
    /// Nonisolated because `VTheme.Symbol` is: a nested type does not inherit its enclosing type's
    /// global actor, and this accessor reads nothing from the theme's main-actor storage.
    ///
    /// ⚠️ PTZ's designed glyph is ``VTheme/Symbol/ptzPad``, which is the **custom** symbol
    /// `vigil.ptz.joystick`; `VigilUI/Resources/Symbols.xcassets` does not exist yet and an
    /// unresolved `Image(systemName:)` renders as nothing. `focusControl` (`viewfinder.circle`) is
    /// substituted for the same reason `ConnectFormView` substitutes the brand mark. Swap it back
    /// when the asset catalogue ships (DESIGN.md §8.5). Reported.
    package var symbol: VTheme.Symbol {
        switch self {
        case .info: return .info
        case .stream: return .healthGraph
        case .ptz: return .focusControl
        case .image: return .imagePanel
        case .events: return .events
        case .recording: return .record
        }
    }

    /// `1`…`6` — the digit in this tab's ⌃-number shortcut (UX.md §16).
    package var shortcutNumber: Int {
        (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }
}

// MARK: - VInspectorRecordingState

/// What the Recording tab prints.
///
/// ⚠️ **This is the one type in this slice that no service protocol backs.**
/// `InspectorServices.swift` declares device, telemetry, PTZ and archive services and nothing for
/// local recording, and UX.md §6.6's schedule grid, retention policy and filename template have no
/// value type anywhere in the package yet. Rather than invent that surface, this holds only the
/// four facts the app demonstrably already has — it is recording or it is not, for how long, into
/// where, and how many clips exist today — so the tab says something true instead of being blank.
/// The remaining §6.6 sections are deliberately absent. Reported.
package struct VInspectorRecordingState: Sendable, Hashable {

    /// Whether Vigil is recording this camera right now.
    package var isRecording: Bool

    /// How long the current clip has been running. Ignored unless ``isRecording``.
    package var elapsedSeconds: Double

    /// The folder clips land in, already shortened for display by the caller.
    package var destination: String?

    /// How many clips this camera produced today.
    package var clipsToday: Int

    /// Every clip Vigil has written to this Mac, and what they weigh.
    ///
    /// Shown because the honest answer to "what is this app putting on my disk" is a number on
    /// screen, not a promise in a manual. `nil` before the folder has been read.
    package var storedClips: Int?
    package var storedBytes: Int64?

    /// When the oldest clip was written, or `nil` when there are none. Answers "is this growing
    /// without bound" without anyone having to open the Finder.
    package var oldestClipAt: Date?

    /// Creates a recording summary. The defaults describe a camera that is not recording.
    package init(isRecording: Bool = false,
                 elapsedSeconds: Double = 0,
                 destination: String? = nil,
                 clipsToday: Int = 0,
                 storedClips: Int? = nil,
                 storedBytes: Int64? = nil,
                 oldestClipAt: Date? = nil) {
        self.isRecording = isRecording
        self.elapsedSeconds = elapsedSeconds
        self.destination = destination
        self.clipsToday = clipsToday
        self.storedClips = storedClips
        self.storedBytes = storedBytes
        self.oldestClipAt = oldestClipAt
    }
}

// MARK: - VInspectorState

/// Everything the inspector panel prints, as one value.
///
/// A single struct rather than a dozen parameters so that the app can hold one `@State` and so that
/// `body` re-evaluates on one `Equatable` comparison. `Hashable` for the same reason every value in
/// this module is: it makes `.animation(_:value:)` and `.onChange(of:)` usable without a wrapper.
package struct VInspectorState: Sendable, Hashable {

    // MARK: Header

    /// The camera being inspected. `nil` renders the "no camera selected" state rather than an
    /// empty panel — UX.md §6 is explicit that the inspector is never blank.
    package var camera: LiveCameraIdentity?

    /// What the stage is showing for this camera, which supplies the header's dot and status word.
    package var connection: LiveConnectionState

    /// The instant every relative reading in the panel is measured against.
    ///
    /// Sampled by the app, normally at 1 Hz alongside the telemetry. Also the tick that drives the
    /// PTZ safety deadline (``InspectorPTZHold/tick(at:)``), so a panel whose clock stops also
    /// stops a camera nobody is holding.
    package var now: Date

    // MARK: Device (Info tab, and the Stream tab's Device block)

    package var identity: InspectorDeviceIdentity

    /// The device's volumes, or `nil` when `/ContentMgmt/Storage` has not answered or is absent.
    package var storage: StorageInfo?

    /// While true the device rows render `VSkeleton` bars at the real content's size (§9.19).
    package var isDeviceLoading: Bool

    /// A failed ISAPI fetch shows an inline "Unavailable" badge with a retry — **never** an alert
    /// (UX.md §6.1).
    package var isDeviceUnavailable: Bool

    // MARK: Stream

    package var stream: InspectorStreamDescription

    /// The most recent 1 Hz sample.
    package var statistics: StreamStatistics

    /// The last samples, oldest first, for the sparkline. Shorter than the window while the ring is
    /// filling; empty is legal and renders §9.21's empty state.
    package var recentStatistics: [StreamStatistics]

    // MARK: PTZ

    package var ptz: InspectorPTZCapability
    package var presets: [PTZPreset]
    package var patrols: [PTZPatrol]

    /// The patrol currently running, if any, so its row shows a stop control.
    package var runningPatrol: Int?

    // MARK: Image

    package var image: InspectorImageSettings

    // MARK: Events and recording

    /// Newest first. The tab shows them in the order given.
    package var events: [InspectorEvent]

    package var recording: VInspectorRecordingState

    // MARK: Initialisation

    /// Creates a panel state. Every field defaults to its own empty form, so a preview or a test
    /// names only what it is about.
    package init(camera: LiveCameraIdentity? = nil,
                 connection: LiveConnectionState = .live,
                 now: Date = Date(timeIntervalSince1970: 0),
                 identity: InspectorDeviceIdentity = InspectorDeviceIdentity(),
                 storage: StorageInfo? = nil,
                 isDeviceLoading: Bool = false,
                 isDeviceUnavailable: Bool = false,
                 stream: InspectorStreamDescription = InspectorStreamDescription(),
                 statistics: StreamStatistics = StreamStatistics(),
                 recentStatistics: [StreamStatistics] = [],
                 ptz: InspectorPTZCapability = .absent,
                 presets: [PTZPreset] = [],
                 patrols: [PTZPatrol] = [],
                 runningPatrol: Int? = nil,
                 image: InspectorImageSettings = InspectorImageSettings(),
                 events: [InspectorEvent] = [],
                 recording: VInspectorRecordingState = VInspectorRecordingState()) {
        self.camera = camera
        self.connection = connection
        self.now = now
        self.identity = identity
        self.storage = storage
        self.isDeviceLoading = isDeviceLoading
        self.isDeviceUnavailable = isDeviceUnavailable
        self.stream = stream
        self.statistics = statistics
        self.recentStatistics = recentStatistics
        self.ptz = ptz
        self.presets = presets
        self.patrols = patrols
        self.runningPatrol = runningPatrol
        self.image = image
        self.events = events
        self.recording = recording
    }

    // MARK: Derived

    /// The bitrate series the Stream tab's sparkline draws, in bits per second, oldest first.
    package var bitrateSeries: [Double] {
        recentStatistics.map(\.bitsPerSecond)
    }

    /// The packet-loss series, as fractions.
    package var lossSeries: [Double] {
        recentStatistics.map(\.lossFraction)
    }

    /// The worst level across the sample, for the header's dot when the stream is flowing.
    package var overallHealth: InspectorHealthLevel {
        InspectorHealth.overall(statistics, targetFramesPerSecond: stream.targetFramesPerSecond)
    }

    /// Total device capacity in decimal MB across every volume, or `nil` when unknown.
    package var storageCapacityMB: Int? {
        guard let storage, storage.totalCapacityMB > 0 else { return nil }
        return storage.totalCapacityMB
    }

    /// 0…1 of the device's storage in use, or `nil` when unknown.
    package var storageUsedFraction: Double? {
        guard let storage, storage.totalCapacityMB > 0 else { return nil }
        let free = Double(storage.totalFreeMB) / Double(storage.totalCapacityMB)
        return Swift.min(1, Swift.max(0, 1 - free))
    }
}

// MARK: - VInspectorActions

/// Everything the panel can ask the app to do.
///
/// Mutable properties with harmless defaults rather than a twenty-argument initialiser: a call site
/// assigns the handful it cares about and a preview assigns none. Every closure is called from a
/// view body, so the whole bag is main-actor isolated.
///
/// ⛔ None of these performs work here. A handler starts a `Task` in the app, where the service and
/// its cancellation live; the panel's job ends at saying which button was pressed.
@MainActor
package struct VInspectorActions {

    // MARK: Device

    /// Re-runs the ISAPI fetch behind an "Unavailable" badge.
    package var onRetryDevice: () -> Void = {}

    /// Puts the full serial on the pasteboard (UX.md §6.1's copy affordance).
    package var onCopySerial: () -> Void = {}

    /// Opens `http(s)://host:port` in the default browser.
    package var onOpenWebPage: () -> Void = {}

    /// Opens the Stream Doctor for this camera.
    package var onRunStreamDoctor: () -> Void = {}

    // MARK: Stream

    /// Asks the encoder for an immediate IDR.
    package var onRequestKeyframe: () -> Void = {}

    /// Tears the session down and dials again.
    package var onReconnect: () -> Void = {}

    /// Copies the telemetry block as text for a bug report.
    package var onCopyDiagnostics: () -> Void = {}

    /// Cycles Auto → Main → Sub → Third.
    package var onCycleStream: () -> Void = {}

    /// Swaps RTSP transport between TCP interleaved and UDP.
    package var onSwapTransport: () -> Void = {}

    // MARK: PTZ

    /// The action ``InspectorPTZHold`` returned. The app forwards `.start` to
    /// `inspectorPTZContinuous`, and both stop cases to `inspectorPTZStop` — distinguishing them
    /// only in what it tells the user.
    package var onPTZ: (InspectorPTZHoldAction) -> Void = { _ in }

    /// A tap rather than a hold: send a self-terminating pulse of
    /// ``InspectorPTZHold/tapPulseMilliseconds``.
    package var onPTZNudge: (InspectorPTZVector) -> Void = { _ in }

    package var onPTZHome: () -> Void = {}

    /// −100…100 focus velocity; zero stops.
    package var onPTZFocus: (Int) -> Void = { _ in }

    /// −100…100 iris velocity; zero stops.
    package var onPTZIris: (Int) -> Void = { _ in }

    package var onPTZGoToPreset: (Int) -> Void = { _ in }
    package var onPTZSavePreset: (Int) -> Void = { _ in }
    package var onPTZDeletePreset: (Int) -> Void = { _ in }
    package var onPTZStartPatrol: (Int) -> Void = { _ in }
    package var onPTZStopPatrol: (Int) -> Void = { _ in }

    // MARK: Image

    /// The whole settings value after one control moved. The app debounces (UX.md §15.4); the
    /// panel does not, because a debounce inside a view is a debounce that a second view forgets.
    package var onImageSettings: (InspectorImageSettings) -> Void = { _ in }

    /// Restores the device's defaults, after the caller's confirmation.
    package var onResetImage: () -> Void = {}

    // MARK: Events and recording

    /// Jumps to Playback at this event.
    package var onOpenEvent: (InspectorEvent) -> Void = { _ in }

    /// Starts or stops local recording (⌘R).
    package var onToggleRecording: () -> Void = {}

    /// Reveals the destination folder in Finder.
    package var onRevealRecordings: () -> Void = {}

    /// Creates a bag in which nothing is wired. Assign the handlers you need.
    package init() {}
}

// MARK: - Preview fixtures

#if DEBUG

extension VInspectorState {

    /// A healthy 1080p main stream on a working camera.
    ///
    /// ⚠️ Synthesised, not captured from hardware. The numbers are the ones
    /// design/mockups/01-main-window.html renders, so a preview and the mockup can be compared
    /// side by side.
    package static var previewHealthy: VInspectorState {
        var statistics = StreamStatistics()
        statistics.framesPerSecond = 25
        statistics.bitsPerSecond = 4_120_000
        statistics.keyframeIntervalSeconds = 2
        statistics.packetsReceived = 918_400
        statistics.packetsOutOfOrder = 3
        statistics.lossFraction = 0.0002
        statistics.jitterMilliseconds = 6
        statistics.decodeQueueDepth = 2
        statistics.estimatedLatencyMilliseconds = 186
        statistics.isHardwareAccelerated = true
        statistics.uptimeSeconds = 5_412

        return VInspectorState(
            camera: previewCamera,
            connection: .live,
            now: previewNow,
            identity: previewIdentity,
            storage: previewStorage(freeMegabytes: 1_040_000),
            stream: previewStream,
            statistics: statistics,
            recentStatistics: previewSeries(peak: 4_600_000, loss: 0.0002),
            ptz: InspectorPTZCapability(isPresent: true, supportsPosition3D: true),
            presets: previewPresets,
            patrols: previewPatrols,
            image: InspectorImageSettings(brightness: 62, contrast: 50, saturation: 55,
                                          sharpness: 40, wdrMode: .auto, wdrLevel: 45,
                                          dayNightMode: .auto, irMode: .auto, irLevel: 60),
            events: previewEvents,
            recording: VInspectorRecordingState(isRecording: true, elapsedSeconds: 252,
                                                destination: "~/Movies/Vigil", clipsToday: 4))
    }

    /// The same camera with every threshold crossed: packet loss past 2 %, jitter and latency in
    /// the danger band, a decode queue that is behind, **software** decode, and a disk at 98 %.
    ///
    /// Every degraded surface in the panel is on screen at once here on purpose — it is the state
    /// that is hardest to get right and the one nobody can reproduce on demand.
    package static var previewDegraded: VInspectorState {
        var statistics = StreamStatistics()
        statistics.framesPerSecond = 14
        statistics.bitsPerSecond = 1_240_000
        statistics.keyframeIntervalSeconds = 4
        statistics.packetsReceived = 402_100
        statistics.packetsLost = 12_880
        statistics.packetsOutOfOrder = 417
        statistics.lossFraction = 0.031
        statistics.jitterMilliseconds = 74
        statistics.decodeQueueDepth = 9
        statistics.estimatedLatencyMilliseconds = 812
        statistics.isHardwareAccelerated = false
        statistics.uptimeSeconds = 612
        statistics.reconnectCount = 4
        statistics.lastErrorCode = "VG-RTP-0012"

        return VInspectorState(
            camera: previewCamera,
            connection: .degraded(.packetLoss(fraction: 0.031)),
            now: previewNow,
            identity: previewIdentity,
            storage: previewStorage(freeMegabytes: 60_000),
            isDeviceUnavailable: true,
            stream: previewStream,
            statistics: statistics,
            recentStatistics: previewSeries(peak: 2_100_000, loss: 0.031),
            ptz: .absent,
            image: InspectorImageSettings(brightness: 88, contrast: 30, saturation: 20,
                                          sharpness: 95, wdrMode: .on, wdrLevel: 90,
                                          dayNightMode: .night, irMode: .on, irLevel: 100,
                                          flip: .horizontal, isLocalPreviewOnly: true),
            events: previewEvents,
            recording: VInspectorRecordingState(destination: "~/Movies/Vigil", clipsToday: 0))
    }

    /// The healthy camera with its ISAPI answers still in flight, so every device row is a
    /// skeleton at the real content's width (§9.19).
    package static var previewLoading: VInspectorState {
        var state = VInspectorState.previewHealthy
        state.isDeviceLoading = true
        state.storage = nil
        return state
    }

    /// A fixed instant, so a preview renders the same uptime and the same event ages every time.
    static var previewNow: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    static var previewCamera: LiveCameraIdentity {
        LiveCameraIdentity(
            id: UUID(uuidString: "1B7E0C6A-1111-4A2B-9C3D-0E5F6A7B8C9D") ?? UUID(),
            name: "Front Door",
            host: "192.168.1.64")
    }

    static var previewIdentity: InspectorDeviceIdentity {
        // ⚠️ The uptime is a typed local rather than an inline sum. `uptimeSeconds` is a `Double`,
        // so `6 * 86_400 + 4 * 3_600 + 12 * 60` written in place makes the solver consider every
        // numeric type for five untyped literals *inside* a call whose fifteen parameters are all
        // defaulted — and it gives up with "unable to type-check this expression in reasonable
        // time". Naming the value with its type collapses that to one candidate.
        let uptime: Double = 6 * 86_400 + 4 * 3_600 + 12 * 60
        var identity = InspectorDeviceIdentity()
        identity.model = "DS-2CD2385G1"
        identity.deviceName = "Front Door"
        identity.firmwareVersion = "V5.7.3 build 220315"
        identity.firmwareReleased = "15 March 2022"
        identity.serialNumber = "DS-2CD2385G120220315AAWR1234821"
        identity.macAddress = "44:47:cc:1a:2b:3c"
        identity.totalChannels = 1
        identity.host = "192.168.1.64"
        identity.uptimeSeconds = uptime
        return identity
    }

    static var previewStream: InspectorStreamDescription {
        InspectorStreamDescription(codec: "H.265",
                                   profile: "Main",
                                   level: "4.1",
                                   pixelWidth: 1920,
                                   pixelHeight: 1080,
                                   streamInUse: "Main",
                                   transport: "TCP (interleaved)",
                                   targetFramesPerSecond: 25,
                                   sessionID: "\u{2026}a91c")
    }

    static func previewStorage(freeMegabytes: Int) -> StorageInfo {
        StorageInfo(volumes: [StorageVolume(id: 1,
                                            name: "HDD1",
                                            kind: .sata,
                                            status: .ok,
                                            capacityMB: 4_000_000,
                                            freeSpaceMB: freeMegabytes,
                                            isReadOnly: false)],
                    workMode: "group")
    }

    /// Sixty samples that rise gently to `peak`, so the sparkline has a shape rather than a slope.
    static func previewSeries(peak: Double, loss: Double) -> [StreamStatistics] {
        (0..<60).map { index in
            var sample = StreamStatistics()
            let phase = Double(index) / 59
            let wobble = (index % 3 == 0) ? 0.92 : 1.0
            sample.bitsPerSecond = peak * (0.62 + 0.38 * phase) * wobble
            sample.lossFraction = loss * wobble
            sample.framesPerSecond = 25 * wobble
            return sample
        }
    }

    static var previewPresets: [PTZPreset] {
        [PTZPreset(id: 1, name: "Gate", enabled: true),
         PTZPreset(id: 2, name: "Driveway", enabled: true),
         PTZPreset(id: 3, name: "", enabled: true),
         PTZPreset(id: 4, name: "Back fence", enabled: true)]
    }

    static var previewPatrols: [PTZPatrol] {
        [PTZPatrol(id: 1, name: "Night Sweep", enabled: true,
                   stops: (1...8).map { PTZPatrol.Stop(presetID: $0, dwellSeconds: 12, speed: 20) }),
         PTZPatrol(id: 2, name: "Perimeter", enabled: true,
                   stops: (1...4).map { PTZPatrol.Stop(presetID: $0, dwellSeconds: 20, speed: 12) })]
    }

    static var previewEvents: [InspectorEvent] {
        let base = previewNow
        return [
            InspectorEvent(id: UUID(uuidString: "2C8F1D7B-2222-4A2B-9C3D-0E5F6A7B8C9D") ?? UUID(),
                           instant: base.addingTimeInterval(-240), kind: .motion,
                           label: "Motion", duration: 8, hasThumbnail: true),
            InspectorEvent(id: UUID(uuidString: "3D9A2E8C-3333-4A2B-9C3D-0E5F6A7B8C9D") ?? UUID(),
                           instant: base.addingTimeInterval(-1_820), kind: .lineCrossing,
                           label: "Line crossing", duration: 3, hasThumbnail: true),
            InspectorEvent(id: UUID(uuidString: "4EAB3F9D-4444-4A2B-9C3D-0E5F6A7B8C9D") ?? UUID(),
                           instant: base.addingTimeInterval(-96_400), kind: .tamper,
                           label: "Tamper", duration: nil, hasThumbnail: false),
        ]
    }
}

#endif

#endif  // os(macOS)
