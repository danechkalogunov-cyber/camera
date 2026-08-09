//
//  EventThumbnailStore.swift
//  Vigil
//
//  Bounded on-disk cache for camera-supplied event JPEGs.
//

#if os(macOS)

import Foundation

import VigilProtocols

actor EventThumbnailStore {
    private let directory: URL
    private let logger: any LoggerProtocol
    private let maximumFiles = 512

    init(logger: any LoggerProtocol, fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directory = base.appendingPathComponent("Vigil/EventThumbnails", isDirectory: true)
        self.logger = logger
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func save(_ jpeg: Data, eventID: EventID) -> URL? {
        guard jpeg.count >= 4, jpeg[0] == 0xFF, jpeg[1] == 0xD8 else {
            logger.notice(.storage, "event snapshot was not a JPEG")
            return nil
        }
        let url = self.url(for: eventID)
        do {
            try jpeg.write(to: url, options: .atomic)
            pruneIfNeeded()
            return url
        } catch {
            logger.error(.storage, "event snapshot could not be cached: \(error)")
            return nil
        }
    }

    func existingURL(for eventID: EventID) -> URL? {
        let candidate = url(for: eventID)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    func remove(_ eventID: EventID) {
        try? FileManager.default.removeItem(at: url(for: eventID))
    }

    private func url(for eventID: EventID) -> URL {
        directory.appendingPathComponent(eventID.rawValue.uuidString).appendingPathExtension("jpg")
    }

    private func pruneIfNeeded() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]), files.count > maximumFiles else { return }
        let oldest = files.sorted {
            let lhs = try? $0.resourceValues(forKeys: keys).contentModificationDate
            let rhs = try? $1.resourceValues(forKeys: keys).contentModificationDate
            return (lhs ?? .distantPast) < (rhs ?? .distantPast)
        }.prefix(files.count - maximumFiles)
        for file in oldest { try? FileManager.default.removeItem(at: file) }
    }
}

#endif  // os(macOS)
