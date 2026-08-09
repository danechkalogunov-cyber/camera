//
//  DataPortability.swift
//  Vigil
//
//  User-controlled import/export formats. These types deliberately live above VigilCore: groups
//  are app state, while cameras belong to the core library.
//

#if os(macOS)

import CryptoKit
import CommonCrypto
import Foundation
import Security
import VigilCore
import VigilProtocols
import VigilUI

// MARK: - Configuration archive

/// Persisted workspace choices that belong in a portable configuration, unlike transient focus,
/// sheets and search text.
struct VigilWorkspaceSettings: Codable, Sendable, Equatable {
    var layout: VGridLayout
    var watchedCameraIDs: [CameraID]
    var fillsTile: Bool
    var showsVideoOverlay: Bool
    var isSidebarVisible: Bool
    var prefersSidebarRail: Bool
    var isInspectorVisible: Bool
}

struct VigilConfigurationArchive: Codable, Sendable, Equatable {
    static let currentVersion = 2

    var version: Int
    var exportedAt: Date
    var cameras: [Camera]
    var groups: [CameraGroupRecord]
    var bookmarks: [BookmarkRecord]?
    var layoutPresets: VLayoutPresetCollection?
    var videoWall: VVideoWallConfiguration?
    var settings: VigilWorkspaceSettings?

    init(exportedAt: Date = Date(), cameras: [Camera], groups: [CameraGroupRecord],
         bookmarks: [BookmarkRecord]? = nil,
         layoutPresets: VLayoutPresetCollection? = nil,
         videoWall: VVideoWallConfiguration? = nil,
         settings: VigilWorkspaceSettings? = nil) {
        version = Self.currentVersion
        self.exportedAt = exportedAt
        self.cameras = cameras
        self.groups = groups
        self.bookmarks = bookmarks
        self.layoutPresets = layoutPresets
        self.videoWall = videoWall
        self.settings = settings
    }
}

enum ConfigurationArchiveCodec {
    enum Failure: Error, Equatable {
        case unsupportedVersion(Int)
        case duplicateCameraID(CameraID)
        case duplicateGroupID(GroupID)
        case danglingGroupMember(CameraID)
        case duplicateBookmarkID(UUID)
        case danglingBookmarkCamera(CameraID)
        case duplicateLayoutPresetID(UUID)
        case danglingLayoutCamera(String)
        case danglingWatchedCamera(CameraID)
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
        try validate(archive)
        return archive
    }

    static func validate(_ archive: VigilConfigurationArchive) throws {
        guard (1...VigilConfigurationArchive.currentVersion).contains(archive.version) else {
            throw Failure.unsupportedVersion(archive.version)
        }
        var identifiers: Set<CameraID> = []
        for camera in archive.cameras where !identifiers.insert(camera.id).inserted {
            throw Failure.duplicateCameraID(camera.id)
        }
        var groupIDs: Set<GroupID> = []
        for group in archive.groups {
            guard groupIDs.insert(group.id).inserted else {
                throw Failure.duplicateGroupID(group.id)
            }
            for member in group.members where !identifiers.contains(member) {
                throw Failure.danglingGroupMember(member)
            }
        }
        var bookmarkIDs: Set<UUID> = []
        for bookmark in archive.bookmarks ?? [] {
            guard bookmarkIDs.insert(bookmark.id).inserted else {
                throw Failure.duplicateBookmarkID(bookmark.id)
            }
            guard identifiers.contains(bookmark.cameraID) else {
                throw Failure.danglingBookmarkCamera(bookmark.cameraID)
            }
        }
        var presetIDs: Set<UUID> = []
        for preset in archive.layoutPresets?.presets ?? [] {
            guard presetIDs.insert(preset.id).inserted else {
                throw Failure.duplicateLayoutPresetID(preset.id)
            }
            for raw in preset.cameraIDs {
                guard let uuid = UUID(uuidString: raw), identifiers.contains(CameraID(uuid)) else {
                    throw Failure.danglingLayoutCamera(raw)
                }
            }
        }
        for watched in archive.settings?.watchedCameraIDs ?? [] where !identifiers.contains(watched) {
            throw Failure.danglingWatchedCamera(watched)
        }
    }
}

