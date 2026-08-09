//
//  PreRollBufferTests.swift
//  VigilCoreTests
//

#if os(macOS)

import Foundation
import Testing
@testable import VigilCore
import VigilProtocols

@Suite("Recording pre-roll buffer")
struct PreRollBufferTests {
    private func frame(_ seconds: Int64, keyframe: Bool = false,
                       bytes: Int = 4) -> EncodedFrame {
        EncodedFrame(
            data: Data(repeating: 0x55, count: bytes), codec: .video(.h264),
            pts: MediaTimestamp(value: seconds * 90_000, timescale: 90_000),
            receivedAt: .zero, isKeyframe: keyframe)
    }

    @Test func framesBeforeTheFirstKeyframeAreDiscarded() {
        var buffer = PreRollBuffer()
        buffer.append(frame(0))
        #expect(buffer.gops.isEmpty)
    }

    @Test func drainAlwaysStartsAtAKeyframeAndIncludesTheLiveEdge() throws {
        var buffer = PreRollBuffer(targetSeconds: 30)
        buffer.append(frame(0, keyframe: true))
        buffer.append(frame(1))
        buffer.append(frame(4, keyframe: true))
        buffer.append(frame(5))
        buffer.append(frame(8, keyframe: true))
        buffer.append(frame(9))

        let drained = buffer.drain(seconds: 3)
        let first = try #require(drained.first)
        #expect(first.isKeyframe)
        #expect(first.pts.seconds == 4, "the GOP at or before the six-second cutoff is retained")
        #expect(drained.last?.pts.seconds == 9)
    }

    @Test func timeEvictionRemovesWholeGOPs() {
        var buffer = PreRollBuffer(targetSeconds: 5)
        for second in 0...8 {
            buffer.append(frame(Int64(second), keyframe: second.isMultiple(of: 2)))
        }
        #expect(buffer.bufferedSeconds <= 5)
        #expect(buffer.gops.first?.frames.first?.isKeyframe == true)
        #expect(buffer.gops.flatMap(\.frames).contains { $0.pts.seconds == 0 } == false)
    }

    @Test func byteCeilingIsHardEvenForOneOversizedGOP() {
        var buffer = PreRollBuffer(targetSeconds: 10, maxBytes: 8)
        buffer.append(frame(0, keyframe: true, bytes: 6))
        buffer.append(frame(1, bytes: 6))
        #expect(buffer.byteCount <= 8)
        #expect(buffer.gops.isEmpty)
    }

    @Test func timeTargetKeepsTheNewestCompleteGOP() {
        var buffer = PreRollBuffer(targetSeconds: 2)
        buffer.append(frame(0, keyframe: true))
        buffer.append(frame(5))

        #expect(buffer.gops.count == 1)
        #expect(buffer.gops.first?.frames.first?.isKeyframe == true)
        #expect(buffer.bufferedSeconds == 5)
    }

    @Test func resetReleasesEveryBufferedByte() {
        var buffer = PreRollBuffer()
        buffer.append(frame(0, keyframe: true, bytes: 1024))
        buffer.reset()
        #expect(buffer.byteCount == 0)
        #expect(buffer.bufferedSeconds == 0)
    }
}

#endif  // os(macOS)
