//
//  LibraryMigrationTests.swift
//  VigilCoreTests
//
//  The schema chain: that it is complete, that each step does exactly what docs/spec-core.md §5.8
//  says, that a future document is refused, and that a schema-1 file loads through the store with
//  its cameras intact and a pre-migration snapshot on disk.
//  Covers Sources/VigilCore/Library/LibrarySchemaMigration.swift.
//

#if os(macOS)

import Foundation
import Testing
import VigilCore
import VigilProtocols

/// A deterministic handle factory, so "how many fresh refs did the migration mint, and which" is
/// assertable instead of random.
private struct LibraryMigrationRefCounter: Sendable {
    static func context(_ refs: [CredentialRef]) -> LibraryMigrationContext {
        let box = Box(refs)
        return LibraryMigrationContext(makeCredentialRef: { box.next() })
    }

    /// Hands out the prepared refs in order, then fresh ones.
    final class Box: @unchecked Sendable {
        // @unchecked is justified: every access is inside `lock`, which is the only other property.
        private let lock = NSLock()
        private var queue: [CredentialRef]

        init(_ refs: [CredentialRef]) { queue = refs }

        func next() -> CredentialRef {
            lock.lock()
            defer { lock.unlock() }
            return queue.isEmpty ? CredentialRef() : queue.removeFirst()
        }
    }
}

// MARK: - The chain itself

@Test func libraryMigrationChainCoversEveryVersionWithoutAGap() {
    #expect(LibrarySchemaMigrator.isChainComplete)
    for step in LibrarySchemaMigrator.steps {
        #expect(step.to == step.from + 1, "a step must never jump versions")
    }
    let versions = LibrarySchemaMigrator.steps.map(\.from)
    #expect(versions == versions.sorted(), "steps are registered in ascending order")
    #expect(Set(versions).count == versions.count, "no version has two steps")
    #expect(LibrarySchemaMigrator.steps.last?.to == LibraryDocument.currentSchemaVersion)
}

@Test func libraryMigrationLeavesACurrentDocumentAlone() throws {
    var document = LibraryDocument(cameras: [LibraryTestSupport.camera()])
    _ = document.normalize()
    let data = try LibraryCoding.makeEncoder().encode(document)

    var context = LibraryMigrationContext()
    let result = try LibrarySchemaMigrator.migrate(data, context: &context)
    #expect(result.applied.isEmpty)
    #expect(result.rekeyRequests.isEmpty)

    let decoded = try LibraryCoding.makeDecoder().decode(LibraryDocument.self, from: result.data)
    #expect(decoded.cameras == document.cameras)
}

@Test func libraryMigrationRefusesADocumentFromTheFuture() {
    let data = Data("{\"schemaVersion\": 42}".utf8)
    var context = LibraryMigrationContext()
    #expect(throws: StorageError.schemaTooNew(found: 42, supported: 3)) {
        try LibrarySchemaMigrator.migrate(data, context: &context)
    }
}

@Test func libraryMigrationRefusesANonObjectRoot() {
    var context = LibraryMigrationContext()
    #expect(throws: StorageError.notAnObject) {
        try LibrarySchemaMigrator.migrate(Data("[]".utf8), context: &context)
    }
}

@Test func libraryMigrationRefusesBytesThatAreNotJSON() {
    var context = LibraryMigrationContext()
    #expect(throws: StorageError.self) {
        try LibrarySchemaMigrator.migrate(Data("<?xml version=\"1.0\"?>".utf8), context: &context)
    }
}

@Test func libraryMigrationRefusesANonPositiveSchemaVersion() {
    var context = LibraryMigrationContext()
    #expect(throws: StorageError.self) {
        try LibrarySchemaMigrator.migrate(Data("{\"schemaVersion\": 0}".utf8), context: &context)
    }
}

// MARK: - 1 → 2

