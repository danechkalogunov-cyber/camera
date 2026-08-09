//
//  DecodeModeGateTests.swift
//  VigilVideoTests
//
//  F-DEC-06: the admission plan must change what reaches the decoder, not merely describe it.
//

#if os(macOS)

import Foundation
import Testing
@testable import VigilVideo
import VigilProtocols

@Suite("Decode mode frame gate")
struct DecodeModeGateTests {
    private func frame(_ index: Int64, keyframe: Bool = false,
                       dropClass: FrameDropClass = .required) -> EncodedFrame {
        EncodedFrame(
            data: Data([0, 0, 0, 1, 0x65]), codec: .video(.h264),
            pts: MediaTimestamp(value: index * 3_000, timescale: 90_000),
            receivedAt: .zero, isKeyframe: keyframe, dropClass: dropClass)
    }

    @Test func fullAdmitsEveryFrame() {
        var gate = DecodeModeGate(mode: .full)
        let keyframe = gate.admits(frame(0, keyframe: true))
        let inter = gate.admits(frame(1))
        #expect(keyframe)
        #expect(inter)
    }

    @Test func keyframesOnlyRejectsInterPictures() {
        var gate = DecodeModeGate(mode: .keyframesOnly)
        let keyframe = gate.admits(frame(0, keyframe: true))
        let inter = gate.admits(frame(1))
        #expect(keyframe)
        #expect(!inter)
    }

    @Test func fpsCapAllowsAtMostFifteenFramesPerSecondButNeverDelaysAKeyframe() {
        var gate = DecodeModeGate(mode: .fpsCapped)
        let first = gate.admits(frame(0))
        let tooSoon = gate.admits(frame(1))
        let nextSlot = gate.admits(frame(2))
        let keyframe = gate.admits(frame(3, keyframe: true))
        #expect(first)
        #expect(!tooSoon, "33 ms is below the 15 fps cadence")
        #expect(nextSlot, "66 ms reaches the next cadence slot")
        #expect(keyframe, "recovery points always pass")
    }

    @Test func trimDropsOnlyFramesProvenDisposableByTheBitstreamLayer() {
        var gate = DecodeModeGate(mode: .trim)
        let required = gate.admits(frame(0, dropClass: .required))
        let nonReference = gate.admits(frame(1, dropClass: .droppableNonReference))
        let temporal = gate.admits(frame(2, dropClass: .droppableTemporal))
        let keyframe = gate.admits(frame(3, keyframe: true, dropClass: .droppableTemporal))
        #expect(required)
        #expect(!nonReference)
        #expect(!temporal)
        #expect(keyframe)
    }

    @Test func zeroSessionModesAdmitNoVideo() {
        var gate = DecodeModeGate(mode: .paused)
        let paused = gate.admits(frame(0, keyframe: true))
        gate.setMode(.jpegPoll)
        let jpegPoll = gate.admits(frame(1, keyframe: true))
        #expect(!paused)
        #expect(!jpegPoll)
    }

    @Test func changingModeResetsTheRateCadence() {
        var gate = DecodeModeGate(mode: .fpsCapped)
        let first = gate.admits(frame(0))
        let tooSoon = gate.admits(frame(1))
        gate.setMode(.full)
        gate.setMode(.fpsCapped)
        let afterReset = gate.admits(frame(1))
        #expect(first)
        #expect(!tooSoon)
        #expect(afterReset)
    }
}

#endif  // os(macOS)
