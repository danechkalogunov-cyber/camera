//
//  DataPortability.swift
//  Vigil
//
//  User-controlled import/export formats. These types deliberately live above VigilCore: groups
//  are app state, while cameras belong to the core library.
//

#if os(macOS)

import Foundation
import VigilCore
import VigilProtocols

// MARK: - Configuration archive

struct VigilConfigurationArchive: Codable, Sendable, Equatable {
    static let currentVersion = 1

    var version: Int
    var exportedAt: Date
    var cameras: [Camera]
    var groups: [CameraGroupRecord]

    init(exportedAt: Date = Date(), cameras: [Camera], groups: [CameraGroupRecord]) {
        version = Self.currentVersion
        self.exportedAt = exportedAt
        self.cameras = cameras
        self.groups = groups
    }
}

enum ConfigurationArchiveCodec {
    enum Failure: Error, Equatable {
        case unsupportedVersion(Int)
        case duplicateCameraID(CameraID)
        case danglingGroupMember(CameraID)
    }

    static func encode(_ archive: VigilConfigurationArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(archive)
    }

    static func decode(_ data: Data) throws -> VigilConfigurationArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(VigilConfigurationArchive.self, from: data)
        guard archive.version == VigilConfigurationArchive.currentVersion else {
            throw Failure.unsupportedVersion(archive.version)
        }
        var identifiers: Set<CameraID> = []
        for camera in archive.cameras where !identifiers.insert(camera.id).inserted {
            throw Failure.duplicateCameraID(camera.id)
        }
        for member in archive.groups.flatMap(\.members) where !identifiers.contains(member) {
            throw Failure.danglingGroupMember(member)
        }
        return archive
    }
}

// MARK: - CSV camera list

enum CameraCSVImporter {
    enum Failure: Error, Equatable {
        case emptyDocument
        case missingHostColumn
        case malformedRow(Int)
        case invalidInteger(row: Int, column: String)
        case invalidBoolean(row: Int, column: String)
    }

    /// Imports RFC 4180 CSV. Required column: `host`. Optional columns are `name`, `httpPort`,
    /// `rtspPort`, `channel`, `useTLS`, and `enabled`. Unknown columns are retained by the user's
    /// source file and ignored, making exports from inventory tools forward compatible.
    static func decode(_ data: Data) throws -> [Camera] {
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.emptyDocument }
        let rows = try rows(in: text)
        guard let header = rows.first, !header.isEmpty else { throw Failure.emptyDocument }
        let names = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard let hostIndex = names.firstIndex(of: "host") else { throw Failure.missingHostColumn }

        return try rows.dropFirst().enumerated().compactMap { offset, fields in
            let row = offset + 2
            if fields.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return nil
            }
            guard fields.count == header.count else { throw Failure.malformedRow(row) }
            func value(_ key: String) -> String? {
                guard let index = names.firstIndex(of: key) else { return nil }
                let result = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
                return result.isEmpty ? nil : result
            }
            func integer(_ key: String, default fallback: Int) throws -> Int {
                guard let raw = value(key) else { return fallback }
                guard let parsed = Int(raw) else { throw Failure.invalidInteger(row: row, column: key) }
                return parsed
            }
            func boolean(_ key: String, default fallback: Bool) throws -> Bool {
                guard let raw = value(key)?.lowercased() else { return fallback }
                switch raw {
                case "true", "yes", "1": return true
                case "false", "no", "0": return false
                default: throw Failure.invalidBoolean(row: row, column: key)
                }
            }
            let host = fields[hostIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            return try Camera(name: value("name") ?? "", host: host,
                              httpPort: integer("httpport", default: 80),
                              rtspPort: integer("rtspport", default: 554),
                              useTLS: boolean("usetls", default: false),
                              channel: ChannelID(integer("channel", default: 1)),
                              isEnabled: boolean("enabled", default: true)).validated()
        }
    }

    private static func rows(in text: String) throws -> [[String]] {
        var result: [[String]] = [], row: [String] = [], field = ""
        var quoted = false
        let characters = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"", index + 1 < characters.count, characters[index + 1] == "\"" {
                    field.append("\""); index += 1
                } else if character == "\"" { quoted = false } else { field.append(character) }
            } else if character == "\"" && field.isEmpty {
                quoted = true
            } else if character == "," {
                row.append(field); field = ""
            } else if character == "\n" {
                row.append(field); result.append(row); row = []; field = ""
            } else { field.append(character) }
            index += 1
        }
        guard !quoted else { throw Failure.malformedRow(max(result.count + 1, 1)) }
        if !field.isEmpty || !row.isEmpty { row.append(field); result.append(row) }
        return result
    }
}

// MARK: - Diagnostic bundle

struct DiagnosticBundle: Codable, Sendable {
    var formatVersion = 1
    var createdAt: Date
    var application: [String: String]
    var statistics: [String: String]
    var logs: [String]
    var deviceResponses: [String: String]
}

enum DiagnosticBundleBuilder {
    /// Produces one portable JSON file. Values are scrubbed a second time here even though logger
    /// call sites already redact, because support exports are a separate security boundary.
    static func build(createdAt: Date = Date(), application: [String: String],
                      statistics: [String: String], logs: [String],
                      deviceResponses: [String: String]) throws -> Data {
        let scrub: (String) -> String = { raw in
            var value = raw
            let patterns = [
                #"(?i)(password|passwd|token|authorization|cookie)\s*[:=]\s*[^\s,;\"}]+"#,
                #"(?i)(rtsp|https?)://[^/@\s]+@"#,
            ]
            for pattern in patterns {
                value = value.replacingOccurrences(of: pattern, with: "$1=<redacted>",
                                                   options: .regularExpression)
            }
            return value
        }
        func dictionary(_ input: [String: String]) -> [String: String] {
            Dictionary(uniqueKeysWithValues: input.map { key, value in
                let sensitive = key.range(of: #"password|passwd|token|authorization|cookie"#,
                                          options: [.regularExpression, .caseInsensitive]) != nil
                return (key, sensitive ? "<redacted>" : scrub(value))
            })
        }
        let bundle = DiagnosticBundle(createdAt: createdAt,
                                      application: dictionary(application),
                                      statistics: dictionary(statistics),
                                      logs: logs.map(scrub),
                                      deviceResponses: dictionary(deviceResponses))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(bundle)
    }
}

#endif
