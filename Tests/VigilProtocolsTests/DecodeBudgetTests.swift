//
//  DecodeBudgetTests.swift
//  VigilProtocolsTests
//
//  F-DEC-06's acceptance criteria, as tests. Criterion 6 asks for exactly this: "given a set of
//  (camera, tile size, visibility, priority) inputs the resulting plan is a pure function".
//
//  ⛔ THE CASE THIS POLICY EXISTS FOR IS SIXTEEN CAMERAS ON A LAPTOP, and the failure it exists to
//  prevent is subtle: the obvious algorithm — admit in priority order until the budget is full — puts
//  the first four cameras on screen in full quality and leaves the last twelve black. Sixteen
//  sub-streams is the same spend and a far better screen, and it is not what "admit until full"
//  produces. `aWallOfSixteenGoesToSubRatherThanHalfBlack` is that difference.
//

import Testing

import VigilProtocols

@Suite("Decode budget")
struct DecodeBudgetTests {

    // MARK: - Fixtures

    private func request(
        _ priority: DecodePriority,
        order: Int = 0,
        recording: Bool = false,
        main: DecodeCost = .one,
        sub: DecodeCost? = nil
    ) -> DecodeRequest {
        DecodeRequest(
            id: CameraID(), priority: priority, orderIndex: order, isRecording: recording,
            main: main, sub: sub)
    }

    // MARK: - Cost

    /// ⛔ F-DEC-06's three worked examples, verbatim. They are the only part of the cost rule that
    /// can be checked against the document rather than against my arithmetic, and they are what
    /// decided the quantum: none of 0.85 or 0.2 is a multiple of the 0.25 the prose names.
    @Test func theSpecifiedExamplesCostWhatTheSpecificationSays() {
        #expect(DecodeCost(size: Resolution(width: 3840, height: 2160), fps: 30).units == 4.0)
        #expect(DecodeCost(size: Resolution(width: 1920, height: 1080), fps: 25).units == 0.85)
        #expect(DecodeCost(size: Resolution(width: 704, height: 576), fps: 25).units == 0.2)
    }

    /// One decode unit is 1080p30 by definition.
    @Test func theUnitIsOneThousandAndEightyAtThirty() {
        #expect(DecodeCost(size: Resolution(width: 1920, height: 1080), fps: 30) == .one)
        #expect(DecodeCost.one.units == 1.0)
    }

    /// Rounding is **up**, because under-counting admits a stream the machine cannot carry and
    /// over-counting costs one preview.
    @Test func costRoundsUpToTheQuantum() {
        // 640×360@30 is 0.111… DU, which is not a multiple of 0.05.
        let cost = DecodeCost(size: Resolution(width: 640, height: 360), fps: 30)
        #expect(cost.units == 0.15)
    }

    /// A format nobody has resolved yet costs nothing. Guessing 1080p30 would refuse a camera on
    /// the strength of a number no one measured.
    @Test func anUnknownFormatCostsNothing() {
        #expect(DecodeCost(size: Resolution(width: 0, height: 0), fps: 0) == .zero)
        #expect(DecodeCost(size: Resolution(width: 1920, height: 1080), fps: 0) == .zero)
    }

    /// Costs add exactly. The whole reason they are stored as integer steps is that `0.85 + 0.85`
    /// is not `1.7` in binary floating point, and a plan must not turn on that difference.
    @Test func costsAddExactly() {
        let one = DecodeCost(size: Resolution(width: 1920, height: 1080), fps: 25)
        #expect((one + one).steps == 34)
        #expect((one + one) == DecodeCost(units: 1.7))
    }

    /// Nothing can cost less than nothing.
    @Test func costsNeverGoNegative() {
        #expect((DecodeCost.zero - .one) == .zero)
    }

    // MARK: - Admission when everything fits

    /// A budget nobody strains gives everyone the main stream, and reports the true spend.
    @Test func everythingFitsAndNothingIsDemoted() {
        let budget = DecodeBudget(total: DecodeCost(units: 24))
        let requests = (0..<4).map { request(.visibleTile, order: $0) }

        let plan = budget.plan(for: requests)

        #expect(plan.decisions.allSatisfy { $0.admission == .main })
        #expect(plan.demoted.isEmpty)
        #expect(plan.spent == DecodeCost(units: 4))
    }

