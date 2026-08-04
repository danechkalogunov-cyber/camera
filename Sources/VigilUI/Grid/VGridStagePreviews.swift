//
//  VGridStagePreviews.swift
//  VigilUI
//
//  Design-time previews for the camera grid stage.
//  Supports Sources/VigilUI/Grid/VGridStageView.swift.
//
//  ⚠️ THE FIXTURE TYPES ARE AT FILE SCOPE, NOT IN `extension VGridStageView`. Two things break the
//  moment they move inside it, and neither error names the extension:
//
//  1. `VGridStageView` is generic over `Video`, so a type nested in its extension is generic too —
//     and a generic type may not hold a static stored property. `private static let names` stops
//     compiling with "static stored properties not supported in generic types".
//  2. Inside that extension the bare name `VGridStageView` means `VGridStageView<Video>`, so the
//     `video:` closure is required to return the caller's `Video` — not the concrete preview
//     picture the fixture actually builds. The stand-in is rejected against a type parameter no
//     preview ever binds.
//
//  At file scope the host names `VGridStageView` itself, `Video` is inferred from the closure, and
//  both problems are gone.
//

#if os(macOS)
#if DEBUG && !VIGIL_NO_PREVIEWS

import Foundation
import SwiftUI
import VigilProtocols

// MARK: - GridStagePreviewPicture

/// A stand-in for the renderer: a still, so the previews show tiles that read as camera frames
/// rather than as flat black rectangles.
@MainActor
private struct GridStagePreviewPicture: View {
    let seed: Int

    var body: some View {
        let shades = [
            SwiftUI.Color(white: 0.05 + 0.02 * Double(seed % 4)),
            SwiftUI.Color(white: 0.24 + 0.03 * Double(seed % 3)),
        ]
        LinearGradient(colors: shades, startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - GridStagePreviewHost

/// Preview host: the cameras are built once, in `init`. Building them in `body` would mint new
/// identifiers on every evaluation and the assignment would stop matching them.
///
/// The six states are the mockup's, in its order: live and recording, live, connecting, live,
/// degraded, offline (`design/mockups/01-main-window.html`).
@MainActor
private struct GridStagePreviewHost: View {
    private let cameras: [VStageCamera]
    private let assignment: VStageAssignment
    private let mode: VStageMode
    private let focusedIndex: Int?

    private static let names = [
        "Front Door", "Garage", "Lobby", "Back Yard", "Side Gate", "Hallway",
    ]

    private static func state(_ index: Int) -> LiveConnectionState {
        switch index % 6 {
        case 2: return .connecting(.negotiating)
        case 4: return .degraded(.packetLoss(fraction: 0.031))
        case 5: return .offline(OfflineDetail(attempt: 3, retryInSeconds: 8))
        default: return .live
        }
    }

    private static func makeCameras(_ count: Int) -> [VStageCamera] {
        (0..<count).map { index in
            let name = names[index % names.count]
            let identity = LiveCameraIdentity(
                id: UUID(),
                name: index < names.count ? name : "\(name) \(index)",
                host: "192.168.1.\(64 + index)")
            return VStageCamera(
                camera: identity,
                state: state(index),
                isRecording: index == 0,
                recordingElapsed: index == 0 ? Duration.seconds(252) : nil,
                stats: VTileStats(
                    codec: index % 2 == 0 ? "H.265" : "H.264",
                    dimensions: FrameDimensions(
                        width: 1920,
                        height: 1080),
                    framesPerSecond: 25,
                    isHardwareDecode: true))
        }
    }

    init(
        layout: VGridLayout,
        cameraCount: Int,
        promotesFirst: Bool = false,
        focusedIndex: Int? = 0
    ) {
        let made = Self.makeCameras(cameraCount)
        self.cameras = made
        self.assignment = VStageAssignment(layout: layout, cameras: made.map { $0.id })
        self.mode = promotesFirst ? (made.first.map { VStageMode.focus($0.id) } ?? .grid) : .grid
        self.focusedIndex = focusedIndex
    }

    var body: some View {
        VGridStageView(
            assignment: assignment,
            mode: mode,
            cameras: cameras,
            selection: cameras.first?.id,
            focusedIndex: focusedIndex
        ) { camera in
            GridStagePreviewPicture(seed: abs(camera.rawValue.hashValue % 6))
        }
        .frame(width: 1040, height: 640)
    }
}

// MARK: - Previews

#Preview("Stage — the mockup's mosaic, 6 of 9") {
    GridStagePreviewHost(layout: .mosaic4x3, cameraCount: 6)
}

#Preview("Stage — 2 × 2, full") {
    GridStagePreviewHost(layout: .grid2x2, cameraCount: 4)
}

#Preview("Stage — 4 × 4, 5 of 16") {
    GridStagePreviewHost(layout: .grid4x4, cameraCount: 5)
}

#Preview("Stage — hero 1 + 5") {
    GridStagePreviewHost(layout: .hero1p5, cameraCount: 6, focusedIndex: 1)
}

#Preview("Stage — promoted tile") {
    GridStagePreviewHost(layout: .grid3x3, cameraCount: 5, promotesFirst: true)
}

#Preview("Stage — overflow") {
    GridStagePreviewHost(layout: .grid2x2, cameraCount: 7)
}

#endif  // DEBUG && !VIGIL_NO_PREVIEWS
#endif  // os(macOS)
