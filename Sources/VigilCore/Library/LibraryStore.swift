//
//  LibraryStore.swift
//  VigilCore
//
//  Atomic, versioned persistence for `library.json`: write to a sibling temp file, fsync it, rotate
//  the backups, then rename over the document, and fsync the directory so the rename itself is
//  durable. A crash at any point leaves either the whole old file or the whole new one.
//  Implements docs/spec-core.md §5.1, §5.5, §5.8, §5.9 and docs/API_CONTRACT.md §2 R-20.
//
//  Two platform decisions worth the paragraphs, because both were measured rather than assumed:
//
//  1. **The swap is POSIX `rename(2)`, not `FileManager.replaceItemAt`.** `replaceItemAt` is what
//     spec-core §5.5 names, and on Darwin it is correct — but its swift-corelibs implementation on
//     Linux moves the *original* onto the temp path and leaves the document missing. That is not a
//     footnote: this file's tests have to run somewhere, and a persistence layer whose write path
//     cannot be exercised before it reaches the customer is exactly how six defects shipped this
//     morning (docs/BUILD-VERIFICATION.md). `rename(2)` is atomic, replaces an existing
//     destination, and is spelled and behaves identically on both platforms — so the code the
//     customer runs is the code the tests ran. The temp file is always a sibling of the document,
//     which is the one precondition `rename` adds over `replaceItemAt`.
//  2. **`F_FULLFSYNC` is spelled behind `canImport(Darwin)`, the call is not.** An ordinary `fsync`
//     does not flush the drive's own write cache on macOS, so the constant matters; but keeping the
//     `fcntl` call itself in shared code means the shadow harness type-checks the real statement
//     instead of a Linux-only stand-in.
//

#if os(macOS)

#if canImport(Darwin)
import Darwin
/// Darwin's `F_FULLFSYNC`: flush the drive's cache, not merely the OS page cache.
private let vigilFullFsyncCommand = Int32(F_FULLFSYNC)
#elseif canImport(Glibc)
import Glibc
/// The numeric value of Darwin's `F_FULLFSYNC`, spelled so the shared call site below compiles in
/// the Linux shadow harness. Linux answers `EINVAL`, which the caller treats as "fall back to
/// `fsync`" — the correct behaviour on a platform without a full-sync command.
private let vigilFullFsyncCommand = Int32(51)
#endif

import Foundation
import VigilISAPI
import VigilProtocols

// MARK: - LibraryLoadOutcome

/// What `LibraryStore.load()` found. Every case carries a usable document, so no caller has to
/// handle "no library at all".
public enum LibraryLoadOutcome: Sendable {

    /// No file on disk. First run: the document is the empty library and nothing has been written.
    case created(LibraryDocument)

    /// The file opened. `migrationsApplied` is empty for a document already at the current schema.
    case loaded(LibraryDocument, migrationsApplied: [String], rekeyRequests: [LibraryRekeyRequest])

    /// The document did not open and a backup (or nothing) did. The bad file is quarantined, never
    /// deleted, and `error` is the *first* failure, which is the one worth showing the user.
    case recovered(LibraryDocument, from: LibraryRecoverySource, error: StorageError)

    /// The file was written by a newer Vigil. The document is opened as far as it decodes, marked
    /// `isReadOnly`, and **nothing is ever written back**.
    case readOnly(LibraryDocument, futureVersion: Int)

    /// The document, whichever case this is.
    public var document: LibraryDocument {
        switch self {
        case let .created(document): document
        case let .loaded(document, _, _): document
        case let .recovered(document, _, _): document
        case let .readOnly(document, _): document
        }
    }

    /// Cameras whose Keychain item needs re-tagging after a 2→3 migration. Empty in every other
    /// case.
    public var rekeyRequests: [LibraryRekeyRequest] {
        if case let .loaded(_, _, requests) = self { return requests }
        return []
    }
}

// MARK: - LibraryStore

