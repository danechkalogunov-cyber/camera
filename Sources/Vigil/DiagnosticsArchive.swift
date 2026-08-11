//
//  DiagnosticsArchive.swift
//  Vigil
//
//  The final security boundary for support exports. Callers hand this type textual evidence; it
//  redacts every value again, hashes the exact bytes that will be written, adds a manifest and emits
//  a deterministic STORE-only ZIP. Nothing is uploaded and no temporary directory is created.
//

#if os(macOS)

import CryptoKit
import Foundation
import OSLog

import VigilProtocols

struct DiagnosticsArchiveFile: Sendable, Hashable {
    let path: String
    let data: Data

    init(path: String, data: Data) {
        self.path = path
        self.data = data
    }

    init(path: String, text: String) {
        self.init(path: path, data: Data(text.utf8))
    }
}

struct DiagnosticsManifest: Codable, Sendable, Hashable {
    struct File: Codable, Sendable, Hashable {
        let path: String
        let bytes: Int
        let sha256: String
    }

    let formatVersion: Int
    let createdAt: Date
    let includesHostnames: Bool
    let includesFullLogs: Bool
    let files: [File]
}

enum DiagnosticsArchiveError: Error, Sendable, Hashable {
    case exceedsSizeLimit(bytes: Int)
}

enum DiagnosticsArchiveBuilder {
    static let maximumBytes = 40 * 1_024 * 1_024

    static func build(createdAt: Date, includesHostnames: Bool, includesFullLogs: Bool,
                      files input: [DiagnosticsArchiveFile]) throws -> Data {
        try Task.checkCancellation()
        let inputBytes = input.reduce(0) { $0 + $1.data.count }
        guard inputBytes <= maximumBytes else {
            throw DiagnosticsArchiveError.exceedsSizeLimit(bytes: inputBytes)
        }
        let files = try input.map { file in
            try Task.checkCancellation()
            let text = String(decoding: file.data, as: UTF8.self)
            return DiagnosticsArchiveFile(path: file.path,
                                          text: Redact.secrets(in: text))
        }
        let contentBytes = files.reduce(0) { $0 + $1.data.count }
        guard contentBytes <= maximumBytes else {
            throw DiagnosticsArchiveError.exceedsSizeLimit(bytes: contentBytes)
        }

        let rows = try files.map { file in
            try Task.checkCancellation()
            DiagnosticsManifest.File(path: file.path, bytes: file.data.count,
                                     sha256: CryptoKit.SHA256.hash(data: file.data).hexadecimal)
        }
        let manifest = DiagnosticsManifest(formatVersion: 1, createdAt: createdAt,
                                           includesHostnames: includesHostnames,
                                           includesFullLogs: includesFullLogs, files: rows)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(manifest)
        let entries = files.map { ZIPEntry(path: $0.path, data: $0.data) }
            + [ZIPEntry(path: "manifest.json", data: manifestData)]
        try Task.checkCancellation()
        let archive = try StoreOnlyZIP.encode(entries)
        guard archive.count <= maximumBytes else {
            throw DiagnosticsArchiveError.exceedsSizeLimit(bytes: archive.count)
        }
        return archive
    }
}

enum DiagnosticLogCollector {
    /// Reads only this process. Unified-log access can be denied by the OS; an explanatory line is
    /// more useful in the bundle than failing the whole export in that case.
    static func last24Hours(now: Date = Date()) -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: now.addingTimeInterval(-24 * 60 * 60))
            let entries = try store.getEntries(at: position)
            let formatter = ISO8601DateFormatter()
            return entries.compactMap { entry -> String? in
                guard let line = entry as? OSLogEntryLog else { return nil }
                return "\(formatter.string(from: line.date)) "
                    + "[\(line.category)] \(Redact.secrets(in: line.composedMessage))"
            }.joined(separator: "\n")
        } catch {
            return "Unified logs unavailable: \(Redact.secrets(in: error.localizedDescription))"
        }
    }
}

private extension CryptoKit.SHA256.Digest {
    var hexadecimal: String { map { String(format: "%02x", $0) }.joined() }
}

#endif
