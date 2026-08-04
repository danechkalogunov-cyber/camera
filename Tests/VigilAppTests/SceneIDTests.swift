//
//  SceneIDTests.swift
//  VigilAppTests
//
//  Direct tests for the executable app target's stable scene contract.
//

#if os(macOS)

import Testing
@testable import Vigil

@Test func appSceneIdentifiersRemainStableAndUnique() {
    let identifiers = [SceneID.main, SceneID.playback, SceneID.discovery, SceneID.wall, SceneID.about,
                       SceneID.settings]

    #expect(identifiers == ["main", "playback", "discovery", "wall", "about", "settings"])
    #expect(Set(identifiers).count == identifiers.count)
}

@Test @MainActor func narrowWindowUsesCameraRailInsteadOfDiscardingSidebarIntent() {
    let state = MainWindowState()
    state.isSidebarVisible = true
    state.contentWidth = 699

    #expect(!state.showsSidebar)
    #expect(state.showsSidebarRail)

    state.contentWidth = 700
    #expect(state.showsSidebar)
    #expect(!state.showsSidebarRail)
}

#endif  // os(macOS)
