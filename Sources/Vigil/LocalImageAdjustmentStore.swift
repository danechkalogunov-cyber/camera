//
//  LocalImageAdjustmentStore.swift
//  Vigil
//
//  Persists per-camera display-only colour adjustments without changing camera or recording data.
//

#if os(macOS)

import Foundation
import Observation

import VigilProtocols
import VigilRender
import VigilUI

@MainActor
@Observable
final class LocalImageAdjustmentStore {
    private struct Record: Codable, Sendable {
        var brightness: Int
        var contrast: Int
        var saturation: Int
        var sharpness: Int
        var gamma: Int
    }

    private static let defaultsKey = "Vigil.image.localAdjustments.v1"
    private let defaults: UserDefaults
    private var records: [String: Record]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    func settings(for cameraID: CameraID) -> InspectorImageSettings? {
        guard let record = records[cameraID.description] else { return nil }
        return InspectorImageSettings(brightness: record.brightness,
                                      contrast: record.contrast,
                                      saturation: record.saturation,
                                      sharpness: record.sharpness,
                                      clientGamma: record.gamma,
                                      isLocalPreviewOnly: true)
    }

    func adjustments(for cameraID: CameraID) -> TileColorAdjustments {
        guard let record = records[cameraID.description] else { return TileColorAdjustments() }
        return TileColorAdjustments(
            brightness: Float(record.brightness - 50) / 50,
            contrast: Float(record.contrast) / 50,
            saturation: Float(record.saturation) / 50,
            gamma: 0.5 + Float(record.gamma) / 100)
    }

    func save(_ settings: InspectorImageSettings, for cameraID: CameraID) {
        records[cameraID.description] = Record(brightness: settings.brightness,
                                               contrast: settings.contrast,
                                               saturation: settings.saturation,
                                               sharpness: settings.sharpness,
                                               gamma: settings.clientGamma)
        persist()
    }

    func reset(_ cameraID: CameraID) -> InspectorImageSettings {
        let neutral = InspectorImageSettings(isLocalPreviewOnly: true)
        save(neutral, for: cameraID)
        return neutral
    }

    func remove(_ cameraID: CameraID) {
        records.removeValue(forKey: cameraID.description)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

#endif
