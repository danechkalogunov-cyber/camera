//
//  LibraryStoreTests.swift
//  VigilCoreTests
//
//  The atomic write, the backup rotation, the corruption-recovery ladder and the read-only forward
//  guard — exercised against a real directory, because a persistence layer whose write path is
//  mocked is a persistence layer nobody has tested.
//  Covers Sources/VigilCore/Library/LibraryStore.swift and docs/spec-core.md §5.5, §5.9.
//

#if os(macOS)

import Foundation
import Testing
import VigilCore
import VigilProtocols

// MARK: - First run and round trip

@Test func libraryStoreFirstLoadCreatesAnEmptyDocumentAndWritesNothing() async {
    let directory = LibraryTestSupport.temporaryDirectory()
    let store = LibraryTestSupport.makeStore(in: directory)

    let outcome = await store.load()
    guard case let .created(document) = outcome else {
        Issue.record("expected .created, got \(outcome)")
        return
    }
    #expect(document.cameras.isEmpty)
    #expect(document.schemaVersion == LibraryDocument.currentSchemaVersion)
    #expect(LibraryTestSupport.contents(of: directory) == [],
            "a load must never write; the first mutation does")
}

@Test func libraryStoreSaveThenLoadRoundTripsTheDocument() async throws {
    let directory = LibraryTestSupport.temporaryDirectory()
    let store = LibraryTestSupport.makeStore(in: directory)
    let camera = LibraryTestSupport.camera(name: "Front Door", host: "192.168.1.64")
    var document = LibraryDocument(cameras: [camera])
    _ = document.normalize()

    #expect(try await store.save(document))

    let reloaded = await LibraryTestSupport.makeStore(in: directory).load()
    guard case let .loaded(loaded, applied, rekey) = reloaded else {
        Issue.record("expected .loaded, got \(reloaded)")
        return
    }
    #expect(loaded.cameras.map(\.id) == [camera.id])
    #expect(loaded.updatedAt == LibraryTestSupport.epoch, "the store stamps updatedAt on write")
    #expect(loaded.generatedBy == "Vigil test")
    #expect(applied.isEmpty)
    #expect(rekey.isEmpty)
}

@Test func libraryStoreSaveLeavesNoTemporaryFileBehind() async throws {
    let directory = LibraryTestSupport.temporaryDirectory()
    let store = LibraryTestSupport.makeStore(in: directory)
    _ = try await store.save(LibraryDocument(cameras: [LibraryTestSupport.camera()]))

    #expect(LibraryTestSupport.contents(of: directory) == ["library.json"])
}

@Test func libraryStoreSkipsTheWriteWhenTheContentIsUnchanged() async throws {
    let directory = LibraryTestSupport.temporaryDirectory()
    let store = LibraryTestSupport.makeStore(in: directory)
    let document = LibraryDocument(cameras: [LibraryTestSupport.camera()])

    #expect(try await store.save(document) == true)
    #expect(try await store.save(document) == false,
            "identical content must not touch the disk, or a slider drag rewrites the file")
    #expect(LibraryTestSupport.contents(of: directory) == ["library.json"],
            "a skipped write must not rotate a backup either")

    var changed = document
    changed.cameras[0].name = "Renamed"
    #expect(try await store.save(changed) == true)
}

@Test func libraryStoreWriteCacheCanBeInvalidated() async throws {
    let directory = LibraryTestSupport.temporaryDirectory()
    let store = LibraryTestSupport.makeStore(in: directory)
    let document = LibraryDocument(cameras: [LibraryTestSupport.camera()])
    #expect(try await store.save(document))
    await store.invalidateWriteCache()
    #expect(try await store.save(document), "an invalidated cache must write again")
}

// MARK: - Backup rotation

@Test func libraryStoreRotatesTwoBackupGenerations() async throws {
    let directory = LibraryTestSupport.temporaryDirectory()
    let store = LibraryTestSupport.makeStore(in: directory)

    for name in ["one", "two", "three"] {
        var document = LibraryDocument(cameras: [LibraryTestSupport.camera(name: name)])
        _ = document.normalize()
        #expect(try await store.save(document))
    }

    #expect(LibraryTestSupport.contents(of: directory) == ["library.json", "library.json.bak",
                                                          "library.json.bak2"])
    let current = try #require(LibraryTestSupport.text(at:
        directory.appendingPathComponent("library.json")))
    let backup = try #require(LibraryTestSupport.text(at:
        directory.appendingPathComponent("library.json.bak")))
    let second = try #require(LibraryTestSupport.text(at:
        directory.appendingPathComponent("library.json.bak2")))
    #expect(current.contains("three"))
    #expect(backup.contains("two"))
    #expect(second.contains("one"))
}

