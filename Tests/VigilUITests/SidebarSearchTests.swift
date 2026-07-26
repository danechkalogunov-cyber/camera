//
//  SidebarSearchTests.swift
//  VigilUITests
//
//  Search matching and the filter predicates. The folding cases matter because the customer's
//  cameras are named in Russian, and the field-priority cases matter because a query that pulls in
//  every camera on the subnet is worse than no search at all.
//  Covers Sources/VigilUI/Sidebar/SidebarSearch.swift; see docs/UX.md §4.4.
//

#if os(macOS)

import Foundation
import Testing

import VigilProtocols

@testable import VigilUI

// MARK: - Helpers

private func sidebarSearchCamera(_ name: String,
                                 host: String = "192.168.1.64",
                                 model: String? = nil,
                                 serial: String? = nil,
                                 status: VSidebarStatus = .live,
                                 recording: Bool = false,
                                 motionAt: Date? = nil) -> VSidebarCamera {
    VSidebarCamera(id: CameraID(),
                   name: name,
                   host: host,
                   status: status,
                   isRecording: recording,
                   model: model,
                   serial: serial,
                   lastMotionAt: motionAt)
}

// MARK: - Folding

/// Matching is case-insensitive.
@Test func sidebarSearchIsCaseInsensitive() {
    let camera = sidebarSearchCamera("Front Door")
    #expect(VSidebarSearch(query: "front").match(camera) != nil)
    #expect(VSidebarSearch(query: "FRONT").match(camera) != nil)
    #expect(VSidebarSearch(query: "FrOnT").match(camera) != nil)
}

/// Matching is diacritic-insensitive, which is the case UX.md §4.4 names: `вход` matches `Вход`.
@Test func sidebarSearchIsDiacriticAndCaseInsensitiveForCyrillic() {
    let camera = sidebarSearchCamera("Вход")
    #expect(VSidebarSearch(query: "вход").match(camera) != nil)
    #expect(VSidebarSearch(query: "ВХОД").match(camera) != nil)
    #expect(VSidebarSearch(query: "вхо").match(camera) != nil)
}

/// Latin diacritics fold too.
@Test func sidebarSearchFoldsLatinDiacritics() {
    let camera = sidebarSearchCamera("Café Entrée")
    #expect(VSidebarSearch(query: "cafe").match(camera) != nil)
    #expect(VSidebarSearch(query: "entree").match(camera) != nil)
    #expect(VSidebarSearch(query: "café").match(camera) != nil)
}

/// A query is trimmed, so a trailing space does not make it match nothing.
@Test func sidebarSearchTrimsSurroundingWhitespace() {
    let camera = sidebarSearchCamera("Front Door")
    #expect(VSidebarSearch(query: "  front  ").match(camera) != nil)
    #expect(VSidebarSearch(query: "   ").hasQuery == false)
    #expect(VSidebarSearch(query: "   ").isActive == false)
}

// MARK: - Field priority

/// A name match beats a host match, whatever the scores.
@Test func sidebarSearchNameBeatsHostAndModelAndSerial() throws {
    let named = sidebarSearchCamera("Gate 19", host: "10.0.0.2", model: "DS-19", serial: "AAAA19")
    let match = try #require(VSidebarSearch(query: "19").match(named))
    #expect(match.field == .name)
}

/// A host matches by prefix only. A scattered match against a dotted quad is noise.
@Test func sidebarSearchMatchesHostByPrefixOnly() throws {
    let camera = sidebarSearchCamera("Lobby", host: "192.168.1.64")
    let prefix = try #require(VSidebarSearch(query: "192.168").match(camera))
    #expect(prefix.field == .host)
    // "1.6" appears inside the address but is not a prefix, and must not match.
    #expect(VSidebarSearch(query: "1.6").match(camera) == nil)
    #expect(VSidebarSearch(query: "68.1").match(camera) == nil)
}

/// A model matches on a substring.
@Test func sidebarSearchMatchesModelBySubstring() throws {
    let camera = sidebarSearchCamera("Lobby", host: "10.0.0.5", model: "DS-2CD2385G1")
    let match = try #require(VSidebarSearch(query: "2385").match(camera))
    #expect(match.field == .model)
}

