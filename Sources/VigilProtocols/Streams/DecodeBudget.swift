//
//  DecodeBudget.swift
//  VigilProtocols
//
//  Axis 3 of the streaming policy: what the machine can afford to decode, and which streams get it.
//  `TilePolicy` decides what one tile *wants* from its own size; this decides what the whole set
//  *gets* when the wants add up to more than the machine has.
//
//  Implements docs/FEATURES.md F-DEC-06. Pure and Linux-testable, deliberately: acceptance
//  criterion 6 asks for a plan that is "a pure function" of its inputs, and the moment a policy
//  reads the machine it can only be tested on the machine it read. Hardware detection therefore
//  lives in `VigilCore/Platform/DecodeBudget+Machine.swift`, and everything here takes the total as
//  an argument.
//
//  ⛔ WHY ADMISSION IS NOT A COUNT. The app has been carrying `maxConcurrentStreams = 4`, labelled
//  in its own doc comment as a placeholder, and four is the wrong shape of answer twice over: four
//  4K cameras are sixteen times the work of four D1 cameras, and a machine that could carry ten
//  sub-streams is told it may have four. Cost is what varies, so cost is what is counted.
//

// MARK: - DecodeCost

/// The cost of decoding one stream, in **decode units**, where 1 DU is 1080p30.
///
/// `cost = (width × height × fps) / (1920 × 1080 × 30)`, rounded **up** to the next
/// ``DecodeCost/quantum``. Rounding up is the safe direction: a budget that under-counts admits a
/// stream it cannot carry, and the cost of over-counting is one fewer preview.
///
/// **Stored as a count of quanta, not as a `Double`.** Costs are added, compared against a budget
/// and asserted on in tests; binary floating point does none of those three exactly. `0.85 + 0.85`
/// is not `1.7` in `Double`, and a plan that admits or refuses a stream on that difference would be
/// correct on one machine and wrong on another.
public struct DecodeCost: Sendable, Hashable, Comparable, CustomStringConvertible {

    // MARK: Stored Properties

    /// How many ``quantum``-sized steps this costs. Never negative.
    public let steps: Int

    // MARK: Initialisation

    /// Wraps a raw step count. Negative values clamp to zero — a stream cannot give decode back.
    public init(steps: Int) {
        self.steps = Swift.max(0, steps)
    }

    /// A cost stated directly in decode units — a budget total, or a figure from a preferences
    /// file. Rounded to the nearest quantum so that a budget of `24.02` is still a budget a set of
    /// streams can exactly fill.
    public init(units: Double) {
        guard units > 0 else {
            self.init(steps: 0)
            return
        }
        self.init(steps: Int((units / Self.quantum).rounded()))
    }

    /// The cost of decoding `size` at `fps`.
    ///
    /// A non-positive dimension or frame rate costs nothing, which is the honest answer for a
    /// stream whose format has not been resolved yet: it is not decoding, so it is not spending.
    /// The alternative — guessing 1080p30 until the SPS arrives — would refuse admission to a
    /// camera on the strength of a number nobody measured.
    public init(size: Resolution, fps: Double) {
        guard size.width > 0, size.height > 0, fps > 0 else {
            self.init(steps: 0)
            return
        }
        let pixels = Double(size.width) * Double(size.height) * fps
        // The epsilon keeps an exact multiple exact: 4K30 is 4.0 DU, and without it the division's
        // last bit can push 80.000000000000014 steps up to 81 and charge 4.05 DU for it.
        let raw = pixels / Self.reference / Self.quantum
        self.init(steps: Int((raw - Self.epsilon).rounded(.up)))
    }

    // MARK: Computed Properties

    /// The cost in decode units, for logs, the inspector and the diagnostics bundle.
    ///
    /// ⚠️ For display and for arithmetic *outside* the policy. Nothing here compares these.
    public var units: Double { Double(steps) * Self.quantum }

    public var description: String { "\(units) DU" }

    // MARK: Arithmetic

    public static func + (a: Self, b: Self) -> Self { Self(steps: a.steps + b.steps) }

    public static func - (a: Self, b: Self) -> Self { Self(steps: a.steps - b.steps) }

