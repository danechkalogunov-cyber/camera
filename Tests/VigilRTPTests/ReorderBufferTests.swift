//
//  ReorderBufferTests.swift
//  VigilRTPTests
//
//  The reorder buffer across the 16-bit sequence wrap, and the difference between the TCP
//  passthrough policy and the UDP adaptive one.
//  Covers docs/spec-rtp.md §10 and docs/API_CONTRACT.md §4.4.
//

import Foundation
import Testing

import VigilProtocols
@testable import VigilRTP

@Suite struct ReorderBufferBehaviour {

    /// A minimal packet carrying its sequence number in the payload, so a released run can be
    /// checked without any codec involvement.
    static func packet(_ sequence: UInt16, timestamp: UInt32 = 0) -> RTPPacket {
        RTPPacket(payloadType: 96, sequenceNumber: sequence, timestamp: timestamp,
                  ssrc: 0x1234_5678, payload: Data([0x41, UInt8(truncatingIfNeeded: sequence)]))
    }

    static func at(_ milliseconds: Int) -> MediaInstant {
        MediaInstant(nanoseconds: Int64(milliseconds) * 1_000_000)
    }

    // MARK: - Wraparound

    @Test func reorderBufferEmitsAnInOrderRunAcrossTheWrap() {
        var buffer = ReorderBuffer.udpLive
        var released: [UInt16] = []
        for step in 0..<20 {
            let sequence = UInt16(truncatingIfNeeded: 65_530 + step)
            let out = buffer.push(Self.packet(sequence), at: Self.at(step * 20))
            released += out.packets.map(\.sequenceNumber)
            #expect(out.gaps.isEmpty)
            #expect(out.late == 0)
            #expect(out.duplicates == 0)
        }
        #expect(released == (0..<20).map { UInt16(truncatingIfNeeded: 65_530 + $0) })
        #expect(buffer.depth == 0)
    }

    @Test func reorderBufferOrdersASwappedPairAcrossTheWrap() {
        var buffer = ReorderBuffer.udpLive
        var released: [UInt16] = []
        // 65534, then 0 before 65535 — the swap that a naive `<` comparison never recovers from.
        for (index, sequence) in [UInt16(65_534), 0, 65_535, 1, 2].enumerated() {
            let out = buffer.push(Self.packet(sequence), at: Self.at(index * 10))
            released += out.packets.map(\.sequenceNumber)
        }
        #expect(released == [65_534, 65_535, 0, 1, 2])
        #expect(buffer.depth == 0)
    }

    @Test func reorderBufferDropsADuplicateAcrossTheWrap() {
        var buffer = ReorderBuffer.udpLive
        var released: [UInt16] = []
        var duplicates = 0
        for (index, sequence) in [UInt16(65_534), 65_535, 65_535, 0, 1].enumerated() {
            let out = buffer.push(Self.packet(sequence), at: Self.at(index * 10))
            released += out.packets.map(\.sequenceNumber)
            duplicates += out.duplicates
        }
        #expect(released == [65_534, 65_535, 0, 1])
        #expect(duplicates == 1)
    }

    @Test func reorderBufferReportsAGapThatStraddlesTheWrapAsTwoRanges() {
        var buffer = ReorderBuffer.udpLive
        _ = buffer.push(Self.packet(65_533), at: Self.at(0))
        // 65534, 65535 and 0 never arrive. The hold bound declares them lost after 60 ms.
        let held = buffer.push(Self.packet(1), at: Self.at(10))
        #expect(held.packets.isEmpty)
        #expect(held.reordered == 1)
        #expect(buffer.depth == 1)

        let drained = buffer.drain(at: Self.at(100))
        #expect(drained.packets.map(\.sequenceNumber) == [1])
        #expect(drained.gaps == [65_534...65_535, 0...0])
        #expect(drained.lostCount == 3)
        #expect(buffer.depth == 0)
    }

    @Test func reorderBufferCountsALatePacketRatherThanReleasingItTwice() {
        var buffer = ReorderBuffer.udpLive
        _ = buffer.push(Self.packet(100), at: Self.at(0))
        _ = buffer.push(Self.packet(101), at: Self.at(10))
        let late = buffer.push(Self.packet(99), at: Self.at(20))
        #expect(late.packets.isEmpty)
        #expect(late.late == 1)
        #expect(late.duplicates == 0)
    }

    @Test func reorderBufferForceFlushesWhenTheHoleExceedsItsCapacity() {
        var buffer = ReorderBuffer(mode: .adaptive, capacity: 8, maxHold: .milliseconds(60))
        _ = buffer.push(Self.packet(10), at: Self.at(0))
        // A jump of 500 is far wider than the 8-slot ring: the hole is declared at once.
        let out = buffer.push(Self.packet(511), at: Self.at(10))
        #expect(out.packets.map(\.sequenceNumber) == [511])
        #expect(out.lostCount == 500)
        #expect(out.gaps == [11...510])
        #expect(buffer.depth == 0)
    }