/// A serial matches only on an exact suffix of four characters or more.
@Test func sidebarSearchMatchesSerialOnlyOnALongExactSuffix() throws {
    let camera = sidebarSearchCamera("Lobby", host: "10.0.0.5", serial: "DS2CD2385G120210517")
    let match = try #require(VSidebarSearch(query: "0517").match(camera))
    #expect(match.field == .serial)
    // Three characters is below the threshold.
    #expect(VSidebarSearch(query: "517").match(camera) == nil)
    // A long run that is not a suffix does not match.
    #expect(VSidebarSearch(query: "2385").match(camera) == nil)
}

/// A group name matches, and ranks below the camera's own name.
@Test func sidebarSearchMatchesGroupNameBelowCameraName() throws {
    let camera = sidebarSearchCamera("Lobby", host: "10.0.0.5")
    let match = try #require(VSidebarSearch(query: "perim").match(camera,
                                                                  groupName: "Perimeter"))
    #expect(match.field == .group)
    #expect(VSidebarMatchField.name < VSidebarMatchField.group)
}

// MARK: - Scoring

/// An exact name scores above a prefix, which scores above an interior substring, which scores
/// above a scattered subsequence.
@Test func sidebarSearchScoreTiersAreOrdered() throws {
    let exact = try #require(VSidebarSearch(query: "gate").match(sidebarSearchCamera("Gate")))
    let prefix = try #require(VSidebarSearch(query: "gate").match(sidebarSearchCamera("Gate East")))
    let inner = try #require(VSidebarSearch(query: "gate").match(sidebarSearchCamera("Side Gate")))
    let fuzzy = try #require(VSidebarSearch(query: "gte").match(sidebarSearchCamera("Garage Test")))
    #expect(exact.score > prefix.score)
    #expect(prefix.score > inner.score)
    #expect(inner.score > fuzzy.score)
}

/// A long name cannot let a prefix match fall out of its tier and below a substring match.
///
/// This is what the penalty caps are for: without them a 200-character name would score a prefix
/// match below an interior one and the ordering would stop being explainable.
@Test func sidebarSearchPenaltiesAreCappedSoTiersNeverInvert() throws {
    let longName = "Gate " + String(repeating: "x", count: 400)
    let prefix = try #require(VSidebarSearch(query: "gate").match(sidebarSearchCamera(longName)))
    let inner = try #require(VSidebarSearch(query: "gate").match(sidebarSearchCamera("Side Gate")))
    #expect(prefix.score > inner.score)
}

/// A query longer than the name cannot match it.
@Test func sidebarSearchRejectsAQueryLongerThanTheName() {
    #expect(VSidebarSearch(query: "front door east").match(sidebarSearchCamera("Front")) == nil)
}

/// A query whose characters are not all present does not match.
@Test func sidebarSearchRejectsANonSubsequence() {
    #expect(VSidebarSearch(query: "zzz").match(sidebarSearchCamera("Front Door")) == nil)
    #expect(VSidebarSearch(query: "rof").match(sidebarSearchCamera("Front")) == nil)
}

// MARK: - Highlight offsets

/// A contiguous match reports exactly the offsets it matched, in the original string's coordinates.
@Test func sidebarSearchReportsContiguousHighlightOffsets() throws {
    let match = try #require(VSidebarSearch(query: "Door").match(sidebarSearchCamera("Front Door")))
    #expect(match.nameOffsets == [6, 7, 8, 9])
    #expect(match.canHighlight)
}

/// A scattered match reports one offset per matched character.
@Test func sidebarSearchReportsScatteredHighlightOffsets() throws {
    let match = try #require(VSidebarSearch(query: "fd").match(sidebarSearchCamera("Front Door")))
    #expect(match.nameOffsets == [0, 6])
    #expect(match.canHighlight)
}

/// Offsets always fall inside the original name, which is what makes them safe to slice with.
@Test func sidebarSearchHighlightOffsetsAreAlwaysInBounds() {
    let names = ["Front Door", "Вход", "Café", "Gate 19", "A", "Side Gate East Wing"]
    let queries = ["f", "o", "e", "a", "g", "1", "вх", "cafe", "ate"]
    for name in names {
        let camera = sidebarSearchCamera(name)
        for query in queries {
            guard let match = VSidebarSearch(query: query).match(camera) else { continue }
            guard match.canHighlight else { continue }
            let count = camera.name.count
            for offset in match.nameOffsets {
                #expect(offset >= 0 && offset < count,
                        "offset \(offset) out of bounds for \"\(name)\" query \"\(query)\"")
            }
        }
    }
}

