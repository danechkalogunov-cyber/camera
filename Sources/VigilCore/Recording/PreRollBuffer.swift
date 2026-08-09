//
//  PreRollBuffer.swift
//  VigilCore
//
//  A bounded compressed-frame history for F-REC-02. Eviction and draining are GOP-aligned so the
//  first frame handed to a movie writer is always independently decodable.
//

#if os(macOS)

import VigilProtocols

public struct PreRollBuffer: Sendable {
    public struct GOP: Sendable, Equatable {
        public private(set) var frames: [EncodedFrame]
        public private(set) var startPTS: MediaTimestamp
        public private(set) var endPTS: MediaTimestamp
        public private(set) var byteCount: Int

        public var duration: Double {
            Swift.max(0, (endPTS - startPTS).seconds)
        }

        fileprivate init(first frame: EncodedFrame) {
            frames = [frame]
            startPTS = frame.pts
            endPTS = frame.pts
            byteCount = frame.byteCount
        }

        fileprivate mutating func append(_ frame: EncodedFrame) {
            frames.append(frame)
            endPTS = frame.pts
            byteCount += frame.byteCount
        }
    }

    private var storedTargetSeconds: Double
    public var targetSeconds: Double {
        get { storedTargetSeconds }
        set {
            storedTargetSeconds = newValue.isFinite
                ? Swift.min(Swift.max(newValue, 0), 30)
                : 0
        }
    }
    public var maxBytes: Int
    public var maxGOPs: Int
    public private(set) var gops: [GOP] = []

    public init(targetSeconds: Double = 10, maxBytes: Int = 24 << 20, maxGOPs: Int = 240) {
        self.storedTargetSeconds = targetSeconds.isFinite
            ? Swift.min(Swift.max(targetSeconds, 0), 30)
            : 0
        self.maxBytes = Swift.max(0, maxBytes)
        self.maxGOPs = Swift.max(0, maxGOPs)
    }

    /// Adds one video frame. Inter-pictures before the first keyframe are intentionally discarded.
    public mutating func append(_ frame: EncodedFrame) {
        guard frame.videoCodec?.isNALBased == true, !frame.isCorrupt else { return }
        if frame.isKeyframe {
            gops.append(GOP(first: frame))
        } else {
            guard !gops.isEmpty else { return }
            gops[gops.count - 1].append(frame)
        }
        evictToBudgets()
    }

    /// Returns a keyframe-first suffix reaching at least `seconds` into the past when possible.
    public func drain(seconds: Double) -> [EncodedFrame] {
        guard !gops.isEmpty, seconds.isFinite, seconds > 0 else { return [] }
        let newest = gops[gops.count - 1].endPTS
        let cutoffSeconds = newest.seconds - Swift.min(seconds, 30)
        var start = gops.startIndex
        for index in gops.indices where gops[index].startPTS.seconds <= cutoffSeconds {
            start = index
        }
        return gops[start...].flatMap(\.frames)
    }

    public var bufferedSeconds: Double {
        guard let first = gops.first, let last = gops.last else { return 0 }
        return Swift.max(0, (last.endPTS - first.startPTS).seconds)
    }

    public var byteCount: Int {
        gops.reduce(0) { $0 + $1.byteCount }
    }

    public mutating func reset() {
        gops.removeAll(keepingCapacity: true)
    }

    private mutating func evictToBudgets() {
        if targetSeconds == 0 || maxBytes == 0 || maxGOPs == 0 {
            gops.removeAll(keepingCapacity: true)
            return
        }
        while !gops.isEmpty,
              gops.count > maxGOPs || byteCount > maxBytes
                  || (gops.count > 1 && bufferedSeconds > targetSeconds) {
            // Eviction is always a whole GOP. The time target is soft for the newest GOP: deleting
            // that GOP would leave no decodable history until the camera emits another keyframe.
            // The byte and count ceilings remain hard safety properties, including for one GOP.
            gops.removeFirst()
        }
    }
}

#endif  // os(macOS)
