//
//  VTheme+Space.swift
//  VigilUI
//
//  The 4 pt spacing ladder, the radius scale (all .continuous), border widths, the five control
//  heights and the fixed structural dimensions of the window.
//  macOS-only. See docs/DESIGN.md §5, docs/API_CONTRACT.md §4.11 and rulings R-34, R-35, R-37.
//

#if os(macOS)

import SwiftUI

// MARK: - Space

extension VTheme.Space {

    /// 2 pt. Icon↔label gap in dense rows, the tile gutter, badge inner padding.
    ///
    /// The only sub-grid value in the system, and an optical half-step only: it is never used for
    /// layout rhythm (§5.1).
    public static let hair: CGFloat = 2

    /// 4 pt. Chip inner padding, stacked caption gap, focus-ring inset.
    public static let xxs: CGFloat = 4

    /// 6 pt. Small-control horizontal padding, list row vertical padding.
    public static let xs: CGFloat = 6

    /// 8 pt. Default control horizontal padding, gap between sibling controls.
    public static let sm: CGFloat = 8

    /// 12 pt. Card padding, inspector row spacing, toolbar item gap.
    public static let md: CGFloat = 12

    /// 16 pt. Panel padding, section gap inside a card, sheet content inset.
    public static let lg: CGFloat = 16

    /// 20 pt. Sheet and window content margin, gap between inspector sections.
    public static let xl: CGFloat = 20

    /// 24 pt. Empty-state internal gap, Settings pane margin.
    public static let xxl: CGFloat = 24

    /// 32 pt. Above and below an empty-state hero; palette top inset.
    public static let huge: CGFloat = 32

    /// 48 pt. Onboarding vertical rhythm only.
    public static let jumbo: CGFloat = 48

    /// The ladder in order, for the token gallery.
    public static let all: [CGFloat] = [hair, xxs, xs, sm, md, lg, xl, xxl, huge, jumbo]
}

// MARK: - Radius

extension VTheme.Radius {

    /// 4 pt. Badge, keycap, inline code, colour swatch, checkbox, sidebar thumbnail.
    public static let xs: CGFloat = 4

    /// 6 pt. Chip, 20/24 pt controls, segmented thumb, small stat pill.
    public static let sm: CGFloat = 6

    /// 8 pt. Default control (28/32 pt), text field, select, slider track ends.
    public static let md: CGFloat = 8

    /// 10 pt. Card, inspector section, sidebar selected row, PTZ preset thumbnail.
    public static let lg: CGFloat = 10

    /// 14 pt. Video tile, popover, floating toolbar, sheet, toast, PTZ pad.
    public static let xl: CGFloat = 14

    /// 20 pt. Command palette, modal sheet, cinema control bar, onboarding card.
    public static let xxl: CGFloat = 20

    /// The ladder in order, for the token gallery.
    public static let all: [CGFloat] = [xs, sm, md, lg, xl, xxl]

    /// A fully-rounded end for a pill, status dot, avatar, live badge or slider knob.
    public static func full(_ height: CGFloat) -> CGFloat {
        height / 2
    }

    /// The **only** rounded-rectangle constructor any view should use.
    ///
    /// ⛔ All rounded rectangles in Vigil are `style: .continuous`. Circular arcs are visibly wrong
    /// next to macOS's own squircles (§5.2), and `cornerRadius:` without the style is a lint
    /// failure (§12.4). Routing every shape through here means a call site cannot get it wrong.
    ///
    ///     init(cornerRadius: CGFloat, style: RoundedCornerStyle = .circular)
    public static func shape(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    /// The nesting rule (§5.2).
    ///
    /// An element that is **flush** with its parent's inner edge takes `outer − inset`, so that the
    /// two curves stay concentric. An element that is merely *inside* the parent keeps its own
    /// token, because the subtraction would otherwise drive a text field inside a card down to a
    /// visibly wrong 4 pt.
    ///
    /// - Parameters:
    ///   - outer: the parent's radius.
    ///   - inset: the distance from the parent's inner edge to this element's edge.
    ///   - own: this element's own radius token.
    /// - Returns: `max(outer - inset, own)`, clamped below at `xs`.
    public static func nested(outer: CGFloat, inset: CGFloat, own: CGFloat) -> CGFloat {
        max(max(outer - inset, own), xs)
    }
}

// MARK: - Border

extension VTheme.Border {

    /// 1 pt. Standard control and card borders.
    public static let thin: CGFloat = 1

    /// 2 pt. The focus ring (§9.28). Becomes ``focusIncreased`` under `increaseContrast`.
    public static let focus: CGFloat = 2

    /// 3 pt. The focus ring under `increaseContrast`, where the outer glow is also dropped (§10.4).
    public static let focusIncreased: CGFloat = 3

    /// 2 pt. Selected tile border, in `accent`.
    public static let selected: CGFloat = 2

    /// 3 pt. Recording tile border, in `live`, breathing α 0.55 ↔ 1.0 (§7.4 #11).
    public static let recording: CGFloat = 3