// MARK: - Encrypted configuration backup

struct EncryptedConfigurationPayload: Codable, Sendable, Equatable {
    struct StoredCredential: Codable, Sendable, Equatable {
        var cameraID: CameraID
        var ref: CredentialRef
        var account: String
        var secret: String
    }

    var archive: VigilConfigurationArchive
    var credentials: [StoredCredential]
}

enum EncryptedConfigurationCodec {
    static let iterations: UInt32 = 600_000
    private static let magic = Data("VIGILBK1".utf8)

    enum Failure: Error, Equatable {
        case weakPassphrase
        case damaged
        case wrongPassphrase
        case randomGenerationFailed
    }

    static func encode(_ payload: EncryptedConfigurationPayload,
                       passphrase: String) throws -> Data {
        guard passphrase.count >= 12 else { throw Failure.weakPassphrase }
        var plaintext = try JSONEncoder.vigilBackup.encode(payload)
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        return try encode(plaintext, passphrase: passphrase, iterations: iterations,
                          salt: randomBytes(count: 16), nonce: randomBytes(count: 12))
    }

    static func decode(_ container: Data, passphrase: String) throws -> EncryptedConfigurationPayload {
        guard passphrase.count >= 12 else { throw Failure.weakPassphrase }
        guard container.count >= 64, container.prefix(8) == magic,
              readUInt16(container, at: 8) == 1,
              container[10] == 1,
              container[31] == 1 else { throw Failure.damaged }
        let count = Int(readUInt32(container, at: 44))
        guard count >= 0, 48 + count + 16 == container.count else { throw Failure.damaged }
        let rounds = readUInt32(container, at: 11)
        guard rounds >= 100_000 else { throw Failure.damaged }
        let salt = Data(container[15..<31])
        let nonceData = Data(container[32..<44])
        let aad = Data(container[0..<44])
        let ciphertext = Data(container[48..<(48 + count)])
        let tag = Data(container[(48 + count)..<container.count])
        let key = try pbkdf2(passphrase: passphrase, salt: salt, iterations: rounds)
        let nonce: AES.GCM.Nonce
        do { nonce = try AES.GCM.Nonce(data: nonceData) } catch { throw Failure.damaged }
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        } catch {
            throw Failure.damaged
        }
        var plaintext: Data
        do {
            plaintext = try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw Failure.wrongPassphrase
        }
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        do {
            let payload = try JSONDecoder.vigilBackup.decode(EncryptedConfigurationPayload.self,
                                                              from: plaintext)
            try ConfigurationArchiveCodec.validate(payload.archive)
            let cameras = Dictionary(uniqueKeysWithValues: payload.archive.cameras.map { ($0.id, $0) })
            var credentialCameras: Set<CameraID> = []
            for stored in payload.credentials {
                guard credentialCameras.insert(stored.cameraID).inserted,
                      let camera = cameras[stored.cameraID], camera.credentialRef == stored.ref
                else { throw Failure.damaged }
            }
            return payload
        } catch {
            if let failure = error as? Failure { throw failure }
            throw Failure.damaged
        }
    }

    /// Internal deterministic seam for byte-exact tests; production always supplies CSPRNG bytes.
    static func encode(_ plaintext: Data, passphrase: String, iterations: UInt32,
                       salt: Data, nonce: Data) throws -> Data {
        guard salt.count == 16, nonce.count == 12, iterations > 0 else { throw Failure.damaged }
        var header = Data()
        header.append(magic)
        append(UInt16(1), to: &header)
        header.append(1)
        append(iterations, to: &header)
        header.append(salt)
        header.append(1)
        header.append(nonce)
        append(UInt32(plaintext.count), to: &header)
        let key = try pbkdf2(passphrase: passphrase, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(plaintext, using: key,
                                      nonce: AES.GCM.Nonce(data: nonce),
                                      authenticating: Data(header.prefix(44)))
        var output = header
        output.append(sealed.ciphertext)
        output.append(sealed.tag)
        return output
    }

    private static func pbkdf2(passphrase: String, salt: Data,
                               iterations: UInt32) throws -> SymmetricKey {
        let password = Data(passphrase.utf8)
        var derived = Data(repeating: 0, count: kCCKeySizeAES256)
        let status = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                derived.withUnsafeMutableBytes { outputBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordBytes.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        outputBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        outputBytes.count)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.damaged }
        return SymmetricKey(data: derived)
    }

    private static func randomBytes(count: Int) throws -> Data {
        var data = Data(repeating: 0, count: count)
        let result = data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard result == errSecSuccess else { throw Failure.randomGenerationFailed }
        return data
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }
}

