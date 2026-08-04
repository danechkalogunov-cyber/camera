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

    /// What the key does, in the user's words.
    package let action: LocalizedStringKey

    /// Stable identity for `ForEach`. The combination is unique across the whole sheet, which
    /// `ShortcutReferenceTests` asserts.
    package var id: String { keys }

    package init(_ keys: String, _ action: LocalizedStringKey) {
        self.keys = keys
        self.action = action
    }
}

// MARK: - VShortcutSection

/// A titled group of rows, in the order the sheet shows them.
package struct VShortcutSection: Sendable, Hashable, Identifiable {
    package let title: LocalizedStringKey
    package let entries: [VShortcutEntry]

    /// Identity for `ForEach`. The keys of the first entry are unique per section by construction.
    package var id: String { entries.first?.keys ?? "" }

    package init(_ title: LocalizedStringKey, _ entries: [VShortcutEntry]) {
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
        ]),
        VShortcutSection("Panels", [
            VShortcutEntry("⌘L", "Show or hide the camera list"),
            VShortcutEntry("⌥⌘L", "The camera list as an icon rail"),
            VShortcutEntry("⌥⌘I", "Show or hide the inspector"),
            VShortcutEntry("⌃1 … ⌃6", "Inspector tab"),
            VShortcutEntry("⌃⌘H", "Keep the selected tile's controls up"),
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

    package var body: some View {
        VStack(alignment: .leading, spacing: VTheme.Space.md) {
            Text("Keyboard shortcuts", bundle: .vigilUI)
                .vType(VTheme.Typography.headline)
                .foregroundStyle(VTheme.Color.Text.primary)
                .accessibilityAddTraits(.isHeader)

            ScrollView(.vertical) {
                // Two columns, because §11.1 is forty rows and one column of forty is a sheet
                // taller than a laptop screen.
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                                    GridItem(.flexible(), alignment: .topLeading)],
                          alignment: .leading,
                          spacing: VTheme.Space.lg) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: VTheme.Space.xs) {
                            Text(section.title, bundle: .vigilUI)
                                .vType(VTheme.Typography.caption1)
                                .foregroundStyle(VTheme.Color.Text.secondary)
                                .textCase(.uppercase)
                            ForEach(section.entries) { entry in
                                row(entry)
                            }
                        }
                    }
                }
                .padding(.trailing, VTheme.Space.sm)
            }
            .frame(maxHeight: 420)

            HStack {
                Spacer(minLength: 0)
                VButton("Done", style: .primary, size: .sm, action: onDismiss)
            }
        }
        .padding(VTheme.Space.lg)
        .frame(width: 620)
    }

    /// One row: the keys in monospace so they align down the column, then the sentence.
    private func row(_ entry: VShortcutEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: VTheme.Space.sm) {
            Text(verbatim: entry.keys)
                .vType(VTheme.Typography.mono)
                .foregroundStyle(VTheme.Color.Text.primary)
                .frame(width: 116, alignment: .leading)
            Text(entry.action, bundle: .vigilUI)
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
