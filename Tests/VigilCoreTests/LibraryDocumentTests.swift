//
//  LibraryDocumentTests.swift
//  VigilCoreTests
//
//  The document's coding rules and its normalisation arithmetic — the JSON round trip, the
//  deterministic byte output, and every repair `normalize()` claims to make.
//  Covers Sources/VigilCore/Library/LibraryDocument.swift and LibraryChannelInventory.swift.
//

#if os(macOS)

import Foundation
import Testing
import VigilCore
import VigilProtocols

// MARK: - Coding

@Test func libraryDocumentRoundTripsThroughJSON() throws {
    let first = LibraryTestSupport.camera(name: "Front Door",
                                          host: "192.168.1.64",
                                          capabilities: DeviceCapabilities(
                                              rtspPathTemplate: .streamingChannelsWithQuality,
                                              resolvedRTSPPath: "/Streaming/Channels/101",
                                              videoCodec: .h264,
                                              probedAt: LibraryTestSupport.epoch,
                                              firmwareVersion: "V5.6.3 build 190923"),
                                          lastSeenAt: LibraryTestSupport.epoch)
    let second = LibraryTestSupport.camera(name: "Garage", host: "192.168.1.65", channel: 2)
    var document = LibraryDocument(generatedBy: "Vigil test",
                                   updatedAt: LibraryTestSupport.epoch,
                                   cameras: [first, second],
                                   channelInventories: [LibraryTestSupport.inventory(for: first)],
                                   didImportLegacyConnection: true)
    _ = document.normalize()

    let data = try LibraryCoding.makeEncoder().encode(document)
    let decoded = try LibraryCoding.makeDecoder().decode(LibraryDocument.self, from: data)

    #expect(decoded.schemaVersion == LibraryDocument.currentSchemaVersion)
    #expect(decoded.generatedBy == "Vigil test")
    #expect(decoded.updatedAt == LibraryTestSupport.epoch)
    #expect(decoded.cameras == document.cameras)
    #expect(decoded.channelInventories == document.channelInventories)
    #expect(decoded.didImportLegacyConnection)
}

@Test func libraryDocumentEncodesTheSameStateToTheSameBytes() throws {
    let document = LibraryDocument(updatedAt: LibraryTestSupport.epoch,
                                   cameras: [LibraryTestSupport.camera()])
    let first = try LibraryCoding.makeEncoder().encode(document)
    let second = try LibraryCoding.makeEncoder().encode(document)
    #expect(first == second)

    // Determinism is what makes LibraryStore's skip-the-write check sound, and key order is the part
    // a dictionary would break.
    let text = try #require(String(data: first, encoding: .utf8))
    let versionIndex = try #require(text.range(of: "\"schemaVersion\""))
    let camerasIndex = try #require(text.range(of: "\"cameras\""))
    #expect(camerasIndex.lowerBound < versionIndex.lowerBound, "keys must be sorted")
}

@Test func libraryDocumentWritesDatesAsISO8601UTC() throws {
    let document = LibraryDocument(updatedAt: LibraryTestSupport.epoch)
    let text = try #require(String(data: try LibraryCoding.makeEncoder().encode(document),
                                   encoding: .utf8))
    #expect(text.contains("\"updatedAt\" : \"\(LibraryTestSupport.epochISO)\""))
    #expect(!text.contains("1769438730"), "a numeric date is the schema-1 form and is never written")
}

@Test func libraryDocumentWritesPathsWithUnescapedSlashes() throws {
    let camera = LibraryTestSupport.camera(capabilities: DeviceCapabilities(
        resolvedRTSPPath: "/Streaming/Channels/101"))
    let document = LibraryDocument(updatedAt: LibraryTestSupport.epoch, cameras: [camera])
    let text = try #require(String(data: try LibraryCoding.makeEncoder().encode(document),
                                   encoding: .utf8))
    #expect(text.contains("\"/Streaming/Channels/101\""))
    #expect(!text.contains("\\/"), "an escaped slash makes the document unreadable by a human")
}

@Test func libraryDocumentDecodesAnEmptyObjectAsSchemaOne() throws {
    let decoded = try LibraryCoding.makeDecoder().decode(LibraryDocument.self,
                                                        from: Data("{}".utf8))
    #expect(decoded.schemaVersion == 1, "an unversioned file is by definition the oldest shape")
    #expect(decoded.cameras.isEmpty)
    #expect(decoded.channelInventories.isEmpty)
    #expect(!decoded.didImportLegacyConnection)
}

