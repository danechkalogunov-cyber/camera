//
//  CredentialStoreKeychainModeTests.swift
//  VigilCoreTests
//
//  Which keychain CredentialStore asks for. A shipping build uses the data-protection keychain; the
//  unsandboxed dev build is signed ad-hoc, has no Team ID, and so cannot use it at all — it must
//  fall back to the legacy file keychain, which needs no access group. These tests pin that choice
//  to the presence of `kSecUseDataProtectionKeychain` in the dictionaries the store hands to the
//  Keychain seam, on both a read and a write.
//

#if os(macOS)

import Foundation
import Security
import Testing
import VigilCore
import VigilProtocols

/// A `KeychainProtocol` double that records every dictionary the store passes it and answers a
/// benign status, so a test can read back exactly what was requested.
private final class RecordingKeychain: KeychainProtocol, @unchecked Sendable {

    private let lock = NSLock()
    private var dicts: [[String: Any]] = []

    /// Every query or attribute dictionary handed over, in call order.
    var recorded: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return dicts
    }

    /// True when at least one recorded dictionary asked for the data-protection keychain.
    var everRequestedDataProtection: Bool {
        recorded.contains { $0[kSecUseDataProtectionKeychain as String] != nil }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        record(attributes)
        return errSecSuccess
    }

    func copyMatching(_ query: [String: Any], _ result: inout CFTypeRef?) -> OSStatus {
        record(query)
        return errSecItemNotFound
    }

    func update(_ query: [String: Any], _ attributesToUpdate: [String: Any]) -> OSStatus {
        record(query)
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        record(query)
        return errSecSuccess
    }

    private func record(_ dict: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        dicts.append(dict)
    }
}

@Suite("Credential store keychain mode")
struct CredentialStoreKeychainModeTests {

    @Test func theShippingStoreRequestsTheDataProtectionKeychain() async throws {
        let keychain = RecordingKeychain()
        let store = CredentialStore(keychain: keychain)  // default: data protection on
        _ = try await store.credential(for: CredentialRef())
        #expect(keychain.everRequestedDataProtection)
    }

    @Test func theDevBuildStoreFallsBackToTheLegacyKeychain() async throws {
        let keychain = RecordingKeychain()
        let store = CredentialStore(keychain: keychain, useDataProtectionKeychain: false)
        _ = try await store.credential(for: CredentialRef())
        #expect(!keychain.everRequestedDataProtection)
    }

    /// The flag governs writes as well as reads: an item saved under the dev build carries no
    /// data-protection request either, so it lands in the same legacy keychain the reads use.
    @Test func aSaveUnderTheDevBuildAlsoAvoidsDataProtection() async throws {
        let keychain = RecordingKeychain()
        let store = CredentialStore(keychain: keychain, useDataProtectionKeychain: false)
        let ref = CredentialRef()
        let credential = Credential(ref: ref, account: "admin", secret: "placeholder-not-a-secret")
        let descriptor = CredentialDescriptor(
            ref: ref, host: "192.0.2.10", port: 80, useTLS: false, account: "admin",
            label: "Vigil — Test (192.0.2.10)")
        try await store.save(credential, descriptor: descriptor)
        #expect(!keychain.everRequestedDataProtection)
    }
}

#endif  // os(macOS)
