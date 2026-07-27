//
//  VCommandPaletteView.swift
//  VigilUI
//
//  The ⌘K command palette: a detached E2 card near the top of the window with a borderless query
//  field, ranked results cut into sections, and ↑ ↓ ⏎ ⎋ over them. The ranking and the selection
//  arithmetic live in `VCommand.swift`; this file draws them and owns nothing else.
//  macOS-only. Implements docs/UX.md §3.2 (the palette) and docs/DESIGN.md §2.3 and §6.5 (a
//  detached surface takes the glass recipe, never the header material), §9.26 (key cap),
//  §9.28 (focus), §10.5 (state carried by shape, not only by hue).
//

#if os(macOS)

import SwiftUI

// MARK: - VPaletteMetrics

/// The palette's own geometry — the numbers that belong to this one overlay.
///
/// A separate namespace for the reason ``VToolbarMetrics`` gives: these are a component's
/// internals, not tokens shared across the app. Everything that *is* a token — the card's width,
/// its maximum height, its inset from the top of the window, every space, radius and colour — comes
/// from `VTheme` and is not restated here.
@MainActor
package enum VPaletteMetrics {

    /// A result row is 40 pt tall — `VTheme.Metrics.xl`, the same step the empty state's call to
    /// action stands at, and tall enough for a title over a subtitle.
    package static var rowHeight: CGFloat { VTheme.Metrics.xl }

    /// A section header is 22 pt — `VTheme.Metrics.Row.sectionHeader`, the height the sidebar's
    /// group headers already use, so the two lists scan alike.
    package static var headerHeight: CGFloat { VTheme.Metrics.Row.sectionHeader }

    /// The query field's row, 52 pt — `VTheme.Metrics.toolbarHeight`, which is deliberate: the
    /// palette's field lines up with the toolbar's when both are on screen.
    package static var fieldHeight: CGFloat { VTheme.Metrics.toolbarHeight }

    /// 18 × 18 pt minimum for a key cap, growing with its caption (§9.26).
    package static let keyCapSide: CGFloat = 18

    /// 5 pt horizontal padding for a multi-character cap such as `⌘K`.
    package static let keyCapPadding: CGFloat = 5

    /// `white α 0.08` — §9.26's key-cap fill.
    package static let keyCapFillAlpha: Double = 0.08

    /// A disabled row's opacity. It is still legible, which is the point of listing it.
    package static let disabledOpacity: Double = 0.45
}

// MARK: - VCommandPaletteView

