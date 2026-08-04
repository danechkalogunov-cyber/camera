//
//  WindowChromeModesTests.swift
//  VigilAppTests
//
//  The window-state half of the keyboard shortcuts UX.md §11.1 specifies and nothing bound:
//  ⌥⌘L (icon rail), ⌘F (solo a tile), ⌃⌘H (pin the tile controls), ⌥N ⌥S ⌥T ⌥B (the four tile
//  overlays) and ⌥⌘F (the camera-list filter). The bindings themselves live in
//  `MainWindowView+Commands.swift`; what is testable without a window is the state they move, and
//  that is what is here.
//

#if os(macOS)

import Testing
@testable import Vigil
import VigilUI

@Suite("Window chrome modes")
@MainActor
struct WindowChromeModesTests {

    // MARK: - ⌥⌘L, the icon rail

    /// The rail is a preference *and* a consequence of a narrow window, and either is enough.
    @Test func railIsShownWhenTheUserAsksForItAtAnyWidth() {
        let window = MainWindowState()
        window.contentWidth = 1400

        #expect(window.showsSidebar)
        #expect(!window.showsSidebarRail)

        window.prefersSidebarRail = true
        #expect(!window.showsSidebar)
        #expect(window.showsSidebarRail)
    }

    /// ⛔ ⌘L still wins. A rail the user cannot dismiss would be a worse answer to "hide the camera
    /// list" than the hiding it replaced.
    @Test func hidingTheListAlsoHidesTheRail() {
        let window = MainWindowState()
        window.contentWidth = 1400
        window.prefersSidebarRail = true
        window.isSidebarVisible = false

        #expect(!window.showsSidebar)
        #expect(!window.showsSidebarRail)
    }

    /// The narrow-window rule is untouched, and it does not need the preference.
    @Test func aNarrowWindowStillCollapsesToTheRailOnItsOwn() {
        let window = MainWindowState()
        window.contentWidth = MainWindowState.sidebarMinimumWidth - 1

        #expect(!window.showsSidebar)
        #expect(window.showsSidebarRail)
    }

    /// ⚠️ The unmeasured first frame is not "narrow". Treating it as narrow would open every window
    /// with the rail up for one frame.
    @Test func anUnmeasuredWindowShowsTheFullList() {
        let window = MainWindowState()
        #expect(window.contentWidth == 0)
        #expect(window.showsSidebar)
        #expect(!window.showsSidebarRail)
    }

    // MARK: - ⌘F, solo

    /// Solo is a round trip: the layout it replaced comes back.
    @Test func soloRestoresTheLayoutItReplaced() {
        let window = MainWindowState()
        window.chooseLayout(.grid2x2)

        window.toggleSolo()
        #expect(window.isSoloed)
        #expect(window.layout == .single)

        window.toggleSolo()
        #expect(!window.isSoloed)
        #expect(window.layout == .grid2x2)
    }

    /// `Esc` leaves solo and toggling into it again is not required first.
    @Test func escapeLeavesSoloAndIsSafeWhenNotSoloed() {
        let window = MainWindowState()
        window.chooseLayout(.grid3x3)

        window.exitSolo()
        #expect(window.layout == .grid3x3)

        window.toggleSolo()
        window.exitSolo()
        #expect(!window.isSoloed)
        #expect(window.layout == .grid3x3)
    }

    /// ⛔ Choosing a layout by name ends solo, so ⌘F cannot snap back to an arrangement the user has
    /// since replaced.
    @Test func choosingALayoutForgetsWhatSoloWasHolding() {
        let window = MainWindowState()
        window.chooseLayout(.grid2x2)
        window.toggleSolo()

        window.chooseLayout(.grid4x4)
        #expect(!window.isSoloed)

        window.toggleSolo()
        #expect(window.layout == .single)
        window.toggleSolo()
        #expect(window.layout == .grid4x4)
    }

    /// Soloing from `.single` is a no-op in both directions rather than a trap.
    @Test func soloFromSingleIsHarmless() {
        let window = MainWindowState()
        window.chooseLayout(.single)

        window.toggleSolo()
        #expect(window.layout == .single)
        window.toggleSolo()
        #expect(window.layout == .single)
        #expect(!window.isSoloed)
    }

    // MARK: - ⌃⌘H, pinned tile controls

    /// Off by default: chrome over every picture is what UX.md §6.2 spends a paragraph forbidding.
    @Test func tileControlsArePinnedOnlyWhenAsked() {
        let window = MainWindowState()
        #expect(!window.pinsTileControls)
        window.pinsTileControls.toggle()
        #expect(window.pinsTileControls)
    }

    // MARK: - ⌥N ⌥S ⌥T ⌥B, the four overlays

    /// Everything on to begin with: a window that opened with the camera names hidden would look
    /// broken rather than tidy.
    @Test func everyOverlayStartsOn() {
        let window = MainWindowState()
        #expect(window.tileOverlays == .all)
        #expect(window.tileOverlays.contains(.name))
        #expect(window.tileOverlays.contains(.stats))
        #expect(window.tileOverlays.contains(.timestamp))
        #expect(window.tileOverlays.contains(.motion))
    }

    /// ⛔ The point of four switches: turning the stats off leaves the name alone. One flag meant
    /// quieting the diagnostics also removed the label that says which camera you are looking at.
    @Test func togglingOneOverlayLeavesTheOthersAlone() {
        let window = MainWindowState()

        window.tileOverlays.formSymmetricDifference(.stats)
        #expect(!window.tileOverlays.contains(.stats))
        #expect(window.tileOverlays.contains(.name))
        #expect(window.tileOverlays.contains(.timestamp))
        #expect(window.tileOverlays.contains(.motion))

        window.tileOverlays.formSymmetricDifference(.stats)
        #expect(window.tileOverlays == .all)
    }

    /// All four off is a picture and its borders, and is reachable.
    @Test func everyOverlayCanBeTurnedOff() {
        let window = MainWindowState()
        for overlay in [VTileOverlays.name, .stats, .timestamp, .motion] {
            window.tileOverlays.formSymmetricDifference(overlay)
        }
        #expect(window.tileOverlays == .hidden)
        #expect(window.tileOverlays.isEmpty)
    }

    // MARK: - ⌥⌘F, the camera-list filter

    /// The filter starts at "everything", which is the only honest default for a list.
    @Test func theListIsUnfilteredToBeginWith() {
        #expect(MainWindowState().sidebarFilter == .all)
    }
}

#endif  // os(macOS)
