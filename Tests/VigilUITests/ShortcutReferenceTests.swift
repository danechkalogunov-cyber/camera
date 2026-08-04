//
//  ShortcutReferenceTests.swift
//  VigilUITests
//
//  What the ⌘/ cheat sheet can be held to without a window.
//
//  ⚠️ THE TABLE IS A CLAIM ABOUT BINDINGS THAT LIVE IN ANOTHER TARGET, and no test can check that
//  claim: `MainWindowView+Commands.swift` binds keys with SwiftUI's `keyboardShortcut`, which is not
//  readable back. So these assert the properties that are checkable from the data alone — no
//  duplicate combination, nothing blank, every section populated — and a row that documents a key
//  nobody bound stays a review obligation. That is worth saying out loud rather than implying by
//  omission: a cheat sheet is trusted, and a wrong one is worse than none.
//

#if os(macOS)

import Testing
@testable import VigilUI

@Suite("Keyboard shortcut reference")
struct ShortcutReferenceTests {

    /// ⛔ Duplicates are the failure this table is most likely to develop: the same combination in
    /// two sections means one of them is wrong, and `Identifiable` keys off the combination, so
    /// `ForEach` would also drop a row silently.
    @Test func everyCombinationAppearsOnce() {
        let keys = VShortcutReference.sections.flatMap { $0.entries.map(\.keys) }
        #expect(keys.count == Set(keys).count)
    }

    /// A section with no rows would render as a heading over nothing.
    @Test func everySectionHasRows() {
        for section in VShortcutReference.sections {
            #expect(!section.entries.isEmpty)
        }
    }

    /// A blank combination would render as an empty column, and blank is what a half-finished row
    /// looks like.
    @Test func noCombinationIsBlank() {
        for section in VShortcutReference.sections {
            for entry in section.entries {
                #expect(!entry.keys.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    /// The sheet is a whole-app reference, so it has to carry more than one area of the app.
    @Test func theReferenceCoversTheWholeWindow() {
        #expect(VShortcutReference.sections.count >= 5)
        let total = VShortcutReference.sections.reduce(0) { $0 + $1.entries.count }
        #expect(total >= 30)
    }

    /// The four keys this sheet shipped alongside are in it — the sheet exists because they were
    /// unreachable, and a cheat sheet that omits the newest shortcuts repeats the same failure.
    @Test func theNewlyBoundKeysAreDocumented() {
        let keys = Set(VShortcutReference.sections.flatMap { $0.entries.map(\.keys) })
        #expect(keys.contains("⌥⌘L"))
        #expect(keys.contains("⌘F"))
        #expect(keys.contains("⌃⌘H"))
        #expect(keys.contains("⌥⇧⌘S"))
        #expect(keys.contains("⌘/"))
    }
}

#endif  // os(macOS)