    /// A thumbnail is a thumbnail however much room there is: it never asked for a decode session,
    /// and promoting it would spend the budget on the sidebar.
    @Test func aThumbnailIsNeverPromoted() {
        let budget = DecodeBudget(total: DecodeCost(units: 24))
        let thumbnail = request(.thumbnail)

        let plan = budget.plan(for: [thumbnail])

        #expect(plan.admission(for: thumbnail.id) == .thumbnail)
        #expect(plan.spent == .zero)
        #expect(plan.demoted.isEmpty, "getting what it asked for is not a demotion")
    }

    // MARK: - Demotion

    /// The lowest-priority streams give way first, and only as far as the budget actually needs:
    /// six 1080p cameras against 4 DU cost three of them their main stream and leave the top three
    /// untouched. Demoting all six would be quality nobody asked to give up.
    @Test func theLowestPriorityStreamsGiveWayFirstAndOnlyAsFarAsNeeded() {
        let budget = DecodeBudget(total: DecodeCost(units: 4))
        let requests = (0..<6).map {
            request(.visibleTile, order: $0, main: .one, sub: DecodeCost(units: 0.25))
        }

        let plan = budget.plan(for: requests)

        #expect(plan.decisions.prefix(3).allSatisfy { $0.admission == .main })
        #expect(plan.decisions.suffix(3).allSatisfy { $0.admission == .sub })
        #expect(plan.spent == DecodeCost(units: 3.75))
        #expect(plan.demoted.count == 3)
    }

    /// ⛔ THE POINT OF THE WHOLE FILE. A 4 × 4 wall against a 4 DU budget lands every tile on the
    /// sub-stream rather than leaving half of them black — because the sweep takes one rung from
    /// everyone before it takes a second from anyone.
    @Test func aWallOfSixteenGoesToSubRatherThanHalfBlack() {
        let budget = DecodeBudget(total: DecodeCost(units: 4))
        let requests = (0..<16).map {
            request(.visibleTile, order: $0, main: .one, sub: DecodeCost(units: 0.25))
        }

        let plan = budget.plan(for: requests)

        #expect(plan.decisions.allSatisfy { $0.admission == .sub })
        #expect(plan.spent == DecodeCost(units: 4))
    }

    /// The focused tile is the last thing to lose anything, because it is the one being watched.
    @Test func theFocusedTileKeepsItsPictureLongest() {
        let budget = DecodeBudget(total: DecodeCost(units: 1))
        let focused = request(.focusedTile, main: .one)
        let background = request(.prewarm, main: .one)

        let plan = budget.plan(for: [background, focused])

        #expect(plan.admission(for: focused.id) == .main)
        #expect(plan.admission(for: background.id) == .thumbnail)
    }

    /// A camera with no sub-stream cannot be charged for one, so the rung is skipped and it goes
    /// straight to a thumbnail. Modelling the absent sub-stream as "costs the same as main" is what
    /// would otherwise make the demoter spin without saving anything.
    @Test func aCameraWithNoSubStreamSkipsThatRung() {
        let budget = DecodeBudget(total: DecodeCost(units: 1))
        let withSub = request(.visibleTile, order: 0, main: .one, sub: DecodeCost(units: 0.25))
        let without = request(.visibleTile, order: 1, main: .one, sub: nil)

        let plan = budget.plan(for: [withSub, without])

        #expect(plan.admission(for: without.id) == .thumbnail, "`.sub` would have saved it nothing")
        #expect(plan.admission(for: withSub.id) == .main, "one demotion was already enough")
        #expect(plan.spent <= budget.total)
    }

    /// ⚠️ The bottom of the ladder the budget can reach is the JPEG poll, not `.paused`. A poll
    /// costs zero decode units, so stopping a stream that is already there saves the budget nothing
    /// — and blanking a tile Vigil could still show a picture in would be spending the user's
    /// information to protect a number. `.paused` belongs to occlusion and to the user.
    @Test func theBudgetNeverBlanksATileItCouldStillFill() {
        let budget = DecodeBudget(total: DecodeCost(units: 1))
        let recording = request(.recording, recording: true, main: .one)
        let preview = request(.visibleTile, main: .one)

        let plan = budget.plan(for: [recording, preview])

        #expect(plan.admission(for: recording.id) == .main)
        #expect(plan.admission(for: preview.id) == .thumbnail)
        #expect(plan.decisions.contains { $0.admission == .paused } == false)
    }

    // MARK: - Recording is exempt

