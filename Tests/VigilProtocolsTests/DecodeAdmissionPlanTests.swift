//
//  DecodeAdmissionPlanTests.swift
//  VigilProtocolsTests
//
//  F-DEC-06 acceptance 6 asks for exactly this: "given a set of (camera, tile size, visibility,
//  priority) inputs the resulting plan is a pure function". These are that function's rules.
//
//  ⛔ THE FAILURE THE PLANNER EXISTS TO PREVENT IS SUBTLE. The obvious algorithm — admit in priority
//  order until the budget is full — puts the first few cameras on screen at full rate and leaves the
//  rest black. The same spend spread across the whole wall shows every camera at a lower rate, which
//  is a far better screen, and it is not what "admit until full" produces.
//  `aWallOfSixteenIsSlowedRatherThanHalfBlanked` is that difference.
//

import Testing

import VigilProtocols

@Suite("Decode admission plan")
struct DecodeAdmissionPlanTests {

    // MARK: - Fixtures

    /// A 1080p30 H.264 stream priced through the existing estimator: exactly one decode unit.
    ///
    /// ⚠️ Coded height 1080, not the 1088 a real SPS allocates. The estimator charges **coded**
    /// pixels on purpose — that is what the decoder allocates — so a true 1080p stream is 1.25 DU
    /// once rounded up. This fixture wants a round number to reason about, and
    /// `theEstimatorChargesCodedPixels` is where the real geometry is asserted.
    private func oneUnit() -> DecodeCost {
        DecodeCost.estimate(
            geometry: FrameGeometry(codedWidth: 1920, codedHeight: 1080, cropWidth: 1920,
                                    cropHeight: 1080),
            codec: .h264, fps: 30, mode: .full)
    }

    private func demand(
        _ priority: StreamPriority,
        order: Int = 0,
        mode: DecodeMode = .full,
        cost: DecodeCost = DecodeCost(units: 1),
        preemptible: Bool = true
    ) -> DecodeDemand {
        DecodeDemand(
            id: StreamKey(camera: CameraID(), quality: .main), priority: priority,
            orderIndex: order, mode: mode, cost: cost, isPreemptible: preemptible)
    }

    // MARK: - Re-pricing

    /// A cheaper rung costs the mode's own weight, which is what `DecodeMode.costWeight` is for.
    /// Nothing here invents a second cost model.
    @Test func aCheaperRungCostsItsOwnWeight() {
        let full = demand(.visibleLarge, cost: DecodeCost(units: 1))

        #expect(full.cost(in: .full).units == 1.00)
        // ⚠️ `.trim` is 0.80 of full, and 0.80 rounds **up** to 1.00 at the quarter-unit
        // granularity `DecodeCost` guarantees. On a one-unit stream that rung therefore saves
        // nothing at all, which is why the planner steps over it rather than charging quality for
        // no gain.
        #expect(full.cost(in: .trim).units == 1.00)
        #expect(full.cost(in: .fpsCapped).units == 0.75)
        #expect(full.cost(in: .keyframesOnly).units == 0.25)
        #expect(full.cost(in: .jpegPoll) == .zero)
        #expect(full.cost(in: .paused) == .zero)
    }

    /// The estimator charges coded pixels, not display pixels, because that is what the decoder
    /// allocates: a real 1080p SPS codes 1088 lines and costs a quarter unit more for them.
    @Test func theEstimatorChargesCodedPixels() {
        let coded = DecodeCost.estimate(
            geometry: FrameGeometry(codedWidth: 1920, codedHeight: 1088, cropWidth: 1920,
                                    cropHeight: 1080),
            codec: .h264, fps: 30, mode: .full)

        #expect(coded.units == 1.25)
        #expect(coded > oneUnit())
    }

    /// The two zero-cost modes hold no decompression session, which is why the session ceiling is a
    /// separate resource from the decode-unit budget.
    @Test func onlyTheDecodingModesHoldASession() {
        #expect(DecodeMode.full.opensDecodeSession)
        #expect(DecodeMode.trim.opensDecodeSession)
        #expect(DecodeMode.fpsCapped.opensDecodeSession)
        #expect(DecodeMode.keyframesOnly.opensDecodeSession)
        #expect(DecodeMode.jpegPoll.opensDecodeSession == false)
        #expect(DecodeMode.paused.opensDecodeSession == false)
    }

    // MARK: - Fitting

