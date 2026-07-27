//
//  VCommandPaletteTests.swift
//  VigilUITests
//
//  The two pure halves of the ⌘K slice: the palette's ranking and the cycle's rotation. Both are
//  things a user notices immediately and a screenshot cannot check — "why is that command not
//  first", "why did the wall skip a page", "why did pausing not pause".
//  Covers Sources/VigilUI/Palette/VCommand.swift and Sources/VigilUI/Palette/VCycleModel.swift;
//  see docs/UX.md §3.2 and §4.4.
//

#if os(macOS)

import Foundation
import Testing

@testable import VigilUI

// MARK: - Helpers

private func paletteCommand(_ id: String,
                            _ title: String,
                            subtitle: String? = nil,
                            shortcut: String? = nil,
                            category: VCommandCategory = .view,
                            enabled: Bool = true) -> VCommand {
    VCommand(id: id,
             title: title,
             subtitle: subtitle,
             shortcut: shortcut,
             category: category,
             isEnabled: enabled)
}

/// The score one query earns against one title, read back through the public ranking so the test
/// exercises the same path the palette does.
private func paletteScore(_ query: String, _ title: String) -> Int? {
    VCommandQuery(query).match(paletteCommand("id", title))?.score
}

// MARK: - The scoring ladder

@Test("An exact title match scores the top of the ladder")
func paletteExactTitleScoresTop() {
    #expect(paletteScore("cycle", "Cycle") == 1000)
}

@Test("A prefix beats a mid-string match, which beats a scattered one")
func paletteLadderIsOrdered() {
    // "Recording" is a prefix hit; "Start Recording" is contiguous but offset; "Rich Corner Dock"
    // only matches as a subsequence.
    let prefix = paletteScore("rec", "Recording")
    let contiguous = paletteScore("rec", "Start Recording")
    let scattered = paletteScore("rec", "Rich Corner Dock")
    #expect(prefix == 894)
    #expect(contiguous == 794)
    #expect(scattered != nil)
    if let prefix, let contiguous, let scattered {
        #expect(prefix > contiguous)
        #expect(contiguous > scattered)
    }
}

@Test("A query that is not even a subsequence does not match")
func paletteNonSubsequenceDoesNotMatch() {
    #expect(paletteScore("zzzz", "Start Recording") == nil)
    #expect(paletteScore("gnidrocer", "Start Recording") == nil)
}

@Test("A query longer than the title cannot match it")
func paletteOverlongQueryDoesNotMatch() {
    #expect(paletteScore("recording everything", "Recording") == nil)
}

@Test("The tier penalties are capped, so a long title never falls out of its tier")
func paletteTierPenaltiesAreCapped() {
    let long = String(repeating: "a", count: 400) + "rec"
    // A contiguous hit 400 characters in is still a contiguous hit: 800 − 99, never below 701.
    let score = paletteScore("rec", long)
    #expect(score == 701)
}

// MARK: - Subtitles

@Test("A subtitle match is found, but never outranks any title match")
func paletteSubtitleNeverOutranksTitle() {
    let query = VCommandQuery("floor")
    let onSubtitle = paletteCommand("a", "Take Snapshot", subtitle: "Ground Floor")
    let onTitle = paletteCommand("b", "Floor Plan Overlay")
    #expect(query.match(onSubtitle)?.score == VCommandQuery.subtitleScore)
    // 401 is the worst score any title match can earn (500 − the 99 cap), so 400 is below all
    // of them by construction rather than by luck.
    #expect(VCommandQuery.subtitleScore < 500 - 99)
    let ranked = query.rank([onSubtitle, onTitle])
    #expect(ranked.map(\.id) == ["b", "a"])
}

@Test("A subtitle is matched contiguously only, never as a scattered subsequence")
func paletteSubtitleIsContiguousOnly() {
    let query = VCommandQuery("gfl")
    let command = paletteCommand("a", "Take Snapshot", subtitle: "Ground Floor")
    #expect(query.match(command) == nil)
}

