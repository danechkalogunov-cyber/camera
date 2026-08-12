//
//  AboutSceneView.swift
//  Vigil
//
//  Product and environment information with direct access to the user's local Vigil data.
//

#if os(macOS)

import AppKit
import SwiftUI

import VigilUI

@MainActor
struct AboutSceneView: View {

    @Bindable var library: AppLibraryModel
    @Bindable var window: MainWindowState

    @Environment(\.openWindow) private var openWindow

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private var architecture: String {
        #if arch(arm64)
        "Apple silicon"
        #elseif arch(x86_64)
        "Intel"
        #else
        "Unknown"
        #endif
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)
                Text(verbatim: "Vigil")
                    .font(.largeTitle.weight(.semibold))
                Text(verbatim: "\(version) (\(build))")
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 9) {
                informationRow("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                informationRow("Architecture", value: architecture)
                informationRow("Cameras", value: String(library.cameras.count))
                informationRow("Data location", value: dataLocation)
            }
            .padding(16)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))

            HStack {
                Button("Show Application Data") { showApplicationData() }
                    .disabled(library.storeDirectory == nil)
                Button("Open Recordings Folder") { openRecordings() }
                Button("Settings…") { openWindow(id: SceneID.settings) }
            }
        }
        .padding(28)
        .frame(width: 520)
    }

    private var dataLocation: String {
        guard let directory = library.storeDirectory else { return "Unavailable" }
        return (directory.path as NSString).abbreviatingWithTildeInPath
    }

    private func informationRow(_ label: LocalizedStringKey, value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .textSelection(.enabled)
        }
    }

    private func showApplicationData() {
        guard let directory = library.storeDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    private func openRecordings() {
        window.openRecordingsFolderRequests &+= 1
        openWindow(id: SceneID.main)
    }
}

#endif  // os(macOS)