@Test func libraryMigrationOneToTwoSplitsThePortAndCanonicalisesDates() throws {
    let json = """
    {"schemaVersion": 1, "updatedAt": 1769438730,
     "cameras": [{"id": "E1A2B3C4-D5E6-4F70-8A9B-0C1D2E3F4A5B", "host": "192.168.1.64",
                  "port": 8000, "createdAt": 1769438730, "lastSeenAt": 1769438730,
                  "capabilities": {"rtspPathTemplate": "legacyH264", "probedAt": 1769438730}}]}
    """
    var context = LibraryMigrationContext()
    let result = try LibrarySchemaMigrator.migrate(Data(json.utf8), context: &context)
    #expect(result.applied == ["1→2", "2→3"])

    let root = try #require(try JSONSerialization.jsonObject(with: result.data) as? [String: Any])
    #expect(root["schemaVersion"] as? Int == 3)
    #expect(root["updatedAt"] as? String == LibraryTestSupport.epochISO)
    let cameras = try #require(root["cameras"] as? [[String: Any]])
    let camera = try #require(cameras.first)
    #expect(camera["httpPort"] as? Int == 8000, "the single legacy port becomes the ISAPI port")
    #expect(camera["rtspPort"] as? Int == 554, "and RTSP takes its default")
    #expect(camera["port"] == nil, "the legacy key is gone")
    #expect(camera["createdAt"] as? String == LibraryTestSupport.epochISO)
    #expect(camera["lastSeenAt"] as? String == LibraryTestSupport.epochISO)
    let capabilities = try #require(camera["capabilities"] as? [String: Any])
    #expect(capabilities["probedAt"] as? String == LibraryTestSupport.epochISO)

    // And the whole thing still decodes into the current model, which is the only real proof.
    let decoded = try LibraryCoding.makeDecoder().decode(LibraryDocument.self, from: result.data)
    #expect(decoded.cameras.first?.httpPort == 8000)
    #expect(decoded.cameras.first?.rtspPort == 554)
    #expect(decoded.cameras.first?.capabilities?.rtspPathTemplate == .legacyH264)
}

@Test func libraryMigrationOneToTwoKeepsAnExplicitHTTPPortOverTheLegacyOne() throws {
    let json = """
    {"schemaVersion": 1,
     "cameras": [{"id": "E1A2B3C4-D5E6-4F70-8A9B-0C1D2E3F4A5B", "host": "10.0.0.1",
                  "port": 8000, "httpPort": 80, "rtspPort": 10554}]}
    """
    var context = LibraryMigrationContext()
    let result = try LibrarySchemaMigrator.migrate(Data(json.utf8), context: &context)
    let decoded = try LibraryCoding.makeDecoder().decode(LibraryDocument.self, from: result.data)
    #expect(decoded.cameras.first?.httpPort == 80)
    #expect(decoded.cameras.first?.rtspPort == 10_554)
}

@Test func libraryMigrationOneToTwoDropsAnEntryThatIsNotAnObject() throws {
    let json = """
    {"schemaVersion": 1, "cameras": ["not a camera",
      {"id": "E1A2B3C4-D5E6-4F70-8A9B-0C1D2E3F4A5B", "host": "10.0.0.1"}]}
    """
    var context = LibraryMigrationContext()
    let result = try LibrarySchemaMigrator.migrate(Data(json.utf8), context: &context)
    let decoded = try LibraryCoding.makeDecoder().decode(LibraryDocument.self, from: result.data)
    #expect(decoded.cameras.count == 1)
    #expect(result.notes.contains { $0.contains("1 unreadable entries dropped") })
}

// MARK: - 2 → 3

