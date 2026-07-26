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
        case .brandMark: return "vigil.aperture"
        case .toggleSidebar: return "sidebar.leading"
        case .toggleInspector: return "sidebar.trailing"
        case .commandPalette: return "command"
        case .search: return "magnifyingglass"
        case .settings: return "gearshape"
        case .help: return "questionmark.circle"
        case .close: return "xmark"
        case .clear: return "xmark.circle.fill"
        case .disclosureCollapsed: return "chevron.right"
        case .disclosureExpanded: return "chevron.down"
        case .menuIndicator: return "chevron.up.chevron.down"
        case .overflow: return "ellipsis.circle"

        // Cameras
        case .camera: return "video"
        case .cameraOffline: return "video.slash"
        case .addCamera: return "plus"
        case .discover: return "antenna.radiowaves.left.and.right"
        case .device: return "externaldrive.connected.to.line.below"
        case .channel: return "rectangle.stack"
        case .group: return "folder"
        case .newGroup: return "folder.badge.plus"
        case .rename: return "pencil"
        case .delete: return "trash"
        case .reorderHandle: return "line.3.horizontal"
        case .credentials: return "key.horizontal"
        case .locked: return "lock"
        case .insecure: return "lock.open.trianglebadge.exclamationmark"

        // Layout and stage
        case .layoutSingle: return "square"
        case .layout2x2: return "square.grid.2x2"
        case .layout3x3: return "square.grid.3x3"
        case .layout4x4: return "square.grid.4x3.fill"
        case .layoutPicker: return "rectangle.grid.2x2"
        case .enterFullscreen: return "arrow.up.left.and.arrow.down.right"
        case .exitFullscreen: return "arrow.down.right.and.arrow.up.left"
        case .cinema: return "film"
        case .pictureInPicture: return "pip.enter"
        case .videoWall: return "display.2"
        case .patrol: return "play.square.stack"
        case .aspectFit: return "aspectratio"
        case .aspectFill: return "aspectratio.fill"
        case .mainstream: return "dial.high"
        case .substream: return "dial.low"

        // Media actions
        case .snapshot: return "camera"
        case .snapshotAll: return "camera.on.rectangle"
        case .copy: return "doc.on.doc"
        case .record: return "record.circle"
        case .recording: return "record.circle.fill"
        case .stop: return "stop.fill"
        case .mute: return "speaker.slash.fill"
        case .unmuted: return "speaker.wave.2.fill"
        case .pushToTalk: return "mic"
        case .exportClip: return "square.and.arrow.up"
        case .trim: return "scissors"
        case .importFile: return "square.and.arrow.down"

        // Playback
        case .play: return "play.fill"
        case .pause: return "pause.fill"
        case .back10: return "gobackward.10"
        case .forward10: return "goforward.10"
        case .frameBack: return "backward.frame.fill"
        case .frameForward: return "forward.frame.fill"
        case .speed: return "speedometer"
        case .reverse: return "backward.fill"
        case .jumpToLive: return "forward.end.alt.fill"
        case .datePicker: return "calendar"
        case .clock: return "clock"
        case .uptime: return "clock.arrow.circlepath"
        case .bookmark: return "bookmark"
        case .synchronisedPlayback: return "link"

        // PTZ
        case .ptzPad: return "vigil.ptz.joystick"
        case .zoomIn: return "plus.magnifyingglass"
        case .zoomOut: return "minus.magnifyingglass"
        case .focusControl: return "viewfinder.circle"
        case .iris: return "camera.aperture"
        case .preset: return "star"
        case .setPreset: return "star.square.on.square"
        case .ptzPatrol: return "arrow.triangle.capsulepath"
        case .homePosition: return "house"
        case .positioning3D: return "viewfinder.rectangular"

        // Image settings
        case .imagePanel: return "slider.horizontal.3"
        case .brightness: return "sun.max"
        case .contrast: return "circle.lefthalf.filled"
        case .saturation: return "drop"
        case .sharpness: return "camera.filters"
        case .wideDynamicRange: return "sun.haze"
        case .dayNight: return "moon.stars"
        case .infraredIlluminator: return "flashlight.on.fill"
        case .flip: return "arrow.left.and.right.righttriangle.left.righttriangle.right"

        // Events and alarms
        case .events: return "bell"
        case .newEvents: return "bell.badge"
        case .motionDetection: return "figure.walk"
        case .lineCrossing: return "line.diagonal"
        case .intrusion: return "rectangle.dashed"
        case .tamper: return "hand.raised.slash"
        case .videoLoss: return "video.slash"
        case .diskError: return "externaldrive.badge.exclamationmark"
        case .notificationSettings: return "bell.and.waves.left.and.right"

        // Diagnostics and telemetry
        case .streamDoctor: return "stethoscope"
        case .healthGraph: return "waveform.path.ecg"
        case .hardwareDecode: return "bolt.fill"
        case .softwareDecode: return "bolt"
        case .cpu: return "cpu"
        case .network: return "network"
        case .signal: return "wifi"
        case .packetLoss: return "chart.line.downtrend.xyaxis"
        case .latency: return "timer"
        case .storage: return "internaldrive"
        case .reconnecting: return "arrow.triangle.2.circlepath"
        case .exportDiagnostics: return "doc.text.magnifyingglass"
        case .logLevel: return "text.alignleft"
        case .reset: return "arrow.counterclockwise"

        // Status and feedback
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .info: return "info.circle"
        case .statusDot: return "circle.fill"
        case .authFailure: return "lock.trianglebadge.exclamationmark"
        case .dropTarget: return "arrow.down.to.line"
        case .keyboardShortcuts: return "keyboard"
        case .appearance: return "circle.lefthalf.filled"
        case .launchAtLogin: return "power"
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
            return name + ".fill"
        default:
            return name
        }
    }

    /// The glyph used for the opposite or active state, where §8.3's *Variant* column says `alt`.
    ///
    /// These are the pairs that swap with `.contentTransition(.symbolEffect(.replace.downUp))`:
    /// play ↔ pause, mute ↔ unmuted, fit ↔ fill, mainstream ↔ substream, PiP enter ↔ exit,
    /// disclosure collapsed ↔ expanded (which **rotates** instead — see §8.3).
    public var alternateName: String? {
        switch self {
        case .play: return "pause.fill"
        case .pause: return "play.fill"
        case .mute: return "speaker.wave.2.fill"
        case .unmuted: return "speaker.slash.fill"
        case .aspectFit: return "aspectratio.fill"
        case .aspectFill: return "aspectratio"
        case .mainstream: return "dial.low"
        case .substream: return "dial.high"
        case .pictureInPicture: return "pip.exit"
        case .disclosureCollapsed: return "chevron.down"
        case .disclosureExpanded: return "chevron.right"
        case .record: return "record.circle.fill"
        case .hardwareDecode: return "bolt"
        case .softwareDecode: return "bolt.fill"
        case .zoomIn: return "minus.magnifyingglass"
        case .zoomOut: return "plus.magnifyingglass"
        case .preset: return "star.fill"
        case .bookmark: return "bookmark.fill"
        case .pushToTalk: return "mic.fill"
        default: return nil
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
            return .semibold
        case .brandMark, .ptzPad:
            return .regular
        default:
            return .medium
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
            return .hierarchical
        case .record, .events, .newEvents:
            return .palette
        default:
            return .monochrome
        }
    }

    /// Whether this is one of the two custom symbols shipped in `Symbols.xcassets` (§8.5).
    ///
    /// ⛔ There are no others. A concept that SF Symbols lacks gets a drawn `Canvas`/`Shape` such
    /// as `VLayoutGlyph`, not a new symbol — symbols must stay maintainable across SF Symbols
    /// releases.
    public var isCustom: Bool {
        switch self {
        case .brandMark, .ptzPad: return true
        default: return false
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
