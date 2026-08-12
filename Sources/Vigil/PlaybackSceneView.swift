//
//  PlaybackSceneView.swift
//  Vigil
//
//  A lightweight launcher for the existing archive timeline. Media remains in the main stage so
//  opening this scene never creates a duplicate RTSP session or decoder.
//

#if os(macOS)

import SwiftUI

import VigilCore
import VigilProtocols
import VigilUI

@MainActor
struct PlaybackSceneView: View {

    let request: PlaybackRequest

    @Bindable var library: AppLibraryModel
    @Bindable var window: MainWindowState

    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    @State private var cameraID: CameraID?
    @State private var instant = Date()

    init(request: PlaybackRequest, library: AppLibraryModel, window: MainWindowState) {
        self.request = request
        self.library = library
        self.window = window
        _cameraID = State(initialValue: request.cameraIDs.first)
        _instant = State(initialValue: request.focus ?? request.day)
    }

    private var availableCameras: [Camera] {
        library.cameras.filter(\.isEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Playback", systemImage: "play.rectangle")
                    .font(.title2.weight(.semibold))
                Text(
                    "Choose a camera and the moment to open on its recording timeline.",
                    bundle: .vigilUI
                )
                .foregroundStyle(.secondary)
            }

            Picker("Camera", selection: $cameraID) {
                Text("Choose a camera", bundle: .vigilUI).tag(CameraID?.none)
                ForEach(availableCameras) { camera in
                    Text(verbatim: camera.displayName).tag(Optional(camera.id))
                }
            }

            DatePicker(
                "Date and time", selection: $instant,
                displayedComponents: [.date, .hourAndMinute])

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                Button("Open Playback") { openPlayback() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(cameraID == nil)
            }
        }
        .padding(24)
        .frame(width: 480)
        .task { chooseDefaultCameraIfNeeded() }
    }

    private func chooseDefaultCameraIfNeeded() {
        guard cameraID == nil else { return }
        cameraID = availableCameras.first?.id
    }

    private func openPlayback() {
        guard let cameraID else { return }
        window.pendingDeepLink = .playback(
            .identifier(cameraID.rawValue), at: instant, speed: nil)
        openWindow(id: SceneID.main)
        close()
    }

    private func close() {
        dismissWindow(id: SceneID.playback)
    }
}

#endif  // os(macOS)
