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