@Test func libraryMigrationTwoToThreeMintsFreshHandlesAndReportsTheRekey() throws {
    let planted = CredentialRef()
    let json = """
    {"schemaVersion": 2,
     "cameras": [{"id": "E1A2B3C4-D5E6-4F70-8A9B-0C1D2E3F4A5B", "host": "192.168.1.64",
                  "credentialRef": "192.168.1.64:80:admin"}]}
    """
    var context = LibraryMigrationRefCounter.context([planted])
    let result = try LibrarySchemaMigrator.migrate(Data(json.utf8), context: &context)

    #expect(result.applied == ["2→3"])
    let decoded = try LibraryCoding.makeDecoder().decode(LibraryDocument.self, from: result.data)
    #expect(decoded.cameras.first?.credentialRef == planted)

    let request = try #require(result.rekeyRequests.first)
    #expect(result.rekeyRequests.count == 1)
    #expect(request.credentialRef == planted)
    #expect(request.host == "192.168.1.64")
    #expect(request.port == 80)
    #expect(request.account == "admin")

    // The username leaked into the schema-2 file; the schema-3 document must not carry it.
    let text = try #require(String(data: result.data, encoding: .utf8))
    #expect(!text.contains("admin"))
    #expect(!text.contains("192.168.1.64:80"))
}

@Test func libraryMigrationTwoToThreeLeavesAUUIDHandleUntouched() throws {
    let existing = CredentialRef()
    let json = """
    {"schemaVersion": 2,
     "cameras": [{"id": "E1A2B3C4-D5E6-4F70-8A9B-0C1D2E3F4A5B", "host": "10.0.0.1",
                  "credentialRef": "\(existing.rawValue.uuidString)"}]}
    """
    var context = LibraryMigrationContext()
    let result = try LibrarySchemaMigrator.migrate(Data(json.utf8), context: &context)
    let decoded = try LibraryCoding.makeDecoder().decode(LibraryDocument.self, from: result.data)
    #expect(decoded.cameras.first?.credentialRef == existing)
    #expect(result.rekeyRequests.isEmpty)
}

@Test func libraryMigrationCompositeHandleSplitsOnTheLastTwoColons() throws {
    // An IPv6 host is written with brackets in the legacy form and contains colons of its own.
    let json = """
    {"schemaVersion": 2,
     "cameras": [{"id": "E1A2B3C4-D5E6-4F70-8A9B-0C1D2E3F4A5B", "host": "fe80::1",
                  "credentialRef": "[fe80::1]:8000:operator"}]}
    """
    var context = LibraryMigrationContext()
    let result = try LibrarySchemaMigrator.migrate(Data(json.utf8), context: &context)
    let request = try #require(result.rekeyRequests.first)
    #expect(request.host == "[fe80::1]")
    #expect(request.port == 8000)
    #expect(request.account == "operator")
}

@Test func libraryMigrationCostsOneCameraItsPasswordForAnUnusableHandleNotTheWholeLibrary() throws {
    let json = """
    {"schemaVersion": 2,
     "cameras": [{"id": "E1A2B3C4-D5E6-4F70-8A9B-0C1D2E3F4A5B", "host": "10.0.0.1",
                  "credentialRef": "nonsense"},
                 {"id": "B2C3D4E5-F6A7-4B80-9C1D-2E3F4A5B6C7D", "host": "10.0.0.2",
                  "credentialRef": "5C6E8A10-77F1-4E20-8E4C-9A0B1C2D3E4F"}]}
    """
    var context = LibraryMigrationContext()
    let result = try LibrarySchemaMigrator.migrate(Data(json.utf8), context: &context)
    // Inventing a handle for an unparseable value would orphan a Keychain item silently, so no
    // rekey is reported: this camera simply has no saved password any more.
    #expect(result.rekeyRequests.isEmpty)

    let decoded = try LibraryCoding.makeDecoder().decode(LibraryDocument.self, from: result.data)
    #expect(decoded.cameras.count == 2, "one bad handle must not take the library down")
    #expect(decoded.cameras.last?.credentialRef.rawValue.uuidString
        == "5C6E8A10-77F1-4E20-8E4C-9A0B1C2D3E4F", "the good handle is untouched")
    let salvaged = try #require(decoded.cameras.first)
    #expect(salvaged.host == "10.0.0.1")
    #expect(salvaged.credentialRef != decoded.cameras.last?.credentialRef)
}