@Test func libraryStoreHonoursBackupGenerationCountOfZero() async throws {
    let directory = LibraryTestSupport.temporaryDirectory()
    let store = LibraryStore(directory: directory,
                             options: LibraryStore.Options(backupGenerations: 0,
                                                           generatedBy: "Vigil test"),
                             wallClock: LibraryTestSupport.FixedWallClock(
                                 instant: LibraryTestSupport.epoch))
    for name in ["one", "two"] {
        _ = try await store.save(LibraryDocument(cameras: [LibraryTestSupport.camera(name: name)]))
    }
    #expect(LibraryTestSupport.contents(of: directory) == ["library.json"])
}

// MARK: - Recovery ladder

@Test func libraryStoreRecoversFromTheBackupWhenTheDocumentIsCorrupt() async throws {
    let directory = LibraryTestSupport.temporaryDirectory()
    let store = LibraryTestSupport.makeStore(in: directory)
    let good = LibraryTestSupport.camera(name: "Front Door")
    _ = try await store.save(LibraryDocument(cameras: [good]))
    _ = try await store.save(LibraryDocument(cameras: [good, LibraryTestSupport.camera(
        name: "Garage", host: "10.0.0.2")]))

    // Truncate the document the way an interrupted write on a lesser design would.
    LibraryTestSupport.write("{\"schemaVersion\": 3, \"cameras\": [{\"id\"",
                            to: directory.appendingPathComponent("library.json"))

    let outcome = await LibraryTestSupport.makeStore(in: directory).load()
    guard case let .recovered(document, source, error) = outcome else {
        Issue.record("expected .recovered, got \(outcome)")
        return
    }
    #expect(source == .backup)
    #expect(document.recoveredFrom == .backup)
    #expect(document.cameras.map(\.name) == ["Front Door"])
    #expect(error.diagnosticCode == "VG-STOR-0002")

    let names = LibraryTestSupport.contents(of: directory)
    #expect(names.contains { $0.hasPrefix("library.json.corrupt-") },
            "the unreadable file is quarantined, never deleted")
    #expect(!names.contains("library.json"), "recovery does not rewrite; the first mutation does")
}

@Test func libraryStoreQuarantineKeepsTheUnreadableBytes() async {
    let directory = LibraryTestSupport.temporaryDirectory()
    let poison = "{ this is not json at all"
    LibraryTestSupport.write(poison, to: directory.appendingPathComponent("library.json"))

    _ = await LibraryTestSupport.makeStore(in: directory).load()

    let quarantined = LibraryTestSupport.contents(of: directory)
        .filter { $0.hasPrefix("library.json.corrupt-") }
    #expect(quarantined.count == 1)
    let name = quarantined.first ?? ""
    #expect(name == "library.json.corrupt-20260126T144530Z", "the name is stamped from the clock")
    #expect(LibraryTestSupport.text(at: directory.appendingPathComponent(name)) == poison)
}

@Test func libraryStoreRecoversFromTheBackupWhenTheDocumentIsMissing() async throws {
    // Deliberate deviation from spec-core §5.9, documented in LibraryStore.load(): a deleted
    // document with a surviving backup is recovered rather than reported as a first run, because
    // "your camera list is empty" is the worst outcome this module can produce.
    let directory = LibraryTestSupport.temporaryDirectory()
    let store = LibraryTestSupport.makeStore(in: directory)
    let camera = LibraryTestSupport.camera(name: "Front Door")
    _ = try await store.save(LibraryDocument(cameras: [camera]))
    _ = try await store.save(LibraryDocument(cameras: [camera,
                                                      LibraryTestSupport.camera(host: "10.0.0.2")]))
    try FileManager.default.removeItem(at: directory.appendingPathComponent("library.json"))

    let outcome = await LibraryTestSupport.makeStore(in: directory).load()
    guard case let .recovered(document, source, _) = outcome else {
        Issue.record("expected .recovered, got \(outcome)")
        return
    }
    #expect(source == .backup)
    #expect(document.cameras.count == 1)
}

