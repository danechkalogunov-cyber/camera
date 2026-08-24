#if os(macOS)

import Foundation
import Testing
import VigilCore
import VigilProtocols
@testable import Vigil

@Suite struct EncryptedConfigurationCodecTests {
    @Test func deterministicContainerRoundTripsAndAuthenticatesHeader() throws {
        // ⛔ A fixed `createdAt`, because the round-trip has to be deterministic and equal. The
        // backup's date strategy is `.iso8601`, which writes whole seconds, so a camera left with the
        // default `createdAt: Date()` loses its sub-second fraction on decode and the restored value
        // no longer equals the original — a false failure about the clock, not the codec.
        let camera = try Camera(
            name: "Gate", host: "192.168.1.40",
            createdAt: Date(timeIntervalSince1970: 1_000)).validated()
        let payload = EncryptedConfigurationPayload(
            archive: VigilConfigurationArchive(exportedAt: Date(timeIntervalSince1970: 1_000),
                                                 cameras: [camera], groups: []),
            credentials: [.init(cameraID: camera.id, ref: camera.credentialRef,
                                account: "admin", secret: "camera-secret")])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let plaintext = try encoder.encode(payload)
        let salt = Data((0..<16).map(UInt8.init))
        let nonce = Data((16..<28).map(UInt8.init))
        let encoded = try EncryptedConfigurationCodec.encode(
            plaintext, passphrase: "correct horse battery", iterations: 100_000,
            salt: salt, nonce: nonce)

        #expect(Data(encoded.prefix(8)) == Data("VIGILBK1".utf8))
        #expect(try EncryptedConfigurationCodec.decode(
            encoded, passphrase: "correct horse battery") == payload)

        var damaged = encoded
        damaged[32] ^= 1
        #expect(throws: EncryptedConfigurationCodec.Failure.self) {
            try EncryptedConfigurationCodec.decode(damaged,
                                                    passphrase: "correct horse battery")
        }
    }

    @Test func shortPassphraseIsRefusedBeforeEncryption() {
        let payload = EncryptedConfigurationPayload(
            archive: VigilConfigurationArchive(cameras: [], groups: []), credentials: [])
        #expect(throws: EncryptedConfigurationCodec.Failure.weakPassphrase) {
            try EncryptedConfigurationCodec.encode(payload, passphrase: "too short")
        }
    }

    @Test func wrongPassphraseAndMalformedContainerAreDistinct() throws {
        let payload = EncryptedConfigurationPayload(
            archive: VigilConfigurationArchive(cameras: [], groups: []), credentials: [])
        let encoded = try EncryptedConfigurationCodec.encode(
            payload, passphrase: "correct horse battery")

        #expect(throws: EncryptedConfigurationCodec.Failure.wrongPassphrase) {
            try EncryptedConfigurationCodec.decode(encoded,
                                                    passphrase: "different horse battery")
        }
        var malformed = encoded
        malformed[10] = 99
        #expect(throws: EncryptedConfigurationCodec.Failure.damaged) {
            try EncryptedConfigurationCodec.decode(malformed,
                                                    passphrase: "correct horse battery")
        }
    }

    @Test func credentialMustBelongToItsCameraAndReference() throws {
        let camera = try Camera(name: "Gate", host: "192.168.1.40").validated()
        let payload = EncryptedConfigurationPayload(
            archive: VigilConfigurationArchive(cameras: [camera], groups: []),
            credentials: [.init(cameraID: camera.id, ref: CredentialRef(),
                                account: "admin", secret: "secret")])
        let encoded = try EncryptedConfigurationCodec.encode(
            payload, passphrase: "correct horse battery")
        #expect(throws: EncryptedConfigurationCodec.Failure.damaged) {
            try EncryptedConfigurationCodec.decode(encoded,
                                                    passphrase: "correct horse battery")
        }
    }
}

#endif
