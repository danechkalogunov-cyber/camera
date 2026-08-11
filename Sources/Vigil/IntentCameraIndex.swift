//
//  IntentCameraIndex.swift
//  Vigil
//
//  A secret-free, tiny projection of the camera library for App Intents entity pickers. Shortcuts
//  may ask its query before a window (and therefore AppLibraryModel) exists; UserDefaults is the
//  launch-safe handoff. No host, account or credential handle is copied here.
//

#if os(macOS)

import Foundation

import VigilCore
import VigilProtocols

struct IntentCameraRecord: Codable, Hashable, Sendable {
    let id: String
    let name: String
    var isEnabled: Bool?
    var state: String?
    var framesPerSecond: Double?
    var bitsPerSecond: Double?
    var uptimeSeconds: Double?
}

enum IntentCameraIndex {
    private static let key = "Vigil.appIntents.cameras"

    @MainActor
    static func save(_ cameras: [Camera]) {
        let records = cameras.map {
            IntentCameraRecord(id: $0.id.rawValue.uuidString, name: $0.displayName,
                               isEnabled: $0.isEnabled)
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> [IntentCameraRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([IntentCameraRecord].self, from: data)
        else { return [] }
        return records
    }

    @MainActor
    static func update(_ cameras: [Camera], streams: CameraStreamSet,
                       telemetry: [CameraID: StreamTelemetrySnapshot]) {
        let previous = Dictionary(uniqueKeysWithValues: load().map { ($0.id, $0) })
        let records = cameras.map { camera in
            let reading = telemetry[camera.id]?.statistics
            let stream = streams.stream(for: camera.id)
            return IntentCameraRecord(
                id: camera.id.rawValue.uuidString, name: camera.displayName,
                isEnabled: camera.isEnabled,
                state: stream.map { String(describing: $0.liveState) }
                    ?? previous[camera.id.rawValue.uuidString]?.state,
                framesPerSecond: reading?.framesPerSecond,
                bitsPerSecond: reading?.bitsPerSecond,
                uptimeSeconds: reading?.uptimeSeconds)
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

#endif
