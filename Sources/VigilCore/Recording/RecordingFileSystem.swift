//
//  RecordingFileSystem.swift
//  VigilCore
//
//  The narrow file-system surface the capture features use, so that destination resolution, disk
//  reserves, collision handling and the `.partial` rename are all testable without touching a disk.
//  Implements docs/spec-core.md §9.6 (pre-flight checks) and §9.8 (the atomic rename).
//
//  Every failure here becomes a **named** `RecordingError` or `StorageError` carrying the path,
//  because the failure mode this project refuses to ship is "no file, no error": a sandbox denial
//  that is swallowed looks exactly like a camera with no video.
//

#if os(macOS)

import Foundation
import VigilProtocols

// MARK: - RecordingFileSystem

/// What recording and snapshots need from the file system.
///
/// Seven operations, not `FileManager`: the interesting behaviour is in the *decisions* around these
/// calls — is the reserve satisfied, is the name free, did the rename happen — and a protocol is what
/// lets those decisions be driven from a test with a full disk, a read-only volume and a name
/// collision, none of which a CI machine can arrange for real.
public protocol RecordingFileSystem: Sendable {

    /// True when something exists at `url`, file or directory.
    func itemExists(at url: URL) -> Bool

    /// True when a directory exists at `url`.
    func directoryExists(at url: URL) -> Bool

    /// True when the process may write inside the directory at `url`.
    ///
    /// In a sandbox this is the check that catches a path outside the container for which no
    /// user-selected grant is held. It must be asked **after** any security-scoped access has been
    /// started, or it answers `false` for a directory the user has in fact chosen.
    func isWritableDirectory(at url: URL) -> Bool

    /// Creates `url` and every missing parent.
    func createDirectory(at url: URL) throws(RecordingError)

    /// Bytes available for "important" usage — the number that accounts for purgeable space, and the
    /// only one worth refusing a recording over. `nil` when the volume cannot answer.
    func availableCapacity(at url: URL) -> Int64?

    /// Size of the file at `url`, or `nil` when it does not exist.
    func fileSize(at url: URL) -> Int64?

    /// Renames within one volume. This is the `.partial` → final step, and it must be a rename
    /// rather than a copy so it is atomic and cannot leave two half-files.
    func moveItem(at source: URL, to destination: URL) throws(RecordingError)

    /// Deletes `url`. A missing item is not an error — the caller is cleaning up.
    func removeItem(at url: URL) throws(RecordingError)

    /// Writes `data` to `url`, replacing any existing file, without leaving a partial file behind if
    /// the write fails part-way.
    func writeDurably(_ data: Data, to url: URL) throws(StorageError)
}

// MARK: - SystemRecordingFileSystem

/// The production file system.
///
/// Every `FileManager` call that can fail is wrapped so the thrown value names the path and the
/// operation. `FileManager` throws `NSError`s whose `localizedDescription` is often just "The
/// operation couldn’t be completed", so the numeric domain and code are always included.
public struct SystemRecordingFileSystem: RecordingFileSystem {

    /// `FileManager.default`, reached through a computed property rather than stored.
    ///
    /// Storing it does not compile: `FileManager` is a non-`Sendable` class, and a `Sendable`-
    /// conforming struct may not hold one. Documented thread-safety is not what the checker asks
    /// about — it asks whether the *type* is `Sendable`, and `NSFileManager` says nothing.
    ///
    /// The injection point that made storing it look useful is removed rather than made unsafe,
    /// because it was never the real seam. This type's whole purpose is that the seam is the
    /// `RecordingFileSystem` protocol above: a test fakes the seven operations — a full disk, a
    /// read-only volume, a name collision — none of which handing in a different `FileManager`
    /// could have arranged anyway. Nothing in the tree constructed this with a custom manager.
    ///
    /// Computing it costs nothing: `FileManager.default` is a shared instance, not an allocation,
    /// and the operations used here are the ones Apple documents as safe to call on it from any
    /// thread.
    private var manager: FileManager { .default }

    /// Builds a file system over `FileManager.default`.
    public init() {}

    public func itemExists(at url: URL) -> Bool {
        manager.fileExists(atPath: url.path)
    }

    public func directoryExists(at url: URL) -> Bool {
        // `func fileExists(atPath:isDirectory:) -> Bool`, whose second argument is an
        // `UnsafeMutablePointer<ObjCBool>?`. Written out because the `ObjCBool` unwrap is the part a
        // reader gets wrong.
        var isDirectory = ObjCBool(false)
        let exists = manager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    public func isWritableDirectory(at url: URL) -> Bool {
        manager.isWritableFile(atPath: url.path)
    }

    public func createDirectory(at url: URL) throws(RecordingError) {
        do {
            // `withIntermediateDirectories: true` also makes the call succeed when the directory
            // already exists, which is why there is no existence check first — checking then
            // creating is a race with any other recorder starting at the same moment.
            try manager.createDirectory(at: url, withIntermediateDirectories: true,
                                        attributes: nil)
        } catch {
            let detail = error as NSError
            throw RecordingError.destinationUnwritable(
                path: "\(url.path) (createDirectory: \(detail.domain) \(detail.code))")
        }
    }

    public func availableCapacity(at url: URL) -> Int64? {
        // `func resourceValues(forKeys keys: Set<URLResourceKey>) throws -> URLResourceValues`
        // `var volumeAvailableCapacityForImportantUsage: Int64? { get }` — the value that includes
        // purgeable space, so it is the one that predicts whether a write will actually succeed.
        // `volumeAvailableCapacity` under-reports on a Mac with a large purgeable cache and would
        // refuse recordings that would have worked.
        do {
            let values = try url.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage
        } catch {
            return nil
        }
    }

    public func fileSize(at url: URL) -> Int64? {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return values.fileSize.map(Int64.init)
        } catch {
            return nil
        }
    }

    public func moveItem(at source: URL, to destination: URL) throws(RecordingError) {
        do {
            try manager.moveItem(at: source, to: destination)
        } catch {
            let detail = error as NSError
            throw RecordingError.writerFailed(
                "moveItem \(source.lastPathComponent) → \(destination.lastPathComponent) failed: "
                + "\(detail.domain) \(detail.code) — \(detail.localizedDescription)")
        }
    }

    public func removeItem(at url: URL) throws(RecordingError) {
        guard manager.fileExists(atPath: url.path) else { return }
        do {
            try manager.removeItem(at: url)
        } catch {
            let detail = error as NSError
            throw RecordingError.writerFailed(
                "removeItem \(url.lastPathComponent) failed: \(detail.domain) \(detail.code)")
        }
    }

    public func writeDurably(_ data: Data, to url: URL) throws(StorageError) {
        do {
            // `.atomic` writes a temporary file in the same directory and renames it over the
            // destination, so a crash mid-write leaves either the old file or the new one — never a
            // truncated image. It is also why the destination directory must be writable, not just
            // the file: the temporary file is created there.
            try data.write(to: url, options: [.atomic])
        } catch {
            let detail = error as NSError
            // `NSFileWriteOutOfSpaceError` is 640 in `NSCocoaErrorDomain`. Reported as `.diskFull`
            // rather than as a generic write failure, because the remedy the user is shown differs:
            // "free up space" versus "check permissions".
            if detail.domain == NSCocoaErrorDomain, detail.code == 640 {
                throw StorageError.diskFull(needBytes: Int64(data.count))
            }
            throw StorageError.notWritable(
                path: "\(url.path) (\(detail.domain) \(detail.code))")
        }
    }
}

#endif