@Test("A subtitle match carries no title highlight")
func paletteSubtitleCarriesNoHighlight() {
    let query = VCommandQuery("floor")
    let command = paletteCommand("a", "Take Snapshot", subtitle: "Ground Floor")
    #expect(query.match(command)?.titleOffsets.isEmpty == true)
    #expect(query.match(command)?.canHighlight == false)
}

// MARK: - Folding

@Test("Matching is case-insensitive")
func paletteFoldsCase() {
    #expect(paletteScore("CYCLE", "cycle") == 1000)
    #expect(paletteScore("cycle", "CYCLE") == 1000)
}

@Test("Matching is diacritic-insensitive")
func paletteFoldsDiacritics() {
    #expect(paletteScore("cafe", "Café") == 1000)
    #expect(paletteScore("café", "Cafe") == 1000)
    #expect(paletteScore("cafe", "Café Camera") != nil)
}

@Test("Cyrillic folds the way the sidebar's own example does")
func paletteFoldsCyrillic() {
    #expect(paletteScore("вход", "Вход") == 1000)
    #expect(paletteScore("ВХОД", "вход") == 1000)
}

@Test("The palette folds through the sidebar's function, so the two cannot drift")
func paletteFoldingIsTheSidebarFolding() {
    for sample in ["Вход", "Café", "STREET", "Ünter Straße", "no diacritics here"] {
        #expect(VCommandQuery.fold(sample) == VSidebarSearch.fold(sample))
    }
}

@Test("Highlight offsets are refused when folding changed the title's length")
func paletteHighlightIsRefusedWhenLengthsDiffer() {
    // A folded title of the same length may be highlighted; the guard is the length comparison,
    // so the same-length case must still say yes or the property is useless.
    let query = VCommandQuery("cafe")
    let match = query.match(paletteCommand("a", "Café Camera"))
    #expect(match?.canHighlight == true)
    #expect(match?.titleOffsets == [0, 1, 2, 3])
}

@Test("Leading and trailing whitespace is trimmed off the query")
func paletteTrimsQueryWhitespace() {
    let query = VCommandQuery("   cycle \n ")
    #expect(query.query == "cycle")
    #expect(query.hasQuery)
    #expect(query.match(paletteCommand("a", "Cycle"))?.score == 1000)
}

@Test("A whitespace-only query is no query at all")
func paletteWhitespaceOnlyQueryIsEmpty() {
    #expect(VCommandQuery("    ").hasQuery == false)
    #expect(VCommandQuery("").hasQuery == false)
}

// MARK: - Ranking

@Test("With no query every command survives, in catalogue order")
func paletteEmptyQueryKeepsCatalogueOrder() {
    let catalogue = [
        paletteCommand("a", "Alpha"),
        paletteCommand("b", "Bravo"),
        paletteCommand("c", "Charlie"),
    ]
    let ranked = VCommandQuery("").rank(catalogue)
    #expect(ranked.map(\.id) == ["a", "b", "c"])
    #expect(ranked.allSatisfy { $0.score == 0 })
}

@Test("Commands that do not match are dropped")
func paletteRankDropsNonMatches() {
    let catalogue = [paletteCommand("a", "Recording"), paletteCommand("b", "Sidebar")]
    #expect(VCommandQuery("rec").rank(catalogue).map(\.id) == ["a"])
    #expect(VCommandQuery("zzzz").rank(catalogue).isEmpty)
}

@Test("The sort is stable: equal scores keep their catalogue order")
func paletteRankIsStable() {
    // Four identical titles in one category — every key but the catalogue index ties.
    let catalogue = (0..<4).map { paletteCommand("c\($0)", "Recording") }
    #expect(VCommandQuery("rec").rank(catalogue).map(\.id) == ["c0", "c1", "c2", "c3"])
}

