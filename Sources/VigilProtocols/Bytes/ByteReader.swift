//
//  ByteReader.swift
//  VigilProtocols
//
//  Bounds-checked, non-owning, allocation-free cursor for parsing a byte buffer that came off the
//  network: every read either returns a value or throws, and no read can trap or read out of bounds.
//  Implements docs/ARCHITECTURE.md §2.4 (type-ownership registry: `ByteReader` is declared here) and
//  serves the read side of docs/spec-rtsp.md §4 (incremental wire decoding, header-line scanning),
//  docs/spec-rtp.md §3 (fixed-width big-endian header fields) and docs/spec-isapi.md §68 (multipart
//  boundary scanning).
//
//  No `import` on purpose: plain integer and collection work needs nothing from Foundation, and the
//  reader is generic over the buffer type so `Data`, `[UInt8]`, `ArraySlice<UInt8>` and
//  `UnsafeRawBufferPointer` all work without a conversion copy.
//

// MARK: - Errors

/// Why a `ByteReader` read failed.
///
/// These are the primitive parse failures; the domain error enums in `VigilError` wrap them with
/// module context (which message, which packet) when they cross a module boundary.
public enum ByteReaderError: Error, Equatable, Sendable, CustomStringConvertible {

    /// A read of `needed` bytes was attempted at `offset` with only `remaining` bytes left.
    ///
    /// This is the ordinary "truncated input" failure and is always caused by the peer, never by a
    /// programming mistake — treat it as data, log it, and drop or resynchronise.
    case outOfBounds(needed: Int, remaining: Int, offset: Int)

    /// A negative length was passed to `read`, `peek` or `skip`. Always a caller bug.
    case negativeLength(Int)

    /// `read(until:)` reached the end of the buffer without finding the delimiter, so the caller
    /// cannot yet (or ever) frame the unit it was looking for. `offset` is where the search started.
    case delimiterNotFound(offset: Int)

    public var description: String {
        switch self {
        case let .outOfBounds(needed, remaining, offset):
            return "ByteReader out of bounds: needed \(needed) B, \(remaining) B remaining at offset \(offset)"
        case let .negativeLength(n):
            return "ByteReader negative length \(n)"
        case let .delimiterNotFound(offset):
            return "ByteReader delimiter not found from offset \(offset)"
        }
    }
}

// MARK: - ByteReader

