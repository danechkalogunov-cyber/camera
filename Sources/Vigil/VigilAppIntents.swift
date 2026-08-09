//
//  VigilAppIntents.swift
//  Vigil
//
//  First-class Shortcuts surface. Actions enter through the same deep-link gate as external
//  automation; read-only queries use the secret-free runtime index maintained once per second.
//

#if os(macOS)

import AppIntents
import AppKit
import Foundation

private enum VigilIntentLink {
    @MainActor static func open(_ text: String) throws {
        guard let url = URL(string: text), NSWorkspace.shared.open(url) else {
            throw VigilIntentError.cannotOpen
        }
    }

    static func path(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

private enum VigilIntentError: Error, CustomLocalizedStringResourceConvertible {
    case cannotOpen
    case cameraUnavailable
    case snapshotTimedOut
    case snapshotFailed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .cannotOpen: "Vigil could not perform the requested action."
        case .cameraUnavailable: "That camera is no longer in Vigil."
        case .snapshotTimedOut: "Vigil did not finish the snapshot in time."
        case .snapshotFailed(let reason): "Vigil could not take the snapshot: \(reason)"
        }
    }
}

// MARK: - Camera entity

struct CameraEntity: AppEntity, Identifiable, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Camera")
    static let defaultQuery = CameraEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "Vigil camera")
    }

    init(_ record: IntentCameraRecord) {
        id = record.id
        name = record.name
    }
}

struct CameraEntityQuery: EntityStringQuery {
    func entities(for identifiers: [CameraEntity.ID]) async throws -> [CameraEntity] {
        let wanted = Set(identifiers)
        return IntentCameraIndex.load().filter { wanted.contains($0.id) }.map(CameraEntity.init)
    }

    func entities(matching string: String) async throws -> [CameraEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return IntentCameraIndex.load().filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
        }.map(CameraEntity.init)
    }

    func suggestedEntities() async throws -> [CameraEntity] {
        IntentCameraIndex.load().map(CameraEntity.init)
    }
}

enum IntentLayout: String, AppEnum {
    case single, grid2x2, hero1p5, grid3x3, grid4x4, hero1p7, dual2p8, mosaic4x3

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Layout")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .single: "Single View", .grid2x2: "2 × 2", .hero1p5: "Hero and Five",
        .grid3x3: "3 × 3", .grid4x4: "4 × 4", .hero1p7: "Hero and Seven",
        .dual2p8: "Two Heroes and Eight", .mosaic4x3: "Mosaic",
    ]
}

// MARK: - Thirteen supported intents

struct OpenCameraIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Camera"
    static let description = IntentDescription("Shows a camera in Vigil.")
    static let openAppWhenRun = true
    @Parameter(title: "Camera") var camera: CameraEntity

    @MainActor func perform() async throws -> some IntentResult {
        try VigilIntentLink.open("vigil://camera/\(camera.id)")
        return .result()
    }
}

struct SetLayoutIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Vigil Layout"
    static let openAppWhenRun = true
    @Parameter(title: "Layout") var layout: IntentLayout

    @MainActor func perform() async throws -> some IntentResult {
        try VigilIntentLink.open("vigil://layout/\(layout.rawValue)")
        return .result()
    }
}

struct RecallLayoutPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Recall Vigil Layout Preset"
    static let openAppWhenRun = true
    @Parameter(title: "Preset Name") var presetName: String

    @MainActor func perform() async throws -> some IntentResult {
        try VigilIntentLink.open("vigil://layout/\(VigilIntentLink.path(presetName))")
        return .result()
    }
}

struct TakeSnapshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Take Camera Snapshot"
    static let description = IntentDescription("Returns a JPEG or PNG file from a Vigil camera.")
    static let openAppWhenRun = true
    @Parameter(title: "Camera") var camera: CameraEntity

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let cameraID = UUID(uuidString: camera.id) else {
            throw VigilIntentError.cameraUnavailable
        }
        let request = IntentSnapshotBridge.begin(for: CameraID(cameraID))
        try VigilIntentLink.open("vigil://camera/\(camera.id)?action=snapshot")
        do {
            let url = try await IntentSnapshotBridge.wait(for: request)
            return .result(value: IntentFile(fileURL: url))
        } catch IntentSnapshotBridgeError.timedOut {
            throw VigilIntentError.snapshotTimedOut
        } catch IntentSnapshotBridgeError.captureFailed(let reason) {
            throw VigilIntentError.snapshotFailed(reason)
        }
    }
}

