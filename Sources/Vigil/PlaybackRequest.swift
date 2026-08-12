//
//  PlaybackRequest.swift
//  Vigil
//
//  Typed payload for the standalone playback scene.
//

#if os(macOS)

import Foundation

import VigilProtocols

public struct PlaybackRequest: Codable, Hashable, Sendable {
    public var cameraIDs: [CameraID]
    public var focus: Date?
    public var day: Date

    public init(cameraIDs: [CameraID], focus: Date?, day: Date) {
        self.cameraIDs = cameraIDs
        self.focus = focus
        self.day = day
    }

    public static let empty = PlaybackRequest(cameraIDs: [], focus: nil, day: .now)
}

#endif  // os(macOS)
