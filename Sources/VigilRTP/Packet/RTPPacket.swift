//
//  RTPPacket.swift
//  VigilRTP
//
//  The RFC 3550 §5.1 fixed header: parse, CSRC list, header extension, padding removal.
//  Implements docs/spec-rtp.md §3 and docs/API_CONTRACT.md §4.4 / §5.5 (`Packet/RTPPacket.swift`).
//

import Foundation
import VigilProtocols

// MARK: - Byte access

/// Index-normalised read-only access to a `Data` that may be a slice.
///
/// `Data` slices keep the parent's indices, so `slice[0]` traps whenever `startIndex != 0`. Every
/// byte read in this module goes through this wrapper; a bare `payload[n]` with an integer literal
/// is a bug, not a style choice (docs/spec-rtp.md §3.5).
@usableFromInline
struct RTPBytes {

    @usableFromInline let base: Data
    @usableFromInline let start: Int
    @usableFromInline let count: Int

    @inlinable init(_ data: Data) {
        base = data
        start = data.startIndex
        count = data.count
    }

    /// The byte at `index` counted from the start of the buffer, not from the parent's `startIndex`.
    @inlinable subscript(index: Int) -> UInt8 { base[start + index] }

    /// Big-endian 16-bit read at `index`. The caller must have bounds-checked `index + 1`.
    @inlinable func u16(_ index: Int) -> UInt16 {
        UInt16(self[index]) << 8 | UInt16(self[index + 1])
    }

    /// Big-endian 32-bit read at `index`. The caller must have bounds-checked `index + 3`.
    @inlinable func u32(_ index: Int) -> UInt32 {
        UInt32(u16(index)) << 16 | UInt32(u16(index + 2))
    }

    /// A zero-copy sub-slice in this buffer's own coordinates.
    @inlinable func slice(_ range: Range<Int>) -> Data {
        base[(start + range.lowerBound)..<(start + range.upperBound)]
    }
}

// MARK: - RTPPacket

/// One parsed RTP packet.
///
/// `payload` is a zero-copy slice of the caller's buffer with any RFC 3550 padding already removed,
/// so it may be empty — an empty payload is legal and Hikvision emits one at the end of some GOPs.
/// The slice keeps the parent's indices; read it through `RTPBytes` or `Data`'s own iteration, never
/// with a bare integer subscript.
public struct RTPPacket: Sendable, Equatable {

    // MARK: - Stored Properties

    /// RTP version. Always 2 for a packet that parsed; a different value is `RTPError.badVersion`.
    public var version: UInt8
    /// The `P` bit. When set, padding has already been stripped from `payload`.
    public var hasPadding: Bool
    /// The `X` bit. When set, `extensionProfile` and `extensionData` are non-nil.
    public var hasExtension: Bool
    /// The `CC` field, 0…15. Hikvision cameras and NVRs always send 0.
    public var csrcCount: UInt8
    /// The `M` bit. **Never trust it for access-unit boundaries** (docs/spec-rtp.md §7).
    public var marker: Bool
    /// The 7-bit payload type. A value other than the track's is dropped and counted.
    public var payloadType: UInt8
    /// The 16-bit sequence number. Compare only with `seqLess`/`seqDiff`, never with `<`.
    public var sequenceNumber: UInt16
    /// The 32-bit media timestamp. Wraps every ~13 h 15 m at 90 kHz; unwrap before use.
    public var timestamp: UInt32
    /// The synchronisation source. A change means a hard reset of the whole receiver.
    public var ssrc: UInt32
    /// Contributing sources. Parsed so the payload offset is right; never acted on.
    public var csrc: [UInt32]
    /// The header-extension profile identifier, or `nil` when `X` was clear.
    public var extensionProfile: UInt16?
    /// The header-extension body, exactly `length * 4` bytes, or `nil` when `X` was clear.
    public var extensionData: Data?
    /// The payload, padding removed. Possibly empty.
    public var payload: Data

    /// The smallest legal RTP packet: version/flags, sequence, timestamp, SSRC.
    public static let fixedHeaderSize = 12

    // MARK: - Initialisation

