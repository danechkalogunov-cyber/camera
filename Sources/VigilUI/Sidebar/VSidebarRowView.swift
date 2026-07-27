//
//  VSidebarRowView.swift
//  VigilUI
//
//  One sidebar row in each of the shapes ``VSidebarRowKind`` can take, and the pure helpers the
//  rows are drawn from: the status → dot mapping, the search-highlight runs, the identity colour,
//  the motion spark's buckets and the footer's bitrate scaling. Split out of VSidebarView.swift
//  for length only; nothing here is used outside the sidebar.
//  macOS-only. Implements docs/DESIGN.md §9.12 (row anatomy and state table), §3.4 (identity
//  palette), §10.5 (colour is never the only cue) and docs/UX.md §4.2, §4.3, §3.3.
//

#if os(macOS)

import Foundation

import AppKit
import SwiftUI

import VigilProtocols

// MARK: - VSidebarMetrics

/// The sidebar's own geometry — the numbers DESIGN.md §9.12 and UX.md §4.2 give for this one
/// component, which are not steps on any token ladder and so cannot live in `VTheme`.
///
/// A separate namespace rather than constants on the row views, because both the rows and the panel
/// need them and because `VSidebarRowView` is generic: Swift rejects a stored `static let` inside a
/// generic type, and that mistake is invisible on Linux (see `Scripts/lint.py`).
@MainActor
package enum VSidebarMetrics {

    /// 3 pt. The identity rail on a camera row's leading edge (UX.md §4.2).
    ///
    /// DESIGN.md §9.12 draws it 2 pt; UX.md §4.2 and the approved mockup both draw it 3 pt, so the
    /// two agreeing sources win.
    package static let railWidth: CGFloat = 3

    /// 30 pt. The rail's height inside a 44 pt row, leaving 7 pt clear top and bottom.
    package static let railHeight: CGFloat = 30

    /// 6 pt. The gap between the rail and the thumbnail, so the thumbnail starts 9 pt in.
    package static let railGap: CGFloat = VTheme.Space.xs

    /// 40 pt. The micro-thumbnail's width (DESIGN.md §9.12; the mockup draws 44).
    package static let thumbnailWidth: CGFloat = 40

    /// 22 pt. The micro-thumbnail's height, 16:9 against ``thumbnailWidth``.
    package static let thumbnailHeight: CGFloat = 22

    /// 0.35. The last known frame's opacity once a camera is offline (DESIGN.md §9.12).
    package static let offlineThumbnailOpacity: Double = 0.35

    /// 40 pt. The motion spark's width (UX.md §4.2).
    ///
    /// DESIGN.md §9.12 sizes it 60 × 10. At the 264 pt sidebar width a 60 pt spark leaves under
    /// 120 pt for a camera name, so UX.md's narrower figure is the one that fits the row it is
    /// specified for.
    package static let sparkWidth: CGFloat = 40

    /// 12 pt. The motion spark's height (UX.md §4.2).
    package static let sparkHeight: CGFloat = 12

    /// 20 buckets of 15 s each — the last five minutes (UX.md §4.2).
    package static let sparkBuckets: Int = 20

    /// 1 pt. A bar's width, and also the gap between two bars: 20 × 1 + 19 × 1 = 39 ≤ 40.
    package static let sparkBar: CGFloat = 1

    /// 1 pt. The baseline a silent bucket still draws — never an empty gap (UX.md §4.2).
    package static let sparkBaseline: CGFloat = 1

    /// 0.35. A bucket with no confirmed event draws at this alpha (UX.md §4.2).
    package static let sparkRestAlpha: Double = 0.35

    /// The intensity at or above which a bucket counts as a confirmed event and draws at full
    /// strength. UX.md §4.2 states the two levels but not the boundary; this is it, named once.
    package static let sparkEventThreshold: Double = 0.75

    /// 14 pt. The rounded square carrying a group's initial, as the approved mockup draws it.
    package static let groupTag: CGFloat = 14

    /// White α 0.05 — a hovered row's fill (DESIGN.md §9.12).
    package static let hoverAlpha: Double = 0.05

    /// White α 0.08 — a selected row's fill while the window is **inactive** (DESIGN.md §9.12).
    package static let inactiveSelectedAlpha: Double = 0.08

    /// Accent α 0.30 — the hairline around a selected row (DESIGN.md §9.12).
    package static let selectedStrokeAlpha: Double = 0.30

    /// 0.45. A disabled camera's row dims to this (UX.md §4.3).
    package static let disabledRowOpacity: Double = 0.45

    /// 12 pt per level. A camera under a device or group header steps in by this much.
    package static let indentStep: CGFloat = VTheme.Space.md

    /// 32 pt. The status footer (UX.md §3.3).
    package static let footerHeight: CGFloat = VTheme.Metrics.lg

    /// 12 pt. The drop insertion line's inset from both ends of the row (DESIGN.md §9.12).
    package static let dropLineInset: CGFloat = VTheme.Space.md

    /// The dash pattern of a group row's drop-target stroke: 4 on, 3 off (DESIGN.md §9.12).
    package static let dropDash: [CGFloat] = [4, 3]
}

// MARK: - VSidebarClick