    /// ⛔ Acceptance 5. A recording is a file the user asked for; a preview is a picture they can
    /// have again in a second. Two recordings over budget therefore *exceed* the budget, and the
    /// plan says so rather than quietly stopping one.
    @Test func recordingsAreNeverDemotedEvenOverBudget() {
        let budget = DecodeBudget(total: DecodeCost(units: 1))
        let first = request(.recording, order: 0, recording: true, main: .one)
        let second = request(.recording, order: 1, recording: true, main: .one)

        let plan = budget.plan(for: [first, second])

        #expect(plan.admission(for: first.id) == .main)
        #expect(plan.admission(for: second.id) == .main)
        #expect(plan.spent == DecodeCost(units: 2))
        #expect(plan.spent > budget.total, "the plan reports the truth rather than a comfortable lie")
    }

    /// A recording holding the budget open costs the previews, not itself.
    @Test func previewsPayForARecordingThatWillNotYield() {
        let budget = DecodeBudget(total: DecodeCost(units: 1))
        let recording = request(.visibleTile, order: 0, recording: true, main: .one)
        let preview = request(.visibleTile, order: 1, main: .one, sub: DecodeCost(units: 0.25))

        let plan = budget.plan(for: [recording, preview])

        #expect(plan.admission(for: recording.id) == .main)
        #expect(plan.admission(for: preview.id) == .thumbnail)
    }

    // MARK: - Determinism

    /// Acceptance 6: the same inputs give the same plan, whatever order they arrive in.
    @Test func thePlanDoesNotDependOnTheOrderOfTheInput() {
        let budget = DecodeBudget(total: DecodeCost(units: 2))
        let requests = [
            request(.visibleTile, order: 2, main: .one, sub: DecodeCost(units: 0.25)),
            request(.focusedTile, order: 0, main: .one, sub: DecodeCost(units: 0.25)),
            request(.prewarm, order: 1, main: .one, sub: DecodeCost(units: 0.25)),
        ]

        let forwards = budget.plan(for: requests)
        let backwards = budget.plan(for: requests.reversed())

        #expect(forwards == backwards)
    }

    /// Priority beats the caller's index, and the index breaks ties inside a class.
    @Test func theOrderIsPriorityThenIndex() {
        let budget = DecodeBudget(total: DecodeCost(units: 2))
        let focused = request(.focusedTile, order: 9, main: .one)
        let firstVisible = request(.visibleTile, order: 0, main: .one)
        let secondVisible = request(.visibleTile, order: 1, main: .one)

        let plan = budget.plan(for: [secondVisible, firstVisible, focused])

        #expect(plan.decisions.map(\.id) == [focused.id, firstVisible.id, secondVisible.id])
        #expect(plan.admission(for: secondVisible.id) == .thumbnail, "the last in line pays first")
    }

    /// An empty stage plans nothing and spends nothing.
    @Test func noStreamsSpendNothing() {
        let plan = DecodeBudget(total: DecodeCost(units: 24)).plan(for: [])

        #expect(plan.decisions.isEmpty)
        #expect(plan.spent == .zero)
        #expect(plan.admission(for: CameraID()) == nil)
    }

    /// A budget of nothing puts everything on the JPEG poll and terminates. The degenerate case
    /// exists because a preferences file can hold one, and a policy that looped on it would hang the
    /// app rather than merely disappoint it.
    @Test func aBudgetOfNothingStillTerminates() {
        let requests = (0..<3).map { request(.visibleTile, order: $0) }

        let plan = DecodeBudget(total: .zero).plan(for: requests)

        #expect(plan.decisions.allSatisfy { $0.admission == .thumbnail })
        #expect(plan.spent == .zero)
    }

    // MARK: - The ladder

    /// The demotion ladder is `main → sub → thumbnail → paused` and it ends.
    @Test func theLadderEnds() {
        #expect(DecodeAdmission.main.demoted == .sub)
        #expect(DecodeAdmission.sub.demoted == .thumbnail)
        #expect(DecodeAdmission.thumbnail.demoted == .paused)
        #expect(DecodeAdmission.paused.demoted == nil)
    }

    /// Only two rungs are decoding, which is what the tile's badge and the inspector read.
    @Test func onlyTheTopTwoRungsDecode() {
        #expect(DecodeAdmission.main.isDecoding)
        #expect(DecodeAdmission.sub.isDecoding)
        #expect(DecodeAdmission.thumbnail.isDecoding == false)
        #expect(DecodeAdmission.paused.isDecoding == false)
    }

    /// The priority order is the one F-DEC-06 acceptance 3 lists, and it is the declaration order.
    @Test func priorityRunsFromTheFocusedTileToTheSidebar() {
        #expect(DecodePriority.allCases == [
            .focusedTile, .visibleTile, .wallTile, .pictureInPicture, .recording, .prewarm,
            .thumbnail,
        ])
        #expect(DecodePriority.focusedTile < DecodePriority.thumbnail)
    }
}
