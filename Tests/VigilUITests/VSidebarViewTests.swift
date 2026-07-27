//
//  VSidebarViewTests.swift
//  VigilUITests
//
//  The parts of the sidebar view that are decidable without a renderer: which rows the tree puts on
//  screen and in what order, the status → dot mapping and its tone, the search-highlight runs, the
//  identity index, the motion spark's buckets and the footer's bitrate scaling.
//  Covers Sources/VigilUI/Sidebar/VSidebarView.swift and VSidebarRowView.swift; see docs/UX.md
//  §4.1, §4.2, §3.3 and docs/DESIGN.md §9.12, §3.4.
//
//  Every test name is prefixed `sidebarView` on purpose: swift-testing attaches @Test to free
//  functions and free functions share one namespace per module, so a name collision with another
//  file takes the whole target down (docs/BUILD-VERIFICATION.md defect 4).
//

#if os(macOS)

import Foundation
import Testing

import VigilProtocols

@testable import VigilUI

// MARK: - Fixtures

private func sidebarViewCamera(_ name: String,
                               host: String = "192.168.1.64",
                               status: VSidebarStatus = .live,
                               codec: String? = nil,
                               resolution: String? = nil,
                               group: GroupID? = nil,
                               deviceKey: String? = nil,
                               deviceName: String? = nil,
                               identityIndex: Int? = nil,
                               enabled: Bool = true,
                               recording: Bool = false,
                               subStream: Bool = false) -> VSidebarCamera {
    VSidebarCamera(id: CameraID(),
                   name: name,
                   host: host,
                   groupID: group,
                   deviceKey: deviceKey,
                   deviceName: deviceName,
                   identityIndex: identityIndex,
                   isEnabled: enabled,
                   status: status,
                   codec: codec,
                   resolutionLabel: resolution,
                   isRecording: recording,
                   isSubStream: subStream)
}

/// The row kinds in order, as short tags, so an ordering assertion reads as the picture it checks.
private func sidebarViewTags(_ tree: VSidebarTree) -> [String] {
    tree.rows.map { row in
        switch row.kind {
        case .sectionHeader(let section): return "section:\(section.rawValue)"
        case .layout: return "layout"
        case .group(let group, _): return "group:\(group.name)"
        case .device(_, let name, _): return "device:\(name)"
        case .camera(let camera, _): return "camera:\(camera.name)"
        case .libraryLink(let link, _): return "library:\(link.rawValue)"
        case .emptyNotice(let section): return "empty:\(section.rawValue)"
        }
    }
}

// MARK: - Row order and identity

/// The four sections appear in their fixed order, top to bottom, with the layout row under LIVE and
/// the three library links under LIBRARY (UX.md §4.1).
@Test func sidebarViewRowsFollowTheFixedSectionOrder() {
    let tree = VSidebarTree(cameras: [sidebarViewCamera("Front Door")])
    let tags = sidebarViewTags(tree)
    #expect(tags.first == "section:live")
    #expect(tags.contains("layout"))
    let sections = tags.filter { $0.hasPrefix("section:") }
    #expect(sections == ["section:live", "section:groups", "section:cameras", "section:library"])
    let library = tags.filter { $0.hasPrefix("library:") }
    #expect(library == ["library:recordings", "library:events", "library:bookmarks"])
}

/// Every row identifier is unique, which is what lets `ForEach` diff the list instead of rebuilding
/// it — and rebuilding a camera row throws its micro-thumbnail away on every keystroke.
@Test func sidebarViewRowIdentifiersAreUnique() {
    let cameras = (0..<8).map { sidebarViewCamera("Camera \($0)") }
    let groups = [VSidebarGroup(id: GroupID(), name: "Perimeter")]
    let tree = VSidebarTree(cameras: cameras, groups: groups, eventBadge: 3)
    let ids = tree.rows.map(\.id)
    #expect(Set(ids).count == ids.count)
}

