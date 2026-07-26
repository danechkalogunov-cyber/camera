//
//  RecordingNaming.swift
//  VigilCore
//
//  The file-name template for clips and snapshots, the path sanitisation that keeps a camera name
//  from becoming a directory traversal, and the collision suffix.
//  Implements docs/spec-core.md §9.5 ("Naming") and docs/FEATURES.md F-REC-01 acceptance 9 /
//  F-CAP-01 acceptance 6.
//
//  Pure string and integer arithmetic — no file system, no clock read, no CoreMedia — so it is
//  exercised for real on Linux by the shadow harness under scratchpad/shadow-recording. The
//  whole-file `#if os(macOS)` is here only because `VigilCore` is a macOS-only target.
//

#if os(macOS)

import Foundation
import VigilProtocols

// MARK: - RecordingNameContext

/// Everything a template can interpolate.
///
/// A value, deliberately: rendering a name must not reach for a clock or a camera store, so a test
/// can render every token combination from a literal.
public struct RecordingNameContext: Sendable, Hashable {

    /// Camera slug — lowercase, hyphenated. Feeds `{camera}`.
    public var cameraSlug: String

    /// Camera display name as the user typed it. Feeds `{cameraName}` and is sanitised, not slugged,
    /// so "Front Door" stays readable.
    public var cameraName: String

    /// Wall-clock capture time. The only place a `Date` enters naming, and it arrives from an
    /// injected `WallClock` — never from `Date()` (IMPL_RULES, "Determinism").
    public var date: Date

    /// The zone the date components are rendered in. The user's, not UTC: a file called
    /// `..._231500` should be the time on the clock in the room.
    public var timeZone: TimeZone

    /// Segment index for `{seq}`, zero-based. Rendered three digits and one-based, so the first file
    /// of a rotating recording is `001`.
    public var segmentIndex: Int

    /// `{res}`, e.g. `1920x1080`. `nil` renders as `unknown` rather than as an empty gap.
    public var resolution: Resolution?

    /// `{codec}`, e.g. `h265`.
    public var codec: VideoCodec?

    /// `{trigger}`, e.g. `manual`.
    public var trigger: String

    /// Builds a context.
    public init(cameraSlug: String, cameraName: String, date: Date, timeZone: TimeZone,
                segmentIndex: Int = 0, resolution: Resolution? = nil, codec: VideoCodec? = nil,
                trigger: String = "manual") {
        self.cameraSlug = cameraSlug
        self.cameraName = cameraName
        self.date = date
        self.timeZone = timeZone
        self.segmentIndex = segmentIndex
        self.resolution = resolution
        self.codec = codec
        self.trigger = trigger
    }
}

// MARK: - RecordingNaming

/// Renders and sanitises destination file names.
public enum RecordingNaming {

    // MARK: - Templates

    /// The default clip template. One directory per camera per day keeps a month of recordings
    /// navigable in the Finder, which a flat directory of 40 000 files is not.
    public static let defaultClipTemplate = "{camera}/{yyyy}-{MM}-{dd}/{camera}_{HHmmss}_{trigger}"

    /// The default snapshot template (F-CAP-01 acceptance 6, `{camera}-{date}-{time}`).
    public static let defaultSnapshotTemplate = "{cameraName}-{yyyy}-{MM}-{dd}-{HH}-{mm}-{ss}"

    // MARK: - Constants

    /// Characters that must never reach a path component. `/` and `:` are the dangerous pair on
    /// macOS: `/` is the separator to the file system and `:` is the separator the Finder still
    /// displays, so a camera named `Lobby: East/West` would otherwise create two directories.
    /// NUL is included because it truncates a C path silently.
    static let forbidden: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\0"]

    /// Longest path component, in UTF-8 bytes. HFS+/APFS allow 255; 200 leaves room for the
    /// `.mp4.partial` suffix and a ` (12)` collision marker without a rename ever failing for
    /// length — a failure that would otherwise only appear for users whose language needs three
    /// bytes per character.
    static let maximumComponentBytes = 200

    /// Highest collision suffix tried before falling back to a UUID fragment.
    static let maximumCollisionSuffix = 999

    // MARK: - Rendering

