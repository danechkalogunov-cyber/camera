//
//  LibraryStore+Writing.swift
//  VigilCore
//
//  Saving: the write primitives, the quarantine, and the pre-migration snapshots.
//  Split from LibraryStore.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

#if os(macOS)

import Foundation
import VigilISAPI
import VigilProtocols

// MARK: - Saving and quarantine

/// ⚠️ Members are `internal`, not `private`: Swift scopes `private` to one file.
/// `Scripts/lint.py`'s `split-access` rule fails the build on any left behind.
extension LibraryStore {

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
    func quarantine(_ url: URL) {
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
    func snapshotBeforeMigration(_ data: Data) {
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
    func pruneQuarantinedFiles() {
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
    func ensureDirectory() {
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