@Test func libraryDocumentDecodeAcceptsNumericAndFractionalDates() throws {
    let json = """
    {"schemaVersion":3,"updatedAt":1769438730,
     "cameras":[{"id":"E1A2B3C4-D5E6-4F70-8A9B-0C1D2E3F4A5B","host":"10.0.0.9",
                 "createdAt":"2026-01-26T14:45:30.250Z"}]}
    """
    let decoded = try LibraryCoding.makeDecoder().decode(LibraryDocument.self,
                                                        from: Data(json.utf8))
    #expect(decoded.updatedAt == LibraryTestSupport.epoch)
    let camera = try #require(decoded.cameras.first)
    // Fractional seconds are accepted on read and truncated toward the past.
    #expect(camera.createdAt.timeIntervalSince1970 >= LibraryTestSupport.epoch.timeIntervalSince1970)
    #expect(camera.createdAt.timeIntervalSince1970 < LibraryTestSupport.epoch.timeIntervalSince1970
        + 1)
}

@Test func libraryDocumentDecodeRejectsAnUnparseableDate() {
    let json = """
    {"schemaVersion":3,"updatedAt":"not a date"}
    """
    #expect(throws: (any Error).self) {
        try LibraryCoding.makeDecoder().decode(LibraryDocument.self, from: Data(json.utf8))
    }
}

@Test func libraryDocumentDecodeToleratesUnknownCameraFields() throws {
    // A document written by a newer build carries fields this one has never heard of. Decoding must
    // ignore them rather than failing the whole library.
    let json = """
    {"schemaVersion":3,
     "cameras":[{"id":"E1A2B3C4-D5E6-4F70-8A9B-0C1D2E3F4A5B","host":"10.0.0.9",
                 "colorTag":"blue","orderIndex":2048,"notes":"back gate"}]}
    """
    let decoded = try LibraryCoding.makeDecoder().decode(LibraryDocument.self,
                                                        from: Data(json.utf8))
    #expect(decoded.cameras.count == 1)
    #expect(decoded.cameras.first?.host == "10.0.0.9")
}

// MARK: - Normalisation

@Test func libraryDocumentNormalizeDropsRecordsThatCannotAddressADevice() {
    let good = LibraryTestSupport.camera(host: "192.168.1.64")
    let pastedURL = LibraryTestSupport.camera(host: "rtsp://192.168.1.70/Streaming/Channels/101")
    let noHost = LibraryTestSupport.camera(host: "   ")
    let badPort = LibraryTestSupport.camera(host: "192.168.1.71", rtspPort: 70_000)

    var document = LibraryDocument(cameras: [good, pastedURL, noHost, badPort])
    let report = document.normalize()

    #expect(document.cameras.map(\.id) == [good.id])
    #expect(Set(report.droppedInvalidCameras) == Set([pastedURL.id, noHost.id, badPort.id]))
    #expect(report.didChange)
}

@Test func libraryDocumentNormalizeRepairsAnEmptyName() {
    var document = LibraryDocument(cameras: [LibraryTestSupport.camera(name: "  \n ",
                                                                      host: "192.168.1.64")])
    let report = document.normalize()
    #expect(document.cameras.first?.name == "Camera 192.168.1.64")
    #expect(report.repairedCameras == 1)
}

@Test func libraryDocumentNormalizeKeepsTheRecordSeenMoreRecently() {
    let id = CameraID()
    let older = LibraryTestSupport.camera(id: id, name: "Old", host: "10.0.0.1",
                                          lastSeenAt: LibraryTestSupport.epoch)
    let newer = LibraryTestSupport.camera(id: id, name: "New", host: "10.0.0.2",
                                         lastSeenAt: LibraryTestSupport.epoch.addingTimeInterval(60))
    var document = LibraryDocument(cameras: [older, newer])
    let report = document.normalize()

    #expect(document.cameras.count == 1)
    #expect(document.cameras.first?.name == "New")
    #expect(report.droppedDuplicateCameras == [id])
}

@Test func libraryDocumentNormalizeKeepsTheFirstRecordWhenNeitherWasEverSeen() {
    let id = CameraID()
    var document = LibraryDocument(cameras: [
        LibraryTestSupport.camera(id: id, name: "First", host: "10.0.0.1"),
        LibraryTestSupport.camera(id: id, name: "Second", host: "10.0.0.2"),
    ])
    _ = document.normalize()
    #expect(document.cameras.first?.name == "First")
}