/// Which modifier keys were held when a row was clicked.
///
/// The three cases map one-to-one onto ``VSidebarSelectionState``'s three entry points, so the
/// window can forward a click without re-deriving anything: ``plain`` → `select(_:)`, ``toggle`` →
/// `toggle(_:in:)`, ``extend`` → `extend(to:in:)` (UX.md §4.3).
package enum VSidebarClick: Sendable, Hashable {

    /// No modifier. Replaces the whole selection.
    case plain

    /// ⌘. Adds this row to, or removes it from, the selection.
    case toggle

    /// ⇧. Selects the contiguous run from the anchor to this row.
    case extend

    /// The click that the modifiers held right now describe.
    ///
    /// SwiftUI's `TapGesture` carries no modifier information on macOS 14 —
    /// `modifierKeyAlternate(_:_:)` arrived in macOS 15 — so the flags are read from AppKit at the
    /// instant the tap is delivered, which is the same instant the event was processed.
    ///
    ///     class var modifierFlags: NSEvent.ModifierFlags { get }
    ///
    /// ⌘ wins when both are held, which is what every macOS list does.
    @MainActor
    package static var current: VSidebarClick {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) { return .toggle }
        if flags.contains(.shift) { return .extend }
        return .plain
    }
}

// MARK: - VSidebarStatus → the dot

extension VSidebarStatus {

    /// The dot's five-way visual vocabulary for this status.
    ///
    /// ``VSidebarStatus/disabled`` has no dot of its own and takes ``VLiveDot/Status/offline``'s
    /// hollow ring, which is exactly what UX.md §4.2 asks a disabled camera to show; the row also
    /// dims to 45 %, so the two are never confused.
    ///
    /// Nonisolated, like `LiveConnectionState.dot`: `VLiveDot.Status` is a nested type and does not
    /// inherit `VLiveDot`'s `@MainActor`.
    package var dotStatus: VLiveDot.Status {
        switch self {
        case .disabled: return .offline
        case .connecting: return .connecting
        case .live: return .live
        case .degraded: return .degraded
        case .offline: return .offline
        case .authFailed: return .authFailed
        }
    }
}

// MARK: - VSidebarTone

/// The ink a row's status line takes, named as a token choice rather than returned as a colour.
///
/// Naming the choice is what makes the mapping testable: a dynamic `SwiftUI.Color` built from
/// `NSColor(name:dynamicProvider:)` cannot usefully be compared in a test, but a case can.
package enum VSidebarTone: Sendable, Hashable {

    /// `text.tertiary` — the ordinary status line.
    case neutral

    /// `warn` — a degraded stream, the one status that colours its own line.
    case warn

    /// `danger` — a rejected credential, which is never retried automatically (UX.md §12.7).
    case danger

    /// The token this tone resolves to.
    @MainActor
    package var colour: SwiftUI.Color {
        switch self {
        case .neutral: return VTheme.Color.Text.tertiary
        case .warn: return VTheme.Color.Semantic.warn
        case .danger: return VTheme.Color.Semantic.danger
        }
    }
}

// MARK: - VSidebarStatusLine

/// The camera row's second line: a dot, and then either a sentence or the codec/resolution chips.
package enum VSidebarStatusLine {

    /// The tone the line is set in.
    package static func tone(for status: VSidebarStatus) -> VSidebarTone {
        switch status {
        case .degraded: return .warn
        case .authFailed: return .danger
        case .disabled, .connecting, .live, .offline: return .neutral
        }
    }

    /// Whether this status prints the codec/resolution chips instead of a sentence.
    ///
    /// Only ``VSidebarStatus/live`` does. The mockup's degraded row reads `3.1% loss` and nothing
    /// else, because naming the fault is worth more than repeating the codec.
    package static func showsChips(for status: VSidebarStatus) -> Bool {
        if case .live = status { return true }
        return false
    }

    /// The sentence, or `nil` when the row shows chips instead.
    ///
    /// Numbers are formatted by `FormatStyle`/`Measurement` and never by hand: the decimal
    /// separator, the unit and the space before `%` are all locale decisions (UX.md §14.2). The
    /// retry countdown's unit is inside the key rather than in a `Measurement`, because
    /// `UnitDuration.seconds` at `.abbreviated` width spells it `sec` — the same reason the
    /// existing `"%@ s"` key exists.
    @MainActor
    package static func text(for status: VSidebarStatus) -> Text? {
        switch status {
        case .disabled:
            return Text("Disabled", bundle: .vigilUI)
        case .connecting(let progress):
            guard let progress else { return Text("Connecting…", bundle: .vigilUI) }
            let value = progress.formatted(.percent.precision(.fractionLength(0)))
            return Text("Connecting \(value)", bundle: .vigilUI)
        case .live:
            return nil
        case .degraded(let impairment):
            return Self.text(for: impairment)
        case .offline(let retryInSeconds):
            guard let retryInSeconds else { return Text("Offline", bundle: .vigilUI) }
            let value = Swift.max(0, retryInSeconds).formatted(.number)
            return Text("Offline · retry \(value) s", bundle: .vigilUI)
        case .authFailed:
            return Text("Sign-in failed", bundle: .vigilUI)
        }
    }

    /// The measured fault, in the shortest form that still names it (UX.md §12.5).
    @MainActor
    package static func text(for impairment: VSidebarImpairment) -> Text {
        switch impairment {
        case .packetLoss(let fraction):
            let value = fraction.formatted(.percent.precision(.fractionLength(1)))
            return Text("\(value) loss", bundle: .vigilUI)
        case .jitter(let milliseconds):
            let value = Measurement(value: milliseconds, unit: UnitDuration.milliseconds)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided))
            return Text("\(value) jitter", bundle: .vigilUI)
        case .decodeQueue(let frames):
            let value = frames.formatted(.number)
            return Text("\(value) queued", bundle: .vigilUI)
        case .lowFrameRate(let fps):
            let value = fps.formatted(.number.precision(.fractionLength(0)))
            return Text("\(value) fps", bundle: .vigilUI)
        case .switchedToTCP:
            return Text("On TCP", bundle: .vigilUI)
        }
    }
}

