//
//  VTheme+Icon.swift
//  VigilUI
//
//  Icon sizes, weights and label gaps, plus the action → SF Symbol map as a typed enum so no view
//  ever writes a symbol name as a string literal.
//  macOS-only. See docs/DESIGN.md §8 and docs/API_CONTRACT.md §4.11.
//

#if os(macOS)

import SwiftUI

// MARK: - Icon sizes

extension VTheme.Icon {

    /// 11 pt, `.semibold`. Pairs with `Caption1`/`Caption2`; 2 pt gap to the label.
    public static let xs: CGFloat = 11

    /// 12 pt, `.medium`. Pairs with `Callout`; 4 pt gap.
    public static let sm: CGFloat = 12

    /// 13 pt, `.medium`. Pairs with `Body`/`Headline`; 6 pt gap. **The default.**
    public static let md: CGFloat = 13

    /// 15 pt, `.medium`. Pairs with `Title3`; 6 pt gap.
    public static let lg: CGFloat = 15

    /// 17 pt, `.regular`. Pairs with `Title2`/`Title1`; 8 pt gap.
    public static let xl: CGFloat = 17

    /// 32 pt, `.light`. Empty states and connecting rings; centred.
    public static let hero: CGFloat = 32

    /// 18 pt. The menu-bar extra, drawn as a template image in an 18 × 18 box.
    public static let brand: CGFloat = 18

    /// Every size in order, for the token gallery.
    public static let all: [CGFloat] = [xs, sm, md, lg, xl, hero, brand]

    /// The weight paired with each icon size (§8.1).
    ///
    /// ⛔ Icon weight is never heavier than the adjacent text weight, and never `.bold` above
    /// 13 pt — heavy SF Symbols at large sizes look like clip art.
    @MainActor
    public enum Weight {

        /// `.semibold`, for 11 pt beside `Caption1`/`Caption2`.
        public static let xs: Font.Weight = .semibold

        /// `.medium`, for 12 pt beside `Callout`.
        public static let sm: Font.Weight = .medium

        /// `.medium`, for 13 pt beside `Body`/`Headline`.
        public static let md: Font.Weight = .medium

        /// `.medium`, for 15 pt beside `Title3`.
        public static let lg: Font.Weight = .medium

        /// `.regular`, for 17 pt beside `Title2`/`Title1`.
        public static let xl: Font.Weight = .regular

        /// `.light`, for the 32 pt hero glyph.
        public static let hero: Font.Weight = .light
    }

    /// The gap between a leading glyph and its label, per icon size (§8.1).
    @MainActor
    public enum Gap {

        /// 2 pt, at `xs`.
        public static let xs: CGFloat = 2

        /// 4 pt, at `sm`.
        public static let sm: CGFloat = 4

        /// 6 pt, at `md` and `lg`.
        public static let md: CGFloat = 6

        /// See ``md``.
        public static let lg: CGFloat = 6

        /// 8 pt, at `xl`.
        public static let xl: CGFloat = 8
    }

    /// The font that sizes a symbol exactly.
    ///
    /// Symbols are sized with `Font.system(size:weight:)` on the `Image` and **not** with
    /// `.imageScale`, so that the size is exact rather than relative to the inherited text style
    /// (§8.1).
    public static func font(_ size: CGFloat, weight: Font.Weight) -> Font {
        Font.system(size: size, weight: weight)
    }
}

// MARK: - Symbol

extension VTheme {

    /// Every icon in Vigil, as a case rather than a string (§8.3).
    ///
    /// A typed enum rather than a raw-value enum because several concepts legitimately share a
    /// glyph — `video.slash` is both "camera offline" and "video loss", `circle.lefthalf.filled` is
    /// both "contrast" and "appearance" — and a `String` raw value would have to be unique.
    ///
    /// ⛔ `.multicolor` rendering is forbidden outside the Settings pane icons and the About window
    /// (§8.2), so ``rendering`` never returns it. Layout pickers use `VLayoutGlyph` miniatures
    /// rather than approximate grid symbols; the layout cases here are for the menu bar, where a
    /// drawn glyph is not available (§8.3).
    public enum Symbol: CaseIterable {

        // App and navigation
        case brandMark, toggleSidebar, toggleInspector, commandPalette, search, settings, help
        case close, clear, disclosureCollapsed, disclosureExpanded, menuIndicator, overflow

