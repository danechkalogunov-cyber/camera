//
//  BookmarkStore.swift
//  Vigil
//
//  Moments the user marked, kept between launches. The source behind LIBRARY ▸ Bookmarks.
//  macOS-only. See docs/UX.md (Bookmarks) and `Sources/VigilUI/Library/VBookmarksView.swift`.
//

#if os(macOS)

import Foundation
import Observation

import VigilCore
import VigilProtocols

// MARK: - BookmarkRecord

/// One marked moment, as it is written to disk.
struct BookmarkRecord: Codable, Sendable, Hashable, Identifiable {

    /// Stable identity, so a row keeps its selection across a reload.
    let id: UUID

    /// Which camera's timeline this points into.
    let cameraID: CameraID

    /// The moment being marked.
    ///
    /// **Not the same as ``createdAt``**, and the difference matters: marking something seen an hour
    /// ago while reviewing a recording puts the bookmark an hour in the past, and `VBookmarksView`
    /// groups by day using *this* value. Storing only one of the two would put such a bookmark under
    /// the wrong day header.
    let instant: Date

    /// What the user called it.
    ///
    /// Empty is legal and stays legal. `VBookmarksView` renders the timestamp in its place, and its
    /// own comment gives the reason: requiring a title at the moment of marking is what stops people
    /// marking anything.
    var title: String

    /// A longer note, or `nil`.
    ///
    /// `nil` rather than `""` when there is nothing to say — the row's subtitle appends `· note`,
    /// and an empty string would leave a dangling separator on the end of the camera name.
    var note: String?

    /// When the user created it.
    let createdAt: Date

    // MARK: Coding

    /// Explicit and stable: renaming a Swift property must never change the JSON key.
    enum CodingKeys: String, CodingKey {
        case id, cameraID, instant, title, note, createdAt
    }

    /// Creates a record. Callers normally go through ``BookmarkStore/add(cameraID:instant:title:note:)``,
    /// which is what performs the trimming.
    init(id: UUID, cameraID: CameraID, instant: Date, title: String, note: String?,
         createdAt: Date) {
        self.id = id
        self.cameraID = cameraID
        self.instant = instant
        self.title = title
        self.note = note
        self.createdAt = createdAt
    }

    /// Forgiving decode, like `Camera`'s: only the three fields a bookmark cannot exist without are
    /// required, so a record written by an older build loads without a migration step.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        cameraID = try container.decode(CameraID.self, forKey: .cameraID)
        instant = try container.decode(Date.self, forKey: .instant)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note)
        // A record from before this field existed is dated by the moment it marks, which is the
        // closest true answer available and never a fabricated "now".
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? instant
    }
}

// MARK: - BookmarkStore

/// The user's bookmarks.
///
/// **Why this exists.** `VBookmarksView` and `VLibraryBookmark` were written with the rest of the
/// library screens, and `VLibraryActions` already carries `onOpenBookmark` and `onDeleteBookmark` —
/// but nothing ever supplied `VLibraryState.bookmarks`, so the screen showed its empty state
/// permanently and there was no gesture anywhere that could create one.
///
/// **Where it lives.** `Vigil/bookmarks.json` under Application Support, beside `clips.json` and
/// `groups.json`.
///
/// **Ordering is the store's job.** ``bookmarks`` is newest-first by ``BookmarkRecord/instant`` at
/// all times, so the screen never re-sorts and two surfaces cannot disagree about which bookmark is
/// most recent.
@MainActor
@Observable
final class BookmarkStore {

    // MARK: - Observable State

    /// Every bookmark, newest first.
    private(set) var bookmarks: [BookmarkRecord] = []

    // MARK: - Stored Properties

    private let logger: any LoggerProtocol

    /// The longest title that will be stored. A bookmark row is one line tall.
    private static let titleLimit = 80

    /// The longest note. Long enough for a sentence, short enough that the file stays a bookmark
    /// list rather than a journal.
    private static let noteLimit = 500

    // MARK: - Initialisation

