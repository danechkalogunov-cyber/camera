//
//  ClipManifest.swift
//  Vigil
//
//  The record of which clips Vigil actually wrote, kept where the user's file manager is not.
//  macOS-only. See docs/spec-core.md §9.
//

#if os(macOS)

import Foundation
import Observation

import VigilCore
import VigilProtocols

// MARK: - ClipManifestEntry

/// One clip Vigil wrote, as it was when the writer closed it.
///
/// The byte count is the integrity check. It is what the recorder observed at the moment it finished
/// the file, so a clip whose size no longer matches has been changed by something that is not Vigil —
/// and the list says so rather than presenting it as a recording.
struct ClipManifestEntry: Codable, Sendable, Hashable {

    /// Path relative to the recordings root, which is the key everything else is looked up by.
    ///
    /// Relative, not absolute: the container path contains a bundle identifier and a user name, and
    /// a manifest full of absolute paths breaks the moment either changes.
    let relativePath: String

    /// The camera this came from.
    let cameraID: UUID

    /// When the recorder opened the file.
    let startedAt: Date

    /// When it closed it.
    let endedAt: Date

    /// Media duration in seconds, as the writer measured it — not as a reader re-derives it.
    let mediaSeconds: Double

    /// Size in bytes at close.
    let byteCount: Int64
}

// MARK: - ClipManifest

/// Which files in the recordings folder are genuinely Vigil's.
///
/// **Why this exists.** The recordings folder is an ordinary directory in the user's Movies. Anything
/// can be dropped into it, and a listing that trusts the file system will present that as a
/// recording — complete with a camera name it never came from. The manifest is the app's own record,
/// written when a clip closes, and the list is filtered through it.
///
/// **Where it lives, and why not next to the clips.** Application Support inside the app's container,
/// which the sandbox owns: `~/Library/Containers/com.vigil.app/Data/Library/Application Support`.
/// Putting it in the Movies folder would make it exactly as substitutable as the files it vouches
/// for, which is the opposite of the point.
///
/// **What it is not.** Not a security boundary. Anyone who can run code as this user can edit the
/// manifest as easily as the clips. It defends against a file *appearing* to be a recording, not
/// against a determined forgery, and the difference is worth being honest about.
@MainActor
@Observable
final class ClipManifest {

    // MARK: - Stored Properties

    /// Entries by relative path.
    private(set) var entries: [String: ClipManifestEntry] = [:]

    private let logger: any LoggerProtocol

    // MARK: - Initialisation

    /// Loads the manifest from disk, or starts empty when there is none.
    ///
    /// A manifest that cannot be read is treated as empty rather than as a failure: the clips are
    /// still on disk, and refusing to list anything because a bookkeeping file is corrupt would be a
    /// worse outcome than listing what can be verified.
    init(logger: any LoggerProtocol) {
        self.logger = logger
        guard let url = Self.storeURL else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            let decoded = try JSONDecoder().decode([ClipManifestEntry].self, from: data)
            entries = Dictionary(decoded.map { ($0.relativePath, $0) },
                                 uniquingKeysWith: { _, latest in latest })
            logger.debug(.storage, "clip manifest: \(entries.count) entries")
        } catch {
            logger.error(.storage, "clip manifest unreadable, starting empty: \(error)")
        }
    }

    // MARK: - API

    /// Records the clips a finished recording produced.
    ///
    /// - Parameters:
    ///   - segments: what `ClipRecorder.finish(reason:)` returned.
    ///   - cameraID: the camera they came from.
    ///   - root: the recordings root, so paths are stored relative to it.
    func record(_ segments: [RecordingSegmentRecord], cameraID: CameraID, root: URL) {
        for segment in segments where !segment.isPartial {
            let path = Self.relativePath(of: segment.url, under: root)
            entries[path] = ClipManifestEntry(relativePath: path,
                                              cameraID: cameraID.rawValue,
                                              startedAt: segment.startedAt,
                                              endedAt: segment.endedAt,
                                              mediaSeconds: segment.mediaSeconds,
                                              byteCount: segment.byteCount)
        }
        save()
    }

    /// Drops an entry, for a clip the user deleted.
    func forget(_ relativePath: String) {
        guard entries.removeValue(forKey: relativePath) != nil else { return }
        save()
    }

    /// The entry for a path, if Vigil wrote it.
    func entry(for relativePath: String) -> ClipManifestEntry? {
        entries[relativePath]
    }

    // MARK: - Private Helpers

    /// Writes the manifest out.
    ///
    /// Atomic, so a crash mid-write leaves the previous manifest rather than a truncated one — the
    /// same reason `SystemRecordingFileSystem.writeDurably` uses `.atomic` for snapshots.
    private func save() {
        guard let url = Self.storeURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Array(entries.values)).write(to: url, options: [.atomic])
        } catch {
            logger.error(.storage, "clip manifest could not be written: \(error)")
        }
    }

    /// Where the manifest is kept.
    static var storeURL: URL? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
        return support?.appending(path: "Vigil/clips.json")
    }

    /// A path relative to the recordings root.
    static func relativePath(of url: URL, under root: URL) -> String {
        let full = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        guard full.hasPrefix(base) else { return url.lastPathComponent }
        return String(full.dropFirst(base.count).drop(while: { $0 == "/" }))
    }
}

#endif  // os(macOS)