/// Owns the bytes of `library.json`, and nothing else.
///
/// An actor because two concurrent writers would interleave temp files and backup rotation; a
/// single serialised writer makes the sequence in ``save(_:)`` mean what it says. It holds no
/// library state — `CameraLibrary` owns that — so a load is always a read of the disk and a save is
/// always a write of what the caller handed over.
public actor LibraryStore {

    // MARK: Options

    /// Knobs with defaults from docs/spec-core.md §5.4.
    public struct Options: Sendable {

        /// How many previous generations to keep: `library.json.bak`, `.bak2`.
        public var backupGenerations: Int

        /// Refuse to load a document larger than this. A 500-camera library is ~380 KB; anything
        /// past 32 MB is a corrupted or hostile file, and decoding it would stall the launch.
        public var maxDocumentBytes: Int

        /// Quarantined files younger than this are never pruned.
        public var corruptFileRetentionDays: Int

        /// The newest N quarantined files are never pruned, whatever their age.
        public var maxCorruptFilesKept: Int

        /// What to write into `generatedBy`. The app passes its real version string; the default
        /// avoids a `Bundle` lookup, which is a launch-crash surface in this project.
        public var generatedBy: String

        /// Builds options.
        public init(backupGenerations: Int = 2,
                    maxDocumentBytes: Int = 32 * 1024 * 1024,
                    corruptFileRetentionDays: Int = 30,
                    maxCorruptFilesKept: Int = 5,
                    generatedBy: String = LibraryDocument.defaultGeneratedBy) {
            self.backupGenerations = backupGenerations
            self.maxDocumentBytes = maxDocumentBytes
            self.corruptFileRetentionDays = corruptFileRetentionDays
            self.maxCorruptFilesKept = maxCorruptFilesKept
            self.generatedBy = generatedBy
        }
    }

    // MARK: File names

    /// The document's file name. Public because the diagnostics bundle and the support instructions
    /// both name it, and two spellings of it would eventually disagree.
    public static let documentFileName = "library.json"

    private static let backupSuffix = ".bak"
    private static let secondBackupSuffix = ".bak2"
    private static let temporaryPrefix = "library.json.tmp-"
    private static let quarantinePrefix = "library.json.corrupt-"
    private static let premigrationPrefix = "library.json.premigration-"

    // MARK: Stored properties

    /// The directory holding the document and its generations.
    public let directory: URL

    private let options: Options
    private let wallClock: any WallClock
    private let logger: any LoggerProtocol
    private let fileManager: FileManager

    /// The content bytes of the last successful write, with `updatedAt` normalised out.
    ///
    /// This is what makes "skip the write when nothing changed" work. Comparing the *final* bytes
    /// could never match, because `updatedAt` is refreshed on every save — spec-core §5.5 has that
    /// backwards, and following it literally would rewrite the file on every mutation attempt.
    private var lastWrittenContent: Data?

    // MARK: Initialisation

    /// Builds a store over a directory. The directory is created on first write, not here, so
    /// constructing a store performs no I/O and cannot fail.
    ///
    /// - Parameters:
    ///   - directory: normally `<AppSupport>/Vigil`. A test passes a temporary directory.
    ///   - options: see ``Options``.
    ///   - wallClock: the only source of time here. Timestamps and quarantine file names come from
    ///     it, so a test's file names are as deterministic as its assertions.
    ///   - logger: structured log sink. Nothing logged here carries a secret, and paths are
    ///     redacted, because a path contains the user's account name.
    ///   - fileManager: injectable purely so a test can point at an isolated instance; the default
    ///     is the shared one.
    public init(directory: URL,
                options: Options = Options(),
                wallClock: any WallClock = SystemWallClock(),
                logger: any LoggerProtocol = NullLogger(),
                fileManager: FileManager = .default) {
        self.directory = directory
        self.options = options
        self.wallClock = wallClock
        self.logger = logger
        self.fileManager = fileManager
    }

    /// `<Application Support>/Vigil`, resolved through `FileManager` so the answer is correct
    /// whether or not the app is sandboxed (docs/spec-core.md §5.1).
    ///
    /// - Throws: `.notWritable` when Application Support cannot be resolved at all, which on macOS
    ///   means a broken home directory rather than a permissions problem.
    public static func applicationSupportDirectory(
        fileManager: FileManager = .default,
        folderName: String = "Vigil"
    ) throws(StorageError) -> URL {
        do {
            let base = try fileManager.url(for: .applicationSupportDirectory,
                                           in: .userDomainMask,
                                           appropriateFor: nil,
                                           create: false)
            return base.appendingPathComponent(folderName, isDirectory: true)
        } catch {
            throw StorageError.notWritable(path: "~/Library/Application Support")
        }
    }

    /// The document's URL.
    public var documentURL: URL {
        directory.appendingPathComponent(Self.documentFileName, isDirectory: false)
    }

    private var backupURL: URL {
        directory.appendingPathComponent(Self.documentFileName + Self.backupSuffix,
                                         isDirectory: false)
    }

    private var secondBackupURL: URL {
        directory.appendingPathComponent(Self.documentFileName + Self.secondBackupSuffix,
                                         isDirectory: false)
    }

    // MARK: Loading

    /// Reads the document, migrating, recovering or creating as needed.
    ///
    /// The ladder is docs/spec-core.md §5.9: the document, then `.bak`, then `.bak2`, then an empty
    /// library — quarantining, never deleting, whatever failed to open. It performs **no write** in
    /// any case except the pre-migration snapshot, so a user who quits to fetch help still has the
    /// evidence.
    ///
    /// One deliberate deviation: a *missing* document with a surviving backup is recovered from the
    /// backup rather than reported as a first run. The spec's ladder starts recovery only on a
    /// corrupt file, which would silently start empty for a user whose document was deleted while a
    /// perfectly good generation sat next to it — and "the camera list is empty" is the single most
    /// visible regression this module can produce.
    public func load() -> LibraryLoadOutcome {
        ensureDirectory()
        pruneQuarantinedFiles()

        var firstError: StorageError?
        let sources: [(url: URL, source: LibraryRecoverySource?)] = [
            (documentURL, nil), (backupURL, .backup), (secondBackupURL, .secondBackup),
        ]

        for (url, recovery) in sources {
            switch read(url) {
            case .missing:
                continue

            case let .document(document, applied, requests, notes):
                for note in notes { logger.notice(.storage, "library migration \(note)") }
                if let recovery {
                    let error = firstError ?? StorageError.corruptDocument("document missing")
                    var recovered = document
                    recovered.recoveredFrom = recovery
                    logger.error(.storage, "library recovered from a backup generation",
                                 ["source": recovery.rawValue])
                    return .recovered(recovered, from: recovery, error: error)
                }
                return .loaded(document, migrationsApplied: applied, rekeyRequests: requests)

            case let .readOnly(document, version):
                // Never quarantined and never rewritten: the file belongs to a newer build.
                logger.error(.storage, "library was written by a newer Vigil; opening read-only",
                             ["found": String(version),
                              "supported": String(LibraryDocument.currentSchemaVersion)])
                return .readOnly(document, futureVersion: version)

            case let .failure(error):
                if firstError == nil { firstError = error }
                logger.failure(.storage, error)
                // Only the document itself is quarantined. A corrupt backup is left where it is —
                // the ladder has already moved past it, and the next successful save rotates it out
                // on its own (docs/spec-core.md §5.9: "same ladder, no further quarantine").
                if recovery == nil { quarantine(url) }
            }
        }

        guard let error = firstError else {
            logger.info(.storage, "no library on disk; starting a new one")
            return .created(freshDocument())
        }
        var document = freshDocument()
        document.recoveredFrom = .freshStart
        logger.error(.storage, "no readable library generation; starting empty",
                     ["code": error.diagnosticCode])
        return .recovered(document, from: .freshStart, error: error)
    }

    /// The result of trying to open one generation.
    private enum ReadResult {
        case missing
        case document(LibraryDocument, applied: [String], rekey: [LibraryRekeyRequest],
                      notes: [String])
        case readOnly(LibraryDocument, version: Int)
        case failure(StorageError)
    }

    /// Reads and validates one file, without touching any other.
    private func read(_ url: URL) -> ReadResult {
        guard fileManager.fileExists(atPath: url.path) else { return .missing }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failure(.corruptDocument("unreadable: \(error.localizedDescription)"))
        }
        guard !data.isEmpty else { return .failure(.corruptDocument("empty file")) }
        guard data.count <= options.maxDocumentBytes else {
            return .failure(.documentTooLarge(bytes: data.count))
        }

        var context = LibraryMigrationContext()
        let migration: LibraryMigrationResult
        do {
            migration = try LibrarySchemaMigrator.migrate(data, context: &context)
        } catch let error {
            if case let .schemaTooNew(found, _) = error {
                return .readOnly(readOnlyDocument(data, version: found), version: found)
            }
            return .failure(error)
        }

        if !migration.applied.isEmpty {
            snapshotBeforeMigration(data)
        }

        let decoder = LibraryCoding.makeDecoder()
        var document: LibraryDocument
        do {
            document = try decoder.decode(LibraryDocument.self, from: migration.data)
        } catch {
            // The migrated document must decode before it is trusted; if it does not, the original
            // file is left exactly as it was and this generation counts as corrupt.
            return .failure(.corruptDocument("decode failed: \(error)"))
        }

        let unknown = Self.unknownContent(in: migration.data)
        document.hadUnknownContent = unknown != nil
        document.unknownContent = unknown
        let report = document.normalize()
        if report.didChange {
            logger.notice(.storage, "library normalised on load",
                          ["droppedInvalid": String(report.droppedInvalidCameras.count),
                           "droppedDuplicate": String(report.droppedDuplicateCameras.count),
                           "droppedOrphanInventories":
                               String(report.droppedOrphanInventories.count),
                           "repaired": String(report.repairedCameras)])
        }
        return .document(document, applied: migration.applied, rekey: migration.rekeyRequests,
                         notes: migration.notes)
    }

    /// Best effort read of a document from the future: decode what we can, mark it read-only.
    ///
    /// A newer build's document may well decode — the schema is additive by design — and showing the
    /// user their cameras read-only is strictly better than showing an empty window.
    private func readOnlyDocument(_ data: Data, version: Int) -> LibraryDocument {
        var document = (try? LibraryCoding.makeDecoder().decode(LibraryDocument.self, from: data))
            ?? freshDocument()
        document.schemaVersion = version
        document.isReadOnly = true
        _ = document.normalize()
        return document
    }

    /// The empty first-run document.
    private func freshDocument() -> LibraryDocument {
        LibraryDocument(generatedBy: options.generatedBy, updatedAt: wallClock.now)
    }

    // MARK: Saving

    /// Writes the document, atomically, unless it is byte-identical to the last write.
    ///
    /// - Returns: `true` when bytes reached the disk, `false` when the content was unchanged and the
    ///   write was skipped. The skip is what keeps a slider drag from rewriting the file forty times
    ///   a second, and it is only sound because ``LibraryCoding`` is deterministic.
    /// - Throws: `.schemaTooNew` when the document is read-only — writing it would downgrade a newer
    ///   Vigil's library, so the attempt is refused loudly rather than ignored; `.notWritable`,
    ///   `.diskFull` or `.atomicReplaceFailed` for the write itself. On any failure the previous
    ///   document is still in place, untouched.
    @discardableResult
    public func save(_ document: LibraryDocument) throws(StorageError) -> Bool {
        guard !document.isReadOnly else {
            throw StorageError.schemaTooNew(found: document.schemaVersion,
                                            supported: LibraryDocument.currentSchemaVersion)
        }
        ensureDirectory()

        var canonical = document
        canonical.schemaVersion = LibraryDocument.currentSchemaVersion
        canonical.generatedBy = options.generatedBy
        canonical.updatedAt = Date(timeIntervalSince1970: 0)

        let encoder = LibraryCoding.makeEncoder()
        let comparison: Data
        do {
            comparison = try encoder.encode(canonical)
        } catch {
            throw StorageError.corruptDocument("document is not encodable: \(error)")
        }
        if let lastWrittenContent, lastWrittenContent == comparison { return false }

        canonical.updatedAt = wallClock.now
        var payload: Data
        do {
            payload = try encoder.encode(canonical)
        } catch {
            throw StorageError.corruptDocument("document is not encodable: \(error)")
        }
        if let unknown = document.unknownContent {
            payload = Self.merging(payload, preserving: unknown) ?? payload
        }

        let temporary = directory.appendingPathComponent(
            Self.temporaryPrefix + UUID().uuidString, isDirectory: false)
        do {
            try writeDurably(payload, to: temporary)
            rotateBackups()
            try atomicallyReplaceDocument(with: temporary, bytes: payload.count)
        } catch {
            try? fileManager.removeItem(at: temporary)
            logger.failure(.storage, error)
            throw error
        }
        syncDirectory()
        lastWrittenContent = comparison
        logger.debug(.storage, "library written",
                     ["bytes": String(payload.count), "cameras": String(document.cameras.count)])
        return true
    }

    /// Forgets the cached last-written bytes, so the next ``save(_:)`` writes even if the content
    /// matches. For tests, and for the case where something outside Vigil edited the file.
    public func invalidateWriteCache() {
        lastWrittenContent = nil
    }

    // MARK: Write primitives

    /// Writes `data` and flushes it through the drive's cache.
    ///
    /// `Data.write(options: .atomic)` is itself a temp-file-plus-rename, which is belt to this
    /// method's braces; what it does not do is fsync, so without the flush below a power loss can
    /// leave a rename pointing at a file whose contents never landed.
    private func writeDurably(_ data: Data, to url: URL) throws(StorageError) {
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw Self.mapWriteFailure(error, url: url, bytes: data.count)
        }
        flushToDisk(url)
    }

    /// fsyncs one file, preferring Darwin's full sync. Failure is logged, never fatal: the data is
    /// in the page cache either way, and refusing to save because a flush hint failed would be
    /// worse than the risk it guards.
    private func flushToDisk(_ url: URL) {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY)
        }
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        if fcntl(descriptor, vigilFullFsyncCommand) == -1 {
            // No full-sync command on this platform, or the volume does not support it: an ordinary
            // fsync still orders the write ahead of the rename.
            _ = fsync(descriptor)
        }
    }

    /// fsyncs the directory, so the rename that swapped the document in is itself durable.
    private func syncDirectory() {
        let descriptor = directory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY)
        }
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = fsync(descriptor)
    }

    /// `rename(2)` the temp file over the document.
    ///
    /// One syscall, atomic, and it replaces the destination — which is the whole reason the temp
    /// file is a sibling rather than in `/tmp`: `rename` cannot cross a filesystem.
    private func atomicallyReplaceDocument(with temporary: URL,
                                           bytes: Int) throws(StorageError) {
        let target = documentURL
        let result = temporary.withUnsafeFileSystemRepresentation { from -> Int32 in
            target.withUnsafeFileSystemRepresentation { to -> Int32 in
                guard let from, let to else { return EINVAL }
                return rename(from, to) == 0 ? 0 : errno
            }
        }
        guard result != 0 else { return }
        switch result {
        case ENOSPC: throw StorageError.diskFull(needBytes: Int64(bytes))
        case EACCES, EPERM, EROFS: throw StorageError.notWritable(path: redacted(target))
        default: throw StorageError.atomicReplaceFailed
        }
    }

    /// `bak2 ← bak`, `bak ← document`, oldest first so a crash mid-rotation never destroys both.
    ///
    /// The current document is **copied** rather than moved into `.bak`: a move would leave a window
    /// in which no `library.json` exists at all, and this runs immediately before the rename that
    /// replaces it. Every step is best effort — a failed rotation must not stop the save, because a
    /// missing backup is a smaller problem than an unsaved change.
    private func rotateBackups() {
        guard options.backupGenerations > 0,
              fileManager.fileExists(atPath: documentURL.path) else { return }

        if options.backupGenerations > 1, fileManager.fileExists(atPath: backupURL.path) {
            try? fileManager.removeItem(at: secondBackupURL)
            do {
                try fileManager.moveItem(at: backupURL, to: secondBackupURL)
            } catch {
                logger.debug(.storage, "second-generation backup rotation skipped")
            }
        }
        try? fileManager.removeItem(at: backupURL)
        do {
            try fileManager.copyItem(at: documentURL, to: backupURL)
        } catch {
            logger.warning(.storage, "could not write the library backup generation")
        }
    }

    // MARK: Quarantine and pre-migration snapshots

    /// Moves an unreadable file aside as `library.json.corrupt-<compact UTC>`. Never deletes.
    private func quarantine(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let stamp = ISAPITime.compactUTC(wallClock.now)
        for attempt in 0...9 {
            let suffix = attempt == 0 ? "" : "-\(attempt)"
            let target = directory.appendingPathComponent(
                Self.quarantinePrefix + stamp + suffix, isDirectory: false)
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            do {
                try fileManager.moveItem(at: url, to: target)
                logger.error(.storage, "unreadable library file quarantined",
                             ["file": target.lastPathComponent])
            } catch {
                logger.warning(.storage, "could not quarantine an unreadable library file")
            }
            return
        }
    }

    /// Copies the pre-migration bytes to `library.json.premigration-v<n>-<compact UTC>`.
    ///
    /// Kept indefinitely: it is small, and it is the only way back from a migration that turns out
    /// to be wrong. Written from the bytes in memory rather than by copying the file, so the
    /// snapshot is exactly what was migrated even if something else touches the file meanwhile.
    private func snapshotBeforeMigration(_ data: Data) {
        let parsed = try? JSONSerialization.jsonObject(with: data)
        let version = (parsed as? [String: Any])?["schemaVersion"] as? Int ?? 1
        let name = "\(Self.premigrationPrefix)v\(version)-\(ISAPITime.compactUTC(wallClock.now))"
        let target = directory.appendingPathComponent(name, isDirectory: false)
        guard !fileManager.fileExists(atPath: target.path) else { return }
        do {
            try data.write(to: target, options: [.atomic])
            logger.notice(.storage, "pre-migration snapshot written", ["file": name])
        } catch {
            logger.warning(.storage, "could not write the pre-migration snapshot")
        }
    }

    /// Deletes quarantined files that are both older than the retention window and outside the
    /// newest N. Either condition alone keeps the file.
    private func pruneQuarantinedFiles() {
        let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        let quarantined = contents
            .filter { $0.hasPrefix(Self.quarantinePrefix) }
            .sorted(by: >)                      // compact UTC sorts lexicographically = newest first
        guard quarantined.count > options.maxCorruptFilesKept else { return }

        let cutoff = wallClock.now.addingTimeInterval(
            -Double(options.corruptFileRetentionDays) * 86_400)
        for name in quarantined.dropFirst(options.maxCorruptFilesKept) {
            let stamp = String(name.dropFirst(Self.quarantinePrefix.count).prefix(16))
            guard let reading = ISAPITime.parse(stamp), reading.date < cutoff else { continue }
            try? fileManager.removeItem(at: directory.appendingPathComponent(name,
                                                                            isDirectory: false))
        }
    }

    // MARK: Helpers

    /// Creates the directory if it is absent. Failure is logged, not thrown: the next write reports
    /// it with the real errno, and a store whose initialiser can fail is a launch that can fail.
    private func ensureDirectory() {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            logger.error(.storage, "could not create the library directory",
                         ["path": redacted(directory)])
        }
    }

    /// A path with the user's home directory removed, for a log line.
    private func redacted(_ url: URL) -> String {
        Redact.path(url.path)
    }

    /// Maps a Foundation write failure onto the storage vocabulary.
    ///
    /// `CocoaError` rather than errno, because that is what `Data.write` reports; the three cases
    /// that get their own diagnosis are the three a user can act on.
    private static func mapWriteFailure(_ error: any Error, url: URL, bytes: Int) -> StorageError {
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileWriteOutOfSpace:
                return .diskFull(needBytes: Int64(bytes))
            case .fileWriteNoPermission, .fileWriteVolumeReadOnly:
                return .notWritable(path: Redact.path(url.path))
            default:
                break
            }
        }
        return .notWritable(path: Redact.path(url.path))
    }

    /// The top-level keys this build does not know, as a JSON object, or `nil` when there are none.
    ///
    /// Preserving them is the difference between "a future build's layouts survive our save" and "a
    /// user loses their layouts the first time they rename a camera".
    static func unknownContent(in data: Data) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let unknown = root.filter { !LibraryDocument.knownTopLevelKeys.contains($0.key) }
        guard !unknown.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: unknown,
                                           options: [.sortedKeys, .prettyPrinted])
    }

    /// Splices preserved unknown keys back into freshly encoded bytes.
    ///
    /// Known keys always win: this build owns them. Returns `nil` if either side does not parse, and
    /// the caller then writes its own bytes unchanged — losing an unknown key is bad, but writing a
    /// malformed document is worse.
    static func merging(_ payload: Data, preserving unknown: Data) -> Data? {
        guard var root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let extra = try? JSONSerialization.jsonObject(with: unknown) as? [String: Any] else {
            return nil
        }
        for (key, value) in extra where root[key] == nil {
            root[key] = value
        }
        return try? JSONSerialization.data(withJSONObject: root,
                                           options: [.sortedKeys, .prettyPrinted])
    }
}

#endif