    /// 1.5 pt. The PTZ pad's outer ring and the `.connecting` progress ring (§9.15, §9.27).
    public static let ring: CGFloat = 1.5

    /// A true one-pixel hairline: 0.5 pt on a Retina display, 1.0 pt on a 1× display.
    ///
    /// ⛔ Never `Divider()` — its colour and inset are not ours. Use a `Rectangle` filled with
    /// `VTheme.Color.Stroke.subtle` at this height (§5.4).
    ///
    ///     @Environment(\.displayScale) private var displayScale
    ///     let hairline = VTheme.Border.hairline(displayScale)
    ///
    /// - Parameter displayScale: the value of `\.displayScale`. Values ≤ 0 cannot come from
    ///   SwiftUI, but are treated as 1 rather than dividing by zero.
    public static func hairline(_ displayScale: CGFloat) -> CGFloat {
        displayScale > 0 ? 1 / displayScale : 1
    }
}

// MARK: - Metrics

extension VTheme.Metrics {

    // MARK: Control heights (§5.5) — five, no others

    /// 20 pt. Tile HUD chips and table cells. Radius 6, h-padding 6, `Caption1`, 11 pt icon.
    public static let xs: CGFloat = 20

    /// 24 pt. Inspector rows and segmented controls. Radius 6, h-padding 8, `Callout`, 12 pt icon.
    public static let sm: CGFloat = 24

    /// 28 pt. **The default** — toolbar, forms, menus. Radius 8, h-padding 10, `Body`, 13 pt icon.
    public static let md: CGFloat = 28

    /// 32 pt. Primary sheet actions and the search field. Radius 8, h-padding 12, `Body`, 15 pt.
    public static let lg: CGFloat = 32

    /// 40 pt. The empty-state call to action and the onboarding primary button only.
    public static let xl: CGFloat = 40

    // MARK: Sidebar and inspector (R-34 — the contract's numbers, derived from the content)

    /// 264 pt. Default sidebar width.
    public static let sidebarWidth: CGFloat = 264

    /// 208 pt. Minimum sidebar width.
    public static let sidebarMin: CGFloat = 208

    /// 380 pt. Maximum sidebar width.
    public static let sidebarMax: CGFloat = 380

    /// 68 pt. The icon-rail collapsed sidebar.
    public static let sidebarRail: CGFloat = 68

    /// 320 pt. Default inspector width.
    public static let inspectorWidth: CGFloat = 320

    /// 288 pt. Minimum inspector width.
    public static let inspectorMin: CGFloat = 288

    /// 440 pt. Maximum inspector width.
    public static let inspectorMax: CGFloat = 440

    // MARK: Window chrome (§11.2)

    /// 52 pt. The unified toolbar of the main window.
    public static let toolbarHeight: CGFloat = 52

    /// 38 pt. `.unifiedCompact`, used in auxiliary windows.
    public static let toolbarCompactHeight: CGFloat = 38

    /// 20 pt. The leading centre-x of the traffic lights in the main window.
    public static let trafficLightLeading: CGFloat = 20

    /// 26 pt. The centre-y of the traffic lights, optically centred in the 52 pt unified bar.
    public static let trafficLightCentreY: CGFloat = 26

    /// 1280 × 800 pt default window size; 900 × 600 minimum. Below 900 wide the inspector
    /// auto-hides, and below 700 wide the sidebar collapses to the rail.
    public static let windowDefaultWidth: CGFloat = 1280

    /// See ``windowDefaultWidth``.
    public static let windowDefaultHeight: CGFloat = 800

    /// See ``windowDefaultWidth``.
    public static let windowMinWidth: CGFloat = 900

    /// See ``windowDefaultWidth``.
    public static let windowMinHeight: CGFloat = 600

    // MARK: Stage (§5.1, R-35)

    /// 2 pt. The canvas seam between tiles in a grid. At this width `layer.canvas` reads as a seam
    /// between frames without a stroke, and the 3.3 L\* step is deliberately too small to read as
    /// a border (R-35).
    public static let tileGutter: CGFloat = 2

    /// 0 pt. The video wall is edge to edge.
    public static let wallGutter: CGFloat = 0

    /// 8 pt on all sides; 0 in cinema mode.
    public static let stageInset: CGFloat = 8

    /// 8 pt. The inset of a name chip, status cluster, HUD or hover toolbar from the tile's edge.
    public static let tileChromeInset: CGFloat = 8

    /// 32 pt. The floating tile hover toolbar.
    public static let tileToolbarHeight: CGFloat = 32

    /// 56 pt tall, max 720 pt wide, 32 pt from the bottom. The cinema control bar (§11.4).
    public static let cinemaBarHeight: CGFloat = 56

    /// See ``cinemaBarHeight``.
    public static let cinemaBarMaxWidth: CGFloat = 720

    /// See ``cinemaBarHeight``.
    public static let cinemaBarBottomInset: CGFloat = 32

    // MARK: Overlays (§5.1, §9.16, §9.17)

