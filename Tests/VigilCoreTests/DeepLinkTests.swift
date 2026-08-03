//
//  DeepLinkTests.swift
//  VigilCoreTests
//
//  The `vigil://` grammar.
//  Covers Sources/VigilCore/Model/DeepLink.swift; see docs/FEATURES.md §F-AUT-03 acceptance 1–3.
//
//  ⛔ A URL scheme is an unauthenticated input surface: any web page, mail message or script on the
//  Mac can hand these strings to Vigil. Acceptance 2 requires the parser to be *total* — "never a
//  crash, never a silent no-op" — so the malformed cases below carry as much weight as the valid
//  ones, and each asserts the specific error rather than merely that something was thrown.
//

#if os(macOS)

import Foundation
import Testing

import VigilProtocols

@testable import VigilCore

// MARK: - Helpers

/// A URL from a literal, or a test failure that names the literal rather than unwrapping into a trap.
private func link(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
    try #require(URL(string: text), "not a URL: \(text)", sourceLocation: sourceLocation)
}

// MARK: - Cameras

@Test func deepLinkReadsACameraByIdentifier() throws {
    let identifier = UUID(uuidString: "2C8F1D7B-2222-4A2B-9C3D-0E5F6A7B8C9D") ?? UUID()
    let target = try DeepLink.parse(try link("vigil://camera/\(identifier.uuidString)"))
    #expect(target == .camera(.identifier(identifier), action: nil, stream: nil))
}

/// A name arrives as a slug: case-folded and whitespace-collapsed (acceptance 3).
@Test func deepLinkReadsACameraByNameAsASlug() throws {
    let target = try DeepLink.parse(try link("vigil://camera/Front%20Door"))
    #expect(target == .camera(.slug("front door"), action: nil, stream: nil))
}

/// Repeated and leading whitespace collapses, so a hand-written link matches a stored name.
@Test func deepLinkSlugCollapsesWhitespaceAndCase() {
    #expect(DeepLink.slug("  Front   DOOR ") == "front door")
    #expect(DeepLink.slug("front door") == "front door")
}

@Test func deepLinkReadsAnActionAndAStream() throws {
    let target = try DeepLink.parse(try link("vigil://camera/lobby?action=record&stream=sub"))
    #expect(target == .camera(.slug("lobby"), action: .record, stream: .sub))
}

/// Unknown query parameters are ignored, which acceptance 2 requires by name.
@Test func deepLinkIgnoresUnknownQueryParameters() throws {
    let target = try DeepLink.parse(try link("vigil://camera/lobby?utm_source=mail&action=live"))
    #expect(target == .camera(.slug("lobby"), action: .live, stream: nil))
}

// MARK: - The other targets

@Test func deepLinkReadsTheSimpleTargets() throws {
    #expect(try DeepLink.parse(try link("vigil://snapshot-all")) == .snapshotAll)
    #expect(try DeepLink.parse(try link("vigil://palette")) == .palette(query: nil))
    #expect(try DeepLink.parse(try link("vigil://palette?q=front")) == .palette(query: "front"))
    #expect(try DeepLink.parse(try link("vigil://layout/grid2x2")) == .layout("grid2x2"))
    #expect(try DeepLink.parse(try link("vigil://group/Perimeter")) == .group(.slug("perimeter")))
    #expect(try DeepLink.parse(try link("vigil://settings/General")) == .settings(pane: "general"))
}

/// An empty `?q=` is what a link builder emits for "no filter". Treating it as a search for the
/// empty string would open the palette showing nothing.
@Test func deepLinkTreatsAnEmptyQueryAsNoQuery() throws {
    #expect(try DeepLink.parse(try link("vigil://palette?q=")) == .palette(query: nil))
}

@Test func deepLinkReadsAPresetNumber() throws {
    let target = try DeepLink.parse(try link("vigil://preset/lobby/3"))
    #expect(target == .preset(.slug("lobby"), number: 3))
}