@Test("Equal scores in different categories break by category, not by hash order")
func paletteRankBreaksTiesByCategory() {
    let catalogue = [
        paletteCommand("app", "Recording", category: .application),
        paletteCommand("cam", "Recording", category: .camera),
        paletteCommand("lay", "Recording", category: .layout),
    ]
    #expect(VCommandQuery("rec").rank(catalogue).map(\.id) == ["lay", "cam", "app"])
}

// MARK: - Disabled commands

@Test("A disabled command never ranks first, even on an exact match")
func paletteDisabledNeverRanksFirst() {
    let catalogue = [
        paletteCommand("off", "Cycle", enabled: false),
        paletteCommand("on", "Cycle Cameras Slowly"),
    ]
    let ranked = VCommandQuery("cycle").rank(catalogue)
    // "Cycle" scores 1000 and "Cycle Cameras Slowly" only 900 − 15, yet the enabled one leads.
    #expect(ranked.map(\.id) == ["on", "off"])
    #expect(ranked.first?.command.isEnabled == true)
}

@Test("A wholly disabled catalogue still ranks, it simply has no runnable first row")
func paletteAllDisabledStillRanks() {
    let catalogue = [
        paletteCommand("a", "Recording", enabled: false),
        paletteCommand("b", "Rec Now", enabled: false),
    ]
    let ranked = VCommandQuery("rec").rank(catalogue)
    #expect(ranked.count == 2)
    #expect(VCommandQuery.firstSelectable(in: ranked) == nil)
}

@Test("Disabled commands sink below every enabled one regardless of category")
func paletteDisabledSinkBelowEnabled() {
    let catalogue = [
        paletteCommand("d", "Recording", category: .layout, enabled: false),
        paletteCommand("e", "Recording", category: .application),
    ]
    #expect(VCommandQuery("rec").rank(catalogue).map(\.id) == ["e", "d"])
}

// MARK: - Grouping

@Test("Sections come out in the order their best member ranked")
func paletteGroupsLeadWithGlobalBest() {
    let catalogue = [
        paletteCommand("lay", "Recording Layout", category: .layout),
        paletteCommand("app", "Rec", category: .application),
    ]
    let query = VCommandQuery("rec")
    let groups = query.groups(catalogue)
    // `.layout` sorts before `.application` as a category, but its best member scored worse.
    #expect(groups.map(\.category) == [.application, .layout])
    #expect(VCommandQuery.flattened(groups).map(\.id) == ["app", "lay"])
}

@Test("Flattening the sections reproduces the ranking's first row")
func paletteFlattenedLeadsWithTheTopMatch() {
    let catalogue = [
        paletteCommand("lay", "Recording Layout", category: .layout),
        paletteCommand("app", "Rec", category: .application),
        paletteCommand("cam", "Reconnect", category: .camera),
    ]
    let query = VCommandQuery("rec")
    let flattened = VCommandQuery.flattened(query.groups(catalogue))
    #expect(flattened.first?.id == query.rank(catalogue).first?.id)
    #expect(flattened.count == query.rank(catalogue).count)
}

@Test("No empty section is ever emitted")
func paletteGroupsSkipEmptySections() {
    let catalogue = [
        paletteCommand("a", "Recording", category: .recording),
        paletteCommand("b", "Sidebar", category: .view),
    ]
    let groups = VCommandQuery("rec").groups(catalogue)
    #expect(groups.count == 1)
    #expect(groups.allSatisfy { !$0.matches.isEmpty })
}

// MARK: - Selection

private func paletteRows() -> [VCommandMatch] {
    VCommandQuery("").rank([
        paletteCommand("a", "Alpha"),
        paletteCommand("b", "Bravo", enabled: false),
        paletteCommand("c", "Charlie"),
    ])
}