/// A forward-only cursor over a byte buffer.
///
/// The reader borrows its buffer: it never copies, never mutates it, and every slice it returns
/// aliases the original storage. All reads are bounds-checked and throw `ByteReaderError` rather
/// than trapping, because the bytes come from a camera on the network and a trap would be a crash
/// bug reachable by a hostile peer.
///
/// `offset` is measured from the *first element of the buffer*, not from `bytes.startIndex`, so a
/// reader over `data[100..<200]` starts at offset 0 and reports offsets a caller can reason about.
///
/// The reader is a value type, so `peek`-style lookahead of arbitrary complexity is just a copy:
/// `var probe = reader; let v = try probe.u32BE()` leaves `reader` untouched.
public struct ByteReader<Bytes: RandomAccessCollection>
where Bytes.Element == UInt8, Bytes.Index == Int {

    /// The buffer being read. Never copied; slices returned by `read`/`peek` alias it.
    public let bytes: Bytes

    /// Number of bytes consumed so far, counted from the first element of `bytes`.
    public private(set) var offset: Int

    /// Total number of readable bytes in the buffer.
    ///
    /// Cached at init: `count` is O(1) on a `RandomAccessCollection` but not free, and it is read on
    /// every bounds check on the per-packet path.
    public let count: Int

    /// Creates a reader positioned at the first byte of `bytes`.
    public init(_ bytes: Bytes) {
        self.bytes = bytes
        self.offset = 0
        self.count = bytes.count
    }

    // MARK: - Position

    /// Bytes not yet consumed. Never negative.
    @inlinable public var remaining: Int { count - offset }

    /// True when every byte has been consumed. True for an empty buffer.
    @inlinable public var isAtEnd: Bool { offset >= count }

    /// Index in `bytes`' own index space of the byte `distance` bytes past the cursor.
    @inline(__always)
    private func index(after distance: Int) -> Bytes.Index { bytes.startIndex + offset + distance }

    /// Bounds check shared by every read. Throws before any state changes, so a failed read always
    /// leaves the cursor exactly where it was.
    @inline(__always)
    private func ensure(_ n: Int) throws(ByteReaderError) {
        guard n >= 0 else { throw ByteReaderError.negativeLength(n) }
        guard n <= count - offset else {
            throw ByteReaderError.outOfBounds(needed: n, remaining: count - offset, offset: offset)
        }
    }

    // MARK: - Cursor movement

    /// Advances the cursor by `n` bytes.
    ///
    /// Throws `.outOfBounds` if fewer than `n` bytes remain and `.negativeLength` if `n < 0`; in
    /// both cases the cursor does not move.
    public mutating func skip(_ n: Int) throws(ByteReaderError) {
        try ensure(n)
        offset += n
    }

    // MARK: - Fixed-width integers, big-endian (network byte order)

    /// Reads one byte.
    public mutating func u8() throws(ByteReaderError) -> UInt8 {
        try ensure(1)
        let value = bytes[index(after: 0)]
        offset += 1
        return value
    }

    /// Reads two bytes as a big-endian `UInt16`.
    public mutating func u16BE() throws(ByteReaderError) -> UInt16 {
        UInt16(truncatingIfNeeded: try readBigEndian(2))
    }

    /// Reads three bytes as a big-endian 24-bit value, zero-extended into a `UInt32`.
    ///
    /// The result is never sign-extended: `FF FF FF` reads as `0x00FF_FFFF`.
    public mutating func u24BE() throws(ByteReaderError) -> UInt32 {
        UInt32(truncatingIfNeeded: try readBigEndian(3))
    }

    /// Reads four bytes as a big-endian `UInt32`.
    public mutating func u32BE() throws(ByteReaderError) -> UInt32 {
        UInt32(truncatingIfNeeded: try readBigEndian(4))
    }

    /// Reads eight bytes as a big-endian `UInt64`.
    public mutating func u64BE() throws(ByteReaderError) -> UInt64 {
        try readBigEndian(8)
    }

    // MARK: - Fixed-width integers, little-endian

    /// Reads two bytes as a little-endian `UInt16`.
    public mutating func u16LE() throws(ByteReaderError) -> UInt16 {
        UInt16(truncatingIfNeeded: try readLittleEndian(2))
    }

    /// Reads three bytes as a little-endian 24-bit value, zero-extended into a `UInt32`.
    public mutating func u24LE() throws(ByteReaderError) -> UInt32 {
        UInt32(truncatingIfNeeded: try readLittleEndian(3))
    }

    /// Reads four bytes as a little-endian `UInt32`.
    public mutating func u32LE() throws(ByteReaderError) -> UInt32 {
        UInt32(truncatingIfNeeded: try readLittleEndian(4))
    }

    /// Reads eight bytes as a little-endian `UInt64`.
    public mutating func u64LE() throws(ByteReaderError) -> UInt64 {
        try readLittleEndian(8)
    }

    /// Accumulates `n` (1...8) bytes most-significant first. Widening to `UInt64` before shifting is
    /// what keeps `u24BE`/`u32BE` free of the sign-extension bugs that plague hand-rolled readers.
    @inline(__always)
    private mutating func readBigEndian(_ n: Int) throws(ByteReaderError) -> UInt64 {
        try ensure(n)
        var value: UInt64 = 0
        var i = bytes.startIndex + offset
        let end = i + n
        while i < end {
            value = (value << 8) | UInt64(bytes[i])
            i += 1
        }
        offset += n
        return value
    }

    /// Accumulates `n` (1...8) bytes least-significant first.
    @inline(__always)
    private mutating func readLittleEndian(_ n: Int) throws(ByteReaderError) -> UInt64 {
        try ensure(n)
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var i = bytes.startIndex + offset
        let end = i + n
        while i < end {
            value |= UInt64(bytes[i]) << shift
            shift += 8
            i += 1
        }
        offset += n
        return value
    }

    // MARK: - Byte slices

    /// Reads exactly `n` bytes and advances the cursor.
    ///
    /// The returned slice aliases the buffer — no allocation, no copy. `n == 0` returns an empty
    /// slice and does not move the cursor. Throws `.outOfBounds` if fewer than `n` bytes remain.
    public mutating func read(_ n: Int) throws(ByteReaderError) -> Bytes.SubSequence {
        try ensure(n)
        let start = bytes.startIndex + offset
        offset += n
        return bytes[start..<(start + n)]
    }

    /// Consumes and returns everything from the cursor to the end of the buffer, possibly empty.
    public mutating func readRemaining() -> Bytes.SubSequence {
        let start = bytes.startIndex + offset
        let end = bytes.startIndex + count
        offset = count
        return bytes[start..<end]
    }

    // MARK: - Lookahead

    /// Returns the next `n` bytes without moving the cursor.
    ///
    /// Throws `.outOfBounds` if fewer than `n` bytes remain — a partially available unit must be
    /// distinguishable from a complete one, so this never returns a short slice.
    public func peek(_ n: Int) throws(ByteReaderError) -> Bytes.SubSequence {
        try ensure(n)
        let start = bytes.startIndex + offset
        return bytes[start..<(start + n)]
    }

    /// Returns the byte `distance` bytes past the cursor without moving it; `distance` defaults to
    /// the byte the cursor is on.
    ///
    /// Used for one-byte discrimination, e.g. the `$` (0x24) test that decides between an RTSP
    /// message and an interleaved frame (docs/spec-rtsp.md §4.3).
    public func peekU8(_ distance: Int = 0) throws(ByteReaderError) -> UInt8 {
        guard distance >= 0 else { throw ByteReaderError.negativeLength(distance) }
        try ensure(distance + 1)
        return bytes[index(after: distance)]
    }

    // MARK: - Delimiter search

    /// Distance from the cursor to the next occurrence of `byte`, or `nil` if it does not occur in
    /// the remaining bytes. `0` means the cursor is already on it.
    public func firstOffset(of byte: UInt8) -> Int? {
        let base = bytes.startIndex + offset
        var i = 0
        let n = remaining
        while i < n {
            if bytes[base + i] == byte { return i }
            i += 1
        }
        return nil
    }

    /// Distance from the cursor to the start of the next occurrence of `pattern`, or `nil` if the
    /// pattern does not occur *in full* before the end of the buffer.
    ///
    /// A pattern that is only partially present at the end of the buffer (e.g. a trailing `CR` when
    /// searching for `CRLF`) returns `nil`: for an incremental decoder that correctly means "not
    /// yet", never "not found". An empty pattern returns `0`.
    ///
    /// Plain O(n·m) scan with no allocation and no precomputed table — `m` here is a CRLF or a MIME
    /// boundary, tens of bytes at most, and the table setup would cost more than it saves.
    public func firstOffset(of pattern: some Collection<UInt8>) -> Int? {
        let m = pattern.count
        guard m > 0 else { return 0 }
        let n = remaining
        guard m <= n else { return nil }
        let base = bytes.startIndex + offset
        var start = 0
        while start <= n - m {
            var matched = 0
            var p = pattern.startIndex
            while matched < m, bytes[base + start + matched] == pattern[p] {
                matched += 1
                p = pattern.index(after: p)
            }
            if matched == m { return start }
            start += 1
        }
        return nil
    }

    /// Reads everything up to — but not including — the next occurrence of `delimiter`.
    ///
    /// The delimiter itself is consumed when `consumingDelimiter` is true (the default), which is
    /// what line-oriented parsing wants. Throws `.delimiterNotFound` and leaves the cursor
    /// untouched if the delimiter is absent, so the caller can wait for more bytes and retry.
    public mutating func read(
        until delimiter: UInt8, consumingDelimiter: Bool = true
    ) throws(ByteReaderError) -> Bytes.SubSequence {
        guard let distance = firstOffset(of: delimiter) else {
            throw ByteReaderError.delimiterNotFound(offset: offset)
        }
        let slice = try read(distance)
        if consumingDelimiter { try skip(1) }
        return slice
    }

    /// Reads everything up to — but not including — the next occurrence of `pattern`.
    ///
    /// The pattern is consumed when `consumingDelimiter` is true (the default). Throws
    /// `.delimiterNotFound` and leaves the cursor untouched if the pattern does not occur in full,
    /// including the case where only a prefix of it is present at the end of the buffer.
    public mutating func read(
        until pattern: some Collection<UInt8>, consumingDelimiter: Bool = true
    ) throws(ByteReaderError) -> Bytes.SubSequence {
        guard let distance = firstOffset(of: pattern) else {
            throw ByteReaderError.delimiterNotFound(offset: offset)
        }
        let slice = try read(distance)
        if consumingDelimiter { try skip(pattern.count) }
        return slice
    }
}

// MARK: - Sendable

/// A reader is safe to send exactly when its buffer is: `Data`, `[UInt8]` and `ArraySlice<UInt8>`
/// all qualify. `UnsafeRawBufferPointer` deliberately does not conform to `Sendable`, so a reader
/// over one is usable within a scope but cannot escape it — which is the correct guarantee.
extension ByteReader: Sendable where Bytes: Sendable {}