// MARK: - VSidebarChips

/// The codec and resolution pills a live row shows.
package enum VSidebarChips {

    /// `["H.265", "1080p"]`, in that order, skipping whatever has not been negotiated yet.
    ///
    /// Empty until the stream is described, which is the state every row starts in: a row has to be
    /// renderable before any network call has returned (UX.md §0 hard rule 2).
    package static func labels(for camera: VSidebarCamera) -> [String] {
        var out: [String] = []
        if let codec = camera.codec, !codec.isEmpty { out.append(codec) }
        if let resolution = camera.resolutionLabel, !resolution.isEmpty { out.append(resolution) }
        return out
    }
}

// MARK: - VSidebarHighlight

/// Splitting a camera's name into the runs the search matched and the runs it did not.
package enum VSidebarHighlight {

    /// One stretch of a name that is either wholly matched or wholly unmatched.
    package struct Run: Sendable, Hashable, Identifiable {

        /// The character offset the run starts at, which is also a stable identity within one name.
        package let id: Int

        /// The characters.
        package let text: String

        /// Whether the query matched here, in which case the run is drawn `accent` semibold
        /// (UX.md §4.4).
        package let isMatch: Bool

        /// Creates a run.
        package init(id: Int, text: String, isMatch: Bool) {
            self.id = id
            self.text = text
            self.isMatch = isMatch
        }
    }

    /// The runs for a name and the match that put its row on screen.
    ///
    /// Returns a single unmatched run — the whole name — whenever there is nothing safe to
    /// highlight: no match, a match on a field other than the name, a match whose
    /// ``VSidebarMatch/canHighlight`` is `false` because folding changed the string's length, or
    /// offsets that fall outside the name. Losing a highlight is cosmetic; highlighting the wrong
    /// letters looks like a bug. An empty name produces no runs at all.
    package static func runs(name: String, match: VSidebarMatch?) -> [Run] {
        let characters = Array(name)
        guard !characters.isEmpty else { return [] }
        var hits: Set<Int> = []
        if let match, match.field == .name, match.canHighlight {
            hits = Set(match.nameOffsets.filter { $0 >= 0 && $0 < characters.count })
        }
        guard !hits.isEmpty else { return [Run(id: 0, text: name, isMatch: false)] }

        var out: [Run] = []
        var start = 0
        var flag = hits.contains(0)
        for index in 1..<characters.count {
            let next = hits.contains(index)
            guard next != flag else { continue }
            out.append(Run(id: start, text: String(characters[start..<index]), isMatch: flag))
            start = index
            flag = next
        }
        out.append(Run(id: start, text: String(characters[start...]), isMatch: flag))
        return out
    }
}

// MARK: - VSidebarIdentity

/// The camera's and the group's identity colour, and the initial that always accompanies it.
package enum VSidebarIdentity {

    /// A camera's index into ``VTheme/Color/Ident/all``: the persisted choice when there is one,
    /// and the deterministic derivation from the identifier otherwise (DESIGN.md §3.4).
    @MainActor
    package static func cameraIndex(_ camera: VSidebarCamera) -> Int {
        camera.identityIndex ?? VTheme.Color.Ident.index(for: camera.id.rawValue)
    }

    /// A group's index, derived the same way.
    @MainActor
    package static func groupIndex(_ group: VSidebarGroup) -> Int {
        group.identityIndex ?? VTheme.Color.Ident.index(for: group.id.rawValue)
    }

    /// The camera's identity colour.
    @MainActor
    package static func colour(for camera: VSidebarCamera) -> SwiftUI.Color {
        VTheme.Color.Ident.colour(at: cameraIndex(camera))
    }

    /// The group's identity colour.
    @MainActor
    package static func colour(for group: VSidebarGroup) -> SwiftUI.Color {
        VTheme.Color.Ident.colour(at: groupIndex(group))
    }

    /// The initial that makes the colour redundant encoding rather than the sole carrier of
    /// identity (DESIGN.md §3.4). `nil` for a name that is empty or only whitespace.
    package static func initial(of name: String) -> Character? {
        name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().first
    }
}

// MARK: - VSidebarBitrate

