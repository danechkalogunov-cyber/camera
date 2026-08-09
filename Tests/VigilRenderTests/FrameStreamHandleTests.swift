#if os(macOS)

import Testing
import VigilProtocols
@testable import VigilRender

@Suite @MainActor struct FrameStreamHandleTests {
    @Test func detachingTemporaryViewRestoresMountedTile() {
        let handle = FrameStreamHandle()
        let tile = VideoTileView(cameraID: CameraID(),
                                 options: TileRenderOptions(backend: .sampleBufferLayer))
        let floating = VideoTileView(cameraID: CameraID(),
                                     options: TileRenderOptions(backend: .sampleBufferLayer))

        handle.attach(tile)
        handle.attach(floating)
        #expect(handle.sink === floating)

        handle.detach(floating)
        #expect(handle.sink === tile)
    }

    @Test func dismantlingCoveredTileDoesNotDetachFloatingView() {
        let handle = FrameStreamHandle()
        let tile = VideoTileView(cameraID: CameraID(),
                                 options: TileRenderOptions(backend: .sampleBufferLayer))
        let floating = VideoTileView(cameraID: CameraID(),
                                     options: TileRenderOptions(backend: .sampleBufferLayer))
        handle.attach(tile)
        handle.attach(floating)

        handle.detach(tile)
        #expect(handle.sink === floating)
    }
}

#endif
