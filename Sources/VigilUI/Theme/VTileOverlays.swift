//
//  VTileOverlays.swift
//  VigilUI
//
//  Which pieces of chrome are drawn over a picture, as four independent switches.
//  macOS-only. Implements docs/UX.md §11.1 — View ▸ Tile Overlays ▸ (Camera Name ⌥N, Stats ⌥S,
//  Timestamp ⌥T, Motion Boxes ⌥B).
//
//  ⛔ FOUR SWITCHES, NOT ONE, AND THE ONE WAS THE BUG. `vShowsVideoOverlay` gated the name chip, the
//  status chip, the stats readout and the recording timecode together, so the only thing a user
//  could say was "all of it" or "none of it". §11.1 gives each its own key because they are wanted
//  in different combinations: the stats readout is for diagnosing a stream and is noise the rest of
//  the time, while the name chip is what tells you which camera you are looking at on a wall of
//  nine — turning the second off to quiet the first is the trade nobody wants to make.
//
//  ⚠️ THE FAILURE OVERLAYS ARE NOT IN HERE, deliberately, and neither is the recording border. An
//  offline card, a degraded banner and the red border report facts about the system rather than
//  decorate the picture; a user who hid the chrome has not asked to stop being told that the camera
//  is gone or that a clip is being written. That rule predates this type and survives it.
//

#if os(macOS)

import SwiftUI

// MARK: - VTileOverlays

/// The chrome drawn over a tile's picture, one bit per piece.
///
/// An `OptionSet` rather than four `Bool`s so it travels as one environment value and one stored
/// preference: four separate keys would be four places to forget when a fifth overlay arrives.
package struct VTileOverlays: OptionSet, Sendable, Hashable, Codable {

    package let rawValue: Int

    package init(rawValue: Int) { self.rawValue = rawValue }

    /// The camera's name, bottom-leading. ⌥N.
    package static let name = VTileOverlays(rawValue: 1 << 0)

    /// Codec, resolution, frame rate and the hardware-decode bolt, top-trailing. ⌥S.
    package static let stats = VTileOverlays(rawValue: 1 << 1)

    /// The recording timecode. ⌥T.
    package static let timestamp = VTileOverlays(rawValue: 1 << 2)

    /// Motion rectangles drawn by the renderer over the frame. ⌥B.
    ///
    /// ⚠️ Nothing feeds these yet — `TileRenderOptions.motionZones` is fed an empty array by the
    /// app, so this switch currently hides nothing. It is here rather than left out because the
    /// menu item exists in §11.1 and because the alternative is a fifth place to remember when the
    /// event feed starts publishing zones. A switch over an empty set is honest; a missing switch
    /// over a live one is not.
    package static let motion = VTileOverlays(rawValue: 1 << 3)

    /// Everything, which is what a tile shows until the user says otherwise.
    package static let all: VTileOverlays = [.name, .stats, .timestamp, .motion]

    /// The state ⌥N ⌥S ⌥T ⌥B all-off leaves: a picture and its borders.
    ///
    /// ⚠️ Not called `none`. A static member of that name on a non-optional type is legal and is a
    /// well-worn way to confuse a reader — and, in a generic context, the compiler — with
    /// `Optional.none`.
    package static let hidden: VTileOverlays = []
}

// MARK: - Environment

private struct VTileOverlaysKey: EnvironmentKey {
    static let defaultValue: VTileOverlays = .all
}

package extension EnvironmentValues {

    /// Which overlays this subtree draws.
    ///
    /// An environment value for the same reason ``vShowsVideoOverlay`` is one: it has to reach
    /// `LiveVideoView` and `GridTileView` through `VGridStageView`, and threading it through three
    /// initialisers means three argument orders to keep right for a value none of them decides.
    var vTileOverlays: VTileOverlays {
        get { self[VTileOverlaysKey.self] }
        set { self[VTileOverlaysKey.self] = newValue }
    }
}

package extension View {

    /// Chooses the overlays drawn over the pictures in this subtree.
    @MainActor
    func vTileOverlays(_ overlays: VTileOverlays) -> some View {
        environment(\.vTileOverlays, overlays)
    }
}

#endif  // os(macOS)