/// Scaling the footer's aggregate ingest rate into a unit a person can read.
package enum VSidebarBitrate {

    /// The four decimal steps. Decimal and not binary: network rates are quoted in powers of ten.
    package enum Unit: String, Sendable, Hashable, CaseIterable {

        /// Under 1 kb/s.
        case bits

        /// Under 1 Mb/s.
        case kilobits

        /// Under 1 Gb/s.
        case megabits

        /// 1 Gb/s and above.
        case gigabits
    }

    /// The value and the unit to print it in.
    ///
    /// Negative, NaN and infinite inputs all return `(0, .bits)` rather than propagating. This
    /// number comes from a rate estimator dividing by an elapsed time, and a footer that reads
    /// `nan Gb/s` is worse than one that reads `0 b/s`.
    package static func scaled(_ bitsPerSecond: Double) -> (value: Double, unit: Unit) {
        guard bitsPerSecond.isFinite, bitsPerSecond > 0 else { return (0, .bits) }
        if bitsPerSecond < 1_000 { return (bitsPerSecond, .bits) }
        if bitsPerSecond < 1_000_000 { return (bitsPerSecond / 1_000, .kilobits) }
        if bitsPerSecond < 1_000_000_000 { return (bitsPerSecond / 1_000_000, .megabits) }
        return (bitsPerSecond / 1_000_000_000, .gigabits)
    }

    /// `1.8 Gb/s`, with the number formatted by `FormatStyle` and the unit inside the key so a
    /// translation can move it (UX.md §14.2).
    @MainActor
    package static func text(_ bitsPerSecond: Double) -> Text {
        let scaled = Self.scaled(bitsPerSecond)
        let digits = scaled.unit == .bits ? 0 : 1
        let value = scaled.value.formatted(.number.precision(.fractionLength(digits)))
        switch scaled.unit {
        case .bits: return Text("\(value) b/s", bundle: .vigilUI)
        case .kilobits: return Text("\(value) kb/s", bundle: .vigilUI)
        case .megabits: return Text("\(value) Mb/s", bundle: .vigilUI)
        case .gigabits: return Text("\(value) Gb/s", bundle: .vigilUI)
        }
    }
}

// MARK: - VSidebarSpark

/// The 40 × 12 pt motion sparkline: twenty buckets of fifteen seconds (UX.md §4.2).
///
/// Drawn as twenty 1 pt bars rather than as a `Shape`, because `Shape.path(in:)` is a nonisolated
/// requirement and a `@MainActor` conformer therefore cannot read its own stored samples from it
/// (R-40) — the trick `VStatusTriangle` gets away with only because it stores nothing.
@MainActor
package struct VSidebarSpark: View {

    /// Motion intensity per bucket, `0…1`, oldest first. Fewer than twenty values are padded at
    /// the front with silence; more than twenty keep the most recent twenty.
    package let samples: [Double]

    /// Creates a spark.
    package init(samples: [Double]) {
        self.samples = samples
    }

    // MARK: - Pure helpers

    /// Normalises any input to exactly `count` buckets clamped to `0…1`.
    ///
    /// Padding at the **front** is what makes a camera that has only just started reporting read as
    /// "quiet until now" rather than as "busy at the start", which is the opposite of the truth.
    /// A `count` of zero or less yields no buckets rather than trapping.
    package static func buckets(_ samples: [Double], count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let clamped = samples.map { value -> Double in
            guard value.isFinite else { return 0 }
            return Swift.min(Swift.max(value, 0), 1)
        }
        if clamped.count >= count { return Array(clamped.suffix(count)) }
        return Array(repeating: 0, count: count - clamped.count) + clamped
    }

    /// A bucket's bar height, never below the 1 pt baseline (UX.md §4.2).
    package static func height(_ value: Double) -> CGFloat {
        let scaled = CGFloat(value) * VSidebarMetrics.sparkHeight
        return Swift.max(VSidebarMetrics.sparkBaseline, scaled)
    }

    /// A bucket's alpha: full for a confirmed event, `sparkRestAlpha` otherwise (UX.md §4.2).
    package static func alpha(_ value: Double) -> Double {
        value >= VSidebarMetrics.sparkEventThreshold ? 1.0 : VSidebarMetrics.sparkRestAlpha
    }

    // MARK: - View

    package var body: some View {
        let values = Self.buckets(samples, count: VSidebarMetrics.sparkBuckets)
        HStack(alignment: .bottom, spacing: VSidebarMetrics.sparkBar) {
            ForEach(Array(values.indices), id: \.self) { index in
                Rectangle()
                    .fill(VTheme.Color.Semantic.motion.opacity(Self.alpha(values[index])))
                    .frame(width: VSidebarMetrics.sparkBar,
                           height: Self.height(values[index]))
            }
        }
        .frame(width: VSidebarMetrics.sparkWidth,
               height: VSidebarMetrics.sparkHeight,
               alignment: .bottomTrailing)
        .accessibilityHidden(true)
    }
}

// MARK: - VSidebarRowSurface

