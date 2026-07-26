//
//  RecordingNamingTests.swift
//  VigilCoreTests
//
//  Path sanitisation, token expansion and collision handling — the arithmetic that stands between a
//  camera named `../../etc` and a file written outside the recordings folder.
//  Covers Sources/VigilCore/Recording/RecordingNaming.swift.
//
//  Pure string and integer work, so these run identically on macOS and in the Linux shadow harness
//  under scratchpad/shadow-recording, which is where they were executed.
//

#if os(macOS)

import Foundation
import Testing
import VigilCore
import VigilProtocols

// MARK: - Support

/// A fixed instant: 2026-07-26 14:31:07 UTC. Not `Date()` — a name that depends on the wall clock
/// cannot be asserted (.vigil/IMPL_RULES.md, "Determinism").
private let recordingNamingDate = Date(timeIntervalSince1970: 1_785_076_267)

/// UTC, so the expected components are the ones in the literal above regardless of the test machine.
private let recordingNamingZone = TimeZone(secondsFromGMT: 0) ?? .gmt

private func recordingNamingContext(slug: String = "front-door",
                                    name: String = "Front Door",
                                    segment: Int = 0,
                                    resolution: Resolution? = nil,
                                    codec: VideoCodec? = nil,
                                    trigger: String = "manual") -> RecordingNameContext {
    RecordingNameContext(cameraSlug: slug, cameraName: name, date: recordingNamingDate,
                         timeZone: recordingNamingZone, segmentIndex: segment,
                         resolution: resolution, codec: codec, trigger: trigger)
}

// MARK: - Token expansion

@Test func recordingNamingExpandsEveryDocumentedToken() {
    let context = recordingNamingContext(segment: 1,
                                         resolution: Resolution(width: 1_920, height: 1_080),
                                         codec: .h265,
                                         trigger: "motion")
    // `_` as the separator, not `|`: the pipe is a forbidden path character and `sanitise` would
    // turn every one of them into a hyphen, which is itself asserted in the sanitisation cases below.
    let template = "{camera}_{cameraName}_{yyyy}_{MM}_{dd}_{HH}_{mm}_{ss}_{HHmmss}_{date}_{time}"
        + "_{seq}_{res}_{codec}_{trigger}_{epoch}"
    let rendered = RecordingNaming.render(template, context: context)
    #expect(rendered == "front-door_Front Door_2026_07_26_14_31_07_143107_2026-07-26_14-31-07"
            + "_002_1920x1080_h265_motion_1785076267")
}

@Test func recordingNamingRendersTheDefaultClipTemplateAsADatedPath() {
    let rendered = RecordingNaming.render(RecordingNaming.defaultClipTemplate,
                                          context: recordingNamingContext())
    // One directory per camera per day: a month of recordings stays navigable in the Finder, which a
    // flat directory of forty thousand files does not.
    #expect(rendered == "front-door/2026-07-26/front-door_143107_manual")
}

@Test func recordingNamingRendersTheDefaultSnapshotTemplate() {
    let rendered = RecordingNaming.render(RecordingNaming.defaultSnapshotTemplate,
                                          context: recordingNamingContext())
    #expect(rendered == "Front Door-2026-07-26-14-31-07")
}

@Test func recordingNamingRendersSequenceOneBasedAndThreeDigits() {
    #expect(RecordingNaming.render("{seq}", context: recordingNamingContext(segment: 0)) == "001")
    #expect(RecordingNaming.render("{seq}", context: recordingNamingContext(segment: 11)) == "012")
    #expect(RecordingNaming.render("{seq}", context: recordingNamingContext(segment: 999)) == "1000")
}

@Test func recordingNamingRendersMissingFactsAsUnknownRatherThanAsAGap() {
    let rendered = RecordingNaming.render("{res}-{codec}", context: recordingNamingContext())
    #expect(rendered == "unknown-unknown")
}

@Test func recordingNamingLeavesAnUnknownTokenVerbatim() {
    // A user who typed `{camra}` should see their typo in the file name and fix it, not silently
    // lose the field.
    #expect(RecordingNaming.render("a-{camra}-b", context: recordingNamingContext())
            == "a-{camra}-b")
}

@Test func recordingNamingRendersTimeInTheGivenZoneNotUTC() {
    let moscow = TimeZone(secondsFromGMT: 3 * 3_600) ?? .gmt
    let context = RecordingNameContext(cameraSlug: "c", cameraName: "C",
                                       date: recordingNamingDate, timeZone: moscow)
    // A file called `..._173107` should be the time on the clock in the room.
    #expect(RecordingNaming.render("{HHmmss}", context: context) == "173107")
}

// MARK: - Sanitisation

@Test func recordingNamingSanitiseReplacesEveryForbiddenCharacter() {
    #expect(RecordingNaming.sanitise(component: "a/b") == "a-b")
    #expect(RecordingNaming.sanitise(component: "a\\b") == "a-b")
    #expect(RecordingNaming.sanitise(component: "Lobby: East") == "Lobby- East")
    #expect(RecordingNaming.sanitise(component: "a*b?c\"d<e>f|g") == "a-b-c-d-e-f-g")
}

@Test func recordingNamingSanitiseReplacesControlCharactersIncludingNUL() {
    // NUL truncates a C path silently, which is the worst possible outcome: the file is written
    // somewhere shorter than the name says.
    #expect(RecordingNaming.sanitise(component: "a\u{0}b") == "a-b")
    #expect(RecordingNaming.sanitise(component: "a\u{1}b") == "a-b")
    #expect(RecordingNaming.sanitise(component: "a\u{7F}b") == "a-b")
    #expect(RecordingNaming.sanitise(component: "a\u{9F}b") == "a-b")
    #expect(RecordingNaming.sanitise(component: "a\tb") == "a-b")
}