    public static func < (a: Self, b: Self) -> Bool { a.steps < b.steps }

    /// Costs nothing: a JPEG poll, or a stream that is paused.
    public static let zero = DecodeCost(steps: 0)

    /// One 1080p30 stream.
    ///
    /// `.rounded()` and not a truncating `Int(_:)`: `1 / 0.05` is `19.999999999999996` in binary
    /// floating point on some evaluations, and truncation would make one decode unit twenty-*one*
    /// twentieths short of itself.
    public static let one = DecodeCost(steps: Int((1 / quantum).rounded()))

    // MARK: Constants

    /// The unit of account: 1920 × 1080 × 30 pixels per second.
    public static let reference = 1920.0 * 1080.0 * 30.0

    /// The rounding step, in decode units.
    ///
    /// ⚠️ **0.05, and F-DEC-06's prose says 0.25.** The prose and its own worked examples do not
    /// agree, and the examples are unambiguous: 1080p25 is given as 0.85 DU and 704×576@25 as 0.2 DU,
    /// neither of which is a multiple of 0.25 — while both are exactly what this formula yields at
    /// 0.05. The examples are the specification that can be checked, so they win here, and the
    /// contradiction is filed as C-DEC-06 in docs/OPEN-CONFLICTS.md for the contract author to rule
    /// on. If the ruling goes the other way, this constant is the only line that changes.
    public static let quantum = 0.05

    /// Guards the ceiling against floating-point dust. Smaller than any real difference in cost.
    private static let epsilon = 1e-9
}

// MARK: - DecodePriority

/// What a stream is for, in the order admission prefers to keep it.
///
/// Declaration order **is** the priority order (F-DEC-06 acceptance 3), highest first. `Comparable`
/// compares that rank, so `.focusedTile < .thumbnail` reads as "the focused tile outranks a
/// thumbnail" — the same direction as `TileClass`, where a smaller letter is a bigger tile.
public enum DecodePriority: Int, Sendable, Hashable, Codable, CaseIterable, Comparable {

    /// The tile the user is looking at. Never demoted while anything else can be.
    case focusedTile

    /// A tile visible in the main window.
    case visibleTile

    /// A tile on the second-display video wall (`F-LIV-07`).
    case wallTile

    /// The picture-in-picture window (`F-LIV-08`).
    case pictureInPicture

    /// A stream that exists because something is being written to disk.
    ///
    /// ⚠️ Its rank barely matters, because ``DecodeRequest/isRecording`` exempts it from demotion
    /// outright — a recording must never be sacrificed for a preview (F-DEC-06 acceptance 5). The
    /// rank is here so that two recordings still order deterministically against each other.
    case recording

    /// A stream started before it is needed: the patrol's next page.
    case prewarm

    /// A sidebar thumbnail. Costs nothing — it is an ISAPI JPEG poll, not a decode session.
    case thumbnail

    /// Declaration rank, most important first.
    @inlinable public var rank: Int { rawValue }

    @inlinable public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

// MARK: - DecodeAdmission

/// What one stream is allowed to do.
///
/// The ladder is `main → sub → thumbnail → paused` and it is walked in that order (F-DEC-06
/// acceptance 4): everything is demoted as far as it will go before anything is stopped, because a
/// small picture is worth more to the person watching than a black rectangle.
public enum DecodeAdmission: Sendable, Hashable, Codable, CaseIterable {

    /// Decode the main stream.
    case main

    /// Decode the sub-stream. Only offered to a camera that has one.
    case sub

    /// No decode session at all: poll the device's JPEG snapshot endpoint.
    case thumbnail

    /// Nothing. The tile keeps its last frame and says why.
    case paused

    /// The next rung down, or `nil` at the bottom.
    public var demoted: DecodeAdmission? {
        switch self {
        case .main: .sub
        case .sub: .thumbnail
        case .thumbnail: .paused
        case .paused: nil
        }
    }