/// Camera rows keep the library's order, which is the order the sidebar view renders them in.
@Test func sidebarViewCameraRowsKeepLibraryOrder() {
    let names = ["Front Door", "Garage", "Lobby", "Back Yard"]
    let tree = VSidebarTree(cameras: names.map { sidebarViewCamera($0) })
    let rendered = sidebarViewTags(tree).filter { $0.hasPrefix("camera:") }
    #expect(rendered == names.map { "camera:\($0)" })
}

/// A section with nothing in it collapses to one muted row rather than disappearing (UX.md §4.1),
/// so the view always has something to draw between the headers.
@Test func sidebarViewEmptySectionsKeepAMutedRow() {
    let tree = VSidebarTree(cameras: [])
    let tags = sidebarViewTags(tree)
    #expect(tags.contains("empty:groups"))
    #expect(tags.contains("empty:cameras"))
}

/// A collapsed CAMERAS section still shows its header — the view keys collapse off the header's
/// row identifier, so the two have to agree on the spelling.
@Test func sidebarViewCollapsedSectionKeepsItsHeader() {
    let tree = VSidebarTree(cameras: [sidebarViewCamera("Front Door")],
                            collapsed: ["section.cameras"])
    let tags = sidebarViewTags(tree)
    #expect(tags.contains("section:cameras"))
    #expect(!tags.contains("camera:Front Door"))
}

/// A device header appears only for two or more channels, and its children indent one level — the
/// indent the row view multiplies by ``VSidebarMetrics/indentStep``.
@Test func sidebarViewDeviceChannelsIndentOneLevel() {
    let cameras = [
        sidebarViewCamera("CH1", deviceKey: "NVR-1", deviceName: "Front NVR"),
        sidebarViewCamera("CH2", deviceKey: "NVR-1", deviceName: "Front NVR"),
        sidebarViewCamera("Standalone"),
    ]
    let tree = VSidebarTree(cameras: cameras)
    #expect(sidebarViewTags(tree).contains("device:Front NVR"))
    for row in tree.rows {
        guard case .camera(let camera, _) = row.kind else { continue }
        #expect(row.indent == (camera.name == "Standalone" ? 0 : 1))
    }
}

// MARK: - Status → dot

/// The five-way dot vocabulary. `disabled` has no dot of its own and takes the hollow offline ring
/// (UX.md §4.2); the row's 45 % dimming is what separates the two.
@Test func sidebarViewStatusMapsOntoTheFiveDots() {
    #expect(VSidebarStatus.disabled.dotStatus == .offline)
    #expect(VSidebarStatus.connecting(progress: nil).dotStatus == .connecting)
    #expect(VSidebarStatus.connecting(progress: 0.62).dotStatus == .connecting)
    #expect(VSidebarStatus.live.dotStatus == .live)
    #expect(VSidebarStatus.degraded(.switchedToTCP).dotStatus == .degraded)
    #expect(VSidebarStatus.offline(retryInSeconds: nil).dotStatus == .offline)
    #expect(VSidebarStatus.offline(retryInSeconds: 8).dotStatus == .offline)
    #expect(VSidebarStatus.authFailed.dotStatus == .authFailed)
}

/// Only a degraded stream and a rejected credential colour their own status line; everything else
/// is `text.tertiary`, because a sidebar where five rows shout is a sidebar nobody scans.
@Test func sidebarViewStatusToneIsWarnOnlyWhereItEarnsIt() {
    #expect(VSidebarStatusLine.tone(for: .live) == .neutral)
    #expect(VSidebarStatusLine.tone(for: .disabled) == .neutral)
    #expect(VSidebarStatusLine.tone(for: .connecting(progress: 0.5)) == .neutral)
    #expect(VSidebarStatusLine.tone(for: .offline(retryInSeconds: 8)) == .neutral)
    #expect(VSidebarStatusLine.tone(for: .degraded(.packetLoss(fraction: 0.031))) == .warn)
    #expect(VSidebarStatusLine.tone(for: .degraded(.jitter(milliseconds: 90))) == .warn)
    #expect(VSidebarStatusLine.tone(for: .authFailed) == .danger)
}