@Test func libraryStoreFallsBackToTheSecondGeneration() async throws {
    let directory = LibraryTestSupport.temporaryDirectory()
    let store = LibraryTestSupport.makeStore(in: directory)
    for name in ["one", "two", "three"] {
        _ = try await store.save(LibraryDocument(cameras: [LibraryTestSupport.camera(name: name)]))
    }
    for name in ["library.json", "library.json.bak"] {
        LibraryTestSupport.write("garbage", to: directory.appendingPathComponent(name))
    }

    let outcome = await LibraryTestSupport.makeStore(in: directory).load()
    guard case let .recovered(document, source, _) = outcome else {
        Issue.record("expected .recovered, got \(outcome)")
        return
    }
    #expect(source == .secondBackup)
    #expect(document.cameras.first?.name == "one")
}

@Test func libraryStoreStartsEmptyWhenEveryGenerationIsUnreadable() async {
    let directory = LibraryTestSupport.temporaryDirectory()
    for name in ["library.json", "library.json.bak", "library.json.bak2"] {
        LibraryTestSupport.write("not json", to: directory.appendingPathComponent(name))
    }

    let outcome = await LibraryTestSupport.makeStore(in: directory).load()
    guard case let .recovered(document, source, _) = outcome else {
        Issue.record("expected .recovered, got \(outcome)")
        return
    }
    #expect(source == .freshStart)
    #expect(document.cameras.isEmpty)
    #expect(document.recoveredFrom == .freshStart)
}

@Test func libraryStoreTreatsAnEmptyFileAsCorrupt() async {
    let directory = LibraryTestSupport.temporaryDirectory()
    LibraryTestSupport.write("", to: directory.appendingPathComponent("library.json"))

    let outcome = await LibraryTestSupport.makeStore(in: directory).load()
    guard case let .recovered(_, source, error) = outcome else {
        Issue.record("expected .recovered, got \(outcome)")
        return
    }
    #expect(source == .freshStart)
    #expect(error == .corruptDocument("empty file"))
}

@Test func libraryStoreRefusesADocumentOverTheSizeCap() async {
    let directory = LibraryTestSupport.temporaryDirectory()
    let filler = String(repeating: "x", count: 400)
    LibraryTestSupport.write("{\"schemaVersion\":3,\"generatedBy\":\"\(filler)\"}",
                             to: directory.appendingPathComponent("library.json"))
    let store = LibraryStore(directory: directory,
                             options: LibraryStore.Options(maxDocumentBytes: 64,
                                                           generatedBy: "Vigil test"),
                             wallClock: LibraryTestSupport.FixedWallClock(
                                 instant: LibraryTestSupport.epoch))

    let outcome = await store.load()
    guard case let .recovered(_, source, error) = outcome else {
        Issue.record("expected .recovered, got \(outcome)")
        return
    }
    #expect(source == .freshStart)
    if case let .documentTooLarge(bytes) = error {
        #expect(bytes > 64)
    } else {
        Issue.record("expected .documentTooLarge, got \(error)")
    }
}

@Test func libraryStoreTreatsANonObjectRootAsCorrupt() async {
    let directory = LibraryTestSupport.temporaryDirectory()
    LibraryTestSupport.write("[1, 2, 3]", to: directory.appendingPathComponent("library.json"))
    let outcome = await LibraryTestSupport.makeStore(in: directory).load()
    guard case let .recovered(_, _, error) = outcome else {
        Issue.record("expected .recovered, got \(outcome)")
        return
    }
    #expect(error == .notAnObject)
}

// MARK: - Forward guard

