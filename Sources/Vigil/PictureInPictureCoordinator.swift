//
//  PictureInPictureCoordinator.swift
//  Vigil
//
//  Floating live camera fallback from F-LIV-08. AVPictureInPictureController's sample-buffer
//  source cannot consume Vigil's Metal pixel-buffer backend, so this uses the documented reduced
//  acceptance: one always-on-top NSPanel hosting the same VideoTile and FrameStreamHandle.
//

#if os(macOS)

import AppKit
import SwiftUI

import VigilCore
import VigilRender

@MainActor
final class PictureInPictureCoordinator: NSObject, NSWindowDelegate {
    private weak var activeStream: CameraStream?
    private weak var session: AppSessionModel?
    private var panel: NSPanel?

    var isPresented: Bool { panel?.isVisible == true }

    func toggle(camera: Camera, stream: CameraStream, session: AppSessionModel) {
        if activeStream === stream, let panel, panel.isVisible {
            panel.performClose(nil)
            return
        }
        activeStream?.isPictureInPicture = false
        activeStream = stream
        self.session = session
        stream.isPictureInPicture = true
        session.rebalanceDecodeBudget()

        let video = VideoTile(
            cameraID: camera.id,
            frames: stream.frames,
            options: TileRenderOptions(gravity: .fit),
            logger: session.dependencies.logger,
            onKeyframeNeeded: { session.recoverStalledPicture(on: stream) },
            onDecodeFailure: { session.handleDecodeFailure($0, on: stream) },
            onFramesDropped: { session.handleFramesDropped($0, reason: $1, on: stream) })
        let content = ZStack(alignment: .topLeading) {
            Color.black
            video
            Text(verbatim: camera.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.black.opacity(0.62), in: Capsule())
                .padding(8)
        }
        let host = NSHostingView(rootView: content)
        let panel = self.panel ?? makePanel()
        panel.title = camera.displayName
        panel.contentView = host
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() { panel?.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
        panel?.contentView = nil
        activeStream?.isPictureInPicture = false
        activeStream = nil
        session?.rebalanceDecodeBudget()
        session = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false)
        panel.delegate = self
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentAspectRatio = NSSize(width: 16, height: 9)
        panel.minSize = NSSize(width: 256, height: 144)
        panel.center()
        return panel
    }
}

#endif
