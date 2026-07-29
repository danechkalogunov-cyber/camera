//
//  MainWindowView+Library.swift
//  Vigil
//
//  The window's clip library: listing the recordings folder, enriching what is listed, and the
//  actions the Recordings screen offers over them.
//  macOS-only. Split from MainWindowView.swift, which docs/DESIGN.md §7.2 caps at 600 lines.
//

#if os(macOS)

import AVFoundation
import AppKit
import CoreMedia
import Foundation
import SwiftUI

import VigilCore
import VigilProtocols
import VigilUI

// MARK: - Clips and the Recordings screen

/// ⚠️ These members are `internal`, not `private`, and the reason is a Swift rule rather than a
/// choice: `private` on a member is visible to the type's extensions **in the same file only**, so a
/// member moved out of `MainWindowView.swift` and left `private` becomes invisible to the body that
/// calls it. Nothing outside this target can reach `MainWindowView` regardless.
extension MainWindowView {

    /// Re-reads the clips folder into `window.clips`.
    ///
    /// Runs on appearance and every time a recording finishes, which is when the set can change. A
    /// file still being written is listed with `isRecording` true rather than hidden, because hiding
    /// it would make pressing Record look like it did nothing for as long as the clip ran.
    func reloadClips() {
        // Two passes on the first run only: the first adopts whatever predates the manifest, the
        // second lists against it. Without this, introducing the manifest would hide every clip the
        // user had already recorded.
        if manifest.entries.isEmpty {
            adoptExistingClips()
        }
        recoverOrphanedClips()
        let logger = session.dependencies.logger
        guard let folder = recording.clipsDirectory() else {
            logger.error(.storage, "clip listing: no usable destination")
            window.clips = []
            return
        }
        // Clips are NOT in this folder — they are under it. `RecordingNaming.defaultClipTemplate`
        // is "{camera}/{yyyy}-{MM}-{dd}/{camera}_{HHmmss}_{trigger}", so the recorder creates two
        // levels of directory per clip, and a flat `contentsOfDirectory` sees one subfolder and no
        // media at all. That is what "0 of 1 entries" was reporting.
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            logger.error(.storage, "clip listing: cannot read \(folder.path)")
            window.clips = []
            return
        }

        let camera = VLibraryCamera(id: cameraID, name: identity.name)
        var found: [VLibraryClip] = []
        var seen = 0
        var foreign = 0
        var altered = 0
        for case let url as URL in walker {
            seen += 1
            // A clip still being written is `name.mp4.partial`, whose `pathExtension` is "partial",
            // so testing the extension alone hides the file a user is watching get recorded.
            let name = url.lastPathComponent
            let isPartial = name.hasSuffix(".partial")
            let mediaName = isPartial ? String(name.dropLast(".partial".count)) : name
            guard ["mp4", "mov"].contains((mediaName as NSString).pathExtension.lowercased()) else {
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile != false else { continue }

            // Only files Vigil wrote. The recordings folder is an ordinary directory in the user's
            // Movies: anything dropped into it would otherwise be listed as a recording, complete
            // with a camera name it never came from. A clip still being written has no entry yet and
            // is allowed through, because the writer holding it open is this process.
            let relative = ClipManifest.key(for: url, under: folder, logger: logger)
            let vouched = manifest.entry(for: relative)
            if !isPartial {
                guard let vouched else {
                    if foreign == 0 {
                        logger.debug(.storage, "clip listing: no manifest entry for \(relative)")
                    }
                    foreign += 1
                    continue
                }
                // Size is reported, not enforced. `ClipRecorder` reads it at close, which can be
                // before `AVAssetWriter` has finished appending the moov atom and before the
                // `.partial` rename — so a legitimate clip can differ from its recorded size, and
                // hiding it over that would lose the user's own recording. Membership in the
                // manifest is the check that answers the question actually asked: was this file put
                // here by Vigil, or dropped in.
                if let size = values?.fileSize, Int64(size) != vouched.byteCount {
                    altered += 1
                }
            }
            found.append(VLibraryClip(id: Self.stableID(for: url),
                                      camera: camera,
                                      startedAt: values?.contentModificationDate ?? Date(),
                                      // Zero means "adopted, never measured" — the enrichment pass
                                      // reads the real length from the file rather than the row
                                      // showing a confident 0:00.
                                      durationSeconds: manifest.entry(for: relative)
                                          .map(\.mediaSeconds).flatMap { $0 > 0 ? $0 : nil },
                                      byteCount: values?.fileSize.map(Int64.init),
                                      fileName: relative,
                                      url: url,
                                      thumbnail: window.posters[url],
                                      isRecording: isPartial))
        }
        window.clips = found
        logger.info(.storage,
                    "clip listing: \(found.count) clips of \(seen) entries under \(folder.path)"
                    + (foreign > 0 ? ", \(foreign) not written by Vigil" : "")
                    + (altered > 0 ? ", \(altered) whose size differs from the record" : ""))
        Task { await enrich(found) }
    }

