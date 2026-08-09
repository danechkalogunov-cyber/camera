#if os(macOS)

import Foundation
import Testing
import VigilProtocols
@testable import VigilVideo

@Suite("Live audio playback")
struct AudioPlaybackEngineTests {
    private let key = StreamKey(camera: CameraID(), quality: .main)

    @Test func aNewRouteIsMutedAndMutedPCMStillUpdatesTheMeter() async {
        let engine = AudioPlaybackEngine()
        let format = AudioFormatInfo(codec: .pcmS16LE, sampleRate: 8_000,
                                     channels: 1, framesPerPacket: 1)
        let frame = EncodedFrame(
            data: Data([0x00, 0x40, 0x00, 0xC0]), codec: .audio(.pcmS16LE),
            pts: .zero, duration: MediaTimestamp(value: 2, timescale: 8_000),
            receivedAt: .zero, isKeyframe: false, audioFormat: format)

        await engine.submit(frame, for: key)
        let muted = await engine.isMuted(key)
        let statistics = await engine.statistics(for: key)

        #expect(muted)
        #expect(statistics.submittedFrames == 1)
        #expect(statistics.rmsLevel > 0.49)
        #expect(statistics.droppedFrames == 0)
    }

    @Test func muteAllAndRemoveRestoreTheSafeDefault() async {
        let engine = AudioPlaybackEngine()
        await engine.setMuted(false, for: key)
        await engine.muteAll()
        let mutedAfterAll = await engine.isMuted(key)
        await engine.remove(key)
        let mutedAfterRemoval = await engine.isMuted(key)

        #expect(mutedAfterAll)
        #expect(mutedAfterRemoval)
    }

    @Test func soloMakesExactlyOneRouteAudible() async {
        let engine = AudioPlaybackEngine()
        let other = StreamKey(camera: CameraID(), quality: .main)

        await engine.solo(key)
        let firstIsMuted = await engine.isMuted(key)
        #expect(!firstIsMuted)
        await engine.solo(other)

        let firstAfterSwitch = await engine.isMuted(key)
        let secondAfterSwitch = await engine.isMuted(other)
        #expect(firstAfterSwitch)
        #expect(!secondAfterSwitch)
    }
}

#endif  // os(macOS)