@Test("Down from nothing selects the first enabled row; up selects the last")
func paletteSelectionFromNothing() {
    let rows = paletteRows()
    #expect(VCommandQuery.selection(movingBy: 1, from: nil, in: rows) == "a")
    #expect(VCommandQuery.selection(movingBy: -1, from: nil, in: rows) == "c")
}

@Test("Arrow keys skip disabled rows and wrap at both ends")
func paletteSelectionSkipsDisabledAndWraps() {
    let rows = paletteRows()
    #expect(VCommandQuery.selection(movingBy: 1, from: "a", in: rows) == "c")
    #expect(VCommandQuery.selection(movingBy: 1, from: "c", in: rows) == "a")
    #expect(VCommandQuery.selection(movingBy: -1, from: "a", in: rows) == "c")
    #expect(VCommandQuery.selection(movingBy: -1, from: "c", in: rows) == "a")
}

@Test("A selection that has fallen out of the list restarts from the end it came from")
func paletteSelectionRecoversFromAStaleID() {
    let rows = paletteRows()
    #expect(VCommandQuery.selection(movingBy: 1, from: "gone", in: rows) == "a")
    #expect(VCommandQuery.selection(movingBy: -1, from: "gone", in: rows) == "c")
    // A disabled row is never selectable, so pointing at one is the same as pointing at nothing.
    #expect(VCommandQuery.selection(movingBy: 1, from: "b", in: rows) == "a")
}

@Test("Selection is nil when nothing can be selected")
func paletteSelectionIsNilWhenNothingIsSelectable() {
    #expect(VCommandQuery.selection(movingBy: 1, from: nil, in: []) == nil)
    let allDisabled = VCommandQuery("").rank([paletteCommand("a", "Alpha", enabled: false)])
    #expect(VCommandQuery.selection(movingBy: 1, from: nil, in: allDisabled) == nil)
    #expect(VCommandQuery.firstSelectable(in: allDisabled) == nil)
}

@Test("Return runs the selected row, and refuses a disabled or missing one")
func paletteRunnableRefusesDisabledRows() {
    let rows = paletteRows()
    #expect(VCommandQuery.runnable("a", in: rows)?.id == "a")
    #expect(VCommandQuery.runnable("b", in: rows) == nil)
    #expect(VCommandQuery.runnable("gone", in: rows) == nil)
    #expect(VCommandQuery.runnable(nil, in: rows) == nil)
}

// MARK: - Cycle: pages per layout

@Test("A page is one screenful, so the page count follows the layout's tile count")
func paletteCyclePageCountFollowsLayout() {
    let cycle = VCycleModel()
    #expect(cycle.pageCount(cameraCount: 16, layout: .single) == 16)
    #expect(cycle.pageCount(cameraCount: 16, layout: .grid2x2) == 4)
    #expect(cycle.pageCount(cameraCount: 16, layout: .hero1p5) == 3)
    #expect(cycle.pageCount(cameraCount: 16, layout: .grid3x3) == 2)
    #expect(cycle.pageCount(cameraCount: 16, layout: .grid4x4) == 1)
}

@Test("An uneven division rounds up, and an empty stage is still one page")
func paletteCyclePageCountRoundsUp() {
    let cycle = VCycleModel()
    #expect(cycle.pageCount(cameraCount: 10, layout: .grid3x3) == 2)
    #expect(cycle.pageCount(cameraCount: 9, layout: .grid3x3) == 1)
    #expect(cycle.pageCount(cameraCount: 0, layout: .grid3x3) == 1)
    #expect(cycle.pageCount(cameraCount: -5, layout: .grid3x3) == 1)
}

@Test("Cycling is only offered when there is more than one page")
func paletteCycleIsOfferedOnlyWhenItWouldDoSomething() {
    let cycle = VCycleModel()
    #expect(cycle.canCycle(cameraCount: 16, layout: .grid3x3))
    #expect(cycle.canCycle(cameraCount: 9, layout: .grid3x3) == false)
    #expect(cycle.canCycle(cameraCount: 4, layout: .grid2x2) == false)
}