/// The fill, hairline and focus ring every sidebar row shares (DESIGN.md §9.12's state table).
///
/// A `ViewModifier` rather than a base view so the camera row and the link row cannot drift apart:
/// they are the same surface with different contents, and a list showing two different selection
/// treatments is a bug the user notices before anything else.
@MainActor
package struct VSidebarRowSurface: ViewModifier {

    /// Whether the row is part of the selection.
    package let isSelected: Bool

    /// Whether the row is the one the keyboard is on.
    package let isFocused: Bool

    /// Whether the pointer is over the row.
    package let isHovering: Bool

    /// Whether a drag is proposing to drop *into* this row. Only a group row accepts one.
    package let isDropTarget: Bool

    // @Environment(\.controlActiveState) is SwiftUI's macOS-only window-activation key:
    //
    //     var controlActiveState: ControlActiveState   // .key | .active | .inactive
    //
    // A selected row in a background window drops to a neutral fill, as every Mac list does.
    @Environment(\.controlActiveState) private var controlActiveState

    /// Creates the surface.
    package init(isSelected: Bool,
                 isFocused: Bool,
                 isHovering: Bool,
                 isDropTarget: Bool = false) {
        self.isSelected = isSelected
        self.isFocused = isFocused
        self.isHovering = isHovering
        self.isDropTarget = isDropTarget
    }

    package func body(content: Content) -> some View {
        content
            .background(fill, in: VTheme.Radius.shape(VTheme.Radius.sm))
            .overlay { border }
            .contentShape(VTheme.Radius.shape(VTheme.Radius.sm))
            // Outset 0: rows sit flush against each other, so a ring 3 pt outside the shape would
            // overlap its neighbours. On the row's own edge it is still 2 pt of `focusRing`.
            .vFocusRing(isFocused, radius: VTheme.Radius.sm, outset: 0)
    }

    /// DESIGN.md §9.12: accent tint when selected, white α 0.05 when merely hovered, clear at rest.
    private var fill: SwiftUI.Color {
        if isDropTarget { return VTheme.Color.Semantic.Tint.dropTarget }
        guard isSelected else {
            return isHovering
                ? SwiftUI.Color.white.opacity(VSidebarMetrics.hoverAlpha)
                : SwiftUI.Color.clear
        }
        guard controlActiveState != .inactive else {
            return SwiftUI.Color.white.opacity(VSidebarMetrics.inactiveSelectedAlpha)
        }
        return isHovering
            ? VTheme.Color.Semantic.Tint.selectedHover
            : VTheme.Color.Semantic.Tint.selected
    }

    @ViewBuilder
    private var border: some View {
        if isDropTarget {
            VTheme.Radius.shape(VTheme.Radius.sm)
                .strokeBorder(VTheme.Color.Semantic.accent,
                              style: StrokeStyle(lineWidth: VTheme.Border.selected,
                                                 dash: VSidebarMetrics.dropDash))
                .allowsHitTesting(false)
        } else if isSelected {
            VTheme.Radius.shape(VTheme.Radius.sm)
                .strokeBorder(selectedStroke, lineWidth: VTheme.Border.thin)
                .allowsHitTesting(false)
        }
    }

    private var selectedStroke: SwiftUI.Color {
        controlActiveState == .inactive
            ? VTheme.Color.Stroke.default
            : VTheme.Color.Semantic.accentTint(VSidebarMetrics.selectedStrokeAlpha)
    }
}

// MARK: - VSidebarRowView

