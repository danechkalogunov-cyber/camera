//
//  CameraLibraryDuplicateTests.swift
//  VigilCoreTests
//
//  Duplication is the fast path from one recorder channel to another.
//

#if os(macOS)

import Foundation
import Testing
import VigilCore
import VigilProtocols

@Test func cameraLibraryDuplicateCopiesConfigurationButResetsIdentity() async throws {
    let directory = LibraryTestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = LibraryTestSupport.makeLibrary(store: LibraryTestSupport.makeStore(in: directory))
    _ = await library.load()
    let original = LibraryTestSupport.camera(name: "Recorder",
                                             channel: ChannelID(7),
                                             lastSeenAt: LibraryTestSupport.epoch)
    _ = try await library.add(original)
    let copyID = CameraID(UUID(uuidString: "00000000-0000-0000-0000-000000000099")!)

    let copy = try await library.duplicate(original.id, as: copyID)

    #expect(copy.id == copyID)
    #expect(copy.name == "Recorder (2)")
    #expect(copy.host == original.host)
    #expect(copy.channel == original.channel)
    #expect(copy.credentialRef == original.credentialRef)
    #expect(copy.createdAt == LibraryTestSupport.epoch)
    #expect(copy.lastSeenAt == nil)
    #expect(await library.cameras().map(\.id) == [original.id, copyID])
}

@Test func cameraLibraryDuplicateChoosesFirstFreeSuffix() async throws {
    let directory = LibraryTestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = LibraryTestSupport.makeLibrary(store: LibraryTestSupport.makeStore(in: directory))
    _ = await library.load()
    let original = LibraryTestSupport.camera(name: "Gate")
    _ = try await library.add(original)
    _ = try await library.add(LibraryTestSupport.camera(name: "Gate (2)"))
    _ = try await library.add(LibraryTestSupport.camera(name: "Gate (4)"))

    let copy = try await library.duplicate(original.id)

    #expect(copy.name == "Gate (3)")
    #expect(await library.cameras()[1].id == copy.id)
}

@Test func cameraLibraryDuplicateRejectsUnknownAndCollidingIdentifiers() async throws {
    let directory = LibraryTestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = LibraryTestSupport.makeLibrary(store: LibraryTestSupport.makeStore(in: directory))
    _ = await library.load()
    let original = LibraryTestSupport.camera()
    _ = try await library.add(original)

    await #expect(throws: LibraryMutationError.self) {
        try await library.duplicate(CameraID())
    }
    await #expect(throws: LibraryMutationError.self) {
        try await library.duplicate(original.id, as: original.id)
    }
}

@Test func cameraLibraryPersistsEnabledStateAndColourTag() async throws {
    let directory = LibraryTestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = LibraryTestSupport.makeLibrary(store: LibraryTestSupport.makeStore(in: directory))
    _ = await library.load()
    let camera = LibraryTestSupport.camera()
    _ = try await library.add(camera)

    _ = try await library.setEnabled(false, for: camera.id)
    _ = try await library.setColorTag(.purple, for: camera.id)
    try await library.flush()

    let reloaded = LibraryTestSupport.makeLibrary(store: LibraryTestSupport.makeStore(in: directory))
    _ = await reloaded.load()
    let stored = try #require(await reloaded.cameras().first)
    #expect(!stored.isEnabled)
    #expect(stored.colorTag == .purple)
}

#endif  // os(macOS)