@Test func libraryMigrationTwoToThreeConvertsLayoutCellsIntoAssignments() throws {
    let json = """
    {"schemaVersion": 2, "cameras": [],
     "layouts": [{"id": "9D1F8C2A-2B41-4E6B-9C7B-1A2B3C4D5E6F", "name": "2x2",
                  "cells": {"3": "AAAA1111-0000-4000-8000-000000000003",
                            "0": "AAAA1111-0000-4000-8000-000000000000",
                            "bogus": "AAAA1111-0000-4000-8000-00000000000B"}}]}
    """
    var context = LibraryMigrationContext()
    let result = try LibrarySchemaMigrator.migrate(Data(json.utf8), context: &context)

    let root = try #require(try JSONSerialization.jsonObject(with: result.data) as? [String: Any])
    let layouts = try #require(root["layouts"] as? [[String: Any]])
    let layout = try #require(layouts.first)
    #expect(layout["cells"] == nil)
    let assignments = try #require(layout["assignments"] as? [[String: Any]])
    #expect(assignments.count == 2, "a cell index that is not an integer cannot be drawn")
    #expect(assignments.map { $0["cellIndex"] as? Int } == [0, 3], "ascending by cell index")
    #expect(assignments.first?["cameraID"] as? String == "AAAA1111-0000-4000-8000-000000000000")
    #expect(result.notes.contains { $0.contains("1 layouts converted") })
}

// MARK: - Through the store

@Test func libraryMigrationOfASchemaOneFileLoadsWithEveryCameraIntact() async throws {
    let directory = LibraryTestSupport.temporaryDirectory()
    let json = """
    {"schemaVersion": 1, "generatedBy": "Vigil 0.3", "updatedAt": 1769438730,
     "cameras": [
       {"id": "E1A2B3C4-D5E6-4F70-8A9B-0C1D2E3F4A5B", "host": "192.168.1.64", "name": "Front Door",
        "port": 80, "createdAt": 1769438730,
        "credentialRef": "5C6E8A10-77F1-4E20-8E4C-9A0B1C2D3E4F",
        "capabilities": {"rtspPathTemplate": "streamingChannelsWithQuality",
                         "resolvedRTSPPath": "/Streaming/Channels/101", "probedAt": 1769438730}},
       {"id": "B2C3D4E5-F6A7-4B80-9C1D-2E3F4A5B6C7D", "host": "192.168.1.65", "name": "Garage",
        "port": 8000, "channel": 2, "createdAt": 1769438730}]}
    """
    let file = directory.appendingPathComponent("library.json")
    LibraryTestSupport.write(json, to: file)
    let before = try #require(LibraryTestSupport.text(at: file))

    let outcome = await LibraryTestSupport.makeStore(in: directory).load()
    guard case let .loaded(document, applied, rekey) = outcome else {
        Issue.record("expected .loaded, got \(outcome)")
        return
    }
    #expect(applied == ["1→2", "2→3"])
    #expect(rekey.isEmpty, "these handles were already UUIDs")
    #expect(document.cameras.map(\.name) == ["Front Door", "Garage"])
    #expect(document.cameras.first?.httpPort == 80)
    #expect(document.cameras.last?.httpPort == 8000)
    #expect(document.cameras.first?.capabilities?.resolvedRTSPPath == "/Streaming/Channels/101")
    #expect(document.cameras.first?.credentialRef.rawValue.uuidString
        == "5C6E8A10-77F1-4E20-8E4C-9A0B1C2D3E4F", "the Keychain handle must survive a migration")

    // The original bytes are kept, and the file itself is not touched until something is saved.
    let names = LibraryTestSupport.contents(of: directory)
    let snapshot = try #require(names.first { $0.hasPrefix("library.json.premigration-") })
    #expect(snapshot == "library.json.premigration-v1-20260126T144530Z")
    #expect(LibraryTestSupport.text(at: directory.appendingPathComponent(snapshot)) == before)
    #expect(LibraryTestSupport.text(at: file) == before, "a load never rewrites the document")
}

