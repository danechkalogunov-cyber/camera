//
//  LibrarySecretAbsenceTests.swift
//  VigilCoreTests
//
//  Proof, rather than assertion, that no credential can reach `library.json`: a fully populated
//  library is encoded and written to a real file, and the bytes are searched for the secret.
//  Covers docs/API_CONTRACT.md §2 R-14 and docs/spec-core.md §6.1, and the checklist line in
//  docs/API_CONTRACT.md §6 ("secret-absence test green over library.json").
//

#if os(macOS)

import Foundation
import Testing
import VigilCore
import VigilProtocols

/// The strings that must never appear in the document. Deliberately distinctive, so a substring
/// search cannot pass by accident.
private enum LibrarySecretFixture {
    static let password = "hunter2-Correct-Horse-Battery"
    static let account = "installer-account-name"
    static let secondPassword = "second-camera-P4ssw0rd"
}

@Test func librarySecretAbsenceEncodedDocumentContainsNoSecret() throws {
    // Build the credentials first, exactly as the connect flow does, so the secrets are genuinely
    // live in this process while the document is encoded.
    let firstCredential = Credential(account: LibrarySecretFixture.account,
                                     secret: LibrarySecretFixture.password)
    let secondCredential = Credential(account: LibrarySecretFixture.account,
                                      secret: LibrarySecretFixture.secondPassword)

    let first = LibraryTestSupport.camera(name: "Front Door",
                                          host: "192.168.1.64",
                                          credentialRef: firstCredential.ref,
                                          capabilities: DeviceCapabilities(
                                              rtspPathTemplate: .streamingChannelsWithQuality,
                                              resolvedRTSPPath: "/Streaming/Channels/101",
                                              videoCodec: .h265,
                                              probedAt: LibraryTestSupport.epoch,
                                              firmwareVersion: "V5.6.3 build 190923"),
                                          lastSeenAt: LibraryTestSupport.epoch)
    let second = LibraryTestSupport.camera(name: "Garage",
                                           host: "192.168.1.65",
                                           channel: 2,
                                           credentialRef: secondCredential.ref)

    var document = LibraryDocument(generatedBy: "Vigil test",
                                   updatedAt: LibraryTestSupport.epoch,
                                   cameras: [first, second],
                                   channelInventories: [LibraryTestSupport.inventory(for: first,
                                                                                    count: 4)],
                                   didImportLegacyConnection: true)
    _ = document.normalize()

    let data = try LibraryCoding.makeEncoder().encode(document)
    let text = try #require(String(data: data, encoding: .utf8))

    #expect(!text.contains(LibrarySecretFixture.password))
    #expect(!text.contains(LibrarySecretFixture.secondPassword))
    #expect(!text.contains(LibrarySecretFixture.account))
    #expect(!text.lowercased().contains("password"))
    #expect(!text.lowercased().contains("secret"))
    #expect(!text.contains("@"), "a userinfo-bearing URL is the other way a password leaks")

    // The opaque handle, on the other hand, MUST be there: it is what keeps the customer's existing
    // Keychain item reachable after an upgrade.
    #expect(text.contains(firstCredential.ref.rawValue.uuidString))
    #expect(text.contains(secondCredential.ref.rawValue.uuidString))
}

@Test func librarySecretAbsenceSavedFileContainsNoSecret() async throws {
    let directory = LibraryTestSupport.temporaryDirectory()
    let store = LibraryTestSupport.makeStore(in: directory)
    let library = LibraryTestSupport.makeLibrary(store: store)
    _ = await library.load()

    let credential = Credential(account: LibrarySecretFixture.account,
                                secret: LibrarySecretFixture.password)
    let camera = LibraryTestSupport.camera(name: LibrarySecretFixture.account.isEmpty ? "x" : "Hall",
                                           host: "192.168.1.64",
                                           credentialRef: credential.ref)
    _ = try await library.add(camera)
    try await library.recordChannelInventory(
        LibraryTestSupport.inventory(for: camera, count: 3))
    try await library.flush()

    // Every file the store may have produced, not only the document: a backup or a quarantine copy
    // of a leaked secret is just as leaked.
    let names = LibraryTestSupport.contents(of: directory)
    #expect(names.contains("library.json"))
    for name in names {
        let bytes = try #require(try? Data(contentsOf: directory.appendingPathComponent(name)))
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(!text.contains(LibrarySecretFixture.password), "secret found in \(name)")
        #expect(!text.contains(LibrarySecretFixture.account), "account found in \(name)")
    }
}

@Test func librarySecretAbsenceCredentialCannotBeSerialisedAtAll() {
    // The structural guarantee behind the two tests above: `Credential` has no `Codable`
    // conformance, so no encoder anywhere can reach it — not through a container, not through
    // `Any`, not through a future field someone adds to `Camera` without thinking.
    #expect(!LibraryTestSupport.isCodable(Credential.self))

    // The handle, by contrast, is Codable — that asymmetry is the design.
    #expect(LibraryTestSupport.isCodable(CredentialRef.self))
    #expect(LibraryTestSupport.isCodable(Camera.self))
    #expect(LibraryTestSupport.isCodable(LibraryDocument.self))
}

@Test func librarySecretAbsenceCredentialDescriptionMasksTheSecret() {
    let credential = Credential(account: LibrarySecretFixture.account,
                                secret: LibrarySecretFixture.password)
    #expect(!credential.description.contains(LibrarySecretFixture.password))
    #expect(!credential.debugDescription.contains(LibrarySecretFixture.password))
    #expect(!"\(credential)".contains(LibrarySecretFixture.password))
}

@Test func librarySecretAbsenceDocumentHasOnlyTheSixExpectedTopLevelKeys() throws {
    // A new top-level key is exactly where a secret would arrive unnoticed, so the set is pinned.
    let data = try LibraryCoding.makeEncoder().encode(LibraryDocument())
    #expect(LibraryTestSupport.topLevelKeys(data) == ["cameras", "channelInventories",
                                                      "didImportLegacyConnection", "generatedBy",
                                                      "schemaVersion", "updatedAt"])
}

#endif