    /// A budget nobody strains grants what was asked for and demotes nothing.
    @Test func everythingFitsAndNothingIsDemoted() {
        let demands = (0..<4).map { demand(.visibleLarge, order: $0, cost: oneUnit()) }

        let plan = DecodeAdmissionPlanner.plan(for: demands, budget: DecodeCost(units: 24))

        #expect(plan.decisions.allSatisfy { $0.mode == .full })
        #expect(plan.demoted.isEmpty)
        #expect(plan.committed == DecodeCost(units: 4))
        #expect(plan.pressure == .none)
    }

    /// Pressure is what the tile badge and the inspector read, and it is `BudgetPressure`'s own
    /// thresholds rather than a second opinion about them.
    @Test func pressureFollowsTheDeclaredThresholds() {
        let budget = DecodeCost(units: 4)

        let quiet = DecodeAdmissionPlanner.plan(
            for: [demand(.visibleLarge, cost: DecodeCost(units: 2))], budget: budget)
        #expect(quiet.pressure == .none)

        let busy = DecodeAdmissionPlanner.plan(
            for: [demand(.visibleLarge, cost: DecodeCost(units: 3))], budget: budget)
        #expect(busy.pressure == .moderate)
    }

    // MARK: - Demotion

    /// ⛔ THE POINT OF THE FILE. Sixteen 1080p30 tiles against a 4 DU budget all end up slowed
    /// rather than half of them blanked.
    @Test func aWallOfSixteenIsSlowedRatherThanHalfBlanked() {
        let demands = (0..<16).map { demand(.visibleSmall, order: $0, cost: oneUnit()) }

        let plan = DecodeAdmissionPlanner.plan(for: demands, budget: DecodeCost(units: 4))

        #expect(plan.decisions.allSatisfy { $0.mode == .keyframesOnly })
        #expect(plan.committed == DecodeCost(units: 4))
        #expect(plan.demoted.count == 16)
        #expect(plan.pressure == .severe, "a demotion is always severe, however much room is left")
    }

    /// Only as far as the budget needs: four 1080p cameras against 3.5 DU cost the last one its
    /// full rate and leave the rest alone.
    @Test func theLowestPriorityGivesWayFirstAndOnlyAsFarAsNeeded() {
        let demands = (0..<4).map { demand(.visibleLarge, order: $0, cost: oneUnit()) }

        let plan = DecodeAdmissionPlanner.plan(for: demands, budget: DecodeCost(units: 3.5))

        #expect(plan.decisions.prefix(2).allSatisfy { $0.mode == .full })
        #expect(plan.decisions.suffix(2).allSatisfy { $0.mode == .fpsCapped })
        #expect(plan.committed == DecodeCost(units: 3.5))
        #expect(plan.demoted.count == 2, "two rungs of 0.25 each is what 0.5 over budget costs")
    }

    /// The focused tile is the last to lose anything, because it is the one being watched.
    @Test func theFocusedTileKeepsItsRateLongest() {
        let focused = demand(.focused, cost: oneUnit())
        let offscreen = demand(.offscreen, cost: oneUnit())

        let plan = DecodeAdmissionPlanner.plan(
            for: [offscreen, focused], budget: DecodeCost(units: 1))

        #expect(plan.mode(for: focused.id) == .full)
        #expect(plan.mode(for: offscreen.id) == .jpegPoll)
    }

    /// The ladder bottoms out at the JPEG poll, not at a black tile: a poll costs no decode budget,
    /// so pausing a stream that is already there saves nothing — and blanking a tile Vigil could
    /// still fill would spend the user's information to protect a number.
    @Test func theLadderBottomsOutAtTheJPEGPoll() {
        let demands = (0..<3).map { demand(.offscreen, order: $0, cost: oneUnit()) }

        let plan = DecodeAdmissionPlanner.plan(for: demands, budget: .zero)

        #expect(plan.decisions.allSatisfy { $0.mode == .jpegPoll })
        #expect(plan.committed == .zero)
        #expect(plan.decisions.contains { $0.mode == .paused } == false)
    }

    // MARK: - Recordings

    /// ⛔ Acceptance 5. A recording is never demoted, so a plan can exceed its budget — and says so
    /// rather than quietly stopping a file the user asked for.
    @Test func aRecordingIsNeverDemotedEvenOverBudget() {
        let first = demand(.recording, order: 0, cost: oneUnit(), preemptible: false)
        let second = demand(.recording, order: 1, cost: oneUnit(), preemptible: false)

        let plan = DecodeAdmissionPlanner.plan(for: [first, second], budget: DecodeCost(units: 1))

        #expect(plan.decisions.allSatisfy { $0.mode == .full })
        #expect(plan.committed == DecodeCost(units: 2))
        #expect(plan.committed > DecodeCost(units: 1), "the plan reports the truth")
        #expect(plan.pressure == .severe)
    }

