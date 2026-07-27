//
//  VTimelineTrack.swift
//  VigilUI
//
//  The archive scrubber's value layer: what a painted box on the bar stands for, the hatch that
//  carries that meaning without colour, the lane geometry every timeline file measures itself
//  against, and the two values a caller hands in — one camera's track and one local clip.
//  macOS-only. Implements docs/DESIGN.md §9.14 (heatmap encoding), §10.5 (hatching) and
//  docs/UX.md §7.3 (lane anatomy).
//
//  Nothing here draws. Splitting the values out of the views is what lets the record-type-to-colour
//  mapping and the lane heights be asserted by a test that renders nothing.
//

#if os(macOS)

import Foundation
import SwiftUI

import VigilISAPI

// MARK: - VTimelineSegmentKind

/// What a painted box on the bar stands for, and therefore what colour it takes.
///
/// A view-layer enum rather than `RecordType` itself, for three reasons: the bar has two kinds that
/// are not record types at all (``noRecording`` and ``localClip``), the five legend keys of the
/// approved mockup are exactly these five cases, and the mapping from the six wire record types down
/// to three drawn colours is a presentation decision that belongs here rather than in `VigilISAPI`.
package enum VTimelineSegmentKind: Int, Sendable, Hashable, CaseIterable {

    /// Scheduled or operator-initiated recording. `continuous` blue.
    case continuous

    /// A motion recording. `motion` amber.
    case motion

    /// An alarm recording. `live` red.
    case alarm

    /// A clip Vigil itself recorded to disk, drawn on its own 6 pt strip in `accent`.
    case localClip

    /// A stretch with no footage. Not a colour so much as the absence of one — the track's own E0
    /// fill with a dotted baseline, so "nothing was recorded" is visibly different from "not yet
    /// loaded", which shimmers (docs/UX.md §7.3).
    case noRecording

    /// The kind a device record type is drawn as.
    ///
    /// `timing`, `manual`, `command` and `other` all collapse onto ``continuous``. That is
    /// deliberate: DESIGN.md §9.14 names exactly three band colours, and inventing two more for
    /// "the operator pressed record" and "a CGI call started it" would spend the reserved status
    /// vocabulary (§3.1) on a distinction no reviewer is looking for. `other` — an unrecognised
    /// wire value — is drawn as ordinary footage rather than as a fourth colour, because the one
    /// thing it certainly is, is footage.
    package init(_ recordType: RecordType) {
        switch recordType {
        case .alarm: self = .alarm
        case .motion: self = .motion
        case .timing, .manual, .command, .other: self = .continuous
        }
    }

    /// The order the legend prints, which is the mockup's order: the three band colours, then the
    /// absence, then the local strip.
    package static let legendOrder: [VTimelineSegmentKind] =
        [.continuous, .motion, .alarm, .noRecording, .localClip]

    /// The base token. Alpha is applied separately — see ``fillOpacity``.
    ///
    /// `@MainActor` on the member rather than on the enum, so the mapping above stays a plain value
    /// a test can assert without an actor hop, exactly as `VButton.Size.control` does.
    @MainActor
    package var colour: SwiftUI.Color {
        switch self {
        case .continuous: VTheme.Color.Semantic.continuous
        case .motion: VTheme.Color.Semantic.motion
        case .alarm: VTheme.Color.Semantic.live
        case .localClip: VTheme.Color.Semantic.accent
        case .noRecording: VTheme.Color.Layer.surfaceRaised
        }
    }

    /// The alpha DESIGN.md §9.14 gives this kind in the density band.
    ///
    /// The specification writes the band's opacity as `0.55 + 0.45 × coverage`, where coverage is
    /// the recorded fraction of one pixel column. `TimelineBarLayout` deliberately does not expose a
    /// per-column coverage — it emits exact runs and guarantees a 2 pt minimum instead, which is the
    /// stronger property — so the drawn alpha is the per-kind constant from the same table
    /// (continuous 0.55, motion 0.75, alarm 0.90). Severity therefore still reads off the bar at a
    /// glance, which is what the ramp was for.
    package var fillOpacity: Double {
        switch self {
        case .continuous: 0.55
        case .motion: 0.75
        case .alarm: 0.90
        case .localClip: 0.90
        case .noRecording: 1.00
        }
    }

    /// The pattern added under `accessibilityDifferentiateWithoutColor` (DESIGN.md §10.5).
    package var hatch: VTimelineHatch {
        switch self {
        case .motion: .diagonal
        case .alarm: .cross
        case .continuous, .localClip, .noRecording: .none
        }
    }
}

// MARK: - VTimelineHatch

/// The non-colour partner for a band colour (DESIGN.md §10.5).
///
/// Motion is a 45° hatch at a 4 pt pitch and alarm a cross-hatch at 3 pt; continuous is the
/// unhatched baseline, so the three are told apart by geometry alone.
package enum VTimelineHatch: Sendable, Hashable {

    /// No pattern — the continuous baseline.
    case none

    /// 45° lines.
    case diagonal

    /// 45° lines in both directions.
    case cross

    /// The distance between lines, in points. Zero for ``none``, which is what stops the renderer
    /// from looping at all.
    package var pitch: CGFloat {
        switch self {
        case .none: 0
        case .diagonal: 4
        case .cross: 3
        }
    }
}

// MARK: - VTimelineMetrics

