//
//  DecodeAdmissionPlan.swift
//  VigilProtocols
//
//  The decision half of `DecodeAdmitting`: given what every stream wants and what the machine has,
//  which mode each one runs in. Pure, so `F-DEC-06` acceptance 6 — "given a set of (camera, tile
//  size, visibility, priority) inputs the resulting plan is a pure function" — is a test rather than
//  an observation on a wall of sixteen cameras.
//
//  ⛔ EVERY TYPE HERE IS ONE `DecodePolicy.swift` ALREADY DEFINED. `DecodeCost` prices a stream,
//  `DecodeMode` *is* the demotion ladder and already carries the cost weight of each rung,
//  `StreamPriority` is the admission order, `BudgetPressure` is what the tile badge reads. What was
//  missing was never a vocabulary — it was something that uses it to decide. `DecodeAdmitting` is
//  the actor-shaped authority that hands out leases; this is the arithmetic it needs, factored out
//  so that the part which can be wrong is the part that can be tested.
//

// MARK: - DecodeDemand

/// One stream asking for decode budget.
///
/// The cost is the cost **at `mode`**, priced by the caller through
/// ``DecodeCost/estimate(geometry:codec:fps:mode:isDownscaling:)`` — only the caller knows the
/// codec, the coded geometry and the frame rate. The planner re-prices it for cheaper rungs from
/// ``DecodeMode/costWeight``, which is exactly what that weight is for.
public struct DecodeDemand: Sendable, Hashable, Identifiable {

    /// Which stream this is. `StreamKey` and not `CameraID`, because a camera's main and sub streams
    /// are two different decodes and a plan has to be able to name them apart.
    public let id: StreamKey

    /// What the stream is for. Ties break on ``orderIndex`` ascending, per `DecodePolicy`.
    public let priority: StreamPriority

    /// Tie-break within a priority class: lower wins. The stage's cell order, normally.
    public let orderIndex: Int

    /// The mode the caller is asking for.
    public let mode: DecodeMode

    /// What ``mode`` costs for this stream.
    public let cost: DecodeCost

    /// Whether admission may demote this stream.
    ///
    /// ⛔ `false` for a recording, and that is `F-DEC-06` acceptance 5 rather than a preference: a
    /// recording is a file the user asked for, and stopping it to keep a preview smooth destroys the
    /// only irreplaceable thing on the screen. `StreamPriority.recording` says the same in the
    /// ordering; this says it in the arithmetic, and the arithmetic is what actually protects it.
    public let isPreemptible: Bool

    /// Describes one stream's claim on the budget.
    public init(
        id: StreamKey,
        priority: StreamPriority,
        orderIndex: Int = 0,
        mode: DecodeMode = .full,
        cost: DecodeCost,
        isPreemptible: Bool = true
    ) {
        self.id = id
        self.priority = priority
        self.orderIndex = orderIndex
        self.mode = mode
        self.cost = cost
        self.isPreemptible = isPreemptible
    }

    /// What this stream would cost in `candidate`, re-priced from the mode it asked for.
    ///
    /// A mode that runs no hardware decoder costs zero however expensive the stream is — that is
    /// ``DecodeMode/costWeight`` being `0` for `.paused` and `.jpegPoll`, and it is why the ladder
    /// bottoms out in a JPEG poll rather than in a black tile.
    ///
    /// Returns ``cost`` unchanged for the mode that was asked for, so a plan that demotes nothing
    /// spends exactly what the caller priced.
    public func cost(in candidate: DecodeMode) -> DecodeCost {
        guard candidate != mode else { return cost }
        guard mode.costWeight > 0 else { return .zero }
        return DecodeCost(units: cost.units / mode.costWeight * candidate.costWeight)
    }
}

// MARK: - DecodeAdmissionPlan

/// What every stream is allowed to do, and what that adds up to.
public struct DecodeAdmissionPlan: Sendable, Hashable {

    /// One stream's outcome, in admission order — highest priority first.
    public struct Decision: Sendable, Hashable, Identifiable {

        public let id: StreamKey

        /// The mode admission granted.
        public let mode: DecodeMode