    @Test func reorderBufferEscalatesAndRelaxesWithoutLosingHeldPackets() {
        var buffer = ReorderBuffer.udpLive
        #expect(buffer.capacity == 128)
        _ = buffer.push(Self.packet(1), at: Self.at(0))
        _ = buffer.push(Self.packet(5), at: Self.at(10))       // held, waiting for 2…4
        #expect(buffer.depth == 1)
        let escalated = buffer.escalate()
        #expect(escalated)
        #expect(buffer.capacity == 512)
        #expect(buffer.maxHold == .milliseconds(200))
        #expect(buffer.depth == 1, "the held packet must survive a depth change")
        let escalatedAgain = buffer.escalate()
        let relaxed = buffer.relax()
        #expect(escalatedAgain == false)
        #expect(relaxed)
        #expect(buffer.capacity == 128)
        #expect(buffer.depth == 1)
        let drained = buffer.drain(at: Self.at(200))
        #expect(drained.packets.map(\.sequenceNumber) == [5])
        #expect(drained.gaps == [2...4])
    }

    // MARK: - Policy comparison

    @Test func reorderBufferPassthroughAddsZeroLatencyForTheSameSequence() {
        // The identical out-of-order run through both policies. On TCP the transport already
        // ordered the stream, so every packet must come straight back out of the same push call.
        let sequence: [UInt16] = [100, 101, 103, 102, 104, 105]

        var passthrough = ReorderBuffer.tcpInterleaved
        var passthroughReleaseIndex: [Int] = []
        var passthroughOrder: [UInt16] = []
        for (index, number) in sequence.enumerated() {
            let out = passthrough.push(Self.packet(number), at: Self.at(index * 20))
            #expect(out.packets.count == 1, "passthrough must never hold a packet")
            passthroughOrder += out.packets.map(\.sequenceNumber)
            passthroughReleaseIndex += out.packets.map { _ in index }
        }
        #expect(passthroughOrder == sequence, "passthrough must not reorder either")
        #expect(passthroughReleaseIndex == Array(0..<sequence.count))
        #expect(passthrough.depth == 0)
        #expect(passthrough.bufferedMilliseconds(at: Self.at(1000)) == 0)
        #expect(passthrough.nextDeadline == nil)

        var adaptive = ReorderBuffer.udpLive
        var adaptiveOrder: [UInt16] = []
        var deferredPackets = 0
        for (index, number) in sequence.enumerated() {
            let out = adaptive.push(Self.packet(number), at: Self.at(index * 20))
            if out.packets.isEmpty { deferredPackets += 1 }
            adaptiveOrder += out.packets.map(\.sequenceNumber)
        }
        #expect(adaptiveOrder == [100, 101, 102, 103, 104, 105], "adaptive must fix the order")
        #expect(deferredPackets == 1, "103 waits for 102, which is the latency passthrough avoids")
    }

    @Test func reorderBufferPassthroughStillReportsLossAndDuplicates() {
        // On TCP a sequence discontinuity means the camera dropped packets, so it still counts.
        var buffer = ReorderBuffer.tcpInterleaved
        _ = buffer.push(Self.packet(10), at: Self.at(0))
        let gapped = buffer.push(Self.packet(14), at: Self.at(10))
        #expect(gapped.packets.count == 1)
        #expect(gapped.gaps == [11...13])
        #expect(gapped.lostCount == 3)
        let duplicate = buffer.push(Self.packet(14), at: Self.at(20))
        #expect(duplicate.duplicates == 1)
        #expect(duplicate.packets.count == 1, "a counter, never a filter")
    }

    @Test func reorderBufferResetForgetsEverything() {
        var buffer = ReorderBuffer.udpLive
        _ = buffer.push(Self.packet(1), at: Self.at(0))
        _ = buffer.push(Self.packet(9), at: Self.at(10))
        #expect(buffer.depth == 1)
        buffer.reset()
        #expect(buffer.depth == 0)
        #expect(buffer.nextDeadline == nil)
        let out = buffer.push(Self.packet(500), at: Self.at(20))
        #expect(out.packets.map(\.sequenceNumber) == [500])
        #expect(out.gaps.isEmpty, "a reset buffer has no expectation to violate")
    }

    @Test func reorderBufferRoundsCapacityUpToAPowerOfTwoAndCaps() {
        #expect(ReorderBuffer(mode: .adaptive, capacity: 100, maxHold: .zero).capacity == 128)
        #expect(ReorderBuffer(mode: .adaptive, capacity: 1, maxHold: .zero).capacity == 1)
        #expect(ReorderBuffer(mode: .adaptive, capacity: 0, maxHold: .zero).capacity == 1)
        #expect(ReorderBuffer(mode: .adaptive, capacity: 99_999, maxHold: .zero).capacity
                == ReorderBuffer.maximumCapacity)
        #expect(ReorderBuffer.tcpInterleaved.capacity == 0)
    }
}
