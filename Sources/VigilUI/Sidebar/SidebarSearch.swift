//
//  SidebarSearch.swift
//  VigilUI
//
//  The search field's matching rules and the filter menu's predicates. Pure functions, because
//  "why did my camera disappear from the list" is a question only a test can answer cheaply.
//  macOS-only. Implements docs/UX.md §4.4 (match priority, folding, filters).
//

#if os(macOS)

import Foundation

// MARK: - VSidebarFilter

/// The filter menu's five states (UX.md §4.4, §1.3).
package enum VSidebarFilter: String, Sendable, Hashable, CaseIterable, Identifiable {

    /// No filtering.
    case all

    /// Cameras currently showing a picture.
    case live

    /// Cameras with no picture, including auth failures — from the operator's point of view a
    /// camera they cannot see is offline, whatever the reason.
    case offline

    /// Cameras Vigil is recording locally.
    case recording

    /// Cameras with confirmed motion in the last 24 hours.
    case motion24h

    /// Stable identity for `ForEach`.
    package var id: String { rawValue }

    /// 24 hours, the window ``motion24h`` uses.
    package static let motionWindow: TimeInterval = 24 * 60 * 60

    /// Whether a camera passes this filter.
    ///
    /// - Parameters:
    ///   - camera: the camera to test.
    ///   - now: the current instant, injected so the motion window is deterministic in a test rather
    ///     than depending on the wall clock.
    package func accepts(_ camera: VSidebarCamera, now: Date) -> Bool {
        switch self {
        case .all:
            return true
        case .live:
            return camera.status.isShowingVideo
        case .offline:
            return !camera.status.isShowingVideo
        case .recording:
            return camera.isRecording
        case .motion24h:
            guard let last = camera.lastMotionAt else { return false }
            let age = now.timeIntervalSince(last)
            return age >= 0 && age <= Self.motionWindow
        }
    }

    /// Whether this filter hides anything, which is what decides if a removable chip is shown.
    package var isActive: Bool {
        self != .all
    }
}

// MARK: - VSidebarMatchField