        // Cameras
        case camera, cameraOffline, addCamera, discover, device, channel, group, newGroup
        case rename, delete, reorderHandle, credentials, locked, insecure

        // Layout and stage
        case layoutSingle, layout2x2, layout3x3, layout4x4, layoutPicker
        case enterFullscreen, exitFullscreen, cinema, pictureInPicture, videoWall, patrol
        case aspectFit, aspectFill, mainstream, substream

        // Media actions
        case snapshot, snapshotAll, copy, record, recording, stop, mute, unmuted, pushToTalk
        case exportClip, trim, importFile

        // Playback
        case play, pause, back10, forward10, frameBack, frameForward, speed, reverse, jumpToLive
        case datePicker, clock, uptime, bookmark, synchronisedPlayback

        // PTZ
        case ptzPad, zoomIn, zoomOut, focusControl, iris, preset, setPreset, ptzPatrol
        case homePosition, positioning3D

        // Image settings
        case imagePanel, brightness, contrast, saturation, sharpness, wideDynamicRange
        case dayNight, infraredIlluminator, flip

        // Events and alarms
        case events, newEvents, motionDetection, lineCrossing, intrusion, tamper, videoLoss
        case diskError, notificationSettings

        // Diagnostics and telemetry
        case streamDoctor, healthGraph, hardwareDecode, softwareDecode, cpu, network, signal
        case packetLoss, latency, storage, reconnecting, exportDiagnostics, logLevel, reset

        // Status and feedback
        case success, warning, error, info, statusDot, authFailure, dropTarget
        case keyboardShortcuts, appearance, launchAtLogin
    }
}

// MARK: - Symbol names

extension VTheme.Symbol {