    /// Fills in the poster frame and the duration for clips that do not have them yet.
    ///
    /// Off the main actor and one clip at a time: `AVAssetImageGenerator` decodes a frame, and doing
    /// that for a folder's worth of clips at once would compete with the live decoder for the very
    /// hardware the picture depends on. Results are cached by URL, so scrolling the list or
    /// re-reading the folder does no work twice.
    func enrich(_ clips: [VLibraryClip]) async {
        for clip in clips {
            guard let url = clip.url, !clip.isRecording, window.posters[url] == nil else { continue }
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 180)
            // A clip that is short, truncated, or whose moov atom never landed simply yields no
            // image; the row keeps its tinted placeholder rather than the list stalling.
            let poster = try? await generator.image(at: .zero).image
            let duration = try? await asset.load(.duration)
            await MainActor.run {
                if let poster { window.posters[url] = poster }
                if let duration, duration.isNumeric {
                    window.durations[url] = duration.seconds
                }
            }
        }
        applyEnrichment()
    }

    /// Rebuilds the rows with whatever posters and durations have been extracted.
    func applyEnrichment() {
        window.clips = window.clips.map { clip in
            guard let url = clip.url else { return clip }
            return VLibraryClip(id: clip.id,
                                camera: clip.camera,
                                startedAt: clip.startedAt,
                                durationSeconds: clip.durationSeconds ?? window.durations[url],
                                byteCount: clip.byteCount,
                                fileName: clip.fileName,
                                url: url,
                                thumbnail: clip.thumbnail ?? window.posters[url],
                                isRecording: clip.isRecording)
        }
    }

    /// A UUID derived from the file's path, so a row keeps its identity across a refresh.
    ///
    /// Hashing the path rather than minting a fresh UUID matters: `ForEach` would otherwise rebuild
    /// every row on each reload, losing selection and restarting animations.
    static func stableID(for url: URL) -> UUID {
        var hasher = Hasher()
        hasher.combine(url.path)
        let value = UInt64(bitPattern: Int64(hasher.finalize()))
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 { bytes[index] = UInt8((value >> (8 * UInt64(index))) & 0xFF) }
        for index in 8..<16 { bytes[index] = bytes[index - 8] }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The library gestures the app can honour today.
    ///
    /// Only the two that need no data behind them. Everything else keeps its no-op default: playing,
    /// revealing and deleting a clip need clips, and scrubbing needs a loaded day. A handler that
    /// fired against an empty list would be a button pretending to work.
    var libraryActions: VLibraryActions {
        var actions = VLibraryActions()
        actions.onOpenRecordingsFolder = { openRecordingsFolder() }
        actions.onRevealClip = { clip in revealClip(clip) }
        actions.onDeleteClip = { clip in deleteClip(clip) }
        actions.onOpenNotificationSettings = { window.isInspectorVisible = true }
        actions.onOpenEvent = { event in openArchive(at: event.occurredAt) }
        actions.onOpenBookmark = { bookmark in openArchive(at: bookmark.instant) }
        actions.onDeleteBookmark = { bookmark in bookmarks.delete(bookmark.id) }
        actions.onDeleteEvent = { event in
            Task { await eventFeed.delete(event.id, camera: session.camera) }
        }
        actions.onScrub = { phase, instant in
            // Only `.ended` would issue a seek — and there is nothing to seek yet, because playing
            // the device's archive needs the playback pipeline `VigilVideo` does not have. The
            // playhead still follows the pointer, so the scrubber reads its own position honestly.
            archive.movePlayhead(to: instant, isScrubbing: phase != .ended)
        }
        actions.onZoom = { stop in archive.zoom(stop) }
        actions.onActivateMarker = { cluster in
            // A cluster is one or more markers at the same x; the earliest is the one the badge is
            // anchored on, and jumping to it is what "open this cluster" means before there is a
            // popover to list the rest.
            guard let first = cluster.markers.first else { return }
            archive.movePlayhead(to: first.instant, isScrubbing: false)
        }
        return actions
    }

    /// Reveals the recordings destination in the Finder, creating nothing.
    ///
    /// `RecordingDestination` owns where clips go; until the app drives it, the folder may not exist
    /// yet, and `activateFileViewerSelecting` on a missing path silently does nothing rather than
    /// failing — which is the right outcome for a button whose whole job is "show me where".
    /// One-time migration: takes responsibility for clips recorded before the manifest existed.
    func adoptExistingClips() {
        guard let folder = recording.clipsDirectory() else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }

        var adoptable: [(relativePath: String, cameraID: CameraID, modifiedAt: Date, bytes: Int64)] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard !name.hasSuffix(".partial") else { continue }
            guard ["mp4", "mov"].contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile != false else { continue }
            adoptable.append((ClipManifest.key(for: url, under: folder),
                              cameraID,
                              values?.contentModificationDate ?? Date(),
                              Int64(values?.fileSize ?? 0)))
        }
        manifest.adopt(adoptable)
    }

    /// Finishes the `.partial` files a crash left behind.
    ///
    /// `ClipRecorder` writes to `name.mp4.partial` and renames on a clean finish, so a file still
    /// carrying that suffix while nothing is recording is the remains of an interrupted session —
    /// a crash, a force quit, a power cut. It is **playable**: the writer is fragmented, so
    /// everything up to the last completed fragment is intact, which is precisely why it is
    /// recovered rather than deleted. Someone who recorded for an hour and lost the app in the last
    /// minute should not lose the hour.
    ///
    /// Renamed and vouched for so it appears in the list like any other clip. The manifest entry is
    /// what makes it appear at all — an unvouched file is treated as something dropped into the
    /// folder by hand, which this is not.
    ///
    /// Silent about a file it cannot move: another process holding it open is the one case where
    /// leaving it alone is right, and it will be recovered on the next launch instead.
    func recoverOrphanedClips() {
        // ⛔ `ownsClipFiles`, never `isRecording`. `isRecording` goes false the moment Stop is
        // pressed, while the writer is still inside `finishWriting` and the file is still called
        // `.partial` — and this method is called from `reloadClips()`, which runs *when a recording
        // finishes*. So the two used to meet exactly: the sweep renamed the live file, the
        // recorder's own rename then failed with NSFileNoSuchFileError, and the clip was recorded
        // against a path nothing occupied.
        guard !recording.ownsClipFiles, let folder = recording.clipsDirectory() else { return }
        let logger = session.dependencies.logger
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }

        var recovered = 0
        for case let url as URL in walker where url.lastPathComponent.hasSuffix(".partial") {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile != false else { continue }
            let bytes = Int64(values?.fileSize ?? 0)
            // A zero-length partial never got a keyframe and holds nothing. Those are dropped:
            // recovering an empty file would put a clip in the list that plays as a black frame.
            guard bytes > 0 else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let finished = url.deletingPathExtension()
            guard !FileManager.default.fileExists(atPath: finished.path) else { continue }
            do {
                try FileManager.default.moveItem(at: url, to: finished)
            } catch {
                logger.info(.storage, "could not recover an interrupted clip: \(error)")
                continue
            }
            manifest.recordRecovered(url: finished,
                                     cameraID: cameraID,
                                     root: folder,
                                     at: values?.contentModificationDate ?? Date(),
                                     bytes: bytes)
            recovered += 1
        }
        if recovered > 0 {
            logger.info(.storage, "recovered \(recovered) interrupted clip(s)")
        }
    }

    /// Adds the clips the last recording produced to the manifest.
    func vouchForFinishedClips() {
        let finished = recording.lastFinished
        guard !finished.isEmpty,
              let camera = session.camera,
              let root = recording.clipsDirectory() else { return }
        manifest.record(finished, cameraID: camera.id, root: root)
    }

    /// Deletes a clip and forgets it.
    ///
    /// The manifest entry goes with the file. Leaving it behind would make a later file of the same
    /// name inherit this one's vouching, which is exactly the substitution the manifest exists to
    /// prevent.
    func deleteClip(_ clip: VLibraryClip) {
        guard let url = clip.url else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            manifest.forget(clip.fileName)
            session.dependencies.logger.info(.storage, "clip moved to trash")
            reloadClips()
        } catch {
            session.dependencies.logger.error(.storage, "could not delete clip: \(error)")
        }
    }

    /// Reveals one clip in the Finder.
    func revealClip(_ clip: VLibraryClip) {
        guard let folder = recording.clipsDirectory() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder.appending(path: clip.fileName)])
    }

    func openRecordingsFolder() {
        guard let folder = recording.clipsDirectory() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

#endif  // os(macOS)
