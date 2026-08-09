//
//  VigilAppIntents.swift
//  Vigil
//
//  Shortcuts surface. Intents enter through the same deep-link gate as external automation, so
//  closed windows, confirmation policy and deferred execution behave identically.
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
}

private enum VigilIntentError: Error, CustomLocalizedStringResourceConvertible {
    case cannotOpen

    var localizedStringResource: LocalizedStringResource {
        "Vigil could not perform the requested action."
    }
}

struct OpenVigilIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Vigil"
    static let description = IntentDescription("Opens the Vigil video wall.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        NSApp.activate(ignoringOtherApps: true)
        return .result()
    }
}

struct SnapshotAllCamerasIntent: AppIntent {
    static let title: LocalizedStringResource = "Snapshot All Cameras"
    static let description = IntentDescription("Saves a snapshot from every enabled camera.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        try VigilIntentLink.open("vigil://snapshot-all")
        return .result()
    }
}

struct StartFocusedRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Camera Recording"
    static let description = IntentDescription("Starts recording the focused camera in Vigil.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        try VigilIntentLink.open("vigil://camera/focused?action=record")
        return .result()
    }
}

struct StopFocusedRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Camera Recording"
    static let description = IntentDescription("Stops recording the focused camera in Vigil.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        try VigilIntentLink.open("vigil://camera/focused?action=stop")
        return .result()
    }
}

struct VigilShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenVigilIntent(), phrases: ["Open \(.applicationName)"],
                    shortTitle: "Open Vigil", systemImageName: "video.fill")
        AppShortcut(intent: SnapshotAllCamerasIntent(),
                    phrases: ["Snapshot all cameras in \(.applicationName)"],
                    shortTitle: "Snapshot All", systemImageName: "camera.fill")
        AppShortcut(intent: StartFocusedRecordingIntent(),
                    phrases: ["Start recording in \(.applicationName)"],
                    shortTitle: "Start Recording", systemImageName: "record.circle")
        AppShortcut(intent: StopFocusedRecordingIntent(),
                    phrases: ["Stop recording in \(.applicationName)"],
                    shortTitle: "Stop Recording", systemImageName: "stop.circle")
    }
}

#endif