/// The archive timeline's own geometry.
///
/// `VTheme` publishes the two numbers DESIGN.md §5.1 gives the component as a whole
/// (``VTheme/Metrics/timelineHeight`` and ``VTheme/Metrics/timelineLaneHeight``) but not the band
/// heights inside a lane, which live in §9.14 and UX.md §7.3. This namespace is where those live,
/// exactly once, each derived from a spacing token where one is an exact match and each carrying
/// the clause it comes from where it is not — the same arrangement `VChip.height`,
/// `VIdentityMark.dotSize` and `VSkeleton.travel` already use for their own component's dimensions.
@MainActor
package enum VTimelineMetrics {

    /// The ruler band: one `MonoSmall` line box for the labels above a 6 pt major tick.
    ///
    /// DESIGN.md §9.14 says 16 pt. 16 does not fit a 13 pt line box and a 6 pt tick without the
    /// label sitting on the tick, so the band is the sum of the two things it actually contains.
    package static let ruler: CGFloat = VTheme.Typography.monoSmall.lineHeight + VTheme.Space.xs

    /// The lane's own label row (UX.md §7.3: 12 pt).
    package static let laneLabel: CGFloat = VTheme.Space.md

    /// The density band of the first camera's lane (UX.md §7.3: 28 pt).
    package static let band: CGFloat = VTheme.Metrics.md

    /// The density band of every camera after the first (UX.md §7.3: 20 pt).
    package static let compactBand: CGFloat = VTheme.Metrics.xs

    /// The local-clip strip (UX.md §7.3: 6 pt).
    package static let clipLane: CGFloat = VTheme.Space.xs

    /// The event-marker row (UX.md §7.3: 12 pt).
    package static let markerRow: CGFloat = VTheme.Space.md

    /// A labelled tick: 1 × 6 pt (DESIGN.md §9.14).
    package static let majorTick: CGFloat = VTheme.Space.xs

    /// An unlabelled tick: 1 × 3 pt (DESIGN.md §9.14).
    package static let minorTick: CGFloat = VTheme.Space.hair + VTheme.Border.thin

    /// A marker diamond's side (UX.md §7.3: 6 pt), matching the identity dot so a lane's marks and
    /// its header dot sit on the same optical row.
    package static let markerGlyph: CGFloat = VIdentityMark.dotSize

    /// The grab width of a marker: 12 pt, per DESIGN.md §10.6's "timeline handles 4 pt visual,
    /// 12 pt grab area". Wider would make two adjacent clusters fight for the same pointer.
    package static let markerGrab: CGFloat = VTheme.Space.md

    /// The playhead's drawn width (UX.md §7.3: 2 pt).
    package static let playhead: CGFloat = VTheme.Border.selected

    /// The timecode bubble above the playhead (UX.md §7.3 asks for a 22 pt rounded label; the 20 pt
    /// `xs` control height is the token that carries a `MonoSmall` line box and is used instead).
    package static let bubble: CGFloat = VTheme.Metrics.xs

    /// The scrub preview card (UX.md §7.3: 176 pt wide, a 160 × 90 thumbnail inside it).
    package static let previewWidth: CGFloat = 176

    /// See ``previewWidth``.
    package static let previewThumbnailHeight: CGFloat = 90

    /// How far above the pointer the preview card floats (UX.md §7.3: 12 pt).
    package static let previewGap: CGFloat = VTheme.Space.md

    /// The legend swatch, matching ``VIdentityMark/glyphBox`` so the legend and a lane header line
    /// up on the same 9 pt optical row.
    package static let legendSwatch: CGFloat = VIdentityMark.glyphBox

    /// The bar the disabled state shows in place of the band (DESIGN.md §9.14: 4 pt).
    package static let emptyBar: CGFloat = VTheme.Space.xxs
}

// MARK: - VTimelineLocalClip

/// A clip Vigil recorded to local disk, drawn on the lane's own 6 pt strip.
///
/// A view-layer value rather than a `VigilCore` model: the strip needs a span, an identity and a
/// name for VoiceOver and nothing else, and keeping it to those three means the timeline can be
/// previewed and tested without the clip store.
package struct VTimelineLocalClip: Identifiable, Sendable, Hashable {

    /// The clip's own identity.
    package let id: UUID

    /// When recording started.
    package let start: Date

    /// When it stopped. Clamped to be no earlier than ``start``.
    package let end: Date

    /// The file's display name, for VoiceOver.
    package let title: String

    /// Creates a clip. An `end` before `start` is clamped up, so no negative-width box can reach
    /// the renderer.
    package init(id: UUID, start: Date, end: Date, title: String) {
        self.id = id
        self.start = start
        self.end = max(start, end)
        self.title = title
    }
}

// MARK: - VTimelineTrack

/// Everything one camera contributes to the scrubber.
///
/// Not `Equatable`: it carries a ``TimelineSegmentIndex``, which holds the day's segments and is
/// deliberately only `Sendable` — comparing a few thousand segments on every body evaluation would
/// cost more than the redraw it was meant to avoid.
package struct VTimelineTrack: Identifiable, Sendable {

    /// The camera's id, which is also the lane's `ForEach` identity.
    package let id: UUID

    /// The camera's name, shown in the lane header and spoken before the timeline's value.
    package let name: String

    /// The camera's identity-colour index (DESIGN.md §3.4), resolved through
    /// ``VTheme/Color/Ident/colour(at:)``. Stored as an index so this value needs no main actor.
    package let identityIndex: Int

    /// The day's footage, already clipped to the day and gapped.
    package let index: TimelineSegmentIndex

    /// The event and bookmark markers for this camera, in any order.
    package let markers: [TimelineMarker]

    /// Vigil's own clips for this camera, in any order.
    package let localClips: [VTimelineLocalClip]

    /// Creates a track.
    package init(id: UUID,
                 name: String,
                 identityIndex: Int,
                 index: TimelineSegmentIndex,
                 markers: [TimelineMarker] = [],
                 localClips: [VTimelineLocalClip] = []) {
        self.id = id
        self.name = name
        self.identityIndex = identityIndex
        self.index = index
        self.markers = markers
        self.localClips = localClips
    }
}

#endif  // os(macOS)