    /// Loads the bookmarks, or starts empty when there are none.
    init(logger: any LoggerProtocol) {
        self.logger = logger
        guard let url = Self.storeURL, let data = try? Data(contentsOf: url) else { return }
        do {
            bookmarks = Self.sorted(try JSONDecoder().decode([BookmarkRecord].self, from: data))
            logger.debug(.storage, "bookmarks: \(bookmarks.count) loaded")
        } catch {
            logger.error(.storage, "bookmarks unreadable, starting empty: \(error)")
        }
    }

    // MARK: - API

    /// Marks a moment and returns the new bookmark's identifier.
    ///
    /// Never refuses. Unlike a group name, an empty title is a normal outcome here, so the only
    /// work done on the way in is trimming and capping.
    @discardableResult
    func add(cameraID: CameraID, instant: Date, title: String, note: String?) -> UUID {
        let record = BookmarkRecord(id: UUID(),
                                    cameraID: cameraID,
                                    instant: instant,
                                    title: Self.cleaned(title, limit: Self.titleLimit) ?? "",
                                    note: Self.cleaned(note ?? "", limit: Self.noteLimit),
                                    createdAt: Date())
        bookmarks = Self.sorted(bookmarks + [record])
        save()
        logger.info(.storage, "bookmark added")
        return record.id
    }

    /// Rewrites a bookmark's title and note. The instant is not editable — a bookmark that could be
    /// moved would no longer be a record of when something happened.
    func update(_ id: UUID, title: String, note: String?) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[index].title = Self.cleaned(title, limit: Self.titleLimit) ?? ""
        bookmarks[index].note = Self.cleaned(note ?? "", limit: Self.noteLimit)
        save()
    }

    /// Removes a bookmark.
    func delete(_ id: UUID) {
        guard bookmarks.contains(where: { $0.id == id }) else { return }
        bookmarks.removeAll { $0.id == id }
        save()
    }

    /// Replaces bookmarks from a validated configuration document.
    func replaceForImport(with imported: [BookmarkRecord], validCameras: Set<CameraID>) {
        bookmarks = Self.sorted(imported.filter { validCameras.contains($0.cameraID) })
        save()
    }

    /// Everything marked on one camera, newest first.
    func bookmarks(for camera: CameraID) -> [BookmarkRecord] {
        bookmarks.filter { $0.cameraID == camera }
    }

    /// The bookmark nearest an instant, within a tolerance.
    ///
    /// What answers "is this moment already marked" before a second bookmark is made three seconds
    /// from the first. Nearest rather than first-found, so a dense stretch of marks resolves to the
    /// one actually being pointed at.
    func bookmark(near instant: Date,
                  camera: CameraID,
                  within seconds: TimeInterval) -> BookmarkRecord? {
        bookmarks
            .filter { $0.cameraID == camera }
            .filter { abs($0.instant.timeIntervalSince(instant)) <= seconds }
            .min { abs($0.instant.timeIntervalSince(instant)) < abs($1.instant.timeIntervalSince(instant)) }
    }

    // MARK: - Private Helpers

    /// Newest first, with the creation instant breaking a tie.
    ///
    /// Two bookmarks can genuinely share an instant — marking the same frame twice — and an unstable
    /// sort would let them swap places on every reload, which reads as the list flickering.
    private static func sorted(_ records: [BookmarkRecord]) -> [BookmarkRecord] {
        records.sorted { first, second in
            if first.instant != second.instant { return first.instant > second.instant }
            return first.createdAt > second.createdAt
        }
    }

    /// Trimmed, newline-free and capped, or `nil` when there is nothing left.
    private static func cleaned(_ raw: String, limit: Int) -> String? {
        var text = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.count > limit { text = String(text.prefix(limit)) }
        return text
    }

    /// Writes the document out, atomically.
    private func save() {
        guard let url = Self.storeURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(bookmarks).write(to: url, options: [.atomic])
        } catch {
            logger.error(.storage, "bookmarks could not be written: \(error)")
        }
    }

    /// Where the document is kept.
    static var storeURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appending(path: "Vigil/bookmarks.json")
    }
}

#endif  // os(macOS)