    /// Expands `template` against `context`, sanitising each `/`-separated component.
    ///
    /// Unknown tokens are left **verbatim**, braces included, rather than deleted: a user who typed
    /// `{camra}` should see their typo in the file name and fix it, not silently lose a field.
    ///
    /// - Returns: A relative path with no leading or trailing separator, never empty. A template
    ///   that sanitises away to nothing yields the camera slug, and if that is empty too,
    ///   `"camera"`.
    public static func render(_ template: String, context: RecordingNameContext) -> String {
        let components = DateComponentsCache.components(for: context.date,
                                                       timeZone: context.timeZone)
        var expanded = template
        for (token, value) in tokens(context: context, components: components) {
            expanded = expanded.replacingOccurrences(of: token, with: value)
        }

        let sanitised = expanded
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { sanitise(component: String($0)) }
            .filter { !$0.isEmpty }

        guard !sanitised.isEmpty else {
            let fallback = sanitise(component: context.cameraSlug)
            return fallback.isEmpty ? "camera" : fallback
        }
        return sanitised.joined(separator: "/")
    }

    /// The token table. Separated out so a test can assert every documented token is present.
    static func tokens(context: RecordingNameContext,
                       components: DateComponents) -> [(String, String)] {
        let year = pad(components.year ?? 0, width: 4)
        let month = pad(components.month ?? 0, width: 2)
        let day = pad(components.day ?? 0, width: 2)
        let hour = pad(components.hour ?? 0, width: 2)
        let minute = pad(components.minute ?? 0, width: 2)
        let second = pad(components.second ?? 0, width: 2)
        return [
            ("{camera}", slug(context.cameraSlug)),
            ("{cameraName}", context.cameraName),
            ("{yyyy}", year),
            ("{MM}", month),
            ("{dd}", day),
            ("{HH}", hour),
            ("{mm}", minute),
            ("{ss}", second),
            ("{HHmmss}", hour + minute + second),
            ("{date}", "\(year)-\(month)-\(day)"),
            ("{time}", "\(hour)-\(minute)-\(second)"),
            ("{epoch}", String(Int64(context.date.timeIntervalSince1970.rounded(.down)))),
            ("{seq}", pad(context.segmentIndex + 1, width: 3)),
            ("{res}", context.resolution.map { "\($0.width)x\($0.height)" } ?? "unknown"),
            ("{codec}", context.codec?.rawValue ?? "unknown"),
            ("{trigger}", context.trigger),
        ]
    }

    // MARK: - Sanitisation

    /// Makes one path component safe.
    ///
    /// In order: NFC-normalise so two spellings of the same name land in one directory; replace every
    /// forbidden character **and every control character** with `-`; collapse runs of `-`; strip
    /// leading and trailing whitespace and `.`; refuse the two reserved names; truncate to
    /// `maximumComponentBytes` on a scalar boundary.
    ///
    /// Returns an empty string when nothing survives, which the caller replaces — this function
    /// never invents a name, so its behaviour is total and testable.
    public static func sanitise(component raw: String) -> String {
        let normalised = raw.precomposedStringWithCanonicalMapping

        var replaced = ""
        replaced.reserveCapacity(normalised.count)
        for character in normalised {
            if forbidden.contains(character) {
                replaced.append("-")
            } else if character.unicodeScalars.allSatisfy({ isControl($0) }) {
                // A character is dropped to `-` only when *every* scalar in it is a control: a
                // grapheme cluster made of a letter plus a combining mark must survive intact.
                replaced.append("-")
            } else {
                replaced.append(character)
            }
        }

        var collapsed = ""
        var previousWasHyphen = false
        for character in replaced {
            if character == "-" {
                if previousWasHyphen { continue }
                previousWasHyphen = true
            } else {
                previousWasHyphen = false
            }
            collapsed.append(character)
        }

        let trimmed = collapsed.trimmingCharacters(in: trimmable)
        guard trimmed != ".", trimmed != ".." else { return "" }
        return truncate(trimmed, toUTF8Bytes: maximumComponentBytes)
    }