        /// What it was asked for. Different from ``mode`` exactly when this stream was demoted.
        public let requested: DecodeMode

        public init(id: StreamKey, mode: DecodeMode, requested: DecodeMode) {
            self.id = id
            self.mode = mode
            self.requested = requested
        }

        /// Whether this stream got less than it asked for — which the caller **must** surface as a
        /// tile badge and an inspector note. Silent degradation is a defect, and `AdmissionResult`
        /// has a whole case (`grantedDegraded`) that exists to say so.
        public var isDemoted: Bool { mode < requested }
    }

    /// The decisions, highest priority first.
    public let decisions: [Decision]

    /// What the plan commits.
    public let committed: DecodeCost

    /// How close to the ceiling the plan runs, for the badge and the inspector.
    public let pressure: BudgetPressure

    /// Builds a plan. Normally produced by ``DecodeAdmissionPlanner/plan(for:budget:maxSessions:)``.
    public init(decisions: [Decision], committed: DecodeCost, pressure: BudgetPressure) {
        self.decisions = decisions
        self.committed = committed
        self.pressure = pressure
    }

    /// The mode one stream was granted, or `nil` when it was not in the demand set.
    public func mode(for key: StreamKey) -> DecodeMode? {
        decisions.first { $0.id == key }?.mode
    }

    /// The streams that got less than they asked for, in admission order.
    public var demoted: [StreamKey] { decisions.filter(\.isDemoted).map(\.id) }
}

// MARK: - DecodeAdmissionPlanner

/// Turns demands and a budget into a plan.
///
/// An enum with static members rather than a struct with state, because there is no state: the
/// whole point is that the same inputs give the same plan. `DecodeAdmitting`'s implementation holds
/// the leases, the thermal multiplier and the change stream; it calls this to decide.
public enum DecodeAdmissionPlanner {

    /// The plan for a set of demands.
    ///
    /// **The algorithm, in two rules that pull in opposite directions and both have to hold.**
    ///
    /// ⛔ 1. PRIORITY CLASSES ARE STRICT. The lowest class that can still give something is
    /// exhausted before the class above it gives anything, which is what `F-DEC-06` acceptance 3
    /// means by an order. Without it a budget one unit short would take a rung off the focused tile
    /// — the one the user is looking at — while an offscreen pre-warm still had four rungs left.
    ///
    /// ⛔ 2. WITHIN A CLASS THE LOSS IS SPREAD, ONE RUNG AT A TIME. Taking one stream all the way
    /// down before touching the next would put the bottom half of a sixteen-tile wall on a JPEG poll
    /// while the top half ran at full rate; a rung at a time lands the whole wall on
    /// `.keyframesOnly` instead — the same spend, a far better screen. The sweep stops the instant
    /// the total fits, so where the budget is only slightly short, only the last tile or two give
    /// anything up at all.
    ///
    /// ⚠️ A rung that saves nothing is skipped rather than taken, so a stream is never charged
    /// quality for no saving. At 0.25 DU granularity that is not a corner case: `.trim` is 0.80 of
    /// `.full`, which on a 1 DU stream rounds back to the same 1 DU, so the ladder steps over it.
    /// Skipping is also what proves the sweep terminates — every demotion it makes strictly reduces
    /// the total.
    ///
    /// ⚠️ Non-preemptible streams — recordings — are skipped entirely, so a plan **can** exceed its
    /// budget. ``DecodeAdmissionPlan/committed`` reports that honestly rather than pretending, and
    /// ``DecodeAdmissionPlan/pressure`` reads `.severe`, which is what puts the warning in front of
    /// the user.
    ///
    /// - Parameters:
    ///   - demands: what every stream wants. Order is irrelevant; the plan sorts.
    ///   - budget: what the machine will decode at once.
    ///   - maxSessions: the ceiling on simultaneous decode sessions, which VideoToolbox exhausts
    ///     long before the DU budget does on small streams. Streams beyond it are held at
    ///     `.jpegPoll`, which opens no session at all. `nil` for no ceiling.
    public static func plan(for demands: [DecodeDemand],
                            budget: DecodeCost,
                            maxSessions: Int? = nil) -> DecodeAdmissionPlan {
        let ordered = demands.sorted(by: precedes)
        var modes = ordered.map(\.mode)
        // The session ceiling is applied first and separately, because it is a different resource:
        // a machine can be nowhere near its decode-unit budget and still be out of decompression
        // sessions. Priority order decides who keeps one, exactly as for the budget.
        if let maxSessions {
            var sessions = 0
            for index in ordered.indices where modes[index].opensDecodeSession {
                sessions += 1
                guard sessions > maxSessions, ordered[index].isPreemptible else { continue }
                modes[index] = .jpegPoll
                sessions -= 1
            }
        }
        var committed = zip(ordered, modes).reduce(DecodeCost.zero) { $0 + $1.0.cost(in: $1.1) }
        while committed > budget {
            // The lowest class with anything left to give. Recomputed each pass, so a class is
            // taken down rung by rung until it is exhausted, and only then does the next one up
            // give anything.
            let givers = ordered.indices.filter {
                ordered[$0].isPreemptible && nextRung(for: ordered[$0], from: modes[$0]) != nil
            }
            guard let floor = givers.map({ ordered[$0].priority }).min() else { break }
            for index in givers.reversed()
            where committed > budget && ordered[index].priority == floor {
                guard let next = nextRung(for: ordered[index], from: modes[index]) else { continue }
                committed = DecodeCost(
                    units: committed.units - ordered[index].cost(in: modes[index]).units
                        + ordered[index].cost(in: next).units)
                modes[index] = next
            }
        }
        let decisions = zip(ordered, modes).map { demand, mode in
            DecodeAdmissionPlan.Decision(id: demand.id, mode: mode, requested: demand.mode)
        }
        return DecodeAdmissionPlan(
            decisions: decisions,
            committed: committed,
            pressure: pressure(committed: committed, budget: budget, decisions: decisions))
    }