    /// The base SF Symbol name.
    ///
    /// `vigil.aperture` and `vigil.ptz.joystick` are the two custom symbols, authored as SF Symbols
    /// 5 templates in `VigilUI/Resources/Symbols.xcassets`; custom symbols resolve through the
    /// asset catalogue when passed to `Image(systemName:)` and honour `foregroundStyle`,
    /// `imageScale` and `symbolRenderingMode` exactly like system symbols (§8.5).
    public var name: String {
        switch self {
        // App and navigation
        case .brandMark: "vigil.aperture"
        case .toggleSidebar: "sidebar.leading"
        case .toggleInspector: "sidebar.trailing"
        case .commandPalette: "command"
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        case .help: "questionmark.circle"
        case .close: "xmark"
        case .clear: "xmark.circle.fill"
        case .disclosureCollapsed: "chevron.right"
        case .disclosureExpanded: "chevron.down"
        case .menuIndicator: "chevron.up.chevron.down"
        case .overflow: "ellipsis.circle"

        // Cameras
        case .camera: "video"
        case .cameraOffline: "video.slash"
        case .addCamera: "plus"
        case .discover: "antenna.radiowaves.left.and.right"
        case .device: "externaldrive.connected.to.line.below"
        case .channel: "rectangle.stack"
        case .group: "folder"
        case .newGroup: "folder.badge.plus"
        case .rename: "pencil"
        case .delete: "trash"
        case .reorderHandle: "line.3.horizontal"
        case .credentials: "key.horizontal"
        case .locked: "lock"
        case .insecure: "lock.open.trianglebadge.exclamationmark"

        // Layout and stage
        case .layoutSingle: "square"
        case .layout2x2: "square.grid.2x2"
        case .layout3x3: "square.grid.3x3"
        case .layout4x4: "square.grid.4x3.fill"
        case .layoutPicker: "rectangle.grid.2x2"
        case .enterFullscreen: "arrow.up.left.and.arrow.down.right"
        case .exitFullscreen: "arrow.down.right.and.arrow.up.left"
        case .cinema: "film"
        case .pictureInPicture: "pip.enter"
        case .videoWall: "display.2"
        case .patrol: "play.square.stack"
        case .aspectFit: "aspectratio"
        case .aspectFill: "aspectratio.fill"
        case .mainstream: "dial.high"
        case .substream: "dial.low"

        // Media actions
        case .snapshot: "camera"
        case .snapshotAll: "camera.on.rectangle"
        case .copy: "doc.on.doc"
        case .record: "record.circle"
        case .recording: "record.circle.fill"
        case .stop: "stop.fill"
        case .mute: "speaker.slash.fill"
        case .unmuted: "speaker.wave.2.fill"
        case .pushToTalk: "mic"
        case .exportClip: "square.and.arrow.up"
        case .trim: "scissors"
        case .importFile: "square.and.arrow.down"

        // Playback
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .back10: "gobackward.10"
        case .forward10: "goforward.10"
        case .frameBack: "backward.frame.fill"
        case .frameForward: "forward.frame.fill"
        case .speed: "speedometer"
        case .reverse: "backward.fill"
        case .jumpToLive: "forward.end.alt.fill"
        case .datePicker: "calendar"
        case .clock: "clock"
        case .uptime: "clock.arrow.circlepath"
        case .bookmark: "bookmark"
        case .synchronisedPlayback: "link"

        // PTZ
        case .ptzPad: "vigil.ptz.joystick"
        case .zoomIn: "plus.magnifyingglass"
        case .zoomOut: "minus.magnifyingglass"
        case .focusControl: "viewfinder.circle"
        case .iris: "camera.aperture"
        case .preset: "star"
        case .setPreset: "star.square.on.square"
        case .ptzPatrol: "arrow.triangle.capsulepath"
        case .homePosition: "house"
        case .positioning3D: "viewfinder.rectangular"

        // Image settings
        case .imagePanel: "slider.horizontal.3"
        case .brightness: "sun.max"
        case .contrast: "circle.lefthalf.filled"
        case .saturation: "drop"
        case .sharpness: "camera.filters"
        case .wideDynamicRange: "sun.haze"
        case .dayNight: "moon.stars"
        case .infraredIlluminator: "flashlight.on.fill"
        case .flip: "arrow.left.and.right.righttriangle.left.righttriangle.right"

        // Events and alarms
        case .events: "bell"
        case .newEvents: "bell.badge"
        case .motionDetection: "figure.walk"
        case .lineCrossing: "line.diagonal"
        case .intrusion: "rectangle.dashed"
        case .tamper: "hand.raised.slash"
        case .videoLoss: "video.slash"
        case .diskError: "externaldrive.badge.exclamationmark"
        case .notificationSettings: "bell.and.waves.left.and.right"

        // Diagnostics and telemetry
        case .streamDoctor: "stethoscope"
        case .healthGraph: "waveform.path.ecg"
        case .hardwareDecode: "bolt.fill"
        case .softwareDecode: "bolt"
        case .cpu: "cpu"
        case .network: "network"
        case .signal: "wifi"
        case .packetLoss: "chart.line.downtrend.xyaxis"
        case .latency: "timer"
        case .storage: "internaldrive"
        case .reconnecting: "arrow.triangle.2.circlepath"
        case .exportDiagnostics: "doc.text.magnifyingglass"
        case .logLevel: "text.alignleft"
        case .reset: "arrow.counterclockwise"

        // Status and feedback
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .info: "info.circle"
        case .statusDot: "circle.fill"
        case .authFailure: "lock.trianglebadge.exclamationmark"
        case .dropTarget: "arrow.down.to.line"
        case .keyboardShortcuts: "keyboard"
        case .appearance: "circle.lefthalf.filled"
        case .launchAtLogin: "power"
        }
    }

    /// The filled variant, where §8.3's *Variant* column specifies one; otherwise ``name``.
    ///
    /// Used for the "active" state of a toggling control: `gearshape` → `gearshape.fill` while the
    /// Settings window is frontmost, `video` → `video.fill` while a camera is live, and so on.
    public var filledName: String {
        switch self {
        case .settings, .camera, .cameraOffline, .group, .credentials, .locked, .cinema,
             .patrol, .mainstream, .substream, .snapshot, .saturation, .wideDynamicRange,
             .dayNight, .events, .tamper, .videoLoss, .info, .preset, .bookmark, .pushToTalk:
            name + ".fill"
        default:
            name
        }
    }