/// Chips replace the sentence for a live camera and for nothing else — the mockup's degraded row
/// reads `3.1% loss` alone, because naming the fault beats repeating the codec.
@Test func sidebarViewOnlyLiveRowsShowCodecChips() {
    #expect(VSidebarStatusLine.showsChips(for: .live))
    #expect(!VSidebarStatusLine.showsChips(for: .degraded(.packetLoss(fraction: 0.031))))
    #expect(!VSidebarStatusLine.showsChips(for: .connecting(progress: nil)))
    #expect(!VSidebarStatusLine.showsChips(for: .offline(retryInSeconds: nil)))
    #expect(!VSidebarStatusLine.showsChips(for: .authFailed))
    #expect(!VSidebarStatusLine.showsChips(for: .disabled))
}

// MARK: - Chips

/// Codec first, then resolution, skipping whatever has not been negotiated yet.
@Test func sidebarViewChipsOrderCodecBeforeResolution() {
    let full = sidebarViewCamera("A", codec: "H.265", resolution: "1080p")
    #expect(VSidebarChips.labels(for: full) == ["H.265", "1080p"])
    let codecOnly = sidebarViewCamera("B", codec: "H.264")
    #expect(VSidebarChips.labels(for: codecOnly) == ["H.264"])
    let resolutionOnly = sidebarViewCamera("C", resolution: "720p")
    #expect(VSidebarChips.labels(for: resolutionOnly) == ["720p"])
}

/// A camera described with empty strings shows no chips at all rather than an empty pill.
@Test func sidebarViewChipsIgnoreEmptyStrings() {
    let camera = sidebarViewCamera("A", codec: "", resolution: "")
    #expect(VSidebarChips.labels(for: camera).isEmpty)
}

/// Nothing is known before the stream is described, and the row still has to render (UX.md §0).
@Test func sidebarViewChipsAreEmptyBeforeTheStreamIsDescribed() {
    #expect(VSidebarChips.labels(for: sidebarViewCamera("A")).isEmpty)
}

// MARK: - Search highlighting

/// A contiguous prefix match highlights exactly the matched letters and nothing else.
@Test func sidebarViewHighlightSplitsOnMatchedOffsets() {
    let match = VSidebarMatch(field: .name, score: 900, nameOffsets: [0, 1, 2],
                              canHighlight: true)
    let runs = VSidebarHighlight.runs(name: "Front Door", match: match)
    #expect(runs.count == 2)
    #expect(runs.first?.text == "Fro")
    #expect(runs.first?.isMatch == true)
    #expect(runs.last?.text == "nt Door")
    #expect(runs.last?.isMatch == false)
}

/// A scattered subsequence match produces alternating runs, and the runs reassemble into the
/// original name — a highlight that dropped or duplicated a letter would be worse than none.
@Test func sidebarViewHighlightRunsReassembleTheName() {
    let match = VSidebarMatch(field: .name, score: 500, nameOffsets: [0, 6],
                              canHighlight: true)
    let runs = VSidebarHighlight.runs(name: "Front Door", match: match)
    #expect(runs.map(\.text).joined() == "Front Door")
    #expect(runs.filter(\.isMatch).map(\.text) == ["F", "D"])
}

/// `canHighlight == false` means folding changed the string's length, so the offsets cannot be
/// trusted against the original: the name is drawn plainly.
@Test func sidebarViewHighlightIsSkippedWhenOffsetsCannotBeTrusted() {
    let match = VSidebarMatch(field: .name, score: 900, nameOffsets: [0, 1],
                              canHighlight: false)
    let runs = VSidebarHighlight.runs(name: "Вход", match: match)
    #expect(runs.count == 1)
    #expect(runs.first?.isMatch == false)
}