    /// The total order admission walks: priority, then the caller's index, then identity — so two
    /// streams that agree on the first two still cannot swap places between runs.
    private static func precedes(_ a: DecodeDemand, _ b: DecodeDemand) -> Bool {
        if a.priority != b.priority { return a.priority > b.priority }
        if a.orderIndex != b.orderIndex { return a.orderIndex < b.orderIndex }
        if a.id.camera != b.id.camera {
            return a.id.camera.rawValue.uuidString < b.id.camera.rawValue.uuidString
        }
        return a.id.quality < b.id.quality
    }

    /// The next mode down that actually costs this stream less, or `nil` when none does.
    ///
    /// Walking past the rungs that save nothing is what keeps a stream from losing picture quality
    /// for no gain, and it is what guarantees the sweep terminates.
    private static func nextRung(for demand: DecodeDemand,
                                 from current: DecodeMode) -> DecodeMode? {
        let spending = demand.cost(in: current)
        for candidate in DecodeMode.allCases.reversed() where candidate < current {
            if demand.cost(in: candidate) < spending { return candidate }
        }
        return nil
    }

    /// `BudgetPressure`'s own thresholds, applied: under 70 % is `.none`, 70–95 % is `.moderate`,
    /// above 95 % — **or any stream demoted at all** — is `.severe`.
    private static func pressure(committed: DecodeCost,
                                 budget: DecodeCost,
                                 decisions: [DecodeAdmissionPlan.Decision]) -> BudgetPressure {
        if decisions.contains(where: \.isDemoted) { return .severe }
        guard budget.units > 0 else { return committed.units > 0 ? .severe : .none }
        let fraction = committed.units / budget.units
        if fraction > 0.95 { return .severe }
        return fraction >= 0.70 ? .moderate : .none
    }
}

// MARK: - DecodeMode

public extension DecodeMode {

    /// Whether this mode holds a `VTDecompressionSession`.
    ///
    /// The two zero-cost modes do not: `.paused` decodes nothing and `.jpegPoll` fetches stills over
    /// HTTP. That distinction is the whole reason `maxConcurrentSessions()` is a separate ceiling
    /// from the decode-unit budget — sixteen small streams can exhaust the sessions while spending
    /// almost none of the budget.
    var opensDecodeSession: Bool { costWeight > 0 }
}