@Test func recordingNamingSanitiseCollapsesRunsOfHyphens() {
    #expect(RecordingNaming.sanitise(component: "a///b") == "a-b")
    #expect(RecordingNaming.sanitise(component: "a---b") == "a-b")
}

@Test func recordingNamingSanitiseStripsLeadingAndTrailingDotsAndSpace() {
    // A leading dot hides the file; a trailing one is stripped by some file systems and kept by
    // others, which makes a later lookup miss.
    #expect(RecordingNaming.sanitise(component: ".hidden") == "hidden")
    #expect(RecordingNaming.sanitise(component: "trailing.") == "trailing")
    #expect(RecordingNaming.sanitise(component: "  padded  ") == "padded")
}

@Test func recordingNamingSanitiseRefusesTheReservedNames() {
    #expect(RecordingNaming.sanitise(component: ".") == "")
    #expect(RecordingNaming.sanitise(component: "..") == "")
}

@Test func recordingNamingRefusesTraversalInEveryComponent() {
    // The whole point: a camera named `../../etc` must not escape the recordings folder. Each
    // component is sanitised independently and the empty ones are dropped.
    let context = recordingNamingContext(slug: "../../etc", name: "../../etc")
    let rendered = RecordingNaming.render("{cameraName}/{cameraName}", context: context)
    #expect(!rendered.contains(".."))
    #expect(!rendered.hasPrefix("/"))
    let components = rendered.split(separator: "/").map(String.init)
    #expect(components.allSatisfy { $0 != ".." && $0 != "." && !$0.isEmpty })
}

@Test func recordingNamingKeepsNonASCIINamesIntact() {
    // Cyrillic and CJK names are not "illegal characters"; only the path separators are.
    #expect(RecordingNaming.sanitise(component: "Вход") == "Вход")
    #expect(RecordingNaming.sanitise(component: "玄関") == "玄関")
}

@Test func recordingNamingTruncatesComponentsByUTF8BytesNotCharacters() {
    // A 200-character Cyrillic name is 400 bytes and would be refused by the file system — which
    // reports it as a rename failure at the *end* of a recording rather than as a naming problem at
    // the start.
    let long = String(repeating: "я", count: 300)
    let sanitised = RecordingNaming.sanitise(component: long)
    #expect(sanitised.utf8.count <= 200)
    #expect(sanitised.count == 100)
    // Truncated on a scalar boundary, so the result is valid UTF-8 and round-trips.
    #expect(String(decoding: Array(sanitised.utf8), as: UTF8.self) == sanitised)
}

@Test func recordingNamingTruncatesASCIIAtExactlyTheLimit() {
    let long = String(repeating: "a", count: 250)
    #expect(RecordingNaming.sanitise(component: long).count == 200)
    let exact = String(repeating: "a", count: 200)
    #expect(RecordingNaming.sanitise(component: exact).count == 200)
}

@Test func recordingNamingFallsBackWhenTheTemplateSanitisesAwayEntirely() {
    let rendered = RecordingNaming.render("///", context: recordingNamingContext())
    #expect(rendered == "front-door")
    // And when even the slug is gone, a constant rather than an empty path.
    let empty = RecordingNaming.render("///", context: recordingNamingContext(slug: "", name: ""))
    #expect(empty == "camera")
}

// MARK: - Slugs

@Test func recordingNamingSlugLowercasesAndHyphenates() {
    #expect(RecordingNaming.slug("Front Door") == "front-door")
    #expect(RecordingNaming.slug("Camera #3 (East)") == "camera-3-east")
    #expect(RecordingNaming.slug("---") == "")
    #expect(RecordingNaming.slug("") == "")
}

@Test func recordingNamingSlugCapsAtFortyEightCharacters() {
    #expect(RecordingNaming.slug(String(repeating: "a", count: 100)).count == 48)
}

// MARK: - Collisions

@Test func recordingNamingUniqueBaseNameReturnsTheNameWhenNothingIsTaken() {
    let chosen = RecordingNaming.uniqueBaseName("clip", extensions: ["mp4", "mp4.partial"],
                                                uniqueSuffix: "abc12345") { _, _ in false }
    #expect(chosen == "clip")
}

@Test func recordingNamingUniqueBaseNameSkipsANameWhosePartialTwinIsTaken() {
    // A recorder must not claim the name another recorder is still writing. The `.partial` twin is
    // the only evidence that this is happening.
    let chosen = RecordingNaming.uniqueBaseName("clip", extensions: ["mp4", "mp4.partial"],
                                                uniqueSuffix: "abc12345") { name, suffix in
        name == "clip" && suffix == "mp4.partial"
    }
    #expect(chosen == "clip (2)")
}

@Test func recordingNamingUniqueBaseNameWalksTheSuffixSequence() {
    let taken: Set<String> = ["clip", "clip (2)", "clip (3)"]
    let chosen = RecordingNaming.uniqueBaseName("clip", extensions: ["jpg"],
                                                uniqueSuffix: "abc12345") { name, _ in
        taken.contains(name)
    }
    #expect(chosen == "clip (4)")
}

@Test func recordingNamingUniqueBaseNameFallsBackToTheSuffixAfterAThousandCollisions() {
    // A thousand collisions means something else is wrong; looping further would hang the capture.
    let chosen = RecordingNaming.uniqueBaseName("clip", extensions: ["jpg"],
                                                uniqueSuffix: "abc12345") { _, _ in true }
    #expect(chosen == "clip-abc12345")
}

#endif