@Test func libraryMigrationAbandonsTheMigrationWhenTheResultWouldNotDecode() async throws {
    // A schema-1 camera with no `host` cannot become a valid record; the migrated document must fail
    // its validating decode, the original file must be left alone, and recovery must take over.
    let directory = LibraryTestSupport.temporaryDirectory()
    let json = """
    {"schemaVersion": 1, "cameras": [{"id": "E1A2B3C4-D5E6-4F70-8A9B-0C1D2E3F4A5B", "port": 80}]}
    """
    let file = directory.appendingPathComponent("library.json")
    LibraryTestSupport.write(json, to: file)

    let outcome = await LibraryTestSupport.makeStore(in: directory).load()
    guard case let .recovered(document, source, _) = outcome else {
        Issue.record("expected .recovered, got \(outcome)")
        return
    }
    #expect(source == .freshStart)
    #expect(document.cameras.isEmpty)
    let quarantined = LibraryTestSupport.contents(of: directory)
        .filter { $0.hasPrefix("library.json.corrupt-") }
    #expect(quarantined.count == 1, "the evidence is kept")
}

// MARK: - Credential handle shape

@Test func libraryMigrationAcceptsTheSpecDocumentedBareStringCredentialRef() throws {
    // docs/spec-core.md §5.2's sample library writes `"credentialRef" : "<UUID>"`, while
    // `VigilProtocols.CredentialRef` currently takes Swift's synthesised Codable and writes
    // `{"rawValue": "<UUID>"}`. Both must load, or a hand-edited or spec-shaped file costs the
    // customer their saved password.
    let uuid = "5C6E8A10-77F1-4E20-8E4C-9A0B1C2D3E4F"
    let json = """
    {"schemaVersion": 3,
     "cameras": [{"id": "E1A2B3C4-D5E6-4F70-8A9B-0C1D2E3F4A5B", "host": "192.168.1.64",
                  "credentialRef": "\(uuid)"}]}
    """
    var context = LibraryMigrationContext()
    let result = try LibrarySchemaMigrator.migrate(Data(json.utf8), context: &context)
    let decoded = try LibraryCoding.makeDecoder().decode(LibraryDocument.self, from: result.data)
    #expect(decoded.cameras.first?.credentialRef.rawValue.uuidString == uuid)
}

@Test func libraryMigrationAcceptsTheObjectFormCredentialRef() throws {
    let uuid = "5C6E8A10-77F1-4E20-8E4C-9A0B1C2D3E4F"
    let json = """
    {"schemaVersion": 3,
     "cameras": [{"id": "E1A2B3C4-D5E6-4F70-8A9B-0C1D2E3F4A5B", "host": "192.168.1.64",
                  "credentialRef": {"rawValue": "\(uuid)"}}]}
    """
    var context = LibraryMigrationContext()
    let result = try LibrarySchemaMigrator.migrate(Data(json.utf8), context: &context)
    let decoded = try LibraryCoding.makeDecoder().decode(LibraryDocument.self, from: result.data)
    #expect(decoded.cameras.first?.credentialRef.rawValue.uuidString == uuid)
}

@Test func libraryMigrationKeepsTheCredentialHandleAcrossSaveAndReload() async throws {
    // The end-to-end property the two tests above exist for: whatever shape this build writes, the
    // handle that comes back is the handle that went in.
    let directory = LibraryTestSupport.temporaryDirectory()
    let store = LibraryTestSupport.makeStore(in: directory)
    let ref = CredentialRef()
    _ = try await store.save(LibraryDocument(cameras: [LibraryTestSupport.camera(
        credentialRef: ref)]))

    let outcome = await LibraryTestSupport.makeStore(in: directory).load()
    #expect(outcome.document.cameras.first?.credentialRef == ref)
}

#endif