/// Which field a query matched, in the priority order UX.md §4.4 lays down.
///
/// The order is the ranking: a query that matches one camera's name and another's serial puts the
/// name match first, however good the serial match was.
package enum VSidebarMatchField: Int, Sendable, Hashable, Comparable, CaseIterable {

    /// The camera's name, matched fuzzily.
    case name = 0

    /// The name of the group the camera is in, matched fuzzily.
    case group = 1

    /// The host or IP address, matched by **prefix** only — a scattered match against an address is
    /// noise, since almost any query is a subsequence of some dotted quad.
    case host = 2

    /// The model name, matched by substring.
    case model = 3

    /// The serial number, matched only on an **exact suffix of four characters or more**, which is
    /// how a serial is read off a label.
    case serial = 4

    /// Lower is better.
    package static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - VSidebarMatch

/// The result of matching one camera against one query.
package struct VSidebarMatch: Sendable, Hashable {

    /// Which field matched.
    package let field: VSidebarMatchField

    /// How good the match was within that field; higher is better. Only comparable against other
    /// matches on the **same** field — ``field`` is the primary key.
    package let score: Int

    /// Character offsets, into the camera's original ``VSidebarCamera/name``, that the query matched.
    ///
    /// Empty unless ``field`` is ``VSidebarMatchField/name``, since only the name is highlighted
    /// (UX.md §4.4: "matched substrings highlight with accent at semibold").
    package let nameOffsets: [Int]

    /// Whether ``nameOffsets`` can be trusted to line up with the original string.
    ///
    /// Matching runs on a case- and diacritic-folded copy. Folding is one-to-one per character for
    /// every script Vigil ships in, but it is not guaranteed to be — a composed character can fold to
    /// two — and an offset computed on a folded string of a different length would highlight the
    /// wrong letters. When the lengths differ this is `false` and the view draws the name plainly.
    /// Losing a highlight is a cosmetic loss; highlighting the wrong characters looks like a bug.
    package let canHighlight: Bool

    /// Orders two matches: better field first, then better score, so a caller can sort directly.
    package func isBetter(than other: VSidebarMatch) -> Bool {
        if field != other.field { return field < other.field }
        return score > other.score
    }
}

// MARK: - VSidebarSearch

/// One query plus one filter, applied to cameras.
///
/// ## Folding
///
/// Matching is case- and diacritic-insensitive via
/// `folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)`, which is what
/// makes `вход` match `Вход` — the example UX.md §4.4 gives, and the reason a naive `lowercased()`
/// is not enough.
///
/// ## Scoring
///
/// Within a field the score is a small ladder rather than a learned ranking, because a sidebar holds
/// tens of cameras and a predictable order beats a clever one:
///
/// | Kind of match | Score |
/// |---|---|
/// | The whole field equals the query | 1000 |
/// | The field starts with the query | 900 − (length beyond the query, capped) |
/// | The query appears contiguously | 800 − (offset, capped) |
/// | The query is a scattered subsequence | 500 − (gaps + first offset, capped) |
///
/// The penalties are capped so a long name can never score below the next tier down; that keeps the
/// tiers meaningful, which is what makes the ordering explainable to a user.
package struct VSidebarSearch: Sendable, Hashable {

    // MARK: - Stored Properties

    /// The raw query as typed.
    package let query: String

    /// The filter chosen from the menu.
    package let filter: VSidebarFilter

    /// The query, folded once at construction. Folding per camera per keystroke would be the one
    /// place this type could plausibly cost anything.
    private let foldedQuery: String

    // MARK: - Initialisation

    /// Creates a search. Leading and trailing whitespace is trimmed, so a stray space does not
    /// silently match nothing.
    package init(query: String = "", filter: VSidebarFilter = .all) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = trimmed
        self.filter = filter
        self.foldedQuery = Self.fold(trimmed)
    }

    /// Folds a string for comparison.
    package static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    // MARK: - Public API

    /// Whether anything is being narrowed at all.
    package var isActive: Bool {
        !query.isEmpty || filter.isActive
    }

    /// Whether text is being matched, as opposed to only filtering.
    package var hasQuery: Bool {
        !foldedQuery.isEmpty
    }

    /// Matches one camera.
    ///
    /// - Parameters:
    ///   - camera: the camera to test.
    ///   - groupName: the name of the camera's group, when it has one, so the group field can match
    ///     without this type needing the whole group list.
    ///   - now: the instant the motion filter measures against.
    /// - Returns: the best match, or `nil` when the camera is filtered out or nothing matched. A
    ///   camera that passes the filter with **no** query returns a match on
    ///   ``VSidebarMatchField/name`` with no offsets, so a caller can treat "shown" uniformly.
    package func match(_ camera: VSidebarCamera,
                       groupName: String? = nil,
                       now: Date = Date()) -> VSidebarMatch? {
        guard filter.accepts(camera, now: now) else { return nil }
        guard hasQuery else {
            return VSidebarMatch(field: .name, score: 0, nameOffsets: [], canHighlight: false)
        }
        let foldedName = Self.fold(camera.name)
        if let scored = Self.score(foldedName, query: foldedQuery) {
            return VSidebarMatch(field: .name,
                                 score: scored.score,
                                 nameOffsets: scored.offsets,
                                 canHighlight: foldedName.count == camera.name.count)
        }
        if let group = groupName, let scored = Self.score(Self.fold(group), query: foldedQuery) {
            return VSidebarMatch(field: .group, score: scored.score,
                                 nameOffsets: [], canHighlight: false)
        }
        // Host is prefix-only: almost any query is a subsequence of some dotted quad, so a fuzzy
        // match here would surface every camera on the subnet for a query of "1".
        let foldedHost = Self.fold(camera.host)
        if !foldedHost.isEmpty, foldedHost.hasPrefix(foldedQuery) {
            let excess = Swift.min(foldedHost.count - foldedQuery.count, 99)
            return VSidebarMatch(field: .host, score: 900 - excess,
                                 nameOffsets: [], canHighlight: false)
        }
        if let model = camera.model {
            let foldedModel = Self.fold(model)
            if !foldedModel.isEmpty, foldedModel.contains(foldedQuery) {
                return VSidebarMatch(field: .model, score: 800,
                                     nameOffsets: [], canHighlight: false)
            }
        }
        if let serial = camera.serial, foldedQuery.count >= Self.minimumSerialSuffix {
            let foldedSerial = Self.fold(serial)
            if !foldedSerial.isEmpty, foldedSerial.hasSuffix(foldedQuery) {
                return VSidebarMatch(field: .serial, score: 1000,
                                     nameOffsets: [], canHighlight: false)
            }
        }
        return nil
    }

    /// A serial is matched only from four characters, so a two-digit query does not pull in every
    /// device whose serial happens to end that way.
    package static let minimumSerialSuffix = 4

    // MARK: - Scoring

    /// The tiered score for a folded candidate against a folded query, plus the matched offsets.
    ///
    /// Returns `nil` when the query is not even a subsequence of the candidate.
    private static func score(_ candidate: String,
                              query: String) -> (score: Int, offsets: [Int])? {
        guard !query.isEmpty else { return nil }
        guard !candidate.isEmpty else { return nil }
        let haystack = Array(candidate)
        let needle = Array(query)
        guard needle.count <= haystack.count else { return nil }
        if haystack == needle {
            return (1000, Array(0..<needle.count))
        }
        if let start = Self.contiguousIndex(haystack, needle) {
            let offsets = Array(start..<(start + needle.count))
            if start == 0 {
                // Prefix: penalise only how much of the name is left over, capped so a long name
                // cannot fall out of its tier.
                let excess = Swift.min(haystack.count - needle.count, 99)
                return (900 - excess, offsets)
            }
            return (800 - Swift.min(start, 99), offsets)
        }
        guard let offsets = Self.subsequenceOffsets(haystack, needle) else { return nil }
        // A gap is a discontinuity between consecutive matched characters. Fewer gaps and an earlier
        // start read as a better match.
        var gaps = 0
        for (previous, next) in zip(offsets, offsets.dropFirst()) where next != previous + 1 {
            gaps += 1
        }
        let firstOffset = offsets.first ?? 0
        return (500 - Swift.min(gaps + firstOffset, 99), offsets)
    }

    /// The index at which `needle` appears contiguously in `haystack`, or `nil`.
    ///
    /// Written over arrays of `Character` rather than with `String.range(of:)` so that the offsets
    /// handed back are character offsets — which is what a caller can use to highlight — rather than
    /// `String.Index` values that would have to be converted anyway.
    private static func contiguousIndex(_ haystack: [Character],
                                        _ needle: [Character]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        let last = haystack.count - needle.count
        for start in 0...last {
            var matched = true
            for offset in 0..<needle.count where haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return start }
        }
        return nil
    }

    /// The offsets of a greedy left-to-right subsequence match, or `nil` when there is none.
    ///
    /// Greedy rather than optimal: an optimal matcher would need to search, and on a list of tens of
    /// cameras the difference is invisible while the cost of a non-obvious ranking is not.
    private static func subsequenceOffsets(_ haystack: [Character],
                                           _ needle: [Character]) -> [Int]? {
        var offsets: [Int] = []
        offsets.reserveCapacity(needle.count)
        var position = 0
        for character in needle {
            var found = false
            while position < haystack.count {
                let current = position
                position += 1
                if haystack[current] == character {
                    offsets.append(current)
                    found = true
                    break
                }
            }
            guard found else { return nil }
        }
        return offsets
    }
}

#endif  // os(macOS)
