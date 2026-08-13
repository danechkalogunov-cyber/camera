//
//  VTileActionBar.swift
//  VigilUI
//
//  The seven buttons UX.md §5.3 puts bottom-trailing on a tile, revealed on hover.
//  macOS-only. Implements docs/UX.md §5.3 (button order, sizes, behaviours) and DESIGN.md §9.13.
//

#if os(macOS)

import Foundation
import SwiftUI

// MARK: - VTileAction

/// One of the seven tile buttons, in the order §5.3 fixes them.
///
/// The order is fixed and the set never changes shape between cameras: a button that this build
/// cannot honour is drawn disabled rather than removed, so a user who learnt where Record sits
/// still finds it there on a camera without PTZ.
package enum VTileAction: String, Sendable, Hashable, CaseIterable, Identifiable {

    /// This camera's audio.
    case mute

    /// Momentary microphone upload to this camera.
    case talk

    /// Save a still.
    case snapshot

    /// Start or stop recording.
    case record

    /// Show the on-video PTZ pad.
    case ptz

    /// Sub ↔ main stream.
    case quality

    /// Aspect fit ↔ fill.
    case fit

    /// Open the archive timeline for this camera.
    ///
    /// ⚠️ An eighth button, where UX.md §5.3 fixes seven. It is here because the timeline needs a
    /// way in from the picture and the plan's own answer — a separate Playback *scene* (§1.2) —
    /// does not exist yet. When that window lands this button becomes the thing that opens it, so
    /// the affordance stays and only its destination changes.
    case timeline

    /// Clear the cell.
    case close

    /// Stable identity.
    package var id: String { rawValue }

    /// The glyph, given the state that changes it.
    ///
    /// - Parameters:
    ///   - isRecording: fills the record button.
    ///   - isMuted: flips the speaker.
    ///   - isFilled: flips the fit/fill arrows.
    package func symbol(isRecording: Bool, isMuted: Bool, isFilled: Bool) -> VTheme.Symbol {
        switch self {
        case .mute:     return isMuted ? .mute : .unmuted
        case .talk:     return .pushToTalk
        case .snapshot: return .snapshot
        case .record:   return isRecording ? .recording : .record
        case .ptz:      return .ptzPad
        case .quality:  return .mainstream
        case .fit:      return isFilled ? .aspectFit : .aspectFill
        case .timeline: return .clock
        case .close:    return .close
        }
    }

    /// What VoiceOver says. Never a glyph name — §10.7 requires a spoken label per control.
    package var accessibilityLabel: LocalizedStringKey {
        switch self {
        case .mute:     return "Mute"
        case .talk:     return "Push to Talk"
        case .snapshot: return "Snapshot"
        case .record:   return "Record"
        case .ptz:      return "PTZ"
        case .quality:  return "Stream quality"
        case .fit:      return "Fit or fill"
        case .timeline: return "Timeline"
        case .close:    return "Close"
        }
    }
}

// MARK: - VTileActions

/// What the tile's buttons do, and which of them can be pressed.
///
/// **A bag of closures, carried in the environment.** The bar has to reach `GridTileView` through
/// `VGridStageView`, and both already take a dozen arguments; threading seven more closures through
/// two long initialisers is seven more chances to get an argument order wrong, for values neither
/// type makes a decision about. `\.vTileActions` puts them in one place.
///
/// Everything defaults to disabled and to a closure that does nothing, so an app wires only what it
/// can honour and the rest is visibly, honestly inert.
package struct VTileActions {

    /// Which buttons can be pressed. Anything absent is drawn dimmed.
    package var enabled: Set<VTileAction> = []

    /// Whether audio is muted, for the speaker glyph.
    package var isMuted = true

    /// Normalized RMS level. It remains visible while muted so sound activity is discoverable.
    package var audioLevel: Float = 0

    /// Whether the picture is filled rather than fitted, for the arrows.
    package var isFilled = false

    /// Momentary talk state and press/release hooks; separate from `perform` because release is an
    /// action with the stronger cleanup guarantee.
    package var isTalking = false
    package var beginTalk: () -> Void = {}
    package var endTalk: () -> Void = {}

    /// Performs one action.
    package var perform: (VTileAction) -> Void = { _ in }

    /// Creates an empty bag: every button present, none of them live.
    package init() {}
}

// MARK: - Environment