    /// Memberwise initialiser. Used by the parser, by fixtures and by the synthetic generator.
    public init(
        version: UInt8 = 2,
        hasPadding: Bool = false,
        hasExtension: Bool = false,
        csrcCount: UInt8 = 0,
        marker: Bool = false,
        payloadType: UInt8,
        sequenceNumber: UInt16,
        timestamp: UInt32,
        ssrc: UInt32,
        csrc: [UInt32] = [],
        extensionProfile: UInt16? = nil,
        extensionData: Data? = nil,
        payload: Data
    ) {
        self.version = version
        self.hasPadding = hasPadding
        self.hasExtension = hasExtension
        self.csrcCount = csrcCount
        self.marker = marker
        self.payloadType = payloadType
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.csrc = csrc
        self.extensionProfile = extensionProfile
        self.extensionData = extensionData
        self.payload = payload
    }

    // MARK: - Computed Properties

    /// The header extension in parsed form, or `nil` when the `X` bit was clear.
    ///
    /// Element decoding is deliberately lazy: the profile is almost always one we do not interpret,
    /// so the per-packet path never walks the elements.
    public var headerExtension: RTPHeaderExtension? {
        guard let extensionProfile, let extensionData else { return nil }
        return RTPHeaderExtension(profile: extensionProfile, data: extensionData)
    }

    /// Byte offset at which `payload` begins, counted from the start of the packet.
    public var payloadOffset: Int {
        var offset = Self.fixedHeaderSize + 4 * Int(csrcCount)
        if let extensionData { offset += 4 + extensionData.count }
        return offset
    }

    // MARK: - Parsing

    /// Parses one RTP packet from a complete datagram or one de-interleaved `$` frame.
    ///
    /// Every length in the header is validated against the buffer before it is used, so a hostile
    /// CSRC count, an extension length that runs past the end, or a padding byte claiming more
    /// padding than the packet holds each throws rather than reading out of bounds.
    ///
    /// - Parameter bytes: the packet, with no interleave framing and no trailing bytes.
    /// - Returns: the parsed packet, whose `payload` is a slice of `bytes` — no copy is made.
    /// - Throws: `RTPError.shortPacket` below 12 bytes, `.badVersion` when `V != 2`,
    ///   `.truncatedCSRC` when `CC` exceeds the buffer, `.truncatedExtension` when the extension
    ///   length exceeds it, and `.badPaddingLength` when the padding count is zero or would eat
    ///   into the header. All five are per-packet failures: count them and read the next packet.
    public static func parse(_ bytes: Data) throws(RTPError) -> RTPPacket {
        let b = RTPBytes(bytes)
        guard b.count >= fixedHeaderSize else { throw .shortPacket(length: b.count) }

        let flags = b[0]
        let version = (flags & 0xC0) >> 6
        guard version == 2 else { throw .badVersion(version) }

        let csrcCount = Int(flags & 0x0F)
        var headerEnd = fixedHeaderSize + 4 * csrcCount
        guard b.count >= headerEnd else { throw .truncatedCSRC }

        var extensionProfile: UInt16?
        var extensionData: Data?
        let hasExtension = flags & 0x10 != 0
        if hasExtension {
            guard b.count >= headerEnd + 4 else { throw .truncatedExtension }
            let profile = b.u16(headerEnd)
            // `words` is at most 65535, so `words * 4` cannot overflow `Int` on any platform.
            let words = Int(b.u16(headerEnd + 2))
            let bodyStart = headerEnd + 4
            let bodyEnd = bodyStart + words * 4
            guard b.count >= bodyEnd else { throw .truncatedExtension }
            extensionProfile = profile
            extensionData = b.slice(bodyStart..<bodyEnd)
            headerEnd = bodyEnd
        }

        var payloadEnd = b.count
        let hasPadding = flags & 0x20 != 0
        if hasPadding {
            let pad = Int(b[b.count - 1])
            guard pad >= 1, headerEnd + pad <= b.count else {
                throw .badPaddingLength(UInt8(truncatingIfNeeded: pad))
            }
            payloadEnd = b.count - pad
        }

        // The shared empty array when CC == 0, which is every Hikvision packet: no allocation.
        let csrc: [UInt32] = csrcCount == 0 ? [] : (0..<csrcCount).map { b.u32(12 + 4 * $0) }

        return RTPPacket(
            version: 2,
            hasPadding: hasPadding,
            hasExtension: hasExtension,
            csrcCount: UInt8(csrcCount),
            marker: b[1] & 0x80 != 0,
            payloadType: b[1] & 0x7F,
            sequenceNumber: b.u16(2),
            timestamp: b.u32(4),
            ssrc: b.u32(8),
            csrc: csrc,
            extensionProfile: extensionProfile,
            extensionData: extensionData,
            payload: b.slice(headerEnd..<payloadEnd)
        )
    }
}
