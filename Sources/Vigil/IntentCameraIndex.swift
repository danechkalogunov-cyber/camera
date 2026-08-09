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

struct IntentCameraRecord: Codable, Hashable, Sendable {
    let id: String
    let name: String
}

enum IntentCameraIndex {
    private static let key = "Vigil.appIntents.cameras"

    @MainActor
    static func save(_ cameras: [Camera]) {
        let records = cameras.map {
            IntentCameraRecord(id: $0.id.rawValue.uuidString, name: $0.displayName)
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
}

#endif