/// A camera row: identity rail, micro-thumbnail, name, status line and motion spark, in 44 pt.
///
/// ## What this view does not do
///
/// It does **no** network work and owns no timer. The picture comes from the `thumbnail` child the
/// app injects — an already-decoded frame downscaled by whatever is already decoding, or an ISAPI
/// JPEG poll, per DESIGN.md §9.12 — and the status, the codec and the motion buckets all arrive as
/// values. A sidebar of sixty cameras must cost sixty layouts and nothing else.
///
/// ## Why the whole row is not a `Button`
///
/// A `Button` gets one action, and this row needs four depending on the modifier keys and the click
/// count (UX.md §4.3). The modifiers are read in ``VSidebarClick/current`` at the moment of the tap.
/// The keyboard path P6 requires is the window's: `↑`/`↓` move the selection and `⏎` activates it,
/// which is exactly what these callbacks are for.
///
/// ## Identity colour and `differentiateWithoutColor`
///
/// DESIGN.md §3.4 requires an identity colour to be accompanied by the camera's initial. Here the
/// **whole name** is on the row, one line above the rail, which is strictly more information than
/// an initial — so no separate glyph is drawn.
@MainActor
package struct VSidebarRowView<Thumbnail: View>: View {

    // MARK: - Stored Properties

    /// The camera this row shows.
    package let camera: VSidebarCamera

    /// The match that put the row on screen, so the matched letters can be highlighted. `nil` when
    /// no search is active.
    package let match: VSidebarMatch?

    /// Whether the camera is part of the sidebar's selection.
    package let isSelected: Bool

    /// Whether this row is the one the inspector is bound to and the keyboard is on.
    package let isFocused: Bool

    /// Nesting depth: 1 for a channel under a device header, 0 otherwise.
    package let indent: Int

    /// Motion intensity per 15 s bucket, `0…1`, oldest first (UX.md §4.2).
    package let motionSamples: [Double]

    /// A click on the row, carrying the modifiers that were held.
    package let onSelect: (VSidebarClick) -> Void

    /// A double-click: assign the camera to the focused stage cell (UX.md §4.3).
    package let onActivate: () -> Void

    private let thumbnail: () -> Thumbnail

    @Environment(\.vMotionEnabled) private var motionEnabled
    @Environment(\.vPulsePhase) private var pulsePhase

    @State private var isHovering = false

    // MARK: - Initialisation

    /// Creates a camera row.
    ///
    /// - Parameter thumbnail: the picture, mounted in **every** state so the last frame is still
    ///   there to dim when the connection drops — the same no-black-flash rule the stage tile
    ///   follows (DESIGN.md §3.6 clause 6).
    package init(camera: VSidebarCamera,
                 match: VSidebarMatch? = nil,
                 isSelected: Bool = false,
                 isFocused: Bool = false,
                 indent: Int = 0,
                 motionSamples: [Double] = [],
                 onSelect: @escaping (VSidebarClick) -> Void = { _ in },
                 onActivate: @escaping () -> Void = {},
                 @ViewBuilder thumbnail: @escaping () -> Thumbnail) {
        self.camera = camera
        self.match = match
        self.isSelected = isSelected
        self.isFocused = isFocused
        self.indent = indent
        self.motionSamples = motionSamples
        self.onSelect = onSelect
        self.onActivate = onActivate
        self.thumbnail = thumbnail
    }

    // MARK: - View

    package var body: some View {
        HStack(spacing: 0) {
            rail
            Spacer().frame(width: VSidebarMetrics.railGap)
            thumbnailWell
            Spacer().frame(width: VTheme.Space.sm)
            meta
            Spacer().frame(width: VTheme.Space.sm)
            VSidebarSpark(samples: motionSamples)
        }
        .padding(.trailing, VTheme.Space.xs)
        .frame(height: VTheme.Metrics.Row.camera)
        .modifier(VSidebarRowSurface(isSelected: isSelected,
                                     isFocused: isFocused,
                                     isHovering: isHovering))
        .opacity(camera.isEnabled ? 1 : VSidebarMetrics.disabledRowOpacity)
        .padding(.leading, CGFloat(indent) * VSidebarMetrics.indentStep)
        .onHover { hovering in
            withAnimation(VTheme.Motion.resolved(VTheme.Motion.micro, reduced: !motionEnabled)) {
                isHovering = hovering
            }
        }
        .onTapGesture(count: 2) { onActivate() }
        .onTapGesture { onSelect(VSidebarClick.current) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: camera.name))
        .accessibilityValue(accessibilityStatus)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(Text(verbatim: camera.name))
    }

    // MARK: - Rail

    /// The 3 pt identity bar. It turns `live` red while Vigil is recording the camera locally
    /// (UX.md §4.2) — a replacement rather than a tint, so an identity colour and a status colour
    /// can never be mistaken for one another (DESIGN.md §3.4).
    private var rail: some View {
        VTheme.Radius.shape(VTheme.Radius.full(VSidebarMetrics.railWidth))
            .fill(railColour)
            .frame(width: VSidebarMetrics.railWidth, height: VSidebarMetrics.railHeight)
            .accessibilityHidden(true)
    }

    private var railColour: SwiftUI.Color {
        camera.isRecording
            ? VTheme.Color.Semantic.live
            : VTheme.Color.Ident.rail(VSidebarIdentity.colour(for: camera))
    }

    // MARK: - Thumbnail

    /// The 40 × 22 well: true black, radius 4, an `onVideo` hairline, and never a material.
    private var thumbnailWell: some View {
        ZStack {
            VTheme.Color.Layer.videoWell
            thumbnail()
                .opacity(camera.status.isShowingVideo
                            ? 1
                            : VSidebarMetrics.offlineThumbnailOpacity)
            if isConnecting {
                VSkeleton(radius: VTheme.Radius.xs, base: VTheme.Color.Layer.videoWell)
            } else if !camera.status.isShowingVideo {
                VTheme.Symbol.cameraOffline.image()
                    .symbolRenderingMode(VTheme.Symbol.cameraOffline.rendering)
                    .vIcon(size: VTheme.Icon.xs, weight: VTheme.Icon.Weight.xs)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
            }
        }
        .frame(width: VSidebarMetrics.thumbnailWidth, height: VSidebarMetrics.thumbnailHeight)
        .clipShape(VTheme.Radius.shape(VTheme.Radius.xs))
        .overlay {
            VTheme.Radius.shape(VTheme.Radius.xs)
                .strokeBorder(VTheme.Color.Stroke.onVideo, lineWidth: VTheme.Border.thin)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) { recordingDot }
        .accessibilityHidden(true)
    }

    private var isConnecting: Bool {
        if case .connecting = camera.status { return true }
        return false
    }

    /// The recording marker, breathing off the window-wide pulse clock rather than off a timer of
    /// its own — sixty rows with sixty animators would blow the four-driver budget (§7.5, §7.9).
    @ViewBuilder
    private var recordingDot: some View {
        if camera.isRecording {
            Circle()
                .fill(VTheme.Color.Semantic.live)
                .frame(width: VLiveDot.dotSize, height: VLiveDot.dotSize)
                .opacity(motionEnabled && !pulsePhase ? 0.55 : 1.0)
                .animation(VTheme.Motion.resolvedLoop(VTheme.Motion.breathe,
                                                      reduced: !motionEnabled),
                           value: pulsePhase)
                .padding(VTheme.Space.hair)
        }
    }

    // MARK: - Name and status

    private var meta: some View {
        VStack(alignment: .leading, spacing: VTheme.Space.hair) {
            name
            subtitle
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var name: some View {
        nameText
            .vType(VTheme.Typography.headline)
            .foregroundStyle(VTheme.Color.Text.primary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// The name, with the matched letters at `accent` semibold (UX.md §4.4).
    ///
    /// Built by concatenating `Text` values, which is the only way to style part of a string in
    /// SwiftUI without laying out several views side by side.
    ///
    ///     func foregroundStyle<S: ShapeStyle>(_ style: S) -> Text    // macOS 14+
    ///     func fontWeight(_ weight: Font.Weight?) -> Text
    private var nameText: Text {
        var out = Text(verbatim: "")
        for run in VSidebarHighlight.runs(name: camera.name, match: match) {
            let piece = Text(verbatim: run.text)
            if run.isMatch {
                out = out + piece
                    .foregroundStyle(VTheme.Color.Semantic.accent)
                    .fontWeight(.semibold)
            } else {
                out = out + piece
            }
        }
        return out
    }

    private var subtitle: some View {
        HStack(spacing: VTheme.Space.xxs) {
            VLiveDot(camera.status.dotStatus)
            statusContent
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        if let line = VSidebarStatusLine.text(for: camera.status) {
            line
                .vType(VTheme.Typography.caption1Numeric)
                .foregroundStyle(VSidebarStatusLine.tone(for: camera.status).colour)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            chips
        }
    }

    /// The codec and resolution pills. `VChip(.neutral)` is the shipped 20 pt chip of §9.9 — the
    /// mockup draws a shorter badge, but re-styling the component here would leave the app with two
    /// chips that differ by a few points and nothing else.
    @ViewBuilder
    private var chips: some View {
        let labels = VSidebarChips.labels(for: camera)
        if labels.isEmpty {
            Text("Live", bundle: .vigilUI)
                .vType(VTheme.Typography.caption1)
                .foregroundStyle(VTheme.Color.Text.tertiary)
        } else {
            ForEach(labels, id: \.self) { label in
                VChip(.neutral) { Text(verbatim: label) }
            }
            if camera.isSubStream {
                VTheme.Symbol.substream.image()
                    .vIcon(size: VTheme.Icon.xs, weight: VTheme.Icon.Weight.xs)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
                    .help(Text("Sub-stream", bundle: .vigilUI))
            }
        }
    }

    /// The one sentence a screen reader hears after the camera's name.
    private var accessibilityStatus: Text {
        if let line = VSidebarStatusLine.text(for: camera.status) { return line }
        guard let codec = VSidebarChips.labels(for: camera).first else {
            return Text("Live", bundle: .vigilUI)
        }
        return Text("Live", bundle: .vigilUI) + Text(verbatim: " · " + codec)
    }
}

// MARK: - VSidebarLinkRow

/// The 28 pt row every non-camera line uses: the layout row, a group, a device header and the three
/// library links.
///
/// One type rather than four, because they differ only in which of four optional slots they fill —
/// a leading glyph, a leading identity tag, a trailing count and a selection — and four
/// near-identical row types is how two of them end up with different selection treatments.
@MainActor
package struct VSidebarLinkRow: View {

    // MARK: - Stored Properties

    /// The row's label, already localised by the caller.
    package let title: Text

    /// A leading glyph, or `nil` when the row carries an identity tag or nothing at all.
    package let symbol: VTheme.Symbol?

    /// The glyph's ink.
    package let symbolTint: SwiftUI.Color

    /// The identity colour of the leading rounded square, or `nil` for no tag.
    package let tagColour: SwiftUI.Color?

    /// The letter inside the tag, which keeps the colour from being the only cue (§3.4).
    package let tagInitial: Character?

    /// The trailing count, already formatted, or `nil` for none.
    package let badge: String?

    /// The badge's ink — `motion` for unread events, `text.tertiary` otherwise (UX.md §4.1).
    package let badgeTint: SwiftUI.Color

    /// Nesting depth.
    package let indent: Int

    /// Whether the row is the current selection.
    package let isSelected: Bool

    /// Whether the keyboard is on this row.
    package let isFocused: Bool

    /// Whether a drag is proposing to drop into this row. Only a group row ever accepts one.
    package let isDropTarget: Bool

    /// A click, carrying the modifiers that were held.
    package let onSelect: (VSidebarClick) -> Void

    /// A double-click.
    package let onActivate: () -> Void

    @Environment(\.vMotionEnabled) private var motionEnabled

    @State private var isHovering = false

    // MARK: - Initialisation

    /// Creates a link row.
    package init(title: Text,
                 symbol: VTheme.Symbol? = nil,
                 symbolTint: SwiftUI.Color = VTheme.Color.Text.secondary,
                 tagColour: SwiftUI.Color? = nil,
                 tagInitial: Character? = nil,
                 badge: String? = nil,
                 badgeTint: SwiftUI.Color = VTheme.Color.Text.tertiary,
                 indent: Int = 0,
                 isSelected: Bool = false,
                 isFocused: Bool = false,
                 isDropTarget: Bool = false,
                 onSelect: @escaping (VSidebarClick) -> Void = { _ in },
                 onActivate: @escaping () -> Void = {}) {
        self.title = title
        self.symbol = symbol
        self.symbolTint = symbolTint
        self.tagColour = tagColour
        self.tagInitial = tagInitial
        self.badge = badge
        self.badgeTint = badgeTint
        self.indent = indent
        self.isSelected = isSelected
        self.isFocused = isFocused
        self.isDropTarget = isDropTarget
        self.onSelect = onSelect
        self.onActivate = onActivate
    }

    // MARK: - View

    package var body: some View {
        HStack(spacing: VTheme.Space.sm) {
            leading
            title
                .vType(VTheme.Typography.body)
                .foregroundStyle(isSelected
                                    ? VTheme.Color.Text.primary
                                    : VTheme.Color.Text.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: VTheme.Space.xxs)
            trailingBadge
        }
        .padding(.horizontal, VTheme.Space.xs)
        .frame(height: VTheme.Metrics.Row.settings)
        .modifier(VSidebarRowSurface(isSelected: isSelected,
                                     isFocused: isFocused,
                                     isHovering: isHovering,
                                     isDropTarget: isDropTarget))
        .padding(.leading, CGFloat(indent) * VSidebarMetrics.indentStep)
        .onHover { hovering in
            withAnimation(VTheme.Motion.resolved(VTheme.Motion.micro, reduced: !motionEnabled)) {
                isHovering = hovering
            }
        }
        .onTapGesture(count: 2) { onActivate() }
        .onTapGesture { onSelect(VSidebarClick.current) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Private Helpers

    @ViewBuilder
    private var leading: some View {
        if let tagColour {
            tag(tagColour)
        } else if let symbol {
            symbol.image()
                .symbolRenderingMode(symbol.rendering)
                .vIcon(size: VTheme.Icon.sm, weight: symbol.weight)
                .foregroundStyle(symbolTint)
                .frame(width: VTheme.Icon.md, alignment: .center)
        }
    }

    @ViewBuilder
    private var trailingBadge: some View {
        if let badge {
            Text(verbatim: badge)
                .vType(VTheme.Typography.monoSmall.numeric)
                .foregroundStyle(badgeTint)
        }
    }

    /// A 14 pt rounded square in the identity colour, carrying the initial in ink.
    ///
    /// `text.inverse` is the correct ink in both appearances by construction: near-black on dark,
    /// where the identity colours are bright, and white on light, where they are dark.
    private func tag(_ colour: SwiftUI.Color) -> some View {
        VTheme.Radius.shape(VTheme.Radius.xs)
            .fill(colour)
            .frame(width: VSidebarMetrics.groupTag, height: VSidebarMetrics.groupTag)
            .overlay { tagLetter }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var tagLetter: some View {
        if let tagInitial {
            Text(String(tagInitial))
                .vType(VTheme.Typography.caption2)
                .foregroundStyle(VTheme.Color.Text.inverse)
        }
    }
}

// MARK: - VSidebarSectionHeader

/// A 22 pt uppercase eyebrow, with an optional `＋` and an optional disclosure state.
///
/// The disclosure chevron shows only while the header is hovered, or while the section is already
/// collapsed: the approved mockup has no chevron at rest, and a section the user has closed must
/// still say so when the pointer is somewhere else.
@MainActor
package struct VSidebarSectionHeader: View {

    // MARK: - Stored Properties

    /// The eyebrow's text. `Caption2` uppercases it, so pass it in sentence case.
    package let title: Text

    /// Whether the section can be collapsed. The LIVE section cannot (UX.md §4.1).
    package let isCollapsible: Bool

    /// Whether it currently is collapsed.
    package let isCollapsed: Bool

    /// The trailing `＋`'s glyph, or `nil` for a header with no add affordance.
    package let addSymbol: VTheme.Symbol?

    /// The `＋`'s VoiceOver label. Required whenever ``addSymbol`` is non-`nil`: a glyph is not
    /// speakable, and no two visible controls in a window may share a label (DESIGN.md §10.7).
    package let addLabel: LocalizedStringKey

    /// A trailing count shown before the `＋`, or `nil` for none.
    package let badge: String?

    /// Toggles the section's collapsed state.
    package let onToggle: () -> Void

    /// Runs the `＋`. Ignored when ``addSymbol`` is `nil`.
    package let onAdd: () -> Void

    @Environment(\.vMotionEnabled) private var motionEnabled

    @State private var isHovering = false

    // MARK: - Initialisation

    /// Creates a section header.
    package init(title: Text,
                 isCollapsible: Bool,
                 isCollapsed: Bool = false,
                 addSymbol: VTheme.Symbol? = nil,
                 addLabel: LocalizedStringKey = "",
                 badge: String? = nil,
                 onToggle: @escaping () -> Void = {},
                 onAdd: @escaping () -> Void = {}) {
        self.title = title
        self.isCollapsible = isCollapsible
        self.isCollapsed = isCollapsed
        self.addSymbol = addSymbol
        self.addLabel = addLabel
        self.badge = badge
        self.onToggle = onToggle
        self.onAdd = onAdd
    }

    // MARK: - View

    package var body: some View {
        HStack(spacing: VTheme.Space.xxs) {
            // The tap target stops at the title: a gesture spanning the whole row would compete
            // with the `＋`'s own `Button` for the same clicks.
            HStack(spacing: VTheme.Space.xxs) {
                chevron
                title
                    .vType(VTheme.Typography.caption2)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleIfPossible() }
            Spacer(minLength: VTheme.Space.xxs)
            trailingBadge
            addButton
        }
        .padding(.horizontal, VTheme.Space.xs)
        .frame(height: VTheme.Metrics.Row.sectionHeader)
        .onHover { hovering in
            withAnimation(VTheme.Motion.resolved(VTheme.Motion.micro, reduced: !motionEnabled)) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Private Helpers

    private func toggleIfPossible() {
        guard isCollapsible else { return }
        onToggle()
    }

    /// `chevron.down`, **rotated** rather than swapped — §8.3 makes the disclosure pair the one
    /// case that rotates instead of using `.symbolEffect(.replace)`.
    @ViewBuilder
    private var chevron: some View {
        if isCollapsible {
            VTheme.Symbol.disclosureExpanded.image()
                .vIcon(size: VTheme.Icon.xs, weight: VTheme.Symbol.disclosureExpanded.weight)
                .foregroundStyle(VTheme.Color.Text.disabled)
                .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                .opacity(isCollapsed || isHovering ? 1 : 0)
                .frame(width: VTheme.Icon.xs)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var trailingBadge: some View {
        if let badge {
            Text(verbatim: badge)
                .vType(VTheme.Typography.monoSmall.numeric)
                .foregroundStyle(VTheme.Color.Text.disabled)
        }
    }

    @ViewBuilder
    private var addButton: some View {
        if let addSymbol {
            VButton(symbol: addSymbol,
                    style: .icon,
                    size: .xs,
                    accessibilityLabel: addLabel,
                    action: onAdd)
        }
    }
}

#endif  // os(macOS)
