//
//  VShortcutsSheet.swift
//  VigilUI
//
//  The keyboard cheat sheet behind ⌘/, and the table it reads.
//  macOS-only. Implements docs/UX.md §11.1 (the shortcut table) and §4 (⌘/ opens it).
//
//  ⛔ THE ONLY PLACE A SHORTCUT IS DISCOVERABLE WITHOUT READING THE SPEC. Vigil binds around forty
//  keys, and the menu bar carries a minority of them: ⌥-arrow tile focus, ⌘= / ⌘- / ⌘0 zoom, `.`
//  and `,` marker stepping, `/` search focus and ⌃1…⌃6 inspector tabs appear in no menu at all,
//  because they belong to the stage rather than to a command. Before this sheet the honest answer
//  to "what can I press" was `docs/UX.md` §11.1, which is not shipped to anyone.
//
//  ⚠️ THIS TABLE IS A CLAIM ABOUT THE APP AND IS NOT CHECKED BY THE COMPILER. Every row here has to
//  correspond to a binding in `MainWindowView+Commands.swift` or `VigilCommands.swift`; nothing
//  makes that true automatically. `VigilUITests/ShortcutReferenceTests.swift` holds it to what can
//  be checked from data alone — no duplicate key combinations, no empty labels, every section
//  populated — and the rest is a review obligation when a binding changes.
//

#if os(macOS)

import SwiftUI

// MARK: - VShortcutEntry

/// One row: what to press, and what it does.
package struct VShortcutEntry: Sendable, Hashable, Identifiable {

    /// The key combination as the user sees it printed — `⌥⇧⌘S`, `⌥←`, `Esc`.
    ///
    /// A rendered string rather than a `KeyEquivalent` plus modifiers, deliberately. This sheet
    /// documents keys it does not own — the stage's own arrow handling, the timeline's `.` and `,`
    /// — and a type that can only express what SwiftUI can bind would have to leave those out,
    /// which are exactly the ones nothing else advertises.
    package let keys: String

    /// What the key does, in the user's words — a **localisation key**, not a rendered string.
    ///
    /// ⚠️ `String` and not `LocalizedStringKey`, and the compiler is what settled it:
    /// `LocalizedStringKey` conforms to neither `Sendable` nor `Hashable`, so a value type holding
    /// one can be neither, and this table is a `static let` read from a view — it has to be both.
    /// The key is the English sentence, exactly as it appears in `Localizable.strings`, and the row
    /// wraps it at render time.
    package let action: String

    /// Stable identity for `ForEach`. The combination is unique across the whole sheet, which
    /// `ShortcutReferenceTests` asserts.
    package var id: String { keys }

    package init(_ keys: String, _ action: String) {
        self.keys = keys
        self.action = action
    }
}

// MARK: - VShortcutSection

/// A titled group of rows, in the order the sheet shows them.
package struct VShortcutSection: Sendable, Hashable, Identifiable {

    /// The section heading, as a localisation key. Same reason as ``VShortcutEntry/action``.
    package let title: String
    package let entries: [VShortcutEntry]

    /// Identity for `ForEach`. The keys of the first entry are unique per section by construction.
    package var id: String { entries.first?.keys ?? "" }

    package init(_ title: String, _ entries: [VShortcutEntry]) {
        self.title = title
        self.entries = entries
    }
}

// MARK: - VShortcutReference

/// The shipped shortcut table, in UX.md §11.1's order.
package enum VShortcutReference {

    package static let sections: [VShortcutSection] = [
        VShortcutSection("Cameras", [
            VShortcutEntry("⌘N", "Add a camera"),
            VShortcutEntry("⇧⌘N", "Find cameras on this network"),
            VShortcutEntry("⌘K", "Command palette"),
            VShortcutEntry("/", "Search the camera list"),
            VShortcutEntry("⌥⌘F", "Filter the camera list"),
            VShortcutEntry("↑ ↓", "Move through the camera list"),
            VShortcutEntry("⌘A", "Select every camera"),
        ]),
        VShortcutSection("The stage", [
            VShortcutEntry("⌘1 … ⌘8", "Layout"),
            VShortcutEntry("⌘9", "First layout preset"),
            VShortcutEntry("⌥⌘8", "Edit the mosaic"),
            VShortcutEntry("⌘F", "Fill the stage with the selected camera"),
            VShortcutEntry("⌃⌘F", "Cinema mode"),
            VShortcutEntry("⌥← ⌥→ ⌥↑ ⌥↓", "Move tile focus"),
            VShortcutEntry("⌘= ⌘-", "Digital zoom in and out"),
            VShortcutEntry("⌘0", "Reset the zoom"),
            VShortcutEntry("⌘Y", "Cycle through cameras"),
            VShortcutEntry("⌥⌘Y", "How long each camera is shown"),
        ]),
        VShortcutSection("Capture", [
            VShortcutEntry("⇧⌘S", "Snapshot"),
            VShortcutEntry("⌥⇧⌘S", "Snapshot every enabled camera"),
            VShortcutEntry("⌘R", "Start or stop recording"),
            VShortcutEntry("⌘D", "Mark this moment"),
            VShortcutEntry("⇧⌘O", "Open the recordings folder"),
            VShortcutEntry("⇧⌘I", "Import cameras from a CSV file"),
            VShortcutEntry("⌥⌘E", "Export the configuration"),
        ]),
        VShortcutSection("Panels", [
            VShortcutEntry("⌘L", "Show or hide the camera list"),
            VShortcutEntry("⌥⌘L", "The camera list as an icon rail"),
            VShortcutEntry("⌥⌘I", "Show or hide the inspector"),
            VShortcutEntry("⌃1 … ⌃6", "Inspector tab"),
            VShortcutEntry("⌃⌘H", "Keep the selected tile's controls up"),
            VShortcutEntry("⌥N ⌥S ⌥T ⌥B", "Overlays: name, stats, timecode, motion"),
            VShortcutEntry("⌥⌘D", "Check the camera's ports"),
            VShortcutEntry("⌘/", "This list"),
        ]),
        VShortcutSection("The timeline", [
            VShortcutEntry("← →", "Step ten seconds"),
            VShortcutEntry("⇧← ⇧→", "Step to the edge of a recording"),
            VShortcutEntry(", .", "Previous and next event"),
            VShortcutEntry("Home End", "Start and end of the day"),
            VShortcutEntry("⇧⌘G", "Jump to now"),
            VShortcutEntry("Esc", "Put the timeline away"),
        ]),
    ]
}