/// Only a name match highlights. A row that got here on its host or serial shows a plain name.
@Test func sidebarViewHighlightOnlyAppliesToNameMatches() {
    let match = VSidebarMatch(field: .host, score: 900, nameOffsets: [0], canHighlight: true)
    let runs = VSidebarHighlight.runs(name: "Front Door", match: match)
    #expect(runs.count == 1)
    #expect(runs.first?.isMatch == false)
}

/// Offsets past the end of the name are discarded rather than trapping. They cannot arrive from
/// `VSidebarSearch`, but a highlighter that indexes blindly is one refactor away from a crash.
@Test func sidebarViewHighlightDiscardsOutOfRangeOffsets() {
    let match = VSidebarMatch(field: .name, score: 900, nameOffsets: [-1, 99],
                              canHighlight: true)
    let runs = VSidebarHighlight.runs(name: "Lobby", match: match)
    #expect(runs.count == 1)
    #expect(runs.first?.text == "Lobby")
    #expect(runs.first?.isMatch == false)
}

/// No match at all is the common case — no search is running — and it is one plain run.
@Test func sidebarViewHighlightWithoutAMatchIsOneRun() {
    let runs = VSidebarHighlight.runs(name: "Garage", match: nil)
    #expect(runs.count == 1)
    #expect(runs.first?.text == "Garage")
    #expect(runs.first?.isMatch == false)
}

/// An empty name produces no runs, so the concatenation that builds the `Text` stays empty rather
/// than emitting a stray zero-length run.
@Test func sidebarViewHighlightOfAnEmptyNameIsEmpty() {
    #expect(VSidebarHighlight.runs(name: "", match: nil).isEmpty)
}

/// A whole-name match is a single matched run, with no empty run either side of it.
@Test func sidebarViewHighlightOfAWholeNameIsOneMatchedRun() {
    let match = VSidebarMatch(field: .name, score: 1000, nameOffsets: [0, 1, 2],
                              canHighlight: true)
    let runs = VSidebarHighlight.runs(name: "Cam", match: match)
    #expect(runs.count == 1)
    #expect(runs.first?.isMatch == true)
    #expect(runs.first?.text == "Cam")
}

// MARK: - Identity

/// An explicitly persisted index wins over the derivation, which is what makes a user's chosen
/// colour tag stick (DESIGN.md §3.4).
@Test @MainActor func sidebarViewIdentityPrefersThePersistedIndex() {
    let camera = sidebarViewCamera("Front Door", identityIndex: 4)
    #expect(VSidebarIdentity.cameraIndex(camera) == 4)
    let group = VSidebarGroup(id: GroupID(), name: "Perimeter", identityIndex: 2)
    #expect(VSidebarIdentity.groupIndex(group) == 2)
}

/// Without one, the index is derived from the identifier — deterministically, and inside the six
/// colours of the categorical palette.
@Test @MainActor func sidebarViewIdentityDerivationIsStableAndInRange() {
    let camera = sidebarViewCamera("Garage")
    let first = VSidebarIdentity.cameraIndex(camera)
    #expect(first == VSidebarIdentity.cameraIndex(camera))
    #expect(first >= 0)
    #expect(first < VTheme.Color.Ident.all.count)
}

/// The initial is upper-cased and skips leading whitespace, so a name typed with a stray space
/// still shows a letter rather than a blank tag.
@Test func sidebarViewIdentityInitialIsTrimmedAndUppercased() {
    #expect(VSidebarIdentity.initial(of: "  perimeter") == "P")
    #expect(VSidebarIdentity.initial(of: "вход") == "В")
    #expect(VSidebarIdentity.initial(of: "   ") == nil)
    #expect(VSidebarIdentity.initial(of: "") == nil)
}

// MARK: - Motion spark

/// Short traces pad at the front, so a camera that has only just started reporting reads as quiet
/// until now rather than as busy at the start.
@Test @MainActor func sidebarViewSparkPadsShortTracesAtTheFront() {
    let buckets = VSidebarSpark.buckets([0.5, 1.0], count: 5)
    #expect(buckets == [0, 0, 0, 0.5, 1.0])
}

