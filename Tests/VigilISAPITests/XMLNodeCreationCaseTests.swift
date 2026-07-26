//
//  XMLNodeCreationCaseTests.swift
//  VigilISAPITests
//
//  `setting(createIfMissing:)` must create elements in the caller's capitalisation, not the path
//  matcher's lower-cased form. Hikvision firmware compares element names case-sensitively.
//

import Testing

@testable import VigilISAPI

// MARK: - XMLNodeCreationCaseTests

/// Pins the case-preservation rule for created elements.
///
/// The defect these exist for was silent in the worst way: `setting("SharpnessLevel", …,
/// createIfMissing: true)` created `<sharpnesslevel>`, the device ignored the element, and the write
/// reported success. An entire firmware-quirk row was inert with no error anywhere.
@Suite struct XMLNodeCreationCaseTests {

    /// A created leaf carries the caller's capitalisation, not the lower-cased match key.
    @Test func xmlNodeSettingCreatesLeafInCallerCapitalisation() {
        let root = XMLNode(name: "ImageChannel")
        let updated = root.setting("SharpnessLevel", to: "50", createIfMissing: true)
        let text = String(decoding: updated.serialized(declaration: false), as: UTF8.self)
        #expect(text.contains("<SharpnessLevel>50</SharpnessLevel>"))
        #expect(!text.contains("sharpnesslevel"))
    }

    /// Every intermediate element in a chain is created with its own capitalisation too.
    @Test func xmlNodeSettingCreatesIntermediatesInCallerCapitalisation() {
        let root = XMLNode(name: "ImageChannel")
        let updated = root.setting("Sharpness/SharpnessLevel", to: "50", createIfMissing: true)
        let text = String(decoding: updated.serialized(declaration: false), as: UTF8.self)
        #expect(text.contains("<Sharpness>"))
        #expect(text.contains("<SharpnessLevel>50</SharpnessLevel>"))
        #expect(!text.lowercased().contains("<sharpness>") || text.contains("<Sharpness>"))
    }

    /// Matching an element that already exists stays case-INsensitive. The fix must not tighten
    /// matching — a device that spells it `sharpnesslevel` must still be found and updated in place,
    /// not shadowed by a second differently-cased sibling.
    @Test func xmlNodeSettingStillMatchesExistingChildCaseInsensitively() {
        let existing = XMLNode(name: "sharpnesslevel", text: "10")
        let root = XMLNode(name: "ImageChannel", children: [existing])
        let updated = root.setting("SharpnessLevel", to: "50", createIfMissing: true)
        let text = String(decoding: updated.serialized(declaration: false), as: UTF8.self)
        #expect(text.contains("<sharpnesslevel>50</sharpnesslevel>"))
        // Updated in place: exactly one such element, and no capitalised duplicate appeared.
        #expect(!text.contains("<SharpnessLevel>"))
        #expect(updated.children.count == 1)
    }

    /// With alternation, the first alternative is created — the same one the matcher would have
    /// chosen — and it keeps its capitalisation.
    @Test func xmlNodeSettingCreatesFirstAlternativeWithItsCase() {
        let root = XMLNode(name: "ImageChannel")
        let updated = root.setting("SharpnessLevel|sharpness", to: "50", createIfMissing: true)
        let text = String(decoding: updated.serialized(declaration: false), as: UTF8.self)
        #expect(text.contains("<SharpnessLevel>50</SharpnessLevel>"))
    }

    /// `createIfMissing: false` still changes nothing when the element is absent.
    @Test func xmlNodeSettingWithoutCreateLeavesTreeUntouched() {
        let root = XMLNode(name: "ImageChannel")
        let updated = root.setting("SharpnessLevel", to: "50", createIfMissing: false)
        #expect(updated.children.isEmpty)
        #expect(updated.text.isEmpty)
    }
}
