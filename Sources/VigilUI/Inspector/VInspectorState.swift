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

    /// Creates a recording summary. The defaults describe a camera that is not recording.
    package init(isRecording: Bool = false,
                 elapsedSeconds: Double = 0,
                 destination: String? = nil,
                 clipsToday: Int = 0) {
        self.isRecording = isRecording
        self.elapsedSeconds = elapsedSeconds
        self.destination = destination
        self.clipsToday = clipsToday
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

#endif  // os(macOS)