@Test func deepLinkReadsPlaybackWithAnInstantAndASpeed() throws {
    let target = try DeepLink.parse(
        try link("vigil://playback/lobby?t=2026-08-03T09:00:00Z&speed=4"))
    guard case let .playback(reference, at: instant, speed: speed) = target else {
        Issue.record("expected playback, got \(target)")
        return
    }
    #expect(reference == .slug("lobby"))
    #expect(speed == 4)
    #expect(instant == Date(timeIntervalSince1970: 1_785_747_600))
}

/// Fractional seconds parse too: both spellings are written in the wild, and failing only on the
/// one with milliseconds would be a maddening thing to debug.
@Test func deepLinkAcceptsFractionalSecondsInTheInstant() throws {
    let target = try DeepLink.parse(try link("vigil://playback/lobby?t=2026-08-03T09:00:00.250Z"))
    guard case .playback = target else {
        Issue.record("expected playback, got \(target)")
        return
    }
}

// MARK: - Totality

@Test func deepLinkRefusesAnotherScheme() throws {
    #expect(throws: DeepLinkError.notAVigilLink) {
        try DeepLink.parse(try link("https://example.com/camera/lobby"))
    }
}

@Test func deepLinkNamesAnUnknownTarget() throws {
    #expect(throws: DeepLinkError.unknownTarget("wormhole")) {
        try DeepLink.parse(try link("vigil://wormhole/lobby"))
    }
}

@Test func deepLinkNamesAMissingComponent() throws {
    #expect(throws: DeepLinkError.missingComponent(target: "camera")) {
        try DeepLink.parse(try link("vigil://camera"))
    }
}

@Test func deepLinkRejectsAnUnknownAction() throws {
    #expect(throws: DeepLinkError.malformedParameter(name: "action", value: "detonate")) {
        try DeepLink.parse(try link("vigil://camera/lobby?action=detonate"))
    }
}

/// `third` exists as a `StreamQuality` and is deliberately not in the grammar, so it is rejected
/// rather than quietly accepted. §F-AUT-03's grammar is normative.
@Test func deepLinkRejectsAStreamOutsideTheGrammar() throws {
    #expect(throws: DeepLinkError.malformedParameter(name: "stream", value: "third")) {
        try DeepLink.parse(try link("vigil://camera/lobby?stream=third"))
    }
}

/// Out of range is an error, not a clamp: a link asking for 100× has misunderstood something, and
/// silently giving it 8× would hide that from whoever wrote the link.
@Test func deepLinkRejectsASpeedOutsideTheGrammar() throws {
    #expect(throws: DeepLinkError.malformedParameter(name: "speed", value: "100")) {
        try DeepLink.parse(try link("vigil://playback/lobby?t=2026-08-03T09:00:00Z&speed=100"))
    }
    #expect(throws: DeepLinkError.malformedParameter(name: "speed", value: "fast")) {
        try DeepLink.parse(try link("vigil://playback/lobby?t=2026-08-03T09:00:00Z&speed=fast"))
    }
}

@Test func deepLinkRejectsAMalformedInstant() throws {
    #expect(throws: DeepLinkError.malformedParameter(name: "t", value: "yesterday")) {
        try DeepLink.parse(try link("vigil://playback/lobby?t=yesterday"))
    }
}

@Test func deepLinkRejectsANonNumericPreset() throws {
    #expect(throws: DeepLinkError.malformedParameter(name: "preset", value: "home")) {
        try DeepLink.parse(try link("vigil://preset/lobby/home"))
    }
}

@Test func deepLinkRejectsAnEventIDThatIsNotAUUID() throws {
    #expect(throws: DeepLinkError.malformedParameter(name: "event", value: "42")) {
        try DeepLink.parse(try link("vigil://event/42"))
    }
}

// MARK: - The confirmation rule's vocabulary

/// Acceptance 4 lives in the app, which knows whether it is frontmost — but which actions it applies
/// to belongs beside the vocabulary, so the rule cannot drift from the enum.
@Test func deepLinkMarksTheActionsThatNeedConfirmation() {
    #expect(DeepLinkAction.record.needsConfirmationFromAnotherApp)
    #expect(DeepLinkAction.snapshot.needsConfirmationFromAnotherApp)
    for action in [DeepLinkAction.live, .fullscreen, .stop, .diagnose] {
        #expect(action.needsConfirmationFromAnotherApp == false)
    }
}

#endif  // os(macOS)