// MARK: - VShortcutsSheet

/// The cheat sheet itself: two columns of sections, scrolling, with one way out.
@MainActor
package struct VShortcutsSheet: View {

    private let sections: [VShortcutSection]
    private let onDismiss: () -> Void

    package init(sections: [VShortcutSection], onDismiss: @escaping () -> Void) {
        self.sections = sections
        self.onDismiss = onDismiss
    }

    /// ⚠️ Four small pieces rather than one nested body, and that is not tidiness: a `body` with the
    /// grid, both `ForEach`es and the row inline is what the SwiftUI type checker gives up on
    /// ("unable to type-check this expression in reasonable time"), which this project has now hit
    /// three times. Every piece below stays inside the four-or-five-modifier budget.
    package var body: some View {
        VStack(alignment: .leading, spacing: VTheme.Space.md) {
            heading
            scroller
            footer
        }
        .padding(VTheme.Space.lg)
        .frame(width: 620)
    }

    private var heading: some View {
        Text("Keyboard shortcuts", bundle: .vigilUI)
            .vType(VTheme.Typography.headline)
            .foregroundStyle(VTheme.Color.Text.primary)
            .accessibilityAddTraits(.isHeader)
    }

    private var scroller: some View {
        ScrollView(.vertical) { grid }
        .scrollIndicators(.visible)
        .defaultScrollAnchor(.top)
        .frame(maxHeight: 420)
    }

    /// Two columns, because §11.1 is forty rows and one column of forty is a sheet taller than a
    /// laptop screen.
    private var grid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: VTheme.Space.lg) {
            ForEach(sections) { section in
                column(section)
            }
        }
        .padding(.trailing, VTheme.Space.sm)
    }

    /// ⚠️ Computed rather than a `static let`: `GridItem` is not `Sendable`, and a static stored
    /// property of a non-`Sendable` type is an error under the Swift 6 language mode this package
    /// builds in. Two allocations per body evaluation of a sheet is not a cost worth a `nonisolated(unsafe)`.
    private var columns: [GridItem] {
        [GridItem(.flexible(), alignment: .topLeading),
         GridItem(.flexible(), alignment: .topLeading)]
    }

    /// One section: its heading, then its rows.
    private func column(_ section: VShortcutSection) -> some View {
        VStack(alignment: .leading, spacing: VTheme.Space.xs) {
            Text(LocalizedStringKey(section.title), bundle: .vigilUI)
                .vType(VTheme.Typography.caption1)
                .foregroundStyle(VTheme.Color.Text.secondary)
                .textCase(.uppercase)
            ForEach(section.entries) { entry in
                row(entry)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer(minLength: 0)
            VButton("Done", style: .primary, size: .sm, action: onDismiss)
        }
    }

    /// One row: the keys in monospace so they align down the column, then the sentence.
    private func row(_ entry: VShortcutEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: VTheme.Space.sm) {
            Text(verbatim: entry.keys)
                .vType(VTheme.Typography.mono)
                .foregroundStyle(VTheme.Color.Text.primary)
                .frame(width: 116, alignment: .leading)
            Text(LocalizedStringKey(entry.action), bundle: .vigilUI)
                .vType(VTheme.Typography.body)
                .foregroundStyle(VTheme.Color.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG && !VIGIL_NO_PREVIEWS

#Preview("Keyboard shortcuts") {
    VShortcutsSheet(sections: VShortcutReference.sections) {}
}

#endif  // DEBUG && !VIGIL_NO_PREVIEWS

#endif  // os(macOS)