    /// The glyph used for the opposite or active state, where §8.3's *Variant* column says `alt`.
    ///
    /// These are the pairs that swap with `.contentTransition(.symbolEffect(.replace.downUp))`:
    /// play ↔ pause, mute ↔ unmuted, fit ↔ fill, mainstream ↔ substream, PiP enter ↔ exit,
    /// disclosure collapsed ↔ expanded (which **rotates** instead — see §8.3).
    public var alternateName: String? {
        switch self {
        case .play: "pause.fill"
        case .pause: "play.fill"
        case .mute: "speaker.wave.2.fill"
        case .unmuted: "speaker.slash.fill"
        case .aspectFit: "aspectratio.fill"
        case .aspectFill: "aspectratio"
        case .mainstream: "dial.low"
        case .substream: "dial.high"
        case .pictureInPicture: "pip.exit"
        case .disclosureCollapsed: "chevron.down"
        case .disclosureExpanded: "chevron.right"
        case .record: "record.circle.fill"
        case .hardwareDecode: "bolt"
        case .softwareDecode: "bolt.fill"
        case .zoomIn: "minus.magnifyingglass"
        case .zoomOut: "plus.magnifyingglass"
        case .preset: "star.fill"
        case .bookmark: "bookmark.fill"
        case .pushToTalk: "mic.fill"
        default: nil
        }
    }
}

// MARK: - Symbol appearance

extension VTheme.Symbol {

    /// The stroke weight from §8.3's *Weight* column; `.medium` unless the table says otherwise.
    public var weight: Font.Weight {
        switch self {
        case .commandPalette, .close, .addCamera, .disclosureCollapsed, .disclosureExpanded,
             .menuIndicator, .lineCrossing, .hardwareDecode, .softwareDecode:
            .semibold
        case .brandMark, .ptzPad:
            .regular
        default:
            .medium
        }
    }

    /// The rendering mode from §8.3's *Mode* column.
    ///
    /// `.monochrome` for roughly 90 % of the app, tinted by `foregroundStyle` from a text token;
    /// `.hierarchical` for multi-layer glyphs where depth aids recognition; `.palette` for the
    /// exactly two-tone status glyphs whose badge carries a different semantic colour — the caller
    /// supplies the two styles (`bell.badge`: glyph `text.secondary`, badge `motion`;
    /// `record.circle`: ring `text.secondary`, dot `live`).
    public var rendering: SymbolRenderingMode {
        switch self {
        case .cameraOffline, .device, .insecure, .videoWall, .snapshotAll, .focusControl, .iris,
             .setPreset, .sharpness, .wideDynamicRange, .dayNight, .diskError,
             .notificationSettings, .cpu, .network, .storage, .exportDiagnostics:
            .hierarchical
        case .record, .events, .newEvents:
            .palette
        default:
            .monochrome
        }
    }

    /// Whether this is one of the two custom symbols shipped in `Symbols.xcassets` (§8.5).
    ///
    /// ⛔ There are no others. A concept that SF Symbols lacks gets a drawn `Canvas`/`Shape` such
    /// as `VLayoutGlyph`, not a new symbol — symbols must stay maintainable across SF Symbols
    /// releases.
    public var isCustom: Bool {
        switch self {
        case .brandMark, .ptzPad: true
        default: false
        }
    }

    /// The `Image` for this symbol.
    ///
    /// Size it with `.font(VTheme.Icon.font(_:weight:))` rather than `.imageScale`, and tint it
    /// with `.foregroundStyle(_:)` from a `VTheme.Color` token.
    ///
    /// - Parameters:
    ///   - filled: use ``filledName`` instead of ``name``.
    ///   - alternate: use ``alternateName`` when one exists; ignored otherwise.
    public func image(filled: Bool = false, alternate: Bool = false) -> Image {
        if alternate, let other = alternateName {
            return Image(systemName: other)
        }
        return Image(systemName: filled ? filledName : name)
    }
}

// MARK: - View modifiers

extension View {

    /// Sizes and weights a symbol exactly, per §8.1.
    ///
    /// Pass the icon size that pairs with the adjacent type step — `VTheme.Icon.md` beside `Body`,
    /// `VTheme.Icon.xs` beside `Caption1`, and so on — together with the matching
    /// `VTheme.Icon.Weight` constant.
    @MainActor
    package func vIcon(size: CGFloat = VTheme.Icon.md,
                       weight: Font.Weight = VTheme.Icon.Weight.md) -> some View {
        self.font(VTheme.Icon.font(size, weight: weight))
    }
}

#endif  // os(macOS)