private extension JSONEncoder {
    static var vigilBackup: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private extension JSONDecoder {
    static var vigilBackup: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - CSV camera list

enum CameraCSVImporter {
    enum Failure: Error, Sendable, Hashable {
        case emptyDocument
        case unsupportedTextEncoding
        case missingHostColumn
        case malformedRow(Int)
        case invalidInteger(row: Int, column: String)
        case invalidBoolean(row: Int, column: String)
        case invalidCamera(row: Int, reason: String)
    }

    struct PreviewRow: Identifiable, Sendable, Hashable {
        var id: Int { sourceRow }
        let sourceRow: Int
        var camera: Camera?
        let username: String?
        let groupName: String?
        let failure: Failure?
    }

    struct Preview: Sendable, Hashable {
        let delimiter: Character
        let encoding: String
        var rows: [PreviewRow]

        var validCameras: [Camera] { rows.compactMap(\.camera) }
        var invalidCount: Int { rows.filter { $0.failure != nil }.count }
    }

    /// Imports RFC 4180-style CSV with comma, semicolon or tab separation. UTF-8 (with or without a
    /// BOM) and Windows-1251 are accepted because camera inventories commonly come from Russian
    /// Windows installations. Unknown columns are ignored for forward compatibility.
    static func decode(_ data: Data) throws -> [Camera] {
        let preview = try preview(data)
        if let failure = preview.rows.compactMap(\.failure).first { throw failure }
        return preview.validCameras
    }

    static func preview(_ data: Data) throws -> Preview {
        let decoded = try decodeText(data)
        let text = decoded.text
        let delimiter = delimiter(in: text)
        let rows = try rows(in: text, delimiter: delimiter)
        guard let header = rows.first, !header.isEmpty else { throw Failure.emptyDocument }
        let names = header.map(canonicalHeader)
        guard let hostIndex = names.firstIndex(of: "host") else { throw Failure.missingHostColumn }

        let previewRows = rows.dropFirst().enumerated().compactMap { offset, fields -> PreviewRow? in
            let row = offset + 2
            if fields.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return nil
            }
            do {
                let parsed = try camera(in: fields, headerCount: header.count, names: names,
                                        hostIndex: hostIndex, sourceRow: row)
                return PreviewRow(sourceRow: row, camera: parsed.camera,
                                  username: parsed.username, groupName: parsed.groupName,
                                  failure: nil)
            } catch let failure as Failure {
                return PreviewRow(sourceRow: row, camera: nil, username: nil, groupName: nil,
                                  failure: failure)
            } catch {
                return PreviewRow(sourceRow: row, camera: nil, username: nil, groupName: nil,
                                  failure: .invalidCamera(row: row,
                                                          reason: String(describing: error)))
            }
        }
        return Preview(delimiter: delimiter, encoding: decoded.encoding, rows: previewRows)
    }

    private static func camera(in fields: [String], headerCount: Int, names: [String],
                               hostIndex: Int, sourceRow row: Int)
        throws -> (camera: Camera, username: String?, groupName: String?) {
        guard fields.count == headerCount else { throw Failure.malformedRow(row) }
        func value(_ key: String) -> String? {
            guard let index = names.firstIndex(of: canonicalHeader(key)) else { return nil }
            let result = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            return result.isEmpty ? nil : result
        }
        func integer(_ key: String, default fallback: Int) throws -> Int {
            guard let raw = value(key) else { return fallback }
            guard let parsed = Int(raw) else {
                throw Failure.invalidInteger(row: row, column: key)
            }
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
        let transport = value("transport").flatMap(RTSPTransportKind.init(rawValue:))
            ?? .tcpInterleaved
        let quality: StreamQuality? = switch value("stream")?.lowercased() {
        case "main": .main
        case "sub": .sub
        case "third": .third
        default: nil
        }
        let color = value("colorTag").flatMap(ColorTag.init(rawValue:)) ?? .none
        do {
            let camera = try Camera(name: value("name") ?? "", host: host,
                                    httpPort: integer("httpport", default: 80),
                                    rtspPort: integer("rtspport", default: 554),
                                    useTLS: boolean("usetls", default: false),
                                    channel: ChannelID(integer("channel", default: 1)),
                                    preferredQuality: quality, transport: transport,
                                    isEnabled: boolean("enabled", default: true), colorTag: color,
                                    rtspPathOverride: value("rtspPathOverride")).validated()
            return (camera, value("username"), value("group"))
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.invalidCamera(row: row, reason: String(describing: error))
        }
    }

    private static func decodeText(_ data: Data) throws -> (text: String, encoding: String) {
        let decoded: (String, String)?
        if let text = String(data: data, encoding: .utf8) {
            decoded = (text, "UTF-8")
        } else if let text = String(data: data, encoding: .windowsCP1251) {
            decoded = (text, "Windows-1251")
        } else {
            decoded = nil
        }
        guard var decoded else { throw Failure.unsupportedTextEncoding }
        if decoded.0.first == "\u{FEFF}" { decoded.0.removeFirst() }
        guard !decoded.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.emptyDocument
        }
        return (decoded.0, decoded.1)
    }

    static func delimiter(in text: String) -> Character {
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0]
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                let next = text.index(after: index)
                if quoted, next < text.endIndex, text[next] == "\"" { index = next }
                else { quoted.toggle() }
            } else if !quoted, character == "\n" || character == "\r" {
                break
            } else if !quoted, counts[character] != nil {
                counts[character, default: 0] += 1
            }
            index = text.index(after: index)
        }
        return [";", "\t"].reduce(Character(",")) { best, candidate in
            (counts[candidate] ?? 0) > (counts[best] ?? 0) ? candidate : best
        }
    }

    private static func canonicalHeader(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .filter { $0 != "_" && $0 != "-" && !$0.isWhitespace }
    }

    private static func rows(in text: String, delimiter: Character) throws -> [[String]] {
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
            } else if character == delimiter {
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

enum CameraCSVExporter {
    static let header = [
        "name", "host", "http_port", "rtsp_port", "use_tls", "channel", "transport",
        "stream", "group", "username", "color_tag", "enabled", "rtsp_path_override", "notes",
    ]

    /// Passwords cannot be supplied to this API and therefore cannot become a column accidentally.
    static func encode(_ cameras: [Camera], groupNames: [CameraID: String] = [:],
                       usernames: [CameraID: String] = [:]) -> Data {
        var lines = [header.joined(separator: ",")]
        lines += cameras.map { camera in
            [camera.name, camera.host, String(camera.httpPort), String(camera.rtspPort),
             String(camera.useTLS), String(camera.channel.value), camera.transport.rawValue,
             camera.preferredQuality?.stringValue ?? "", groupNames[camera.id] ?? "",
             usernames[camera.id] ?? "", camera.colorTag.rawValue, String(camera.isEnabled),
             camera.rtspPathOverride ?? "", ""]
                .map(field).joined(separator: ",")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    private static func field(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\r")
                || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
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