    /// Whether this admission decodes video at all.
    public var isDecoding: Bool { self == .main || self == .sub }
}

// MARK: - DecodeRequest

/// One stream asking to be decoded.
///
/// The costs are supplied rather than derived, because only the caller knows them: `main` comes
/// from the resolved `StreamFormat` when there is one and from the camera's advertised capability
/// when there is not, and `sub` is `nil` for a device that has no second stream — which is a real
/// case and must not be modelled as "a sub-stream that costs the same".
public struct DecodeRequest: Sendable, Hashable, Identifiable {

    /// The camera this stream belongs to.
    public let id: CameraID

    /// What the stream is for.
    public let priority: DecodePriority

    /// Tie-break within a priority class: lower wins. The stage's cell order, normally.
    public let orderIndex: Int

    /// Whether something is being written to disk from this stream.
    public let isRecording: Bool

    /// What decoding the main stream costs.
    public let main: DecodeCost

    /// What decoding the sub-stream costs, or `nil` when the device has none.
    public let sub: DecodeCost?

    /// Describes one stream's claim on the budget.
    public init(
        id: CameraID,
        priority: DecodePriority,
        orderIndex: Int = 0,
        isRecording: Bool = false,
        main: DecodeCost,
        sub: DecodeCost? = nil
    ) {
        self.id = id
        self.priority = priority
        self.orderIndex = orderIndex
        self.isRecording = isRecording
        self.main = main
        self.sub = sub
    }

    /// What `admission` costs for this stream.
    ///
    /// A camera with no sub-stream cannot be charged for one; asking for `.sub` where none exists
    /// costs what `.main` costs, which is what the planner uses to decide the rung is not worth
    /// taking.
    public func cost(of admission: DecodeAdmission) -> DecodeCost {
        switch admission {
        case .main: main
        case .sub: sub ?? main
        case .thumbnail, .paused: .zero
        }
    }
}

// MARK: - DecodePlan

/// What every stream is allowed to do, and what that adds up to.
public struct DecodePlan: Sendable, Hashable {

    /// One stream's outcome, in admission order — highest priority first.
    public struct Decision: Sendable, Hashable, Identifiable {

        public let id: CameraID
        public let admission: DecodeAdmission

        /// Whether this stream got less than it asked for, which is what a tile badge reports.
        public let isDemoted: Bool

        public init(id: CameraID, admission: DecodeAdmission, isDemoted: Bool) {
            self.id = id
            self.admission = admission
            self.isDemoted = isDemoted
        }
    }

    /// The decisions, highest priority first.
    public let decisions: [Decision]

    /// What the plan spends.
    public let spent: DecodeCost

    /// Builds a plan. Normally produced by ``DecodeBudget/plan(for:)``.
    public init(decisions: [Decision], spent: DecodeCost) {
        self.decisions = decisions
        self.spent = spent
    }

    /// What one camera is allowed to do, or `nil` when it was not in the request set.
    public func admission(for camera: CameraID) -> DecodeAdmission? {
        decisions.first { $0.id == camera }?.admission
    }

    /// The cameras that got less than they asked for, in admission order.
    public var demoted: [CameraID] { decisions.filter(\.isDemoted).map(\.id) }
}

// MARK: - DecodeBudget

/// How much decoding the machine will do at once, and who gets it.
///
/// ⛔ THE PLAN IS A PURE FUNCTION OF ITS INPUTS (F-DEC-06 acceptance 6). Nothing here reads a clock,
/// a machine or a stream — the same requests always produce the same plan, so the policy can be
/// argued about in a test rather than observed on a wall of sixteen cameras. Where the total comes
/// from is `VigilCore`'s problem, and the dwell that stops a plan flapping belongs to the caller
/// that applies it, exactly as `TilePolicySelector` holds the dwell for axis 1.
public struct DecodeBudget: Sendable, Hashable {

    /// Everything the machine will decode at once.
    public let total: DecodeCost

    /// Builds a budget.
    public init(total: DecodeCost) {
        self.total = total
    }

