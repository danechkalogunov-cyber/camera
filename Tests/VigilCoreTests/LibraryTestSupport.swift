//
//  LibraryTestSupport.swift
//  VigilCoreTests
//
//  Fixtures and helpers shared by the `Library*` test files: a fixed wall clock, temporary
//  directories, camera builders, and the two questions about a type's conformances that prove a
//  secret cannot be serialised.
//
//  Everything lives inside one namespace type on purpose: four agents add files to this target, and
//  a free helper called `makeCamera` would be a collision waiting to happen.
//

#if os(macOS)

import Foundation
import VigilCore
import VigilProtocols

enum LibraryTestSupport {

    // MARK: - Clocks

    /// A `WallClock` that never moves, so an encoded document is byte-comparable.
    struct FixedWallClock: WallClock {
        var instant: Date
        var now: Date { instant }
    }

    /// `2026-01-26T14:45:30Z`. Chosen because it round-trips through the second-resolution ISO-8601
    /// form with nothing to truncate.
    static let epoch = Date(timeIntervalSince1970: 1_769_438_730)

    /// `epoch` in the exact spelling `LibraryCoding` writes.
    static let epochISO = "2026-01-26T14:45:30Z"

    // MARK: - Directories

    /// A fresh, empty directory under the system temporary directory.
    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vigil-library-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The file names in a directory, sorted. Used to assert that a save leaves no temp files.
    static func contents(of directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    /// The bytes of a file as UTF-8 text, or `nil`.
    static func text(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Writes text to a file, replacing whatever was there.
    static func write(_ text: String, to url: URL) {
        try? Data(text.utf8).write(to: url, options: [.atomic])
    }

    // MARK: - Factories

    /// A store over `directory` whose clock and version string are fixed.
    static func makeStore(in directory: URL,
                          options: LibraryStore.Options = LibraryStore.Options(
                              generatedBy: "Vigil test")) -> LibraryStore {
        LibraryStore(directory: directory,
                     options: options,
                     wallClock: FixedWallClock(instant: epoch))
    }

    /// A library over a store, with a virtual monotonic clock so the write debounce never sleeps.
    static func makeLibrary(store: LibraryStore, at instant: Date = epoch) -> CameraLibrary {
        CameraLibrary(store: store,
                      clock: VirtualLibraryClock(),
                      wallClock: FixedWallClock(instant: instant))
    }

    /// A monotonic clock that stands still and never suspends.
    ///
    /// `VigilTestKit.VirtualClock` would do, but it is a value type: the copy the library holds
    /// cannot be advanced from a test, so the extra dependency would buy nothing here.
    struct VirtualLibraryClock: MonotonicClock {
        func now() -> MediaInstant { .zero }
        func sleep(for duration: Duration) async throws {}
        func sleep(until deadline: MediaInstant) async throws {}
    }

    /// A camera with everything spelled out, so no test depends on a default that might change.
    static func camera(id: CameraID = CameraID(),
                       name: String = "Front Door",
                       host: String = "192.168.1.64",
                       httpPort: Int = 80,
                       rtspPort: Int = 554,
                       channel: ChannelID = .first,
                       credentialRef: CredentialRef = CredentialRef(),
                       capabilities: DeviceCapabilities? = nil,
                       createdAt: Date = LibraryTestSupport.epoch,
                       lastSeenAt: Date? = nil,
                       isEnabled: Bool = true) -> Camera {
        Camera(id: id,
               name: name,
               host: host,
               httpPort: httpPort,
               rtspPort: rtspPort,
               channel: channel,
               credentialRef: credentialRef,
               capabilities: capabilities,
               createdAt: createdAt,
               lastSeenAt: lastSeenAt,
               isEnabled: isEnabled)
    }

    /// An inventory of `count` channels for a camera.
    static func inventory(for camera: Camera,
                          count: Int = 2,
                          source: ChannelInventorySource = .isapi) -> CameraChannelInventory {
        CameraChannelInventory(
            cameraID: camera.id,
            host: camera.host,
            httpPort: camera.httpPort,
            channels: (1...max(count, 1)).map { index in
                LibraryChannel(channel: ChannelID(index),
                               name: "Channel \(index)",
                               qualities: [.main, .sub])
            },
            source: source,
            enumeratedAt: epoch)
    }

    // MARK: - Conformance probes

    /// Whether a type conforms to `Encodable` or `Decodable`, asked dynamically.
    ///
    /// Generic on purpose: writing `Credential.self is any Encodable.Type` at a concrete type lets
    /// the compiler answer statically (with a warning), which is not the same as demonstrating that
    /// no encoder can ever reach the type at runtime.
    static func isCodable<T>(_ type: T.Type) -> Bool {
        type is any Encodable.Type || type is any Decodable.Type
    }

    /// A JSON document's top-level keys, sorted, or `nil` when the bytes are not a JSON object.
    static func topLevelKeys(_ data: Data) -> [String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return root.keys.sorted()
    }
}

#endif