    /// A recording holding the budget open costs the previews, not itself.
    @Test func previewsPayForARecordingThatWillNotYield() {
        let recording = demand(.recording, order: 0, cost: oneUnit(), preemptible: false)
        let preview = demand(.visibleSmall, order: 1, cost: oneUnit())

        let plan = DecodeAdmissionPlanner.plan(
            for: [recording, preview], budget: DecodeCost(units: 1))

        #expect(plan.mode(for: recording.id) == .full)
        #expect(plan.mode(for: preview.id) == .jpegPoll)
    }

    // MARK: - The session ceiling

    /// ⚠️ A different resource from the budget. Sixteen tiny streams can exhaust VideoToolbox's
    /// decompression sessions while spending almost none of the decode-unit budget, so the ceiling
    /// is applied on its own — and the streams held back go to the JPEG poll, which opens none.
    @Test func theSessionCeilingIsSeparateFromTheBudget() {
        let demands = (0..<6).map { demand(.visibleSmall, order: $0, cost: DecodeCost(units: 0.25)) }

        let plan = DecodeAdmissionPlanner.plan(
            for: demands, budget: DecodeCost(units: 24), maxSessions: 4)

        #expect(plan.decisions.prefix(4).allSatisfy { $0.mode == .full })
        #expect(plan.decisions.suffix(2).allSatisfy { $0.mode == .jpegPoll })
        #expect(plan.committed == DecodeCost(units: 1), "well inside a budget it never strained")
    }

    /// ⚠️ A recording is exempt from *demotion*, not from the hardware. The session ceiling is what
    /// VideoToolbox will actually refuse, so the recording takes the one session available and the
    /// previews take none — the honest outcome, and the opposite of what "recordings are exempt"
    /// would suggest if it were read as exemption from everything.
    @Test func aRecordingTakesTheSessionAndThePreviewsGoWithout() {
        let recording = demand(.recording, order: 0, cost: DecodeCost(units: 0.25),
                               preemptible: false)
        let previews = (0..<3).map {
            demand(.visibleSmall, order: $0, cost: DecodeCost(units: 0.25))
        }

        let plan = DecodeAdmissionPlanner.plan(
            for: previews + [recording], budget: DecodeCost(units: 24), maxSessions: 1)

        #expect(plan.mode(for: recording.id) == .full)
        #expect(plan.decisions.filter { $0.mode == .full }.count == 1)
        #expect(previews.allSatisfy { plan.mode(for: $0.id) == .jpegPoll })
    }

    // MARK: - Determinism

    /// Acceptance 6: the same demands give the same plan, whatever order they arrive in.
    @Test func thePlanDoesNotDependOnTheOrderOfTheInput() {
        let demands = [
            demand(.visibleSmall, order: 2, cost: oneUnit()),
            demand(.focused, order: 0, cost: oneUnit()),
            demand(.offscreen, order: 1, cost: oneUnit()),
        ]

        let forwards = DecodeAdmissionPlanner.plan(for: demands, budget: DecodeCost(units: 2))
        let backwards = DecodeAdmissionPlanner.plan(
            for: demands.reversed(), budget: DecodeCost(units: 2))

        #expect(forwards == backwards)
    }

    /// Priority beats the caller's index, and the index breaks ties inside a class.
    @Test func theOrderIsPriorityThenIndex() {
        let focused = demand(.focused, order: 9, cost: oneUnit())
        let first = demand(.visibleLarge, order: 0, cost: oneUnit())
        let second = demand(.visibleLarge, order: 1, cost: oneUnit())

        let plan = DecodeAdmissionPlanner.plan(
            for: [second, first, focused], budget: DecodeCost(units: 24))

        #expect(plan.decisions.map(\.id) == [focused.id, first.id, second.id])
    }

    /// An empty stage plans nothing, spends nothing and is under no pressure.
    @Test func noDemandsSpendNothing() {
        let plan = DecodeAdmissionPlanner.plan(for: [], budget: DecodeCost(units: 24))

        #expect(plan.decisions.isEmpty)
        #expect(plan.committed == .zero)
        #expect(plan.pressure == .none)
        #expect(plan.mode(for: StreamKey(camera: CameraID(), quality: .main)) == nil)
    }
}
