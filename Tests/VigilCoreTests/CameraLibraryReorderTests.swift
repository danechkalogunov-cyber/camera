//
//  CameraLibraryReorderTests.swift
//  VigilCoreTests
//
//  A drag destination is measured before removal; these vectors guard the easy downward off-by-one.
//

#if os(macOS)

import Foundation
import Testing
import VigilCore
import VigilProtocols

@Test func cameraLibraryMovesCameraUsingPreRemovalDestination() async throws {
    let directory = LibraryTestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = LibraryTestSupport.makeLibrary(store: LibraryTestSupport.makeStore(in: directory))
    _ = await library.load()
    let cameras = ["A", "B", "C", "D"].map { LibraryTestSupport.camera(name: $0) }
    for camera in cameras { _ = try await library.add(camera) }

    #expect(try await library.moveCameras(fromOffsets: IndexSet(integer: 0), toOffset: 3))
    #expect(await library.cameras().map(\.name) == ["B", "C", "A", "D"])
}

@Test func cameraLibraryReorderPersistsAndPreservesEveryCamera() async throws {
    let directory = LibraryTestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LibraryTestSupport.makeStore(in: directory)
    let library = LibraryTestSupport.makeLibrary(store: store)
    _ = await library.load()
    let cameras = ["A", "B", "C"].map { LibraryTestSupport.camera(name: $0) }
    for camera in cameras { _ = try await library.add(camera) }

    #expect(try await library.moveCameras(fromOffsets: IndexSet(integer: 2), toOffset: 0))
    try await library.flush()

    let reloaded = LibraryTestSupport.makeLibrary(store: LibraryTestSupport.makeStore(in: directory))
    _ = await reloaded.load()
    #expect(await reloaded.cameras().map(\.id) == [cameras[2].id, cameras[0].id, cameras[1].id])
}

#endif  // os(macOS)
