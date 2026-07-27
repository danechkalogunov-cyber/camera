//
//  VSidebarRowView.swift
//  VigilUI
//
//  The 44 pt camera row — identity rail, micro-thumbnail, name, status line and motion spark —
//  together with the motion sparkline itself and the row surface every sidebar row shares.
//  macOS-only. Implements docs/DESIGN.md §9.12 (row anatomy and state table), §3.4 (identity),
//  §10.5 (colour is never the only cue) and docs/UX.md §4.2, §4.3.
//

#if os(macOS)

import Foundation

import SwiftUI

import VigilProtocols

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

#endif  // os(macOS)