/// With no query, a camera that passes the filter still returns a match so callers treat "shown"
/// uniformly — but with nothing to highlight.
@Test func sidebarSearchEmptyQueryMatchesEverythingWithoutHighlights() throws {
    let camera = sidebarSearchCamera("Front Door")
    let match = try #require(VSidebarSearch().match(camera))
    #expect(match.nameOffsets.isEmpty)
    #expect(!match.canHighlight)
}

// MARK: - Filters

/// The live filter keeps cameras showing a picture, including degraded ones.
@Test func sidebarSearchLiveFilterIncludesDegraded() {
    let now = Date()
    let live = sidebarSearchCamera("A", status: .live)
    let degraded = sidebarSearchCamera("B", status: .degraded(.packetLoss(fraction: 0.031)))
    let offline = sidebarSearchCamera("C", status: .offline(retryInSeconds: 8))
    #expect(VSidebarFilter.live.accepts(live, now: now))
    #expect(VSidebarFilter.live.accepts(degraded, now: now))
    #expect(!VSidebarFilter.live.accepts(offline, now: now))
}

/// The offline filter is the complement of live, and includes auth failures and disabled cameras —
/// from the operator's point of view a camera they cannot see is offline.
@Test func sidebarSearchOfflineFilterIsTheComplementOfLive() {
    let now = Date()
    let cases: [VSidebarStatus] = [
        .disabled, .connecting(progress: nil), .live,
        .degraded(.switchedToTCP), .offline(retryInSeconds: nil), .authFailed,
    ]
    for status in cases {
        let camera = sidebarSearchCamera("A", status: status)
        #expect(VSidebarFilter.live.accepts(camera, now: now)
                != VSidebarFilter.offline.accepts(camera, now: now))
    }
}

/// The recording filter keeps only cameras being recorded.
@Test func sidebarSearchRecordingFilterKeepsOnlyRecordingCameras() {
    let now = Date()
    #expect(VSidebarFilter.recording.accepts(sidebarSearchCamera("A", recording: true), now: now))
    #expect(!VSidebarFilter.recording.accepts(sidebarSearchCamera("B"), now: now))
}

/// The motion filter uses a 24 hour window measured from the injected instant, and excludes a
/// timestamp in the future.
@Test func sidebarSearchMotionFilterUsesAnInjectedTwentyFourHourWindow() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let recent = sidebarSearchCamera("A", motionAt: now.addingTimeInterval(-3600))
    let old = sidebarSearchCamera("B", motionAt: now.addingTimeInterval(-25 * 3600))
    let edge = sidebarSearchCamera("C", motionAt: now.addingTimeInterval(-24 * 3600))
    let future = sidebarSearchCamera("D", motionAt: now.addingTimeInterval(3600))
    let never = sidebarSearchCamera("E")
    #expect(VSidebarFilter.motion24h.accepts(recent, now: now))
    #expect(!VSidebarFilter.motion24h.accepts(old, now: now))
    #expect(VSidebarFilter.motion24h.accepts(edge, now: now))
    #expect(!VSidebarFilter.motion24h.accepts(future, now: now))
    #expect(!VSidebarFilter.motion24h.accepts(never, now: now))
}

/// A filter and a query compose: the filter is applied first, so a filtered-out camera never
/// matches however good its name is.
@Test func sidebarSearchFilterIsAppliedBeforeTheQuery() {
    let offline = sidebarSearchCamera("Front Door", status: .offline(retryInSeconds: 4))
    let search = VSidebarSearch(query: "Front Door", filter: .live)
    #expect(search.match(offline) == nil)
    #expect(VSidebarSearch(query: "Front Door", filter: .offline).match(offline) != nil)
}

/// Only `.all` reports itself inactive, which is what decides whether a removable chip is drawn.
@Test func sidebarSearchOnlyAllFilterIsInactive() {
    #expect(!VSidebarFilter.all.isActive)
    for filter in VSidebarFilter.allCases where filter != .all {
        #expect(filter.isActive)
    }
    #expect(VSidebarSearch(filter: .live).isActive)
    #expect(!VSidebarSearch().isActive)
}

// MARK: - Status helpers

/// Severity orders the footer's popover worst-first.
@Test func sidebarSearchStatusSeverityOrdersWorstFirst() {
    let ordered: [VSidebarStatus] = [
        .authFailed,
        .offline(retryInSeconds: 4),
        .degraded(.jitter(milliseconds: 90)),
        .connecting(progress: 0.5),
        .live,
        .disabled,
    ]
    let severities = ordered.map(\.severity)
    #expect(severities == severities.sorted())
    #expect(Set(severities).count == severities.count)
}

#endif