    /// 640 pt wide, max 520 pt tall, 132 pt from the window top. The command palette.
    public static let paletteWidth: CGFloat = 640

    /// See ``paletteWidth``.
    public static let paletteMaxHeight: CGFloat = 520

    /// See ``paletteWidth``.
    public static let paletteTopInset: CGFloat = 132

    /// 320 pt fixed. A toast card.
    public static let toastWidth: CGFloat = 320

    /// 20 pt from the bottom-trailing window corner; 8 pt between stacked toasts.
    public static let toastInset: CGFloat = 20

    /// See ``toastInset``.
    public static let toastGap: CGFloat = 8

    // MARK: Timeline (§9.14)

    /// 88 pt, single camera.
    public static let timelineHeight: CGFloat = 88

    /// 44 pt per lane, multi-camera.
    public static let timelineLaneHeight: CGFloat = 44

    // MARK: Hit targets (§10.6)

    /// 24 × 24 pt. The minimum interactive area, achieved with `.contentShape(.rect)` and negative
    /// padding even when the glyph is 11 pt.
    public static let minHitTarget: CGFloat = 24

    /// 32 × 32 pt. Tile chrome buttons are 28 pt visually with this `contentShape`, to be forgiving
    /// under a moving cursor.
    public static let videoHitTarget: CGFloat = 32

    // MARK: Rows

    /// List and table row heights.
    ///
    /// A **separate** token group from the five control heights: a 44 pt camera row with a
    /// micro-thumbnail and a sparkline is correct and a reviewer must not flag it (R-37). Both
    /// groups remain multiples of 4.
    @MainActor
    public enum Row {

        /// 44 pt. A sidebar camera row, with micro-thumbnail, status dot and motion spark.
        public static let camera: CGFloat = 44

        /// 36 pt. An event feed row.
        public static let event: CGFloat = 36

        /// 32 pt. An NVR channel row.
        public static let channel: CGFloat = 32

        /// 28 pt. A settings or inspector row; also a sidebar group/section child.
        public static let settings: CGFloat = 28

        /// 22 pt. A sidebar section header.
        public static let sectionHeader: CGFloat = 22
    }
}

// MARK: - Control geometry

extension VTheme.Metrics {

    /// Everything that follows from choosing one of the five control heights (§5.5).
    ///
    /// A component declares a ``Control`` and reads its height, radius, padding, type step and
    /// icon size from it, so that the five rows of the specification's table exist exactly once.
    @MainActor
    public struct Control {

        // MARK: - Stored Properties

        /// Visual height in points.
        public let height: CGFloat

        /// Corner radius; always applied through ``VTheme/Radius/shape(_:)``.
        public let radius: CGFloat

        /// Horizontal padding inside the control.
        public let horizontalPadding: CGFloat

        /// The type step for the control's label.
        public let type: VTheme.Typography.Step

        /// The icon point size that pairs with ``type``.
        public let icon: CGFloat

        /// The gap between a leading icon and its label.
        public let iconGap: CGFloat

        // MARK: - Computed Properties

        /// The square side of an icon-only button at this size, never below the 24 pt minimum.
        public var hitTarget: CGFloat {
            max(height, VTheme.Metrics.minHitTarget)
        }
    }

    /// 20 pt: tile HUD chips, table cells.
    public static let controlXS = Control(height: xs, radius: VTheme.Radius.sm,
                                          horizontalPadding: VTheme.Space.xs,
                                          type: VTheme.Typography.caption1,
                                          icon: VTheme.Icon.xs, iconGap: VTheme.Space.hair)

    /// 24 pt: inspector rows, segmented controls.
    public static let controlSM = Control(height: sm, radius: VTheme.Radius.sm,
                                          horizontalPadding: VTheme.Space.sm,
                                          type: VTheme.Typography.callout,
                                          icon: VTheme.Icon.sm, iconGap: VTheme.Space.xxs)

    /// 28 pt: **the default** — toolbar, forms, menus.
    public static let controlMD = Control(height: md, radius: VTheme.Radius.md,
                                          horizontalPadding: 10,
                                          type: VTheme.Typography.body,
                                          icon: VTheme.Icon.md, iconGap: VTheme.Space.xs)

    /// 32 pt: primary sheet actions, the search field.
    public static let controlLG = Control(height: lg, radius: VTheme.Radius.md,
                                          horizontalPadding: VTheme.Space.md,
                                          type: VTheme.Typography.body,
                                          icon: VTheme.Icon.lg, iconGap: VTheme.Space.xs)

    /// 40 pt: the empty-state call to action and the onboarding primary button.
    public static let controlXL = Control(height: xl, radius: VTheme.Radius.lg,
                                          horizontalPadding: VTheme.Space.lg,
                                          type: VTheme.Typography.title3,
                                          icon: VTheme.Icon.xl, iconGap: VTheme.Space.sm)

    /// The five, smallest to largest, for the token gallery.
    public static let allControls: [Control] = [controlXS, controlSM, controlMD, controlLG,
                                                controlXL]
}

#endif  // os(macOS)
