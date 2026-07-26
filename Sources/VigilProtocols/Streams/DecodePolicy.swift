//
//  DecodePolicy.swift
//  VigilProtocols
//
//  Axis 2 of the streaming policy: how hard a stream is run, what it costs in decode
//  units, and the admission protocol that hands out that budget.
//
//  Implements docs/API_CONTRACT.md §3.7 (rulings R-21, R-22, R-49, R-58).
//

import Foundation

// MARK: - Mode

/// How hard a stream is being run, independent of which stream it is.
/// Axis 2 of the tile policy (API_CONTRACT §2 R-21).
public enum DecodeMode: Int, Sendable, Hashable, Codable, Comparable, CaseIterable {
    case paused = 0
    case jpegPoll = 1
    case keyframesOnly = 2
    /// 15 fps ceiling on a 25/30 fps stream. `ReducedFrameDelivery = 0.5`.
    case fpsCapped = 3
    /// Drop droppable frames under transient pressure; not a steady state.
    case trim = 4
    case full = 5

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Multiplier on the DU cost. `paused` and `jpegPoll` cost zero hardware-decode budget.
    @inlinable public var costWeight: Double {
        switch self {
        case .paused, .jpegPoll: 0
        case .keyframesOnly: 0.12
        case .fpsCapped: 0.55
        case .trim: 0.80
        case .full: 1.00
        }
    }
}

// MARK: - Priority

/// Admission priority. Ties break on `orderIndex` ascending. One enum, not two
/// (`TilePriority` does not exist — API_CONTRACT §2 R-49).
public enum StreamPriority: Int, Sendable, Hashable, Codable, Comparable, CaseIterable {
    /// Fullscreen, or the single focused tile, or the audio-solo camera.
    case focused = 400
    /// On-screen tile with a short edge ≥ 480 backing px.
    case visibleLarge = 300
    /// On-screen tile with a short edge < 480 backing px.
    case visibleSmall = 200
    /// Video-wall tile on a secondary display.
    case wall = 175
    case pictureInPicture = 150
    /// **Never demoted, never occlusion-paused.** A recording must not be sacrificed for a preview.
    /// Its raw value puts it above every visible tile but below the focused one.
    case recording = 350
    /// In the layout but scrolled off, occluded, or pre-warming.
    case offscreen = 100
    case sidebarThumbnail = 50
    /// `Camera.isPinnedLive` and nothing else.
    case background = 10

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

// MARK: - Cost

/// Hardware-decode cost in **decode units**. 1 DU = one 1080p30 H.264 stream.
public struct DecodeCost: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    /// Always a non-negative multiple of 0.25.
    public let units: Double

    /// Rounds **up** to the next quarter unit and clamps to zero, so the invariant on `units`
    /// holds for every value however it was computed. A non-finite argument — which a garbage
    /// frame rate from a device can produce — becomes zero rather than poisoning the budget.
    public init(units: Double) {
        guard units.isFinite, units > 0 else {
            self.units = 0
            return
        }
        let quarters = (units * 4).rounded(.up)
        // 2^53 quarters is far beyond any budget; clamping keeps the Double exact-integer domain.
        self.units = quarters.isFinite ? Swift.min(quarters, 9_007_199_254_740_992) / 4 : 0
    }

    /// `ceil( codedPixels × fps / (1920×1080×30) × codecWeight × depthWeight × modeWeight × 4 ) / 4`
    /// where `depthWeight` is 1.26 above 8-bit and 1.0 otherwise, plus 0.05 additive when
    /// downscale-on-decode is active (API_CONTRACT §2 R-58). Uses **coded** pixels, not display
    /// pixels: the decoder allocates 1088 lines and that is what costs bandwidth.
    ///
    /// A mode that runs no hardware decoder at all (`paused`, `jpegPoll`) costs exactly zero, the
    /// downscale surcharge included — there is nothing to surcharge. A negative or non-finite
    /// `fps` is treated as zero.
    public static func estimate(geometry: FrameGeometry, codec: VideoCodec, fps: Double,
                                mode: DecodeMode, isDownscaling: Bool = false) -> DecodeCost {
        let modeWeight = mode.costWeight
        guard modeWeight > 0 else { return .zero }
        guard fps.isFinite, fps > 0 else { return .zero }

        let pixels = Double(geometry.codedWidth) * Double(geometry.codedHeight)
        guard pixels > 0 else { return .zero }

        let reference = 1920.0 * 1080.0 * 30.0
        let depthWeight = geometry.bitDepth > 8 ? 1.26 : 1.0
        let raw = pixels * fps / reference * codec.decodeWeight * depthWeight * modeWeight
        // The surcharge is inside the rounding, so `units` stays a multiple of 0.25.
        return DecodeCost(units: raw + (isDownscaling ? 0.05 : 0))
    }

    public static let zero = DecodeCost(units: 0)

    public static func + (a: Self, b: Self) -> Self { DecodeCost(units: a.units + b.units) }

    public static func < (a: Self, b: Self) -> Bool { a.units < b.units }

