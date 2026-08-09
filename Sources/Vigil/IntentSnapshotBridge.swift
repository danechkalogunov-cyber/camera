//
//  IntentSnapshotBridge.swift
//  Vigil
//
//  App Intents launch the app through the same confirmed deep-link gate as every other external
//  caller. This tiny, secret-free rendezvous lets the intent wait for the file that gate produced.
//

#if os(macOS)

import Foundation

import VigilProtocols

enum IntentSnapshotBridge {
    private static let pendingRequestKey = "Vigil.intents.snapshot.pendingRequest"
    private static let pendingCameraKey = "Vigil.intents.snapshot.pendingCamera"
    private static let resultPrefix = "Vigil.intents.snapshot.result."
    private static let failurePrefix = "Vigil.intents.snapshot.failure."

    static func begin(for cameraID: CameraID) -> UUID {
        let request = UUID()
        let defaults = UserDefaults.standard
        defaults.set(request.uuidString, forKey: pendingRequestKey)
        defaults.set(cameraID.rawValue.uuidString, forKey: pendingCameraKey)
        return request
    }

    static func takePending(for cameraID: CameraID) -> UUID? {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: pendingCameraKey) == cameraID.rawValue.uuidString,
              let raw = defaults.string(forKey: pendingRequestKey),
              let request = UUID(uuidString: raw) else { return nil }
        defaults.removeObject(forKey: pendingRequestKey)
        defaults.removeObject(forKey: pendingCameraKey)
        return request
    }

    static func complete(_ request: UUID, url: URL) {
        UserDefaults.standard.set(url.path, forKey: resultPrefix + request.uuidString)
    }

    static func fail(_ request: UUID, reason: String) {
        UserDefaults.standard.set(Redact.secrets(in: reason),
                                  forKey: failurePrefix + request.uuidString)
    }

    static func wait(for request: UUID, timeout: Duration = .seconds(45)) async throws -> URL {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            let defaults = UserDefaults.standard
            let resultKey = resultPrefix + request.uuidString
            if let path = defaults.string(forKey: resultKey) {
                defaults.removeObject(forKey: resultKey)
                return URL(fileURLWithPath: path)
            }
            let failureKey = failurePrefix + request.uuidString
            if let reason = defaults.string(forKey: failureKey) {
                defaults.removeObject(forKey: failureKey)
                throw IntentSnapshotBridgeError.captureFailed(reason)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw IntentSnapshotBridgeError.timedOut
    }
}

enum IntentSnapshotBridgeError: Error, Sendable, Hashable {
    case captureFailed(String)
    case timedOut
}

#endif