/// The ⌘K overlay.
///
/// ## What it owns
///
/// Nothing but the cursor. The query, the selected command, the catalogue and every action arrive
/// as a `let` or a `Binding`, so the same view serves the app, the previews and a screenshot
/// harness. The one exception is the field's `@FocusState`, which cannot be lifted out without
/// making the whole view generic — the same exception, for the same reason, that ``VToolbarView``
/// makes for its search field.
///
/// The ranking is not computed here either: ``VCommandQuery`` does it, and this view draws
/// ``VCommandQuery/groups(_:)`` in order and moves the selection with
/// ``VCommandQuery/selection(movingBy:from:in:)``. Keeping the arithmetic outside the body is what
/// makes it possible to prove that `Return` runs the row that is highlighted.
///
/// ## The surface
///
/// DESIGN.md §2.3 gives *detached* surfaces — palette, popovers, toasts — the `.hudWindow` glass of
/// §6.5, not the toolbar's `.headerView`. It is applied through `vElevation(.e2, over: .chrome)`
/// rather than by hand, because §12.4 bans shadow and material constructions outside the elevation
/// appliers. `reduceTransparency` and `increaseContrast` are resolved inside that applier, so this
/// file does not restate the fallback rule.
@MainActor
package struct VCommandPaletteView: View {

    // MARK: - Stored Properties

    /// Everything the palette can run, in catalogue order. Ties in the ranking fall back to this
    /// order, so it is worth putting the commands an operator reaches for most near the front.
    package let commands: [VCommand]

    /// The query as typed.
    @Binding package var query: String

    /// The selected command's ``VCommand/id``, or `nil` when nothing is selected.
    ///
    /// The **command**, not the row index: typing one more character re-ranks the list, and a
    /// remembered index would move the highlight onto a different action under the user's finger.
    @Binding package var selection: String?

    /// Runs a command. The caller dismisses the palette; this view does not assume it should.
    package let onRun: (VCommand) -> Void

    /// Closes the palette — `⎋`, or a click on the scrim.
    package let onDismiss: () -> Void

    @Environment(\.vMotionEnabled) private var motionEnabled
    @FocusState private var isFieldFocused: Bool

    // MARK: - Initialisation

    /// Creates the palette.
    ///
    /// - Parameters:
    ///   - commands: the catalogue.
    ///   - query: the bound query text.
    ///   - selection: the bound selected command id.
    ///   - onRun: performed on `Return`, or on a click on a row.
    ///   - onDismiss: performed on `⎋` or a scrim click.
    package init(commands: [VCommand],
                 query: Binding<String>,
                 selection: Binding<String?>,
                 onRun: @escaping (VCommand) -> Void = { _ in },
                 onDismiss: @escaping () -> Void = {}) {
        self.commands = commands
        self._query = query
        self._selection = selection
        self.onRun = onRun
        self.onDismiss = onDismiss
    }

    // MARK: - View

    package var body: some View {
        // Ranked once per body, then handed to both the drawing and the key handling. Two calls
        // would be two chances for the highlighted row and the run row to disagree.
        let groups = VCommandQuery(query).groups(commands)
        let rows = VCommandQuery.flattened(groups)
        return ZStack(alignment: .top) {
            scrim
            card(groups: groups, rows: rows)
        }
        .onExitCommand(perform: onDismiss)
        .onMoveCommand { direction in move(direction, in: rows) }
        .onAppear { isFieldFocused = true }
        .onChange(of: query) { _, _ in
            // A re-rank can strand the selection on a row that no longer exists. Snapping to the
            // new best match is what makes typing feel continuous rather than losing the highlight.
            selection = VCommandQuery.firstSelectable(in: rows)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Command palette", bundle: .vigilUI))
    }

    /// The dimming behind the card. A click on it dismisses, which is the one gesture every macOS
    /// overlay owes its user.
    private var scrim: some View {
        VTheme.Color.Scrim.modal
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: onDismiss)
            .accessibilityHidden(true)
    }

    /// The card itself.
    private func card(groups: [VCommandGroup], rows: [VCommandMatch]) -> some View {
        VStack(spacing: 0) {
            field
            fieldSeparator
            results(groups: groups, rows: rows)
        }
        .frame(width: VTheme.Metrics.paletteWidth)
        .vElevation(VTheme.Elevation.e2, radius: VTheme.Radius.lg, over: .chrome)
        .padding(.top, VTheme.Metrics.paletteTopInset)
    }

    // MARK: - The field

    /// The query field: a leading `command` glyph, a borderless input, a trailing `esc` cap.
    ///
    /// Borderless and without a well on purpose. ``VTextField`` draws a label above and reserves a
    /// 16 pt message row below, both of which are right for a form and wrong for the top of a
    /// palette, where the card's own edge is already the field's boundary.
    private var field: some View {
        HStack(spacing: VTheme.Space.sm) {
            VTheme.Symbol.commandPalette.image()
                .vIcon(size: VTheme.Icon.lg, weight: VTheme.Symbol.commandPalette.weight)
                .foregroundStyle(VTheme.Color.Text.secondary)
                .accessibilityHidden(true)
            TextField(text: $query, prompt: prompt) {
                Text("Type a command", bundle: .vigilUI)
            }
            .labelsHidden()
            .textFieldStyle(.plain)
            .focused($isFieldFocused)
            .focusEffectDisabled()
            .vType(VTheme.Typography.title3)
            .foregroundStyle(VTheme.Color.Text.primary)
            // `.tint` is what colours the insertion point and the selection on macOS (§9.5).
            .tint(VTheme.Color.Semantic.accent)
            .autocorrectionDisabled()
            .onSubmit { run() }
            if !query.isEmpty {
                clearButton
            }
            VPaletteKeyCap(label: "esc")
        }
        .padding(.horizontal, VTheme.Space.lg)
        .frame(height: VPaletteMetrics.fieldHeight)
    }

    private var prompt: Text {
        Text("Type a command", bundle: .vigilUI)
            .foregroundStyle(VTheme.Color.Text.tertiary)
    }

    private var clearButton: some View {
        Button {
            query = ""
        } label: {
            VTheme.Symbol.clear.image()
                .vIcon(size: VTheme.Icon.md, weight: VTheme.Icon.Weight.md)
                .foregroundStyle(VTheme.Color.Text.tertiary)
                .frame(width: VTheme.Metrics.minHitTarget,
                       height: VTheme.Metrics.minHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Clear search", bundle: .vigilUI))
        .transition(.opacity)
    }

    /// ⛔ Never `Divider()`, whose colour and inset are not ours (§5.4).
    private var fieldSeparator: some View {
        Rectangle()
            .fill(VTheme.Color.Stroke.subtle)
            .frame(height: VTheme.Border.thin)
            .allowsHitTesting(false)
    }

    // MARK: - Results

    @ViewBuilder
    private func results(groups: [VCommandGroup], rows: [VCommandMatch]) -> some View {
        if rows.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.matches) { match in
                                    row(match)
                                }
                            } header: {
                                sectionHeader(group.category)
                            }
                        }
                    }
                    .padding(.vertical, VTheme.Space.xs)
                }
                .frame(maxHeight: VTheme.Metrics.paletteMaxHeight)
                .onChange(of: selection) { _, moved in
                    guard let moved else { return }
                    withAnimation(VTheme.Motion.resolved(VTheme.Motion.snap,
                                                         reduced: !motionEnabled)) {
                        proxy.scrollTo(moved, anchor: .center)
                    }
                }
            }
        }
    }

    /// A pinned section header. The label is a literal per case rather than a stored key, because
    /// a `LocalizedStringKey` built from a variable is invisible to the localisation checker and
    /// would ship untranslated.
    private func sectionHeader(_ category: VCommandCategory) -> some View {
        categoryLabel(category)
            // `caption2` is the section-eyebrow step and already carries `.textCase(.uppercase)`;
            // restating it here would be a second place for the two to disagree.
            .vType(VTheme.Typography.caption2)
            .foregroundStyle(VTheme.Color.Text.tertiary)
            .padding(.horizontal, VTheme.Space.lg)
            .frame(height: VPaletteMetrics.headerHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VTheme.Color.Layer.surface)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func categoryLabel(_ category: VCommandCategory) -> some View {
        switch category {
        case .layout: Text("Layout", bundle: .vigilUI)
        case .view: Text("View", bundle: .vigilUI)
        case .camera: Text("Camera", bundle: .vigilUI)
        case .recording: Text("Recording", bundle: .vigilUI)
        case .application: Text("Application", bundle: .vigilUI)
        }
    }

    /// One result.
    ///
    /// Selection is drawn as a **filled** row rather than as a tinted title, so the state survives
    /// `differentiateWithoutColor` (§10.5) — the same substitution ``VToolbarView`` makes for its
    /// active toggles.
    private func row(_ match: VCommandMatch) -> some View {
        let isSelected = selection == match.id
        let isEnabled = match.command.isEnabled
        return Button {
            guard isEnabled else { return }
            onRun(match.command)
        } label: {
            HStack(spacing: VTheme.Space.sm) {
                VStack(alignment: .leading, spacing: 0) {
                    titleText(match)
                        .vType(VTheme.Typography.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let subtitle = match.command.subtitle {
                        Text(verbatim: subtitle)
                            .vType(VTheme.Typography.caption1)
                            .foregroundStyle(VTheme.Color.Text.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: VTheme.Space.sm)
                if let shortcut = match.command.shortcut {
                    VPaletteKeyCap(label: shortcut)
                }
            }
            .foregroundStyle(VTheme.Color.Text.primary)
            .padding(.horizontal, VTheme.Space.lg)
            .frame(height: VPaletteMetrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? VTheme.Color.Semantic.Tint.selected : SwiftUI.Color.clear,
                        in: VTheme.Radius.shape(VTheme.Radius.sm))
            .padding(.horizontal, VTheme.Space.xs)
            .opacity(isEnabled ? 1 : VPaletteMetrics.disabledOpacity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        // Hovering moves the keyboard selection too, so the pointer and the arrow keys can never
        // point at two different rows at once.
        .onHover { hovering in
            if hovering, isEnabled { selection = match.id }
        }
        .id(match.id)
        .accessibilityLabel(Text(verbatim: match.command.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The title, with the matched characters emboldened in `accent`.
    ///
    /// Falls back to the plain title when ``VCommandMatch/canHighlight`` is `false` — see that
    /// property for why a wrong highlight is worse than no highlight.
    private func titleText(_ match: VCommandMatch) -> Text {
        guard match.canHighlight, !match.titleOffsets.isEmpty else {
            return Text(verbatim: match.command.title)
        }
        let hits = Set(match.titleOffsets)
        var out = Text(verbatim: "")
        for (index, character) in match.command.title.enumerated() {
            let piece = Text(verbatim: String(character))
            out = out + (hits.contains(index)
                ? piece.foregroundStyle(VTheme.Color.Semantic.accent).bold()
                : piece)
        }
        return out
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: VTheme.Space.sm) {
            VTheme.Symbol.search.image()
                .vIcon(size: VTheme.Icon.hero, weight: VTheme.Icon.Weight.hero)
                .foregroundStyle(VTheme.Color.Text.tertiary)
                .accessibilityHidden(true)
            Text("No matching commands", bundle: .vigilUI)
                .vType(VTheme.Typography.title3)
                .foregroundStyle(VTheme.Color.Text.primary)
            Text("Try a camera name, a layout, or a recording action.", bundle: .vigilUI)
                .vType(VTheme.Typography.body)
                .foregroundStyle(VTheme.Color.Text.secondary)
                .multilineTextAlignment(.center)
            VButton("Clear search", style: .secondary, size: .sm) {
                query = ""
            }
            .padding(.top, VTheme.Space.xxs)
        }
        .padding(.horizontal, VTheme.Space.xl)
        .padding(.vertical, VTheme.Space.huge)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Keyboard

    /// `↑` and `↓` walk the rows; `←` and `→` belong to the text field and are left alone.
    private func move(_ direction: MoveCommandDirection, in rows: [VCommandMatch]) {
        switch direction {
        case .up:
            selection = VCommandQuery.selection(movingBy: -1, from: selection, in: rows)
        case .down:
            selection = VCommandQuery.selection(movingBy: 1, from: selection, in: rows)
        default:
            break
        }
    }

    /// `Return`. Runs the selected command, or the best match when nothing is selected yet, and
    /// does nothing at all when neither is runnable — an empty palette must not fire the last
    /// command the user happened to leave highlighted.
    private func run() {
        let rows = VCommandQuery.flattened(VCommandQuery(query).groups(commands))
        let target = selection ?? VCommandQuery.firstSelectable(in: rows)
        guard let command = VCommandQuery.runnable(target, in: rows) else { return }
        onRun(command)
    }
}

// MARK: - VPaletteKeyCap

/// §9.26's key cap: an 18 pt minimum square, `radius.xs` 4, `white α 0.08` with a hairline.
///
/// ⚠️ §9.26 also asks for a 1 pt **bottom** inner shadow. `VInnerHighlight` draws a top edge only,
/// and inventing a second gradient here would put a shadow construction outside the elevation
/// appliers, which §12.4 bans. Left out — the same call, and the same report, that
/// `VToolbarView`'s own cap makes.
///
/// A near-twin of that private `VToolbarKeyCap`. Not shared, because the manifest gives
/// `Components/` ownership of any cross-directory component and claiming that name from here would
/// collide with whoever writes it; this one is `package` so the palette and the overflow menu can
/// both draw a shortcut without a third copy appearing.
///
/// The caption is `Text(verbatim:)` — `esc` and `⌘K` are key names, and a key name is not
/// translated.
@MainActor
package struct VPaletteKeyCap: View {

    /// The caption, verbatim.
    package let label: String

    /// Creates a key cap.
    package init(label: String) {
        self.label = label
    }

    package var body: some View {
        Text(verbatim: label)
            .vType(VTheme.Typography.caption2)
            .foregroundStyle(VTheme.Color.Text.secondary)
            .padding(.horizontal, VPaletteMetrics.keyCapPadding)
            .frame(minWidth: VPaletteMetrics.keyCapSide,
                   minHeight: VPaletteMetrics.keyCapSide)
            .background(SwiftUI.Color.white.opacity(VPaletteMetrics.keyCapFillAlpha),
                        in: VTheme.Radius.shape(VTheme.Radius.xs))
            .overlay {
                VTheme.Radius.shape(VTheme.Radius.xs)
                    .strokeBorder(VTheme.Color.Stroke.default, lineWidth: VTheme.Border.thin)
                    .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Previews

#if DEBUG

/// The catalogue the previews rank against. Titles are plain strings because ``VCommand/title`` is
/// resolved by the caller — see that property's note.
@MainActor
private enum VPalettePreviewData {

    static let commands: [VCommand] = [
        VCommand(id: "layout.single", title: "Single", shortcut: "⌘1", category: .layout),
        VCommand(id: "layout.2x2", title: "2 × 2 Grid", shortcut: "⌘2", category: .layout),
        VCommand(id: "layout.hero", title: "Hero + 5", shortcut: "⌘3", category: .layout),
        VCommand(id: "view.cycle", title: "Cycle Cameras", category: .view),
        VCommand(id: "view.sidebar", title: "Toggle Sidebar", shortcut: "⌘L", category: .view),
        VCommand(id: "camera.entrance", title: "Вход", subtitle: "Ground Floor",
                 category: .camera),
        VCommand(id: "camera.snapshot", title: "Take Snapshot", shortcut: "⇧⌘S",
                 category: .camera),
        VCommand(id: "record.start", title: "Start Recording", subtitle: "Front Door",
                 category: .recording, isEnabled: false),
        VCommand(id: "app.settings", title: "Settings", shortcut: "⌘,", category: .application),
    ]
}

/// A preview host. `@State` cannot live in a `#Preview` body on the macOS 14 SDK, so the states are
/// held by a small view rather than by the `@Previewable` macro, which is newer.
@MainActor
private struct VCommandPalettePreview: View {

    let initialQuery: String
    @State private var query = ""
    @State private var selection: String?

    init(initialQuery: String = "") {
        self.initialQuery = initialQuery
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        VCommandPaletteView(commands: VPalettePreviewData.commands,
                            query: $query,
                            selection: $selection)
            .frame(width: 1080, height: 720)
            .background(VTheme.Color.Layer.canvas)
    }
}

#Preview("VCommandPaletteView — open") {
    VCommandPalettePreview()
}

#Preview("VCommandPaletteView — ranked") {
    VCommandPalettePreview(initialQuery: "rec")
}

#Preview("VCommandPaletteView — empty") {
    VCommandPalettePreview(initialQuery: "zzzz")
}
#endif

#endif  // os(macOS)