    public var description: String {
        // No Foundation, so no String(format:): two decimals by construction, since `units` is
        // always a multiple of 0.25.
        let quarters = Int((units * 4).rounded())
        let whole = quarters / 4
        let fraction = (quarters % 4) * 25
        let padded = fraction < 10 ? "0\(fraction)" : "\(fraction)"
        return "\(whole).\(padded) DU"
    }
}

// MARK: - Leases

/// A granted reservation. Releasing is idempotent and MUST happen in a `defer` or an actor
/// `deinit`-equivalent path; a leaked lease starves every other camera.
public struct DecodeLease: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let key: StreamKey
    public private(set) var cost: DecodeCost
    public private(set) var mode: DecodeMode

    /// Only the admission authority (`VigilVideo.DecodeBudget`) should construct one: a lease that
    /// no authority is tracking reserves nothing.
    public init(id: UUID = UUID(), key: StreamKey, cost: DecodeCost, mode: DecodeMode) {
        self.id = id
        self.key = key
        self.cost = cost
        self.mode = mode
    }

    /// The same lease re-priced. Used by `DecodeAdmitting.update(_:cost:mode:priority:)`; the `id`
    /// is preserved so `release` still matches.
    public func repriced(cost: DecodeCost, mode: DecodeMode) -> DecodeLease {
        DecodeLease(id: id, key: key, cost: cost, mode: mode)
    }
}

public enum DenialReason: String, Sendable, Hashable, Codable {
    case insufficientBudget, sessionLimitReached, thermalCritical, hardwareUnavailable
}

/// How close the machine is to its decode ceiling. Drives the tile badge and the inspector note;
/// silent degradation is a defect.
public enum BudgetPressure: String, Sendable, Hashable, Codable, Comparable, CaseIterable {
    /// < 70 % of budget committed.
    case none
    /// 70–95 %.
    case moderate
    /// > 95 %, or any stream currently demoted by admission.
    case severe

    /// Ordering rank. The raw values are strings for the diagnostics bundle, so severity order is
    /// declared here rather than inherited from the raw value.
    @usableFromInline var rank: Int {
        switch self {
        case .none: 0
        case .moderate: 1
        case .severe: 2
        }
    }

    @inlinable public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

// MARK: - Admission

public enum AdmissionResult: Sendable, Hashable {
    case granted(DecodeLease)
    /// Admitted, but at a cheaper mode than asked for. The caller MUST surface a visible badge
    /// and an inspector note: silent degradation is a defect (FEATURES.md honesty requirement).
    case grantedDegraded(DecodeLease, DecodeMode)
    case denied(DenialReason)

    /// The lease, for the two granting cases. `nil` when denied.
    @inlinable public var lease: DecodeLease? {
        switch self {
        case .granted(let lease): lease
        case .grantedDegraded(let lease, _): lease
        case .denied: nil
        }
    }
}

public enum BudgetChange: Sendable, Hashable {
    case demote(StreamKey, to: DecodeMode, reason: DenialReason)
    case promote(StreamKey, to: DecodeMode)
    case pressureChanged(BudgetPressure)
    case budgetChanged(DecodeCost, reason: String)
}

public struct BudgetSnapshot: Sendable, Hashable, Codable {
    public var budget: DecodeCost
    public var committed: DecodeCost
    public var sessionCount: Int
    public var maxSessions: Int
    public var pressure: BudgetPressure
    public var modes: [StreamKey: DecodeMode]

    public init(budget: DecodeCost, committed: DecodeCost, sessionCount: Int, maxSessions: Int,
                pressure: BudgetPressure, modes: [StreamKey: DecodeMode]) {
        self.budget = budget
        self.committed = committed
        self.sessionCount = sessionCount
        self.maxSessions = maxSessions
        self.pressure = pressure
        self.modes = modes
    }
}

/// The admission authority, declared here so `StreamCoordinator`'s planner is Linux-testable.
/// The single implementation is `VigilVideo.DecodeBudget`, a `@globalActor actor`
/// (API_CONTRACT §2 R-49).
public protocol DecodeAdmitting: Sendable {
    /// Total DU available right now, after thermal and low-power multipliers.
    func currentBudget() async -> DecodeCost
    /// Hard ceiling on simultaneous `VTDecompressionSession`s / `AVSampleBufferDisplayLayer`s,
    /// which VideoToolbox exhausts long before the DU budget does on small streams.
    func maxConcurrentSessions() async -> Int
    /// Reserves capacity, possibly at a cheaper mode than requested.
    func admit(key: StreamKey, cost: DecodeCost, mode: DecodeMode,
               priority: StreamPriority, isPreemptible: Bool) async -> AdmissionResult
    /// Re-prices an existing lease after a tile resize or a format change.
    func update(_ lease: DecodeLease, cost: DecodeCost, mode: DecodeMode,
                priority: StreamPriority) async -> AdmissionResult
    func release(_ lease: DecodeLease) async
    /// Reserves headroom for a transient (strategy switch, one-shot snapshot session).
    func reserveTransient(_ cost: DecodeCost, for duration: Duration) async -> Bool
    /// Demotion orders pushed to pipelines. A factory, not a property (API_CONTRACT §2 R-65).
    func budgetChanges() -> AsyncStream<BudgetChange>
    func snapshot() async -> BudgetSnapshot
}
