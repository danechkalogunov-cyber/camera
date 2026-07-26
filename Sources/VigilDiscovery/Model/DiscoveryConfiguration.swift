//
//  DiscoveryConfiguration.swift
//  VigilDiscovery
//
//  Every knob a discovery run has: what to scan, which ports, how fast, how long, and what the app
//  already knows. The safety limits are deliberately not in here — they live in `SweepPolicy`.
//  Implements docs/spec-discovery.md §10.2, with the normative numbers of §6.5 and §6.10.
//

import VigilProtocols

/// The parameters of one discovery run.
///
/// Defaults are the normative numbers from the spec and are what the app ships with; the mutable
/// surface exists for Advanced settings, for `.single` re-checks after activation, and for tests
/// that need a run to be small and deterministic. Nothing here can lift the sweep guard: a prefix
/// wider than `/16` is refused whatever this says (§6.2).
public struct DiscoveryConfiguration: Sendable {

    /// What the run covers.
    public var mode: Mode
    /// Probed on every planned host.
    public var tierAPorts: [UInt16]
    /// Probed on hosts where tier A found anything, plus ARP hosts and hosts named by a mechanism.
    public var tierBPorts: [UInt16]
    /// Probed only to break a classification tie when the vendor is still unknown.
    public var tierCPorts: [UInt16]
    /// Appended to tier A. For the user who moved HTTP to 8899.
    public var additionalPorts: [UInt16]
    /// Per-connect budget. 350 ms is tight on purpose: a LAN handshake is sub-millisecond, and a
    /// generous timeout multiplied by 254 hosts is what makes a scan feel broken.
    public var tcpConnectTimeout: Duration
    /// Budget for one fingerprint exchange.
    public var fingerprintTimeout: Duration
    /// Connects in flight. Clamped further by the file-descriptor limit at run time.
    public var maxInFlightConnects: Int
    /// When each SADP probe is sent, relative to the phase start.
    public var sadpProbeSchedule: [Duration]
    /// When each WS-Discovery probe is sent, relative to the phase start.
    public var onvifProbeSchedule: [Duration]
    /// How long to keep listening after the last probe.
    public var multicastListenTail: Duration
    /// The sweep starts this late so multicast answers arrive on a quiet network.
    public var sweepStartDelay: Duration
    /// Quiet period before a run is declared finished.
    public var settleQuietPeriod: Duration
    /// Sweep a `/16`…`/21` in full instead of narrowing it. Explicit opt-in; still cannot widen past
    /// the `/16` floor.
    public var allowLargeSweep: Bool
    /// Include VPN and tunnel interfaces. Off by default: sweeping a corporate tunnel is hostile.
    public var includeTunnels: Bool
    /// What to do when multicast turns out to be unavailable.
    public var multicastUnavailablePolicy: MulticastUnavailablePolicy
    /// Cameras the app already has saved, so a moved camera is recognised rather than duplicated.
    public var knownDevices: [KnownDeviceSnapshot]
    /// Index into `DiscoveryPlan.hostOrder` to resume from, for "Keep scanning" after a deadline.
    public var resumeFrom: Int
    /// Hard cap on datagrams sent by one run (§6.10).
    public var maxDatagramsPerRun: Int
    /// Overrides the computed overall deadline. Tests use it; the UI does not expose it.
    public var overallDeadlineOverride: Duration?

    /// What a run covers.
    public enum Mode: Sendable, Equatable {
        /// Everything: multicast on every interface, then a sweep of every eligible subnet.
        case fullScan
        /// Multicast only — the fast "Refresh" that sends no SYNs at all.
        case multicastOnly
        /// A user-entered range.
        case subnets([IPv4Subnet])
        /// One address: a post-activation re-check or a manual add.
        case single(address: IPv4Address, ports: [UInt16])

        /// True when this mode enumerates hosts at all.
        public var includesSweep: Bool {
            if case .multicastOnly = self { return false }
            return true
        }
    }

    /// What to do when multicast is unavailable.
    public enum MulticastUnavailablePolicy: Sendable, Equatable {
        /// Degrade to a unicast sweep and tell the user what that costs (§9.5). The default.
        case unicastSweep
        /// Fail the run. For callers that would rather show an error than a partial list.
        case fail
    }

    public init(mode: Mode = .fullScan,
                tierAPorts: [UInt16] = [554, 80],
                tierBPorts: [UInt16] = [8_000, 443, 8_080],
                tierCPorts: [UInt16] = [37_777, 8_554, 2_020],
                additionalPorts: [UInt16] = [],
                tcpConnectTimeout: Duration = .milliseconds(350),
                fingerprintTimeout: Duration = .milliseconds(600),
                maxInFlightConnects: Int = 128,
                sadpProbeSchedule: [Duration] = [.zero, .milliseconds(500), .milliseconds(1_000)],
                onvifProbeSchedule: [Duration] = [.zero, .milliseconds(500), .milliseconds(1_000)],
                multicastListenTail: Duration = .milliseconds(2_500),
                sweepStartDelay: Duration = .milliseconds(250),
                settleQuietPeriod: Duration = .milliseconds(750),
                allowLargeSweep: Bool = false,
                includeTunnels: Bool = false,
                multicastUnavailablePolicy: MulticastUnavailablePolicy = .unicastSweep,
                knownDevices: [KnownDeviceSnapshot] = [],
                resumeFrom: Int = 0,
                maxDatagramsPerRun: Int = 8_192,
                overallDeadlineOverride: Duration? = nil) {
        self.mode = mode
        self.tierAPorts = tierAPorts
        self.tierBPorts = tierBPorts
        self.tierCPorts = tierCPorts
        self.additionalPorts = additionalPorts
        self.tcpConnectTimeout = tcpConnectTimeout
        self.fingerprintTimeout = fingerprintTimeout
        self.maxInFlightConnects = maxInFlightConnects
        self.sadpProbeSchedule = sadpProbeSchedule
        self.onvifProbeSchedule = onvifProbeSchedule
        self.multicastListenTail = multicastListenTail
        self.sweepStartDelay = sweepStartDelay
        self.settleQuietPeriod = settleQuietPeriod
        self.allowLargeSweep = allowLargeSweep
        self.includeTunnels = includeTunnels
        self.multicastUnavailablePolicy = multicastUnavailablePolicy
        self.knownDevices = knownDevices
        self.resumeFrom = resumeFrom
        self.maxDatagramsPerRun = maxDatagramsPerRun
        self.overallDeadlineOverride = overallDeadlineOverride
    }

    /// The shipping defaults.
    public static let `default` = DiscoveryConfiguration()

    /// A run that checks exactly one address on the tier A and tier B ports — what the UI uses after
    /// the user activates a camera, or types an address by hand.
    public static func single(address: IPv4Address) -> Self {
        var configuration = DiscoveryConfiguration()
        configuration.mode = .single(address: address, ports: [554, 80, 8_000, 443, 8_080])
        return configuration
    }

    /// Tier A plus any user-added ports, de-duplicated, order preserved. This is the port set every
    /// planned host is probed on, and therefore the multiplier in the connect budget.
    public var effectiveTierAPorts: [UInt16] {
        var seen: Set<UInt16> = []
        return (tierAPorts + additionalPorts).filter { seen.insert($0).inserted }
    }

    /// The per-run connect budget from §6.10: `4 × plannedHosts + 512`.
    public func maxTCPConnects(plannedHosts: Int) -> Int {
        4 * max(0, plannedHosts) + 512
    }
}