/// ⛔ No `@MainActor` here, and it is not an oversight — `Sources/VigilUI/Theme/Environment.swift`
/// records the same rule for its own keys. `EnvironmentKey.defaultValue` is a `nonisolated` static
/// requirement, so a main-actor-isolated property cannot witness it and the conformance fails to
/// compile. A computed `static var` is used rather than a `static let` because ``VTileActions``
/// holds closures and is therefore not `Sendable`; a stored global of a non-`Sendable` type would
/// need `nonisolated(unsafe)` to say the same thing less honestly.
private struct VTileActionsKey: EnvironmentKey {
    static var defaultValue: VTileActions { VTileActions() }
}

extension EnvironmentValues {

    /// The tile's hover buttons. See ``VTileActions``.
    package var vTileActions: VTileActions {
        get { self[VTileActionsKey.self] }
        set { self[VTileActionsKey.self] = newValue }
    }
}

extension View {

    /// Publishes the tile's hover buttons for a subtree.
    @MainActor
    package func vTileActions(_ actions: VTileActions) -> some View {
        environment(\.vTileActions, actions)
    }
}

// MARK: - VTileActionBar

/// The bottom-trailing button row.
///
/// 24 × 24 pt glyphs packed into adjacent hit targets, on the tile's own scrim so the
/// row reads over a bright frame and a dark one alike.
@MainActor
package struct VTileActionBar: View {

    /// Whether this camera is being recorded, which fills the record button red.
    package let isRecording: Bool

    /// What the buttons do.
    package let actions: VTileActions
    @State private var talkPressed = false

    /// Creates the bar.
    package init(isRecording: Bool, actions: VTileActions) {
        self.isRecording = isRecording
        self.actions = actions
    }

    package var body: some View {
        HStack(spacing: VTileActionMetrics.spacing) {
            ForEach(VTileAction.allCases) { action in
                button(action)
            }
        }
        .padding(.horizontal, VTheme.Space.xs)
        .padding(.vertical, VTheme.Space.xxs)
        .background(VTheme.Color.Scrim.base, in: VTheme.Radius.shape(VTheme.Radius.sm))
        .accessibilityElement(children: .contain)
    }

    // MARK: - Private Helpers

    private func button(_ action: VTileAction) -> some View {
        let isEnabled = actions.enabled.contains(action)
        let symbol = action.symbol(isRecording: isRecording,
                                   isMuted: actions.isMuted,
                                   isFilled: actions.isFilled)
        return Button {
            if action != .talk { actions.perform(action) }
        } label: {
            symbol.image()
                .vIcon(size: VTheme.Icon.sm)
                // Record turns red while it is running — the one button whose *state* is the point
                // (§5.3) — and the rest take the fixed on-video ink, so the row reads over a bright
                // frame and over the black letterbox alike.
                .foregroundStyle(tint(for: action, isEnabled: isEnabled))
                .frame(width: VTileActionMetrics.hit, height: VTileActionMetrics.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(action.accessibilityLabel)
        .accessibilityLabel(Text(action.accessibilityLabel, bundle: .vigilUI))
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard action == .talk, isEnabled, !talkPressed else { return }
                    talkPressed = true
                    actions.beginTalk()
                }
                .onEnded { _ in
                    guard action == .talk, talkPressed else { return }
                    talkPressed = false
                    actions.endTalk()
                }
        )
    }

    private func tint(for action: VTileAction, isEnabled: Bool) -> SwiftUI.Color {
        guard isEnabled else { return VTheme.Color.Text.onVideoDim }
        if action == .record, isRecording { return VTheme.Color.Semantic.live }
        if action == .talk, actions.isTalking { return VTheme.Color.Semantic.live }
        return VTheme.Color.Text.onVideo
    }
}

// MARK: - VTileActionMetrics

/// The bar's sizes, from §5.3.
///
/// ⛔ `@MainActor`, because `VTheme.Space` and `VTheme.Metrics` are — every theme namespace is
/// declared that way in `VTheme.swift`. A nonisolated static that reads one does not compile, and
/// the error surfaces only on a Mac: `VigilUI` is never built on Linux.
@MainActor
package enum VTileActionMetrics {

    /// The hit target. The glyph inside it is `Icon.sm`.
    package static let hit: CGFloat = 24

    /// Between buttons.
    package static let spacing: CGFloat = 0

    /// How wide the whole row is, buttons plus gaps plus its own padding.
    ///
    /// Computed rather than written down, so adding a button cannot leave the tile's "does it fit"
    /// test measuring against a stale number.
    package static var width: CGFloat {
        let count = CGFloat(VTileAction.allCases.count)
        return count * hit + (count - 1) * spacing + VTheme.Space.xs * 2
    }
}

#endif  // os(macOS)