@Test func libraryDocumentNormalizeNeverPromotesAnUnseenRecordOverASeenOne() {
    let id = CameraID()
    var document = LibraryDocument(cameras: [
        LibraryTestSupport.camera(id: id, name: "Connected", host: "10.0.0.1",
                                  lastSeenAt: LibraryTestSupport.epoch),
        LibraryTestSupport.camera(id: id, name: "Never connected", host: "10.0.0.2"),
    ])
    _ = document.normalize()
    #expect(document.cameras.first?.name == "Connected")
}

@Test func libraryDocumentNormalizeIsIdempotent() {
    let id = CameraID()
    var document = LibraryDocument(cameras: [
        LibraryTestSupport.camera(name: "  spaces  ", host: "192.168.1.64"),
        LibraryTestSupport.camera(host: "not a host/with slash"),
        LibraryTestSupport.camera(id: id, host: "10.0.0.1"),
        LibraryTestSupport.camera(id: id, host: "10.0.0.2"),
    ])
    let first = document.normalize()
    let fixedPoint = document
    let second = document.normalize()

    #expect(first.didChange)
    #expect(!second.didChange, "normalize(normalize(x)) must equal normalize(x)")
    #expect(document == fixedPoint)
}

@Test func libraryDocumentNormalizePreservesDisplayOrder() {
    let cameras = (1...5).map { index in
        LibraryTestSupport.camera(name: "Camera \(index)", host: "10.0.0.\(index)")
    }
    var document = LibraryDocument(cameras: cameras.reversed())
    _ = document.normalize()
    #expect(document.cameras.map(\.name) == cameras.reversed().map(\.name),
            "the array order IS the display order; normalisation must not re-sort it")
}

@Test func libraryDocumentNormalizeDropsOrphanInventoriesAndKeepsCameraOrder() {
    let first = LibraryTestSupport.camera(host: "10.0.0.1")
    let second = LibraryTestSupport.camera(host: "10.0.0.2")
    let ghost = LibraryTestSupport.camera(host: "10.0.0.3")

    var document = LibraryDocument(
        cameras: [first, second],
        channelInventories: [LibraryTestSupport.inventory(for: ghost),
                             LibraryTestSupport.inventory(for: second),
                             LibraryTestSupport.inventory(for: first)])
    let report = document.normalize()

    #expect(document.channelInventories.map(\.cameraID) == [first.id, second.id])
    #expect(report.droppedOrphanInventories == [ghost.id])
}

@Test func libraryDocumentNormalizeDeduplicatesInventoriesForOneCamera() {
    let camera = LibraryTestSupport.camera()
    var document = LibraryDocument(cameras: [camera],
                                   channelInventories: [
                                       LibraryTestSupport.inventory(for: camera, count: 4),
                                       LibraryTestSupport.inventory(for: camera, count: 1),
                                   ])
    _ = document.normalize()
    #expect(document.channelInventories.count == 1)
    #expect(document.channelInventories.first?.channels.count == 4, "the first record wins")
}

// MARK: - Lookups

@Test func libraryDocumentLooksUpCamerasAndEnabledSubset() {
    let enabled = LibraryTestSupport.camera(host: "10.0.0.1")
    let disabled = LibraryTestSupport.camera(host: "10.0.0.2", isEnabled: false)
    let document = LibraryDocument(cameras: [enabled, disabled])

    #expect(document.camera(enabled.id) == enabled)
    #expect(document.camera(CameraID()) == nil)
    #expect(document.index(of: disabled.id) == 1)
    #expect(document.enabledCameras.map(\.id) == [enabled.id])
}

@Test func libraryDocumentFindsALearnedTemplateOnlyForTheSameDeviceAddress() {
    let probed = LibraryTestSupport.camera(
        host: "192.168.1.64",
        capabilities: DeviceCapabilities(rtspPathTemplate: .legacyH264))
    let document = LibraryDocument(cameras: [probed])

    #expect(document.learnedPathTemplate(host: "192.168.1.64", rtspPort: 554) == .legacyH264)
    #expect(document.learnedPathTemplate(host: "192.168.1.65", rtspPort: 554) == nil)
    #expect(document.learnedPathTemplate(host: "192.168.1.64", rtspPort: 555) == nil,
            "a different RTSP port is a different device")
}

