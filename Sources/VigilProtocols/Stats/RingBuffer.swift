//
//  RingBuffer.swift
//  VigilProtocols
//
//  Fixed-capacity ring used by the health ring, the RTP reorder buffer, the frame queue
//  and the statistics reservoirs.
//
//  Implements docs/API_CONTRACT.md §3.15 (ruling R-72).
//

/// Fixed-capacity ring. Preallocated at construction; O(1) append; **zero allocation** afterwards.
/// Used by `HealthRing`, the RTP reorder buffer, `FrameQueue` and the statistics reservoirs.
///
/// The storage never shrinks and never grows: `removeFirst()` and `removeAll()` only move indices,
/// so an element that has been removed stays alive in the backing array until it is overwritten.
/// That is the price of the no-allocation guarantee on the per-packet path, and it is why the
/// element type should be a value type — a ring of class references would keep them alive longer
/// than the caller expects.
public struct RingBuffer<Element>: Sendable where Element: Sendable {
    /// Number of slots. Always at least 1.
    public let capacity: Int
    /// Number of slots currently occupied, `0...capacity`.
    public private(set) var count: Int

    private var storage: [Element]
    /// Index of the oldest element in `storage`.
    private var head: Int

    /// Allocates `capacity` slots, all initialised to `repeating`.
    ///
    /// A `capacity` below 1 is clamped to 1: a zero-slot ring cannot satisfy any of its own
    /// postconditions, and trapping here would take the app down for a configuration mistake.
    public init(capacity: Int, repeating: Element) {
        let slots = Swift.max(1, capacity)
        self.capacity = slots
        self.storage = [Element](repeating: repeating, count: slots)
        self.count = 0
        self.head = 0
    }

    /// True when no element has been appended since the last `removeAll()`.
    @inlinable public var isEmpty: Bool { count == 0 }

    /// True when the next `append` will evict.
    @inlinable public var isFull: Bool { count == capacity }

    /// The oldest element, or `nil` when empty.
    public var first: Element? { count == 0 ? nil : storage[head] }

    /// The newest element, or `nil` when empty.
    public var last: Element? {
        count == 0 ? nil : storage[(head + count - 1) % capacity]
    }

    /// Overwrites the oldest element when full. Returns the evicted element, if any.
    @discardableResult
    public mutating func append(_ element: Element) -> Element? {
        if count < capacity {
            storage[(head + count) % capacity] = element
            count += 1
            return nil
        }
        let evicted = storage[head]
        storage[head] = element
        head = (head + 1) % capacity
        return evicted
    }

    /// Removes and returns the oldest element, or `nil` when empty.
    public mutating func removeFirst() -> Element? {
        guard count > 0 else { return nil }
        let element = storage[head]
        head = (head + 1) % capacity
        count -= 1
        return element
    }

    /// Every occupied slot, oldest → newest. Allocates; never call it on the packet path.
    public func ordered() -> [Element] {
        var out = [Element]()
        out.reserveCapacity(count)
        for offset in 0..<count {
            out.append(storage[(head + offset) % capacity])
        }
        return out
    }

    /// The newest `n` elements, oldest → newest. `n` above `count` yields everything, `n` below 1
    /// yields an empty array — it never traps.
    public func suffix(_ n: Int) -> [Element] {
        let wanted = Swift.min(Swift.max(0, n), count)
        guard wanted > 0 else { return [] }
        var out = [Element]()
        out.reserveCapacity(wanted)
        for offset in (count - wanted)..<count {
            out.append(storage[(head + offset) % capacity])
        }
        return out
    }

    /// Index 0 is the oldest element, `count - 1` the newest.
    ///
    /// Traps on an out-of-range index. This is an index into a buffer the caller owns and sized,
    /// never a value taken from the network, so it is programmer error by construction.
    public subscript(_ i: Int) -> Element {
        get {
            precondition(i >= 0 && i < count,
                         "RingBuffer index \(i) out of range for count \(count)")
            return storage[(head + i) % capacity]
        }
    }

    /// Empties the ring without releasing its storage.
    public mutating func removeAll() {
        count = 0
        head = 0
    }
}