    /// A camera slug: lowercased, non-alphanumerics collapsed to `-`, trimmed, at most 48 characters.
    ///
    /// Slugs are **not** unique — two cameras called "Front Door" produce the same slug — which is
    /// why the date directory and the timestamp are part of every default template.
    public static func slug(_ raw: String) -> String {
        let lowered = raw.precomposedStringWithCanonicalMapping.lowercased()
        var out = ""
        var previousWasHyphen = false
        for character in lowered {
            if character.isLetter || character.isNumber {
                out.append(character)
                previousWasHyphen = false
            } else if !previousWasHyphen {
                out.append("-")
                previousWasHyphen = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(48))
    }

    /// Truncates on a Unicode scalar boundary so the result is never invalid UTF-8.
    ///
    /// Counting bytes rather than characters is the point: a 200-character Cyrillic name is 400 bytes
    /// and would be refused by the file system, which reports it as a rename failure at the end of a
    /// recording rather than as a naming problem at the start.
    static func truncate(_ text: String, toUTF8Bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var out = ""
        var bytes = 0
        for scalar in text.unicodeScalars {
            let width = String(scalar).utf8.count
            if bytes + width > limit { break }
            out.unicodeScalars.append(scalar)
            bytes += width
        }
        // Truncation can expose a trailing hyphen or dot that the earlier trim had protected.
        return out.trimmingCharacters(in: trimmable)
    }

    // MARK: - Collisions

    /// The first free name in the ` (2)`, ` (3)`, … sequence.
    ///
    /// - Parameters:
    ///   - baseName: File name without its extension.
    ///   - extensions: Every extension the caller intends to write for this name, e.g.
    ///     `["mp4", "mp4.partial"]`. A name is only free when **none** of them is taken, so a clip
    ///     cannot claim a name whose `.partial` twin is still being written by another recorder.
    ///   - exists: Answers whether `<name>.<extension>` is taken. Injected so this is testable
    ///     without a file system, and so the caller decides what "taken" means.
    /// - Returns: The chosen base name. After `maximumCollisionSuffix` attempts it falls back to
    ///   `baseName-<uniqueSuffix>`, which is returned **without** consulting `exists` again — a
    ///   thousand collisions means something else is wrong and looping further would hang the
    ///   capture.
    public static func uniqueBaseName(_ baseName: String, extensions: [String],
                                      uniqueSuffix: String,
                                      exists: (String, String) -> Bool) -> String {
        // A nested `func`, not a closure bound to a `let`: assigning a closure to a local makes it
        // escaping, and an escaping closure may not capture the non-escaping `exists`. Keeping
        // `exists` non-escaping is deliberate — it means this function cannot squirrel the caller's
        // file-system probe away and call it later.
        func isFree(_ candidate: String) -> Bool {
            !extensions.contains { exists(candidate, $0) }
        }
        if isFree(baseName) { return baseName }
        for suffix in 2...maximumCollisionSuffix {
            let candidate = "\(baseName) (\(suffix))"
            if isFree(candidate) { return candidate }
        }
        return "\(baseName)-\(uniqueSuffix)"
    }

    // MARK: - Private Helpers

    /// Whitespace, newlines and `.` — the characters a path component must not start or end with.
    /// A leading `.` would hide the file; a trailing one is stripped by some file systems and kept
    /// by others, which makes a later lookup miss.
    private static let trimmable: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: ".")
        return set
    }()

    /// True for a Unicode scalar in a control category, including DEL and the C1 block.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value <= 0x9F)
    }

    /// Zero-padded decimal. A negative value renders as `0`-padded magnitude, which cannot arise
    /// from a calendar component and would otherwise put a `-` in the middle of a name.
    private static func pad(_ value: Int, width: Int) -> String {
        let digits = String(abs(value))
        guard digits.count < width else { return digits }
        return String(repeating: "0", count: width - digits.count) + digits
    }
}

// MARK: - DateComponentsCache

/// The one calendar in the naming path.
///
/// A fresh `Calendar` per name costs about 40 µs and, worse, picks up the *current* locale, so the
/// same recording could be named with two different calendars across a locale change. This one is
/// explicitly Gregorian, because a file name is a machine-sortable key, not a display string.
enum DateComponentsCache {

    /// Gregorian, no locale. `static let` on a non-generic enum — a `static let` inside a *generic*
    /// type does not compile on macOS, which is how this project lost a build once.
    private static let gregorian = Calendar(identifier: .gregorian)

    /// Year through second, in `timeZone`.
    static func components(for date: Date, timeZone: TimeZone) -> DateComponents {
        var calendar = gregorian
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }
}

#endif