    /// The plan for a set of streams.
    ///
    /// **The algorithm, and why it is this one.** Everything starts at the best it can have. While
    /// the total does not fit, the set is swept from the *lowest* priority upwards, demoting each
    /// stream by **one** rung — and the sweep stops the instant the total fits, so nothing gives up
    /// more than the budget actually needs.
    ///
    /// ⛔ ONE RUNG PER SWEEP IS WHAT KEEPS A WALL FROM GOING HALF BLACK. Demoting each stream all
    /// the way down before moving to the next would put the bottom half of a sixteen-tile wall on a
    /// JPEG poll while the top half stayed in full quality; one rung at a time means sixteen
    /// 1080p tiles against a 4 DU budget all land on the sub-stream instead, which is the same
    /// spend and a far better screen. Where the budget is only slightly short, the difference does
    /// not arise: six 1080p cameras against 4 DU demote three of them and leave the top three alone,
    /// because that is already enough.
    ///
    /// ⚠️ A rung that saves nothing is skipped rather than taken. A camera with no sub-stream costs
    /// the same on `.sub` as on `.main`, so stepping it there would cost the user picture quality and
    /// buy the budget nothing at all — it goes straight to the JPEG poll. This is also what stops the
    /// sweep spinning: every demotion it performs strictly reduces the total.
    ///
    /// ⚠️ Recording streams are skipped by the demoter entirely, so a plan can exceed its budget.
    /// That is deliberate and it is acceptance 5: a recording is a file the user asked for, and
    /// stopping it to keep a preview smooth would destroy the only irreplaceable thing on screen.
    /// ``DecodePlan/spent`` reports the truth so the caller can say so.
    ///
    /// ⚠️ **The budget alone never reaches `.paused`.** A thumbnail is an ISAPI JPEG poll and costs
    /// zero decode units, so once a stream is there the ladder can save nothing more by stopping it.
    /// `.paused` exists for the other reasons a stream stops — occlusion, a minimised window, the
    /// user — and this policy deliberately does not reach for it. A decode budget that blanked tiles
    /// it could still have shown a picture in would be spending the user's information to protect a
    /// number.
    public func plan(for requests: [DecodeRequest]) -> DecodePlan {
        // Deterministic total order: priority, then the caller's index, then identity — so two
        // streams that agree on the first two still cannot swap places between runs.
        let ordered = requests.sorted { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            if a.orderIndex != b.orderIndex { return a.orderIndex < b.orderIndex }
            return a.id.rawValue.uuidString < b.id.rawValue.uuidString
        }
        var admissions = ordered.map { Self.best(for: $0) }
        var spent = zip(ordered, admissions).reduce(DecodeCost.zero) { $0 + $1.0.cost(of: $1.1) }
        // From the back, one rung per pass, until it fits or nothing else can give.
        var didDemote = true
        while spent > total, didDemote {
            didDemote = false
            for index in ordered.indices.reversed() where spent > total {
                let request = ordered[index]
                guard !request.isRecording else { continue }
                guard let next = Self.nextRung(for: request, from: admissions[index]) else {
                    continue
                }
                let saving = request.cost(of: admissions[index]) - request.cost(of: next)
                admissions[index] = next
                spent = spent - saving
                didDemote = true
            }
        }
        let decisions = zip(ordered, admissions).map { request, admission in
            DecodePlan.Decision(id: request.id,
                                admission: admission,
                                isDemoted: admission != Self.best(for: request))
        }
        return DecodePlan(decisions: decisions, spent: spent)
    }

    /// What a stream would get if it were the only one.
    ///
    /// A thumbnail request is a thumbnail whatever the budget: it never asked for a decode session,
    /// and "promoting" it to one would spend the budget on the sidebar.
    private static func best(for request: DecodeRequest) -> DecodeAdmission {
        request.priority == .thumbnail ? .thumbnail : .main
    }

    /// The next rung down that actually costs this stream less, or `nil` when none does.
    ///
    /// Walking past the rungs that save nothing is what makes a camera with no sub-stream skip
    /// `.sub` instead of losing its main picture for no saving — and it is what guarantees the
    /// sweep in ``plan(for:)`` terminates, because every demotion it returns strictly reduces the
    /// total.
    private static func nextRung(for request: DecodeRequest,
                                 from current: DecodeAdmission) -> DecodeAdmission? {
        let spending = request.cost(of: current)
        var rung = current
        while let next = rung.demoted {
            if request.cost(of: next) < spending { return next }
            rung = next
        }
        return nil
    }
}
