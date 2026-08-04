//
//  VGridIdleCell.swift
//  VigilUI
//
//  A camera that is on the stage but not streaming: named, addressed, and one click from a picture.
//  macOS-only. The third cell shape of docs/UX.md §5.1, beside the tile and the empty cell.
//
//  ⛔ WHY THIS EXISTS RATHER THAN A NEW `LiveConnectionState` CASE. The obvious way to say "this
//  camera is not running" is to add a case to that enum — and it is the wrong way. `LiveConnectionState`
//  describes *a session*: connecting, live, degraded, offline. A camera nobody has opened a session
//  for has no session to describe, and `.offline` would claim an attempt was made and failed, which
//  is the one thing that must not be said about a device that was never dialled. Adding a case would
//  also have reached eleven exhaustive switches and `VLiveDot.Status` with it, for a state that
//  renders no video and therefore never touches the video path at all.
//
//  ⚠️ It is a *button*, not a placard. UX.md §5.3 gives every populated cell an action; this one's is
//  "show me this camera", and the single-stream build honours it by switching the session. That is
//  also why it draws no video well: there is no picture behind it to preserve, so the black
//  rectangle a tile would show is replaced by something that says what to do.
//

#if os(macOS)

import Foundation
import SwiftUI

import VigilProtocols

// MARK: - VGridIdleCell

/// A stage cell for a camera the app knows about but is not streaming.
@MainActor
package struct VGridIdleCell: View {

    // MARK: - Stored Properties

    /// Name, address and identity colour.
    package let camera: LiveCameraIdentity

    /// Whether the sidebar and inspector are bound to this camera.
    package let isSelected: Bool

    /// Whether this cell has keyboard focus.
    package let isFocused: Bool

    /// Streams this camera. In a one-stream build that stops whatever is playing.
    package let onConnect: () -> Void

    @Environment(\.vMotionEnabled) private var motionEnabled

    @State private var isHovering = false

    // MARK: - Initialisation

    /// Creates an idle cell.
    ///
    /// - Parameters:
    ///   - camera: the camera this cell stands for.
    ///   - isSelected: whether it is the selection everywhere else.
    ///   - isFocused: whether it holds stage focus.
    ///   - onConnect: streams it.
    package init(camera: LiveCameraIdentity,
                 isSelected: Bool = false,
                 isFocused: Bool = false,
                 onConnect: @escaping () -> Void = {}) {
        self.camera = camera
        self.isSelected = isSelected
        self.isFocused = isFocused
        self.onConnect = onConnect
    }

    // MARK: - View

    package var body: some View {
        Button(action: onConnect) {
            VStack(spacing: VTheme.Space.xs) {
                // 22 pt, matching `VGridEmptyCell`'s glyph rather than an `Icon` step: both are the
                // hero of a cell-sized empty state, and the largest token is 15 pt.
                Image(systemName: VTheme.Symbol.camera.name)
                    .font(VTheme.Icon.font(22, weight: VTheme.Icon.Weight.lg))
                    .foregroundStyle(VTheme.Color.Text.tertiary)
                Text(verbatim: camera.name)
                    .vType(VTheme.Typography.body)
                    .foregroundStyle(VTheme.Color.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // The address, because on a wall of similar names it is the thing that tells two
                // lobby cameras apart — and because a cell that cannot show a picture should at
                // least prove it knows which device it means.
                Text(verbatim: camera.host)
                    .vType(VTheme.Typography.monoSmall)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
                    .lineLimit(1)
                // One sentence, tinted rather than swapped on hover. Copy that changes under the
                // pointer reads as a glitch on a wall of sixteen cells, and the accent is already
                // the app's "this is clickable" cue.
                Text("Not connected", bundle: .vigilUI)
                    .vType(VTheme.Typography.caption1)
                    .foregroundStyle(isHovering
                        ? VTheme.Color.Semantic.accent
                        : VTheme.Color.Text.tertiary)
                    .padding(.top, VTheme.Space.hair)
            }
            .padding(VTheme.Space.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // ⛔ `layer.videoWell` and not `layer.canvas`: this cell sits among tiles, and the
            // empty cell's canvas fill is what distinguishes "nothing here" from "something here
            // that is not playing". DESIGN.md §3.6 reserves the well for where a picture belongs.
            .background(VTheme.Color.Layer.videoWell,
                        in: VTheme.Radius.shape(VTheme.Radius.xl))
            .overlay { border }
            .contentShape(VTheme.Radius.shape(VTheme.Radius.xl))
        }
        .buttonStyle(PlainButtonStyle())
        .focusEffectDisabled()
        .onHover { hovering in
            withAnimation(VTheme.Motion.resolved(VTheme.Motion.micro, reduced: !motionEnabled)) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: camera.name))
        .accessibilityValue(Text("Not connected", bundle: .vigilUI))
        .accessibilityHint(Text("Press Return to view this camera", bundle: .vigilUI))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Private Helpers

    /// The focus ring, the selection border, or the tile's ordinary hairline.
    ///
    /// The same ladder `VGridTileView` uses, so an idle cell and a playing one read as members of
    /// one grid rather than as two kinds of object that happen to be adjacent.
    @ViewBuilder
    private var border: some View {
        let shape = VTheme.Radius.shape(VTheme.Radius.xl)
        if isFocused {
            shape.strokeBorder(VTheme.Color.Semantic.focusRing,
                               lineWidth: VTheme.Border.selected)
        } else if isSelected {
            shape.strokeBorder(VTheme.Color.Semantic.accent, lineWidth: VTheme.Border.selected)
        } else {
            shape.strokeBorder(VTheme.Color.Stroke.subtle, lineWidth: VTheme.Border.thin)
        }
    }
}

// MARK: - Previews

#if DEBUG && !VIGIL_NO_PREVIEWS
#Preview("Idle cell") {
    HStack(spacing: 2) {
        VGridIdleCell(camera: LiveCameraIdentity(id: UUID(),
                                                 name: "Garage",
                                                 host: "192.168.1.65"))
        VGridIdleCell(camera: LiveCameraIdentity(id: UUID(),
                                                 name: "Back Yard",
                                                 host: "192.168.1.66"),
                      isSelected: true)
        VGridIdleCell(camera: LiveCameraIdentity(id: UUID(),
                                                 name: "Side Gate",
                                                 host: "192.168.1.67"),
                      isFocused: true)
    }
    .frame(width: 720, height: 220)
    .padding(8)
    .background(VTheme.Color.Layer.canvas)
}
#endif

#endif  // os(macOS)