/// Long traces keep the most recent buckets, which is what "the last five minutes" means.
@Test @MainActor func sidebarViewSparkKeepsTheMostRecentBuckets() {
    let buckets = VSidebarSpark.buckets([0.1, 0.2, 0.3, 0.4], count: 2)
    #expect(buckets == [0.3, 0.4])
}

/// Out-of-range and non-finite samples are clamped rather than propagated: this data comes from a
/// running intensity estimator and a NaN would silently blank the bar.
@Test @MainActor func sidebarViewSparkClampsHostileSamples() {
    let buckets = VSidebarSpark.buckets([-2, 4, .nan, .infinity], count: 4)
    #expect(buckets == [0, 1, 0, 0])
}

/// A zero-length request yields nothing rather than trapping on a negative count.
@Test @MainActor func sidebarViewSparkWithNoBucketsIsEmpty() {
    #expect(VSidebarSpark.buckets([0.5], count: 0).isEmpty)
    #expect(VSidebarSpark.buckets([0.5], count: -3).isEmpty)
}

/// A silent bucket still draws the 1 pt baseline, never an empty gap (UX.md §4.2).
@Test @MainActor func sidebarViewSparkSilenceStillDrawsABaseline() {
    #expect(VSidebarSpark.height(0) == VSidebarMetrics.sparkBaseline)
    #expect(VSidebarSpark.height(1) == VSidebarMetrics.sparkHeight)
}

/// A bucket at or above the event threshold is full strength; anything quieter sits at α 0.35.
@Test @MainActor func sidebarViewSparkAlphaSeparatesEventsFromNoise() {
    #expect(VSidebarSpark.alpha(0) == VSidebarMetrics.sparkRestAlpha)
    #expect(VSidebarSpark.alpha(VSidebarMetrics.sparkEventThreshold) == 1.0)
    #expect(VSidebarSpark.alpha(1) == 1.0)
}

// MARK: - Footer

/// The footer's rate picks the unit a person would say it in (UX.md §3.3).
@Test func sidebarViewBitrateScalesToTheRightUnit() {
    #expect(VSidebarBitrate.scaled(820).unit == .bits)
    #expect(VSidebarBitrate.scaled(820_000).unit == .kilobits)
    #expect(VSidebarBitrate.scaled(4_200_000).unit == .megabits)
    #expect(VSidebarBitrate.scaled(1_800_000_000).unit == .gigabits)
}

/// And the value is the rate expressed in that unit — `1.8`, not `1_800_000_000`.
@Test func sidebarViewBitrateValueIsExpressedInItsUnit() {
    #expect(abs(VSidebarBitrate.scaled(1_800_000_000).value - 1.8) < 0.000_001)
    #expect(abs(VSidebarBitrate.scaled(4_200_000).value - 4.2) < 0.000_001)
    #expect(abs(VSidebarBitrate.scaled(820_000).value - 820) < 0.000_001)
}

/// The boundaries land on the larger unit, so 1 000 000 b/s reads `1.0 Mb/s` and never
/// `1000.0 kb/s`.
@Test func sidebarViewBitrateBoundariesRollOverToTheLargerUnit() {
    #expect(VSidebarBitrate.scaled(999).unit == .bits)
    #expect(VSidebarBitrate.scaled(1_000).unit == .kilobits)
    #expect(VSidebarBitrate.scaled(999_999).unit == .kilobits)
    #expect(VSidebarBitrate.scaled(1_000_000).unit == .megabits)
    #expect(VSidebarBitrate.scaled(999_999_999).unit == .megabits)
    #expect(VSidebarBitrate.scaled(1_000_000_000).unit == .gigabits)
}

/// A rate estimator dividing by an elapsed time can hand over zero, a negative or a NaN. None of
/// them may reach the footer as text.
@Test func sidebarViewBitrateRejectsNonFiniteAndNegativeRates() {
    for input in [0.0, -1.0, -1_000_000.0, Double.nan, Double.infinity] {
        let scaled = VSidebarBitrate.scaled(input)
        #expect(scaled.unit == .bits)
        #expect(scaled.value == 0)
    }
}

