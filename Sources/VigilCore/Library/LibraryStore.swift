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
    static let temporaryPrefix = "library.json.tmp-"
    static let quarantinePrefix = "library.json.corrupt-"
    private static let premigrationPrefix = "library.json.premigration-"

    // MARK: Stored properties

    /// The directory holding the document and its generations.
    public let directory: URL

    private let options: Options
    let wallClock: any WallClock
    let logger: any LoggerProtocol
    let fileManager: FileManager

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

    var backupURL: URL {
        directory.appendingPathComponent(Self.documentFileName + Self.backupSuffix,
                                         isDirectory: false)
    }

    var secondBackupURL: URL {
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
}

#endif
