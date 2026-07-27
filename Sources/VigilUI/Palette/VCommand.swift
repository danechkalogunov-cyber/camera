//
//  VCommand.swift
//  VigilUI
//
//  What the ⌘K palette can run, and how a query is ranked against it. Pure values and pure
//  functions — no SwiftUI — because "why is that command not first" is a question only a test can
//  answer cheaply, and because the ranking has to be provably the *same* ranking the sidebar uses.
//  macOS-only. Implements docs/UX.md §3.2 (the palette and the overflow menu) with the match rules
//  of §4.4 (folding, the tiered ladder).
//

#if os(macOS)

import Foundation

// MARK: - VCommandCategory

/// The section a command is filed under in the palette.
///
/// The raw values are the *display* order of the section headers when two sections tie, and nothing
/// else — a section's real position comes from how well its best member matched, so a query that
/// nails a recording action does not have to scroll past every layout first.
package enum VCommandCategory: Int, Sendable, Hashable, CaseIterable, Identifiable, Comparable {

    /// Stage layouts: single, 2 × 2, the hero, 3 × 3 (`⌘1`…`⌘8`).
    case layout = 0

    /// Chrome and presentation: sidebar, inspector, full screen, cycle.
    case view = 1

    /// Acting on a camera: connect, snapshot, mute, discover.
    case camera = 2

    /// Recording and the library.
    case recording = 3

    /// The application itself: settings, diagnostics, help.
    case application = 4

    /// Stable identity for `ForEach`.
    package var id: Int { rawValue }

    /// Lower is earlier.
    package static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - VCommand

/// One runnable entry in the command palette.
///
/// ## Why ``title`` is a plain `String` and not a `LocalizedStringKey`
///
/// Ranking folds and compares the title character by character, which a `LocalizedStringKey` cannot
/// be made to do — it is opaque, it is not `Sendable`, and it is not `Hashable` in a way this type
/// could rely on. So the **caller** resolves the title into the user's language and hands over the
/// finished string, and the palette ranks what the user can actually see. That is also the only
/// spelling under which "вход" ranks against a Russian command name at all; a key-based title would
/// rank against the English key and silently mis-order every non-English build.
///
/// The consequence is deliberate and worth stating: a command's title is drawn with
/// `Text(verbatim:)`, so no command title is ever a localisation key in this target. Only the
/// palette's own chrome — the placeholder, the empty state, the section headers — is localised here.
package struct VCommand: Sendable, Hashable, Identifiable {

    /// A stable identifier, used for selection and for `ForEach`. Never shown.
    ///
    /// It must survive a re-rank: the palette remembers the *selected command*, not the selected
    /// row, so that typing one more character does not move the highlight onto a different action
    /// under the user's finger.
    package let id: String

    /// The title, already localised by the caller. See the type's note on why this is a `String`.
    package let title: String

    /// An optional second line — a camera's group, a layout's tile count, a destination folder.
    ///
    /// Matched, but only contiguously and at a tier below every title match, so a subtitle can help
    /// a user find something without ever displacing a real title hit.
    package let subtitle: String?

    /// The key equivalent as it is printed on a key cap: `⌘K`, `⌥⌘I`, `⌘1`.
    ///
    /// `nil` when the command has no shortcut. Never localised — a key name is not translated, which
    /// is the same rule ``VToolbarView``'s key cap follows.
    package let shortcut: String?

    /// The section the command is filed under.
    package let category: VCommandCategory

    /// Whether the command can run right now.
    ///
    /// A disabled command is still listed, dimmed, because a palette that hides what it cannot do is
    /// a palette that teaches the user nothing. It can never be the first result and can never be
    /// selected — see ``VCommandQuery/rank(_:)`` and
    /// ``VCommandQuery/selection(movingBy:from:in:)``.
    package let isEnabled: Bool

    /// Creates a command.
    ///
    /// - Parameters:
    ///   - id: a stable, never-shown identifier.
    ///   - title: the localised title.
    ///   - subtitle: an optional localised second line.
    ///   - shortcut: the key cap caption, or `nil`.
    ///   - category: the section to file it under.
    ///   - isEnabled: whether it can run now; `true` by default.
    package init(id: String,
                 title: String,
                 subtitle: String? = nil,
                 shortcut: String? = nil,
                 category: VCommandCategory,
                 isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.category = category
        self.isEnabled = isEnabled
    }
}

// MARK: - VCommandMatch

/// One command, plus how well it matched the query.
package struct VCommandMatch: Sendable, Hashable, Identifiable {

    /// The command that matched.
    package let command: VCommand

    /// How good the match was; higher is better. Comparable across categories, unlike
    /// ``VSidebarMatch``'s score — the palette has no field-priority axis, so the number is the
    /// whole ordering.
    package let score: Int

    /// Character offsets, into the command's original ``VCommand/title``, that the query matched.
    ///
    /// Empty when the match came from the subtitle, since only the title is highlighted.
    package let titleOffsets: [Int]

    /// Whether ``titleOffsets`` line up with the original title.
    ///
    /// Matching runs on a folded copy. Folding is one-to-one per character for every script Vigil
    /// ships in, but it is not guaranteed to be — a composed character can fold to two — and an
    /// offset computed on a folded string of a different length would embolden the wrong letters.
    /// When the lengths differ this is `false` and the row draws the title plainly. Losing a
    /// highlight is cosmetic; highlighting the wrong characters looks like a bug. This is exactly
    /// ``VSidebarMatch/canHighlight``'s rule, restated because the two types do not share storage.
    package let canHighlight: Bool

    /// The command's identity, so a match can go straight into a `ForEach`.
    package var id: String { command.id }

    /// Creates a match. Normally produced by ``VCommandQuery/match(_:)`` rather than by hand.
    package init(command: VCommand, score: Int, titleOffsets: [Int], canHighlight: Bool) {
        self.command = command
        self.score = score
        self.titleOffsets = titleOffsets
        self.canHighlight = canHighlight
    }
}

// MARK: - VCommandGroup

/// A run of matches that share a category, in the order the palette draws them.
package struct VCommandGroup: Sendable, Hashable, Identifiable {

    /// The section these matches belong to; also the header's identity.
    package let category: VCommandCategory

    /// The matches, best first. Never empty — ``VCommandQuery/groups(_:)`` drops empty sections
    /// rather than drawing a header with nothing under it.
    package let matches: [VCommandMatch]

    /// Stable identity for `ForEach`.
    package var id: Int { category.rawValue }

    /// Creates a group.
    package init(category: VCommandCategory, matches: [VCommandMatch]) {
        self.category = category
        self.matches = matches
    }
}

// MARK: - VCommandQuery

/// One query, applied to a list of commands.
///
/// ## Folding
///
/// Matching is case- and diacritic-insensitive, and it folds through ``VSidebarSearch/fold(_:)``
/// **by calling it**, not by repeating its options. That is the point: the palette and the sidebar
/// must agree about whether `вход` matches `Вход`, and the only way two rankers cannot drift is for
/// there to be one folding function.
///
/// ## Scoring
///
/// The ladder is ``VSidebarSearch``'s, tier for tier, because a user who has learned how the sidebar
/// orders results has learned how the palette orders them too:
///
/// | Kind of match | Score |
/// |---|---|
/// | The whole title equals the query | 1000 |
/// | The title starts with the query | 900 − (length beyond the query, capped at 99) |
/// | The query appears contiguously in the title | 800 − (offset, capped at 99) |
/// | The query is a scattered subsequence of the title | 500 − (gaps + first offset, capped at 99) |
/// | The query appears contiguously in the **subtitle** | 400 |
///
/// 400 is not an arbitrary floor: the worst possible title match scores 500 − 99 = 401, so a
/// subtitle hit can never outrank a title hit however bad the title hit was. That is what makes the
/// subtitle safe to match at all.
package struct VCommandQuery: Sendable, Hashable {

    // MARK: - Stored Properties

    /// The raw query as typed, trimmed.
    package let query: String

    /// The query, folded once at construction. Folding per command per keystroke would be the one
    /// place this type could plausibly cost anything.
    private let foldedQuery: String

    // MARK: - Initialisation

    /// Creates a query. Leading and trailing whitespace is trimmed, so a stray space does not
    /// silently match nothing.
    package init(_ query: String = "") {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = trimmed
        self.foldedQuery = Self.fold(trimmed)
    }

    /// Folds a string for comparison.
    ///
    /// Delegates to ``VSidebarSearch/fold(_:)`` so that the palette cannot fold differently from the
    /// sidebar. ⛔ Never reimplement the options here.
    package static func fold(_ text: String) -> String {
        VSidebarSearch.fold(text)
    }

    /// The score a subtitle match earns. Below the worst possible title match, which is 401.
    package static let subtitleScore = 400

    // MARK: - Public API

    /// Whether text is being matched, as opposed to the palette merely being open.
    package var hasQuery: Bool {
        !foldedQuery.isEmpty
    }

    /// Matches one command.
    ///
    /// - Parameter command: the command to test.
    /// - Returns: the match, or `nil` when nothing matched. With **no** query every command matches
    ///   at score 0, so the palette can show its full catalogue the moment it opens.
    package func match(_ command: VCommand) -> VCommandMatch? {
        guard hasQuery else {
            return VCommandMatch(command: command, score: 0,
                                 titleOffsets: [], canHighlight: false)
        }
        let foldedTitle = Self.fold(command.title)
        if let scored = Self.score(foldedTitle, query: foldedQuery) {
            return VCommandMatch(command: command,
                                 score: scored.score,
                                 titleOffsets: scored.offsets,
                                 canHighlight: foldedTitle.count == command.title.count)
        }
        // Subtitles are contiguous-only. A scattered match against "Living Room / Ground Floor"
        // would surface half the catalogue for a query of "lo", which is the failure mode
        // UX.md §4.4 avoids for host addresses by the same means.
        if let subtitle = command.subtitle {
            let foldedSubtitle = Self.fold(subtitle)
            if !foldedSubtitle.isEmpty, foldedSubtitle.contains(foldedQuery) {
                return VCommandMatch(command: command, score: Self.subtitleScore,
                                     titleOffsets: [], canHighlight: false)
            }
        }
        return nil
    }

    /// Ranks a catalogue against this query, best first.
    ///
    /// The keys, in order:
    ///
    /// 1. **Enabled before disabled.** Unconditional, and ahead of the score: a disabled command can
    ///    never be the first result, so `Return` on a fresh palette can never fire nothing. It is
    ///    ahead of the score rather than behind it because an exact-title match on a greyed-out
    ///    action is exactly the case where the user would otherwise press `Return` and be ignored.
    /// 2. Higher score.
    /// 3. Earlier category, so ties break the same way every time rather than by hash order.
    /// 4. The catalogue's own order, which makes the sort **stable** — `Array.sort` is not, so the
    ///    original index is carried through the comparison rather than assumed.
    ///
    /// Commands that did not match at all are dropped.
    package func rank(_ commands: [VCommand]) -> [VCommandMatch] {
        var scored: [(match: VCommandMatch, index: Int)] = []
        scored.reserveCapacity(commands.count)
        for (index, command) in commands.enumerated() {
            guard let matched = match(command) else { continue }
            scored.append((matched, index))
        }
        scored.sort { left, right in
            let one = left.match
            let other = right.match
            if one.command.isEnabled != other.command.isEnabled {
                return one.command.isEnabled
            }
            if one.score != other.score {
                return one.score > other.score
            }
            if one.command.category != other.command.category {
                return one.command.category < other.command.category
            }
            return left.index < right.index
        }
        return scored.map(\.match)
    }

    /// Ranks a catalogue and cuts it into the sections the palette draws.
    ///
    /// Sections come out in the order their **best** member ranked, not in category order, so the
    /// very first row of the very first section is the global best match — which is what the
    /// selection starts on, and what `Return` runs. A section whose members all scored worse sinks
    /// below one whose did not, and an empty section is not emitted at all.
    package func groups(_ commands: [VCommand]) -> [VCommandGroup] {
        var order: [VCommandCategory] = []
        var buckets: [VCommandCategory: [VCommandMatch]] = [:]
        for matched in rank(commands) {
            let category = matched.command.category
            if buckets[category] == nil {
                order.append(category)
                buckets[category] = []
            }
            buckets[category]?.append(matched)
        }
        return order.compactMap { category in
            guard let matches = buckets[category], !matches.isEmpty else { return nil }
            return VCommandGroup(category: category, matches: matches)
        }
    }

    /// The grouped results flattened back into one list, in drawing order.
    ///
    /// The palette's keyboard selection runs over **this** list, so the arrow keys walk the rows in
    /// the order they are actually on screen. One function rather than two loops in the view is the
    /// whole point: an index computed one way and drawn another is how a palette ends up running the
    /// row above the one that is highlighted.
    package static func flattened(_ groups: [VCommandGroup]) -> [VCommandMatch] {
        groups.flatMap(\.matches)
    }

    // MARK: - Selection

    /// The id of the first row the arrow keys may land on, or `nil` when nothing is selectable.
    package static func firstSelectable(in matches: [VCommandMatch]) -> String? {
        matches.first { $0.command.isEnabled }?.id
    }

    /// The id of the row `step` places away from `current`, skipping disabled rows and wrapping.
    ///
    /// - Parameters:
    ///   - step: `+1` for `↓`, `-1` for `↑`. Any other magnitude works too.
    ///   - current: the selected command's id, or `nil` when nothing is selected.
    ///   - matches: the rows in drawing order, normally from ``flattened(_:)``.
    /// - Returns: the new selection, or `nil` when no row is selectable.
    ///
    /// Disabled rows are removed *before* the arithmetic rather than skipped during it, so `↓` on
    /// the last enabled row wraps to the first enabled row instead of stalling in a run of greyed
    /// entries. A `current` that is no longer in the list — because the query just changed — is
    /// treated as no selection, which is what makes typing recover gracefully.
    package static func selection(movingBy step: Int,
                                  from current: String?,
                                  in matches: [VCommandMatch]) -> String? {
        let selectable = matches.filter { $0.command.isEnabled }
        guard !selectable.isEmpty else { return nil }
        guard step != 0 else { return current }
        guard let index = selectable.firstIndex(where: { $0.id == current }) else {
            return step > 0 ? selectable.first?.id : selectable.last?.id
        }
        let count = selectable.count
        // Two modulos: Swift's `%` keeps the sign of the dividend, so `-1 % 5` is `-1` and a bare
        // remainder would index out of bounds on `↑` from the first row.
        let moved = ((index + step) % count + count) % count
        return selectable[moved].id
    }

    /// The command a `Return` should run, given the current selection.
    ///
    /// `nil` when the selected row is missing or disabled, which is the state a caller should treat
    /// as "do nothing and leave the palette open".
    package static func runnable(_ current: String?,
                                in matches: [VCommandMatch]) -> VCommand? {
        guard let found = matches.first(where: { $0.id == current }) else { return nil }
        return found.command.isEnabled ? found.command : nil
    }

    // MARK: - Scoring

    /// The tiered score for a folded candidate against a folded query, plus the matched offsets.
    ///
    /// Returns `nil` when the query is not even a subsequence of the candidate. This is
    /// ``VSidebarSearch``'s private ladder, tier for tier and cap for cap; the two are pinned
    /// together by `VCommandPaletteTests`.
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
                // Prefix: penalise only how much of the title is left over, capped so a long title
                // cannot fall out of its tier.
                let excess = Swift.min(haystack.count - needle.count, 99)
                return (900 - excess, offsets)
            }
            return (800 - Swift.min(start, 99), offsets)
        }
        guard let offsets = Self.subsequenceOffsets(haystack, needle) else { return nil }
        // A gap is a discontinuity between consecutive matched characters. Fewer gaps and an
        // earlier start read as a better match.
        var gaps = 0
        for (previous, next) in zip(offsets, offsets.dropFirst()) where next != previous + 1 {
            gaps += 1
        }
        let firstOffset = offsets.first ?? 0
        return (500 - Swift.min(gaps + firstOffset, 99), offsets)
    }

    /// The index at which `needle` appears contiguously in `haystack`, or `nil`.
    ///
    /// Over arrays of `Character` rather than with `String.range(of:)` so the offsets handed back
    /// are character offsets — which is what a row can use to embolden — rather than `String.Index`
    /// values that would have to be converted anyway.
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
    /// Greedy rather than optimal: an optimal matcher would need to search, and on a catalogue of
    /// tens of commands the difference is invisible while the cost of a non-obvious ranking is not.
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