@Test("The visible range is clipped, so the final short page is short and not out of bounds")
func paletteCycleVisibleRangeClipsTheFinalPage() {
    let cycle = VCycleModel(isRunning: true)
    #expect(cycle.visibleRange(cameraCount: 16, layout: .grid3x3) == 0..<9)
    let second = cycle.next(cameraCount: 16, layout: .grid3x3)
    #expect(second.page == 1)
    #expect(second.visibleRange(cameraCount: 16, layout: .grid3x3) == 9..<16)
    #expect(cycle.visibleRange(cameraCount: 0, layout: .grid3x3) == 0..<0)
}

// MARK: - Cycle: rotation

@Test("Forward walks the pages and wraps, per layout")
func paletteCycleForwardWrapsPerLayout() {
    var cycle = VCycleModel(order: .forward, isRunning: true)
    var pages: [Int] = [cycle.page]
    for _ in 0..<4 {
        cycle = cycle.next(cameraCount: 16, layout: .hero1p5)  // three pages of six
        pages.append(cycle.page)
    }
    #expect(pages == [0, 1, 2, 0, 1])
}

@Test("Backward walks the same pages the other way")
func paletteCycleBackwardWraps() {
    var cycle = VCycleModel(order: .backward, isRunning: true)
    var pages: [Int] = [cycle.page]
    for _ in 0..<4 {
        cycle = cycle.next(cameraCount: 16, layout: .hero1p5)
        pages.append(cycle.page)
    }
    #expect(pages == [0, 2, 1, 0, 2])
}

@Test("Ping-pong turns at both ends rather than jumping")
func paletteCyclePingPongTurnsAtBothEnds() {
    var cycle = VCycleModel(order: .pingPong, isRunning: true)
    var pages: [Int] = [cycle.page]
    for _ in 0..<6 {
        cycle = cycle.next(cameraCount: 16, layout: .hero1p5)
        pages.append(cycle.page)
    }
    #expect(pages == [0, 1, 2, 1, 0, 1, 2])
}

@Test("Ping-pong over exactly two pages alternates")
func paletteCyclePingPongOverTwoPages() {
    var cycle = VCycleModel(order: .pingPong, isRunning: true)
    var pages: [Int] = [cycle.page]
    for _ in 0..<4 {
        cycle = cycle.next(cameraCount: 16, layout: .grid3x3)  // two pages of nine
        pages.append(cycle.page)
    }
    #expect(pages == [0, 1, 0, 1, 0])
}

@Test("A single page never moves, whatever the order")
func paletteCycleSinglePageNeverMoves() {
    for order in VCycleOrder.allCases {
        let cycle = VCycleModel(order: order, isRunning: true)
        let moved = cycle.next(cameraCount: 4, layout: .grid2x2)
        #expect(moved.page == 0)
        #expect(moved.isReversing == false)
    }
}

@Test("Changing the order resets the ping-pong direction")
func paletteCycleOrderChangeResetsDirection() {
    var cycle = VCycleModel(order: .pingPong, isRunning: true)
    for _ in 0..<3 { cycle = cycle.next(cameraCount: 16, layout: .hero1p5) }
    #expect(cycle.isReversing)
    #expect(cycle.withOrder(.forward).isReversing == false)
    #expect(cycle.withOrder(.forward).order == .forward)
}

// MARK: - Cycle: pause and resume

@Test("A paused cycle does not advance")
func paletteCyclePausedDoesNotAdvance() {
    let running = VCycleModel(isRunning: true)
    let paused = running.paused()
    #expect(paused.isPaused)
    #expect(paused.isTicking == false)
    #expect(paused.next(cameraCount: 16, layout: .grid3x3) == paused)
}

