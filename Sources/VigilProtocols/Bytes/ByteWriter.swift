//
//  ByteWriter.swift
//  VigilProtocols
//
//  The mirror of `ByteReader`: an append-only byte buffer for building the messages this app sends —
//  RTSP requests (docs/spec-rtsp.md §3.1), RTCP receiver reports (docs/spec-rtp.md §9), SADP probes
//  (docs/spec-discovery.md) and `avcC`/`hvcC` configuration records (docs/spec-bitstream.md §17).
//  Implements docs/ARCHITECTURE.md §2.4 (type-ownership registry: `ByteWriter` is declared here).
//
//  Writing cannot fail, so nothing here throws; the only way to misuse it is an over-wide value
//  passed to a narrow append, which is documented as truncating rather than trapping.
//

import Foundation

/// An append-only byte buffer with explicit endianness at every call site.
///
/// Storage is a single `[UInt8]` that grows amortised-constant. `reserveCapacity` up front and the
/// whole build is one allocation. `data` and `bytes` are the finalisers: `bytes` hands back the
/// storage with no copy, `data` copies once into a `Data` for the transport layer.
public struct ByteWriter: Sendable {

    /// The bytes written so far, in order. Handing this back is free — it is the storage itself.
    public private(set) var bytes: [UInt8]

    /// Creates an empty writer.
    public init() {
        self.bytes = []
    }

    /// Creates an empty writer with room for `capacity` bytes already allocated.
    ///
    /// A negative or zero `capacity` is simply ignored; it is a hint, not a limit, and the writer
    /// still grows past it on demand.
    public init(capacity: Int) {
        self.bytes = []
        if capacity > 0 { self.bytes.reserveCapacity(capacity) }
    }

    // MARK: - State

    /// Number of bytes written.
    @inlinable public var count: Int { bytes.count }

    /// True when nothing has been written yet.
    @inlinable public var isEmpty: Bool { bytes.isEmpty }

    /// Ensures room for at least `capacity` bytes in total, so a long build does not reallocate.
    public mutating func reserveCapacity(_ capacity: Int) {
        if capacity > 0 { bytes.reserveCapacity(capacity) }
    }

    /// Discards everything written, keeping the allocation so the writer can be reused for the next
    /// message on the same connection.
    public mutating func removeAll() {
        bytes.removeAll(keepingCapacity: true)
    }

    // MARK: - Finalising

    /// The bytes written so far as `Data`. Copies once; call it at the end of a build, not in a loop.
    public var data: Data { Data(bytes) }

    // MARK: - Bytes and strings

    /// Appends one byte.
    public mutating func append(_ byte: UInt8) {
        bytes.append(byte)
    }

    /// Appends every byte of `sequence`, in order.
    public mutating func append(contentsOf sequence: some Sequence<UInt8>) {
        bytes.append(contentsOf: sequence)
    }

    /// Appends `string` encoded as UTF-8, with no length prefix and no terminator.
    ///
    /// Nothing is escaped: RTSP and SDP text is assembled by the caller, which knows the grammar.
    /// A string containing non-ASCII produces multi-byte UTF-8, which is correct for ISAPI XML
    /// bodies and for `User-Agent`, and is what Hikvision firmware expects.
    public mutating func appendUTF8(_ string: String) {
        bytes.append(contentsOf: string.utf8)
    }

    /// Appends CR LF (0x0D 0x0A).
    ///
    /// Every line of every message this app sends — RTSP, HTTP and multipart — ends this way, and
    /// Hikvision firmware rejects a bare LF in a request, so this is spelled out once here.
    public mutating func appendCRLF() {
        bytes.append(0x0D)
        bytes.append(0x0A)
    }

    // MARK: - Fixed-width integers, big-endian (network byte order)

    /// Appends `value` as two bytes, most significant first.
    public mutating func appendU16BE(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    /// Appends the low 24 bits of `value` as three bytes, most significant first.
    ///
    /// Bits 24...31 are discarded rather than trapping: 24-bit fields (RTCP lengths, SADP fields,
    /// AAC AU headers) are always produced from a value the caller has already range-checked.
    public mutating func appendU24BE(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    /// Appends `value` as four bytes, most significant first.
    public mutating func appendU32BE(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    /// Appends `value` as eight bytes, most significant first.
    public mutating func appendU64BE(_ value: UInt64) {
        var shift = 56
        while shift >= 0 {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
            shift -= 8
        }
    }

    // MARK: - Fixed-width integers, little-endian

    /// Appends `value` as two bytes, least significant first.
    public mutating func appendU16LE(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    /// Appends the low 24 bits of `value` as three bytes, least significant first. Bits 24...31 are
    /// discarded, as in `appendU24BE`.
    public mutating func appendU24LE(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
    }

    /// Appends `value` as four bytes, least significant first.
    public mutating func appendU32LE(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    /// Appends `value` as eight bytes, least significant first.
    public mutating func appendU64LE(_ value: UInt64) {
        var shift = 0
        while shift <= 56 {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
            shift += 8
        }
    }
}