struct SnapshotAllCamerasIntent: AppIntent {
    static let title: LocalizedStringResource = "Snapshot All Cameras"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        try VigilIntentLink.open("vigil://snapshot-all")
        return .result()
    }
}

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Camera Recording"
    static let openAppWhenRun = true
    @Parameter(title: "Camera") var camera: CameraEntity
    @MainActor func perform() async throws -> some IntentResult {
        try VigilIntentLink.open("vigil://camera/\(camera.id)?action=record")
        return .result()
    }
}

struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Camera Recording"
    static let openAppWhenRun = true
    @Parameter(title: "Camera") var camera: CameraEntity
    @MainActor func perform() async throws -> some IntentResult {
        try VigilIntentLink.open("vigil://camera/\(camera.id)?action=stop")
        return .result()
    }
}

struct GoToPTZPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Go to PTZ Preset"
    static let openAppWhenRun = true
    @Parameter(title: "Camera") var camera: CameraEntity
    @Parameter(title: "Preset Number") var presetNumber: Int
    @MainActor func perform() async throws -> some IntentResult {
        try VigilIntentLink.open("vigil://preset/\(camera.id)/\(presetNumber)")
        return .result()
    }
}

struct SetMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Camera Mute"
    static let openAppWhenRun = true
    @Parameter(title: "Camera") var camera: CameraEntity
    @Parameter(title: "Muted") var isMuted: Bool
    @MainActor func perform() async throws -> some IntentResult {
        let action = isMuted ? "mute" : "unmute"
        try VigilIntentLink.open("vigil://camera/\(camera.id)?action=\(action)")
        return .result()
    }
}

struct GetCameraStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Camera Status"
    @Parameter(title: "Camera") var camera: CameraEntity
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let record = IntentCameraIndex.load().first(where: { $0.id == camera.id }) else {
            throw VigilIntentError.cameraUnavailable
        }
        let status = [record.state ?? (record.isEnabled == false ? "disabled" : "not running"),
                      record.framesPerSecond.map { String(format: "%.1f fps", $0) },
                      record.bitsPerSecond.map { String(format: "%.0f bit/s", $0) },
                      record.uptimeSeconds.map { String(format: "%.0f s uptime", $0) }]
            .compactMap { $0 }.joined(separator: ", ")
        return .result(value: status)
    }
}

struct ListCamerasIntent: AppIntent {
    static let title: LocalizedStringResource = "List Vigil Cameras"
    func perform() async throws -> some IntentResult & ReturnsValue<[CameraEntity]> {
        return .result(value: IntentCameraIndex.load().map(CameraEntity.init))
    }
}

struct StartCyclingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Cycling Cameras"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        try VigilIntentLink.open("vigil://cycling/start")
        return .result()
    }
}

struct DiagnoseCameraIntent: AppIntent {
    static let title: LocalizedStringResource = "Diagnose Camera"
    static let openAppWhenRun = true
    @Parameter(title: "Camera") var camera: CameraEntity
    @MainActor func perform() async throws -> some IntentResult {
        try VigilIntentLink.open("vigil://camera/\(camera.id)?action=diagnose")
        return .result()
    }
}

struct VigilShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenCameraIntent(),
                    phrases: ["Show \(\.$camera) in \(.applicationName)"],
                    shortTitle: "Show Camera", systemImageName: "video.fill")
        AppShortcut(intent: TakeSnapshotIntent(),
                    phrases: ["Take a snapshot of \(\.$camera) with \(.applicationName)"],
                    shortTitle: "Take Snapshot", systemImageName: "camera.fill")
        AppShortcut(intent: SnapshotAllCamerasIntent(),
                    phrases: ["Snapshot all cameras with \(.applicationName)"],
                    shortTitle: "Snapshot All", systemImageName: "camera.on.rectangle")
        AppShortcut(intent: StartRecordingIntent(),
                    phrases: ["Start recording \(\.$camera) with \(.applicationName)"],
                    shortTitle: "Start Recording", systemImageName: "record.circle")
        AppShortcut(intent: StartCyclingIntent(),
                    phrases: ["Cycle cameras in \(.applicationName)"],
                    shortTitle: "Cycle Cameras", systemImageName: "arrow.triangle.2.circlepath")
    }
}

#endif
