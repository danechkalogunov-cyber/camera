//
//  GapPolicy.swift
//  VigilRTP
//
//  What the receiver does about a gap: throttled key-frame requests, and the loss-window that
//  escalates and relaxes the reorder buffer's depth.
//  Implements docs/spec-rtp.md §10.5 / §10.6 and docs/API_CONTRACT.md §5.5
//  (`Jitter/GapPolicy.swift`).
//

import Foundation
import VigilProtocols

/// The thresholds that turn measured loss into an action.
///
/// Held as a value so a test can drive a whole session in microseconds, and so no part of the
/// decision depends on a wall clock.
public struct GapPolicy: Sendable, Hashable {

    // MARK: - Stored Properties

    /// Ask for a key frame when a gap is declared.
    public var requestKeyframeOnGap: Bool

    /// Minimum spacing between two key-frame requests for one stream. A camera that is dropping
    /// packets will not be helped by being asked for an IRAP a hundred times a second.
    public var minimumKeyframeRequestInterval: Duration

    /// Loss fraction above which the reorder buffer escalates to 512 packets / 200 ms.
    public var escalationLossFraction: Double

    /// Window over which `escalationLossFraction` is measured.
    public var escalationWindow: Duration

    /// Loss fraction the stream must stay below to earn its low-latency depth back.
    public var relaxLossFraction: Double

    /// How long it must stay below `relaxLossFraction` before relaxing.
    public var relaxWindow: Duration

    // MARK: - Initialisation

    /// Creates a policy. The defaults are the contract's: escalate above 1 % over 10 s, relax below
    /// 0.1 % sustained for 60 s.
    public init(requestKeyframeOnGap: Bool = true,
                minimumKeyframeRequestInterval: Duration = .seconds(2),
                escalationLossFraction: Double = 0.01,
                escalationWindow: Duration = .seconds(10),
                relaxLossFraction: Double = 0.001,
                relaxWindow: Duration = .seconds(60)) {
        self.requestKeyframeOnGap = requestKeyframeOnGap
        self.minimumKeyframeRequestInterval = minimumKeyframeRequestInterval
        self.escalationLossFraction = escalationLossFraction
        self.escalationWindow = escalationWindow
        self.relaxLossFraction = relaxLossFraction
        self.relaxWindow = relaxWindow
    }

    /// Live viewing.
    public static let live = GapPolicy()

    /// Recorded playback: the file will not gain the packets back, so asking for a key frame is
    /// pointless and the depth may as well stay wide.
    public static let playback = GapPolicy(requestKeyframeOnGap: false,
                                           escalationLossFraction: 0.0)
}

// MARK: - GapTracker

/// Applies a `GapPolicy`: rate-limits key-frame requests and decides when the reorder buffer should
/// escalate or relax.
///
/// The loss window is two counters and a window start, not a ring of samples: at 24 000 packets per
/// second across sixteen streams, a per-packet append would dominate the packet path.
public struct GapTracker: Sendable {

    /// What the loss window is asking the reorder buffer to do.
    public enum DepthDecision: Sendable, Equatable {
        /// Leave the depth alone.
        case unchanged
        /// Widen to 512 packets / 200 ms.
        case escalate
        /// Return to 128 packets / 60 ms.
        case relax
    }

    // MARK: - Stored Properties

    /// The thresholds in force.
    public var policy: GapPolicy

    /// When the last key-frame request was allowed through.
    private var lastKeyframeRequest: MediaInstant?

    /// Start of the current loss-measurement window.
    private var windowStart: MediaInstant

    /// Packets that arrived in the current window.
    private var windowReceived: UInt64 = 0

    /// Packets the sequence numbers say were lost in the current window.
    private var windowLost: UInt64 = 0

    /// True while the buffer is escalated, so `relax` is only asked for once.
    private var isEscalated = false

    /// When the stream last exceeded `relaxLossFraction`; the relax timer runs from here.
    private var lastNoisyInstant: MediaInstant

    // MARK: - Initialisation

    /// Creates a tracker whose windows start at `startTime`.
    public init(policy: GapPolicy = .live, startTime: MediaInstant) {
        self.policy = policy
        self.windowStart = startTime
        self.lastNoisyInstant = startTime
    }

    // MARK: - Public API

    /// The measured loss fraction of the window in progress, 0…1.
    public var windowLossFraction: Double {
        let total = windowReceived &+ windowLost
        guard total > 0 else { return 0 }
        return Swift.min(1, Double(windowLost) / Double(total))
    }

    /// Records what one ingest step saw.
    public mutating func note(received: Int, lost: Int) {
        windowReceived &+= UInt64(Swift.max(0, received))
        windowLost &+= UInt64(Swift.max(0, lost))
    }

    /// Whether a key-frame request may be sent now, recording the decision when it may.
    ///
    /// Returns false when `requestKeyframeOnGap` is off or the previous request was less than
    /// `minimumKeyframeRequestInterval` ago.
    public mutating func shouldRequestKeyframe(at now: MediaInstant) -> Bool {
        guard policy.requestKeyframeOnGap else { return false }
        if let last = lastKeyframeRequest, now < last + policy.minimumKeyframeRequestInterval {
            return false
        }
        lastKeyframeRequest = now
        return true
    }

    /// Evaluates the loss window and reports whether the reorder depth should change.
    ///
    /// Call once per `tick`. The window closes and restarts whenever `escalationWindow` has elapsed;
    /// between closings this returns `.unchanged` without touching any state.
    public mutating func evaluateDepth(at now: MediaInstant) -> DepthDecision {
        guard now >= windowStart + policy.escalationWindow else { return .unchanged }
        let fraction = windowLossFraction
        windowStart = now
        windowReceived = 0
        windowLost = 0

        if fraction > policy.relaxLossFraction { lastNoisyInstant = now }

        if !isEscalated, policy.escalationLossFraction > 0, fraction > policy.escalationLossFraction {
            isEscalated = true
            return .escalate
        }
        if isEscalated, now >= lastNoisyInstant + policy.relaxWindow {
            isEscalated = false
            return .relax
        }
        return .unchanged
    }

    /// Clears every window and throttle. Called on an SSRC change or a reconnect.
    public mutating func reset(at now: MediaInstant) {
        lastKeyframeRequest = nil
        windowStart = now
        windowReceived = 0
        windowLost = 0
        isEscalated = false
        lastNoisyInstant = now
    }
}