/// The footer counts the whole library, not the filtered list: a filter is a view of the system
/// and the footer reports the system (UX.md §3.3).
@Test func sidebarViewFooterCountsIgnoreTheSearch() {
    let cameras = [
        sidebarViewCamera("Front Door", status: .live),
        sidebarViewCamera("Garage", status: .live),
        sidebarViewCamera("Side Gate", status: .degraded(.packetLoss(fraction: 0.031))),
        sidebarViewCamera("Hallway", status: .offline(retryInSeconds: 8)),
    ]
    let plain = VSidebarTree(cameras: cameras)
    #expect(plain.liveCount == 3)
    #expect(plain.degradedCount == 1)

    let searched = VSidebarTree(cameras: cameras, search: VSidebarSearch(query: "zzz"))
    #expect(searched.liveCount == 3)
    #expect(searched.degradedCount == 1)
    #expect(searched.matchedCount == 0)
    #expect(sidebarViewTags(searched).contains("empty:cameras"))
}

/// A degraded camera counts as live as well: it is showing a picture, and the footer's warning form
/// is `"{n} live · {m} degraded"` rather than a count that moved between two buckets.
@Test func sidebarViewDegradedCamerasStillCountAsLive() {
    let tree = VSidebarTree(cameras: [
        sidebarViewCamera("Side Gate", status: .degraded(.jitter(milliseconds: 90))),
    ])
    #expect(tree.liveCount == 1)
    #expect(tree.degradedCount == 1)
}

// MARK: - Drop indicators

/// `between(index:)` puts the insertion line on the **leading** edge of the row at that index, and
/// nowhere else — two lines for one drop would be worse than none.
@Test func sidebarViewDropBetweenMarksTheLeadingEdgeOfOneRow() {
    let ids = [CameraID(), CameraID(), CameraID()]
    let edges = ids.map { VSidebarDrop.edge(for: .between(index: 1), camera: $0, in: ids) }
    #expect(edges == [nil, .above, nil])
}

/// A drop after the last camera is the one position no leading edge can express, so it becomes the
/// trailing edge of the final row.
@Test func sidebarViewDropPastTheEndMarksTheLastRowsTrailingEdge() {
    let ids = [CameraID(), CameraID(), CameraID()]
    let edges = ids.map { VSidebarDrop.edge(for: .between(index: 3), camera: $0, in: ids) }
    #expect(edges == [nil, nil, .below])
}

/// A drop before the first camera marks the first row, which is the position a user reaches by
/// dragging to the very top of the list.
@Test func sidebarViewDropAtZeroMarksTheFirstRow() {
    let ids = [CameraID(), CameraID()]
    #expect(VSidebarDrop.edge(for: .between(index: 0), camera: ids[0], in: ids) == .above)
    #expect(VSidebarDrop.edge(for: .between(index: 0), camera: ids[1], in: ids) == nil)
}

/// An index outside `0...count` draws nothing rather than clamping: a line at the wrong end of the
/// list is worse than no line, because the user would drop where it points.
@Test func sidebarViewDropOutOfRangeDrawsNothing() {
    let ids = [CameraID(), CameraID()]
    for index in [-1, 3, 99] {
        let edges = ids.map { VSidebarDrop.edge(for: .between(index: index), camera: $0, in: ids) }
        #expect(edges.allSatisfy { $0 == nil })
    }
}

/// The other two drop positions never produce an insertion line: `onGroup` highlights a group row
/// and `rejected` shows nothing at all (UX.md §4.3).
@Test func sidebarViewDropOnGroupAndRejectedDrawNoInsertionLine() {
    let ids = [CameraID()]
    #expect(VSidebarDrop.edge(for: .onGroup(index: 0), camera: ids[0], in: ids) == nil)
    #expect(VSidebarDrop.edge(for: .rejected, camera: ids[0], in: ids) == nil)
    #expect(VSidebarDrop.edge(for: nil, camera: ids[0], in: ids) == nil)
}

