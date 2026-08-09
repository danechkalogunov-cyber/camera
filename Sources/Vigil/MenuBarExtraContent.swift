//
//  MenuBarExtraContent.swift
//  Vigil
//
//  The window-independent status and action surface required by F-AUT-05.
//

#if os(macOS)

import AppKit
import ImageIO
import Observation
import SwiftUI

import VigilISAPI
import VigilProtocols
import VigilUI

// MARK: - Badge

enum MenuBarBadgeState: Equatable {
    case offline(Int)
    case degraded
    case recording(Int)
    case unread(Int)
    case nominal

    @MainActor
    static func resolve(streams: [CameraStream], isRecording: Bool,
                        unreadEvents: Int) -> MenuBarBadgeState {
        let offline = streams.filter { stream in
            if case .offline = stream.liveState { return true }
            return false
        }.count
        if offline > 0 { return .offline(offline) }
        if streams.contains(where: { stream in
            if case .degraded = stream.liveState { return true }
            return false
        }) { return .degraded }
        let recording = streams.filter { $0.recordingTap.recorder() != nil }.count
        if isRecording || recording > 0 { return .recording(max(recording, 1)) }
        if unreadEvents > 0 { return .unread(unreadEvents) }
        return .nominal
    }
}

struct MenuBarExtraLabel: View {
    let session: AppSessionModel
    let isRecording: Bool
    @Bindable var window: MainWindowState

    private var badge: MenuBarBadgeState {
        MenuBarBadgeState.resolve(streams: session.cameras.all, isRecording: isRecording,
                                  unreadEvents: window.unreadEventCount)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "video.badge.waveform")
            switch badge {
            case .offline(let count):
                badgeCircle(.red, text: String(count))
            case .degraded:
                badgeCircle(.orange)
            case .recording(let count):
                badgeRing(.red, text: String(count))
            case .unread(let count):
                badgeCircle(.blue, text: String(count))
            case .nominal:
                EmptyView()
            }
        }
        .accessibilityLabel("Vigil")
    }

    private func badgeCircle(_ color: Color, text: String? = nil) -> some View {
        ZStack {
            Circle().fill(color).frame(width: 9, height: 9)
            if let text {
                Text(verbatim: text).font(.system(size: 6, weight: .bold)).foregroundStyle(.white)
            }
        }
        .offset(x: 4, y: -3)
    }

    private func badgeRing(_ color: Color, text: String) -> some View {
        ZStack {
            Circle().stroke(color, lineWidth: 2).frame(width: 10, height: 10)
            Text(verbatim: text).font(.system(size: 6, weight: .bold)).foregroundStyle(color)
        }
        .offset(x: 4, y: -3)
    }
}

// MARK: - Content

struct MenuBarExtraContent: View {
    @Environment(\.openWindow) private var openWindow

    let session: AppSessionModel
    @Bindable var window: MainWindowState
    @State private var thumbnails = MenuBarThumbnailStore()

    private var rows: [CameraStream] {
        Array(session.cameras.all.sorted {
            ($0.camera?.displayName ?? "") < ($1.camera?.displayName ?? "")
        }.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image("MenuBarIcon", bundle: .vigilUI)
                    .resizable().frame(width: 20, height: 20)
                Text(verbatim: "Vigil").font(.headline)
                Spacer()
                Text(verbatim: "\(rows.filter(\.isActive).count)/\(rows.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            if rows.isEmpty {
                Text(MainWindowView.localized("No cameras yet"))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 54)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { row in
                        cameraCell(row.element)
                    }
                }
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    action("Snapshot every enabled camera", symbol: "camera.on.rectangle") {
                        deferToMainWindow(.snapshotAll)
                    }
                    action(window.isRecording ? "Stop Recording" : "Start Recording",
                           symbol: window.isRecording ? "stop.circle.fill" : "record.circle") {
                        deferToMainWindow(.recordToggle)
                    }
                }
                GridRow {
                    action("Discover Cameras…", symbol: "dot.radiowaves.left.and.right") {
                        deferToMainWindow(.discover)
                    }
                    action("Video Wall", symbol: "rectangle.grid.2x2") {
                        openWindow(id: SceneID.wall)
                    }
                }
                GridRow {
                    action("Open Vigil", symbol: "macwindow") { openWindow(id: SceneID.main) }
                    action("Mute All Audio", symbol: "speaker.slash.fill") {
                        session.muteAllAudio()
                    }
                }
                GridRow {
                    action("Disconnect", symbol: "stop.fill") { session.disconnect() }
                }
            }

            Divider()
            Button(MainWindowView.localized("Quit Vigil")) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 340)
        .task(id: rows.compactMap { $0.camera?.id }) {
            await thumbnails.poll(cameras: rows.compactMap(\.camera), session: session)
        }
    }

    private func cameraCell(_ stream: CameraStream) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let id = stream.camera?.id, let image = thumbnails.images[id] {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: "video.slash")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 5) {
                Circle().fill(statusColor(stream.liveState)).frame(width: 7, height: 7)
                Text(verbatim: stream.camera?.displayName ?? "—")
                    .font(.caption.weight(.medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(.black.opacity(0.62))
            .foregroundStyle(.white)
        }
        .frame(height: 78)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stream.camera?.displayName ?? "Vigil")
        .accessibilityValue(stream.liveState.statusWord)
    }

    private func statusColor(_ state: LiveConnectionState) -> Color {
        switch state {
        case .live: .green
        case .degraded: .orange
        case .connecting: .blue
        case .offline: .red
        case .paused: .secondary
        case .noRecording: .secondary
        }
    }

    private func action(_ title: String, symbol: String,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(MainWindowView.localized(title), systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
    }

    private func deferToMainWindow(_ request: MainWindowState.DeferredRequest) {
        window.deferredRequest = request
        openWindow(id: SceneID.main)
    }
}

// MARK: - JPEG polling

/// Small device-rendered pictures for the menu extra; no media decoder or second RTSP session.
@MainActor
@Observable
final class MenuBarThumbnailStore {
    private(set) var images: [CameraID: CGImage] = [:]

    /// Polls at the required 1 Hz while the menu window exists, capped by the caller at eight.
    func poll(cameras: [Camera], session: AppSessionModel) async {
        let wanted = Set(cameras.map(\.id))
        images = images.filter { wanted.contains($0.key) }
        while !Task.isCancelled {
            await refresh(cameras: cameras, session: session)
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
        }
    }

    private func refresh(cameras: [Camera], session: AppSessionModel) async {
        var authenticated: [(Camera, Credential)] = []
        for camera in cameras.prefix(8) {
            guard let credential = try? await session.credentials.credential(
                for: camera.credentialRef) else { continue }
            authenticated.append((camera, credential))
        }

        let logger = session.dependencies.logger
        let clock = session.dependencies.clock
        await withTaskGroup(of: (CameraID, Data?).self) { group in
            for (camera, credential) in authenticated {
                group.addTask {
                    let client = ISAPIClient(
                        endpoint: ISAPIEndpoint(host: camera.host, port: camera.httpPort,
                                                useTLS: camera.useTLS),
                        credential: credential,
                        transport: URLSessionHTTPTransport(logger: logger),
                        clock: clock,
                        logger: logger)
                    let route = SnapshotDeviceRoute(requester: client, clock: clock)
                    return (camera.id, try? await route.fetchJPEG(channel: camera.channel))
                }
            }
            for await (id, jpeg) in group {
                guard let jpeg,
                      let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 320,
                      ] as CFDictionary) else { continue }
                images[id] = image
            }
        }
    }
}

#endif  // os(macOS)
