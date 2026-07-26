//
//  RingBufferTests.swift
//  VigilProtocolsTests
//
//  The fixed-capacity ring behind the health ring, the RTP reorder buffer and the
//  statistics reservoirs. Covers docs/API_CONTRACT.md §3.15 (ruling R-72).
//

import Foundation
import Testing
import VigilProtocols

@Suite struct RingBufferTests {

    @Test func ringBufferStartsEmptyAtItsCapacity() {
        let ring = RingBuffer(capacity: 4, repeating: 0)
        #expect(ring.capacity == 4)
        #expect(ring.count == 0)
        #expect(ring.isEmpty)
        #expect(!ring.isFull)
        #expect(ring.first == nil)
        #expect(ring.last == nil)
        #expect(ring.ordered().isEmpty)
    }

    @Test func ringBufferClampsANonsenseCapacityRatherThanTrapping() {
        var ring = RingBuffer(capacity: 0, repeating: 0)
        #expect(ring.capacity == 1)
        ring.append(7)
        #expect(ring.ordered() == [7])
        #expect(RingBuffer(capacity: -10, repeating: 0).capacity == 1)
    }

    @Test func ringBufferKeepsInsertionOrderUntilFull() {
        var ring = RingBuffer(capacity: 4, repeating: 0)
        for value in 1...3 {
            #expect(ring.append(value) == nil)
        }
        #expect(ring.count == 3)
        #expect(ring.ordered() == [1, 2, 3])
        #expect(ring.first == 1)
        #expect(ring.last == 3)
        #expect(!ring.isFull)
    }

    @Test func ringBufferOverwritesTheOldestAndReturnsIt() {
        var ring = RingBuffer(capacity: 3, repeating: 0)
        for value in 1...3 { ring.append(value) }
        #expect(ring.isFull)
        #expect(ring.append(4) == 1)
        #expect(ring.ordered() == [2, 3, 4])
        #expect(ring.append(5) == 2)
        #expect(ring.ordered() == [3, 4, 5])
        #expect(ring.count == 3)
    }

    @Test func ringBufferWrapsManyTimesWithoutDrift() {
        var ring = RingBuffer(capacity: 5, repeating: 0)
        for value in 1...1000 { ring.append(value) }
        #expect(ring.count == 5)
        #expect(ring.ordered() == [996, 997, 998, 999, 1000])
        #expect(ring[0] == 996)
        #expect(ring[4] == 1000)
    }

    @Test func ringBufferSubscriptCountsFromTheOldest() {
        var ring = RingBuffer(capacity: 3, repeating: 0)
        for value in 1...4 { ring.append(value) }
        #expect(ring[0] == 2)
        #expect(ring[1] == 3)
        #expect(ring[2] == 4)
    }

    @Test func ringBufferRemoveFirstDrainsInOrder() {
        var ring = RingBuffer(capacity: 3, repeating: 0)
        for value in 1...3 { ring.append(value) }
        #expect(ring.removeFirst() == 1)
        #expect(ring.removeFirst() == 2)
        #expect(ring.count == 1)
        #expect(ring.removeFirst() == 3)
        #expect(ring.removeFirst() == nil)
        #expect(ring.isEmpty)
        // The ring is reusable after draining, with no drift in the head index.
        ring.append(9)
        #expect(ring.ordered() == [9])
    }

    @Test func ringBufferSuffixNeverTrapsOnAnOutOfRangeCount() {
        var ring = RingBuffer(capacity: 4, repeating: 0)
        for value in 1...4 { ring.append(value) }
        #expect(ring.suffix(2) == [3, 4])
        #expect(ring.suffix(0).isEmpty)
        #expect(ring.suffix(-3).isEmpty)
        #expect(ring.suffix(99) == [1, 2, 3, 4])
    }

    @Test func ringBufferRemoveAllKeepsTheCapacity() {
        var ring = RingBuffer(capacity: 4, repeating: 0)
        for value in 1...6 { ring.append(value) }
        ring.removeAll()
        #expect(ring.isEmpty)
        #expect(ring.capacity == 4)
        #expect(ring.ordered().isEmpty)
        ring.append(1)
        #expect(ring.ordered() == [1])
    }

    @Test func ringBufferIsAValueTypeAndDoesNotShareStorage() {
        var original = RingBuffer(capacity: 3, repeating: 0)
        original.append(1)
        var copy = original
        copy.append(2)
        #expect(original.ordered() == [1])
        #expect(copy.ordered() == [1, 2])
    }

    @Test func ringBufferHoldsTheSixHundredSlotHealthWindow() {
        // HealthMonitor samples at 1 Hz into a fixed 600-slot ring per camera.
        var ring = RingBuffer(capacity: 600, repeating: StreamStatistics())
        for second in 0..<1200 {
            var sample = StreamStatistics()
            sample.framesDecoded = UInt64(second)
            ring.append(sample)
        }
        #expect(ring.count == 600)
        #expect(ring[0].framesDecoded == 600)
        #expect(ring[599].framesDecoded == 1199)
    }
}