@Test func libraryDocumentFindsAChannelInventoryByDeviceAddress() {
    let camera = LibraryTestSupport.camera(host: "192.168.1.70", httpPort: 8000)
    let document = LibraryDocument(cameras: [camera],
                                   channelInventories: [LibraryTestSupport.inventory(for: camera)])

    #expect(document.channelInventory(host: "192.168.1.70", httpPort: 8000)?.cameraID == camera.id)
    #expect(document.channelInventory(host: "192.168.1.70", httpPort: 80) == nil)
}

// MARK: - Channel inventory records

@Test func libraryChannelInventorySortsChannelsAndQualities() {
    let inventory = CameraChannelInventory(
        cameraID: CameraID(),
        host: "10.0.0.1",
        httpPort: 80,
        channels: [LibraryChannel(channel: 3, name: "Three", qualities: [.third, .main, .sub]),
                   LibraryChannel(channel: 1, name: "One")],
        source: .isapi,
        enumeratedAt: LibraryTestSupport.epoch)

    #expect(inventory.channels.map(\.channel) == [1, 3])
    #expect(inventory.channels.last?.qualities == [.main, .sub, .third])
}

@Test func libraryChannelInventoryNormalizedDropsDuplicateChannels() {
    let inventory = CameraChannelInventory(
        cameraID: CameraID(),
        host: "10.0.0.1",
        httpPort: 80,
        channels: [LibraryChannel(channel: 1, name: "Kept"),
                   LibraryChannel(channel: 1, name: "Dropped")],
        source: .isapi,
        enumeratedAt: LibraryTestSupport.epoch).normalized()

    #expect(inventory.channels.count == 1)
    #expect(inventory.channels.first?.name == "Kept")
}

@Test func libraryChannelInventoryPopulatedChannelsExcludeOfflineAndDisabled() {
    let inventory = CameraChannelInventory(
        cameraID: CameraID(),
        host: "10.0.0.1",
        httpPort: 80,
        channels: [LibraryChannel(channel: 1, name: "Live"),
                   LibraryChannel(channel: 2, name: "Nothing plugged in", isOnline: false,
                                  offlineReason: "noVideoInput"),
                   LibraryChannel(channel: 3, name: "Disabled on the NVR", isEnabled: false)],
        source: .isapi,
        enumeratedAt: LibraryTestSupport.epoch)

    #expect(inventory.populatedChannels.map(\.channel) == [1])
    #expect(inventory.isAuthoritative)
}

@Test func libraryChannelInventoryFromADescribeProbeIsNotAuthoritative() {
    let inventory = CameraChannelInventory(cameraID: CameraID(),
                                           host: "10.0.0.1",
                                           httpPort: 80,
                                           channels: [],
                                           source: .describeProbe,
                                           enumeratedAt: LibraryTestSupport.epoch)
    #expect(!inventory.isAuthoritative)
}

@Test func libraryChannelInventoryDecodeSuppliesDefaultsForAThinRecord() throws {
    let json = """
    {"cameraID":"E1A2B3C4-D5E6-4F70-8A9B-0C1D2E3F4A5B","channels":[{"channel":4}],
     "source":"somethingNewerVigilInvented"}
    """
    let decoded = try LibraryCoding.makeDecoder().decode(CameraChannelInventory.self,
                                                         from: Data(json.utf8))
    #expect(decoded.httpPort == 80)
    #expect(decoded.channels.first?.name == "Channel 4")
    #expect(decoded.channels.first?.isOnline == true)
    #expect(decoded.source == .describeProbe, "an unknown source reads as existence-only")
}

@Test func libraryChannelInventoryEncodesDeterministicallyWithNoDictionaryOrder() throws {
    let camera = LibraryTestSupport.camera()
    let inventory = LibraryTestSupport.inventory(for: camera, count: 8)
    let encoder = LibraryCoding.makeEncoder()
    let first = try encoder.encode(inventory)
    let second = try encoder.encode(inventory)
    #expect(first == second)
    let text = try #require(String(data: first, encoding: .utf8))
    // Qualities are an ordered array, never a dictionary keyed by an enum — that is the whole reason
    // this record exists instead of persisting VigilISAPI.DeviceChannel.
    #expect(text.contains("\"qualities\" : ["))
}

#endif
