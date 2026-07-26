//
//  DiscoveryEvents.swift
//  VigilDiscovery
//
//  What a running discovery tells its consumer: the event stream, the phases a run moves through,
//  and the progress snapshot that keeps a UI honest while a sweep is in flight.
//  Implements docs/spec-discovery.md §8.1 and §10.3.
//

import Foundation
import VigilProtocols

// MARK: - Events

/// One thing that happened during a run.
///
/// The emission discipline is the contract the UI is built on: **exactly one `.deviceFound` per
/// record, ever**. Everything afterwards is `.deviceUpdated` or `.deviceMerged`, so a list can
/// insert a row with an animation and then mutate it in place, and a test can assert an exact
/// sequence rather than a set.
public enum DiscoveryEvent: Sendable {

    /// The plan, emitted once before any probe is sent. Carries what will be scanned and what was
    /// refused, so the UI can say up front that a subnet was skipped.
    case started(DiscoveryPlan)
    /// A progress snapshot. Coalesced to 20 Hz, but forced immediately after any device event so the
    /// counter never lags a visible row.
    case progress(DiscoveryProgress)
    /// A record that did not exist before. Emitted at most once per record.
    case deviceFound(DiscoveredDevice)
    /// An existing record changed. `changes` names exactly the fields that moved.
    case deviceUpdated(DiscoveredDevice, changes: Set<DeviceFieldKey>)
    /// Records that were provisionally separate turned out to be one device — a new key proved it.
    /// `absorbed` are the identities that no longer exist as rows.
    case deviceMerged(absorbed: [DeviceIdentity], into: DeviceIdentity)
    /// A saved camera answered from a new address (DHCP moved it). The UI offers to update the saved
    /// camera; it never silently duplicates it.
    case addressChanged(DeviceIdentity, from: IPv4Address, to: IPv4Address)
    /// A **different** device answered at a saved camera's address. The new device is listed as new
    /// and the saved camera is marked not-found: re-pointing it would hand a stranger the user's
    /// stored credentials.
    case addressReused(IPv4Address, previous: DeviceIdentity, now: DeviceIdentity)
    /// A phase finished, with its counters.
    case phaseCompleted(DiscoveryPhase, PhaseSummary)
    /// A non-fatal finding.
    case diagnostic(DiscoveryDiagnostic)
    /// The run ended, for whatever reason. Always the last event.
    case finished(DiscoverySummary)

    /// True for `.deviceFound`. Used by the merge engine to enforce "at most one per record".
    public var isDeviceFound: Bool {
        if case .deviceFound = self { return true }
        return false
    }

    /// True for the events that must force an immediate progress emission (§8.1).
    public var forcesProgressEmission: Bool {
        switch self {
        case .deviceFound, .deviceUpdated, .deviceMerged: true
        default: false
        }
    }
}

// MARK: - Phases

/// The stages of a run. Several overlap: multicast listening continues while the sweep runs.
public enum DiscoveryPhase: String, Sendable, Hashable, Codable, CaseIterable {
    case planning, arpSnapshot, sadp, onvif, bonjour, sweepA, sweepB, fingerprint, settling, finished

    /// Display order, narrowest-active-phase first. The progress label shows the *narrowest* active
    /// phase because "Fingerprinting 192.168.1.64" is more informative than "Scanning".
    public var specificity: Int {
        switch self {
        case .planning: 0
        case .arpSnapshot: 1
        case .sadp, .onvif, .bonjour: 2
        case .sweepA: 3
        case .sweepB: 4
        case .fingerprint: 5
        case .settling: 6
        case .finished: 7
        }
    }

    /// Short label for the UI's status line.
    public var label: String {
        switch self {
        case .planning: "Preparing"
        case .arpSnapshot: "Reading address table"
        case .sadp: "Asking Hikvision cameras"
        case .onvif: "Asking ONVIF devices"
        case .bonjour: "Browsing services"
        case .sweepA, .sweepB: "Scanning addresses"
        case .fingerprint: "Identifying devices"
        case .settling: "Finishing"
        case .finished: "Done"
        }
    }
}

// MARK: - Progress

/// A snapshot of how far a run has got.
///
/// Every counter here is something a user can see change. `fraction` and `estimatedRemaining` are
/// deliberately optional: an honest "still working" beats a bar that jumps backwards or an ETA that
/// climbs, both of which read as a broken app (§8.2).
public struct DiscoveryProgress: Sendable, Hashable, Codable {

    /// The narrowest active phase, for the label.
    public var phase: DiscoveryPhase
    /// Everything running right now.
    public var activePhases: Set<DiscoveryPhase>
    /// Records confident enough to present as devices (confidence ≥ 30).
    public var devicesFound: Int
    /// All records, including the ones the UI collapses into "Other devices found".
    public var candidatesFound: Int
    public var hostsPlanned: Int
    /// Hosts whose tier A probes have all completed.
    public var hostsProbed: Int
    /// Hosts that answered anything at all, open or refused.
    public var hostsAlive: Int
    public var portProbesCompleted: Int
    /// Grows as tier B and C work is scheduled, which is why `fraction` needs a monotonic guard.
    public var portProbesPlanned: Int
    public var multicastWindowRemaining: Duration
    public var elapsed: Duration
    /// `nil` while indeterminate — suppressed for the first 750 ms and whenever throughput is too
    /// low to extrapolate from.
    public var estimatedRemaining: Duration?
    /// EWMA of host completions per second.
    public var throughputHostsPerSecond: Double
    /// 0…1 for a determinate bar; `nil` for the first 300 ms, when the shimmer is more honest.
    public var fraction: Double?

