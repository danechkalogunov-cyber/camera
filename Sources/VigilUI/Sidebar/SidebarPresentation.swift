//
//  SidebarPresentation.swift
//  VigilUI
//
//  Everything the sidebar's rows are drawn *from*, with no view in it: the component's own
//  geometry, the click modifiers, the status → dot and status → tone mappings, the codec pills,
//  the search-highlight runs, the identity colour, the footer's bitrate scaling and the reading of
//  a drop position. Separated so that "which letters highlight" and "which unit does 1.8e9 print
//  in" are testable questions rather than screenshots.
//  macOS-only. Implements docs/DESIGN.md §9.12, §3.4 and docs/UX.md §4.2, §4.3, §4.4, §3.3.
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
        case .decodeBudget:
            return Text("Decode budget", bundle: .vigilUI)
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


// MARK: - VSidebarDrop

/// Resolving a ``VSidebarDropPosition`` against the rows currently on screen.
///
/// Pure, because "why did the insertion line appear above the wrong row" is a question a test can
/// answer in a millisecond and a person cannot answer at all while their hand is on the mouse. The
/// arithmetic that *produces* a position lives in ``VSidebarReorder``; this only reads one.
package enum VSidebarDrop {

    /// Which edge of a camera's row the 2 pt insertion line is drawn on.
    package enum Edge: Sendable, Hashable {

        /// Above the row: the drop lands before this camera.
        case above

        /// Below the row: the drop lands after the last camera, and this is the last camera.
        case below
    }

    /// The edge to draw on `camera`'s row, or `nil` when the drag is proposing something else.
    ///
    /// - Parameters:
    ///   - position: what the drag is proposing, or `nil` when nothing is being dragged.
    ///   - camera: the camera whose row is being drawn.
    ///   - visible: the cameras on screen in display order — ``VSidebarTree/visibleCameras``.
    ///
    /// ``VSidebarDropPosition/between(index:)`` is an index into `visible`, so `count` means "after
    /// the last row" — the one case a leading edge cannot express, and the reason ``Edge/below``
    /// exists. An index outside `0...count` draws nothing rather than clamping: a line at the wrong
    /// end of the list is worse than no line at all.
    package static func edge(for position: VSidebarDropPosition?,
                             camera: CameraID,
                             in visible: [CameraID]) -> Edge? {
        guard let position else { return nil }
        guard case .between(let index) = position else { return nil }
        guard index >= 0, index <= visible.count else { return nil }
        if index == visible.count {
            return visible.last == camera ? .below : nil
        }
        guard let slot = visible.firstIndex(of: camera) else { return nil }
        return slot == index ? .above : nil
    }

    /// Whether the group row at `ordinal` — its position among the group rows — is the drop target.
    package static func targetsGroup(_ position: VSidebarDropPosition?, ordinal: Int?) -> Bool {
        guard let position, let ordinal else { return false }
        guard case .onGroup(let index) = position else { return false }
        return index == ordinal
    }

    /// The position of each group row among the group rows, which is what
    /// ``VSidebarDropPosition/onGroup(index:)`` counts.
    ///
    /// Built once per structural update and handed down: resolving it inside the row builder would
    /// make drawing the sidebar quadratic in the number of groups.
    package static func groupOrdinals(_ rows: [VSidebarRow]) -> [GroupID: Int] {
        var out: [GroupID: Int] = [:]
        var next = 0
        for row in rows {
            guard case .group(let group, _) = row.kind else { continue }
            out[group.id] = next
            next += 1
        }
        return out
    }
}

#endif  // os(macOS)