@Test func libraryStoreOpensAFutureSchemaReadOnlyAndRefusesToWriteIt() async throws {
    let directory = LibraryTestSupport.temporaryDirectory()
    let json = """
    {"schemaVersion": 99, "generatedBy": "Vigil 9.0", "updatedAt": "2027-01-01T00:00:00Z",
     "cameras": [{"id": "E1A2B3C4-D5E6-4F70-8A9B-0C1D2E3F4A5B", "host": "192.168.1.64",
                  "name": "From the future"}]}
    """
    let file = directory.appendingPathComponent("library.json")
    LibraryTestSupport.write(json, to: file)
    let before = try #require(LibraryTestSupport.text(at: file))

    let store = LibraryTestSupport.makeStore(in: directory)
    let outcome = await store.load()
    guard case let .readOnly(document, version) = outcome else {
        Issue.record("expected .readOnly, got \(outcome)")
        return
    }
    #expect(version == 99)
    #expect(document.isReadOnly)
    #expect(document.cameras.first?.name == "From the future",
            "the user still sees their cameras; they just cannot be changed")

    await #expect(throws: StorageError.schemaTooNew(found: 99, supported: 3)) {
        try await store.save(document)
    }
    #expect(LibraryTestSupport.text(at: file) == before, "not one byte may change")
    #expect(!LibraryTestSupport.contents(of: directory).contains { $0.contains("corrupt") },
            "a future document is not corrupt and must never be quarantined")
}

// MARK: - Forward compatibility

@Test func libraryStorePreservesUnknownTopLevelKeysAcrossASave() async throws {
    // The data-loss case this guards: a later build writes `layouts`, the user then runs a build
    // that has never heard of them, renames a camera — and the layouts must still be there.
    let directory = LibraryTestSupport.temporaryDirectory()
    let json = """
    {"schemaVersion": 3, "generatedBy": "Vigil 1.1", "updatedAt": "\(LibraryTestSupport.epochISO)",
     "cameras": [{"id": "E1A2B3C4-D5E6-4F70-8A9B-0C1D2E3F4A5B", "host": "192.168.1.64"}],
     "groups": [{"id": "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0", "name": "Upstairs"}],
     "settings": {"launchAtLogin": true}}
    """
    LibraryTestSupport.write(json, to: directory.appendingPathComponent("library.json"))

    let store = LibraryTestSupport.makeStore(in: directory)
    let outcome = await store.load()
    var document = outcome.document
    #expect(document.hadUnknownContent)
    #expect(document.unknownContent != nil)

    document.cameras[0].name = "Renamed by an older build"
    #expect(try await store.save(document))

    let reloadedText = try #require(LibraryTestSupport.text(at:
        directory.appendingPathComponent("library.json")))
    #expect(reloadedText.contains("\"Upstairs\""), "an unknown key must survive our save")
    #expect(reloadedText.contains("launchAtLogin"))
    #expect(reloadedText.contains("Renamed by an older build"))

    let keys = try #require(LibraryTestSupport.topLevelKeys(Data(reloadedText.utf8)))
    #expect(keys.contains("groups"))
    #expect(keys.contains("settings"))
    #expect(keys.contains("cameras"))
}

@Test func libraryStoreReportsNoUnknownContentForItsOwnDocument() async throws {
    let directory = LibraryTestSupport.temporaryDirectory()
    let store = LibraryTestSupport.makeStore(in: directory)
    _ = try await store.save(LibraryDocument(cameras: [LibraryTestSupport.camera()]))
    let outcome = await LibraryTestSupport.makeStore(in: directory).load()
    #expect(!outcome.document.hadUnknownContent)
    #expect(outcome.document.unknownContent == nil)
}

// MARK: - Failure reporting

@Test func libraryStoreReportsNotWritableWhenTheDirectoryCannotExist() async {
    let root = LibraryTestSupport.temporaryDirectory()
    let blocker = root.appendingPathComponent("blocker")
    LibraryTestSupport.write("I am a file, not a directory", to: blocker)
    let store = LibraryTestSupport.makeStore(in: blocker.appendingPathComponent("Vigil"))

    await #expect(throws: StorageError.self) {
        try await store.save(LibraryDocument(cameras: [LibraryTestSupport.camera()]))
    }
    // The load path must not throw at all: an unwritable location still has to open the app.
    let outcome = await store.load()
    #expect(outcome.document.cameras.isEmpty)
}

@Test func libraryStoreApplicationSupportDirectoryEndsInTheAppFolder() throws {
    let url = try LibraryStore.applicationSupportDirectory()
    #expect(url.lastPathComponent == "Vigil")
    #expect(!url.path.isEmpty)
}

#endif