/// A camera that is not on screen — filtered out, or inside a collapsed device — never carries an
/// indicator, whatever the drag is proposing.
@Test func sidebarViewDropIgnoresCamerasThatAreNotVisible() {
    let visible = [CameraID(), CameraID()]
    let hidden = CameraID()
    #expect(VSidebarDrop.edge(for: .between(index: 0), camera: hidden, in: visible) == nil)
    #expect(VSidebarDrop.edge(for: .between(index: 2), camera: hidden, in: visible) == nil)
}

/// `onGroup(index:)` counts group rows, so the ordinals have to come from the tree in row order.
@Test func sidebarViewGroupOrdinalsFollowRowOrder() {
    let groups = [
        VSidebarGroup(id: GroupID(), name: "Perimeter"),
        VSidebarGroup(id: GroupID(), name: "Indoors"),
        VSidebarGroup(id: GroupID(), name: "Gate"),
    ]
    let tree = VSidebarTree(cameras: [sidebarViewCamera("Front Door")], groups: groups)
    let ordinals = VSidebarDrop.groupOrdinals(tree.rows)
    #expect(ordinals[groups[0].id] == 0)
    #expect(ordinals[groups[1].id] == 1)
    #expect(ordinals[groups[2].id] == 2)
    #expect(VSidebarDrop.targetsGroup(.onGroup(index: 1), ordinal: ordinals[groups[1].id]))
    #expect(!VSidebarDrop.targetsGroup(.onGroup(index: 1), ordinal: ordinals[groups[2].id]))
    #expect(!VSidebarDrop.targetsGroup(.between(index: 1), ordinal: 1))
    #expect(!VSidebarDrop.targetsGroup(nil, ordinal: 1))
    #expect(!VSidebarDrop.targetsGroup(.onGroup(index: 1), ordinal: nil))
}

// MARK: - Geometry

/// The row heights the view frames each kind at, so a change to one of them shows up here rather
/// than as a sidebar that no longer lines up with the mockup (R-37).
@Test @MainActor func sidebarViewRowHeightsMatchTheSpecification() {
    #expect(VTheme.Metrics.Row.camera == 44)
    #expect(VTheme.Metrics.Row.settings == 28)
    #expect(VTheme.Metrics.Row.sectionHeader == 22)
    #expect(VSidebarMetrics.footerHeight == 32)
}

/// Twenty 1 pt bars separated by 1 pt gaps fit inside the 40 pt spark with room to spare.
@Test @MainActor func sidebarViewSparkBarsFitTheirBox() {
    let bars = CGFloat(VSidebarMetrics.sparkBuckets) * VSidebarMetrics.sparkBar
    let gaps = CGFloat(VSidebarMetrics.sparkBuckets - 1) * VSidebarMetrics.sparkBar
    #expect(bars + gaps <= VSidebarMetrics.sparkWidth)
}

/// The rail is inset equally top and bottom inside the 44 pt row.
@Test @MainActor func sidebarViewRailIsCentredInTheCameraRow() {
    let slack = VTheme.Metrics.Row.camera - VSidebarMetrics.railHeight
    #expect(slack == 14)
}

/// The camera row's fixed leading furniture leaves a usable name column at the minimum sidebar
/// width — the check that catches a thumbnail or spark that grew without anyone measuring.
@Test @MainActor func sidebarViewNameColumnSurvivesTheMinimumWidth() {
    let panelPadding = VTheme.Space.sm * 2
    let furniture = VSidebarMetrics.railWidth
        + VSidebarMetrics.railGap
        + VSidebarMetrics.thumbnailWidth
        + VTheme.Space.sm
        + VTheme.Space.sm
        + VSidebarMetrics.sparkWidth
        + VTheme.Space.xs
    let nameColumn = VTheme.Metrics.sidebarMin - panelPadding - furniture
    #expect(nameColumn >= 80)
}

#endif  // os(macOS)