@Test("Resuming advances again from where it stopped")
func paletteCycleResumeAdvancesFromWhereItStopped() {
    let running = VCycleModel(isRunning: true)
    let moved = running.next(cameraCount: 16, layout: .hero1p5)
    #expect(moved.page == 1)
    let held = moved.paused()
    #expect(held.next(cameraCount: 16, layout: .hero1p5).page == 1)
    let resumed = held.resumed()
    #expect(resumed.isTicking)
    #expect(resumed.page == 1)
    #expect(resumed.next(cameraCount: 16, layout: .hero1p5).page == 2)
}

@Test("A stopped cycle does not advance and cannot be armed by a pause")
func paletteCycleStoppedDoesNotAdvance() {
    let stopped = VCycleModel(isRunning: false)
    #expect(stopped.isTicking == false)
    #expect(stopped.next(cameraCount: 16, layout: .grid3x3) == stopped)
    // Hovering a still stage must not leave a pause behind that suppresses the next start.
    #expect(stopped.paused() == stopped)
    #expect(stopped.paused().isPaused == false)
}

@Test("The one-flag pause drives both directions")
func paletteCyclePauseFlagDrivesBothWays() {
    let running = VCycleModel(isRunning: true)
    #expect(running.paused(true).isPaused)
    #expect(running.paused(true).paused(false).isPaused == false)
    #expect(running.paused(false).isTicking)
}

@Test("Starting resets to the first page; stopping clears the pause")
func paletteCycleStartResetsAndStopClears() {
    var cycle = VCycleModel(isRunning: true)
    cycle = cycle.next(cameraCount: 16, layout: .single)
    #expect(cycle.page == 1)
    let restarted = cycle.paused().started()
    #expect(restarted.page == 0)
    #expect(restarted.isPaused == false)
    #expect(restarted.isRunning)
    let stopped = cycle.paused().stopped()
    #expect(stopped.isRunning == false)
    #expect(stopped.isPaused == false)
}

@Test("The toolbar's Cycle button toggles running")
func paletteCycleToggleFollowsTheButton() {
    let off = VCycleModel()
    #expect(off.toggledRunning().isRunning)
    #expect(off.toggledRunning().toggledRunning().isRunning == false)
}

// MARK: - Cycle: settings and retargeting

@Test("The dwell is clamped, and a non-finite dwell falls back to the default")
func paletteCycleIntervalIsClamped() {
    #expect(VCycleModel(interval: 0.5).interval == VCycleModel.minimumInterval)
    #expect(VCycleModel(interval: 10_000).interval == VCycleModel.maximumInterval)
    #expect(VCycleModel(interval: .nan).interval == VCycleModel.defaultInterval)
    #expect(VCycleModel(interval: .infinity).interval == VCycleModel.defaultInterval)
    #expect(VCycleModel().withInterval(30).interval == 30)
    #expect(VCycleModel.intervals.allSatisfy { VCycleModel.clamp($0) == $0 })
}

@Test("A negative page is floored rather than carried")
func paletteCyclePageIsFloored() {
    #expect(VCycleModel(page: -3).page == 0)
}

@Test("Retargeting pulls a stranded page back inside the new grid")
func paletteCycleRetargetClampsTheStrandedPage() {
    // Fifteen pages at `single`, then the operator switches to 3 × 3, which has two.
    let cycle = VCycleModel(isRunning: true, page: 15)
    let retargeted = cycle.retargeted(cameraCount: 16, layout: .grid3x3)
    #expect(retargeted.page == 1)
    #expect(retargeted.isReversing == false)
    // Widening the grid leaves a valid page exactly where it was.
    #expect(retargeted.retargeted(cameraCount: 16, layout: .single).page == 1)
}

@Test("Retargeting a page that is already valid changes nothing at all")
func paletteCycleRetargetIsIdentityWhenValid() {
    let cycle = VCycleModel(isRunning: true, page: 1)
    #expect(cycle.retargeted(cameraCount: 16, layout: .grid3x3) == cycle)
}

#endif  // os(macOS)