    public init(phase: DiscoveryPhase = .planning,
                activePhases: Set<DiscoveryPhase> = [],
                devicesFound: Int = 0, candidatesFound: Int = 0,
                hostsPlanned: Int = 0, hostsProbed: Int = 0, hostsAlive: Int = 0,
                portProbesCompleted: Int = 0, portProbesPlanned: Int = 0,
                multicastWindowRemaining: Duration = .zero, elapsed: Duration = .zero,
                estimatedRemaining: Duration? = nil, throughputHostsPerSecond: Double = 0,
                fraction: Double? = nil) {
        self.phase = phase
        self.activePhases = activePhases
        self.devicesFound = devicesFound
        self.candidatesFound = candidatesFound
        self.hostsPlanned = hostsPlanned
        self.hostsProbed = hostsProbed
        self.hostsAlive = hostsAlive
        self.portProbesCompleted = portProbesCompleted
        self.portProbesPlanned = portProbesPlanned
        self.multicastWindowRemaining = multicastWindowRemaining
        self.elapsed = elapsed
        self.estimatedRemaining = estimatedRemaining
        self.throughputHostsPerSecond = throughputHostsPerSecond
        self.fraction = fraction
    }

    /// The ETA rendered the way the UI shows it, or `nil` when there is nothing honest to say.
    /// Rounding is coarse on purpose: a per-second countdown invites the user to watch it.
    public var estimatedRemainingText: String? {
        guard let estimatedRemaining else { return nil }
        let seconds = Double(estimatedRemaining.components.seconds)
            + Double(estimatedRemaining.components.attoseconds) / 1e18
        if seconds < 3 { return "a moment" }
        if seconds < 60 { return "about \(Int(seconds.rounded())) seconds" }
        let minutes = Int((seconds / 60).rounded())
        return "about \(minutes) minute\(minutes == 1 ? "" : "s")"
    }
}

// MARK: - Summaries

/// Counters for one finished phase.
public struct PhaseSummary: Sendable, Hashable, Codable {
    public let phase: DiscoveryPhase
    public let duration: Duration
    /// Records this phase created or changed.
    public let devicesContributed: Int
    public let datagramsSent: Int
    public let datagramsReceived: Int
    public let connectsAttempted: Int

    public init(phase: DiscoveryPhase, duration: Duration, devicesContributed: Int = 0,
                datagramsSent: Int = 0, datagramsReceived: Int = 0, connectsAttempted: Int = 0) {
        self.phase = phase
        self.duration = duration
        self.devicesContributed = devicesContributed
        self.datagramsSent = datagramsSent
        self.datagramsReceived = datagramsReceived
        self.connectsAttempted = connectsAttempted
    }
}

/// The final word on a run. Emitted whatever the outcome — a cancelled or deadlined run still
/// returns every device it found, because partial results are the normal case on a big network.
public struct DiscoverySummary: Sendable, Hashable {

    public let terminationReason: TerminationReason
    /// Everything merged, in the stable order of §10.4.
    public let devices: [DiscoveredDevice]
    public let elapsed: Duration
    public let hostsProbed: Int
    public let hostsPlanned: Int
    public let phases: [PhaseSummary]
    public let diagnostics: [DiscoveryDiagnostic]
    public let entitlements: EntitlementStatus

    public init(terminationReason: TerminationReason, devices: [DiscoveredDevice],
                elapsed: Duration, hostsProbed: Int, hostsPlanned: Int,
                phases: [PhaseSummary] = [], diagnostics: [DiscoveryDiagnostic] = [],
                entitlements: EntitlementStatus = .unknown) {
        self.terminationReason = terminationReason
        self.devices = devices
        self.elapsed = elapsed
        self.hostsProbed = hostsProbed
        self.hostsPlanned = hostsPlanned
        self.phases = phases
        self.diagnostics = diagnostics
        self.entitlements = entitlements
    }

    /// Why the run ended.
    public enum TerminationReason: String, Sendable, Hashable, Codable {
        /// Every planned host was probed and the settle period elapsed.
        case completed
        /// The overall deadline hit first. Results are kept and the UI offers "Keep scanning".
        case deadline
        /// The user stopped it, or the event stream was torn down.
        case cancelled
        /// A `DiscoveryError` terminated the run.
        case failed
    }

    /// True when more hosts remain — the condition for offering to resume from `hostsProbed`.
    public var hasUnscannedHosts: Bool { hostsProbed < hostsPlanned }
}
